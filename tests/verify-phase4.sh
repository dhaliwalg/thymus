#!/usr/bin/env bash
set -euo pipefail

ROOT="$(realpath "$(dirname "$0")/..")"
ADD="$ROOT/scripts/add-invariant.sh"
UNHEALTHY="$ROOT/tests/fixtures/unhealthy-project"

echo "=== Phase 4 Verification ==="
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

# --- Task 1: add-invariant.sh ---
echo "add-invariant.sh:"

TMPDIR_TEST=$(mktemp -d)
cp "$UNHEALTHY/.thymus/invariants.yml" "$TMPDIR_TEST/invariants.yml"

NEW_BLOCK='  - id: test-auto-added-rule
    type: boundary
    severity: warning
    description: "Test rule added by add-invariant.sh"
    source_glob: "src/api/**"
    forbidden_imports:
      - "src/db/**"'

# Test 1: script exists and is executable
if [ -x "$ADD" ]; then
  echo "  ✓ add-invariant.sh exists and is executable"
  ((passed++)) || true
else
  echo "  ✗ add-invariant.sh missing or not executable"
  ((failed++)) || true
fi

# Test 2: appends new invariant to invariants.yml
echo "$NEW_BLOCK" | bash "$ADD" "$TMPDIR_TEST/invariants.yml"
check "new rule id appears in invariants.yml" "test-auto-added-rule" "$(cat "$TMPDIR_TEST/invariants.yml")"

# Test 3: original rules still present after append
check "original rule still present after append" "boundary-routes-no-direct-db" "$(cat "$TMPDIR_TEST/invariants.yml")"

# Test 4: resulting YAML is parseable by the python3 parser
# Write parser to temp file to avoid heredoc-in-subshell bash compatibility issues
PY_PARSER=$(mktemp /tmp/thymus-test-parser-XXXXXX.py)
cat > "$PY_PARSER" << 'ENDPY'
import sys, re, json

def strip_val(s):
    s = re.sub(r'\s{2,}#.*$', '', s)
    return s.strip("\"'")

invariants = []
current = None
list_key = None
with open(sys.argv[1]) as f:
    for line in f:
        line = line.rstrip('\n')
        m = re.match(r'^  - id:\s*["\']?(.*?)["\']?\s*$', line)
        if m:
            if current:
                invariants.append(current)
            current = {'id': strip_val(m.group(1))}
            list_key = None
            continue
        if current is None:
            continue
        m = re.match(r'^      - ["\']?(.*?)["\']?\s*$', line)
        if m and list_key is not None:
            current[list_key].append(strip_val(m.group(1)))
            continue
        m = re.match(r'^    ([a-z_]+):\s*$', line)
        if m:
            list_key = m.group(1)
            current[list_key] = []
            continue
        m = re.match(r'^    ([a-z_]+):\s*["\']?(.*?)["\']?\s*$', line)
        if m:
            current[m.group(1)] = strip_val(m.group(2))
            list_key = None
            continue
if current:
    invariants.append(current)
print(json.dumps({'count': len(invariants), 'ids': [i['id'] for i in invariants]}))
ENDPY
PARSE_RESULT=$(python3 "$PY_PARSER" "$TMPDIR_TEST/invariants.yml" 2>/dev/null || echo '{"count":0}')
rm -f "$PY_PARSER"
check_json "YAML parses cleanly after append" ".count" "4" "$PARSE_RESULT"

rm -rf "$TMPDIR_TEST"

# --- Task 2: learn/SKILL.md exists and is a model-invocation skill ---
echo ""
echo "learn/SKILL.md:"

LEARN_SKILL="$ROOT/skills/learn/SKILL.md"
if [ -f "$LEARN_SKILL" ]; then
  echo "  ✓ learn/SKILL.md exists"
  ((passed++)) || true
else
  echo "  ✗ learn/SKILL.md missing"
  ((failed++)) || true
fi

# Should NOT have disable-model-invocation: true (needs Claude for NL translation)
if ! grep -q "disable-model-invocation: true" "$LEARN_SKILL"; then
  echo "  ✓ model invocation enabled (no disable-model-invocation: true)"
  ((passed++)) || true
else
  echo "  ✗ model invocation disabled — learn skill needs Claude for NL translation"
  ((failed++)) || true
fi

# Should reference add-invariant.sh
if grep -q "add-invariant.sh" "$LEARN_SKILL"; then
  echo "  ✓ skill references add-invariant.sh"
  ((passed++)) || true
else
  echo "  ✗ skill does not reference add-invariant.sh"
  ((failed++)) || true
fi

# --- Task 3: CLAUDE.md suggestions ---
echo ""
echo "session-report.sh (CLAUDE.md suggestions):"

# Setup: create a temp Thymus dir with a baseline and 3 history snapshots
# all containing the same rule violation (to trigger the suggestion threshold)
TMPDIR_REPORT=$(mktemp -d)
mkdir -p "$TMPDIR_REPORT/.thymus/history"
echo '{"modules":[],"boundaries":[],"patterns":[],"conventions":[]}' > "$TMPDIR_REPORT/.thymus/baseline.json"

for i in 1 2 3; do
  cat > "$TMPDIR_REPORT/.thymus/history/2026-02-20T00:0${i}:00.json" <<JSON
{
  "timestamp": "2026-02-20T00:0${i}:00",
  "session_id": "sess-${i}",
  "violations": [
    {"rule":"boundary-db-access","severity":"error","message":"direct DB access","file":"src/routes/users.ts"}
  ]
}
JSON
done

# Create a session-violations cache (empty — this session had no violations)
HASH=$(echo "$TMPDIR_REPORT" | md5 -q 2>/dev/null || echo "$TMPDIR_REPORT" | md5sum | cut -d' ' -f1)
CACHE="/tmp/thymus-cache-${HASH}"
mkdir -p "$CACHE"
echo "[]" > "$CACHE/session-violations.json"

# Run session-report.sh from the temp project dir
REPORT_OUT=$(cd "$TMPDIR_REPORT" && echo '{"session_id":"test-sess"}' | bash "$ROOT/scripts/session-report.sh" 2>/dev/null)

# Test: output contains CLAUDE.md suggestion for the repeated rule
if echo "$REPORT_OUT" | jq -r '.systemMessage' | grep -q "CLAUDE.md"; then
  echo "  ✓ suggests adding rule to CLAUDE.md when violation repeats ≥ 3 times"
  ((passed++)) || true
else
  echo "  ✗ missing CLAUDE.md suggestion for repeated violation"
  echo "    output: $REPORT_OUT"
  ((failed++)) || true
fi

# Test: the specific rule ID is mentioned in the suggestion
if echo "$REPORT_OUT" | jq -r '.systemMessage' | grep -q "boundary-db-access"; then
  echo "  ✓ suggestion names the specific repeated rule"
  ((passed++)) || true
else
  echo "  ✗ suggestion does not name the rule"
  ((failed++)) || true
fi

rm -rf "$TMPDIR_REPORT" "$CACHE"

# --- Task 4: refresh-baseline.sh ---
echo ""
echo "refresh-baseline.sh:"

REFRESH="$ROOT/scripts/refresh-baseline.sh"

# Test: script exists and is executable
if [ -x "$REFRESH" ]; then
  echo "  ✓ refresh-baseline.sh exists and is executable"
  ((passed++)) || true
else
  echo "  ✗ refresh-baseline.sh missing or not executable"
  ((failed++)) || true
fi

# Setup: create a temp project with a baseline
TMPDIR_REFRESH=$(mktemp -d)
mkdir -p "$TMPDIR_REFRESH/src/routes" "$TMPDIR_REFRESH/src/models" "$TMPDIR_REFRESH/.thymus"

# Create a baseline that does NOT include "src/services" module
cat > "$TMPDIR_REFRESH/.thymus/baseline.json" <<'BASELINE'
{
  "generated_at": "2026-01-01T00:00:00",
  "modules": [
    {"name": "routes", "path": "src/routes"},
    {"name": "models", "path": "src/models"}
  ],
  "boundaries": [],
  "patterns": [],
  "conventions": []
}
BASELINE

# Add a new directory that wasn't in the baseline
mkdir -p "$TMPDIR_REFRESH/src/services"
echo "// new service module" > "$TMPDIR_REFRESH/src/services/user.ts"

# Run refresh-baseline.sh from the temp project
REFRESH_OUT=$(cd "$TMPDIR_REFRESH" && bash "$REFRESH" 2>/dev/null)

# Test: output is valid JSON
if echo "$REFRESH_OUT" | jq -e '.new_directories' > /dev/null 2>&1; then
  echo "  ✓ refresh output is valid JSON with new_directories"
  ((passed++)) || true
else
  echo "  ✗ refresh output missing new_directories field"
  echo "    got: $REFRESH_OUT"
  ((failed++)) || true
fi

# Test: detects src/services as new directory not in baseline
if echo "$REFRESH_OUT" | jq -e '.new_directories | map(select(contains("services"))) | length > 0' > /dev/null 2>&1; then
  echo "  ✓ detects new directory (src/services) not in baseline"
  ((passed++)) || true
else
  echo "  ✗ did not detect new directory"
  ((failed++)) || true
fi

rm -rf "$TMPDIR_REFRESH"

# --- Task 5: calibrate-severity.sh ---
echo ""
echo "calibrate-severity.sh:"

CALIBRATE="$ROOT/scripts/calibrate-severity.sh"

if [ -x "$CALIBRATE" ]; then
  echo "  ✓ calibrate-severity.sh exists and is executable"
  ((passed++)) || true
else
  echo "  ✗ calibrate-severity.sh missing or not executable"
  ((failed++)) || true
fi

# Setup: create calibration.json with a rule that has been ignored many times
TMPDIR_CAL=$(mktemp -d)
mkdir -p "$TMPDIR_CAL/.thymus"
cat > "$TMPDIR_CAL/.thymus/calibration.json" <<'CALIB'
{
  "rules": {
    "convention-test-colocation": {"fixed": 1, "ignored": 9},
    "boundary-db-access": {"fixed": 5, "ignored": 0}
  }
}
CALIB

CAL_OUT=$(cd "$TMPDIR_CAL" && bash "$CALIBRATE" 2>/dev/null)

# Test: output is valid JSON
if echo "$CAL_OUT" | jq -e '.recommendations' > /dev/null 2>&1; then
  echo "  ✓ output is valid JSON with recommendations"
  ((passed++)) || true
else
  echo "  ✗ output missing recommendations field"
  echo "    got: $CAL_OUT"
  ((failed++)) || true
fi

# Test: identifies the ignored rule as a downgrade candidate
if echo "$CAL_OUT" | jq -e '.recommendations[] | select(.rule == "convention-test-colocation" and .action == "downgrade")' > /dev/null 2>&1; then
  echo "  ✓ flags mostly-ignored rule as downgrade candidate"
  ((passed++)) || true
else
  echo "  ✗ did not flag ignored rule correctly"
  ((failed++)) || true
fi

# Test: does NOT flag the well-enforced rule
if echo "$CAL_OUT" | jq -e '.recommendations[] | select(.rule == "boundary-db-access")' > /dev/null 2>&1; then
  echo "  ✗ incorrectly flagged well-enforced rule"
  ((failed++)) || true
else
  echo "  ✓ does not flag well-enforced rule"
  ((passed++)) || true
fi

rm -rf "$TMPDIR_CAL"

# --- Task 6: CLAUDE.md auto-update ---
echo ""
echo "refresh-baseline.sh (CLAUDE.md update):"

TMPDIR_CMD=$(mktemp -d)
mkdir -p "$TMPDIR_CMD/src/routes" "$TMPDIR_CMD/src/models" "$TMPDIR_CMD/.thymus"

# Create baseline.json
cat > "$TMPDIR_CMD/.thymus/baseline.json" <<'BLJSON'
{
  "generated_at": "2026-01-01T00:00:00",
  "modules": [
    {"name": "routes", "path": "src/routes"},
    {"name": "models", "path": "src/models"}
  ],
  "boundaries": [],
  "patterns": [],
  "conventions": []
}
BLJSON

# Create invariants.yml with error-severity rules
cat > "$TMPDIR_CMD/.thymus/invariants.yml" <<'INVYML'
version: "1.0"
invariants:
  - id: boundary-routes-no-db
    type: boundary
    severity: error
    description: "Route handlers must not import from db layer"
    source_glob: "src/routes/**"
    forbidden_imports:
      - "src/db/**"
  - id: pattern-no-raw-sql
    type: pattern
    severity: error
    description: "No raw SQL outside db layer"
    forbidden_pattern: "SELECT.*FROM"
    scope_glob: "src/**"
  - id: convention-test-colocation
    type: convention
    severity: warning
    description: "Source files should have colocated tests"
    source_glob: "src/**"
    rule: "test colocation"
INVYML

# Test 1: CLAUDE.md created from scratch when it doesn't exist
(cd "$TMPDIR_CMD" && bash "$REFRESH" > /dev/null 2>&1)
if [ -f "$TMPDIR_CMD/CLAUDE.md" ]; then
  echo "  ✓ CLAUDE.md created when it didn't exist"
  ((passed++)) || true
else
  echo "  ✗ CLAUDE.md not created"
  ((failed++)) || true
fi

# Test 2: has thymus markers
if grep -q "<!-- thymus:start -->" "$TMPDIR_CMD/CLAUDE.md" && grep -q "<!-- thymus:end -->" "$TMPDIR_CMD/CLAUDE.md"; then
  echo "  ✓ CLAUDE.md has thymus markers"
  ((passed++)) || true
else
  echo "  ✗ CLAUDE.md missing thymus markers"
  ((failed++)) || true
fi

# Test 3: contains error-severity rule summaries (not warning-severity)
if grep -q "boundary-routes-no-db" "$TMPDIR_CMD/CLAUDE.md" && grep -q "pattern-no-raw-sql" "$TMPDIR_CMD/CLAUDE.md"; then
  echo "  ✓ CLAUDE.md contains error-severity rule summaries"
  ((passed++)) || true
else
  echo "  ✗ CLAUDE.md missing error-severity rules"
  ((failed++)) || true
fi

# Test 4: does NOT contain warning-severity rules
if ! grep -q "convention-test-colocation" "$TMPDIR_CMD/CLAUDE.md"; then
  echo "  ✓ CLAUDE.md excludes warning-severity rules"
  ((passed++)) || true
else
  echo "  ✗ CLAUDE.md should not include warning-severity rules"
  ((failed++)) || true
fi

# Test 5: existing content preserved when CLAUDE.md already exists
echo "# My Project" > "$TMPDIR_CMD/CLAUDE.md"
echo "Some existing content." >> "$TMPDIR_CMD/CLAUDE.md"
(cd "$TMPDIR_CMD" && bash "$REFRESH" > /dev/null 2>&1)
if grep -q "Some existing content" "$TMPDIR_CMD/CLAUDE.md" && grep -q "<!-- thymus:start -->" "$TMPDIR_CMD/CLAUDE.md"; then
  echo "  ✓ existing CLAUDE.md content preserved"
  ((passed++)) || true
else
  echo "  ✗ existing content lost or thymus block missing"
  ((failed++)) || true
fi

# Test 6: idempotent — running again doesn't duplicate the block
(cd "$TMPDIR_CMD" && bash "$REFRESH" > /dev/null 2>&1)
CMD_COUNT=$(grep -c "<!-- thymus:start -->" "$TMPDIR_CMD/CLAUDE.md")
if [ "$CMD_COUNT" -eq 1 ]; then
  echo "  ✓ idempotent — no duplicate thymus blocks"
  ((passed++)) || true
else
  echo "  ✗ duplicate thymus blocks found ($CMD_COUNT)"
  ((failed++)) || true
fi

# Test 7: has Project Notes header when created from scratch
rm -f "$TMPDIR_CMD/CLAUDE.md"
(cd "$TMPDIR_CMD" && bash "$REFRESH" > /dev/null 2>&1)
if head -1 "$TMPDIR_CMD/CLAUDE.md" | grep -q "# Project Notes"; then
  echo "  ✓ new CLAUDE.md has Project Notes header"
  ((passed++)) || true
else
  echo "  ✗ missing Project Notes header"
  ((failed++)) || true
fi

rm -rf "$TMPDIR_CMD"

# --- Task 7: settings.json hook permissions ---
echo ""
echo "refresh-baseline.sh (settings.json update):"

TMPDIR_SETTINGS=$(mktemp -d)
mkdir -p "$TMPDIR_SETTINGS/src/routes" "$TMPDIR_SETTINGS/src/models" "$TMPDIR_SETTINGS/.thymus" "$TMPDIR_SETTINGS/.claude"

# Create baseline.json
cat > "$TMPDIR_SETTINGS/.thymus/baseline.json" <<'BLJSON2'
{
  "generated_at": "2026-01-01T00:00:00",
  "modules": [{"name": "routes", "path": "src/routes"}],
  "boundaries": [], "patterns": [], "conventions": []
}
BLJSON2

cat > "$TMPDIR_SETTINGS/.thymus/invariants.yml" <<'INVYML2'
version: "1.0"
invariants:
  - id: test-rule
    type: pattern
    severity: error
    description: "test"
    forbidden_pattern: "TODO"
    scope_glob: "src/**"
INVYML2

# Test 1: does NOT create settings.json if it doesn't exist
rm -f "$TMPDIR_SETTINGS/.claude/settings.json"
rmdir "$TMPDIR_SETTINGS/.claude" 2>/dev/null || true
(cd "$TMPDIR_SETTINGS" && bash "$REFRESH" > /dev/null 2>&1)
if [ ! -f "$TMPDIR_SETTINGS/.claude/settings.json" ]; then
  echo "  ✓ does not create settings.json when .claude/ doesn't exist"
  ((passed++)) || true
else
  echo "  ✗ created settings.json when it shouldn't have"
  ((failed++)) || true
fi

# Test 2: adds hook permissions to existing settings.json
mkdir -p "$TMPDIR_SETTINGS/.claude"
echo '{"permissions":{"allow":["Bash(git status)"]}}' | jq . > "$TMPDIR_SETTINGS/.claude/settings.json"
(cd "$TMPDIR_SETTINGS" && bash "$REFRESH" > /dev/null 2>&1)
if jq -e '.permissions.allow | map(select(contains("analyze-edit"))) | length > 0' "$TMPDIR_SETTINGS/.claude/settings.json" > /dev/null 2>&1; then
  echo "  ✓ adds hook permissions to existing settings.json"
  ((passed++)) || true
else
  echo "  ✗ did not add hook permissions"
  echo "    got: $(cat "$TMPDIR_SETTINGS/.claude/settings.json")"
  ((failed++)) || true
fi

# Test 3: preserves existing settings
if jq -e '.permissions.allow | map(select(. == "Bash(git status)")) | length > 0' "$TMPDIR_SETTINGS/.claude/settings.json" > /dev/null 2>&1; then
  echo "  ✓ preserves existing settings"
  ((passed++)) || true
else
  echo "  ✗ existing settings lost"
  ((failed++)) || true
fi

# Test 4: idempotent — running again doesn't duplicate entries
(cd "$TMPDIR_SETTINGS" && bash "$REFRESH" > /dev/null 2>&1)
ANALYZE_COUNT=$(jq '.permissions.allow | map(select(contains("analyze-edit"))) | length' "$TMPDIR_SETTINGS/.claude/settings.json")
if [ "$ANALYZE_COUNT" -eq 1 ]; then
  echo "  ✓ idempotent — no duplicate hook entries"
  ((passed++)) || true
else
  echo "  ✗ duplicate hook entries ($ANALYZE_COUNT)"
  ((failed++)) || true
fi

# Test 5: handles settings.json with no permissions key
echo '{"model":"sonnet"}' | jq . > "$TMPDIR_SETTINGS/.claude/settings.json"
(cd "$TMPDIR_SETTINGS" && bash "$REFRESH" > /dev/null 2>&1)
if jq -e '.permissions.allow | length > 0' "$TMPDIR_SETTINGS/.claude/settings.json" > /dev/null 2>&1 \
  && jq -e '.model == "sonnet"' "$TMPDIR_SETTINGS/.claude/settings.json" > /dev/null 2>&1; then
  echo "  ✓ handles settings.json with no permissions key"
  ((passed++)) || true
else
  echo "  ✗ failed on settings.json with no permissions key"
  ((failed++)) || true
fi

rm -rf "$TMPDIR_SETTINGS"

echo ""
echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ] || exit 1
