# CLAUDE.md — Architectural Immune System Plugin

> Project-level instructions for building the AIS Claude Code plugin. Claude reads this file at session start.

---

## Project Overview

You are building **Architectural Immune System (AIS)** — a Claude Code plugin that continuously monitors codebase health, detects architectural drift, and enforces structural invariants in real-time.

**Repository root**: This directory IS the plugin root.
**Roadmap**: See `ROADMAP.md` for full phase breakdown and task checklists.
**Task tracking**: See `tasks/todo.md` for current sprint items.
**Lessons learned**: See `tasks/lessons.md` for accumulated patterns to follow.

---

## Project Structure

```
architectural-immune-system/
├── .claude-plugin/
│   └── plugin.json              # ← Only plugin.json goes here. Nothing else.
├── skills/                      # ← At plugin ROOT, not inside .claude-plugin/
│   ├── health/SKILL.md
│   ├── learn/SKILL.md
│   ├── scan/SKILL.md
│   ├── baseline/SKILL.md
│   └── configure/SKILL.md
├── agents/
│   ├── invariant-detector.md
│   ├── violation-analyzer.md
│   └── debt-projector.md
├── hooks/
│   └── hooks.json
├── scripts/                     # Shell scripts (called by hooks AND skills)
│   ├── analyze-edit.sh          # Hook: PostToolUse — checks edit against invariants
│   ├── session-report.sh        # Hook: Stop — aggregates session violations
│   ├── load-baseline.sh         # Hook: SessionStart — injects baseline context
│   ├── scan-dependencies.sh     # Skill: called by /ais:baseline and /ais:scan
│   ├── detect-patterns.sh       # Skill: called by /ais:baseline for pattern discovery
│   └── generate-report.sh       # Skill: called by /ais:health for HTML report
├── templates/
│   ├── invariants.yml
│   ├── report.html
│   └── default-rules.yml
├── tests/                       # Test fixtures and verification scripts
│   ├── fixtures/
│   │   ├── healthy-project/
│   │   └── unhealthy-project/
│   └── verify.sh
├── tasks/
│   ├── todo.md
│   └── lessons.md
├── ROADMAP.md
├── CLAUDE.md                    # This file
├── README.md
└── LICENSE
```

### CRITICAL structure rules
- **NEVER** put commands/, agents/, skills/, or hooks/ inside `.claude-plugin/`. Only `plugin.json` goes there.
- All component directories MUST be at the **plugin root level**.
- Skill directory names MUST match the `name:` field in their SKILL.md frontmatter.
- Hook scripts MUST be executable (`chmod +x`).

---

## Tech Stack & Dependencies

### Runtime requirements (must be available on user's machine)
- `bash` (4.0+) — all hook scripts
- `jq` — JSON parsing in hooks (standard on most dev machines)
- `find`, `grep`, `sed`, `awk` — pattern detection
- `git` — for diff-aware scanning

### NO external dependencies
- Do NOT require npm install, pip install, or any package manager
- All scripts must be self-contained bash
- Use only standard Unix tools + `jq`
- This makes the plugin install-and-go with zero friction

### Languages we analyze (in priority order)
1. TypeScript/JavaScript (imports, package.json, tsconfig paths)
2. Python (imports, pyproject.toml, __init__.py structure)
3. Go (imports, go.mod)
4. Rust (use statements, Cargo.toml)
5. Java (import statements, pom.xml/build.gradle)

---

## Coding Standards

### Shell scripts
- Start every script with `#!/usr/bin/env bash` and `set -euo pipefail`
- Read hook input from stdin: `input=$(cat)`
- Parse with jq: `file_path=$(echo "$input" | jq -r '.tool_input.file_path // empty')`
- Output JSON to stdout for structured responses
- Output errors/warnings to stderr
- Exit code 0 = success, exit code 2 = block (PreToolUse only, and we do NOT block)
- Every script must complete in < 2 seconds. If it might be slow, cache aggressively.
- Use `/tmp/ais-cache-$(echo "$PWD" | md5sum | cut -d' ' -f1)/` for project-specific cache

### SKILL.md format
```yaml
---
name: skill-name            # MUST match parent directory name
description: >-
  What this skill does. When Claude should use it.
  Be specific — the description is the primary trigger for auto-invocation.
disable-model-invocation: true   # For action skills (scan, baseline, learn, configure)
argument-hint: "[optional args]" # Show user what arguments are accepted
---

# Skill Title

Instructions for Claude...
Reference `$ARGUMENTS` for user input.
Reference `${CLAUDE_PLUGIN_ROOT}` for paths to scripts.
```

### Agent .md format
```markdown
You are a specialized agent for [purpose].

## Your role
[What you do]

## Inputs
[What you receive]

## Output format
[Exact structure of your response — always JSON or structured YAML]

## Rules
- [Specific constraints]
```

### hooks.json format
```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Edit|Write",
        "hooks": [{
          "type": "command",
          "command": "bash ${CLAUDE_PLUGIN_ROOT}/scripts/analyze-edit.sh",
          "timeout": 10
        }]
      }
    ],
    "Stop": [
      {
        "matcher": "*",
        "hooks": [{
          "type": "command",
          "command": "bash ${CLAUDE_PLUGIN_ROOT}/scripts/session-report.sh"
        }]
      }
    ],
    "SessionStart": [
      {
        "matcher": "*",
        "hooks": [{
          "type": "command",
          "command": "bash ${CLAUDE_PLUGIN_ROOT}/scripts/load-baseline.sh",
          "timeout": 5
        }]
      }
    ]
  }
}
```

---

## Key Design Decisions

### 1. Warn, never block
PostToolUse hooks should NEVER return exit code 2 or use `permissionDecision: deny`. Blocking Claude mid-task confuses the agent and produces worse results (confirmed by community best practices). Instead, return a `systemMessage` that warns Claude about the violation. Claude will self-correct.

### 2. Performance is non-negotiable
Every hook invocation must complete in < 2 seconds. Users report that slow hooks destroy the coding flow. Strategies:
- Cache parsed invariants and baselines in `/tmp/`
- Filter invariants by file glob BEFORE checking (most edits only need 2-3 rules checked)
- Use `grep` and `find` over AST parsing
- If a scan would take > 2s, skip it and log a warning

### 3. Context budget is sacred
The plugin must add < 3K tokens to the session context. This means:
- Action skills (`/ais:scan`, `/ais:baseline`, `/ais:learn`, `/ais:configure`) use `disable-model-invocation: true`
- Only `/ais:health` auto-invokes (when user asks about code quality or health)
- SessionStart hook injects a COMPACT summary (< 500 tokens), not the full baseline
- Keep skill descriptions SHORT — they're loaded into context even when not invoked

### 4. .ais/ directory is the source of truth
All persistent state lives in `.ais/` at the project root:
- `baseline.json` — structural fingerprint
- `invariants.yml` — rules (both user-defined and auto-discovered)
- `history/` — timestamped snapshots for trend analysis
- `config.yml` — user preferences, thresholds, ignored paths

Users choose whether to `.gitignore` this or commit it for team sharing.

### 5. Start conservative, let users expand
Default invariant set should be SMALL (5-10 rules) and high-confidence. Better to miss a violation than to cry wolf. Users expand via `/ais:learn` and `/ais:baseline --refresh`.

---

## Invariant Rule Schema

```yaml
# invariants.yml
version: "1.0"
invariants:
  - id: boundary-db-access
    type: boundary
    severity: error          # error | warning | info
    description: "Database access only through repository layer"
    source_glob: "src/routes/**"
    forbidden_imports:
      - "src/db/**"
      - "prisma"
      - "knex"
    allowed_imports:
      - "src/repositories/**"

  - id: convention-test-colocation
    type: convention
    severity: warning
    description: "Tests must be colocated with source files"
    rule: "For every src/**/*.ts, there should be a src/**/*.test.ts"

  - id: structure-no-circular-deps
    type: structure
    severity: error
    description: "No circular module dependencies"
    scope: "src/*"

  - id: pattern-no-raw-sql
    type: pattern
    severity: error
    description: "No raw SQL strings outside the db layer"
    forbidden_pattern: "(SELECT|INSERT|UPDATE|DELETE)\\s+(FROM|INTO|SET)"
    scope_glob: "src/**"
    scope_glob_exclude:
      - "src/db/**"          # blocklist — files matching these globs are skipped
                             # Replaces bash extglob negation !(foo)/** which is not portable

  - id: dependency-scope
    type: dependency
    severity: warning
    description: "Axios only used in api-client module"
    package: "axios"
    allowed_in: ["src/lib/api-client/**"]
```

---

## Hook Input/Output Contracts

### PostToolUse (Edit|Write) — analyze-edit.sh

**Stdin** (from Claude Code):
```json
{
  "tool_name": "Edit",
  "tool_input": {
    "file_path": "src/routes/users.ts",
    "old_string": "...",
    "new_string": "..."
  },
  "tool_response": {
    "filePath": "src/routes/users.ts",
    "success": true
  },
  "session_id": "abc123"
}
```

**Stdout** (our response):
```json
{
  "systemMessage": "⚠️ AIS: 1 violation detected in src/routes/users.ts:\n- [ERROR] boundary-db-access: Direct database import in route handler. Use repository pattern.\n  Suggestion: Import from src/repositories/userRepo instead.",
  "hookSpecificOutput": {}
}
```

If no violations: output nothing (empty stdout) or `{}`.

### SessionStart — load-baseline.sh

**Stdout**:
```json
{
  "systemMessage": "📊 AIS Active | Health: 87/100 | 3 known violations | 24 invariants enforced | Run /ais:health for details"
}
```

### Stop — session-report.sh

**Stdout**:
```json
{
  "systemMessage": "📋 AIS Session Summary: 14 edits analyzed | 1 new violation (boundary-db-access) | 0 resolved | Health: 85/100 (was 87)"
}
```

---

## Development Workflow

### When starting a new session
1. Read `tasks/todo.md` to know what's in progress
2. Read `tasks/lessons.md` to avoid past mistakes
3. Check which ROADMAP phase we're on
4. Continue from where we left off

### When building
1. **Plan first**: Write the plan to `tasks/todo.md` before coding
2. **Build in stages**: Small, testable increments
3. **Test each piece**: Run the plugin locally with `claude --plugin-dir .`
4. **Verify hooks**: Check `/tmp/ais-debug.log` for hook output
5. **Check context cost**: Run `/context` after loading to verify token impact

### When something goes wrong
1. Stop immediately
2. Document the issue in `tasks/lessons.md` with the pattern
3. Re-plan before continuing
4. Don't patch — find root cause

### After any correction from user
1. Update `tasks/lessons.md` with the mistake pattern
2. Write a rule to prevent the same mistake
3. Apply the correction
4. Verify it works

---

## Testing Protocol

### Manual verification
```bash
# Test plugin loading
claude --plugin-dir ./architectural-immune-system

# Verify skills appear
# Type / and look for ais:health, ais:scan, etc.

# Test SessionStart hook
# Check /tmp/ais-debug.log for startup output

# Test PostToolUse hook
# Edit any file and check /tmp/ais-debug.log

# Test Stop hook
# End a session and check for summary output
```

### Test fixtures
Maintain two test projects in `tests/fixtures/`:
- `healthy-project/` — passes all default invariants
- `unhealthy-project/` — has known violations (circular deps, boundary violations, missing tests)

### Verification script
`tests/verify.sh` runs the full test suite:
```bash
#!/usr/bin/env bash
# Runs AIS against both fixtures and validates output
# Exit 0 if all tests pass, exit 1 with details on failure
```

---

## What NOT to Do

- **Do NOT use npm, pip, or any package manager** — all scripts must be self-contained bash + jq
- **Do NOT block edits** — warn only, never exit code 2 on PostToolUse
- **Do NOT parse ASTs** — use grep/find heuristics for speed. Correctness > completeness
- **Do NOT load full baseline into context** — summarize to < 500 tokens on SessionStart
- **Do NOT auto-discover invariants without user approval** — suggest, let user confirm
- **Do NOT use `once: true` in agents** — it's only supported in skills and commands, not agents
- **Do NOT put component directories inside `.claude-plugin/`** — everything at plugin root
- **Do NOT assume specific directory structure in target projects** — detect and adapt
- **Do NOT make hooks that take > 2 seconds** — cache or skip
- **Do NOT create a separate CSS/JS file for the HTML report** — single self-contained HTML file