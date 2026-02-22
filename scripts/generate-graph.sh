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
IGNORED_PATHS=("node_modules" "dist" ".next" ".git" "coverage" "__pycache__" ".venv" "vendor" "target" "build" ".thymus")
IGNORED_ARGS=()
for p in "${IGNORED_PATHS[@]}"; do
  IGNORED_ARGS+=(-not -path "*/$p/*" -not -name "$p")
done

declare -a FILES=()
while IFS= read -r f; do
  [ -n "$f" ] && FILES+=("$(echo "$f" | sed "s|$PWD/||")")
done < <(find "$PWD" -type f \( -name "*.ts" -o -name "*.js" -o -name "*.py" -o -name "*.java" -o -name "*.go" -o -name "*.rs" -o -name "*.dart" -o -name "*.kt" -o -name "*.kts" -o -name "*.swift" -o -name "*.cs" -o -name "*.php" -o -name "*.rb" \) \
  "${IGNORED_ARGS[@]}" 2>/dev/null | sort)

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
IMPORT_ENTRIES="["
first=true
for rel_path in "${FILES[@]}"; do
  abs_path="$PWD/$rel_path"
  [ -f "$abs_path" ] || continue

  # Run extract-imports.py, collect one import per line
  imports_raw=$(python3 "${SCRIPT_DIR}/extract-imports.py" "$abs_path" 2>/dev/null || true)

  # Build JSON array of imports
  imports_json="[]"
  if [ -n "$imports_raw" ]; then
    imports_json=$(printf '%s\n' "$imports_raw" | jq -R '.' | jq -s '.')
  fi

  if [ "$first" = true ]; then
    first=false
  else
    IMPORT_ENTRIES+=","
  fi
  IMPORT_ENTRIES+=$(jq -n --arg file "$rel_path" --argjson imports "$imports_json" \
    '{"file":$file,"imports":$imports}')
done
IMPORT_ENTRIES+="]"

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
open "$OUTPUT_FILE" 2>/dev/null || xdg-open "$OUTPUT_FILE" 2>/dev/null || true
