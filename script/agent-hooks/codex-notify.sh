#!/usr/bin/env bash
# codex-notify.sh
# Set as Codex `notify` program in ~/.codex/config.toml.
# Codex appends a JSON payload as the LAST argument.
# This wrapper (1) passes the event through to the original Computer Use client,
# then (2) records "turn ended" state for AgentStatusBoard.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REC="$DIR/record.sh"

# --- 1) passthrough to the original notify program (preserve existing behavior) ---
ORIG_JSON="$HOME/.agent-status-board/codex-notify-original.json"
orig_args=()
if [ -f "$ORIG_JSON" ]; then
  while IFS= read -r arg; do
    orig_args+=("$arg")
  done < <(python3 - "$ORIG_JSON" <<'PY' 2>/dev/null || true
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    data = []
if isinstance(data, list):
    for item in data:
        print(str(item))
PY
)
fi

if [ "${#orig_args[@]}" -eq 0 ]; then
  orig_args=("$HOME/.codex/computer-use/Codex Computer Use.app/Contents/SharedSupport/SkyComputerUseClient.app/Contents/MacOS/SkyComputerUseClient" "turn-ended")
fi

if [ -x "${orig_args[0]}" ]; then
  "${orig_args[@]}" "$@" >/dev/null 2>&1 || true
fi

# --- 2) record state ---
# The JSON payload is the last argument.
payload="${@: -1}"

id="$(printf '%s' "$payload" | jq -r '."thread-id" // .thread_id // ."turn-id" // .turn_id // "session"' 2>/dev/null || echo session)"
raw_msg="$(printf '%s' "$payload" | jq -r '
  (."input-messages" // .input_messages // []) as $m
  | (if ($m|type)=="array" then ($m|join(" ")) else ($m|tostring) end)
' 2>/dev/null | tr '\n' ' ')"

# Filter out Codex's internal "ambient" agents (memory writer, suggestion engine,
# safety/compliance classifiers). They fire turn-ended too, but are not user tasks.
# Their input is a system-style instruction prompt with recognizable markers.
case "$raw_msg" in
  "You are "*|"# Overview"*|"## Memory Writing Agent"*|*"hyperpersonalized suggestion"*|\
  *"upholding safety and compliance"*|*"presented with a user prompt"*|*"Phase 2 (Consolidation)"*)
    exit 0 ;;
esac

# Session name = the Codex thread's name (from the session index), not the raw
# prompt. Falls back to a generic label if not found.
IDX="$HOME/.codex/session_index.jsonl"
title="$(grep -F "$id" "$IDX" 2>/dev/null | tail -1 | jq -r '.thread_name // empty' 2>/dev/null)"
[ -z "$title" ] && title="Codex 会话"

# A finished Codex turn = done. (The notify event only ever means "turn ended".)
"$REC" --source codex --id "$id" --status done --title "$title" --activity || true

exit 0
