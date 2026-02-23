#!/usr/bin/env python3
"""Thymus load-baseline.py -- SessionStart hook: inject baseline summary.

Auto-adds .thymus/ to .gitignore if git repo and not already ignored.
Reads baseline.json, counts invariants, reads last history entry.

Output: {"systemMessage": "thymus: N modules | M invariants active | ..."}
If no baseline: {"systemMessage": "thymus: no baseline found -- run /thymus:baseline to initialize"}

CRITICAL: Never exits with code 2 — exit 0 or exit 1 only.
Exit code 2 blocks Claude Code tool execution.

Python 3 stdlib only. No pip dependencies.
"""

import json
import os
import re
import sys

# Add lib/ to path
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), 'lib'))
from core import debug_log


def main():
    try:
        cwd = os.getcwd()
        thymus_dir = os.path.join(cwd, ".thymus")
        baseline_path = os.path.join(thymus_dir, "baseline.json")

        debug_log(f"load-baseline.py fired in {cwd}")

        # Auto-add .thymus/ to .gitignore if it's a git repo and not already ignored
        if os.path.isdir(thymus_dir) and os.path.isdir(os.path.join(cwd, ".git")):
            gitignore_path = os.path.join(cwd, ".gitignore")
            already_ignored = False
            if os.path.isfile(gitignore_path):
                try:
                    with open(gitignore_path) as f:
                        for line in f:
                            if re.match(r'^\.thymus/?$', line.strip()):
                                already_ignored = True
                                break
                except OSError:
                    pass

            if not already_ignored:
                try:
                    with open(gitignore_path, "a") as f:
                        f.write(".thymus/\n")
                    debug_log("added .thymus/ to .gitignore")
                except OSError:
                    pass

        # Check for baseline
        if not os.path.isfile(baseline_path):
            json.dump(
                {"systemMessage": "thymus: no baseline found \u2014 run /thymus:baseline to initialize"},
                sys.stdout,
            )
            print()
            sys.exit(0)

        # Read baseline
        module_count = 0
        try:
            with open(baseline_path) as f:
                baseline = json.load(f)
            module_count = len(baseline.get("modules", []))
        except (json.JSONDecodeError, OSError):
            pass

        # Count invariants (lines matching ^  - id: in invariants.yml)
        invariant_count = 0
        invariants_yml = os.path.join(thymus_dir, "invariants.yml")
        if os.path.isfile(invariants_yml):
            try:
                with open(invariants_yml) as f:
                    for line in f:
                        if re.match(r'^  - id:', line):
                            invariant_count += 1
            except OSError:
                pass

        # Read last history entry for recent violations
        recent_violations = 0
        history_file = os.path.join(thymus_dir, "history.jsonl")
        if os.path.isfile(history_file):
            try:
                last_line = ""
                with open(history_file) as f:
                    for line in f:
                        if line.strip():
                            last_line = line.strip()
                if last_line:
                    last_entry = json.loads(last_line)
                    recent_violations = last_entry.get("violations", {}).get("error", 0)
            except (json.JSONDecodeError, OSError):
                pass

        debug_log(
            f"baseline: {module_count} modules, {invariant_count} invariants, "
            f"{recent_violations} recent violations"
        )

        msg = f"thymus: {module_count} modules | {invariant_count} invariants active"
        if recent_violations > 0:
            msg += f" | {recent_violations} violation(s) last session"
        msg += " | /thymus:health for full report"

        json.dump({"systemMessage": msg}, sys.stdout)
        print()

    except SystemExit:
        raise
    except Exception as e:
        debug_log(f"load-baseline.py fatal error: {e}")
        sys.exit(0)


if __name__ == "__main__":
    main()
