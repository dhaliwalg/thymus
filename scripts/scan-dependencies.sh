#!/usr/bin/env bash
set -euo pipefail

# Thymus scan-dependencies.sh
# Detects language, framework, external deps, and import relationships.
# Usage: bash scan-dependencies.sh [project_root]
# Output: JSON to stdout

PROJECT_ROOT="${1:-$PWD}"
DEBUG_LOG="/tmp/thymus-debug.log"
TIMESTAMP=$(date '+%Y-%m-%dT%H:%M:%S')

IGNORED_PATHS=("node_modules" "dist" ".next" ".git" "coverage" "__pycache__" ".venv" "vendor" "target" "build")
IGNORED_FIND_ARGS=()
for p in "${IGNORED_PATHS[@]}"; do
  IGNORED_FIND_ARGS+=(-not -path "*/$p/*" -not -name "$p")
done

echo "[$TIMESTAMP] scan-dependencies.sh scanning $PROJECT_ROOT" >> "$DEBUG_LOG"

# --- language detection ---
detect_language() {
  if [ -f "$PROJECT_ROOT/package.json" ]; then
    if [ -f "$PROJECT_ROOT/tsconfig.json" ] || \
       find "$PROJECT_ROOT/src" -name "*.ts" -maxdepth 2 2>/dev/null | grep -q .; then
      echo "typescript"
    else
      echo "javascript"
    fi
  elif [ -f "$PROJECT_ROOT/pyproject.toml" ] || [ -f "$PROJECT_ROOT/setup.py" ] || \
       [ -f "$PROJECT_ROOT/requirements.txt" ]; then
    echo "python"
  elif [ -f "$PROJECT_ROOT/go.mod" ]; then
    echo "go"
  elif [ -f "$PROJECT_ROOT/Cargo.toml" ]; then
    echo "rust"
  elif [ -f "$PROJECT_ROOT/pom.xml" ] || [ -f "$PROJECT_ROOT/build.gradle" ] || [ -f "$PROJECT_ROOT/build.gradle.kts" ]; then
    echo "java"
  else
    echo "unknown"
  fi
}

# --- framework detection from package.json deps ---
detect_framework() {
  local lang="$1"
  if [ "$lang" = "typescript" ] || [ "$lang" = "javascript" ]; then
    if [ -f "$PROJECT_ROOT/package.json" ]; then
      if jq -e '.dependencies.next // .devDependencies.next' "$PROJECT_ROOT/package.json" > /dev/null 2>&1; then
        echo "nextjs"
      elif jq -e '.dependencies.express // .devDependencies.express' "$PROJECT_ROOT/package.json" > /dev/null 2>&1; then
        echo "express"
      elif jq -e '.dependencies["@nestjs/core"] // .devDependencies["@nestjs/core"]' "$PROJECT_ROOT/package.json" > /dev/null 2>&1; then
        echo "nestjs"
      elif jq -e '.dependencies.fastify // .devDependencies.fastify' "$PROJECT_ROOT/package.json" > /dev/null 2>&1; then
        echo "fastify"
      else
        echo "unknown"
      fi
    else
      echo "unknown"
    fi
  elif [ "$lang" = "python" ]; then
    if grep -q "django" "$PROJECT_ROOT/requirements.txt" 2>/dev/null || \
       grep -q "django" "$PROJECT_ROOT/pyproject.toml" 2>/dev/null; then
      echo "django"
    elif grep -q "fastapi" "$PROJECT_ROOT/requirements.txt" 2>/dev/null || \
         grep -q "fastapi" "$PROJECT_ROOT/pyproject.toml" 2>/dev/null; then
      echo "fastapi"
    else
      echo "unknown"
    fi
  elif [ "$lang" = "java" ]; then
    local build_content=""
    if [ -f "$PROJECT_ROOT/pom.xml" ]; then
      build_content=$(cat "$PROJECT_ROOT/pom.xml" 2>/dev/null)
    elif [ -f "$PROJECT_ROOT/build.gradle" ]; then
      build_content=$(cat "$PROJECT_ROOT/build.gradle" 2>/dev/null)
    elif [ -f "$PROJECT_ROOT/build.gradle.kts" ]; then
      build_content=$(cat "$PROJECT_ROOT/build.gradle.kts" 2>/dev/null)
    fi
    if echo "$build_content" | grep -q "spring-boot-starter-web\|spring-webmvc"; then
      if echo "$build_content" | grep -q "spring-boot-starter"; then
        echo "spring-boot"
      else
        echo "spring-mvc"
      fi
    elif echo "$build_content" | grep -q "quarkus-core\|quarkus-bom"; then
      echo "quarkus"
    elif echo "$build_content" | grep -q "micronaut-core\|micronaut-bom"; then
      echo "micronaut"
    elif echo "$build_content" | grep -q "dropwizard"; then
      echo "dropwizard"
    else
      echo "unknown"
    fi
  elif [ "$lang" = "go" ]; then
    if [ -f "$PROJECT_ROOT/go.mod" ]; then
      if grep -q "github.com/gin-gonic/gin" "$PROJECT_ROOT/go.mod" 2>/dev/null; then
        echo "gin"
      elif grep -q "github.com/labstack/echo" "$PROJECT_ROOT/go.mod" 2>/dev/null; then
        echo "echo"
      elif grep -q "github.com/gofiber/fiber" "$PROJECT_ROOT/go.mod" 2>/dev/null; then
        echo "fiber"
      elif grep -q "github.com/gorilla/mux" "$PROJECT_ROOT/go.mod" 2>/dev/null; then
        echo "gorilla"
      elif grep -q "github.com/go-chi/chi" "$PROJECT_ROOT/go.mod" 2>/dev/null; then
        echo "chi"
      elif grep -q "net/http" "$PROJECT_ROOT/go.mod" 2>/dev/null; then
        echo "stdlib-http"
      else
        echo "unknown"
      fi
    else
      echo "unknown"
    fi
  elif [ "$lang" = "rust" ]; then
    if [ -f "$PROJECT_ROOT/Cargo.toml" ]; then
      if grep -q "actix-web" "$PROJECT_ROOT/Cargo.toml" 2>/dev/null; then
        echo "actix"
      elif grep -q "axum" "$PROJECT_ROOT/Cargo.toml" 2>/dev/null; then
        echo "axum"
      elif grep -q "rocket" "$PROJECT_ROOT/Cargo.toml" 2>/dev/null; then
        echo "rocket"
      elif grep -q "warp" "$PROJECT_ROOT/Cargo.toml" 2>/dev/null; then
        echo "warp"
      elif grep -q "tide" "$PROJECT_ROOT/Cargo.toml" 2>/dev/null; then
        echo "tide"
      else
        echo "unknown"
      fi
    else
      echo "unknown"
    fi
  else
    echo "unknown"
  fi
}

# --- external deps from manifest ---
get_external_deps() {
  local lang="$1"
  if [ "$lang" = "typescript" ] || [ "$lang" = "javascript" ]; then
    if [ -f "$PROJECT_ROOT/package.json" ]; then
      jq -r '(.dependencies // {}) + (.devDependencies // {}) | keys[]' \
        "$PROJECT_ROOT/package.json" 2>/dev/null | jq -R . | jq -s .
      return
    fi
  elif [ "$lang" = "python" ]; then
    if [ -f "$PROJECT_ROOT/requirements.txt" ]; then
      grep -v '^#' "$PROJECT_ROOT/requirements.txt" | grep -v '^$' | \
        sed 's/[>=<].*//' | jq -R . | jq -s .
      return
    fi
  elif [ "$lang" = "go" ]; then
    if [ -f "$PROJECT_ROOT/go.mod" ]; then
      { grep '^require' -A 100 "$PROJECT_ROOT/go.mod" 2>/dev/null || true; } | \
        { grep -oE '[a-z0-9.-]+/[a-z0-9./-]+' || true; } | jq -R . | jq -s .
      return
    fi
  elif [ "$lang" = "java" ]; then
    if [ -f "$PROJECT_ROOT/pom.xml" ]; then
      python3 -c "
import xml.etree.ElementTree as ET, json, sys
try:
    tree = ET.parse('$PROJECT_ROOT/pom.xml')
    root = tree.getroot()
    ns = {'m': 'http://maven.apache.org/POM/4.0.0'}
    # Try with namespace first, then without
    deps_els = root.findall('.//m:dependency', ns)
    if not deps_els:
        deps_els = root.findall('.//dependency')
    deps = []
    for dep in deps_els:
        group = dep.find('m:groupId', ns)
        if group is None:
            group = dep.find('groupId')
        artifact = dep.find('m:artifactId', ns)
        if artifact is None:
            artifact = dep.find('artifactId')
        version = dep.find('m:version', ns)
        if version is None:
            version = dep.find('version')
        if group is not None and artifact is not None:
            v = version.text if version is not None else 'managed'
            deps.append(f'{group.text}:{artifact.text}:{v}')
    print(json.dumps(deps))
except Exception:
    print('[]')
" 2>/dev/null
      return
    elif [ -f "$PROJECT_ROOT/build.gradle" ] || [ -f "$PROJECT_ROOT/build.gradle.kts" ]; then
      local gradle_file="$PROJECT_ROOT/build.gradle"
      [ -f "$gradle_file" ] || gradle_file="$PROJECT_ROOT/build.gradle.kts"
      { grep -oE "(implementation|compile|api|runtimeOnly|compileOnly|testImplementation)[[:space:]]*['\(]['\"]([^'\"]+)['\"]" "$gradle_file" 2>/dev/null || true; } \
        | { grep -oE "['\"][^'\"]+['\"]" || true; } | tr -d "'" | tr -d '"' \
        | jq -R . | jq -s .
      return
    fi
  fi
  echo "[]"
}

# --- import frequency: top 20 most-imported internal paths ---
get_import_frequency() {
  local lang="$1"
  local pattern=""

  case "$lang" in
    typescript|javascript)
      pattern="from ['\"][./][^'\"]*['\"]"
      ;;
    python)
      pattern="^from \.|^import \."
      ;;
    go)
      pattern="\"[a-z0-9_-]+/"
      ;;
    java)
      pattern="^import [a-z]"
      ;;
    *)
      echo "[]"
      return
      ;;
  esac

  local result
  result=$(find "$PROJECT_ROOT" -type f \( -name "*.ts" -o -name "*.js" -o -name "*.py" -o -name "*.go" -o -name "*.java" -o -name "*.rs" \) \
    "${IGNORED_FIND_ARGS[@]}" 2>/dev/null \
  | ( xargs grep -hoE "$pattern" 2>/dev/null || true ) \
  | sed "s/from ['\"]//" | sed "s/['\"]$//" \
  | sort | uniq -c | sort -rn \
  | head -20 \
  | awk '{print "{\"path\":\""$2"\",\"count\":"$1"}"}' || true)
  if [ -n "$result" ]; then
    echo "$result" | jq -s .
  else
    echo "[]"
  fi
}

# --- cross_module_imports: which top-level dirs import from which ---
get_cross_module_imports() {
  local lang="${1:-unknown}"

  if [ "$lang" = "java" ]; then
    _get_cross_module_imports_java
    return
  fi
  if [ "$lang" = "go" ]; then
    _get_cross_module_imports_go
    return
  fi
  if [ "$lang" = "rust" ]; then
    _get_cross_module_imports_rust
    return
  fi

  # JS/TS/Python: get top-level source dirs (depth 1 under src/ or project root)
  local src_root="$PROJECT_ROOT/src"
  [ -d "$src_root" ] || src_root="$PROJECT_ROOT"

  local grep_pattern sed_pattern
  case "$lang" in
    python)
      grep_pattern='from \.\.[a-z_]+'
      sed_pattern='s|from \.\.||'
      ;;
    *)
      # JS/TS/Go default
      grep_pattern="from ['\"\`]\\.\\./[a-z_-]+"
      sed_pattern='s|\.\./||'
      ;;
  esac

  local result
  result=$(find "$src_root" -maxdepth 1 -mindepth 1 -type d \
    "${IGNORED_FIND_ARGS[@]}" 2>/dev/null \
  | while read -r module_dir; do
      local from_module
      from_module=$(basename "$module_dir")

      find "$module_dir" -type f \( -name "*.ts" -o -name "*.js" -o -name "*.py" -o -name "*.go" -o -name "*.java" -o -name "*.rs" \) \
        "${IGNORED_FIND_ARGS[@]}" 2>/dev/null \
      | ( xargs grep -hoE "$grep_pattern" 2>/dev/null || true ) \
      | ( grep -oE "\.\./[a-z_-]+|from \.\.[a-z_]+" || true ) \
      | sed "$sed_pattern" \
      | sort -u \
      | while read -r to_module; do
          [ -n "$to_module" ] && echo "{\"from\":\"$from_module\",\"to\":\"$to_module\"}"
        done
    done || true)
  if [ -n "$result" ]; then
    echo "$result" | jq -s .
  else
    echo "[]"
  fi
}

_get_cross_module_imports_java() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local extractor="$script_dir/extract-imports.py"

  # Find the base package directory: deepest common ancestor of all .java files
  # For standard Maven/Gradle layout: src/main/java/com/example/
  local java_root=""
  if [ -d "$PROJECT_ROOT/src/main/java" ]; then
    # Find base package dir: first directory under src/main/java that contains subdirs with .java files
    java_root=$(find "$PROJECT_ROOT/src/main/java" -name "*.java" -type f 2>/dev/null | head -1)
    if [ -n "$java_root" ]; then
      # Walk up from the first .java file to find the base package (parent of top-level packages)
      java_root=$(dirname "$java_root")
      # Keep going up while sibling dirs don't contain .java files at the same level
      # The base package is the dir whose children are the top-level packages (controller, service, etc.)
      local parent
      parent=$(dirname "$java_root")
      while [ "$parent" != "$PROJECT_ROOT/src/main/java" ] && [ "$parent" != "/" ]; do
        # Check if parent has multiple subdirs with .java files
        local subdir_count
        subdir_count=$(find "$parent" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
        if [ "$subdir_count" -gt 1 ]; then
          java_root="$parent"
          break
        fi
        java_root="$parent"
        parent=$(dirname "$parent")
      done
    fi
  fi

  if [ -z "$java_root" ] || [ ! -d "$java_root" ]; then
    echo "[]"
    return
  fi

  # Get the base package name from the directory structure
  # e.g., src/main/java/com/example -> com.example
  local java_base="${java_root#$PROJECT_ROOT/src/main/java/}"
  local base_package
  base_package=$(echo "$java_base" | tr '/' '.')

  # Enumerate top-level packages (controller, service, repository, model, etc.)
  local top_level_dirs
  top_level_dirs=$(find "$java_root" -maxdepth 1 -mindepth 1 -type d 2>/dev/null)

  local result=""
  for module_dir in $top_level_dirs; do
    local from_module
    from_module=$(basename "$module_dir")

    # Extract imports from all .java files in this module
    find "$module_dir" -name "*.java" -type f 2>/dev/null | while read -r java_file; do
      python3 "$extractor" "$java_file" 2>/dev/null
    done | while read -r imp; do
      # Check if the import starts with our base package
      if echo "$imp" | grep -q "^${base_package}\."; then
        # Extract the sub-package (first segment after base package)
        local sub_package
        sub_package=$(echo "$imp" | sed "s|^${base_package}\.||" | cut -d. -f1)
        if [ -n "$sub_package" ] && [ "$sub_package" != "$from_module" ]; then
          echo "{\"from\":\"$from_module\",\"to\":\"$sub_package\"}"
        fi
      fi
    done
  done | sort -u > /tmp/thymus-java-xmod-$$.tmp

  result=$(cat /tmp/thymus-java-xmod-$$.tmp 2>/dev/null || true)
  rm -f /tmp/thymus-java-xmod-$$.tmp

  if [ -n "$result" ]; then
    echo "$result" | jq -s .
  else
    echo "[]"
  fi
}

_get_cross_module_imports_go() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local extractor="$script_dir/extract-imports.py"

  # Read module path from go.mod
  local module_path=""
  if [ -f "$PROJECT_ROOT/go.mod" ]; then
    module_path=$(grep '^module ' "$PROJECT_ROOT/go.mod" 2>/dev/null | awk '{print $2}')
  fi
  if [ -z "$module_path" ]; then
    echo "[]"
    return
  fi

  # Find all Go packages (directories with .go files) under src/ or project root
  local src_root="$PROJECT_ROOT/src"
  [ -d "$src_root" ] || src_root="$PROJECT_ROOT"

  local result=""
  find "$src_root" -name "*.go" -not -name "*_test.go" -type f \
    "${IGNORED_FIND_ARGS[@]}" 2>/dev/null | while read -r go_file; do
    local from_dir
    from_dir=$(dirname "$go_file")
    local from_module
    from_module=$(basename "$from_dir")

    python3 "$extractor" "$go_file" 2>/dev/null | while read -r imp; do
      if echo "$imp" | grep -q "^${module_path}/"; then
        local rel_import
        rel_import=$(echo "$imp" | sed "s|^${module_path}/||")
        # Get first directory segment after module root as package name
        # Handle src/ prefix if present
        local to_module
        to_module=$(echo "$rel_import" | sed 's|^src/||' | cut -d/ -f1)
        if [ -n "$to_module" ] && [ "$to_module" != "$from_module" ]; then
          echo "{\"from\":\"$from_module\",\"to\":\"$to_module\"}"
        fi
      fi
    done
  done | sort -u > /tmp/thymus-go-xmod-$$.tmp

  result=$(cat /tmp/thymus-go-xmod-$$.tmp 2>/dev/null || true)
  rm -f /tmp/thymus-go-xmod-$$.tmp

  if [ -n "$result" ]; then
    echo "$result" | jq -s .
  else
    echo "[]"
  fi
}

_get_cross_module_imports_rust() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local extractor="$script_dir/extract-imports.py"

  local src_root="$PROJECT_ROOT/src"
  if [ ! -d "$src_root" ]; then
    echo "[]"
    return
  fi

  local result=""
  find "$src_root" -name "*.rs" -type f \
    "${IGNORED_FIND_ARGS[@]}" 2>/dev/null | while read -r rs_file; do
    local from_dir
    from_dir=$(dirname "$rs_file")
    local from_module
    from_module=$(basename "$from_dir")
    # If file is directly in src/, use the filename (without extension) as module
    if [ "$from_dir" = "$src_root" ]; then
      from_module=$(basename "${rs_file%.rs}")
    fi

    python3 "$extractor" "$rs_file" 2>/dev/null | while read -r imp; do
      if echo "$imp" | grep -q "^crate::"; then
        local to_module
        to_module=$(echo "$imp" | sed 's|^crate::||' | cut -d: -f1)
        if [ -n "$to_module" ] && [ "$to_module" != "$from_module" ]; then
          echo "{\"from\":\"$from_module\",\"to\":\"$to_module\"}"
        fi
      fi
    done
  done | sort -u > /tmp/thymus-rust-xmod-$$.tmp

  result=$(cat /tmp/thymus-rust-xmod-$$.tmp 2>/dev/null || true)
  rm -f /tmp/thymus-rust-xmod-$$.tmp

  if [ -n "$result" ]; then
    echo "$result" | jq -s .
  else
    echo "[]"
  fi
}

# --- Assemble output ---
language=$(detect_language)
framework=$(detect_framework "$language")
external_deps=$(get_external_deps "$language")
import_frequency=$(get_import_frequency "$language")
cross_module_imports=$(get_cross_module_imports "$language")

jq -n \
  --arg language "$language" \
  --arg framework "$framework" \
  --argjson external_deps "$external_deps" \
  --argjson import_frequency "$import_frequency" \
  --argjson cross_module_imports "$cross_module_imports" \
  '{
    language: $language,
    framework: $framework,
    external_deps: $external_deps,
    import_frequency: $import_frequency,
    cross_module_imports: $cross_module_imports
  }'
