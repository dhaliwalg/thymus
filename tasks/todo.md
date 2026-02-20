# AIS — Current Sprint Tasks

## Phase 0 — Foundation & Scaffolding

- [x] Create directory structure
- [x] Write all 5 skill stubs
- [x] Write hooks/hooks.json
- [x] Write scripts/load-baseline.sh
- [x] Write scripts/analyze-edit.sh
- [x] Write scripts/session-report.sh
- [x] Verify plugin loads
- [x] Verify all 5 skills appear
- [x] Verify hooks fire on Edit/Write

## Phase 1 — Baseline Engine

- [x] Create test fixtures (healthy + unhealthy TypeScript/Express projects)
- [x] Write scripts/detect-patterns.sh (structure scan → JSON)
- [x] Write scripts/scan-dependencies.sh (language/framework/imports → JSON)
- [x] Write agents/invariant-detector.md (proposes YAML invariants from scan data)
- [x] Write templates/default-rules.yml (generic + express/nextjs/django/fastapi rules)
- [x] Implement skills/baseline/SKILL.md (full 8-step scan-and-confirm flow)
- [x] End-to-end verification: both scripts pass, test gaps and boundary violations detected

## Phase 2 — Real-Time Enforcement

- [x] Apply Phase 1 fixes (invariants.json output, source_glob arrays, || true guards)
- [x] Add .ais/invariants.json test fixtures
- [x] Implement scripts/analyze-edit.sh (boundary + pattern + convention checking)
- [x] Implement scripts/session-report.sh (session aggregation + history snapshots)
- [x] Enhance scripts/load-baseline.sh (reads invariants.json, shows recent violation count)
- [x] End-to-end verification: all Phase 2 tests pass, hooks < 2s

## Backlog

See ROADMAP.md for Phase 3+ tasks.
