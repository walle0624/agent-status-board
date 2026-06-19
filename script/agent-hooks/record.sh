#!/usr/bin/env bash
# record.sh --source S --id I --status ST [--title T] [--cwd C] [--model M] [--tool TL] [--activity]
#
# Writes/updates one session-state file consumed by AgentStatusBoard, and
# (with --activity) appends a line to the activity timeline.
#   status must match the Swift AgentTaskStatus rawValue:
#     running | thinking | waitingReview | done   (use "gone" to delete the file)
set -euo pipefail

DIR="$HOME/.agent-status-board"
SESS="$DIR/sessions"
ACT="$DIR/activity.jsonl"
mkdir -p "$SESS"

source="" id="" status="" title="" cwd="" model="" tool="" log_activity=0
while [ $# -gt 0 ]; do
  case "$1" in
    --source) source="$2"; shift 2;;
    --id) id="$2"; shift 2;;
    --status) status="$2"; shift 2;;
    --title) title="$2"; shift 2;;
    --cwd) cwd="$2"; shift 2;;
    --model) model="$2"; shift 2;;
    --tool) tool="$2"; shift 2;;
    --activity) log_activity=1; shift;;
    *) shift;;
  esac
done

[ -z "$source" ] && exit 0
[ -z "$id" ] && id="unknown"

key="${source}-${id}"
safe_key="$(printf '%s' "$key" | tr -c 'A-Za-z0-9._-' '_')"
f="$SESS/${safe_key}.json"
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

if [ "$status" = "gone" ]; then
  rm -f "$f"
  exit 0
fi

# preserve previously-known fields when this event does not carry them
if [ -f "$f" ]; then
  [ -z "$title" ] && title="$(jq -r '.title // ""' "$f" 2>/dev/null || echo "")"
  [ -z "$cwd" ]   && cwd="$(jq -r '.cwd // ""'   "$f" 2>/dev/null || echo "")"
  [ -z "$model" ] && model="$(jq -r '.model // ""' "$f" 2>/dev/null || echo "")"
  [ -z "$tool" ]  && tool="$(jq -r '.lastTool // ""' "$f" 2>/dev/null || echo "")"
fi

jq -n \
  --arg key "$key" --arg source "$source" --arg status "$status" \
  --arg title "$title" --arg cwd "$cwd" --arg model "$model" \
  --arg tool "$tool" --arg now "$now" \
  '{key:$key, source:$source, status:$status, title:$title, cwd:$cwd, model:$model, lastTool:$tool, updatedAt:$now}' \
  > "$f.tmp" && mv "$f.tmp" "$f"

if [ "$log_activity" = "1" ]; then
  jq -nc \
    --arg at "$now" --arg key "$key" --arg source "$source" --arg status "$status" \
    --arg title "$title" --arg cwd "$cwd" \
    '{at:$at, key:$key, source:$source, status:$status, title:$title, cwd:$cwd}' \
    >> "$ACT"
  # keep the timeline bounded
  if [ "$(wc -l < "$ACT" 2>/dev/null || echo 0)" -gt 500 ]; then
    tail -n 300 "$ACT" > "$ACT.tmp" && mv "$ACT.tmp" "$ACT"
  fi
fi
