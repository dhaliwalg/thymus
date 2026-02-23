#!/usr/bin/env python3
"""Build a module-level adjacency graph from file-level import data.

Reads JSON array of {"file": "rel/path.ts", "imports": ["./foo", "../bar/baz"]}
from stdin.  Optionally cross-references violation data from scan-project.sh.

Usage:
    echo '[...]' | python3 build-adjacency.py [--violations /path/to/scan.json]

Output (stdout): JSON with "modules" and "edges" arrays.
"""
import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "lib"))
from core import file_to_module, resolve_import
from utils import debug as _debug


def debug(msg):
    _debug("build-adjacency.py", msg)


# ---------------------------------------------------------------------------
# Violation cross-referencing
# ---------------------------------------------------------------------------

def load_violations(violations_path):
    """Load and index violations from a scan-project.sh JSON file.

    Returns a dict mapping (source_file, resolved_import) -> list of rule ids
    for boundary violations that have an 'import' field.
    """
    if not violations_path:
        return {}
    try:
        with open(violations_path) as f:
            data = json.load(f)
    except (OSError, json.JSONDecodeError, TypeError) as e:
        debug(f"Could not load violations file {violations_path}: {e}")
        return {}

    violation_map = {}  # (source_file, resolved_import) -> [rule_id, ...]
    violations = data.get("violations", [])
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
# Main logic
# ---------------------------------------------------------------------------

def build_adjacency(entries, violation_map):
    """Build the module adjacency graph.

    Args:
        entries: list of {"file": str, "imports": [str, ...]}
        violation_map: dict of (source_file, resolved_import) -> [rule_ids]

    Returns:
        dict with "modules" and "edges" keys.
    """
    # Track which files belong to which module
    module_files = {}  # module_id -> set of file paths
    # Track edges: (from_module, to_module) -> list of import detail dicts
    edge_imports = {}  # (from_mod, to_mod) -> [{"source": file, "target": raw_import}]
    # Track violations per edge: (from_mod, to_mod) -> set of rule_ids
    edge_violations = {}
    # Track violations per module
    module_violation_count = {}  # module_id -> int

    for entry in entries:
        source_file = entry.get("file", "")
        imports = entry.get("imports", [])

        if not source_file:
            continue

        source_module = file_to_module(source_file)

        # Register file in its module
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


def main():
    violations_path = None

    # Parse --violations flag
    args = sys.argv[1:]
    i = 0
    while i < len(args):
        if args[i] == "--violations" and i + 1 < len(args):
            violations_path = args[i + 1]
            i += 2
        else:
            # Unknown arg — skip
            i += 1

    debug(f"starting, violations={violations_path}")

    # Read stdin
    raw = sys.stdin.read().strip()
    if not raw:
        json.dump({"modules": [], "edges": []}, sys.stdout, indent=2)
        sys.stdout.write("\n")
        debug("empty input, exiting")
        return

    try:
        entries = json.loads(raw)
    except json.JSONDecodeError as e:
        debug(f"JSON parse error: {e}")
        json.dump({"modules": [], "edges": []}, sys.stdout, indent=2)
        sys.stdout.write("\n")
        return

    if not isinstance(entries, list):
        debug(f"Expected JSON array, got {type(entries).__name__}")
        json.dump({"modules": [], "edges": []}, sys.stdout, indent=2)
        sys.stdout.write("\n")
        return

    violation_map = load_violations(violations_path)

    result = build_adjacency(entries, violation_map)

    json.dump(result, sys.stdout, indent=2)
    sys.stdout.write("\n")

    debug(f"done: {len(result['modules'])} modules, {len(result['edges'])} edges")


if __name__ == "__main__":
    main()
