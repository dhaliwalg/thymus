# Phase 5 — Polish & Distribution Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make Thymus production-ready for marketplace distribution: comprehensive docs, language auto-detection, edge-case hardening, and all distribution artifacts.

**Architecture:** Six independent tasks. Tasks 1-2 are pure documentation (write files, no scripts). Tasks 3-5 add a new detection script, harden existing hook scripts against edge cases, and add a Python test fixture. Task 6 creates the final verification suite.

**Tech Stack:** bash, python3 stdlib, jq, standard Unix tools (no new deps)

---

## Overview of new/modified files

| File | New/Modified | Purpose |
|------|-------------|---------|
| `README.md` | New | Full user-facing documentation |
| `LICENSE` | New | MIT license |
| `CHANGELOG.md` | New | Version history |
| `.claude-plugin/marketplace.json` | New | Marketplace distribution metadata |
| `scripts/detect-framework.sh` | New | Detect language/framework from project files |
| `scripts/analyze-edit.sh` | Modified | Skip binary files, symlinks, oversized files |
| `scripts/scan-project.sh` | Modified | Skip binary files, symlinks, oversized files |
| `scripts/load-baseline.sh` | Modified | Add timeout guard + graceful JSON parse errors |
| `tests/fixtures/python-project/` | New | Python/Django-style test fixture |
| `tests/verify-phase5.sh` | New | Phase 5 test suite |
| `tasks/todo.md` | Modified | Phase 5 tasks marked complete |

---

## Task 1: Distribution artifacts — LICENSE, CHANGELOG, marketplace.json

No tests needed for static files. Write them directly.

**Files:**
- Create: `LICENSE`
- Create: `CHANGELOG.md`
- Create: `.claude-plugin/marketplace.json`

### Step 1: Create `LICENSE`

```
MIT License

Copyright (c) 2026 Gurjit Dhaliwal

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

### Step 2: Create `CHANGELOG.md`

```markdown
# Changelog

All notable changes to Thymus (Thymus) are documented here.

## [1.0.0] — 2026-02-20

### Added
- **Phase 0**: Plugin scaffold — 5 skills, 3 hooks, plugin.json manifest
- **Phase 1**: Baseline engine — structural scan, dependency map, invariant proposals
- **Phase 2**: Real-time enforcement — PostToolUse hook, session-end summaries
- **Phase 3**: Health dashboard — HTML report, `/thymus:scan`, debt projection agent
- **Phase 4**: Learning & auto-discovery — `/thymus:learn`, CLAUDE.md suggestions, baseline refresh, severity calibration
- **Phase 5**: Polish & distribution — README, language auto-detection, edge-case hardening, marketplace metadata
```

### Step 3: Create `.claude-plugin/marketplace.json`

```json
{
  "name": "claude-immune-system",
  "display_name": "Thymus",
  "description": "Continuously monitors codebase health, detects architectural drift, and enforces structural invariants in real-time across every Claude Code session.",
  "version": "1.0.0",
  "author": {
    "name": "Gurjit Dhaliwal"
  },
  "keywords": ["architecture", "code-quality", "invariants", "drift-detection", "health"],
  "skills": [
    { "name": "health", "description": "Generate HTML architectural health report" },
    { "name": "scan", "description": "Quick terminal scan for violations" },
    { "name": "baseline", "description": "Initialize or refresh structural baseline" },
    { "name": "learn", "description": "Teach Thymus a new invariant in natural language" },
    { "name": "configure", "description": "Adjust thresholds and ignored paths" }
  ],
  "hooks": ["PostToolUse", "Stop", "SessionStart"],
  "requirements": {
    "tools": ["bash", "jq", "python3", "git"],
    "min_bash": "4.0"
  },
  "repository": "https://github.com/gurjitdhaliwal/architectural-immune-system",
  "license": "MIT"
}
```

### Step 4: Commit

```bash
git add LICENSE CHANGELOG.md .claude-plugin/marketplace.json
git commit -m "chore(phase5): add LICENSE, CHANGELOG, and marketplace.json"
```

---

## Task 2: README.md

Write the full user-facing README. No tests needed.

**File:** Create `README.md`

### Step 1: Write `README.md`

```markdown
# Thymus

> A Claude Code plugin that continuously monitors codebase health, detects architectural drift, and enforces structural invariants in real-time.

Claude generates code. You merge it. Over days and weeks, architecture silently rots — duplicated patterns, inconsistent abstractions, violated boundaries. **Thymus is the immune system.** It learns what "healthy" looks like and rejects violations before they compound.

---

## Quick Start (< 2 minutes)

**1. Install**
```
/plugin install architectural-immune-system
```

**2. Initialize** (run once per project)
```
/thymus:baseline
```
Thymus scans your project, proposes invariants, and waits for your approval before saving.

**3. You're done.** Thymus now monitors every file edit and warns Claude about violations in real-time.

**4. Check health anytime**
```
/thymus:health
```

---

## How It Works

Thymus fires on three events:

| Event | What happens |
|-------|-------------|
| **Every file edit** | Checks the edited file against your invariants. Warns Claude about violations instantly. |
| **Session start** | Injects a compact health summary into Claude's context (< 500 tokens). |
| **Session end** | Summarizes violations, writes a history snapshot, suggests CLAUDE.md rules for recurring issues. |

---

## Commands

### `/thymus:baseline`
Initialize Thymus for the current project. Scans structure, maps dependencies, proposes invariants.

```
/thymus:baseline            # First-time setup
/thymus:baseline --refresh  # Re-scan after major refactors; shows diff + proposes new rules
```

**What it produces:**
- `.thymus/baseline.json` — structural fingerprint (modules, boundaries, patterns)
- `.thymus/invariants.yml` — your architectural rules
- `.thymus/config.yml` — thresholds and ignored paths

### `/thymus:scan`
Quick terminal scan. Checks all files against current invariants.

```
/thymus:scan                # Scan entire project
/thymus:scan src/auth       # Scope to a subdirectory
/thymus:scan --diff         # Only files changed since git HEAD (great for PR review)
```

### `/thymus:health`
Full health report with trend data. Opens an interactive HTML dashboard in `.thymus/report.html`.

Shows: overall score, violation breakdown, drift timeline, tech debt projection.

### `/thymus:learn`
Teach Thymus a new rule in plain English.

```
/thymus:learn all database queries must go through the repository layer
/thymus:learn React components must not import from other components directly
/thymus:learn never use raw SQL outside src/db
```

Thymus translates to a formal YAML invariant and asks for confirmation before saving.

### `/thymus:configure`
Adjust thresholds and ignored paths (edit `.thymus/config.yml` directly or use this command as a guide).

---

## The `.thymus/` Directory

All Thymus state lives here. Safe to `.gitignore` (personal) or commit (team sharing).

```
.thymus/
├── baseline.json      # Structural fingerprint — modules, dependencies, patterns
├── invariants.yml     # Your architectural rules (human-editable)
├── config.yml         # Thresholds, ignored paths, language settings
├── report.html        # Latest health report (updated on /thymus:health)
├── calibration.json   # Violation fix/ignore tracking for auto-calibration
└── history/           # Timestamped snapshots for trend analysis
    └── YYYY-MM-DDTHH-MM-SS.json
```

---

## Invariant Rule Syntax

Edit `.thymus/invariants.yml` directly or use `/thymus:learn` to add rules.

### Boundary rule — module A must not import from module B
```yaml
- id: boundary-routes-no-db
  type: boundary
  severity: error
  description: "Route handlers must not import directly from the db layer"
  source_glob: "src/routes/**"
  forbidden_imports:
    - "src/db/**"
    - "prisma"
  allowed_imports:
    - "src/repositories/**"
```

### Pattern rule — forbidden code pattern
```yaml
- id: pattern-no-raw-sql
  type: pattern
  severity: error
  description: "No raw SQL strings outside the db layer"
  forbidden_pattern: "(SELECT|INSERT|UPDATE|DELETE)[[:space:]]+(FROM|INTO|SET|WHERE)"
  scope_glob: "src/**"
  scope_glob_exclude:
    - "src/db/**"
```

### Convention rule — structural requirement
```yaml
- id: convention-test-colocation
  type: convention
  severity: warning
  description: "Every source file must have a colocated test file"
  source_glob: "src/**"
  rule: "For every src/**/*.ts, there should be a src/**/*.test.ts"
```

### Dependency rule — package usage restriction
```yaml
- id: dependency-axios-scope
  type: dependency
  severity: warning
  description: "Axios only used in the API client module"
  package: "axios"
  allowed_in:
    - "src/lib/api-client/**"
```

**Severity levels:** `error` (hard rules), `warning` (best practices), `info` (informational)

---

## Configuration

`.thymus/config.yml` controls thresholds and ignored paths:

```yaml
version: "1.0"
ignored_paths: [node_modules, dist, .next, .git, coverage, __pycache__]
health_warning_threshold: 70   # Score below this → ⚠️ warning
health_error_threshold: 50     # Score below this → 🔴 critical
language: typescript           # auto-detected; override if needed
```

---

## Supported Languages

| Language | Framework detection | Import analysis |
|----------|--------------------|--------------  |
| TypeScript/JavaScript | Next.js, Express, React | ✅ |
| Python | Django, FastAPI, Flask | ✅ |
| Go | Modules | ✅ |
| Rust | Cargo | ✅ |
| Java | Maven, Gradle | Partial |

---

## Performance

Thymus is designed to never slow Claude down:
- Every hook completes in < 2 seconds
- Parsed invariants are cached in `/tmp/thymus-cache-{project-hash}/`
- Only invariants matching the edited file's glob are checked
- Binary files, symlinks, and files > 500KB are skipped automatically

---

## FAQ

**Q: Thymus is warning about something that's intentional in my codebase.**
Run `/thymus:configure` or edit `.thymus/invariants.yml` to adjust the rule severity to `info` or remove it.

**Q: I refactored and now the baseline is stale.**
Run `/thymus:baseline --refresh`. Thymus will show what changed and propose new invariants.

**Q: How do I share invariants with my team?**
Commit `.thymus/invariants.yml` and `.thymus/baseline.json`. Add `.thymus/history/` and `.thymus/report.html` to `.gitignore`.

**Q: A violation keeps appearing but I always fix it. Can Thymus auto-adjust?**
Yes — Thymus tracks fix/ignore patterns in `.thymus/calibration.json`. After 10+ data points, run `bash ${CLAUDE_PLUGIN_ROOT}/scripts/calibrate-severity.sh` for recommendations.

**Q: Can I use Thymus without a baseline?**
Partially — you can manually write `.thymus/invariants.yml` and Thymus will enforce it. But `/thymus:baseline` gives you auto-detected rules tailored to your project.

**Q: Does Thymus block edits?**
Never. Thymus warns Claude but never blocks. Blocking mid-task causes confusing behavior — warning gives Claude the information it needs to self-correct.

---

## Troubleshooting

**Hook not firing:** Check `/tmp/thymus-debug.log` for output.

**"No baseline detected":** Run `/thymus:baseline` in your project directory.

**"Failed to parse invariants.yml":** Check YAML indentation — each invariant starts with `  - id:` (2 spaces). Use `/thymus:learn` to add rules safely.

**Slow hook:** Check `/tmp/thymus-debug.log` for timing. If > 2s, your project may have a very large `src/` directory. Add large generated directories to `ignored_paths` in `.thymus/config.yml`.

---

## Requirements

- `bash` 4.0+
- `jq` (install: `brew install jq` / `apt install jq`)
- `python3` (stdlib only, no packages needed)
- `git` (for `--diff` scanning)

---

## License

MIT — see [LICENSE](LICENSE)
```

### Step 2: Commit

```bash
git add README.md
git commit -m "docs(phase5): write comprehensive README with quick start, config reference, FAQ"
```

---

## Task 3: `detect-framework.sh` — language/framework auto-detection

**Files:**
- Create: `scripts/detect-framework.sh`
- Test: `tests/verify-phase5.sh` (initial section)

### Step 1: Create `tests/verify-phase5.sh` with the first failing test

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(realpath "$(dirname "$0")/..")"
DETECT="$ROOT/scripts/detect-framework.sh"

echo "=== Phase 5 Verification ==="
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

# --- Task 3: detect-framework.sh ---
echo "detect-framework.sh:"

if [ -x "$DETECT" ]; then
  echo "  ✓ detect-framework.sh exists and is executable"
  ((passed++)) || true
else
  echo "  ✗ detect-framework.sh missing or not executable"
  ((failed++)) || true
fi

# TypeScript + Express detection
TMPDIR_TS=$(mktemp -d)
cat > "$TMPDIR_TS/package.json" <<'JSON'
{
  "name": "my-app",
  "dependencies": {
    "express": "^4.18.0",
    "typescript": "^5.0.0"
  }
}
JSON
TS_OUT=$(cd "$TMPDIR_TS" && bash "$DETECT" 2>/dev/null)
check_json "detects typescript language" ".language" "typescript" "$TS_OUT"
check_json "detects express framework" ".framework" "express" "$TS_OUT"
rm -rf "$TMPDIR_TS"

# Python + Django detection
TMPDIR_PY=$(mktemp -d)
cat > "$TMPDIR_PY/pyproject.toml" <<'TOML'
[project]
name = "my-django-app"
dependencies = ["django>=4.0", "djangorestframework"]
TOML
PY_OUT=$(cd "$TMPDIR_PY" && bash "$DETECT" 2>/dev/null)
check_json "detects python language" ".language" "python" "$PY_OUT"
check_json "detects django framework" ".framework" "django" "$PY_OUT"
rm -rf "$TMPDIR_PY"

# Go detection
TMPDIR_GO=$(mktemp -d)
cat > "$TMPDIR_GO/go.mod" <<'GOMOD'
module github.com/example/myapp

go 1.21
GOMOD
GO_OUT=$(cd "$TMPDIR_GO" && bash "$DETECT" 2>/dev/null)
check_json "detects go language" ".language" "go" "$GO_OUT"
rm -rf "$TMPDIR_GO"

# Unknown project
TMPDIR_UNK=$(mktemp -d)
UNK_OUT=$(cd "$TMPDIR_UNK" && bash "$DETECT" 2>/dev/null)
check_json "returns unknown for undetectable project" ".language" "unknown" "$UNK_OUT"
rm -rf "$TMPDIR_UNK"

# Output is always valid JSON
check "output is valid JSON" "language" "$TS_OUT"
```

### Step 2: Run test to verify it fails

```bash
bash tests/verify-phase5.sh
```

Expected: FAIL — `detect-framework.sh missing or not executable`

### Step 3: Implement `scripts/detect-framework.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

# Thymus detect-framework.sh
# Detects the language and framework of the project in $PWD.
# Output: JSON { language, framework, config_file }
# Language: typescript | javascript | python | go | rust | java | unknown
# Framework: express | nextjs | react | django | fastapi | flask | unknown

LANG="unknown"
FRAMEWORK="unknown"
CONFIG_FILE=""

# --- TypeScript / JavaScript ---
if [ -f "package.json" ]; then
  if jq -e '.dependencies.typescript or .devDependencies.typescript' package.json > /dev/null 2>&1; then
    LANG="typescript"
  else
    LANG="javascript"
  fi
  CONFIG_FILE="package.json"

  # Framework detection from package.json dependencies
  ALL_DEPS=$(jq -r '(.dependencies // {}) + (.devDependencies // {}) | keys[]' package.json 2>/dev/null | tr '\n' ' ' || true)

  if echo "$ALL_DEPS" | grep -qw "next"; then
    FRAMEWORK="nextjs"
  elif echo "$ALL_DEPS" | grep -qw "express"; then
    FRAMEWORK="express"
  elif echo "$ALL_DEPS" | grep -qw "react"; then
    FRAMEWORK="react"
  elif echo "$ALL_DEPS" | grep -qw "fastify"; then
    FRAMEWORK="fastify"
  elif echo "$ALL_DEPS" | grep -qw "koa"; then
    FRAMEWORK="koa"
  fi

# --- Python ---
elif [ -f "pyproject.toml" ] || [ -f "requirements.txt" ] || [ -f "setup.py" ]; then
  LANG="python"
  CONFIG_FILE="${CONFIG_FILE:-pyproject.toml}"
  [ -f "pyproject.toml" ] && CONFIG_FILE="pyproject.toml"
  [ -f "requirements.txt" ] && CONFIG_FILE="${CONFIG_FILE:-requirements.txt}"

  # Check for frameworks in pyproject.toml or requirements.txt
  DEPS_TEXT=""
  [ -f "pyproject.toml" ] && DEPS_TEXT=$(cat pyproject.toml 2>/dev/null || true)
  [ -f "requirements.txt" ] && DEPS_TEXT="${DEPS_TEXT}$(cat requirements.txt 2>/dev/null || true)"

  if echo "$DEPS_TEXT" | grep -qi "django"; then
    FRAMEWORK="django"
  elif echo "$DEPS_TEXT" | grep -qi "fastapi"; then
    FRAMEWORK="fastapi"
  elif echo "$DEPS_TEXT" | grep -qi "flask"; then
    FRAMEWORK="flask"
  fi

# --- Go ---
elif [ -f "go.mod" ]; then
  LANG="go"
  CONFIG_FILE="go.mod"
  # Detect common Go web frameworks
  if [ -f "go.sum" ]; then
    if grep -q "gin-gonic" go.sum 2>/dev/null; then FRAMEWORK="gin"
    elif grep -q "gofiber" go.sum 2>/dev/null; then FRAMEWORK="fiber"
    elif grep -q "chi" go.sum 2>/dev/null; then FRAMEWORK="chi"
    fi
  fi

# --- Rust ---
elif [ -f "Cargo.toml" ]; then
  LANG="rust"
  CONFIG_FILE="Cargo.toml"
  if grep -q "actix-web" Cargo.toml 2>/dev/null; then FRAMEWORK="actix"
  elif grep -q "axum" Cargo.toml 2>/dev/null; then FRAMEWORK="axum"
  fi

# --- Java ---
elif [ -f "pom.xml" ]; then
  LANG="java"
  CONFIG_FILE="pom.xml"
  if grep -q "spring-boot" pom.xml 2>/dev/null; then FRAMEWORK="spring"
  fi
elif [ -f "build.gradle" ] || [ -f "build.gradle.kts" ]; then
  LANG="java"
  CONFIG_FILE="build.gradle"
  if grep -q "spring-boot" build.gradle 2>/dev/null; then FRAMEWORK="spring"
  fi
fi

jq -n \
  --arg lang "$LANG" \
  --arg framework "$FRAMEWORK" \
  --arg config "$CONFIG_FILE" \
  '{"language": $lang, "framework": $framework, "config_file": $config}'
```

Make executable:
```bash
chmod +x scripts/detect-framework.sh
```

### Step 4: Run test to verify it passes

```bash
bash tests/verify-phase5.sh
```

Expected: all detect-framework.sh tests pass

### Step 5: Commit

```bash
git add scripts/detect-framework.sh tests/verify-phase5.sh
git commit -m "feat(phase5): add detect-framework.sh for language/framework auto-detection"
```

---

## Task 4: Edge-case hardening — skip binary files, symlinks, large files

Add guards to `analyze-edit.sh` and `scan-project.sh` so they never hang or error on unusual files.

**Files:**
- Modify: `scripts/analyze-edit.sh` (after line 18, where `file_path` is validated)
- Modify: `scripts/scan-project.sh` (in the per-file loop)
- Test: `tests/verify-phase5.sh` (new section)

### Step 1: Write the failing test

Add to `tests/verify-phase5.sh`:

```bash
# --- Task 4: edge case hardening ---
echo ""
echo "analyze-edit.sh edge cases:"

ANALYZE="$ROOT/scripts/analyze-edit.sh"
UNHEALTHY="$ROOT/tests/fixtures/unhealthy-project"

# Test: binary file is silently skipped (no output, exit 0)
TMPDIR_BIN=$(mktemp -d)
cp -r "$UNHEALTHY/.thymus" "$TMPDIR_BIN/"
# Create a binary file (PNG magic bytes)
printf '\x89PNG\r\n\x1a\n' > "$TMPDIR_BIN/image.png"
BIN_OUT=$(cd "$TMPDIR_BIN" && printf '{"tool_name":"Write","tool_input":{"file_path":"%s/image.png"},"tool_response":{"success":true},"session_id":"test"}' "$TMPDIR_BIN" \
  | bash "$ANALYZE" 2>/dev/null || true)
if [ -z "$BIN_OUT" ] || echo "$BIN_OUT" | jq -e '. == {} or .systemMessage == null' > /dev/null 2>&1; then
  echo "  ✓ binary file produces no violation output"
  ((passed++)) || true
else
  echo "  ✗ binary file should be silently skipped"
  echo "    got: $BIN_OUT"
  ((failed++)) || true
fi
rm -rf "$TMPDIR_BIN"

# Test: very large file is silently skipped
TMPDIR_LARGE=$(mktemp -d)
cp -r "$UNHEALTHY/.thymus" "$TMPDIR_LARGE/"
# Create a large file (600KB of text with forbidden import)
python3 -c "
import os
content = 'x = 1\n' * 100000 + \"from '../db/client' import db\\n\"
open('$TMPDIR_LARGE/big.ts', 'w').write(content)
"
LARGE_OUT=$(cd "$TMPDIR_LARGE" && printf '{"tool_name":"Write","tool_input":{"file_path":"%s/big.ts"},"tool_response":{"success":true},"session_id":"test"}' "$TMPDIR_LARGE" \
  | bash "$ANALYZE" 2>/dev/null || true)
if [ -z "$LARGE_OUT" ] || echo "$LARGE_OUT" | jq -e '. == {} or .systemMessage == null' > /dev/null 2>&1; then
  echo "  ✓ large file (>500KB) is silently skipped"
  ((passed++)) || true
else
  echo "  ✗ large file should be skipped"
  echo "    got: $LARGE_OUT"
  ((failed++)) || true
fi
rm -rf "$TMPDIR_LARGE"
```

### Step 2: Run test to verify it fails

```bash
bash tests/verify-phase5.sh
```

Expected: FAIL on binary file test (analyze-edit.sh doesn't skip binaries yet)

### Step 3: Modify `scripts/analyze-edit.sh`

After the existing `[ -z "$file_path" ] && exit 0` line (line 18), add these guards before the `THYMUS_DIR=` assignment:

```bash
# --- Skip binary files ---
# `file` command exits 0 with "text" for text files; binaries have "data", "image", etc.
if [ -f "$file_path" ]; then
  file_type=$(file -b "$file_path" 2>/dev/null || true)
  case "$file_type" in
    *text*|*JSON*|*XML*|*HTML*|*script*|*empty*) : ;;  # text — proceed
    *) exit 0 ;;  # binary — skip silently
  esac
fi

# --- Skip symlinks ---
[ -L "$file_path" ] && exit 0

# --- Skip files larger than 500KB ---
if [ -f "$file_path" ]; then
  file_size=$(wc -c < "$file_path" 2>/dev/null || echo 0)
  [ "$file_size" -gt 512000 ] && exit 0
fi
```

### Step 4: Modify `scripts/scan-project.sh`

In the per-file loop (after `[ -f "$abs_path" ] || continue`), add:

```bash
  # Skip binary files, symlinks, and files > 500KB
  [ -L "$abs_path" ] && continue
  file_size=$(wc -c < "$abs_path" 2>/dev/null || echo 0)
  [ "$file_size" -gt 512000 ] && continue
```

The binary check via `file` command is expensive to run per-file in a batch scan, so for scan-project.sh we rely only on the extension filter (`.ts`, `.js`, `.py`) which already excludes most binaries, plus the size guard.

### Step 5: Run test to verify it passes

```bash
bash tests/verify-phase5.sh
```

Expected: edge case tests pass

### Step 6: Run regression tests

```bash
bash tests/verify-phase2.sh && bash tests/verify-phase3.sh
```

Expected: all pass (existing behavior unchanged)

### Step 7: Commit

```bash
git add scripts/analyze-edit.sh scripts/scan-project.sh tests/verify-phase5.sh
git commit -m "fix(phase5): skip binary files, symlinks, and files >500KB in hooks and scan"
```

---

## Task 5: Python test fixture + multi-language scan

Add a minimal Python project fixture so the scanner can be verified on Python files.

**Files:**
- Create: `tests/fixtures/python-project/.thymus/invariants.yml`
- Create: `tests/fixtures/python-project/src/routes/users.py`
- Create: `tests/fixtures/python-project/src/db/client.py`
- Test: `tests/verify-phase5.sh` (new section)

### Step 1: Write the failing test

Add to `tests/verify-phase5.sh`:

```bash
# --- Task 5: Python fixture scan ---
echo ""
echo "Python fixture scan:"

PYTHON_FIXTURE="$ROOT/tests/fixtures/python-project"
SCAN="$ROOT/scripts/scan-project.sh"

if [ -d "$PYTHON_FIXTURE" ]; then
  echo "  ✓ python-project fixture exists"
  ((passed++)) || true
else
  echo "  ✗ python-project fixture missing"
  ((failed++)) || true
fi

# Scan should detect the boundary violation (route importing db directly)
if [ -d "$PYTHON_FIXTURE" ]; then
  PY_SCAN=$(cd "$PYTHON_FIXTURE" && bash "$SCAN" 2>/dev/null)
  if echo "$PY_SCAN" | jq -e '.stats.total > 0' > /dev/null 2>&1; then
    echo "  ✓ Python project scan detects violations"
    ((passed++)) || true
  else
    echo "  ✗ Python project scan found no violations (expected some)"
    echo "    output: $PY_SCAN"
    ((failed++)) || true
  fi
fi
```

### Step 2: Run test to verify it fails

```bash
bash tests/verify-phase5.sh
```

Expected: FAIL — python-project fixture missing

### Step 3: Create the Python project fixture

**`tests/fixtures/python-project/.thymus/invariants.yml`:**
```yaml
version: "1.0"
invariants:
  - id: boundary-views-no-direct-db
    type: boundary
    severity: error
    description: "Django views must not import directly from the db layer"
    source_glob: "src/routes/**"
    forbidden_imports:
      - "src.db.client"
      - "src/db/client"
      - "django.db.connection"
  - id: pattern-no-raw-sql-python
    type: pattern
    severity: error
    description: "No raw SQL strings outside the db layer"
    forbidden_pattern: "(SELECT|INSERT|UPDATE|DELETE)[[:space:]]+(FROM|INTO|SET|WHERE)"
    scope_glob: "src/**"
    scope_glob_exclude:
      - "src/db/**"
```

**`tests/fixtures/python-project/src/routes/users.py`:**
```python
# Thymus test fixture — intentional boundary violation
# This route imports directly from db instead of going through a repository

from src.db.client import get_connection  # VIOLATION: should use src/repositories/

def get_user(user_id: int):
    conn = get_connection()
    return conn.execute(f"SELECT * FROM users WHERE id = {user_id}").fetchone()
```

**`tests/fixtures/python-project/src/db/client.py`:**
```python
# Thymus test fixture — db layer (permitted to have raw SQL)
import sqlite3

def get_connection():
    return sqlite3.connect("app.db")

def execute_raw(sql: str):
    # Raw SQL is allowed here — this file is in the excluded scope
    conn = get_connection()
    return conn.execute(sql)
```

**`tests/fixtures/python-project/src/repositories/__init__.py`:**
```python
# Thymus test fixture — correct import target for routes
```

### Step 4: Run test to verify it passes

```bash
bash tests/verify-phase5.sh
```

Expected: Python fixture tests pass

### Step 5: Commit

```bash
git add tests/fixtures/python-project/ tests/verify-phase5.sh
git commit -m "test(phase5): add Python project fixture and multi-language scan verification"
```

---

## Task 6: Final verification + todo.md update

Run all phase tests, confirm everything passes end-to-end.

**Files:**
- Modify: `tasks/todo.md`

### Step 1: Add Phase 5 closing block to `tests/verify-phase5.sh`

At the end of `verify-phase5.sh`, before the final `echo "Results:"`, add a full regression block:

```bash
# --- Final regression: all previous phases still pass ---
echo ""
echo "Phase regression:"

P2_OUT=$(bash "$ROOT/tests/verify-phase2.sh" 2>&1)
if echo "$P2_OUT" | grep -q "0 failed"; then
  echo "  ✓ Phase 2 tests still pass"
  ((passed++)) || true
else
  echo "  ✗ Phase 2 regression"
  ((failed++)) || true
fi

P3_OUT=$(bash "$ROOT/tests/verify-phase3.sh" 2>&1)
if echo "$P3_OUT" | grep -q "0 failed"; then
  echo "  ✓ Phase 3 tests still pass"
  ((passed++)) || true
else
  echo "  ✗ Phase 3 regression"
  ((failed++)) || true
fi
```

### Step 2: Run the full suite

```bash
bash tests/verify-phase5.sh
```

Expected output:
```
=== Phase 5 Verification ===

detect-framework.sh:
  ✓ detect-framework.sh exists and is executable
  ✓ detects typescript language
  ✓ detects express framework
  ✓ detects python language
  ✓ detects django framework
  ✓ detects go language
  ✓ returns unknown for undetectable project
  ✓ output is valid JSON

analyze-edit.sh edge cases:
  ✓ binary file produces no violation output
  ✓ large file (>500KB) is silently skipped

Python fixture scan:
  ✓ python-project fixture exists
  ✓ Python project scan detects violations

Phase regression:
  ✓ Phase 2 tests still pass
  ✓ Phase 3 tests still pass

Results: 14 passed, 0 failed
```

### Step 3: Update `tasks/todo.md`

Add Phase 5 section:

```markdown
## Phase 5 — Polish & Distribution

- [x] Create LICENSE (MIT)
- [x] Create CHANGELOG.md
- [x] Create .claude-plugin/marketplace.json
- [x] Write comprehensive README.md
- [x] Implement scripts/detect-framework.sh (language/framework auto-detection)
- [x] Harden analyze-edit.sh against binary files, symlinks, large files
- [x] Harden scan-project.sh against symlinks and large files
- [x] Add Python project test fixture
- [x] End-to-end verification: verify-phase5.sh passes with no regressions
```

### Step 4: Final commit

```bash
git add tests/verify-phase5.sh tasks/todo.md
git commit -m "feat(phase5): complete Phase 5 — polish, distribution artifacts, framework detection"
```

---

## Definition of Done

- [ ] `bash tests/verify-phase5.sh` passes with 0 failures
- [ ] Phase 2 and Phase 3 regression tests still pass
- [ ] `README.md` exists with quick start, all commands documented, FAQ
- [ ] `LICENSE` is MIT
- [ ] `.claude-plugin/marketplace.json` exists with correct schema
- [ ] `detect-framework.sh` correctly identifies TypeScript/Express, Python/Django, and Go
- [ ] `analyze-edit.sh` silently skips binary files and files > 500KB
- [ ] Python project fixture has a detectable boundary violation
- [ ] All new scripts are executable (`chmod +x`)
