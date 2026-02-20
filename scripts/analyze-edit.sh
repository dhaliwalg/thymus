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

# Nothing to check if no file path
[ -z "$file_path" ] && exit 0

# Look for .ais/invariants.json in the current working directory (project root)
AIS_DIR="$PWD/.ais"
INVARIANTS_FILE="$AIS_DIR/invariants.json"

# No baseline = no checking (silent, don't nag on every edit)
[ -f "$INVARIANTS_FILE" ] || exit 0

# Cache setup — project-specific temp dir
PROJECT_HASH=$(echo "$PWD" | md5 -q 2>/dev/null || echo "$PWD" | md5sum | cut -d' ' -f1)
CACHE_DIR="/tmp/ais-cache-${PROJECT_HASH}"
mkdir -p "$CACHE_DIR"
SESSION_VIOLATIONS="$CACHE_DIR/session-violations.json"
[ -f "$SESSION_VIOLATIONS" ] || echo "[]" > "$SESSION_VIOLATIONS"

# Make file path relative to project root for glob matching
REL_PATH="${file_path#"$PWD"/}"
# If file is outside PWD, use basename as fallback
[ "$REL_PATH" = "$file_path" ] && REL_PATH=$(basename "$file_path")

echo "[$TIMESTAMP] Checking $REL_PATH" >> "$DEBUG_LOG"

# --- Glob → regex conversion ---
# src/routes/** → ^src/routes/.*$
# src/**/*.ts  → ^src/.*/[^/]*\.ts$
# TODO(Phase 3): extended glob negation !(foo)/** is not handled — scope_glob rules using
# this syntax silently match nothing. Requires extglob-aware conversion or a blocklist approach.
glob_to_regex() {
  printf '%s' "$1" \
    | sed \
        -e 's/\./\\./g' \
        -e 's|\*\*|__DS__|g' \
        -e 's|\*|[^/]*|g' \
        -e 's|__DS__|.*|g'
}

# Returns 0 if path matches glob pattern, 1 otherwise
path_matches() {
  local path="$1" glob="$2"
  local regex
  regex="^$(glob_to_regex "$glob")"'$'
  echo "$path" | grep -qE "$regex" 2>/dev/null || return 1
}

# --- Import extraction (TypeScript/JavaScript) ---
# Returns one import path per line
extract_ts_imports() {
  local file="$1"
  [ -f "$file" ] || return 0
  # Match: from 'path', from "path", require('path'), require("path")
  { grep -oE "(from|require)[[:space:]]*['\"][^'\"]+['\"]" "$file" 2>/dev/null || true; } \
    | { grep -oE "['\"][^'\"]+['\"]" || true; } \
    | tr -d "'\"" \
    || true
}

# --- Check one import against a forbidden patterns list ---
# Returns 0 (match found) or 1 (no match)
import_is_forbidden() {
  local import="$1"
  local invariant_json="$2"
  local count
  count=$(echo "$invariant_json" | jq '.forbidden_imports | length' 2>/dev/null || echo 0)
  for ((f=0; f<count; f++)); do
    pattern=$(echo "$invariant_json" | jq -r ".forbidden_imports[$f]")
    # Glob match (handles src/db/**) or exact package name match
    if path_matches "$import" "$pattern" \
       || [ "$import" = "$pattern" ]; then
      return 0
    fi
  done
  return 1
}

# --- Accumulate violations ---
violation_lines=()
new_violation_objects=()

# --- Load and iterate invariants ---
invariant_count=$(jq '.invariants | length' "$INVARIANTS_FILE" 2>/dev/null || echo 0)

for ((i=0; i<invariant_count; i++)); do
  inv=$(jq ".invariants[$i]" "$INVARIANTS_FILE")
  rule_id=$(echo "$inv" | jq -r '.id')
  rule_type=$(echo "$inv" | jq -r '.type')
  severity=$(echo "$inv" | jq -r '.severity')
  description=$(echo "$inv" | jq -r '.description')

  # Determine the applicable glob (source_glob for boundary/convention, scope_glob for pattern)
  applicable_glob=$(echo "$inv" | jq -r '.source_glob // .scope_glob // empty')

  # Skip invariants that don't apply to this file
  if [ -n "$applicable_glob" ]; then
    path_matches "$REL_PATH" "$applicable_glob" || continue
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
            --arg rule "$rule_id" \
            --arg sev "$severity" \
            --arg msg "$description" \
            --arg file "$REL_PATH" \
            --arg imp "$import" \
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
          --arg rule "$rule_id" \
          --arg sev "$severity" \
          --arg msg "$description" \
          --arg file "$REL_PATH" \
          --arg line "${line_num}" \
          '{rule:$rule,severity:$sev,message:$msg,file:$file,line:$line}')")
      fi
      ;;

    convention)
      [ -f "$file_path" ] || continue
      rule_text=$(echo "$inv" | jq -r '.rule // empty')
      # Test colocation convention
      if echo "$rule_text" | grep -qi "test"; then
        # Only check .ts/.js/.py files that aren't test or declaration files
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
              --arg rule "$rule_id" \
              --arg sev "$severity" \
              --arg msg "Missing colocated test file" \
              --arg file "$REL_PATH" \
              '{rule:$rule,severity:$sev,message:$msg,file:$file}')")
          fi
        fi
      fi
      ;;

  esac
done

echo "[$TIMESTAMP] Found ${#violation_lines[@]} violations in $REL_PATH" >> "$DEBUG_LOG"

# --- Exit silently if no violations ---
[ ${#violation_lines[@]} -eq 0 ] && exit 0

# --- Append to session violations cache ---
for obj in "${new_violation_objects[@]}"; do
  updated=$(jq --argjson v "$obj" '. + [$v]' "$SESSION_VIOLATIONS")
  echo "$updated" > "$SESSION_VIOLATIONS"
done

# --- Format systemMessage ---
msg_body="⚠️ AIS: ${#violation_lines[@]} violation(s) in $REL_PATH:\n"
for line in "${violation_lines[@]}"; do
  msg_body+="  • $line\n"
done

jq -n --arg msg "$msg_body" '{"systemMessage": $msg}'
