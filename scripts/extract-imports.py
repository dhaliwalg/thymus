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
# Go — comment-aware state-machine parser
# ---------------------------------------------------------------------------

def _strip_go_comments(content):
    """Strip Go comments, preserving string content and line structure.

    Handles:
    - Line comments: // through end of line
    - Block comments: /* ... */ (no nesting in Go)
    - Double-quoted strings: "..." with \\ escape sequences (preserved)
    - Raw strings (backtick): `...` — no escapes (preserved)
    - Rune literals: '...' with \\ escape sequences (preserved)

    Only comment content is blanked. String content is preserved so that
    line-level import detection can distinguish code from strings.
    """
    out = list(content)
    i = 0
    n = len(content)
    # States: 0=code, 1=line_comment, 2=block_comment,
    #         3=double_string, 4=raw_string, 5=rune_literal
    state = 0

    while i < n:
        ch = content[i]

        if state == 0:  # code
            if ch == '/' and i + 1 < n:
                nch = content[i + 1]
                if nch == '/':
                    out[i] = ' '; out[i + 1] = ' '
                    state = 1
                    i += 2; continue
                if nch == '*':
                    out[i] = ' '; out[i + 1] = ' '
                    state = 2
                    i += 2; continue
            if ch == '"':
                state = 3
            elif ch == '`':
                state = 4
            elif ch == "'":
                state = 5
            i += 1

        elif state == 1:  # line comment
            if ch == '\n':
                state = 0
            else:
                out[i] = ' '
            i += 1

        elif state == 2:  # block comment
            if ch == '*' and i + 1 < n and content[i + 1] == '/':
                out[i] = ' '; out[i + 1] = ' '
                state = 0
                i += 2; continue
            if ch != '\n':
                out[i] = ' '
            i += 1

        elif state == 3:  # double-quoted string (preserved)
            if ch == '\\' and i + 1 < n:
                i += 2; continue
            if ch == '"':
                state = 0
            i += 1

        elif state == 4:  # raw string (preserved)
            if ch == '`':
                state = 0
            i += 1

        elif state == 5:  # rune literal (preserved)
            if ch == '\\' and i + 1 < n:
                i += 2; continue
            if ch == "'":
                state = 0
            i += 1

        else:
            i += 1

    return ''.join(out)


def extract_go_imports(filepath):
    """Extract imports from Go files using a comment-aware state machine.

    Phase 1: strip comments (preserving strings and line structure).
    Phase 2: line-by-line extraction — only match import at line start.

    Go import statements are always at file scope, so `import` at the start
    of a line (after whitespace) is always a real import, never inside a
    string or variable assignment.
    """
    try:
        with open(filepath, encoding='utf-8', errors='replace') as f:
            content = f.read()
    except (IOError, OSError):
        return []

    cleaned = _strip_go_comments(content)
    imports = []
    in_group = False

    for line in cleaned.split('\n'):
        stripped = line.strip()
        if not stripped:
            continue

        # Detect start of grouped import
        if re.match(r'^import\s*\(', stripped):
            in_group = True
            continue

        # Detect end of grouped import
        if in_group and stripped.startswith(')'):
            in_group = False
            continue

        if in_group:
            # Inside import (...): extract "path" or alias "path"
            m = re.match(r'\s*(?:\w+\s+)?"([^"]+)"', line)
            if m:
                path = m.group(1)
                if path not in imports:
                    imports.append(path)
        elif stripped.startswith('import '):
            # Single import: import "path" or import alias "path"
            m = re.match(r'import\s+(?:\w+\s+)?"([^"]+)"', stripped)
            if m:
                path = m.group(1)
                if path not in imports:
                    imports.append(path)

    return imports


# ---------------------------------------------------------------------------
# Rust — comment-aware state-machine parser
# ---------------------------------------------------------------------------

def _strip_rust_comments(content):
    """Strip Rust comments, preserving string content and line structure.

    Handles:
    - Line comments: // through end of line
    - Block comments: /* ... */ with NESTED support (depth counter)
    - Double-quoted strings: "..." with \\ escape sequences (preserved)
    - Raw strings: r"...", r#"..."#, r##"..."## etc. (preserved)
    - Byte strings: b"..." (preserved)
    - Raw byte strings: br"...", br#"..."# (preserved)
    - Character literals: '...' with \\ escapes (preserved, heuristic for lifetimes)

    Only comment content is blanked. String content is preserved so that
    line-level import detection can distinguish code from strings.
    """
    out = list(content)
    i = 0
    n = len(content)
    # States: 0=code, 1=line_comment, 2=block_comment,
    #         3=double_string, 4=raw_string, 5=char_literal
    state = 0
    block_depth = 0
    raw_hashes = 0  # number of # in current raw string delimiter

    while i < n:
        ch = content[i]

        if state == 0:  # code
            if ch == '/' and i + 1 < n:
                nch = content[i + 1]
                if nch == '/':
                    out[i] = ' '; out[i + 1] = ' '
                    state = 1
                    i += 2; continue
                if nch == '*':
                    out[i] = ' '; out[i + 1] = ' '
                    state = 2
                    block_depth = 1
                    i += 2; continue
            # Raw strings: r"...", r#"..."#, r##"..."##
            # Also br"...", br#"..."#
            if ch in ('r', 'b') and i + 1 < n:
                j = i
                if ch == 'b' and content[j + 1] == 'r':
                    j += 2
                elif ch == 'r':
                    j += 1
                else:
                    j = -1  # not a raw string
                if j > 0 and j < n:
                    hashes = 0
                    while j < n and content[j] == '#':
                        hashes += 1
                        j += 1
                    if j < n and content[j] == '"':
                        raw_hashes = hashes
                        state = 4
                        i = j + 1; continue
            if ch == 'b' and i + 1 < n and content[i + 1] == '"':
                state = 3
                i += 2; continue
            if ch == '"':
                state = 3
                i += 1; continue
            if ch == "'":
                # Heuristic: distinguish char literal from lifetime
                if i + 2 < n and content[i + 1] == '\\':
                    state = 5
                    i += 1; continue
                if i + 2 < n and content[i + 2] == "'":
                    state = 5
                    i += 1; continue
                # Otherwise likely a lifetime — skip
            i += 1

        elif state == 1:  # line comment
            if ch == '\n':
                state = 0
            else:
                out[i] = ' '
            i += 1

        elif state == 2:  # block comment (nested)
            if ch == '/' and i + 1 < n and content[i + 1] == '*':
                out[i] = ' '; out[i + 1] = ' '
                block_depth += 1
                i += 2; continue
            if ch == '*' and i + 1 < n and content[i + 1] == '/':
                out[i] = ' '; out[i + 1] = ' '
                block_depth -= 1
                if block_depth == 0:
                    state = 0
                i += 2; continue
            if ch != '\n':
                out[i] = ' '
            i += 1

        elif state == 3:  # double-quoted string (preserved)
            if ch == '\\' and i + 1 < n:
                i += 2; continue
            if ch == '"':
                state = 0
            i += 1

        elif state == 4:  # raw string (preserved)
            if ch == '"':
                j = i + 1
                hashes = 0
                while j < n and content[j] == '#' and hashes < raw_hashes:
                    hashes += 1
                    j += 1
                if hashes == raw_hashes:
                    state = 0
                    i = j; continue
            i += 1

        elif state == 5:  # char literal (preserved)
            if ch == '\\' and i + 1 < n:
                i += 2; continue
            if ch == "'":
                state = 0
            i += 1

        else:
            i += 1

    return ''.join(out)


def extract_rust_imports(filepath):
    """Extract imports from Rust files using a comment-aware state machine.

    Phase 1: strip comments (preserving strings and line structure).
    Phase 2: line-by-line extraction — only match use/extern at line start.

    Rust use/extern crate statements are at module scope, so `use` or
    `extern crate` at the start of a line is always a real import.
    """
    try:
        with open(filepath, encoding='utf-8', errors='replace') as f:
            content = f.read()
    except (IOError, OSError):
        return []

    cleaned = _strip_rust_comments(content)
    imports = []

    for line in cleaned.split('\n'):
        stripped = line.strip()
        if not stripped:
            continue

        # Only match use/extern at line start
        if not (stripped.startswith('use ') or
                stripped.startswith('extern ')):
            continue

        # extern crate: extern crate serde;
        m = re.match(r'extern\s+crate\s+(\w+)', stripped)
        if m:
            path = m.group(1)
            if path not in imports:
                imports.append(path)
            continue

        # use with grouped imports: use std::{io, fs};
        m = re.match(r'use\s+([\w:]+)::\{([^}]+)\}', stripped)
        if m:
            prefix = m.group(1)
            items = m.group(2)
            for item in items.split(','):
                item = item.strip()
                if ' as ' in item:
                    item = item.split(' as ')[0].strip()
                if item:
                    full_path = prefix + '::' + item
                    if full_path not in imports:
                        imports.append(full_path)
            continue

        # Simple use: use std::collections::HashMap;
        # Glob use: use std::io::*;
        # Renamed: use std::io::Result as IoResult;
        m = re.match(r'use\s+([\w:]+(?:::\*)?)\s*(?:as\s+\w+\s*)?;', stripped)
        if m:
            path = m.group(1)
            if path not in imports:
                imports.append(path)

    return imports


# ---------------------------------------------------------------------------
# Java — regex fallback
# ---------------------------------------------------------------------------

def _strip_java_comments(content):
    """Strip Java block comments and line comments, preserving string literals."""
    result = []
    i = 0
    n = len(content)
    while i < n:
        c = content[i]
        # String literal (double-quoted)
        if c == '"':
            result.append(c)
            i += 1
            while i < n and content[i] != '"':
                if content[i] == '\\':
                    result.append(content[i])
                    i += 1
                    if i < n:
                        result.append(content[i])
                        i += 1
                else:
                    result.append(content[i])
                    i += 1
            if i < n:
                result.append(content[i])
                i += 1
        # Character literal
        elif c == "'":
            result.append(c)
            i += 1
            while i < n and content[i] != "'":
                if content[i] == '\\':
                    result.append(content[i])
                    i += 1
                    if i < n:
                        result.append(content[i])
                        i += 1
                else:
                    result.append(content[i])
                    i += 1
            if i < n:
                result.append(content[i])
                i += 1
        # Line comment
        elif c == '/' and i + 1 < n and content[i + 1] == '/':
            while i < n and content[i] != '\n':
                i += 1
        # Block comment
        elif c == '/' and i + 1 < n and content[i + 1] == '*':
            i += 2
            while i + 1 < n and not (content[i] == '*' and content[i + 1] == '/'):
                i += 1
            i += 2  # skip */
        else:
            result.append(c)
            i += 1
    return ''.join(result)


def extract_java_imports(filepath):
    """Extract imports from Java files with comment/string awareness."""
    try:
        with open(filepath, encoding='utf-8', errors='replace') as f:
            content = f.read()
    except (IOError, OSError):
        return []

    stripped = _strip_java_comments(content)
    imports = []
    for m in re.finditer(r'import\s+(?:static\s+)?([\w.*]+)', stripped):
        path = m.group(1)
        if path not in imports:
            imports.append(path)
    return imports


# ---------------------------------------------------------------------------
# Dart — comment-aware state-machine parser
# ---------------------------------------------------------------------------

def _strip_dart_comments(content):
    """Strip Dart comments, preserving string content and line structure.

    Handles:
    - Line comments: // through end of line
    - Block comments: /* ... */ (no nesting in Dart)
    - Double-quoted strings: "..." with \\ escapes (preserved)
    - Single-quoted strings: '...' with \\ escapes (preserved)
    - Triple-quoted strings: \"\"\"...\"\"\" and '''...''' (preserved)
    - Raw strings: r"..." and r'...' (preserved, no escapes)
    """
    out = list(content)
    i = 0
    n = len(content)
    # States: 0=code, 1=line_comment, 2=block_comment,
    #         3=double_string, 4=single_string,
    #         5=triple_double_string, 6=triple_single_string,
    #         7=raw_double_string, 8=raw_single_string
    state = 0

    while i < n:
        ch = content[i]

        if state == 0:  # code
            # Raw strings: r"..." or r'...'
            if ch == 'r' and i + 1 < n:
                if content[i + 1] == '"':
                    state = 7
                    i += 2; continue
                if content[i + 1] == "'":
                    state = 8
                    i += 2; continue
            if ch == '/' and i + 1 < n:
                nch = content[i + 1]
                if nch == '/':
                    out[i] = ' '; out[i + 1] = ' '
                    state = 1
                    i += 2; continue
                if nch == '*':
                    out[i] = ' '; out[i + 1] = ' '
                    state = 2
                    i += 2; continue
            # Triple-quoted strings (must check before single/double)
            if ch == '"' and i + 2 < n and content[i + 1] == '"' and content[i + 2] == '"':
                state = 5
                i += 3; continue
            if ch == "'" and i + 2 < n and content[i + 1] == "'" and content[i + 2] == "'":
                state = 6
                i += 3; continue
            if ch == '"':
                state = 3
            elif ch == "'":
                state = 4
            i += 1

        elif state == 1:  # line comment
            if ch == '\n':
                state = 0
            else:
                out[i] = ' '
            i += 1

        elif state == 2:  # block comment
            if ch == '*' and i + 1 < n and content[i + 1] == '/':
                out[i] = ' '; out[i + 1] = ' '
                state = 0
                i += 2; continue
            if ch != '\n':
                out[i] = ' '
            i += 1

        elif state == 3:  # double-quoted string (preserved)
            if ch == '\\' and i + 1 < n:
                i += 2; continue
            if ch == '"':
                state = 0
            i += 1

        elif state == 4:  # single-quoted string (preserved)
            if ch == '\\' and i + 1 < n:
                i += 2; continue
            if ch == "'":
                state = 0
            i += 1

        elif state == 5:  # triple-double-quoted string (preserved)
            if ch == '"' and i + 2 < n and content[i + 1] == '"' and content[i + 2] == '"':
                state = 0
                i += 3; continue
            i += 1

        elif state == 6:  # triple-single-quoted string (preserved)
            if ch == "'" and i + 2 < n and content[i + 1] == "'" and content[i + 2] == "'":
                state = 0
                i += 3; continue
            i += 1

        elif state == 7:  # raw double-quoted string (preserved, no escapes)
            if ch == '"':
                state = 0
            i += 1

        elif state == 8:  # raw single-quoted string (preserved, no escapes)
            if ch == "'":
                state = 0
            i += 1

        else:
            i += 1

    return ''.join(out)


def extract_dart_imports(filepath):
    """Extract imports from Dart files using a comment-aware state machine."""
    try:
        with open(filepath, encoding='utf-8', errors='replace') as f:
            content = f.read()
    except (IOError, OSError):
        return []

    cleaned = _strip_dart_comments(content)
    imports = []

    for line in cleaned.split('\n'):
        stripped = line.strip()
        if not stripped:
            continue
        # import/export/part directives
        m = re.match(r'''(?:import|export|part)\s+['"](.+?)['"]''', stripped)
        if m:
            path = m.group(1)
            if path not in imports:
                imports.append(path)

    return imports


# ---------------------------------------------------------------------------
# Kotlin — comment-aware state-machine parser
# ---------------------------------------------------------------------------

def _strip_kotlin_comments(content):
    """Strip Kotlin comments, preserving string content and line structure.

    Handles:
    - Line comments: // through end of line
    - Block comments: /* ... */ with NESTED support (depth counter)
    - Double-quoted strings: "..." with \\ escapes (preserved)
    - Triple-quoted strings: \"\"\"...\"\"\" (raw, no escapes, preserved)
    - Character literals: '...' with \\ escapes (preserved)
    """
    out = list(content)
    i = 0
    n = len(content)
    # States: 0=code, 1=line_comment, 2=block_comment,
    #         3=double_string, 4=triple_string, 5=char_literal
    state = 0
    block_depth = 0

    while i < n:
        ch = content[i]

        if state == 0:  # code
            if ch == '/' and i + 1 < n:
                nch = content[i + 1]
                if nch == '/':
                    out[i] = ' '; out[i + 1] = ' '
                    state = 1
                    i += 2; continue
                if nch == '*':
                    out[i] = ' '; out[i + 1] = ' '
                    state = 2
                    block_depth = 1
                    i += 2; continue
            # Triple-quoted strings (check before double)
            if ch == '"' and i + 2 < n and content[i + 1] == '"' and content[i + 2] == '"':
                state = 4
                i += 3; continue
            if ch == '"':
                state = 3
            elif ch == "'":
                state = 5
            i += 1

        elif state == 1:  # line comment
            if ch == '\n':
                state = 0
            else:
                out[i] = ' '
            i += 1

        elif state == 2:  # block comment (nested)
            if ch == '/' and i + 1 < n and content[i + 1] == '*':
                out[i] = ' '; out[i + 1] = ' '
                block_depth += 1
                i += 2; continue
            if ch == '*' and i + 1 < n and content[i + 1] == '/':
                out[i] = ' '; out[i + 1] = ' '
                block_depth -= 1
                if block_depth == 0:
                    state = 0
                i += 2; continue
            if ch != '\n':
                out[i] = ' '
            i += 1

        elif state == 3:  # double-quoted string (preserved)
            if ch == '\\' and i + 1 < n:
                i += 2; continue
            if ch == '"':
                state = 0
            i += 1

        elif state == 4:  # triple-quoted string (preserved)
            if ch == '"' and i + 2 < n and content[i + 1] == '"' and content[i + 2] == '"':
                state = 0
                i += 3; continue
            i += 1

        elif state == 5:  # char literal (preserved)
            if ch == '\\' and i + 1 < n:
                i += 2; continue
            if ch == "'":
                state = 0
            i += 1

        else:
            i += 1

    return ''.join(out)


def extract_kotlin_imports(filepath):
    """Extract imports from Kotlin files using a comment-aware state machine."""
    try:
        with open(filepath, encoding='utf-8', errors='replace') as f:
            content = f.read()
    except (IOError, OSError):
        return []

    cleaned = _strip_kotlin_comments(content)
    imports = []

    for line in cleaned.split('\n'):
        stripped = line.strip()
        if not stripped:
            continue
        # import com.example.Foo or import com.example.* or import ... as Alias
        m = re.match(r'import\s+([\w]+(?:\.[\w]+)*(?:\.\*)?)', stripped)
        if m:
            path = m.group(1)
            if path not in imports:
                imports.append(path)

    return imports


# ---------------------------------------------------------------------------
# Swift — comment-aware state-machine parser
# ---------------------------------------------------------------------------

def _strip_swift_comments(content):
    """Strip Swift comments, preserving string content and line structure.

    Handles:
    - Line comments: // through end of line
    - Block comments: /* ... */ with NESTED support (depth counter)
    - Double-quoted strings: "..." with \\ escapes (preserved)
    - Multi-line strings: \"\"\"...\"\"\" (preserved)
    - String interpolation \\(...) treated as part of string
    """
    out = list(content)
    i = 0
    n = len(content)
    # States: 0=code, 1=line_comment, 2=block_comment,
    #         3=double_string, 4=triple_string
    state = 0
    block_depth = 0

    while i < n:
        ch = content[i]

        if state == 0:  # code
            if ch == '/' and i + 1 < n:
                nch = content[i + 1]
                if nch == '/':
                    out[i] = ' '; out[i + 1] = ' '
                    state = 1
                    i += 2; continue
                if nch == '*':
                    out[i] = ' '; out[i + 1] = ' '
                    state = 2
                    block_depth = 1
                    i += 2; continue
            # Triple-quoted strings (check before double)
            if ch == '"' and i + 2 < n and content[i + 1] == '"' and content[i + 2] == '"':
                state = 4
                i += 3; continue
            if ch == '"':
                state = 3
            i += 1

        elif state == 1:  # line comment
            if ch == '\n':
                state = 0
            else:
                out[i] = ' '
            i += 1

        elif state == 2:  # block comment (nested)
            if ch == '/' and i + 1 < n and content[i + 1] == '*':
                out[i] = ' '; out[i + 1] = ' '
                block_depth += 1
                i += 2; continue
            if ch == '*' and i + 1 < n and content[i + 1] == '/':
                out[i] = ' '; out[i + 1] = ' '
                block_depth -= 1
                if block_depth == 0:
                    state = 0
                i += 2; continue
            if ch != '\n':
                out[i] = ' '
            i += 1

        elif state == 3:  # double-quoted string (preserved)
            if ch == '\\' and i + 1 < n:
                i += 2; continue
            if ch == '"':
                state = 0
            i += 1

        elif state == 4:  # triple-quoted string (preserved)
            if ch == '"' and i + 2 < n and content[i + 1] == '"' and content[i + 2] == '"':
                state = 0
                i += 3; continue
            i += 1

        else:
            i += 1

    return ''.join(out)


def extract_swift_imports(filepath):
    """Extract imports from Swift files using a comment-aware state machine."""
    try:
        with open(filepath, encoding='utf-8', errors='replace') as f:
            content = f.read()
    except (IOError, OSError):
        return []

    cleaned = _strip_swift_comments(content)
    imports = []

    for line in cleaned.split('\n'):
        stripped = line.strip()
        if not stripped:
            continue
        # @testable import Foo, import struct Foundation.Date, import Foundation
        m = re.match(
            r'(?:@testable\s+)?import\s+'
            r'(?:(?:struct|class|enum|protocol|typealias|func|var|let)\s+)?'
            r'(\w+)',
            stripped
        )
        if m:
            path = m.group(1)
            if path not in imports:
                imports.append(path)

    return imports


# ---------------------------------------------------------------------------
# C# — comment-aware state-machine parser
# ---------------------------------------------------------------------------

def _strip_csharp_comments(content):
    """Strip C# comments, preserving string content and line structure.

    Handles:
    - Line comments: // through end of line
    - Block comments: /* ... */ (no nesting)
    - Double-quoted strings: "..." with \\ escapes (preserved)
    - Verbatim strings: @"..." — no escapes, "" is escaped quote (preserved)
    - Raw string literals: three or more " to open/close (preserved)
    - Character literals: '...' with \\ escapes (preserved)
    - Interpolated strings: $"..." treated as regular strings
    """
    out = list(content)
    i = 0
    n = len(content)
    # States: 0=code, 1=line_comment, 2=block_comment,
    #         3=double_string, 4=verbatim_string, 5=char_literal,
    #         6=raw_string
    state = 0
    raw_quote_count = 0

    while i < n:
        ch = content[i]

        if state == 0:  # code
            if ch == '/' and i + 1 < n:
                nch = content[i + 1]
                if nch == '/':
                    out[i] = ' '; out[i + 1] = ' '
                    state = 1
                    i += 2; continue
                if nch == '*':
                    out[i] = ' '; out[i + 1] = ' '
                    state = 2
                    i += 2; continue
            # Verbatim strings: @"..." or $@"..."
            if ch in ('@', '$') and i + 1 < n:
                j = i
                if ch == '$' and j + 1 < n and content[j + 1] == '@':
                    j += 2
                elif ch == '@':
                    j += 1
                else:
                    j = -1
                if j > 0 and j < n and content[j] == '"':
                    # Check for raw string (3+ quotes)
                    qcount = 0
                    k = j
                    while k < n and content[k] == '"':
                        qcount += 1
                        k += 1
                    if qcount >= 3:
                        raw_quote_count = qcount
                        state = 6
                        i = k; continue
                    # Verbatim string
                    state = 4
                    i = j + 1; continue
            # Raw string literals: """...""" (3+ quotes)
            if ch == '"' and i + 2 < n and content[i + 1] == '"' and content[i + 2] == '"':
                qcount = 0
                j = i
                while j < n and content[j] == '"':
                    qcount += 1
                    j += 1
                raw_quote_count = qcount
                state = 6
                i = j; continue
            # Interpolated string: $"..."
            if ch == '$' and i + 1 < n and content[i + 1] == '"':
                state = 3
                i += 2; continue
            if ch == '"':
                state = 3
            elif ch == "'":
                state = 5
            i += 1

        elif state == 1:  # line comment
            if ch == '\n':
                state = 0
            else:
                out[i] = ' '
            i += 1

        elif state == 2:  # block comment
            if ch == '*' and i + 1 < n and content[i + 1] == '/':
                out[i] = ' '; out[i + 1] = ' '
                state = 0
                i += 2; continue
            if ch != '\n':
                out[i] = ' '
            i += 1

        elif state == 3:  # double-quoted string (preserved)
            if ch == '\\' and i + 1 < n:
                i += 2; continue
            if ch == '"':
                state = 0
            i += 1

        elif state == 4:  # verbatim string (preserved)
            if ch == '"':
                if i + 1 < n and content[i + 1] == '"':
                    i += 2; continue  # escaped quote
                state = 0
            i += 1

        elif state == 5:  # char literal (preserved)
            if ch == '\\' and i + 1 < n:
                i += 2; continue
            if ch == "'":
                state = 0
            i += 1

        elif state == 6:  # raw string literal (preserved)
            if ch == '"':
                qcount = 0
                j = i
                while j < n and content[j] == '"':
                    qcount += 1
                    j += 1
                if qcount >= raw_quote_count:
                    state = 0
                    i = j; continue
            i += 1

        else:
            i += 1

    return ''.join(out)


def extract_csharp_imports(filepath):
    """Extract imports from C# files using a comment-aware state machine."""
    try:
        with open(filepath, encoding='utf-8', errors='replace') as f:
            content = f.read()
    except (IOError, OSError):
        return []

    cleaned = _strip_csharp_comments(content)
    imports = []

    # Only extract top-level using directives (before namespace/class)
    for line in cleaned.split('\n'):
        stripped = line.strip()
        if not stripped:
            continue
        # Stop at namespace or class declarations
        if re.match(r'(namespace|class|struct|interface|enum|record)\s', stripped):
            break
        m = re.match(
            r'(?:global\s+)?using\s+(?:static\s+)?(?:\w+\s*=\s*)?(?:global::)?([\w.]+)',
            stripped
        )
        if m:
            path = m.group(1)
            # Strip generic type parameters if present (from alias targets)
            path = re.sub(r'<.*', '', path)
            if path not in imports:
                imports.append(path)

    return imports


# ---------------------------------------------------------------------------
# PHP — comment-aware state-machine parser
# ---------------------------------------------------------------------------

def _strip_php_comments(content):
    """Strip PHP comments, preserving string content and line structure.

    Handles:
    - Line comments: // through end of line
    - Hash comments: # through end of line (but not #[ attributes)
    - Block comments: /* ... */ (no nesting)
    - Single-quoted strings: '...' with \\\\ and \\' escapes (preserved)
    - Double-quoted strings: "..." with \\ escapes (preserved)
    - Heredoc/Nowdoc: <<<ID ... ID; (preserved)
    """
    out = list(content)
    i = 0
    n = len(content)
    # States: 0=code, 1=line_comment, 2=block_comment,
    #         3=single_string, 4=double_string, 5=heredoc
    state = 0
    heredoc_id = ""

    while i < n:
        ch = content[i]

        if state == 0:  # code
            if ch == '/' and i + 1 < n:
                nch = content[i + 1]
                if nch == '/':
                    out[i] = ' '; out[i + 1] = ' '
                    state = 1
                    i += 2; continue
                if nch == '*':
                    out[i] = ' '; out[i + 1] = ' '
                    state = 2
                    i += 2; continue
            if ch == '#' and (i + 1 >= n or content[i + 1] != '['):
                out[i] = ' '
                state = 1
                i += 1; continue
            # Heredoc/Nowdoc: <<<IDENTIFIER or <<<'IDENTIFIER'
            if ch == '<' and i + 2 < n and content[i + 1] == '<' and content[i + 2] == '<':
                j = i + 3
                # Skip optional whitespace
                while j < n and content[j] in ' \t':
                    j += 1
                # Check for nowdoc (quoted identifier)
                nowdoc = False
                if j < n and content[j] == "'":
                    nowdoc = True
                    j += 1
                # Read identifier
                id_start = j
                while j < n and (content[j].isalnum() or content[j] == '_'):
                    j += 1
                if j > id_start:
                    heredoc_id = content[id_start:j]
                    if nowdoc and j < n and content[j] == "'":
                        j += 1
                    # Skip to end of line
                    while j < n and content[j] != '\n':
                        j += 1
                    state = 5
                    i = j; continue
            if ch == "'":
                state = 3
            elif ch == '"':
                state = 4
            i += 1

        elif state == 1:  # line comment
            if ch == '\n':
                state = 0
            else:
                out[i] = ' '
            i += 1

        elif state == 2:  # block comment
            if ch == '*' and i + 1 < n and content[i + 1] == '/':
                out[i] = ' '; out[i + 1] = ' '
                state = 0
                i += 2; continue
            if ch != '\n':
                out[i] = ' '
            i += 1

        elif state == 3:  # single-quoted string (preserved)
            if ch == '\\' and i + 1 < n and content[i + 1] in ('\\', "'"):
                i += 2; continue
            if ch == "'":
                state = 0
            i += 1

        elif state == 4:  # double-quoted string (preserved)
            if ch == '\\' and i + 1 < n:
                i += 2; continue
            if ch == '"':
                state = 0
            i += 1

        elif state == 5:  # heredoc/nowdoc (preserved)
            if ch == '\n':
                # Check if next line starts with the heredoc identifier
                j = i + 1
                # Skip optional whitespace (for flexible heredoc)
                while j < n and content[j] in ' \t':
                    j += 1
                if content[j:j + len(heredoc_id)] == heredoc_id:
                    after = j + len(heredoc_id)
                    if after >= n or content[after] in ('\n', ';'):
                        state = 0
                        i = after; continue
                    if after < n and content[after] == ';':
                        state = 0
                        i = after + 1; continue
            i += 1

        else:
            i += 1

    return ''.join(out)


def extract_php_imports(filepath):
    """Extract imports from PHP files using a comment-aware state machine."""
    try:
        with open(filepath, encoding='utf-8', errors='replace') as f:
            content = f.read()
    except (IOError, OSError):
        return []

    cleaned = _strip_php_comments(content)
    imports = []

    for line in cleaned.split('\n'):
        stripped = line.strip()
        if not stripped:
            continue

        # use App\Services\UserService;
        # use App\Services\UserService as US;
        # use function App\Helpers\format;
        # use const App\Config\VERSION;
        m = re.match(r'use\s+(?:function\s+|const\s+)?([\w\\]+)\s*(?:as\s+\w+\s*)?;', stripped)
        if m:
            path = m.group(1)
            if path not in imports:
                imports.append(path)
            continue

        # use App\Models\{User, Role};
        m = re.match(r'use\s+(?:function\s+|const\s+)?([\w\\]+)\\\{([^}]+)\}', stripped)
        if m:
            prefix = m.group(1)
            items = m.group(2)
            for item in items.split(','):
                item = item.strip()
                if ' as ' in item:
                    item = item.split(' as ')[0].strip()
                if item:
                    full_path = prefix + '\\' + item
                    if full_path not in imports:
                        imports.append(full_path)
            continue

        # require/require_once/include/include_once
        m = re.match(
            r'(?:require_once|require|include_once|include)\s+[\'"](.+?)[\'"]',
            stripped
        )
        if m:
            path = m.group(1)
            if path not in imports:
                imports.append(path)

    return imports


# ---------------------------------------------------------------------------
# Ruby — comment-aware state-machine parser
# ---------------------------------------------------------------------------

def _strip_ruby_comments(content):
    """Strip Ruby comments, preserving string content and line structure.

    Handles:
    - Line comments: # through end of line
    - Block comments: =begin at start of line through =end at start of line
    - Single-quoted strings: '...' with \\\\ and \\' escapes (preserved)
    - Double-quoted strings: "..." with \\ escapes (preserved)
    - Heredoc: <<~ID, <<-ID, <<ID through ID at start of line (preserved)
    """
    out = list(content)
    i = 0
    n = len(content)
    # States: 0=code, 1=line_comment, 2=block_comment,
    #         3=single_string, 4=double_string, 5=heredoc
    state = 0
    heredoc_id = ""
    at_line_start = True

    while i < n:
        ch = content[i]

        if state == 0:  # code
            if at_line_start and ch == '=' and content[i:i + 6] == '=begin' and \
               (i + 6 >= n or content[i + 6] in (' ', '\t', '\n')):
                # Replace =begin line with spaces
                while i < n and content[i] != '\n':
                    out[i] = ' '
                    i += 1
                state = 2
                at_line_start = True
                continue
            if ch == '#':
                out[i] = ' '
                state = 1
                i += 1; continue
            # Heredoc: <<~ID, <<-ID, <<ID, <<~'ID', <<-'ID', <<'ID'
            if ch == '<' and i + 1 < n and content[i + 1] == '<':
                j = i + 2
                if j < n and content[j] in ('~', '-'):
                    j += 1
                # Check for quoted heredoc
                quote = None
                if j < n and content[j] in ("'", '"'):
                    quote = content[j]
                    j += 1
                id_start = j
                while j < n and (content[j].isalnum() or content[j] == '_'):
                    j += 1
                if j > id_start:
                    hid = content[id_start:j]
                    if quote and j < n and content[j] == quote:
                        j += 1
                    # Verify it's a heredoc (next meaningful char should be newline-ish or ,)
                    k = j
                    while k < n and content[k] in ' \t':
                        k += 1
                    if k < n and content[k] in ('\n', ',', '.', ')'):
                        heredoc_id = hid
                        # Skip to end of current line
                        while i < n and content[i] != '\n':
                            i += 1
                        state = 5
                        at_line_start = True
                        continue
            if ch == "'":
                state = 3
            elif ch == '"':
                state = 4
            at_line_start = (ch == '\n')
            i += 1

        elif state == 1:  # line comment
            if ch == '\n':
                state = 0
                at_line_start = True
            else:
                out[i] = ' '
            i += 1

        elif state == 2:  # block comment (=begin...=end)
            if at_line_start and ch == '=' and content[i:i + 4] == '=end' and \
               (i + 4 >= n or content[i + 4] in (' ', '\t', '\n')):
                while i < n and content[i] != '\n':
                    out[i] = ' '
                    i += 1
                state = 0
                at_line_start = True
                continue
            if ch != '\n':
                out[i] = ' '
            at_line_start = (ch == '\n')
            i += 1

        elif state == 3:  # single-quoted string (preserved)
            if ch == '\\' and i + 1 < n and content[i + 1] in ('\\', "'"):
                i += 2; continue
            if ch == "'":
                state = 0
            at_line_start = (ch == '\n')
            i += 1

        elif state == 4:  # double-quoted string (preserved)
            if ch == '\\' and i + 1 < n:
                i += 2; continue
            if ch == '"':
                state = 0
            at_line_start = (ch == '\n')
            i += 1

        elif state == 5:  # heredoc (preserved)
            if ch == '\n':
                # Check if next line starts with heredoc identifier
                j = i + 1
                # Skip optional leading whitespace
                while j < n and content[j] in ' \t':
                    j += 1
                if content[j:j + len(heredoc_id)] == heredoc_id:
                    after = j + len(heredoc_id)
                    if after >= n or content[after] in ('\n', ' ', '\t'):
                        state = 0
                        i = after
                        at_line_start = False
                        continue
                at_line_start = True
            else:
                at_line_start = False
            i += 1

        else:
            i += 1

    return ''.join(out)


def extract_ruby_imports(filepath):
    """Extract imports from Ruby files using a comment-aware state machine."""
    try:
        with open(filepath, encoding='utf-8', errors='replace') as f:
            content = f.read()
    except (IOError, OSError):
        return []

    cleaned = _strip_ruby_comments(content)
    imports = []

    for line in cleaned.split('\n'):
        stripped = line.strip()
        if not stripped:
            continue

        # require/require_relative/require_dependency/load
        m = re.match(
            r'''(?:require_relative|require_dependency|require|load)\s+['"](.+?)['"]''',
            stripped
        )
        if m:
            path = m.group(1)
            if path not in imports:
                imports.append(path)
            continue

        # autoload :Symbol, 'path'
        m = re.match(r'''autoload\s+:\w+,\s*['"](.+?)['"]''', stripped)
        if m:
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
    '.dart': extract_dart_imports,
    '.kt': extract_kotlin_imports,
    '.kts': extract_kotlin_imports,
    '.swift': extract_swift_imports,
    '.cs': extract_csharp_imports,
    '.php': extract_php_imports,
    '.rb': extract_ruby_imports,
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
