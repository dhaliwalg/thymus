#!/usr/bin/env bash
set -euo pipefail

# AIS Stop hook — session-report.sh
# Fires at end of every Claude session. In Phase 0: logs only.
# Phase 2 will aggregate violations and compute health score delta.

DEBUG_LOG="/tmp/ais-debug.log"
TIMESTAMP=$(date '+%Y-%m-%dT%H:%M:%S')

input=$(cat)
session_id=$(echo "$input" | jq -r '.session_id // "unknown"' 2>/dev/null || echo "unknown")

echo "[$TIMESTAMP] session-report.sh: session $session_id ended" >> "$DEBUG_LOG"

# Phase 0: silent exit — no summary yet
exit 0
