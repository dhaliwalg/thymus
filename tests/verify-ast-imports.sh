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

# --- Test 7: Java imports ---
echo ""
echo "Java import extraction:"

cat > "$TMPDIR/TestJava.java" << 'EOF'
import java.util.*;
import static org.junit.Assert.*;
import com.example.service.UserService;
EOF

OUT=$(python3 "$EXTRACTOR" "$TMPDIR/TestJava.java")
check_has "extracts wildcard import java.util.*" "java.util.*" "$OUT"
check_has "extracts static wildcard import org.junit.Assert.*" "org.junit.Assert.*" "$OUT"
check_has "extracts regular import com.example.service.UserService" "com.example.service.UserService" "$OUT"
check_count "exactly 3 java imports" 3 "$OUT"

# --- Test 8: Go imports ---
echo ""
echo "Go import extraction:"

cat > "$TMPDIR/test_go.go" << 'EOF'
package main

import "fmt"
import alias "net/http"
import (
    "database/sql"
    "os"
    myalias "github.com/example/myapp/service"
)
// import "commented/out"
/* import "block/commented" */
var s = "import \"string/literal\""
var raw = `import "raw/string"`
EOF

OUT=$(python3 "$EXTRACTOR" "$TMPDIR/test_go.go")
check_has "extracts single import fmt" "fmt" "$OUT"
check_has "extracts aliased import net/http" "net/http" "$OUT"
check_has "extracts grouped import database/sql" "database/sql" "$OUT"
check_has "extracts grouped import os" "os" "$OUT"
check_has "extracts grouped aliased import" "github.com/example/myapp/service" "$OUT"
check_not_has "ignores line-commented import" "commented/out" "$OUT"
check_not_has "ignores block-commented import" "block/commented" "$OUT"
check_not_has "ignores import in double-quoted string" "string/literal" "$OUT"
check_not_has "ignores import in raw string" "raw/string" "$OUT"
check_count "exactly 5 Go imports" 5 "$OUT"

# --- Test 9: Rust imports ---
echo ""
echo "Rust import extraction:"

cat > "$TMPDIR/test_rust.rs" << 'EOF'
use std::collections::HashMap;
use crate::service::UserService;
use std::io::{self, Read, Write};
extern crate serde;
use std::io::*;
use std::result::Result as StdResult;
// use commented::out;
/* use block::commented; */
/*
  /* nested block use nested::comment; */
*/
let s = "use string::literal;";
let raw = r#"use raw::string;"#;
EOF

OUT=$(python3 "$EXTRACTOR" "$TMPDIR/test_rust.rs")
check_has "extracts use std::collections::HashMap" "std::collections::HashMap" "$OUT"
check_has "extracts use crate::service::UserService" "crate::service::UserService" "$OUT"
check_has "extracts grouped use std::io::self" "std::io::self" "$OUT"
check_has "extracts grouped use std::io::Read" "std::io::Read" "$OUT"
check_has "extracts grouped use std::io::Write" "std::io::Write" "$OUT"
check_has "extracts extern crate serde" "serde" "$OUT"
check_has "extracts glob use std::io::*" "std::io::*" "$OUT"
check_has "extracts renamed use std::result::Result" "std::result::Result" "$OUT"
check_not_has "ignores line-commented use" "commented::out" "$OUT"
check_not_has "ignores block-commented use" "block::commented" "$OUT"
check_not_has "ignores nested block comment" "nested::comment" "$OUT"
check_not_has "ignores use in string literal" "string::literal" "$OUT"
check_not_has "ignores use in raw string" "raw::string" "$OUT"
check_count "exactly 8 Rust imports" 8 "$OUT"

# --- Test: Dart imports ---
echo ""
echo "Dart import extraction:"

cat > "$TMPDIR/test_dart.dart" << 'EOF'
import 'package:flutter/material.dart';
import 'dart:async';
import '../utils/helpers.dart';
import 'package:http/http.dart' as http;
export 'package:foo/bar.dart';
part 'src/detail.dart';
// import 'commented/out.dart';
/* import 'block/commented.dart'; */
var s = "import 'string/literal.dart';";
var raw = r"import 'raw/string.dart';";
EOF

OUT=$(python3 "$EXTRACTOR" "$TMPDIR/test_dart.dart")
check_has "extracts flutter material" "package:flutter/material.dart" "$OUT"
check_has "extracts dart:async" "dart:async" "$OUT"
check_has "extracts relative import" "../utils/helpers.dart" "$OUT"
check_has "extracts aliased import" "package:http/http.dart" "$OUT"
check_has "extracts export" "package:foo/bar.dart" "$OUT"
check_has "extracts part directive" "src/detail.dart" "$OUT"
check_not_has "ignores line comment" "commented/out.dart" "$OUT"
check_not_has "ignores block comment" "block/commented.dart" "$OUT"
check_not_has "ignores string literal" "string/literal.dart" "$OUT"
check_not_has "ignores raw string" "raw/string.dart" "$OUT"
check_count "exactly 6 Dart imports" 6 "$OUT"

# --- Test: Kotlin imports ---
echo ""
echo "Kotlin import extraction:"

cat > "$TMPDIR/test_kotlin.kt" << 'EOF'
import kotlin.collections.List
import com.example.service.UserService
import com.example.repo.*
import com.example.util.Helper as H
// import commented.Out
/* import block.Commented */
/* outer /* nested */ still comment import nested.Comment */
val s = "import string.Literal"
EOF

OUT=$(python3 "$EXTRACTOR" "$TMPDIR/test_kotlin.kt")
check_has "extracts kotlin.collections.List" "kotlin.collections.List" "$OUT"
check_has "extracts UserService" "com.example.service.UserService" "$OUT"
check_has "extracts wildcard" "com.example.repo.*" "$OUT"
check_has "extracts aliased" "com.example.util.Helper" "$OUT"
check_not_has "ignores line comment" "commented.Out" "$OUT"
check_not_has "ignores block comment" "block.Commented" "$OUT"
check_not_has "ignores nested comment" "nested.Comment" "$OUT"
check_not_has "ignores string literal" "string.Literal" "$OUT"
check_count "exactly 4 Kotlin imports" 4 "$OUT"

# --- Test: Swift imports ---
echo ""
echo "Swift import extraction:"

cat > "$TMPDIR/test_swift.swift" << 'EOF'
import Foundation
import UIKit
import struct Foundation.Date
@testable import MyApp
// import CommentedOut
/* import BlockCommented */
/* outer /* nested */ import NestedComment */
let s = "import StringLiteral"
EOF

OUT=$(python3 "$EXTRACTOR" "$TMPDIR/test_swift.swift")
check_has "extracts Foundation" "Foundation" "$OUT"
check_has "extracts UIKit" "UIKit" "$OUT"
check_has "extracts struct import module" "Foundation" "$OUT"
check_has "extracts testable import" "MyApp" "$OUT"
check_not_has "ignores line comment" "CommentedOut" "$OUT"
check_not_has "ignores block comment" "BlockCommented" "$OUT"
check_not_has "ignores nested comment" "NestedComment" "$OUT"
check_not_has "ignores string literal" "StringLiteral" "$OUT"
check_count "exactly 3 unique Swift imports" 3 "$OUT"

# --- Test: C# imports ---
echo ""
echo "C# import extraction:"

cat > "$TMPDIR/test_csharp.cs" << 'EOF'
using System;
using System.Collections.Generic;
using static System.Math;
using Alias = System.IO.Path;
// using Commented.Out;
/* using Block.Commented; */
string s = "using String.Literal;";
string v = @"using Verbatim.Literal;";

namespace MyApp {
    class Foo {
        void Bar() {
            using var stream = File.OpenRead("x");
        }
    }
}
EOF

OUT=$(python3 "$EXTRACTOR" "$TMPDIR/test_csharp.cs")
check_has "extracts System" "System" "$OUT"
check_has "extracts Generic" "System.Collections.Generic" "$OUT"
check_has "extracts static" "System.Math" "$OUT"
check_has "extracts alias target" "System.IO.Path" "$OUT"
check_not_has "ignores line comment" "Commented.Out" "$OUT"
check_not_has "ignores block comment" "Block.Commented" "$OUT"
check_not_has "ignores string literal" "String.Literal" "$OUT"
check_not_has "ignores verbatim string" "Verbatim.Literal" "$OUT"
check_not_has "ignores using statement in method" "File" "$OUT"
check_count "exactly 4 C# imports" 4 "$OUT"

# --- Test: PHP imports ---
echo ""
echo "PHP import extraction:"

cat > "$TMPDIR/test_php.php" << 'EOF'
<?php
use App\Services\UserService;
use App\Services\AuthService as Auth;
use App\Models\{User, Role};
use function App\Helpers\format;
require 'vendor/autoload.php';
require_once 'config/app.php';
// use Commented\Out;
/* use Block\Commented; */
$s = "use String\Literal;";
EOF

OUT=$(python3 "$EXTRACTOR" "$TMPDIR/test_php.php")
check_has "extracts UserService" 'App\Services\UserService' "$OUT"
check_has "extracts aliased" 'App\Services\AuthService' "$OUT"
check_has "extracts grouped User" 'App\Models\User' "$OUT"
check_has "extracts grouped Role" 'App\Models\Role' "$OUT"
check_has "extracts function use" 'App\Helpers\format' "$OUT"
check_has "extracts require" "vendor/autoload.php" "$OUT"
check_has "extracts require_once" "config/app.php" "$OUT"
check_not_has "ignores line comment" "Commented" "$OUT"
check_not_has "ignores block comment" "Block" "$OUT"
check_not_has "ignores string" "String" "$OUT"
check_count "exactly 7 PHP imports" 7 "$OUT"

# --- Test: Ruby imports ---
echo ""
echo "Ruby import extraction:"

cat > "$TMPDIR/test_ruby.rb" << 'EOF'
require 'json'
require "active_record"
require_relative 'models/user'
require_relative '../lib/helpers'
load 'config/routes.rb'
autoload :UserService, 'services/user_service'
# require 'commented_out'
=begin
require 'block_commented'
=end
s = "require 'string_literal'"
EOF

OUT=$(python3 "$EXTRACTOR" "$TMPDIR/test_ruby.rb")
check_has "extracts json" "json" "$OUT"
check_has "extracts active_record" "active_record" "$OUT"
check_has "extracts require_relative" "models/user" "$OUT"
check_has "extracts relative parent" "../lib/helpers" "$OUT"
check_has "extracts load" "config/routes.rb" "$OUT"
check_has "extracts autoload" "services/user_service" "$OUT"
check_not_has "ignores line comment" "commented_out" "$OUT"
check_not_has "ignores block comment" "block_commented" "$OUT"
check_not_has "ignores string literal" "string_literal" "$OUT"
check_count "exactly 6 Ruby imports" 6 "$OUT"

# --- Test 10: Edge cases ---
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

# --- Test 11: Fixture integration ---
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
