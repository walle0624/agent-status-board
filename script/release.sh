#!/usr/bin/env bash
# release.sh [<version>|next|major] [--dry-run]
#
# One-command release. Bumps VERSION, commits, tags, pushes, and creates a
# GitHub Release whose notes are the matching "## v<version>" section of
# CHANGELOG.md. So the flow per release is:
#   1) write a "## v<new>" section at the top of CHANGELOG.md
#   2) run this script
#
#   bash script/release.sh 1.15            # explicit version
#   bash script/release.sh next            # bump last component (1.14 -> 1.15)
#   bash script/release.sh                 # same as "next"
#   bash script/release.sh 1.15 --dry-run  # preview only, change nothing
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

DRY=0; ARG=""
for a in "$@"; do
  case "$a" in --dry-run|-n) DRY=1 ;; *) ARG="$a" ;; esac
done
[ -n "$ARG" ] || ARG="next"

CUR="$(tr -d '[:space:]' < VERSION 2>/dev/null || echo 0.0)"
case "$ARG" in
  next)  NEW="${CUR%.*}.$(( ${CUR##*.} + 1 ))" ;;   # 1.14 -> 1.15
  major) NEW="$(( ${CUR%%.*} + 1 )).0" ;;           # 1.14 -> 2.0
  *)     NEW="$ARG" ;;
esac
TAG="v$NEW"
GH="$(command -v gh || echo "$HOME/.local/npm/bin/gh")"

# Release notes = the CHANGELOG section for this version, if written.
NOTES="$(mktemp)"; trap 'rm -f "$NOTES"' EXIT
if [ -f CHANGELOG.md ]; then
  awk -v v="## v$NEW" '$0==v{g=1;next} g&&/^## v/{exit} g{print}' CHANGELOG.md \
    | sed '/^[[:space:]]*$/d' > "$NOTES" || true
fi
if [ ! -s "$NOTES" ]; then
  echo "⚠ CHANGELOG.md 里没有 \"## v$NEW\" 段落（建议先写好该段，再发版）"
  printf '本版更新见仓库 CHANGELOG.md。\n' > "$NOTES"
fi

echo "── 发布 $CUR → $NEW (tag $TAG) ──"
echo "Release 说明："; sed 's/^/  /' "$NOTES"

if git rev-parse "$TAG" >/dev/null 2>&1; then
  [ "$DRY" = 1 ] && { echo "(注：tag $TAG 已存在，正式发版会被拒)"; exit 0; }
  echo "✗ tag $TAG 已存在，换个版本号"; exit 1
fi
[ "$DRY" = 1 ] && { echo "(--dry-run：未做任何改动)"; exit 0; }

printf '%s\n' "$NEW" > VERSION
git add -A
git commit -q -m "Release $NEW" || true
git tag -a "$TAG" -m "Agent Status Board $NEW"
git push origin "$(git branch --show-current)"
git push origin "$TAG"

if [ -x "$GH" ]; then
  "$GH" release create "$TAG" --title "$TAG" --notes-file "$NOTES" >/dev/null \
    && echo "✅ 已发布 + 建 Release：$("$GH" release view "$TAG" --json url -q .url 2>/dev/null)"
else
  echo "✅ 已 push tag $TAG（未找到 gh，跳过 GitHub Release）"
fi
echo "（装了的人会在下次检查/重启时收到更新提示）"
