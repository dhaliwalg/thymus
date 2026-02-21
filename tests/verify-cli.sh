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

# --- thymus (main entry point) ---
echo "thymus (entry point):"

# Test: version command
output=$("$ROOT/bin/thymus" version 2>/dev/null)
check "version outputs version string" "thymus" "$output"
check_exit "version exits 0" 0 "$ROOT/bin/thymus" version

# Test: no args shows usage
output=$("$ROOT/bin/thymus" 2>/dev/null || true)
check "no args shows usage" "Usage:" "$output"

# Test: scan subcommand routes to thymus-scan
output=$(cd "$UNHEALTHY" && "$ROOT/bin/thymus" scan --format json 2>/dev/null || true)
check "scan routes correctly" "boundary-routes-no-direct-db" "$output"

# Test: check subcommand routes to thymus-check
output=$(cd "$UNHEALTHY" && "$ROOT/bin/thymus" check src/routes/users.ts --format json 2>/dev/null || true)
check "check routes correctly" "boundary-routes-no-direct-db" "$output"

# Test: init subcommand
TMPDIR_ENTRY=$(mktemp -d)
"$ROOT/bin/thymus" init "$TMPDIR_ENTRY" > /dev/null 2>&1
if [ -f "$TMPDIR_ENTRY/.thymus/invariants.yml" ]; then
  echo "  ✓ init routes correctly"
  ((passed++)) || true
else
  echo "  ✗ init routing failed"
  ((failed++)) || true
fi
rm -rf "$TMPDIR_ENTRY"

# Test: unknown command exits 2
check_exit "unknown command exits 2" 2 "$ROOT/bin/thymus" foobar

echo ""
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

# --- thymus-init ---
echo ""
echo "thymus-init:"

# Test: init creates .thymus/ with starter files
TMPDIR_INIT=$(mktemp -d)
"$ROOT/bin/thymus-init" "$TMPDIR_INIT" > /dev/null 2>&1
if [ -f "$TMPDIR_INIT/.thymus/invariants.yml" ]; then
  echo "  ✓ creates invariants.yml"
  ((passed++)) || true
else
  echo "  ✗ invariants.yml not created"
  ((failed++)) || true
fi
if [ -f "$TMPDIR_INIT/.thymus/config.yml" ]; then
  echo "  ✓ creates config.yml"
  ((passed++)) || true
else
  echo "  ✗ config.yml not created"
  ((failed++)) || true
fi

# Test: invariants.yml is valid YAML with at least a version field
if grep -q "version:" "$TMPDIR_INIT/.thymus/invariants.yml" 2>/dev/null; then
  echo "  ✓ invariants.yml has version field"
  ((passed++)) || true
else
  echo "  ✗ invariants.yml missing version"
  ((failed++)) || true
fi

# Test: init does not overwrite existing files
echo "custom: true" > "$TMPDIR_INIT/.thymus/config.yml"
"$ROOT/bin/thymus-init" "$TMPDIR_INIT" > /dev/null 2>&1 || true
if grep -q "custom: true" "$TMPDIR_INIT/.thymus/config.yml" 2>/dev/null; then
  echo "  ✓ does not overwrite existing config"
  ((passed++)) || true
else
  echo "  ✗ overwrote existing config"
  ((failed++)) || true
fi

# Test: init with no args uses $PWD
TMPDIR_INIT2=$(mktemp -d)
(cd "$TMPDIR_INIT2" && "$ROOT/bin/thymus-init") > /dev/null 2>&1
if [ -f "$TMPDIR_INIT2/.thymus/invariants.yml" ]; then
  echo "  ✓ init with no args uses PWD"
  ((passed++)) || true
else
  echo "  ✗ init with no args failed"
  ((failed++)) || true
fi

rm -rf "$TMPDIR_INIT" "$TMPDIR_INIT2"

# --- pre-commit hook ---
echo ""
echo "pre-commit hook:"

# Test: hook script exists and is executable
if [ -x "$ROOT/integrations/pre-commit/thymus-pre-commit" ]; then
  echo "  ✓ thymus-pre-commit is executable"
  ((passed++)) || true
else
  echo "  ✗ thymus-pre-commit missing or not executable"
  ((failed++)) || true
fi

# Test: hook blocks commit with error-severity violations
TMPDIR_HOOK=$(mktemp -d)
git init "$TMPDIR_HOOK" > /dev/null 2>&1
cp -r "$UNHEALTHY/.thymus" "$TMPDIR_HOOK/"
cp -r "$UNHEALTHY/src" "$TMPDIR_HOOK/"
cp "$UNHEALTHY/package.json" "$TMPDIR_HOOK/"
# Copy bin/ so the hook can find it
cp -r "$ROOT/bin" "$TMPDIR_HOOK/"
# Copy scripts/ so bin/ can find them
cp -r "$ROOT/scripts" "$TMPDIR_HOOK/"
# Copy templates/ for init
cp -r "$ROOT/templates" "$TMPDIR_HOOK/"
(cd "$TMPDIR_HOOK" && git add src/routes/users.ts > /dev/null 2>&1)
hook_exit=0
hook_output=$(cd "$TMPDIR_HOOK" && bash "$ROOT/integrations/pre-commit/thymus-pre-commit" 2>&1) || hook_exit=$?
# The hook should detect violations and exit 1
if [ "$hook_exit" -ne 0 ] && echo "$hook_output" | grep -q "violation"; then
  echo "  ✓ hook blocks commit with error violations"
  ((passed++)) || true
else
  echo "  ✗ hook did not block (exit=$hook_exit, output: $hook_output)"
  ((failed++)) || true
fi
rm -rf "$TMPDIR_HOOK"

# Test: hook allows commit with only warnings
TMPDIR_HOOK2=$(mktemp -d)
git init "$TMPDIR_HOOK2" > /dev/null 2>&1
cp -r "$UNHEALTHY/.thymus" "$TMPDIR_HOOK2/"
cp -r "$UNHEALTHY/src" "$TMPDIR_HOOK2/"
cp "$UNHEALTHY/package.json" "$TMPDIR_HOOK2/"
cp -r "$ROOT/bin" "$TMPDIR_HOOK2/"
cp -r "$ROOT/scripts" "$TMPDIR_HOOK2/"
cp -r "$ROOT/templates" "$TMPDIR_HOOK2/"
# Stage only the model file (which has a warning-level convention violation, not error boundary)
(cd "$TMPDIR_HOOK2" && git add src/models/user.model.ts > /dev/null 2>&1)
hook_exit2=0
(cd "$TMPDIR_HOOK2" && bash "$ROOT/integrations/pre-commit/thymus-pre-commit" > /dev/null 2>&1) || hook_exit2=$?
if [ "$hook_exit2" -eq 0 ]; then
  echo "  ✓ hook allows commit with warnings only"
  ((passed++)) || true
else
  echo "  ✗ hook blocked commit with only warnings (exit=$hook_exit2)"
  ((failed++)) || true
fi
rm -rf "$TMPDIR_HOOK2"

# Test: .pre-commit-hooks.yaml exists and is valid YAML
if [ -f "$ROOT/integrations/pre-commit/.pre-commit-hooks.yaml" ]; then
  echo "  ✓ .pre-commit-hooks.yaml exists"
  ((passed++)) || true
else
  echo "  ✗ .pre-commit-hooks.yaml missing"
  ((failed++)) || true
fi

# --- GitHub Action ---
echo ""
echo "GitHub Action:"

# Test: action.yml exists
if [ -f "$ROOT/integrations/github-actions/action.yml" ]; then
  echo "  ✓ action.yml exists"
  ((passed++)) || true
else
  echo "  ✗ action.yml missing"
  ((failed++)) || true
fi

# Test: action.yml has required fields
if grep -q "name:" "$ROOT/integrations/github-actions/action.yml" 2>/dev/null && \
   grep -q "inputs:" "$ROOT/integrations/github-actions/action.yml" 2>/dev/null; then
  echo "  ✓ action.yml has name and inputs"
  ((passed++)) || true
else
  echo "  ✗ action.yml missing required fields"
  ((failed++)) || true
fi

echo ""
echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ] || exit 1
