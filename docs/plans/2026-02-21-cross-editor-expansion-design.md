# Thymus Cross-Editor Expansion — Design

## Problem

Thymus only works inside Claude Code sessions. Edits from Cursor, Windsurf, Codex, VS Code, Vim, or any other tool bypass enforcement entirely.

## Solution

Add a portable CLI layer (`bin/thymus`) that wraps existing scanning scripts. All downstream integrations (pre-commit, VS Code extension, GitHub Actions) call the CLI, never internal scripts directly.

## Architecture

```
.thymus/invariants.yml (rules — unchanged)
        │
scripts/ (existing engine — unchanged)
        │
bin/ (CLI + jq field translation)
        │
┌───────┼───────┬──────────┐
Pre-    VS Code GitHub     Claude Code
commit  ext     Action     hooks (unchanged)
```

## Key Decisions

1. **Translation in CLI wrappers** — existing scripts stay unchanged. CLI wrappers use `jq` to remap fields (`rule`→`rule_id`, `import`→`import_path`, string `line`→integer `line`).
2. **`--diff` = staged files** — `git diff --cached --name-only` for pre-commit semantics.
3. **`thymus init` auto-detects** — runs `scan-dependencies.sh`, copies matching rules from `templates/default-rules.yml`.
4. **Portable symlink resolution** — POSIX-compatible loop, no `readlink -f`.
5. **Exit codes** — 0 = no violations, 1 = violations found, 2 = config/runtime error.
6. **Format auto-detection** — TTY gets text, pipe gets JSON, `--format` overrides.

## Violation Schema Contract

All integrations consume this JSON format:

```json
[{
  "file": "src/routes/users.ts",
  "line": 3,
  "rule_id": "boundary-routes-no-direct-db",
  "rule_name": "Route handlers must not import directly from the db layer",
  "severity": "error",
  "message": "Route handlers must not import directly from the db layer",
  "source_module": "routes",
  "target_module": "db",
  "import_path": "../db/client"
}]
```

## Execution Order

1. Phase 5: JSON violation schema (`docs/violation-schema.json`)
2. Phase 1: Standalone CLI (`bin/thymus`, `bin/thymus-scan`, `bin/thymus-check`, `bin/thymus-init`)
3. Phase 2: Git pre-commit hook (`integrations/pre-commit/`)
4. Phase 4: GitHub Action (`integrations/github-actions/`)
5. Phase 3: VS Code extension (`integrations/vscode/`)
6. Phase 6: Documentation (README updates)

## What Stays Unchanged

- `hooks/hooks.json`, all `scripts/*.sh`, all `skills/`, all existing tests, `.thymus/` format

## Constraints

- Zero new runtime dependencies (bash, python3 stdlib, jq, git)
- VS Code extension is the only Node component — thin wrapper shelling out to `bin/thymus-check`
- < 2s single-file performance budget
- CLI works without Claude Code installed
