---
name: scan
description: >-
  Run a full architectural scan against the current baseline and invariants.
  Use when the user wants to check for violations, audit a module,
  or see what changed since the last scan. Supports scoping to a subdirectory.
disable-model-invocation: true
argument-hint: "[path/to/module] [--diff]"
---

# Thymus Scan

Run the full-project invariant scanner:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/scan-project.sh $ARGUMENTS
```

The output is JSON. Parse it and format a human-readable violation table:

```
Scanning <scope or "entire project"> (<N> files)...

VIOLATIONS
──────────
[ERROR]   <rule-id>
          <file>:<line> — <message>

[WARNING] <rule-id>
          <file> — <message>

N violation(s) found (X errors, Y warnings).
```

If `stats.total` is 0, output: `No violations found.`

Append at the end: `Run /thymus:health for the full report with trend data.`

**Scoping:** If `$ARGUMENTS` contains a path (e.g. `src/auth`), the scan is limited to that directory.

**Diff mode:** If `$ARGUMENTS` contains `--diff`, only files changed since `git HEAD` are scanned.
