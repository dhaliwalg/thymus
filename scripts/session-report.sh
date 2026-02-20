#!/usr/bin/env bash
set -euo pipefail

# AIS Stop hook — session-report.sh
# Fires at end of every Claude session. Reads session violations from cache,
# writes a history snapshot, and outputs a compact summary systemMessage.

DEBUG_LOG="/tmp/ais-debug.log"
TIMESTAMP=$(date '+%Y-%m-%dT%H:%M:%S')
AIS_DIR="$PWD/.ais"

input=$(cat)
session_id=$(echo "$input" | jq -r '.session_id // "unknown"' 2>/dev/null || echo "unknown")

echo "[$TIMESTAMP] session-report.sh: session $session_id ended" >> "$DEBUG_LOG"

# No baseline = silent exit
[ -f "$AIS_DIR/baseline.json" ] || exit 0

# Get session cache
PROJECT_HASH=$(echo "$PWD" | md5 -q 2>/dev/null || echo "$PWD" | md5sum | cut -d' ' -f1)
CACHE_DIR="/tmp/ais-cache-${PROJECT_HASH}"
SESSION_VIOLATIONS="$CACHE_DIR/session-violations.json"

# No violations file means no edits were analyzed
if [ ! -f "$SESSION_VIOLATIONS" ]; then
  jq -n '{"systemMessage": "📋 AIS: No architectural edits this session."}'
  exit 0
fi

# Count violations by severity
total=$(jq 'length' "$SESSION_VIOLATIONS")
errors=$(jq '[.[] | select(.severity == "error")] | length' "$SESSION_VIOLATIONS")
warnings=$(jq '[.[] | select(.severity == "warning")] | length' "$SESSION_VIOLATIONS")

echo "[$TIMESTAMP] session-report: $total total, $errors errors, $warnings warnings" >> "$DEBUG_LOG"

# Write history snapshot
mkdir -p "$AIS_DIR/history"
SNAPSHOT_FILE="$AIS_DIR/history/${TIMESTAMP//:/-}.json"
jq -n \
  --arg ts "$TIMESTAMP" \
  --arg sid "$session_id" \
  --argjson violations "$(cat "$SESSION_VIOLATIONS")" \
  '{timestamp: $ts, session_id: $sid, violations: $violations}' \
  > "$SNAPSHOT_FILE"

echo "[$TIMESTAMP] History snapshot written to $SNAPSHOT_FILE" >> "$DEBUG_LOG"

# Build summary message
if [ "$total" -eq 0 ]; then
  summary="✅ AIS: Clean session — no violations detected."
else
  parts=()
  [ "$errors" -gt 0 ] && parts+=("$errors error(s)")
  [ "$warnings" -gt 0 ] && parts+=("$warnings warning(s)")
  violation_summary=$(IFS=", "; echo "${parts[*]}")

  # Get unique rules violated
  rules=$(jq -r '[.[].rule] | unique | join(", ")' "$SESSION_VIOLATIONS")

  summary="⚠️ AIS Session: $total violation(s) — $violation_summary | Rules: $rules | Run /ais:scan for details"
fi

jq -n --arg msg "$summary" '{"systemMessage": $msg}'

# Clear session cache for next session
rm -f "$SESSION_VIOLATIONS"
