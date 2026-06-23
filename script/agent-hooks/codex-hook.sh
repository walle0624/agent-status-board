#!/usr/bin/env bash
# codex-hook.sh <EventName>   (registered in ~/.codex/config.toml [[hooks.*]])
# Codex lifecycle hooks — same stdin JSON schema as Claude Code. Maps Codex
# events to AgentStatusBoard session state. This is the OFFICIAL real-time
# signal (replaces the fragile log/rollout heuristics).
set -euo pipefail

EVENT="${1:-}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REC="$DIR/record.sh"

payload="$(cat 2>/dev/null || true)"
get() { printf '%s' "$payload" | jq -r "$1 // \"\"" 2>/dev/null || echo ""; }

id="$(get '.session_id')"; [ -z "$id" ] && id="unknown"
cwd="$(get '.cwd')"
model="$(get '.model.slug // .model.id // .model')"

# Session name = the thread's name from the session index, else the project folder.
name="$(grep -F "$id" "$HOME/.codex/session_index.jsonl" 2>/dev/null | tail -1 | jq -r '.thread_name // empty' 2>/dev/null)"
if [ -z "$name" ]; then
  name="$(basename "$cwd" 2>/dev/null)"
  [ -z "$name" ] || [ "$name" = "." ] || [ "$name" = "/" ] && name="Codex 会话"
fi

case "$EVENT" in
  UserPromptSubmit)
    "$REC" --source codex --id "$id" --status running --title "$name" --cwd "$cwd" --model "$model" --activity
    ;;
  PreToolUse|PostToolUse)
    tool="$(get '.tool_name')"
    "$REC" --source codex --id "$id" --status running --title "$name" --cwd "$cwd" --model "$model" --tool "$tool"
    ;;
  PreCompact|PostCompact)
    "$REC" --source codex --id "$id" --status thinking --title "$name" --cwd "$cwd" --model "$model" --activity
    ;;
  PermissionRequest)
    "$REC" --source codex --id "$id" --status waitingReview --title "$name" --cwd "$cwd" --model "$model" --activity
    ;;
  Stop)
    # Turn finished = done. "Needs you" is signalled separately by
    # PermissionRequest (agent blocked waiting for your approval/input).
    "$REC" --source codex --id "$id" --status done --title "$name" --cwd "$cwd" --model "$model" --activity
    # Background LLM classify: is this finished turn actually waiting on the user?
    nohup python3 "$DIR/classify.py" codex "$id" >/dev/null 2>&1 &
    ;;
esac

# Hooks must exit 0 and emit nothing on stdout to avoid altering Codex behavior.
exit 0
