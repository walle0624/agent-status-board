#!/usr/bin/env bash
# pr-watch.sh [--test]
#
# Poll the repo's open pull requests and pop a macOS notification for each NEW
# one (not seen before). Meant to be run periodically by the LaunchAgent that
# pr-watch-install.sh sets up. Already-notified PR numbers are remembered in
# ~/.agent-status-board/pr-seen.txt. The review itself stays on-demand — you see
# the notification, then ask Claude to review (script/review-pr.sh).
set -uo pipefail

GH="$(command -v gh || echo "$HOME/.local/npm/bin/gh")"
REPO="walle0624/agent-status-board"
SEEN="$HOME/.agent-status-board/pr-seen.txt"
mkdir -p "$(dirname "$SEEN")"; touch "$SEEN"

clean() { printf '%s' "$1" | tr -d '"\\'; }
notify() { /usr/bin/osascript -e "display notification \"$2\" with title \"$1\" sound name \"Glass\"" >/dev/null 2>&1 || true; }

if [ "${1:-}" = "--test" ]; then
  notify "PR 监视已开启" "之后有新 PR 会在这里提醒你 · agent-status-board"
  exit 0
fi

"$GH" pr list -R "$REPO" --state open --json number,title,author \
  --jq '.[] | "\(.number)\t\(.title)\t\(.author.login)"' 2>/dev/null \
| while IFS=$'\t' read -r num title author; do
    [ -n "${num:-}" ] || continue
    grep -qx "$num" "$SEEN" && continue
    echo "$num" >> "$SEEN"
    notify "新 PR #$num 待审" "$(clean "$author"): $(clean "$title")"
  done
exit 0
