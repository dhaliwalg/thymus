# Phase 4 — Learning & Auto-Discovery Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make Thymus smarter over time by adding natural-language rule learning, CLAUDE.md suggestions from repeated violations, baseline refresh with diff-based invariant proposals, and severity auto-calibration tracking.

**Architecture:** Four independent features built on the Phase 3 infrastructure. Each feature adds a new script and/or enhances an existing one. All features follow the warn-never-block design, the existing YAML/JSON conventions, and the < 2s hook performance budget.

**Tech Stack:** bash, python3 stdlib, jq, standard Unix tools (no new deps)

---

## Overview of new/modified files

| File | New/Modified | Purpose |
|------|-------------|---------|
| `scripts/add-invariant.sh` | New | Appends a YAML invariant block to `.thymus/invariants.yml` |
| `skills/learn/SKILL.md` | Modified | Full NL→YAML translation skill (enable model invocation) |
| `scripts/session-report.sh` | Modified | Add CLAUDE.md suggestions when a rule repeats ≥ 3× |
| `scripts/refresh-baseline.sh` | New | Diffs current project scan against existing baseline |
| `skills/baseline/SKILL.md` | Modified | Document `--refresh` argument and orchestration steps |
| `scripts/calibrate-severity.sh` | New | Analyzes calibration data, reports ignored/fixed counts per rule |
| `scripts/analyze-edit.sh` | Modified | Track fix/ignore events in `.thymus/calibration.json` |
| `tests/verify-phase4.sh` | New | Full Phase 4 test suite |
| `tasks/todo.md` | Modified | Add Phase 4 tasks |

---

## Task 1: `add-invariant.sh` — Append invariant to YAML

**Files:**
- Create: `scripts/add-invariant.sh`
- Test: `tests/verify-phase4.sh` (initial section)

### Step 1: Create `tests/verify-phase4.sh` with the first failing test

```bash
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
PARSE_RESULT=$(python3 - "$TMPDIR_TEST/invariants.yml" <<'PYEOF'
import sys, re, json

def strip_val(s):
    s = re.sub(r'\s{2,}#.*$', '', s)
    return s.strip('"\'')

def parse(src):
    invariants = []
    current = None
    list_key = None
    with open(src) as f:
        for line in f:
            line = line.rstrip('\n')
            m = re.match(r'^  - id:\s*["\']?(.*?)["\']?\s*$', line)
            if m:
                if current: invariants.append(current)
                current = {'id': strip_val(m.group(1))}
                list_key = None
                continue
            if current is None: continue
            m = re.match(r'^      - ["\']?(.*?)["\']?\s*$', line)
            if m and list_key is not None:
                current[list_key].append(strip_val(m.group(1)))
                continue
            m = re.match(r'^    ([a-z_]+):\s*$', line)
            if m: list_key = m.group(1); current[list_key] = []; continue
            m = re.match(r'^    ([a-z_]+):\s*["\']?(.*?)["\']?\s*$', line)
            if m: current[m.group(1)] = strip_val(m.group(2)); list_key = None; continue
    if current: invariants.append(current)
    print(json.dumps({'count': len(invariants), 'ids': [i['id'] for i in invariants]}))

parse(sys.argv[1])
PYEOF
)
check_json "YAML parses cleanly after append" ".count" "4" "$PARSE_RESULT"

rm -rf "$TMPDIR_TEST"
```

### Step 2: Run the test to verify it fails

```bash
bash tests/verify-phase4.sh
```

Expected: FAIL — `add-invariant.sh missing or not executable`

### Step 3: Implement `scripts/add-invariant.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

# Thymus add-invariant.sh
# Appends a new invariant YAML block (from stdin) to the given invariants.yml.
# Usage: echo "$YAML_BLOCK" | bash add-invariant.sh /path/to/.thymus/invariants.yml
# Exit 0 on success, exit 1 on failure.

INVARIANTS_YML="${1:-}"
if [ -z "$INVARIANTS_YML" ] || [ ! -f "$INVARIANTS_YML" ]; then
  echo "Thymus: add-invariant.sh requires path to invariants.yml as argument" >&2
  exit 1
fi

NEW_BLOCK=$(cat)
if [ -z "$NEW_BLOCK" ]; then
  echo "Thymus: no invariant block on stdin" >&2
  exit 1
fi

# Backup before modifying
cp "$INVARIANTS_YML" "${INVARIANTS_YML}.bak"

# Append new block (ensure file ends with newline first)
printf '\n' >> "$INVARIANTS_YML"
echo "$NEW_BLOCK" >> "$INVARIANTS_YML"

# Validate: try parsing with the same python3 parser used by hooks
PARSE_OK=$(python3 - "$INVARIANTS_YML" <<'PYEOF'
import sys, re, json

def strip_val(s):
    s = re.sub(r'\s{2,}#.*$', '', s)
    return s.strip('"\'')

invariants = []
current = None
list_key = None
with open(sys.argv[1]) as f:
    for line in f:
        line = line.rstrip('\n')
        m = re.match(r'^  - id:\s*["\']?(.*?)["\']?\s*$', line)
        if m:
            if current: invariants.append(current)
            current = {'id': strip_val(m.group(1))}
            list_key = None
            continue
        if current is None: continue
        m = re.match(r'^      - ["\']?(.*?)["\']?\s*$', line)
        if m and list_key is not None:
            current[list_key].append(strip_val(m.group(1)))
            continue
        m = re.match(r'^    ([a-z_]+):\s*$', line)
        if m: list_key = m.group(1); current[list_key] = []; continue
        m = re.match(r'^    ([a-z_]+):\s*["\']?(.*?)["\']?\s*$', line)
        if m: current[m.group(1)] = strip_val(m.group(2)); list_key = None; continue
if current: invariants.append(current)
print('ok')
PYEOF
)

if [ "$PARSE_OK" != "ok" ]; then
  # Restore backup if invalid
  mv "${INVARIANTS_YML}.bak" "$INVARIANTS_YML"
  echo "Thymus: Invalid YAML — invariants.yml restored from backup" >&2
  exit 1
fi

rm -f "${INVARIANTS_YML}.bak"
echo "Thymus: Invariant added successfully to $(basename "$INVARIANTS_YML")"
```

Make it executable:
```bash
chmod +x scripts/add-invariant.sh
```

### Step 4: Run test to verify it passes

```bash
bash tests/verify-phase4.sh
```

Expected: Task 1 section passes (4 checks pass)

### Step 5: Commit

```bash
git add scripts/add-invariant.sh tests/verify-phase4.sh
git commit -m "feat(phase4): add add-invariant.sh and Phase 4 test suite scaffold"
```

---

## Task 2: `/thymus:learn` skill — NL→YAML translation

**Files:**
- Modify: `skills/learn/SKILL.md`

The existing stub has `disable-model-invocation: true`, which prevents Claude from doing NL translation. We need to remove that flag so Claude can interpret the natural language rule.

### Step 1: Write the test (add to `tests/verify-phase4.sh`)

Add this section after Task 1 tests:

```bash
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
```

### Step 2: Run test to verify it fails

```bash
bash tests/verify-phase4.sh
```

Expected: 2 tests fail (disable-model-invocation present, add-invariant.sh not referenced)

### Step 3: Implement the full `skills/learn/SKILL.md`

```yaml
---
name: learn
description: >-
  Teach Thymus a new architectural invariant in natural language.
  Use when the user says "always", "never", "must", "should", "only" about
  code structure. Examples: /thymus:learn all DB queries go through repositories
  /thymus:learn never import from src/db in route handlers
argument-hint: "<natural language rule>"
---

# Thymus Learn — Teach a New Invariant

The user wants to teach Thymus a new architectural rule in natural language:

**User's rule:** `$ARGUMENTS`

## Your task

Translate this natural language rule into a formal YAML invariant and save it.

### Step 1 — Translate to YAML

Map the natural language to the appropriate invariant type:

| If the rule says... | Use type |
|---------------------|----------|
| "must not import", "cannot use", "never import" | `boundary` |
| "no X pattern", "never use raw X", "must not contain" | `pattern` |
| "every X must have Y", "all files must", naming rules | `convention` |
| "only use library X in module Y" | `dependency` |

**Required fields for each type:**

For `boundary`:
```yaml
  - id: boundary-<descriptive-slug>
    type: boundary
    severity: error
    description: "<what the rule enforces>"
    source_glob: "<glob of files this applies to>"
    forbidden_imports:
      - "<forbidden import pattern>"
    allowed_imports:
      - "<allowed alternative>"
```

For `pattern`:
```yaml
  - id: pattern-<descriptive-slug>
    type: pattern
    severity: error
    description: "<what pattern is forbidden>"
    forbidden_pattern: "<regex>"
    scope_glob: "<glob of files to check>"
    scope_glob_exclude:
      - "<paths to exclude>"
```

For `convention`:
```yaml
  - id: convention-<descriptive-slug>
    type: convention
    severity: warning
    description: "<convention description>"
    source_glob: "<glob this applies to>"
    rule: "<human-readable rule statement>"
```

For `dependency`:
```yaml
  - id: dependency-<descriptive-slug>
    type: dependency
    severity: warning
    description: "<package usage rule>"
    package: "<npm/pip package name>"
    allowed_in:
      - "<glob of files where it's allowed>"
```

**ID naming:** `<type>-<short-slug>` e.g. `boundary-routes-no-db`, `pattern-no-console-log`

**Severity rules:**
- `error` — hard architectural rules (boundary violations, forbidden patterns)
- `warning` — conventions and best practices
- `info` — informational only

### Step 2 — Show the generated YAML to the user

Present the invariant clearly and ask for confirmation:

```
I'll add this invariant to `.thymus/invariants.yml`:

```yaml
[the generated YAML block]
```

Does this look right? If you'd like to adjust the glob, severity, or description, let me know. Otherwise, say **yes** to save it.
```

### Step 3 — If user confirms, save it

When the user confirms, run this bash command to append the invariant:

```bash
echo '[the exact YAML block]' | bash ${CLAUDE_PLUGIN_ROOT}/scripts/add-invariant.sh "$PWD/.thymus/invariants.yml"
```

The YAML block must use the indentation shown in the examples above (2 spaces + `- id:` for the entry, 4 spaces for fields, 6 spaces for list items).

After saving, clear the invariants cache so the next hook invocation picks up the new rule:
```bash
PROJECT_HASH=$(echo "$PWD" | md5 -q 2>/dev/null || echo "$PWD" | md5sum | cut -d' ' -f1)
rm -f "/tmp/thymus-cache-${PROJECT_HASH}/invariants.json" "/tmp/thymus-cache-${PROJECT_HASH}/invariants-scan.json"
```

Then confirm to the user: "✅ Invariant `<id>` added. Thymus will enforce this rule on the next file edit."

### Step 4 — If .thymus/invariants.yml doesn't exist

Check for `.thymus/invariants.yml` in `$PWD`. If it doesn't exist, tell the user:

"`.thymus/invariants.yml` not found. Run `/thymus:baseline` first to initialize Thymus, then re-run `/thymus:learn`."
```

### Step 4: Run test to verify it passes

```bash
bash tests/verify-phase4.sh
```

Expected: Task 2 section passes (3 checks pass)

### Step 5: Commit

```bash
git add skills/learn/SKILL.md tests/verify-phase4.sh
git commit -m "feat(phase4): implement /thymus:learn skill with NL-to-YAML translation"
```

---

## Task 3: CLAUDE.md auto-suggestions in `session-report.sh`

When the same violation rule appears ≥ 3 times across all historical sessions, append a CLAUDE.md suggestion to the Stop hook's summary message.

**Files:**
- Modify: `scripts/session-report.sh`
- Test: `tests/verify-phase4.sh` (new section)

### Step 1: Write the failing test

Add to `tests/verify-phase4.sh`:

```bash
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
```

### Step 2: Run test to verify it fails

```bash
bash tests/verify-phase4.sh
```

Expected: FAIL — output does not contain CLAUDE.md suggestion

### Step 3: Modify `scripts/session-report.sh`

Add this block after the existing summary is built (just before the final `jq -n --arg msg "$summary"` line):

```bash
# --- CLAUDE.md suggestions for repeated violations ---
# Count all violation rule occurrences across all history snapshots
SUGGESTION=""
if [ -d "$THYMUS_DIR/history" ]; then
  HISTORY_FILES=$(find "$THYMUS_DIR/history" -name "*.json" 2>/dev/null | sort)
  if [ -n "$HISTORY_FILES" ]; then
    # Collect all rule IDs across history into a flat list
    ALL_RULES=$(cat $HISTORY_FILES 2>/dev/null \
      | jq -rs '[.[].violations[].rule] | group_by(.) | map({rule: .[0], count: length}) | .[] | select(.count >= 3)' \
      2>/dev/null || true)
    if [ -n "$ALL_RULES" ] && [ "$ALL_RULES" != "null" ]; then
      REPEAT_RULES=$(echo "$ALL_RULES" | jq -r '.rule' | tr '\n' ', ' | sed 's/,$//')
      if [ -n "$REPEAT_RULES" ]; then
        SUGGESTION="\n\n💡 CLAUDE.md suggestion: Rule(s) [${REPEAT_RULES}] violated ≥ 3 times. Consider adding to CLAUDE.md:\n  'Never violate ${REPEAT_RULES} — run /thymus:scan to check before committing.'"
      fi
    fi
  fi
fi
```

Then change the final output line from:
```bash
jq -n --arg msg "$summary" '{"systemMessage": $msg}'
```
to:
```bash
jq -n --arg msg "${summary}${SUGGESTION}" '{"systemMessage": $msg}'
```

### Step 4: Run test to verify it passes

```bash
bash tests/verify-phase4.sh
```

Expected: Task 3 section passes (2 checks pass)

### Step 5: Verify Phase 2/3 tests still pass

```bash
bash tests/verify-phase2.sh
bash tests/verify-phase3.sh
```

Expected: all existing tests still pass

### Step 6: Commit

```bash
git add scripts/session-report.sh tests/verify-phase4.sh
git commit -m "feat(phase4): add CLAUDE.md suggestions to session-report when rule repeats 3+ times"
```

---

## Task 4: `refresh-baseline.sh` + `/thymus:baseline --refresh`

Re-scan the project, diff against the existing baseline, and return a structured diff that the skill uses to propose new invariants.

**Files:**
- Create: `scripts/refresh-baseline.sh`
- Modify: `skills/baseline/SKILL.md`
- Test: `tests/verify-phase4.sh` (new section)

### Step 1: Write the failing test

Add to `tests/verify-phase4.sh`:

```bash
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
```

### Step 2: Run test to verify it fails

```bash
bash tests/verify-phase4.sh
```

Expected: FAIL — `refresh-baseline.sh missing or not executable`

### Step 3: Implement `scripts/refresh-baseline.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

# Thymus refresh-baseline.sh
# Re-scans the project structure and diffs against the existing baseline.json.
# Outputs JSON: { new_directories, removed_directories, new_file_types, changed_module_count }
# Used by /thymus:baseline --refresh to propose new invariants.

THYMUS_DIR="$PWD/.thymus"
BASELINE="$THYMUS_DIR/baseline.json"

if [ ! -f "$BASELINE" ]; then
  echo '{"error":"No baseline.json found. Run /thymus:baseline first.","new_directories":[]}'
  exit 0
fi

IGNORED=("node_modules" "dist" ".next" ".git" "coverage" "__pycache__" ".venv" "vendor" "target" "build" ".thymus")
IGNORED_ARGS=()
for p in "${IGNORED[@]}"; do
  IGNORED_ARGS+=(-not -path "*/$p" -not -path "*/$p/*")
done

# Scan current directory structure (top 3 levels)
CURRENT_DIRS=$(find "$PWD" -mindepth 1 -maxdepth 3 -type d \
  "${IGNORED_ARGS[@]}" 2>/dev/null \
  | sed "s|$PWD/||" | sort)

# Get baseline module paths
BASELINE_PATHS=$(jq -r '.modules[].path // empty' "$BASELINE" 2>/dev/null | sort || true)

# New directories: in current scan but not represented in baseline modules
NEW_DIRS=()
while IFS= read -r dir; do
  [ -z "$dir" ] && continue
  # Only flag direct src subdirs (depth 2: src/something)
  depth=$(echo "$dir" | tr -cd '/' | wc -c | tr -d ' ')
  [ "$depth" -ne 1 ] && continue
  # Check if this path appears in baseline modules
  if ! echo "$BASELINE_PATHS" | grep -q "^${dir}$"; then
    NEW_DIRS+=("$dir")
  fi
done <<< "$CURRENT_DIRS"

# Removed directories: in baseline but no longer present
REMOVED_DIRS=()
while IFS= read -r bpath; do
  [ -z "$bpath" ] && continue
  if [ ! -d "$PWD/$bpath" ]; then
    REMOVED_DIRS+=("$bpath")
  fi
done <<< "$BASELINE_PATHS"

# Detect file types present in new directories
NEW_FILE_TYPES=()
for dir in "${NEW_DIRS[@]}"; do
  TYPES=$(find "$PWD/$dir" -type f 2>/dev/null \
    | grep -oE '\.[^./]+$' | sort -u | tr '\n' ',' | sed 's/,$//' || true)
  [ -n "$TYPES" ] && NEW_FILE_TYPES+=("${dir}:${TYPES}")
done

# Serialize arrays to JSON
NEW_DIRS_JSON=$(printf '%s\n' "${NEW_DIRS[@]+"${NEW_DIRS[@]}"}" | jq -R . | jq -s '.')
REMOVED_DIRS_JSON=$(printf '%s\n' "${REMOVED_DIRS[@]+"${REMOVED_DIRS[@]}"}" | jq -R . | jq -s '.')
NEW_FILE_TYPES_JSON=$(printf '%s\n' "${NEW_FILE_TYPES[@]+"${NEW_FILE_TYPES[@]}"}" | jq -R . | jq -s '.')

BASELINE_MODULE_COUNT=$(jq '.modules | length' "$BASELINE" 2>/dev/null || echo 0)

jq -n \
  --argjson new_dirs "$NEW_DIRS_JSON" \
  --argjson removed_dirs "$REMOVED_DIRS_JSON" \
  --argjson new_file_types "$NEW_FILE_TYPES_JSON" \
  --argjson baseline_module_count "$BASELINE_MODULE_COUNT" \
  '{
    new_directories: $new_dirs,
    removed_directories: $removed_dirs,
    new_file_types: $new_file_types,
    baseline_module_count: $baseline_module_count
  }'
```

Make it executable:
```bash
chmod +x scripts/refresh-baseline.sh
```

### Step 4: Update `skills/baseline/SKILL.md` to document `--refresh`

Read the current baseline SKILL.md first. Then add at the end of the skill:

```markdown
## Refresh mode: `/thymus:baseline --refresh`

When called with `--refresh`, compare the current project structure against the saved baseline and propose invariants for any new patterns.

**Steps:**

1. Run: `bash ${CLAUDE_PLUGIN_ROOT}/scripts/refresh-baseline.sh`
2. Parse the JSON output. If `new_directories` is non-empty, those are modules added since the baseline.
3. For each new directory, propose an invariant. Example: if `src/services` is new, propose:
   - A boundary rule: "What modules can services import from?"
   - A convention rule: "Do service files follow a naming convention?"
4. Show the proposals to the user in a numbered list and ask which to add.
5. For each approved invariant, run:
   `echo '<yaml_block>' | bash ${CLAUDE_PLUGIN_ROOT}/scripts/add-invariant.sh "$PWD/.thymus/invariants.yml"`
6. Report summary: "Found N new directories. Added X invariants."
```

### Step 5: Run test to verify it passes

```bash
bash tests/verify-phase4.sh
```

Expected: Task 4 section passes

### Step 6: Commit

```bash
git add scripts/refresh-baseline.sh skills/baseline/SKILL.md tests/verify-phase4.sh
git commit -m "feat(phase4): add refresh-baseline.sh and --refresh support to baseline skill"
```

---

## Task 5: Severity auto-calibration tracking

Track which violations get fixed vs. ignored. When `analyze-edit.sh` runs on a file that previously had violations, check if those violations are now gone (fixed) or still present (ignored). Persist counts to `.thymus/calibration.json`. Implement `calibrate-severity.sh` to report calibration recommendations.

**Files:**
- Modify: `scripts/analyze-edit.sh`
- Create: `scripts/calibrate-severity.sh`
- Test: `tests/verify-phase4.sh` (new section)

### Step 1: Write the failing test

Add to `tests/verify-phase4.sh`:

```bash
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
    "convention-test-colocation": {"fixed": 1, "ignored": 8},
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
```

### Step 2: Run test to verify it fails

```bash
bash tests/verify-phase4.sh
```

Expected: FAIL — `calibrate-severity.sh missing or not executable`

### Step 3: Implement `scripts/calibrate-severity.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

# Thymus calibrate-severity.sh
# Reads .thymus/calibration.json and outputs severity adjustment recommendations.
# A rule with ≥ 10 data points and > 70% ignore rate → recommend downgrade.
# A rule with ≥ 10 data points and 100% fix rate → no change needed.
# Output: JSON { recommendations: [{rule, action, reason, fixed, ignored}] }

THYMUS_DIR="$PWD/.thymus"
CALIBRATION="$THYMUS_DIR/calibration.json"

if [ ! -f "$CALIBRATION" ]; then
  echo '{"recommendations":[],"note":"No calibration data yet. Edit files to build up data."}'
  exit 0
fi

python3 - "$CALIBRATION" <<'PYEOF'
import sys, json

with open(sys.argv[1]) as f:
    data = json.load(f)

rules = data.get('rules', {})
recommendations = []

for rule_id, counts in rules.items():
    fixed = counts.get('fixed', 0)
    ignored = counts.get('ignored', 0)
    total = fixed + ignored
    if total < 10:
        continue  # Not enough data
    ignore_rate = ignored / total
    if ignore_rate >= 0.7:
        recommendations.append({
            'rule': rule_id,
            'action': 'downgrade',
            'reason': f'Ignored {ignored}/{total} times ({int(ignore_rate*100)}% ignore rate). Consider downgrading severity or removing.',
            'fixed': fixed,
            'ignored': ignored
        })

print(json.dumps({'recommendations': recommendations}))
PYEOF
```

Make it executable:
```bash
chmod +x scripts/calibrate-severity.sh
```

### Step 4: Add calibration tracking to `analyze-edit.sh`

In `scripts/analyze-edit.sh`, add calibration tracking after the existing violations are detected.

Find the line after `[ ${#violation_lines[@]} -eq 0 ] && exit 0` and before the final `jq -n` output. Add:

```bash
# --- Calibration tracking ---
# Check if this file had violations previously (in session cache) and compare.
# If a previous violation for this file is now gone → "fixed"
# If it remains → "ignored"
CALIBRATION_FILE="$THYMUS_DIR/calibration.json"
[ -f "$CALIBRATION_FILE" ] || echo '{"rules":{}}' > "$CALIBRATION_FILE"

# Find violations for this file from earlier in this session
PREV_RULES=$(jq -r --arg f "$REL_PATH" '[.[] | select(.file == $f) | .rule] | unique[]' "$SESSION_VIOLATIONS" 2>/dev/null || true)
CURR_RULES=$(printf '%s\n' "${new_violation_objects[@]+"${new_violation_objects[@]}"}" | jq -r '.rule' 2>/dev/null | sort -u || true)

while IFS= read -r prev_rule; do
  [ -z "$prev_rule" ] && continue
  if echo "$CURR_RULES" | grep -q "^${prev_rule}$"; then
    # Still present → ignored
    python3 - "$CALIBRATION_FILE" "$prev_rule" "ignored" <<'PYEOF'
import sys, json
f, rule, event = sys.argv[1], sys.argv[2], sys.argv[3]
with open(f) as fp: data = json.load(fp)
rules = data.setdefault('rules', {})
r = rules.setdefault(rule, {'fixed': 0, 'ignored': 0})
r[event] = r.get(event, 0) + 1
with open(f, 'w') as fp: json.dump(data, fp)
PYEOF
  else
    # Gone → fixed
    python3 - "$CALIBRATION_FILE" "$prev_rule" "fixed" <<'PYEOF'
import sys, json
f, rule, event = sys.argv[1], sys.argv[2], sys.argv[3]
with open(f) as fp: data = json.load(fp)
rules = data.setdefault('rules', {})
r = rules.setdefault(rule, {'fixed': 0, 'ignored': 0})
r[event] = r.get(event, 0) + 1
with open(f, 'w') as fp: json.dump(data, fp)
PYEOF
  fi
done <<< "$PREV_RULES"
```

**Exact location in `analyze-edit.sh`:** Add the calibration block between line 233 (`[ ${#violation_lines[@]} -eq 0 ] && exit 0`) and line 235 (`for obj in "${new_violation_objects[@]}"; do`).

Wait — re-read the logic: calibration should track whether files that *had* violations in a previous session now have them fixed. The session violations only contain the current session. For cross-session calibration, we need to compare against the last session's history snapshot. Let me simplify:

**Simplified approach:** Only track within-session fix events. When `analyze-edit.sh` fires on a file that already has violations in `session-violations.json`, check if any of those violations are now fixed.

The calibration block above (comparing `$PREV_RULES` from session cache to `$CURR_RULES` from current check) is correct for this.

### Step 5: Run test to verify it passes

```bash
bash tests/verify-phase4.sh
```

Expected: Task 5 section passes

### Step 6: Run all tests to confirm no regressions

```bash
bash tests/verify-phase2.sh && bash tests/verify-phase3.sh && bash tests/verify-phase4.sh
```

Expected: all pass

### Step 7: Commit

```bash
git add scripts/calibrate-severity.sh scripts/analyze-edit.sh tests/verify-phase4.sh
git commit -m "feat(phase4): add severity calibration tracking and calibrate-severity.sh"
```

---

## Task 6: Final wiring — update `tasks/todo.md` + docs

**Files:**
- Modify: `tasks/todo.md`

### Step 1: Add Phase 4 tasks to `tasks/todo.md`

```markdown
## Phase 4 — Learning & Auto-Discovery

- [x] Implement scripts/add-invariant.sh (YAML append + validation)
- [x] Implement skills/learn/SKILL.md (NL → YAML with model invocation)
- [x] Implement CLAUDE.md suggestions in session-report.sh (≥ 3× rule repeat)
- [x] Implement scripts/refresh-baseline.sh (project scan diff)
- [x] Update skills/baseline/SKILL.md with --refresh orchestration
- [x] Implement scripts/calibrate-severity.sh (fix/ignore recommendations)
- [x] Add calibration tracking to scripts/analyze-edit.sh
- [x] End-to-end verification: verify-phase4.sh passes
```

### Step 2: Final verification

```bash
bash tests/verify-phase4.sh
```

Expected output:
```
=== Phase 4 Verification ===

add-invariant.sh:
  ✓ add-invariant.sh exists and is executable
  ✓ new rule id appears in invariants.yml
  ✓ original rule still present after append
  ✓ YAML parses cleanly after append

learn/SKILL.md:
  ✓ learn/SKILL.md exists
  ✓ model invocation enabled (no disable-model-invocation: true)
  ✓ skill references add-invariant.sh

session-report.sh (CLAUDE.md suggestions):
  ✓ suggests adding rule to CLAUDE.md when violation repeats ≥ 3 times
  ✓ suggestion names the specific repeated rule

refresh-baseline.sh:
  ✓ refresh-baseline.sh exists and is executable
  ✓ refresh output is valid JSON with new_directories
  ✓ detects new directory (src/services) not in baseline

calibrate-severity.sh:
  ✓ calibrate-severity.sh exists and is executable
  ✓ output is valid JSON with recommendations
  ✓ flags mostly-ignored rule as downgrade candidate
  ✓ does not flag well-enforced rule

Results: 16 passed, 0 failed
```

### Step 3: Commit

```bash
git add tasks/todo.md
git commit -m "chore(phase4): mark all Phase 4 tasks complete in todo.md"
```

---

## Definition of Done

- [ ] `bash tests/verify-phase4.sh` passes with 0 failures
- [ ] `bash tests/verify-phase2.sh && bash tests/verify-phase3.sh` still pass (no regressions)
- [ ] `/thymus:learn some rule` translates to YAML and calls `add-invariant.sh`
- [ ] `session-report.sh` suggests CLAUDE.md rule when any violation repeats ≥ 3 times
- [ ] `refresh-baseline.sh` outputs new directories not in baseline
- [ ] `calibrate-severity.sh` recommends downgrading rules with ≥ 70% ignore rate
- [ ] All new scripts are executable (`chmod +x`)
- [ ] No existing Phase 2/3 tests broken
