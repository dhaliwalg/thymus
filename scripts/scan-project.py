#!/usr/bin/env python3
"""Thymus scan-project.py — batch invariant checker.

Usage: python3 scan-project.py [scope_path] [--diff]
Output: JSON { scope, files_checked, violations, stats }

Replaces scan-project.sh with zero subprocess overhead.
Python 3 stdlib only. No pip dependencies.
"""

import json
import os
import subprocess
import sys

# Add lib/ to path
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), 'lib'))
from core import debug_log, thymus_cache_dir, load_invariants, find_source_files
from rules import eval_rule_for_file


def main():
    # --- Parse args: [scope_path] [--diff] ---
    scope = ""
    diff_mode = False
    for arg in sys.argv[1:]:
        if arg == "--diff":
            diff_mode = True
        elif not scope:
            scope = arg

    # Normalize scope: strip trailing slash, make relative to PWD if absolute
    if scope:
        scope = scope.rstrip("/")
        cwd = os.getcwd()
        if scope.startswith(cwd):
            scope = scope[len(cwd):]
            scope = scope.lstrip("/")

    debug_log(f"scan-project.py: scope={scope or 'full'} diff={diff_mode}")

    # --- Check for invariants.yml ---
    thymus_dir = os.path.join(os.getcwd(), ".thymus")
    invariants_yml = os.path.join(thymus_dir, "invariants.yml")

    if not os.path.isfile(invariants_yml):
        json.dump({
            "error": "No invariants.yml found. Run /thymus:baseline first.",
            "violations": [],
            "stats": {"total": 0, "errors": 0, "warnings": 0}
        }, sys.stdout)
        print()
        sys.exit(0)

    # --- Load invariants ONCE ---
    cache_dir = thymus_cache_dir()
    cache_path = os.path.join(cache_dir, "invariants-scan.json")

    try:
        invariants_data = load_invariants(invariants_yml, cache_path)
    except Exception:
        json.dump({
            "error": "Failed to parse invariants.yml",
            "violations": [],
            "stats": {"total": 0, "errors": 0, "warnings": 0}
        }, sys.stdout)
        print()
        sys.exit(0)

    invariants = invariants_data.get("invariants", [])

    # --- Build file list ---
    cwd = os.getcwd()
    files = []

    if diff_mode:
        try:
            result = subprocess.run(
                ["git", "diff", "--name-only", "HEAD"],
                capture_output=True, text=True, timeout=10
            )
            for f in result.stdout.splitlines():
                f = f.strip()
                if not f:
                    continue
                if scope and not f.startswith(scope):
                    continue
                files.append(f)
        except Exception:
            pass
    else:
        scan_root = cwd
        if scope:
            scan_root = os.path.join(cwd, scope)
        raw_files = find_source_files(scan_root)
        for f in raw_files:
            if not f:
                continue
            # find_source_files returns paths relative to scan_root;
            # prefix with scope so paths are relative to PWD
            if scope:
                f = scope + "/" + f
            files.append(f)

    files_checked = len(files)
    debug_log(f"scan-project: checking {files_checked} files")

    if files_checked == 0:
        json.dump({
            "scope": scope,
            "files_checked": 0,
            "violations": [],
            "stats": {"total": 0, "errors": 0, "warnings": 0}
        }, sys.stdout)
        print()
        sys.exit(0)

    # --- Evaluate rules ---
    violations = []

    for rel_path in files:
        abs_path = os.path.join(cwd, rel_path)
        if not os.path.isfile(abs_path):
            continue

        for inv in invariants:
            viols = eval_rule_for_file(abs_path, rel_path, inv)
            violations.extend(viols)

    # --- Count stats in one pass ---
    total = len(violations)
    errors = sum(1 for v in violations if v.get("severity") == "error")
    warnings = sum(1 for v in violations if v.get("severity") == "warning")

    # --- Output JSON ---
    output = {
        "scope": scope,
        "files_checked": files_checked,
        "violations": violations,
        "stats": {
            "total": total,
            "errors": errors,
            "warnings": warnings
        }
    }
    json.dump(output, sys.stdout)
    print()


if __name__ == "__main__":
    main()
