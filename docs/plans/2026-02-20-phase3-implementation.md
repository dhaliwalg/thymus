# Phase 3 — Health Dashboard & Reporting Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a full-project batch scanner, interactive HTML health report, debt projection agent, and diff-aware scanning — plus fix two Phase 2 carryover issues (YAML format inconsistency, broken extglob negation).

**Architecture:** Standalone `scan-project.sh` batch scanner (new, independent from `analyze-edit.sh`) + `generate-report.sh` HTML generator. Both scripts inline a `load_invariants()` helper that converts `invariants.yml` → temp JSON using Python3, cached by mtime. The `/ais:health` skill orchestrates: scan → debt-projector agent → report generation → Claude narration.

**Tech Stack:** bash 4+, jq, python3 (stdlib only — no PyYAML), standard Unix tools (find, grep, awk, sed, date)

---

## Batch 1: Carryover Fixes

### Task 1: Convert test fixture invariants.json → invariants.yml

Both fixtures currently have `invariants.json` (Phase 2 used JSON for easy jq parsing). This task converts them to YAML and replaces the broken extglob pattern with `scope_glob_exclude`.

**Files:**
- Delete: `tests/fixtures/unhealthy-project/.ais/invariants.json`
- Create: `tests/fixtures/unhealthy-project/.ais/invariants.yml`
- Delete: `tests/fixtures/healthy-project/.ais/invariants.json`
- Create: `tests/fixtures/healthy-project/.ais/invariants.yml`

**Step 1: Delete both .json files**

```bash
rm tests/fixtures/unhealthy-project/.ais/invariants.json
rm tests/fixtures/healthy-project/.ais/invariants.json
```

**Step 2: Create unhealthy fixture invariants.yml**

Write `tests/fixtures/unhealthy-project/.ais/invariants.yml`:

```yaml
version: "1.0"
invariants:
  - id: boundary-routes-no-direct-db
    type: boundary
    severity: error
    description: "Route handlers must not import directly from the db layer"
    source_glob: "src/routes/**"
    forbidden_imports:
      - "../db/client"
      - "src/db/**"
      - "prisma"
      - "knex"
    allowed_imports:
      - "../controllers/**"
      - "../repositories/**"
  - id: convention-test-colocation
    type: convention
    severity: warning
    description: "Every source file must have a colocated test file"
    rule: "For every src/**/*.ts (excluding *.test.ts, *.d.ts), there should be a src/**/*.test.ts"
  - id: pattern-no-raw-sql
    type: pattern
    severity: error
    description: "No raw SQL strings outside the db layer"
    forbidden_pattern: "(SELECT|INSERT|UPDATE|DELETE)[[:space:]]+(FROM|INTO|SET|WHERE)"
    scope_glob: "src/**"
    scope_glob_exclude:
      - "src/db/**"
```

**Step 3: Create healthy fixture invariants.yml** (identical schema, same rules)

Write `tests/fixtures/healthy-project/.ais/invariants.yml` with the same content as above.

**Step 4: Verify the files parse cleanly**

```bash
python3 -c "
import re, json

def parse(path):
    invariants = []
    current = None
    list_key = None
    with open(path) as f:
        for line in f:
            line = line.rstrip()
            m = re.match(r'^  - id:\s*[\"\'](.*?)[\"\']|\s*\$', line) or re.match(r'^  - id:\s*(.*?)\s*\$', line)
            if re.match(r'^  - id:', line):
                if current: invariants.append(current)
                val = re.sub(r'^  - id:\s*[\"\'](.*?)[\"\']\s*\$', r'\1', line)
                val = re.sub(r'^  - id:\s*(.*?)\s*\$', r'\1', val)
                current = {'id': val}; list_key = None; continue
            if current is None: continue
            if re.match(r'^      - ', line):
                if list_key: current[list_key].append(re.sub(r'^      - [\"\'](.*?)[\"\']?\s*\$', r'\1', line).strip())
                continue
            m = re.match(r'^    ([a-z_]+):\s*\$', line)
            if m: list_key = m.group(1); current[list_key] = []; continue
            m = re.match(r'^    ([a-z_]+):\s*[\"\'](.*?)[\"\']?\s*\$', line) or re.match(r'^    ([a-z_]+):\s*(.*?)\s*\$', line)
            if m: current[m.group(1)] = m.group(2); list_key = None; continue
        if current: invariants.append(current)
    return invariants

for path in [
    'tests/fixtures/unhealthy-project/.ais/invariants.yml',
    'tests/fixtures/healthy-project/.ais/invariants.yml',
]:
    invs = parse(path)
    print(f'{path}: {len(invs)} invariants OK')
    for inv in invs:
        print(f'  - {inv[\"id\"]} ({inv.get(\"type\",\"?\")})')
"
```

Expected output: 3 invariants listed for each fixture.

**Step 5: Commit**

```bash
git add tests/fixtures/
git commit -m "chore: migrate test fixture invariants from JSON to YAML with scope_glob_exclude"
```

---

### Task 2: Add load_invariants() to analyze-edit.sh, switch to invariants.yml

`analyze-edit.sh` currently reads `invariants.json` with `jq`. This task replaces that with a `load_invariants()` function that parses `invariants.yml` via an inline Python3 script and caches the result as JSON.

**Files:**
- Modify: `scripts/analyze-edit.sh`

**Step 1: Verify existing Phase 2 tests fail now (invariants.json is gone)**

```bash
bash tests/verify-analyze-edit.sh
```

Expected: FAIL — because analyze-edit.sh looks for `invariants.json` which no longer exists. Good, this is our red phase.

**Step 2: Replace analyze-edit.sh with the updated version**

Write the full `scripts/analyze-edit.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

# AIS PostToolUse hook — analyze-edit.sh
# Fires on every Edit/Write. Checks the edited file against active invariants.
# Output: JSON systemMessage if violations found, empty if clean.
# NEVER exits with code 2 (no blocking).

DEBUG_LOG="/tmp/ais-debug.log"
TIMESTAMP=$(date '+%Y-%m-%dT%H:%M:%S')

input=$(cat)
file_path=$(echo "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)
tool_name=$(echo "$input" | jq -r '.tool_name // "unknown"' 2>/dev/null || true)

echo "[$TIMESTAMP] analyze-edit.sh: $tool_name on ${file_path:-unknown}" >> "$DEBUG_LOG"

[ -z "$file_path" ] && exit 0

AIS_DIR="$PWD/.ais"
INVARIANTS_YML="$AIS_DIR/invariants.yml"

[ -f "$INVARIANTS_YML" ] || exit 0

PROJECT_HASH=$(echo "$PWD" | md5 -q 2>/dev/null || echo "$PWD" | md5sum | cut -d' ' -f1)
CACHE_DIR="/tmp/ais-cache-${PROJECT_HASH}"
mkdir -p "$CACHE_DIR"
SESSION_VIOLATIONS="$CACHE_DIR/session-violations.json"
[ -f "$SESSION_VIOLATIONS" ] || echo "[]" > "$SESSION_VIOLATIONS"

# --- YAML → JSON conversion (cached by mtime) ---
# Parses invariants.yml using Python3 stdlib only (no PyYAML).
# Writes parsed JSON to cache; reuses cache if newer than source.
load_invariants() {
  local yml="$1" cache="$2"
  [ -f "$yml" ] || { echo "AIS: invariants.yml not found" >&2; return 1; }
  if [ -f "$cache" ] && [ "$cache" -nt "$yml" ]; then
    echo "$cache"; return 0
  fi
  python3 - "$yml" "$cache" <<'PYEOF'
import sys, json, re

def parse(src, dst):
    invariants = []
    current = None
    list_key = None
    with open(src) as f:
        for line in f:
            line = line.rstrip('\n')
            m = re.match(r'^  - id:\s*["\']?(.*?)["\']?\s*$', line)
            if m:
                if current:
                    invariants.append(current)
                current = {'id': m.group(1)}
                list_key = None
                continue
            if current is None:
                continue
            m = re.match(r'^      - ["\']?(.*?)["\']?\s*$', line)
            if m and list_key is not None:
                current[list_key].append(m.group(1))
                continue
            m = re.match(r'^    ([a-z_]+):\s*$', line)
            if m:
                list_key = m.group(1)
                current[list_key] = []
                continue
            m = re.match(r'^    ([a-z_]+):\s*["\']?(.*?)["\']?\s*$', line)
            if m:
                current[m.group(1)] = m.group(2)
                list_key = None
                continue
    if current:
        invariants.append(current)
    with open(dst, 'w') as f:
        json.dump({'invariants': invariants}, f)

parse(sys.argv[1], sys.argv[2])
PYEOF
  if [ $? -ne 0 ] || [ ! -s "$cache" ]; then
    echo "AIS: Failed to parse invariants.yml" >&2; return 1
  fi
  echo "$cache"
}

INVARIANTS_JSON=$(load_invariants "$INVARIANTS_YML" "$CACHE_DIR/invariants.json") || exit 0

REL_PATH="${file_path#"$PWD"/}"
[ "$REL_PATH" = "$file_path" ] && REL_PATH=$(basename "$file_path")

echo "[$TIMESTAMP] Checking $REL_PATH" >> "$DEBUG_LOG"

# --- Glob → regex conversion ---
# NOTE: Extended glob negation !(foo)/** is NOT supported.
# Use scope_glob + scope_glob_exclude instead (see invariants.yml schema).
glob_to_regex() {
  printf '%s' "$1" \
    | sed \
        -e 's/\./\\./g' \
        -e 's|\*\*|__DS__|g' \
        -e 's|\*|[^/]*|g' \
        -e 's|__DS__|.*|g'
}

path_matches() {
  local path="$1" glob="$2"
  local regex
  regex="^$(glob_to_regex "$glob")"'$'
  echo "$path" | grep -qE "$regex" 2>/dev/null || return 1
}

extract_ts_imports() {
  local file="$1"
  [ -f "$file" ] || return 0
  { grep -oE "(from|require)[[:space:]]*['\"][^'\"]+['\"]" "$file" 2>/dev/null || true; } \
    | { grep -oE "['\"][^'\"]+['\"]" || true; } \
    | tr -d "'\"" \
    || true
}

import_is_forbidden() {
  local import="$1"
  local invariant_json="$2"
  local count
  count=$(echo "$invariant_json" | jq '.forbidden_imports | length' 2>/dev/null || echo 0)
  for ((f=0; f<count; f++)); do
    pattern=$(echo "$invariant_json" | jq -r ".forbidden_imports[$f]")
    if path_matches "$import" "$pattern" || [ "$import" = "$pattern" ]; then
      return 0
    fi
  done
  return 1
}

violation_lines=()
new_violation_objects=()

invariant_count=$(jq '.invariants | length' "$INVARIANTS_JSON" 2>/dev/null || echo 0)

for ((i=0; i<invariant_count; i++)); do
  inv=$(jq ".invariants[$i]" "$INVARIANTS_JSON")
  rule_id=$(echo "$inv" | jq -r '.id')
  rule_type=$(echo "$inv" | jq -r '.type')
  severity=$(echo "$inv" | jq -r '.severity')
  description=$(echo "$inv" | jq -r '.description')

  applicable_glob=$(echo "$inv" | jq -r '.source_glob // .scope_glob // empty')

  if [ -n "$applicable_glob" ]; then
    path_matches "$REL_PATH" "$applicable_glob" || continue
    # scope_glob_exclude: skip file if it matches any exclusion pattern
    excl_count=$(echo "$inv" | jq 'if .scope_glob_exclude then .scope_glob_exclude | length else 0 end' 2>/dev/null || echo 0)
    excluded=false
    for ((e=0; e<excl_count; e++)); do
      excl=$(echo "$inv" | jq -r ".scope_glob_exclude[$e]")
      if path_matches "$REL_PATH" "$excl"; then
        excluded=true; break
      fi
    done
    $excluded && continue
  fi

  echo "[$TIMESTAMP]   Checking rule $rule_id ($rule_type) against $REL_PATH" >> "$DEBUG_LOG"

  case "$rule_type" in

    boundary)
      [ -f "$file_path" ] || continue
      imports=$(extract_ts_imports "$file_path")
      [ -z "$imports" ] && continue
      while IFS= read -r import; do
        [ -z "$import" ] && continue
        if import_is_forbidden "$import" "$inv"; then
          SEV_UPPER=$(echo "$severity" | tr '[:lower:]' '[:upper:]')
          msg="[$SEV_UPPER] $rule_id: $description (import: $import)"
          violation_lines+=("$msg")
          new_violation_objects+=("$(jq -n \
            --arg rule "$rule_id" --arg sev "$severity" --arg msg "$description" \
            --arg file "$REL_PATH" --arg imp "$import" \
            '{rule:$rule,severity:$sev,message:$msg,file:$file,import:$imp}')")
        fi
      done <<< "$imports"
      ;;

    pattern)
      [ -f "$file_path" ] || continue
      forbidden_pattern=$(echo "$inv" | jq -r '.forbidden_pattern // empty')
      [ -z "$forbidden_pattern" ] && continue
      if grep -qE "$forbidden_pattern" "$file_path" 2>/dev/null; then
        line_num=$({ grep -nE "$forbidden_pattern" "$file_path" 2>/dev/null | head -1 | cut -d: -f1; } || echo "?")
        SEV_UPPER=$(echo "$severity" | tr '[:lower:]' '[:upper:]')
        msg="[$SEV_UPPER] $rule_id: $description (line $line_num)"
        violation_lines+=("$msg")
        new_violation_objects+=("$(jq -n \
          --arg rule "$rule_id" --arg sev "$severity" --arg msg "$description" \
          --arg file "$REL_PATH" --arg line "${line_num}" \
          '{rule:$rule,severity:$sev,message:$msg,file:$file,line:$line}')")
      fi
      ;;

    convention)
      [ -f "$file_path" ] || continue
      rule_text=$(echo "$inv" | jq -r '.rule // empty')
      if echo "$rule_text" | grep -qi "test"; then
        if [[ "$REL_PATH" =~ \.(ts|js|py)$ ]] \
           && [[ ! "$REL_PATH" =~ \.(test|spec)\. ]] \
           && [[ ! "$REL_PATH" =~ \.d\.ts$ ]]; then
          base="${file_path%.*}"
          ext="${file_path##*.}"
          if ! { [ -f "${base}.test.${ext}" ] || [ -f "${base}.spec.${ext}" ]; }; then
            SEV_UPPER=$(echo "$severity" | tr '[:lower:]' '[:upper:]')
            msg="[$SEV_UPPER] $rule_id: Missing test file for $REL_PATH"
            violation_lines+=("$msg")
            new_violation_objects+=("$(jq -n \
              --arg rule "$rule_id" --arg sev "$severity" \
              --arg msg "Missing colocated test file" --arg file "$REL_PATH" \
              '{rule:$rule,severity:$sev,message:$msg,file:$file}')")
          fi
        fi
      fi
      ;;

  esac
done

echo "[$TIMESTAMP] Found ${#violation_lines[@]} violations in $REL_PATH" >> "$DEBUG_LOG"

[ ${#violation_lines[@]} -eq 0 ] && exit 0

for obj in "${new_violation_objects[@]}"; do
  updated=$(jq --argjson v "$obj" '. + [$v]' "$SESSION_VIOLATIONS")
  echo "$updated" > "$SESSION_VIOLATIONS"
done

msg_body="⚠️ AIS: ${#violation_lines[@]} violation(s) in $REL_PATH:\n"
for line in "${violation_lines[@]}"; do
  msg_body+="  • $line\n"
done

jq -n --arg msg "$msg_body" '{"systemMessage": $msg}'
```

**Step 3: Run Phase 2 tests — should pass again**

```bash
bash tests/verify-analyze-edit.sh
```

Expected: all PASS. Then:

```bash
bash tests/verify-phase2.sh
```

Expected: all PASS.

**Step 4: Commit**

```bash
git add scripts/analyze-edit.sh
git commit -m "fix: migrate analyze-edit.sh to invariants.yml with load_invariants() and scope_glob_exclude"
```

---

### Task 3: Update load-baseline.sh to invariants.yml

`load-baseline.sh` has an `if/elif` that tries `invariants.json` first, then `invariants.yml`. After migration, there is only `.yml`.

**Files:**
- Modify: `scripts/load-baseline.sh`

**Step 1: Update the INVARIANT_COUNT block**

Find this block in `scripts/load-baseline.sh` (lines 28-32):

```bash
INVARIANT_COUNT=0
if [ -f "$AIS_DIR/invariants.json" ]; then
  INVARIANT_COUNT=$(jq '.invariants | length' "$AIS_DIR/invariants.json" 2>/dev/null || echo "0")
elif [ -f "$AIS_DIR/invariants.yml" ]; then
  INVARIANT_COUNT=$(grep -c "^  - id:" "$AIS_DIR/invariants.yml" 2>/dev/null || echo "0")
fi
```

Replace with:

```bash
INVARIANT_COUNT=0
if [ -f "$AIS_DIR/invariants.yml" ]; then
  INVARIANT_COUNT=$(grep -c "^  - id:" "$AIS_DIR/invariants.yml" 2>/dev/null || echo "0")
fi
```

(No need for `load_invariants()` here — we just count lines, not parse.)

**Step 2: Verify load-baseline.sh still works**

```bash
cd tests/fixtures/unhealthy-project && echo '{}' | bash ../../../scripts/load-baseline.sh
```

Expected output: JSON with `systemMessage` showing `AIS Active | ... | 3 invariants enforced`.

**Step 3: Commit**

```bash
git add scripts/load-baseline.sh
git commit -m "fix: load-baseline.sh reads invariants.yml count directly"
```

---

### Task 4: Update CLAUDE.md and ROADMAP.md schema examples

Replace the broken `src/!(db)/**` extglob pattern in the canonical docs.

**Files:**
- Modify: `CLAUDE.md`
- Modify: `ROADMAP.md`

**Step 1: Update CLAUDE.md invariant schema**

In `CLAUDE.md`, find the `pattern-no-raw-sql` example under "Invariant Rule Schema":

```yaml
  - id: pattern-no-raw-sql
    type: pattern
    severity: error
    description: "No raw SQL strings outside the db layer"
    forbidden_pattern: "(SELECT|INSERT|UPDATE|DELETE)\\s+(FROM|INTO|SET)"
    scope_glob: "src/!(db)/**"
```

Replace `scope_glob: "src/!(db)/**"` with:

```yaml
    scope_glob: "src/**"
    scope_glob_exclude:
      - "src/db/**"
```

Also add `scope_glob_exclude` to the schema type list after `allowed_imports`:

```yaml
    scope_glob_exclude:
      - "src/db/**"          # blocklist — files matching these globs are skipped
                             # Replaces bash extglob negation !(foo)/** which is not portable
```

**Step 2: Update ROADMAP.md**

In `ROADMAP.md`, find the `pattern-no-raw-sql` example in the Phase 1 invariant schema section:

```yaml
  - id: pattern-no-raw-sql
    type: pattern
    severity: error
    description: "No raw SQL strings outside the db layer"
    forbidden_pattern: "(SELECT|INSERT|UPDATE|DELETE)\\s+(FROM|INTO|SET)"
    scope_glob: "src/!(db)/**"
```

Replace the `scope_glob` line with:

```yaml
    scope_glob: "src/**"
    scope_glob_exclude:
      - "src/db/**"
```

**Step 3: Commit**

```bash
git add CLAUDE.md ROADMAP.md
git commit -m "docs: replace extglob negation with scope_glob_exclude in schema examples"
```

---

## Batch 2: Batch Scanner

### Task 5: Write verify-phase3.sh with failing scan tests (TDD red)

Write the test file first. These tests will fail until `scan-project.sh` exists.

**Files:**
- Create: `tests/verify-phase3.sh`

**Step 1: Write the test file**

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(realpath "$(dirname "$0")/..")"
SCAN="$ROOT/scripts/scan-project.sh"
UNHEALTHY="$ROOT/tests/fixtures/unhealthy-project"
HEALTHY="$ROOT/tests/fixtures/healthy-project"

echo "=== Phase 3 Verification ==="
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
    echo "    expected: $expected"
    echo "    got: $actual"
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

# --- scan-project.sh ---
echo "scan-project.sh:"

# Test 1: unhealthy project detects boundary violation
output=$(cd "$UNHEALTHY" && bash "$SCAN" 2>/dev/null)
check "detects boundary violation" "boundary-routes-no-direct-db" "$output"

# Test 2: healthy project produces zero violations
output=$(cd "$HEALTHY" && bash "$SCAN" 2>/dev/null)
check_json "healthy project has 0 violations" ".stats.total" "0" "$output"

# Test 3: scope limiting — scanning only src/db produces no boundary violations
output=$(cd "$UNHEALTHY" && bash "$SCAN" src/db 2>/dev/null)
if echo "$output" | jq -e '.violations | map(select(.rule == "boundary-routes-no-direct-db")) | length == 0' > /dev/null 2>&1; then
  echo "  ✓ scope limits scan to target directory"
  ((passed++)) || true
else
  echo "  ✗ scope limiting failed"
  ((failed++)) || true
fi

# Test 4: scope_glob_exclude — pattern-no-raw-sql must NOT fire on src/db files
# (The unhealthy project's db/client.ts may have raw SQL — it should be excluded)
output=$(cd "$UNHEALTHY" && bash "$SCAN" src/db 2>/dev/null)
if echo "$output" | jq -e '[.violations[] | select(.rule == "pattern-no-raw-sql" and (.file | startswith("src/db/")))] | length == 0' > /dev/null 2>&1; then
  echo "  ✓ scope_glob_exclude suppresses pattern rule on excluded paths"
  ((passed++)) || true
else
  echo "  ✗ scope_glob_exclude did not suppress pattern rule on src/db"
  echo "    output: $output"
  ((failed++)) || true
fi

# Test 5: output is valid JSON with expected shape
output=$(cd "$UNHEALTHY" && bash "$SCAN" 2>/dev/null)
if echo "$output" | jq -e '.violations and .stats' > /dev/null 2>&1; then
  echo "  ✓ output is valid JSON with violations and stats"
  ((passed++)) || true
else
  echo "  ✗ output is not valid JSON or missing fields"
  ((failed++)) || true
fi

# Test 6: stats.errors and stats.warnings are integers
check_json "stats.errors is a number" ".stats.errors | type" "number" "$output"

echo ""
echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ] || exit 1
```

Make it executable: `chmod +x tests/verify-phase3.sh`

**Step 2: Run to confirm tests fail**

```bash
bash tests/verify-phase3.sh
```

Expected: all FAIL (scan-project.sh doesn't exist yet). This confirms TDD red phase.

---

### Task 6: Implement scripts/scan-project.sh

**Files:**
- Create: `scripts/scan-project.sh`

**Step 1: Write the script**

```bash
#!/usr/bin/env bash
set -euo pipefail

# AIS scan-project.sh — batch invariant checker
# Usage: bash scan-project.sh [scope_path] [--diff]
# Output: JSON { violations: [...], stats: {...}, scope: "..." }
# scope_path: optional subdirectory to limit scan (e.g. "src/auth")
# --diff: limit scan to files changed since git HEAD

DEBUG_LOG="/tmp/ais-debug.log"
TIMESTAMP=$(date '+%Y-%m-%dT%H:%M:%S')
AIS_DIR="$PWD/.ais"
INVARIANTS_YML="$AIS_DIR/invariants.yml"

SCOPE=""
DIFF_MODE=false
for arg in "$@"; do
  case "$arg" in
    --diff) DIFF_MODE=true ;;
    *) [ -z "$SCOPE" ] && SCOPE="$arg" ;;
  esac
done

echo "[$TIMESTAMP] scan-project.sh: scope=${SCOPE:-full} diff=$DIFF_MODE" >> "$DEBUG_LOG"

if [ ! -f "$INVARIANTS_YML" ]; then
  echo '{"error":"No invariants.yml found. Run /ais:baseline first.","violations":[],"stats":{"total":0,"errors":0,"warnings":0}}'
  exit 0
fi

PROJECT_HASH=$(echo "$PWD" | md5 -q 2>/dev/null || echo "$PWD" | md5sum | cut -d' ' -f1)
CACHE_DIR="/tmp/ais-cache-${PROJECT_HASH}"
mkdir -p "$CACHE_DIR"

# --- YAML → JSON (cached by mtime) ---
load_invariants() {
  local yml="$1" cache="$2"
  [ -f "$yml" ] || { echo "AIS: invariants.yml not found" >&2; return 1; }
  if [ -f "$cache" ] && [ "$cache" -nt "$yml" ]; then
    echo "$cache"; return 0
  fi
  python3 - "$yml" "$cache" <<'PYEOF'
import sys, json, re

def parse(src, dst):
    invariants = []
    current = None
    list_key = None
    with open(src) as f:
        for line in f:
            line = line.rstrip('\n')
            m = re.match(r'^  - id:\s*["\']?(.*?)["\']?\s*$', line)
            if m:
                if current:
                    invariants.append(current)
                current = {'id': m.group(1)}
                list_key = None
                continue
            if current is None:
                continue
            m = re.match(r'^      - ["\']?(.*?)["\']?\s*$', line)
            if m and list_key is not None:
                current[list_key].append(m.group(1))
                continue
            m = re.match(r'^    ([a-z_]+):\s*$', line)
            if m:
                list_key = m.group(1)
                current[list_key] = []
                continue
            m = re.match(r'^    ([a-z_]+):\s*["\']?(.*?)["\']?\s*$', line)
            if m:
                current[m.group(1)] = m.group(2)
                list_key = None
                continue
    if current:
        invariants.append(current)
    with open(dst, 'w') as f:
        json.dump({'invariants': invariants}, f)

parse(sys.argv[1], sys.argv[2])
PYEOF
  if [ $? -ne 0 ] || [ ! -s "$cache" ]; then
    echo "AIS: Failed to parse invariants.yml" >&2; return 1
  fi
  echo "$cache"
}

INVARIANTS_JSON=$(load_invariants "$INVARIANTS_YML" "$CACHE_DIR/invariants-scan.json") || {
  echo '{"error":"Failed to parse invariants.yml","violations":[],"stats":{"total":0,"errors":0,"warnings":0}}'
  exit 0
}

# --- Glob → regex ---
glob_to_regex() {
  printf '%s' "$1" \
    | sed \
        -e 's/\./\\./g' \
        -e 's|\*\*|__DS__|g' \
        -e 's|\*|[^/]*|g' \
        -e 's|__DS__|.*|g'
}

path_matches() {
  local path="$1" glob="$2"
  local regex
  regex="^$(glob_to_regex "$glob")"'$'
  echo "$path" | grep -qE "$regex" 2>/dev/null || return 1
}

# Returns 0 if file is in scope for this invariant (matches glob, not in exclude list)
file_in_scope() {
  local rel_path="$1" inv_json="$2"
  local applicable_glob
  applicable_glob=$(echo "$inv_json" | jq -r '.source_glob // .scope_glob // empty')
  [ -z "$applicable_glob" ] && return 0
  path_matches "$rel_path" "$applicable_glob" || return 1
  local excl_count
  excl_count=$(echo "$inv_json" | jq 'if .scope_glob_exclude then .scope_glob_exclude | length else 0 end' 2>/dev/null || echo 0)
  for ((e=0; e<excl_count; e++)); do
    local excl
    excl=$(echo "$inv_json" | jq -r ".scope_glob_exclude[$e]")
    path_matches "$rel_path" "$excl" && return 1
  done
  return 0
}

extract_ts_imports() {
  local file="$1"
  [ -f "$file" ] || return 0
  { grep -oE "(from|require)[[:space:]]*['\"][^'\"]+['\"]" "$file" 2>/dev/null || true; } \
    | { grep -oE "['\"][^'\"]+['\"]" || true; } \
    | tr -d "'\"" || true
}

import_is_forbidden() {
  local import="$1" inv_json="$2"
  local count
  count=$(echo "$inv_json" | jq '.forbidden_imports | length' 2>/dev/null || echo 0)
  for ((f=0; f<count; f++)); do
    local pattern
    pattern=$(echo "$inv_json" | jq -r ".forbidden_imports[$f]")
    if path_matches "$import" "$pattern" || [ "$import" = "$pattern" ]; then
      return 0
    fi
  done
  return 1
}

# --- Build file list ---
IGNORED_PATHS=("node_modules" "dist" ".next" ".git" "coverage" "__pycache__" ".venv" "vendor" "target" "build" ".ais")
IGNORED_ARGS=()
for p in "${IGNORED_PATHS[@]}"; do
  IGNORED_ARGS+=(-not -path "*/$p/*" -not -name "$p")
done

declare -a FILES=()
if $DIFF_MODE; then
  while IFS= read -r f; do
    [ -n "$f" ] && FILES+=("$f")
  done < <(git diff --name-only HEAD 2>/dev/null | grep -v '^$' || true)
else
  SCAN_ROOT="$PWD"
  [ -n "$SCOPE" ] && SCAN_ROOT="$PWD/$SCOPE"
  while IFS= read -r f; do
    [ -n "$f" ] && FILES+=("$(echo "$f" | sed "s|$PWD/||")")
  done < <(find "$SCAN_ROOT" -type f \( -name "*.ts" -o -name "*.js" -o -name "*.py" \) \
    "${IGNORED_ARGS[@]}" 2>/dev/null | sort)
fi

files_checked=${#FILES[@]}
echo "[$TIMESTAMP] scan-project: checking $files_checked files" >> "$DEBUG_LOG"

# --- Accumulate violations ---
VIOLATIONS_FILE="$CACHE_DIR/scan-violations-$$.json"
echo "[]" > "$VIOLATIONS_FILE"

invariant_count=$(jq '.invariants | length' "$INVARIANTS_JSON" 2>/dev/null || echo 0)

for rel_path in "${FILES[@]}"; do
  abs_path="$PWD/$rel_path"
  [ -f "$abs_path" ] || continue

  for ((i=0; i<invariant_count; i++)); do
    inv=$(jq ".invariants[$i]" "$INVARIANTS_JSON")
    rule_id=$(echo "$inv" | jq -r '.id')
    rule_type=$(echo "$inv" | jq -r '.type')
    severity=$(echo "$inv" | jq -r '.severity')
    description=$(echo "$inv" | jq -r '.description')

    file_in_scope "$rel_path" "$inv" || continue

    case "$rule_type" in

      boundary)
        imports=$(extract_ts_imports "$abs_path")
        [ -z "$imports" ] && continue
        while IFS= read -r import; do
          [ -z "$import" ] && continue
          if import_is_forbidden "$import" "$inv"; then
            obj=$(jq -n \
              --arg rule "$rule_id" --arg sev "$severity" --arg msg "$description" \
              --arg file "$rel_path" --arg imp "$import" \
              '{rule:$rule,severity:$sev,message:$msg,file:$file,import:$imp}')
            updated=$(jq --argjson v "$obj" '. + [$v]' "$VIOLATIONS_FILE")
            echo "$updated" > "$VIOLATIONS_FILE"
          fi
        done <<< "$imports"
        ;;

      pattern)
        forbidden_pattern=$(echo "$inv" | jq -r '.forbidden_pattern // empty')
        [ -z "$forbidden_pattern" ] && continue
        if grep -qE "$forbidden_pattern" "$abs_path" 2>/dev/null; then
          line_num=$({ grep -nE "$forbidden_pattern" "$abs_path" 2>/dev/null | head -1 | cut -d: -f1; } || echo "")
          obj=$(jq -n \
            --arg rule "$rule_id" --arg sev "$severity" --arg msg "$description" \
            --arg file "$rel_path" --arg line "${line_num}" \
            '{rule:$rule,severity:$sev,message:$msg,file:$file,line:$line}')
          updated=$(jq --argjson v "$obj" '. + [$v]' "$VIOLATIONS_FILE")
          echo "$updated" > "$VIOLATIONS_FILE"
        fi
        ;;

      convention)
        rule_text=$(echo "$inv" | jq -r '.rule // empty')
        if echo "$rule_text" | grep -qi "test"; then
          if [[ "$rel_path" =~ \.(ts|js|py)$ ]] \
             && [[ ! "$rel_path" =~ \.(test|spec)\. ]] \
             && [[ ! "$rel_path" =~ \.d\.ts$ ]]; then
            base="${abs_path%.*}"
            ext="${abs_path##*.}"
            if ! { [ -f "${base}.test.${ext}" ] || [ -f "${base}.spec.${ext}" ]; }; then
              obj=$(jq -n \
                --arg rule "$rule_id" --arg sev "$severity" \
                --arg msg "Missing colocated test file" --arg file "$rel_path" \
                '{rule:$rule,severity:$sev,message:$msg,file:$file}')
              updated=$(jq --argjson v "$obj" '. + [$v]' "$VIOLATIONS_FILE")
              echo "$updated" > "$VIOLATIONS_FILE"
            fi
          fi
        fi
        ;;

    esac
  done
done

# --- Compute stats ---
VIOLATIONS=$(cat "$VIOLATIONS_FILE")
total=$(echo "$VIOLATIONS" | jq 'length')
errors=$(echo "$VIOLATIONS" | jq '[.[] | select(.severity=="error")] | length')
warnings=$(echo "$VIOLATIONS" | jq '[.[] | select(.severity=="warning")] | length')

rm -f "$VIOLATIONS_FILE"

# --- Output ---
jq -n \
  --arg scope "${SCOPE:-}" \
  --argjson files_checked "$files_checked" \
  --argjson violations "$VIOLATIONS" \
  --argjson total "$total" \
  --argjson errors "$errors" \
  --argjson warnings "$warnings" \
  '{
    scope: $scope,
    files_checked: $files_checked,
    violations: $violations,
    stats: {
      total: $total,
      errors: $errors,
      warnings: $warnings
    }
  }'
```

Make executable: `chmod +x scripts/scan-project.sh`

**Step 2: Run the Phase 3 tests**

```bash
bash tests/verify-phase3.sh
```

Expected: all 6 PASS.

**Step 3: Also confirm Phase 2 tests still pass**

```bash
bash tests/verify-phase2.sh
```

Expected: all PASS (no regressions).

**Step 4: Commit**

```bash
git add scripts/scan-project.sh tests/verify-phase3.sh
git commit -m "feat: implement scan-project.sh batch invariant scanner"
```

---

### Task 7: Update skills/scan/SKILL.md

Replace the stub with a full action skill that calls `scan-project.sh`.

**Files:**
- Modify: `skills/scan/SKILL.md`

**Step 1: Write the full skill**

```markdown
---
name: scan
description: >-
  Run a full architectural scan against the current baseline and invariants.
  Use when the user wants to check for violations, audit a module,
  or see what changed since the last scan. Supports scoping to a subdirectory.
disable-model-invocation: true
argument-hint: "[path/to/module] [--diff]"
---

# AIS Scan

Run the full-project invariant scanner:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/scan-project.sh $ARGUMENTS
```

The output is JSON. Parse it and format a human-readable violation table:

```
Scanning <scope or "entire project"> (<N> files)...

VIOLATIONS
──────────
[ERROR]   <rule-id>
          <file>:<line> — <message>

[WARNING] <rule-id>
          <file> — <message>

N violation(s) found (X errors, Y warnings).
```

If `stats.total` is 0, output: `✅ No violations found.`

Append at the end: `Run /ais:health for the full report with trend data.`

**Scoping:** If `$ARGUMENTS` contains a path (e.g. `src/auth`), the scan is limited to that directory.

**Diff mode:** If `$ARGUMENTS` contains `--diff`, only files changed since `git HEAD` are scanned.
```

**Step 2: Commit**

```bash
git add skills/scan/SKILL.md
git commit -m "feat: implement /ais:scan skill with scan-project.sh"
```

---

## Batch 3: Reporting Layer

### Task 8: Implement agents/debt-projector.md

**Files:**
- Create: `agents/debt-projector.md`

**Step 1: Write the agent**

```markdown
You are a specialized agent that analyzes architectural health history to project technical debt trajectory.

## Your role

Given a list of `.ais/history/*.json` snapshot files, compute the velocity of architectural drift and identify which modules are degrading fastest.

## Inputs

You will receive:
- A list of snapshot file paths, in chronological order
- Each snapshot contains: `{ timestamp, violations: [...] }`

Read each file. For each snapshot, compute:
- `total_violations` = `violations.length`
- `error_violations` = violations where severity == "error"
- `timestamp` = the snapshot timestamp

## Calculations

**Velocity:** Average change in total violations per day across consecutive snapshots.
- For each pair of consecutive snapshots, compute: `(later.total - earlier.total) / days_between`
- Average these deltas. Positive = degrading. Negative = improving.

**Projection:** `velocity * 30` rounded to nearest integer = projected new violations in 30 days.

**Trend:**
- If velocity > 0.5: `"degrading"`
- If velocity < -0.5: `"improving"`
- Otherwise: `"stable"`

**Hotspots:** Group all violations across all snapshots by the top-level module (`file.split("/")[0:2].join("/")`). Sort by frequency descending. Return top 3.

**Recommendation:** Identify the rule ID that appears most frequently across all violations. State what percentage of violations it accounts for.

## Output format

Return ONLY this JSON, no prose:

```json
{
  "velocity": <float, violations per day, 2 decimal places>,
  "projection_30d": <integer>,
  "trend": "degrading" | "improving" | "stable",
  "hotspots": ["src/routes", "src/controllers"],
  "recommendation": "boundary-routes-no-direct-db accounts for 60% of violations. Consider refactoring src/routes to use the repository pattern."
}
```

If fewer than 2 snapshots are provided, return:
```json
{"error": "insufficient_history", "message": "Need at least 2 snapshots for trend analysis"}
```

## Rules

- Do not include any text outside the JSON object
- Round velocity to 2 decimal places
- If projection_30d is negative, set it to 0
- Hotspots list may have fewer than 3 entries if there are fewer modules with violations
```

**Step 2: Commit**

```bash
git add agents/debt-projector.md
git commit -m "feat: implement debt-projector agent for trend analysis"
```

---

### Task 9: Implement scripts/generate-report.sh

This script receives scan JSON (via `--scan`) and optional projection JSON (via `--projection`), computes the health score, reads history for trend, writes self-contained HTML, and opens the browser.

**Files:**
- Create: `scripts/generate-report.sh`

**Step 1: Write the script**

```bash
#!/usr/bin/env bash
set -euo pipefail

# AIS generate-report.sh — HTML health report generator
# Usage: bash generate-report.sh --scan /path/to/scan.json [--projection '{"velocity":...}']
# Output: writes .ais/report.html, opens in browser, prints JSON summary to stdout

DEBUG_LOG="/tmp/ais-debug.log"
TIMESTAMP=$(date '+%Y-%m-%dT%H:%M:%S')
AIS_DIR="$PWD/.ais"

SCAN_FILE=""
PROJECTION_JSON=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scan) SCAN_FILE="$2"; shift 2 ;;
    --projection) PROJECTION_JSON="$2"; shift 2 ;;
    *) shift ;;
  esac
done

if [ -z "$SCAN_FILE" ] || [ ! -f "$SCAN_FILE" ]; then
  echo "AIS: --scan <file> is required and must exist" >&2
  exit 1
fi

echo "[$TIMESTAMP] generate-report.sh: scan=$SCAN_FILE" >> "$DEBUG_LOG"

# --- Read scan data ---
SCAN=$(cat "$SCAN_FILE")
TOTAL=$(echo "$SCAN" | jq '.stats.total')
ERRORS=$(echo "$SCAN" | jq '.stats.errors')
WARNINGS=$(echo "$SCAN" | jq '.stats.warnings')
FILES_CHECKED=$(echo "$SCAN" | jq '.files_checked')
SCOPE=$(echo "$SCAN" | jq -r '.scope // ""')

UNIQUE_ERROR_RULES=$(echo "$SCAN" | jq '[.violations[] | select(.severity=="error") | .rule] | unique | length')
UNIQUE_WARNING_RULES=$(echo "$SCAN" | jq '[.violations[] | select(.severity=="warning") | .rule] | unique | length')

# Health score: 100 - unique_error_rules×10 - unique_warning_rules×3, floor 0
SCORE=$(echo "$UNIQUE_ERROR_RULES $UNIQUE_WARNING_RULES" | awk '{s=100-$1*10-$2*3; print (s<0?0:s)}')

# --- Trend arrow (compare to last history snapshot) ---
PREV_SCORE=""
HISTORY_DIR="$AIS_DIR/history"
mkdir -p "$HISTORY_DIR"

if [ -d "$HISTORY_DIR" ]; then
  LAST_SNAP=$(find "$HISTORY_DIR" -name "*.json" -type f | sort | tail -1)
  if [ -n "$LAST_SNAP" ]; then
    PREV_SCORE=$(jq '.score // empty' "$LAST_SNAP" 2>/dev/null || true)
  fi
fi

if [ -z "$PREV_SCORE" ]; then
  ARROW="→"
  TREND_TEXT="First scan"
elif [ "$SCORE" -gt "$PREV_SCORE" ]; then
  ARROW="↑"
  TREND_TEXT="Up from $PREV_SCORE"
elif [ "$SCORE" -lt "$PREV_SCORE" ]; then
  ARROW="↓"
  TREND_TEXT="Down from $PREV_SCORE"
else
  ARROW="→"
  TREND_TEXT="No change from $PREV_SCORE"
fi

# --- Write history snapshot ---
SNAPSHOT_FILE="$HISTORY_DIR/$(date -u +%Y-%m-%dT%H-%M-%S).json"
echo "$SCAN" | jq \
  --argjson score "$SCORE" \
  --arg ts "$TIMESTAMP" \
  '{score: $score, timestamp: $ts, stats: .stats, violations: .violations}' \
  > "$SNAPSHOT_FILE"
echo "[$TIMESTAMP] History snapshot: $SNAPSHOT_FILE" >> "$DEBUG_LOG"

# --- Compute SVG sparkline from history scores ---
SVG_SPARKLINE=""
SCORE_HISTORY=$(find "$HISTORY_DIR" -name "*.json" -type f | sort | tail -10 | while read -r f; do
  jq '.score // 0' "$f" 2>/dev/null || echo 0
done | tr '\n' ' ')

if [ "$(echo "$SCORE_HISTORY" | wc -w | tr -d ' ')" -ge 2 ]; then
  SVG_SPARKLINE=$(echo "$SCORE_HISTORY" | python3 -c "
import sys
vals = list(map(float, sys.stdin.read().split()))
if len(vals) < 2:
    sys.exit()
w, h = 300, 60
mn, mx = min(vals), max(vals)
rng = mx - mn if mx != mn else 1
pts = []
for i, v in enumerate(vals):
    x = i * (w - 1) / max(len(vals) - 1, 1)
    y = h - ((v - mn) / rng) * (h - 8) - 4
    pts.append(f'{x:.1f},{y:.1f}')
color = '#4ade80' if vals[-1] >= vals[0] else '#f87171'
print(f'<polyline points=\"{\" \".join(pts)}\" stroke=\"{color}\" stroke-width=\"2\" fill=\"none\" stroke-linejoin=\"round\"/>')
" 2>/dev/null || true)
fi

# --- Module breakdown table ---
MODULE_TABLE_HTML=$(echo "$SCAN" | jq -r '
  if (.violations | length) == 0 then
    "<tr><td colspan=\"3\" style=\"color:#4ade80\">All modules clean ✓</td></tr>"
  else
    .violations
    | group_by(.file | split("/")[0:2] | join("/"))
    | map({
        module: (.[0].file | split("/")[0:2] | join("/")),
        errors: (map(select(.severity=="error")) | length),
        warnings: (map(select(.severity=="warning")) | length)
      })
    | sort_by(-.errors, -.warnings)
    | .[:15]
    | .[]
    | "<tr><td><code>\(.module)</code></td><td class=\"e\">\(.errors)</td><td class=\"w\">\(.warnings)</td></tr>"
  end
' 2>/dev/null || echo "<tr><td colspan=\"3\">Error computing modules</td></tr>")

# --- Top violations list ---
VIOLATIONS_HTML=$(echo "$SCAN" | jq -r '
  if (.violations | length) == 0 then
    "<p style=\"color:#4ade80\">No violations found ✓</p>"
  else
    .violations
    | sort_by(if .severity == "error" then 0 else 1 end, .rule)
    | .[:30]
    | .[]
    | "<div class=\"v \(.severity)\"><span class=\"badge\">\(.severity | ascii_upcase)</span> <code>\(.rule)</code> — <span class=\"filepath\">\(.file)\(if (.line != null and .line != "") then ":\(.line)" else "" end)</span></div>"
  end
' 2>/dev/null || echo "<p>Error computing violations</p>")

# --- Debt projection callout ---
PROJECTION_HTML=""
if [ -n "$PROJECTION_JSON" ]; then
  VELOCITY=$(echo "$PROJECTION_JSON" | jq -r '.velocity // ""')
  PROJ_30=$(echo "$PROJECTION_JSON" | jq -r '.projection_30d // ""')
  TREND=$(echo "$PROJECTION_JSON" | jq -r '.trend // "stable"')
  REC=$(echo "$PROJECTION_JSON" | jq -r '.recommendation // ""')
  if [ -n "$VELOCITY" ] && [ "$VELOCITY" != "null" ]; then
    TREND_ICON="→"
    [ "$TREND" = "degrading" ] && TREND_ICON="📈"
    [ "$TREND" = "improving" ] && TREND_ICON="📉"
    PROJECTION_HTML="<div class=\"proj\"><h2>$TREND_ICON Debt Projection</h2><p><strong>Trend:</strong> $TREND | <strong>30-day projection:</strong> +$PROJ_30 violations at current rate ($VELOCITY/day)</p>$([ -n "$REC" ] && echo "<p class=\"rec\">$REC</p>")</div>"
  fi
fi

# --- Score color ---
SCORE_COLOR="#4ade80"
[ "$SCORE" -lt 80 ] && SCORE_COLOR="#facc15"
[ "$SCORE" -lt 50 ] && SCORE_COLOR="#f87171"

SCOPE_LABEL="entire project"
[ -n "$SCOPE" ] && SCOPE_LABEL="$SCOPE"

# --- Generate HTML ---
REPORT_FILE="$AIS_DIR/report.html"
cat > "$REPORT_FILE" <<HTMLEOF
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>AIS Health Report</title>
  <style>
    *, *::before, *::after { box-sizing: border-box; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
      background: #0f172a; color: #e2e8f0;
      max-width: 960px; margin: 0 auto; padding: 32px 24px;
      line-height: 1.5;
    }
    h1 { font-size: 24px; font-weight: 700; color: #f8fafc; margin: 0 0 4px; }
    h2 { font-size: 16px; font-weight: 600; color: #94a3b8; text-transform: uppercase;
         letter-spacing: .05em; border-bottom: 1px solid #1e293b;
         padding-bottom: 8px; margin: 32px 0 12px; }
    .meta { color: #475569; font-size: 13px; margin-bottom: 28px; }
    .score-row { display: flex; align-items: baseline; gap: 12px; margin-bottom: 8px; }
    .score { font-size: 80px; font-weight: 800; color: ${SCORE_COLOR}; line-height: 1; }
    .arrow { font-size: 40px; color: ${SCORE_COLOR}; }
    .score-sub { color: #64748b; font-size: 14px; }
    .summary { color: #94a3b8; font-size: 14px; margin: 4px 0 0; }
    table { width: 100%; border-collapse: collapse; font-size: 14px; }
    th { color: #64748b; font-weight: 500; text-align: left; padding: 6px 10px;
         border-bottom: 2px solid #1e293b; }
    td { padding: 7px 10px; border-bottom: 1px solid #1e293b; }
    .e { color: #f87171; font-weight: 600; }
    .w { color: #facc15; font-weight: 600; }
    .v { padding: 8px 12px; margin: 4px 0; border-radius: 6px;
         background: #1e293b; font-size: 13px; }
    .v.error { border-left: 3px solid #f87171; }
    .v.warning { border-left: 3px solid #facc15; }
    .badge { font-size: 10px; font-weight: 700; padding: 2px 6px; border-radius: 3px;
             margin-right: 8px; vertical-align: middle; }
    .error .badge { background: #450a0a; color: #fca5a5; }
    .warning .badge { background: #422006; color: #fde68a; }
    code { font-family: 'SF Mono', 'Fira Code', monospace; font-size: 12px; color: #93c5fd; }
    .filepath { color: #94a3b8; font-size: 12px; font-family: monospace; }
    .chart-wrap { background: #1e293b; border-radius: 8px; padding: 16px;
                  display: inline-block; margin: 4px 0; }
    .proj { background: #1e293b; border-radius: 8px; padding: 20px; margin: 8px 0; }
    .proj h2 { margin-top: 0; border: none; padding: 0; }
    .rec { color: #94a3b8; font-size: 13px; margin: 8px 0 0;
           border-left: 3px solid #334155; padding-left: 12px; }
    footer { color: #1e293b; font-size: 11px; margin-top: 48px; text-align: center; }
  </style>
</head>
<body>
  <h1>🏥 AIS Architectural Health</h1>
  <p class="meta">$(date '+%Y-%m-%d %H:%M') · Scanned $SCOPE_LABEL · $FILES_CHECKED file(s)</p>

  <div class="score-row">
    <span class="score">$SCORE</span>
    <span class="arrow">$ARROW</span>
    <span class="score-sub">/ 100</span>
  </div>
  <p class="summary">$TREND_TEXT · $TOTAL violation(s) · $UNIQUE_ERROR_RULES unique error rule(s) · $UNIQUE_WARNING_RULES unique warning rule(s)</p>

  <h2>Module Breakdown</h2>
  <table>
    <tr><th>Module</th><th>Errors</th><th>Warnings</th></tr>
    ${MODULE_TABLE_HTML}
  </table>

  <h2>Violations</h2>
  ${VIOLATIONS_HTML}

$(if [ -n "$SVG_SPARKLINE" ]; then
  echo "  <h2>Health Trend</h2>"
  echo "  <div class=\"chart-wrap\">"
  echo "    <svg width=\"300\" height=\"60\" style=\"display:block;overflow:visible\">"
  echo "      $SVG_SPARKLINE"
  echo "    </svg>"
  echo "  </div>"
fi)

  ${PROJECTION_HTML}

  <footer>Generated by AIS · Run /ais:scan for terminal view · /ais:baseline to re-initialize</footer>
</body>
</html>
HTMLEOF

echo "[$TIMESTAMP] Report written: $REPORT_FILE" >> "$DEBUG_LOG"
open "$REPORT_FILE" 2>/dev/null || xdg-open "$REPORT_FILE" 2>/dev/null || echo "AIS: Open $REPORT_FILE in your browser" >&2

# Output summary JSON for Claude to narrate
jq -n \
  --argjson score "$SCORE" \
  --arg arrow "$ARROW" \
  --arg trend_text "$TREND_TEXT" \
  --argjson total "$TOTAL" \
  --argjson errors "$ERRORS" \
  --argjson warnings "$WARNINGS" \
  --argjson files_checked "$FILES_CHECKED" \
  --arg report_path "$REPORT_FILE" \
  '{score:$score, arrow:$arrow, trend_text:$trend_text,
    stats:{total:$total,errors:$errors,warnings:$warnings,files_checked:$files_checked},
    report_path:$report_path}'
```

Make executable: `chmod +x scripts/generate-report.sh`

**Step 2: Smoke-test generate-report.sh**

First run `scan-project.sh` to produce a scan file, then feed it to `generate-report.sh`:

```bash
cd tests/fixtures/unhealthy-project
bash ../../../scripts/scan-project.sh > /tmp/ais-test-scan.json
bash ../../../scripts/generate-report.sh --scan /tmp/ais-test-scan.json
```

Expected:
- A file appears at `tests/fixtures/unhealthy-project/.ais/report.html`
- stdout JSON contains `score`, `stats`, `report_path`
- The HTML file exists and contains `AIS Architectural Health`

```bash
[ -f tests/fixtures/unhealthy-project/.ais/report.html ] && echo "PASS: report.html created"
grep -q "AIS Architectural Health" tests/fixtures/unhealthy-project/.ais/report.html && echo "PASS: title present"
```

**Step 3: Commit**

```bash
git add scripts/generate-report.sh
git commit -m "feat: implement generate-report.sh self-contained HTML health report"
```

---

### Task 10: Update skills/health/SKILL.md

Replace the stub with the full Claude-narrated orchestration skill.

**Files:**
- Modify: `skills/health/SKILL.md`

**Step 1: Write the full skill**

```markdown
---
name: health
description: >-
  Generate an architectural health report for the current project.
  Use when the user asks about code quality, architectural health,
  technical debt, drift trends, or wants a summary of codebase violations.
argument-hint: "[--diff]"
---

# AIS Health Report

Generate a full architectural health report. Follow these steps exactly:

## Step 1: Run the full-project scan

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/scan-project.sh $ARGUMENTS > /tmp/ais-health-scan-$$.json
```

## Step 2: Check for history (debt projection)

Count history snapshots:

```bash
ls ${PWD}/.ais/history/*.json 2>/dev/null | wc -l
```

If there are 2 or more snapshots, invoke the `debt-projector` agent:
- Pass it the list of snapshot file paths (sorted chronologically)
- Capture the JSON output as `PROJECTION`

If fewer than 2 snapshots exist, set `PROJECTION` to empty string.

## Step 3: Generate the HTML report

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/generate-report.sh \
  --scan /tmp/ais-health-scan-$$.json \
  [--projection '$PROJECTION']
```

Include `--projection` only if projection data is available.

## Step 4: Narrate the results

Read the scan JSON from `/tmp/ais-health-scan-$$.json` and the summary JSON from `generate-report.sh` stdout. Narrate a structured summary:

```
📊 Health Score: <score>/100 <arrow>

Files scanned: <N>
Violations: <total> (<errors> errors, <warnings> warnings)

## Module Breakdown
<list modules with violation counts — only show modules with violations>

## Top Violations
<list up to 5, most severe first>

## Trend
<trend_text from generate-report.sh output>
<if projection: velocity + 30-day projection + recommendation>

Full report opened: .ais/report.html
```

If there are no violations, say: `✅ Clean — no architectural violations detected. Health score: 100/100`

Clean up temp file: `rm -f /tmp/ais-health-scan-$$.json`
```

**Step 2: Commit**

```bash
git add skills/health/SKILL.md
git commit -m "feat: implement /ais:health skill with full orchestration"
```

---

## Batch 4: Final Verification

### Task 11: Add generate-report.sh tests to verify-phase3.sh and run all tests

**Files:**
- Modify: `tests/verify-phase3.sh`

**Step 1: Add report generation tests**

Append these tests to `tests/verify-phase3.sh` before the final `echo "Results:"` block:

```bash
# --- generate-report.sh ---
echo ""
echo "generate-report.sh:"

# Setup: run scan on unhealthy project
SCAN_FILE=$(mktemp)
(cd "$UNHEALTHY" && bash "$ROOT/scripts/scan-project.sh" > "$SCAN_FILE")

# Test: report file is created
REPORT_FILE="$UNHEALTHY/.ais/report.html"
rm -f "$REPORT_FILE"
(cd "$UNHEALTHY" && bash "$ROOT/scripts/generate-report.sh" --scan "$SCAN_FILE" > /dev/null 2>&1) || true

if [ -f "$REPORT_FILE" ]; then
  echo "  ✓ report.html created"
  ((passed++)) || true
else
  echo "  ✗ report.html not created"
  ((failed++)) || true
fi

# Test: HTML contains expected sections
if grep -q "AIS Architectural Health" "$REPORT_FILE" 2>/dev/null; then
  echo "  ✓ report contains title"
  ((passed++)) || true
else
  echo "  ✗ report missing title"
  ((failed++)) || true
fi

if grep -q "boundary-routes-no-direct-db" "$REPORT_FILE" 2>/dev/null; then
  echo "  ✓ report contains violation rule id"
  ((passed++)) || true
else
  echo "  ✗ report missing violation data"
  ((failed++)) || true
fi

# Test: stdout is valid JSON with score field
REPORT_OUTPUT=$(cd "$UNHEALTHY" && bash "$ROOT/scripts/generate-report.sh" --scan "$SCAN_FILE" 2>/dev/null)
if echo "$REPORT_OUTPUT" | jq -e '.score' > /dev/null 2>&1; then
  echo "  ✓ stdout JSON contains score"
  ((passed++)) || true
else
  echo "  ✗ stdout JSON missing score"
  ((failed++)) || true
fi

# Test: score is between 0 and 100
SCORE_VAL=$(echo "$REPORT_OUTPUT" | jq '.score')
if [ "$SCORE_VAL" -ge 0 ] && [ "$SCORE_VAL" -le 100 ] 2>/dev/null; then
  echo "  ✓ score is in valid range (0-100)"
  ((passed++)) || true
else
  echo "  ✗ score out of range: $SCORE_VAL"
  ((failed++)) || true
fi

# Test: history snapshot was written
if ls "$UNHEALTHY/.ais/history/"*.json > /dev/null 2>&1; then
  echo "  ✓ history snapshot written"
  ((passed++)) || true
else
  echo "  ✗ no history snapshot written"
  ((failed++)) || true
fi

rm -f "$SCAN_FILE"
```

**Step 2: Run the complete Phase 3 test suite**

```bash
bash tests/verify-phase3.sh
```

Expected: all tests PASS.

**Step 3: Run Phase 2 regression check**

```bash
bash tests/verify-phase2.sh
```

Expected: all PASS.

**Step 4: Commit**

```bash
git add tests/verify-phase3.sh
git commit -m "test: add generate-report.sh verification to verify-phase3.sh"
```

---

### Task 12: Update tasks/todo.md

**Files:**
- Modify: `tasks/todo.md`

**Step 1: Add Phase 3 section**

Append to `tasks/todo.md`:

```markdown
## Phase 3 — Health Dashboard & Reporting

- [x] YAML migration: convert test fixture invariants.json → invariants.yml
- [x] YAML migration: update analyze-edit.sh to use load_invariants() + invariants.yml
- [x] YAML migration: update load-baseline.sh to invariants.yml
- [x] Docs: update CLAUDE.md + ROADMAP.md schema examples (scope_glob_exclude)
- [x] Implement scripts/scan-project.sh (batch invariant checker)
- [x] Implement skills/scan/SKILL.md (full implementation)
- [x] Implement agents/debt-projector.md (trend analysis agent)
- [x] Implement scripts/generate-report.sh (self-contained HTML report)
- [x] Implement skills/health/SKILL.md (full Claude-narrated orchestration)
- [x] End-to-end verification: verify-phase3.sh passes
```

**Step 2: Final commit**

```bash
git add tasks/todo.md
git commit -m "chore: mark Phase 3 complete in todo.md"
```

---

## Summary

| Batch | Tasks | Key Deliverables |
|-------|-------|-----------------|
| 1: Carryover Fixes | 1–4 | YAML migration, scope_glob_exclude, doc updates |
| 2: Batch Scanner | 5–7 | scan-project.sh, /ais:scan skill |
| 3: Reporting | 8–10 | debt-projector agent, generate-report.sh, /ais:health skill |
| 4: Verification | 11–12 | Full test suite, todo update |

All Phase 1 and Phase 2 tests must continue passing throughout.
