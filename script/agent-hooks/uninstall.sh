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

# 2) Codex: remove our hook block and restore the original notify program, if any.
CODEX_CFG="$HOME/.codex/config.toml"
ORIG_JSON="$HOME/.agent-status-board/codex-notify-original.json"
if [ -f "$CODEX_CFG" ]; then
  cp "$CODEX_CFG" "$CODEX_CFG.bak.$(date +%Y%m%d%H%M%S)"
  python3 - "$CODEX_CFG" "$ORIG_JSON" "$BIN_DIR/codex-notify.sh" <<'PY'
import json, os, re, sys
path, orig_json, wrapper = sys.argv[1], sys.argv[2], sys.argv[3]
txt = open(path).read()

MARK = "# >>> agent-status-board hooks >>>"
END = "# <<< agent-status-board hooks <<<"
txt = re.sub(re.escape(MARK) + r".*?" + re.escape(END) + r"\n?", "", txt, flags=re.S)

def toml_string(value):
    return json.dumps(str(value), ensure_ascii=False)

def notify_line(args):
    return "notify = [" + ", ".join(toml_string(a) for a in args) + "]"

original = None
try:
    data = json.load(open(orig_json))
    if isinstance(data, list) and data:
        original = [str(x) for x in data]
except Exception:
    pass

notify_re = re.compile(r'(?m)^\s*notify\s*=\s*\[[^\n]*\]\s*$')
nm = notify_re.search(txt)
if original:
    line = notify_line(original)
    if nm:
        txt = txt[:nm.start()] + line + txt[nm.end():]
    else:
        m = re.search(r'(?m)^\[', txt)
        txt = (txt[:m.start()] + line + "\n\n" + txt[m.start():]) if m else (txt.rstrip() + "\n" + line + "\n")
elif nm and "codex-notify.sh" in nm.group(0):
    txt = txt[:nm.start()] + txt[nm.end():]

open(path,"w").write(txt)
print("restored Codex notify ->", path)
PY
fi

echo "done. Restart Codex / start new Claude Code sessions for removal to take effect."
echo "(state dir ~/.agent-status-board left in place; rm -rf it to fully clean up.)"
