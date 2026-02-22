---
name: infer
description: >-
  Analyze the project's import graph and propose boundary rules based on
  actual usage patterns. Shows rules with confidence scores.
argument-hint: "[--min-confidence N] [--apply]"
---

# Thymus Auto-Inference

Analyze the codebase's import patterns and propose boundary rules. Follow these steps:

## Step 1: Run the inference

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/infer-rules.sh $ARGUMENTS
```

## Step 2: Narrate the results

Show the proposed rules to the user with a summary:

```
Inferred Rules (min confidence: 90%)

  1. inferred-src-auth-boundary (96.2%)
     Auth module is self-contained — external imports should go through index.ts

  2. inferred-src-routes-directionality (100%)
     Routes imports from services but services never imports from routes

No rules applied. To apply: /thymus:infer --apply
```

If `--apply` was used, confirm how many rules were appended.

If no rules were inferred, say:
```
No rules could be inferred above the confidence threshold.
Try lowering the threshold: /thymus:infer --min-confidence 70
```
