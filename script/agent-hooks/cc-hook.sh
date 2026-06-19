#!/usr/bin/env bash
# cc-hook.sh <EventName>   (registered in ~/.claude/settings.json)
# Reads the hook JSON payload from stdin and maps Claude Code lifecycle
# events to AgentStatusBoard session state + activity timeline.
set -euo pipefail

EVENT="${1:-}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REC="$DIR/record.sh"

payload="$(cat 2>/dev/null || true)"
get() { printf '%s' "$payload" | jq -r "$1 // \"\"" 2>/dev/null || echo ""; }

id="$(get '.session_id')"; [ -z "$id" ] && id="unknown"
cwd="$(get '.cwd')"
model="$(get '.model.display_name // .model.id // .model')"
tx="$(get '.transcript_path')"

# Claude Code's own session name lives in the transcript as custom-title
# (user-set, preferred) or ai-title (auto-generated) entries. Read the latest
# from the file tail (cheap; titles are appended near the end).
name=""
if [ -f "$tx" ]; then
  name="$(tail -c 300000 "$tx" 2>/dev/null | grep '"type":"custom-title"' | tail -1 | jq -r '.customTitle // empty' 2>/dev/null)"
  [ -z "$name" ] && name="$(tail -c 300000 "$tx" 2>/dev/null | grep '"type":"ai-title"' | tail -1 | jq -r '.aiTitle // empty' 2>/dev/null)"
fi
# Fallback to the project folder name if the session has no title yet.
if [ -z "$name" ]; then
  name="$(basename "$cwd" 2>/dev/null)"
  [ -z "$name" ] || [ "$name" = "." ] || [ "$name" = "/" ] && name="CC 会话"
fi
proj="$name"

case "$EVENT" in
  UserPromptSubmit)
    "$REC" --source claudeCode --id "$id" --status running --title "$proj" --cwd "$cwd" --model "$model" --activity
    ;;
  PreToolUse|PostToolUse)
    tool="$(get '.tool_name')"
    "$REC" --source claudeCode --id "$id" --status running --title "$proj" --cwd "$cwd" --model "$model" --tool "$tool"
    ;;
  PreCompact|PostCompact)
    "$REC" --source claudeCode --id "$id" --status thinking --title "$proj" --cwd "$cwd" --model "$model" --activity
    ;;
  Notification)
    "$REC" --source claudeCode --id "$id" --status waitingReview --title "$proj" --cwd "$cwd" --model "$model" --activity
    ;;
  Stop)
    "$REC" --source claudeCode --id "$id" --status done --title "$proj" --cwd "$cwd" --model "$model" --activity
    ;;
  SessionEnd)
    "$REC" --source claudeCode --id "$id" --status gone
    ;;
esac

exit 0
