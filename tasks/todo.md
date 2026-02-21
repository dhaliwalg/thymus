# Thymus — Current Sprint Tasks

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
- [x] Add .thymus/invariants.json test fixtures
- [x] Implement scripts/analyze-edit.sh (boundary + pattern + convention checking)
- [x] Implement scripts/session-report.sh (session aggregation + history snapshots)
- [x] Enhance scripts/load-baseline.sh (reads invariants.json, shows recent violation count)
- [x] End-to-end verification: all Phase 2 tests pass, hooks < 2s

## Phase 3 — Health Dashboard & Reporting

- [x] YAML migration: convert test fixture invariants.json → invariants.yml
- [x] YAML migration: update analyze-edit.sh to use load_invariants() + invariants.yml
- [x] YAML migration: update load-baseline.sh to invariants.yml
- [x] Docs: update CLAUDE.md + ROADMAP.md schema examples (scope_glob_exclude)
- [x] Implement scripts/scan-project.sh (batch invariant checker)
- [x] Implement skills/scan/SKILL.md (full implementation)
- [x] Implement agents/debt-projector.md (trend analysis agent)
- [x] Implement scripts/generate-report.sh (self-contained HTML report)
- [x] Implement skills/health/SKILL.md (full Claude-narrated orchestration)
- [x] End-to-end verification: verify-phase3.sh passes

## Phase 4 — Learning & Auto-Discovery

- [x] Implement scripts/add-invariant.sh (safe YAML append with validation)
- [x] Implement skills/learn/SKILL.md (NL → YAML invariant translation + save)
- [x] Add CLAUDE.md auto-suggestions to scripts/session-report.sh (≥3 repeats)
- [x] Implement scripts/refresh-baseline.sh (detect new directories vs baseline)
- [x] Implement scripts/calibrate-severity.sh (fix/ignore ratio → downgrade recs)
- [x] End-to-end verification: verify-phase4.sh passes (16/16)

## Phase 5 — Polish & Distribution

- [x] Implement scripts/detect-framework.sh (language + framework auto-detection)
- [x] Harden scripts/analyze-edit.sh (binary, symlink, large file guards)
- [x] Add Python test fixture (tests/fixtures/python-project/)
- [x] Write README.md (user-facing documentation)
- [x] Write CHANGELOG.md (version history)
- [x] Write LICENSE (MIT)
- [x] End-to-end verification: verify-phase5.sh passes (14/14)

## All phases complete — 50/50 tests passing
