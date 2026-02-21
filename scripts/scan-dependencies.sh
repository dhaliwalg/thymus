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
  # Get top-level source dirs (depth 1 under src/ or project root)
  local src_root="$PROJECT_ROOT/src"
  [ -d "$src_root" ] || src_root="$PROJECT_ROOT"

  local result
  result=$(find "$src_root" -maxdepth 1 -mindepth 1 -type d \
    "${IGNORED_FIND_ARGS[@]}" 2>/dev/null \
  | while read -r module_dir; do
      local from_module
      from_module=$(basename "$module_dir")

      find "$module_dir" -type f \( -name "*.ts" -o -name "*.js" -o -name "*.py" -o -name "*.go" -o -name "*.java" -o -name "*.rs" \) \
        "${IGNORED_FIND_ARGS[@]}" 2>/dev/null \
      | ( xargs grep -hoE "from ['\"\`]\.\./[a-z_-]+|import [a-z]+\.[a-z]+\.[a-z]+" 2>/dev/null || true ) \
      | ( grep -oE "\.\./[a-z_-]+|import [a-z]+\.[a-z]+\.[a-z]+" || true ) \
      | sed 's|\.\./||; s|import [a-z]*\.||; s|\..*||' \
      | sort -u \
      | while read -r to_module; do
          echo "{\"from\":\"$from_module\",\"to\":\"$to_module\"}"
        done
    done || true)
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
