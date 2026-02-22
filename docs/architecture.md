# Thymus Architecture

## Source of Truth

```
.thymus/invariants.yml    ← Single source of truth for all rules
         │
         ├──→ analyze-edit.sh       (PostToolUse hook — real-time, per-file)
         ├──→ scan-project.sh       (Batch scanner — full project)
         ├──→ thymus-scan CLI       (CI/pre-commit entry point)
         ├──→ generate-agents-md.sh (AGENTS.md — soft enforcement for AI)
         └──→ generate-report.sh    (HTML health dashboard)
```

All enforcement paths read from the same `invariants.yml`. No rule exists only in code.

## Data Flow

```
                        ┌─────────────────────┐
                        │  invariants.yml      │
                        │  (YAML rule defs)    │
                        └────────┬────────────┘
                                 │
              ┌──────────────────┼──────────────────┐
              │                  │                   │
              ▼                  ▼                   ▼
   ┌──────────────────┐  ┌─────────────┐  ┌──────────────────┐
   │ analyze-edit.sh  │  │ scan-project│  │ generate-agents- │
   │ (per-file hook)  │  │   .sh       │  │    md.sh         │
   └───────┬──────────┘  └──────┬──────┘  └────────┬─────────┘
           │                    │                   │
           ▼                    ▼                   ▼
   ┌──────────────────┐  ┌─────────────┐  ┌──────────────────┐
   │ systemMessage    │  │ JSON output │  │ AGENTS.md /      │
   │ (Claude Code)    │  │ (violations)│  │ CLAUDE.md        │
   └──────────────────┘  └──────┬──────┘  └──────────────────┘
                                │
                    ┌───────────┼───────────┐
                    │           │           │
                    ▼           ▼           ▼
             ┌──────────┐ ┌─────────┐ ┌─────────┐
             │ text     │ │ github  │ │ sarif   │
             │ (human)  │ │ (annot.)│ │ (GHAS)  │
             └──────────┘ └─────────┘ └─────────┘
```

## Component Overview

### Core Engine

| Script | Purpose | Input | Output |
|--------|---------|-------|--------|
| `analyze-edit.sh` | PostToolUse hook — checks one file | Hook JSON (stdin) | `systemMessage` JSON |
| `scan-project.sh` | Batch scan — checks all files | `invariants.yml` | `{violations, stats}` JSON |
| `extract-imports.py` | AST-aware import extraction | Source file path | Import list (one per line) |
| `scan-dependencies.sh` | Language/framework detection | Project root | `{language, framework}` JSON |
| `detect-patterns.sh` | Layer/structure detection | Project root | `{detected_layers}` JSON |

### CLI Tools (`bin/`)

| Command | Purpose | Formats |
|---------|---------|---------|
| `thymus scan` | Full or diff project scan | json, text, github, sarif |
| `thymus check <file>` | Single file check | json, text, github, sarif |
| `thymus init` | Initialize `.thymus/` directory | — |

### Integrations

| Integration | Location | Purpose |
|-------------|----------|---------|
| Pre-commit hook | `integrations/pre-commit/` | Block commits with violations |
| GitHub Action | `integrations/github-actions/` | CI gate + SARIF upload |
| VS Code extension | `integrations/vscode/` | Editor diagnostics |
| Claude Code hooks | `hooks/hooks.json` | Real-time AI enforcement |

### Soft Enforcement (AI Agents)

| Script | Purpose |
|--------|---------|
| `generate-agents-md.sh` | Produce AGENTS.md from invariants |
| `import-agents-rules.sh` | Extract rules from existing AGENTS.md |
| `load-baseline.sh` | Inject rules into Claude Code session context |

## Rule Types

| Type | Enforcement | Example |
|------|-------------|---------|
| `boundary` | Import graph | "routes must not import db" |
| `pattern` | Regex on source | "no raw SQL outside db/" |
| `dependency` | Import + scope | "prisma only in db/" |
| `convention` | File structure | "test colocation" |

## Enforcement Layers

```
Strictness ───────────────────────────────────────────────►

  AI Agent        Pre-commit       CI Gate         SARIF/GHAS
  (soft)          (local)          (blocking)      (tracking)
  ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐
  │ AGENTS.md│    │ thymus   │    │ GitHub   │    │ Code     │
  │ context  │    │ pre-     │    │ Action   │    │ Scanning │
  │ injection│    │ commit   │    │ check    │    │ dashboard│
  └──────────┘    └──────────┘    └──────────┘    └──────────┘
  Guides AI       Blocks local    Blocks merge    Historical
  generation      commits with    PRs with        tracking of
  in real-time    error-severity  violations      all findings
                  violations
```

## Supported Languages

TypeScript, JavaScript, Python, Java, Go, Rust, Dart, Kotlin, Swift, C#, PHP, Ruby.

Each language has:
- Comment-aware import extraction (`extract-imports.py`)
- Framework detection (`scan-dependencies.sh`)
- Default rule templates (`templates/default-rules.yml`)
- Convention checking (test colocation patterns)
