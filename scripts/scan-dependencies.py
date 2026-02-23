#!/usr/bin/env python3
"""Thymus scan-dependencies.py

Detects language, framework, external deps, and import relationships.
Replaces scan-dependencies.sh with os.walk + regex — no subprocess pipelines.

Usage: python3 scan-dependencies.py [project_root]
Output: JSON to stdout

Python 3 stdlib only. No pip dependencies.
"""

import collections
import json
import os
import re
import sys
import xml.etree.ElementTree as ET

# ---------------------------------------------------------------------------
# Bootstrap: add scripts/ and scripts/lib/ to import path
# ---------------------------------------------------------------------------

_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
_LIB_DIR = os.path.join(_SCRIPT_DIR, "lib")
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)

from core import (  # noqa: E402
    THYMUS_IGNORED_PATHS,
    extract_imports_for_file,
    debug_log,
)

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

IGNORED_PATHS = set(THYMUS_IGNORED_PATHS)

# Extension sets for source file scanning
ALL_SOURCE_EXTS = {
    ".ts", ".js", ".py", ".go", ".java", ".rs",
    ".dart", ".kt", ".kts", ".swift", ".cs", ".php", ".rb",
}

# ---------------------------------------------------------------------------
# Language detection
# ---------------------------------------------------------------------------

def _has_ts_files(project_root: str) -> bool:
    """Check if there are .ts files under src/ (up to depth 2)."""
    src = os.path.join(project_root, "src")
    if not os.path.isdir(src):
        return False
    for dirpath, dirnames, filenames in os.walk(src):
        rel = os.path.relpath(dirpath, src)
        depth = 0 if rel == "." else rel.count(os.sep) + 1
        if depth > 2:
            dirnames[:] = []
            continue
        for f in filenames:
            if f.endswith(".ts"):
                return True
    return False


def _has_files_with_ext(root: str, ext: str, max_depth: int = 4) -> bool:
    """Check if files with given extension exist under root."""
    if not os.path.isdir(root):
        return False
    for dirpath, dirnames, filenames in os.walk(root):
        rel = os.path.relpath(dirpath, root)
        depth = 0 if rel == "." else rel.count(os.sep) + 1
        if depth > max_depth:
            dirnames[:] = []
            continue
        for f in filenames:
            if f.endswith(ext):
                return True
    return False


def _has_glob_in_dir(root: str, ext: str, max_depth: int = 1) -> bool:
    """Check if files matching an extension exist in root at limited depth."""
    if not os.path.isdir(root):
        return False
    for dirpath, dirnames, filenames in os.walk(root):
        rel = os.path.relpath(dirpath, root)
        depth = 0 if rel == "." else rel.count(os.sep) + 1
        if depth > max_depth:
            dirnames[:] = []
            continue
        for f in filenames:
            if f.endswith(ext):
                return True
    return False


def detect_language(project_root: str) -> str:
    """Detect the primary programming language."""
    p = lambda f: os.path.join(project_root, f)

    if os.path.isfile(p("package.json")):
        if os.path.isfile(p("tsconfig.json")) or _has_ts_files(project_root):
            return "typescript"
        return "javascript"

    if (os.path.isfile(p("pyproject.toml")) or os.path.isfile(p("setup.py")) or
            os.path.isfile(p("requirements.txt"))):
        return "python"

    if os.path.isfile(p("go.mod")):
        return "go"

    if os.path.isfile(p("Cargo.toml")):
        return "rust"

    if (os.path.isfile(p("pom.xml")) or os.path.isfile(p("build.gradle")) or
            os.path.isfile(p("build.gradle.kts"))):
        # Kotlin check
        if os.path.isfile(p("build.gradle.kts")):
            try:
                with open(p("build.gradle.kts")) as f:
                    if "kotlin" in f.read():
                        return "kotlin"
            except OSError:
                pass
        if _has_files_with_ext(os.path.join(project_root, "src"), ".kt", 4):
            return "kotlin"
        return "java"

    if os.path.isfile(p("pubspec.yaml")):
        return "dart"

    if os.path.isfile(p("Package.swift")):
        return "swift"
    if _has_glob_in_dir(project_root, ".xcodeproj", 0) or \
       _has_glob_in_dir(project_root, ".xcworkspace", 0):
        return "swift"

    if _has_files_with_ext(project_root, ".csproj", 2) or \
       _has_glob_in_dir(project_root, ".sln", 0):
        return "csharp"

    if os.path.isfile(p("composer.json")):
        return "php"

    if os.path.isfile(p("Gemfile")) or os.path.isfile(p("Rakefile")):
        return "ruby"

    return "unknown"


# ---------------------------------------------------------------------------
# Framework detection
# ---------------------------------------------------------------------------

def _read_file_safe(path: str) -> str:
    """Read a file, returning empty string on error."""
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return ""


def _load_json_safe(path: str) -> dict:
    """Load JSON file, returning empty dict on error."""
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return {}


def _json_has_dep(data: dict, dep_name: str) -> bool:
    """Check if a dependency exists in package.json deps or devDeps."""
    deps = data.get("dependencies", {}) or {}
    dev_deps = data.get("devDependencies", {}) or {}
    return dep_name in deps or dep_name in dev_deps


def detect_framework(project_root: str, language: str) -> str:
    """Detect the framework based on language and manifest files."""
    p = lambda f: os.path.join(project_root, f)

    if language in ("typescript", "javascript"):
        pkg = _load_json_safe(p("package.json"))
        if not pkg:
            return "unknown"
        if _json_has_dep(pkg, "next"):
            return "nextjs"
        if _json_has_dep(pkg, "express"):
            return "express"
        if _json_has_dep(pkg, "@nestjs/core"):
            return "nestjs"
        if _json_has_dep(pkg, "fastify"):
            return "fastify"
        return "unknown"

    elif language == "python":
        for path in (p("requirements.txt"), p("pyproject.toml")):
            content = _read_file_safe(path)
            if "django" in content:
                return "django"
            if "fastapi" in content:
                return "fastapi"
        return "unknown"

    elif language == "java":
        build_content = ""
        for bf in ("pom.xml", "build.gradle", "build.gradle.kts"):
            if os.path.isfile(p(bf)):
                build_content = _read_file_safe(p(bf))
                break
        if re.search(r"spring-boot-starter-web|spring-webmvc", build_content):
            if "spring-boot-starter" in build_content:
                return "spring-boot"
            return "spring-mvc"
        if re.search(r"quarkus-core|quarkus-bom", build_content):
            return "quarkus"
        if re.search(r"micronaut-core|micronaut-bom", build_content):
            return "micronaut"
        if "dropwizard" in build_content:
            return "dropwizard"
        return "unknown"

    elif language == "go":
        content = _read_file_safe(p("go.mod"))
        if not content:
            return "unknown"
        if "github.com/gin-gonic/gin" in content:
            return "gin"
        if "github.com/labstack/echo" in content:
            return "echo"
        if "github.com/gofiber/fiber" in content:
            return "fiber"
        if "github.com/gorilla/mux" in content:
            return "gorilla"
        if "github.com/go-chi/chi" in content:
            return "chi"
        return "unknown"

    elif language == "rust":
        content = _read_file_safe(p("Cargo.toml"))
        if not content:
            return "unknown"
        if "actix-web" in content:
            return "actix"
        if "axum" in content:
            return "axum"
        if "rocket" in content:
            return "rocket"
        if "warp" in content:
            return "warp"
        if "tide" in content:
            return "tide"
        return "unknown"

    elif language == "kotlin":
        build_content = ""
        for bf in ("build.gradle.kts", "build.gradle", "pom.xml"):
            if os.path.isfile(p(bf)):
                build_content = _read_file_safe(p(bf))
                break
        if "spring-boot" in build_content:
            return "spring-boot"
        if "io.ktor" in build_content:
            return "ktor"
        if "io.micronaut" in build_content:
            return "micronaut"
        return "unknown"

    elif language == "dart":
        content = _read_file_safe(p("pubspec.yaml"))
        if not content:
            return "unknown"
        if "flutter:" in content or "flutter_test:" in content:
            return "flutter"
        if "aqueduct:" in content:
            return "aqueduct"
        if "shelf:" in content:
            return "shelf"
        if re.search(r"angel_framework:|angel3_framework:", content):
            return "angel"
        return "unknown"

    elif language == "swift":
        if os.path.isfile(p("Package.swift")):
            content = _read_file_safe(p("Package.swift"))
            if "vapor" in content:
                return "vapor"
            return "spm"
        if _has_glob_in_dir(project_root, ".xcodeproj", 0) or \
           _has_glob_in_dir(project_root, ".xcworkspace", 0):
            return "ios"
        return "unknown"

    elif language == "csharp":
        csproj_content = ""
        # Find first .csproj within depth 2
        for dirpath, dirnames, filenames in os.walk(project_root):
            rel = os.path.relpath(dirpath, project_root)
            depth = 0 if rel == "." else rel.count(os.sep) + 1
            if depth > 2:
                dirnames[:] = []
                continue
            for f in filenames:
                if f.endswith(".csproj"):
                    csproj_content = _read_file_safe(os.path.join(dirpath, f))
                    break
            if csproj_content:
                break
        if re.search(r"Microsoft\.AspNetCore|Microsoft\.NET\.Sdk\.Web", csproj_content):
            return "aspnet"
        if "Xamarin" in csproj_content:
            return "xamarin"
        if "Microsoft.Maui" in csproj_content:
            return "maui"
        return "unknown"

    elif language == "php":
        pkg = _load_json_safe(p("composer.json"))
        if not pkg:
            return "unknown"
        req = pkg.get("require", {}) or {}
        if "laravel/framework" in req or "laravel/lumen-framework" in req:
            return "laravel"
        if any(k.startswith("symfony/") for k in req):
            return "symfony"
        if "slim/slim" in req:
            return "slim"
        if "yiisoft/yii2" in req:
            return "yii"
        return "unknown"

    elif language == "ruby":
        content = _read_file_safe(p("Gemfile"))
        if not content:
            return "unknown"
        if re.search(r"""['"]rails['"]""", content):
            return "rails"
        if re.search(r"""['"]sinatra['"]""", content):
            return "sinatra"
        if re.search(r"""['"]hanami['"]""", content):
            return "hanami"
        return "unknown"

    return "unknown"


# ---------------------------------------------------------------------------
# External dependencies
# ---------------------------------------------------------------------------

def get_external_deps(project_root: str, language: str) -> list:
    """Extract external dependency names from manifest files."""
    p = lambda f: os.path.join(project_root, f)

    if language in ("typescript", "javascript"):
        pkg = _load_json_safe(p("package.json"))
        if pkg:
            deps = dict(pkg.get("dependencies", {}) or {})
            deps.update(pkg.get("devDependencies", {}) or {})
            return sorted(deps.keys())
        return []

    elif language == "python":
        if os.path.isfile(p("requirements.txt")):
            result = []
            for line in _read_file_safe(p("requirements.txt")).splitlines():
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                # Strip version specifiers
                name = re.split(r"[>=<!\[]", line)[0].strip()
                if name:
                    result.append(name)
            return result
        return []

    elif language == "go":
        if os.path.isfile(p("go.mod")):
            content = _read_file_safe(p("go.mod"))
            # Find lines after 'require' keyword
            in_require = False
            deps = []
            for line in content.splitlines():
                stripped = line.strip()
                if stripped.startswith("require"):
                    in_require = True
                    # Single-line require
                    m = re.search(r'require\s+(\S+)\s+', stripped)
                    if m:
                        deps.append(m.group(1))
                    continue
                if in_require:
                    if stripped == ")":
                        in_require = False
                        continue
                    # Match module path
                    m = re.match(r'([a-z0-9._-]+/[a-z0-9./_-]+)', stripped)
                    if m:
                        deps.append(m.group(1))
            return deps
        return []

    elif language == "java":
        if os.path.isfile(p("pom.xml")):
            return _parse_pom_deps(p("pom.xml"))
        for gf in ("build.gradle", "build.gradle.kts"):
            if os.path.isfile(p(gf)):
                return _parse_gradle_deps(p(gf))
        return []

    return []


def _parse_pom_deps(pom_path: str) -> list:
    """Parse Maven pom.xml for dependencies."""
    try:
        tree = ET.parse(pom_path)
        root = tree.getroot()
        ns = {"m": "http://maven.apache.org/POM/4.0.0"}
        deps_els = root.findall(".//m:dependency", ns)
        if not deps_els:
            deps_els = root.findall(".//dependency")
        deps = []
        for dep in deps_els:
            group = dep.find("m:groupId", ns)
            if group is None:
                group = dep.find("groupId")
            artifact = dep.find("m:artifactId", ns)
            if artifact is None:
                artifact = dep.find("artifactId")
            version = dep.find("m:version", ns)
            if version is None:
                version = dep.find("version")
            if group is not None and artifact is not None:
                v = version.text if version is not None else "managed"
                deps.append(f"{group.text}:{artifact.text}:{v}")
        return deps
    except Exception:
        return []


def _parse_gradle_deps(gradle_path: str) -> list:
    """Parse Gradle build file for dependencies."""
    content = _read_file_safe(gradle_path)
    pattern = re.compile(
        r"""(?:implementation|compile|api|runtimeOnly|compileOnly|testImplementation)"""
        r"""\s*['\(]['"]([^'"]+)['"]"""
    )
    deps = []
    for m in pattern.finditer(content):
        deps.append(m.group(1))
    return deps


# ---------------------------------------------------------------------------
# Import frequency
# ---------------------------------------------------------------------------

# Language-specific import regex patterns (matching bash grep patterns)
_IMPORT_PATTERNS = {
    "typescript": re.compile(r"""from\s+['"]([./][^'"]*?)['"]"""),
    "javascript": re.compile(r"""from\s+['"]([./][^'"]*?)['"]"""),
    "python": re.compile(r"""^(?:from\s+(\.[^\s]+)|import\s+(\.[^\s]+))""", re.MULTILINE),
    "go": re.compile(r'"([a-z0-9_-]+/.+?)"'),
    "java": re.compile(r"^import\s+(?:static\s+)?([a-z][\w.]*)", re.MULTILINE),
    "kotlin": re.compile(r"^import\s+([a-z][\w.]*)", re.MULTILINE),
    "dart": re.compile(r"""^import\s+['"]package:([^'"]+)['"]""", re.MULTILINE),
    "swift": re.compile(r"^import\s+(\w+)", re.MULTILINE),
    "csharp": re.compile(r"^using\s+([A-Z][\w.]*)", re.MULTILINE),
    "php": re.compile(r"^use\s+([A-Z][\w\\]*)", re.MULTILINE),
    "ruby": re.compile(r"^require\S*\s+['\"](.+?)['\"]", re.MULTILINE),
    "rust": re.compile(r"^use\s+(.+?)\s*;", re.MULTILINE),
}

# File extensions to scan per language
_LANG_EXTS = {
    "typescript": {".ts", ".js"},
    "javascript": {".ts", ".js"},
    "python": {".py"},
    "go": {".go"},
    "java": {".java"},
    "kotlin": {".kt", ".kts"},
    "dart": {".dart"},
    "swift": {".swift"},
    "csharp": {".cs"},
    "php": {".php"},
    "ruby": {".rb"},
    "rust": {".rs"},
}


def get_import_frequency(project_root: str, language: str) -> list:
    """Get top 20 most-imported internal paths."""
    pattern = _IMPORT_PATTERNS.get(language)
    if pattern is None:
        return []

    exts = _LANG_EXTS.get(language, set())
    counter = collections.Counter()

    for dirpath, dirnames, filenames in os.walk(project_root):
        dirnames[:] = [d for d in dirnames if d not in IGNORED_PATHS]
        for fname in filenames:
            _, ext = os.path.splitext(fname)
            if ext not in exts:
                continue
            fpath = os.path.join(dirpath, fname)
            try:
                with open(fpath, encoding="utf-8", errors="replace") as f:
                    content = f.read()
            except OSError:
                continue

            for m in pattern.finditer(content):
                # For python, group(1) or group(2) may match
                path = m.group(1) or (m.group(2) if m.lastindex and m.lastindex >= 2 else None)
                if path:
                    # Clean up like the bash sed pipeline:
                    # Remove from ['"]/['"]: the regex already captures without quotes
                    counter[path] += 1

    # Top 20 by count descending
    top20 = counter.most_common(20)
    return [{"path": path, "count": count} for path, count in top20]


# ---------------------------------------------------------------------------
# Cross-module imports
# ---------------------------------------------------------------------------

def _get_cross_module_imports_js_ts_py(project_root: str, language: str) -> list:
    """Cross-module imports for JS/TS/Python."""
    src_root = os.path.join(project_root, "src")
    if not os.path.isdir(src_root):
        src_root = project_root

    if language == "python":
        grep_re = re.compile(r"from\s+\.\.([a-z_]+)")
    else:
        grep_re = re.compile(r"""from\s+['"`]\.\./([a-z_-]+)""")

    results = set()

    # Get top-level module directories
    try:
        entries = os.listdir(src_root)
    except OSError:
        return []

    module_dirs = [
        d for d in entries
        if os.path.isdir(os.path.join(src_root, d)) and d not in IGNORED_PATHS
    ]

    for from_module in module_dirs:
        module_path = os.path.join(src_root, from_module)
        for dirpath, dirnames, filenames in os.walk(module_path):
            dirnames[:] = [d for d in dirnames if d not in IGNORED_PATHS]
            for fname in filenames:
                _, ext = os.path.splitext(fname)
                if ext not in ALL_SOURCE_EXTS:
                    continue
                fpath = os.path.join(dirpath, fname)
                try:
                    with open(fpath, encoding="utf-8", errors="replace") as f:
                        content = f.read()
                except OSError:
                    continue

                for m in grep_re.finditer(content):
                    to_module = m.group(1)
                    if to_module and to_module != from_module:
                        results.add((from_module, to_module))

    return sorted(
        [{"from": f, "to": t} for f, t in results],
        key=lambda x: (x["from"], x["to"])
    )


def _get_cross_module_imports_java(project_root: str, language: str) -> list:
    """Cross-module imports for Java/Kotlin."""
    file_ext = ".kt" if language == "kotlin" else ".java"
    src_subdir = "java"
    if language == "kotlin":
        if os.path.isdir(os.path.join(project_root, "src/main/kotlin")):
            src_subdir = "kotlin"

    java_src = os.path.join(project_root, "src/main", src_subdir)
    if not os.path.isdir(java_src):
        return []

    # Find the base package directory: walk down until we find branching dirs
    # or source files
    first_file = None
    for dirpath, dirnames, filenames in os.walk(java_src):
        for f in filenames:
            if f.endswith(file_ext):
                first_file = os.path.join(dirpath, f)
                break
        if first_file:
            break

    if not first_file:
        return []

    # Walk up from the first file to find the base package dir
    java_root = os.path.dirname(first_file)
    parent = os.path.dirname(java_root)
    while parent != java_src and parent != "/":
        try:
            subdirs = [d for d in os.listdir(parent) if os.path.isdir(os.path.join(parent, d))]
        except OSError:
            break
        if len(subdirs) > 1:
            java_root = parent
            break
        java_root = parent
        parent = os.path.dirname(parent)

    if not os.path.isdir(java_root):
        return []

    # Get base package name from directory structure
    rel_base = os.path.relpath(java_root, java_src)
    base_package = rel_base.replace(os.sep, ".")

    # Enumerate top-level packages
    try:
        top_dirs = [
            d for d in os.listdir(java_root)
            if os.path.isdir(os.path.join(java_root, d))
        ]
    except OSError:
        return []

    results = set()
    for from_module in top_dirs:
        module_path = os.path.join(java_root, from_module)
        for dirpath, dirnames, filenames in os.walk(module_path):
            for fname in filenames:
                if not fname.endswith(file_ext):
                    continue
                fpath = os.path.join(dirpath, fname)
                imports = extract_imports_for_file(fpath)
                for imp in imports:
                    if imp.startswith(base_package + "."):
                        sub = imp[len(base_package) + 1:].split(".")[0]
                        if sub and sub != from_module:
                            results.add((from_module, sub))

    return sorted(
        [{"from": f, "to": t} for f, t in results],
        key=lambda x: (x["from"], x["to"])
    )


def _get_cross_module_imports_go(project_root: str) -> list:
    """Cross-module imports for Go."""
    go_mod = os.path.join(project_root, "go.mod")
    if not os.path.isfile(go_mod):
        return []

    # Read module path
    module_path = ""
    for line in _read_file_safe(go_mod).splitlines():
        if line.startswith("module "):
            module_path = line.split()[1] if len(line.split()) > 1 else ""
            break
    if not module_path:
        return []

    src_root = os.path.join(project_root, "src")
    if not os.path.isdir(src_root):
        src_root = project_root

    results = set()
    for dirpath, dirnames, filenames in os.walk(src_root):
        dirnames[:] = [d for d in dirnames if d not in IGNORED_PATHS]
        for fname in filenames:
            if not fname.endswith(".go") or fname.endswith("_test.go"):
                continue
            fpath = os.path.join(dirpath, fname)
            from_module = os.path.basename(dirpath)

            for imp in extract_imports_for_file(fpath):
                if imp.startswith(module_path + "/"):
                    rel_import = imp[len(module_path) + 1:]
                    # Strip src/ prefix if present
                    if rel_import.startswith("src/"):
                        rel_import = rel_import[4:]
                    to_module = rel_import.split("/")[0]
                    if to_module and to_module != from_module:
                        results.add((from_module, to_module))

    return sorted(
        [{"from": f, "to": t} for f, t in results],
        key=lambda x: (x["from"], x["to"])
    )


def _get_cross_module_imports_rust(project_root: str) -> list:
    """Cross-module imports for Rust."""
    src_root = os.path.join(project_root, "src")
    if not os.path.isdir(src_root):
        return []

    results = set()
    for dirpath, dirnames, filenames in os.walk(src_root):
        dirnames[:] = [d for d in dirnames if d not in IGNORED_PATHS]
        for fname in filenames:
            if not fname.endswith(".rs"):
                continue
            fpath = os.path.join(dirpath, fname)
            from_dir = dirpath
            if from_dir == src_root:
                from_module = os.path.splitext(fname)[0]
            else:
                from_module = os.path.basename(from_dir)

            for imp in extract_imports_for_file(fpath):
                if imp.startswith("crate::"):
                    to_module = imp[7:].split(":")[0]
                    if to_module and to_module != from_module:
                        results.add((from_module, to_module))

    return sorted(
        [{"from": f, "to": t} for f, t in results],
        key=lambda x: (x["from"], x["to"])
    )


def _get_cross_module_imports_dart(project_root: str) -> list:
    """Cross-module imports for Dart."""
    pubspec = os.path.join(project_root, "pubspec.yaml")
    if not os.path.isfile(pubspec):
        return []

    # Read package name
    package_name = ""
    for line in _read_file_safe(pubspec).splitlines():
        if line.startswith("name:"):
            package_name = line.split(":", 1)[1].strip().strip("'\"")
            break
    if not package_name:
        return []

    lib_root = os.path.join(project_root, "lib")
    if not os.path.isdir(lib_root):
        return []

    prefix = f"package:{package_name}/"
    results = set()

    for dirpath, dirnames, filenames in os.walk(lib_root):
        dirnames[:] = [d for d in dirnames if d not in IGNORED_PATHS]
        for fname in filenames:
            if not fname.endswith(".dart"):
                continue
            fpath = os.path.join(dirpath, fname)
            from_module = os.path.basename(dirpath)
            if dirpath == lib_root:
                from_module = "lib"

            for imp in extract_imports_for_file(fpath):
                if imp.startswith(prefix):
                    rel_path = imp[len(prefix):]
                    to_module = rel_path.split("/")[0]
                    if to_module and to_module != from_module:
                        results.add((from_module, to_module))

    return sorted(
        [{"from": f, "to": t} for f, t in results],
        key=lambda x: (x["from"], x["to"])
    )


def _get_cross_module_imports_csharp(project_root: str) -> list:
    """Cross-module imports for C#."""
    # Find root namespace from .csproj
    root_ns = ""
    for dirpath, dirnames, filenames in os.walk(project_root):
        rel = os.path.relpath(dirpath, project_root)
        depth = 0 if rel == "." else rel.count(os.sep) + 1
        if depth > 2:
            dirnames[:] = []
            continue
        for f in filenames:
            if f.endswith(".csproj"):
                content = _read_file_safe(os.path.join(dirpath, f))
                m = re.search(r"<RootNamespace>([^<]*)</RootNamespace>", content)
                if m:
                    root_ns = m.group(1)
                else:
                    root_ns = os.path.splitext(f)[0]
                break
        if root_ns:
            break

    if not root_ns:
        return []

    results = set()
    for dirpath, dirnames, filenames in os.walk(project_root):
        dirnames[:] = [d for d in dirnames if d not in IGNORED_PATHS]
        for fname in filenames:
            if not fname.endswith(".cs"):
                continue
            fpath = os.path.join(dirpath, fname)
            from_module = os.path.basename(dirpath)

            for imp in extract_imports_for_file(fpath):
                if imp.startswith(root_ns + "."):
                    sub_ns = imp[len(root_ns) + 1:].split(".")[0]
                    if sub_ns and sub_ns != from_module:
                        results.add((from_module, sub_ns))

    return sorted(
        [{"from": f, "to": t} for f, t in results],
        key=lambda x: (x["from"], x["to"])
    )


def _get_cross_module_imports_php(project_root: str) -> list:
    """Cross-module imports for PHP."""
    composer = _load_json_safe(os.path.join(project_root, "composer.json"))
    if not composer:
        return []

    autoload = composer.get("autoload", {}).get("psr-4", {})
    if not autoload:
        return []

    root_ns = list(autoload.keys())[0].rstrip("\\")
    if not root_ns:
        return []

    results = set()
    for dirpath, dirnames, filenames in os.walk(project_root):
        dirnames[:] = [d for d in dirnames if d not in IGNORED_PATHS]
        for fname in filenames:
            if not fname.endswith(".php"):
                continue
            fpath = os.path.join(dirpath, fname)
            from_module = os.path.basename(dirpath)

            for imp in extract_imports_for_file(fpath):
                if imp.startswith(root_ns + "\\"):
                    sub_ns = imp[len(root_ns) + 1:].split("\\")[0]
                    if sub_ns and sub_ns != from_module:
                        results.add((from_module, sub_ns))

    return sorted(
        [{"from": f, "to": t} for f, t in results],
        key=lambda x: (x["from"], x["to"])
    )


def _get_cross_module_imports_ruby(project_root: str) -> list:
    """Cross-module imports for Ruby."""
    src_root = os.path.join(project_root, "app")
    if not os.path.isdir(src_root):
        src_root = os.path.join(project_root, "lib")
    if not os.path.isdir(src_root):
        return []

    results = set()
    for dirpath, dirnames, filenames in os.walk(src_root):
        dirnames[:] = [d for d in dirnames if d not in IGNORED_PATHS]
        for fname in filenames:
            if not fname.endswith(".rb"):
                continue
            fpath = os.path.join(dirpath, fname)
            from_module = os.path.basename(dirpath)

            for imp in extract_imports_for_file(fpath):
                # Only track require_relative style (internal deps)
                if imp.startswith("../") or "/" in imp:
                    to_module = imp.lstrip("../").split("/")[0]
                    if to_module and to_module != from_module:
                        results.add((from_module, to_module))

    return sorted(
        [{"from": f, "to": t} for f, t in results],
        key=lambda x: (x["from"], x["to"])
    )


def _get_cross_module_imports_swift(project_root: str) -> list:
    """Cross-module imports for Swift."""
    sources_root = os.path.join(project_root, "Sources")
    if not os.path.isdir(sources_root):
        return []

    # Get available target names (dirs under Sources/)
    try:
        targets = {
            d for d in os.listdir(sources_root)
            if os.path.isdir(os.path.join(sources_root, d))
        }
    except OSError:
        return []

    results = set()
    for dirpath, dirnames, filenames in os.walk(sources_root):
        dirnames[:] = [d for d in dirnames if d not in IGNORED_PATHS]
        for fname in filenames:
            if not fname.endswith(".swift"):
                continue
            fpath = os.path.join(dirpath, fname)
            # Get target name (first dir under Sources/)
            rel = os.path.relpath(dirpath, sources_root)
            from_module = rel.split(os.sep)[0]

            for imp in extract_imports_for_file(fpath):
                if imp in targets and imp != from_module:
                    results.add((from_module, imp))

    return sorted(
        [{"from": f, "to": t} for f, t in results],
        key=lambda x: (x["from"], x["to"])
    )


def get_cross_module_imports(project_root: str, language: str) -> list:
    """Dispatch to language-specific cross-module import analysis."""
    if language in ("java", "kotlin"):
        return _get_cross_module_imports_java(project_root, language)
    elif language == "go":
        return _get_cross_module_imports_go(project_root)
    elif language == "rust":
        return _get_cross_module_imports_rust(project_root)
    elif language == "dart":
        return _get_cross_module_imports_dart(project_root)
    elif language == "csharp":
        return _get_cross_module_imports_csharp(project_root)
    elif language == "php":
        return _get_cross_module_imports_php(project_root)
    elif language == "ruby":
        return _get_cross_module_imports_ruby(project_root)
    elif language == "swift":
        return _get_cross_module_imports_swift(project_root)
    else:
        # JS/TS/Python and others
        return _get_cross_module_imports_js_ts_py(project_root, language)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def scan(project_root: str) -> dict:
    """Run full dependency scan."""
    project_root = os.path.abspath(project_root)

    language = detect_language(project_root)
    framework = detect_framework(project_root, language)
    external_deps = get_external_deps(project_root, language)
    import_frequency = get_import_frequency(project_root, language)
    cross_module_imports = get_cross_module_imports(project_root, language)

    return {
        "language": language,
        "framework": framework,
        "external_deps": external_deps,
        "import_frequency": import_frequency,
        "cross_module_imports": cross_module_imports,
    }


def main():
    project_root = sys.argv[1] if len(sys.argv) > 1 else os.getcwd()
    debug_log(f"scan-dependencies.py scanning {project_root}")
    result = scan(project_root)
    json.dump(result, sys.stdout, separators=(",", ":"))
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
