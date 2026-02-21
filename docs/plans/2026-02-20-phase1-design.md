# Phase 1 Design — Baseline Engine

**Date:** 2026-02-20
**Phase:** 1 of 5
**Goal:** Thymus can scan a codebase and produce a structural baseline — the "healthy" fingerprint stored in `.thymus/`.

---

## Data Schema

### `.thymus/baseline.json`
Structural fingerprint written on confirmation. Never edited directly by users.

```json
{
  "version": "1.0",
  "created_at": "2026-02-20T12:00:00Z",
  "project": {
    "root": "/path/to/project",
    "language": "typescript",
    "framework": "nextjs"
  },
  "modules": [
    {
      "name": "auth",
      "path": "src/auth",
      "purpose": "Authentication and session management",
      "allowed_dependencies": ["users", "db"]
    }
  ],
  "patterns": [
    {
      "name": "repository-pattern",
      "description": "Database access abstracted behind repository classes",
      "file_glob": "src/repositories/**",
      "expected_suffix": ".repo.ts"
    }
  ],
  "boundaries": [
    { "source_module": "routes", "target_module": "db", "allowed": false }
  ],
  "conventions": [
    {
      "name": "test-colocation",
      "rule": "Every src/**/*.ts should have a colocated src/**/*.test.ts",
      "severity": "warning"
    }
  ]
}
```

### `.thymus/invariants.yml`
User-editable rules file. Separate from `baseline.json` so users can tune without re-baselining. Written on first baseline, updated by `/thymus:learn`.

```yaml
version: "1.0"
invariants:
  - id: boundary-db-access
    type: boundary
    severity: error
    description: "Database access only through repository layer"
    source_glob: "src/routes/**"
    forbidden_imports:
      - "src/db/**"
      - "prisma"
    allowed_imports:
      - "src/repositories/**"
```

Invariant types: `boundary`, `convention`, `structure`, `dependency`, `pattern`.

### `.thymus/config.yml`
Thresholds and ignored paths. Sane defaults; user adjusts via `/thymus:configure`.

```yaml
version: "1.0"
ignored_paths:
  - node_modules
  - dist
  - .next
  - .git
  - coverage
health_warning_threshold: 70
health_error_threshold: 50
language: auto
```

---

## Scripts

### `scripts/detect-patterns.sh`
Produces raw structural data via `find` and `grep`. No AST parsing.

**Output JSON fields:**
- `raw_structure` — directory tree to depth 3 (excluding ignored paths)
- `detected_layers` — directories matching known layer names: `routes`, `controllers`, `services`, `repositories`, `models`, `middleware`, `utils`, `lib`, `helpers`, `types`
- `naming_patterns` — file suffixes found (e.g. `.service.ts`, `.repo.ts`, `.controller.ts`)
- `test_gaps` — source files with no matching `.test.` counterpart
- `file_counts` — per-directory file counts and language breakdown

Accepts optional `$1` scope path, defaults to `$PWD`.

### `scripts/scan-dependencies.sh`
Produces dependency and import data.

**Output JSON fields:**
- `language` — detected from manifest files (package.json → ts/js, pyproject.toml → python, go.mod → go, Cargo.toml → rust, pom.xml → java)
- `framework` — detected from deps in manifest (next → nextjs, express → express, django → django, etc.)
- `external_deps` — list of external package names from manifest
- `import_frequency` — top 20 most-imported internal paths (grep-based)
- `cross_module_imports` — raw list of `{from, to}` pairs showing which directories import from which; no cycle detection (deferred to Phase 3 `/thymus:scan`)

Both scripts complete in < 5s for a 50K LOC codebase.

---

## `/thymus:baseline` Skill Flow

**`disable-model-invocation: true`** — prevents Claude from auto-triggering on mentions of "architecture". User must explicitly type `/thymus:baseline`. Claude reads SKILL.md and follows instructions within the existing session.

Steps Claude follows when invoked:

1. Run `${CLAUDE_PLUGIN_ROOT}/scripts/detect-patterns.sh` → capture JSON
2. Run `${CLAUDE_PLUGIN_ROOT}/scripts/scan-dependencies.sh` → capture JSON
3. Dispatch `invariant-detector` agent with combined scan output → receive proposed invariants YAML
4. Present all findings in one structured summary:
   - Detected language + framework
   - Modules (inferred from directory structure + import patterns)
   - Identified naming conventions + patterns
   - Module boundaries inferred from `cross_module_imports`
   - ≥ 5 proposed invariants with reasoning
5. End with: *"Review above. Tell me what to adjust, or say 'save' to write the baseline."*
6. On confirmation: write `baseline.json`, `invariants.yml`, `config.yml` to `.thymus/`

The conversation IS the review loop — no state machine needed. User replies in natural language, Claude adjusts and re-presents.

---

## `agents/invariant-detector.md`

Subagent invoked during `/thymus:baseline`. Receives raw scan JSON. Outputs 5–10 proposed invariants in YAML, ranked by confidence. Rules:
- Propose only high-confidence invariants (patterns seen ≥ 3 times or explicit layer structure detected)
- Include `reasoning` field explaining why each invariant was proposed
- Prefer `boundary` and `convention` types for first baseline (most impactful, lowest false positive rate)
- Do NOT propose circular dependency rules (Phase 3)

---

## `templates/default-rules.yml`

Pre-written invariant library Claude references when proposing invariants. Sections:

- **Generic**: no-circular-deps (placeholder for Phase 3), test-colocation, single-responsibility-dirs
- **Next.js**: app/pages router conventions, no direct DB in pages or components
- **Express**: middleware chain order, centralized error handling
- **Django**: ORM only in models, view logic separation
- **FastAPI**: router patterns, dependency injection via `Depends`

Framework auto-detected from `scan-dependencies.sh` output. Claude includes the relevant section in the invariants proposal.

---

## Definition of Done

- `/thymus:baseline` produces a valid `baseline.json` for a real TypeScript project
- `invariant-detector` proposes ≥ 5 meaningful invariants
- Baseline captures modules, patterns, boundaries, conventions
- Both scripts complete in < 5s (tested on a 50K LOC project)
- `.thymus/` is portable — safe to commit or gitignore
- No circular dep detection in Phase 1 (deferred to Phase 3)
