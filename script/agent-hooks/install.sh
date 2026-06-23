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
for s in record.sh cc-hook.sh codex-hook.sh codex-notify.sh classify.py configure-llm.sh; do
  cp "$SRC_DIR/$s" "$BIN_DIR/$s"
  chmod +x "$BIN_DIR/$s"
done
echo "installed scripts -> $BIN_DIR"

# The "needs input" classifier (classify.py) is portable: it talks to any
# OpenAI-compatible endpoint (Aliyun DashScope compatible-mode, OpenAI, DeepSeek,
# Ollama, ...) configured in ~/.agent-status-board/classify.json, or falls back
# to a local `bl` CLI when one is installed. Step 4 runs a guided setup; if you
# skip it the classifier just stays off until you run configure-llm.sh.

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

# 3) wire Codex official hooks (~/.codex/config.toml) — the real-time signal.
CODEX_CFG="$HOME/.codex/config.toml"
CODEX_HOOK="$BIN_DIR/codex-hook.sh"
if [ -f "$CODEX_CFG" ]; then
  cp "$CODEX_CFG" "$CODEX_CFG.bak.$(date +%Y%m%d%H%M%S)"
  python3 - "$CODEX_CFG" "$CODEX_HOOK" <<'PY'
import re, sys
path, hook = sys.argv[1], sys.argv[2]
txt = open(path).read()
MARK = "# >>> agent-status-board hooks >>>"
END  = "# <<< agent-status-board hooks <<<"
# Drop any previous block so re-running updates cleanly.
txt = re.sub(re.escape(MARK)+r".*?"+re.escape(END)+r"\n?", "", txt, flags=re.S)
events = ["UserPromptSubmit","PreToolUse","PostToolUse",
          "PreCompact","PostCompact","PermissionRequest","Stop"]
block = [MARK]
for e in events:
    block.append(f"[[hooks.{e}]]")
    block.append(f"[[hooks.{e}.hooks]]")
    block.append('type = "command"')
    block.append(f"command = '{hook} {e}'")
    block.append("timeout = 10")
    block.append("")
block.append(END)
txt = txt.rstrip() + "\n\n" + "\n".join(block) + "\n"

# Wire notify too (only if none exists) so turn-end works even before hooks are trusted.
if not re.search(r'(?m)^\s*notify\s*=', txt):
    m = re.search(r'(?m)^\[', txt)
    line = 'notify = ["%s/codex-notify.sh"]\n' % __import__("os").path.dirname(hook)
    txt = (txt[:m.start()] + line + "\n" + txt[m.start():]) if m else (txt + line)

open(path, "w").write(txt)
print("wired Codex hooks ->", path)
PY
else
  echo "skip: $CODEX_CFG not found"
fi

# 4) guided setup for the optional "needs input" AI classifier
if [ -t 0 ]; then
  bash "$BIN_DIR/configure-llm.sh" || true
else
  echo "• AI 分类器未配置（非交互安装）。需要时运行： $BIN_DIR/configure-llm.sh"
fi

echo "done."
echo "  • Claude Code: start a new session to begin emitting events."
echo "  • Codex: restart it, then run /hooks inside Codex once to TRUST the hooks."
echo "  • AI 分类器：重跑 $BIN_DIR/configure-llm.sh 可改 provider / key / model。"
