#!/usr/bin/env bash
set -euo pipefail

# Atomically appends a scan snapshot to .thymus/history.jsonl
# Usage:
#   bash append-history.sh --scan /path/to/scan.json
#   echo '<scan-json>' | bash append-history.sh --stdin

DEBUG_LOG="/tmp/thymus-debug.log"
TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
THYMUS_DIR="$PWD/.thymus"
HISTORY_FILE="$THYMUS_DIR/history.jsonl"
FIFO_CAP=500

echo "[$TIMESTAMP] append-history.sh: start" >> "$DEBUG_LOG"

# --- Parse arguments ---
MODE=""
SCAN_FILE=""
for arg in "$@"; do
  case "$arg" in
    --stdin) MODE="stdin" ;;
    --scan)  MODE="scan" ;;
    *)
      if [ "$MODE" = "scan" ] && [ -z "$SCAN_FILE" ]; then
        SCAN_FILE="$arg"
      fi
      ;;
  esac
done

if [ -z "$MODE" ]; then
  echo "Usage: append-history.sh --scan <file> | --stdin" >&2
  exit 1
fi

# --- Read scan JSON ---
if [ "$MODE" = "stdin" ]; then
  SCAN_JSON=$(cat)
elif [ "$MODE" = "scan" ]; then
  if [ -z "$SCAN_FILE" ] || [ ! -f "$SCAN_FILE" ]; then
    echo "append-history.sh: scan file not found: ${SCAN_FILE:-<none>}" >&2
    exit 1
  fi
  SCAN_JSON=$(cat "$SCAN_FILE")
else
  echo "append-history.sh: unknown mode" >&2
  exit 1
fi

echo "[$TIMESTAMP] append-history.sh: read scan JSON (${#SCAN_JSON} bytes)" >> "$DEBUG_LOG"

# --- Extract fields from scan JSON ---
files_checked=$(echo "$SCAN_JSON" | jq -r '.files_checked // 0')
error_count=$(echo "$SCAN_JSON" | jq '[.violations[] | select(.severity=="error")] | length')
warn_count=$(echo "$SCAN_JSON" | jq '[.violations[] | select(.severity=="warning")] | length')
info_count=$(echo "$SCAN_JSON" | jq '[.violations[] | select(.severity=="info")] | length')
total_files=$(echo "$SCAN_JSON" | jq -r '.files_checked // 0')

# --- Compliance score: ((files_checked - error_count) / files_checked) * 100 ---
compliance_score=$(awk -v fc="$files_checked" -v ec="$error_count" \
  'BEGIN { if (fc == 0) printf "%.1f", 100.0; else printf "%.1f", ((fc - ec) / fc) * 100 }')

# --- Per-rule violation counts ---
by_rule=$(echo "$SCAN_JSON" | jq '[.violations[].rule] | group_by(.) | map({(.[0]): length}) | add // {}')

# --- Git commit hash ---
commit=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")

# --- Build JSONL line ---
JSONL_LINE=$(jq -cn \
  --arg ts "$TIMESTAMP" \
  --arg commit "$commit" \
  --argjson total_files "$total_files" \
  --argjson files_checked "$files_checked" \
  --argjson error "$error_count" \
  --argjson warn "$warn_count" \
  --argjson info "$info_count" \
  --argjson compliance "$compliance_score" \
  --argjson by_rule "$by_rule" \
  '{
    timestamp: $ts,
    commit: $commit,
    total_files: $total_files,
    files_checked: $files_checked,
    violations: { error: $error, warn: $warn, info: $info },
    compliance_score: $compliance,
    by_rule: $by_rule
  }')

echo "[$TIMESTAMP] append-history.sh: compliance=$compliance_score commit=$commit" >> "$DEBUG_LOG"

# --- Ensure .thymus directory exists ---
mkdir -p "$THYMUS_DIR"

# --- Atomic append with FIFO cap ---
TMP_FILE=$(mktemp "$THYMUS_DIR/.history.jsonl.XXXXXX")

{
  if [ -f "$HISTORY_FILE" ]; then
    # Read existing entries, append new line, keep newest FIFO_CAP
    cat "$HISTORY_FILE"
  fi
  echo "$JSONL_LINE"
} | tail -n "$FIFO_CAP" > "$TMP_FILE"

mv "$TMP_FILE" "$HISTORY_FILE"

entry_count=$(wc -l < "$HISTORY_FILE" | tr -d ' ')
echo "[$TIMESTAMP] append-history.sh: appended (total entries: $entry_count)" >> "$DEBUG_LOG"
