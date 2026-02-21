#!/usr/bin/env bash
set -euo pipefail

# AIS refresh-baseline.sh
# Re-scans the project structure and diffs against the existing baseline.json.
# Outputs JSON: { new_directories, removed_directories, new_file_types, baseline_module_count }
# Used by /ais:baseline --refresh to propose new invariants.

AIS_DIR="$PWD/.ais"
BASELINE="$AIS_DIR/baseline.json"

if [ ! -f "$BASELINE" ]; then
  echo '{"error":"No baseline.json found. Run /ais:baseline first.","new_directories":[]}'
  exit 0
fi

IGNORED=("node_modules" "dist" ".next" ".git" "coverage" "__pycache__" ".venv" "vendor" "target" "build" ".ais")
IGNORED_ARGS=()
for p in "${IGNORED[@]}"; do
  IGNORED_ARGS+=(-not -path "*/$p" -not -path "*/$p/*")
done

# Scan current directory structure (top 3 levels)
CURRENT_DIRS=$(find "$PWD" -mindepth 1 -maxdepth 3 -type d \
  "${IGNORED_ARGS[@]}" 2>/dev/null \
  | sed "s|$PWD/||" | sort)

# Get baseline module paths
BASELINE_PATHS=$(jq -r '.modules[].path // empty' "$BASELINE" 2>/dev/null | sort || true)

# New directories: in current scan but not represented in baseline modules
NEW_DIRS=()
while IFS= read -r dir; do
  [ -z "$dir" ] && continue
  # Only flag direct src subdirs (depth 2: src/something)
  depth=$(echo "$dir" | tr -cd '/' | wc -c | tr -d ' ')
  [ "$depth" -ne 1 ] && continue
  # Check if this path appears in baseline modules
  if ! echo "$BASELINE_PATHS" | grep -q "^${dir}$"; then
    NEW_DIRS+=("$dir")
  fi
done <<< "$CURRENT_DIRS"

# Removed directories: in baseline but no longer present
REMOVED_DIRS=()
while IFS= read -r bpath; do
  [ -z "$bpath" ] && continue
  if [ ! -d "$PWD/$bpath" ]; then
    REMOVED_DIRS+=("$bpath")
  fi
done <<< "$BASELINE_PATHS"

# Detect file types present in new directories
NEW_FILE_TYPES=()
for dir in "${NEW_DIRS[@]+"${NEW_DIRS[@]}"}"; do
  TYPES=$(find "$PWD/$dir" -type f 2>/dev/null \
    | grep -oE '\.[^./]+$' | sort -u | tr '\n' ',' | sed 's/,$//' || true)
  [ -n "$TYPES" ] && NEW_FILE_TYPES+=("${dir}:${TYPES}")
done

# Serialize arrays to JSON
NEW_DIRS_JSON=$(printf '%s\n' "${NEW_DIRS[@]+"${NEW_DIRS[@]}"}" | jq -R . | jq -s '.')
REMOVED_DIRS_JSON=$(printf '%s\n' "${REMOVED_DIRS[@]+"${REMOVED_DIRS[@]}"}" | jq -R . | jq -s '.')
NEW_FILE_TYPES_JSON=$(printf '%s\n' "${NEW_FILE_TYPES[@]+"${NEW_FILE_TYPES[@]}"}" | jq -R . | jq -s '.')

BASELINE_MODULE_COUNT=$(jq '.modules | length' "$BASELINE" 2>/dev/null || echo 0)

jq -n \
  --argjson new_dirs "$NEW_DIRS_JSON" \
  --argjson removed_dirs "$REMOVED_DIRS_JSON" \
  --argjson new_file_types "$NEW_FILE_TYPES_JSON" \
  --argjson baseline_module_count "$BASELINE_MODULE_COUNT" \
  '{
    new_directories: $new_dirs,
    removed_directories: $removed_dirs,
    new_file_types: $new_file_types,
    baseline_module_count: $baseline_module_count
  }'
