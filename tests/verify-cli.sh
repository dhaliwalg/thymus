#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UNHEALTHY="$ROOT/tests/fixtures/unhealthy-project"
HEALTHY="$ROOT/tests/fixtures/healthy-project"

echo "=== CLI Verification ==="
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
    echo "    expected to find: $expected"
    echo "    in: $(echo "$actual" | head -5)"
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

check_exit() {
  local desc="$1" expected_code="$2"
  shift 2
  local actual_code
  set +e
  "$@" > /dev/null 2>&1
  actual_code=$?
  set -e
  if [ "$actual_code" -eq "$expected_code" ]; then
    echo "  ✓ $desc"
    ((passed++)) || true
  else
    echo "  ✗ $desc (exit $actual_code, expected $expected_code)"
    ((failed++)) || true
  fi
}

# --- thymus-check ---
echo "thymus-check:"

# Test: check a file with violations → exit 1, valid JSON
output=$(cd "$UNHEALTHY" && "$ROOT/bin/thymus-check" src/routes/users.ts --format json 2>/dev/null || true)
check "detects boundary violation" "boundary-routes-no-direct-db" "$output"
check_json "output uses rule_id field" ".[0].rule_id" "boundary-routes-no-direct-db" "$output"
check_json "severity is error" ".[0].severity" "error" "$output"
check_json "file field is relative path" ".[0].file" "src/routes/users.ts" "$output"
check_json "import_path field present" ".[0].import_path" "../db/client" "$output"

# Test: check a clean file → exit 0, empty array
output=$(cd "$HEALTHY" && "$ROOT/bin/thymus-check" src/routes/users.ts --format json 2>/dev/null)
check_json "clean file returns empty array" ". | length" "0" "$output"
check_exit "clean file exits 0" 0 bash -c "cd '$HEALTHY' && '$ROOT/bin/thymus-check' src/routes/users.ts --format json"

# Test: check violation file exits 1
check_exit "violation file exits 1" 1 bash -c "cd '$UNHEALTHY' && '$ROOT/bin/thymus-check' src/routes/users.ts --format json"

# Test: nonexistent file exits 2
check_exit "nonexistent file exits 2" 2 bash -c "cd '$UNHEALTHY' && '$ROOT/bin/thymus-check' nonexistent.ts --format json"

# Test: text format output
text_output=$(cd "$UNHEALTHY" && "$ROOT/bin/thymus-check" src/routes/users.ts --format text 2>/dev/null || true)
check "text format shows file path" "src/routes/users.ts" "$text_output"
check "text format shows severity" "error" "$text_output"

echo ""
echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ] || exit 1
