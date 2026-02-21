#!/usr/bin/env bash
set -euo pipefail

ROOT="$(realpath "$(dirname "$0")/..")"

echo "=== Phase 5 Verification ==="
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
    echo "    in: $actual"
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

# --- Task 3: language detection via scan-dependencies.sh ---
echo "Language/framework detection (scan-dependencies.sh):"

SCAN_DEPS="$ROOT/scripts/scan-dependencies.sh"

if [ -x "$SCAN_DEPS" ]; then
  echo "  ✓ scan-dependencies.sh exists and is executable"
  ((passed++)) || true
else
  echo "  ✗ scan-dependencies.sh missing or not executable"
  ((failed++)) || true
fi

# TypeScript + Express detection
TMPDIR_TS=$(mktemp -d)
cat > "$TMPDIR_TS/package.json" <<'JSON'
{
  "name": "my-app",
  "dependencies": {
    "express": "^4.18.0",
    "typescript": "^5.0.0"
  }
}
JSON
echo '{}' > "$TMPDIR_TS/tsconfig.json"
TS_OUT=$(cd "$TMPDIR_TS" && bash "$SCAN_DEPS" "$TMPDIR_TS" 2>/dev/null || true)
check_json "detects typescript language" ".language" "typescript" "$TS_OUT"
rm -rf "$TMPDIR_TS"

# Python + Django detection
TMPDIR_PY=$(mktemp -d)
cat > "$TMPDIR_PY/pyproject.toml" <<'TOML'
[project]
name = "my-django-app"
dependencies = ["django>=4.0", "djangorestframework"]
TOML
PY_OUT=$(cd "$TMPDIR_PY" && bash "$SCAN_DEPS" "$TMPDIR_PY" 2>/dev/null || true)
check_json "detects python language" ".language" "python" "$PY_OUT"
rm -rf "$TMPDIR_PY"

# Go detection
TMPDIR_GO=$(mktemp -d)
cat > "$TMPDIR_GO/go.mod" <<'GOMOD'
module github.com/example/myapp

go 1.21
GOMOD
mkdir -p "$TMPDIR_GO/src"
echo 'package main' > "$TMPDIR_GO/src/main.go"
GO_OUT=$(cd "$TMPDIR_GO" && bash "$SCAN_DEPS" "$TMPDIR_GO" 2>/dev/null || true)
check_json "detects go language" ".language" "go" "$GO_OUT"
rm -rf "$TMPDIR_GO"

# --- Task 4: edge case hardening ---
echo ""
echo "analyze-edit.sh edge cases:"

ANALYZE="$ROOT/scripts/analyze-edit.sh"
UNHEALTHY="$ROOT/tests/fixtures/unhealthy-project"

# Test: binary file is silently skipped (no output, exit 0)
TMPDIR_BIN=$(mktemp -d)
cp -r "$UNHEALTHY/.thymus" "$TMPDIR_BIN/"
# Create a binary file (PNG magic bytes)
printf '\x89PNG\r\n\x1a\n' > "$TMPDIR_BIN/image.png"
BIN_OUT=$(cd "$TMPDIR_BIN" && printf '{"tool_name":"Write","tool_input":{"file_path":"%s/image.png"},"tool_response":{"success":true},"session_id":"test"}' "$TMPDIR_BIN" \
  | bash "$ANALYZE" 2>/dev/null || true)
if [ -z "$BIN_OUT" ] || echo "$BIN_OUT" | jq -e '. == {} or .systemMessage == null' > /dev/null 2>&1; then
  echo "  ✓ binary file produces no violation output"
  ((passed++)) || true
else
  echo "  ✗ binary file should be silently skipped"
  echo "    got: $BIN_OUT"
  ((failed++)) || true
fi
rm -rf "$TMPDIR_BIN"

# Test: very large file is silently skipped
TMPDIR_LARGE=$(mktemp -d)
cp -r "$UNHEALTHY/.thymus" "$TMPDIR_LARGE/"
# Create a large file (600KB of text with forbidden import)
python3 -c "
import os
content = 'x = 1\n' * 100000 + \"from '../db/client' import db\n\"
open('$TMPDIR_LARGE/big.ts', 'w').write(content)
"
LARGE_OUT=$(cd "$TMPDIR_LARGE" && printf '{"tool_name":"Write","tool_input":{"file_path":"%s/big.ts"},"tool_response":{"success":true},"session_id":"test"}' "$TMPDIR_LARGE" \
  | bash "$ANALYZE" 2>/dev/null || true)
if [ -z "$LARGE_OUT" ] || echo "$LARGE_OUT" | jq -e '. == {} or .systemMessage == null' > /dev/null 2>&1; then
  echo "  ✓ large file (>500KB) is silently skipped"
  ((passed++)) || true
else
  echo "  ✗ large file should be skipped"
  echo "    got: $LARGE_OUT"
  ((failed++)) || true
fi
rm -rf "$TMPDIR_LARGE"

# --- Task 5: Python fixture scan ---
echo ""
echo "Python fixture scan:"

PYTHON_FIXTURE="$ROOT/tests/fixtures/python-project"
SCAN="$ROOT/scripts/scan-project.sh"

if [ -d "$PYTHON_FIXTURE" ]; then
  echo "  ✓ python-project fixture exists"
  ((passed++)) || true
else
  echo "  ✗ python-project fixture missing"
  ((failed++)) || true
fi

# Scan should detect the pattern violation (raw SQL in route file)
if [ -d "$PYTHON_FIXTURE" ]; then
  PY_SCAN=$(cd "$PYTHON_FIXTURE" && bash "$SCAN" 2>/dev/null)
  if echo "$PY_SCAN" | jq -e '[.violations[].rule] | any(. == "pattern-no-raw-sql-python")' > /dev/null 2>&1; then
    echo "  ✓ Python project scan detects pattern-no-raw-sql-python violation"
    ((passed++)) || true
  else
    echo "  ✗ Python project scan did not detect pattern-no-raw-sql-python"
    echo "    output: $PY_SCAN"
    ((failed++)) || true
  fi
fi

# --- AST import extraction ---
echo ""
echo "AST import extraction:"

AST_OUT=$(bash "$ROOT/tests/verify-ast-imports.sh" 2>&1)
if echo "$AST_OUT" | grep -q "0 failed"; then
  echo "  ✓ AST import extraction tests pass"
  ((passed++)) || true
else
  echo "  ✗ AST import extraction regression"
  echo "$AST_OUT" | grep "✗" | head -5
  ((failed++)) || true
fi

# --- False positive elimination: commented-import.ts ---
echo ""
echo "False positive elimination:"

SCAN="$ROOT/scripts/scan-project.sh"
UNHEALTHY="$ROOT/tests/fixtures/unhealthy-project"
FP_SCAN=$(cd "$UNHEALTHY" && bash "$SCAN" 2>/dev/null)
FP_BOUNDARY=$(echo "$FP_SCAN" | jq '[.violations[] | select(.file | contains("commented-import")) | select(.rule == "boundary-routes-no-direct-db")] | length')
if [ "$FP_BOUNDARY" -eq 0 ]; then
  echo "  ✓ commented-import.ts has no false boundary violations"
  ((passed++)) || true
else
  echo "  ✗ commented-import.ts still has $FP_BOUNDARY false boundary violation(s)"
  ((failed++)) || true
fi

# --- Final regression: all previous phases still pass ---
echo ""
echo "Phase regression:"

P2_OUT=$(bash "$ROOT/tests/verify-phase2.sh" 2>&1)
if echo "$P2_OUT" | grep -q "0 failed"; then
  echo "  ✓ Phase 2 tests still pass"
  ((passed++)) || true
else
  echo "  ✗ Phase 2 regression"
  ((failed++)) || true
fi

P3_OUT=$(bash "$ROOT/tests/verify-phase3.sh" 2>&1)
if echo "$P3_OUT" | grep -q "0 failed"; then
  echo "  ✓ Phase 3 tests still pass"
  ((passed++)) || true
else
  echo "  ✗ Phase 3 regression"
  ((failed++)) || true
fi

echo ""
echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
