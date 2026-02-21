---
name: baseline
description: >-
  Initialize or refresh the Thymus architectural baseline for this project.
  Run this first in any new project to enable architectural monitoring.
  Creates .thymus/baseline.json with the structural fingerprint and proposes
  invariants for user review. Use with --refresh to update after major refactors.
disable-model-invocation: true
argument-hint: "[--refresh]"
---

# Thymus Baseline

Follow these steps to initialize Thymus for the current project.

## Steps

**1. Run structural scan**

Execute:
```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/detect-patterns.sh $PWD
```

Capture the full JSON output. If it fails, check that `jq` is installed (`which jq`).

**2. Run dependency scan**

Execute:
```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/scan-dependencies.sh $PWD
```

Capture the full JSON output.

**3. Propose invariants**

Invoke the `invariant-detector` agent with the combined scan output. Pass both JSON objects merged as a single object:
```json
{
  "structure": <detect-patterns output>,
  "dependencies": <scan-dependencies output>
}
```

The agent will return YAML invariants.

**4. Load default rules**

Read `${CLAUDE_PLUGIN_ROOT}/templates/default-rules.yml` and select rules relevant to the detected framework. Merge with the agent's proposals, deduplicating by `id`.

**5. Present findings**

Present a structured summary to the user:

```
## Thymus Baseline Scan Results

**Project:** [language] / [framework]
**Scanned:** [file count] files across [module count] modules

### Detected Modules
[list each detected layer with its path and inferred purpose]

### Naming Conventions
[list detected file suffix patterns]

### Test Coverage Gaps
[list files missing colocated tests, or "None detected"]

### Module Dependency Map
[list cross_module_imports pairs in readable form: "routes → controllers → services → repositories → db"]

### Proposed Invariants ([N] rules)
[list each invariant: id, type, severity, description]

---
Review the above. Tell me what to adjust (e.g. "auth isn't a separate module, it's part of users"), or say **save** to write the baseline.
```

**6. Handle user response**

- If user says **save** (or equivalent): proceed to step 7
- If user requests adjustments: apply them to the in-memory data, re-present the affected section, ask again
- If user says **skip** or **cancel**: abort without writing files

**7. Write `.thymus/` files**

Create the `.thymus/` directory if it doesn't exist:
```bash
mkdir -p $PWD/.thymus/history
```

Write three files:

**`.thymus/baseline.json`** — structural fingerprint (JSON from steps 1-3, synthesized):
```json
{
  "version": "1.0",
  "created_at": "[ISO timestamp]",
  "project": { "root": "[PWD]", "language": "[detected]", "framework": "[detected]" },
  "modules": [...],
  "patterns": [...],
  "boundaries": [...],
  "conventions": [...]
}
```

**`.thymus/invariants.yml`** — user-facing rules (also read by hooks via `load_invariants()`):
```yaml
version: "1.0"
invariants:
  [proposed invariants from step 3-4]
```

**`.thymus/config.yml`** — default configuration:
```yaml
version: "1.0"
ignored_paths: [node_modules, dist, .next, .git, coverage]
health_warning_threshold: 70
health_error_threshold: 50
language: [detected]
```

**8. Confirm**

Tell the user:
> Thymus baseline saved to `.thymus/`. [N] invariants active. Run `/thymus:health` for a report or `/thymus:scan` to check for violations.
