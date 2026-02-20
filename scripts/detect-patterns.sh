#!/usr/bin/env bash
set -euo pipefail

# AIS detect-patterns.sh
# Scans a project directory and outputs structural data as JSON.
# Usage: bash detect-patterns.sh [project_root]
# Output: JSON to stdout

PROJECT_ROOT="${1:-$PWD}"
DEBUG_LOG="/tmp/ais-debug.log"
TIMESTAMP=$(date '+%Y-%m-%dT%H:%M:%S')

# Load ignored paths
IGNORED_PATHS=("node_modules" "dist" ".next" ".git" "coverage" "__pycache__" ".venv" "vendor" "target" "build")
IGNORED_FIND_ARGS=()
for p in "${IGNORED_PATHS[@]}"; do
  IGNORED_FIND_ARGS+=(-not -path "*/$p/*" -not -name "$p")
done

echo "[$TIMESTAMP] detect-patterns.sh scanning $PROJECT_ROOT" >> "$DEBUG_LOG"

# --- raw_structure: directory tree depth 3 ---
raw_structure=$(find "$PROJECT_ROOT" -maxdepth 3 -type d \
  "${IGNORED_FIND_ARGS[@]}" \
  | sed "s|$PROJECT_ROOT/||" \
  | grep -v "^${PROJECT_ROOT}$" \
  | grep -v "^$" \
  | sort \
  | jq -R . | jq -s .)

# --- detected_layers: dirs matching known layer names ---
KNOWN_LAYERS=("routes" "controllers" "services" "repositories" "models" "middleware" "utils" "lib" "helpers" "types" "handlers" "resolvers" "stores" "hooks" "components" "pages" "app" "api" "db" "database" "config" "auth" "tests" "test" "__tests__")

detected_layers=$(
  for layer in "${KNOWN_LAYERS[@]}"; do
    if find "$PROJECT_ROOT" -maxdepth 4 -type d -name "$layer" \
      "${IGNORED_FIND_ARGS[@]}" 2>/dev/null | grep -q .; then
      echo "$layer"
    fi
  done | jq -R . | jq -s .
)

# --- naming_patterns: multi-part file extensions found (e.g. .service.ts) ---
naming_patterns=$(
  find "$PROJECT_ROOT" -type f \( -name "*.ts" -o -name "*.js" -o -name "*.py" \) \
    "${IGNORED_FIND_ARGS[@]}" 2>/dev/null \
  | while read -r f; do basename "$f"; done \
  | grep -oE '\.[a-z]+\.[a-z]+$' \
  | sort | uniq -c | sort -rn \
  | awk '{print $2}' \
  | head -20 \
  | jq -R . | jq -s .
)

# --- test_gaps: source files without a colocated test file ---
test_gaps=$(
  find "$PROJECT_ROOT" -type f \( -name "*.ts" -o -name "*.js" -o -name "*.py" \) \
    "${IGNORED_FIND_ARGS[@]}" \
    ! -name "*.test.*" ! -name "*.spec.*" ! -name "*.d.ts" 2>/dev/null \
  | while read -r src_file; do
      base="${src_file%.*}"
      ext="${src_file##*.}"
      if ! { [ -f "${base}.test.${ext}" ] || [ -f "${base}.spec.${ext}" ]; }; then
        echo "$src_file" | sed "s|$PROJECT_ROOT/||"
      fi
    done \
  | jq -R . | jq -s .
)

# --- file_counts: per top-level directory ---
file_counts=$(
  find "$PROJECT_ROOT" -maxdepth 1 -mindepth 1 -type d \
    "${IGNORED_FIND_ARGS[@]}" \
  | while read -r dir; do
      name=$(basename "$dir")
      count=$(find "$dir" -type f "${IGNORED_FIND_ARGS[@]}" 2>/dev/null | wc -l | tr -d ' ')
      printf '{"dir":"%s","count":%s}' "$name" "$count"
    done \
  | jq -s .
)

# --- Output combined JSON ---
jq -n \
  --argjson raw_structure "$raw_structure" \
  --argjson detected_layers "$detected_layers" \
  --argjson naming_patterns "$naming_patterns" \
  --argjson test_gaps "$test_gaps" \
  --argjson file_counts "$file_counts" \
  '{
    raw_structure: $raw_structure,
    detected_layers: $detected_layers,
    naming_patterns: $naming_patterns,
    test_gaps: $test_gaps,
    file_counts: $file_counts
  }'
