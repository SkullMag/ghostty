#!/bin/sh
#
# Ghostty coding-agent activity hook.
#
# Registered as a Claude Code hook (see install.sh), this reads the hook
# payload JSON on stdin, maps the lifecycle event to an agent state, and
# emits an `OSC 777;agent;<state>` escape sequence to the terminal running
# the agent. Ghostty parses this and shows an animated indicator on the tab
# in the left sidebar (requires `macos-tab-position = left` and
# `macos-tab-sidebar-agent-status = true`, which is the default).
#
# Claude runs hooks WITHOUT a controlling terminal, so /dev/tty is not
# available. Instead we walk up the process tree to find the agent process
# that still owns the surface's PTY and write the escape sequence there. The
# sequence is invisible to the agent's TUI, and works over SSH too (the bytes
# travel back over the PTY).
#
# Set GHOSTTY_AGENT_HOOK_DEBUG=1 to append diagnostics to
# /tmp/ghostty-agent-hook.log.

input=$(cat 2>/dev/null)

# Extract "hook_event_name" without requiring jq. Tolerates compact or
# multi-line JSON and arbitrary key ordering.
event=$(printf '%s' "$input" \
  | grep -oE '"hook_event_name"[[:space:]]*:[[:space:]]*"[^"]*"' \
  | head -n1 \
  | grep -oE '"[^"]*"$' \
  | tr -d '"')

[ -z "$event" ] && exit 0

case "$event" in
  UserPromptSubmit|PreToolUse|PostToolUse|SubagentStop) state=working ;;
  Notification)                                         state=waiting ;;
  Stop)                                                 state=done ;;
  SessionStart)                                         state=idle ;;
  SessionEnd)                                           state=end ;;
  *)                                                    exit 0 ;;
esac

# Walk up the process tree to find an ancestor with a real controlling
# terminal (the agent itself) and use that PTY device.
target_tty=""
pid=$PPID
i=0
while [ -n "$pid" ] && [ "$pid" -gt 1 ] && [ "$i" -lt 12 ]; do
  t=$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')
  case "$t" in
    ""|\?\?|"-") : ;;
    *)
      if [ -c "/dev/$t" ] && [ -w "/dev/$t" ]; then
        target_tty="/dev/$t"
        break
      fi
      ;;
  esac
  pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
  i=$((i + 1))
done

if [ "${GHOSTTY_AGENT_HOOK_DEBUG:-0}" != "0" ]; then
  echo "$(date '+%H:%M:%S') event=$event state=$state tty=$target_tty ppid=$PPID" \
    >> /tmp/ghostty-agent-hook.log 2>&1
fi

[ -n "$target_tty" ] || exit 0
printf '\033]777;agent;%s\033\\' "$state" > "$target_tty" 2>/dev/null || true
exit 0
