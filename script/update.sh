#!/usr/bin/env bash
# update.sh [<checkout-dir>] [--check]
#
# Source self-update WITHOUT git. Downloads the latest source archive from the
# GitHub repo named in update-source.json, rebuilds locally, reinstalls, and
# relaunches. Works for anyone who installed from a ZIP — no git needed, just
# curl + ditto (built in) + the Swift toolchain. Bundles are ad-hoc signed locally.
# ASB_UPDATE_STATUS_FILE optionally receives atomic, private JSON progress.
#
#   bash update.sh                 # update if a newer version exists
#   bash update.sh <dir> --check   # only report whether a newer version exists
set -euo pipefail

STATUS_FILE="${ASB_UPDATE_STATUS_FILE:-}"
PHASE=checking
VERSION=""
TMP=""
LOCK_OWNED=0
LOCK_DIR="$HOME/.agent-status-board/update.lock"
LOCK_TOKEN="$$-$RANDOM-$RANDOM"

write_status() {
  [ -n "$STATUS_FILE" ] || return 0
  python3 - "$STATUS_FILE" "$PHASE" "$VERSION" "${1:-}" "${2:-}" "$$" <<'PY'
import json, os, pathlib, sys, tempfile, time
path = pathlib.Path(sys.argv[1])
path.parent.mkdir(parents=True, exist_ok=True)
data = {"phase": sys.argv[2], "version": sys.argv[3], "updatedAt": time.time(), "pid": int(sys.argv[6])}
if sys.argv[4]:
    data["exitCode"] = int(sys.argv[4])
if sys.argv[5]:
    data["failedPhase"] = sys.argv[5]
fd, temporary = tempfile.mkstemp(prefix=".asb-update-", dir=path.parent)
try:
    with os.fdopen(fd, "w") as out:
        os.fchmod(out.fileno(), 0o600)
        json.dump(data, out)
        out.write("\n")
    os.replace(temporary, path)
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)
PY
}

set_phase() { PHASE="$1"; write_status; }

# mkdir is the long-lived lock; flock only serializes its metadata changes so
# two contenders cannot both remove a stale lock and steal the replacement.
lock_action() {
  python3 - "$LOCK_DIR" "$1" "$$" "$LOCK_TOKEN" <<'PY'
import fcntl, json, os, pathlib, sys, time
lock, action, pid, token = pathlib.Path(sys.argv[1]), sys.argv[2], int(sys.argv[3]), sys.argv[4]
lock.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
fd = os.open(str(lock) + ".guard", os.O_RDWR | os.O_CREAT, 0o600)
with os.fdopen(fd, "w") as guard:
    fcntl.flock(guard, fcntl.LOCK_EX)
    owner = lock / "owner.json"
    try:
        previous = json.loads(owner.read_text())
    except (OSError, ValueError):
        previous = {}
    if not isinstance(previous, dict):
        previous = {}
    if action == "release":
        if previous == {"pid": pid, "token": token} and not lock.is_symlink():
            owner.unlink()
            lock.rmdir()
        sys.exit(0)
    if lock.is_symlink() or (lock.exists() and not lock.is_dir()):
        sys.exit(75)
    if lock.exists():
        previous_pid = previous.get("pid")
        if type(previous_pid) is int and previous_pid > 0:
            try:
                os.kill(previous_pid, 0)
            except ProcessLookupError:
                pass
            except PermissionError:
                sys.exit(75)
            else:
                sys.exit(75)
        elif time.time() - lock.stat().st_mtime < 30:
            # A new/incomplete owner record is never presumed dead.
            sys.exit(75)
        if any(p.name != "owner.json" for p in lock.iterdir()):
            sys.exit(75)
        if owner.exists():
            owner.unlink()
        lock.rmdir()
    lock.mkdir(mode=0o700)
    owner.write_text(json.dumps({"pid": pid, "token": token}))
    owner.chmod(0o600)
PY
}

finish() {
  local rc=$? failed_phase="$PHASE"
  trap - EXIT HUP INT TERM
  if [ "$rc" -ne 0 ]; then
    PHASE=failed
    write_status "$rc" "$failed_phase" || true
    echo "更新失败（阶段 $failed_phase，退出码 $rc）；详见更新日志。" >&2
  fi
  [ -z "$TMP" ] || rm -rf "$TMP" || true
  if [ "$LOCK_OWNED" = 1 ]; then lock_action release || true; fi
  exit "$rc"
}
trap finish EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

CHECKOUT=""; CHECK=0
for a in "$@"; do
  case "$a" in
    --check) CHECK=1 ;;
    *) CHECKOUT="$a" ;;
  esac
done
[ -n "$CHECKOUT" ] || CHECKOUT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if lock_action acquire; then
  LOCK_OWNED=1
else
  rc=$?
  [ "$rc" -ne 75 ] || echo "已有更新正在运行，请等待完成后重试。" >&2
  exit "$rc"
fi
write_status
SRC_JSON="$CHECKOUT/update-source.json"
[ -f "$SRC_JSON" ] || { echo "缺少 update-source.json"; exit 1; }
SOURCE_FIELDS="$(python3 - "$SRC_JSON" <<'PY'
import json, re, sys
d = json.load(open(sys.argv[1]))
owner, repo, branch = d.get("owner", ""), d.get("repo", ""), d.get("branch", "main")
if not all(isinstance(x, str) and re.fullmatch(r"[A-Za-z0-9_.\-/]+", x) for x in (owner, repo, branch)):
    sys.exit("update-source.json 的 owner/repo/branch 无效")
print(owner, repo, branch)
PY
)"
read -r OWNER REPO BRANCH <<< "$SOURCE_FIELDS"

LOCAL_VER="$(tr -d '[:space:]' < "$CHECKOUT/VERSION" 2>/dev/null || echo 0)"
REMOTE_VER="$(curl -fsSL --connect-timeout 10 --max-time 30 --retry 2 --retry-delay 1 --retry-max-time 65 \
  "https://raw.githubusercontent.com/$OWNER/$REPO/$BRANCH/VERSION")"
REMOTE_VER="$(printf '%s' "$REMOTE_VER" | tr -d '[:space:]')"
[[ "$REMOTE_VER" =~ ^[0-9]+(\.[0-9]+)*$ ]] || { echo "远端 VERSION 无效，已取消。" >&2; exit 65; }
VERSION="$REMOTE_VER"

ver_gt() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)" = "$1" ]; }

if [ "$CHECK" = 1 ]; then
  if ver_gt "$REMOTE_VER" "$LOCAL_VER"; then echo "update-available $REMOTE_VER"; else echo "up-to-date $LOCAL_VER"; fi
  set_phase completed
  exit 0
fi

echo "本地 $LOCAL_VER → 远端 ${REMOTE_VER}；下载最新源码…"
set_phase downloading
TMP="$(mktemp -d)"
curl -fsSL --connect-timeout 10 --max-time 180 --retry 2 --retry-delay 1 --retry-max-time 360 \
  "https://codeload.github.com/$OWNER/$REPO/zip/refs/heads/$BRANCH" -o "$TMP/src.zip"
/usr/bin/ditto -x -k "$TMP/src.zip" "$TMP/x"
NEWSRC="$(/bin/ls -d "$TMP/x/"*/ 2>/dev/null | head -1)"
[ -n "$NEWSRC" ] && [ -f "${NEWSRC}Package.swift" ] || { echo "下载的源码不完整，已取消（旧版保持不动）"; exit 1; }

echo "编译…"
set_phase building
( cd "$NEWSRC" && ./script/build_and_run.sh package )   # build first — if it fails, old app stays
echo "重装并重启…"
set_phase installing
( cd "$NEWSRC" && ASB_LEGACY_CHECKOUT_DIR="$CHECKOUT" bash script/agent-hooks/autostart.sh on )

# Refresh the stable hook scripts so hook improvements ship with the update.
# Content-compare only, and we NEVER touch ~/.codex/config.toml: Codex keys hook
# trust on the command string (unchanged), not the script's content, so this
# triggers no re-approval.
SBIN="$HOME/.agent-status-board/bin"
set_phase refreshing
if [ -d "$SBIN" ]; then
  for s in record.sh cc-hook.sh codex-hook.sh codex-notify.sh classify.py configure-llm.sh cc-token-setup.sh; do
    src="${NEWSRC}script/agent-hooks/$s"
    if [ -f "$src" ] && ! cmp -s "$src" "$SBIN/$s" 2>/dev/null; then
      cp "$src" "$SBIN/$s"; chmod +x "$SBIN/$s"
    fi
  done
fi

# Refresh the local source so the next check/update is current (keep build dirs).
# NEVER for a git checkout: this rsync overwrites every uncommitted edit and
# deletes untracked and ignored files. On 2026-10-15, releasing v1.32 made an
# installed 1.31 app wipe the dev clone this way (the app compares the remote
# VERSION with its own bundle, not with the checkout). A git checkout is
# refreshed with git. A .git entry alone counts too, so a git that errors
# (dubious ownership, a stale worktree link) can't fail open into the rsync.
# The build, reinstall and hook refresh above still run for a git checkout:
# they write to $TMP, ~/Applications, the LaunchAgent and the stable hook bin.
# The installer may also remove a verified obsolete dist/AgentStatusBoard.app;
# source files and unrelated checkout artifacts remain untouched. This is what the user
# clicked 更新 for. Skipping them would leave the banner up, with the button
# stuck on "更新中…" because the app never restarts. A git-cloned install
# could then never update from the app.
if [ -e "$CHECKOUT/.git" ] || [ -L "$CHECKOUT/.git" ] || git -C "$CHECKOUT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "源码未刷新：$CHECKOUT 是 git 检出，本地改动原样保留；源码请用 git 自行更新。"
  echo "✅ 已更新到 $(tr -d '[:space:]' < "${NEWSRC}VERSION" 2>/dev/null)"
else
  /usr/bin/rsync -a --delete --exclude '.git' --exclude '.build' --exclude 'dist' "$NEWSRC" "$CHECKOUT/"
  echo "✅ 已更新到 $(tr -d '[:space:]' < "$CHECKOUT/VERSION" 2>/dev/null)"
fi
set_phase completed
