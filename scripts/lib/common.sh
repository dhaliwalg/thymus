#!/usr/bin/env bash
# Thymus shared utilities
# Source this file: source "$(dirname "$0")/lib/common.sh"

[[ -n "${_THYMUS_COMMON_LOADED:-}" ]] && return 0
_THYMUS_COMMON_LOADED=1

THYMUS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
THYMUS_SCRIPTS_DIR="$(cd "$THYMUS_LIB_DIR/.." && pwd)"

DEBUG_LOG="/tmp/thymus-debug.log"
TIMESTAMP=$(date '+%Y-%m-%dT%H:%M:%S')

# Ignored paths for file discovery
THYMUS_IGNORED_PATHS=("node_modules" "dist" ".next" ".git" "coverage" "__pycache__" ".venv" "vendor" "target" "build" ".thymus")

# --- Project hash and cache ---

thymus_project_hash() {
  echo "$PWD" | md5 -q 2>/dev/null || echo "$PWD" | md5sum | cut -d' ' -f1
}

thymus_cache_dir() {
  local hash
  hash=$(thymus_project_hash)
  local dir="/tmp/thymus-cache-${hash}"
  mkdir -p "$dir"
  echo "$dir"
}

# --- YAML parser (canonical copy) ---

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

# --- Glob matching ---

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

# --- Import helpers ---

extract_imports() {
  local file="$1"
  [ -f "$file" ] || return 0
  python3 "${THYMUS_SCRIPTS_DIR}/extract-imports.py" "$file" 2>/dev/null || true
}

import_is_forbidden() {
  local import="$1"
  local invariant_json="$2"
  local count
  count=$(echo "$invariant_json" | jq '.forbidden_imports | length' 2>/dev/null || echo 0)
  local import_as_path="$import"
  if [[ "$import" == *.* ]] && [[ "$import" != */* ]]; then
    import_as_path=$(printf '%s' "$import" | tr '.' '/')
  fi
  for ((f=0; f<count; f++)); do
    local pattern
    pattern=$(echo "$invariant_json" | jq -r ".forbidden_imports[$f]")
    if path_matches "$import" "$pattern" || [ "$import" = "$pattern" ] \
       || path_matches "$import_as_path" "$pattern"; then
      return 0
    fi
  done
  return 1
}

# --- File discovery ---

find_source_files() {
  local root="${1:-$PWD}"
  local ignored_args=()
  for p in "${THYMUS_IGNORED_PATHS[@]}"; do
    ignored_args+=(-not -path "*/$p/*" -not -name "$p")
  done
  find "$root" -type f \( -name "*.ts" -o -name "*.js" -o -name "*.py" -o -name "*.java" -o -name "*.go" -o -name "*.rs" -o -name "*.dart" -o -name "*.kt" -o -name "*.kts" -o -name "*.swift" -o -name "*.cs" -o -name "*.php" -o -name "*.rb" \) \
    "${ignored_args[@]}" 2>/dev/null | sed "s|${root}/||" | sort
}

# Build import entries JSON array from a file list on stdin
# Usage: find_source_files | build_import_entries [root_dir]
build_import_entries() {
  local root="${1:-$PWD}"
  local entries="["
  local first=true
  while IFS= read -r rel_path; do
    [ -n "$rel_path" ] || continue
    local abs_path="$root/$rel_path"
    [ -f "$abs_path" ] || continue
    local imports_raw
    imports_raw=$(extract_imports "$abs_path")
    local imports_json="[]"
    if [ -n "$imports_raw" ]; then
      imports_json=$(printf '%s\n' "$imports_raw" | jq -R '.' | jq -s '.')
    fi
    if [ "$first" = true ]; then
      first=false
    else
      entries+=","
    fi
    entries+=$(jq -n --arg file "$rel_path" --argjson imports "$imports_json" \
      '{"file":$file,"imports":$imports}')
  done
  entries+="]"
  echo "$entries"
}

# Build find args for ignored paths (for scripts that need custom find commands)
thymus_ignored_find_args() {
  for p in "${THYMUS_IGNORED_PATHS[@]}"; do
    printf '%s\n' "-not" "-path" "*/$p/*" "-not" "-name" "$p"
  done
}
