# ROADMAP — Thymus

> A Claude Code plugin that continuously models your codebase's architectural invariants and enforces them in real-time across every session.

---

## v1.0 Release (2026-02-21)

Thymus v1.0 ships with:
- **3 hooks**: PostToolUse (`analyze-edit.sh`), Stop (`session-report.sh`), SessionStart (`load-baseline.sh`)
- **5 skills**: `/thymus:health`, `/thymus:scan`, `/thymus:baseline`, `/thymus:learn`, `/thymus:configure`
- **2 agents**: `invariant-detector`, `debt-projector`
- **4 enforced invariant types**: `boundary`, `pattern`, `convention`, `dependency`
- Health score formula, HTML report with SVG sparkline, debt projections
- Severity auto-calibration, pattern auto-discovery, diff-aware scanning
- Language/framework auto-detection (TypeScript, Python, Go, Rust, Java)
- Per-phase verification test suite

All five development phases (0-5) are complete.

---

## Vision

Claude Code generates code. You merge it. Over days and weeks, architecture silently rots — duplicated patterns, inconsistent abstractions, dependency bloat, violated boundaries. 41% of AI-generated code gets revised within 2 weeks. **Nothing watches the codebase between sessions.**

Thymus is the immune system. It learns what "healthy" looks like, detects foreign patterns, and rejects architectural violations before they compound into technical debt.

---

## Plugin Architecture Overview

```
thymus/
├── .claude-plugin/
│   └── plugin.json                  # Plugin manifest (name, version, author)
├── skills/
│   ├── health/SKILL.md              # /thymus:health — Generate health report
│   ├── learn/SKILL.md               # /thymus:learn — Teach Thymus a new invariant
│   ├── scan/SKILL.md                # /thymus:scan — Full codebase scan
│   ├── baseline/SKILL.md            # /thymus:baseline — Initialize/reset baseline
│   └── configure/SKILL.md           # /thymus:configure — Edit rules & thresholds
├── agents/
│   ├── invariant-detector.md        # Discovers implicit patterns in codebase
│   └── debt-projector.md            # Projects tech debt trajectory from trends
├── hooks/
│   └── hooks.json                   # PostToolUse + Stop + SessionStart hooks
├── scripts/
│   ├── analyze-edit.sh              # PostToolUse: analyze each file edit
│   ├── session-report.sh            # Stop: summarize violations found this session
│   ├── load-baseline.sh             # SessionStart: inject baseline context
│   ├── scan-dependencies.sh         # Dependency graph analysis
│   ├── detect-patterns.sh           # AST-lite pattern detection
│   └── generate-report.sh           # HTML health report generator
├── templates/
│   └── default-rules.yml            # Sensible defaults per language/framework
├── README.md
└── LICENSE
```

---

## Phase 0 — Foundation & Scaffolding ✓

**Goal:** Working plugin skeleton that installs, loads, and responds to basic commands.

### Tasks

- [x] Create plugin directory structure matching the tree above
- [x] Write `.claude-plugin/plugin.json` manifest with correct schema
- [x] Create minimal `skills/health/SKILL.md` that returns "Thymus not yet initialized"
- [x] Create `hooks/hooks.json` with stubbed PostToolUse, Stop, and SessionStart hooks
- [x] Write `scripts/load-baseline.sh` that checks for `.thymus/` directory in project root
- [x] Verify plugin loads with `claude --plugin-dir ./architectural-immune-system`
- [x] Verify `/thymus:health` appears in skill list and is invocable
- [x] Verify hooks fire on Edit/Write events (log to `/tmp/thymus-debug.log`)

### Definition of Done
- Plugin installs without errors
- All 5 skills appear in `/` menu
- Hooks fire and produce log output
- No context bloat (verify with `/context` — should add < 2K tokens)

### Estimated Complexity: Simple

---

## Phase 1 — Baseline Engine ✓

**Goal:** Thymus can scan a codebase and produce a structural baseline — the "healthy" fingerprint.

### Tasks

- [x] Design the `.thymus/` directory structure:
  ```
  .thymus/
  ├── baseline.json        # Structural fingerprint
  ├── invariants.yml       # User-defined + auto-discovered rules
  ├── history/             # Historical health snapshots
  │   └── YYYY-MM-DD.json
  └── config.yml           # Thresholds, ignored paths, language settings
  ```
- [x] Implement `/thymus:baseline` skill:
  - Scans project structure (directories, file types, module boundaries)
  - Maps dependency graph (imports/requires/use statements)
  - Identifies repeating patterns (where auth lives, where DB access happens, test locations)
  - Detects layering (routes → controllers → services → repositories → models)
  - Generates `baseline.json` with:
    - `modules[]` — name, path, purpose, allowed_dependencies
    - `patterns[]` — name, description, file_glob, expected_structure
    - `boundaries[]` — source_module, target_module, allowed (bool)
    - `conventions[]` — name, rule, severity
  - Presents findings to user for review/adjustment before saving
- [x] Implement `scripts/detect-patterns.sh`:
  - Uses `grep`, `find`, `jq`, and language-aware heuristics
  - Supports: TypeScript/JavaScript, Python, Go, Rust, Java (extensible)
  - Extracts import graphs, directory structure, naming conventions
  - Outputs structured JSON
- [x] Implement `scripts/scan-dependencies.sh`:
  - Parses `package.json`, `pyproject.toml`, `go.mod`, `Cargo.toml`, `pom.xml`
  - Maps internal module dependencies via import statements
  - Detects circular dependencies
  - Outputs adjacency list in JSON
- [x] Write `invariant-detector` agent:
  - System prompt instructs it to analyze the baseline and propose invariants
  - Runs as a subagent with `context: fork`
  - Returns structured YAML invariants for user approval
- [x] Implement default rule templates in `templates/default-rules.yml`:
  - Generic rules: no circular deps, single responsibility directories, test co-location
  - Framework-specific: Next.js (app router conventions), Express (middleware chains), Django (app structure), FastAPI (router patterns)
- [x] Create `invariants.yml` schema with types:
  - `boundary` — Module A must not import from Module B
  - `convention` — Files matching glob must follow naming pattern
  - `structure` — Directory must contain specific file types
  - `dependency` — External dep X only used in module Y
  - `pattern` — This code pattern must/must-not exist in this scope

### Definition of Done
- `/thymus:baseline` produces a valid `baseline.json` for a real project
- Invariant detector proposes ≥ 5 meaningful invariants for a Next.js project
- Baseline captures modules, dependencies, patterns, conventions
- `.thymus/` directory is `.gitignore`-safe (user chooses to commit or not)
- Process completes in < 60 seconds for a 50K LOC codebase

### Estimated Complexity: Ambitious

---

## Phase 2 — Real-Time Enforcement (The Immune Response) ✓

**Goal:** Every file edit triggers a violation check. Claude gets immediate feedback on architectural drift.

### Tasks

- [x] Implement `scripts/analyze-edit.sh` (PostToolUse hook):
  - Receives tool input JSON via stdin (file_path from Edit/Write)
  - Loads `baseline.json` and `invariants.yml` from `.thymus/`
  - Checks the edited file against relevant invariants:
    - New import added? Check boundary rules
    - New file created? Check convention/structure rules
    - Pattern detected? Check pattern rules
  - Outputs a JSON result:
    ```json
    {
      "violations": [
        {
          "rule": "boundary:db-access",
          "severity": "error",
          "message": "Direct database import in route handler. Use repository pattern.",
          "file": "src/routes/users.ts",
          "line": 3,
          "suggestion": "Import from src/repositories/userRepo instead"
        }
      ],
      "warnings": [],
      "passed": 12
    }
    ```
  - Returns `systemMessage` to Claude with violation context
  - Does NOT block edits (warns only — blocking confuses the agent per community best practices)
- [x] Implement Stop hook in `scripts/session-report.sh`:
  - Aggregates all violations from the session
  - Computes a "session health score" (violations weighted by severity)
  - Outputs summary: "This session introduced 2 boundary violations and 1 convention warning"
  - Writes snapshot to `.thymus/history/`
- [x] Implement SessionStart hook in `scripts/load-baseline.sh`:
  - Checks if `.thymus/baseline.json` exists
  - If yes: injects a compact summary (< 500 tokens) into Claude's context via `systemMessage`
  - If no: suggests running `/thymus:baseline`
  - Loads recent violation history for awareness
- [x] Performance optimization:
  - Hook must complete in < 2 seconds to avoid disrupting flow
  - Cache parsed invariants in `/tmp/thymus-cache-$PROJECT_HASH/`
  - Only check invariants relevant to the edited file (filter by glob)
  - Use `find` and `grep` over AST parsing for speed

### Definition of Done
- Editing a file that violates a boundary rule triggers an inline warning to Claude
- Claude adjusts its approach based on the warning (e.g., uses correct import path)
- Session-end report accurately summarizes all violations
- Hook execution time < 2 seconds for 95th percentile
- No false positives on the project's own existing code (baseline is the source of truth)

### Estimated Complexity: Ambitious

---

## Phase 3 — Health Dashboard & Reporting ✓

**Goal:** Rich, visual health reports that show drift over time.

### Tasks

- [x] Implement `/thymus:health` skill (full version):
  - Runs full scan against current baseline
  - Computes health scores per module and overall
  - Generates an interactive HTML report (opens in browser):
    - **Overview**: Overall health score, trend arrow, violation count
    - **Module Map**: Visual dependency graph with violation hotspots
    - **Drift Timeline**: Health score over time (from `.thymus/history/`)
    - **Top Violations**: Ranked by severity × frequency
    - **Tech Debt Projection**: "At current rate, X new violations per week"
  - Uses `scripts/generate-report.sh` with the HTML template
- [x] Implement `/thymus:scan` skill:
  - Lighter than `/thymus:health` — runs in terminal, no HTML
  - Outputs a structured table of current violations
  - Flags new violations since last scan
  - Supports `$ARGUMENTS` for scoping: `/thymus:scan src/auth`
- [x] Implement `debt-projector` agent:
  - Analyzes `.thymus/history/` snapshots
  - Computes velocity of architectural drift
  - Projects: "If current patterns continue, you'll have X boundary violations in 30 days"
  - Identifies which modules are degrading fastest
  - Suggests targeted refactoring priorities
- [x] Add diff-aware scanning:
  - Compare against git HEAD, branch, or specific commit
  - Show only NEW violations introduced by current branch
  - Perfect for PR review workflows

### Definition of Done
- `/thymus:health` generates a professional HTML report
- Report shows meaningful trends across ≥ 5 historical snapshots
- Debt projector produces actionable recommendations
- `/thymus:scan src/module` scopes correctly to subdirectory
- Reports render correctly in Chrome, Safari, Firefox

### Estimated Complexity: Medium

---

## Phase 4 — Learning & Auto-Discovery ✓

**Goal:** Thymus gets smarter over time. It learns from corrections, discovers new patterns, and auto-tunes.

### Tasks

- [x] Implement `/thymus:learn` skill:
  - User teaches Thymus a new invariant in natural language
  - Example: `/thymus:learn all database queries must go through the repository layer`
  - Thymus translates to a formal invariant in `invariants.yml`
  - Confirms with user before saving
  - Supports learning from corrections: "Claude, that import is wrong — auth should never touch the DB directly"
- [x] Implement CLAUDE.md auto-suggestions:
  - When a violation pattern repeats ≥ 3 times, suggest adding a CLAUDE.md rule
  - Format: "Consider adding to CLAUDE.md: 'Never import from src/db/ directly in route handlers. Use src/repositories/ instead.'"
  - Track which CLAUDE.md rules reduce violations (effectiveness scoring)
- [x] Implement pattern auto-discovery:
  - On `/thymus:baseline --refresh`, re-scan and detect NEW patterns
  - Diff against existing baseline to show what changed
  - Propose new invariants based on newly detected patterns
  - User approves/rejects each proposal
- [x] Implement severity auto-calibration:
  - Track which violations get fixed vs. ignored
  - Violations that are always fixed → increase severity
  - Violations that are always ignored → decrease severity or suggest removal
  - Prevents alert fatigue

### Definition of Done
- `/thymus:learn` correctly translates natural language to YAML invariants
- Auto-discovery finds ≥ 3 new patterns on a mature codebase
- Severity calibration adjusts after 10+ data points
- CLAUDE.md suggestions are actionable and specific

### Estimated Complexity: Ambitious

---

## Phase 5 — Polish & Distribution ✓

**Goal:** Production-quality plugin ready for marketplace distribution.

### Tasks

- [x] Write comprehensive README.md:
  - Quick start (< 2 minutes to first health report)
  - Configuration reference
  - Invariant rule syntax
  - FAQ and troubleshooting
- [x] Optimize for context window impact:
  - Skills use `disable-model-invocation: true` for action skills (scan, baseline, learn)
  - Reference skills (`user-invocable: false`) for background context
  - Total context footprint < 3K tokens at session start
- [x] Add language/framework auto-detection:
  - Detect from package.json, pyproject.toml, go.mod, etc.
  - Load appropriate default rules automatically
  - Support monorepos with per-package baselines
- [x] Error handling and edge cases:
  - Graceful degradation when `.thymus/` missing
  - Handle binary files, symlinks, very large files
  - Timeout protection on all hooks (< 10s hard limit)
  - Clear error messages (not stack traces)
- [x] Testing:
  - Create test fixtures: healthy project, unhealthy project, mixed
  - Verify invariant detection accuracy ≥ 90%
  - Verify false positive rate < 5%
  - Test with real-world codebases: Next.js, Django, Go API, Rust CLI
- [x] Prepare for marketplace:
  - Publish to GitHub
  - Create `marketplace.json` entry
  - Write a changelog
  - Add LICENSE (MIT)

### Definition of Done
- Plugin installs with single `/plugin install` command
- Works on TypeScript, Python, Go, Rust, Java projects
- README enables self-serve setup in < 5 minutes
- Marketplace-ready with all metadata

### Estimated Complexity: Medium

---

## Future

- **`structure` type handler**: Circular dependency detection via import graph analysis
- **Broader `convention` matching**: Beyond test colocation — naming conventions, file placement rules
- **Plugin marketplace submission**: Publish to the Claude Code plugin marketplace
- **CI/CD integration**: Run Thymus in GitHub Actions, fail PRs that introduce boundary violations
- **Team invariants**: Shared `.thymus/` committed to repo, team-wide enforcement
- **Visualization MCP**: Dependency graph as interactive web UI via MCP server
- **Cross-repo rules**: Organization-wide architectural standards
- **Migration planner**: Prioritized refactoring plans with estimated effort

---

## Risk Register

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Hook performance degrades Claude flow | Medium | High | Cache aggressively, filter by glob, < 2s hard limit |
| False positives erode trust | High | High | Start conservative, let users calibrate, severity auto-tune |
| Context bloat from skill descriptions | Medium | Medium | Use `disable-model-invocation` on action skills, keep descriptions lean |
| Different languages need different heuristics | High | Medium | Start with TS/Python, design for extensibility from day 1 |
| Users don't run `/thymus:baseline` | Medium | Low | SessionStart hook prompts on first use, provide 1-command setup |
| Baseline gets stale | Medium | Medium | `/thymus:baseline --refresh` diffing, auto-suggest refresh after N sessions |

---

## Success Metrics

- **Adoption**: 500+ installs in first month on marketplace
- **Violation catch rate**: ≥ 80% of architectural violations detected before commit
- **False positive rate**: < 5% after calibration
- **Performance**: < 2s per hook execution (p95)
- **Context cost**: < 3K tokens added to session start
- **User retention**: Users who install keep it enabled after 1 week