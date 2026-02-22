#!/usr/bin/env bash
set -euo pipefail

# Thymus infer-rules.sh — Auto-infer boundary rules from import patterns
# Usage: bash infer-rules.sh [--min-confidence 90] [--apply]

DEBUG_LOG="/tmp/thymus-debug.log"
TIMESTAMP=$(date '+%Y-%m-%dT%H:%M:%S')
THYMUS_DIR="$PWD/.thymus"
INVARIANTS_YML="$THYMUS_DIR/invariants.yml"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

MIN_CONFIDENCE=90
APPLY=false

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --min-confidence) MIN_CONFIDENCE="$2"; shift 2 ;;
    --apply) APPLY=true; shift ;;
    *) shift ;;
  esac
done

echo "[$TIMESTAMP] infer-rules.sh: min_confidence=$MIN_CONFIDENCE apply=$APPLY" >> "$DEBUG_LOG"

# --- Validate --apply prerequisites ---
if [ "$APPLY" = true ] && [ ! -f "$INVARIANTS_YML" ]; then
  echo "Error: --apply requires .thymus/invariants.yml to exist. Run 'thymus init' first." >&2
  exit 1
fi

# --- Build file list (same extensions and ignored paths as scan-project.sh / generate-graph.sh) ---
declare -a FILES=()
while IFS= read -r f; do
  [ -n "$f" ] && FILES+=("$f")
done < <(find_source_files)

file_count=${#FILES[@]}
echo "[$TIMESTAMP] infer-rules: found $file_count source files" >> "$DEBUG_LOG"

# --- Empty project ---
if [ "$file_count" -eq 0 ]; then
  echo "# No source files found to analyze"
  echo "[$TIMESTAMP] infer-rules: empty project, exiting" >> "$DEBUG_LOG"
  exit 0
fi

# --- Extract imports from each file ---
IMPORT_ENTRIES=$(printf '%s\n' "${FILES[@]}" | build_import_entries)

echo "[$TIMESTAMP] infer-rules: extracted imports from $file_count files" >> "$DEBUG_LOG"

# --- Build adjacency graph ---
GRAPH_JSON=$(echo "$IMPORT_ENTRIES" | python3 "${SCRIPT_DIR}/build-adjacency.py")

echo "[$TIMESTAMP] infer-rules: adjacency graph built" >> "$DEBUG_LOG"

# --- Run analyze-graph.py to infer rules ---
RULES_YAML=$(echo "$GRAPH_JSON" | python3 "${SCRIPT_DIR}/analyze-graph.py" --min-confidence "$MIN_CONFIDENCE")

echo "[$TIMESTAMP] infer-rules: inference complete" >> "$DEBUG_LOG"

# --- Output or apply ---
if [ "$APPLY" = true ]; then
  # Strip comment lines (starting with #) and empty lines, then append
  RULES_TO_APPEND=$(echo "$RULES_YAML" | grep -v '^#' | grep -v '^$' || true)

  if [ -z "$RULES_TO_APPEND" ]; then
    echo "# No rules inferred above confidence threshold — nothing to apply"
    exit 0
  fi

  # Append a blank line separator then the rules
  printf '\n%s\n' "$RULES_TO_APPEND" >> "$INVARIANTS_YML"
  echo "[$TIMESTAMP] infer-rules: appended rules to $INVARIANTS_YML" >> "$DEBUG_LOG"

  # Also print the full output (with comments) so the user sees what was inferred
  echo "$RULES_YAML"
else
  echo "$RULES_YAML"
fi
