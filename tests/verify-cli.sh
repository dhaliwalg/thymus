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

# --- thymus-scan ---
echo ""
echo "thymus-scan:"

# Test: scan unhealthy project → violations found, valid JSON
output=$(cd "$UNHEALTHY" && "$ROOT/bin/thymus-scan" --format json 2>/dev/null || true)
check "scan detects boundary violation" "boundary-routes-no-direct-db" "$output"
check_json "output is array" ". | type" "array" "$output"
check_json "violations use rule_id field" ".[0].rule_id" "boundary-routes-no-direct-db" "$(echo "$output" | jq '[.[] | select(.rule_id == "boundary-routes-no-direct-db")]')"
check_json "severity maps warning→warn" ".[0].severity" "warn" "$(echo "$output" | jq '[.[] | select(.severity == "warn")]')"

# Test: scan healthy project → empty array, exit 0
output=$(cd "$HEALTHY" && "$ROOT/bin/thymus-scan" --format json 2>/dev/null || true)
check_json "healthy project returns empty array" ". | length" "0" "$output"
check_exit "healthy scan exits 0" 0 bash -c "cd '$HEALTHY' && '$ROOT/bin/thymus-scan' --format json"

# Test: scan with violations exits 1
check_exit "violation scan exits 1" 1 bash -c "cd '$UNHEALTHY' && '$ROOT/bin/thymus-scan' --format json"

# Test: --diff flag (staged files only)
# Create a temp git repo, stage a file with violation
TMPDIR_DIFF=$(mktemp -d)
git init "$TMPDIR_DIFF" > /dev/null 2>&1
cp -r "$UNHEALTHY/.thymus" "$TMPDIR_DIFF/"
cp -r "$UNHEALTHY/src" "$TMPDIR_DIFF/"
cp "$UNHEALTHY/package.json" "$TMPDIR_DIFF/"
(cd "$TMPDIR_DIFF" && git add src/routes/users.ts > /dev/null 2>&1)
output=$(cd "$TMPDIR_DIFF" && "$ROOT/bin/thymus-scan" --diff --format json 2>/dev/null || true)
check "diff mode scans staged files" "boundary-routes-no-direct-db" "$output"
rm -rf "$TMPDIR_DIFF"

# Test: --files flag
output=$(cd "$UNHEALTHY" && "$ROOT/bin/thymus-scan" --files src/routes/users.ts --format json 2>/dev/null || true)
check "files flag scans specific file" "boundary-routes-no-direct-db" "$output"

# Test: text format
text_output=$(cd "$UNHEALTHY" && "$ROOT/bin/thymus-scan" --format text 2>/dev/null || true)
check "text format shows violation count" "violation" "$text_output"

echo ""
echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ] || exit 1
