#!/usr/bin/env bash
set -euo pipefail

# AIS SessionStart hook — load-baseline.sh
# Injects a compact baseline summary into Claude's context at session start.
# Output: JSON systemMessage (< 500 tokens)

DEBUG_LOG="/tmp/ais-debug.log"
AIS_DIR="$PWD/.ais"
BASELINE="$AIS_DIR/baseline.json"
TIMESTAMP=$(date '+%Y-%m-%dT%H:%M:%S')

echo "[$TIMESTAMP] load-baseline.sh fired in $PWD" >> "$DEBUG_LOG"

if [ ! -f "$BASELINE" ]; then
  echo "[$TIMESTAMP] No baseline found — outputting setup prompt" >> "$DEBUG_LOG"
  cat <<'EOF'
{
  "systemMessage": "📊 AIS: No baseline detected for this project. Run /ais:baseline to initialize architectural monitoring."
}
EOF
  exit 0
fi

# Baseline exists — compute compact summary
MODULE_COUNT=$(jq '.modules | length' "$BASELINE" 2>/dev/null || echo "0")
INVARIANT_COUNT=0
if [ -f "$AIS_DIR/invariants.json" ]; then
  INVARIANT_COUNT=$(jq '.invariants | length' "$AIS_DIR/invariants.json" 2>/dev/null || echo "0")
elif [ -f "$AIS_DIR/invariants.yml" ]; then
  INVARIANT_COUNT=$(grep -c "^  - id:" "$AIS_DIR/invariants.yml" 2>/dev/null || echo "0")
fi

# Count recent violations from last history snapshot
RECENT_VIOLATIONS=0
HISTORY_DIR="$AIS_DIR/history"
if [ -d "$HISTORY_DIR" ]; then
  LAST_SNAPSHOT=$(find "$HISTORY_DIR" -name "*.json" -type f | sort | tail -1)
  if [ -n "$LAST_SNAPSHOT" ]; then
    RECENT_VIOLATIONS=$(jq '.violations | length' "$LAST_SNAPSHOT" 2>/dev/null || echo "0")
  fi
fi

echo "[$TIMESTAMP] Baseline: $MODULE_COUNT modules, $INVARIANT_COUNT invariants, $RECENT_VIOLATIONS recent violations" >> "$DEBUG_LOG"

# Build compact message (< 500 tokens)
if [ "$RECENT_VIOLATIONS" -gt 0 ]; then
  STATUS="⚠️ AIS Active"
  VIOLATION_NOTE=" | $RECENT_VIOLATIONS violation(s) last session"
else
  STATUS="✅ AIS Active"
  VIOLATION_NOTE=""
fi

cat <<EOF
{
  "systemMessage": "$STATUS | $MODULE_COUNT modules | $INVARIANT_COUNT invariants enforced$VIOLATION_NOTE | Run /ais:health for full report"
}
EOF
