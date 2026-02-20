#!/usr/bin/env bash
set -euo pipefail

SCRIPT="$(dirname "$0")/../scripts/scan-dependencies.sh"
HEALTHY="$(dirname "$0")/fixtures/healthy-project"

echo "=== Testing scan-dependencies.sh ==="

output=$(bash "$SCRIPT" "$HEALTHY")

echo "$output" | jq . > /dev/null || { echo "FAIL: not valid JSON"; exit 1; }

for field in language framework external_deps import_frequency cross_module_imports; do
  echo "$output" | jq -e ".$field" > /dev/null || { echo "FAIL: missing field $field"; exit 1; }
done

lang=$(echo "$output" | jq -r '.language')
[ "$lang" = "typescript" ] || { echo "FAIL: expected language=typescript, got $lang"; exit 1; }

framework=$(echo "$output" | jq -r '.framework')
[ "$framework" = "express" ] || { echo "FAIL: expected framework=express, got $framework"; exit 1; }

echo "PASS: scan-dependencies.sh output is valid"
