# wezterm-attention

A WezTerm plugin that turns your tab bar into a notification system. Any CLI tool — AI agents, build scripts, test runners — can signal state changes via simple marker files, and WezTerm reflects them as colored tab indicators.

## What it looks like

| State | Indicator | Tab tint | Meaning |
|-------|-----------|----------|---------|
| `thinking` | ◌ ◔ ◑ ◕ (animated) | Violet | Agent is working |
| `stop` | ✓ | Mint | Agent finished — check results |
| `notify` | ! | Rose | Something needs your attention |
| `review` | ◆ | Gold | Manually flagged for review |

Inactive tabs light up when a background process writes a marker. Active tabs auto-clear `stop` and `notify` (you've seen it). `review` persists until explicitly removed. `thinking` persists while the writer keeps refreshing it, and expires after `thinking_ttl` (default 10 minutes) without a refresh — so a crashed agent doesn't leave a tab claiming "working" forever.

When multiple panes in a tab have different states, the highest-priority one wins: **notify > stop > review > thinking**.

## Install

Add one line to your `wezterm.lua`:

```lua
local attention = wezterm.plugin.require("https://github.com/moesin-lab/wezterm-attention")
attention.apply_to_config(config)
```

By default, the plugin owns tab title formatting (`dir / title` + attention indicators). It also registers pane cleanup, a marker poller, and an `Alt+B` keybind to toggle review mode.

> **Important:** WezTerm only runs the **first** registered `format-tab-title` handler. If another plugin (e.g. tabline.wez) registers one before this plugin, the visual output — indicators, colors, title formatting — is disabled. The poller, auto-clear, TTL expiry and user var bridge keep working (they don't live in the render path). Make sure `apply_to_config` runs before any other plugin that touches tab titles, or use `renderer = "manual"` to integrate via the API instead.

## Render modes

The plugin supports two render modes:

| Mode | Who owns `format-tab-title` | Per-tab colors | Use when |
|------|---------------------------|----------------|----------|
| `tab` (default) | Plugin | Yes | You want it to just work |
| `manual` | You | Yes | You have a custom tab formatter |

```lua
-- Default: plugin owns everything
attention.apply_to_config(config)

-- Manual: you own format-tab-title, plugin provides helpers
attention.apply_to_config(config, { renderer = "manual" })
wezterm.on("format-tab-title", attention.wrap_title_formatter(function(tab, ctx)
  return ctx.default_title  -- your custom logic here
end))
```

## Custom tab titles

In `tab` mode, pass a `title_formatter` to control the base title without losing indicators:

```lua
attention.apply_to_config(config, {
  title_formatter = function(tab, ctx)
    -- ctx.default_title = "dir / pane_title"
    -- ctx.attention = { indicator, type, color }
    local pane = tab.active_pane
    return pane.title  -- just the pane title, no directory
  end,
})
```

## Configure

All options are optional — defaults work out of the box:

```lua
attention.apply_to_config(config, {
  -- Render mode: "tab" | "manual"
  renderer = "tab",

  -- Where marker files live (one file per pane ID)
  dir = os.getenv("HOME") .. "/.local/state/wezterm-attention",

  -- Custom base title (tab mode only; plugin adds indicators + colors around it)
  title_formatter = nil,  -- function(tab, ctx) -> string

  -- Tab background tints per attention type
  colors = {
    thinking = "#1c1730",  -- violet tint
    stop     = "#12271c",  -- mint tint
    notify   = "#240f16",  -- rose tint
    review   = "#1a1a0c",  -- gold tint
  },

  -- Tab text indicators
  indicators = {
    thinking_frames = { "◌ ", "◔ ", "◑ ", "◕ " },
    stop   = "✓ ",
    notify = "! ",
    review = "◆ ",
  },

  -- Priority order (last = highest)
  priority = { "thinking", "review", "stop", "notify" },

  -- Auto-clear these types when switching to the tab
  auto_clear = { "stop", "notify" },

  -- Review toggle keybind (false to disable)
  review_key = { key = "b", mods = "ALT" },

  -- User var name watched for SSH/remote attention updates (false to disable)
  user_var = "wezterm_attention",

  -- Seconds without a refresh before a "thinking" marker is considered
  -- abandoned and dropped (false to disable)
  thinking_ttl = 600,

  -- Drive tab bar repaints while attention state exists (false to disable;
  -- see "How it works" — without this, spinner frames and indicator
  -- clearing are invisible until something else repaints the tab bar)
  drive_repaint = true,

})
```

## The protocol

Any **local** process running inside WezTerm can write a marker (for SSH/remote processes, use [user vars](#ssh--remote-sessions-user-vars) instead). The contract is:

1. **Write** a JSON file to `~/.local/state/wezterm-attention/<WEZTERM_PANE>`
2. **Contents:** `{"type":"<state>"}` where state is `thinking`, `stop`, `notify`, or `review`
3. **Optional heartbeat:** `{"type":"thinking","frame":0}` — rewrite the marker with a changing `frame` (or any changing field) to keep a `thinking` marker alive past `thinking_ttl`. The spinner animation itself is time-driven by the plugin; `frame` no longer controls it.
4. **Cleanup** is automatic — markers whose pane no longer exists are reaped on the first poll and periodically after that (~30 poll ticks; wezterm has no pane-destroyed event), `auto_clear` types clear when their tab is viewed in a focused window, and `thinking` expires when it stops being refreshed (`thinking_ttl`).

The `WEZTERM_PANE` environment variable is injected by WezTerm into every shell it spawns. That's the pane's unique ID.

The state is last-write-wins: writers just declare the pane's current state. The plugin owns everything else — animation, expiry, cleanup. If a marker's content is ever caught mid-write, the plugin keeps the previous state instead of flickering it off.

**Atomic writes recommended:** write to a tmp file with a **unique name** (include your PID — a fixed `.tmp` name lets concurrent writers trample each other), then rename:

### Shell (one-liner)

```bash
MARKER_DIR="$HOME/.local/state/wezterm-attention"
mkdir -p "$MARKER_DIR"
echo '{"type":"stop"}' > "$MARKER_DIR/$WEZTERM_PANE.$$.tmp" && mv "$MARKER_DIR/$WEZTERM_PANE.$$.tmp" "$MARKER_DIR/$WEZTERM_PANE"
```

### TypeScript / Bun

```typescript
import { mkdir, writeFile, rename } from "node:fs/promises";
import { join } from "node:path";

const dir = join(process.env.HOME!, ".local", "state", "wezterm-attention");
await mkdir(dir, { recursive: true });

const file = join(dir, process.env.WEZTERM_PANE!);
const tmp = `${file}.${process.pid}.tmp`;
await writeFile(tmp, JSON.stringify({ type: "stop" }));
await rename(tmp, file);
```

### Node.js

```javascript
const fs = require("fs");
const path = require("path");

const dir = path.join(process.env.HOME, ".local", "state", "wezterm-attention");
fs.mkdirSync(dir, { recursive: true });

const file = path.join(dir, process.env.WEZTERM_PANE);
const tmp = `${file}.${process.pid}.tmp`;
fs.writeFileSync(tmp, JSON.stringify({ type: "stop" }));
fs.renameSync(tmp, file);
```

## SSH / remote sessions (user vars)

Marker files only work for processes running on the same machine as WezTerm. A hook running on an SSH host (or inside WSL) can't write to your local marker directory — instead, it should emit a [WezTerm user var](https://wezterm.org/recipes/passing-data.html) (iTerm2-style OSC 1337 `SetUserVar` escape). The plugin listens for `user-var-changed`, resolves the local pane ID itself, and writes the marker file locally. The escape sequence travels through SSH like any terminal output, so the remote side never needs to know your local paths.

The watched variable name defaults to `wezterm_attention`; set `user_var = false` to disable the bridge, or pass a different name.

Accepted values (base64-encoded inside the escape; WezTerm decodes before the plugin sees them):

- Plain strings: `thinking`, `stop`, `notify`, `review`, `clear`
- JSON: `{"type":"thinking","frame":2}` or `{"type":"clear"}`

`clear` removes the pane's marker. Anything else is ignored (with a `wezterm.log_warn`). Every received event counts as a refresh for `thinking_ttl`, even with identical values — so a remote agent just re-sends `thinking` periodically to stay alive.

### Shell helper

Put this in your remote `.bashrc`/`.zshrc` (or hook scripts). It handles base64 encoding and tmux passthrough wrapping:

```bash
wezterm_attention() {
  local value="${1:-stop}"
  if command -v base64 >/dev/null 2>&1; then
    if [ -n "${TMUX:-}" ]; then
      printf '\033Ptmux;\033\033]1337;SetUserVar=wezterm_attention=%s\007\033\\' \
        "$(printf '%s' "$value" | base64 | tr -d '\n')" 2>/dev/null > /dev/tty || true
    else
      printf '\033]1337;SetUserVar=wezterm_attention=%s\007' \
        "$(printf '%s' "$value" | base64 | tr -d '\n')" 2>/dev/null > /dev/tty || true
    fi
  fi
}
```

If you run tmux inside the SSH session, tmux must be allowed to pass the escape through — add to your tmux config:

```
set -g allow-passthrough on
```

### Remote hook examples

Use the helper from your agent hooks instead of writing marker files:

| Hook event | Command |
|------------|---------|
| `Stop` | `wezterm_attention stop` |
| `Notification` / `PermissionRequest` | `wezterm_attention notify` |
| `PreToolUse` / `PostToolUse` | `wezterm_attention thinking` — every event refreshes `thinking_ttl`, so firing it per tool call keeps the indicator alive |
| `SessionEnd` | `wezterm_attention clear` |

### Complete Claude Code bridge (with interrupt fallbacks)

There is a lifecycle gap to be aware of: **Claude Code fires no hook at all when you interrupt a turn with Esc or a single Ctrl-C** — `Stop` only runs on normal completion. Without a fallback, an interrupted agent leaves the tab claiming `thinking` until `thinking_ttl` expires.

[`examples/claude-code-hook.sh`](examples/claude-code-hook.sh) is a complete, drop-in bridge that closes the gap with three layers:

1. **Idle notification** — ~60s after an interrupt, Claude Code sends a "waiting for your input" notification. The script remembers the last value it sent per session: if that was `thinking`, this is an interrupt leftover → send `clear`. A finished `stop` checkmark is left alone.
2. **SessionEnd** — `/exit` or quitting the process clears a leftover `thinking` instantly (same state check, so a fresh ✓ survives).
3. **The plugin's `thinking_ttl`** — last resort for `kill -9`, dropped SSH connections, and anything else that runs no code. With per-tool heartbeats you can lower it: `thinking_ttl = 120`.

Save the script as `~/.claude/hooks/wezterm-attention.sh` and register it in `~/.claude/settings.json`:

```json
{
  "hooks": {
    "UserPromptSubmit": [
      { "hooks": [{ "type": "command", "command": "sh ~/.claude/hooks/wezterm-attention.sh prompt-submit" }] }
    ],
    "PostToolUse": [
      { "matcher": "*", "hooks": [{ "type": "command", "command": "sh ~/.claude/hooks/wezterm-attention.sh post-tool" }] }
    ],
    "Stop": [
      { "hooks": [{ "type": "command", "command": "sh ~/.claude/hooks/wezterm-attention.sh stop" }] }
    ],
    "Notification": [
      { "hooks": [{ "type": "command", "command": "sh ~/.claude/hooks/wezterm-attention.sh notification" }] }
    ],
    "SessionEnd": [
      { "hooks": [{ "type": "command", "command": "sh ~/.claude/hooks/wezterm-attention.sh session-end" }] }
    ]
  }
}
```

The `PostToolUse` heartbeat does double duty: it keeps `thinking_ttl` refreshed during long runs, and every user var event makes WezTerm repaint the tab bar, so the spinner animates smoothly while tools are running.

### Quick test

From any SSH session inside WezTerm:

```bash
printf '\033]1337;SetUserVar=wezterm_attention=%s\007' "$(printf stop | base64 | tr -d '\n')" > /dev/tty
```

Switch to another tab — the source tab should show the mint ✓ indicator.

## Existing update-status handler?

By default, the plugin registers its own `update-status` handler to poll marker files. If you already have one (e.g., for a git status bar), use manual polling instead:

```lua
attention.apply_to_config(config, { auto_poll = false })

-- Then in your existing update-status handler:
wezterm.on('update-status', function(window, pane)
  attention.poll(window)  -- reads markers, updates cache
  -- ... your git status bar, battery, etc.
end)
```

## Public API

The plugin exposes functions for use in your own WezTerm Lua code:

```lua
local attention = wezterm.plugin.require("https://github.com/moesin-lab/wezterm-attention")

-- Read cached attention state: returns (type, frame) or nil
local state, frame = attention.get_attention(pane:pane_id())

-- Clear a marker programmatically
attention.remove_marker(pane:pane_id())

-- Poll markers manually (for auto_poll = false)
attention.poll(window)

-- Wrap a title function with attention decoration (for renderer = "manual")
wezterm.on("format-tab-title", attention.wrap_title_formatter(function(tab, ctx)
  -- ctx.default_title is "dir / title"
  -- ctx.attention is { indicator, type, color }
  return ctx.default_title
end))
```

## Claude Code hooks

Claude Code has [hooks](https://docs.anthropic.com/en/docs/claude-code/hooks) that fire on lifecycle events. Add attention markers to each one:

| Hook event | Marker | What happens | Required? |
|------------|--------|--------------|-----------|
| `Stop` | `stop` | Tab turns mint with ✓ when agent finishes | **Yes** — core value |
| `PreToolUse` | `thinking` | Spinner animates while agent works | Recommended |
| `Notification` | `notify` | Tab turns rose with ! for notifications | Optional |
| `PermissionRequest` | `notify` | Tab turns rose when agent needs approval | Optional |
| `SessionEnd` | _(cleanup)_ | Marker file removed | Recommended |

**Minimum viable setup:** Just the `Stop` hook gives you the "agent finished" indicator. Add the rest as desired.

The snippets below are **fragments to paste into your hook files** — not standalone scripts. Each one guards on `WEZTERM_PANE` so it's safe to use outside WezTerm. If you don't have existing hooks, wrap the snippet in a Claude Code hook handler (see [hook docs](https://docs.anthropic.com/en/docs/claude-code/hooks)).

Register hooks in `~/.claude/settings.json`:
```json
{
  "hooks": {
    "Stop": [
      { "hooks": [{ "type": "command", "command": "/bin/bash ~/.claude/hooks/stop.sh" }] }
    ],
    "PreToolUse": [
      { "matcher": "*", "hooks": [{ "type": "command", "command": "/bin/bash ~/.claude/hooks/pre_tool_use.sh" }] }
    ],
    "SessionEnd": [
      { "hooks": [{ "type": "command", "command": "/bin/bash ~/.claude/hooks/session_end.sh" }] }
    ]
  }
}
```

> **Lifecycle gap:** Claude Code fires **no hook** when you interrupt a turn with Esc/Ctrl-C — `Stop` only runs on normal completion, so an interrupted agent leaves `thinking` lit until `thinking_ttl` expires. See [the complete bridge with interrupt fallbacks](#complete-claude-code-bridge-with-interrupt-fallbacks) for how to close the gap using the idle notification and `SessionEnd`; the same state-file trick works with marker files too.

**PreToolUse** — thinking indicator:
```typescript
if (process.env.WEZTERM_PANE) {
  const { mkdirSync, writeFileSync, renameSync } = require('fs');
  const markerDir = `${process.env.HOME}/.local/state/wezterm-attention`;
  const markerFile = `${markerDir}/${process.env.WEZTERM_PANE}`;
  mkdirSync(markerDir, { recursive: true });
  // frame is just a heartbeat nonce — each change refreshes thinking_ttl.
  // The spinner animation itself is time-driven by the plugin.
  const tmp = `${markerFile}.${process.pid}.tmp`;
  writeFileSync(tmp, JSON.stringify({ type: 'thinking', frame: Date.now() % 1000 }));
  renameSync(tmp, markerFile);
}
```

**Stop** — agent finished:
```typescript
if (process.env.WEZTERM_PANE) {
  const { mkdirSync, writeFileSync, renameSync } = require('fs');
  const markerDir = `${process.env.HOME}/.local/state/wezterm-attention`;
  const markerFile = `${markerDir}/${process.env.WEZTERM_PANE}`;
  mkdirSync(markerDir, { recursive: true });
  const tmp = `${markerFile}.${process.pid}.tmp`;
  writeFileSync(tmp, JSON.stringify({ type: 'stop' }));
  renameSync(tmp, markerFile);
}
```

**Notification / PermissionRequest** — needs attention:
```typescript
if (process.env.WEZTERM_PANE) {
  const { mkdirSync, writeFileSync, renameSync } = require('fs');
  const markerDir = `${process.env.HOME}/.local/state/wezterm-attention`;
  const markerFile = `${markerDir}/${process.env.WEZTERM_PANE}`;
  mkdirSync(markerDir, { recursive: true });
  const tmp = `${markerFile}.${process.pid}.tmp`;
  writeFileSync(tmp, JSON.stringify({ type: 'notify' }));
  renameSync(tmp, markerFile);
}
```

**SessionEnd** — cleanup:
```typescript
if (process.env.WEZTERM_PANE) {
  const { unlinkSync } = require('fs');
  try {
    unlinkSync(`${process.env.HOME}/.local/state/wezterm-attention/${process.env.WEZTERM_PANE}`);
  } catch {}
}
```

> **Latency note:** Marker files are picked up on the next poll tick (`status_update_interval`, default 1000ms) — forcing a redraw doesn't help, because the renderer only reads the in-memory cache that the poller fills. If you need event-level immediacy, use the [user var bridge](#ssh--remote-sessions-user-vars): it updates the cache the moment the event arrives.

## Codex hooks

Codex uses a single `notify` hook that fires when the agent finishes or needs attention. Add this to your Codex notify handler:

```typescript
async function writeWezTermMarker(type: "stop" | "notify"): Promise<void> {
  const paneId = process.env.WEZTERM_PANE;
  const home = process.env.HOME;
  if (!paneId || !home) return;

  const { mkdir, writeFile, rename } = require("node:fs/promises");
  const { join } = require("node:path");

  const markerDir = join(home, ".local", "state", "wezterm-attention");
  await mkdir(markerDir, { recursive: true });

  const file = join(markerDir, paneId);
  const tmp = `${file}.${process.pid}.tmp`;
  await writeFile(tmp, JSON.stringify({ type }));
  await rename(tmp, file);
}

// In your notify handler:
// - "stop" if the agent completed work (has last-assistant-message)
// - "notify" for other notifications
const attentionType = payload["last-assistant-message"] ? "stop" : "notify";
await writeWezTermMarker(attentionType);
```

Wire it in `~/.codex/config.toml`:
```toml
[hooks]
notify = ["bun", "/path/to/your/notify.ts"]
```

## Other use cases

- **Build systems** — write `notify` on failure, `stop` on success
- **Test runners** — animated `thinking` while running, `stop` or `notify` on completion
- **Long-running scripts** — any background job that wants your attention when done
- **Manual triage** — `Alt+B` to flag tabs for review during code review sessions

## How it works

The plugin uses a **poller/renderer split** to avoid blocking WezTerm's GUI thread:

1. **Poller** (`update-status` event) — runs on WezTerm's `config.status_update_interval` (default 1000ms). Reads marker files from disk and updates an in-memory cache. This is the single place state transitions happen: picking up new markers, auto-clearing markers the user has actually seen (active tab **and** focused window), expiring stale `thinking` markers, tolerating partial writes (keeps the previous state for one tick, then drops corrupt files), and periodically reaping markers for panes that no longer exist.
2. **Renderer** (`format-tab-title` event) — fires on every tab repaint (mouse hover, key press, redraws). Pure: reads only from the cache, mutates nothing — zero I/O, instant returns. The thinking spinner advances on wall-clock time, one frame per second.

WezTerm only recomputes tab titles when something it can observe changes — right-status content, user vars, mouse movement, tab switches. Cache-internal transitions (spinner frames, TTL expiry, auto-clear) are invisible to it, so the poller also **drives repaints**: while any attention state exists (plus one tick after it clears), it alternates a zero-width character through `window:set_right_status()`, which forces the tab bar to recompute. Visually a no-op; set `drive_repaint = false` if you manage `set_right_status` yourself and its content already changes every tick (e.g. a clock with seconds). Spinner frame rate and state-transition latency are both bounded by `config.status_update_interval` (default 1000ms).

Marker writes are atomic (unique tmp name + rename) and portable — on Windows, where `rename()` can't replace an existing file, the plugin falls back to remove-then-rename. Startup cleanup is **live-aware**: the first poll reaps markers (and orphaned tmp files) whose pane doesn't exist, but never touches markers for live panes — so reconnecting to a long-lived mux server (`wezterm connect`) keeps valid state, and a user var arriving before the first poll isn't lost. The trade-off: after a fresh start, a leftover marker whose pane ID gets reused by the new session survives until auto-clear or TTL handles it (`stop`/`notify` clear on view, `thinking` expires, `review` can be toggled off with Alt+B).

No background threads, no FFI, no external dependencies — just filesystem reads in Lua on a configurable interval.

## Troubleshooting

**Markers not showing?**
- Check the directory exists: `ls ~/.local/state/wezterm-attention/` (or your configured `dir`)
- Verify `WEZTERM_PANE` is set: `echo $WEZTERM_PANE` (should print a number inside WezTerm)
- Check file contents: `cat ~/.local/state/wezterm-attention/$WEZTERM_PANE` (should be valid JSON)
- Ensure your hooks write to the same path as the plugin's `dir` setting
- `status_update_interval` defaults to 1000ms; markers update on this interval
- Over SSH? Marker files won't work remotely — send a [user var](#ssh--remote-sessions-user-vars) instead. Inside tmux, make sure `allow-passthrough` is on.

**Tab titles look wrong?**
- WezTerm only runs the **first** registered `format-tab-title` handler. If you have your own handler, set `renderer = "manual"` and use `wrap_title_formatter()` or the plugin API. Two handlers cannot coexist.
- Use `title_formatter` to customize the base title while keeping the plugin's indicators.

**Spinner frozen, or indicators never clear (stuck `thinking` after killing an agent)?**
- The state machine is fine — the tab bar just isn't repainting. Make sure you're on a plugin version with `drive_repaint` and that you haven't set it to `false` (only disable it if your own `update-status` handler writes changing content to `set_right_status` every tick).
- A large `config.status_update_interval` slows everything down: spinner frames, TTL expiry and auto-clear all happen on the poll tick. Keep it at the default 1000ms.
- A dead agent's `thinking` clears after `thinking_ttl` (default 600s). If your hooks send heartbeats more often (e.g. every 30s), you can lower it: `thinking_ttl = 120`.

**Thinking indicator disappeared while the agent is still working?**
- `thinking` markers expire after `thinking_ttl` (default 600s) without a refresh. Make sure your hook fires repeatedly (e.g. on every `PreToolUse`) with changing content, or raise/disable the TTL.

**Alt+B not working?**
- Check for keybind conflicts. Set `review_key = false` and bind manually if needed.

## Type annotations

LuaCATS type annotations are available via [wezterm-types](https://github.com/DrKJeff16/wezterm-types) for IDE autocomplete and type checking. See [DrKJeff16/wezterm-types#145](https://github.com/DrKJeff16/wezterm-types/pull/145).

## License

MIT
