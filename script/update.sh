#!/usr/bin/env bash
# update.sh [<checkout-dir>] [--check]
#
# Source self-update WITHOUT git. Downloads the latest source archive from the
# GitHub repo named in update-source.json, rebuilds locally, reinstalls, and
# relaunches. Works for anyone who installed from a ZIP — no git needed, just
# curl + ditto (built in) + the Swift toolchain. Locally compiled, so no code
# signing / notarization / Apple account, and never blocked by Gatekeeper.
#
#   bash update.sh                 # update if a newer version exists
#   bash update.sh <dir> --check   # only report whether a newer version exists
set -euo pipefail

CHECKOUT=""; CHECK=0
for a in "$@"; do
  case "$a" in
    --check) CHECK=1 ;;
    *) CHECKOUT="$a" ;;
  esac
done
[ -n "$CHECKOUT" ] || CHECKOUT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SRC_JSON="$CHECKOUT/update-source.json"
[ -f "$SRC_JSON" ] || { echo "缺少 update-source.json"; exit 1; }
read -r OWNER REPO BRANCH < <(python3 -c "import json;d=json.load(open('$SRC_JSON'));print(d.get('owner','') or '-', d.get('repo','') or '-', d.get('branch','main'))")
[ "$OWNER" != "-" ] && [ "$OWNER" != "" ] || { echo "update-source.json 还没填 owner/repo（你的 GitHub）"; exit 1; }

LOCAL_VER="$(tr -d '[:space:]' < "$CHECKOUT/VERSION" 2>/dev/null || echo 0)"
REMOTE_VER="$(curl -fsSL "https://raw.githubusercontent.com/$OWNER/$REPO/$BRANCH/VERSION" 2>/dev/null | tr -d '[:space:]' || true)"
REMOTE_VER="${REMOTE_VER:-$LOCAL_VER}"

ver_gt() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)" = "$1" ]; }

if [ "$CHECK" = 1 ]; then
  if ver_gt "$REMOTE_VER" "$LOCAL_VER"; then echo "update-available $REMOTE_VER"; else echo "up-to-date $LOCAL_VER"; fi
  exit 0
fi

echo "本地 $LOCAL_VER → 远端 $REMOTE_VER；下载最新源码…"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
curl -fsSL "https://codeload.github.com/$OWNER/$REPO/zip/refs/heads/$BRANCH" -o "$TMP/src.zip"
/usr/bin/ditto -x -k "$TMP/src.zip" "$TMP/x"
NEWSRC="$(/bin/ls -d "$TMP/x/"*/ 2>/dev/null | head -1)"
[ -n "$NEWSRC" ] && [ -f "${NEWSRC}Package.swift" ] || { echo "下载的源码不完整，已取消（旧版保持不动）"; exit 1; }

echo "编译…"
( cd "$NEWSRC" && ./script/build_and_run.sh package )   # build first — if it fails, old app stays
echo "重装并重启…"
( cd "$NEWSRC" && bash script/agent-hooks/autostart.sh on )

# Refresh the stable hook scripts so hook improvements ship with the update.
# Content-compare only, and we NEVER touch ~/.codex/config.toml: Codex keys hook
# trust on the command string (unchanged), not the script's content, so this
# triggers no re-approval.
SBIN="$HOME/.agent-status-board/bin"
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
# they write only to $TMP, ~/Applications, the LaunchAgent and
# ~/.agent-status-board/bin, never to the checkout, and they're what the user
# clicked 更新 for. Skipping them would leave the banner up, with the button
# stuck on "更新中…" because the app never restarts. A git-cloned install
# could then never update from the app.
if [ -e "$CHECKOUT/.git" ] || git -C "$CHECKOUT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "源码未刷新：$CHECKOUT 是 git 检出，本地改动原样保留；源码请用 git 自行更新。"
  echo "✅ 已更新到 $(tr -d '[:space:]' < "${NEWSRC}VERSION" 2>/dev/null)"
else
  /usr/bin/rsync -a --delete --exclude '.git' --exclude '.build' --exclude 'dist' "$NEWSRC" "$CHECKOUT/" 2>/dev/null || true
  echo "✅ 已更新到 $(tr -d '[:space:]' < "$CHECKOUT/VERSION" 2>/dev/null)"
fi
