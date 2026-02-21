#!/usr/bin/env bash
set -euo pipefail

ROOT="$(realpath "$(dirname "$0")/..")"
EXTRACTOR="$ROOT/scripts/extract-imports.py"

echo "=== AST Import Extraction Tests ==="
echo ""

passed=0
failed=0

check_has() {
  local desc="$1" expected="$2" actual="$3"
  if echo "$actual" | grep -qF "$expected"; then
    echo "  ✓ $desc"
    ((passed++)) || true
  else
    echo "  ✗ $desc"
    echo "    expected to find: $expected"
    echo "    in: $actual"
    ((failed++)) || true
  fi
}

check_not_has() {
  local desc="$1" unwanted="$2" actual="$3"
  if echo "$actual" | grep -qF "$unwanted"; then
    echo "  ✗ $desc"
    echo "    should NOT contain: $unwanted"
    echo "    in: $actual"
    ((failed++)) || true
  else
    echo "  ✓ $desc"
    ((passed++)) || true
  fi
}

check_empty() {
  local desc="$1" actual="$2"
  if [ -z "$actual" ]; then
    echo "  ✓ $desc"
    ((passed++)) || true
  else
    echo "  ✗ $desc (expected empty, got: $actual)"
    ((failed++)) || true
  fi
}

check_count() {
  local desc="$1" expected="$2" actual="$3"
  local count
  if [ -z "$actual" ]; then
    count=0
  else
    count=$(echo "$actual" | wc -l | tr -d ' ')
  fi
  if [ "$count" -eq "$expected" ]; then
    echo "  ✓ $desc ($count imports)"
    ((passed++)) || true
  else
    echo "  ✗ $desc (got $count, expected $expected)"
    echo "    output: $actual"
    ((failed++)) || true
  fi
}

# --- Test 1: Basic JS/TS import extraction ---
echo "JS/TS basic import extraction:"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

cat > "$TMPDIR/basic.ts" << 'EOF'
import { foo } from '../lib/foo';
import * as bar from 'bar-package';
import baz from '../utils/baz';
import '../side-effect';
const x = require('express');
export { helper } from '../helpers/helper';
export * from '../utils/all';
import type { User } from '../models/user';
import('./lazy/chunk');
EOF

OUT=$(python3 "$EXTRACTOR" "$TMPDIR/basic.ts")
check_has "extracts import { X } from 'path'" "../lib/foo" "$OUT"
check_has "extracts import * as X from 'path'" "bar-package" "$OUT"
check_has "extracts default import" "../utils/baz" "$OUT"
check_has "extracts side-effect import" "../side-effect" "$OUT"
check_has "extracts require()" "express" "$OUT"
check_has "extracts export { X } from" "../helpers/helper" "$OUT"
check_has "extracts export * from" "../utils/all" "$OUT"
check_has "extracts import type" "../models/user" "$OUT"
check_has "extracts dynamic import()" "./lazy/chunk" "$OUT"
check_count "extracts exactly 9 imports" 9 "$OUT"

# --- Test 2: Comment filtering ---
echo ""
echo "Comment filtering:"

cat > "$TMPDIR/comments.ts" << 'EOF'
// import { db } from '../db/client';
// const x = require('prisma');
/*
import { foo } from '../forbidden/path';
const y = require('blocked');
*/
/**
 * @see import('../db/client')
 */
import { real } from '../real/import';
EOF

OUT=$(python3 "$EXTRACTOR" "$TMPDIR/comments.ts")
check_has "extracts real import" "../real/import" "$OUT"
check_not_has "ignores single-line comment import" "../db/client" "$OUT"
check_not_has "ignores single-line comment require" "prisma" "$OUT"
check_not_has "ignores block comment import" "../forbidden/path" "$OUT"
check_not_has "ignores block comment require" "blocked" "$OUT"
check_count "only 1 import from commented file" 1 "$OUT"

# --- Test 3: String literal filtering ---
echo ""
echo "String literal filtering:"

cat > "$TMPDIR/strings.ts" << 'EOF'
const msg1 = "import { db } from '../db/client'";
const msg2 = 'import { foo } from "../forbidden/path"';
const msg3 = "const x = require('blocked')";
import { real } from '../real/import';
EOF

OUT=$(python3 "$EXTRACTOR" "$TMPDIR/strings.ts")
check_has "extracts real import" "../real/import" "$OUT"
check_not_has "ignores double-quoted string import" "../db/client" "$OUT"
check_not_has "ignores single-quoted string import" "../forbidden/path" "$OUT"
check_not_has "ignores string require" "blocked" "$OUT"
check_count "only 1 import from string file" 1 "$OUT"

# --- Test 4: Template string filtering ---
echo ""
echo "Template string filtering:"

cat > "$TMPDIR/templates.ts" << 'EOF'
const tmpl = `import { db } from '../db/client'`;
const multi = `
  import { foo } from '../forbidden/path'
  line2
`;
import { real } from '../real/import';
EOF

OUT=$(python3 "$EXTRACTOR" "$TMPDIR/templates.ts")
check_has "extracts real import" "../real/import" "$OUT"
check_not_has "ignores template string import" "../db/client" "$OUT"
check_not_has "ignores multiline template import" "../forbidden/path" "$OUT"
check_count "only 1 import from template file" 1 "$OUT"

# --- Test 5: Mixed file (real + commented + string imports) ---
echo ""
echo "Mixed file (real + false positives):"

cat > "$TMPDIR/mixed.ts" << 'EOF'
// import { prisma } from '../db/client';  // commented out
import { UserController } from '../controllers/user.controller';
/* import { db } from '../db/direct' */
const msg = "import { prisma } from '../db/client'";
const msg2 = 'import { x } from "../db/other"';
const tmpl = `import { y } from '../db/template'`;
export const handler = { controller: new UserController() };
import type { User } from '../models/user';
const x = require('express');
export * from '../utils/helpers';
import('../lazy/module');
EOF

OUT=$(python3 "$EXTRACTOR" "$TMPDIR/mixed.ts")
check_has "extracts UserController import" "../controllers/user.controller" "$OUT"
check_has "extracts type import" "../models/user" "$OUT"
check_has "extracts require" "express" "$OUT"
check_has "extracts export *" "../utils/helpers" "$OUT"
check_has "extracts dynamic import" "../lazy/module" "$OUT"
check_not_has "ignores // commented import" "../db/client" "$OUT"
check_not_has "ignores /* */ blocked import" "../db/direct" "$OUT"
check_not_has "ignores double-string import" "../db/client" "$OUT"
check_not_has "ignores single-string import" "../db/other" "$OUT"
check_not_has "ignores template-string import" "../db/template" "$OUT"
check_count "exactly 5 real imports" 5 "$OUT"

# --- Test 6: Python imports ---
echo ""
echo "Python import extraction:"

cat > "$TMPDIR/test_py.py" << 'EOF'
import os
import sys
from pathlib import Path
from collections import OrderedDict
# import json  -- commented out
msg = "from os import path"  # string literal
from ..models import User
EOF

OUT=$(python3 "$EXTRACTOR" "$TMPDIR/test_py.py")
check_has "extracts import os" "os" "$OUT"
check_has "extracts import sys" "sys" "$OUT"
check_has "extracts from pathlib" "pathlib" "$OUT"
check_has "extracts from collections" "collections" "$OUT"
check_has "extracts relative from ..models" "models" "$OUT"
check_not_has "ignores commented import json" "json" "$OUT"
check_count "exactly 5 python imports" 5 "$OUT"

# --- Test 7: Edge cases ---
echo ""
echo "Edge cases:"

# Empty file
touch "$TMPDIR/empty.ts"
OUT=$(python3 "$EXTRACTOR" "$TMPDIR/empty.ts")
check_empty "empty file produces no output" "$OUT"

# Missing file
OUT=$(python3 "$EXTRACTOR" "$TMPDIR/nonexistent.ts" 2>/dev/null || true)
check_empty "missing file produces no output" "$OUT"

# Binary-ish file (not a real language extension — should produce nothing)
printf '\x89PNG\r\n' > "$TMPDIR/image.png"
OUT=$(python3 "$EXTRACTOR" "$TMPDIR/image.png" 2>/dev/null || true)
check_empty "non-language file produces no output" "$OUT"

# File with only comments
cat > "$TMPDIR/only-comments.ts" << 'EOF'
// import { a } from 'a';
/* import { b } from 'b'; */
// require('c');
EOF
OUT=$(python3 "$EXTRACTOR" "$TMPDIR/only-comments.ts")
check_empty "file with only comments produces no output" "$OUT"

# --- Test 8: Fixture integration ---
echo ""
echo "Fixture integration:"

# Unhealthy fixture should detect the real boundary violation
UNHEALTHY_OUT=$(python3 "$EXTRACTOR" "$ROOT/tests/fixtures/unhealthy-project/src/routes/users.ts")
check_has "unhealthy fixture: detects ../db/client import" "../db/client" "$UNHEALTHY_OUT"
check_has "unhealthy fixture: detects ../controllers/user.controller" "../controllers/user.controller" "$UNHEALTHY_OUT"

# Healthy fixture should not have db imports
HEALTHY_OUT=$(python3 "$EXTRACTOR" "$ROOT/tests/fixtures/healthy-project/src/routes/users.ts")
check_not_has "healthy fixture: no ../db/client import" "../db/client" "$HEALTHY_OUT"
check_has "healthy fixture: has ../controllers/user.controller" "../controllers/user.controller" "$HEALTHY_OUT"

# Commented-import fixture (false positive test case)
COMMENTED="$ROOT/tests/fixtures/unhealthy-project/src/routes/commented-import.ts"
if [ -f "$COMMENTED" ]; then
  COMMENTED_OUT=$(python3 "$EXTRACTOR" "$COMMENTED")
  check_not_has "commented-import fixture: no false positive on ../db/client" "../db/client" "$COMMENTED_OUT"
  check_has "commented-import fixture: extracts real UserController import" "../controllers/user.controller" "$COMMENTED_OUT"
else
  echo "  ~ commented-import.ts fixture not yet created (skipping)"
fi

echo ""
echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ] || exit 1
