#!/usr/bin/env bash
set -euo pipefail

# AIS detect-framework.sh
# Detects the language and framework of the project in $PWD.
# Output: JSON { language, framework, config_file }
# Language: typescript | javascript | python | go | rust | java | unknown
# Framework: express | nextjs | react | django | fastapi | flask | unknown

PROJECT_LANG="unknown"
FRAMEWORK="unknown"
CONFIG_FILE=""

# --- TypeScript / JavaScript ---
if [ -f "package.json" ]; then
  if jq -e '.dependencies.typescript or .devDependencies.typescript' package.json > /dev/null 2>&1; then
    PROJECT_LANG="typescript"
  else
    PROJECT_LANG="javascript"
  fi
  CONFIG_FILE="package.json"

  # Framework detection from package.json dependencies
  ALL_DEPS=$(jq -r '(.dependencies // {}) + (.devDependencies // {}) | keys[]' package.json 2>/dev/null | tr '\n' ' ' || true)

  if echo "$ALL_DEPS" | grep -qw "next"; then
    FRAMEWORK="nextjs"
  elif echo "$ALL_DEPS" | grep -qw "express"; then
    FRAMEWORK="express"
  elif echo "$ALL_DEPS" | grep -qw "react"; then
    FRAMEWORK="react"
  elif echo "$ALL_DEPS" | grep -qw "fastify"; then
    FRAMEWORK="fastify"
  elif echo "$ALL_DEPS" | grep -qw "koa"; then
    FRAMEWORK="koa"
  fi

# --- Python ---
elif [ -f "pyproject.toml" ] || [ -f "requirements.txt" ] || [ -f "setup.py" ]; then
  PROJECT_LANG="python"
  CONFIG_FILE="${CONFIG_FILE:-pyproject.toml}"
  [ -f "pyproject.toml" ] && CONFIG_FILE="pyproject.toml"
  [ -f "requirements.txt" ] && CONFIG_FILE="${CONFIG_FILE:-requirements.txt}"

  # Check for frameworks in pyproject.toml or requirements.txt
  DEPS_TEXT=""
  [ -f "pyproject.toml" ] && DEPS_TEXT=$(cat pyproject.toml 2>/dev/null || true)
  [ -f "requirements.txt" ] && DEPS_TEXT="${DEPS_TEXT}$(cat requirements.txt 2>/dev/null || true)"

  if echo "$DEPS_TEXT" | grep -qi "django"; then
    FRAMEWORK="django"
  elif echo "$DEPS_TEXT" | grep -qi "fastapi"; then
    FRAMEWORK="fastapi"
  elif echo "$DEPS_TEXT" | grep -qi "flask"; then
    FRAMEWORK="flask"
  fi

# --- Go ---
elif [ -f "go.mod" ]; then
  PROJECT_LANG="go"
  CONFIG_FILE="go.mod"
  # Detect common Go web frameworks
  if [ -f "go.sum" ]; then
    if grep -q "gin-gonic" go.sum 2>/dev/null; then FRAMEWORK="gin"
    elif grep -q "gofiber" go.sum 2>/dev/null; then FRAMEWORK="fiber"
    elif grep -q "chi" go.sum 2>/dev/null; then FRAMEWORK="chi"
    fi
  fi

# --- Rust ---
elif [ -f "Cargo.toml" ]; then
  PROJECT_LANG="rust"
  CONFIG_FILE="Cargo.toml"
  if grep -q "actix-web" Cargo.toml 2>/dev/null; then FRAMEWORK="actix"
  elif grep -q "axum" Cargo.toml 2>/dev/null; then FRAMEWORK="axum"
  fi

# --- Java ---
elif [ -f "pom.xml" ]; then
  PROJECT_LANG="java"
  CONFIG_FILE="pom.xml"
  if grep -q "spring-boot" pom.xml 2>/dev/null; then FRAMEWORK="spring"
  fi
elif [ -f "build.gradle" ] || [ -f "build.gradle.kts" ]; then
  PROJECT_LANG="java"
  if [ -f "build.gradle" ]; then
    CONFIG_FILE="build.gradle"
    if grep -q "spring-boot" build.gradle 2>/dev/null; then FRAMEWORK="spring"; fi
  else
    CONFIG_FILE="build.gradle.kts"
    if grep -q "spring-boot" build.gradle.kts 2>/dev/null; then FRAMEWORK="spring"; fi
  fi
fi

jq -n \
  --arg lang "$PROJECT_LANG" \
  --arg framework "$FRAMEWORK" \
  --arg config "$CONFIG_FILE" \
  '{"language": $lang, "framework": $framework, "config_file": $config}'
