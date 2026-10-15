#!/usr/bin/env bash
# uninstall.sh — remove AgentStatusBoard hooks from Claude Code and Codex.
# Restores Codex notify to the original Computer Use client and strips the
# cc-hook.sh entries from Claude Code settings. Leaves backups untouched.
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

# 2) Codex: remove our hooks and restore the original notify program, if any.
CODEX_CFG="$HOME/.codex/config.toml"
ORIG_JSON="$HOME/.agent-status-board/codex-notify-original.json"
if [ -f "$CODEX_CFG" ]; then
  cp "$CODEX_CFG" "$CODEX_CFG.bak.$(date +%Y%m%d%H%M%S)"
  python3 - "$SRC_DIR" "$CODEX_CFG" "$ORIG_JSON" "$BIN_DIR/codex-notify.sh" "$BIN_DIR/codex-hook.sh" <<'PY'
import json, os, re, sys
sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1])
from codex_toml import statements, duplicates, root_key, first_table, str_array, table_path, toml_str
path, orig_json, wrapper, hook = sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
txt = open(path).read()

# Already broken (e.g. by an older install.sh)? Don't touch it — point at the backup.
try:
    stmts = statements(txt)
    problem = ", ".join(duplicates(stmts)[:4])
    problem = problem and "重复定义 " + problem
except ValueError as e:
    problem = str(e)
if problem:
    print("⚠️ %s 不是合法 TOML（%s），Codex 无法加载它；本次未改动。" % (path, problem))
    print("   请用同目录下出问题前的 config.toml.bak.<时间戳> 还原。")
    sys.exit(0)

# Find our hooks by their command, not by our marker comments: Codex re-saves
# the file with "double quotes" and drops comments, and may have put its own
# tables ([hooks.state] trust, new [mcp_servers.*]) inside the old fence.
# Drop each [[hooks.<E>.hooks]] table whose command is ours, its [[hooks.<E>]]
# group once nothing else is left in it, and the two marker lines; every
# other table (other tools' hooks for the same event included) stays put.
MARK = "# >>> agent-status-board hooks >>>"
END = "# <<< agent-status-board hooks <<<"
tables = []                             # [header, path, keys] in file order
for s in stmts:
    if s.value is None:
        tables.append([s, table_path(s.head), []])
    elif tables:
        tables[-1][2].append(s)
cur, members, ours = {}, {}, set()      # cur: event -> [its latest group, latest handler]
for i, (h, p, keys) in enumerate(tables):
    if len(p) < 2 or p[0] != "hooks":
        continue
    e, array = p[1], h.head.startswith("[[")
    if array and len(p) == 2:           # [[hooks.E]] opens a new group
        cur[e], members[i] = [i, None], []
    elif e in cur:                      # a table inside the current group
        members[cur[e][0]].append(i)
        if array and p[2:] == ("hooks",):
            cur[e][1] = i
            if [toml_str(k.value) for k in keys if k.head.strip("\"'") == "command"] == [f"{hook} {e}"]:
                ours.add(i)
        elif p[2:3] == ("hooks",):      # a sub-table of that handler: not just ours any more
            ours.discard(cur[e][1])
drop = ours | {g for g, m in members.items() if m and set(m) <= ours and not tables[g][2]}

BLANK = re.compile(r"(?:[ \t\r]*\n)*")
def whole_lines(a, b):                  # the lines holding offsets a..b, plus blank lines after
    b = txt.find("\n", b)
    return txt.rfind("\n", 0, a) + 1, BLANK.match(txt, len(txt) if b < 0 else b + 1).end()
cuts = []
for i in drop:
    h, _, keys = tables[i]
    cuts.append(whole_lines(h.start, (keys or [h])[-1].end))
for m in re.finditer(r"(?m)^[ \t]*(?:%s|%s)[ \t\r]*$" % (re.escape(MARK), re.escape(END)), txt):
    if not any(s.start <= m.start() < s.end for s in stmts):   # a comment line, not inside a value
        cuts.append(whole_lines(m.start(), m.end()))
kept, pos = [], 0
for a, b in sorted(cuts):
    kept.append(txt[pos:max(pos, a)])
    pos = max(pos, b)
kept.append(txt[pos:])
at_eof = bool(cuts) and pos == len(txt)
txt = "".join(kept)
if at_eof:                              # cut through to the end: leave no trailing blank lines
    txt = txt.rstrip() + "\n" if txt.strip() else ""

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

# Read notify as TOML, not by line: Computer Use rewrites it as a multi-line
# array (a single-line regex missed it and a second `notify` got inserted →
# duplicate key), chaining us via --previous-notify '["\/…\/codex-notify.sh"]'.
stmts = statements(txt)
nm = root_key(stmts, "notify")
args = str_array(nm.value) if nm else None
if nm and "codex-notify.sh" in nm.value and args is None:
    print("⚠️ Codex notify 无法解析，未改动它 ->", path)
elif nm and "codex-notify.sh" in nm.value:
    k = args.index("--previous-notify") if "--previous-notify" in args[:-1] else -1
    if k > 0 and "codex-notify.sh" in args[k + 1]:
        # Computer Use chains us. Hand back what was there before install:
        # Computer Use's own notify we saved (as-is), the program we replaced
        # (re-chained behind Computer Use), or just unlink us.
        if original and os.path.basename(original[0]) == os.path.basename(args[0]):
            args = original
        elif original:
            args = args[:k + 1] + [json.dumps(original)] + args[k + 2:]
        else:
            args = args[:k] + args[k + 2:]
    else:
        args = original
    txt = txt[:nm.start] + (notify_line(args) if args else "") + txt[nm.end:]
elif not nm and original:
    line = notify_line(original)
    m = first_table(stmts)
    txt = (txt[:m.start] + line + "\n\n" + txt[m.start:]) if m else (txt.rstrip() + "\n" + line + "\n")

after = statements(txt)
if duplicates(after):                   # never write a file Codex can't load
    print("⚠️ 卸载后会产生重复键，已放弃；未改动", path)
    sys.exit(0)
open(path,"w").write(txt)
print("removed %d Codex hooks, restored notify ->" % len(ours), path)
left = sum(hook in (s.value or "") for s in after)
if left:
    print("⚠️ 还有 %d 处 codex-hook.sh 不是 [[hooks.<事件>.hooks]] 写法，没有自动移除，请手动删除 ->" % left, path)
PY
fi

echo "done. Restart Codex / start new Claude Code sessions for removal to take effect."
echo "(state dir ~/.agent-status-board left in place; rm -rf it to fully clean up.)"
