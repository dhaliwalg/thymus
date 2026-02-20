# Phase 1 — Baseline Engine Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build the AIS baseline engine — scripts that scan a project's structure and dependencies, an agent that proposes invariants, and a `/ais:baseline` skill that ties it together into a one-shot review flow.

**Architecture:** Two bash scripts produce raw JSON (structure + dependencies). The `invariant-detector` agent synthesizes proposals. The `baseline` skill instructs Claude to run both scripts, invoke the agent, present findings, and write `.ais/` files on user confirmation. No AST parsing — grep/find only.

**Tech Stack:** bash 4+, jq, grep, find. No external dependencies. Test fixtures in `tests/fixtures/`.

---

### Task 1: Create test fixtures

**Files:**
- Create: `tests/fixtures/healthy-project/` (TypeScript Express app with clean layers)
- Create: `tests/fixtures/unhealthy-project/` (same structure but with boundary violations)

**Step 1: Create the healthy project fixture**

```bash
mkdir -p tests/fixtures/healthy-project/src/{routes,controllers,services,repositories,db,models,utils,types}
mkdir -p tests/fixtures/healthy-project/src/routes
mkdir -p tests/fixtures/healthy-project/src/controllers
mkdir -p tests/fixtures/healthy-project/src/services
mkdir -p tests/fixtures/healthy-project/src/repositories
mkdir -p tests/fixtures/healthy-project/src/db
mkdir -p tests/fixtures/healthy-project/src/models
mkdir -p tests/fixtures/healthy-project/src/utils
```

**Step 2: Populate healthy project files**

Create `tests/fixtures/healthy-project/package.json`:
```json
{
  "name": "healthy-project",
  "dependencies": {
    "express": "^4.18.0",
    "prisma": "^5.0.0"
  },
  "devDependencies": {
    "typescript": "^5.0.0",
    "jest": "^29.0.0"
  }
}
```

Create `tests/fixtures/healthy-project/src/routes/users.ts`:
```typescript
import { UserController } from '../controllers/user.controller';
export const userRouter = { controller: new UserController() };
```

Create `tests/fixtures/healthy-project/src/routes/users.test.ts`:
```typescript
import { userRouter } from './users';
test('userRouter exists', () => { expect(userRouter).toBeDefined(); });
```

Create `tests/fixtures/healthy-project/src/controllers/user.controller.ts`:
```typescript
import { UserService } from '../services/user.service';
export class UserController { service = new UserService(); }
```

Create `tests/fixtures/healthy-project/src/controllers/user.controller.test.ts`:
```typescript
import { UserController } from './user.controller';
test('UserController exists', () => { expect(new UserController()).toBeDefined(); });
```

Create `tests/fixtures/healthy-project/src/services/user.service.ts`:
```typescript
import { UserRepository } from '../repositories/user.repo';
export class UserService { repo = new UserRepository(); }
```

Create `tests/fixtures/healthy-project/src/services/user.service.test.ts`:
```typescript
import { UserService } from './user.service';
test('UserService exists', () => { expect(new UserService()).toBeDefined(); });
```

Create `tests/fixtures/healthy-project/src/repositories/user.repo.ts`:
```typescript
import { prisma } from '../db/client';
export class UserRepository { client = prisma; }
```

Create `tests/fixtures/healthy-project/src/db/client.ts`:
```typescript
export const prisma = { user: {} };
```

Create `tests/fixtures/healthy-project/src/models/user.model.ts`:
```typescript
export interface User { id: string; email: string; }
```

Create `tests/fixtures/healthy-project/src/utils/logger.ts`:
```typescript
export const log = (msg: string) => console.log(msg);
```

**Step 3: Create the unhealthy project fixture**

Copy the healthy project, then add a boundary violation (route importing directly from db):

```bash
cp -r tests/fixtures/healthy-project tests/fixtures/unhealthy-project
```

Overwrite `tests/fixtures/unhealthy-project/src/routes/users.ts`:
```typescript
import { prisma } from '../db/client';  // VIOLATION: route accessing db directly
import { UserController } from '../controllers/user.controller';
export const userRouter = { controller: new UserController(), db: prisma };
```

Remove a test file to create a test gap:
```bash
rm tests/fixtures/unhealthy-project/src/models/user.model.ts
```

Create `tests/fixtures/unhealthy-project/src/models/user.model.ts` (no test file — deliberate gap):
```typescript
export interface User { id: string; email: string; name: string; }
```

**Step 4: Verify fixture structure**

```bash
find tests/fixtures/ -type f | sort
```

Expected output: both projects listed with ~10 files each, test files colocated with source (healthy) and one missing test (unhealthy).

**Step 5: Commit**

```bash
git add tests/fixtures/
git commit -m "test: add healthy and unhealthy project fixtures for Phase 1"
```

---

### Task 2: Write `scripts/detect-patterns.sh`

**Files:**
- Create: `scripts/detect-patterns.sh`

This script accepts an optional directory argument and outputs a JSON object with structural data.

**Step 1: Write the test first — define expected output shape**

Create `tests/verify-detect-patterns.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT="$(dirname "$0")/../scripts/detect-patterns.sh"
HEALTHY="$(dirname "$0")/fixtures/healthy-project"

echo "=== Testing detect-patterns.sh ==="

output=$(bash "$SCRIPT" "$HEALTHY")

# Verify it's valid JSON
echo "$output" | jq . > /dev/null || { echo "FAIL: not valid JSON"; exit 1; }

# Verify required fields exist
for field in raw_structure detected_layers naming_patterns test_gaps file_counts; do
  echo "$output" | jq -e ".$field" > /dev/null || { echo "FAIL: missing field $field"; exit 1; }
done

# Verify detected_layers found 'routes', 'controllers', 'services'
for layer in routes controllers services repositories; do
  echo "$output" | jq -e ".detected_layers[] | select(. == \"$layer\")" > /dev/null \
    || { echo "FAIL: expected layer '$layer' not detected"; exit 1; }
done

echo "PASS: detect-patterns.sh output is valid"
```

```bash
chmod +x tests/verify-detect-patterns.sh
bash tests/verify-detect-patterns.sh
```

Expected: FAIL (script doesn't exist yet).

**Step 2: Write `scripts/detect-patterns.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

# AIS detect-patterns.sh
# Scans a project directory and outputs structural data as JSON.
# Usage: bash detect-patterns.sh [project_root]
# Output: JSON to stdout

PROJECT_ROOT="${1:-$PWD}"
DEBUG_LOG="/tmp/ais-debug.log"
TIMESTAMP=$(date '+%Y-%m-%dT%H:%M:%S')

# Load ignored paths from config if available
IGNORED_PATHS=("node_modules" "dist" ".next" ".git" "coverage" "__pycache__" ".venv" "vendor" "target" "build")
IGNORED_FIND_ARGS=()
for p in "${IGNORED_PATHS[@]}"; do
  IGNORED_FIND_ARGS+=(-not -path "*/$p/*" -not -name "$p")
done

echo "[$TIMESTAMP] detect-patterns.sh scanning $PROJECT_ROOT" >> "$DEBUG_LOG"

# --- raw_structure: directory tree depth 3 ---
raw_structure=$(find "$PROJECT_ROOT" -maxdepth 3 -type d \
  "${IGNORED_FIND_ARGS[@]}" \
  | sed "s|$PROJECT_ROOT/||" \
  | grep -v "^$PROJECT_ROOT$" \
  | sort \
  | jq -R . | jq -s .)

# --- detected_layers: dirs matching known layer names ---
KNOWN_LAYERS=("routes" "controllers" "services" "repositories" "models" "middleware" "utils" "lib" "helpers" "types" "handlers" "resolvers" "stores" "hooks" "components" "pages" "app" "api" "db" "database" "config" "auth" "tests" "test" "__tests__")

detected_layers=$(
  for layer in "${KNOWN_LAYERS[@]}"; do
    if find "$PROJECT_ROOT" -maxdepth 4 -type d -name "$layer" \
      "${IGNORED_FIND_ARGS[@]}" | grep -q .; then
      echo "$layer"
    fi
  done | jq -R . | jq -s .
)

# --- naming_patterns: file suffixes/patterns found ---
naming_patterns=$(
  find "$PROJECT_ROOT" -type f -name "*.ts" -o -name "*.js" -o -name "*.py" \
    "${IGNORED_FIND_ARGS[@]}" 2>/dev/null \
  | xargs -I{} basename {} \
  | grep -oE '\.[a-z]+\.[a-z]+$' \
  | sort | uniq -c | sort -rn \
  | awk '{print $2}' \
  | head -20 \
  | jq -R . | jq -s .
)

# --- test_gaps: source files without a colocated test file ---
test_gaps=$(
  find "$PROJECT_ROOT" -type f \( -name "*.ts" -o -name "*.js" -o -name "*.py" \) \
    "${IGNORED_FIND_ARGS[@]}" \
    ! -name "*.test.*" ! -name "*.spec.*" ! -name "*.d.ts" 2>/dev/null \
  | while read -r src_file; do
      base="${src_file%.*}"
      ext="${src_file##*.}"
      if ! ls "${base}.test.${ext}" "${base}.spec.${ext}" 2>/dev/null | grep -q .; then
        echo "$src_file" | sed "s|$PROJECT_ROOT/||"
      fi
    done \
  | jq -R . | jq -s .
)

# --- file_counts: per top-level directory ---
file_counts=$(
  find "$PROJECT_ROOT" -maxdepth 1 -mindepth 1 -type d \
    "${IGNORED_FIND_ARGS[@]}" \
  | while read -r dir; do
      name=$(basename "$dir")
      count=$(find "$dir" -type f "${IGNORED_FIND_ARGS[@]}" 2>/dev/null | wc -l | tr -d ' ')
      printf '{"dir":"%s","count":%s}' "$name" "$count"
    done \
  | jq -s .
)

# --- Output combined JSON ---
jq -n \
  --argjson raw_structure "$raw_structure" \
  --argjson detected_layers "$detected_layers" \
  --argjson naming_patterns "$naming_patterns" \
  --argjson test_gaps "$test_gaps" \
  --argjson file_counts "$file_counts" \
  '{
    raw_structure: $raw_structure,
    detected_layers: $detected_layers,
    naming_patterns: $naming_patterns,
    test_gaps: $test_gaps,
    file_counts: $file_counts
  }'
```

**Step 3: Make executable and run verification**

```bash
chmod +x scripts/detect-patterns.sh
bash tests/verify-detect-patterns.sh
```

Expected: `PASS: detect-patterns.sh output is valid`

**Step 4: Smoke-test on unhealthy fixture**

```bash
bash scripts/detect-patterns.sh tests/fixtures/unhealthy-project | jq '.test_gaps'
```

Expected: array containing `"src/models/user.model.ts"` (the file we left without a test).

**Step 5: Commit**

```bash
git add scripts/detect-patterns.sh tests/verify-detect-patterns.sh
git commit -m "feat: add scripts/detect-patterns.sh with verification test"
```

---

### Task 3: Write `scripts/scan-dependencies.sh`

**Files:**
- Create: `scripts/scan-dependencies.sh`

**Step 1: Write the verification test**

Create `tests/verify-scan-dependencies.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT="$(dirname "$0")/../scripts/scan-dependencies.sh"
HEALTHY="$(dirname "$0")/fixtures/healthy-project"

echo "=== Testing scan-dependencies.sh ==="

output=$(bash "$SCRIPT" "$HEALTHY")

echo "$output" | jq . > /dev/null || { echo "FAIL: not valid JSON"; exit 1; }

for field in language framework external_deps import_frequency cross_module_imports; do
  echo "$output" | jq -e ".$field" > /dev/null || { echo "FAIL: missing field $field"; exit 1; }
done

lang=$(echo "$output" | jq -r '.language')
[ "$lang" = "typescript" ] || { echo "FAIL: expected language=typescript, got $lang"; exit 1; }

framework=$(echo "$output" | jq -r '.framework')
[ "$framework" = "express" ] || { echo "FAIL: expected framework=express, got $framework"; exit 1; }

echo "PASS: scan-dependencies.sh output is valid"
```

```bash
chmod +x tests/verify-scan-dependencies.sh
bash tests/verify-scan-dependencies.sh
```

Expected: FAIL (script doesn't exist yet).

**Step 2: Write `scripts/scan-dependencies.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

# AIS scan-dependencies.sh
# Detects language, framework, external deps, and import relationships.
# Usage: bash scan-dependencies.sh [project_root]
# Output: JSON to stdout

PROJECT_ROOT="${1:-$PWD}"
DEBUG_LOG="/tmp/ais-debug.log"
TIMESTAMP=$(date '+%Y-%m-%dT%H:%M:%S')

IGNORED_PATHS=("node_modules" "dist" ".next" ".git" "coverage" "__pycache__" ".venv" "vendor" "target" "build")
IGNORED_FIND_ARGS=()
for p in "${IGNORED_PATHS[@]}"; do
  IGNORED_FIND_ARGS+=(-not -path "*/$p/*" -not -name "$p")
done

echo "[$TIMESTAMP] scan-dependencies.sh scanning $PROJECT_ROOT" >> "$DEBUG_LOG"

# --- language detection ---
detect_language() {
  if [ -f "$PROJECT_ROOT/package.json" ]; then
    # Check tsconfig or .ts files to distinguish TS from JS
    if [ -f "$PROJECT_ROOT/tsconfig.json" ] || \
       find "$PROJECT_ROOT/src" -name "*.ts" -maxdepth 2 2>/dev/null | grep -q .; then
      echo "typescript"
    else
      echo "javascript"
    fi
  elif [ -f "$PROJECT_ROOT/pyproject.toml" ] || [ -f "$PROJECT_ROOT/setup.py" ] || \
       [ -f "$PROJECT_ROOT/requirements.txt" ]; then
    echo "python"
  elif [ -f "$PROJECT_ROOT/go.mod" ]; then
    echo "go"
  elif [ -f "$PROJECT_ROOT/Cargo.toml" ]; then
    echo "rust"
  elif [ -f "$PROJECT_ROOT/pom.xml" ] || [ -f "$PROJECT_ROOT/build.gradle" ]; then
    echo "java"
  else
    echo "unknown"
  fi
}

# --- framework detection from package.json deps ---
detect_framework() {
  local lang="$1"
  if [ "$lang" = "typescript" ] || [ "$lang" = "javascript" ]; then
    if [ -f "$PROJECT_ROOT/package.json" ]; then
      if jq -e '.dependencies.next // .devDependencies.next' "$PROJECT_ROOT/package.json" > /dev/null 2>&1; then
        echo "nextjs"
      elif jq -e '.dependencies.express // .devDependencies.express' "$PROJECT_ROOT/package.json" > /dev/null 2>&1; then
        echo "express"
      elif jq -e '.dependencies["@nestjs/core"] // .devDependencies["@nestjs/core"]' "$PROJECT_ROOT/package.json" > /dev/null 2>&1; then
        echo "nestjs"
      elif jq -e '.dependencies.fastify // .devDependencies.fastify' "$PROJECT_ROOT/package.json" > /dev/null 2>&1; then
        echo "fastify"
      else
        echo "unknown"
      fi
    fi
  elif [ "$lang" = "python" ]; then
    if grep -q "django" "$PROJECT_ROOT/requirements.txt" 2>/dev/null || \
       grep -q "django" "$PROJECT_ROOT/pyproject.toml" 2>/dev/null; then
      echo "django"
    elif grep -q "fastapi" "$PROJECT_ROOT/requirements.txt" 2>/dev/null || \
         grep -q "fastapi" "$PROJECT_ROOT/pyproject.toml" 2>/dev/null; then
      echo "fastapi"
    else
      echo "unknown"
    fi
  else
    echo "unknown"
  fi
}

# --- external deps from manifest ---
get_external_deps() {
  local lang="$1"
  if [ "$lang" = "typescript" ] || [ "$lang" = "javascript" ]; then
    if [ -f "$PROJECT_ROOT/package.json" ]; then
      jq -r '(.dependencies // {}) + (.devDependencies // {}) | keys[]' \
        "$PROJECT_ROOT/package.json" 2>/dev/null | jq -R . | jq -s .
      return
    fi
  elif [ "$lang" = "python" ]; then
    if [ -f "$PROJECT_ROOT/requirements.txt" ]; then
      grep -v '^#' "$PROJECT_ROOT/requirements.txt" | grep -v '^$' | \
        sed 's/[>=<].*//' | jq -R . | jq -s .
      return
    fi
  elif [ "$lang" = "go" ]; then
    if [ -f "$PROJECT_ROOT/go.mod" ]; then
      grep '^require' -A 100 "$PROJECT_ROOT/go.mod" | \
        grep -oE '[a-z0-9.-]+/[a-z0-9./-]+' | jq -R . | jq -s .
      return
    fi
  fi
  echo "[]"
}

# --- import frequency: top 20 most-imported internal paths ---
get_import_frequency() {
  local lang="$1"
  local pattern=""

  case "$lang" in
    typescript|javascript)
      pattern="from ['\"][./][^'\"]*['\"]"
      ;;
    python)
      pattern="^from \.|^import \."
      ;;
    go)
      pattern="\"[a-z0-9_-]+/"
      ;;
    *)
      echo "[]"
      return
      ;;
  esac

  find "$PROJECT_ROOT" -type f \( -name "*.ts" -o -name "*.js" -o -name "*.py" -o -name "*.go" \) \
    "${IGNORED_FIND_ARGS[@]}" 2>/dev/null \
  | xargs grep -hoE "$pattern" 2>/dev/null \
  | sed "s/from ['\"]//" | sed "s/['\"]$//" \
  | sort | uniq -c | sort -rn \
  | head -20 \
  | awk '{print "{\"path\":\""$2"\",\"count\":"$1"}"}' \
  | jq -s .
}

# --- cross_module_imports: which top-level dirs import from which ---
get_cross_module_imports() {
  local lang="$1"

  # Get top-level source dirs (depth 1 under src/ or project root)
  local src_root="$PROJECT_ROOT/src"
  [ -d "$src_root" ] || src_root="$PROJECT_ROOT"

  find "$src_root" -maxdepth 1 -mindepth 1 -type d \
    "${IGNORED_FIND_ARGS[@]}" \
  | while read -r module_dir; do
      local from_module
      from_module=$(basename "$module_dir")

      find "$module_dir" -type f \( -name "*.ts" -o -name "*.js" -o -name "*.py" -o -name "*.go" \) \
        "${IGNORED_FIND_ARGS[@]}" 2>/dev/null \
      | xargs grep -hoE "from ['\"\`]\.\./[a-z_-]+" 2>/dev/null \
      | grep -oE "\.\./[a-z_-]+" | sed 's|\.\./||' \
      | sort -u \
      | while read -r to_module; do
          echo "{\"from\":\"$from_module\",\"to\":\"$to_module\"}"
        done
    done \
  | jq -s .
}

# --- Assemble output ---
language=$(detect_language)
framework=$(detect_framework "$language")
external_deps=$(get_external_deps "$language")
import_frequency=$(get_import_frequency "$language")
cross_module_imports=$(get_cross_module_imports "$language")

jq -n \
  --arg language "$language" \
  --arg framework "$framework" \
  --argjson external_deps "$external_deps" \
  --argjson import_frequency "$import_frequency" \
  --argjson cross_module_imports "$cross_module_imports" \
  '{
    language: $language,
    framework: $framework,
    external_deps: $external_deps,
    import_frequency: $import_frequency,
    cross_module_imports: $cross_module_imports
  }'
```

**Step 3: Make executable and run verification**

```bash
chmod +x scripts/scan-dependencies.sh
bash tests/verify-scan-dependencies.sh
```

Expected: `PASS: scan-dependencies.sh output is valid`

**Step 4: Smoke-test cross_module_imports on unhealthy fixture**

```bash
bash scripts/scan-dependencies.sh tests/fixtures/unhealthy-project | jq '.cross_module_imports'
```

Expected: array includes `{"from":"routes","to":"db"}` — the boundary violation.

**Step 5: Commit**

```bash
git add scripts/scan-dependencies.sh tests/verify-scan-dependencies.sh
git commit -m "feat: add scripts/scan-dependencies.sh with verification test"
```

---

### Task 4: Write `agents/invariant-detector.md`

**Files:**
- Create: `agents/invariant-detector.md`

**Step 1: Write the agent**

```markdown
You are the AIS Invariant Detector. Your job is to analyze raw scan data from a codebase and propose architectural invariants that should be enforced.

## Your role

Given JSON output from `detect-patterns.sh` and `scan-dependencies.sh`, propose 5–10 high-confidence invariants in YAML format that capture the architectural patterns you observe.

## Inputs

You will receive a JSON object with these fields:
- `structure.detected_layers` — directory names matching known architectural layers
- `structure.naming_patterns` — file suffixes found (e.g. `.service.ts`, `.repo.ts`)
- `structure.test_gaps` — source files without colocated tests
- `dependencies.language` + `.framework` — detected stack
- `dependencies.cross_module_imports` — `{from, to}` pairs showing actual import relationships
- `dependencies.external_deps` — external packages in use

## Output format

Output ONLY valid YAML. No preamble, no explanation, no markdown code fences. Start directly with:

```yaml
invariants:
  - id: ...
```

Each invariant must have:
- `id`: kebab-case identifier
- `type`: one of `boundary`, `convention`, `structure`, `dependency`, `pattern`
- `severity`: `error` | `warning` | `info`
- `description`: one sentence, plain English
- `reasoning`: one sentence explaining what scan data led to this rule
- At least one specificity field: `source_glob`, `forbidden_imports`, `allowed_imports`, `rule`, `forbidden_pattern`, `scope_glob`, `package`, `allowed_in`

## Rules

1. **Propose only high-confidence invariants.** A pattern must appear ≥ 2 times, or be a well-known framework convention, to warrant a rule.
2. **Prefer `boundary` and `convention` types.** These have the lowest false positive rate.
3. **Do NOT propose circular dependency rules.** That's handled in Phase 3.
4. **Do NOT propose rules about external packages unless the package appears in `external_deps`.**
5. **Scale to what you see.** If only 2 layers are detected, propose 2-3 invariants. If 6 layers, propose 8-10.
6. **Framework-aware.** If `framework` is `nextjs`, `express`, `django`, or `fastapi`, include 1-2 framework-specific invariants.

## Example output

```yaml
invariants:
  - id: boundary-routes-no-direct-db
    type: boundary
    severity: error
    description: "Route handlers must not import directly from the db layer"
    reasoning: "cross_module_imports shows routes→db which violates the repository pattern detected in the layer structure"
    source_glob: "src/routes/**"
    forbidden_imports:
      - "src/db/**"
      - "prisma"
    allowed_imports:
      - "src/repositories/**"

  - id: convention-test-colocation
    type: convention
    severity: warning
    description: "Every source file must have a colocated test file"
    reasoning: "test_gaps found files without matching .test.ts counterparts"
    rule: "For every src/**/*.ts (excluding *.test.ts, *.d.ts), there should be a src/**/*.test.ts"
```
```

**Step 2: Verify the agent file is well-formed**

```bash
# Check it exists and has the required sections
grep -c "## Your role\|## Inputs\|## Output format\|## Rules" agents/invariant-detector.md
```

Expected: `4`

**Step 3: Commit**

```bash
git add agents/invariant-detector.md
git commit -m "feat: add agents/invariant-detector.md"
```

---

### Task 5: Write `templates/default-rules.yml`

**Files:**
- Create: `templates/default-rules.yml`

This is a reference library. The `/ais:baseline` skill instructs Claude to consult it when proposing invariants for known frameworks.

**Step 1: Write the template**

```yaml
# AIS Default Rules Library
# Claude references this during /ais:baseline to supplement invariant-detector output.
# Rules are organized by category. Claude selects relevant sections based on detected framework.

version: "1.0"

generic:
  - id: generic-no-circular-deps
    type: structure
    severity: error
    description: "No circular module dependencies"
    note: "Implemented in Phase 3 /ais:scan — placeholder only"

  - id: generic-test-colocation
    type: convention
    severity: warning
    description: "Tests must be colocated with source files"
    rule: "For every src/**/*.ts, there should be a src/**/*.test.ts"

  - id: generic-single-responsibility-dirs
    type: structure
    severity: info
    description: "Each directory should have a single clear responsibility"
    rule: "Directories should not mix concerns (e.g. no routes + services in same dir)"

  - id: generic-no-deep-nesting
    type: structure
    severity: info
    description: "Source files should not be nested more than 4 levels deep"
    rule: "No src file should be at depth > 4 from project root"

nextjs:
  - id: nextjs-no-db-in-pages
    type: boundary
    severity: error
    description: "Next.js pages must not import directly from the database layer"
    source_glob: "pages/**,app/**"
    forbidden_imports: ["prisma", "src/db/**", "mongoose", "sequelize"]
    reasoning: "Database access in pages bypasses the API layer and breaks SSR safety"

  - id: nextjs-api-routes-only-in-pages-api
    type: structure
    severity: warning
    description: "API route handlers belong in pages/api or app/api only"
    rule: "Files matching the Next.js route handler pattern should live under pages/api/** or app/api/**"

  - id: nextjs-no-server-imports-in-client
    type: boundary
    severity: error
    description: "Client components must not import server-only modules"
    source_glob: "**/*.client.ts,**/*.client.tsx"
    forbidden_imports: ["server-only", "fs", "path", "child_process"]

express:
  - id: express-middleware-in-middleware-dir
    type: convention
    severity: warning
    description: "Express middleware must live in the middleware/ directory"
    rule: "Files exporting Express middleware functions should be in src/middleware/**"

  - id: express-routes-no-business-logic
    type: boundary
    severity: warning
    description: "Route handlers should delegate to controllers, not contain business logic"
    source_glob: "src/routes/**"
    forbidden_imports: ["src/db/**", "src/repositories/**"]
    allowed_imports: ["src/controllers/**", "src/middleware/**"]

  - id: express-centralized-error-handler
    type: convention
    severity: info
    description: "Error handling should be centralized, not in individual route handlers"
    rule: "try/catch blocks in route handlers should call next(err), not respond directly"

django:
  - id: django-orm-in-models-only
    type: boundary
    severity: error
    description: "Django ORM queries belong in models or managers, not in views"
    source_glob: "**/views.py,**/views/**"
    forbidden_pattern: "(objects\\.filter|objects\\.get|objects\\.create|objects\\.all)"

  - id: django-business-logic-in-services
    type: convention
    severity: warning
    description: "Business logic should live in service classes, not views"
    rule: "Complex logic in views should be extracted to services/ or managers/"

fastapi:
  - id: fastapi-dependency-injection
    type: convention
    severity: info
    description: "FastAPI route dependencies should use Depends() injection"
    rule: "Routes should accept dependencies via Depends() rather than instantiating them directly"

  - id: fastapi-schemas-in-schemas-module
    type: structure
    severity: warning
    description: "Pydantic request/response schemas should be in a dedicated schemas module"
    rule: "Classes inheriting from BaseModel should live in schemas/ or models/"
```

**Step 2: Verify it parses as valid YAML**

```bash
# Use Python if available, otherwise just check structure manually
python3 -c "import yaml; yaml.safe_load(open('templates/default-rules.yml'))" 2>/dev/null \
  && echo "PASS: valid YAML" \
  || echo "WARN: python3 not available or parse error — review manually"
```

**Step 3: Commit**

```bash
git add templates/default-rules.yml
git commit -m "feat: add templates/default-rules.yml invariant library"
```

---

### Task 6: Update `skills/baseline/SKILL.md` — full implementation

**Files:**
- Modify: `skills/baseline/SKILL.md` (replace stub with full instructions)

**Step 1: Read the current stub**

Read `skills/baseline/SKILL.md` to see what's there (the Phase 0 stub).

**Step 2: Replace with full skill**

```yaml
---
name: baseline
description: >-
  Initialize or refresh the AIS architectural baseline for this project.
  Run this first in any new project to enable architectural monitoring.
  Creates .ais/baseline.json with the structural fingerprint and proposes
  invariants for user review. Use with --refresh to update after major refactors.
disable-model-invocation: true
argument-hint: "[--refresh]"
---

# AIS Baseline

Follow these steps to initialize AIS for the current project.

## Steps

**1. Run structural scan**

Execute:
```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/detect-patterns.sh $PWD
```

Capture the full JSON output. If it fails, check that `jq` is installed (`which jq`).

**2. Run dependency scan**

Execute:
```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/scan-dependencies.sh $PWD
```

Capture the full JSON output.

**3. Propose invariants**

Invoke the `invariant-detector` agent with the combined scan output. Pass both JSON objects merged as a single object:
```json
{
  "structure": <detect-patterns output>,
  "dependencies": <scan-dependencies output>
}
```

The agent will return YAML invariants.

**4. Load default rules**

Read `${CLAUDE_PLUGIN_ROOT}/templates/default-rules.yml` and select rules relevant to the detected framework. Merge with the agent's proposals, deduplicating by `id`.

**5. Present findings**

Present a structured summary to the user:

```
## AIS Baseline Scan Results

**Project:** [language] / [framework]
**Scanned:** [file count] files across [module count] modules

### Detected Modules
[list each detected layer with its path and inferred purpose]

### Naming Conventions
[list detected file suffix patterns]

### Test Coverage Gaps
[list files missing colocated tests, or "None detected"]

### Module Dependency Map
[list cross_module_imports pairs in readable form: "routes → controllers → services → repositories → db"]

### Proposed Invariants ([N] rules)
[list each invariant: id, type, severity, description]

---
Review the above. Tell me what to adjust (e.g. "auth isn't a separate module, it's part of users"), or say **save** to write the baseline.
```

**6. Handle user response**

- If user says **save** (or equivalent): proceed to step 7
- If user requests adjustments: apply them to the in-memory data, re-present the affected section, ask again
- If user says **skip** or **cancel**: abort without writing files

**7. Write `.ais/` files**

Create the `.ais/` directory if it doesn't exist:
```bash
mkdir -p $PWD/.ais/history
```

Write three files:

**`.ais/baseline.json`** — structural fingerprint (JSON from steps 1-3, synthesized):
```json
{
  "version": "1.0",
  "created_at": "[ISO timestamp]",
  "project": { "root": "[PWD]", "language": "[detected]", "framework": "[detected]" },
  "modules": [...],
  "patterns": [...],
  "boundaries": [...],
  "conventions": [...]
}
```

**`.ais/invariants.yml`** — user-facing rules:
```yaml
version: "1.0"
invariants:
  [proposed invariants from step 3-4]
```

**`.ais/config.yml`** — default configuration:
```yaml
version: "1.0"
ignored_paths: [node_modules, dist, .next, .git, coverage]
health_warning_threshold: 70
health_error_threshold: 50
language: [detected]
```

**8. Confirm**

Tell the user:
> ✅ AIS baseline saved to `.ais/`. [N] invariants active. Run `/ais:health` for a full report, or `/ais:scan` to check for current violations.
```

**Step 3: Verify skill name matches directory**

```bash
grep "^name:" skills/baseline/SKILL.md
```

Expected: `name: baseline`

**Step 4: Commit**

```bash
git add skills/baseline/SKILL.md
git commit -m "feat: implement /ais:baseline skill with full scan-and-confirm flow"
```

---

### Task 7: End-to-end verification

**Step 1: Run all verification scripts**

```bash
bash tests/verify-detect-patterns.sh
bash tests/verify-scan-dependencies.sh
```

Both should output `PASS`.

**Step 2: Test detect-patterns on unhealthy fixture — confirm test gap detected**

```bash
bash scripts/detect-patterns.sh tests/fixtures/unhealthy-project \
  | jq '.test_gaps | length'
```

Expected: `1` or more (the model file we left without a test).

**Step 3: Test scan-dependencies on unhealthy fixture — confirm boundary violation visible**

```bash
bash scripts/scan-dependencies.sh tests/fixtures/unhealthy-project \
  | jq '.cross_module_imports[] | select(.from == "routes" and .to == "db")'
```

Expected: `{"from":"routes","to":"db"}`

**Step 4: Time both scripts on a larger project (if available)**

```bash
time bash scripts/detect-patterns.sh ~/path/to/real/project > /dev/null
time bash scripts/scan-dependencies.sh ~/path/to/real/project > /dev/null
```

Expected: both complete in < 5 seconds.

**Step 5: Update `tasks/todo.md`** — mark all Phase 1 items complete.

**Step 6: Final commit**

```bash
git add -A
git commit -m "feat: Phase 1 complete — baseline engine with scan scripts, invariant-detector agent, and /ais:baseline skill"
```

---

## Verification Checklist

- [ ] `bash tests/verify-detect-patterns.sh` → PASS
- [ ] `bash tests/verify-scan-dependencies.sh` → PASS
- [ ] `detect-patterns.sh tests/fixtures/unhealthy-project | jq '.test_gaps'` → non-empty array
- [ ] `scan-dependencies.sh tests/fixtures/unhealthy-project | jq '.cross_module_imports'` → includes `{from:"routes",to:"db"}`
- [ ] `agents/invariant-detector.md` has all 4 required sections
- [ ] `templates/default-rules.yml` covers generic + 4 frameworks
- [ ] `skills/baseline/SKILL.md` has `disable-model-invocation: true` and all 8 steps
- [ ] Both scripts complete in < 5s (on test fixtures)
- [ ] `tasks/todo.md` updated with Phase 1 complete
