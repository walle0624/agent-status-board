#!/usr/bin/env bash
# install.sh — wire AgentStatusBoard event hooks into Claude Code and Codex.
# Safe & idempotent. Backs up edited config files. Run again to update.
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HOME/.agent-status-board/bin"
mkdir -p "$BIN_DIR" "$HOME/.agent-status-board/sessions"

# Seed an editable display-name map: { "<project path>": "<name to show>" }.
# A session at or under a mapped path shows that name instead of the folder name.
NAMES="$HOME/.agent-status-board/names.json"
[ -f "$NAMES" ] || printf '{\n  "/Users/example/path/to/project": "My Session Name"\n}\n' > "$NAMES"

# 1) install scripts to a stable location
for s in record.sh cc-hook.sh codex-notify.sh; do
  cp "$SRC_DIR/$s" "$BIN_DIR/$s"
  chmod +x "$BIN_DIR/$s"
done
echo "installed scripts -> $BIN_DIR"

# 2) wire Claude Code hooks (~/.claude/settings.json)
CC_SETTINGS="$HOME/.claude/settings.json"
[ -f "$CC_SETTINGS" ] && cp "$CC_SETTINGS" "$CC_SETTINGS.bak.$(date +%Y%m%d%H%M%S)"
CC_HOOK="$BIN_DIR/cc-hook.sh"
python3 - "$CC_SETTINGS" "$CC_HOOK" <<'PY'
import json, os, sys
path, hook = sys.argv[1], sys.argv[2]
data = {}
if os.path.exists(path):
    with open(path) as f:
        try: data = json.load(f)
        except Exception: data = {}
hooks = data.setdefault("hooks", {})
def ensure(event):
    cmd = f"{hook} {event}"
    entries = hooks.setdefault(event, [])
    for grp in entries:
        for h in grp.get("hooks", []):
            if h.get("command","").startswith(hook):
                h["command"] = cmd       # refresh path
                return
    entries.append({"hooks":[{"type":"command","command":cmd}]})
for e in ["UserPromptSubmit","PreToolUse","PostToolUse","PreCompact","PostCompact","Notification","Stop","SessionEnd"]:
    ensure(e)
with open(path,"w") as f:
    json.dump(data, f, indent=2)
print("wired Claude Code hooks ->", path)
PY

# 3) wire Codex notify (~/.codex/config.toml)
CODEX_CFG="$HOME/.codex/config.toml"
WRAP="$BIN_DIR/codex-notify.sh"
if [ -f "$CODEX_CFG" ]; then
  cp "$CODEX_CFG" "$CODEX_CFG.bak.$(date +%Y%m%d%H%M%S)"
  python3 - "$CODEX_CFG" "$WRAP" <<'PY'
import re, sys
path, wrap = sys.argv[1], sys.argv[2]
txt = open(path).read()
new_line = f'notify = ["{wrap}"]'
if re.search(r'(?m)^\s*notify\s*=', txt):
    txt = re.sub(r'(?m)^\s*notify\s*=.*$', new_line, txt, count=1)
else:
    # insert after the first top-level key block (before first [table]) or at top
    m = re.search(r'(?m)^\[', txt)
    if m:
        txt = txt[:m.start()] + new_line + "\n\n" + txt[m.start():]
    else:
        txt = txt.rstrip()+"\n"+new_line+"\n"
open(path,"w").write(txt)
print("wired Codex notify ->", path)
PY
else
  echo "skip: $CODEX_CFG not found"
fi

echo "done. Restart Codex / start new Claude Code sessions to begin emitting events."
