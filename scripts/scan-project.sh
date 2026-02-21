#!/usr/bin/env bash
set -euo pipefail

# AIS scan-project.sh — batch invariant checker
# Usage: bash scan-project.sh [scope_path] [--diff]
# Output: JSON { violations: [...], stats: {...}, scope: "..." }
# scope_path: optional subdirectory to limit scan (e.g. "src/auth")
# --diff: limit scan to files changed since git HEAD

DEBUG_LOG="/tmp/ais-debug.log"
TIMESTAMP=$(date '+%Y-%m-%dT%H:%M:%S')
AIS_DIR="$PWD/.ais"
INVARIANTS_YML="$AIS_DIR/invariants.yml"

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
  echo '{"error":"No invariants.yml found. Run /ais:baseline first.","violations":[],"stats":{"total":0,"errors":0,"warnings":0}}'
  exit 0
fi

PROJECT_HASH=$(echo "$PWD" | md5 -q 2>/dev/null || echo "$PWD" | md5sum | cut -d' ' -f1)
CACHE_DIR="/tmp/ais-cache-${PROJECT_HASH}"
mkdir -p "$CACHE_DIR"

# --- YAML → JSON (cached by mtime) ---
load_invariants() {
  local yml="$1" cache="$2"
  [ -f "$yml" ] || { echo "AIS: invariants.yml not found" >&2; return 1; }
  if [ -f "$cache" ] && [ "$cache" -nt "$yml" ]; then
    echo "$cache"; return 0
  fi
  python3 - "$yml" "$cache" <<'PYEOF'
import sys, json, re

def strip_val(s):
    """Strip inline comments (2+ spaces before #) and surrounding quotes."""
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
    echo "AIS: Failed to parse invariants.yml" >&2; return 1
  fi
  echo "$cache"
}

INVARIANTS_JSON=$(load_invariants "$INVARIANTS_YML" "$CACHE_DIR/invariants-scan.json") || {
  echo '{"error":"Failed to parse invariants.yml","violations":[],"stats":{"total":0,"errors":0,"warnings":0}}'
  exit 0
}

# --- Glob → regex ---
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

# Returns 0 if file is in scope for this invariant (matches glob, not in exclude list)
file_in_scope() {
  local rel_path="$1" inv_json="$2"
  local applicable_glob
  applicable_glob=$(echo "$inv_json" | jq -r '.source_glob // .scope_glob // empty')
  [ -z "$applicable_glob" ] && return 0
  path_matches "$rel_path" "$applicable_glob" || return 1
  local excl_count
  excl_count=$(echo "$inv_json" | jq 'if .scope_glob_exclude then .scope_glob_exclude | length else 0 end' 2>/dev/null || echo 0)
  for ((e=0; e<excl_count; e++)); do
    local excl
    excl=$(echo "$inv_json" | jq -r ".scope_glob_exclude[$e]")
    path_matches "$rel_path" "$excl" && return 1
  done
  return 0
}

extract_ts_imports() {
  local file="$1"
  [ -f "$file" ] || return 0
  { grep -oE "(from|require)[[:space:]]*['\"][^'\"]+['\"]" "$file" 2>/dev/null || true; } \
    | { grep -oE "['\"][^'\"]+['\"]" || true; } \
    | tr -d "'\"" || true
}

import_is_forbidden() {
  local import="$1" inv_json="$2"
  local count
  count=$(echo "$inv_json" | jq '.forbidden_imports | length' 2>/dev/null || echo 0)
  for ((f=0; f<count; f++)); do
    local pattern
    pattern=$(echo "$inv_json" | jq -r ".forbidden_imports[$f]")
    if path_matches "$import" "$pattern" || [ "$import" = "$pattern" ]; then
      return 0
    fi
  done
  return 1
}

# --- Build file list ---
IGNORED_PATHS=("node_modules" "dist" ".next" ".git" "coverage" "__pycache__" ".venv" "vendor" "target" "build" ".ais")
IGNORED_ARGS=()
for p in "${IGNORED_PATHS[@]}"; do
  IGNORED_ARGS+=(-not -path "*/$p/*" -not -name "$p")
done

declare -a FILES=()
if $DIFF_MODE; then
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    # If scope is set, only include diff files under that path
    if [ -n "$SCOPE" ] && [[ ! "$f" == "$SCOPE"* ]]; then
      continue
    fi
    FILES+=("$f")
  done < <(git diff --name-only HEAD 2>/dev/null | grep -v '^$' || true)
else
  SCAN_ROOT="$PWD"
  [ -n "$SCOPE" ] && SCAN_ROOT="$PWD/$SCOPE"
  while IFS= read -r f; do
    [ -n "$f" ] && FILES+=("$(echo "$f" | sed "s|$PWD/||")")
  done < <(find "$SCAN_ROOT" -type f \( -name "*.ts" -o -name "*.js" -o -name "*.py" \) \
    "${IGNORED_ARGS[@]}" 2>/dev/null | sort)
fi

files_checked=${#FILES[@]}
echo "[$TIMESTAMP] scan-project: checking $files_checked files" >> "$DEBUG_LOG"

# Early exit for empty file list (e.g. --diff with no changed files, empty scope)
if [ "$files_checked" -eq 0 ]; then
  jq -n --arg scope "${SCOPE:-}" \
    '{"scope":$scope,"files_checked":0,"violations":[],"stats":{"total":0,"errors":0,"warnings":0}}'
  exit 0
fi

# --- Accumulate violations in memory (avoids O(n²) file rewrite per violation) ---
violation_objects=()

invariant_count=$(jq '.invariants | length' "$INVARIANTS_JSON" 2>/dev/null || echo 0)

for rel_path in "${FILES[@]}"; do
  abs_path="$PWD/$rel_path"
  [ -f "$abs_path" ] || continue

  for ((i=0; i<invariant_count; i++)); do
    inv=$(jq ".invariants[$i]" "$INVARIANTS_JSON")
    rule_id=$(echo "$inv" | jq -r '.id')
    rule_type=$(echo "$inv" | jq -r '.type')
    severity=$(echo "$inv" | jq -r '.severity')
    description=$(echo "$inv" | jq -r '.description')

    file_in_scope "$rel_path" "$inv" || continue

    case "$rule_type" in

      boundary)
        imports=$(extract_ts_imports "$abs_path")
        [ -z "$imports" ] && continue
        while IFS= read -r import; do
          [ -z "$import" ] && continue
          if import_is_forbidden "$import" "$inv"; then
            violation_objects+=("$(jq -n \
              --arg rule "$rule_id" --arg sev "$severity" --arg msg "$description" \
              --arg file "$rel_path" --arg imp "$import" \
              '{rule:$rule,severity:$sev,message:$msg,file:$file,import:$imp}')")
          fi
        done <<< "$imports"
        ;;

      pattern)
        forbidden_pattern=$(echo "$inv" | jq -r '.forbidden_pattern // empty')
        [ -z "$forbidden_pattern" ] && continue
        if grep -qE "$forbidden_pattern" "$abs_path" 2>/dev/null; then
          line_num=$({ grep -nE "$forbidden_pattern" "$abs_path" 2>/dev/null | head -1 | cut -d: -f1; } || echo "")
          violation_objects+=("$(jq -n \
            --arg rule "$rule_id" --arg sev "$severity" --arg msg "$description" \
            --arg file "$rel_path" --arg line "${line_num}" \
            '{rule:$rule,severity:$sev,message:$msg,file:$file,line:$line}')")
        fi
        ;;

      convention)
        rule_text=$(echo "$inv" | jq -r '.rule // empty')
        if echo "$rule_text" | grep -qi "test"; then
          if [[ "$rel_path" =~ \.(ts|js|py)$ ]] \
             && [[ ! "$rel_path" =~ \.(test|spec)\. ]] \
             && [[ ! "$rel_path" =~ \.d\.ts$ ]]; then
            base="${abs_path%.*}"
            ext="${abs_path##*.}"
            if ! { [ -f "${base}.test.${ext}" ] || [ -f "${base}.spec.${ext}" ]; }; then
              violation_objects+=("$(jq -n \
                --arg rule "$rule_id" --arg sev "$severity" \
                --arg msg "Missing colocated test file" --arg file "$rel_path" \
                '{rule:$rule,severity:$sev,message:$msg,file:$file}')")
            fi
          fi
        fi
        ;;

    esac
  done
done

# --- Serialize violation array once ---
if [ "${#violation_objects[@]}" -eq 0 ]; then
  VIOLATIONS="[]"
else
  VIOLATIONS=$(printf '%s\n' "${violation_objects[@]}" | jq -s '.')
fi

# --- Compute stats ---
total=$(echo "$VIOLATIONS" | jq 'length')
errors=$(echo "$VIOLATIONS" | jq '[.[] | select(.severity=="error")] | length')
warnings=$(echo "$VIOLATIONS" | jq '[.[] | select(.severity=="warning")] | length')

# --- Output ---
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
