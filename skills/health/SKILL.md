---
name: health
description: >-
  Generate an architectural health report for the current project.
  Use when the user asks about code quality, architectural health,
  technical debt, drift trends, or wants a summary of codebase violations.
argument-hint: "[--diff]"
---

# Thymus Health Report

Generate a full architectural health report. Follow these steps exactly:

## Step 1: Generate the report

```bash
THYMUS_NO_OPEN=1 bash ${CLAUDE_PLUGIN_ROOT}/scripts/generate-report.sh $ARGUMENTS
```

This runs the scan internally, writes `.thymus/report.html`, and writes a machine-readable sidecar at `.thymus/health-summary.json`.

## Step 2: Read the summary

Use the Read tool on `${PWD}/.thymus/health-summary.json`. This file contains:

- `score` — health score (0-100)
- `compliance` — file compliance percentage
- `arrow` — trend direction
- `trend_text` — human-readable trend description
- `files_checked` — number of files scanned
- `total_violations`, `errors`, `warnings` — violation counts
- `violations` — list of violation objects (up to 30)
- `report_path` — path to the full HTML report

## Step 3: Narrate the results

From the summary JSON, narrate:

```
Health Score: <score>/100 <arrow>

Files scanned: <files_checked>
Violations: <total_violations> (<errors> errors, <warnings> warnings)

Modules with violations:
<group violations by module (first 2 path segments), list counts — only show modules with violations>

Top violations:
<list up to 5, most severe first — show rule, file, severity>

Trend: <trend_text>

Full report: .thymus/report.html
```

If there are no violations, say: `No violations. Health score: <score>/100`
