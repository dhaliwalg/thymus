"""Thymus shared Python utilities.

Replaces scripts/lib/common.sh — all functions have identical behavior
to their bash counterparts but run in-process with zero subprocess overhead.

Python 3 stdlib only. No pip dependencies.
"""

import datetime
import hashlib
import json
import os
import re
import sys

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

THYMUS_IGNORED_PATHS = [
    "node_modules", "dist", ".next", ".git", "coverage",
    "__pycache__", ".venv", "vendor", "target", "build", ".thymus",
]

SOURCE_EXTENSIONS = {
    ".ts", ".js", ".py", ".java", ".go", ".rs", ".dart",
    ".kt", ".kts", ".swift", ".cs", ".php", ".rb",
}

DEBUG_LOG = "/tmp/thymus-debug.log"

# ---------------------------------------------------------------------------
# Debug logging
# ---------------------------------------------------------------------------


def debug_log(msg: str) -> None:
    """Log a timestamped debug message to /tmp/thymus-debug.log."""
    ts = datetime.datetime.now().strftime("%Y-%m-%dT%H:%M:%S")
    try:
        with open(DEBUG_LOG, "a") as f:
            f.write(f"[{ts}] core.py: {msg}\n")
    except OSError:
        pass


# ---------------------------------------------------------------------------
# Project hash and cache directory
# ---------------------------------------------------------------------------


def thymus_project_hash() -> str:
    """Return md5 hex digest of the current working directory path."""
    return hashlib.md5(os.getcwd().encode()).hexdigest()


def thymus_cache_dir() -> str:
    """Return /tmp/thymus-cache-{hash}/, creating it if needed."""
    h = thymus_project_hash()
    d = f"/tmp/thymus-cache-{h}"
    os.makedirs(d, exist_ok=True)
    return d


# ---------------------------------------------------------------------------
# YAML parser (canonical copy) — identical regex logic to common.sh
# ---------------------------------------------------------------------------


def _strip_val(s: str) -> str:
    """Strip trailing inline comments and surrounding quotes."""
    s = re.sub(r'\s{2,}#.*$', '', s)
    return s.strip('"\'')


def load_invariants(yml_path: str, cache_path: str) -> dict:
    """Parse .thymus/invariants.yml into a dict, caching as JSON.

    Uses the same regex-based parser as common.sh's embedded Python.
    Returns the parsed dict (not the path, unlike the bash version).
    """
    if not os.path.isfile(yml_path):
        raise FileNotFoundError(f"thymus: invariants.yml not found: {yml_path}")

    # Use cache if it exists and is newer than the YAML file
    if os.path.isfile(cache_path):
        if os.path.getmtime(cache_path) > os.path.getmtime(yml_path):
            try:
                with open(cache_path) as f:
                    return json.load(f)
            except (json.JSONDecodeError, OSError):
                pass  # fall through to re-parse

    invariants = []
    current = None
    list_key = None

    with open(yml_path) as f:
        for line in f:
            line = line.rstrip('\n')

            # New invariant block:  "  - id: some_id"
            m = re.match(r'^  - id:\s*["\']?(.*?)["\']?\s*$', line)
            if m:
                if current:
                    invariants.append(current)
                current = {'id': _strip_val(m.group(1))}
                list_key = None
                continue

            if current is None:
                continue

            # List item:  "      - value"
            m = re.match(r'^      - ["\']?(.*?)["\']?\s*$', line)
            if m and list_key is not None:
                current[list_key].append(_strip_val(m.group(1)))
                continue

            # List key (bare, no value):  "    some_key:"
            m = re.match(r'^    ([a-z_]+):\s*$', line)
            if m:
                list_key = m.group(1)
                current[list_key] = []
                continue

            # Scalar key-value:  "    some_key: some_value"
            m = re.match(r'^    ([a-z_]+):\s*["\']?(.*?)["\']?\s*$', line)
            if m:
                current[m.group(1)] = _strip_val(m.group(2))
                list_key = None
                continue

    if current:
        invariants.append(current)

    result = {'invariants': invariants}

    # Write cache
    try:
        with open(cache_path, 'w') as f:
            json.dump(result, f)
    except OSError:
        pass

    return result


# ---------------------------------------------------------------------------
# Glob matching — identical to common.sh's glob_to_regex / path_matches
# ---------------------------------------------------------------------------


def glob_to_regex(pattern: str) -> str:
    """Convert a glob pattern to a regex string.

    Transforms:  . -> \\.   ** -> .*   * -> [^/]*
    Matches the exact sed pipeline in common.sh.
    """
    # Order matters: escape dots, then ** before *
    result = pattern.replace('.', '\\.')
    result = result.replace('**', '__DS__')
    result = result.replace('*', '[^/]*')
    result = result.replace('__DS__', '.*')
    return result


def path_matches(path: str, glob_pattern: str) -> bool:
    """Return True if path matches the glob pattern (full match)."""
    regex = '^' + glob_to_regex(glob_pattern) + '$'
    return re.search(regex, path) is not None


def file_in_scope(rel_path: str, invariant: dict) -> bool:
    """Check whether a file is in scope for an invariant rule.

    Uses source_glob (preferred) or scope_glob, then excludes via
    scope_glob_exclude. Matches common.sh file_in_scope() exactly.
    """
    applicable_glob = invariant.get('source_glob') or invariant.get('scope_glob')
    if not applicable_glob:
        return True

    if not path_matches(rel_path, applicable_glob):
        return False

    for excl in (invariant.get('scope_glob_exclude') or []):
        if path_matches(rel_path, excl):
            return False

    return True


# ---------------------------------------------------------------------------
# Import extraction — in-process, zero subprocess overhead
# ---------------------------------------------------------------------------

# Lazy-loaded reference to extract-imports.py's extract_imports()
_extract_imports_fn = None


def _get_extract_imports():
    """Import extract_imports from scripts/extract-imports.py in-process."""
    global _extract_imports_fn
    if _extract_imports_fn is not None:
        return _extract_imports_fn

    # Resolve path: this file is scripts/lib/core.py
    # extract-imports.py is at scripts/extract-imports.py
    lib_dir = os.path.dirname(os.path.abspath(__file__))
    scripts_dir = os.path.dirname(lib_dir)
    extract_path = os.path.join(scripts_dir, 'extract-imports.py')

    if not os.path.isfile(extract_path):
        raise ImportError(f"Cannot find extract-imports.py at {extract_path}")

    # Import the module despite the hyphenated filename
    import importlib.util
    spec = importlib.util.spec_from_file_location("extract_imports", extract_path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    _extract_imports_fn = mod.extract_imports
    return _extract_imports_fn


def extract_imports_for_file(filepath: str) -> list:
    """Extract imports from a source file in-process.

    Calls extract-imports.py's extract_imports() directly — no subprocess.
    Returns a list of import path strings (empty list if file missing or error).
    """
    if not os.path.isfile(filepath):
        return []
    try:
        fn = _get_extract_imports()
        return fn(filepath)
    except Exception:
        return []


# ---------------------------------------------------------------------------
# Import forbidden/allowed checking — identical to common.sh
# ---------------------------------------------------------------------------


def import_is_forbidden(imp: str, invariant: dict) -> bool:
    """Check if an import is forbidden by an invariant rule.

    Mirrors common.sh import_is_forbidden() exactly:
    1. Check if import matches any forbidden_imports pattern
    2. If matched, check if it also matches an allowed_imports pattern (override)
    3. Also tries converting dotted module names to paths (a.b -> a/b)
    """
    forbidden = invariant.get('forbidden_imports', [])
    if not forbidden:
        return False

    # Convert dotted module names to path form for matching
    import_as_path = imp
    if '.' in imp and '/' not in imp:
        import_as_path = imp.replace('.', '/')

    # Check if import matches any forbidden pattern
    matched = False
    for pattern in forbidden:
        if (path_matches(imp, pattern) or imp == pattern
                or path_matches(import_as_path, pattern)):
            matched = True
            break

    if not matched:
        return False

    # Check allowed_imports — if import matches an allowed pattern, not forbidden
    allowed = invariant.get('allowed_imports', [])
    for pattern in allowed:
        if (path_matches(imp, pattern) or imp == pattern
                or path_matches(import_as_path, pattern)):
            return False  # allowed override

    return True  # forbidden


# ---------------------------------------------------------------------------
# File discovery — identical to common.sh find_source_files
# ---------------------------------------------------------------------------


def find_source_files(root: str = None) -> list:
    """Walk the tree and return sorted relative paths of source files.

    Skips THYMUS_IGNORED_PATHS directories, only includes files with
    SOURCE_EXTENSIONS. Matches common.sh find_source_files() output.
    """
    if root is None:
        root = os.getcwd()

    root = os.path.abspath(root)
    ignored = set(THYMUS_IGNORED_PATHS)
    results = []

    for dirpath, dirnames, filenames in os.walk(root):
        # Prune ignored directories in-place (prevents os.walk from descending)
        dirnames[:] = [d for d in dirnames if d not in ignored]

        for fname in filenames:
            _, ext = os.path.splitext(fname)
            if ext in SOURCE_EXTENSIONS:
                abs_path = os.path.join(dirpath, fname)
                rel_path = os.path.relpath(abs_path, root)
                results.append(rel_path)

    results.sort()
    return results


# ---------------------------------------------------------------------------
# Build import entries — identical to common.sh build_import_entries
# ---------------------------------------------------------------------------


def build_import_entries(file_list: list, root: str = None) -> list:
    """Build import entries for a list of relative file paths.

    Returns: [{"file": rel_path, "imports": [...]}, ...]
    Matches common.sh build_import_entries() output exactly.
    """
    if root is None:
        root = os.getcwd()

    entries = []
    for rel_path in file_list:
        if not rel_path:
            continue
        abs_path = os.path.join(root, rel_path)
        if not os.path.isfile(abs_path):
            continue
        imports = extract_imports_for_file(abs_path)
        entries.append({"file": rel_path, "imports": imports})

    return entries
