#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UNHEALTHY="$ROOT/tests/fixtures/unhealthy-project"
HEALTHY="$ROOT/tests/fixtures/healthy-project"

echo "=== CI Output Format Tests ==="
echo ""

passed=0
failed=0

check() {
  local desc="$1" expected="$2" actual="$3"
  if echo "$actual" | grep -qF "$expected"; then
    echo "  ✓ $desc"
    ((passed++)) || true
  else
    echo "  ✗ $desc"
    echo "    expected to find: $expected"
    echo "    in: $(echo "$actual" | head -3)"
    ((failed++)) || true
  fi
}

check_not() {
  local desc="$1" unwanted="$2" actual="$3"
  if echo "$actual" | grep -qF "$unwanted"; then
    echo "  ✗ $desc"
    echo "    should NOT contain: $unwanted"
    ((failed++)) || true
  else
    echo "  ✓ $desc"
    ((passed++)) || true
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

# --- GitHub annotation format ---
echo "GitHub annotation format (--format github):"

GH_OUT=$(cd "$UNHEALTHY" && "$ROOT/bin/thymus-scan" --format github 2>/dev/null || true)

check "contains ::error annotation" "::error file=" "$GH_OUT"
check "contains ::warning annotation" "::warning file=" "$GH_OUT"
check "error annotation has file path" "src/routes/users.ts" "$GH_OUT"
check "annotation contains message" "must not import" "$GH_OUT"

# Healthy project should produce no annotations
GH_HEALTHY=$(cd "$HEALTHY" && "$ROOT/bin/thymus-scan" --format github 2>/dev/null || true)
if [ -z "$GH_HEALTHY" ]; then
  echo "  ✓ healthy project produces no annotations"
  ((passed++)) || true
else
  echo "  ✗ healthy project should produce no annotations"
  echo "    got: $GH_HEALTHY"
  ((failed++)) || true
fi

# --- SARIF format ---
echo ""
echo "SARIF format (--format sarif):"

SARIF_OUT=$(cd "$UNHEALTHY" && "$ROOT/bin/thymus-scan" --format sarif 2>/dev/null || true)

check_json "SARIF version is 2.1.0" ".version" "2.1.0" "$SARIF_OUT"
check_json "has \$schema field" '.["$schema"] | length > 0 | tostring' "true" "$SARIF_OUT"
check_json "has runs array" ".runs | length | tostring" "1" "$SARIF_OUT"
check_json "tool name is Thymus" ".runs[0].tool.driver.name" "Thymus" "$SARIF_OUT"
check_json "has rules" ".runs[0].tool.driver.rules | length > 0 | tostring" "true" "$SARIF_OUT"
check_json "has results" ".runs[0].results | length > 0 | tostring" "true" "$SARIF_OUT"

# Check that boundary violation appears in SARIF results
SARIF_RULE_IDS=$(echo "$SARIF_OUT" | jq -r '.runs[0].results[].ruleId' 2>/dev/null)
check "SARIF contains boundary rule" "boundary-routes-no-direct-db" "$SARIF_RULE_IDS"

# Check SARIF result has proper location
SARIF_FILE=$(echo "$SARIF_OUT" | jq -r '.runs[0].results[] | select(.ruleId == "boundary-routes-no-direct-db") | .locations[0].physicalLocation.artifactLocation.uri' 2>/dev/null)
check "SARIF result has file location" "src/routes/users.ts" "$SARIF_FILE"

# Check rule has severity level
SARIF_LEVEL=$(echo "$SARIF_OUT" | jq -r '.runs[0].results[] | select(.ruleId == "boundary-routes-no-direct-db") | .level' 2>/dev/null)
if [ "$SARIF_LEVEL" = "error" ]; then
  echo "  ✓ SARIF boundary violation has error level"
  ((passed++)) || true
else
  echo "  ✗ SARIF boundary violation level (got $SARIF_LEVEL, expected error)"
  ((failed++)) || true
fi

# Healthy project SARIF should have empty results
SARIF_HEALTHY=$(cd "$HEALTHY" && "$ROOT/bin/thymus-scan" --format sarif 2>/dev/null || true)
SARIF_HEALTHY_COUNT=$(echo "$SARIF_HEALTHY" | jq '.runs[0].results | length' 2>/dev/null || echo "PARSE_ERROR")
if [ "$SARIF_HEALTHY_COUNT" = "0" ]; then
  echo "  ✓ healthy project SARIF has 0 results"
  ((passed++)) || true
else
  echo "  ✗ healthy project SARIF should have 0 results (got $SARIF_HEALTHY_COUNT)"
  ((failed++)) || true
fi

# --- thymus-check with SARIF format ---
echo ""
echo "thymus-check SARIF format:"

CHECK_SARIF=$(cd "$UNHEALTHY" && "$ROOT/bin/thymus-check" src/routes/users.ts --format sarif 2>/dev/null || true)
check_json "check SARIF version" ".version" "2.1.0" "$CHECK_SARIF"
check_json "check SARIF has results" ".runs[0].results | length > 0 | tostring" "true" "$CHECK_SARIF"

# --- thymus-check with GitHub format ---
echo ""
echo "thymus-check GitHub format:"

CHECK_GH=$(cd "$UNHEALTHY" && "$ROOT/bin/thymus-check" src/routes/users.ts --format github 2>/dev/null || true)
check "check github has ::error" "::error file=" "$CHECK_GH"
check "check github has file path" "src/routes/users.ts" "$CHECK_GH"

# --- Pre-commit THYMUS_STRICT ---
echo ""
echo "Pre-commit THYMUS_STRICT:"

# Test: THYMUS_STRICT=1 blocks on warnings
TMPDIR_STRICT=$(mktemp -d)
git init "$TMPDIR_STRICT" > /dev/null 2>&1
cp -r "$UNHEALTHY/.thymus" "$TMPDIR_STRICT/"
cp -r "$UNHEALTHY/src" "$TMPDIR_STRICT/"
cp "$UNHEALTHY/package.json" "$TMPDIR_STRICT/"
cp -r "$ROOT/bin" "$TMPDIR_STRICT/"
cp -r "$ROOT/scripts" "$TMPDIR_STRICT/"
cp -r "$ROOT/templates" "$TMPDIR_STRICT/"
# Stage only model file (produces warning-level convention violation, not error boundary)
(cd "$TMPDIR_STRICT" && git add src/models/user.model.ts > /dev/null 2>&1)

# Without THYMUS_STRICT: should pass (warnings only)
strict_exit_normal=0
(cd "$TMPDIR_STRICT" && bash "$ROOT/integrations/pre-commit/thymus-pre-commit" > /dev/null 2>&1) || strict_exit_normal=$?
if [ "$strict_exit_normal" -eq 0 ]; then
  echo "  ✓ warnings-only commit passes without THYMUS_STRICT"
  ((passed++)) || true
else
  echo "  ✗ warnings-only commit should pass without THYMUS_STRICT (exit=$strict_exit_normal)"
  ((failed++)) || true
fi

# With THYMUS_STRICT=1: should block
strict_exit=0
strict_output=$(cd "$TMPDIR_STRICT" && THYMUS_STRICT=1 bash "$ROOT/integrations/pre-commit/thymus-pre-commit" 2>&1) || strict_exit=$?
if [ "$strict_exit" -ne 0 ]; then
  echo "  ✓ THYMUS_STRICT=1 blocks commit with warnings"
  ((passed++)) || true
else
  echo "  ✗ THYMUS_STRICT=1 should block commit with warnings"
  ((failed++)) || true
fi
check "THYMUS_STRICT output mentions strict mode" "THYMUS_STRICT" "$strict_output"

rm -rf "$TMPDIR_STRICT"

# --- Pre-commit summary format ---
echo ""
echo "Pre-commit summary format:"

TMPDIR_SUMMARY=$(mktemp -d)
git init "$TMPDIR_SUMMARY" > /dev/null 2>&1
cp -r "$UNHEALTHY/.thymus" "$TMPDIR_SUMMARY/"
cp -r "$UNHEALTHY/src" "$TMPDIR_SUMMARY/"
cp "$UNHEALTHY/package.json" "$TMPDIR_SUMMARY/"
cp -r "$ROOT/bin" "$TMPDIR_SUMMARY/"
cp -r "$ROOT/scripts" "$TMPDIR_SUMMARY/"
cp -r "$ROOT/templates" "$TMPDIR_SUMMARY/"
(cd "$TMPDIR_SUMMARY" && git add src/routes/users.ts > /dev/null 2>&1)

summary_output=$(cd "$TMPDIR_SUMMARY" && bash "$ROOT/integrations/pre-commit/thymus-pre-commit" 2>&1 || true)
check "summary has violation count" "violation(s)" "$summary_output"
check "summary has error count" "error(s)" "$summary_output"
check "summary has warning count" "warning(s)" "$summary_output"

rm -rf "$TMPDIR_SUMMARY"

# --- Format validation ---
echo ""
echo "Format validation:"

# Invalid format should exit 2
invalid_exit=0
(cd "$UNHEALTHY" && "$ROOT/bin/thymus-scan" --format xml 2>/dev/null) || invalid_exit=$?
if [ "$invalid_exit" -eq 2 ]; then
  echo "  ✓ invalid format exits 2"
  ((passed++)) || true
else
  echo "  ✗ invalid format should exit 2 (got $invalid_exit)"
  ((failed++)) || true
fi

# --- Action.yml structure ---
echo ""
echo "Action.yml enhancements:"

ACTION="$ROOT/integrations/github-actions/action.yml"
check "action.yml has format input" "format:" "$(cat "$ACTION")"
check "action.yml has sarif-upload input" "sarif-upload:" "$(cat "$ACTION")"
check "action.yml has agents-md-check input" "agents-md-check:" "$(cat "$ACTION")"
check "action.yml has SARIF upload step" "upload-sarif" "$(cat "$ACTION")"

echo ""
echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ] || exit 1
