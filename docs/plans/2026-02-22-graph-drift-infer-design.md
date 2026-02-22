# Thymus: Graph Visualization, Drift Scoring, Auto-Inference

**Date**: 2026-02-22
**Status**: Approved

## Feature 1: Dependency Graph Visualization

### New files
- `scripts/generate-graph.sh` — orchestrator: collects imports, builds adjacency JSON, injects into template
- `scripts/build-adjacency.py` — groups files into modules, builds adjacency matrix, cross-references violations
- `templates/graph.html` — self-contained HTML template with `/*GRAPH_DATA*/` placeholder
- `skills/graph/SKILL.md` — `/thymus:graph` slash command

### Modified files
- `bin/thymus-scan` — add `--format graph` output option
- `bin/thymus` — document new format in help text
- `README.md`, `docs/index.html`

### Data flow
1. `generate-graph.sh` runs `extract-imports.py` across all source files
2. Pipes into `build-adjacency.py` which groups by top-level directory, builds module graph, cross-refs violations
3. Outputs JSON: `{"modules": [...], "edges": [...]}`
4. Replaces `/*GRAPH_DATA*/` token in `templates/graph.html`
5. Writes to `.thymus/graph.html`

### Graph rendering
- Fruchterman-Reingold force-directed layout in vanilla JS (~120 lines)
- SVG rendering (nodes=circles, edges=lines with arrows)
- Click node → file list, click edge → import list, hover → violation badge
- Dark theme: #1e1e2e bg, #89b4fa accent, #f38ba8 violations

---

## Feature 2: Drift Scoring + Trend Tracking

### New files
- `scripts/append-history.sh` — atomic JSONL append with FIFO cap at 500

### Modified files
- `scripts/scan-project.sh` — call `append-history.sh` after scan
- `scripts/session-report.sh` — replace per-file history with JSONL append
- `scripts/generate-report.sh` — JSONL reading, 30-point sparklines, compliance score, per-rule trends, worst-drift, sprint summary
- `bin/thymus` — add `history` and `score` commands
- `agents/debt-projector.md` — read JSONL instead of per-file snapshots

### History format (one line per scan)
```json
{"timestamp":"...","commit":"...","total_files":N,"files_checked":N,"violations":{"error":N,"warn":N,"info":N},"compliance_score":N.N,"by_rule":{"rule-id":N}}
```

### Compliance score
`((files_checked - error_count) / files_checked) * 100`

### Atomic write
Copy existing + new line to tmp, `mv` to final path.

### Report upgrades
- Large compliance score with delta arrow
- 30-point SVG sparkline (refactored from existing 10-point)
- Per-rule mini sparklines (top 5)
- Worst-drift callout, sprint summary (14-day window, 5+ scans)

---

## Feature 3: Auto-Inference Mode

### New files
- `scripts/infer-rules.sh` — orchestrator
- `scripts/analyze-graph.py` — graph analysis (stdlib Python)
- `skills/infer/SKILL.md` — `/thymus:infer` slash command

### Modified files
- `bin/thymus` — add `infer` command
- `README.md`

### Algorithm
1. Build adjacency matrix from import data (reuses `build-adjacency.py`)
2. Cluster detection: internal-import-ratio per module, threshold 0.9
3. Directionality: unidirectional edges → directional rule candidates
4. Gateway detection: >90% external imports target single file → gateway enforcement
5. Confidence scoring: % of existing imports already compliant

### CLI flags
- `--apply` — append above-threshold rules to invariants.yml
- `--min-confidence N` — minimum confidence (default 90)

### Output format
```yaml
- id: inferred-auth-boundary
  type: boundary
  severity: warning
  description: "..."
  source_glob: "src/**"
  forbidden_imports: ["src/auth/**"]
  inferred: true
  confidence: 96.2
```

---

## Design decisions
- **SVG over Canvas** for graph: supports CSS styling, click events, text natively
- **JSONL replaces per-file history**: simpler, faster trend reads, atomic appends
- **Separate analyze-graph.py**: keeps import parsing separate from graph analysis
- **Internal-import-ratio over Louvain**: zero dependencies, sufficient for module-level detection
- **Separate templates/graph.html**: easier to maintain HTML/JS than heredoc in bash
