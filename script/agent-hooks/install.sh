#!/usr/bin/env bash
# install.sh — wire AgentStatusBoard event hooks into Claude Code and Codex.
# Safe & idempotent. Backs up edited config files. Run again to update.
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HOME/.agent-status-board/bin"
mkdir -p "$BIN_DIR" "$HOME/.agent-status-board/sessions"

# Seed an editable display-name map: { "<key>": "<name to show>" }.
# A key that looks like a path matches any session at/under it; any other key
# (e.g. a session UUID) names that one session exactly (and wins over a path).
# Use a session-id key when one folder hosts several differently-named sessions.
NAMES="$HOME/.agent-status-board/names.json"
[ -f "$NAMES" ] || printf '{\n  "/Users/example/path/to/project": "My Session Name",\n  "00000000-0000-0000-0000-000000000000": "Exact Session Name"\n}\n' > "$NAMES"

# 1) install scripts to a stable location — only when content changed, so
#    re-running install doesn't needlessly churn files.
_changed=0
for s in record.sh cc-hook.sh codex-hook.sh codex-notify.sh classify.py configure-llm.sh cc-token-setup.sh; do
  if ! cmp -s "$SRC_DIR/$s" "$BIN_DIR/$s" 2>/dev/null; then
    cp "$SRC_DIR/$s" "$BIN_DIR/$s"; chmod +x "$BIN_DIR/$s"; _changed=$((_changed+1))
  fi
done
echo "installed scripts -> ${BIN_DIR}（更新 ${_changed} 个）"

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
#    per hook (keyed by its position) in a [hooks.state] table inside
#    config.toml. So if everything is already wired we change NOTHING, and
#    otherwise we only ADD what's missing — existing hooks, [hooks.state] and
#    every other table stay exactly where they are (nothing to rescue/re-add).
#    "Already wired" must survive Codex's own rewrites: it re-saves the file
#    with "double quotes" and drops our marker comments, and Computer Use turns
#    `notify` into a multi-line array that chains codex-notify.sh. Line regexes
#    missed both and appended a second notify / a second set of hooks, which
#    Codex refused to load (duplicate key). codex_toml.py reads it as TOML.
CODEX_CFG="$HOME/.codex/config.toml"
CODEX_HOOK="$BIN_DIR/codex-hook.sh"
if [ -f "$CODEX_CFG" ]; then
  python3 - "$SRC_DIR" "$CODEX_CFG" "$CODEX_HOOK" <<'PY'
import json, os, sys, time, shutil
sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1])
from codex_toml import statements, duplicates, root_key, first_table, toml_str, str_array, toml_string
path, hook = sys.argv[2], sys.argv[3]
txt = open(path).read()
events = ["UserPromptSubmit","PreToolUse","PostToolUse",
          "PreCompact","PostCompact","PermissionRequest","Stop"]
notify_wrapper = os.path.join(os.path.dirname(hook), "codex-notify.sh")
MARK = "# >>> agent-status-board hooks >>>"
END  = "# <<< agent-status-board hooks <<<"

# Already broken (e.g. by an older install.sh)? Don't touch it — point at the backup.
try:
    stmts = statements(txt)
    problem = ", ".join(duplicates(stmts)[:4])
    problem = problem and "重复定义 " + problem
except ValueError as e:
    problem = str(e)
if problem:
    print("⚠️ %s 不是合法 TOML（%s），Codex 无法加载它；本次未改动。" % (path, problem))
    print("   请用同目录下出问题前的 config.toml.bak.<时间戳> 还原，再重跑本脚本。")
    sys.exit(0)

# A hook is wired if some `command` holds exactly our command string, however
# Codex quoted it and whether or not our marker comments survived.
commands = {toml_str(s.value) for s in stmts if s.head.strip("\"'") == "command"}
missing = [e for e in events if f"{hook} {e}" not in commands]
# notify is wired if codex-notify.sh appears anywhere in its value — including
# Computer Use's rewrite that chains us via --previous-notify '["\/…\/codex-notify.sh"]'.
# Never replace that one: saving it as the "original" would make an endless
# loop codex-notify.sh → Computer Use → codex-notify.sh → …
notify = root_key(stmts, "notify")
notify_ok = notify is not None and "codex-notify.sh" in notify.value

# Already wired → DO NOTHING, so Codex's [hooks.state] trust hashes survive and
# you never re-approve on an update.
if not missing and notify_ok:
    print("Codex hooks 已就绪，未改动（保留信任，无需重新审核）")
    sys.exit(0)

# Wire notify too so turn-end works even before hooks are trusted. If Codex
# already had a notify command, save it and let codex-notify.sh pass through.
# (Done before appending hooks: offsets in `stmts` refer to the original text.)
if not notify_ok:
    line = "notify = [%s]" % toml_string(notify_wrapper)
    if notify:
        original = str_array(notify.value)
        if original:
            out = os.path.expanduser("~/.agent-status-board/codex-notify-original.json")
            os.makedirs(os.path.dirname(out), exist_ok=True)
            open(out, "w").write(json.dumps(original, indent=2))
        txt = txt[:notify.start] + line + txt[notify.end:]
    else:                       # a top-level key must come before the first [table]
        first = first_table(stmts)
        txt = (txt[:first.start] + line + "\n\n" + txt[first.start:]) if first \
              else txt.rstrip() + ("\n" if txt.strip() else "") + line + "\n"

# Append only the missing hooks; the ones already there keep their trust.
if missing:
    block = [MARK]
    for e in missing:
        block += [f"[[hooks.{e}]]", f"[[hooks.{e}.hooks]]", 'type = "command"',
                  "command = " + toml_string(f"{hook} {e}"), "timeout = 10", ""]
    block.append(END)
    txt = txt.rstrip() + "\n\n" + "\n".join(block) + "\n"

if duplicates(statements(txt)):     # never write a file Codex can't load
    print("⚠️ 接入 Codex hooks 会产生重复键，已放弃；未改动", path)
    sys.exit(0)
shutil.copy(path, path + ".bak." + time.strftime("%Y%m%d%H%M%S"))   # back up only when actually changing
open(path, "w").write(txt)
added = (["%d 个 hook" % len(missing)] if missing else []) + ([] if notify_ok else ["notify"])
print("wired Codex hooks ->", path, "（补上 %s；已有 hooks 与信任表未动）" % " + ".join(added))
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
