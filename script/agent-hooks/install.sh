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

# 1) install scripts to a stable location — only when content changed, so
#    re-running install doesn't needlessly churn files.
_changed=0
for s in record.sh cc-hook.sh codex-hook.sh codex-notify.sh classify.py configure-llm.sh cc-token-setup.sh; do
  if ! cmp -s "$SRC_DIR/$s" "$BIN_DIR/$s" 2>/dev/null; then
    cp "$SRC_DIR/$s" "$BIN_DIR/$s"; chmod +x "$BIN_DIR/$s"; _changed=$((_changed+1))
  fi
done
echo "installed scripts -> $BIN_DIR（更新 $_changed 个）"

# The "needs input" classifier (classify.py) is portable: it talks to any
# OpenAI-compatible endpoint (Aliyun DashScope compatible-mode, OpenAI, DeepSeek,
# Ollama, ...) configured in ~/.agent-status-board/classify.json, or falls back
# to a local `bl` CLI when one is installed. Step 4 runs a guided setup; if you
# skip it the classifier just stays off until you run configure-llm.sh.

# 2) wire Claude Code hooks (~/.claude/settings.json) — write (and back up)
#    only when the result actually changes, so re-running stays quiet.
CC_SETTINGS="$HOME/.claude/settings.json"
CC_HOOK="$BIN_DIR/cc-hook.sh"
python3 - "$CC_SETTINGS" "$CC_HOOK" <<'PY'
import json, os, sys, time, shutil
path, hook = sys.argv[1], sys.argv[2]
before = open(path).read() if os.path.exists(path) else ""
try: orig = json.loads(before) if before else {}
except Exception: orig = {}
data = json.loads(json.dumps(orig))      # deep copy to mutate
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
if data != orig:
    if before: shutil.copy(path, path + ".bak." + time.strftime("%Y%m%d%H%M%S"))
    open(path, "w").write(json.dumps(data, indent=2))
    print("wired Claude Code hooks ->", path)
else:
    print("Claude Code hooks 已就绪，未改动")
PY

# 3) wire Codex official hooks (~/.codex/config.toml) — the real-time signal.
#    IDEMPOTENT & TRUST-PRESERVING. Codex records hook trust as a `trusted_hash`
#    per hook in a [hooks.state] table written INSIDE config.toml — and it lands
#    inside our marker block. The old code deleted that block on every run, so it
#    wiped Codex's trust and forced you to re-approve all 7 hooks each time.
#    Now: if the hooks are already wired we change NOTHING; and when we must
#    rewire, we rescue [hooks.state] and re-attach it OUTSIDE the block.
CODEX_CFG="$HOME/.codex/config.toml"
CODEX_HOOK="$BIN_DIR/codex-hook.sh"
if [ -f "$CODEX_CFG" ]; then
  python3 - "$CODEX_CFG" "$CODEX_HOOK" <<'PY'
import re, sys, os, time, shutil
path, hook = sys.argv[1], sys.argv[2]
txt = open(path).read()
events = ["UserPromptSubmit","PreToolUse","PostToolUse",
          "PreCompact","PostCompact","PermissionRequest","Stop"]
desired = [f"command = '{hook} {e}'" for e in events]

# Already wired → DO NOTHING. This is the fix: no rewrite means Codex's
# [hooks.state] trust hashes survive, so you never re-approve on an update.
if all(d in txt for d in desired):
    print("Codex hooks 已就绪，未改动（保留信任，无需重新审核）")
    sys.exit(0)

MARK = "# >>> agent-status-board hooks >>>"
END  = "# <<< agent-status-board hooks <<<"

# Rescue Codex's [hooks.state] trust table before touching anything (it runs
# from its header up to our END marker, or to EOF).
state = ""
sm = re.search(r'(?ms)^[ \t]*\[hooks\.state\b', txt)
if sm:
    state = txt[sm.start():].split(END, 1)[0].rstrip() + "\n"

# Remove our old fenced block (which may contain the state we just rescued)...
txt = re.sub(re.escape(MARK) + r".*?" + re.escape(END) + r"\n?", "", txt, flags=re.S)
# ...and any [hooks.state] left elsewhere (we re-add exactly one copy).
txt = re.sub(r'(?ms)^[ \t]*\[hooks\.state\b.*?(?=^\[(?!hooks\.state)|\Z)', "", txt)

block = [MARK]
for e in events:
    block += [f"[[hooks.{e}]]", f"[[hooks.{e}.hooks]]", 'type = "command"',
              f"command = '{hook} {e}'", "timeout = 10", ""]
block.append(END)
txt = txt.rstrip() + "\n\n" + "\n".join(block) + "\n"
if state:                       # re-attach AFTER the fence so it's never swallowed again
    txt = txt.rstrip() + "\n\n" + state

# Wire notify too (only if none exists) so turn-end works even before hooks are trusted.
if not re.search(r'(?m)^\s*notify\s*=', txt):
    m = re.search(r'(?m)^\[', txt)
    line = 'notify = ["%s/codex-notify.sh"]\n' % os.path.dirname(hook)
    txt = (txt[:m.start()] + line + "\n" + txt[m.start():]) if m else (txt + line)

shutil.copy(path, path + ".bak." + time.strftime("%Y%m%d%H%M%S"))   # back up only when actually changing
open(path, "w").write(txt)
print("wired Codex hooks ->", path, "（已保留 [hooks.state] 信任表）")
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

# 5) enable in-app self-update from update-source.json (ships inside the zip).
#    The app downloads new source from GitHub over HTTP — no git on this machine.
REPO_ROOT="$(cd "$SRC_DIR/../.." && pwd)"
SRC_JSON="$REPO_ROOT/update-source.json"
if [ -f "$SRC_JSON" ]; then
  REPO_ROOT="$REPO_ROOT" python3 - "$SRC_JSON" "$HOME/.agent-status-board/update.json" <<'PY'
import json, os, sys
src = json.load(open(sys.argv[1]))
owner = (src.get("owner") or "").strip()
if owner and not owner.startswith("<"):
    out = {"owner": owner, "repo": (src.get("repo") or "").strip(),
           "branch": (src.get("branch") or "main").strip(), "checkout": os.environ["REPO_ROOT"]}
    open(sys.argv[2], "w").write(json.dumps(out, indent=2))
    print("自更新已启用 ->", owner + "/" + out["repo"])
else:
    print("update-source.json 未填 owner/repo —— App 内更新暂不启用（填好后重跑本脚本）")
PY
fi

echo "done."
echo "  • Claude Code: start a new session to begin emitting events."
echo "  • Codex: 在「设置 → 编码 → 钩子 → 用户配置（7 个钩子）」里信任/启用这些 hooks"
echo "          （Codex 没有 /hooks 命令；不信任则状态不更新）。"
echo "  • AI 分类器：重跑 $BIN_DIR/configure-llm.sh 可改 provider / key / model。"
echo "  • CC 用量面板：跑 $BIN_DIR/cc-token-setup.sh 生成长期 token（Codex 用量开箱即用）。"
