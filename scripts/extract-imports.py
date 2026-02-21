#!/usr/bin/env python3
"""AST-aware import extractor for Thymus.

Extracts real import paths from source files, ignoring imports inside
comments, string literals, and template strings.

Usage: python3 extract-imports.py <filepath>
Output: one import path per line to stdout

Supports: JS/TS (state-machine parser), Python (ast module),
          Go/Rust/Java (regex fallback with TODO markers).
"""
import sys
import os
import re


# ---------------------------------------------------------------------------
# JS / TS — two-phase state-machine parser
# ---------------------------------------------------------------------------
#
# Phase 1: Strip comments from source (replace with spaces), preserving
#           string content and line structure.
# Phase 2: For each line in the comment-stripped source, check if import
#           keywords (import/require/export) appear outside of string
#           literals.  If so, extract module paths using regex.
#
# This correctly handles:
#   - Commented-out imports:  // import { db } from '../db/client'
#   - Block comment imports:  /* import { db } from '../db/client' */
#   - String-literal imports: const msg = "import { db } from '../db/client'"
#   - Real imports:           import { db } from '../db/client'
# ---------------------------------------------------------------------------

# States for the comment-stripping state machine
_CODE = 0
_LINE_COMMENT = 1
_BLOCK_COMMENT = 2
_SINGLE_STRING = 3
_DOUBLE_STRING = 4
_TEMPLATE_STRING = 5
_REGEX_LITERAL = 6

# Regex to pull module specifiers from a comment-free line
_IMPORT_PATTERNS = [
    # import ... from 'path'  /  import type ... from 'path'
    re.compile(r'''(?:import|export)\s+.*?\s+from\s+['"]([^'"]+)['"]'''),
    # import 'path'  (side-effect)
    re.compile(r'''import\s+['"]([^'"]+)['"]'''),
    # export * from 'path'
    re.compile(r'''export\s+\*\s+from\s+['"]([^'"]+)['"]'''),
    # require('path')
    re.compile(r'''require\s*\(\s*['"]([^'"]+)['"]\s*\)'''),
    # dynamic import('path') — only string literals
    re.compile(r'''import\s*\(\s*['"]([^'"]+)['"]\s*\)'''),
]

_IMPORT_KEYWORDS = ('import', 'require', 'export')


def _is_prev_token_value(source, pos):
    """Heuristic: does the char before pos look like the end of an expression?
    If so, '/' is division; otherwise it starts a regex literal."""
    i = pos - 1
    while i >= 0 and source[i] in ' \t':
        i -= 1
    if i < 0:
        return False
    return source[i].isalnum() or source[i] in ')]}._$'


def _strip_comments(source):
    """Remove JS/TS comments, replacing them with spaces.

    String content (single, double, template) is preserved so that import
    paths remain extractable.  Template ${...} expressions are handled with
    a depth counter so that braces inside expressions don't confuse the
    parser.
    """
    out = list(source)
    state = _CODE
    state_stack = []   # for template ${...} nesting
    brace_depth = 0
    i = 0
    n = len(source)

    while i < n:
        ch = source[i]

        if state == _CODE:
            if ch == '/' and i + 1 < n:
                nch = source[i + 1]
                if nch == '/':
                    out[i] = ' '; out[i + 1] = ' '
                    state = _LINE_COMMENT
                    i += 2; continue
                if nch == '*':
                    out[i] = ' '; out[i + 1] = ' '
                    state = _BLOCK_COMMENT
                    i += 2; continue
                if not _is_prev_token_value(source, i):
                    state = _REGEX_LITERAL
                    i += 1; continue
            if ch == "'":
                state = _SINGLE_STRING
            elif ch == '"':
                state = _DOUBLE_STRING
            elif ch == '`':
                out[i] = ' '
                state_stack.append(_CODE)
                state = _TEMPLATE_STRING
            elif ch == '}' and state_stack:
                brace_depth -= 1
                if brace_depth <= 0:
                    brace_depth = 0
                    state = state_stack.pop()
            elif ch == '{' and state_stack:
                brace_depth += 1
            i += 1

        elif state == _LINE_COMMENT:
            if ch == '\n':
                state = _CODE
            else:
                out[i] = ' '
            i += 1

        elif state == _BLOCK_COMMENT:
            if ch == '*' and i + 1 < n and source[i + 1] == '/':
                out[i] = ' '; out[i + 1] = ' '
                state = _CODE
                i += 2; continue
            if ch != '\n':
                out[i] = ' '
            i += 1

        elif state == _SINGLE_STRING:
            if ch == '\\' and i + 1 < n:
                i += 2; continue
            if ch == "'" or ch == '\n':
                state = _CODE
            i += 1

        elif state == _DOUBLE_STRING:
            if ch == '\\' and i + 1 < n:
                i += 2; continue
            if ch == '"' or ch == '\n':
                state = _CODE
            i += 1

        elif state == _TEMPLATE_STRING:
            if ch == '\\' and i + 1 < n:
                out[i] = ' '; out[i + 1] = ' '
                i += 2; continue
            if ch == '`':
                out[i] = ' '
                state = state_stack.pop() if state_stack else _CODE
                i += 1; continue
            if ch == '$' and i + 1 < n and source[i + 1] == '{':
                out[i] = ' '; out[i + 1] = ' '
                state_stack.append(_TEMPLATE_STRING)
                state = _CODE
                brace_depth = 1
                i += 2; continue
            if ch != '\n':
                out[i] = ' '
            i += 1

        elif state == _REGEX_LITERAL:
            if ch == '\\' and i + 1 < n:
                i += 2; continue
            if ch == '/':
                state = _CODE
                i += 1
                while i < n and source[i].isalpha():
                    i += 1
                continue
            if ch == '\n':
                state = _CODE
            i += 1

        else:
            i += 1

    return ''.join(out)


def _keyword_outside_strings(line, keyword):
    """Return True if *keyword* appears in *line* outside string literals.

    Assumes comments have already been stripped by _strip_comments().
    """
    klen = len(keyword)
    state = 0  # 0=code, 1=single-string, 2=double-string, 3=template
    i = 0
    n = len(line)

    while i < n:
        ch = line[i]

        if state == 0:
            # Check for keyword at word boundary
            if line[i:i + klen] == keyword:
                before_ok = (i == 0 or not (line[i - 1].isalnum()
                                            or line[i - 1] == '_'))
                after_idx = i + klen
                after_ok = (after_idx >= n or not (line[after_idx].isalnum()
                                                   or line[after_idx] == '_'))
                if before_ok and after_ok:
                    return True
            if ch == "'":
                state = 1
            elif ch == '"':
                state = 2
            elif ch == '`':
                state = 3
            i += 1

        elif state == 1:
            if ch == '\\' and i + 1 < n:
                i += 2; continue
            if ch == "'" or ch == '\n':
                state = 0
            i += 1

        elif state == 2:
            if ch == '\\' and i + 1 < n:
                i += 2; continue
            if ch == '"' or ch == '\n':
                state = 0
            i += 1

        elif state == 3:
            if ch == '\\' and i + 1 < n:
                i += 2; continue
            if ch == '`':
                state = 0
            # Simplified: skip ${...} tracking for keyword detection.
            # Import keywords inside template expressions are rare.
            i += 1

        else:
            i += 1

    return False


def extract_js_ts_imports(filepath):
    """Extract imports from JS/TS using a two-phase state machine.

    Phase 1: strip comments (preserving strings and line structure).
    Phase 2: for lines with import keywords outside strings, extract paths.
    """
    try:
        with open(filepath, encoding='utf-8', errors='replace') as f:
            source = f.read()
    except (IOError, OSError):
        return []

    cleaned = _strip_comments(source)
    imports = []

    for line in cleaned.split('\n'):
        # Quick check — skip lines without any keyword
        has_kw = False
        for kw in _IMPORT_KEYWORDS:
            if kw in line and _keyword_outside_strings(line, kw):
                has_kw = True
                break
        if not has_kw:
            continue

        # Extract module specifiers from the comment-free line
        for pattern in _IMPORT_PATTERNS:
            for match in pattern.finditer(line):
                path = match.group(1)
                if path and path not in imports:
                    imports.append(path)

    return imports


# ---------------------------------------------------------------------------
# Python — real AST parsing
# ---------------------------------------------------------------------------

def extract_python_imports(filepath):
    """Extract imports from Python using the ast module."""
    import ast as _ast
    try:
        with open(filepath, encoding='utf-8', errors='replace') as f:
            source = f.read()
    except (IOError, OSError):
        return []

    try:
        tree = _ast.parse(source, filename=filepath)
    except SyntaxError:
        return []

    imports = []
    for node in _ast.walk(tree):
        if isinstance(node, _ast.Import):
            for alias in node.names:
                if alias.name and alias.name not in imports:
                    imports.append(alias.name)
        elif isinstance(node, _ast.ImportFrom):
            if node.module and node.module not in imports:
                imports.append(node.module)
    return imports


# ---------------------------------------------------------------------------
# Go — regex fallback
# ---------------------------------------------------------------------------

def extract_go_imports(filepath):
    """Extract imports from Go files using regex.

    TODO: implement state-machine parser for Go imports to avoid false
    positives from comments and string literals.
    """
    try:
        with open(filepath, encoding='utf-8', errors='replace') as f:
            content = f.read()
    except (IOError, OSError):
        return []

    imports = []
    # Single import: import "path"
    for m in re.finditer(r'import\s+"([^"]+)"', content):
        path = m.group(1)
        if path not in imports:
            imports.append(path)
    # Grouped import: import ( "path" ... )
    for block in re.finditer(r'import\s*\((.*?)\)', content, re.DOTALL):
        for m in re.finditer(r'"([^"]+)"', block.group(1)):
            path = m.group(1)
            if path not in imports:
                imports.append(path)
    return imports


# ---------------------------------------------------------------------------
# Rust — regex fallback
# ---------------------------------------------------------------------------

def extract_rust_imports(filepath):
    """Extract imports from Rust files using regex.

    TODO: implement state-machine parser for Rust imports to avoid false
    positives from comments and string literals.
    """
    try:
        with open(filepath, encoding='utf-8', errors='replace') as f:
            content = f.read()
    except (IOError, OSError):
        return []

    imports = []
    for m in re.finditer(r'(?:use|extern\s+crate)\s+([\w:]+)', content):
        path = m.group(1)
        if path not in imports:
            imports.append(path)
    return imports


# ---------------------------------------------------------------------------
# Java — regex fallback
# ---------------------------------------------------------------------------

def extract_java_imports(filepath):
    """Extract imports from Java files using regex.

    TODO: implement state-machine parser for Java imports to avoid false
    positives from comments and string literals.
    """
    try:
        with open(filepath, encoding='utf-8', errors='replace') as f:
            content = f.read()
    except (IOError, OSError):
        return []

    imports = []
    for m in re.finditer(r'import\s+(?:static\s+)?([\w.]+)', content):
        path = m.group(1)
        if path not in imports:
            imports.append(path)
    return imports


# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

_EXT_MAP = {
    '.ts': extract_js_ts_imports,
    '.tsx': extract_js_ts_imports,
    '.js': extract_js_ts_imports,
    '.jsx': extract_js_ts_imports,
    '.mjs': extract_js_ts_imports,
    '.cjs': extract_js_ts_imports,
    '.py': extract_python_imports,
    '.go': extract_go_imports,
    '.rs': extract_rust_imports,
    '.java': extract_java_imports,
}


def extract_imports(filepath):
    """Dispatch to the appropriate extractor based on file extension."""
    _, ext = os.path.splitext(filepath)
    extractor = _EXT_MAP.get(ext.lower())
    if extractor is None:
        return []
    return extractor(filepath)


def main():
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <filepath>", file=sys.stderr)
        sys.exit(1)

    filepath = sys.argv[1]
    if not os.path.isfile(filepath):
        sys.exit(0)

    for imp in extract_imports(filepath):
        print(imp)


if __name__ == '__main__':
    main()
