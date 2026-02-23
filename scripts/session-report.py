#!/usr/bin/env python3
"""Thymus session-report.py -- Stop hook: session summary + history snapshot.

Reads JSON from stdin (session_id). Checks session violations cache.
Builds summary message. Appends history entry IN-PROCESS (no subprocess).
Checks history.jsonl for repeated rules (>=3 times), suggests CLAUDE.md additions.

Output: {"systemMessage": "thymus: N violation(s)..."} or
        {"systemMessage": "thymus: no edits this session"}

Python 3 stdlib only. No pip dependencies.
"""

import json
import os
import sys

# Add lib/ to path
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), 'lib'))
from core import debug_log, thymus_cache_dir

# Import append-history functions IN-PROCESS
from importlib.util import spec_from_file_location, module_from_spec
_append_history_mod = None


def _get_append_history_mod():
    """Lazy-load append-history.py module."""
    global _append_history_mod
    if _append_history_mod is not None:
        return _append_history_mod
    scripts_dir = os.path.dirname(os.path.abspath(__file__))
    path = os.path.join(scripts_dir, "append-history.py")
    spec = spec_from_file_location("append_history", path)
    mod = module_from_spec(spec)
    spec.loader.exec_module(mod)
    _append_history_mod = mod
    return mod


def main():
    thymus_dir = os.path.join(os.getcwd(), ".thymus")

    raw_input = sys.stdin.read()
    try:
        input_data = json.loads(raw_input)
    except (json.JSONDecodeError, ValueError):
        input_data = {}

    session_id = input_data.get("session_id", "unknown")
    debug_log(f"session-report.py: session {session_id} ended")

    # Require baseline
    baseline_path = os.path.join(thymus_dir, "baseline.json")
    if not os.path.isfile(baseline_path):
        sys.exit(0)

    cache_dir = thymus_cache_dir()
    session_violations_path = os.path.join(cache_dir, "session-violations.json")

    if not os.path.isfile(session_violations_path):
        json.dump({"systemMessage": "thymus: no edits this session"}, sys.stdout)
        print()
        sys.exit(0)

    # Read session violations
    try:
        with open(session_violations_path) as f:
            session_viols = json.load(f)
    except (json.JSONDecodeError, OSError):
        session_viols = []

    total = len(session_viols)
    errors = sum(1 for v in session_viols if v.get("severity") == "error")
    warnings = sum(1 for v in session_viols if v.get("severity") == "warning")

    debug_log(f"session-report: {total} total, {errors} errors, {warnings} warnings")

    # Build scan-compatible JSON for history append (IN-PROCESS)
    unique_files = list(set(v.get("file", "") for v in session_viols))
    scan_json = {
        "files_checked": len(unique_files),
        "violations": session_viols,
        "stats": {"total": total, "errors": errors, "warnings": warnings},
    }

    ah = _get_append_history_mod()
    entry = ah.build_history_entry(scan_json)
    ah.append_history(entry, thymus_dir)

    # Build summary
    if total == 0:
        summary = "thymus: clean session"
    else:
        parts = []
        if errors > 0:
            parts.append(f"{errors} error(s)")
        if warnings > 0:
            parts.append(f"{warnings} warning(s)")
        violation_summary = ", ".join(parts)
        rules = sorted(set(v.get("rule", "") for v in session_viols if v.get("rule")))
        rules_str = ", ".join(rules)
        summary = f"thymus: {total} violation(s) \u2014 {violation_summary} | rules: {rules_str} | run /thymus:scan for details"

    # Check for repeated rules in history
    suggestion = ""
    history_file = os.path.join(thymus_dir, "history.jsonl")
    if os.path.isfile(history_file):
        try:
            with open(history_file) as f:
                history_lines = f.readlines()

            # Aggregate by_rule counts across all history entries
            rule_counts = {}
            for line in history_lines:
                line = line.strip()
                if not line:
                    continue
                try:
                    entry_data = json.loads(line)
                    by_rule = entry_data.get("by_rule", {})
                    for rule, count in by_rule.items():
                        rule_counts[rule] = rule_counts.get(rule, 0) + count
                except (json.JSONDecodeError, ValueError):
                    continue

            # Find rules that have fired >= 3 times total
            repeat_rules = [r for r, c in rule_counts.items() if c >= 3]
            if repeat_rules:
                repeat_str = ", ".join(sorted(repeat_rules))
                suggestion = (
                    f"\n\nCLAUDE.md tip: [{repeat_str}] has fired 3+ times "
                    f"\u2014 consider adding to CLAUDE.md:\n"
                    f"  'always run /thymus:scan before committing'"
                )
        except OSError:
            pass

    msg = summary + suggestion
    json.dump({"systemMessage": msg}, sys.stdout)
    print()

    # Clean up session violations
    try:
        os.unlink(session_violations_path)
    except OSError:
        pass


if __name__ == "__main__":
    main()
