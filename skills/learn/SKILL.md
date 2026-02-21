---
name: learn
description: >-
  Teach Thymus a new architectural invariant in natural language.
  Use when the user says "always", "never", "must", "should", "only" about
  code structure. Examples: /thymus:learn all DB queries go through repositories
  /thymus:learn never import from src/db in route handlers
argument-hint: "<natural language rule>"
---

# Thymus Learn — Teach a New Invariant

The user wants to teach Thymus a new architectural rule in natural language:

**User's rule:** `$ARGUMENTS`

## Your task

Translate this natural language rule into a formal YAML invariant and save it.

### Precondition — check `.thymus/invariants.yml` exists

Before doing anything, verify `$PWD/.thymus/invariants.yml` exists. If it doesn't, tell the user:

"`.thymus/invariants.yml` not found. Run `/thymus:baseline` first to initialize Thymus, then re-run `/thymus:learn`."

Stop here if the file is missing.

### Step 1 — Translate to YAML

Map the natural language to the appropriate invariant type:

| If the rule says... | Use type |
|---------------------|----------|
| "must not import", "cannot use", "never import" | `boundary` |
| "no X pattern", "never use raw X", "must not contain" | `pattern` |
| "every X must have Y", "all files must", naming rules | `convention` |
| "only use library X in module Y" | `dependency` |

**Required fields for each type:**

For `boundary`:
```yaml
  - id: boundary-<descriptive-slug>
    type: boundary
    severity: error
    description: "<what the rule enforces>"
    source_glob: "<glob of files this applies to>"
    forbidden_imports:
      - "<forbidden import pattern>"
    allowed_imports:
      - "<allowed alternative>"
```

For `pattern`:
```yaml
  - id: pattern-<descriptive-slug>
    type: pattern
    severity: error
    description: "<what pattern is forbidden>"
    forbidden_pattern: "<regex>"
    scope_glob: "<glob of files to check>"
    scope_glob_exclude:
      - "<paths to exclude>"
```

For `convention`:
```yaml
  - id: convention-<descriptive-slug>
    type: convention
    severity: warning
    description: "<convention description>"
    source_glob: "<glob this applies to>"
    rule: "<human-readable rule statement>"
```

For `dependency`:
```yaml
  - id: dependency-<descriptive-slug>
    type: dependency
    severity: warning
    description: "<package usage rule>"
    package: "<npm/pip package name>"
    allowed_in:
      - "<glob of files where it's allowed>"
```

**ID naming:** `<type>-<short-slug>` e.g. `boundary-routes-no-db`, `pattern-no-console-log`

**Severity rules:**
- `error` — hard architectural rules (boundary violations, forbidden patterns)
- `warning` — conventions and best practices
- `info` — informational only

### Step 2 — Show the generated YAML to the user

Present the invariant clearly and ask for confirmation:

```
I'll add this invariant to `.thymus/invariants.yml`:

```yaml
[the generated YAML block]
```

Does this look right? If you'd like to adjust the glob, severity, or description, let me know. Otherwise, say **yes** to save it.
```

### Step 3 — If user confirms, save it

When the user confirms, save the invariant using a heredoc to handle multi-line YAML safely:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/add-invariant.sh "$PWD/.thymus/invariants.yml" << 'YAML_EOF'
[the exact YAML block — indented with 2 spaces before `- id:`, 4 spaces for fields, 6 for list items]
YAML_EOF
```

The YAML block must use the indentation shown in the examples above (2 spaces + `- id:` for the entry, 4 spaces for fields, 6 spaces for list items).

After saving, clear the invariants cache so the next hook invocation picks up the new rule:
```bash
PROJECT_HASH=$(echo "$PWD" | md5 -q 2>/dev/null || echo "$PWD" | md5sum | cut -d' ' -f1)
rm -f "/tmp/thymus-cache-${PROJECT_HASH}/invariants.json" "/tmp/thymus-cache-${PROJECT_HASH}/invariants-scan.json"
```

Then confirm to the user: "Invariant `<id>` added. Thymus will enforce this rule on the next file edit."

