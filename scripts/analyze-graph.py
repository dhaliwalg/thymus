#!/usr/bin/env python3
"""Analyze a module adjacency graph and infer architectural boundary rules.

Reads JSON from build-adjacency.py on stdin.  Applies four detection
algorithms (cluster/boundary, directionality, gateway, self-containment)
and outputs proposed YAML rules to stdout.

Usage:
    echo '<adjacency-json>' | python3 analyze-graph.py [--min-confidence 90]

Output: YAML rules matching the invariants.yml format.
"""
import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "lib"))
from utils import debug as _debug


def debug(msg):
    _debug("analyze-graph.py", msg)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def module_id_to_slug(module_id):
    """Convert a module id like 'src/routes' to 'src-routes' for use in rule IDs."""
    return module_id.replace("/", "-").replace("\\", "-")


def make_rule_id(module_slug, rule_type):
    """Create a deterministic rule ID."""
    return f"inferred-{module_slug}-{rule_type}"


# ---------------------------------------------------------------------------
# Common gateway filenames (without extension)
# ---------------------------------------------------------------------------
GATEWAY_NAMES = {"index", "__init__", "mod", "lib", "main", "exports", "public"}


def file_basename_stem(filepath):
    """Return the filename stem (no extension) from a path."""
    base = os.path.basename(filepath)
    dot = base.rfind(".")
    if dot > 0:
        return base[:dot]
    return base


# ---------------------------------------------------------------------------
# 1. Directionality Detection
# ---------------------------------------------------------------------------

def detect_directionality(modules, edges, min_confidence):
    """For each pair of modules (A, B), if A->B exists but B->A does not,
    and the edge has 2+ imports, propose a rule: B cannot import from A.
    Confidence = 100% (all existing imports follow this direction)."""
    rules = []

    # Build module lookup for file_count filtering
    mod_info = {m["id"]: m for m in modules}

    # Build edge set for fast lookup
    edge_set = {}
    for e in edges:
        edge_set[(e["from"], e["to"])] = e

    # Check each edge for unidirectionality
    for e in edges:
        from_mod = e["from"]
        to_mod = e["to"]
        import_count = len(e.get("imports", []))

        # Skip edges with fewer than 2 imports (not meaningful)
        if import_count < 2:
            continue

        # Skip if either module has 0 files (phantom modules)
        from_info = mod_info.get(from_mod)
        to_info = mod_info.get(to_mod)
        if not from_info or not to_info:
            continue
        if from_info.get("file_count", 0) == 0 or to_info.get("file_count", 0) == 0:
            continue

        # Check if reverse edge exists
        reverse_key = (to_mod, from_mod)
        if reverse_key in edge_set:
            continue  # Bidirectional — skip

        # Unidirectional: from_mod -> to_mod, but NOT to_mod -> from_mod
        confidence = 100.0
        if confidence < min_confidence:
            continue

        from_slug = module_id_to_slug(from_mod)
        to_slug = module_id_to_slug(to_mod)
        rule_id = make_rule_id(to_slug, "directionality")

        # Avoid duplicate rule IDs by appending the from module
        rule_id = f"inferred-{to_slug}-no-import-{from_slug}"

        rule = {
            "id": rule_id,
            "type": "boundary",
            "severity": "warning",
            "description": f"{from_mod} imports from {to_mod} but {to_mod} never imports from {from_mod}",
            "source_glob": f"{to_mod}/**",
            "forbidden_imports": [f"{from_mod}/**"],
            "inferred": True,
            "confidence": confidence,
        }
        rules.append(rule)

    return rules


# ---------------------------------------------------------------------------
# 2. Gateway Detection
# ---------------------------------------------------------------------------

def detect_gateway(modules, edges, min_confidence):
    """For each module that receives external imports, check if >90% of
    external imports target a single file.  If that file is a common
    gateway file, propose enforcing it."""
    rules = []
    mod_info = {m["id"]: m for m in modules}

    # Group incoming imports by target module
    # incoming[target_mod] = list of (source_file, target_import_specifier)
    incoming = {}
    for e in edges:
        to_mod = e["to"]
        if to_mod not in incoming:
            incoming[to_mod] = []
        for imp in e.get("imports", []):
            incoming[to_mod].append(imp)

    for mod_id, imp_list in incoming.items():
        info = mod_info.get(mod_id)
        if not info:
            continue
        # Skip modules with 0 or 1 file
        if info.get("file_count", 0) <= 1:
            continue

        if len(imp_list) < 2:
            continue

        # Count which target files are imported
        # The "target" field in imports is the raw import specifier;
        # we need to figure out which file within the module is targeted.
        # Since we don't have resolved paths, we use the import specifier
        # and extract the last path component as a proxy for the target file.
        target_file_counts = {}
        for imp in imp_list:
            target = imp.get("target", "")
            # Extract the last component of the import path
            parts = target.replace("\\", "/").split("/")
            leaf = parts[-1] if parts else target
            target_file_counts[leaf] = target_file_counts.get(leaf, 0) + 1

        if not target_file_counts:
            continue

        total_imports = len(imp_list)
        top_target = max(target_file_counts, key=target_file_counts.get)
        top_count = target_file_counts[top_target]
        pct = (top_count / total_imports) * 100.0

        # Check if the top target is a gateway file
        stem = file_basename_stem(top_target)
        if stem not in GATEWAY_NAMES:
            continue

        if pct < 90.0:
            continue

        confidence = round(pct, 1)
        if confidence < min_confidence:
            continue

        mod_slug = module_id_to_slug(mod_id)
        rule_id = make_rule_id(mod_slug, "gateway")

        rule = {
            "id": rule_id,
            "type": "boundary",
            "severity": "warning",
            "description": f"{pct:.0f}% of imports into {mod_id} go through {top_target} — enforce gateway pattern",
            "source_glob": f"**",
            "forbidden_imports": [f"{mod_id}/**"],
            "allowed_imports": [f"{mod_id}/{top_target}"],
            "inferred": True,
            "confidence": confidence,
        }
        rules.append(rule)

    return rules


# ---------------------------------------------------------------------------
# 3. Self-Containment Detection
# ---------------------------------------------------------------------------

def detect_self_containment(modules, edges, min_confidence):
    """For each module with outgoing edges to at most 1 other module,
    and the project has 3+ modules total, propose a boundary rule
    limiting its external imports."""
    rules = []
    if len(modules) < 3:
        return rules

    mod_info = {m["id"]: m for m in modules}

    # Count outgoing edges per module
    outgoing = {}  # mod_id -> set of target mod_ids
    for e in edges:
        from_mod = e["from"]
        if from_mod not in outgoing:
            outgoing[from_mod] = set()
        outgoing[from_mod].add(e["to"])

    for mod in modules:
        mod_id = mod["id"]
        if mod.get("file_count", 0) <= 1:
            continue
        if mod.get("file_count", 0) == 0:
            continue

        targets = outgoing.get(mod_id, set())
        if len(targets) > 1:
            continue

        # Module imports from 0 or 1 other module — self-contained
        confidence = 100.0
        if confidence < min_confidence:
            continue

        mod_slug = module_id_to_slug(mod_id)
        rule_id = make_rule_id(mod_slug, "self-contained")

        if len(targets) == 0:
            desc = f"{mod_id} has no external imports — enforce self-containment"
            rule = {
                "id": rule_id,
                "type": "boundary",
                "severity": "warning",
                "description": desc,
                "source_glob": f"{mod_id}/**",
                "forbidden_imports": ["**"],
                "allowed_imports": [f"{mod_id}/**"],
                "inferred": True,
                "confidence": confidence,
            }
        else:
            allowed_target = list(targets)[0]
            desc = f"{mod_id} only imports from {allowed_target} — enforce self-containment"
            rule = {
                "id": rule_id,
                "type": "boundary",
                "severity": "warning",
                "description": desc,
                "source_glob": f"{mod_id}/**",
                "forbidden_imports": ["**"],
                "allowed_imports": [f"{mod_id}/**", f"{allowed_target}/**"],
                "inferred": True,
                "confidence": confidence,
            }
        rules.append(rule)

    return rules


# ---------------------------------------------------------------------------
# 4. Cluster/Boundary Detection
# ---------------------------------------------------------------------------

def detect_cluster_boundary(modules, edges, min_confidence):
    """For each module, calculate what % of its total import relationships
    are internal vs external.  If a module only imports from 1-2 other
    modules (highly selective), propose a boundary rule."""
    rules = []
    if len(modules) < 3:
        return rules

    mod_info = {m["id"]: m for m in modules}

    # Count outgoing edge targets per module
    outgoing = {}  # mod_id -> set of target mod_ids
    for e in edges:
        from_mod = e["from"]
        if from_mod not in outgoing:
            outgoing[from_mod] = set()
        outgoing[from_mod].add(e["to"])

    # Count incoming edge sources per module
    incoming = {}  # mod_id -> set of source mod_ids
    for e in edges:
        to_mod = e["to"]
        if to_mod not in incoming:
            incoming[to_mod] = set()
        incoming[to_mod].add(e["from"])

    for mod in modules:
        mod_id = mod["id"]
        if mod.get("file_count", 0) <= 1:
            continue

        out_targets = outgoing.get(mod_id, set())
        in_sources = incoming.get(mod_id, set())

        total_connections = len(out_targets) + len(in_sources)
        if total_connections == 0:
            continue

        # Highly selective: imports from exactly 2 other modules
        # (1 is handled by self-containment, 0 is handled by self-containment)
        if len(out_targets) != 2:
            continue

        # Confidence: 100% if the module currently follows this pattern perfectly
        confidence = 100.0
        if confidence < min_confidence:
            continue

        mod_slug = module_id_to_slug(mod_id)
        rule_id = make_rule_id(mod_slug, "selective-deps")

        allowed = sorted(out_targets)
        desc = (f"{mod_id} only imports from {allowed[0]} and {allowed[1]}"
                f" — enforce selective dependencies")

        rule = {
            "id": rule_id,
            "type": "boundary",
            "severity": "warning",
            "description": desc,
            "source_glob": f"{mod_id}/**",
            "forbidden_imports": ["**"],
            "allowed_imports": [f"{mod_id}/**"] + [f"{t}/**" for t in allowed],
            "inferred": True,
            "confidence": confidence,
        }
        rules.append(rule)

    return rules


# ---------------------------------------------------------------------------
# Deduplication
# ---------------------------------------------------------------------------

def deduplicate_rules(rules):
    """Remove duplicate rules with the same source_glob + forbidden_imports."""
    seen = set()
    unique = []
    for rule in rules:
        key = (
            rule.get("source_glob", ""),
            tuple(sorted(rule.get("forbidden_imports", []))),
        )
        if key in seen:
            continue
        seen.add(key)
        unique.append(rule)
    return unique


# ---------------------------------------------------------------------------
# YAML output
# ---------------------------------------------------------------------------

def emit_yaml(rules, min_confidence):
    """Emit rules as YAML matching the invariants.yml format.

    Uses 2-space indent for '- id:', 4-space for fields, 6-space for list items.
    """
    lines = []
    lines.append("# Auto-inferred rules (thymus infer)")
    lines.append(f"# Min confidence: {min_confidence}%")
    lines.append("# Review before applying")
    lines.append("")

    for rule in rules:
        lines.append(f"  - id: {rule['id']}")
        lines.append(f"    type: {rule['type']}")
        lines.append(f"    severity: {rule['severity']}")
        lines.append(f'    description: "{rule["description"]}"')
        if "source_glob" in rule:
            lines.append(f'    source_glob: "{rule["source_glob"]}"')
        if "forbidden_imports" in rule:
            lines.append("    forbidden_imports:")
            for imp in rule["forbidden_imports"]:
                lines.append(f'      - "{imp}"')
        if "allowed_imports" in rule:
            lines.append("    allowed_imports:")
            for imp in rule["allowed_imports"]:
                lines.append(f'      - "{imp}"')
        lines.append(f"    inferred: {str(rule.get('inferred', True)).lower()}")
        conf = rule.get("confidence", 0)
        # Format as integer if whole number, else 1 decimal
        if conf == int(conf):
            lines.append(f"    confidence: {int(conf)}")
        else:
            lines.append(f"    confidence: {conf}")

    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    min_confidence = 90

    # Parse --min-confidence flag
    args = sys.argv[1:]
    i = 0
    while i < len(args):
        if args[i] == "--min-confidence" and i + 1 < len(args):
            try:
                min_confidence = int(args[i + 1])
            except ValueError:
                debug(f"Invalid --min-confidence value: {args[i + 1]}")
                print(f"Error: --min-confidence must be an integer", file=sys.stderr)
                sys.exit(1)
            i += 2
        else:
            i += 1

    debug(f"starting, min_confidence={min_confidence}")

    # Read stdin
    raw = sys.stdin.read().strip()
    if not raw:
        debug("empty input, exiting")
        # Output empty YAML header
        print("# Auto-inferred rules (thymus infer)")
        print(f"# Min confidence: {min_confidence}%")
        print("# Review before applying")
        print("# No modules found — nothing to infer")
        return

    try:
        data = json.loads(raw)
    except json.JSONDecodeError as e:
        debug(f"JSON parse error: {e}")
        print(f"Error: invalid JSON on stdin: {e}", file=sys.stderr)
        sys.exit(1)

    modules = data.get("modules", [])
    edges = data.get("edges", [])

    if not isinstance(modules, list):
        modules = []
    if not isinstance(edges, list):
        edges = []

    # Filter out phantom modules (file_count == 0) and single-file modules
    valid_modules = [m for m in modules if m.get("file_count", 0) >= 2]

    debug(f"loaded {len(modules)} modules ({len(valid_modules)} valid), {len(edges)} edges")

    if not valid_modules:
        debug("no valid modules, exiting")
        print("# Auto-inferred rules (thymus infer)")
        print(f"# Min confidence: {min_confidence}%")
        print("# Review before applying")
        print("# No multi-file modules found — nothing to infer")
        return

    # Run all detection algorithms
    all_rules = []

    dir_rules = detect_directionality(modules, edges, min_confidence)
    debug(f"directionality: {len(dir_rules)} rules")
    all_rules.extend(dir_rules)

    gw_rules = detect_gateway(modules, edges, min_confidence)
    debug(f"gateway: {len(gw_rules)} rules")
    all_rules.extend(gw_rules)

    sc_rules = detect_self_containment(modules, edges, min_confidence)
    debug(f"self-containment: {len(sc_rules)} rules")
    all_rules.extend(sc_rules)

    cb_rules = detect_cluster_boundary(modules, edges, min_confidence)
    debug(f"cluster/boundary: {len(cb_rules)} rules")
    all_rules.extend(cb_rules)

    # Deduplicate
    all_rules = deduplicate_rules(all_rules)
    debug(f"total after dedup: {len(all_rules)} rules")

    if not all_rules:
        print("# Auto-inferred rules (thymus infer)")
        print(f"# Min confidence: {min_confidence}%")
        print("# Review before applying")
        print("# No rules inferred at this confidence level")
        return

    # Output YAML
    yaml_out = emit_yaml(all_rules, min_confidence)
    sys.stdout.write(yaml_out)

    debug(f"done: emitted {len(all_rules)} rules")


if __name__ == "__main__":
    main()
