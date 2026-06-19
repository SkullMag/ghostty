#!/bin/sh
#
# Install the Ghostty coding-agent activity hook into Claude Code.
#
# This copies ghostty-agent-hook.sh into your Ghostty config directory and
# merges the necessary hook entries into ~/.claude/settings.json, preserving
# any existing settings and user-defined hooks. Re-running is safe and
# idempotent (it replaces only the entries it previously installed).
#
# Usage:  sh dist/agent-hook/install.sh
#
# After installing, restart any running `claude` sessions for the hooks to
# take effect.

set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/ghostty"
HOOK_DEST="$CONFIG_DIR/claude-agent-hook.sh"
SETTINGS="$HOME/.claude/settings.json"

if ! command -v python3 >/dev/null 2>&1; then
  echo "error: python3 is required to merge ~/.claude/settings.json" >&2
  exit 1
fi

mkdir -p "$CONFIG_DIR" "$HOME/.claude"
cp "$SCRIPT_DIR/ghostty-agent-hook.sh" "$HOOK_DEST"
chmod +x "$HOOK_DEST"

python3 - "$SETTINGS" "$HOOK_DEST" <<'PY'
import json, sys

settings_path, cmd = sys.argv[1], sys.argv[2]

try:
    with open(settings_path) as f:
        data = json.load(f)
except FileNotFoundError:
    data = {}
except json.JSONDecodeError:
    print("error: ~/.claude/settings.json is not valid JSON; aborting", file=sys.stderr)
    sys.exit(1)

if not isinstance(data, dict):
    print("error: ~/.claude/settings.json is not a JSON object; aborting", file=sys.stderr)
    sys.exit(1)

hooks = data.setdefault("hooks", {})

# (event name, matcher-or-None). Tool events use a "*" matcher.
events = [
    ("SessionStart", None),
    ("SessionEnd", None),
    ("UserPromptSubmit", None),
    ("Stop", None),
    ("SubagentStop", None),
    ("Notification", None),
    ("PreToolUse", "*"),
    ("PostToolUse", "*"),
]

def is_ours(defn):
    return any(
        h.get("command", "").endswith("claude-agent-hook.sh") or h.get("command") == cmd
        for h in defn.get("hooks", [])
    )

def make_entry(matcher):
    entry = {"hooks": [{"type": "command", "command": cmd}]}
    if matcher is not None:
        entry["matcher"] = matcher
    return entry

for name, matcher in events:
    lst = hooks.get(name)
    if not isinstance(lst, list):
        lst = []
        hooks[name] = lst
    # Drop any entries we installed previously, then append a fresh one.
    lst[:] = [d for d in lst if not (isinstance(d, dict) and is_ours(d))]
    lst.append(make_entry(matcher))

with open(settings_path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")

print("Installed Ghostty agent hooks into", settings_path)
PY

echo "Hook script: $HOOK_DEST"
echo "Done. Restart any running 'claude' sessions for the hooks to take effect."
