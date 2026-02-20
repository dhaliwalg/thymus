# Phase 0 — Foundation & Scaffolding Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Create a working AIS plugin skeleton — all 5 skills visible in the `/` menu, hooks fire on edit events, and `load-baseline.sh` prompts setup when `.ais/` is absent.

**Architecture:** Pure bash scripts + markdown skill files. No external dependencies. All hooks log to `/tmp/ais-debug.log`. Skills are stubs — real logic deferred to later phases.

**Tech Stack:** bash 4+, jq, Claude Code plugin system (plugin.json, SKILL.md, hooks.json)

---

### Task 1: Create directory structure

**Files:**
- Create dirs: `skills/health/`, `skills/learn/`, `skills/scan/`, `skills/baseline/`, `skills/configure/`, `hooks/`, `scripts/`, `templates/`, `agents/`, `tasks/`, `tests/fixtures/`

**Step 1: Create all directories**

```bash
mkdir -p skills/health skills/learn skills/scan skills/baseline skills/configure
mkdir -p hooks scripts templates agents
mkdir -p tasks tests/fixtures/healthy-project tests/fixtures/unhealthy-project
```

Run from the repo root: `/Users/vapor/Documents/projs/claude-immune-system`

**Step 2: Verify structure**

```bash
find . -type d | grep -v '.git' | sort
```

Expected: all dirs listed above appear.

**Step 3: Commit**

```bash
git init  # if not already a repo
git add -A
git commit -m "chore: scaffold Phase 0 directory structure"
```

---

### Task 2: Create `tasks/todo.md` and `tasks/lessons.md`

**Files:**
- Create: `tasks/todo.md`
- Create: `tasks/lessons.md`

**Step 1: Write `tasks/todo.md`**

```markdown
# AIS — Current Sprint Tasks

## Phase 0 — Foundation & Scaffolding

- [x] Create directory structure
- [ ] Write all 5 skill stubs
- [ ] Write hooks/hooks.json
- [ ] Write scripts/load-baseline.sh
- [ ] Write scripts/analyze-edit.sh
- [ ] Write scripts/session-report.sh
- [ ] Verify plugin loads
- [ ] Verify all 5 skills appear
- [ ] Verify hooks fire on Edit/Write

## Backlog

See ROADMAP.md for Phase 1+ tasks.
```

**Step 2: Write `tasks/lessons.md`**

```markdown
# AIS — Lessons Learned

> Accumulated patterns and mistakes to avoid.
> Updated after every correction or discovered issue.

## Patterns

(none yet)

## Mistakes to Avoid

(none yet)
```

**Step 3: Commit**

```bash
git add tasks/
git commit -m "chore: add tasks/todo.md and tasks/lessons.md"
```

---

### Task 3: Write `skills/health/SKILL.md`

**Files:**
- Create: `skills/health/SKILL.md`

**Step 1: Write the skill file**

```yaml
---
name: health
description: >-
  Generate an architectural health report for the current project.
  Use when the user asks about code quality, architectural health,
  technical debt, or wants a summary of codebase violations.
argument-hint: "[--verbose]"
---

# AIS Health Report

AIS has not been initialized yet for this project.

To get started, run:

```
/ais:baseline
```

This will scan your codebase, detect structural patterns, and create
a baseline in `.ais/baseline.json` that future scans compare against.

Once initialized, `/ais:health` will generate a full architectural
health report showing module health scores, violation counts, and
drift over time.
```

**Step 2: Verify SKILL.md is valid**

- `name:` field must match parent directory name (`health`) ✓
- No `disable-model-invocation: true` on health (it auto-invokes) ✓

**Step 3: Commit**

```bash
git add skills/health/SKILL.md
git commit -m "feat: add skills/health stub"
```

---

### Task 4: Write action skill stubs (learn, scan, baseline, configure)

**Files:**
- Create: `skills/learn/SKILL.md`
- Create: `skills/scan/SKILL.md`
- Create: `skills/baseline/SKILL.md`
- Create: `skills/configure/SKILL.md`

All four get `disable-model-invocation: true` since they're action skills.

**Step 1: Write `skills/learn/SKILL.md`**

```yaml
---
name: learn
description: >-
  Teach AIS a new architectural invariant in natural language.
  Use when the user says "always", "never", "must", "should" about
  code structure. Example: /ais:learn all DB queries go through repositories
disable-model-invocation: true
argument-hint: "<natural language rule>"
---

# AIS Learn

AIS has not been initialized yet. Run `/ais:baseline` first to create
the baseline before teaching new invariants.

Once initialized, use this skill to add invariants:

  /ais:learn all database queries must go through the repository layer
  /ais:learn React components must not import from other components directly

AIS will translate your natural language rule into a formal invariant
in `.ais/invariants.yml` and confirm before saving.
```

**Step 2: Write `skills/scan/SKILL.md`**

```yaml
---
name: scan
description: >-
  Run a full architectural scan against the current baseline.
  Use when the user wants to check for violations, audit a module,
  or see what changed since the last scan.
disable-model-invocation: true
argument-hint: "[path/to/module]"
---

# AIS Scan

AIS has not been initialized yet. Run `/ais:baseline` first.

Once initialized, scan the full project:

  /ais:scan

Scope to a specific module:

  /ais:scan src/auth

AIS will check all files against `invariants.yml` and report
violations grouped by severity.
```

**Step 3: Write `skills/baseline/SKILL.md`**

```yaml
---
name: baseline
description: >-
  Initialize or refresh the AIS architectural baseline for this project.
  Run this first in any new project, or with --refresh to update after
  major refactors. Creates .ais/baseline.json with the structural fingerprint.
disable-model-invocation: true
argument-hint: "[--refresh]"
---

# AIS Baseline

This skill initializes AIS for your project by scanning the codebase
and producing a structural baseline.

**This feature is coming in Phase 1.**

For now, you can manually create `.ais/` to silence the setup prompt:

```bash
mkdir -p .ais
echo '{"version":"1.0","modules":[],"patterns":[],"boundaries":[],"conventions":[]}' > .ais/baseline.json
```

Full baseline scanning (with pattern detection, dependency graph,
and auto-discovered invariants) will be available in Phase 1.
```

**Step 4: Write `skills/configure/SKILL.md`**

```yaml
---
name: configure
description: >-
  Configure AIS thresholds, ignored paths, and rule settings.
  Use when the user wants to adjust severity levels, exclude directories,
  or change how AIS behaves in this project.
disable-model-invocation: true
argument-hint: "[setting] [value]"
---

# AIS Configure

AIS has not been initialized yet. Run `/ais:baseline` first.

Once initialized, you can configure AIS behavior in `.ais/config.yml`:

  /ais:configure ignore node_modules dist .next
  /ais:configure severity boundary error
  /ais:configure threshold health-warning 70

Configuration is stored in `.ais/config.yml` and takes effect
on the next hook invocation.
```

**Step 5: Commit all four**

```bash
git add skills/
git commit -m "feat: add action skill stubs (learn, scan, baseline, configure)"
```

---

### Task 5: Write `hooks/hooks.json`

**Files:**
- Create: `hooks/hooks.json`

**Step 1: Write the hooks file**

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Edit|Write",
        "hooks": [
          {
            "type": "command",
            "command": "bash ${CLAUDE_PLUGIN_ROOT}/scripts/analyze-edit.sh",
            "timeout": 10
          }
        ]
      }
    ],
    "Stop": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "bash ${CLAUDE_PLUGIN_ROOT}/scripts/session-report.sh"
          }
        ]
      }
    ],
    "SessionStart": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "bash ${CLAUDE_PLUGIN_ROOT}/scripts/load-baseline.sh",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
```

**Step 2: Commit**

```bash
git add hooks/hooks.json
git commit -m "feat: add hooks/hooks.json with PostToolUse, Stop, SessionStart"
```

---

### Task 6: Write `scripts/load-baseline.sh`

**Files:**
- Create: `scripts/load-baseline.sh`

This is the SessionStart hook. It checks if `.ais/baseline.json` exists in the
current project (i.e. `$PWD`). If not, it tells Claude to suggest setup.

**Step 1: Write the script**

```bash
#!/usr/bin/env bash
set -euo pipefail

# AIS SessionStart hook — load-baseline.sh
# Injects a compact baseline summary into Claude's context at session start.
# Output: JSON systemMessage (< 500 tokens)

DEBUG_LOG="/tmp/ais-debug.log"
AIS_DIR="$PWD/.ais"
BASELINE="$AIS_DIR/baseline.json"
TIMESTAMP=$(date '+%Y-%m-%dT%H:%M:%S')

echo "[$TIMESTAMP] load-baseline.sh fired in $PWD" >> "$DEBUG_LOG"

if [ ! -f "$BASELINE" ]; then
  echo "[$TIMESTAMP] No baseline found — outputting setup prompt" >> "$DEBUG_LOG"
  cat <<'EOF'
{
  "systemMessage": "📊 AIS: No baseline detected for this project. Run /ais:baseline to initialize architectural monitoring."
}
EOF
  exit 0
fi

# Baseline exists — output a compact summary
MODULE_COUNT=$(jq '.modules | length' "$BASELINE" 2>/dev/null || echo "0")
INVARIANT_COUNT=0
INVARIANTS_FILE="$AIS_DIR/invariants.yml"
if [ -f "$INVARIANTS_FILE" ]; then
  INVARIANT_COUNT=$(grep -c "^  - id:" "$INVARIANTS_FILE" 2>/dev/null || echo "0")
fi

echo "[$TIMESTAMP] Baseline found — $MODULE_COUNT modules, $INVARIANT_COUNT invariants" >> "$DEBUG_LOG"

cat <<EOF
{
  "systemMessage": "📊 AIS Active | $MODULE_COUNT modules | $INVARIANT_COUNT invariants enforced | Run /ais:health for full report"
}
EOF
```

**Step 2: Make executable**

```bash
chmod +x scripts/load-baseline.sh
```

**Step 3: Test the script manually**

```bash
# Should output the "no baseline" message
bash scripts/load-baseline.sh
```

Expected output:
```json
{
  "systemMessage": "📊 AIS: No baseline detected for this project. Run /ais:baseline to initialize architectural monitoring."
}
```

Also verify it logged to `/tmp/ais-debug.log`:
```bash
tail -5 /tmp/ais-debug.log
```

**Step 4: Commit**

```bash
git add scripts/load-baseline.sh
git commit -m "feat: add scripts/load-baseline.sh SessionStart hook"
```

---

### Task 7: Write `scripts/analyze-edit.sh`

**Files:**
- Create: `scripts/analyze-edit.sh`

This is the PostToolUse hook for Edit|Write. In Phase 0 it just logs and exits cleanly.

**Step 1: Write the script**

```bash
#!/usr/bin/env bash
set -euo pipefail

# AIS PostToolUse hook — analyze-edit.sh
# Receives tool input JSON via stdin. In Phase 0: logs only.
# Phase 2 will add real invariant checking against .ais/invariants.yml

DEBUG_LOG="/tmp/ais-debug.log"
TIMESTAMP=$(date '+%Y-%m-%dT%H:%M:%S')

input=$(cat)
file_path=$(echo "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null || echo "unknown")
tool_name=$(echo "$input" | jq -r '.tool_name // "unknown"' 2>/dev/null || echo "unknown")

echo "[$TIMESTAMP] analyze-edit.sh: $tool_name on $file_path" >> "$DEBUG_LOG"

# Phase 0: no violations to report — output nothing
exit 0
```

**Step 2: Make executable**

```bash
chmod +x scripts/analyze-edit.sh
```

**Step 3: Test the script manually**

```bash
echo '{"tool_name":"Edit","tool_input":{"file_path":"src/test.ts"}}' | bash scripts/analyze-edit.sh
echo "Exit code: $?"
```

Expected: no output, exit code 0.

```bash
tail -3 /tmp/ais-debug.log
```

Expected: log line showing `analyze-edit.sh: Edit on src/test.ts`

**Step 4: Commit**

```bash
git add scripts/analyze-edit.sh
git commit -m "feat: add scripts/analyze-edit.sh PostToolUse hook stub"
```

---

### Task 8: Write `scripts/session-report.sh`

**Files:**
- Create: `scripts/session-report.sh`

This is the Stop hook. In Phase 0 it logs the session end.

**Step 1: Write the script**

```bash
#!/usr/bin/env bash
set -euo pipefail

# AIS Stop hook — session-report.sh
# Fires at end of every Claude session. In Phase 0: logs only.
# Phase 2 will aggregate violations and compute health score delta.

DEBUG_LOG="/tmp/ais-debug.log"
TIMESTAMP=$(date '+%Y-%m-%dT%H:%M:%S')

input=$(cat)
session_id=$(echo "$input" | jq -r '.session_id // "unknown"' 2>/dev/null || echo "unknown")

echo "[$TIMESTAMP] session-report.sh: session $session_id ended" >> "$DEBUG_LOG"

# Phase 0: silent exit — no summary yet
exit 0
```

**Step 2: Make executable**

```bash
chmod +x scripts/session-report.sh
```

**Step 3: Test manually**

```bash
echo '{"session_id":"test-123"}' | bash scripts/session-report.sh
echo "Exit code: $?"
tail -3 /tmp/ais-debug.log
```

Expected: exit 0, log entry shows session end.

**Step 4: Commit**

```bash
git add scripts/session-report.sh
git commit -m "feat: add scripts/session-report.sh Stop hook stub"
```

---

### Task 9: Verify the full plugin loads

**Step 1: Check all scripts are executable**

```bash
ls -la scripts/
```

Expected: `analyze-edit.sh`, `session-report.sh`, `load-baseline.sh` all show `-rwxr-xr-x`

**Step 2: Verify directory structure matches ROADMAP**

```bash
find . -not -path './.git/*' -not -path './node_modules/*' | sort
```

Expected: all dirs and files present per design.

**Step 3: Smoke-test load-baseline.sh from an arbitrary directory**

```bash
cd /tmp && bash /Users/vapor/Documents/projs/claude-immune-system/scripts/load-baseline.sh
```

Expected: "No baseline detected" JSON (since /tmp has no .ais/).

**Step 4: Update tasks/todo.md** — mark all Phase 0 items complete.

**Step 5: Final commit**

```bash
git add -A
git commit -m "feat: Phase 0 complete — plugin skeleton with 5 skills, hooks, and stub scripts"
```

---

## Verification Checklist

After all tasks:

- [ ] `ls skills/` shows: `health  learn  scan  baseline  configure`
- [ ] `ls hooks/` shows: `hooks.json`
- [ ] `ls scripts/` shows: `analyze-edit.sh  load-baseline.sh  session-report.sh`
- [ ] All 3 scripts are executable (`chmod +x` applied)
- [ ] `bash scripts/load-baseline.sh` outputs valid JSON
- [ ] `echo '{}' | bash scripts/analyze-edit.sh` exits 0 silently
- [ ] `/tmp/ais-debug.log` contains entries from both test runs
- [ ] `tasks/todo.md` has all Phase 0 items checked
