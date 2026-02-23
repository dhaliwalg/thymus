# Thymus — Codebase Immune System

A Claude Code plugin that enforces architectural invariants on every file edit via hooks. Zero external dependencies beyond python3 (stdlib only) and git. Bash scripts exist as thin wrappers delegating to Python implementations.

## Project Structure

```
scripts/          # Core scripts — Python implementations with bash wrappers
  lib/                # Shared Python libraries (imported by all scripts)
    core.py             # YAML parser, glob matching, file discovery, imports
    rules.py            # Rule evaluation engine + test colocation (11 languages)
    common.sh           # Legacy bash library (kept for add-invariant.sh, infer-rules.sh)
    eval-rules.sh       # Legacy bash rule evaluation (kept for add-invariant.sh)
    utils.py            # Shared Python debug logging
  analyze-edit.py     # PostToolUse hook: checks single file against invariants
  scan-project.py     # Full-project batch scanner
  scan-dependencies.py # Language/framework/import detection
  detect-patterns.py  # Structural scan (layers, naming, test gaps)
  generate-report.py  # HTML health report builder
  session-report.py   # Stop hook: session summary + history snapshot
  load-baseline.py    # SessionStart hook: injects baseline context
  append-history.py   # Atomic JSONL history append (importable)
  generate-graph.py   # Dependency graph HTML generator
  add-invariant.sh    # Appends validated YAML block to invariants.yml
  refresh-baseline.sh # Diffs current structure against saved baseline
  calibrate-severity.sh # Recommends severity downgrades from fix/ignore data
  build-adjacency.py  # Module adjacency graph builder (shared by graph + infer)
  infer-rules.sh      # Auto-inference orchestrator
  analyze-graph.py    # Graph analysis / rule inference engine
  *.sh                # Bash wrappers (exec python3 ... "$@") for backward compat
hooks/hooks.json  # Hook definitions (PostToolUse, Stop, SessionStart) — calls python3 directly
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

Invariants are defined in `.thymus/invariants.yml` (YAML). The canonical `load_invariants()` function in `scripts/lib/core.py` converts YAML to cached JSON in `/tmp/thymus-cache-{hash}/`. All Python scripts import from this shared library. Rule evaluation (boundary/pattern/convention/dependency) lives in `scripts/lib/rules.py`, shared by both the single-file hook (analyze-edit.py) and batch scanner (scan-project.py).

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

- **Shared Python libraries are canonical.** `scripts/lib/core.py` owns `load_invariants()`, `glob_to_regex()`, `path_matches()`, `file_in_scope()`, `extract_imports_for_file()`, `import_is_forbidden()`, `find_source_files()`, and `build_import_entries()`. `scripts/lib/rules.py` owns `eval_rule_for_file()` and `check_test_colocation()`. All Python scripts import from these — never duplicate them.
- **Legacy bash libraries remain** (`scripts/lib/common.sh`, `scripts/lib/eval-rules.sh`) for scripts not yet rewritten (`add-invariant.sh`, `infer-rules.sh`).
- **Hooks must never exit with code 2.** Exit 0 (success) or exit 1 (error) only. Exit 2 blocks Claude Code tool execution. Python scripts wrap `main()` in try/except to enforce this.
- **analyze-edit.py must complete in under 2 seconds.** It runs on every file edit. Performance is tested in verify-phase2.sh. The Python implementation typically completes in ~25ms.
- **invariants.yml indentation is structural:** 2 spaces before `- id:`, 4 spaces for fields, 6 spaces for list items. The Python parser depends on this exact format.
- **`.thymus/` is auto-added to .gitignore** by load-baseline.py. Don't break this.
- **`build-adjacency.py` is used by `infer-rules.sh`** (rule inference). `generate-graph.py` absorbed this logic in-process. Changes to `build-adjacency.py` output format affect `infer-rules.sh`.
- **`.thymus/history.jsonl` replaces the old per-file `.thymus/history/*.json` snapshots.** `append-history.py` handles atomic writes with FIFO cap at 500 entries and exposes importable functions for in-process use by `session-report.py` and `generate-report.py`.
- **Python is stdlib-only.** No pip dependencies. All scripts use only the Python 3 standard library.
- **Bash wrappers maintain backward compatibility.** Each `.sh` file delegates to its `.py` counterpart via `exec python3`. Tests, skills, and external callers continue to work unchanged.

## Adding a New Rule Type

1. Add the case branch in `scripts/lib/rules.py` (`eval_rule_for_file()`). Both analyze-edit.py and scan-project.py share this function.
2. Add the type to `agents/invariant-detector.md` so baseline detection can propose rules of that type.
3. Add at least one example rule to `templates/default-rules.yml`.
4. Add a fixture file that triggers the new rule type in `tests/fixtures/unhealthy-project/`.
5. Add a test assertion in the relevant `verify-phase*.sh` script.

## Adding a New Supported Language

1. Update `detect_language()` and `detect_framework()` in `scripts/scan-dependencies.py`.
2. Add language support to `extract-imports.py`.
3. Add test colocation patterns to `check_test_colocation()` in `scripts/lib/rules.py`.
4. Add a test fixture under `tests/fixtures/` with language-specific invariants.
5. Update the supported languages table in `README.md`.

## Style

- Bash wrappers use `set -euo pipefail` and delegate to Python via `exec python3`.
- Debug logging goes to `/tmp/thymus-debug.log` with ISO timestamps.
- JSON output uses `json.dump()` with `separators=(",", ":")` for compact output.
- Python is stdlib-only. No pip dependencies.
- SKILL.md files contain the full instructions for Claude Code slash commands. They are the interface contract — keep them precise.

## Known Limitations

- Import analysis is regex/grep-based, not AST-based. This causes false positives on commented-out imports, string literals containing import-like patterns, and dynamic imports.
- The convention rule type only handles test colocation checks. Other convention patterns require manual `rule` text matching.
- `scope_glob_exclude` is the only way to handle negation — extended glob negation like `!(foo)/**` is not supported.
