"""Thymus rule evaluation engine.

Replaces scripts/lib/eval-rules.sh — produces identical JSON output
for all four rule types: boundary, pattern, convention, dependency.

Python 3 stdlib only. No pip dependencies.
"""

import os
import re

from core import (
    debug_log,
    extract_imports_for_file,
    file_in_scope,
    import_is_forbidden,
    path_matches,
)


# ---------------------------------------------------------------------------
# Test colocation check — all 11 language patterns from eval-rules.sh
# ---------------------------------------------------------------------------

# Patterns that identify test files themselves (skip these)
_TEST_FILE_PATTERNS = [
    re.compile(r'\.(test|spec)\.'),          # foo.test.ts, foo.spec.js
    re.compile(r'\.d\.ts$'),                 # type definition files
    re.compile(r'(Test|Tests|IT|Spec)\.java$'),
    re.compile(r'_test\.(go|dart|rb)$'),
    re.compile(r'_spec\.rb$'),
    re.compile(r'(Test|Tests)\.kt$'),
    re.compile(r'(Tests)\.swift$'),
    re.compile(r'(Tests|Test)\.cs$'),
    re.compile(r'(Test)\.php$'),
]

# Extensions we check for test colocation
_SOURCE_EXT_RE = re.compile(
    r'\.(ts|js|py|java|go|rs|dart|kt|kts|swift|cs|php|rb)$'
)


def _is_test_file(rel_path: str) -> bool:
    """Return True if the file is itself a test file."""
    for pat in _TEST_FILE_PATTERNS:
        if pat.search(rel_path):
            return True
    return False


def check_test_colocation(abs_path: str, rel_path: str) -> bool:
    """Check if a source file has a colocated test file.

    Returns True (has test) or False (missing test).
    Implements ALL 11 language patterns from eval-rules.sh.
    """
    # Must be a recognized source file
    if not _SOURCE_EXT_RE.search(rel_path):
        return True

    # Skip test files themselves
    if _is_test_file(rel_path):
        return True

    base, ext = os.path.splitext(abs_path)
    ext_no_dot = ext.lstrip('.')

    # Generic: foo.test.ext or foo.spec.ext (works for all languages)
    if os.path.isfile(f"{base}.test.{ext_no_dot}") or \
       os.path.isfile(f"{base}.spec.{ext_no_dot}"):
        return True

    basename_no_ext = os.path.basename(base)
    dir_path = os.path.dirname(abs_path)

    if ext_no_dot == 'java':
        # Same directory: FooTest.java, FooTests.java, FooIT.java
        if (os.path.isfile(os.path.join(dir_path, f"{basename_no_ext}Test.java")) or
                os.path.isfile(os.path.join(dir_path, f"{basename_no_ext}Tests.java")) or
                os.path.isfile(os.path.join(dir_path, f"{basename_no_ext}IT.java"))):
            return True
        # Maven mirror: src/main/java -> src/test/java
        if '/src/main/java/' in abs_path:
            test_mirror_base = abs_path.replace('src/main/java', 'src/test/java')
            test_mirror_base = os.path.splitext(test_mirror_base)[0]
            if (os.path.isfile(f"{test_mirror_base}Test.java") or
                    os.path.isfile(f"{test_mirror_base}Tests.java") or
                    os.path.isfile(f"{test_mirror_base}IT.java")):
                return True

    elif ext_no_dot == 'go':
        # foo.go -> foo_test.go (same directory)
        test_name = f"{basename_no_ext}_test.go"
        if os.path.isfile(os.path.join(dir_path, test_name)):
            return True

    elif ext_no_dot == 'rs':
        # Check for #[cfg(test)] inside the file itself
        try:
            with open(abs_path, encoding='utf-8', errors='replace') as f:
                content = f.read()
            if '#[cfg(test)]' in content:
                return True
        except OSError:
            pass
        # Check tests/ directory at project root
        cwd = os.getcwd()
        if (os.path.isfile(os.path.join(cwd, 'tests', f"{basename_no_ext}.rs")) or
                os.path.isfile(os.path.join(cwd, 'tests', f"test_{basename_no_ext}.rs"))):
            return True

    elif ext_no_dot == 'dart':
        # Same directory: foo_test.dart
        if os.path.isfile(os.path.join(dir_path, f"{basename_no_ext}_test.dart")):
            return True
        # Mirror: lib/ -> test/
        if '/lib/' in abs_path:
            test_mirror_base = abs_path.replace('/lib/', '/test/')
            test_mirror_base = os.path.splitext(test_mirror_base)[0]
            if os.path.isfile(f"{test_mirror_base}_test.dart"):
                return True

    elif ext_no_dot in ('kt', 'kts'):
        # Same directory: FooTest.kt, FooTests.kt
        if (os.path.isfile(os.path.join(dir_path, f"{basename_no_ext}Test.kt")) or
                os.path.isfile(os.path.join(dir_path, f"{basename_no_ext}Tests.kt"))):
            return True
        # Maven/Gradle mirror: src/main/kotlin -> src/test/kotlin, src/main/java -> src/test/java
        if '/src/main/' in abs_path:
            test_mirror = abs_path.replace('src/main/kotlin', 'src/test/kotlin')
            test_mirror = test_mirror.replace('src/main/java', 'src/test/java')
            test_mirror_base = os.path.splitext(test_mirror)[0]
            if (os.path.isfile(f"{test_mirror_base}Test.kt") or
                    os.path.isfile(f"{test_mirror_base}Tests.kt")):
                return True

    elif ext_no_dot == 'swift':
        # Same directory: FooTests.swift
        if os.path.isfile(os.path.join(dir_path, f"{basename_no_ext}Tests.swift")):
            return True
        # SPM mirror: Sources/ -> Tests/
        if '/Sources/' in abs_path:
            test_mirror_base = abs_path.replace('/Sources/', '/Tests/')
            test_mirror_base = os.path.splitext(test_mirror_base)[0]
            if os.path.isfile(f"{test_mirror_base}Tests.swift"):
                return True

    elif ext_no_dot == 'cs':
        # Same directory: FooTests.cs, FooTest.cs
        if (os.path.isfile(os.path.join(dir_path, f"{basename_no_ext}Tests.cs")) or
                os.path.isfile(os.path.join(dir_path, f"{basename_no_ext}Test.cs"))):
            return True

    elif ext_no_dot == 'php':
        # Same directory: FooTest.php
        if os.path.isfile(os.path.join(dir_path, f"{basename_no_ext}Test.php")):
            return True
        # Mirror: src/ -> tests/
        if '/src/' in abs_path:
            test_mirror_base = abs_path.replace('/src/', '/tests/')
            test_mirror_base = os.path.splitext(test_mirror_base)[0]
            if os.path.isfile(f"{test_mirror_base}Test.php"):
                return True

    elif ext_no_dot == 'rb':
        # Same directory: foo_test.rb, foo_spec.rb
        if (os.path.isfile(os.path.join(dir_path, f"{basename_no_ext}_test.rb")) or
                os.path.isfile(os.path.join(dir_path, f"{basename_no_ext}_spec.rb"))):
            return True
        # Rails mirror: app/ -> test/ and app/ -> spec/
        if '/app/' in abs_path:
            test_mirror_base = abs_path.replace('/app/', '/test/')
            spec_mirror_base = abs_path.replace('/app/', '/spec/')
            test_mirror_base = os.path.splitext(test_mirror_base)[0]
            spec_mirror_base = os.path.splitext(spec_mirror_base)[0]
            if (os.path.isfile(f"{test_mirror_base}_test.rb") or
                    os.path.isfile(f"{spec_mirror_base}_spec.rb")):
                return True

    return False  # no test found


# ---------------------------------------------------------------------------
# Rule evaluation — produces identical JSON to eval-rules.sh
# ---------------------------------------------------------------------------


def eval_rule_for_file(abs_path: str, rel_path: str, invariant: dict) -> list:
    """Evaluate a single invariant against a file.

    Returns a list of violation dicts. Each dict matches the exact JSON
    schema that eval-rules.sh outputs via jq -cn.

    Handles four rule types: boundary, pattern, convention, dependency.
    """
    rule_id = invariant.get('id', '')
    rule_type = invariant.get('type', '')
    severity = invariant.get('severity', '')
    description = invariant.get('description', '')

    # Scope check
    if not file_in_scope(rel_path, invariant):
        return []

    if not os.path.isfile(abs_path):
        return []

    violations = []

    if rule_type == 'boundary':
        imports = extract_imports_for_file(abs_path)
        if not imports:
            return []
        for imp in imports:
            if not imp:
                continue
            if import_is_forbidden(imp, invariant):
                violations.append({
                    "rule": rule_id,
                    "severity": severity,
                    "message": description,
                    "file": rel_path,
                    "import": imp,
                })

    elif rule_type == 'pattern':
        forbidden_pattern = invariant.get('forbidden_pattern', '')
        if not forbidden_pattern:
            return []
        # Translate POSIX character classes to Python equivalents
        # (bash grep -E supports these but Python re does not)
        py_pattern = forbidden_pattern
        py_pattern = py_pattern.replace('[[:space:]]', r'\s')
        py_pattern = py_pattern.replace('[[:alpha:]]', '[a-zA-Z]')
        py_pattern = py_pattern.replace('[[:digit:]]', r'\d')
        py_pattern = py_pattern.replace('[[:alnum:]]', '[a-zA-Z0-9]')
        py_pattern = py_pattern.replace('[[:upper:]]', '[A-Z]')
        py_pattern = py_pattern.replace('[[:lower:]]', '[a-z]')
        py_pattern = py_pattern.replace('[[:punct:]]', r'[^\w\s]')
        py_pattern = py_pattern.replace('[[:blank:]]', r'[ \t]')
        try:
            pat = re.compile(py_pattern)
        except re.error:
            debug_log(f"Invalid regex in pattern rule {rule_id}: {forbidden_pattern}")
            return []
        try:
            with open(abs_path, encoding='utf-8', errors='replace') as f:
                for line_num, line in enumerate(f, 1):
                    if pat.search(line):
                        violations.append({
                            "rule": rule_id,
                            "severity": severity,
                            "message": description,
                            "file": rel_path,
                            "line": str(line_num),
                        })
                        break  # only first match, like grep | head -1
        except OSError:
            pass

    elif rule_type == 'convention':
        rule_text = invariant.get('rule', '')
        if re.search(r'test', rule_text, re.IGNORECASE):
            if not check_test_colocation(abs_path, rel_path):
                violations.append({
                    "rule": rule_id,
                    "severity": severity,
                    "message": "missing colocated test file",
                    "file": rel_path,
                })

    elif rule_type == 'dependency':
        package = invariant.get('package', '')
        if not package:
            return []
        # Check allowed_in — if file matches, skip
        allowed_in = invariant.get('allowed_in', [])
        in_allowed = False
        for allowed_glob in allowed_in:
            if path_matches(rel_path, allowed_glob):
                in_allowed = True
                break
        if in_allowed:
            return []
        # Check if file imports the package
        file_imports = extract_imports_for_file(abs_path)
        for imp in file_imports:
            if package in imp:
                violations.append({
                    "rule": rule_id,
                    "severity": severity,
                    "message": description,
                    "file": rel_path,
                    "package": package,
                })
                break  # one violation per file per rule

    return violations
