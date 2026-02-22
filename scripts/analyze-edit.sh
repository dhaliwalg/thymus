#!/usr/bin/env bash
set -euo pipefail

# PostToolUse hook: check edited file against invariants
# never exits with code 2 — warns but doesn't block

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/eval-rules.sh"

input=$(cat)
file_path=$(echo "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)
tool_name=$(echo "$input" | jq -r '.tool_name // "unknown"' 2>/dev/null || true)

echo "[$TIMESTAMP] analyze-edit.sh: $tool_name on ${file_path:-unknown}" >> "$DEBUG_LOG"

[ -z "$file_path" ] && exit 0

[ -L "$file_path" ] && exit 0

if [ -f "$file_path" ]; then
  file_type=$(file -b "$file_path" 2>/dev/null || true)
  case "$file_type" in
    *text*|*JSON*|*XML*|*HTML*|*script*|*empty*) : ;;
    *) exit 0 ;;
  esac
fi

if [ -f "$file_path" ]; then
  file_size=$(wc -c < "$file_path" 2>/dev/null || echo 0)
  [ "$file_size" -gt 512000 ] && exit 0
fi

THYMUS_DIR="$PWD/.thymus"
INVARIANTS_YML="$THYMUS_DIR/invariants.yml"

[ -f "$INVARIANTS_YML" ] || exit 0

CACHE_DIR=$(thymus_cache_dir)
SESSION_VIOLATIONS="$CACHE_DIR/session-violations.json"
[ -f "$SESSION_VIOLATIONS" ] || echo "[]" > "$SESSION_VIOLATIONS"

INVARIANTS_JSON=$(load_invariants "$INVARIANTS_YML" "$CACHE_DIR/invariants.json") || exit 0

REL_PATH="${file_path#"$PWD"/}"
[ "$REL_PATH" = "$file_path" ] && REL_PATH=$(basename "$file_path")

echo "[$TIMESTAMP] checking $REL_PATH" >> "$DEBUG_LOG"

violation_lines=()
new_violation_objects=()

invariant_count=$(jq '.invariants | length' "$INVARIANTS_JSON" 2>/dev/null || echo 0)

for ((i=0; i<invariant_count; i++)); do
  inv=$(jq ".invariants[$i]" "$INVARIANTS_JSON")
  rule_id=$(echo "$inv" | jq -r '.id')

  echo "[$TIMESTAMP]   rule $rule_id ($(echo "$inv" | jq -r '.type')) vs $REL_PATH" >> "$DEBUG_LOG"

  # Collect violations from shared evaluator
  while IFS= read -r viol_json; do
    [ -z "$viol_json" ] && continue
    severity=$(echo "$viol_json" | jq -r '.severity')
    SEV_UPPER=$(echo "$severity" | tr '[:lower:]' '[:upper:]')
    msg_detail=$(echo "$viol_json" | jq -r 'if .import then "(import: " + .import + ")" elif .line then "(line " + .line + ")" elif .package then "(package: " + .package + ")" else "" end')
    description=$(echo "$viol_json" | jq -r '.message')
    msg="[$SEV_UPPER] $rule_id: $description $msg_detail"
    violation_lines+=("$msg")
    new_violation_objects+=("$viol_json")
  done < <(eval_rule_for_file "$file_path" "$REL_PATH" "$inv")
done

echo "[$TIMESTAMP] found ${#violation_lines[@]} violations in $REL_PATH" >> "$DEBUG_LOG"

# calibration: track fix/ignore events for previously-violated rules
CALIBRATION_FILE="$THYMUS_DIR/calibration.json"
[ -f "$CALIBRATION_FILE" ] || echo '{"rules":{}}' > "$CALIBRATION_FILE"

PREV_RULES=$(jq -r --arg f "$REL_PATH" '[.[] | select(.file == $f) | .rule] | unique[]' "$SESSION_VIOLATIONS" 2>/dev/null || true)
CURR_RULES=$(printf '%s\n' "${new_violation_objects[@]}" \
  | jq -r '.rule' 2>/dev/null | sort -u || true)

CAL_EVENTS=()
while IFS= read -r prev_rule; do
  [ -z "$prev_rule" ] && continue
  if echo "$CURR_RULES" | grep -q "^${prev_rule}$"; then
    CAL_EVENTS+=("${prev_rule}:ignored")
  else
    CAL_EVENTS+=("${prev_rule}:fixed")
  fi
done <<< "${PREV_RULES:-}"

if [ "${#CAL_EVENTS[@]}" -gt 0 ]; then
  CAL_PY=$(mktemp /tmp/thymus-cal-XXXXXX.py)
  trap 'rm -f "$CAL_PY"' EXIT
  cat > "$CAL_PY" << 'ENDPY'
import sys, json
cal_file = sys.argv[1]
events = [e.split(':', 1) for e in sys.argv[2:]]
with open(cal_file) as fp:
    data = json.load(fp)
rules_map = data.setdefault('rules', {})
for rule, event in events:
    r = rules_map.setdefault(rule, {'fixed': 0, 'ignored': 0})
    r[event] = r.get(event, 0) + 1
with open(cal_file, 'w') as fp:
    json.dump(data, fp)
ENDPY
  python3 "$CAL_PY" "$CALIBRATION_FILE" "${CAL_EVENTS[@]}" 2>/dev/null || true
  rm -f "$CAL_PY"
  trap - EXIT
fi

[ ${#violation_lines[@]} -eq 0 ] && exit 0

ALL_NEW_JSON=$(printf '%s\n' "${new_violation_objects[@]}" | jq -s '.')
jq --argjson new "$ALL_NEW_JSON" '. + $new' "$SESSION_VIOLATIONS" > "$SESSION_VIOLATIONS.tmp"
mv "$SESSION_VIOLATIONS.tmp" "$SESSION_VIOLATIONS"

msg_body="thymus: ${#violation_lines[@]} violation(s) in $REL_PATH\n"
for line in "${violation_lines[@]}"; do
  msg_body+="  $line\n"
done

jq -n --arg msg "$msg_body" '{"systemMessage": $msg}'
