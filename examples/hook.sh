#!/usr/bin/env bash
#
# Shell one-liner to write an attention marker.
# Drop this into any hook or script that runs inside WezTerm.

MARKER_DIR="${HOME}/.local/state/wezterm-attention"
mkdir -p "$MARKER_DIR"

# Write a "stop" marker (tab shows ✓ in mint)
# Atomic: unique tmp name ($$ = PID) + rename. A fixed tmp name would let
# concurrent writers (other hooks, the plugin itself) trample each other.
TMP="${MARKER_DIR}/${WEZTERM_PANE}.$$.tmp"
echo '{"type":"stop"}' > "$TMP"
mv "$TMP" "${MARKER_DIR}/${WEZTERM_PANE}"

# Other types:
#   echo '{"type":"notify"}'              # tab shows ! in rose
#   echo '{"type":"thinking","frame":0}'  # spinner; bump frame on each write
#                                         # to keep the marker alive past
#                                         # thinking_ttl (animation itself is
#                                         # time-driven by the plugin)
#   echo '{"type":"review"}'              # tab shows ◆ in gold
