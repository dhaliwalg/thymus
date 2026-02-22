#!/usr/bin/env bash
set -euo pipefail

ROOT="$(realpath "$(dirname "$0")/..")"

echo "=== Inference Verification ==="
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

check_not() {
  local desc="$1" unexpected="$2" actual="$3"
  if echo "$actual" | grep -q "$unexpected"; then
    echo "  ✗ $desc"
    echo "    did NOT expect to find: $unexpected"
    ((failed++)) || true
  else
    echo "  ✓ $desc"
    ((passed++)) || true
  fi
}

# --- 1. analyze-graph.py exists and is executable ---
echo "Script existence:"

ANALYZE_GRAPH="$ROOT/scripts/analyze-graph.py"
if [ -f "$ANALYZE_GRAPH" ] && python3 -c "import os; assert os.access('$ANALYZE_GRAPH', os.R_OK)" 2>/dev/null; then
  echo "  ✓ analyze-graph.py exists and is readable"
  ((passed++)) || true
else
  echo "  ✗ analyze-graph.py missing or not readable"
  ((failed++)) || true
fi

# --- 2. infer-rules.sh exists and is executable ---
INFER_RULES="$ROOT/scripts/infer-rules.sh"
if [ -x "$INFER_RULES" ]; then
  echo "  ✓ infer-rules.sh exists and is executable"
  ((passed++)) || true
else
  echo "  ✗ infer-rules.sh missing or not executable"
  ((failed++)) || true
fi

# --- 3. infer skill exists ---
SKILL_FILE="$ROOT/skills/infer/SKILL.md"
if [ -f "$SKILL_FILE" ]; then
  echo "  ✓ skills/infer/SKILL.md exists"
  ((passed++)) || true
else
  echo "  ✗ skills/infer/SKILL.md missing"
  ((failed++)) || true
fi

# --- 4. analyze-graph.py detects directionality ---
echo ""
echo "Directionality detection:"

SAMPLE_JSON='{
  "modules": [
    {"id": "src/api", "files": ["src/api/handler.ts", "src/api/routes.ts"], "file_count": 2, "violations": 0},
    {"id": "src/services", "files": ["src/services/user.ts", "src/services/auth.ts"], "file_count": 2, "violations": 0},
    {"id": "src/db", "files": ["src/db/client.ts", "src/db/pool.ts"], "file_count": 2, "violations": 0}
  ],
  "edges": [
    {"from": "src/api", "to": "src/services", "imports": [
      {"source": "src/api/handler.ts", "target": "../services/user"},
      {"source": "src/api/routes.ts", "target": "../services/auth"}
    ]},
    {"from": "src/services", "to": "src/db", "imports": [
      {"source": "src/services/user.ts", "target": "../db/client"},
      {"source": "src/services/auth.ts", "target": "../db/pool"}
    ]}
  ]
}'

DIR_OUT=$(echo "$SAMPLE_JSON" | python3 "$ANALYZE_GRAPH" --min-confidence 50 2>/dev/null)

# Directionality rules use "no-import" pattern in IDs: inferred-{target}-no-import-{source}
check "detects directionality rules (no-import pattern) from unidirectional edges" "no-import" "$(echo "$DIR_OUT" | grep 'id:' || true)"

# Verify the specific directionality rule IDs exist
check "generates inferred-src-services-no-import-src-api rule" "inferred-src-services-no-import-src-api" "$DIR_OUT"
check "generates inferred-src-db-no-import-src-services rule" "inferred-src-db-no-import-src-services" "$DIR_OUT"

# Verify description captures the directional relationship
check "description mentions directional import pattern" "never imports from" "$DIR_OUT"

# --- 5. analyze-graph.py respects --min-confidence ---
echo ""
echo "Confidence threshold:"

# Sample data with a gateway pattern that produces ~90% confidence
# 9/10 imports go through index (gateway), 1/10 through helper
# Gateway confidence = 90% — included at threshold 50, excluded at threshold 95
GATEWAY_JSON='{
  "modules": [
    {"id": "src/api", "files": ["src/api/a.ts", "src/api/b.ts"], "file_count": 2, "violations": 0},
    {"id": "src/lib", "files": ["src/lib/index.ts", "src/lib/helper.ts", "src/lib/core.ts"], "file_count": 3, "violations": 0}
  ],
  "edges": [
    {"from": "src/api", "to": "src/lib", "imports": [
      {"source": "src/api/a.ts", "target": "../lib/index"},
      {"source": "src/api/a.ts", "target": "../lib/index"},
      {"source": "src/api/a.ts", "target": "../lib/index"},
      {"source": "src/api/a.ts", "target": "../lib/index"},
      {"source": "src/api/a.ts", "target": "../lib/index"},
      {"source": "src/api/a.ts", "target": "../lib/index"},
      {"source": "src/api/a.ts", "target": "../lib/index"},
      {"source": "src/api/a.ts", "target": "../lib/index"},
      {"source": "src/api/a.ts", "target": "../lib/index"},
      {"source": "src/api/b.ts", "target": "../lib/helper"}
    ]}
  ]
}'

LOW_OUT=$(echo "$GATEWAY_JSON" | python3 "$ANALYZE_GRAPH" --min-confidence 50 2>/dev/null)
HIGH_OUT=$(echo "$GATEWAY_JSON" | python3 "$ANALYZE_GRAPH" --min-confidence 95 2>/dev/null)

LOW_COUNT=$(echo "$LOW_OUT" | grep -c "^  - id:" || true)
HIGH_COUNT=$(echo "$HIGH_OUT" | grep -c "^  - id:" || true)

if [ "$LOW_COUNT" -gt "$HIGH_COUNT" ]; then
  echo "  ✓ low threshold (50) produces more rules ($LOW_COUNT) than high threshold (95) ($HIGH_COUNT)"
  ((passed++)) || true
else
  echo "  ✗ expected more rules at low threshold: low=$LOW_COUNT, high=$HIGH_COUNT"
  ((failed++)) || true
fi

# --- 6. analyze-graph.py handles empty input ---
echo ""
echo "Empty input handling:"

EMPTY_OUT=$(echo '{"modules":[],"edges":[]}' | python3 "$ANALYZE_GRAPH" 2>/dev/null)
EMPTY_EXIT=$?

if [ "$EMPTY_EXIT" -eq 0 ]; then
  echo "  ✓ empty input exits cleanly (code 0)"
  ((passed++)) || true
else
  echo "  ✗ empty input crashed (exit $EMPTY_EXIT)"
  ((failed++)) || true
fi

check "empty input contains '# No'" "# No" "$EMPTY_OUT"

# Also test truly empty stdin
TRULY_EMPTY_OUT=$(echo '' | python3 "$ANALYZE_GRAPH" 2>/dev/null)
TRULY_EMPTY_EXIT=$?

if [ "$TRULY_EMPTY_EXIT" -eq 0 ]; then
  echo "  ✓ truly empty stdin exits cleanly (code 0)"
  ((passed++)) || true
else
  echo "  ✗ truly empty stdin crashed (exit $TRULY_EMPTY_EXIT)"
  ((failed++)) || true
fi

# --- 7. infer-rules.sh produces YAML for multi-module fixture ---
echo ""
echo "Multi-module fixture inference:"

MULTI_FIXTURE="$ROOT/tests/fixtures/multi-module-project"

INFER_OUT=$(cd "$MULTI_FIXTURE" && bash "$INFER_RULES" 2>/dev/null)
INFER_EXIT=$?

if [ "$INFER_EXIT" -eq 0 ]; then
  echo "  ✓ infer-rules.sh exits cleanly"
  ((passed++)) || true
else
  echo "  ✗ infer-rules.sh exited with code $INFER_EXIT"
  ((failed++)) || true
fi

RULE_COUNT=$(echo "$INFER_OUT" | grep -c "^  - id:" || true)
if [ "$RULE_COUNT" -gt 0 ]; then
  echo "  ✓ infer-rules.sh produces $RULE_COUNT YAML rules (- id: lines)"
  ((passed++)) || true
else
  echo "  ✗ infer-rules.sh produced no - id: lines"
  echo "    output: $INFER_OUT"
  ((failed++)) || true
fi

check "infer-rules.sh output contains 'type: boundary'" "type: boundary" "$INFER_OUT"

# --- 8. --apply appends to invariants.yml ---
echo ""
echo "Apply mode:"

TMPDIR_APPLY=$(mktemp -d)
cp -r "$MULTI_FIXTURE/.thymus" "$TMPDIR_APPLY/"
# Copy source files so infer-rules.sh can find them
cp -r "$MULTI_FIXTURE/src" "$TMPDIR_APPLY/"
cp "$MULTI_FIXTURE/package.json" "$TMPDIR_APPLY/" 2>/dev/null || true

BEFORE_SIZE=$(wc -c < "$TMPDIR_APPLY/.thymus/invariants.yml")

APPLY_OUT=$(cd "$TMPDIR_APPLY" && bash "$INFER_RULES" --apply 2>/dev/null)
APPLY_EXIT=$?

AFTER_SIZE=$(wc -c < "$TMPDIR_APPLY/.thymus/invariants.yml")

if [ "$APPLY_EXIT" -eq 0 ]; then
  echo "  ✓ --apply exits cleanly"
  ((passed++)) || true
else
  echo "  ✗ --apply exited with code $APPLY_EXIT"
  ((failed++)) || true
fi

if [ "$AFTER_SIZE" -gt "$BEFORE_SIZE" ]; then
  echo "  ✓ --apply grew invariants.yml ($BEFORE_SIZE -> $AFTER_SIZE bytes)"
  ((passed++)) || true
else
  echo "  ✗ invariants.yml did not grow (before=$BEFORE_SIZE, after=$AFTER_SIZE)"
  ((failed++)) || true
fi

# Verify appended content contains inferred rules
APPENDED=$(cat "$TMPDIR_APPLY/.thymus/invariants.yml")
check "--apply appended inferred rule IDs" "inferred-" "$APPENDED"

rm -rf "$TMPDIR_APPLY"

# --- 9. Empty project produces graceful output ---
echo ""
echo "Empty project:"

TMPDIR_EMPTY=$(mktemp -d)
mkdir -p "$TMPDIR_EMPTY/.thymus"
cat > "$TMPDIR_EMPTY/.thymus/invariants.yml" <<'YAML'
version: "1.0"
invariants:
YAML

EMPTY_PROJECT_OUT=$(cd "$TMPDIR_EMPTY" && bash "$INFER_RULES" 2>/dev/null)
EMPTY_PROJECT_EXIT=$?

if [ "$EMPTY_PROJECT_EXIT" -eq 0 ]; then
  echo "  ✓ empty project exits cleanly (code 0)"
  ((passed++)) || true
else
  echo "  ✗ empty project crashed (exit $EMPTY_PROJECT_EXIT)"
  ((failed++)) || true
fi

check "empty project output contains '# No'" "# No" "$EMPTY_PROJECT_OUT"

rm -rf "$TMPDIR_EMPTY"

# --- 10. CLI integration works ---
echo ""
echo "CLI integration:"

CLI="$ROOT/bin/thymus"
CLI_OUT=$(cd "$MULTI_FIXTURE" && "$CLI" infer --min-confidence 80 2>/dev/null)
CLI_EXIT=$?

if [ "$CLI_EXIT" -eq 0 ]; then
  echo "  ✓ bin/thymus infer exits cleanly"
  ((passed++)) || true
else
  echo "  ✗ bin/thymus infer exited with code $CLI_EXIT"
  ((failed++)) || true
fi

CLI_RULE_COUNT=$(echo "$CLI_OUT" | grep -c "^  - id:" || true)
if [ "$CLI_RULE_COUNT" -gt 0 ]; then
  echo "  ✓ bin/thymus infer produces $CLI_RULE_COUNT YAML rules"
  ((passed++)) || true
else
  echo "  ✗ bin/thymus infer produced no rules"
  echo "    output: $CLI_OUT"
  ((failed++)) || true
fi

check "CLI output contains Min confidence: 80%" "Min confidence: 80%" "$CLI_OUT"

echo ""
echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
