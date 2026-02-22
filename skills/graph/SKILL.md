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

The script will output the path to the generated HTML file.

## Step 2: Open the graph

The graph opens automatically in the default browser. If it doesn't, tell the user:

```
Dependency graph written to .thymus/graph.html
Open it in your browser to explore module relationships.
```

## Step 3: Narrate the results

Read the graph data and provide a brief summary:
- Number of modules detected
- Number of cross-module edges
- Number of edges with violations (red edges)
- Which modules have the most violations

Example:
```
Dependency Graph: 6 modules, 8 edges (2 violations)

Violation edges:
  src/routes → src/db (boundary-routes-no-direct-db)

Graph: .thymus/graph.html
```
