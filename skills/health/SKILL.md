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
