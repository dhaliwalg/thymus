#!/usr/bin/env python3
"""Thymus generate-graph.py — dependency graph visualization.

Replaces generate-graph.sh + build-adjacency.py with zero subprocess
overhead.  All import extraction, adjacency building, violation scanning,
and template injection happen in-process.

Usage: python3 generate-graph.py [--output /path/to/output.html]
Output: writes .thymus/graph.html (or custom path), prints path to stdout

Python 3 stdlib only. No pip dependencies.
"""

import json
import os
import platform
import subprocess
import sys

# Add lib/ to path
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), 'lib'))
from core import (
    debug_log,
    find_source_files,
    build_import_entries,
    load_invariants,
    thymus_cache_dir,
)
from rules import eval_rule_for_file


# ---------------------------------------------------------------------------
# Module grouping — absorbed from build-adjacency.py
# ---------------------------------------------------------------------------


def file_to_module(filepath):
    """Map a file path to its module id (first 2 path components).

    Examples:
        src/routes/users.ts  -> src/routes
        src/db/client.ts     -> src/db
        utils.ts             -> utils
        lib/foo/bar/baz.ts   -> lib/foo
    """
    parts = filepath.replace("\\", "/").split("/")
    if len(parts) >= 3:
        return parts[0] + "/" + parts[1]
    elif len(parts) == 2:
        return parts[0]
    else:
        name = parts[0]
        dot = name.rfind(".")
        if dot > 0:
            return name[:dot]
        return name


# ---------------------------------------------------------------------------
# Import resolution — absorbed from build-adjacency.py
# ---------------------------------------------------------------------------


def resolve_import(source_file, imp):
    """Resolve an import specifier relative to the source file.

    - Relative imports (starting with . or ..) are resolved against the
      source file's directory using os.path.normpath.
    - Non-relative imports are returned as-is.

    Returns the resolved path (without extension).
    """
    if imp.startswith("."):
        source_dir = os.path.dirname(source_file)
        resolved = os.path.normpath(os.path.join(source_dir, imp))
        resolved = resolved.replace("\\", "/")
        return resolved
    return imp


# ---------------------------------------------------------------------------
# Violation loading — index by (source_file, resolved_import)
# ---------------------------------------------------------------------------


def load_violations_from_scan(scan_data):
    """Index violations from scan-project output by (source_file, resolved_import).

    Returns a dict mapping (source_file, resolved_import) -> [rule_ids]
    for boundary violations that have an 'import' field.
    """
    violation_map = {}
    violations = scan_data.get("violations", [])
    if not isinstance(violations, list):
        return {}

    for v in violations:
        imp = v.get("import")
        source = v.get("file")
        rule = v.get("rule")
        if not imp or not source or not rule:
            continue
        resolved = resolve_import(source, imp)
        key = (source, resolved)
        if key not in violation_map:
            violation_map[key] = []
        if rule not in violation_map[key]:
            violation_map[key].append(rule)

    return violation_map


# ---------------------------------------------------------------------------
# Adjacency graph builder — absorbed from build-adjacency.py
# ---------------------------------------------------------------------------


def build_adjacency(entries, violation_map):
    """Build the module adjacency graph.

    Args:
        entries: list of {"file": str, "imports": [str, ...]}
        violation_map: dict of (source_file, resolved_import) -> [rule_ids]

    Returns:
        dict with "modules" and "edges" keys.
    """
    module_files = {}       # module_id -> set of file paths
    edge_imports = {}       # (from_mod, to_mod) -> [{"source": file, "target": raw_import}]
    edge_violations = {}    # (from_mod, to_mod) -> set of rule_ids
    module_violation_count = {}  # module_id -> int

    for entry in entries:
        source_file = entry.get("file", "")
        imports = entry.get("imports", [])

        if not source_file:
            continue

        source_module = file_to_module(source_file)

        if source_module not in module_files:
            module_files[source_module] = set()
        module_files[source_module].add(source_file)

        for imp in imports:
            if not imp:
                continue

            resolved = resolve_import(source_file, imp)
            target_module = file_to_module(resolved)

            # Skip self-edges (imports within same module)
            if target_module == source_module:
                continue

            # Ensure target module exists in tracking
            if target_module not in module_files:
                module_files[target_module] = set()

            edge_key = (source_module, target_module)

            if edge_key not in edge_imports:
                edge_imports[edge_key] = []
            edge_imports[edge_key].append({
                "source": source_file,
                "target": imp
            })

            # Check for violations on this specific import
            viol_key = (source_file, resolved)
            if viol_key in violation_map:
                if edge_key not in edge_violations:
                    edge_violations[edge_key] = set()
                for rule_id in violation_map[viol_key]:
                    edge_violations[edge_key].add(rule_id)

    # Count violations per module (from violation_map, by source file)
    for (source_file, _resolved), rule_ids in violation_map.items():
        mod = file_to_module(source_file)
        if mod not in module_violation_count:
            module_violation_count[mod] = 0
        module_violation_count[mod] += len(rule_ids)

    # Build modules output
    modules = []
    for mod_id in sorted(module_files.keys()):
        files = sorted(module_files[mod_id])
        modules.append({
            "id": mod_id,
            "files": files,
            "file_count": len(files),
            "violations": module_violation_count.get(mod_id, 0)
        })

    # Build edges output
    edges = []
    for (from_mod, to_mod) in sorted(edge_imports.keys()):
        imp_list = edge_imports[(from_mod, to_mod)]
        rule_ids = sorted(edge_violations.get((from_mod, to_mod), set()))
        edges.append({
            "from": from_mod,
            "to": to_mod,
            "imports": imp_list,
            "violation": len(rule_ids) > 0,
            "rule_ids": rule_ids
        })

    return {"modules": modules, "edges": edges}


# ---------------------------------------------------------------------------
# In-process violation scan — replaces spawning scan-project.sh
# ---------------------------------------------------------------------------


def run_scan(invariants_data, files, cwd):
    """Run scan-project logic in-process.

    Args:
        invariants_data: parsed invariants dict from load_invariants()
        files: list of relative file paths
        cwd: current working directory

    Returns:
        dict with "violations" key (list of violation dicts)
    """
    invariants = invariants_data.get("invariants", [])
    violations = []

    for rel_path in files:
        abs_path = os.path.join(cwd, rel_path)
        if not os.path.isfile(abs_path):
            continue

        for inv in invariants:
            viols = eval_rule_for_file(abs_path, rel_path, inv)
            violations.extend(viols)

    return {"violations": violations}


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def main():
    cwd = os.getcwd()
    thymus_dir = os.path.join(cwd, ".thymus")
    invariants_yml = os.path.join(thymus_dir, "invariants.yml")

    # Locate template
    script_dir = os.path.dirname(os.path.abspath(__file__))
    template_dir = os.path.normpath(os.path.join(script_dir, "..", "templates"))
    template_path = os.path.join(template_dir, "graph.html")

    # --- Parse arguments ---
    output_file = ""
    args = sys.argv[1:]
    i = 0
    while i < len(args):
        if args[i] == "--output" and i + 1 < len(args):
            output_file = args[i + 1]
            i += 2
        else:
            i += 1

    if not output_file:
        os.makedirs(thymus_dir, exist_ok=True)
        output_file = os.path.join(thymus_dir, "graph.html")

    debug_log(f"generate-graph.py: output={output_file}")

    # --- Verify template exists ---
    if not os.path.isfile(template_path):
        print(f"Thymus: graph template not found at {template_path}", file=sys.stderr)
        sys.exit(1)

    # --- Build file list (single os.walk) ---
    files = find_source_files(cwd)
    file_count = len(files)
    debug_log(f"generate-graph: found {file_count} source files")

    # --- Empty project: write template with empty data ---
    if file_count == 0:
        debug_log("generate-graph: empty project, writing empty graph")
        empty_data = {"modules": [], "edges": []}
        with open(template_path) as f:
            template = f.read()
        output = template.replace(
            '/*GRAPH_DATA*/{"modules":[],"edges":[]}',
            json.dumps(empty_data)
        )
        os.makedirs(os.path.dirname(output_file), exist_ok=True)
        with open(output_file, 'w') as f:
            f.write(output)
        print(output_file)
        sys.exit(0)

    # --- Extract imports in-process (no subprocess) ---
    entries = build_import_entries(files, cwd)
    debug_log(f"generate-graph: extracted imports from {file_count} files")

    # --- Run violation scan in-process if invariants.yml exists ---
    violation_map = {}
    if os.path.isfile(invariants_yml):
        try:
            cache_dir = thymus_cache_dir()
            cache_path = os.path.join(cache_dir, "invariants-graph.json")
            invariants_data = load_invariants(invariants_yml, cache_path)
            scan_data = run_scan(invariants_data, files, cwd)
            violation_map = load_violations_from_scan(scan_data)
            debug_log("generate-graph: violation scan succeeded")
        except Exception as e:
            debug_log(f"generate-graph: violation scan failed ({e}), continuing without")
    else:
        debug_log("generate-graph: no invariants.yml, skipping violation scan")

    # --- Build adjacency graph in-process ---
    graph_data = build_adjacency(entries, violation_map)
    debug_log(
        f"generate-graph: adjacency graph built — "
        f"{len(graph_data['modules'])} modules, {len(graph_data['edges'])} edges"
    )

    # --- Inject graph data into template ---
    with open(template_path) as f:
        template = f.read()

    output = template.replace(
        '/*GRAPH_DATA*/{"modules":[],"edges":[]}',
        json.dumps(graph_data)
    )

    os.makedirs(os.path.dirname(os.path.abspath(output_file)), exist_ok=True)
    with open(output_file, 'w') as f:
        f.write(output)

    debug_log(f"generate-graph: wrote {output_file}")

    # --- Print output path ---
    print(output_file)

    # --- Attempt to open in browser ---
    if not os.environ.get("THYMUS_NO_OPEN"):
        try:
            if platform.system() == "Darwin":
                subprocess.Popen(["open", output_file],
                                 stdout=subprocess.DEVNULL,
                                 stderr=subprocess.DEVNULL)
            else:
                subprocess.Popen(["xdg-open", output_file],
                                 stdout=subprocess.DEVNULL,
                                 stderr=subprocess.DEVNULL)
        except OSError:
            pass


if __name__ == "__main__":
    main()
