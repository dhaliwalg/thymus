#!/usr/bin/env bash
set -euo pipefail

# Thymus add-invariant.sh
# Appends a new invariant YAML block (from stdin) to the given invariants.yml.
# Usage: echo "$YAML_BLOCK" | bash add-invariant.sh /path/to/.thymus/invariants.yml
# Exit 0 on success, exit 1 on failure.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

INVARIANTS_YML="${1:-}"
if [ -z "$INVARIANTS_YML" ] || [ ! -f "$INVARIANTS_YML" ]; then
  echo "Thymus: add-invariant.sh requires path to invariants.yml as argument" >&2
  exit 1
fi

NEW_BLOCK=$(cat)
if [ -z "$NEW_BLOCK" ]; then
  echo "Thymus: no invariant block on stdin" >&2
  exit 1
fi

# Backup before modifying
cp "$INVARIANTS_YML" "${INVARIANTS_YML}.bak"

# Append new block (ensure file ends with newline first)
printf '\n' >> "$INVARIANTS_YML"
printf '%s\n' "$NEW_BLOCK" >> "$INVARIANTS_YML"

# Validate using the canonical parser from common.sh
VALIDATOR_CACHE="/tmp/thymus-validate-$$"
mkdir -p "$VALIDATOR_CACHE"
PARSE_OK=$(load_invariants "$INVARIANTS_YML" "$VALIDATOR_CACHE/check.json" >/dev/null 2>/dev/null && echo "ok" || echo "fail")
rm -rf "$VALIDATOR_CACHE"

if [ "$PARSE_OK" != "ok" ]; then
  # Restore backup if invalid
  mv "${INVARIANTS_YML}.bak" "$INVARIANTS_YML"
  echo "Thymus: Invalid YAML — invariants.yml restored from backup" >&2
  exit 1
fi

rm -f "${INVARIANTS_YML}.bak"
echo "Thymus: Invariant added successfully to $(basename "$INVARIANTS_YML")"
