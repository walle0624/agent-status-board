#!/usr/bin/env bash
# uninstall.sh — remove AgentStatusBoard hooks from Claude Code and Codex.
# Restores Codex notify to the original Computer Use client and strips the
# cc-hook.sh entries from Claude Code settings. Leaves backups untouched.
set -euo pipefail

BIN_DIR="$HOME/.agent-status-board/bin"

# 1) Claude Code: drop any hook entry pointing at our cc-hook.sh
CC_SETTINGS="$HOME/.claude/settings.json"
if [ -f "$CC_SETTINGS" ]; then
  cp "$CC_SETTINGS" "$CC_SETTINGS.bak.$(date +%Y%m%d%H%M%S)"
  python3 - "$CC_SETTINGS" "$BIN_DIR/cc-hook.sh" <<'PY'
import json, sys
path, hook = sys.argv[1], sys.argv[2]
data = json.load(open(path))
hooks = data.get("hooks", {})
for event in list(hooks.keys()):
    groups = []
    for grp in hooks[event]:
        kept = [h for h in grp.get("hooks", []) if not h.get("command","").startswith(hook)]
        if kept:
            grp["hooks"] = kept
            groups.append(grp)
    if groups:
        hooks[event] = groups
    else:
        del hooks[event]
if not hooks:
    data.pop("hooks", None)
json.dump(data, open(path,"w"), indent=2)
print("removed Claude Code hooks ->", path)
PY
fi

# 2) Codex: restore the original notify program
CODEX_CFG="$HOME/.codex/config.toml"
ORIG='notify = ["/Users/walle/.codex/computer-use/Codex Computer Use.app/Contents/SharedSupport/SkyComputerUseClient.app/Contents/MacOS/SkyComputerUseClient", "turn-ended"]'
if [ -f "$CODEX_CFG" ]; then
  cp "$CODEX_CFG" "$CODEX_CFG.bak.$(date +%Y%m%d%H%M%S)"
  python3 - "$CODEX_CFG" "$ORIG" <<'PY'
import re, sys
path, orig = sys.argv[1], sys.argv[2]
txt = open(path).read()
txt = re.sub(r'(?m)^\s*notify\s*=.*$', orig, txt, count=1)
open(path,"w").write(txt)
print("restored Codex notify ->", path)
PY
fi

echo "done. Restart Codex / start new Claude Code sessions for removal to take effect."
echo "(state dir ~/.agent-status-board left in place; rm -rf it to fully clean up.)"
