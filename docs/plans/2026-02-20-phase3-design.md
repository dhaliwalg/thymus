# Phase 3 Design — Health Dashboard & Reporting

**Date:** 2026-02-20
**Status:** Approved

---

## Overview

Phase 3 adds the visible output layer to Thymus: a full-project batch scanner, an interactive HTML health report, a debt projection agent, and diff-aware scanning. It also resolves two Phase 2 carryover issues: the `invariants.json` vs `.yml` inconsistency and the broken extglob negation syntax in `scope_glob`.

---

## New Components

### `scripts/scan-project.sh`
Batch invariant checker. Accepts an optional scope path. Iterates all matching files, runs boundary / pattern / convention checks (same logic as `analyze-edit.sh` but written independently for batch mode), outputs structured JSON:

```json
{
  "scope": "src/routes",
  "files_checked": 12,
  "violations": [
    {
      "rule": "boundary-routes-no-direct-db",
      "severity": "error",
      "file": "src/routes/users.ts",
      "line": "3",
      "message": "Route handlers must not import directly from the db layer",
      "import": "../db/client"
    }
  ],
  "stats": {
    "total": 2,
    "errors": 1,
    "warnings": 1,
    "unique_rules_violated": 2
  }
}
```

Uses the shared `load_invariants()` helper (see YAML Migration below) to parse `invariants.yml`.

Supports `--diff` flag: limits file set to `git diff --name-only HEAD` output for PR-review workflows.

### `scripts/generate-report.sh`
Reads scan output (via `--scan path`) and optional projection (via `--projection '{...}'`). Computes health score, reads `.thymus/history/*.json` for trend, generates a single self-contained `.thymus/report.html` (all CSS and JS inline — no external files). Writes a history snapshot. Opens the report in the browser.

**Health score formula:**
```
score = max(0, 100 - unique_error_rule_count×10 - unique_warning_rule_count×3)
```
Deductions are per unique rule ID, not per violation instance. One rule violated across 50 files costs 10 points (error) or 3 points (warning), not 500/150. Violation counts per rule are shown in the report for full visibility.

**HTML report sections:**
1. Score badge with trend arrow (↑ / ↓ / → vs. previous snapshot)
2. Module breakdown table (files checked, error count, warning count per top-level directory)
3. Top violations list (sorted severity-first, then frequency)
4. Drift timeline — inline SVG sparkline computed from history snapshot scores (no external chart libs)
5. Debt projection callout (omitted if no projection data passed)

Opens with: `open "$report" 2>/dev/null || xdg-open "$report" 2>/dev/null || true`

### Updated `skills/health/SKILL.md`
Full Claude-narrated skill (no `disable-model-invocation`). Orchestration:

1. Run `scripts/scan-project.sh` → capture violations JSON to temp file
2. If `.thymus/history/` has ≥2 snapshots: invoke `debt-projector` agent
3. Run `scripts/generate-report.sh --scan <scan_file> [--projection '<json>']`
4. Narrate: score, module breakdown, top violations, trend, projection

### Updated `skills/scan/SKILL.md`
Keeps `disable-model-invocation: true`. Calls `scripts/scan-project.sh "$ARGUMENTS"`, outputs a human-readable violation table.

### `agents/debt-projector.md`
Analyzes `.thymus/history/*.json` snapshots. Input: list of snapshot paths. Output:

```json
{
  "velocity": -1.4,
  "projection_30d": 4,
  "trend": "degrading",
  "hotspots": ["src/routes", "src/controllers"],
  "recommendation": "boundary-routes-no-direct-db accounts for 60% of new violations"
}
```

`velocity` = average change in violation count per day across snapshots. `projection_30d` = projected new violations in 30 days at current velocity. Invoked by Claude as a subagent inside `/thymus:health`.

---

## Phase 2 Carryover Fixes

### 1. YAML Migration (`invariants.json` → `invariants.yml`)

All invariant storage moves to `.yml` format, consistent with the spec. A `load_invariants()` bash function (inlined in each script that needs it) converts `invariants.yml` to a temp JSON file once per script run using an awk state-machine parser, then caches by mtime. `jq` operates on the JSON cache.

Files changed:
- `scripts/analyze-edit.sh` — switch from `invariants.json` to `load_invariants()` + `invariants.yml`
- `scripts/load-baseline.sh` — same
- `tests/fixtures/unhealthy-project/.thymus/invariants.json` → `invariants.yml`
- `tests/fixtures/healthy-project/.thymus/invariants.json` → `invariants.yml` (if exists)
- All test verification scripts updated to reference `.yml`

No `.json` fallback — clean cut.

### 2. `scope_glob_exclude` (replaces extglob negation)

The `src/!(db)/**` extglob pattern used in the test fixture and ROADMAP examples is replaced with a `scope_glob_exclude` blocklist field:

```yaml
- id: pattern-no-raw-sql
  type: pattern
  severity: error
  description: "No raw SQL strings outside the db layer"
  forbidden_pattern: "(SELECT|INSERT|UPDATE|DELETE)[[:space:]]+(FROM|INTO|SET|WHERE)"
  scope_glob: "src/**"
  scope_glob_exclude:
    - "src/db/**"
    - "src/migrations/**"
```

A file is checked when it: matches `scope_glob` AND does NOT match any `scope_glob_exclude` entry.

Updated in:
- `CLAUDE.md` — canonical invariant schema
- `ROADMAP.md` — Phase 2 schema example
- Test fixtures (replace `src/!(db)/**` with `scope_glob` + `scope_glob_exclude`)
- `scripts/analyze-edit.sh` — implement the exclusion check
- `scripts/scan-project.sh` — implemented from the start

---

## Execution Flow

### `/thymus:scan [scope]`
```
bash scripts/scan-project.sh [scope]
  → JSON output
  → Claude formats terminal violation table
```

### `/thymus:health`
```
bash scripts/scan-project.sh → /tmp/thymus-scan-$HASH.json
  (if ≥2 history snapshots)
  → invoke debt-projector agent → projection JSON
bash scripts/generate-report.sh --scan /tmp/thymus-scan-$HASH.json [--projection '...']
  → writes .thymus/report.html
  → writes .thymus/history/<timestamp>.json
  → opens browser
Claude narrates: score, modules, top violations, trend, projection
```

### Diff-aware (PR review mode)
```
bash scripts/scan-project.sh --diff
  → git diff --name-only HEAD → file list
  → scan only those files
  → output: only NEW violations not in last history snapshot
```

---

## Definition of Done

- `/thymus:health` narrates a health summary and opens `report.html` in the browser
- `report.html` includes score, module table, SVG trend chart, debt projection callout (when available)
- `/thymus:scan src/module` scopes correctly and outputs a violation table
- `debt-projector` produces actionable velocity + projection when ≥2 history snapshots exist
- All invariants read from `invariants.yml` (no `.json` variant anywhere)
- `scope_glob_exclude` works correctly in both `analyze-edit.sh` and `scan-project.sh`
- CLAUDE.md and ROADMAP.md schema examples updated
- All existing Phase 1 + Phase 2 verification tests still pass
- New verification tests added for Phase 3 scripts

---

## Files Touched

| File | Action |
|------|--------|
| `scripts/scan-project.sh` | Create |
| `scripts/generate-report.sh` | Create |
| `skills/health/SKILL.md` | Replace (full implementation) |
| `skills/scan/SKILL.md` | Replace (full implementation) |
| `agents/debt-projector.md` | Create |
| `scripts/analyze-edit.sh` | Update (YAML + scope_glob_exclude) |
| `scripts/load-baseline.sh` | Update (YAML) |
| `tests/fixtures/*/invariants.json` | Replace with `.yml` |
| `tests/verify-phase3.sh` | Create |
| `CLAUDE.md` | Update schema examples |
| `ROADMAP.md` | Update schema examples |
| `tasks/todo.md` | Update with Phase 3 tasks |
