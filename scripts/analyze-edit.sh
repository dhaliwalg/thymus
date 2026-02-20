#!/usr/bin/env bash
set -euo pipefail

# AIS PostToolUse hook — analyze-edit.sh
# Receives tool input JSON via stdin. In Phase 0: logs only.
# Phase 2 will add real invariant checking against .ais/invariants.yml

DEBUG_LOG="/tmp/ais-debug.log"
TIMESTAMP=$(date '+%Y-%m-%dT%H:%M:%S')

input=$(cat)
file_path=$(echo "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null || echo "unknown")
tool_name=$(echo "$input" | jq -r '.tool_name // "unknown"' 2>/dev/null || echo "unknown")

echo "[$TIMESTAMP] analyze-edit.sh: $tool_name on $file_path" >> "$DEBUG_LOG"

# Phase 0: no violations to report — output nothing
exit 0
