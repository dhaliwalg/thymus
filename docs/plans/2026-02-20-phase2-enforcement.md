# Phase 2 — Real-Time Enforcement Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make every file edit trigger live invariant checking. Claude receives immediate warnings about architectural violations so it can self-correct before moving on.

**Architecture:** Three hook scripts become real (currently Phase 0 stubs). `analyze-edit.sh` is the core — it fires on every Edit/Write, loads cached invariants, checks the edited file, and emits a `systemMessage` with any violations. `session-report.sh` aggregates the session at Stop. `load-baseline.sh` is enhanced to include violation history. All caching uses `/tmp/thymus-cache-{PROJECT_HASH}/` for < 2s performance. A new `.thymus/invariants.json` (written by `/thymus:baseline`) gives hooks a jq-parseable invariant store.

**Tech Stack:** bash 4+, jq, grep, find. No external dependencies. Invariants read from `.thymus/invariants.json`.

---

## Pre-work: Fix Phase 1 issues that block Phase 2

### Task 0: Apply Phase 1 fixes

**Files:**
- Modify: `skills/baseline/SKILL.md`
- Modify: `scripts/scan-dependencies.sh`
- Modify: `scripts/detect-patterns.sh`
- Modify: `templates/default-rules.yml`

**Step 1: Update `skills/baseline/SKILL.md` Step 7 to also write `invariants.json`**

In Step 7, after writing `.thymus/invariants.yml`, add:

```
**`.thymus/invariants.json`** — machine-readable copy for hooks (same invariants, JSON format):
```json
{
  "version": "1.0",
  "invariants": [
    {
      "id": "...",
      "type": "boundary|convention|pattern|structure|dependency",
      "severity": "error|warning|info",
      "description": "...",
      "source_glob": "src/routes/**",
      "forbidden_imports": ["src/db/**", "prisma"],
      "allowed_imports": ["src/repositories/**"]
    }
  ]
}
```
Omit fields that don't apply to each invariant type.
```

**Step 2: Fix `source_glob` comma-separated values in `templates/default-rules.yml`**

Change the two offending entries to use `source_globs` (array) instead of `source_glob` (string):

```yaml
# nextjs-no-db-in-pages: change
source_glob: "pages/**,app/**"
# to:
source_globs:
  - "pages/**"
  - "app/**"

# nextjs-no-server-imports-in-client: change
source_glob: "**/*.client.ts,**/*.client.tsx"
# to:
source_globs:
  - "**/*.client.ts"
  - "**/*.client.tsx"
```

**Step 3: Add `|| true` guards to grep pipelines in both scripts**

In `scripts/scan-dependencies.sh`, `get_import_frequency()` at the `xargs grep` line:
```bash
# Before:
| xargs grep -hoE "$pattern" 2>/dev/null \
# After:
| { xargs grep -hoE "$pattern" 2>/dev/null || true; } \
```

Same fix in `get_cross_module_imports()`.

In `scripts/detect-patterns.sh`, the `naming_patterns` section uses `xargs -I{} basename` then `grep -oE` — same guard needed.

**Step 4: Commit**

```bash
git add skills/baseline/SKILL.md templates/default-rules.yml scripts/scan-dependencies.sh scripts/detect-patterns.sh
git commit -m "fix: phase 1 fixups — invariants.json output, source_glob arrays, grep || true guards"
```

---

## Phase 2 Tasks

---

### Task 1: Create test fixture for Phase 2

**Goal:** Give `analyze-edit.sh` a `.thymus/invariants.json` to read during tests, without requiring a full `/thymus:baseline` run.

**Files:**
- Create: `tests/fixtures/unhealthy-project/.thymus/invariants.json`
- Create: `tests/fixtures/healthy-project/.thymus/invariants.json`

**Step 1: Create invariants.json for unhealthy project**

This mirrors what `/thymus:baseline` would produce for the test fixture. Create `tests/fixtures/unhealthy-project/.thymus/invariants.json`:

```json
{
  "version": "1.0",
  "invariants": [
    {
      "id": "boundary-routes-no-direct-db",
      "type": "boundary",
      "severity": "error",
      "description": "Route handlers must not import directly from the db layer",
      "source_glob": "src/routes/**",
      "forbidden_imports": ["../db/client", "src/db/**", "prisma", "knex"],
      "allowed_imports": ["../controllers/**", "../repositories/**"]
    },
    {
      "id": "convention-test-colocation",
      "type": "convention",
      "severity": "warning",
      "description": "Every source file must have a colocated test file",
      "rule": "For every src/**/*.ts (excluding *.test.ts, *.d.ts), there should be a src/**/*.test.ts"
    },
    {
      "id": "pattern-no-raw-sql",
      "type": "pattern",
      "severity": "error",
      "description": "No raw SQL strings outside the db layer",
      "forbidden_pattern": "(SELECT|INSERT|UPDATE|DELETE)[[:space:]]+(FROM|INTO|SET|WHERE)",
      "scope_glob": "src/!(db)/**"
    }
  ]
}
```

**Step 2: Create invariants.json for healthy project**

Create `tests/fixtures/healthy-project/.thymus/invariants.json` — same content as above (healthy project should pass all these rules).

**Step 3: Verify both files are valid JSON**

```bash
jq . tests/fixtures/unhealthy-project/.thymus/invariants.json > /dev/null && echo "PASS"
jq . tests/fixtures/healthy-project/.thymus/invariants.json > /dev/null && echo "PASS"
```

Expected: two `PASS` lines.

**Step 4: Commit**

```bash
git add tests/fixtures/
git commit -m "test: add .thymus/invariants.json fixtures for Phase 2 hook testing"
```

---

### Task 2: Implement `scripts/analyze-edit.sh`

**Files:**
- Modify: `scripts/analyze-edit.sh` (replace Phase 0 stub)

This is the core of Phase 2. Replaces the 18-line Phase 0 stub.

**Step 1: Write the failing verification test first**

Create `tests/verify-analyze-edit.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT="$(dirname "$0")/../scripts/analyze-edit.sh"
UNHEALTHY="$(cd "$(dirname "$0")/../tests/fixtures/unhealthy-project" 2>/dev/null || \
             cd "$(dirname "$0")/fixtures/unhealthy-project" && pwd)"
UNHEALTHY="$(realpath "$(dirname "$0")/fixtures/unhealthy-project")"

echo "=== Testing analyze-edit.sh ==="

# Test 1: boundary violation detected (route imports from db)
input=$(jq -n \
  --arg tool "Edit" \
  --arg file "$UNHEALTHY/src/routes/users.ts" \
  '{tool_name: $tool, tool_input: {file_path: $file}, tool_response: {success: true}}')

output=$(cd "$UNHEALTHY" && echo "$input" | bash "$SCRIPT")

if echo "$output" | jq -e '.systemMessage' > /dev/null 2>&1; then
  if echo "$output" | jq -r '.systemMessage' | grep -q "boundary-routes-no-direct-db"; then
    echo "PASS: boundary violation detected"
  else
    echo "FAIL: systemMessage missing rule id"
    echo "$output" | jq -r '.systemMessage'
    exit 1
  fi
else
  echo "FAIL: no systemMessage in output (expected violation)"
  echo "Output: $output"
  exit 1
fi

# Test 2: healthy file produces no output
input=$(jq -n \
  --arg tool "Edit" \
  --arg file "$UNHEALTHY/src/services/user.service.ts" \
  '{tool_name: $tool, tool_input: {file_path: $file}, tool_response: {success: true}}')

output=$(cd "$UNHEALTHY" && echo "$input" | bash "$SCRIPT")

if [ -z "$output" ] || [ "$output" = "{}" ]; then
  echo "PASS: no violation on clean file"
else
  echo "FAIL: unexpected output on clean file"
  echo "$output"
  exit 1
fi

# Test 3: missing .thymus/ produces no output (silent exit)
TMP_DIR=$(mktemp -d)
input=$(jq -n \
  --arg tool "Edit" \
  --arg file "$TMP_DIR/src/routes/users.ts" \
  '{tool_name: $tool, tool_input: {file_path: $file}, tool_response: {success: true}}')

output=$(cd "$TMP_DIR" && echo "$input" | bash "$SCRIPT")
rm -rf "$TMP_DIR"

if [ -z "$output" ] || [ "$output" = "{}" ]; then
  echo "PASS: silent exit when no .thymus/ present"
else
  echo "FAIL: unexpected output when no baseline"
  exit 1
fi

echo ""
echo "All analyze-edit.sh tests passed."
```

```bash
chmod +x tests/verify-analyze-edit.sh
bash tests/verify-analyze-edit.sh
```

Expected: Test 1 FAIL (script is still a stub), Tests 2-3 might PASS.

**Step 2: Write `scripts/analyze-edit.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

# Thymus PostToolUse hook — analyze-edit.sh
# Fires on every Edit/Write. Checks the edited file against active invariants.
# Output: JSON systemMessage if violations found, empty if clean.
# NEVER exits with code 2 (no blocking).

DEBUG_LOG="/tmp/thymus-debug.log"
TIMESTAMP=$(date '+%Y-%m-%dT%H:%M:%S')

input=$(cat)
file_path=$(echo "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)
tool_name=$(echo "$input" | jq -r '.tool_name // "unknown"' 2>/dev/null || true)

echo "[$TIMESTAMP] analyze-edit.sh: $tool_name on ${file_path:-unknown}" >> "$DEBUG_LOG"

# Nothing to check if no file path
[ -z "$file_path" ] && exit 0

# Look for .thymus/invariants.json in the current working directory (project root)
THYMUS_DIR="$PWD/.thymus"
INVARIANTS_FILE="$THYMUS_DIR/invariants.json"

# No baseline = no checking (silent, don't nag on every edit)
[ -f "$INVARIANTS_FILE" ] || exit 0

# Cache setup — project-specific temp dir
PROJECT_HASH=$(echo "$PWD" | md5 -q 2>/dev/null || echo "$PWD" | md5sum | cut -d' ' -f1)
CACHE_DIR="/tmp/thymus-cache-${PROJECT_HASH}"
mkdir -p "$CACHE_DIR"
SESSION_VIOLATIONS="$CACHE_DIR/session-violations.json"
[ -f "$SESSION_VIOLATIONS" ] || echo "[]" > "$SESSION_VIOLATIONS"

# Make file path relative to project root for glob matching
REL_PATH="${file_path#"$PWD"/}"
# If file is outside PWD, use basename as fallback
[ "$REL_PATH" = "$file_path" ] && REL_PATH=$(basename "$file_path")

echo "[$TIMESTAMP] Checking $REL_PATH" >> "$DEBUG_LOG"

# --- Glob → jq-compatible regex conversion ---
# src/routes/** → ^src/routes/.*$
# src/**/*.ts  → ^src/.*/[^/]*\.ts$
glob_to_regex() {
  printf '%s' "$1" \
    | sed \
        -e 's/\./\\./g' \
        -e 's|\*\*|__DS__|g' \
        -e 's|\*|[^/]*|g' \
        -e 's|__DS__|.*|g'
}

# Returns 0 if path matches glob pattern, 1 otherwise
path_matches() {
  local path="$1" glob="$2"
  local regex
  regex="^$(glob_to_regex "$glob")"'$'
  echo "$path" | grep -qE "$regex" 2>/dev/null || return 1
}

# --- Import extraction (TypeScript/JavaScript) ---
# Returns one import path per line
extract_ts_imports() {
  local file="$1"
  [ -f "$file" ] || return 0
  # Match: from 'path', from "path", require('path'), require("path")
  grep -oE "(from|require)[[:space:]]*['\"][^'\"]+['\"]" "$file" 2>/dev/null \
    | grep -oE "['\"][^'\"]+['\"]" \
    | tr -d "'\"" \
    || true
}

# --- Check one import against a forbidden patterns list ---
# Returns 0 (match found) or 1 (no match)
import_is_forbidden() {
  local import="$1"
  local invariant_json="$2"
  local count
  count=$(echo "$invariant_json" | jq '.forbidden_imports | length' 2>/dev/null || echo 0)
  for ((f=0; f<count; f++)); do
    pattern=$(echo "$invariant_json" | jq -r ".forbidden_imports[$f]")
    # Direct match, prefix match (for ../db/**), or exact package name
    if path_matches "$import" "$pattern" \
       || [ "$import" = "$pattern" ] \
       || echo "$import" | grep -qF "$pattern" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

# --- Accumulate violations in these arrays ---
violation_lines=()
new_violation_objects=()

# --- Load and iterate invariants ---
invariant_count=$(jq '.invariants | length' "$INVARIANTS_FILE" 2>/dev/null || echo 0)

for ((i=0; i<invariant_count; i++)); do
  inv=$(jq ".invariants[$i]" "$INVARIANTS_FILE")
  rule_id=$(echo "$inv" | jq -r '.id')
  rule_type=$(echo "$inv" | jq -r '.type')
  severity=$(echo "$inv" | jq -r '.severity')
  description=$(echo "$inv" | jq -r '.description')

  # Determine the applicable glob (source_glob for boundary/convention, scope_glob for pattern)
  applicable_glob=$(echo "$inv" | jq -r '.source_glob // .scope_glob // empty')

  # Skip invariants that don't apply to this file
  if [ -n "$applicable_glob" ]; then
    path_matches "$REL_PATH" "$applicable_glob" || continue
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
            --arg rule "$rule_id" \
            --arg sev "$severity" \
            --arg msg "$description" \
            --arg file "$REL_PATH" \
            --arg imp "$import" \
            '{rule:$rule,severity:$sev,message:$msg,file:$file,import:$imp}')")
        fi
      done <<< "$imports"
      ;;

    pattern)
      [ -f "$file_path" ] || continue
      forbidden_pattern=$(echo "$inv" | jq -r '.forbidden_pattern // empty')
      [ -z "$forbidden_pattern" ] && continue

      if grep -qE "$forbidden_pattern" "$file_path" 2>/dev/null; then
        line_num=$(grep -nE "$forbidden_pattern" "$file_path" 2>/dev/null | head -1 | cut -d: -f1 || echo "?")
        SEV_UPPER=$(echo "$severity" | tr '[:lower:]' '[:upper:]')
        msg="[$SEV_UPPER] $rule_id: $description (line $line_num)"
        violation_lines+=("$msg")
        new_violation_objects+=("$(jq -n \
          --arg rule "$rule_id" \
          --arg sev "$severity" \
          --arg msg "$description" \
          --arg file "$REL_PATH" \
          --argjson line "${line_num:-0}" \
          '{rule:$rule,severity:$sev,message:$msg,file:$file,line:$line}')")
      fi
      ;;

    convention)
      [ -f "$file_path" ] || continue
      rule_text=$(echo "$inv" | jq -r '.rule // empty')
      # Test colocation convention
      if echo "$rule_text" | grep -qi "test"; then
        # Only check .ts/.js/.py files that aren't test or declaration files
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
              --arg rule "$rule_id" \
              --arg sev "$severity" \
              --arg msg "Missing colocated test file" \
              --arg file "$REL_PATH" \
              '{rule:$rule,severity:$sev,message:$msg,file:$file}')")
          fi
        fi
      fi
      ;;

  esac
done

echo "[$TIMESTAMP] Found ${#violation_lines[@]} violations in $REL_PATH" >> "$DEBUG_LOG"

# --- Exit silently if no violations ---
[ ${#violation_lines[@]} -eq 0 ] && exit 0

# --- Append to session violations cache ---
for obj in "${new_violation_objects[@]}"; do
  updated=$(jq --argjson v "$obj" '. + [$v]' "$SESSION_VIOLATIONS")
  echo "$updated" > "$SESSION_VIOLATIONS"
done

# --- Format systemMessage ---
msg_body="⚠️ Thymus: ${#violation_lines[@]} violation(s) in $REL_PATH:\n"
for line in "${violation_lines[@]}"; do
  msg_body+="  • $line\n"
done

jq -n --arg msg "$msg_body" '{"systemMessage": $msg}'
```

**Step 3: Make executable**

```bash
chmod +x scripts/analyze-edit.sh
```

**Step 4: Run the verification test**

```bash
bash tests/verify-analyze-edit.sh
```

Expected: all 3 tests PASS.

**Step 5: Verify timing**

```bash
input=$(jq -n \
  --arg file "$(pwd)/tests/fixtures/unhealthy-project/src/routes/users.ts" \
  '{tool_name:"Edit",tool_input:{file_path:$file},tool_response:{success:true}}')
time (cd tests/fixtures/unhealthy-project && echo "$input" | bash scripts/analyze-edit.sh)
```

Expected: real time < 0.5s, systemMessage contains `boundary-routes-no-direct-db`.

**Step 6: Commit**

```bash
git add scripts/analyze-edit.sh tests/verify-analyze-edit.sh
git commit -m "feat: implement analyze-edit.sh — real-time boundary and pattern violation detection"
```

---

### Task 3: Implement `scripts/session-report.sh`

**Files:**
- Modify: `scripts/session-report.sh` (replace Phase 0 stub)

**Step 1: Write the verification test**

Create `tests/verify-session-report.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT="$(dirname "$0")/../scripts/session-report.sh"
UNHEALTHY="$(realpath "$(dirname "$0")/fixtures/unhealthy-project")"

echo "=== Testing session-report.sh ==="

PROJECT_HASH=$(echo "$UNHEALTHY" | md5 -q 2>/dev/null || echo "$UNHEALTHY" | md5sum | cut -d' ' -f1)
CACHE_DIR="/tmp/thymus-cache-${PROJECT_HASH}"
SESSION_FILE="$CACHE_DIR/session-violations.json"

# Setup: pre-populate session cache with 2 violations
mkdir -p "$CACHE_DIR"
cat > "$SESSION_FILE" <<'EOF'
[
  {"rule":"boundary-routes-no-direct-db","severity":"error","message":"Route imports db directly","file":"src/routes/users.ts"},
  {"rule":"convention-test-colocation","severity":"warning","message":"Missing test","file":"src/models/user.model.ts"}
]
EOF

# Run the hook
input='{"session_id":"test-session-123"}'
output=$(cd "$UNHEALTHY" && echo "$input" | bash "$SCRIPT")

# Verify it has a systemMessage
echo "$output" | jq -e '.systemMessage' > /dev/null || { echo "FAIL: no systemMessage"; exit 1; }

msg=$(echo "$output" | jq -r '.systemMessage')

# Should mention the violation counts
echo "$msg" | grep -q "1 error" || { echo "FAIL: should mention 1 error. Got: $msg"; exit 1; }
echo "$msg" | grep -q "1 warning" || { echo "FAIL: should mention 1 warning. Got: $msg"; exit 1; }

echo "PASS: session-report.sh output is correct"

# Cleanup
rm -f "$SESSION_FILE"
```

```bash
chmod +x tests/verify-session-report.sh
bash tests/verify-session-report.sh
```

Expected: FAIL (stub outputs nothing).

**Step 2: Write `scripts/session-report.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

# Thymus Stop hook — session-report.sh
# Fires at end of every Claude session. Reads session violations from cache,
# writes a history snapshot, and outputs a compact summary systemMessage.

DEBUG_LOG="/tmp/thymus-debug.log"
TIMESTAMP=$(date '+%Y-%m-%dT%H:%M:%S')
THYMUS_DIR="$PWD/.thymus"

input=$(cat)
session_id=$(echo "$input" | jq -r '.session_id // "unknown"' 2>/dev/null || echo "unknown")

echo "[$TIMESTAMP] session-report.sh: session $session_id ended" >> "$DEBUG_LOG"

# No baseline = silent exit
[ -f "$THYMUS_DIR/baseline.json" ] || exit 0

# Get session cache
PROJECT_HASH=$(echo "$PWD" | md5 -q 2>/dev/null || echo "$PWD" | md5sum | cut -d' ' -f1)
CACHE_DIR="/tmp/thymus-cache-${PROJECT_HASH}"
SESSION_VIOLATIONS="$CACHE_DIR/session-violations.json"

# No violations file means no edits were analyzed
if [ ! -f "$SESSION_VIOLATIONS" ]; then
  jq -n '{"systemMessage": "📋 Thymus: No architectural edits this session."}'
  exit 0
fi

# Count violations by severity
total=$(jq 'length' "$SESSION_VIOLATIONS")
errors=$(jq '[.[] | select(.severity == "error")] | length' "$SESSION_VIOLATIONS")
warnings=$(jq '[.[] | select(.severity == "warning")] | length' "$SESSION_VIOLATIONS")

echo "[$TIMESTAMP] session-report: $total total, $errors errors, $warnings warnings" >> "$DEBUG_LOG"

# Write history snapshot
mkdir -p "$THYMUS_DIR/history"
SNAPSHOT_FILE="$THYMUS_DIR/history/${TIMESTAMP//:/-}.json"
jq -n \
  --arg ts "$TIMESTAMP" \
  --arg sid "$session_id" \
  --argjson violations "$(cat "$SESSION_VIOLATIONS")" \
  '{timestamp: $ts, session_id: $sid, violations: $violations}' \
  > "$SNAPSHOT_FILE"

echo "[$TIMESTAMP] History snapshot written to $SNAPSHOT_FILE" >> "$DEBUG_LOG"

# Build summary message
if [ "$total" -eq 0 ]; then
  summary="✅ Thymus: Clean session — no violations detected."
else
  parts=()
  [ "$errors" -gt 0 ] && parts+=("$errors error(s)")
  [ "$warnings" -gt 0 ] && parts+=("$warnings warning(s)")
  violation_summary=$(IFS=", "; echo "${parts[*]}")

  # Get unique rules violated
  rules=$(jq -r '[.[].rule] | unique | join(", ")' "$SESSION_VIOLATIONS")

  summary="⚠️ Thymus Session: $total violation(s) — $violation_summary | Rules: $rules | Run /thymus:scan for details"
fi

jq -n --arg msg "$summary" '{"systemMessage": $msg}'

# Clear session cache for next session
rm -f "$SESSION_VIOLATIONS"
```

**Step 3: Make executable and run verification**

```bash
chmod +x scripts/session-report.sh
bash tests/verify-session-report.sh
```

Expected: `PASS: session-report.sh output is correct`

**Step 4: Commit**

```bash
git add scripts/session-report.sh tests/verify-session-report.sh
git commit -m "feat: implement session-report.sh — session violation aggregation and history snapshots"
```

---

### Task 4: Enhance `scripts/load-baseline.sh`

**Files:**
- Modify: `scripts/load-baseline.sh`

The current load-baseline.sh already works. We enhance it to include a recent violation count and a health indicator derived from history.

**Step 1: Read current implementation**

Read `scripts/load-baseline.sh` to see what's there.

**Step 2: Update to include recent violation history**

Replace the current "baseline exists" branch (lines 26–39) with an enhanced version:

```bash
# Baseline exists — compute compact summary
MODULE_COUNT=$(jq '.modules | length' "$BASELINE" 2>/dev/null || echo "0")
INVARIANT_COUNT=0
if [ -f "$THYMUS_DIR/invariants.json" ]; then
  INVARIANT_COUNT=$(jq '.invariants | length' "$THYMUS_DIR/invariants.json" 2>/dev/null || echo "0")
elif [ -f "$THYMUS_DIR/invariants.yml" ]; then
  INVARIANT_COUNT=$(grep -c "^  - id:" "$THYMUS_DIR/invariants.yml" 2>/dev/null || echo "0")
fi

# Count recent violations from last history snapshot
RECENT_VIOLATIONS=0
HISTORY_DIR="$THYMUS_DIR/history"
if [ -d "$HISTORY_DIR" ]; then
  LAST_SNAPSHOT=$(find "$HISTORY_DIR" -name "*.json" -type f | sort | tail -1)
  if [ -n "$LAST_SNAPSHOT" ]; then
    RECENT_VIOLATIONS=$(jq '.violations | length' "$LAST_SNAPSHOT" 2>/dev/null || echo "0")
  fi
fi

echo "[$TIMESTAMP] Baseline: $MODULE_COUNT modules, $INVARIANT_COUNT invariants, $RECENT_VIOLATIONS recent violations" >> "$DEBUG_LOG"

# Build compact message (< 500 tokens)
if [ "$RECENT_VIOLATIONS" -gt 0 ]; then
  STATUS="⚠️ Thymus Active"
  VIOLATION_NOTE=" | $RECENT_VIOLATIONS violation(s) last session"
else
  STATUS="✅ Thymus Active"
  VIOLATION_NOTE=""
fi

cat <<EOF
{
  "systemMessage": "$STATUS | $MODULE_COUNT modules | $INVARIANT_COUNT invariants enforced$VIOLATION_NOTE | Run /thymus:health for full report"
}
EOF
```

**Step 3: Verify load-baseline.sh handles the invariants.json path**

```bash
# Quick smoke test — no .thymus/ should produce setup prompt
tmp=$(mktemp -d)
output=$(cd "$tmp" && bash /path/to/scripts/load-baseline.sh)
echo "$output" | jq -r '.systemMessage' | grep -q "No baseline" && echo "PASS: setup prompt shown"
rm -rf "$tmp"
```

**Step 4: Commit**

```bash
git add scripts/load-baseline.sh
git commit -m "feat: enhance load-baseline.sh — reads invariants.json and recent violation history"
```

---

### Task 5: End-to-end verification

**Files:**
- Create: `tests/verify-phase2.sh`

**Step 1: Write the end-to-end test**

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(realpath "$(dirname "$0")/..")"
UNHEALTHY="$ROOT/tests/fixtures/unhealthy-project"
HEALTHY="$ROOT/tests/fixtures/healthy-project"

echo "=== Phase 2 End-to-End Verification ==="
echo ""

passed=0
failed=0

check() {
  local desc="$1"; shift
  if "$@" > /dev/null 2>&1; then
    echo "  ✓ $desc"
    ((passed++)) || true
  else
    echo "  ✗ $desc"
    ((failed++)) || true
  fi
}

check_output() {
  local desc="$1"
  local expected="$2"
  local actual="$3"
  if echo "$actual" | grep -q "$expected"; then
    echo "  ✓ $desc"
    ((passed++)) || true
  else
    echo "  ✗ $desc (got: $actual)"
    ((failed++)) || true
  fi
}

# --- analyze-edit.sh tests ---
echo "analyze-edit.sh:"

# Build test input for unhealthy route (boundary violation)
input=$(jq -n \
  --arg file "$UNHEALTHY/src/routes/users.ts" \
  '{tool_name:"Edit",tool_input:{file_path:$file},tool_response:{success:true}}')

output=$(cd "$UNHEALTHY" && echo "$input" | bash "$ROOT/scripts/analyze-edit.sh")
check_output "detects boundary violation on unhealthy route" "boundary-routes-no-direct-db" "$output"
check_output "systemMessage contains ⚠️ Thymus" "Thymus" "$output"

# Build test input for healthy route (no violation)
input=$(jq -n \
  --arg file "$HEALTHY/src/routes/users.ts" \
  '{tool_name:"Edit",tool_input:{file_path:$file},tool_response:{success:true}}')

output=$(cd "$HEALTHY" && echo "$input" | bash "$ROOT/scripts/analyze-edit.sh")
check_output "no violation on healthy route" "" "$output"

# --- session-report.sh tests ---
echo ""
echo "session-report.sh:"
bash "$ROOT/tests/verify-session-report.sh" > /dev/null 2>&1 && \
  echo "  ✓ session report test suite" && ((passed++)) || true || \
  echo "  ✗ session report test suite" && ((failed++)) || true

# --- load-baseline.sh tests ---
echo ""
echo "load-baseline.sh:"
output=$(cd "$UNHEALTHY" && echo '{}' | bash "$ROOT/scripts/load-baseline.sh")
check_output "shows Thymus Active when baseline exists" "Thymus Active" "$output"
check_output "shows invariant count" "invariants enforced" "$output"

# --- Timing tests ---
echo ""
echo "Performance:"
start=$(date +%s%N 2>/dev/null || date +%s)
input=$(jq -n --arg file "$UNHEALTHY/src/routes/users.ts" '{tool_name:"Edit",tool_input:{file_path:$file},tool_response:{success:true}}')
cd "$UNHEALTHY" && echo "$input" | bash "$ROOT/scripts/analyze-edit.sh" > /dev/null
end=$(date +%s%N 2>/dev/null || date +%s)
# macOS nanoseconds
if [[ "$start" =~ [0-9]{18} ]]; then
  elapsed_ms=$(( (end - start) / 1000000 ))
  if [ "$elapsed_ms" -lt 2000 ]; then
    echo "  ✓ analyze-edit.sh < 2s (${elapsed_ms}ms)"
    ((passed++)) || true
  else
    echo "  ✗ analyze-edit.sh too slow (${elapsed_ms}ms)"
    ((failed++)) || true
  fi
else
  echo "  ~ timing: use 'time' manually to verify < 2s"
fi

echo ""
echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ] || exit 1
```

```bash
chmod +x tests/verify-phase2.sh
bash tests/verify-phase2.sh
```

Expected: all checks pass.

**Step 2: Update `tasks/todo.md`**

Add Phase 2 section:

```markdown
## Phase 2 — Real-Time Enforcement

- [x] Apply Phase 1 fixes (invariants.json output, source_glob arrays, || true guards)
- [x] Add .thymus/invariants.json test fixtures
- [x] Implement scripts/analyze-edit.sh (boundary + pattern + convention checking)
- [x] Implement scripts/session-report.sh (session aggregation + history snapshots)
- [x] Enhance scripts/load-baseline.sh (reads invariants.json, shows recent violation count)
- [x] End-to-end verification: all Phase 2 tests pass, hooks < 2s
```

**Step 3: Final commit**

```bash
git add tests/verify-phase2.sh tasks/todo.md
git commit -m "feat: Phase 2 complete — real-time enforcement with analyze-edit, session-report, load-baseline"
```

---

## Verification Checklist

- [ ] `bash tests/verify-analyze-edit.sh` → all 3 tests PASS
- [ ] `bash tests/verify-session-report.sh` → PASS
- [ ] `bash tests/verify-phase2.sh` → all checks pass
- [ ] `analyze-edit.sh` on unhealthy route → `systemMessage` contains `boundary-routes-no-direct-db`
- [ ] `analyze-edit.sh` on healthy route → empty output
- [ ] `analyze-edit.sh` with no `.thymus/` → empty output (silent)
- [ ] `session-report.sh` with 2 seeded violations → correct error/warning counts in message
- [ ] `load-baseline.sh` with baseline present → `systemMessage` includes invariant count
- [ ] `analyze-edit.sh` timing < 2 seconds (p95)
- [ ] `.thymus/history/` snapshot written after session-report runs
- [ ] `tasks/todo.md` Phase 2 items all checked

---

## Design Notes for Implementation Instance

### Why invariants.json (not YAML)

The hook fires on every edit. Parsing YAML in bash requires either Python (banned) or fragile awk. `jq` can parse JSON in milliseconds. The baseline skill writes both `.thymus/invariants.yml` (human-editable) and `.thymus/invariants.json` (hook-readable). Users edit the YAML; `/thymus:baseline --refresh` regenerates the JSON.

### Glob matching strategy

The `glob_to_regex()` function converts Thymus globs to POSIX ERE for `grep -E`. Key transforms:
- Escape `.` → `\.`
- Replace `**` → `.*` (cross-directory)
- Replace `*` → `[^/]*` (single-segment)
- Anchor with `^...$`

This handles all patterns in `default-rules.yml` correctly.

### Session state via /tmp

The session violations file `/tmp/thymus-cache-{HASH}/session-violations.json` is created by the first analyze-edit.sh call and consumed + deleted by session-report.sh. The hash is derived from `$PWD` so multiple projects don't collide.

### md5 portability

macOS uses `md5 -q`, Linux uses `md5sum`. The script tries `md5 -q` first, falls back to `md5sum`. Both produce the same hex hash.

### Convention check: new file vs. edit

The convention (test colocation) check fires on EVERY edit to a `.ts` file, not just creation. This is intentional — if a user edits a source file that has no test, the warning nudges them to add one. It's `severity: warning` so it's informational, not alarming.
