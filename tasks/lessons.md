# Thymus — Lessons Learned

> Accumulated patterns and mistakes to avoid.
> Updated after every correction or discovered issue.

## Patterns

- **YAML is the single source of truth for invariants.** After the Phase 3 migration, all invariant storage uses `.yml`. Never write `.json` copies — hooks parse YAML via `load_invariants()`.
- **Health score formula must be consistent.** Both `generate-report.sh` and `session-report.sh` must use: `100 - unique_error_rules×10 - unique_warning_rules×3`. History snapshots must include a `score` field for the sparkline to work.
- **Diff mode must respect scope.** When `--diff` and a scope path are both provided, filter git diff output to only include files under the scope path.
- **`load_invariants()` is deliberately duplicated.** The ~30-line Python YAML parser exists in `analyze-edit.sh`, `scan-project.sh`, and `add-invariant.sh` independently. This is intentional — no shared `lib.sh` due to fragile path resolution in plugin contexts.
- **Tree listings in CLAUDE.md and ROADMAP.md must match reality.** Only list files/dirs that actually exist. Don't list planned-but-unbuilt artifacts.

## Mistakes to Avoid

- **Don't write `invariants.json`** — stale artifact from pre-YAML era. Hooks read YAML directly.
- **Don't list files in docs that don't exist** — `violation-analyzer.md`, `templates/invariants.yml`, `templates/report.html`, and `tests/verify.sh` were listed but never created.
- **Don't forget to include health score in session snapshots** — omitting `score` from history JSON creates gaps in the sparkline trend chart.
- **Don't assume `--diff` files are in scope** — always cross-filter with scope path when both are specified.
- **Don't reference `${CLAUDE_PLUGIN_ROOT}` in user-facing docs** — this variable only exists inside the plugin runtime. Use relative paths in README/FAQ.
