#!/usr/bin/env bash
set -euo pipefail

# Thymus refresh-baseline.sh
# Re-scans the project structure and diffs against the existing baseline.json.
# Outputs JSON: { new_directories, removed_directories, new_file_types, baseline_module_count }
# Used by /thymus:baseline --refresh to propose new invariants.

THYMUS_DIR="$PWD/.thymus"
BASELINE="$THYMUS_DIR/baseline.json"

if [ ! -f "$BASELINE" ]; then
  echo '{"error":"No baseline.json found. Run /thymus:baseline first.","new_directories":[]}'
  exit 0
fi

IGNORED=("node_modules" "dist" ".next" ".git" "coverage" "__pycache__" ".venv" "vendor" "target" "build" ".thymus")
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

# --- Auto-update CLAUDE.md with architectural summary ---
_update_claude_md() {
  local project_root="$1"
  local invariants_file="$project_root/.thymus/invariants.yml"
  local claude_md="$project_root/CLAUDE.md"

  [ -f "$invariants_file" ] || return 0

  # Extract error-severity rule summaries (id + description) via Python
  local summary
  local _pyscript
  _pyscript=$(mktemp /tmp/thymus-cmd-XXXXXX.py)
  cat > "$_pyscript" <<'PYEOF'
import sys, re

rules = []
current_id = None
current_desc = None
current_sev = None

with open(sys.argv[1]) as f:
    for line in f:
        line = line.rstrip('\n')
        m = re.match(r'^  - id:\s*["\']?(.*?)["\']?\s*$', line)
        if m:
            if current_id and current_sev == 'error' and current_desc:
                rules.append(f"- {current_desc} ({current_id})")
            current_id = m.group(1).strip('"\'')
            current_desc = None
            current_sev = None
            continue
        m = re.match(r'^    description:\s*["\']?(.*?)["\']?\s*$', line)
        if m:
            current_desc = m.group(1).strip('"\'')
            continue
        m = re.match(r'^    severity:\s*["\']?(.*?)["\']?\s*$', line)
        if m:
            current_sev = m.group(1).strip('"\'')
            continue

if current_id and current_sev == 'error' and current_desc:
    rules.append(f"- {current_desc} ({current_id})")

for r in rules[:5]:
    print(r)
if len(rules) > 5:
    print("- See `.thymus/invariants.yml` for all rules.")
PYEOF
  summary=$(python3 "$_pyscript" "$invariants_file" 2>/dev/null) || true
  rm -f "$_pyscript"

  [ -z "$summary" ] && summary="- No error-severity rules defined yet."

  local block
  block="
<!-- thymus:start -->
## Architectural Rules

This project uses Thymus for architectural enforcement. Rules are defined in \`.thymus/invariants.yml\` and checked on every file edit.

Before generating imports or moving code between modules, check that the change doesn't violate boundary rules. Key constraints:
$summary

Run \`/thymus:scan\` to check for violations. Run \`/thymus:learn\` to add new rules.
<!-- thymus:end -->"

  if [ -f "$claude_md" ]; then
    if grep -q "<!-- thymus:start -->" "$claude_md"; then
      # Remove existing block, then append updated version
      local tmpfile
      tmpfile=$(mktemp)
      sed '/<!-- thymus:start -->/,/<!-- thymus:end -->/d' "$claude_md" > "$tmpfile"
      # Remove trailing blank lines left by sed (portable)
      python3 -c "
import sys; p=sys.argv[1]; t=open(p).read().rstrip('\n')
open(p,'w').write(t+'\n' if t else '')
" "$tmpfile"
      mv "$tmpfile" "$claude_md"
      printf '%s\n' "$block" >> "$claude_md"
    else
      printf '%s\n' "$block" >> "$claude_md"
    fi
  else
    printf '%s\n' "# Project Notes" > "$claude_md"
    printf '%s\n' "$block" >> "$claude_md"
  fi
}

_update_claude_md "$PWD"
