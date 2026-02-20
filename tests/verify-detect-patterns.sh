#!/usr/bin/env bash
set -euo pipefail

SCRIPT="$(dirname "$0")/../scripts/detect-patterns.sh"
HEALTHY="$(dirname "$0")/fixtures/healthy-project"

echo "=== Testing detect-patterns.sh ==="

output=$(bash "$SCRIPT" "$HEALTHY")

# Verify it's valid JSON
echo "$output" | jq . > /dev/null || { echo "FAIL: not valid JSON"; exit 1; }

# Verify required fields exist
for field in raw_structure detected_layers naming_patterns test_gaps file_counts; do
  echo "$output" | jq -e ".$field" > /dev/null || { echo "FAIL: missing field $field"; exit 1; }
done

# Verify detected_layers found 'routes', 'controllers', 'services', 'repositories'
for layer in routes controllers services repositories; do
  echo "$output" | jq -e ".detected_layers[] | select(. == \"$layer\")" > /dev/null \
    || { echo "FAIL: expected layer '$layer' not detected"; exit 1; }
done

echo "PASS: detect-patterns.sh output is valid"
