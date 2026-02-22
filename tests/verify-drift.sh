#!/usr/bin/env bash
set -euo pipefail
export THYMUS_NO_OPEN=1

ROOT="$(realpath "$(dirname "$0")/..")"
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

echo "=== Drift Scoring & Trend Tracking Verification ==="
echo ""

APPEND="$ROOT/scripts/append-history.sh"
SCAN="$ROOT/scripts/scan-project.sh"
REPORT="$ROOT/scripts/generate-report.sh"
THYMUS_CLI="$ROOT/bin/thymus"
UNHEALTHY="$ROOT/tests/fixtures/unhealthy-project"

# --- Test 1: append-history.sh exists and is executable ---
echo "Scripts:"
if [ -x "$APPEND" ]; then
  echo "  ✓ append-history.sh exists and is executable"
  ((passed++)) || true
else
  echo "  ✗ append-history.sh missing or not executable"
  ((failed++)) || true
fi

# --- Test 2: Appending a scan produces valid JSONL ---
echo ""
echo "Append scan to history:"

TMPDIR_SCAN=$(mktemp -d)
mkdir -p "$TMPDIR_SCAN/.thymus"
# Initialize a git repo so append-history.sh can get a commit hash
git -C "$TMPDIR_SCAN" init -q 2>/dev/null
git -C "$TMPDIR_SCAN" commit --allow-empty -m "init" -q 2>/dev/null

# Run scan-project.sh on unhealthy fixture, pipe to append-history.sh
SCAN_OUT=$(cd "$UNHEALTHY" && bash "$SCAN" 2>/dev/null)
echo "$SCAN_OUT" | (cd "$TMPDIR_SCAN" && bash "$APPEND" --stdin 2>/dev/null)

HISTORY_FILE="$TMPDIR_SCAN/.thymus/history.jsonl"
if [ -f "$HISTORY_FILE" ] && [ -s "$HISTORY_FILE" ]; then
  LAST_LINE=$(tail -1 "$HISTORY_FILE")
  if echo "$LAST_LINE" | jq -e '.' > /dev/null 2>&1; then
    echo "  ✓ last line is valid JSON"
    ((passed++)) || true
  else
    echo "  ✗ last line is not valid JSON"
    echo "    got: $LAST_LINE"
    ((failed++)) || true
  fi

  # Check required fields
  check_json "has timestamp field" ".timestamp | type" "string" "$LAST_LINE"
  check_json "has commit field" ".commit | type" "string" "$LAST_LINE"
  check_json "has files_checked field" ".files_checked | type" "number" "$LAST_LINE"
  check_json "has violations object" ".violations | type" "object" "$LAST_LINE"
  check_json "has compliance_score field" ".compliance_score | type" "number" "$LAST_LINE"
  check_json "has by_rule field" ".by_rule | type" "object" "$LAST_LINE"
else
  echo "  ✗ history.jsonl not created or empty"
  ((failed++)) || true
fi
rm -rf "$TMPDIR_SCAN"

# --- Test 3: FIFO cap works ---
echo ""
echo "FIFO cap:"

TMPDIR_FIFO=$(mktemp -d)
mkdir -p "$TMPDIR_FIFO/.thymus"
git -C "$TMPDIR_FIFO" init -q 2>/dev/null
git -C "$TMPDIR_FIFO" commit --allow-empty -m "init" -q 2>/dev/null

# Build a minimal scan JSON that append-history.sh can consume
MINI_SCAN='{"files_checked":5,"violations":[],"stats":{"total":0,"errors":0,"warnings":0}}'

# Pre-populate history with 505 entries using direct writes (fast)
for i in $(seq 1 505); do
  echo "{\"timestamp\":\"2026-01-01T00:00:00Z\",\"commit\":\"abc\",\"total_files\":5,\"files_checked\":5,\"violations\":{\"error\":0,\"warn\":0,\"info\":0},\"compliance_score\":100.0,\"by_rule\":{}}" \
    >> "$TMPDIR_FIFO/.thymus/history.jsonl"
done

# Append one more via the script (should trigger FIFO trim to 500)
echo "$MINI_SCAN" | (cd "$TMPDIR_FIFO" && bash "$APPEND" --stdin 2>/dev/null)

LINE_COUNT=$(wc -l < "$TMPDIR_FIFO/.thymus/history.jsonl" | tr -d ' ')
if [ "$LINE_COUNT" -eq 500 ]; then
  echo "  ✓ FIFO cap trims to 500 lines (had 506, now $LINE_COUNT)"
  ((passed++)) || true
else
  echo "  ✗ FIFO cap: expected 500 lines, got $LINE_COUNT"
  ((failed++)) || true
fi
rm -rf "$TMPDIR_FIFO"

# --- Test 4: Compliance score calculation ---
echo ""
echo "Compliance score:"

TMPDIR_COMP=$(mktemp -d)
mkdir -p "$TMPDIR_COMP/.thymus"
git -C "$TMPDIR_COMP" init -q 2>/dev/null
git -C "$TMPDIR_COMP" commit --allow-empty -m "init" -q 2>/dev/null

# 10 files checked, 2 errors => compliance = (10-2)/10 * 100 = 80.0
COMP_SCAN='{"files_checked":10,"violations":[{"severity":"error","rule":"r1"},{"severity":"error","rule":"r2"},{"severity":"warning","rule":"r3"}],"stats":{"total":3,"errors":2,"warnings":1}}'
echo "$COMP_SCAN" | (cd "$TMPDIR_COMP" && bash "$APPEND" --stdin 2>/dev/null)

COMP_LINE=$(tail -1 "$TMPDIR_COMP/.thymus/history.jsonl")
COMP_SCORE=$(echo "$COMP_LINE" | jq -r '.compliance_score')
if [ "$COMP_SCORE" = "80" ] || [ "$COMP_SCORE" = "80.0" ]; then
  echo "  ✓ compliance_score is 80.0 for 10 files / 2 errors"
  ((passed++)) || true
else
  echo "  ✗ compliance_score: expected 80.0, got $COMP_SCORE"
  ((failed++)) || true
fi
rm -rf "$TMPDIR_COMP"

# --- Test 5: `thymus history` shows table output ---
echo ""
echo "CLI commands:"

TMPDIR_CLI=$(mktemp -d)
mkdir -p "$TMPDIR_CLI/.thymus"
git -C "$TMPDIR_CLI" init -q 2>/dev/null
git -C "$TMPDIR_CLI" commit --allow-empty -m "init" -q 2>/dev/null

# Seed history with a valid entry
echo '{"timestamp":"2026-02-22T12:00:00Z","commit":"abc1234","total_files":10,"files_checked":10,"violations":{"error":1,"warn":2,"info":0},"compliance_score":90.0,"by_rule":{"r1":1,"r2":2}}' \
  > "$TMPDIR_CLI/.thymus/history.jsonl"

HISTORY_OUT=$(cd "$TMPDIR_CLI" && bash "$THYMUS_CLI" history 2>/dev/null || true)
if echo "$HISTORY_OUT" | grep -q "TIMESTAMP"; then
  echo "  ✓ thymus history shows TIMESTAMP header"
  ((passed++)) || true
else
  echo "  ✗ thymus history missing TIMESTAMP header"
  echo "    got: $HISTORY_OUT"
  ((failed++)) || true
fi

if echo "$HISTORY_OUT" | grep -q "90.0"; then
  echo "  ✓ thymus history shows data row with score"
  ((passed++)) || true
else
  echo "  ✗ thymus history missing data row"
  echo "    got: $HISTORY_OUT"
  ((failed++)) || true
fi

# --- Test 6: `thymus score` shows percentage ---
SCORE_OUT=$(cd "$TMPDIR_CLI" && bash "$THYMUS_CLI" score 2>/dev/null || true)
if echo "$SCORE_OUT" | grep -qE "Compliance: [0-9]+\.[0-9]+%"; then
  echo "  ✓ thymus score shows Compliance: N.N%"
  ((passed++)) || true
else
  echo "  ✗ thymus score output unexpected"
  echo "    got: $SCORE_OUT"
  ((failed++)) || true
fi

# --- Test 7: `thymus history --json` outputs valid JSONL ---
JSON_OUT=$(cd "$TMPDIR_CLI" && bash "$THYMUS_CLI" history --json 2>/dev/null || true)
# Every line must be valid JSON
JSON_VALID=true
while IFS= read -r line; do
  [ -z "$line" ] && continue
  if ! echo "$line" | jq -e '.' > /dev/null 2>&1; then
    JSON_VALID=false
    break
  fi
done <<< "$JSON_OUT"

if [ "$JSON_VALID" = "true" ] && [ -n "$JSON_OUT" ]; then
  echo "  ✓ thymus history --json outputs valid JSONL"
  ((passed++)) || true
else
  echo "  ✗ thymus history --json has invalid JSONL"
  echo "    got: $JSON_OUT"
  ((failed++)) || true
fi

rm -rf "$TMPDIR_CLI"

# --- Test 8: generate-report.sh produces HTML with compliance score ---
echo ""
echo "Report with compliance:"

TMPDIR_RPT=$(mktemp -d)
mkdir -p "$TMPDIR_RPT/.thymus"
git -C "$TMPDIR_RPT" init -q 2>/dev/null
git -C "$TMPDIR_RPT" commit --allow-empty -m "init" -q 2>/dev/null

# Run scan on unhealthy fixture and save to temp file
SCAN_FILE=$(mktemp)
(cd "$UNHEALTHY" && bash "$SCAN" 2>/dev/null) > "$SCAN_FILE"

RPT_OUT=$(cd "$TMPDIR_RPT" && bash "$REPORT" --scan "$SCAN_FILE" 2>/dev/null || true)
RPT_HTML="$TMPDIR_RPT/.thymus/report.html"

if [ -f "$RPT_HTML" ]; then
  echo "  ✓ report.html created"
  ((passed++)) || true
else
  echo "  ✗ report.html not created"
  ((failed++)) || true
fi

if [ -f "$RPT_HTML" ] && grep -qi "compliance" "$RPT_HTML" 2>/dev/null; then
  echo "  ✓ report.html contains compliance text"
  ((passed++)) || true
else
  echo "  ✗ report.html missing compliance text"
  ((failed++)) || true
fi

# Verify the stdout JSON includes compliance
if echo "$RPT_OUT" | jq -e '.compliance' > /dev/null 2>&1; then
  echo "  ✓ report stdout JSON includes compliance field"
  ((passed++)) || true
else
  echo "  ✗ report stdout JSON missing compliance field"
  echo "    got: $RPT_OUT"
  ((failed++)) || true
fi

rm -f "$SCAN_FILE"
rm -rf "$TMPDIR_RPT"

echo ""
echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
