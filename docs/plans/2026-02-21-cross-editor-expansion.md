# Cross-Editor Expansion Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make Thymus the portable, tool-agnostic architectural rules standard by adding a CLI, pre-commit hook, VS Code extension, and GitHub Action.

**Architecture:** A `bin/` CLI layer wraps existing `scripts/` engine. CLI wrappers use `jq` to translate the internal violation format (`rule`, `import`, `line` as string) to the public schema (`rule_id`, `import_path`, `line` as integer). All downstream integrations (pre-commit, VS Code, GitHub Actions) call only the CLI, never internal scripts. Existing Claude Code hooks remain unchanged.

**Tech Stack:** bash 4+, jq, python3 stdlib, git (core CLI); TypeScript (VS Code extension only)

---

### Task 1: Verify existing tests pass (baseline)

**Files:**
- Read: `tests/verify-phase5.sh`

**Step 1: Run the full test suite**

Run: `bash tests/verify-phase5.sh`
Expected: All tests pass, `0 failed` in output

**Step 2: Commit nothing** — this is just a baseline check. If tests fail, stop and fix before proceeding.

---

### Task 2: Create violation JSON schema

**Files:**
- Create: `docs/violation-schema.json`

**Step 1: Write the schema file**

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "title": "Thymus Violations",
  "type": "array",
  "items": {
    "type": "object",
    "required": ["file", "rule_id", "severity", "message"],
    "properties": {
      "file": {
        "type": "string",
        "description": "Relative path from project root"
      },
      "line": {
        "type": "integer",
        "minimum": 1,
        "description": "Line number of the violation (1-indexed). Null if file-level."
      },
      "column": {
        "type": "integer",
        "minimum": 1,
        "description": "Column number (1-indexed). Optional."
      },
      "rule_id": {
        "type": "string",
        "description": "Unique invariant identifier from invariants.yml"
      },
      "rule_name": {
        "type": "string",
        "description": "Human-readable rule name"
      },
      "severity": {
        "type": "string",
        "enum": ["error", "warn", "info"]
      },
      "message": {
        "type": "string",
        "description": "Human-readable violation description"
      },
      "source_module": {
        "type": "string",
        "description": "Module that contains the violating file"
      },
      "target_module": {
        "type": "string",
        "description": "Module being imported in violation of the rule"
      },
      "import_path": {
        "type": "string",
        "description": "The actual import statement that triggered the violation"
      }
    }
  }
}
```

**Step 2: Validate the schema is valid JSON**

Run: `jq . docs/violation-schema.json`
Expected: Pretty-printed JSON, no errors

**Step 3: Commit**

```bash
git add docs/violation-schema.json
git commit -m "feat: add violation JSON schema contract"
```

---

### Task 3: Create `bin/thymus-check` (single-file CLI wrapper)

This is the smallest CLI component and the one the VS Code extension calls on every save. Build it first because it's the easiest to test.

**Files:**
- Create: `bin/thymus-check`

**Step 1: Write the failing test**

Create `tests/verify-cli.sh` with the thymus-check tests:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UNHEALTHY="$ROOT/tests/fixtures/unhealthy-project"
HEALTHY="$ROOT/tests/fixtures/healthy-project"

echo "=== CLI Verification ==="
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

check_exit() {
  local desc="$1" expected_code="$2"
  shift 2
  local actual_code
  set +e
  "$@" > /dev/null 2>&1
  actual_code=$?
  set -e
  if [ "$actual_code" -eq "$expected_code" ]; then
    echo "  ✓ $desc"
    ((passed++)) || true
  else
    echo "  ✗ $desc (exit $actual_code, expected $expected_code)"
    ((failed++)) || true
  fi
}

# --- thymus-check ---
echo "thymus-check:"

# Test: check a file with violations → exit 1, valid JSON
output=$(cd "$UNHEALTHY" && "$ROOT/bin/thymus-check" src/routes/users.ts --format json 2>/dev/null)
check "detects boundary violation" "boundary-routes-no-direct-db" "$output"
check_json "output uses rule_id field" ".[0].rule_id" "boundary-routes-no-direct-db" "$output"
check_json "severity is error" ".[0].severity" "error" "$output"
check_json "file field is relative path" ".[0].file" "src/routes/users.ts" "$output"
check_json "import_path field present" ".[0].import_path" "../db/client" "$output"

# Test: check a clean file → exit 0, empty array
output=$(cd "$HEALTHY" && "$ROOT/bin/thymus-check" src/routes/users.ts --format json 2>/dev/null)
check_json "clean file returns empty array" ". | length" "0" "$output"
check_exit "clean file exits 0" 0 bash -c "cd '$HEALTHY' && '$ROOT/bin/thymus-check' src/routes/users.ts --format json"

# Test: check violation file exits 1
check_exit "violation file exits 1" 1 bash -c "cd '$UNHEALTHY' && '$ROOT/bin/thymus-check' src/routes/users.ts --format json"

# Test: nonexistent file exits 2
check_exit "nonexistent file exits 2" 2 bash -c "cd '$UNHEALTHY' && '$ROOT/bin/thymus-check' nonexistent.ts --format json"

# Test: text format output
text_output=$(cd "$UNHEALTHY" && "$ROOT/bin/thymus-check" src/routes/users.ts --format text 2>/dev/null || true)
check "text format shows file path" "src/routes/users.ts" "$text_output"
check "text format shows severity" "error" "$text_output"

echo ""
echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ] || exit 1
```

**Step 2: Run test to verify it fails**

Run: `bash tests/verify-cli.sh`
Expected: FAIL (bin/thymus-check doesn't exist yet)

**Step 3: Write `bin/thymus-check`**

```bash
#!/usr/bin/env bash
set -euo pipefail

# thymus-check — Check a single file against invariants
# Usage: thymus-check <file> [--format json|text]
# Exit: 0 = no violations, 1 = violations found, 2 = error

# --- Resolve script location (portable, no readlink -f) ---
SCRIPT="$0"
while [ -L "$SCRIPT" ]; do
  SCRIPT_DIR="$(cd "$(dirname "$SCRIPT")" && pwd)"
  SCRIPT="$(readlink "$SCRIPT")"
  [[ "$SCRIPT" != /* ]] && SCRIPT="$SCRIPT_DIR/$SCRIPT"
done
BIN_DIR="$(cd "$(dirname "$SCRIPT")" && pwd)"
SCRIPTS_DIR="$(cd "$BIN_DIR/../scripts" && pwd)"

# --- Parse args ---
FILE=""
FORMAT=""
for arg in "$@"; do
  case "$arg" in
    --format) : ;;  # next arg is the format value
    json|text)
      if [ "${prev_arg:-}" = "--format" ]; then FORMAT="$arg"; fi
      ;;
    --format=*) FORMAT="${arg#--format=}" ;;
    -*) echo "thymus-check: unknown option: $arg" >&2; exit 2 ;;
    *) [ -z "$FILE" ] && FILE="$arg" ;;
  esac
  prev_arg="$arg"
done

if [ -z "$FILE" ]; then
  echo "Usage: thymus-check <file> [--format json|text]" >&2
  exit 2
fi

# --- Auto-detect format ---
if [ -z "$FORMAT" ]; then
  if [ -t 1 ]; then FORMAT="text"; else FORMAT="json"; fi
fi

# --- Find project root (walk up looking for .thymus/invariants.yml) ---
find_root() {
  local dir="$PWD"
  while [ "$dir" != "/" ]; do
    if [ -f "$dir/.thymus/invariants.yml" ]; then
      echo "$dir"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  return 1
}

PROJECT_ROOT=$(find_root) || {
  echo "thymus-check: no .thymus/invariants.yml found (walk from $PWD to /)" >&2
  exit 2
}

# --- Resolve file to absolute path ---
if [[ "$FILE" = /* ]]; then
  ABS_FILE="$FILE"
else
  ABS_FILE="$PWD/$FILE"
fi

if [ ! -f "$ABS_FILE" ]; then
  echo "thymus-check: file not found: $FILE" >&2
  exit 2
fi

# --- Build hook-style JSON input for analyze-edit.sh ---
INPUT=$(jq -n --arg file "$ABS_FILE" \
  '{tool_name:"ThymusCLI",tool_input:{file_path:$file},tool_response:{success:true}}')

# --- Run analyze-edit.sh and capture its internal violations ---
# analyze-edit.sh writes violations to session-violations.json in the cache dir.
# We need to capture before/after to extract just the new violations.
PROJECT_HASH=$(echo "$PROJECT_ROOT" | md5 -q 2>/dev/null || echo "$PROJECT_ROOT" | md5sum | cut -d' ' -f1)
CACHE_DIR="/tmp/thymus-cache-${PROJECT_HASH}"
mkdir -p "$CACHE_DIR"
SESSION_FILE="$CACHE_DIR/session-violations.json"

# Save current session violations, replace with empty array
SAVED_VIOLATIONS="[]"
[ -f "$SESSION_FILE" ] && SAVED_VIOLATIONS=$(cat "$SESSION_FILE")
echo "[]" > "$SESSION_FILE"

# Run analyze-edit.sh
HOOK_OUTPUT=$(cd "$PROJECT_ROOT" && echo "$INPUT" | bash "$SCRIPTS_DIR/analyze-edit.sh" 2>/dev/null) || true

# Read new violations (what analyze-edit.sh appended)
NEW_VIOLATIONS="[]"
[ -f "$SESSION_FILE" ] && NEW_VIOLATIONS=$(cat "$SESSION_FILE")

# Restore original session violations
echo "$SAVED_VIOLATIONS" > "$SESSION_FILE"

# --- Translate to public schema ---
# Internal: {rule, severity, message, file, import?, package?, line?}
# Public:   {rule_id, severity(warn not warning), message, file, import_path?, line?(int), rule_name, source_module?, target_module?}
REL_FILE="${ABS_FILE#"$PROJECT_ROOT"/}"

VIOLATIONS=$(echo "$NEW_VIOLATIONS" | jq --arg rel "$REL_FILE" '
  [ .[] | {
    file: .file,
    line: (if .line and .line != "" and .line != "?" then (.line | tonumber) else null end),
    rule_id: .rule,
    rule_name: .message,
    severity: (if .severity == "warning" then "warn" else .severity end),
    message: .message,
    source_module: (.file | split("/") | if length > 1 then .[0] + "/" + .[1] else .[0] end),
    target_module: (if .import then (.import | ltrimstr("../") | split("/")[0]) else null end),
    import_path: (.import // null)
  } ]
')

COUNT=$(echo "$VIOLATIONS" | jq 'length')

# --- Output ---
if [ "$FORMAT" = "json" ]; then
  echo "$VIOLATIONS"
else
  if [ "$COUNT" -eq 0 ]; then
    echo "thymus: no violations in $REL_FILE"
  else
    echo "thymus: $COUNT violation(s) in $REL_FILE"
    echo "$VIOLATIONS" | jq -r '.[] |
      "  \(.severity): \(.file)" +
      (if .line then ":\(.line)" else "" end) +
      " — \(.message)" +
      (if .import_path then " (import: \(.import_path))" else "" end)'
  fi
fi

# --- Exit code ---
if [ "$COUNT" -gt 0 ]; then
  exit 1
else
  exit 0
fi
```

**Step 4: Make executable and run tests**

Run: `chmod +x bin/thymus-check && bash tests/verify-cli.sh`
Expected: All thymus-check tests pass

**Step 5: Commit**

```bash
git add bin/thymus-check tests/verify-cli.sh
git commit -m "feat: add thymus-check CLI for single-file checking"
```

---

### Task 4: Create `bin/thymus-scan` (project scanner CLI wrapper)

**Files:**
- Create: `bin/thymus-scan`
- Modify: `tests/verify-cli.sh` (append scan tests)

**Step 1: Add scan tests to `tests/verify-cli.sh`**

Append the following test block before the final results output:

```bash
# --- thymus-scan ---
echo ""
echo "thymus-scan:"

# Test: scan unhealthy project → violations found, valid JSON
output=$(cd "$UNHEALTHY" && "$ROOT/bin/thymus-scan" --format json 2>/dev/null)
check "scan detects boundary violation" "boundary-routes-no-direct-db" "$output"
check_json "output is array" ". | type" "array" "$output"
check_json "violations use rule_id field" ".[0].rule_id" "boundary-routes-no-direct-db" "$(echo "$output" | jq '[.[] | select(.rule_id == "boundary-routes-no-direct-db")]')"
check_json "severity maps warning→warn" ".[0].severity" "warn" "$(echo "$output" | jq '[.[] | select(.severity == "warn")]')"

# Test: scan healthy project → empty array, exit 0
output=$(cd "$HEALTHY" && "$ROOT/bin/thymus-scan" --format json 2>/dev/null)
check_json "healthy project returns empty array" ". | length" "0" "$output"
check_exit "healthy scan exits 0" 0 bash -c "cd '$HEALTHY' && '$ROOT/bin/thymus-scan' --format json"

# Test: scan with violations exits 1
check_exit "violation scan exits 1" 1 bash -c "cd '$UNHEALTHY' && '$ROOT/bin/thymus-scan' --format json"

# Test: --diff flag (staged files only)
# Create a temp git repo, stage a file with violation
TMPDIR_DIFF=$(mktemp -d)
git init "$TMPDIR_DIFF" > /dev/null 2>&1
cp -r "$UNHEALTHY/.thymus" "$TMPDIR_DIFF/"
cp -r "$UNHEALTHY/src" "$TMPDIR_DIFF/"
cp "$UNHEALTHY/package.json" "$TMPDIR_DIFF/"
(cd "$TMPDIR_DIFF" && git add src/routes/users.ts > /dev/null 2>&1)
output=$(cd "$TMPDIR_DIFF" && "$ROOT/bin/thymus-scan" --diff --format json 2>/dev/null)
check "diff mode scans staged files" "boundary-routes-no-direct-db" "$output"
rm -rf "$TMPDIR_DIFF"

# Test: --files flag
output=$(cd "$UNHEALTHY" && "$ROOT/bin/thymus-scan" --files src/routes/users.ts --format json 2>/dev/null)
check "files flag scans specific file" "boundary-routes-no-direct-db" "$output"

# Test: text format
text_output=$(cd "$UNHEALTHY" && "$ROOT/bin/thymus-scan" --format text 2>/dev/null || true)
check "text format shows violation count" "violation" "$text_output"
```

**Step 2: Run test to verify scan tests fail**

Run: `bash tests/verify-cli.sh`
Expected: thymus-check tests pass, thymus-scan tests fail

**Step 3: Write `bin/thymus-scan`**

```bash
#!/usr/bin/env bash
set -euo pipefail

# thymus-scan — Scan project or staged files against invariants
# Usage: thymus-scan [--diff] [--files file1 file2 ...] [--format json|text]
# Exit: 0 = no violations, 1 = violations found, 2 = error

# --- Resolve script location (portable, no readlink -f) ---
SCRIPT="$0"
while [ -L "$SCRIPT" ]; do
  SCRIPT_DIR="$(cd "$(dirname "$SCRIPT")" && pwd)"
  SCRIPT="$(readlink "$SCRIPT")"
  [[ "$SCRIPT" != /* ]] && SCRIPT="$SCRIPT_DIR/$SCRIPT"
done
BIN_DIR="$(cd "$(dirname "$SCRIPT")" && pwd)"
SCRIPTS_DIR="$(cd "$BIN_DIR/../scripts" && pwd)"

# --- Parse args ---
DIFF_MODE=false
FORMAT=""
FILES=()
PARSING_FILES=false
prev_arg=""
for arg in "$@"; do
  if $PARSING_FILES; then
    case "$arg" in
      --*) PARSING_FILES=false ;;  # new flag ends --files list
      *) FILES+=("$arg"); continue ;;
    esac
  fi
  case "$arg" in
    --diff) DIFF_MODE=true ;;
    --files) PARSING_FILES=true ;;
    --format) : ;;
    json|text)
      if [ "${prev_arg:-}" = "--format" ]; then FORMAT="$arg"; fi
      ;;
    --format=*) FORMAT="${arg#--format=}" ;;
    -*) echo "thymus-scan: unknown option: $arg" >&2; exit 2 ;;
  esac
  prev_arg="$arg"
done

# --- Auto-detect format ---
if [ -z "$FORMAT" ]; then
  if [ -t 1 ]; then FORMAT="text"; else FORMAT="json"; fi
fi

# --- Find project root ---
find_root() {
  local dir="$PWD"
  while [ "$dir" != "/" ]; do
    if [ -f "$dir/.thymus/invariants.yml" ]; then
      echo "$dir"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  return 1
}

PROJECT_ROOT=$(find_root) || {
  echo "thymus-scan: no .thymus/invariants.yml found" >&2
  exit 2
}

# --- Build scan args ---
SCAN_ARGS=()

if $DIFF_MODE; then
  # Build file list from staged files
  STAGED_FILES=$(cd "$PROJECT_ROOT" && git diff --cached --name-only 2>/dev/null || true)
  if [ -z "$STAGED_FILES" ]; then
    if [ "$FORMAT" = "json" ]; then
      echo "[]"
    else
      echo "thymus: no staged files to scan"
    fi
    exit 0
  fi
  # Use thymus-check on each staged file and merge results
  ALL_VIOLATIONS="[]"
  while IFS= read -r staged_file; do
    [ -z "$staged_file" ] && continue
    [ -f "$PROJECT_ROOT/$staged_file" ] || continue
    FILE_VIOLATIONS=$(cd "$PROJECT_ROOT" && "$BIN_DIR/thymus-check" "$staged_file" --format json 2>/dev/null) || true
    if [ -n "$FILE_VIOLATIONS" ] && [ "$FILE_VIOLATIONS" != "[]" ]; then
      ALL_VIOLATIONS=$(echo "$ALL_VIOLATIONS" "$FILE_VIOLATIONS" | jq -s '.[0] + .[1]')
    fi
  done <<< "$STAGED_FILES"
  VIOLATIONS="$ALL_VIOLATIONS"

elif [ "${#FILES[@]}" -gt 0 ]; then
  # Scan specific files using thymus-check
  ALL_VIOLATIONS="[]"
  for file in "${FILES[@]}"; do
    [ -f "$PROJECT_ROOT/$file" ] || continue
    FILE_VIOLATIONS=$(cd "$PROJECT_ROOT" && "$BIN_DIR/thymus-check" "$file" --format json 2>/dev/null) || true
    if [ -n "$FILE_VIOLATIONS" ] && [ "$FILE_VIOLATIONS" != "[]" ]; then
      ALL_VIOLATIONS=$(echo "$ALL_VIOLATIONS" "$FILE_VIOLATIONS" | jq -s '.[0] + .[1]')
    fi
  done
  VIOLATIONS="$ALL_VIOLATIONS"

else
  # Full project scan — use scan-project.sh and translate
  RAW_OUTPUT=$(cd "$PROJECT_ROOT" && bash "$SCRIPTS_DIR/scan-project.sh" 2>/dev/null) || {
    echo "thymus-scan: scan-project.sh failed" >&2
    exit 2
  }

  # Translate from internal format to public schema
  VIOLATIONS=$(echo "$RAW_OUTPUT" | jq '
    [ .violations[] | {
      file: .file,
      line: (if .line and .line != "" and .line != "?" then (.line | tonumber) else null end),
      rule_id: .rule,
      rule_name: .message,
      severity: (if .severity == "warning" then "warn" else .severity end),
      message: .message,
      source_module: (.file | split("/") | if length > 1 then .[0] + "/" + .[1] else .[0] end),
      target_module: (if .import then (.import | ltrimstr("../") | split("/")[0]) else null end),
      import_path: (.import // null)
    } ]
  ')
fi

COUNT=$(echo "$VIOLATIONS" | jq 'length')

# --- Output ---
if [ "$FORMAT" = "json" ]; then
  echo "$VIOLATIONS"
else
  if [ "$COUNT" -eq 0 ]; then
    echo "thymus: no violations found"
  else
    ERRORS=$(echo "$VIOLATIONS" | jq '[.[] | select(.severity == "error")] | length')
    WARNS=$(echo "$VIOLATIONS" | jq '[.[] | select(.severity == "warn")] | length')
    echo "thymus: $COUNT violation(s) found ($ERRORS errors, $WARNS warnings)"
    echo ""
    echo "$VIOLATIONS" | jq -r '.[] |
      "  \(.severity): \(.file)" +
      (if .line then ":\(.line)" else "" end) +
      " — \(.message)" +
      (if .import_path then " (import: \(.import_path))" else "" end)'
  fi
fi

# --- Exit code ---
if [ "$COUNT" -gt 0 ]; then
  exit 1
else
  exit 0
fi
```

**Step 4: Make executable and run tests**

Run: `chmod +x bin/thymus-scan && bash tests/verify-cli.sh`
Expected: All tests pass

**Step 5: Commit**

```bash
git add bin/thymus-scan tests/verify-cli.sh
git commit -m "feat: add thymus-scan CLI for project scanning"
```

---

### Task 5: Create `bin/thymus-init`

**Files:**
- Create: `bin/thymus-init`
- Modify: `tests/verify-cli.sh` (append init tests)

**Step 1: Add init tests to `tests/verify-cli.sh`**

Append before the results section:

```bash
# --- thymus-init ---
echo ""
echo "thymus-init:"

# Test: init creates .thymus/ with starter files
TMPDIR_INIT=$(mktemp -d)
"$ROOT/bin/thymus-init" "$TMPDIR_INIT" > /dev/null 2>&1
if [ -f "$TMPDIR_INIT/.thymus/invariants.yml" ]; then
  echo "  ✓ creates invariants.yml"
  ((passed++)) || true
else
  echo "  ✗ invariants.yml not created"
  ((failed++)) || true
fi
if [ -f "$TMPDIR_INIT/.thymus/config.yml" ]; then
  echo "  ✓ creates config.yml"
  ((passed++)) || true
else
  echo "  ✗ config.yml not created"
  ((failed++)) || true
fi

# Test: invariants.yml is valid YAML with at least a version field
if grep -q "version:" "$TMPDIR_INIT/.thymus/invariants.yml" 2>/dev/null; then
  echo "  ✓ invariants.yml has version field"
  ((passed++)) || true
else
  echo "  ✗ invariants.yml missing version"
  ((failed++)) || true
fi

# Test: init does not overwrite existing files
echo "custom: true" > "$TMPDIR_INIT/.thymus/config.yml"
"$ROOT/bin/thymus-init" "$TMPDIR_INIT" > /dev/null 2>&1 || true
if grep -q "custom: true" "$TMPDIR_INIT/.thymus/config.yml" 2>/dev/null; then
  echo "  ✓ does not overwrite existing config"
  ((passed++)) || true
else
  echo "  ✗ overwrote existing config"
  ((failed++)) || true
fi

# Test: init with no args uses $PWD
TMPDIR_INIT2=$(mktemp -d)
(cd "$TMPDIR_INIT2" && "$ROOT/bin/thymus-init") > /dev/null 2>&1
if [ -f "$TMPDIR_INIT2/.thymus/invariants.yml" ]; then
  echo "  ✓ init with no args uses PWD"
  ((passed++)) || true
else
  echo "  ✗ init with no args failed"
  ((failed++)) || true
fi

rm -rf "$TMPDIR_INIT" "$TMPDIR_INIT2"
```

**Step 2: Run test to verify init tests fail**

Run: `bash tests/verify-cli.sh`
Expected: check/scan tests pass, init tests fail

**Step 3: Write `bin/thymus-init`**

```bash
#!/usr/bin/env bash
set -euo pipefail

# thymus-init — Initialize .thymus/ in a project
# Usage: thymus-init [target_dir]
# If target_dir not given, uses $PWD.
# Creates .thymus/ with starter invariants.yml and config.yml.
# Runs scan-dependencies.sh to auto-detect language/framework.
# Does NOT overwrite existing files.

# --- Resolve script location ---
SCRIPT="$0"
while [ -L "$SCRIPT" ]; do
  SCRIPT_DIR="$(cd "$(dirname "$SCRIPT")" && pwd)"
  SCRIPT="$(readlink "$SCRIPT")"
  [[ "$SCRIPT" != /* ]] && SCRIPT="$SCRIPT_DIR/$SCRIPT"
done
BIN_DIR="$(cd "$(dirname "$SCRIPT")" && pwd)"
SCRIPTS_DIR="$(cd "$BIN_DIR/../scripts" && pwd)"
TEMPLATES_DIR="$(cd "$BIN_DIR/../templates" && pwd)"

TARGET="${1:-$PWD}"

if [ ! -d "$TARGET" ]; then
  echo "thymus-init: directory not found: $TARGET" >&2
  exit 2
fi

THYMUS_DIR="$TARGET/.thymus"
mkdir -p "$THYMUS_DIR"
mkdir -p "$THYMUS_DIR/history"

# --- Detect language/framework ---
LANG="unknown"
FRAMEWORK="unknown"
if [ -f "$SCRIPTS_DIR/scan-dependencies.sh" ]; then
  DEPS_JSON=$(cd "$TARGET" && bash "$SCRIPTS_DIR/scan-dependencies.sh" "$TARGET" 2>/dev/null) || true
  if [ -n "$DEPS_JSON" ]; then
    LANG=$(echo "$DEPS_JSON" | jq -r '.language // "unknown"')
    FRAMEWORK=$(echo "$DEPS_JSON" | jq -r '.framework // "unknown"')
  fi
fi

echo "thymus: detected language=$LANG framework=$FRAMEWORK"

# --- Create config.yml (only if not exists) ---
if [ ! -f "$THYMUS_DIR/config.yml" ]; then
  cat > "$THYMUS_DIR/config.yml" <<EOF
version: "1.0"
ignored_paths: [node_modules, dist, .next, .git, coverage, .thymus, .worktrees, __pycache__, .venv, vendor, target, build]
health_warning_threshold: 70
health_error_threshold: 50
language: $LANG
EOF
  echo "thymus: created .thymus/config.yml"
else
  echo "thymus: .thymus/config.yml already exists, skipping"
fi

# --- Create invariants.yml with default rules ---
if [ ! -f "$THYMUS_DIR/invariants.yml" ]; then
  # Start with header
  cat > "$THYMUS_DIR/invariants.yml" <<'EOF'
version: "1.0"
invariants:
EOF

  # Copy framework-specific rules from templates if available
  RULES_ADDED=0
  if [ -f "$TEMPLATES_DIR/default-rules.yml" ]; then
    # Always add generic rules
    python3 - "$TEMPLATES_DIR/default-rules.yml" "$THYMUS_DIR/invariants.yml" "$FRAMEWORK" <<'PYEOF'
import sys, re

template_file = sys.argv[1]
output_file = sys.argv[2]
framework = sys.argv[3]

with open(template_file) as f:
    content = f.read()

# Parse sections: find lines like "sectionname:" at indent 0
sections = {}
current_section = None
current_lines = []
for line in content.split('\n'):
    # Skip comments and blank lines at top level
    if re.match(r'^[a-z]+:', line):
        if current_section and current_lines:
            sections[current_section] = current_lines
        current_section = line.rstrip(':').strip()
        current_lines = []
    elif current_section is not None:
        current_lines.append(line)
if current_section and current_lines:
    sections[current_section] = current_lines

# Collect rules to add: always "generic", plus framework if detected
targets = ['generic']
if framework != 'unknown' and framework in sections:
    targets.append(framework)

rules = []
for section in targets:
    if section in sections:
        for line in sections[section]:
            rules.append(line)

# Filter out comment-only rules (lines starting with #)
# Keep only actual rule blocks (starting with "  - id:")
filtered = []
in_commented = False
for line in rules:
    stripped = line.lstrip()
    if stripped.startswith('# ') and not stripped.startswith('# v2'):
        continue
    if stripped.startswith('# -') or stripped.startswith('#   '):
        in_commented = True
        continue
    if in_commented and (stripped == '' or stripped.startswith('#')):
        continue
    in_commented = False
    filtered.append(line)

with open(output_file, 'a') as f:
    for line in filtered:
        if line.strip():  # skip blank lines
            f.write(line + '\n')

# Count rules added
count = sum(1 for line in filtered if line.strip().startswith('- id:'))
print(count)
PYEOF
    RULES_ADDED=$?
  fi

  echo "thymus: created .thymus/invariants.yml"
else
  echo "thymus: .thymus/invariants.yml already exists, skipping"
fi

# --- Add .thymus/ to .gitignore ---
if [ -d "$TARGET/.git" ]; then
  GITIGNORE="$TARGET/.gitignore"
  if ! grep -q "^\.thymus" "$GITIGNORE" 2>/dev/null; then
    echo ".thymus/" >> "$GITIGNORE"
    echo "thymus: added .thymus/ to .gitignore"
  fi
fi

echo "thymus: initialization complete"
echo ""
echo "Next steps:"
echo "  1. Review .thymus/invariants.yml and add project-specific rules"
echo "  2. Run: bin/thymus scan"
echo "  3. (Optional) Install pre-commit hook: ln -sf ../../integrations/pre-commit/thymus-pre-commit .git/hooks/pre-commit"
```

**Step 4: Make executable and run tests**

Run: `chmod +x bin/thymus-init && bash tests/verify-cli.sh`
Expected: All tests pass

**Step 5: Commit**

```bash
git add bin/thymus-init tests/verify-cli.sh
git commit -m "feat: add thymus-init CLI for project initialization"
```

---

### Task 6: Create `bin/thymus` (main entry point with subcommands)

**Files:**
- Create: `bin/thymus`
- Modify: `tests/verify-cli.sh` (add entry point tests)

**Step 1: Add main entry point tests to `tests/verify-cli.sh`**

Prepend before existing sections:

```bash
# --- thymus (main entry point) ---
echo "thymus (entry point):"

# Test: version command
output=$("$ROOT/bin/thymus" version 2>/dev/null)
check "version outputs version string" "thymus" "$output"
check_exit "version exits 0" 0 "$ROOT/bin/thymus" version

# Test: no args shows usage
output=$("$ROOT/bin/thymus" 2>/dev/null || true)
check "no args shows usage" "Usage:" "$output"

# Test: scan subcommand routes to thymus-scan
output=$(cd "$UNHEALTHY" && "$ROOT/bin/thymus" scan --format json 2>/dev/null)
check "scan routes correctly" "boundary-routes-no-direct-db" "$output"

# Test: check subcommand routes to thymus-check
output=$(cd "$UNHEALTHY" && "$ROOT/bin/thymus" check src/routes/users.ts --format json 2>/dev/null)
check "check routes correctly" "boundary-routes-no-direct-db" "$output"

# Test: init subcommand
TMPDIR_ENTRY=$(mktemp -d)
"$ROOT/bin/thymus" init "$TMPDIR_ENTRY" > /dev/null 2>&1
if [ -f "$TMPDIR_ENTRY/.thymus/invariants.yml" ]; then
  echo "  ✓ init routes correctly"
  ((passed++)) || true
else
  echo "  ✗ init routing failed"
  ((failed++)) || true
fi
rm -rf "$TMPDIR_ENTRY"

# Test: unknown command exits 2
check_exit "unknown command exits 2" 2 "$ROOT/bin/thymus" foobar

echo ""
```

**Step 2: Run test to verify entry point tests fail**

Run: `bash tests/verify-cli.sh`
Expected: entry point tests fail, other tests pass

**Step 3: Write `bin/thymus`**

```bash
#!/usr/bin/env bash
set -euo pipefail

# thymus — Architectural invariants for AI-assisted codebases
# Usage: thymus <command> [options]

VERSION="0.1.0"

# --- Resolve script location ---
SCRIPT="$0"
while [ -L "$SCRIPT" ]; do
  SCRIPT_DIR="$(cd "$(dirname "$SCRIPT")" && pwd)"
  SCRIPT="$(readlink "$SCRIPT")"
  [[ "$SCRIPT" != /* ]] && SCRIPT="$SCRIPT_DIR/$SCRIPT"
done
BIN_DIR="$(cd "$(dirname "$SCRIPT")" && pwd)"

usage() {
  cat <<EOF
thymus v$VERSION — Architectural invariants for AI-assisted codebases

Usage: thymus <command> [options]

Commands:
  scan [--diff] [--files f1 f2] [--format json|text]   Scan project or staged files
  check <file> [--format json|text]                     Check single file against invariants
  init [dir]                                            Initialize .thymus/ in a project
  version                                               Print version

Exit codes:
  0  No violations found
  1  Violations found
  2  Configuration or runtime error

Docs: https://github.com/anthropics/thymus
EOF
}

if [ $# -eq 0 ]; then
  usage
  exit 2
fi

COMMAND="$1"
shift

case "$COMMAND" in
  scan)
    exec "$BIN_DIR/thymus-scan" "$@"
    ;;
  check)
    exec "$BIN_DIR/thymus-check" "$@"
    ;;
  init)
    exec "$BIN_DIR/thymus-init" "$@"
    ;;
  version)
    echo "thymus v$VERSION"
    exit 0
    ;;
  help|--help|-h)
    usage
    exit 0
    ;;
  *)
    echo "thymus: unknown command: $COMMAND" >&2
    echo "Run 'thymus help' for usage." >&2
    exit 2
    ;;
esac
```

**Step 4: Make executable and run tests**

Run: `chmod +x bin/thymus && bash tests/verify-cli.sh`
Expected: All tests pass

**Step 5: Verify existing tests still pass**

Run: `bash tests/verify-phase5.sh`
Expected: All previous tests still pass (backward compatible)

**Step 6: Commit**

```bash
git add bin/thymus tests/verify-cli.sh
git commit -m "feat: add thymus CLI entry point with subcommand routing"
```

---

### Task 7: Create pre-commit hook integration

**Files:**
- Create: `integrations/pre-commit/thymus-pre-commit`
- Create: `integrations/pre-commit/.pre-commit-hooks.yaml`
- Modify: `tests/verify-cli.sh` (append pre-commit tests)

**Step 1: Add pre-commit tests to `tests/verify-cli.sh`**

```bash
# --- pre-commit hook ---
echo ""
echo "pre-commit hook:"

# Test: hook script exists and is executable
if [ -x "$ROOT/integrations/pre-commit/thymus-pre-commit" ]; then
  echo "  ✓ thymus-pre-commit is executable"
  ((passed++)) || true
else
  echo "  ✗ thymus-pre-commit missing or not executable"
  ((failed++)) || true
fi

# Test: hook blocks commit with error-severity violations
TMPDIR_HOOK=$(mktemp -d)
git init "$TMPDIR_HOOK" > /dev/null 2>&1
cp -r "$UNHEALTHY/.thymus" "$TMPDIR_HOOK/"
cp -r "$UNHEALTHY/src" "$TMPDIR_HOOK/"
cp "$UNHEALTHY/package.json" "$TMPDIR_HOOK/"
# Copy bin/ so the hook can find it
cp -r "$ROOT/bin" "$TMPDIR_HOOK/"
# Copy scripts/ so bin/ can find them
cp -r "$ROOT/scripts" "$TMPDIR_HOOK/"
# Copy templates/ for init
cp -r "$ROOT/templates" "$TMPDIR_HOOK/"
(cd "$TMPDIR_HOOK" && git add src/routes/users.ts > /dev/null 2>&1)
hook_output=$(cd "$TMPDIR_HOOK" && bash "$ROOT/integrations/pre-commit/thymus-pre-commit" 2>&1 || true)
hook_exit=$?
# The hook should detect violations and exit 1
if [ "$hook_exit" -ne 0 ] && echo "$hook_output" | grep -q "violation"; then
  echo "  ✓ hook blocks commit with error violations"
  ((passed++)) || true
else
  echo "  ✗ hook did not block (exit=$hook_exit, output: $hook_output)"
  ((failed++)) || true
fi
rm -rf "$TMPDIR_HOOK"

# Test: hook allows commit with only warnings
TMPDIR_HOOK2=$(mktemp -d)
git init "$TMPDIR_HOOK2" > /dev/null 2>&1
cp -r "$UNHEALTHY/.thymus" "$TMPDIR_HOOK2/"
cp -r "$UNHEALTHY/src" "$TMPDIR_HOOK2/"
cp "$UNHEALTHY/package.json" "$TMPDIR_HOOK2/"
cp -r "$ROOT/bin" "$TMPDIR_HOOK2/"
cp -r "$ROOT/scripts" "$TMPDIR_HOOK2/"
cp -r "$ROOT/templates" "$TMPDIR_HOOK2/"
# Stage only the model file (which has a warning-level convention violation, not error boundary)
(cd "$TMPDIR_HOOK2" && git add src/models/user.model.ts > /dev/null 2>&1)
hook_exit2=0
(cd "$TMPDIR_HOOK2" && bash "$ROOT/integrations/pre-commit/thymus-pre-commit" > /dev/null 2>&1) || hook_exit2=$?
if [ "$hook_exit2" -eq 0 ]; then
  echo "  ✓ hook allows commit with warnings only"
  ((passed++)) || true
else
  echo "  ✗ hook blocked commit with only warnings (exit=$hook_exit2)"
  ((failed++)) || true
fi
rm -rf "$TMPDIR_HOOK2"

# Test: .pre-commit-hooks.yaml exists and is valid YAML
if [ -f "$ROOT/integrations/pre-commit/.pre-commit-hooks.yaml" ]; then
  echo "  ✓ .pre-commit-hooks.yaml exists"
  ((passed++)) || true
else
  echo "  ✗ .pre-commit-hooks.yaml missing"
  ((failed++)) || true
fi
```

**Step 2: Run test to verify pre-commit tests fail**

Run: `bash tests/verify-cli.sh`
Expected: pre-commit tests fail

**Step 3: Create directory and write `integrations/pre-commit/thymus-pre-commit`**

```bash
#!/usr/bin/env bash
set -euo pipefail

# thymus-pre-commit — Git pre-commit hook for Thymus
# Scans staged files against architectural invariants.
# Exit 0 = pass (or thymus not configured), Exit 1 = blocked (error violations)

# Find thymus binary relative to repo root
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
THYMUS_BIN="$REPO_ROOT/bin/thymus"

if [ ! -x "$THYMUS_BIN" ]; then
  echo "thymus: bin/thymus not found. Run 'thymus init' first." >&2
  exit 0  # Don't block commits if thymus isn't set up
fi

if [ ! -f "$REPO_ROOT/.thymus/invariants.yml" ]; then
  exit 0  # No rules configured
fi

# Scan only staged files
VIOLATIONS=$("$THYMUS_BIN" scan --diff --format json 2>/dev/null) || true

if [ -z "$VIOLATIONS" ] || [ "$VIOLATIONS" = "[]" ]; then
  exit 0
fi

COUNT=$(echo "$VIOLATIONS" | jq 'length')

if [ "$COUNT" -eq 0 ]; then
  exit 0
fi

echo "thymus: $COUNT architectural violation(s) found in staged files:"
echo "$VIOLATIONS" | jq -r '.[] |
  "  \(.severity): \(.file)" +
  (if .line then ":\(.line)" else "" end) +
  " — \(.message)"'

# Check if any are errors (not just warnings)
ERRORS=$(echo "$VIOLATIONS" | jq '[.[] | select(.severity == "error")] | length')
if [ "$ERRORS" -gt 0 ]; then
  echo ""
  echo "Commit blocked. Fix $ERRORS error(s) or use --no-verify to bypass."
  exit 1
else
  echo ""
  echo "Warnings only — commit proceeding."
  exit 0
fi
```

**Step 4: Write `integrations/pre-commit/.pre-commit-hooks.yaml`**

```yaml
- id: thymus
  name: thymus architectural lint
  entry: bin/thymus scan --diff --format text
  language: script
  pass_filenames: false
  always_run: true
  stages: [pre-commit, pre-merge-commit, pre-push, manual]
```

**Step 5: Make executable and run tests**

Run: `chmod +x integrations/pre-commit/thymus-pre-commit && bash tests/verify-cli.sh`
Expected: All tests pass

**Step 6: Commit**

```bash
git add integrations/pre-commit/thymus-pre-commit integrations/pre-commit/.pre-commit-hooks.yaml tests/verify-cli.sh
git commit -m "feat: add git pre-commit hook integration"
```

---

### Task 8: Create GitHub Action

**Files:**
- Create: `integrations/github-actions/action.yml`
- Modify: `tests/verify-cli.sh` (append action tests)

**Step 1: Add action tests to `tests/verify-cli.sh`**

```bash
# --- GitHub Action ---
echo ""
echo "GitHub Action:"

# Test: action.yml exists
if [ -f "$ROOT/integrations/github-actions/action.yml" ]; then
  echo "  ✓ action.yml exists"
  ((passed++)) || true
else
  echo "  ✗ action.yml missing"
  ((failed++)) || true
fi

# Test: action.yml has required fields
if grep -q "name:" "$ROOT/integrations/github-actions/action.yml" 2>/dev/null && \
   grep -q "inputs:" "$ROOT/integrations/github-actions/action.yml" 2>/dev/null; then
  echo "  ✓ action.yml has name and inputs"
  ((passed++)) || true
else
  echo "  ✗ action.yml missing required fields"
  ((failed++)) || true
fi
```

**Step 2: Write `integrations/github-actions/action.yml`**

```yaml
name: 'Thymus Architectural Lint'
description: 'Check architectural invariants defined in .thymus/invariants.yml'
inputs:
  scan-mode:
    description: 'full (all files) or diff (changed files only)'
    default: 'diff'
  fail-on:
    description: 'Fail the check on: error, warn, or never'
    default: 'error'
runs:
  using: 'composite'
  steps:
    - name: Check thymus exists
      shell: bash
      run: |
        if [ ! -f ".thymus/invariants.yml" ]; then
          echo "::notice::No .thymus/invariants.yml found, skipping"
          exit 0
        fi
        if [ ! -x "bin/thymus" ]; then
          echo "::error::bin/thymus not found or not executable"
          exit 1
        fi
    - name: Run thymus scan
      shell: bash
      run: |
        SCAN_ARGS="--format json"
        if [ "${{ inputs.scan-mode }}" = "diff" ]; then
          SCAN_ARGS="--diff $SCAN_ARGS"
        fi

        set +e
        VIOLATIONS=$(bin/thymus scan $SCAN_ARGS 2>/dev/null)
        SCAN_EXIT=$?
        set -e

        # Exit 2 = config error
        if [ "$SCAN_EXIT" -eq 2 ]; then
          echo "::error::Thymus configuration error"
          exit 1
        fi

        if [ -z "$VIOLATIONS" ] || [ "$VIOLATIONS" = "[]" ]; then
          echo "::notice::Thymus: No architectural violations found"
          exit 0
        fi

        COUNT=$(echo "$VIOLATIONS" | jq 'length')

        if [ "$COUNT" -eq 0 ]; then
          echo "::notice::Thymus: No architectural violations found"
          exit 0
        fi

        # Output as GitHub annotations
        echo "$VIOLATIONS" | jq -r '.[] |
          if .severity == "error" then "::error file=\(.file)" + (if .line then ",line=\(.line)" else "" end) + "::\(.message)"
          else "::warning file=\(.file)" + (if .line then ",line=\(.line)" else "" end) + "::\(.message)"
          end'

        # Determine exit code
        if [ "${{ inputs.fail-on }}" = "never" ]; then
          exit 0
        elif [ "${{ inputs.fail-on }}" = "warn" ]; then
          exit 1
        else
          # Default: fail on errors only
          ERRORS=$(echo "$VIOLATIONS" | jq '[.[] | select(.severity == "error")] | length')
          if [ "$ERRORS" -gt 0 ]; then
            exit 1
          fi
        fi
```

**Step 3: Run tests**

Run: `bash tests/verify-cli.sh`
Expected: All tests pass

**Step 4: Commit**

```bash
git add integrations/github-actions/action.yml tests/verify-cli.sh
git commit -m "feat: add GitHub Actions integration"
```

---

### Task 9: Create VS Code extension

**Files:**
- Create: `integrations/vscode/package.json`
- Create: `integrations/vscode/tsconfig.json`
- Create: `integrations/vscode/src/extension.ts`
- Create: `integrations/vscode/.gitignore`

**Step 1: Create directory structure**

Run: `mkdir -p integrations/vscode/src`

**Step 2: Write `integrations/vscode/package.json`**

```json
{
  "name": "thymus",
  "displayName": "Thymus — Architectural Invariants",
  "description": "Enforces architectural boundary rules defined in .thymus/invariants.yml. Works with any AI coding tool.",
  "version": "0.1.0",
  "publisher": "thymus",
  "engines": { "vscode": "^1.85.0" },
  "categories": ["Linters"],
  "keywords": ["architecture", "boundaries", "linter", "invariants", "cursor", "windsurf"],
  "activationEvents": ["workspaceContains:.thymus/invariants.yml"],
  "main": "./out/extension.js",
  "contributes": {
    "configuration": {
      "title": "Thymus",
      "properties": {
        "thymus.enable": {
          "type": "boolean",
          "default": true,
          "description": "Enable/disable Thymus architectural checking"
        },
        "thymus.binaryPath": {
          "type": "string",
          "default": "",
          "description": "Path to thymus binary (auto-detected from workspace if empty)"
        },
        "thymus.checkOnSave": {
          "type": "boolean",
          "default": true,
          "description": "Run thymus check on file save"
        },
        "thymus.checkOnType": {
          "type": "boolean",
          "default": false,
          "description": "Run thymus check while typing (may impact performance)"
        },
        "thymus.severityMap": {
          "type": "object",
          "default": { "error": "Error", "warn": "Warning", "info": "Information" },
          "description": "Map thymus severity levels to VS Code diagnostic severity"
        }
      }
    },
    "commands": [
      { "command": "thymus.scanWorkspace", "title": "Thymus: Scan Workspace" },
      { "command": "thymus.showHealth", "title": "Thymus: Show Health Report" }
    ]
  },
  "scripts": {
    "compile": "tsc -p ./",
    "watch": "tsc -watch -p ./",
    "package": "vsce package"
  },
  "devDependencies": {
    "@types/vscode": "^1.85.0",
    "typescript": "^5.3.0",
    "@vscode/vsce": "^2.22.0"
  }
}
```

**Step 3: Write `integrations/vscode/tsconfig.json`**

```json
{
  "compilerOptions": {
    "module": "commonjs",
    "target": "ES2022",
    "outDir": "out",
    "sourceMap": true,
    "strict": true,
    "rootDir": "src"
  },
  "include": ["src"]
}
```

**Step 4: Write `integrations/vscode/.gitignore`**

```
out/
node_modules/
*.vsix
```

**Step 5: Write `integrations/vscode/src/extension.ts`**

```typescript
import * as vscode from 'vscode';
import { execFile } from 'child_process';
import { existsSync } from 'fs';
import { join, dirname } from 'path';

interface ThymusViolation {
  file: string;
  line?: number;
  rule_id: string;
  rule_name?: string;
  severity: 'error' | 'warn' | 'info';
  message: string;
  import_path?: string;
}

let diagnosticCollection: vscode.DiagnosticCollection;
let statusBarItem: vscode.StatusBarItem;
let outputChannel: vscode.OutputChannel;
let thymusBinary: string | null = null;
let binaryWarningShown = false;
let debounceTimer: ReturnType<typeof setTimeout> | undefined;
let violationCount = 0;

export function activate(context: vscode.ExtensionContext): void {
  outputChannel = vscode.window.createOutputChannel('Thymus');
  diagnosticCollection = vscode.languages.createDiagnosticCollection('thymus');
  statusBarItem = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left, 100);
  statusBarItem.command = 'thymus.scanWorkspace';

  context.subscriptions.push(diagnosticCollection, statusBarItem, outputChannel);

  thymusBinary = findThymusBinary();
  if (!thymusBinary) {
    if (!binaryWarningShown) {
      vscode.window.showInformationMessage(
        "Thymus binary not found. Run 'thymus init' or set thymus.binaryPath in settings."
      );
      binaryWarningShown = true;
    }
    return;
  }

  updateStatusBar();
  statusBarItem.show();

  // Check on save
  context.subscriptions.push(
    vscode.workspace.onDidSaveTextDocument((doc) => {
      const config = vscode.workspace.getConfiguration('thymus');
      if (config.get<boolean>('enable') && config.get<boolean>('checkOnSave')) {
        checkFile(doc.uri);
      }
    })
  );

  // Check on type (debounced)
  context.subscriptions.push(
    vscode.workspace.onDidChangeTextDocument((event) => {
      const config = vscode.workspace.getConfiguration('thymus');
      if (config.get<boolean>('enable') && config.get<boolean>('checkOnType')) {
        if (debounceTimer) {
          clearTimeout(debounceTimer);
        }
        debounceTimer = setTimeout(() => {
          checkFile(event.document.uri);
        }, 500);
      }
    })
  );

  // Clear diagnostics on close
  context.subscriptions.push(
    vscode.workspace.onDidCloseTextDocument((doc) => {
      diagnosticCollection.delete(doc.uri);
    })
  );

  // Scan workspace command
  context.subscriptions.push(
    vscode.commands.registerCommand('thymus.scanWorkspace', () => {
      scanWorkspace();
    })
  );

  // Show health command
  context.subscriptions.push(
    vscode.commands.registerCommand('thymus.showHealth', () => {
      if (thymusBinary) {
        const workspaceRoot = getWorkspaceRoot();
        if (workspaceRoot) {
          const reportPath = join(workspaceRoot, '.thymus', 'report.html');
          if (existsSync(reportPath)) {
            vscode.env.openExternal(vscode.Uri.file(reportPath));
          } else {
            vscode.window.showInformationMessage('No health report found. Run a scan first.');
          }
        }
      }
    })
  );

  // Re-detect binary on config change
  context.subscriptions.push(
    vscode.workspace.onDidChangeConfiguration((e) => {
      if (e.affectsConfiguration('thymus.binaryPath')) {
        thymusBinary = findThymusBinary();
      }
    })
  );
}

function findThymusBinary(): string | null {
  const config = vscode.workspace.getConfiguration('thymus');
  const configPath = config.get<string>('binaryPath');
  if (configPath && existsSync(configPath)) {
    return configPath;
  }

  // Search from workspace root upward
  let dir = getWorkspaceRoot();
  while (dir && dir !== '/') {
    const candidate = join(dir, 'bin', 'thymus-check');
    if (existsSync(candidate)) {
      return candidate;
    }
    dir = dirname(dir);
  }
  return null;
}

function getWorkspaceRoot(): string | undefined {
  return vscode.workspace.workspaceFolders?.[0]?.uri.fsPath;
}

function checkFile(uri: vscode.Uri): void {
  if (!thymusBinary) { return; }

  const filePath = uri.fsPath;

  // Skip excluded directories
  const excludedDirs = ['.thymus', 'node_modules', '.git', 'dist', 'coverage'];
  if (excludedDirs.some(dir => filePath.includes(`/${dir}/`) || filePath.includes(`\\${dir}\\`))) {
    return;
  }

  const workspaceRoot = getWorkspaceRoot();
  if (!workspaceRoot) { return; }

  const relativePath = filePath.startsWith(workspaceRoot)
    ? filePath.slice(workspaceRoot.length + 1)
    : filePath;

  execFile(thymusBinary, [relativePath, '--format', 'json'], {
    cwd: workspaceRoot,
    timeout: 5000,
  }, (error, stdout, stderr) => {
    if (stderr) {
      outputChannel.appendLine(`[stderr] ${stderr}`);
    }

    // If the process failed and there's no JSON output, clear diagnostics
    if (error && !stdout.trim()) {
      diagnosticCollection.delete(uri);
      return;
    }

    let violations: ThymusViolation[];
    try {
      violations = JSON.parse(stdout || '[]');
    } catch {
      outputChannel.appendLine(`[parse error] ${stdout}`);
      diagnosticCollection.delete(uri);
      return;
    }

    const diagnostics: vscode.Diagnostic[] = violations.map((v) => {
      const line = (v.line && v.line > 0) ? v.line - 1 : 0;
      const range = new vscode.Range(line, 0, line, Number.MAX_SAFE_INTEGER);
      const severity = mapSeverity(v.severity);
      const diagnostic = new vscode.Diagnostic(range, v.message, severity);
      diagnostic.source = `thymus (${v.rule_id})`;
      diagnostic.code = v.rule_id;
      return diagnostic;
    });

    diagnosticCollection.set(uri, diagnostics);

    // Update global count
    violationCount = 0;
    diagnosticCollection.forEach((_, diags) => {
      violationCount += diags.length;
    });
    updateStatusBar();
  });
}

function scanWorkspace(): void {
  if (!thymusBinary) {
    vscode.window.showWarningMessage('Thymus binary not found.');
    return;
  }

  const workspaceRoot = getWorkspaceRoot();
  if (!workspaceRoot) { return; }

  // thymus-check is for single files; for workspace scan, use thymus-scan
  const scanBinary = thymusBinary.replace('thymus-check', 'thymus-scan');

  vscode.window.withProgress({
    location: vscode.ProgressLocation.Notification,
    title: 'Thymus: Scanning workspace...',
    cancellable: false,
  }, () => {
    return new Promise<void>((resolve) => {
      execFile(scanBinary, ['--format', 'json'], {
        cwd: workspaceRoot,
        timeout: 30000,
      }, (error, stdout, stderr) => {
        if (stderr) {
          outputChannel.appendLine(`[scan stderr] ${stderr}`);
        }

        let violations: ThymusViolation[];
        try {
          violations = JSON.parse(stdout || '[]');
        } catch {
          outputChannel.appendLine(`[scan parse error] ${stdout}`);
          resolve();
          return;
        }

        // Clear all existing diagnostics
        diagnosticCollection.clear();

        // Group violations by file
        const byFile = new Map<string, ThymusViolation[]>();
        for (const v of violations) {
          const absPath = join(workspaceRoot, v.file);
          if (!byFile.has(absPath)) {
            byFile.set(absPath, []);
          }
          byFile.get(absPath)!.push(v);
        }

        // Set diagnostics per file
        for (const [absPath, fileViolations] of byFile) {
          const uri = vscode.Uri.file(absPath);
          const diagnostics = fileViolations.map((v) => {
            const line = (v.line && v.line > 0) ? v.line - 1 : 0;
            const range = new vscode.Range(line, 0, line, Number.MAX_SAFE_INTEGER);
            const diagnostic = new vscode.Diagnostic(range, v.message, mapSeverity(v.severity));
            diagnostic.source = `thymus (${v.rule_id})`;
            diagnostic.code = v.rule_id;
            return diagnostic;
          });
          diagnosticCollection.set(uri, diagnostics);
        }

        violationCount = violations.length;
        updateStatusBar();

        vscode.window.showInformationMessage(
          `Thymus: ${violations.length} violation(s) found across ${byFile.size} file(s).`
        );
        resolve();
      });
    });
  });
}

function mapSeverity(severity: string): vscode.DiagnosticSeverity {
  const config = vscode.workspace.getConfiguration('thymus');
  const map = config.get<Record<string, string>>('severityMap') ?? {};
  const mapped = map[severity];

  switch (mapped || severity) {
    case 'Error':
    case 'error':
      return vscode.DiagnosticSeverity.Error;
    case 'Warning':
    case 'warn':
    case 'warning':
      return vscode.DiagnosticSeverity.Warning;
    case 'Information':
    case 'info':
      return vscode.DiagnosticSeverity.Information;
    default:
      return vscode.DiagnosticSeverity.Warning;
  }
}

function updateStatusBar(): void {
  if (violationCount > 0) {
    statusBarItem.text = `$(alert) Thymus ${violationCount}`;
    statusBarItem.tooltip = `${violationCount} architectural violation(s). Click to scan workspace.`;
    statusBarItem.backgroundColor = new vscode.ThemeColor('statusBarItem.warningBackground');
  } else {
    statusBarItem.text = '$(check) Thymus';
    statusBarItem.tooltip = 'No architectural violations. Click to scan workspace.';
    statusBarItem.backgroundColor = undefined;
  }
}

export function deactivate(): void {
  if (debounceTimer) {
    clearTimeout(debounceTimer);
  }
}
```

**Step 6: Install deps and compile**

Run: `cd integrations/vscode && npm install && npm run compile`
Expected: Compiles with zero errors

**Step 7: Commit**

```bash
git add integrations/vscode/
git commit -m "feat: add VS Code extension for architectural linting"
```

---

### Task 10: Update README with installation instructions

**Files:**
- Modify: `README.md`

**Step 1: Update README**

Add the following sections after the existing "Setup" section. Keep the existing Claude Code setup section, and add new sections for other editors/tools.

Insert after the existing Setup section (after the `---` following "That's it. Thymus now checks every file you edit against your rules."):

```markdown
## Cross-Editor Usage

Thymus works everywhere — not just Claude Code.

### CLI (any environment)

```bash
bin/thymus scan              # Scan entire project
bin/thymus scan --diff       # Scan staged files only
bin/thymus check src/file.ts # Check single file
bin/thymus init              # Initialize .thymus/ in a new project
```

### VS Code / Cursor / Windsurf

1. Build the extension: `cd integrations/vscode && npm install && npm run compile`
2. Open a project that has `.thymus/invariants.yml`
3. Violations appear as squiggly underlines on save

### Git Pre-Commit Hook

```bash
# Option A: Symlink (recommended)
ln -sf ../../integrations/pre-commit/thymus-pre-commit .git/hooks/pre-commit

# Option B: pre-commit framework
# Add to .pre-commit-config.yaml:
- repo: local
  hooks:
    - id: thymus
      name: thymus architectural lint
      entry: bin/thymus scan --diff --format text
      language: script
      pass_filenames: false
```

### CI/CD (GitHub Actions)

```yaml
# .github/workflows/thymus.yml
name: Architectural Lint
on: [pull_request]
jobs:
  thymus:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - name: Run Thymus
        uses: ./integrations/github-actions
        with:
          scan-mode: diff
          fail-on: error
```
```

Also update the header tagline to:

```markdown
A Claude Code plugin that watches your codebase for architectural drift and enforces structural invariants — in Claude Code, VS Code, Cursor, Windsurf, CI, and every git commit.
```

**Step 2: Commit**

```bash
git add README.md
git commit -m "docs: add cross-editor installation instructions to README"
```

---

### Task 11: Final verification and schema validation

**Files:**
- Read: `tests/verify-cli.sh`, `tests/verify-phase5.sh`

**Step 1: Run the full CLI test suite**

Run: `bash tests/verify-cli.sh`
Expected: All tests pass, `0 failed`

**Step 2: Run existing test suite (backward compatibility)**

Run: `bash tests/verify-phase5.sh`
Expected: All tests pass, `0 failed`

**Step 3: Validate JSON schema contract**

Run:
```bash
cd tests/fixtures/unhealthy-project && ../../../bin/thymus scan --format json | python3 -c "
import json, sys
violations = json.load(sys.stdin)
assert isinstance(violations, list), 'Expected array'
for v in violations:
    assert 'file' in v, 'Missing file'
    assert 'rule_id' in v, 'Missing rule_id'
    assert 'severity' in v and v['severity'] in ('error', 'warn', 'info'), f'Bad severity: {v.get(\"severity\")}'
    assert 'message' in v, 'Missing message'
print(f'Schema valid: {len(violations)} violations')
"
```
Expected: `Schema valid: 3 violations`

**Step 4: Verify VS Code extension compiles**

Run: `cd integrations/vscode && npm run compile`
Expected: No errors

**Step 5: Performance check**

Run:
```bash
time (cd tests/fixtures/unhealthy-project && ../../../bin/thymus check src/routes/users.ts --format json > /dev/null)
```
Expected: Under 2 seconds

**Step 6: Verify CLI works without Claude Code**

Run:
```bash
TMPDIR_STANDALONE=$(mktemp -d)
# Copy only what the CLI needs (bin/, scripts/, templates/)
cp -r bin "$TMPDIR_STANDALONE/"
cp -r scripts "$TMPDIR_STANDALONE/"
cp -r templates "$TMPDIR_STANDALONE/"
# Init and scan
(cd "$TMPDIR_STANDALONE" && bin/thymus init && bin/thymus scan --format json)
```
Expected: Init succeeds, scan outputs empty array `[]`

**Step 7: No commit** — this is verification only. If anything fails, go back and fix.

---

### Task 12: Final commit with all tests green

**Step 1: Run all tests one more time**

Run:
```bash
bash tests/verify-phase5.sh && bash tests/verify-cli.sh
```
Expected: All pass

**Step 2: Review git log**

Run: `git log --oneline -10`
Expected: Clean commit history with one commit per phase

**Step 3: Done** — invoke `superpowers:finishing-a-development-branch` to decide on merge/PR.
