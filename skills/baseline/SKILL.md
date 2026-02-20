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
