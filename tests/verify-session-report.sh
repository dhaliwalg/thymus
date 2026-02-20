#!/usr/bin/env bash
set -euo pipefail

SCRIPT="$(realpath "$(dirname "$0")/../scripts/session-report.sh")"
UNHEALTHY="$(realpath "$(dirname "$0")/fixtures/unhealthy-project")"

echo "=== Testing session-report.sh ==="

PROJECT_HASH=$(echo "$UNHEALTHY" | md5 -q 2>/dev/null || echo "$UNHEALTHY" | md5sum | cut -d' ' -f1)
CACHE_DIR="/tmp/ais-cache-${PROJECT_HASH}"
SESSION_FILE="$CACHE_DIR/session-violations.json"

# Setup: pre-populate session cache with 2 violations
mkdir -p "$CACHE_DIR"
cat > "$SESSION_FILE" <<'EOF'
[
  {"rule":"boundary-routes-no-direct-db","severity":"error","message":"Route imports db directly","file":"src/routes/users.ts"},
  {"rule":"convention-test-colocation","severity":"warning","message":"Missing test","file":"src/models/user.model.ts"}
]
EOF

# Run the hook
input='{"session_id":"test-session-123"}'
output=$(cd "$UNHEALTHY" && echo "$input" | bash "$SCRIPT")

# Verify it has a systemMessage
echo "$output" | jq -e '.systemMessage' > /dev/null || { echo "FAIL: no systemMessage"; exit 1; }

msg=$(echo "$output" | jq -r '.systemMessage')

# Should mention the violation counts
echo "$msg" | grep -q "1 error" || { echo "FAIL: should mention 1 error. Got: $msg"; exit 1; }
echo "$msg" | grep -q "1 warning" || { echo "FAIL: should mention 1 warning. Got: $msg"; exit 1; }

echo "PASS: session-report.sh output is correct"

# Cleanup
rm -f "$SESSION_FILE"
