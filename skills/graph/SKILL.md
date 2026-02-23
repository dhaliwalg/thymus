---
name: graph
description: >-
  Generate an interactive dependency graph showing module relationships
  and boundary violations. Opens as an HTML file in the browser.
argument-hint: ""
---

# Thymus Dependency Graph

Generate an interactive dependency graph visualization. Follow these steps exactly:

## Step 1: Generate the graph

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/generate-graph.sh
```

The script writes `.thymus/graph.html` (opens in browser) and a sidecar at `.thymus/graph-summary.json`.

## Step 2: Read the summary

Use the Read tool on `${PWD}/.thymus/graph-summary.json`. This file contains:

- `module_count` — number of modules detected
- `edge_count` — number of cross-module edges
- `violation_count` — number of edges with violations
- `top_modules` — top 5 modules by file count, each with `id`, `file_count`, `violations`
- `violation_edges` — list of violation edges with `from`, `to`, `rules`

## Step 3: Narrate the results

From the summary JSON, narrate:

```
Dependency Graph: <module_count> modules, <edge_count> edges (<violation_count> violations)

<if violation_edges:>
Violation edges:
  <from> -> <to> (<rules joined by comma>)

<if no violations:>
No boundary violations detected.

Graph: .thymus/graph.html
```
