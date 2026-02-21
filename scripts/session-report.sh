#!/usr/bin/env bash
set -euo pipefail

# Stop hook: summarize session violations and write history snapshot

DEBUG_LOG="/tmp/ais-debug.log"
TIMESTAMP=$(date '+%Y-%m-%dT%H:%M:%S')
AIS_DIR="$PWD/.ais"

input=$(cat)
session_id=$(echo "$input" | jq -r '.session_id // "unknown"' 2>/dev/null || echo "unknown")

echo "[$TIMESTAMP] session-report.sh: session $session_id ended" >> "$DEBUG_LOG"

[ -f "$AIS_DIR/baseline.json" ] || exit 0

PROJECT_HASH=$(echo "$PWD" | md5 -q 2>/dev/null || echo "$PWD" | md5sum | cut -d' ' -f1)
CACHE_DIR="/tmp/ais-cache-${PROJECT_HASH}"
SESSION_VIOLATIONS="$CACHE_DIR/session-violations.json"

if [ ! -f "$SESSION_VIOLATIONS" ]; then
  jq -n '{"systemMessage": "ais: no edits this session"}'
  exit 0
fi

total=$(jq 'length' "$SESSION_VIOLATIONS")
errors=$(jq '[.[] | select(.severity == "error")] | length' "$SESSION_VIOLATIONS")
warnings=$(jq '[.[] | select(.severity == "warning")] | length' "$SESSION_VIOLATIONS")

echo "[$TIMESTAMP] session-report: $total total, $errors errors, $warnings warnings" >> "$DEBUG_LOG"

mkdir -p "$AIS_DIR/history"
SNAPSHOT_FILE="$AIS_DIR/history/${TIMESTAMP//:/-}.json"

# Compute health score matching generate-report.sh formula
unique_error_rules=$(jq '[.[] | select(.severity=="error") | .rule] | unique | length' "$SESSION_VIOLATIONS")
unique_warning_rules=$(jq '[.[] | select(.severity=="warning") | .rule] | unique | length' "$SESSION_VIOLATIONS")
score=$(echo "$unique_error_rules $unique_warning_rules" | awk '{s=100-$1*10-$2*3; print (s<0?0:s)}')

jq -n \
  --argjson score "$score" \
  --arg ts "$TIMESTAMP" \
  --arg sid "$session_id" \
  --argjson violations "$(cat "$SESSION_VIOLATIONS")" \
  '{score: $score, timestamp: $ts, session_id: $sid, violations: $violations}' \
  > "$SNAPSHOT_FILE"

if [ "$total" -eq 0 ]; then
  summary="ais: clean session"
else
  parts=()
  [ "$errors" -gt 0 ] && parts+=("$errors error(s)")
  [ "$warnings" -gt 0 ] && parts+=("$warnings warning(s)")
  violation_summary=$(IFS=", "; echo "${parts[*]}")
  rules=$(jq -r '[.[].rule] | unique | join(", ")' "$SESSION_VIOLATIONS")
  summary="ais: $total violation(s) — $violation_summary | rules: $rules | run /ais:scan for details"
fi

# warn about rules that keep getting violated
SUGGESTION=""
ALL_RULES=$(find "$AIS_DIR/history" -name "*.json" -print0 2>/dev/null \
  | xargs -0 cat 2>/dev/null \
  | jq -rs '[.[].violations[].rule] | group_by(.) | map({rule: .[0], count: length}) | .[] | select(.count >= 3)' \
  2>/dev/null || true)
if [ -n "$ALL_RULES" ] && [ "$ALL_RULES" != "null" ]; then
  REPEAT_RULES=$(echo "$ALL_RULES" | jq -r '.rule' | tr '\n' ', ' | sed 's/,$//')
  if [ -n "$REPEAT_RULES" ]; then
    SUGGESTION="\n\nCLAUDE.md tip: [${REPEAT_RULES}] has fired 3+ times — consider adding to CLAUDE.md:\n  'always run /ais:scan before committing'"
  fi
fi

jq -n --arg msg "${summary}${SUGGESTION}" '{"systemMessage": $msg}'

rm -f "$SESSION_VIOLATIONS"
