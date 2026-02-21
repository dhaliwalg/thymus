#!/usr/bin/env bash
set -euo pipefail

ROOT="$(realpath "$(dirname "$0")/..")"
UNHEALTHY="$ROOT/tests/fixtures/unhealthy-project"
HEALTHY="$ROOT/tests/fixtures/healthy-project"

echo "=== Phase 2 End-to-End Verification ==="
echo ""

passed=0
failed=0

check_output() {
  local desc="$1"
  local expected="$2"
  local actual="$3"
  if echo "$actual" | grep -q "$expected"; then
    echo "  ✓ $desc"
    ((passed++)) || true
  else
    echo "  ✗ $desc (got: $actual)"
    ((failed++)) || true
  fi
}

check_empty() {
  local desc="$1"
  local actual="$2"
  if [ -z "$actual" ] || [ "$actual" = "{}" ]; then
    echo "  ✓ $desc"
    ((passed++)) || true
  else
    echo "  ✗ $desc (expected empty, got: $actual)"
    ((failed++)) || true
  fi
}

# --- analyze-edit.sh tests ---
echo "analyze-edit.sh:"

# Build test input for unhealthy route (boundary violation)
input=$(jq -n \
  --arg file "$UNHEALTHY/src/routes/users.ts" \
  '{tool_name:"Edit",tool_input:{file_path:$file},tool_response:{success:true}}')

output=$(cd "$UNHEALTHY" && echo "$input" | bash "$ROOT/scripts/analyze-edit.sh")
check_output "detects boundary violation on unhealthy route" "boundary-routes-no-direct-db" "$output"
check_output "systemMessage contains thymus warning" "thymus:" "$output"

# Build test input for healthy route (no violation)
input=$(jq -n \
  --arg file "$HEALTHY/src/routes/users.ts" \
  '{tool_name:"Edit",tool_input:{file_path:$file},tool_response:{success:true}}')

output=$(cd "$HEALTHY" && echo "$input" | bash "$ROOT/scripts/analyze-edit.sh")
check_empty "no violation on healthy route" "$output"

# --- session-report.sh tests ---
echo ""
echo "session-report.sh:"
if bash "$ROOT/tests/verify-session-report.sh" > /dev/null 2>&1; then
  echo "  ✓ session report test suite"
  ((passed++)) || true
else
  echo "  ✗ session report test suite"
  ((failed++)) || true
fi

# --- load-baseline.sh tests ---
echo ""
echo "load-baseline.sh:"
output=$(cd "$UNHEALTHY" && echo '{}' | bash "$ROOT/scripts/load-baseline.sh")
check_output "shows module count when baseline exists" "modules" "$output"
check_output "shows invariant count" "invariants active" "$output"

# No baseline → setup prompt
tmp=$(mktemp -d)
output=$(cd "$tmp" && echo '{}' | bash "$ROOT/scripts/load-baseline.sh")
check_output "shows setup prompt when no baseline" "no baseline" "$output"
rm -rf "$tmp"

# --- Timing tests ---
echo ""
echo "Performance:"
input=$(jq -n --arg file "$UNHEALTHY/src/routes/users.ts" '{tool_name:"Edit",tool_input:{file_path:$file},tool_response:{success:true}}')
start_ns=$(date +%s%N 2>/dev/null || echo "")
cd "$UNHEALTHY" && echo "$input" | bash "$ROOT/scripts/analyze-edit.sh" > /dev/null
end_ns=$(date +%s%N 2>/dev/null || echo "")

if [ -n "$start_ns" ] && [[ "$start_ns" =~ ^[0-9]{18,}$ ]]; then
  elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))
  if [ "$elapsed_ms" -lt 2000 ]; then
    echo "  ✓ analyze-edit.sh < 2s (${elapsed_ms}ms)"
    ((passed++)) || true
  else
    echo "  ✗ analyze-edit.sh too slow (${elapsed_ms}ms)"
    ((failed++)) || true
  fi
else
  echo "  ~ timing: use 'time' manually to verify < 2s"
fi

echo ""
echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ] || exit 1
