#!/usr/bin/env bash
set -euo pipefail

# AIS add-invariant.sh
# Appends a new invariant YAML block (from stdin) to the given invariants.yml.
# Usage: echo "$YAML_BLOCK" | bash add-invariant.sh /path/to/.ais/invariants.yml
# Exit 0 on success, exit 1 on failure.

INVARIANTS_YML="${1:-}"
if [ -z "$INVARIANTS_YML" ] || [ ! -f "$INVARIANTS_YML" ]; then
  echo "AIS: add-invariant.sh requires path to invariants.yml as argument" >&2
  exit 1
fi

NEW_BLOCK=$(cat)
if [ -z "$NEW_BLOCK" ]; then
  echo "AIS: no invariant block on stdin" >&2
  exit 1
fi

# Backup before modifying
cp "$INVARIANTS_YML" "${INVARIANTS_YML}.bak"

# Append new block (ensure file ends with newline first)
printf '\n' >> "$INVARIANTS_YML"
printf '%s\n' "$NEW_BLOCK" >> "$INVARIANTS_YML"

# Validate: write parser to temp file to avoid heredoc-in-subshell issues
VALIDATOR=$(mktemp /tmp/ais-validate-XXXXXX.py)
cat > "$VALIDATOR" << 'ENDPY'
import sys, re

def strip_val(s):
    s = re.sub(r'\s{2,}#.*$', '', s)
    return s.strip("\"'")

invariants = []
current = None
list_key = None
with open(sys.argv[1]) as f:
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
print('ok')
ENDPY

PARSE_OK=$(python3 "$VALIDATOR" "$INVARIANTS_YML" 2>/dev/null || echo "fail")
rm -f "$VALIDATOR"

if [ "$PARSE_OK" != "ok" ]; then
  # Restore backup if invalid
  mv "${INVARIANTS_YML}.bak" "$INVARIANTS_YML"
  echo "AIS: Invalid YAML — invariants.yml restored from backup" >&2
  exit 1
fi

rm -f "${INVARIANTS_YML}.bak"
echo "AIS: Invariant added successfully to $(basename "$INVARIANTS_YML")"
