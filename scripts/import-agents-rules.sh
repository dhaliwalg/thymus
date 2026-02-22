#!/usr/bin/env bash
set -euo pipefail

# Thymus import-agents-rules.sh
# Reads an existing AGENTS.md or CLAUDE.md and extracts architectural rules,
# converting them to Thymus YAML where possible.
#
# Usage: bash import-agents-rules.sh [project_root]
# Output: Proposed YAML invariants to stdout
#
# This is a best-effort convenience feature. If a rule can't be parsed,
# it's skipped and noted in stderr.

PROJECT_ROOT="${1:-$PWD}"
DEBUG_LOG="/tmp/thymus-debug.log"
TIMESTAMP=$(date '+%Y-%m-%dT%H:%M:%S')

echo "[$TIMESTAMP] import-agents-rules.sh running for $PROJECT_ROOT" >> "$DEBUG_LOG"

# Find the source file
SOURCE_FILE=""
if [ -f "$PROJECT_ROOT/AGENTS.md" ]; then
  SOURCE_FILE="$PROJECT_ROOT/AGENTS.md"
elif [ -f "$PROJECT_ROOT/CLAUDE.md" ]; then
  SOURCE_FILE="$PROJECT_ROOT/CLAUDE.md"
else
  echo "Error: No AGENTS.md or CLAUDE.md found in $PROJECT_ROOT" >&2
  exit 1
fi

echo "# Proposed invariants extracted from $(basename "$SOURCE_FILE")" >&2
echo "# Review carefully — automated extraction is approximate" >&2
echo "" >&2

# Extract rules using Python for reliable text processing
python3 - "$SOURCE_FILE" << 'PYEOF'
import re
import sys

source_file = sys.argv[1] if len(sys.argv) > 1 else ""

with open(source_file, encoding='utf-8', errors='replace') as f:
    content = f.read()

rules = []
rule_count = 0
skipped = []

# Patterns that indicate architectural rules
boundary_patterns = [
    # "X must not import Y" / "X should not import Y"
    re.compile(
        r'(?:files?\s+in\s+)?[`"]?([^`"]+?)[`"]?\s+'
        r'(?:must\s+not|should\s+not|cannot|MUST\s+NOT)\s+'
        r'import\s+(?:from\s+)?[`"]?([^`".]+?)[`"]?(?:\s|$|\.)',
        re.IGNORECASE
    ),
    # "no X imports in Y" / "X forbidden in Y"
    re.compile(
        r'(?:no|forbid|ban)\s+[`"]?([^`"]+?)[`"]?\s+'
        r'(?:imports?\s+)?in\s+[`"]?([^`"]+?)[`"]?',
        re.IGNORECASE
    ),
]

# "Only use X in Y" pattern
dependency_patterns = [
    re.compile(
        r'[`"]?(\w[\w.-]*)[`"]?\s+'
        r'(?:may\s+only|should\s+only|must\s+only|only)\s+'
        r'(?:be\s+)?(?:imported|used)\s+in\s+[`"]?([^`"]+?)[`"]?',
        re.IGNORECASE
    ),
]

# Pattern ban: "no raw SQL outside X"
pattern_patterns = [
    re.compile(
        r'no\s+(?:raw\s+)?[`"]?([^`"]+?)[`"]?\s+'
        r'outside\s+(?:of\s+)?[`"]?([^`"]+?)[`"]?',
        re.IGNORECASE
    ),
]

lines = content.split('\n')

for line in lines:
    stripped = line.strip()
    if not stripped or stripped.startswith('#'):
        continue

    # Strip markdown list markers
    text = re.sub(r'^[-*]\s+', '', stripped)
    text = re.sub(r'^\*\*[^*]+\*\*:?\s*', '', text)

    matched = False

    # Try boundary patterns
    for pat in boundary_patterns:
        m = pat.search(text)
        if m:
            source = m.group(1).strip().rstrip('/')
            forbidden = m.group(2).strip().rstrip('/')
            rule_id = f"imported-boundary-{rule_count}"
            rule_count += 1
            rules.append({
                'id': rule_id,
                'type': 'boundary',
                'source': source,
                'forbidden': forbidden,
                'desc': text[:80],
            })
            matched = True
            break

    if matched:
        continue

    # Try dependency patterns
    for pat in dependency_patterns:
        m = pat.search(text)
        if m:
            package = m.group(1).strip()
            allowed = m.group(2).strip().rstrip('/')
            rule_id = f"imported-dependency-{rule_count}"
            rule_count += 1
            rules.append({
                'id': rule_id,
                'type': 'dependency',
                'package': package,
                'allowed': allowed,
                'desc': text[:80],
            })
            matched = True
            break

    if matched:
        continue

    # Try pattern ban patterns
    for pat in pattern_patterns:
        m = pat.search(text)
        if m:
            pattern = m.group(1).strip()
            scope_exclude = m.group(2).strip().rstrip('/')
            rule_id = f"imported-pattern-{rule_count}"
            rule_count += 1
            rules.append({
                'id': rule_id,
                'type': 'pattern',
                'pattern': pattern,
                'exclude': scope_exclude,
                'desc': text[:80],
            })
            matched = True
            break

# Output YAML
if not rules:
    print("# No extractable rules found in " + source_file, file=sys.stderr)
    print("# The file may use formats that aren't automatically parseable.", file=sys.stderr)
    sys.exit(0)

print(f"# Extracted {len(rules)} rules from {source_file}", file=sys.stderr)
print("")

print("version: \"1.0\"")
print("invariants:")

for r in rules:
    print(f"  - id: {r['id']}")
    print(f"    type: {r['type']}")
    print(f"    severity: warning")
    print(f"    description: \"{r['desc']}\"")

    if r['type'] == 'boundary':
        source = r['source']
        if not source.endswith('**'):
            source = source.rstrip('/') + '/**'
        print(f"    source_glob: \"{source}\"")
        print(f"    forbidden_imports:")
        print(f"      - \"{r['forbidden']}\"")

    elif r['type'] == 'dependency':
        print(f"    package: \"{r['package']}\"")
        print(f"    allowed_in:")
        print(f"      - \"{r['allowed']}\"")

    elif r['type'] == 'pattern':
        print(f"    scope_glob: \"**\"")
        print(f"    forbidden_pattern: \"{r['pattern']}\"")
        print(f"    scope_glob_exclude:")
        print(f"      - \"{r['exclude']}/**\"")

    print("")

PYEOF
