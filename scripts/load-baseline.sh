#!/usr/bin/env bash
set -euo pipefail

# SessionStart hook: inject a compact baseline summary

DEBUG_LOG="/tmp/ais-debug.log"
AIS_DIR="$PWD/.ais"
BASELINE="$AIS_DIR/baseline.json"
TIMESTAMP=$(date '+%Y-%m-%dT%H:%M:%S')

echo "[$TIMESTAMP] load-baseline.sh fired in $PWD" >> "$DEBUG_LOG"

if [ ! -f "$BASELINE" ]; then
  jq -n '{"systemMessage": "ais: no baseline found — run /ais:baseline to initialize"}'
  exit 0
fi

MODULE_COUNT=$(jq '.modules | length' "$BASELINE" 2>/dev/null || echo "0")
INVARIANT_COUNT=0
if [ -f "$AIS_DIR/invariants.yml" ]; then
  INVARIANT_COUNT=$(grep -c "^  - id:" "$AIS_DIR/invariants.yml" 2>/dev/null || echo "0")
fi

RECENT_VIOLATIONS=0
if [ -d "$AIS_DIR/history" ]; then
  LAST_SNAPSHOT=$(find "$AIS_DIR/history" -name "*.json" -type f | sort | tail -1)
  if [ -n "$LAST_SNAPSHOT" ]; then
    RECENT_VIOLATIONS=$(jq '.violations | length' "$LAST_SNAPSHOT" 2>/dev/null || echo "0")
  fi
fi

echo "[$TIMESTAMP] baseline: $MODULE_COUNT modules, $INVARIANT_COUNT invariants, $RECENT_VIOLATIONS recent violations" >> "$DEBUG_LOG"

MSG="ais: $MODULE_COUNT modules | $INVARIANT_COUNT invariants active"
[ "$RECENT_VIOLATIONS" -gt 0 ] && MSG="$MSG | $RECENT_VIOLATIONS violation(s) last session"
MSG="$MSG | /ais:health for full report"

jq -n --arg m "$MSG" '{"systemMessage": $m}'
