#!/usr/bin/env bash
set -euo pipefail

# Stop hook: summarize session violations and write history snapshot

THYMUS_DIR="$PWD/.thymus"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

input=$(cat)
session_id=$(echo "$input" | jq -r '.session_id // "unknown"' 2>/dev/null || echo "unknown")

echo "[$TIMESTAMP] session-report.sh: session $session_id ended" >> "$DEBUG_LOG"

[ -f "$THYMUS_DIR/baseline.json" ] || exit 0

CACHE_DIR=$(thymus_cache_dir)
SESSION_VIOLATIONS="$CACHE_DIR/session-violations.json"

if [ ! -f "$SESSION_VIOLATIONS" ]; then
  jq -n '{"systemMessage": "thymus: no edits this session"}'
  exit 0
fi

total=$(jq 'length' "$SESSION_VIOLATIONS")
errors=$(jq '[.[] | select(.severity == "error")] | length' "$SESSION_VIOLATIONS")
warnings=$(jq '[.[] | select(.severity == "warning")] | length' "$SESSION_VIOLATIONS")

echo "[$TIMESTAMP] session-report: $total total, $errors errors, $warnings warnings" >> "$DEBUG_LOG"

# Build scan-compatible JSON for history append
SCAN_JSON=$(jq -n \
  --argjson violations "$(cat "$SESSION_VIOLATIONS")" \
  --argjson total "$total" \
  --argjson errors "$errors" \
  --argjson warnings "$warnings" \
  '{files_checked: ([$violations[].file] | unique | length), violations: $violations, stats: {total: $total, errors: $errors, warnings: $warnings}}')
echo "$SCAN_JSON" | bash "$SCRIPT_DIR/append-history.sh" --stdin

if [ "$total" -eq 0 ]; then
  summary="thymus: clean session"
else
  parts=()
  [ "$errors" -gt 0 ] && parts+=("$errors error(s)")
  [ "$warnings" -gt 0 ] && parts+=("$warnings warning(s)")
  violation_summary=$(IFS=", "; echo "${parts[*]}")
  rules=$(jq -r '[.[].rule] | unique | join(", ")' "$SESSION_VIOLATIONS")
  summary="thymus: $total violation(s) — $violation_summary | rules: $rules | run /thymus:scan for details"
fi

# warn about rules that keep getting violated
SUGGESTION=""
HISTORY_FILE="$THYMUS_DIR/history.jsonl"
ALL_RULES=""
if [ -f "$HISTORY_FILE" ]; then
  ALL_RULES=$(jq -s '[.[].by_rule // {} | to_entries[]] | group_by(.key) | map({rule: .[0].key, count: (map(.value) | add)}) | .[] | select(.count >= 3)' "$HISTORY_FILE" 2>/dev/null || true)
fi
if [ -n "$ALL_RULES" ] && [ "$ALL_RULES" != "null" ]; then
  REPEAT_RULES=$(echo "$ALL_RULES" | jq -r '.rule' | tr '\n' ', ' | sed 's/,$//')
  if [ -n "$REPEAT_RULES" ]; then
    SUGGESTION="\n\nCLAUDE.md tip: [${REPEAT_RULES}] has fired 3+ times — consider adding to CLAUDE.md:\n  'always run /thymus:scan before committing'"
  fi
fi

jq -n --arg msg "${summary}${SUGGESTION}" '{"systemMessage": $msg}'

rm -f "$SESSION_VIOLATIONS"
