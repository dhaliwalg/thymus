# Thymus

A Claude Code plugin that watches your codebase for architectural drift and enforces structural invariants as you write code.

Code gets generated fast. Over time, architecture quietly rots — boundary violations, inconsistent patterns, modules that should never talk to each other suddenly do. Thymus is the immune system: it learns what healthy looks like and warns when things go wrong, before the mess compounds.

---

## Setup

**Install**
```
/plugin install thymus
```

**Initialize** (once per project)
```
/thymus:baseline
```

Scans the project, proposes invariants, waits for your approval before saving anything.

That's it. Thymus now checks every file you edit against your rules.

**Check health**
```
/thymus:health
```

---

## How it works

Three hooks:

| Hook | What it does |
|------|-------------|
| Every file edit | Checks the file against your invariants. Warns immediately if something's wrong. |
| Session start | Injects a compact health summary into context. |
| Session end | Summarizes violations, writes a history snapshot, flags rules that keep firing. |

---

## Commands

### `/thymus:baseline`
Initialize or refresh the baseline for the current project.

```
/thymus:baseline            # first-time setup
/thymus:baseline --refresh  # re-scan after a big refactor
```

Produces:
- `.thymus/baseline.json` — structural fingerprint
- `.thymus/invariants.yml` — your rules
- `.thymus/config.yml` — thresholds and ignored paths

### `/thymus:scan`
Scan the whole project (or a subdirectory) right now.

```
/thymus:scan
/thymus:scan src/auth
/thymus:scan --diff        # only files changed since git HEAD
```

### `/thymus:health`
Full health report with trend data. Generates `.thymus/report.html`.

### `/thymus:learn`
Teach Thymus a new rule in plain English.

```
/thymus:learn all database queries must go through the repository layer
/thymus:learn React components must not import from other components directly
/thymus:learn never use raw SQL outside src/db
```

Translates it to YAML and asks for confirmation before saving.

### `/thymus:configure`
Adjust thresholds and ignored paths via `.thymus/config.yml`.

---

## The `.thymus/` directory

All state lives here. Thymus automatically adds `.thymus` to your `.gitignore` on first run. To share rules with your team, commit `invariants.yml` and `baseline.json` separately.

```
.thymus/
├── baseline.json      # structural fingerprint
├── invariants.yml     # your rules (human-editable)
├── config.yml         # thresholds, ignored paths
├── report.html        # latest health report
├── calibration.json   # tracks which rules get fixed vs ignored
└── history/           # timestamped session snapshots
```

---

## Rule syntax

Edit `.thymus/invariants.yml` directly or use `/thymus:learn`.

```yaml
# boundary rule: module A can't import from module B
- id: boundary-routes-no-db
  type: boundary
  severity: error
  description: "Route handlers must not import directly from the db layer"
  source_glob: "src/routes/**"
  forbidden_imports:
    - "src/db/**"
    - "prisma"
  allowed_imports:
    - "src/repositories/**"

# pattern rule: forbid a code pattern by regex
- id: pattern-no-raw-sql
  type: pattern
  severity: error
  description: "No raw SQL strings outside the db layer"
  forbidden_pattern: "(SELECT|INSERT|UPDATE|DELETE)[[:space:]]+(FROM|INTO|SET|WHERE)"
  scope_glob: "src/**"
  scope_glob_exclude:
    - "src/db/**"

# convention rule: structural requirement
- id: convention-test-colocation
  type: convention
  severity: warning
  description: "Every source file must have a colocated test file"
  source_glob: "src/**"
  rule: "For every src/**/*.ts, there should be a src/**/*.test.ts"

# dependency rule: restrict where a package can be imported
- id: dependency-axios-scope
  type: dependency
  severity: warning
  description: "Axios only used in the API client module"
  package: "axios"
  allowed_in:
    - "src/lib/api-client/**"
```

Severity: `error` (hard rules), `warning` (best practices), `info` (informational)

---

## Config

`.thymus/config.yml`:

```yaml
version: "1.0"
ignored_paths: [node_modules, dist, .next, .git, coverage, __pycache__]
health_warning_threshold: 70
health_error_threshold: 50
language: typescript   # auto-detected; override if needed
```

---

## Supported languages

| Language | Framework detection | Import analysis |
|----------|--------------------|--------------  |
| TypeScript/JavaScript | Next.js, Express, React | yes |
| Python | Django, FastAPI, Flask | yes |
| Go | modules | yes |
| Rust | Cargo | yes |
| Java | Maven, Gradle | partial |

---

## Performance

- Every hook runs in < 2s
- Parsed invariants cached in `/tmp/thymus-cache-{hash}/`
- Only checks invariants that match the edited file's glob
- Binary files, symlinks, and files > 500KB are skipped

---

## FAQ

**A rule keeps firing but I always fix it. Can Thymus adjust automatically?**
Thymus tracks this in `.thymus/calibration.json`. After enough data points, run `/thymus:configure` or manually run `bash scripts/calibrate-severity.sh` from the plugin directory to get downgrade recommendations.

**I refactored and the baseline is stale.**
Run `/thymus:baseline --refresh`.

**How do I share invariants with my team?**
Thymus auto-gitignores `.thymus/` by default. To share rules, remove the `.thymus` line from `.gitignore` and commit `.thymus/invariants.yml` and `.thymus/baseline.json`. Keep `.thymus/history/` and `.thymus/report.html` gitignored.

**Does Thymus block edits?**
No. It warns but never blocks. Blocking mid-task causes confusing behavior — a warning gives the context needed to self-correct.

**Thymus is flagging something that's intentional.**
Edit `.thymus/invariants.yml` directly and change the severity to `info`, or remove the rule.

---

## Troubleshooting

**Hook not firing:** check `/tmp/thymus-debug.log`

**"no baseline found":** run `/thymus:baseline` in your project root

**"failed to parse invariants.yml":** check indentation — each rule starts with `  - id:` (2 spaces). Use `/thymus:learn` to add rules safely.

**Hook is slow:** check `/tmp/thymus-debug.log` for timing. Add large generated directories to `ignored_paths` in `.thymus/config.yml`.

---

## Requirements

- bash 4.0+
- jq
- python3 (stdlib only)
- git (for `--diff` scanning)

---

## License

MIT

