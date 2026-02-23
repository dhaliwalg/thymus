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

echo "=== Graph Verification ==="
echo ""

# Test 1: build-adjacency.py exists and is executable
echo "Scripts:"
if [ -x "$ROOT/scripts/build-adjacency.py" ]; then
  echo "  ✓ build-adjacency.py exists and is executable"
  ((passed++)) || true
else
  echo "  ✗ build-adjacency.py missing or not executable"
  ((failed++)) || true
fi

# Test 2: generate-graph.sh exists and is executable
if [ -x "$ROOT/scripts/generate-graph.sh" ]; then
  echo "  ✓ generate-graph.sh exists and is executable"
  ((passed++)) || true
else
  echo "  ✗ generate-graph.sh missing or not executable"
  ((failed++)) || true
fi

# Test 3: graph.html template exists
if [ -f "$ROOT/templates/graph.html" ]; then
  echo "  ✓ graph.html template exists"
  ((passed++)) || true
else
  echo "  ✗ graph.html template missing"
  ((failed++)) || true
fi

# Test 4: graph skill exists
if [ -f "$ROOT/skills/graph/SKILL.md" ]; then
  echo "  ✓ graph skill exists"
  ((passed++)) || true
else
  echo "  ✗ graph skill missing"
  ((failed++)) || true
fi

echo ""
echo "build-adjacency.py:"

# Test 5: produces valid JSON from sample input
SAMPLE='[{"file":"src/routes/users.ts","imports":["../db/client","../services/user"]},{"file":"src/services/user.ts","imports":["../db/client"]}]'
ADJ_OUT=$(echo "$SAMPLE" | python3 "$ROOT/scripts/build-adjacency.py" 2>/dev/null)
if echo "$ADJ_OUT" | jq -e '.modules | length > 0' > /dev/null 2>&1; then
  echo "  ✓ produces valid module JSON"
  ((passed++)) || true
else
  echo "  ✗ output invalid"
  ((failed++)) || true
fi

# Test 6: produces edges
if echo "$ADJ_OUT" | jq -e '.edges | length > 0' > /dev/null 2>&1; then
  echo "  ✓ produces edges"
  ((passed++)) || true
else
  echo "  ✗ no edges in output"
  ((failed++)) || true
fi

# Test 7: empty input produces valid JSON
EMPTY_OUT=$(echo '[]' | python3 "$ROOT/scripts/build-adjacency.py" 2>/dev/null)
if echo "$EMPTY_OUT" | jq -e '.modules | length == 0' > /dev/null 2>&1; then
  echo "  ✓ empty input produces valid JSON"
  ((passed++)) || true
else
  echo "  ✗ empty input failed"
  ((failed++)) || true
fi

echo ""
echo "generate-graph.sh:"

# Test 8: generates graph for multi-module fixture
FIXTURE="$ROOT/tests/fixtures/multi-module-project"
if [ -d "$FIXTURE" ]; then
  rm -f "$FIXTURE/.thymus/graph.html"
  GRAPH_PATH=$(cd "$FIXTURE" && bash "$ROOT/scripts/generate-graph.sh" 2>/dev/null)
  if [ -f "$FIXTURE/.thymus/graph.html" ]; then
    echo "  ✓ creates graph.html for multi-module fixture"
    ((passed++)) || true
    # Test 9: contains module data
    if grep -q 'src/api' "$FIXTURE/.thymus/graph.html" 2>/dev/null; then
      echo "  ✓ graph.html contains module data"
      ((passed++)) || true
    else
      echo "  ✗ graph.html missing module data"
      ((failed++)) || true
    fi
    # Test: graph-summary.json sidecar exists and has expected fields
    if [ -f "$FIXTURE/.thymus/graph-summary.json" ]; then
      echo "  ✓ graph-summary.json sidecar exists"
      ((passed++)) || true
      if jq -e '.module_count > 0 and .edge_count >= 0 and has("violation_count") and has("top_modules")' "$FIXTURE/.thymus/graph-summary.json" > /dev/null 2>&1; then
        echo "  ✓ graph-summary.json has expected fields"
        ((passed++)) || true
      else
        echo "  ✗ graph-summary.json missing expected fields"
        ((failed++)) || true
      fi
      rm -f "$FIXTURE/.thymus/graph-summary.json"
    else
      echo "  ✗ graph-summary.json sidecar missing"
      ((failed++)) || true
    fi
    rm -f "$FIXTURE/.thymus/graph.html"
  else
    echo "  ✗ did not create graph.html"
    ((failed++)) || true
  fi
else
  echo "  ✗ multi-module-project fixture missing"
  ((failed++)) || true
fi

# Test 10: empty project produces valid graph
TMPDIR_EMPTY=$(mktemp -d)
mkdir -p "$TMPDIR_EMPTY/.thymus"
EMPTY_PATH=$(cd "$TMPDIR_EMPTY" && bash "$ROOT/scripts/generate-graph.sh" 2>/dev/null || true)
if [ -f "$TMPDIR_EMPTY/.thymus/graph.html" ]; then
  echo "  ✓ empty project produces valid graph.html"
  ((passed++)) || true
else
  echo "  ✗ empty project graph.html missing"
  ((failed++)) || true
fi
rm -rf "$TMPDIR_EMPTY"

echo ""
echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
