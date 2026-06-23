#!/usr/bin/env bash
# update.sh — pull the latest source from your GitHub remote, rebuild, and
# reinstall the app, then relaunch it.
#
# This is the "source self-update" path: the app is compiled locally, so it
# needs NO code-signing / notarization / Apple Developer account, and isn't
# blocked by Gatekeeper. Requirements: the repo is a git clone of your GitHub
# remote, and the machine has the Swift toolchain (same as the first install).
#
#   bash script/update.sh           # update to the latest on the tracked branch
#   bash script/update.sh --check   # only report whether a newer version exists
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

LOCAL_VER="$(tr -d '[:space:]' < VERSION 2>/dev/null || echo 0)"

# Newest VERSION committed on the remote's tracked branch.
remote_version() {
  git fetch --quiet origin 2>/dev/null || true
  local br
  br="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null | sed 's@^[^/]*/@@')"
  br="${br:-$(git branch --show-current 2>/dev/null)}"
  br="${br:-main}"
  git show "origin/${br}:VERSION" 2>/dev/null | tr -d '[:space:]'
}

# ver_gt A B → true if A > B (numeric, dot-separated).
ver_gt() {
  [ "$1" = "$2" ] && return 1
  [ "$(printf '%s\n%s\n' "$1" "$2" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)" = "$1" ]
}

REMOTE_VER="$(remote_version || true)"
REMOTE_VER="${REMOTE_VER:-$LOCAL_VER}"

if [ "${1:-}" = "--check" ]; then
  if ver_gt "$REMOTE_VER" "$LOCAL_VER"; then echo "update-available $REMOTE_VER"; else echo "up-to-date $LOCAL_VER"; fi
  exit 0
fi

echo "本地 $LOCAL_VER → 远端 $REMOTE_VER"
echo "拉取最新源码…"
git pull --ff-only

echo "重新编译…"
./script/build_and_run.sh package

echo "重新安装并重启…"
bash script/agent-hooks/autostart.sh on

echo "✅ 已更新到 $(tr -d '[:space:]' < VERSION)"
