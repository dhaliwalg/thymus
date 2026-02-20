#!/usr/bin/env bash
set -euo pipefail

ROOT="$(realpath "$(dirname "$0")/..")"
SCAN="$ROOT/scripts/scan-project.sh"
UNHEALTHY="$ROOT/tests/fixtures/unhealthy-project"
HEALTHY="$ROOT/tests/fixtures/healthy-project"

echo "=== Phase 3 Verification ==="
echo ""

passed=0
failed=0

check() {
  local desc="$1" expected="$2" actual="$3"
  if echo "$actual" | grep -q "$expected"; then
    echo "  ✓ $desc"
    ((passed++)) || true
  else
    echo "  ✗ $desc"
    echo "    expected: $expected"
    echo "    got: $actual"
    ((failed++)) || true
  fi
}

check_json() {
  local desc="$1" jq_expr="$2" expected="$3" actual="$4"
  local val
  val=$(echo "$actual" | jq -r "$jq_expr" 2>/dev/null || echo "PARSE_ERROR")
  if [ "$val" = "$expected" ]; then
    echo "  ✓ $desc"
    ((passed++)) || true
  else
    echo "  ✗ $desc (got $val, expected $expected)"
    ((failed++)) || true
  fi
}

# --- scan-project.sh ---
echo "scan-project.sh:"

# Test 1: unhealthy project detects boundary violation
output=$(cd "$UNHEALTHY" && bash "$SCAN" 2>/dev/null)
check "detects boundary violation" "boundary-routes-no-direct-db" "$output"

# Test 2: healthy project produces zero violations
output=$(cd "$HEALTHY" && bash "$SCAN" 2>/dev/null)
check_json "healthy project has 0 violations" ".stats.total" "0" "$output"

# Test 3: scope limiting — scanning only src/db produces no boundary violations
output=$(cd "$UNHEALTHY" && bash "$SCAN" src/db 2>/dev/null)
if echo "$output" | jq -e '.violations | map(select(.rule == "boundary-routes-no-direct-db")) | length == 0' > /dev/null 2>&1; then
  echo "  ✓ scope limits scan to target directory"
  ((passed++)) || true
else
  echo "  ✗ scope limiting failed"
  ((failed++)) || true
fi

# Test 4: scope_glob_exclude — pattern-no-raw-sql must NOT fire on src/db files
output=$(cd "$UNHEALTHY" && bash "$SCAN" src/db 2>/dev/null)
if echo "$output" | jq -e '[.violations[] | select(.rule == "pattern-no-raw-sql" and (.file | startswith("src/db/")))] | length == 0' > /dev/null 2>&1; then
  echo "  ✓ scope_glob_exclude suppresses pattern rule on excluded paths"
  ((passed++)) || true
else
  echo "  ✗ scope_glob_exclude did not suppress pattern rule on src/db"
  echo "    output: $output"
  ((failed++)) || true
fi

# Test 5: output is valid JSON with expected shape
output=$(cd "$UNHEALTHY" && bash "$SCAN" 2>/dev/null)
if echo "$output" | jq -e '.violations and .stats' > /dev/null 2>&1; then
  echo "  ✓ output is valid JSON with violations and stats"
  ((passed++)) || true
else
  echo "  ✗ output is not valid JSON or missing fields"
  ((failed++)) || true
fi

# Test 6: stats.errors and stats.warnings are integers
check_json "stats.errors is a number" ".stats.errors | type" "number" "$output"

echo ""
echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ] || exit 1
