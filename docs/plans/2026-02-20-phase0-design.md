# Phase 0 Design — Foundation & Scaffolding

**Date:** 2026-02-20
**Phase:** 0 of 5
**Goal:** Working plugin skeleton that installs, loads, and responds to basic commands.

## What Gets Created

```
skills/
  health/SKILL.md        — stub returning "AIS not yet initialized"
  learn/SKILL.md         — stub: "Run /ais:baseline first"
  scan/SKILL.md          — stub: "Run /ais:baseline first"
  baseline/SKILL.md      — stub: initializes .ais/ directory (future)
  configure/SKILL.md     — stub: configure thresholds and rules (future)
hooks/
  hooks.json             — PostToolUse + Stop + SessionStart wired to scripts
scripts/
  analyze-edit.sh        — logs to /tmp/ais-debug.log, outputs {}
  session-report.sh      — logs session end to /tmp/ais-debug.log
  load-baseline.sh       — checks for .ais/, prompts setup if missing
tasks/
  todo.md                — Phase 0 checklist
  lessons.md             — empty, ready for accumulated patterns
```

## Key Decisions

- `plugin.json` already exists — no changes needed
- Action skills (scan, baseline, learn, configure) use `disable-model-invocation: true`
- Hook scripts log to `/tmp/ais-debug.log` for verification
- `load-baseline.sh` outputs a `systemMessage` suggesting `/ais:baseline` if `.ais/` missing; silent otherwise
- Scripts are stubs only — real logic deferred to Phase 2

## Definition of Done

- Plugin loads with `claude --plugin-dir ./architectural-immune-system`
- All 5 skills appear in `/` menu
- Hooks fire on Edit/Write and produce log output in `/tmp/ais-debug.log`
- Context footprint < 2K tokens at session start
