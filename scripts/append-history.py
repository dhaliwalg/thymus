#!/usr/bin/env python3
"""Thymus append-history.py -- atomic JSONL history append.

Usage:
  python3 append-history.py --scan /path/to/scan.json
  echo '<scan-json>' | python3 append-history.py --stdin

Builds a JSONL entry from scan data, atomically appends to
.thymus/history.jsonl with FIFO cap at 500 entries.

Only subprocess: git rev-parse --short HEAD for commit hash.

Python 3 stdlib only. No pip dependencies.
"""

import datetime
import json
import os
import subprocess
import sys
import tempfile

# Add lib/ to path
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), 'lib'))
from core import debug_log

FIFO_CAP = 500


def get_git_commit():
    """Get short git commit hash, or 'unknown' if not in a git repo."""
    try:
        result = subprocess.run(
            ["git", "rev-parse", "--short", "HEAD"],
            capture_output=True, text=True, timeout=5
        )
        if result.returncode == 0:
            return result.stdout.strip()
    except Exception:
        pass
    return "unknown"


def build_history_entry(scan_json):
    """Build a JSONL history entry dict from scan JSON data."""
    timestamp = datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")

    files_checked = scan_json.get("files_checked", 0)
    violations = scan_json.get("violations", [])

    error_count = sum(1 for v in violations if v.get("severity") == "error")
    warn_count = sum(1 for v in violations if v.get("severity") == "warning")
    info_count = sum(1 for v in violations if v.get("severity") == "info")

    # Compliance score: ((files_checked - error_count) / files_checked) * 100
    if files_checked == 0:
        compliance_score = 100.0
    else:
        compliance_score = round(((files_checked - error_count) / files_checked) * 100, 1)

    # Per-rule violation counts
    by_rule = {}
    for v in violations:
        rule = v.get("rule", "")
        if rule:
            by_rule[rule] = by_rule.get(rule, 0) + 1

    commit = get_git_commit()

    entry = {
        "timestamp": timestamp,
        "commit": commit,
        "total_files": files_checked,
        "files_checked": files_checked,
        "violations": {
            "error": error_count,
            "warn": warn_count,
            "info": info_count,
        },
        "compliance_score": compliance_score,
        "by_rule": by_rule,
    }

    debug_log(f"append-history: compliance={compliance_score} commit={commit}")
    return entry


def append_history(entry, thymus_dir=None):
    """Atomically append entry to history.jsonl with FIFO cap."""
    if thymus_dir is None:
        thymus_dir = os.path.join(os.getcwd(), ".thymus")

    os.makedirs(thymus_dir, exist_ok=True)
    history_file = os.path.join(thymus_dir, "history.jsonl")

    jsonl_line = json.dumps(entry, separators=(",", ":"))

    # Read existing entries
    existing_lines = []
    if os.path.isfile(history_file):
        with open(history_file, "r") as f:
            existing_lines = [line.rstrip("\n") for line in f if line.strip()]

    # Append new line and apply FIFO cap
    existing_lines.append(jsonl_line)
    if len(existing_lines) > FIFO_CAP:
        existing_lines = existing_lines[-FIFO_CAP:]

    # Atomic write: write to temp file, then rename
    fd, tmp_path = tempfile.mkstemp(
        prefix=".history.jsonl.", dir=thymus_dir
    )
    try:
        with os.fdopen(fd, "w") as f:
            for line in existing_lines:
                f.write(line + "\n")
        os.replace(tmp_path, history_file)
    except Exception:
        # Clean up temp file on error
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise

    debug_log(f"append-history: appended (total entries: {len(existing_lines)})")


def main():
    timestamp = datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
    debug_log("append-history.py: start")

    # Parse arguments
    mode = ""
    scan_file = ""
    args = sys.argv[1:]
    i = 0
    while i < len(args):
        if args[i] == "--stdin":
            mode = "stdin"
        elif args[i] == "--scan":
            mode = "scan"
            if i + 1 < len(args):
                scan_file = args[i + 1]
                i += 1
        i += 1

    if not mode:
        print("Usage: append-history.py --scan <file> | --stdin", file=sys.stderr)
        sys.exit(1)

    # Read scan JSON
    if mode == "stdin":
        raw = sys.stdin.read()
    elif mode == "scan":
        if not scan_file or not os.path.isfile(scan_file):
            print(f"append-history.py: scan file not found: {scan_file or '<none>'}",
                  file=sys.stderr)
            sys.exit(1)
        with open(scan_file) as f:
            raw = f.read()
    else:
        print("append-history.py: unknown mode", file=sys.stderr)
        sys.exit(1)

    debug_log(f"append-history.py: read scan JSON ({len(raw)} bytes)")

    scan_json = json.loads(raw)
    entry = build_history_entry(scan_json)
    append_history(entry)


if __name__ == "__main__":
    main()
