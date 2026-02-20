#!/usr/bin/env bash
set -euo pipefail

# AIS PostToolUse hook — analyze-edit.sh
# Fires on every Edit/Write. Checks the edited file against active invariants.
# Output: JSON systemMessage if violations found, empty if clean.
# NEVER exits with code 2 (no blocking).

DEBUG_LOG="/tmp/ais-debug.log"
TIMESTAMP=$(date '+%Y-%m-%dT%H:%M:%S')

input=$(cat)
file_path=$(echo "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)
tool_name=$(echo "$input" | jq -r '.tool_name // "unknown"' 2>/dev/null || true)

echo "[$TIMESTAMP] analyze-edit.sh: $tool_name on ${file_path:-unknown}" >> "$DEBUG_LOG"

[ -z "$file_path" ] && exit 0

AIS_DIR="$PWD/.ais"
INVARIANTS_YML="$AIS_DIR/invariants.yml"

[ -f "$INVARIANTS_YML" ] || exit 0

PROJECT_HASH=$(echo "$PWD" | md5 -q 2>/dev/null || echo "$PWD" | md5sum | cut -d' ' -f1)
CACHE_DIR="/tmp/ais-cache-${PROJECT_HASH}"
mkdir -p "$CACHE_DIR"
SESSION_VIOLATIONS="$CACHE_DIR/session-violations.json"
[ -f "$SESSION_VIOLATIONS" ] || echo "[]" > "$SESSION_VIOLATIONS"

# --- YAML → JSON conversion (cached by mtime) ---
# Parses invariants.yml using Python3 stdlib only (no PyYAML).
# Writes parsed JSON to cache; reuses cache if newer than source.
load_invariants() {
  local yml="$1" cache="$2"
  [ -f "$yml" ] || { echo "AIS: invariants.yml not found" >&2; return 1; }
  if [ -f "$cache" ] && [ "$cache" -nt "$yml" ]; then
    echo "$cache"; return 0
  fi
  python3 - "$yml" "$cache" <<'PYEOF'
import sys, json, re

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
                current = {'id': m.group(1)}
                list_key = None
                continue
            if current is None:
                continue
            m = re.match(r'^      - ["\']?(.*?)["\']?\s*$', line)
            if m and list_key is not None:
                current[list_key].append(m.group(1))
                continue
            m = re.match(r'^    ([a-z_]+):\s*$', line)
            if m:
                list_key = m.group(1)
                current[list_key] = []
                continue
            m = re.match(r'^    ([a-z_]+):\s*["\']?(.*?)["\']?\s*$', line)
            if m:
                current[m.group(1)] = m.group(2)
                list_key = None
                continue
    if current:
        invariants.append(current)
    with open(dst, 'w') as f:
        json.dump({'invariants': invariants}, f)

parse(sys.argv[1], sys.argv[2])
PYEOF
  if [ $? -ne 0 ] || [ ! -s "$cache" ]; then
    echo "AIS: Failed to parse invariants.yml" >&2; return 1
  fi
  echo "$cache"
}

INVARIANTS_JSON=$(load_invariants "$INVARIANTS_YML" "$CACHE_DIR/invariants.json") || exit 0

REL_PATH="${file_path#"$PWD"/}"
[ "$REL_PATH" = "$file_path" ] && REL_PATH=$(basename "$file_path")

echo "[$TIMESTAMP] Checking $REL_PATH" >> "$DEBUG_LOG"

# --- Glob → regex conversion ---
# NOTE: Extended glob negation !(foo)/** is NOT supported.
# Use scope_glob + scope_glob_exclude instead (see invariants.yml schema).
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

extract_ts_imports() {
  local file="$1"
  [ -f "$file" ] || return 0
  { grep -oE "(from|require)[[:space:]]*['\"][^'\"]+['\"]" "$file" 2>/dev/null || true; } \
    | { grep -oE "['\"][^'\"]+['\"]" || true; } \
    | tr -d "'\"" \
    || true
}

import_is_forbidden() {
  local import="$1"
  local invariant_json="$2"
  local count
  count=$(echo "$invariant_json" | jq '.forbidden_imports | length' 2>/dev/null || echo 0)
  for ((f=0; f<count; f++)); do
    pattern=$(echo "$invariant_json" | jq -r ".forbidden_imports[$f]")
    if path_matches "$import" "$pattern" || [ "$import" = "$pattern" ]; then
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
    # scope_glob_exclude: skip file if it matches any exclusion pattern
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

  echo "[$TIMESTAMP]   Checking rule $rule_id ($rule_type) against $REL_PATH" >> "$DEBUG_LOG"

  case "$rule_type" in

    boundary)
      [ -f "$file_path" ] || continue
      imports=$(extract_ts_imports "$file_path")
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
        if [[ "$REL_PATH" =~ \.(ts|js|py)$ ]] \
           && [[ ! "$REL_PATH" =~ \.(test|spec)\. ]] \
           && [[ ! "$REL_PATH" =~ \.d\.ts$ ]]; then
          base="${file_path%.*}"
          ext="${file_path##*.}"
          if ! { [ -f "${base}.test.${ext}" ] || [ -f "${base}.spec.${ext}" ]; }; then
            SEV_UPPER=$(echo "$severity" | tr '[:lower:]' '[:upper:]')
            msg="[$SEV_UPPER] $rule_id: Missing test file for $REL_PATH"
            violation_lines+=("$msg")
            new_violation_objects+=("$(jq -n \
              --arg rule "$rule_id" --arg sev "$severity" \
              --arg msg "Missing colocated test file" --arg file "$REL_PATH" \
              '{rule:$rule,severity:$sev,message:$msg,file:$file}')")
          fi
        fi
      fi
      ;;

  esac
done

echo "[$TIMESTAMP] Found ${#violation_lines[@]} violations in $REL_PATH" >> "$DEBUG_LOG"

[ ${#violation_lines[@]} -eq 0 ] && exit 0

for obj in "${new_violation_objects[@]}"; do
  updated=$(jq --argjson v "$obj" '. + [$v]' "$SESSION_VIOLATIONS")
  echo "$updated" > "$SESSION_VIOLATIONS"
done

msg_body="⚠️ AIS: ${#violation_lines[@]} violation(s) in $REL_PATH:\n"
for line in "${violation_lines[@]}"; do
  msg_body+="  • $line\n"
done

jq -n --arg msg "$msg_body" '{"systemMessage": $msg}'
