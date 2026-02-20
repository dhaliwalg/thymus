#!/usr/bin/env bash
set -euo pipefail

# AIS scan-dependencies.sh
# Detects language, framework, external deps, and import relationships.
# Usage: bash scan-dependencies.sh [project_root]
# Output: JSON to stdout

PROJECT_ROOT="${1:-$PWD}"
DEBUG_LOG="/tmp/ais-debug.log"
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
  elif [ -f "$PROJECT_ROOT/pom.xml" ] || [ -f "$PROJECT_ROOT/build.gradle" ]; then
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
      grep '^require' -A 100 "$PROJECT_ROOT/go.mod" | \
        grep -oE '[a-z0-9.-]+/[a-z0-9./-]+' | jq -R . | jq -s .
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
    *)
      echo "[]"
      return
      ;;
  esac

  find "$PROJECT_ROOT" -type f \( -name "*.ts" -o -name "*.js" -o -name "*.py" -o -name "*.go" \) \
    "${IGNORED_FIND_ARGS[@]}" 2>/dev/null \
  | xargs grep -hoE "$pattern" 2>/dev/null \
  | sed "s/from ['\"]//" | sed "s/['\"]$//" \
  | sort | uniq -c | sort -rn \
  | head -20 \
  | awk '{print "{\"path\":\""$2"\",\"count\":"$1"}"}' \
  | jq -s .
}

# --- cross_module_imports: which top-level dirs import from which ---
get_cross_module_imports() {
  # Get top-level source dirs (depth 1 under src/ or project root)
  local src_root="$PROJECT_ROOT/src"
  [ -d "$src_root" ] || src_root="$PROJECT_ROOT"

  find "$src_root" -maxdepth 1 -mindepth 1 -type d \
    "${IGNORED_FIND_ARGS[@]}" \
  | while read -r module_dir; do
      local from_module
      from_module=$(basename "$module_dir")

      find "$module_dir" -type f \( -name "*.ts" -o -name "*.js" -o -name "*.py" -o -name "*.go" \) \
        "${IGNORED_FIND_ARGS[@]}" 2>/dev/null \
      | xargs grep -hoE "from ['\"\`]\.\./[a-z_-]+" 2>/dev/null \
      | grep -oE "\.\./[a-z_-]+" | sed 's|\.\./||' \
      | sort -u \
      | while read -r to_module; do
          echo "{\"from\":\"$from_module\",\"to\":\"$to_module\"}"
        done
    done \
  | jq -s .
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
