#!/usr/bin/env python3
"""Thymus analyze-edit.py — PostToolUse hook.

Reads JSON from stdin, checks the edited file against invariants,
outputs JSON with systemMessage to stdout if violations are found.

CRITICAL: Never exits with code 2 — exit 0 or exit 1 only.
Exit code 2 blocks Claude Code tool execution.

Python 3 stdlib only. No pip dependencies.
"""

import json
import os
import sys

# Add lib/ to path
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), 'lib'))
from core import debug_log, thymus_cache_dir, load_invariants
from rules import eval_rule_for_file

# Text file extensions — files with these extensions are always treated as text
_TEXT_EXTENSIONS = {
    '.ts', '.tsx', '.js', '.jsx', '.mjs', '.cjs',
    '.py', '.pyi', '.pyw',
    '.java', '.go', '.rs', '.dart', '.kt', '.kts', '.swift', '.cs', '.php', '.rb',
    '.json', '.jsonl', '.yaml', '.yml', '.toml', '.xml', '.html', '.htm',
    '.css', '.scss', '.sass', '.less',
    '.md', '.mdx', '.txt', '.rst', '.tex',
    '.sh', '.bash', '.zsh', '.fish', '.bat', '.cmd', '.ps1',
    '.sql', '.graphql', '.gql',
    '.c', '.h', '.cpp', '.hpp', '.cc', '.hh', '.cxx', '.hxx',
    '.m', '.mm',  # Objective-C
    '.r', '.R',
    '.lua', '.vim', '.el', '.ex', '.exs', '.erl', '.hrl',
    '.hs', '.lhs', '.ml', '.mli', '.fs', '.fsi', '.fsx',
    '.scala', '.sbt', '.clj', '.cljs', '.cljc',
    '.tf', '.tfvars', '.hcl',
    '.dockerfile', '.makefile',
    '.env', '.ini', '.cfg', '.conf', '.properties',
    '.csv', '.tsv',
    '.gitignore', '.gitattributes', '.editorconfig',
}

# Binary-like extensions to skip
_BINARY_EXTENSIONS = {
    '.png', '.jpg', '.jpeg', '.gif', '.bmp', '.ico', '.svg', '.webp',
    '.pdf', '.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx',
    '.zip', '.tar', '.gz', '.bz2', '.xz', '.7z', '.rar',
    '.exe', '.dll', '.so', '.dylib', '.a', '.o', '.obj',
    '.wasm', '.class', '.pyc', '.pyo',
    '.mp3', '.mp4', '.wav', '.avi', '.mkv', '.mov',
    '.woff', '.woff2', '.ttf', '.otf', '.eot',
    '.lock', '.min.js', '.min.css',
}


def _is_text_file(filepath):
    """Check if a file is likely a text file using extension heuristics.

    Returns True for text files, False for binary/unknown files.
    Uses extension-based heuristics to avoid subprocess calls to `file`.
    """
    _, ext = os.path.splitext(filepath)
    ext_lower = ext.lower()

    # Check known text extensions
    if ext_lower in _TEXT_EXTENSIONS:
        return True

    # Check known binary extensions
    if ext_lower in _BINARY_EXTENSIONS:
        return False

    # Check files with no extension by basename
    basename = os.path.basename(filepath).lower()
    if basename in ('makefile', 'dockerfile', 'rakefile', 'gemfile',
                    'procfile', 'brewfile', 'vagrantfile',
                    'license', 'licence', 'readme', 'changelog',
                    'authors', 'contributors', 'todo', 'news'):
        return True

    # If extension-based check is inconclusive, try reading a small chunk
    try:
        with open(filepath, 'rb') as f:
            chunk = f.read(512)
        # If there's a null byte, it's likely binary
        if b'\x00' in chunk:
            return False
        return True
    except OSError:
        return False


def main():
    try:
        # --- Read stdin ---
        raw_input = sys.stdin.read()
        try:
            data = json.loads(raw_input)
        except (json.JSONDecodeError, ValueError):
            sys.exit(0)

        file_path = ""
        tool_name = "unknown"
        try:
            file_path = data.get("tool_input", {}).get("file_path", "") or ""
            tool_name = data.get("tool_name", "unknown") or "unknown"
        except (AttributeError, TypeError):
            pass

        debug_log(f"analyze-edit.py: {tool_name} on {file_path or 'unknown'}")

        # --- Early exits ---
        if not file_path:
            sys.exit(0)

        if os.path.islink(file_path):
            sys.exit(0)

        # Check text file (skip binary)
        if os.path.isfile(file_path):
            if not _is_text_file(file_path):
                sys.exit(0)

        # Check file size (skip >512KB)
        if os.path.isfile(file_path):
            try:
                file_size = os.path.getsize(file_path)
                if file_size > 512000:
                    sys.exit(0)
            except OSError:
                pass

        # --- Load invariants ---
        cwd = os.getcwd()
        thymus_dir = os.path.join(cwd, ".thymus")
        invariants_yml = os.path.join(thymus_dir, "invariants.yml")

        if not os.path.isfile(invariants_yml):
            sys.exit(0)

        cache_dir = thymus_cache_dir()
        session_violations_path = os.path.join(cache_dir, "session-violations.json")

        # Initialize session-violations.json if missing
        if not os.path.isfile(session_violations_path):
            with open(session_violations_path, "w") as f:
                json.dump([], f)

        cache_path = os.path.join(cache_dir, "invariants.json")
        try:
            invariants_data = load_invariants(invariants_yml, cache_path)
        except Exception:
            sys.exit(0)

        invariants = invariants_data.get("invariants", [])

        # --- Compute relative path ---
        # Use os.path.realpath to resolve symlinks (macOS: /var -> /private/var)
        # so that prefix comparison works even when cwd and file_path differ
        real_cwd = os.path.realpath(cwd)
        real_file = os.path.realpath(file_path) if os.path.isabs(file_path) else file_path
        rel_path = file_path
        if real_file.startswith(real_cwd + "/"):
            rel_path = real_file[len(real_cwd) + 1:]
        elif file_path.startswith(cwd + "/"):
            rel_path = file_path[len(cwd) + 1:]
        elif not file_path.startswith("/"):
            # Already relative
            pass
        else:
            # Absolute path not under cwd — use os.path.relpath as fallback
            try:
                rel_path = os.path.relpath(real_file, real_cwd)
                if rel_path.startswith("../"):
                    rel_path = os.path.basename(file_path)
            except ValueError:
                rel_path = os.path.basename(file_path)

        debug_log(f"checking {rel_path}")

        # --- Evaluate all rules ---
        violation_lines = []
        new_violation_objects = []

        for inv in invariants:
            rule_id = inv.get("id", "")
            debug_log(f"  rule {rule_id} ({inv.get('type', '')}) vs {rel_path}")

            viols = eval_rule_for_file(file_path, rel_path, inv)
            for viol in viols:
                severity = viol.get("severity", "")
                sev_upper = severity.upper()

                # Build detail suffix
                if viol.get("import"):
                    msg_detail = f"(import: {viol['import']})"
                elif viol.get("line"):
                    msg_detail = f"(line {viol['line']})"
                elif viol.get("package"):
                    msg_detail = f"(package: {viol['package']})"
                else:
                    msg_detail = ""

                description = viol.get("message", "")
                msg = f"[{sev_upper}] {rule_id}: {description} {msg_detail}"
                violation_lines.append(msg)
                new_violation_objects.append(viol)

        debug_log(f"found {len(violation_lines)} violations in {rel_path}")

        # --- Calibration: track fix/ignore events ---
        calibration_file = os.path.join(thymus_dir, "calibration.json")
        if not os.path.isfile(calibration_file):
            try:
                with open(calibration_file, "w") as f:
                    json.dump({"rules": {}}, f)
            except OSError:
                pass

        # Load previous session violations for this file
        prev_rules = set()
        try:
            with open(session_violations_path) as f:
                session_viols = json.load(f)
            for sv in session_viols:
                if sv.get("file") == rel_path:
                    prev_rules.add(sv.get("rule", ""))
            prev_rules.discard("")
        except (json.JSONDecodeError, OSError):
            session_viols = []

        # Current rules that are violated
        curr_rules = set()
        for vo in new_violation_objects:
            r = vo.get("rule", "")
            if r:
                curr_rules.add(r)

        # Compute calibration events
        cal_events = []
        for prev_rule in prev_rules:
            if prev_rule in curr_rules:
                cal_events.append((prev_rule, "ignored"))
            else:
                cal_events.append((prev_rule, "fixed"))

        # Apply calibration events
        if cal_events:
            try:
                with open(calibration_file) as f:
                    cal_data = json.load(f)
                rules_map = cal_data.setdefault("rules", {})
                for rule, event in cal_events:
                    r = rules_map.setdefault(rule, {"fixed": 0, "ignored": 0})
                    r[event] = r.get(event, 0) + 1
                with open(calibration_file, "w") as f:
                    json.dump(cal_data, f)
            except (json.JSONDecodeError, OSError):
                pass

        # --- No violations → exit silently ---
        if not violation_lines:
            sys.exit(0)

        # --- Append new violations to session cache ---
        try:
            with open(session_violations_path) as f:
                session_viols = json.load(f)
        except (json.JSONDecodeError, OSError):
            session_viols = []

        session_viols.extend(new_violation_objects)
        try:
            with open(session_violations_path, "w") as f:
                json.dump(session_viols, f)
        except OSError:
            pass

        # --- Build output message ---
        msg_body = f"thymus: {len(violation_lines)} violation(s) in {rel_path}\\n"
        for line in violation_lines:
            msg_body += f"  {line}\\n"

        output = {"systemMessage": msg_body}
        json.dump(output, sys.stdout)
        print()

    except SystemExit:
        raise
    except Exception as e:
        # CRITICAL: never exit with code 2
        debug_log(f"analyze-edit.py fatal error: {e}")
        sys.exit(0)


if __name__ == "__main__":
    main()
