#!/usr/bin/env bash
set -euo pipefail

# PostToolUse hook: check edited file against invariants
# never exits with code 2 — warns but doesn't block

DEBUG_LOG="/tmp/thymus-debug.log"
TIMESTAMP=$(date '+%Y-%m-%dT%H:%M:%S')

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

PROJECT_HASH=$(echo "$PWD" | md5 -q 2>/dev/null || echo "$PWD" | md5sum | cut -d' ' -f1)
CACHE_DIR="/tmp/thymus-cache-${PROJECT_HASH}"
mkdir -p "$CACHE_DIR"
SESSION_VIOLATIONS="$CACHE_DIR/session-violations.json"
[ -f "$SESSION_VIOLATIONS" ] || echo "[]" > "$SESSION_VIOLATIONS"

# parse invariants.yml to json, cached by mtime
load_invariants() {
  local yml="$1" cache="$2"
  [ -f "$yml" ] || { echo "thymus: invariants.yml not found" >&2; return 1; }
  if [ -f "$cache" ] && [ "$cache" -nt "$yml" ]; then
    echo "$cache"; return 0
  fi
  python3 - "$yml" "$cache" <<'PYEOF'
import sys, json, re

def strip_val(s):
    s = re.sub(r'\s{2,}#.*$', '', s)
    return s.strip('"\'')

def parse(src, dst):
    invariants = []
    current = None
    list_key = None
    with open(src) as f:
        for line in f:
            line = line.rstrip('\n')
            m = re.match(r'^  - id:\s*["\']?(.*?)["\']?\s*$', line)
            if m:
                if current:
                    invariants.append(current)
                current = {'id': strip_val(m.group(1))}
                list_key = None
                continue
            if current is None:
                continue
            m = re.match(r'^      - ["\']?(.*?)["\']?\s*$', line)
            if m and list_key is not None:
                current[list_key].append(strip_val(m.group(1)))
                continue
            m = re.match(r'^    ([a-z_]+):\s*$', line)
            if m:
                list_key = m.group(1)
                current[list_key] = []
                continue
            m = re.match(r'^    ([a-z_]+):\s*["\']?(.*?)["\']?\s*$', line)
            if m:
                current[m.group(1)] = strip_val(m.group(2))
                list_key = None
                continue
    if current:
        invariants.append(current)
    with open(dst, 'w') as f:
        json.dump({'invariants': invariants}, f)

parse(sys.argv[1], sys.argv[2])
PYEOF
  if [ $? -ne 0 ] || [ ! -s "$cache" ]; then
    echo "thymus: failed to parse invariants.yml" >&2; return 1
  fi
  echo "$cache"
}

INVARIANTS_JSON=$(load_invariants "$INVARIANTS_YML" "$CACHE_DIR/invariants.json") || exit 0

REL_PATH="${file_path#"$PWD"/}"
[ "$REL_PATH" = "$file_path" ] && REL_PATH=$(basename "$file_path")

echo "[$TIMESTAMP] checking $REL_PATH" >> "$DEBUG_LOG"

# NOTE: extended glob negation !(foo)/** is not supported — use scope_glob_exclude instead
glob_to_regex() {
  printf '%s' "$1" \
    | sed \
        -e 's/\./\\./g' \
        -e 's|\*\*|__DS__|g' \
        -e 's|\*|[^/]*|g' \
        -e 's|__DS__|.*|g'
}

path_matches() {
  local path="$1" glob="$2"
  local regex
  regex="^$(glob_to_regex "$glob")"'$'
  echo "$path" | grep -qE "$regex" 2>/dev/null || return 1
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

extract_imports() {
  local file="$1"
  [ -f "$file" ] || return 0
  python3 "${SCRIPT_DIR}/extract-imports.py" "$file" 2>/dev/null || true
}

import_is_forbidden() {
  local import="$1"
  local invariant_json="$2"
  local count
  count=$(echo "$invariant_json" | jq '.forbidden_imports | length' 2>/dev/null || echo 0)
  # For Java dot-separated imports, also try matching as a path (dots -> slashes)
  local import_as_path="$import"
  if [[ "$import" == *.* ]] && [[ "$import" != */* ]]; then
    import_as_path=$(printf '%s' "$import" | tr '.' '/')
  fi
  for ((f=0; f<count; f++)); do
    pattern=$(echo "$invariant_json" | jq -r ".forbidden_imports[$f]")
    if path_matches "$import" "$pattern" || [ "$import" = "$pattern" ] \
       || path_matches "$import_as_path" "$pattern"; then
      return 0
    fi
  done
  return 1
}

violation_lines=()
new_violation_objects=()

invariant_count=$(jq '.invariants | length' "$INVARIANTS_JSON" 2>/dev/null || echo 0)

for ((i=0; i<invariant_count; i++)); do
  inv=$(jq ".invariants[$i]" "$INVARIANTS_JSON")
  rule_id=$(echo "$inv" | jq -r '.id')
  rule_type=$(echo "$inv" | jq -r '.type')
  severity=$(echo "$inv" | jq -r '.severity')
  description=$(echo "$inv" | jq -r '.description')

  applicable_glob=$(echo "$inv" | jq -r '.source_glob // .scope_glob // empty')

  if [ -n "$applicable_glob" ]; then
    path_matches "$REL_PATH" "$applicable_glob" || continue
    excl_count=$(echo "$inv" | jq 'if .scope_glob_exclude then .scope_glob_exclude | length else 0 end' 2>/dev/null || echo 0)
    excluded=false
    for ((e=0; e<excl_count; e++)); do
      excl=$(echo "$inv" | jq -r ".scope_glob_exclude[$e]")
      if path_matches "$REL_PATH" "$excl"; then
        excluded=true; break
      fi
    done
    $excluded && continue
  fi

  echo "[$TIMESTAMP]   rule $rule_id ($rule_type) vs $REL_PATH" >> "$DEBUG_LOG"

  case "$rule_type" in

    boundary)
      [ -f "$file_path" ] || continue
      imports=$(extract_imports "$file_path")
      [ -z "$imports" ] && continue
      while IFS= read -r import; do
        [ -z "$import" ] && continue
        if import_is_forbidden "$import" "$inv"; then
          SEV_UPPER=$(echo "$severity" | tr '[:lower:]' '[:upper:]')
          msg="[$SEV_UPPER] $rule_id: $description (import: $import)"
          violation_lines+=("$msg")
          new_violation_objects+=("$(jq -n \
            --arg rule "$rule_id" --arg sev "$severity" --arg msg "$description" \
            --arg file "$REL_PATH" --arg imp "$import" \
            '{rule:$rule,severity:$sev,message:$msg,file:$file,import:$imp}')")
        fi
      done <<< "$imports"
      ;;

    pattern)
      [ -f "$file_path" ] || continue
      forbidden_pattern=$(echo "$inv" | jq -r '.forbidden_pattern // empty')
      [ -z "$forbidden_pattern" ] && continue
      if grep -qE "$forbidden_pattern" "$file_path" 2>/dev/null; then
        line_num=$({ grep -nE "$forbidden_pattern" "$file_path" 2>/dev/null | head -1 | cut -d: -f1; } || echo "?")
        SEV_UPPER=$(echo "$severity" | tr '[:lower:]' '[:upper:]')
        msg="[$SEV_UPPER] $rule_id: $description (line $line_num)"
        violation_lines+=("$msg")
        new_violation_objects+=("$(jq -n \
          --arg rule "$rule_id" --arg sev "$severity" --arg msg "$description" \
          --arg file "$REL_PATH" --arg line "${line_num}" \
          '{rule:$rule,severity:$sev,message:$msg,file:$file,line:$line}')")
      fi
      ;;

    convention)
      [ -f "$file_path" ] || continue
      rule_text=$(echo "$inv" | jq -r '.rule // empty')
      if echo "$rule_text" | grep -qi "test"; then
        if [[ "$REL_PATH" =~ \.(ts|js|py|java|go|rs)$ ]] \
           && [[ ! "$REL_PATH" =~ \.(test|spec)\. ]] \
           && [[ ! "$REL_PATH" =~ \.d\.ts$ ]] \
           && [[ ! "$REL_PATH" =~ (Test|Tests|IT|Spec)\.java$ ]]; then
          base="${file_path%.*}"
          ext="${file_path##*.}"
          has_test=false
          if [ -f "${base}.test.${ext}" ] || [ -f "${base}.spec.${ext}" ]; then
            has_test=true
          elif [ "$ext" = "java" ]; then
            # Java convention: FooTest.java, FooTests.java, FooIT.java
            basename_no_ext=$(basename "${base}")
            dir=$(dirname "${file_path}")
            # Check same directory
            if [ -f "${dir}/${basename_no_ext}Test.java" ] || \
               [ -f "${dir}/${basename_no_ext}Tests.java" ] || \
               [ -f "${dir}/${basename_no_ext}IT.java" ]; then
              has_test=true
            fi
            # Check src/test/java mirror of src/main/java
            if [ "$has_test" = "false" ] && [[ "$file_path" == *"/src/main/java/"* ]]; then
              test_mirror=$(echo "$file_path" | sed 's|src/main/java|src/test/java|')
              test_mirror_base="${test_mirror%.*}"
              if [ -f "${test_mirror_base}Test.java" ] || \
                 [ -f "${test_mirror_base}Tests.java" ] || \
                 [ -f "${test_mirror_base}IT.java" ]; then
                has_test=true
              fi
            fi
          fi
          if [ "$has_test" = "false" ]; then
            SEV_UPPER=$(echo "$severity" | tr '[:lower:]' '[:upper:]')
            msg="[$SEV_UPPER] $rule_id: missing test file for $REL_PATH"
            violation_lines+=("$msg")
            new_violation_objects+=("$(jq -n \
              --arg rule "$rule_id" --arg sev "$severity" \
              --arg msg "missing colocated test file" --arg file "$REL_PATH" \
              '{rule:$rule,severity:$sev,message:$msg,file:$file}')")
          fi
        fi
      fi
      ;;

    dependency)
      [ -f "$file_path" ] || continue
      package=$(echo "$inv" | jq -r '.package // empty')
      [ -z "$package" ] && continue
      # Check if this file is in an allowed location
      allowed_count=$(echo "$inv" | jq 'if .allowed_in then .allowed_in | length else 0 end' 2>/dev/null || echo 0)
      in_allowed=false
      for ((a=0; a<allowed_count; a++)); do
        allowed_glob=$(echo "$inv" | jq -r ".allowed_in[$a]")
        if path_matches "$REL_PATH" "$allowed_glob"; then
          in_allowed=true; break
        fi
      done
      $in_allowed && continue
      # Check if the file imports the package (using AST-aware extractor)
      file_imports=$(extract_imports "$file_path")
      if echo "$file_imports" | grep -qF "$package" 2>/dev/null; then
        SEV_UPPER=$(echo "$severity" | tr '[:lower:]' '[:upper:]')
        msg="[$SEV_UPPER] $rule_id: $description (package: $package)"
        violation_lines+=("$msg")
        new_violation_objects+=("$(jq -n \
          --arg rule "$rule_id" --arg sev "$severity" --arg msg "$description" \
          --arg file "$REL_PATH" --arg pkg "$package" \
          '{rule:$rule,severity:$sev,message:$msg,file:$file,package:$pkg}')")
      fi
      ;;

  esac
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
