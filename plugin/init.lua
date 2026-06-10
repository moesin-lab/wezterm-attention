local wezterm = require("wezterm")

local M = {}

-- ── Defaults ────────────────────────────────────────────────────────────────

local home = wezterm.home_dir or os.getenv("HOME") or os.getenv("USERPROFILE") or "/tmp"

local defaults = {
  -- Where marker files are written (one file per pane ID)
  dir = home .. "/.local/state/wezterm-attention",

  -- Render mode: "tab" | "manual"
  --   tab:    plugin owns format-tab-title (default)
  --   manual: plugin registers no tab handler; use wrap_title_formatter() or API
  renderer = "tab",

  -- Tab background tint per attention type (subtle, dark)
  colors = {
    thinking = "#1c1730",
    stop     = "#12271c",
    notify   = "#240f16",
    review   = "#1a1a0c",
  },

  -- Tab text indicators
  indicators = {
    thinking_frames = { "◌ ", "◔ ", "◑ ", "◕ " },
    stop   = "✓ ",
    notify = "! ",
    review = "◆ ",
  },

  -- Higher index = higher priority when multiple panes have attention
  priority = { "thinking", "review", "stop", "notify" },

  -- These types auto-clear when their tab becomes active
  auto_clear = { "stop", "notify" },

  -- Keybind to toggle "review" marker on active pane (false to disable)
  review_key = { key = "b", mods = "ALT" },

  -- User var name watched for remote/SSH attention updates (false to disable)
  user_var = "wezterm_attention",

  -- Seconds without a refresh before a "thinking" marker is considered
  -- abandoned (writer crashed) and dropped. false to disable.
  thinking_ttl = 600,

  -- Drive tab bar repaints while attention state exists (false to disable).
  -- WezTerm only recomputes tab titles when something it knows about changes
  -- (right status content, user vars, mouse, tab switches) — cache-internal
  -- transitions like spinner frames, TTL expiry and auto-clear are invisible
  -- to it. poll() flips a zero-width character through set_right_status to
  -- force the recompute; visually a no-op.
  drive_repaint = true,
}

-- Known attention types (reject unknown values from marker files / user vars)
local valid_types = { thinking = true, stop = true, notify = true, review = true }

-- ── Filesystem helpers ──────────────────────────────────────────────────────

local is_windows = package.config:sub(1, 1) == "\\"

-- Create the marker dir via argv (no shell quoting issues), then verify it
-- is actually writable with a probe file — mkdir exit codes differ across
-- platforms (cmd's mkdir fails when the dir already exists). Only a verified
-- dir is cached as ready, so transient failures retry on the next write.
local dir_ready = {}
local function ensure_dir(dir)
  if dir_ready[dir] then return true end
  local argv
  if is_windows then
    -- cmd's mkdir creates parents natively but chokes on forward slashes
    argv = { "cmd.exe", "/c", "mkdir", (dir:gsub("/", "\\")) }
  else
    argv = { "mkdir", "-p", dir }
  end
  pcall(wezterm.run_child_process, argv)

  local probe = dir .. "/.probe"
  local f = io.open(probe, "w")
  if f then
    f:close()
    os.remove(probe)
    dir_ready[dir] = true
    return true
  end
  wezterm.log_warn("wezterm-attention: marker dir not writable: " .. dir)
  return false
end

-- ── Marker I/O ──────────────────────────────────────────────────────────────

--- Parse marker content / user var value into (type, frame).
--- Accepts JSON ({"type":"thinking","frame":2}) or plain text ("stop").
--- Returns nil for anything that isn't a known attention type.
local function parse_state(value)
  if type(value) ~= "string" then return nil end

  if value:match("^%s*{") then
    local ok, data = pcall(wezterm.json_parse, value)
    if ok and type(data) == "table" and valid_types[data.type] then
      local frame = tonumber(data.frame)
      return data.type, frame and math.floor(frame) or nil
    end
    return nil
  end

  local text = value:gsub("%s+", "")
  if valid_types[text] then return text end
  return nil
end

--- Parse a user var value. Same as parse_state, plus "clear" (plain or JSON).
local function parse_attention_value(value)
  if type(value) ~= "string" then return nil end
  if value:gsub("%s+", "") == "clear" then return "clear" end
  if value:match("^%s*{") then
    local ok, data = pcall(wezterm.json_parse, value)
    if ok and type(data) == "table" and data.type == "clear" then return "clear" end
  end
  return parse_state(value)
end

--- Read a pane's marker file.
--- Returns (type, frame, raw). raw is non-nil whenever the file exists, even
--- if its content didn't parse — that distinguishes "marker removed" from
--- "partial write in flight".
local function read_marker(dir, pane_id)
  local f = io.open(dir .. "/" .. pane_id, "r")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  local atype, frame = parse_state(content)
  return atype, frame, content
end

local function remove_marker(dir, pane_id)
  os.remove(dir .. "/" .. pane_id)
end

--- Write a marker file atomically: unique tmp name, then rename over <id>.
--- The unique name keeps concurrent writers (hooks, user vars, keybinds)
--- from trampling each other's half-written tmp files.
--- Returns the content written, or nil on failure.
local tmp_seq = 0
local function write_marker(dir, pane_id, atype, frame)
  if not ensure_dir(dir) then return nil end
  local path = dir .. "/" .. pane_id

  local content
  if frame then
    content = string.format('{"type":"%s","frame":%d}', atype, frame)
  else
    content = string.format('{"type":"%s"}', atype)
  end

  tmp_seq = tmp_seq + 1
  local tmp = string.format("%s.%d.%d.tmp", path, os.time(), tmp_seq)
  local f = io.open(tmp, "w")
  if not f then return nil end
  f:write(content)
  f:close()

  if not os.rename(tmp, path) then
    -- Windows rename() can't replace an existing target; replace manually.
    -- The remove→rename gap is sub-ms vs a 1s poll interval.
    os.remove(path)
    if not os.rename(tmp, path) then
      os.remove(tmp)
      return nil
    end
  end
  return content
end

-- ── In-memory cache ─────────────────────────────────────────────────────────
-- format-tab-title must not do I/O (blocks GUI thread).
-- update-status reads files on the interval; format-tab-title reads cache.

-- { [pane_id_string] = { type, frame, raw, fresh, invalid } }
--   raw:     marker file content this entry was built from (change detection)
--   fresh:   os.time() of the last observed change (drives thinking_ttl)
--   invalid: consecutive polls the file existed but didn't parse; an entry
--            may exist with type = nil purely to count a garbage file down
--            (renderers must check entry.type)
local attention_cache = {}

-- ── Directory hygiene ───────────────────────────────────────────────────────

--- Drop markers and cache entries for panes that no longer exist, plus
--- orphaned .tmp files from crashed writers. Runs on the first poll (startup
--- cleanup) and periodically after that — there is no wezterm event for pane
--- destruction.
---
--- Cleanup is live-aware on purpose: a blind directory sweep at startup
--- would also delete markers for panes that are still alive when the GUI
--- reconnects to a long-lived mux server (`wezterm connect`), or markers
--- written via user var before the first poll. The cost is that after a
--- fresh start, a leftover marker whose pane ID happens to be reused by the
--- new session survives until auto-clear/TTL handles it — losing user state
--- is strictly worse than briefly mislabeling a tab.
local function reap(dir)
  local live = {}
  local ok = pcall(function()
    for _, w in ipairs(wezterm.mux.all_windows()) do
      for _, t in ipairs(w:tabs()) do
        for _, p in ipairs(t:panes()) do
          live[tostring(p:pane_id())] = true
        end
      end
    end
  end)
  if not ok then return end

  local ok_dir, entries = pcall(wezterm.read_dir, dir)
  if ok_dir and entries then
    for _, path in ipairs(entries) do
      local name = path:match("([^/\\]+)$") or path
      if name:match("%.tmp$") then
        -- orphaned tmp; an in-flight external write loses a sub-ms race at
        -- worst, and that writer's next update restores the marker
        os.remove(path)
      elseif name:match("^%d+$") and not live[name] then
        os.remove(path)
      end
    end
  end

  for id in pairs(attention_cache) do
    if not live[id] then attention_cache[id] = nil end
  end
end

-- ── Internal helpers ────────────────────────────────────────────────────────

--- Build the default tab title: "dir / pane_title"
local function default_title(tab)
  local pane = tab.active_pane
  local title = pane.title or ""

  local cwd = pane.current_working_dir
  local dir_name = ""
  if cwd then
    local path = cwd.file_path or cwd.path or tostring(cwd)
    dir_name = string.match(path, "([^/]+)/?$") or ""
  end

  return dir_name ~= "" and (dir_name .. " / " .. title) or title
end

--- Get the resolved attention indicator and type for a tab.
--- Considers all panes and applies priority. Returns (indicator, type, color) or ("", nil, nil).
--- The thinking spinner is time-driven (advances once per second) — writers
--- don't control animation.
local function get_tab_attention(tab, opts)
  local cfg_indicators = (opts and opts.indicators) or M._active_indicators or defaults.indicators
  local cfg_colors = (opts and opts.colors) or M._active_colors or defaults.colors
  local cfg_priority = M._active_priority_map or {}

  local best_type     = nil
  local best_priority = -1

  for _, p in ipairs(tab.panes) do
    local cached = attention_cache[tostring(p.pane_id)]
    if cached and cached.type then
      local pri = cfg_priority[cached.type] or 0
      if pri > best_priority then
        best_type     = cached.type
        best_priority = pri
      end
    end
  end

  if not best_type then return "", nil, nil end

  local indicator = ""
  if best_type == "thinking" then
    local frames = cfg_indicators.thinking_frames
    indicator = frames[(os.time() % #frames) + 1]
  elseif cfg_indicators[best_type] then
    indicator = cfg_indicators[best_type]
  end

  return indicator, best_type, cfg_colors[best_type]
end

-- ── Public API ──────────────────────────────────────────────────────────────

--- Read the cached attention state for a pane.
--- Returns (type, frame) or nil.
function M.get_attention(pane_id, opts)
  local id = tostring(pane_id)
  if opts and opts.dir then
    return read_marker(opts.dir, id)
  end
  local cached = attention_cache[id]
  if cached and cached.type then return cached.type, cached.frame end
  return nil
end

--- Remove the attention marker for a pane.
function M.remove_marker(pane_id, opts)
  local dir = (opts and opts.dir) or defaults.dir
  local id = tostring(pane_id)
  remove_marker(dir, id)
  attention_cache[id] = nil
end

--- Poll marker files and update cache. Call from your own update-status
--- handler if you set auto_poll = false.
---
--- This is the single place markers transition state:
---   - new/changed file content refreshes the cache entry
---   - auto_clear types are dropped when their tab is active in a focused window
---   - "thinking" entries expire after thinking_ttl without a refresh
---   - a file that exists but doesn't parse keeps the previous state for one
---     poll (partial write in flight), then is dropped as corrupt
---
--- Only refreshes entries for panes in the current window. Cross-window cache
--- entries are left alone — pruning them here would cause cache thrash when
--- multiple windows fire update-status. Dead panes are cleaned up by the
--- periodic reaper below (wezterm has no pane-destroyed event).
local poll_count = 0
local REAP_EVERY = 30
local repaint_flip = false
local had_state = false

function M.poll(window, opts)
  local dir = (opts and opts.dir) or M._active_dir or defaults.dir
  local mux_win = window:mux_window()
  if not mux_win then return end

  local now = os.time()
  local ttl = M._active_thinking_ttl
  if ttl == nil then ttl = defaults.thinking_ttl end
  local clear_set = M._active_clear_set or { stop = true, notify = true }

  local active_tab_id
  local ok, active_tab = pcall(function() return window:active_tab() end)
  if ok and active_tab then active_tab_id = active_tab:tab_id() end

  -- auto_clear means "the user has seen it" — require window focus, not just
  -- tab activation, or background windows clear their own markers unseen.
  local focused = true
  local ok_f, is_f = pcall(function() return window:is_focused() end)
  if ok_f and is_f == false then focused = false end

  for _, tab in ipairs(mux_win:tabs()) do
    local tab_is_active = active_tab_id ~= nil and tab:tab_id() == active_tab_id
    for _, p in ipairs(tab:panes()) do
      local id = tostring(p:pane_id())
      local atype, frame, raw = read_marker(dir, id)
      local entry = attention_cache[id]

      -- Ingest
      if atype then
        if entry and entry.raw == raw then
          entry.invalid = nil
        else
          entry = { type = atype, frame = frame, raw = raw, fresh = now }
          attention_cache[id] = entry
        end
      elseif raw ~= nil then
        -- Exists but unparsable. Tolerate one poll (partial write in
        -- flight), then treat as corrupt — a corrupt file must not shield
        -- a stale entry from auto-clear/TTL forever.
        entry = entry or {}
        attention_cache[id] = entry
        entry.invalid = (entry.invalid or 0) + 1
        if entry.invalid >= 2 then
          remove_marker(dir, id)
          attention_cache[id] = nil
          entry = nil
        end
      else
        attention_cache[id] = nil
        entry = nil
      end

      -- Lifecycle (also applies to entries kept through an invalid read)
      if entry and entry.type then
        if tab_is_active and focused and clear_set[entry.type] then
          remove_marker(dir, id)
          attention_cache[id] = nil
        elseif ttl and entry.type == "thinking" and now - (entry.fresh or now) > ttl then
          -- writer stopped refreshing; assume it died
          remove_marker(dir, id)
          attention_cache[id] = nil
        end
      end
    end
  end

  poll_count = poll_count + 1
  if poll_count == 1 or poll_count % REAP_EVERY == 0 then
    -- first poll doubles as startup cleanup (see reap); poll_count resets on
    -- config reload, so reloads get an extra (harmless) reap too
    reap(dir)
  end

  -- Drive a repaint while any attention state exists (and once more on the
  -- tick it goes away, so the cleared indicator actually disappears).
  -- Alternating zero-width content defeats wezterm's "status unchanged, skip
  -- repaint" check. See defaults.drive_repaint.
  local drive = M._active_drive_repaint
  if drive == nil then drive = defaults.drive_repaint end
  if drive then
    local has_state = next(attention_cache) ~= nil
    if has_state or had_state then
      repaint_flip = not repaint_flip
      pcall(function()
        window:set_right_status(repaint_flip and "\u{200B}" or "")
      end)
    end
    had_state = has_state
  end
end

--- Wrap a user's title function with attention decoration.
--- For renderer = "manual" mode. Returns a function suitable for wezterm.on("format-tab-title", ...).
--- Pure: no I/O, no state mutation (auto-clear happens in poll()).
---
--- Usage:
---   wezterm.on("format-tab-title", attention.wrap_title_formatter(function(tab, ctx)
---     return string.format("%d %s", tab.tab_index + 1, ctx.default_title)
---   end))
function M.wrap_title_formatter(base_fn)
  return function(tab, tabs, panes, config, hover, max_width)
    local ctx = {
      tabs         = tabs,
      panes        = panes,
      config       = config,
      hover        = hover,
      max_width    = max_width,
      default_title = default_title(tab),
      attention    = { get_tab_attention(tab) },
    }

    local base = base_fn(tab, ctx)
    local index = tab.tab_index + 1

    if tab.is_active then
      return " " .. index .. ": " .. base .. " "
    end

    local indicator, atype, color = get_tab_attention(tab)
    local text = " " .. indicator .. index .. ": " .. base .. " "

    if color then
      return {
        { Background = { Color = color } },
        { Text = text },
      }
    end

    return text
  end
end

-- ── apply_to_config ─────────────────────────────────────────────────────────

local applied = false

function M.apply_to_config(config, opts)
  if applied then return end
  applied = true

  opts = opts or {}

  -- Merge options with defaults
  local dir = opts.dir or defaults.dir
  local auto_poll = opts.auto_poll ~= false
  M._active_dir = dir

  -- Resolve renderer: support both new "renderer" and legacy "format_tab_title"
  local renderer = opts.renderer or defaults.renderer
  if opts.format_tab_title == false then renderer = "manual" end

  local title_formatter = opts.title_formatter -- optional user callback

  local colors = {}
  for k, v in pairs(defaults.colors) do colors[k] = v end
  if opts.colors then
    for k, v in pairs(opts.colors) do colors[k] = v end
  end
  M._active_colors = colors

  local indicators = {}
  for k, v in pairs(defaults.indicators) do indicators[k] = v end
  if opts.indicators then
    for k, v in pairs(opts.indicators) do indicators[k] = v end
  end
  -- A bad thinking_frames (empty/non-table) would crash every tab repaint
  if type(indicators.thinking_frames) ~= "table" or #indicators.thinking_frames == 0 then
    wezterm.log_warn("wezterm-attention: invalid indicators.thinking_frames; using defaults")
    indicators.thinking_frames = defaults.indicators.thinking_frames
  end
  M._active_indicators = indicators

  local auto_clear = opts.auto_clear or defaults.auto_clear
  local priority   = opts.priority   or defaults.priority

  local thinking_ttl = opts.thinking_ttl
  if thinking_ttl == nil then thinking_ttl = defaults.thinking_ttl end
  M._active_thinking_ttl = thinking_ttl

  local drive_repaint = opts.drive_repaint
  if drive_repaint == nil then drive_repaint = defaults.drive_repaint end
  M._active_drive_repaint = drive_repaint

  -- Build lookup tables
  local clear_set = {}
  for _, t in ipairs(auto_clear) do clear_set[t] = true end
  M._active_clear_set = clear_set

  local priority_map = {}
  for i, t in ipairs(priority) do priority_map[t] = i end
  M._active_priority_map = priority_map

  -- ── Poller: update-status ─────────────────────────────────────────────
  -- (startup cleanup and dead-pane reaping happen inside poll)

  if auto_poll then
    wezterm.on("update-status", function(window, _pane)
      M.poll(window)
    end)
  end

  -- ── User var bridge: SSH/remote sessions ─────────────────────────────
  -- Remote hooks can't write local marker files; they emit OSC 1337
  -- SetUserVar instead and we translate it into a marker here.

  local user_var = opts.user_var
  if user_var == nil then user_var = defaults.user_var end

  if user_var then
    wezterm.on("user-var-changed", function(_window, pane, name, value)
      if name ~= user_var then return end

      local atype, frame = parse_attention_value(value)
      if not atype then
        wezterm.log_warn("wezterm-attention: ignoring invalid user var value: " .. tostring(value))
        return
      end

      local id = tostring(pane:pane_id())
      if atype == "clear" then
        remove_marker(dir, id)
        attention_cache[id] = nil
        return
      end

      -- Every event refreshes `fresh`, so repeated identical values still
      -- keep a "thinking" entry alive past thinking_ttl.
      local raw = write_marker(dir, id, atype, frame)
      if raw then
        attention_cache[id] = { type = atype, frame = frame, raw = raw, fresh = os.time() }
      end
    end)
  end

  -- ── Renderer: format-tab-title ────────────────────────────────────────
  -- Pure: reads cache only. All state transitions live in poll().

  if renderer == "tab" then
    wezterm.on("format-tab-title", function(tab)
      local index = tab.tab_index + 1

      -- Build base title (user callback or default)
      local base
      if title_formatter then
        local ctx = {
          default_title = default_title(tab),
          attention     = { get_tab_attention(tab) },
        }
        base = title_formatter(tab, ctx)
      else
        base = default_title(tab)
      end

      -- Active tab: plain title (auto-clear happens in poll)
      if tab.is_active then
        return " " .. index .. ": " .. base .. " "
      end

      -- Inactive tab: attention indicator + background tint
      local indicator, attention_type, color = get_tab_attention(tab)
      local text = " " .. indicator .. index .. ": " .. base .. " "

      if color then
        return {
          { Background = { Color = color } },
          { Text = text },
        }
      end

      return text
    end)
  end
  -- renderer == "manual": no format-tab-title registered

  -- ── Review toggle keybind ─────────────────────────────────────────────

  local review_key = opts.review_key
  if review_key == nil then review_key = defaults.review_key end

  if review_key then
    config.keys = config.keys or {}
    table.insert(config.keys, {
      key  = review_key.key,
      mods = review_key.mods,
      action = wezterm.action_callback(function(_win, pane)
        local id = tostring(pane:pane_id())

        local cached = attention_cache[id]
        if cached and cached.type == "review" then
          remove_marker(dir, id)
          attention_cache[id] = nil
          return
        end

        local raw = write_marker(dir, id, "review")
        if raw then
          attention_cache[id] = { type = "review", raw = raw, fresh = os.time() }
        end
      end),
    })
  end
end

return M
