# Thymus

Architectural boundary enforcement for AI-assisted codebases.

## The Problem

AI coding tools are fast. They're also structurally reckless. Give Claude or Cursor a feature to build and it'll happily route your controllers straight to the database, import across module boundaries, and scatter business logic wherever it lands. The architecture you spent months setting up erodes one helpful commit at a time.

Thymus catches this. It watches every file edit against a set of rules you define in YAML, and flags the ones that violate your module boundaries. If an import shouldn't exist, Thymus catches it before it ships.

## Quick Start

Install the plugin:

<!-- When accepted to Anthropic's official directory, simplify to: /plugin install thymus -->
```
/plugin marketplace add dhaliwalg/thymus
/plugin install thymus@dhaliwalg/thymus
```

Generate a baseline for your project:

```
/thymus:baseline
```

This scans your project structure, proposes rules, and waits for approval before saving anything.

Teach it a rule in plain English:

```
/thymus:learn "controllers must not import from the database layer"
```

Thymus converts this to a structured YAML invariant with the right scope, patterns, and severity. The rule takes effect on the next edit.

From here, every file edit is checked automatically. Violations show up inline:

```
BOUNDARY VIOLATION: src/routes/users.ts imports from db/models
  Rule: routes-no-direct-db — "Route handlers must not import directly from the db layer"
  Severity: error
```

## How It Works

Three hooks fire automatically: session start loads your rules and injects a health summary into context, post-edit checks the changed file against all matching invariants in under 2 seconds, and session end summarizes violations and writes a history snapshot. Rules live in `.thymus/invariants.yml`. Import extraction is AST-aware for JavaScript/TypeScript and Python — it won't flag `import { db }` inside a comment or string literal. All other languages use comment-aware state machine parsers.

## What You Can Define

| Rule Type | Example |
|-----------|---------|
| Boundary | `routes/` cannot import from `db/` |
| Dependency | Only `services/` may use the ORM |
| Pattern ban | No raw SQL outside `repositories/` |
| Naming | Files in `hooks/` must be named `use*.ts` |
| Test coverage | Every file in `services/` needs a corresponding test |

Rules are defined in YAML. Use `/thymus:learn` to generate them from plain English, or edit `.thymus/invariants.yml` directly:

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

Severity levels: `error` (hard rules), `warning` (best practices), `info` (informational).

## Enforcement Beyond Claude Code

Rules are portable YAML. Thymus ships integrations that enforce the same rules outside of Claude Code:

- **Pre-commit hook** — blocks violations at commit time, works with any editor
- **CLI** — `bin/thymus scan` and `bin/thymus check <file>` for scripting and CI
- **VS Code / Cursor / Windsurf** — extension reads the same rules, shows inline diagnostics
- **GitHub Actions** — annotates PRs with violations

### CLI

```bash
bin/thymus scan              # Scan entire project
bin/thymus scan --diff       # Scan staged files only
bin/thymus check src/file.ts # Check a single file
bin/thymus graph             # Generate interactive dependency graph
bin/thymus infer             # Infer boundary rules from import patterns
bin/thymus score             # Show current compliance score
bin/thymus history           # Show scan history with trends
bin/thymus init              # Initialize .thymus/ in a new project
```

### Pre-commit hook

```bash
ln -sf ../../integrations/pre-commit/thymus-pre-commit .git/hooks/pre-commit
```

### GitHub Actions

```yaml
# .github/workflows/thymus.yml
- uses: ./integrations/github-actions
  with:
    scan-mode: diff
    fail-on: error
```

## Slash Commands

```
/thymus:baseline   — Scan project structure and generate initial rules
/thymus:scan       — Run a full project scan and show violations
/thymus:learn      — Teach a new rule in plain English
/thymus:health     — Generate an HTML health report with trends
/thymus:configure  — Adjust severity levels and rule settings
/thymus:graph      — Generate an interactive dependency graph
/thymus:infer      — Auto-infer boundary rules from import patterns
```

## Language Support

| Language | Framework Detection | Import Analysis |
|----------|-------------------|-----------------|
| TypeScript/JavaScript | Next.js, Express, React | Comment-aware (state machine) |
| Python | Django, FastAPI, Flask | AST (`ast` module) |
| Go | Gin, Echo, Fiber, Chi | Comment-aware (state machine) |
| Rust | Actix, Axum, Rocket | Comment-aware (state machine) |
| Java | Spring, Quarkus, Micronaut | Comment-aware (state machine) |
| Dart | Flutter, Shelf, Angel | Comment-aware (state machine) |
| Kotlin | Spring Boot, Ktor, Micronaut | Comment-aware (state machine) |
| Swift | Vapor, iOS/macOS | Comment-aware (state machine) |
| C# | ASP.NET, MAUI | Comment-aware (state machine) |
| PHP | Laravel, Symfony, Slim | Comment-aware (state machine) |
| Ruby | Rails, Sinatra, Hanami | Comment-aware (state machine) |

## Dependency Graph

`/thymus:graph` (or `bin/thymus graph`) builds an interactive HTML visualization of your module-level import relationships. Each module is a node, each cross-module import is an edge, and edges that violate a boundary rule are highlighted in red.

```
/thymus:graph
```

The graph opens in your default browser. It cross-references your `invariants.yml` rules so you can see which module relationships are clean and which are in violation.

## Drift Scoring

Every scan appends a snapshot to `.thymus/history.jsonl` with violation counts, a compliance score, and the current git commit hash. The compliance score formula:

```
compliance = ((files_checked - error_count) / files_checked) * 100
```

View the current score and recent trend:

```bash
bin/thymus score              # Compliance: 94.2% (+1.3% from last scan)
bin/thymus history            # Last 10 scans with timestamps, scores, and commits
bin/thymus history --json     # Raw JSONL for scripting
```

History is capped at 500 entries (FIFO). The session-end hook and health report use this data to show sparklines and trend direction over time.

## Auto-Inference

`/thymus:infer` (or `bin/thymus infer`) analyzes your project's actual import graph and proposes boundary rules based on what the code already does. Four detection algorithms run:

| Algorithm | What it detects |
|-----------|----------------|
| Directionality | Module A imports from B but B never imports from A — propose preventing the reverse |
| Gateway | >90% of external imports into a module target a single file (e.g. `index.ts`) — enforce gateway pattern |
| Self-containment | Module imports from 0-1 other modules — lock down external dependencies |
| Selective dependencies | Module imports from exactly 2 other modules — enforce the existing boundary |

Each proposed rule includes a confidence score (0-100%). Rules below the threshold are filtered out:

```bash
bin/thymus infer                       # Default: 90% confidence threshold
bin/thymus infer --min-confidence 70   # Lower threshold for more suggestions
bin/thymus infer --apply               # Append inferred rules to invariants.yml
```

Inferred rules are tagged with `inferred: true` and their confidence percentage so you can distinguish them from hand-written rules.

## Installation

From the Claude Code plugin marketplace:

<!-- When accepted to Anthropic's official directory, simplify to: /plugin install thymus -->
```
/plugin marketplace add dhaliwalg/thymus
/plugin install thymus@dhaliwalg/thymus
```

Or manually:

```bash
git clone https://github.com/dhaliwalg/thymus.git
claude --plugin-dir ./thymus
```

### Requirements

- bash 4.0+
- jq
- python3 (stdlib only)
- git

## License

MIT. See [CLAUDE.md](CLAUDE.md) for contributor notes.
