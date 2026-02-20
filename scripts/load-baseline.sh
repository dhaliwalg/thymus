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

# Baseline exists — output a compact summary
MODULE_COUNT=$(jq '.modules | length' "$BASELINE" 2>/dev/null || echo "0")
INVARIANT_COUNT=0
INVARIANTS_FILE="$AIS_DIR/invariants.yml"
if [ -f "$INVARIANTS_FILE" ]; then
  INVARIANT_COUNT=$(grep -c "^  - id:" "$INVARIANTS_FILE" 2>/dev/null || echo "0")
fi

echo "[$TIMESTAMP] Baseline found — $MODULE_COUNT modules, $INVARIANT_COUNT invariants" >> "$DEBUG_LOG"

cat <<EOF
{
  "systemMessage": "📊 AIS Active | $MODULE_COUNT modules | $INVARIANT_COUNT invariants enforced | Run /ais:health for full report"
}
EOF
