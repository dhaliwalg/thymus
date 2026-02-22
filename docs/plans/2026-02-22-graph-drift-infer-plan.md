# Graph, Drift Scoring, Auto-Inference Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add dependency graph visualization, drift/trend tracking with compliance scoring, and auto-inference of boundary rules to Thymus.

**Architecture:** Three features built sequentially. Feature 1 creates the import graph infrastructure (build-adjacency.py) reused by Feature 3. Feature 2 replaces the per-file history system with JSONL. Feature 3 uses Feature 1's adjacency data for graph analysis algorithms.

**Tech Stack:** Bash 4+, Python 3 (stdlib only), jq, git. Vanilla JS/SVG for HTML visualizations.

---

## Pre-Flight

### Task 0: Verify baseline tests pass

**Files:**
- Read: `tests/verify-phase5.sh`

**Step 1: Run full test suite**

Run: `bash /Users/vapor/Documents/projs/thymus/tests/verify-phase5.sh`
Expected: `0 failed`

If any tests fail, STOP and report. Do not proceed until baseline is green.

---

## Feature 1: Dependency Graph Visualization

### Task 1: Create build-adjacency.py — the graph data engine

**Files:**
- Create: `scripts/build-adjacency.py`
- Read: `scripts/extract-imports.py` (understand import output format)

**Step 1: Write build-adjacency.py**

This Python script takes two inputs:
1. A JSON list of `{"file": "rel/path.ts", "imports": ["./foo", "../bar/baz"]}` objects on stdin
2. An optional `--violations` flag pointing to a scan-project.sh JSON output file

It outputs JSON to stdout:
```json
{
  "modules": [
    {"id": "src/routes", "files": ["src/routes/users.ts", "src/routes/admin.ts"], "file_count": 2, "violations": 1}
  ],
  "edges": [
    {"from": "src/routes", "to": "src/db", "imports": [{"source": "src/routes/users.ts", "target": "../db/client"}], "violation": true, "rule_ids": ["boundary-routes-no-direct-db"]}
  ]
}
```

```python
#!/usr/bin/env python3
"""Build module adjacency graph from file imports.

Usage:
  echo '<import-json>' | python3 build-adjacency.py [--violations scan.json]

Input (stdin): JSON array of {"file": "path", "imports": ["import1", "import2"]}
Output (stdout): JSON {"modules": [...], "edges": [...]}
"""
import sys
import json
import os
import re
from collections import defaultdict

def get_module(filepath):
    """Group files by top-level directory pair (e.g., src/routes)."""
    parts = filepath.split('/')
    if len(parts) >= 2:
        return parts[0] + '/' + parts[1]
    return parts[0]

def resolve_import(source_file, import_path):
    """Resolve relative import to absolute-ish path."""
    if import_path.startswith('.'):
        source_dir = os.path.dirname(source_file)
        resolved = os.path.normpath(os.path.join(source_dir, import_path))
        return resolved
    return import_path

def main():
    violations_file = None
    args = sys.argv[1:]
    i = 0
    while i < len(args):
        if args[i] == '--violations' and i + 1 < len(args):
            violations_file = args[i + 1]
            i += 2
        else:
            i += 1

    # Read import data from stdin
    try:
        import_data = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        import_data = []

    # Load violations if provided
    violation_map = defaultdict(list)  # (from_module, to_module) -> [rule_id]
    if violations_file and os.path.isfile(violations_file):
        with open(violations_file) as f:
            scan = json.load(f)
        for v in scan.get('violations', []):
            src_mod = get_module(v.get('file', ''))
            imp = v.get('import', '')
            if imp:
                resolved = resolve_import(v['file'], imp)
                tgt_mod = get_module(resolved)
                if src_mod != tgt_mod:
                    violation_map[(src_mod, tgt_mod)].append(v.get('rule', ''))

    # Build module data
    module_files = defaultdict(list)
    module_violations = defaultdict(int)
    edge_imports = defaultdict(list)  # (from_mod, to_mod) -> [{"source": ..., "target": ...}]

    for entry in import_data:
        filepath = entry.get('file', '')
        imports = entry.get('imports', [])
        mod = get_module(filepath)
        module_files[mod].append(filepath)

        for imp in imports:
            resolved = resolve_import(filepath, imp)
            target_mod = get_module(resolved)
            if target_mod != mod:
                edge_imports[(mod, target_mod)].append({
                    'source': filepath,
                    'target': imp
                })

    # Count violations per module from scan data
    if violations_file and os.path.isfile(violations_file):
        with open(violations_file) as f:
            scan = json.load(f)
        for v in scan.get('violations', []):
            mod = get_module(v.get('file', ''))
            module_violations[mod] += 1

    # Build output
    modules = []
    for mod_id in sorted(module_files.keys()):
        modules.append({
            'id': mod_id,
            'files': sorted(module_files[mod_id]),
            'file_count': len(module_files[mod_id]),
            'violations': module_violations.get(mod_id, 0)
        })

    edges = []
    for (from_mod, to_mod), imps in sorted(edge_imports.items()):
        rule_ids = list(set(violation_map.get((from_mod, to_mod), [])))
        edges.append({
            'from': from_mod,
            'to': to_mod,
            'imports': imps,
            'violation': len(rule_ids) > 0,
            'rule_ids': rule_ids
        })

    json.dump({'modules': modules, 'edges': edges}, sys.stdout, indent=2)
    print()

if __name__ == '__main__':
    main()
```

**Step 2: Make it executable**

Run: `chmod +x /Users/vapor/Documents/projs/thymus/scripts/build-adjacency.py`

**Step 3: Test with unhealthy-project fixture**

Run a quick smoke test:
```bash
cd /Users/vapor/Documents/projs/thymus/tests/fixtures/unhealthy-project
# First get scan data
bash ../../../scripts/scan-project.sh > /tmp/thymus-test-scan.json 2>/dev/null
# Build imports JSON
SCRIPT_DIR="../../../scripts"
find src -type f -name "*.ts" | while read f; do
  imports=$(python3 "$SCRIPT_DIR/extract-imports.py" "$f" 2>/dev/null | jq -Rs 'split("\n") | map(select(length > 0))')
  echo "{\"file\": \"$f\", \"imports\": $imports}"
done | jq -s '.' | python3 "$SCRIPT_DIR/build-adjacency.py" --violations /tmp/thymus-test-scan.json
```

Expected: JSON with `modules` containing `src/routes`, `src/db`, `src/services`, etc., and `edges` with at least one `"violation": true` edge from `src/routes` to `src/db`.

**Step 4: Commit**

```bash
git add scripts/build-adjacency.py
git commit -m "feat: add build-adjacency.py for module dependency graph"
```

---

### Task 2: Create the graph HTML template

**Files:**
- Create: `templates/graph.html`

**Step 1: Write the template**

Create `templates/graph.html` — a self-contained HTML file with:
- `/*GRAPH_DATA*/` placeholder in a `<script>` tag where JSON will be injected
- Fruchterman-Reingold force-directed layout in vanilla JS
- SVG rendering with interactive nodes and edges
- Dark theme: `#1e1e2e` background, `#89b4fa` accent, `#f38ba8` violations
- Fonts: system fonts + monospace for file paths (match existing report.html style)

Key interactive behaviors:
- Click node → sidebar shows file list
- Click edge → sidebar shows imports list + violation info
- Hover node → show violation count badge
- Legend showing clean vs violation edge colors
- Module name labels on nodes
- Arrow markers on edges showing direction

The template should gracefully handle:
- Empty graph (no modules) — show "No source files found" message
- Single module (no edges) — center the single node
- No violations — all edges green/gray

The `/*GRAPH_DATA*/` placeholder will be replaced with the actual JSON by `generate-graph.sh`:
```html
<script>
const GRAPH_DATA = /*GRAPH_DATA*/{"modules":[],"edges":[]};
</script>
```

**Step 2: Validate template opens in browser**

Run: `open /Users/vapor/Documents/projs/thymus/templates/graph.html`
Expected: Dark page with "No source files found" or empty graph (since placeholder has empty data).

**Step 3: Commit**

```bash
git add templates/graph.html
git commit -m "feat: add interactive graph HTML template with force-directed layout"
```

---

### Task 3: Create generate-graph.sh — the orchestrator

**Files:**
- Create: `scripts/generate-graph.sh`
- Read: `scripts/scan-project.sh` (for file discovery patterns)
- Read: `scripts/extract-imports.py` (usage pattern)

**Step 1: Write generate-graph.sh**

```bash
#!/usr/bin/env bash
set -euo pipefail

# Thymus generate-graph.sh — Dependency graph visualization
# Usage: bash generate-graph.sh [--output /path/to/output.html]
# Output: writes .thymus/graph.html (or custom path), prints path to stdout

DEBUG_LOG="/tmp/thymus-debug.log"
TIMESTAMP=$(date '+%Y-%m-%dT%H:%M:%S')
THYMUS_DIR="$PWD/.thymus"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE_DIR="$(cd "$SCRIPT_DIR/../templates" && pwd)"

OUTPUT_FILE="$THYMUS_DIR/graph.html"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output) OUTPUT_FILE="$2"; shift 2 ;;
    *) shift ;;
  esac
done

echo "[$TIMESTAMP] generate-graph.sh: starting" >> "$DEBUG_LOG"

# Verify template exists
TEMPLATE="$TEMPLATE_DIR/graph.html"
if [ ! -f "$TEMPLATE" ]; then
  echo "Error: graph template not found at $TEMPLATE" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUTPUT_FILE")"

# --- Ignored paths (same as scan-project.sh) ---
IGNORED_PATHS=("node_modules" "dist" ".next" ".git" "coverage" "__pycache__" ".venv" "vendor" "target" "build" ".thymus")
IGNORED_ARGS=()
for p in "${IGNORED_PATHS[@]}"; do
  IGNORED_ARGS+=(-not -path "*/$p/*" -not -name "$p")
done

# --- Find all source files ---
FILES=()
while IFS= read -r f; do
  [ -n "$f" ] && FILES+=("$(echo "$f" | sed "s|$PWD/||")")
done < <(find "$PWD" -type f \( -name "*.ts" -o -name "*.js" -o -name "*.py" -o -name "*.java" -o -name "*.go" -o -name "*.rs" -o -name "*.dart" -o -name "*.kt" -o -name "*.kts" -o -name "*.swift" -o -name "*.cs" -o -name "*.php" -o -name "*.rb" \) \
  "${IGNORED_ARGS[@]}" 2>/dev/null | sort)

if [ "${#FILES[@]}" -eq 0 ]; then
  echo "[$TIMESTAMP] generate-graph.sh: no source files found" >> "$DEBUG_LOG"
  # Write template with empty data
  sed 's|/\*GRAPH_DATA\*/|{"modules":[],"edges":[]}|' "$TEMPLATE" > "$OUTPUT_FILE"
  echo "$OUTPUT_FILE"
  exit 0
fi

# --- Extract imports for each file ---
IMPORT_JSON=$(for f in "${FILES[@]}"; do
  abs="$PWD/$f"
  [ -f "$abs" ] || continue
  imports=$(python3 "$SCRIPT_DIR/extract-imports.py" "$abs" 2>/dev/null | jq -Rs 'split("\n") | map(select(length > 0))')
  [ "$imports" = "[]" ] && continue
  jq -n --arg file "$f" --argjson imports "$imports" '{file: $file, imports: $imports}'
done | jq -s '.' 2>/dev/null || echo '[]')

# --- Run scan for violations (if invariants.yml exists) ---
VIOLATIONS_ARG=""
SCAN_FILE="/tmp/thymus-graph-scan-$$.json"
if [ -f "$THYMUS_DIR/invariants.yml" ]; then
  bash "$SCRIPT_DIR/scan-project.sh" > "$SCAN_FILE" 2>/dev/null && VIOLATIONS_ARG="--violations $SCAN_FILE" || true
fi

# --- Build adjacency graph ---
GRAPH_JSON=$(echo "$IMPORT_JSON" | python3 "$SCRIPT_DIR/build-adjacency.py" $VIOLATIONS_ARG 2>/dev/null || echo '{"modules":[],"edges":[]}')

# --- Inject data into template ---
# Use Python for safe JSON injection (avoids sed issues with special chars)
python3 -c "
import sys, json
template = open('$TEMPLATE').read()
data = json.loads(sys.stdin.read())
# Replace the placeholder with actual JSON
output = template.replace('/*GRAPH_DATA*/', json.dumps(data))
with open('$OUTPUT_FILE', 'w') as f:
    f.write(output)
" <<< "$GRAPH_JSON"

# Cleanup
rm -f "$SCAN_FILE"

echo "[$TIMESTAMP] generate-graph.sh: wrote $OUTPUT_FILE" >> "$DEBUG_LOG"
echo "$OUTPUT_FILE"
```

**Step 2: Make it executable**

Run: `chmod +x /Users/vapor/Documents/projs/thymus/scripts/generate-graph.sh`

**Step 3: Test against unhealthy-project**

Run:
```bash
cd /Users/vapor/Documents/projs/thymus/tests/fixtures/unhealthy-project
bash ../../../scripts/generate-graph.sh
```
Expected: Prints `.thymus/graph.html` path. File should exist and contain the injected graph data.

Verify data was injected:
```bash
grep -c 'src/routes' .thymus/graph.html
```
Expected: At least 1 match (module ID in the JSON data).

**Step 4: Open in browser to visually verify**

Run: `open /Users/vapor/Documents/projs/thymus/tests/fixtures/unhealthy-project/.thymus/graph.html`

Expected: Interactive graph with nodes for each module, red edges for boundary violations.

**Step 5: Commit**

```bash
git add scripts/generate-graph.sh
git commit -m "feat: add generate-graph.sh orchestrator for dependency visualization"
```

---

### Task 4: Create /thymus:graph skill + CLI integration

**Files:**
- Create: `skills/graph/SKILL.md`
- Modify: `bin/thymus-scan` (add `--format graph`)
- Modify: `bin/thymus` (add `graph` command, update help text)

**Step 1: Write the skill file**

Create `skills/graph/SKILL.md`:
```markdown
---
name: graph
description: >-
  Generate an interactive dependency graph showing module relationships
  and boundary violations. Opens as an HTML file in the browser.
argument-hint: ""
---

# Thymus Dependency Graph

Generate an interactive dependency graph visualization. Follow these steps exactly:

## Step 1: Generate the graph

\```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/generate-graph.sh
\```

The script will output the path to the generated HTML file.

## Step 2: Open the graph

The graph opens automatically in the default browser. If it doesn't, tell the user:

```
Dependency graph written to .thymus/graph.html
Open it in your browser to explore module relationships.
```

## Step 3: Narrate the results

Read the graph data and provide a brief summary:
- Number of modules detected
- Number of cross-module edges
- Number of edges with violations (red edges)
- Which modules have the most violations

Example:
```
Dependency Graph: 6 modules, 8 edges (2 violations)

Violation edges:
  src/routes → src/db (boundary-routes-no-direct-db)

Graph: .thymus/graph.html
```
```

**Step 2: Add `--format graph` to thymus-scan**

In `bin/thymus-scan`, add `"graph"` to the format validation check on line 53. Add a new output branch after the SARIF format section (around line 205) that calls generate-graph.sh and outputs the path.

**Step 3: Add `graph` command to bin/thymus**

Add a new case in the `bin/thymus` case statement (before the `*` catch-all):
```bash
  graph)
    exec bash "$BIN_DIR/../scripts/generate-graph.sh" "$@"
    ;;
```

Update the usage() help text to include: `graph                                             Generate dependency graph HTML`

**Step 4: Test the CLI**

Run:
```bash
cd /Users/vapor/Documents/projs/thymus/tests/fixtures/unhealthy-project
../../../bin/thymus graph
```
Expected: Prints path to `.thymus/graph.html`.

Run:
```bash
cd /Users/vapor/Documents/projs/thymus/tests/fixtures/unhealthy-project
../../../bin/thymus-scan --format graph
```
Expected: Generates graph HTML.

**Step 5: Commit**

```bash
git add skills/graph/SKILL.md bin/thymus bin/thymus-scan
git commit -m "feat: add /thymus:graph skill and --format graph CLI option"
```

---

### Task 5: Create test fixture for graph + write verification test

**Files:**
- Create: `tests/fixtures/multi-module-project/` (small multi-module fixture if needed)
- Create: `tests/verify-graph.sh`

**Step 1: Create multi-module test fixture**

Create a minimal project at `tests/fixtures/multi-module-project/` with:
- `package.json` with `{"name": "multi-mod"}`
- `.thymus/invariants.yml` with a boundary rule: `src/api/**` cannot import from `src/db/**`
- `src/api/handler.ts` — imports from `../services/user` (clean) AND `../db/client` (violation)
- `src/services/user.ts` — imports from `../db/client` (clean, no rule against it)
- `src/db/client.ts` — no imports
- `src/shared/utils.ts` — no imports

This gives us 4 modules: `src/api`, `src/services`, `src/db`, `src/shared`.

**Step 2: Write verify-graph.sh**

```bash
#!/usr/bin/env bash
set -euo pipefail

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

# Test 1: build-adjacency.py exists and is executable
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

# Test 4: build-adjacency.py produces valid JSON from sample input
SAMPLE_INPUT='[{"file":"src/routes/users.ts","imports":["../db/client","../services/user"]},{"file":"src/services/user.ts","imports":["../db/client"]}]'
ADJ_OUT=$(echo "$SAMPLE_INPUT" | python3 "$ROOT/scripts/build-adjacency.py" 2>/dev/null)
if echo "$ADJ_OUT" | jq -e '.modules | length > 0' > /dev/null 2>&1; then
  echo "  ✓ build-adjacency.py produces valid module JSON"
  ((passed++)) || true
else
  echo "  ✗ build-adjacency.py output invalid"
  ((failed++)) || true
fi

if echo "$ADJ_OUT" | jq -e '.edges | length > 0' > /dev/null 2>&1; then
  echo "  ✓ build-adjacency.py produces edges"
  ((passed++)) || true
else
  echo "  ✗ build-adjacency.py has no edges"
  ((failed++)) || true
fi

# Test 5: generate-graph.sh produces HTML with multi-module fixture
FIXTURE="$ROOT/tests/fixtures/multi-module-project"
if [ -d "$FIXTURE" ]; then
  GRAPH_PATH=$(cd "$FIXTURE" && bash "$ROOT/scripts/generate-graph.sh" 2>/dev/null)
  if [ -f "$FIXTURE/.thymus/graph.html" ]; then
    echo "  ✓ generate-graph.sh creates graph.html"
    ((passed++)) || true
  else
    echo "  ✗ generate-graph.sh did not create graph.html"
    ((failed++)) || true
  fi
  # Verify data injection
  if grep -q 'src/api' "$FIXTURE/.thymus/graph.html" 2>/dev/null; then
    echo "  ✓ graph.html contains module data"
    ((passed++)) || true
  else
    echo "  ✗ graph.html missing module data"
    ((failed++)) || true
  fi
  rm -f "$FIXTURE/.thymus/graph.html"
fi

# Test 6: Empty project produces valid HTML
TMPDIR_EMPTY=$(mktemp -d)
mkdir -p "$TMPDIR_EMPTY/.thymus"
EMPTY_PATH=$(cd "$TMPDIR_EMPTY" && bash "$ROOT/scripts/generate-graph.sh" 2>/dev/null)
if [ -f "$TMPDIR_EMPTY/.thymus/graph.html" ]; then
  echo "  ✓ empty project produces valid graph.html"
  ((passed++)) || true
else
  echo "  ✗ empty project graph.html missing"
  ((failed++)) || true
fi
rm -rf "$TMPDIR_EMPTY"

# Test 7: graph skill exists
if [ -f "$ROOT/skills/graph/SKILL.md" ]; then
  echo "  ✓ graph skill exists"
  ((passed++)) || true
else
  echo "  ✗ graph skill missing"
  ((failed++)) || true
fi

echo ""
echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
```

**Step 3: Run the test**

Run: `bash /Users/vapor/Documents/projs/thymus/tests/verify-graph.sh`
Expected: All tests pass, `0 failed`.

**Step 4: Commit**

```bash
git add tests/verify-graph.sh tests/fixtures/multi-module-project/
git commit -m "test: add graph verification tests and multi-module fixture"
```

---

### Task 6: Feature 1 regression check

**Step 1: Run full test suite**

Run: `bash /Users/vapor/Documents/projs/thymus/tests/verify-phase5.sh`
Expected: `0 failed` — no regressions from Feature 1 changes.

Run: `bash /Users/vapor/Documents/projs/thymus/tests/verify-graph.sh`
Expected: `0 failed`.

**Step 2: Commit if needed**

If any fixes were needed, commit them.

---

## Feature 2: Drift Scoring + Trend Tracking

### Task 7: Create append-history.sh — atomic JSONL append

**Files:**
- Create: `scripts/append-history.sh`

**Step 1: Write append-history.sh**

```bash
#!/usr/bin/env bash
set -euo pipefail

# Thymus append-history.sh — Atomically append a scan snapshot to history.jsonl
# Usage: bash append-history.sh --scan /path/to/scan.json
#   OR: echo '<scan-json>' | bash append-history.sh --stdin
# Reads scan JSON, computes compliance score, appends one JSONL line.
# FIFO cap: 500 entries.

DEBUG_LOG="/tmp/thymus-debug.log"
TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
THYMUS_DIR="$PWD/.thymus"
HISTORY_FILE="$THYMUS_DIR/history.jsonl"

SCAN_FILE=""
USE_STDIN=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --scan) SCAN_FILE="$2"; shift 2 ;;
    --stdin) USE_STDIN=true; shift ;;
    *) shift ;;
  esac
done

mkdir -p "$THYMUS_DIR"

if $USE_STDIN; then
  SCAN=$(cat)
elif [ -n "$SCAN_FILE" ] && [ -f "$SCAN_FILE" ]; then
  SCAN=$(cat "$SCAN_FILE")
else
  echo "append-history.sh: --scan <file> or --stdin required" >&2
  exit 1
fi

# Extract stats
FILES_CHECKED=$(echo "$SCAN" | jq '.files_checked // 0')
ERRORS=$(echo "$SCAN" | jq '[.violations[] | select(.severity=="error")] | length' 2>/dev/null || echo 0)
WARNS=$(echo "$SCAN" | jq '[.violations[] | select(.severity=="warning")] | length' 2>/dev/null || echo 0)
INFOS=$(echo "$SCAN" | jq '[.violations[] | select(.severity=="info")] | length' 2>/dev/null || echo 0)
TOTAL_FILES=$(echo "$SCAN" | jq '.files_checked // 0')

# Compliance score: ((files_checked - error_count) / files_checked) * 100
if [ "$FILES_CHECKED" -gt 0 ]; then
  COMPLIANCE=$(echo "$FILES_CHECKED $ERRORS" | awk '{printf "%.1f", (($1 - $2) / $1) * 100}')
else
  COMPLIANCE="100.0"
fi

# Per-rule violation counts
BY_RULE=$(echo "$SCAN" | jq '[.violations[].rule] | group_by(.) | map({(.[0]): length}) | add // {}' 2>/dev/null || echo '{}')

# Git commit hash
COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")

# Build JSONL line
LINE=$(jq -nc \
  --arg ts "$TIMESTAMP" \
  --arg commit "$COMMIT" \
  --argjson total_files "$TOTAL_FILES" \
  --argjson files_checked "$FILES_CHECKED" \
  --argjson errors "$ERRORS" \
  --argjson warns "$WARNS" \
  --argjson infos "$INFOS" \
  --argjson compliance "$COMPLIANCE" \
  --argjson by_rule "$BY_RULE" \
  '{timestamp:$ts, commit:$commit, total_files:$total_files, files_checked:$files_checked, violations:{error:$errors, warn:$warns, info:$infos}, compliance_score:$compliance, by_rule:$by_rule}')

# Atomic append with FIFO cap
TMP_FILE="$HISTORY_FILE.tmp.$$"
{
  # Keep existing entries (up to 499 to make room for new one)
  if [ -f "$HISTORY_FILE" ]; then
    tail -499 "$HISTORY_FILE"
  fi
  echo "$LINE"
} > "$TMP_FILE"
mv "$TMP_FILE" "$HISTORY_FILE"

echo "[$TIMESTAMP] append-history.sh: appended snapshot (compliance=$COMPLIANCE)" >> "$DEBUG_LOG"
```

**Step 2: Make it executable**

Run: `chmod +x /Users/vapor/Documents/projs/thymus/scripts/append-history.sh`

**Step 3: Test with fixture**

Run:
```bash
cd /Users/vapor/Documents/projs/thymus/tests/fixtures/unhealthy-project
bash ../../../scripts/scan-project.sh > /tmp/thymus-test-scan.json 2>/dev/null
bash ../../../scripts/append-history.sh --scan /tmp/thymus-test-scan.json
tail -1 .thymus/history.jsonl
```
Expected: A valid JSONL line with `compliance_score`, `violations`, `by_rule` fields.

**Step 4: Commit**

```bash
git add scripts/append-history.sh
git commit -m "feat: add append-history.sh for atomic JSONL history tracking"
```

---

### Task 8: Migrate session-report.sh to JSONL

**Files:**
- Modify: `scripts/session-report.sh`

**Step 1: Update session-report.sh**

Replace the per-file history snapshot logic (lines 32-46) with a call to `append-history.sh`. The session violations need to be wrapped in the scan-project.sh output format for append-history.sh to consume.

Key changes:
1. Replace `mkdir -p "$THYMUS_DIR/history"` and the snapshot file write with a call to `append-history.sh --stdin`
2. Build a minimal scan JSON from session violations: `{"files_checked": N, "violations": [...]}`
3. Pipe it to `append-history.sh --stdin`
4. Update the "repeated rules" analysis (lines 61-69) to read from `history.jsonl` instead of `find "$THYMUS_DIR/history"`

**Step 2: Test**

Run:
```bash
cd /Users/vapor/Documents/projs/thymus/tests/fixtures/unhealthy-project
echo '{"session_id": "test-session"}' | bash ../../../scripts/session-report.sh
```
Expected: systemMessage output. Verify `.thymus/history.jsonl` was appended to.

**Step 3: Run phase 2 regression**

Run: `bash /Users/vapor/Documents/projs/thymus/tests/verify-phase2.sh`
Expected: `0 failed`.

**Step 4: Commit**

```bash
git add scripts/session-report.sh
git commit -m "refactor: migrate session-report.sh from per-file history to JSONL"
```

---

### Task 9: Migrate generate-report.sh to JSONL + add compliance score and trends

**Files:**
- Modify: `scripts/generate-report.sh`

**Step 1: Refactor history reading**

Replace lines 55-64 (find history/*.json) with reading from `history.jsonl`:
- Read last entry for previous score comparison
- Read last 30 entries for sparkline
- Compute compliance score using the new formula

**Step 2: Add compliance score hero section**

Add a compliance score display alongside the existing health score:
- Large number with 1 decimal (e.g., "92.8%")
- Delta from last scan with arrow
- Use the formula: `((files_checked - error_count) / files_checked) * 100`

**Step 3: Refactor sparkline to 30 data points**

Update the sparkline generation (lines 90-112) to:
- Read last 30 `compliance_score` values from `history.jsonl` (instead of 10 `score` values from per-file history)
- Keep the same SVG generation approach but with 30 points

**Step 4: Add per-rule sparklines**

After the main sparkline, add mini sparklines for the top 5 most-violated rules:
- Read `by_rule` from last 30 JSONL entries
- For each of the top 5 rules, generate a small SVG sparkline (150px wide, 30px tall)
- Show rule ID + sparkline + current count

**Step 5: Add worst-drift callout**

Compare `by_rule` counts from 10 entries ago to the latest. The rule with the biggest increase is the "worst drift":
```html
<div class="drift-callout">
  Worst drift: <code>rule-id</code> — increased by N violations over last 10 scans
</div>
```

**Step 6: Add sprint summary**

If 5+ entries exist in the last 14 days:
```html
<div class="sprint-card">
  <p>Sprint Summary (last 14 days)</p>
  <p>N scans · Compliance: X% → Y% · Net: +/-Z violations</p>
</div>
```

**Step 7: Write the history snapshot (migrate from per-file to JSONL)**

Replace the per-file snapshot write (lines 81-87) with a call to `append-history.sh`.

**Step 8: Test**

Run:
```bash
cd /Users/vapor/Documents/projs/thymus/tests/fixtures/unhealthy-project
bash ../../../scripts/scan-project.sh > /tmp/thymus-health-scan.json 2>/dev/null
bash ../../../scripts/generate-report.sh --scan /tmp/thymus-health-scan.json
```
Expected: Report HTML is generated. Open it to verify compliance score, sparklines, and trend sections appear.

**Step 9: Run phase 3 regression**

Run: `bash /Users/vapor/Documents/projs/thymus/tests/verify-phase3.sh`
Expected: `0 failed`.

**Step 10: Commit**

```bash
git add scripts/generate-report.sh
git commit -m "feat: add compliance score, 30-point sparklines, per-rule trends to health report"
```

---

### Task 10: Update health skill + add CLI commands

**Files:**
- Modify: `skills/health/SKILL.md` — update to reference JSONL instead of per-file history
- Modify: `bin/thymus` — add `history` and `score` commands
- Modify: `agents/debt-projector.md` — update to read JSONL

**Step 1: Update health skill**

In `skills/health/SKILL.md`, replace the history count check (Step 2) from `ls .thymus/history/*.json | wc -l` to `wc -l < .thymus/history.jsonl`.

**Step 2: Add CLI commands to bin/thymus**

Add two new cases in the case statement:

```bash
  history)
    THYMUS_DIR="$PWD/.thymus"
    HISTORY="$THYMUS_DIR/history.jsonl"
    if [ ! -f "$HISTORY" ]; then
      echo "No history found. Run a scan first." >&2
      exit 2
    fi
    if [[ "${1:-}" == "--json" ]]; then
      cat "$HISTORY"
    else
      echo "Last 10 scans:"
      echo "TIMESTAMP                SCORE   ERR  WARN  COMMIT"
      tail -10 "$HISTORY" | while IFS= read -r line; do
        ts=$(echo "$line" | jq -r '.timestamp')
        score=$(echo "$line" | jq -r '.compliance_score')
        err=$(echo "$line" | jq -r '.violations.error')
        warn=$(echo "$line" | jq -r '.violations.warn')
        commit=$(echo "$line" | jq -r '.commit')
        printf "%-24s %5s%%  %3s  %4s  %s\n" "$ts" "$score" "$err" "$warn" "$commit"
      done
    fi
    exit 0
    ;;
  score)
    THYMUS_DIR="$PWD/.thymus"
    HISTORY="$THYMUS_DIR/history.jsonl"
    if [ ! -f "$HISTORY" ]; then
      echo "No history found. Run a scan first." >&2
      exit 2
    fi
    LAST=$(tail -1 "$HISTORY")
    SCORE=$(echo "$LAST" | jq -r '.compliance_score')
    PREV=$(tail -2 "$HISTORY" | head -1)
    PREV_SCORE=$(echo "$PREV" | jq -r '.compliance_score // empty' 2>/dev/null || true)
    if [ -n "$PREV_SCORE" ] && [ "$PREV_SCORE" != "$SCORE" ]; then
      DELTA=$(echo "$SCORE $PREV_SCORE" | awk '{printf "%+.1f", $1-$2}')
      echo "Compliance: ${SCORE}% (${DELTA}% from last scan)"
    else
      echo "Compliance: ${SCORE}%"
    fi
    exit 0
    ;;
```

Update usage() to include:
```
  history [--json]                                  Show scan history
  score                                             Show current compliance score
```

**Step 3: Update debt-projector.md**

Update the agent prompt to read `.thymus/history.jsonl` lines instead of individual snapshot files.

**Step 4: Test CLI commands**

Run:
```bash
cd /Users/vapor/Documents/projs/thymus/tests/fixtures/unhealthy-project
# Ensure at least 2 JSONL entries exist
bash ../../../scripts/scan-project.sh > /tmp/scan1.json 2>/dev/null
bash ../../../scripts/append-history.sh --scan /tmp/scan1.json
bash ../../../scripts/append-history.sh --scan /tmp/scan1.json
../../../bin/thymus history
../../../bin/thymus score
../../../bin/thymus history --json | tail -1 | jq .
```
Expected: history shows table, score shows percentage, --json outputs valid JSONL.

**Step 5: Commit**

```bash
git add skills/health/SKILL.md bin/thymus agents/debt-projector.md
git commit -m "feat: add history and score CLI commands, update health skill for JSONL"
```

---

### Task 11: Write drift verification test

**Files:**
- Create: `tests/verify-drift.sh`

**Step 1: Write verify-drift.sh**

Test:
1. append-history.sh exists and is executable
2. Appending a scan produces valid JSONL
3. FIFO cap works (append 502 entries, verify only 500 remain)
4. Compliance score is correctly calculated
5. `thymus history` shows table output
6. `thymus score` shows percentage
7. generate-report.sh produces HTML with compliance score
8. Sprint summary appears when 5+ recent entries exist

**Step 2: Run it**

Run: `bash /Users/vapor/Documents/projs/thymus/tests/verify-drift.sh`
Expected: `0 failed`.

**Step 3: Commit**

```bash
git add tests/verify-drift.sh
git commit -m "test: add drift scoring and trend tracking verification"
```

---

### Task 12: Feature 2 regression check

**Step 1: Run full test suite**

Run: `bash /Users/vapor/Documents/projs/thymus/tests/verify-phase5.sh`

Note: The existing tests reference `.thymus/history/*.json` — they may need updating since we replaced per-file history with JSONL. If phase tests fail because they look for history files:
- Update `verify-phase3.sh` if it checks for history snapshot files
- Update `verify-phase2.sh` if session-report.sh tests check for history files

Fix any regressions, then run again until `0 failed`.

Run: `bash /Users/vapor/Documents/projs/thymus/tests/verify-drift.sh`
Expected: `0 failed`.

**Step 2: Commit fixes**

```bash
git add -A
git commit -m "fix: update existing tests for JSONL history migration"
```

---

## Feature 3: Auto-Inference Mode

### Task 13: Create analyze-graph.py — the inference engine

**Files:**
- Create: `scripts/analyze-graph.py`

**Step 1: Write analyze-graph.py**

This Python script takes adjacency JSON on stdin (from `build-adjacency.py`) and outputs proposed YAML rules to stdout.

```python
#!/usr/bin/env python3
"""Analyze module dependency graph and propose boundary rules.

Usage:
  echo '<adjacency-json>' | python3 analyze-graph.py [--min-confidence 90]

Input (stdin): JSON from build-adjacency.py {"modules": [...], "edges": [...]}
Output (stdout): YAML rules with confidence scores
"""
import sys
import json
import os
from collections import defaultdict

def main():
    min_confidence = 90.0
    args = sys.argv[1:]
    i = 0
    while i < len(args):
        if args[i] == '--min-confidence' and i + 1 < len(args):
            min_confidence = float(args[i + 1])
            i += 2
        else:
            i += 1

    try:
        graph = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        print("# No graph data available")
        return

    modules = {m['id']: m for m in graph.get('modules', [])}
    edges = graph.get('edges', [])

    if not modules:
        print("# No modules detected")
        return

    # Build adjacency data
    outgoing = defaultdict(list)  # module -> [target_modules]
    incoming = defaultdict(list)  # module -> [source_modules]
    edge_details = {}  # (from, to) -> edge

    for edge in edges:
        src, tgt = edge['from'], edge['to']
        outgoing[src].append(tgt)
        incoming[tgt].append(src)
        edge_details[(src, tgt)] = edge

    proposed_rules = []

    # --- 1. Cluster/boundary detection ---
    # For each module, what % of its file imports stay within the module?
    for mod_id, mod in modules.items():
        total_edges_from = len(outgoing.get(mod_id, []))
        total_edges_to = len(incoming.get(mod_id, []))
        total_connections = total_edges_from + total_edges_to

        if total_connections == 0:
            continue

        # Count total imports in and out
        total_imports_out = sum(len(edge_details.get((mod_id, t), {}).get('imports', [])) for t in outgoing.get(mod_id, []))
        total_imports_in = sum(len(edge_details.get((s, mod_id), {}).get('imports', [])) for s in incoming.get(mod_id, []))

        # High ratio of incoming with few outgoing = strong boundary candidate
        if total_imports_in > 0 and total_imports_out <= 1:
            # This module is mostly imported-from, rarely imports external
            # Calculate what % of external imports come through a single file
            all_incoming_imports = []
            for s in incoming.get(mod_id, []):
                edge = edge_details.get((s, mod_id), {})
                for imp in edge.get('imports', []):
                    all_incoming_imports.append(imp.get('target', ''))

            if all_incoming_imports:
                # Check for gateway pattern
                target_files = [os.path.basename(t).split('.')[0] for t in all_incoming_imports]
                from collections import Counter
                file_counts = Counter(target_files)
                if file_counts:
                    most_common_file, most_common_count = file_counts.most_common(1)[0]
                    gateway_ratio = most_common_count / len(all_incoming_imports) * 100
                    if gateway_ratio >= min_confidence:
                        # Gateway pattern detected
                        gateway_names = ['index', '__init__', 'mod', 'lib', 'main', 'exports']
                        if most_common_file in gateway_names:
                            proposed_rules.append({
                                'type': 'gateway',
                                'module': mod_id,
                                'gateway_file': most_common_file,
                                'confidence': round(gateway_ratio, 1),
                                'description': f'{mod_id} imports should go through {most_common_file} file'
                            })

    # --- 2. Directionality detection ---
    all_module_pairs = set()
    for edge in edges:
        all_module_pairs.add((edge['from'], edge['to']))

    for (a, b) in list(all_module_pairs):
        if (b, a) not in all_module_pairs:
            # Unidirectional: A -> B but not B -> A
            edge = edge_details.get((a, b), {})
            import_count = len(edge.get('imports', []))
            if import_count >= 2:  # Only propose if there's a meaningful pattern
                proposed_rules.append({
                    'type': 'directionality',
                    'from': a,
                    'to': b,
                    'import_count': import_count,
                    'confidence': 100.0,  # All existing imports follow this direction
                    'description': f'{a} imports from {b} but {b} never imports from {a}'
                })

    # --- 3. Self-containment detection ---
    for mod_id in modules:
        out_targets = set(outgoing.get(mod_id, []))
        if len(out_targets) <= 1 and len(modules) > 2:
            # Module imports from at most 1 other module
            total_file_imports = sum(len(edge_details.get((mod_id, t), {}).get('imports', [])) for t in out_targets)
            in_sources = set(incoming.get(mod_id, []))
            if total_file_imports > 0:
                allowed = list(out_targets)
                confidence = 100.0
                proposed_rules.append({
                    'type': 'boundary',
                    'module': mod_id,
                    'allowed_targets': allowed,
                    'confidence': confidence,
                    'description': f'{mod_id} only imports from {", ".join(allowed)}'
                })

    # --- Filter by confidence and output YAML ---
    filtered = [r for r in proposed_rules if r.get('confidence', 0) >= min_confidence]

    if not filtered:
        print("# No rules inferred above confidence threshold")
        return

    print("# Auto-inferred rules (thymus infer)")
    print(f"# Min confidence: {min_confidence}%")
    print("# Review before applying\n")

    for i, rule in enumerate(filtered):
        rule_id = f"inferred-{rule.get('module', rule.get('from', 'unknown')).replace('/', '-')}-{rule['type']}"

        if rule['type'] == 'boundary':
            mod = rule['module']
            allowed = rule['allowed_targets']
            print(f"  - id: {rule_id}")
            print(f"    type: boundary")
            print(f"    severity: warning")
            print(f"    description: \"{rule['description']}\"")
            print(f"    source_glob: \"{mod}/**\"")
            print(f"    forbidden_imports:")
            # Forbid everything except allowed targets and self
            for other_mod in sorted(modules.keys()):
                if other_mod != mod and other_mod not in allowed:
                    print(f"      - \"{other_mod}/**\"")
            print(f"    inferred: true")
            print(f"    confidence: {rule['confidence']}")

        elif rule['type'] == 'directionality':
            print(f"  - id: {rule_id}")
            print(f"    type: boundary")
            print(f"    severity: warning")
            print(f"    description: \"{rule['description']}\"")
            print(f"    source_glob: \"{rule['to']}/**\"")
            print(f"    forbidden_imports:")
            print(f"      - \"{rule['from']}/**\"")
            print(f"    inferred: true")
            print(f"    confidence: {rule['confidence']}")

        elif rule['type'] == 'gateway':
            print(f"  - id: {rule_id}")
            print(f"    type: boundary")
            print(f"    severity: warning")
            print(f"    description: \"{rule['description']}\"")
            print(f"    source_glob: \"**\"")
            print(f"    source_glob_exclude:")
            print(f"      - \"{rule['module']}/**\"")
            print(f"    # Gateway: imports should target {rule['module']}/{rule['gateway_file']}.*")
            print(f"    inferred: true")
            print(f"    confidence: {rule['confidence']}")

        if i < len(filtered) - 1:
            print()

if __name__ == '__main__':
    main()
```

**Step 2: Make it executable**

Run: `chmod +x /Users/vapor/Documents/projs/thymus/scripts/analyze-graph.py`

**Step 3: Test with sample data**

Run:
```bash
echo '{"modules":[{"id":"src/routes","files":["src/routes/users.ts"],"file_count":1,"violations":0},{"id":"src/services","files":["src/services/user.ts"],"file_count":1,"violations":0},{"id":"src/db","files":["src/db/client.ts"],"file_count":1,"violations":0}],"edges":[{"from":"src/routes","to":"src/services","imports":[{"source":"src/routes/users.ts","target":"../services/user"},{"source":"src/routes/admin.ts","target":"../services/admin"}],"violation":false,"rule_ids":[]},{"from":"src/services","to":"src/db","imports":[{"source":"src/services/user.ts","target":"../db/client"},{"source":"src/services/admin.ts","target":"../db/client"}],"violation":false,"rule_ids":[]}]}' | python3 /Users/vapor/Documents/projs/thymus/scripts/analyze-graph.py --min-confidence 90
```

Expected: YAML output with at least one directionality rule (routes→services is one-way, services→db is one-way).

**Step 4: Commit**

```bash
git add scripts/analyze-graph.py
git commit -m "feat: add analyze-graph.py for auto-inference of boundary rules"
```

---

### Task 14: Create infer-rules.sh — the orchestrator

**Files:**
- Create: `scripts/infer-rules.sh`

**Step 1: Write infer-rules.sh**

```bash
#!/usr/bin/env bash
set -euo pipefail

# Thymus infer-rules.sh — Auto-infer boundary rules from import patterns
# Usage: bash infer-rules.sh [--min-confidence 90] [--apply]

DEBUG_LOG="/tmp/thymus-debug.log"
TIMESTAMP=$(date '+%Y-%m-%dT%H:%M:%S')
THYMUS_DIR="$PWD/.thymus"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

MIN_CONFIDENCE=90
APPLY=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --min-confidence) MIN_CONFIDENCE="$2"; shift 2 ;;
    --apply) APPLY=true; shift ;;
    *) shift ;;
  esac
done

echo "[$TIMESTAMP] infer-rules.sh: confidence=$MIN_CONFIDENCE apply=$APPLY" >> "$DEBUG_LOG"

# --- Ignored paths (same as scan-project.sh) ---
IGNORED_PATHS=("node_modules" "dist" ".next" ".git" "coverage" "__pycache__" ".venv" "vendor" "target" "build" ".thymus")
IGNORED_ARGS=()
for p in "${IGNORED_PATHS[@]}"; do
  IGNORED_ARGS+=(-not -path "*/$p/*" -not -name "$p")
done

# --- Find all source files ---
FILES=()
while IFS= read -r f; do
  [ -n "$f" ] && FILES+=("$(echo "$f" | sed "s|$PWD/||")")
done < <(find "$PWD" -type f \( -name "*.ts" -o -name "*.js" -o -name "*.py" -o -name "*.java" -o -name "*.go" -o -name "*.rs" -o -name "*.dart" -o -name "*.kt" -o -name "*.kts" -o -name "*.swift" -o -name "*.cs" -o -name "*.php" -o -name "*.rb" \) \
  "${IGNORED_ARGS[@]}" 2>/dev/null | sort)

if [ "${#FILES[@]}" -eq 0 ]; then
  echo "# No source files found to analyze"
  exit 0
fi

# --- Extract imports for each file ---
IMPORT_JSON=$(for f in "${FILES[@]}"; do
  abs="$PWD/$f"
  [ -f "$abs" ] || continue
  imports=$(python3 "$SCRIPT_DIR/extract-imports.py" "$abs" 2>/dev/null | jq -Rs 'split("\n") | map(select(length > 0))')
  [ "$imports" = "[]" ] && continue
  jq -n --arg file "$f" --argjson imports "$imports" '{file: $file, imports: $imports}'
done | jq -s '.' 2>/dev/null || echo '[]')

# --- Build adjacency graph ---
GRAPH_JSON=$(echo "$IMPORT_JSON" | python3 "$SCRIPT_DIR/build-adjacency.py" 2>/dev/null || echo '{"modules":[],"edges":[]}')

# --- Analyze graph and propose rules ---
PROPOSED=$(echo "$GRAPH_JSON" | python3 "$SCRIPT_DIR/analyze-graph.py" --min-confidence "$MIN_CONFIDENCE" 2>/dev/null)

if [ -z "$PROPOSED" ] || echo "$PROPOSED" | grep -q "^# No"; then
  echo "$PROPOSED"
  exit 0
fi

echo "$PROPOSED"

# --- Apply if requested ---
if $APPLY; then
  INVARIANTS="$THYMUS_DIR/invariants.yml"
  if [ ! -f "$INVARIANTS" ]; then
    echo "" >&2
    echo "Cannot apply: no invariants.yml found. Run /thymus:baseline first." >&2
    exit 1
  fi
  # Append proposed rules to invariants.yml (strip comment lines)
  echo "" >> "$INVARIANTS"
  echo "$PROPOSED" | grep -v '^#' >> "$INVARIANTS"
  echo "" >&2
  echo "Rules appended to $INVARIANTS" >&2
fi
```

**Step 2: Make it executable**

Run: `chmod +x /Users/vapor/Documents/projs/thymus/scripts/infer-rules.sh`

**Step 3: Test with multi-module fixture**

Run:
```bash
cd /Users/vapor/Documents/projs/thymus/tests/fixtures/multi-module-project
bash ../../../scripts/infer-rules.sh --min-confidence 80
```
Expected: YAML output with proposed rules based on the fixture's import patterns.

**Step 4: Test --apply flag**

Run:
```bash
cd /Users/vapor/Documents/projs/thymus/tests/fixtures/multi-module-project
cp .thymus/invariants.yml .thymus/invariants.yml.bak
bash ../../../scripts/infer-rules.sh --min-confidence 80 --apply
diff .thymus/invariants.yml.bak .thymus/invariants.yml
mv .thymus/invariants.yml.bak .thymus/invariants.yml
```
Expected: The diff shows appended rules.

**Step 5: Commit**

```bash
git add scripts/infer-rules.sh
git commit -m "feat: add infer-rules.sh orchestrator for auto-inference"
```

---

### Task 15: Create /thymus:infer skill + CLI integration

**Files:**
- Create: `skills/infer/SKILL.md`
- Modify: `bin/thymus` (add `infer` command)

**Step 1: Write the skill file**

Create `skills/infer/SKILL.md`:
```markdown
---
name: infer
description: >-
  Analyze the project's import graph and propose boundary rules based on
  actual usage patterns. Shows rules with confidence scores.
argument-hint: "[--min-confidence N] [--apply]"
---

# Thymus Auto-Inference

Analyze the codebase's import patterns and propose boundary rules. Follow these steps:

## Step 1: Run the inference

\```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/infer-rules.sh $ARGUMENTS
\```

## Step 2: Narrate the results

Show the proposed rules to the user with a summary:

```
Inferred Rules (min confidence: 90%)

  1. inferred-src-auth-boundary (96.2%)
     Auth module is self-contained — external imports should go through index.ts

  2. inferred-src-routes-directionality (100%)
     Routes imports from services but services never imports from routes

No rules applied. To apply: /thymus:infer --apply
```

If `--apply` was used, confirm:
```
N rules appended to .thymus/invariants.yml
Run /thymus:scan to verify.
```

If no rules were inferred, say:
```
No rules could be inferred above the confidence threshold.
Try lowering the threshold: /thymus:infer --min-confidence 70
```
```

**Step 2: Add `infer` command to bin/thymus**

Add a new case in the case statement:
```bash
  infer)
    exec bash "$BIN_DIR/../scripts/infer-rules.sh" "$@"
    ;;
```

Update usage() to include: `infer [--min-confidence N] [--apply]             Infer boundary rules from imports`

**Step 3: Test**

Run:
```bash
cd /Users/vapor/Documents/projs/thymus/tests/fixtures/multi-module-project
../../../bin/thymus infer --min-confidence 80
```
Expected: YAML output with proposed rules.

**Step 4: Commit**

```bash
git add skills/infer/SKILL.md bin/thymus
git commit -m "feat: add /thymus:infer skill and CLI command"
```

---

### Task 16: Write inference verification test

**Files:**
- Create: `tests/verify-infer.sh`

**Step 1: Write verify-infer.sh**

Test:
1. analyze-graph.py exists and is executable
2. infer-rules.sh exists and is executable
3. infer skill exists
4. analyze-graph.py detects directionality from sample data
5. analyze-graph.py respects --min-confidence flag
6. infer-rules.sh produces YAML output for multi-module fixture
7. --apply appends to invariants.yml (with restore)
8. Empty project produces graceful output

**Step 2: Run it**

Run: `bash /Users/vapor/Documents/projs/thymus/tests/verify-infer.sh`
Expected: `0 failed`.

**Step 3: Commit**

```bash
git add tests/verify-infer.sh
git commit -m "test: add auto-inference verification tests"
```

---

### Task 17: Feature 3 regression check

**Step 1: Run full test suite**

Run: `bash /Users/vapor/Documents/projs/thymus/tests/verify-phase5.sh`
Expected: `0 failed`.

Run all new tests:
```bash
bash /Users/vapor/Documents/projs/thymus/tests/verify-graph.sh
bash /Users/vapor/Documents/projs/thymus/tests/verify-drift.sh
bash /Users/vapor/Documents/projs/thymus/tests/verify-infer.sh
```
Expected: All `0 failed`.

---

## Post-Implementation

### Task 18: Update README.md

**Files:**
- Modify: `README.md`

Add documentation for:
1. `/thymus:graph` — dependency graph visualization with screenshot description
2. `/thymus:infer` — auto-inference of boundary rules
3. `thymus graph` — CLI graph generation
4. `thymus history` / `thymus score` — drift tracking CLI
5. `thymus infer` — CLI inference
6. Compliance score explanation
7. JSONL history format

**Step 1: Update README.md**

Add new sections after the existing "Slash Commands" section.

**Step 2: Commit**

```bash
git add README.md
git commit -m "docs: add graph, drift scoring, and auto-inference to README"
```

---

### Task 19: Update docs/index.html

**Files:**
- Modify: `docs/index.html`

Add brief mentions of the three new features in the marketing landing page.

**Step 1: Update landing page**

**Step 2: Commit**

```bash
git add docs/index.html
git commit -m "docs: update landing page with graph, drift, and infer features"
```

---

### Task 20: Update CLAUDE.md

**Files:**
- Modify: `CLAUDE.md`

Add:
1. New files to the project structure section
2. Note about `build-adjacency.py` being shared between graph and infer features
3. Note about JSONL history format replacing per-file snapshots
4. New commands in the Commands section

**Step 1: Update CLAUDE.md**

**Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: update CLAUDE.md with new features and architecture"
```

---

### Task 21: Final verification

**Step 1: Run ALL tests**

```bash
bash /Users/vapor/Documents/projs/thymus/tests/verify-phase5.sh
bash /Users/vapor/Documents/projs/thymus/tests/verify-graph.sh
bash /Users/vapor/Documents/projs/thymus/tests/verify-drift.sh
bash /Users/vapor/Documents/projs/thymus/tests/verify-infer.sh
```

All must show `0 failed`.

**Step 2: Verify no uncommitted changes**

Run: `git status`
Expected: Clean working tree.

---

## Summary

| Task | Feature | Description |
|------|---------|-------------|
| 0 | Pre-flight | Verify baseline tests |
| 1 | Graph | build-adjacency.py |
| 2 | Graph | templates/graph.html |
| 3 | Graph | generate-graph.sh |
| 4 | Graph | Skill + CLI |
| 5 | Graph | Test fixture + verification |
| 6 | Graph | Regression check |
| 7 | Drift | append-history.sh |
| 8 | Drift | Migrate session-report.sh |
| 9 | Drift | Upgrade generate-report.sh |
| 10 | Drift | Health skill + CLI commands |
| 11 | Drift | Verification test |
| 12 | Drift | Regression check |
| 13 | Infer | analyze-graph.py |
| 14 | Infer | infer-rules.sh |
| 15 | Infer | Skill + CLI |
| 16 | Infer | Verification test |
| 17 | Infer | Regression check |
| 18 | Docs | README.md |
| 19 | Docs | Landing page |
| 20 | Docs | CLAUDE.md |
| 21 | Final | Full verification |
