#!/usr/bin/env bash
set -euo pipefail

# Thymus scan-project.sh — batch invariant checker
# Usage: bash scan-project.sh [scope_path] [--diff]
# Output: JSON { violations: [...], stats: {...}, scope: "..." }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/eval-rules.sh"

THYMUS_DIR="$PWD/.thymus"
INVARIANTS_YML="$THYMUS_DIR/invariants.yml"

SCOPE=""
DIFF_MODE=false
for arg in "$@"; do
  case "$arg" in
    --diff) DIFF_MODE=true ;;
    *) [ -z "$SCOPE" ] && SCOPE="$arg" ;;
  esac
done

echo "[$TIMESTAMP] scan-project.sh: scope=${SCOPE:-full} diff=$DIFF_MODE" >> "$DEBUG_LOG"

if [ ! -f "$INVARIANTS_YML" ]; then
  echo '{"error":"No invariants.yml found. Run /thymus:baseline first.","violations":[],"stats":{"total":0,"errors":0,"warnings":0}}'
  exit 0
fi

CACHE_DIR=$(thymus_cache_dir)

INVARIANTS_JSON=$(load_invariants "$INVARIANTS_YML" "$CACHE_DIR/invariants-scan.json") || {
  echo '{"error":"Failed to parse invariants.yml","violations":[],"stats":{"total":0,"errors":0,"warnings":0}}'
  exit 0
}

# --- Build file list ---
declare -a FILES=()
if $DIFF_MODE; then
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ -n "$SCOPE" ] && [[ ! "$f" == "$SCOPE"* ]]; then
      continue
    fi
    FILES+=("$f")
  done < <(git diff --name-only HEAD 2>/dev/null | grep -v '^$' || true)
else
  SCAN_ROOT="$PWD"
  [ -n "$SCOPE" ] && SCAN_ROOT="$PWD/$SCOPE"
  while IFS= read -r f; do
    [ -n "$f" ] && FILES+=("$f")
  done < <(find_source_files "$SCAN_ROOT")
fi

files_checked=${#FILES[@]}
echo "[$TIMESTAMP] scan-project: checking $files_checked files" >> "$DEBUG_LOG"

if [ "$files_checked" -eq 0 ]; then
  jq -n --arg scope "${SCOPE:-}" \
    '{"scope":$scope,"files_checked":0,"violations":[],"stats":{"total":0,"errors":0,"warnings":0}}'
  exit 0
fi

# --- Evaluate rules ---
violation_objects=()

invariant_count=$(jq '.invariants | length' "$INVARIANTS_JSON" 2>/dev/null || echo 0)

for rel_path in "${FILES[@]}"; do
  abs_path="$PWD/$rel_path"
  [ -f "$abs_path" ] || continue

  for ((i=0; i<invariant_count; i++)); do
    inv=$(jq ".invariants[$i]" "$INVARIANTS_JSON")

    while IFS= read -r viol_json; do
      [ -z "$viol_json" ] && continue
      violation_objects+=("$viol_json")
    done < <(eval_rule_for_file "$abs_path" "$rel_path" "$inv")
  done
done

# --- Serialize ---
if [ "${#violation_objects[@]}" -eq 0 ]; then
  VIOLATIONS="[]"
else
  VIOLATIONS=$(printf '%s\n' "${violation_objects[@]}" | jq -s '.')
fi

total=$(echo "$VIOLATIONS" | jq 'length')
errors=$(echo "$VIOLATIONS" | jq '[.[] | select(.severity=="error")] | length')
warnings=$(echo "$VIOLATIONS" | jq '[.[] | select(.severity=="warning")] | length')

jq -n \
  --arg scope "${SCOPE:-}" \
  --argjson files_checked "$files_checked" \
  --argjson violations "$VIOLATIONS" \
  --argjson total "$total" \
  --argjson errors "$errors" \
  --argjson warnings "$warnings" \
  '{
    scope: $scope,
    files_checked: $files_checked,
    violations: $violations,
    stats: {
      total: $total,
      errors: $errors,
      warnings: $warnings
    }
  }'
