#!/usr/bin/env bash
set -euo pipefail

SCRIPT="$(realpath "$(dirname "$0")/../scripts/analyze-edit.sh")"
UNHEALTHY="$(realpath "$(dirname "$0")/fixtures/unhealthy-project")"

echo "=== Testing analyze-edit.sh ==="

# Test 1: boundary violation detected (route imports from db)
input=$(jq -n \
  --arg tool "Edit" \
  --arg file "$UNHEALTHY/src/routes/users.ts" \
  '{tool_name: $tool, tool_input: {file_path: $file}, tool_response: {success: true}}')

output=$(cd "$UNHEALTHY" && echo "$input" | bash "$SCRIPT")

if echo "$output" | jq -e '.systemMessage' > /dev/null 2>&1; then
  if echo "$output" | jq -r '.systemMessage' | grep -q "boundary-routes-no-direct-db"; then
    echo "PASS: boundary violation detected"
  else
    echo "FAIL: systemMessage missing rule id"
    echo "$output" | jq -r '.systemMessage'
    exit 1
  fi
else
  echo "FAIL: no systemMessage in output (expected violation)"
  echo "Output: $output"
  exit 1
fi

# Test 2: healthy file produces no output
input=$(jq -n \
  --arg tool "Edit" \
  --arg file "$UNHEALTHY/src/services/user.service.ts" \
  '{tool_name: $tool, tool_input: {file_path: $file}, tool_response: {success: true}}')

output=$(cd "$UNHEALTHY" && echo "$input" | bash "$SCRIPT")

if [ -z "$output" ] || [ "$output" = "{}" ]; then
  echo "PASS: no violation on clean file"
else
  echo "FAIL: unexpected output on clean file"
  echo "$output"
  exit 1
fi

# Test 3: missing .ais/ produces no output (silent exit)
TMP_DIR=$(mktemp -d)
input=$(jq -n \
  --arg tool "Edit" \
  --arg file "$TMP_DIR/src/routes/users.ts" \
  '{tool_name: $tool, tool_input: {file_path: $file}, tool_response: {success: true}}')

output=$(cd "$TMP_DIR" && echo "$input" | bash "$SCRIPT")
rm -rf "$TMP_DIR"

if [ -z "$output" ] || [ "$output" = "{}" ]; then
  echo "PASS: silent exit when no .ais/ present"
else
  echo "FAIL: unexpected output when no baseline"
  exit 1
fi

echo ""
echo "All analyze-edit.sh tests passed."
