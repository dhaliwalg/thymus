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
