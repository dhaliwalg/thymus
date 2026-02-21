#!/usr/bin/env bash
set -euo pipefail

# SessionStart hook: inject a compact baseline summary

DEBUG_LOG="/tmp/thymus-debug.log"
THYMUS_DIR="$PWD/.thymus"
BASELINE="$THYMUS_DIR/baseline.json"
TIMESTAMP=$(date '+%Y-%m-%dT%H:%M:%S')

echo "[$TIMESTAMP] load-baseline.sh fired in $PWD" >> "$DEBUG_LOG"

# Auto-add .thymus/ to .gitignore if it's a git repo and not already ignored
if [ -d "$THYMUS_DIR" ] && [ -d "$PWD/.git" ]; then
  GITIGNORE="$PWD/.gitignore"
  if [ ! -f "$GITIGNORE" ] || ! grep -qE '^\.thymus/?$' "$GITIGNORE" 2>/dev/null; then
    echo '.thymus/' >> "$GITIGNORE"
    echo "[$TIMESTAMP] added .thymus/ to .gitignore" >> "$DEBUG_LOG"
  fi
fi

if [ ! -f "$BASELINE" ]; then
  jq -n '{"systemMessage": "thymus: no baseline found — run /thymus:baseline to initialize"}'
  exit 0
fi

MODULE_COUNT=$(jq '.modules | length' "$BASELINE" 2>/dev/null || echo "0")
INVARIANT_COUNT=0
if [ -f "$THYMUS_DIR/invariants.yml" ]; then
  INVARIANT_COUNT=$(grep -c "^  - id:" "$THYMUS_DIR/invariants.yml" 2>/dev/null || echo "0")
fi

RECENT_VIOLATIONS=0
if [ -d "$THYMUS_DIR/history" ]; then
  LAST_SNAPSHOT=$(find "$THYMUS_DIR/history" -name "*.json" -type f | sort | tail -1)
  if [ -n "$LAST_SNAPSHOT" ]; then
    RECENT_VIOLATIONS=$(jq '.violations | length' "$LAST_SNAPSHOT" 2>/dev/null || echo "0")
  fi
fi

echo "[$TIMESTAMP] baseline: $MODULE_COUNT modules, $INVARIANT_COUNT invariants, $RECENT_VIOLATIONS recent violations" >> "$DEBUG_LOG"

MSG="thymus: $MODULE_COUNT modules | $INVARIANT_COUNT invariants active"
[ "$RECENT_VIOLATIONS" -gt 0 ] && MSG="$MSG | $RECENT_VIOLATIONS violation(s) last session"
MSG="$MSG | /thymus:health for full report"

jq -n --arg m "$MSG" '{"systemMessage": $m}'
