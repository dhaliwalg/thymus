#!/usr/bin/env python3
"""Thymus detect-patterns.py

Scans a project directory and outputs structural data as JSON.
Replaces detect-patterns.sh with a single os.walk pass for all 5 metrics.

Usage: python3 detect-patterns.py [project_root]
Output: JSON to stdout

Python 3 stdlib only. No pip dependencies.
"""

import collections
import json
import os
import re
import sys

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

IGNORED_PATHS = {
    "node_modules", "dist", ".next", ".git", "coverage",
    "__pycache__", ".venv", "vendor", "target", "build", ".thymus",
}

SOURCE_EXTENSIONS = {".ts", ".js", ".py", ".java", ".go", ".rs"}

# Files to skip when checking for test gaps
TEST_FILE_PATTERNS = re.compile(
    r'\.test\.[^.]+$|\.spec\.[^.]+$|\.d\.ts$'
    r'|Test\.java$|Tests\.java$|IT\.java$|Spec\.java$'
)

# Multi-part extension pattern (e.g., .service.ts, .model.py)
MULTI_EXT_RE = re.compile(r'\.[a-zA-Z]+\.[a-z]+$')

KNOWN_LAYERS = {
    "routes", "controllers", "controller", "services", "service",
    "repositories", "repository", "models", "model", "middleware",
    "utils", "util", "lib", "helpers", "types", "handlers", "resolvers",
    "stores", "hooks", "components", "pages", "app", "api", "db",
    "database", "config", "auth", "tests", "test", "__tests__",
    "entity", "entities", "dto", "converter", "mapper", "filter",
    "interceptor", "domain", "infrastructure", "adapter", "port",
    "presenter", "exception", "exceptions",
}

# Ordered list to preserve output order from the bash version
KNOWN_LAYERS_ORDERED = [
    "routes", "controllers", "controller", "services", "service",
    "repositories", "repository", "models", "model", "middleware",
    "utils", "util", "lib", "helpers", "types", "handlers", "resolvers",
    "stores", "hooks", "components", "pages", "app", "api", "db",
    "database", "config", "auth", "tests", "test", "__tests__",
    "entity", "entities", "dto", "converter", "mapper", "filter",
    "interceptor", "domain", "infrastructure", "adapter", "port",
    "presenter", "exception", "exceptions",
]

DEBUG_LOG = "/tmp/thymus-debug.log"


# ---------------------------------------------------------------------------
# Debug logging
# ---------------------------------------------------------------------------

def debug_log(msg: str) -> None:
    import datetime
    ts = datetime.datetime.now().strftime("%Y-%m-%dT%H:%M:%S")
    try:
        with open(DEBUG_LOG, "a") as f:
            f.write(f"[{ts}] detect-patterns.py: {msg}\n")
    except OSError:
        pass


# ---------------------------------------------------------------------------
# Test gap checking
# ---------------------------------------------------------------------------

def _has_colocated_test(filepath: str, ext: str, all_files_in_dir: set) -> bool:
    """Check if a source file has a colocated test file.

    Replicates the bash logic exactly:
    - For all files: check for base.test.ext and base.spec.ext
    - For Java: also check for BaseTest.java, BaseTests.java, BaseIT.java
      plus the src/main/java -> src/test/java mirror.
    """
    base = filepath[:-(len(ext) + 1)]  # strip .ext
    basename_no_ext = os.path.basename(base)
    dirpath = os.path.dirname(filepath)

    # Standard test file patterns
    if f"{base}.test.{ext}" in all_files_in_dir or f"{base}.spec.{ext}" in all_files_in_dir:
        return True

    # Java-specific patterns
    if ext == "java":
        for suffix in ("Test.java", "Tests.java", "IT.java"):
            if os.path.join(dirpath, f"{basename_no_ext}{suffix}") in all_files_in_dir:
                return True
        # src/main/java -> src/test/java mirror
        if "/src/main/java/" in filepath:
            test_mirror_base = filepath.replace("src/main/java", "src/test/java")
            test_mirror_base = test_mirror_base[:-(len("java") + 1)]  # strip .java
            test_mirror_dir = os.path.dirname(test_mirror_base)
            test_mirror_name = os.path.basename(test_mirror_base)
            for suffix in ("Test.java", "Tests.java", "IT.java"):
                if os.path.isfile(os.path.join(test_mirror_dir, f"{test_mirror_name}{suffix}")):
                    return True

    return False


# ---------------------------------------------------------------------------
# Main scan
# ---------------------------------------------------------------------------

def scan(project_root: str) -> dict:
    """Perform a single os.walk pass computing all 5 metrics."""
    project_root = os.path.abspath(project_root)

    # Accumulators
    raw_structure = []          # dir paths relative to root, depth <= 3
    detected_layers_set = set() # layer directory names found
    naming_counter = collections.Counter()  # multi-part extension counts
    source_files = []           # (abs_path, rel_path, ext) for test gap analysis
    top_level_counts = collections.Counter()  # file counts per top-level dir
    all_files = set()           # all absolute file paths (for test gap lookup)

    for dirpath, dirnames, filenames in os.walk(project_root):
        # Prune ignored directories
        dirnames[:] = sorted(d for d in dirnames if d not in IGNORED_PATHS)

        rel_dir = os.path.relpath(dirpath, project_root)
        if rel_dir == ".":
            rel_dir = ""

        depth = rel_dir.count(os.sep) + 1 if rel_dir else 0

        # raw_structure: directories to depth 3 (depth 0 = root, skip root itself)
        if rel_dir and depth <= 3:
            raw_structure.append(rel_dir)

        # detected_layers: check directory basename against known layers
        dir_basename = os.path.basename(dirpath)
        if dir_basename in KNOWN_LAYERS:
            detected_layers_set.add(dir_basename)

        for fname in filenames:
            abs_path = os.path.join(dirpath, fname)
            all_files.add(abs_path)
            _, ext = os.path.splitext(fname)

            # file_counts: per top-level directory
            if rel_dir:
                top_dir = rel_dir.split(os.sep)[0]
                top_level_counts[top_dir] += 1

            # Only process source files for naming_patterns and test_gaps
            if ext not in SOURCE_EXTENSIONS:
                continue

            rel_path = os.path.relpath(abs_path, project_root)

            # naming_patterns: multi-part extensions
            m = MULTI_EXT_RE.search(fname)
            if m:
                naming_counter[m.group()] += 1

            # Collect source files for test gap analysis (skip test files)
            if not TEST_FILE_PATTERNS.search(fname):
                source_files.append((abs_path, rel_path, ext.lstrip(".")))

    # --- Assemble test_gaps ---
    test_gaps = []
    for abs_path, rel_path, ext in source_files:
        if not _has_colocated_test(abs_path, ext, all_files):
            test_gaps.append(rel_path)
    test_gaps.sort()

    # --- Assemble naming_patterns (top 20 by count) ---
    naming_patterns = [
        p for p, _ in naming_counter.most_common(20)
    ]

    # --- Assemble detected_layers (preserve order from KNOWN_LAYERS) ---
    detected_layers = [
        layer for layer in KNOWN_LAYERS_ORDERED
        if layer in detected_layers_set
    ]

    # --- Assemble file_counts ---
    file_counts = sorted(
        [{"dir": d, "count": c} for d, c in top_level_counts.items()],
        key=lambda x: x["dir"]
    )

    # --- raw_structure: sort ---
    raw_structure.sort()

    return {
        "raw_structure": raw_structure,
        "detected_layers": detected_layers,
        "naming_patterns": naming_patterns,
        "test_gaps": test_gaps,
        "file_counts": file_counts,
    }


def main():
    project_root = sys.argv[1] if len(sys.argv) > 1 else os.getcwd()
    debug_log(f"scanning {project_root}")
    result = scan(project_root)
    json.dump(result, sys.stdout, separators=(",", ":"))
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
