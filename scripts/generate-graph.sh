#!/usr/bin/env bash
set -euo pipefail

# Thymus generate-graph.sh — Dependency graph visualization
# Usage: bash generate-graph.sh [--output /path/to/output.html]
# Output: writes .thymus/graph.html (or custom path), prints path to stdout

DEBUG_LOG="/tmp/thymus-debug.log"
TIMESTAMP=$(date '+%Y-%m-%dT%H:%M:%S')
THYMUS_DIR="$PWD/.thymus"
INVARIANTS_YML="$THYMUS_DIR/invariants.yml"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
TEMPLATE_DIR="$(cd "$SCRIPT_DIR/../templates" && pwd)"
TEMPLATE="$TEMPLATE_DIR/graph.html"

OUTPUT_FILE=""

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output) OUTPUT_FILE="$2"; shift 2 ;;
    *) shift ;;
  esac
done

# Default output path
if [ -z "$OUTPUT_FILE" ]; then
  mkdir -p "$THYMUS_DIR"
  OUTPUT_FILE="$THYMUS_DIR/graph.html"
fi

echo "[$TIMESTAMP] generate-graph.sh: output=$OUTPUT_FILE" >> "$DEBUG_LOG"

# --- Verify template exists ---
if [ ! -f "$TEMPLATE" ]; then
  echo "Thymus: graph template not found at $TEMPLATE" >&2
  exit 1
fi

# --- Build file list (same extensions and ignored paths as scan-project.sh) ---
declare -a FILES=()
while IFS= read -r f; do
  [ -n "$f" ] && FILES+=("$f")
done < <(find_source_files)

file_count=${#FILES[@]}
echo "[$TIMESTAMP] generate-graph: found $file_count source files" >> "$DEBUG_LOG"

# --- Empty project: write template with empty data, exit 0 ---
if [ "$file_count" -eq 0 ]; then
  echo "[$TIMESTAMP] generate-graph: empty project, writing empty graph" >> "$DEBUG_LOG"
  EMPTY_DATA='{"modules":[],"edges":[]}'
  python3 -c "
import sys, json
template = open('$TEMPLATE').read()
data = json.loads(sys.stdin.read())
output = template.replace('/*GRAPH_DATA*/{\"modules\":[],\"edges\":[]}', json.dumps(data))
with open('$OUTPUT_FILE', 'w') as f:
    f.write(output)
" <<< "$EMPTY_DATA"
  echo "$OUTPUT_FILE"
  exit 0
fi

# --- Extract imports from each file ---
IMPORT_ENTRIES=$(printf '%s\n' "${FILES[@]}" | build_import_entries)

echo "[$TIMESTAMP] generate-graph: extracted imports from $file_count files" >> "$DEBUG_LOG"

# --- Optionally run scan-project.sh for violation data ---
VIOLATIONS_FLAG=""
SCAN_TMPFILE=""
if [ -f "$INVARIANTS_YML" ]; then
  SCAN_TMPFILE=$(mktemp /tmp/thymus-graph-scan-XXXXXX.json)
  if bash "${SCRIPT_DIR}/scan-project.sh" > "$SCAN_TMPFILE" 2>/dev/null; then
    VIOLATIONS_FLAG="--violations $SCAN_TMPFILE"
    echo "[$TIMESTAMP] generate-graph: violation scan succeeded" >> "$DEBUG_LOG"
  else
    echo "[$TIMESTAMP] generate-graph: violation scan failed, continuing without" >> "$DEBUG_LOG"
    rm -f "$SCAN_TMPFILE"
    SCAN_TMPFILE=""
  fi
else
  echo "[$TIMESTAMP] generate-graph: no invariants.yml, skipping violation scan" >> "$DEBUG_LOG"
fi

# --- Build adjacency graph ---
# shellcheck disable=SC2086
GRAPH_JSON=$(echo "$IMPORT_ENTRIES" | python3 "${SCRIPT_DIR}/build-adjacency.py" $VIOLATIONS_FLAG)

echo "[$TIMESTAMP] generate-graph: adjacency graph built" >> "$DEBUG_LOG"

# --- Inject graph data into template ---
# Ensure output directory exists
mkdir -p "$(dirname "$OUTPUT_FILE")"

python3 -c "
import sys, json
template = open('$TEMPLATE').read()
data = json.loads(sys.stdin.read())
output = template.replace('/*GRAPH_DATA*/{\"modules\":[],\"edges\":[]}', json.dumps(data))
with open('$OUTPUT_FILE', 'w') as f:
    f.write(output)
" <<< "$GRAPH_JSON"

echo "[$TIMESTAMP] generate-graph: wrote $OUTPUT_FILE" >> "$DEBUG_LOG"

# --- Clean up temp files ---
if [ -n "$SCAN_TMPFILE" ] && [ -f "$SCAN_TMPFILE" ]; then
  rm -f "$SCAN_TMPFILE"
fi

# --- Print output path ---
echo "$OUTPUT_FILE"

# --- Attempt to open in browser (don't fail if unavailable) ---
if [ -z "${THYMUS_NO_OPEN:-}" ]; then
  open "$OUTPUT_FILE" 2>/dev/null || xdg-open "$OUTPUT_FILE" 2>/dev/null || true
fi
