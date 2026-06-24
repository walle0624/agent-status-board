#!/usr/bin/env bash
# review-pr.sh [<pr-number>]
#
# Local PR review helper. With no argument it lists the open pull requests.
# With a PR number it pulls that PR into an ISOLATED git worktree (so your main
# checkout is never disturbed), builds + tests it, prints the PR metadata and the
# full diff — everything needed to review the code locally. A human (or Claude)
# then reads it and writes: 功能摘要 + 代码审查 + 结论. Merging stays manual:
#   gh pr merge <N> --squash
set -uo pipefail

GH="$(command -v gh || echo "$HOME/.local/npm/bin/gh")"
REPO="walle0624/agent-status-board"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ "$#" -lt 1 ]; then
  echo "── 打开的 PR ──"
  "$GH" pr list -R "$REPO" 2>&1
  echo
  echo "用法: $0 <pr-number>   # 拉到隔离 worktree + 编译 + 测试 + 看 diff"
  exit 0
fi

N="$1"; WT="/tmp/asb-pr-$N"; BR="asb-pr-$N"

echo "════════ PR #$N ════════"
"$GH" pr view "$N" -R "$REPO" 2>&1 | sed -n '1,/^--/p'

# Fetch the PR head into a throwaway branch + worktree (works for fork PRs too).
git -C "$ROOT" worktree remove --force "$WT" 2>/dev/null || true
git -C "$ROOT" branch -D "$BR" 2>/dev/null || true
if ! git -C "$ROOT" fetch -q "https://github.com/$REPO" "pull/$N/head:$BR"; then
  echo "❌ 拉取 PR #$N 失败（确认编号、网络、gh 登录）"; exit 1
fi
git -C "$ROOT" worktree add -q "$WT" "$BR"

echo; echo "──── 功能检查（隔离 worktree: $WT）────"
( cd "$WT" && swift build && swift test ) && echo "✅ 编译 + 测试 通过" || echo "⚠️ 编译/测试 有问题（见上）"

echo; echo "──── 改动（相对 main）────"
"$GH" pr diff "$N" -R "$REPO" 2>&1

echo
echo "审完给：功能摘要 + 代码审查 + 结论（✅可合并 / ⚠️有问题）。"
echo "合并由你定：  $GH pr merge $N --squash -R $REPO"
echo "清理 worktree：git -C \"$ROOT\" worktree remove --force \"$WT\" && git -C \"$ROOT\" branch -D \"$BR\""
