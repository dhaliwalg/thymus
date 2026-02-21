---
name: health
description: >-
  Generate an architectural health report for the current project.
  Use when the user asks about code quality, architectural health,
  technical debt, drift trends, or wants a summary of codebase violations.
argument-hint: "[--diff]"
---

# AIS Health Report

Generate a full architectural health report. Follow these steps exactly:

## Step 1: Run the full-project scan

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/scan-project.sh $ARGUMENTS > /tmp/ais-health-scan.json
```

## Step 2: Check for history (debt projection)

Count history snapshots:

```bash
ls ${PWD}/.ais/history/*.json 2>/dev/null | wc -l
```

If there are 2 or more snapshots, invoke the `debt-projector` agent:
- Pass it the list of snapshot file paths (sorted chronologically)
- Capture the JSON output as `PROJECTION`

If fewer than 2 snapshots exist, set `PROJECTION` to empty string.

## Step 3: Generate the HTML report

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/generate-report.sh \
  --scan /tmp/ais-health-scan.json \
  [--projection '$PROJECTION']
```

Include `--projection` only if projection data is available.

## Step 4: Narrate the results

Read the scan JSON from `/tmp/ais-health-scan.json` and the summary JSON from `generate-report.sh` stdout. Narrate a structured summary:

```
Health Score: <score>/100 <arrow>

Files scanned: <N>
Violations: <total> (<errors> errors, <warnings> warnings)

Modules with violations:
<list modules with violation counts — only show modules with violations>

Top violations:
<list up to 5, most severe first>

Trend: <trend_text from generate-report.sh output>
<if projection: velocity + 30-day projection + recommendation>

Full report: .ais/report.html
```

If there are no violations, say: `No violations. Health score: 100/100`

Clean up temp file: `rm -f /tmp/ais-health-scan.json`
