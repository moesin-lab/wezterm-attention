#!/bin/sh
# Claude Code → wezterm-attention bridge (user var transport, works over SSH).
#
# Install:
#   1. Save as ~/.claude/hooks/wezterm-attention.sh on the machine running
#      Claude Code (local, SSH host, WSL — anywhere inside a WezTerm pane).
#   2. Register the five hooks in ~/.claude/settings.json (see README).
#
# Why five events? Claude Code fires NO hook when you interrupt a turn with
# Esc/Ctrl-C, so "thinking" would otherwise stay lit. Three fallbacks cover it:
#   - Notification "waiting for input" (~60s after an interrupt) clears a
#     leftover thinking indicator — but keeps a finished stop checkmark
#   - SessionEnd (/exit, quitting the process) does the same, instantly
#   - the plugin's thinking_ttl is the last resort (SIGKILL, lost SSH, ...)
#
# State: the last value sent is remembered per session, so the fallbacks can
# tell "interrupted mid-work" (thinking → clear it) from "finished, waiting
# for you to look" (stop → keep it).

mode="$1"
input="$(cat)"

sid="$(printf '%s' "$input" | jq -j '.session_id // "unknown"' | tr -c 'A-Za-z0-9_.-' '_')"
attn_file="/tmp/wezterm-attention-claude-$sid.attn"

# Send a user var (thinking|stop|notify|review|clear) and remember it.
send_attn() {
	if command -v base64 >/dev/null 2>&1; then
		b64="$(printf '%s' "$1" | base64 | tr -d '\n')"
		if [ -n "${TMUX:-}" ]; then
			printf '\033Ptmux;\033\033]1337;SetUserVar=wezterm_attention=%s\007\033\\' "$b64" 2>/dev/null > /dev/tty || true
		else
			printf '\033]1337;SetUserVar=wezterm_attention=%s\007' "$b64" 2>/dev/null > /dev/tty || true
		fi
	fi
	printf '%s' "$1" > "$attn_file"
}

last_attn() {
	cat "$attn_file" 2>/dev/null
}

case "$mode" in
	prompt-submit)
		send_attn thinking
		;;

	post-tool)
		# Activity heartbeat: a finished tool call means work is ongoing.
		# Refreshes the plugin's thinking_ttl, and every user var event
		# also drives a WezTerm repaint (smoother spinner).
		send_attn thinking
		;;

	stop)
		send_attn stop
		;;

	notification)
		message="$(printf '%s' "$input" | jq -r '.message // ""')"
		if [ "$message" = "Claude is waiting for your input" ]; then
			# Idle notification — the only signal that follows an
			# Esc/Ctrl-C interrupt. Clear leftover thinking only.
			[ "$(last_attn)" = "thinking" ] && send_attn clear
		else
			send_attn notify
		fi
		;;

	session-end)
		# /exit or quitting the process. Clear leftover thinking;
		# keep a finished stop checkmark visible.
		[ "$(last_attn)" = "thinking" ] && send_attn clear
		rm -f "$attn_file"
		;;

	*)
		exit 2
		;;
esac

exit 0
