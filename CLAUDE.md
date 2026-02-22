# Thymus — Codebase Immune System

A Claude Code plugin that enforces architectural invariants on every file edit via hooks. Zero external dependencies beyond bash 4+, jq, python3 (stdlib only), and git.

## Project Structure

```
scripts/          # Core bash scripts — the runtime engine
  lib/                # Shared libraries (sourced by all scripts)
    common.sh           # YAML parser, glob matching, file discovery, imports
    eval-rules.sh       # Rule evaluation loop + test colocation (11 languages)
    utils.py            # Shared Python debug logging
  analyze-edit.sh     # PostToolUse hook: checks single file against invariants
  scan-project.sh     # Full-project batch scanner
  scan-dependencies.sh # Language/framework/import detection
  detect-patterns.sh  # Structural scan (layers, naming, test gaps)
  generate-report.sh  # HTML health report builder
  session-report.sh   # Stop hook: session summary + history snapshot
  load-baseline.sh    # SessionStart hook: injects baseline context
  add-invariant.sh    # Appends validated YAML block to invariants.yml
  refresh-baseline.sh # Diffs current structure against saved baseline
  calibrate-severity.sh # Recommends severity downgrades from fix/ignore data
  build-adjacency.py  # Module adjacency graph builder (shared by graph + infer)
  generate-graph.sh   # Dependency graph HTML generator
  append-history.sh   # Atomic JSONL history append
  infer-rules.sh      # Auto-inference orchestrator
  analyze-graph.py    # Graph analysis / rule inference engine
hooks/hooks.json  # Hook definitions (PostToolUse, Stop, SessionStart)
skills/           # SKILL.md files for each slash command
  graph/              # /thymus:graph slash command
  infer/              # /thymus:infer slash command
agents/           # Agent prompts (invariant-detector, debt-projector)
templates/        # Default rules library by framework
  graph.html          # Interactive graph visualization template
tests/            # Verification scripts + fixture projects
  fixtures/healthy-project/    # Clean project (0 violations expected)
  fixtures/unhealthy-project/  # Intentional violations for testing
  fixtures/python-project/     # Python-specific test fixture
docs/index.html   # Marketing landing page
```

## How It Works

Invariants are defined in `.thymus/invariants.yml` (YAML). The canonical `load_invariants()` function in `scripts/lib/common.sh` converts YAML to cached JSON in `/tmp/thymus-cache-{hash}/`. All scripts source this shared library. Rule evaluation (boundary/pattern/convention/dependency) lives in `scripts/lib/eval-rules.sh`, shared by both the single-file hook (analyze-edit.sh) and batch scanner (scan-project.sh).

Four rule types are enforced at runtime: `boundary`, `pattern`, `convention`, `dependency`. Two types exist in schema only (`structure`, commented out in default-rules.yml).

## Commands

```bash
# Run all tests (phases 2-5)
bash tests/verify-phase5.sh

# Run individual phase tests
bash tests/verify-phase2.sh   # hooks: analyze-edit, session-report, load-baseline
bash tests/verify-phase3.sh   # scan-project, generate-report
bash tests/verify-phase4.sh   # add-invariant, learn skill, calibration, refresh

# Test a specific script against fixtures
cd tests/fixtures/unhealthy-project && bash ../../scripts/scan-project.sh
cd tests/fixtures/healthy-project && bash ../../scripts/scan-project.sh

# Graph, history, score, and inference commands
thymus graph                    # Generate dependency graph HTML
thymus history [--json]         # Show scan history
thymus score                    # Show current compliance score
thymus infer [--min-confidence N] [--apply]  # Infer boundary rules
```

## Development Workflow

1. **Before any change**, run `bash tests/verify-phase5.sh` to establish a passing baseline.
2. Make changes in a single script or skill at a time. Keep diffs small.
3. Run the relevant phase test after each change. Fix regressions before moving on.
4. Run the full `verify-phase5.sh` before considering the change complete.

## Critical Invariants

- **Shared libraries are canonical.** `scripts/lib/common.sh` owns `load_invariants()`, `glob_to_regex()`, `path_matches()`, `file_in_scope()`, `extract_imports()`, `import_is_forbidden()`, `find_source_files()`, and `build_import_entries()`. `scripts/lib/eval-rules.sh` owns `eval_rule_for_file()` and `check_test_colocation()`. All scripts source these — never duplicate them.
- **Hooks must never exit with code 2.** Exit 0 (success) or exit 1 (error) only. Exit 2 blocks Claude Code tool execution.
- **analyze-edit.sh must complete in under 2 seconds.** It runs on every file edit. Performance is tested in verify-phase2.sh.
- **eval-rules.sh must use `jq -cn`** (compact output), not `jq -n`. The calling code reads JSON via `while IFS= read -r` line-by-line — multi-line jq output breaks parsing.
- **invariants.yml indentation is structural:** 2 spaces before `- id:`, 4 spaces for fields, 6 spaces for list items. The Python parser depends on this exact format.
- **`.thymus/` is auto-added to .gitignore** by load-baseline.sh. Don't break this.
- **`build-adjacency.py` is shared** between `generate-graph.sh` (graph visualization) and `infer-rules.sh` (rule inference). Changes to its output format affect both consumers.
- **`.thymus/history.jsonl` replaces the old per-file `.thymus/history/*.json` snapshots.** `append-history.sh` handles atomic writes with FIFO cap at 500 entries. `session-report.sh` and `generate-report.sh` now use JSONL.

## Adding a New Rule Type

1. Add the case branch in `scripts/lib/eval-rules.sh` (`eval_rule_for_file()`). Both analyze-edit.sh and scan-project.sh share this function.
2. Add the type to `agents/invariant-detector.md` so baseline detection can propose rules of that type.
3. Add at least one example rule to `templates/default-rules.yml`.
4. Add a fixture file that triggers the new rule type in `tests/fixtures/unhealthy-project/`.
5. Add a test assertion in the relevant `verify-phase*.sh` script.

## Adding a New Supported Language

1. Update `detect_language()` and `detect_framework()` in `scan-dependencies.sh`.
2. Add language support to `extract-imports.py`.
3. Add test colocation patterns to `check_test_colocation()` in `scripts/lib/eval-rules.sh`.
4. Add a test fixture under `tests/fixtures/` with language-specific invariants.
5. Update the supported languages table in `README.md`.

## Style

- All scripts use `set -euo pipefail`.
- Debug logging goes to `/tmp/thymus-debug.log` with ISO timestamps.
- JSON output uses `jq -n` for construction (or `jq -cn` when output is read line-by-line). Never echo raw JSON strings.
- Python is stdlib-only. No pip dependencies.
- SKILL.md files contain the full instructions for Claude Code slash commands. They are the interface contract — keep them precise.

## Known Limitations

- Import analysis is regex/grep-based, not AST-based. This causes false positives on commented-out imports, string literals containing import-like patterns, and dynamic imports.
- The convention rule type only handles test colocation checks. Other convention patterns require manual `rule` text matching.
- `scope_glob_exclude` is the only way to handle negation — extended glob negation like `!(foo)/**` is not supported.
