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
for s in record.sh cc-hook.sh codex-hook.sh codex-notify.sh classify.py configure-llm.sh cc-token-setup.sh; do
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

# 5) record the source repo so the app can offer in-app self-update
#    (only works when installed from a git clone of your GitHub remote).
REPO_ROOT="$(cd "$SRC_DIR/../.." && pwd)"
REMOTE_URL="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || true)"
if [ -n "$REMOTE_URL" ]; then
  REPO_ROOT="$REPO_ROOT" REMOTE_URL="$REMOTE_URL" \
  BRANCH_NAME="$(git -C "$REPO_ROOT" branch --show-current 2>/dev/null || echo main)" \
  python3 - "$HOME/.agent-status-board/update.json" <<'PY'
import json, os, re, sys
remote = os.environ["REMOTE_URL"]
data = {"checkout": os.environ["REPO_ROOT"], "branch": os.environ.get("BRANCH_NAME", "main"), "remote": remote}
m = re.search(r'github\.com[:/]+([^/]+)/([^/.]+)', remote)
if m:
    data["owner"], data["repo"] = m.group(1), m.group(2)
open(sys.argv[1], "w").write(json.dumps(data, indent=2))
print("recorded source repo for self-update:", data.get("owner"), "/", data.get("repo"))
PY
else
  echo "（非 git 克隆，跳过自更新配置；想用 App 内更新，请先从 GitHub git clone 再跑本脚本）"
fi

echo "done."
echo "  • Claude Code: start a new session to begin emitting events."
echo "  • Codex: 在「设置 → 编码 → 钩子 → 用户配置（7 个钩子）」里信任/启用这些 hooks"
echo "          （Codex 没有 /hooks 命令；不信任则状态不更新）。"
echo "  • AI 分类器：重跑 $BIN_DIR/configure-llm.sh 可改 provider / key / model。"
echo "  • CC 用量面板：跑 $BIN_DIR/cc-token-setup.sh 生成长期 token（Codex 用量开箱即用）。"
