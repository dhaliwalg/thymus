---
name: configure
description: >-
  Configure Thymus thresholds, ignored paths, and rule settings.
  Use when the user wants to adjust severity levels, exclude directories,
  or change how Thymus behaves in this project.
disable-model-invocation: true
argument-hint: "[setting] [value]"
---

# Thymus Configure

## Steps

**1. Check initialization**

If `.thymus/config.yml` does not exist, tell the user:
> Thymus has not been initialized yet. Run `/thymus:baseline` first.

Then stop.

**2. Parse arguments**

Read `$ARGUMENTS` and determine the operation:

| Command | Meaning |
|---------|---------|
| `ignore <paths...>` | Add paths to `ignored_paths` |
| `unignore <paths...>` | Remove paths from `ignored_paths` |
| `severity <rule-id> <error\|warning\|info>` | Change a rule's severity in `invariants.yml` |
| `threshold health-warning <N>` | Set `health_warning_threshold` in config |
| `threshold health-error <N>` | Set `health_error_threshold` in config |
| `language <lang>` | Override detected language |
| (no arguments) | Show current configuration |

**3. If no arguments — show current config**

Read `.thymus/config.yml` and present it:
```
## Current Thymus Configuration

- **Language:** [language]
- **Ignored paths:** [list]
- **Health warning threshold:** [N]
- **Health error threshold:** [N]

To change: `/thymus:configure <setting> <value>`
```

**4. Apply the change**

- For `ignore`/`unignore`: Read `.thymus/config.yml`, modify the `ignored_paths` list, write it back.
- For `severity`: Read `.thymus/invariants.yml`, find the rule by `id`, change its `severity` field, write it back.
- For `threshold`: Read `.thymus/config.yml`, update the relevant threshold field, write it back.
- For `language`: Read `.thymus/config.yml`, update the `language` field, write it back.

Preserve all other fields and formatting when editing YAML files.

**5. Confirm**

Tell the user what changed:
> Updated `[setting]` to `[value]` in `.thymus/config.yml`.

If the change was to `invariants.yml`:
> Updated severity of `[rule-id]` to `[severity]` in `.thymus/invariants.yml`.
