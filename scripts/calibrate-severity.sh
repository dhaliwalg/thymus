#!/usr/bin/env bash
set -euo pipefail

# Thymus calibrate-severity.sh
# Reads .thymus/calibration.json and outputs severity adjustment recommendations.
# A rule with >= 10 data points and > 70% ignore rate -> recommend downgrade.
# Output: JSON { recommendations: [{rule, action, reason, fixed, ignored}] }

THYMUS_DIR="$PWD/.thymus"
CALIBRATION="$THYMUS_DIR/calibration.json"

if [ ! -f "$CALIBRATION" ]; then
  echo '{"recommendations":[],"note":"No calibration data yet. Edit files to build up data."}'
  exit 0
fi

CALIBRATE_PY=$(mktemp /tmp/thymus-calibrate-XXXXXX.py)
trap 'rm -f "$CALIBRATE_PY"' EXIT
cat > "$CALIBRATE_PY" << 'ENDPY'
import sys, json

with open(sys.argv[1]) as f:
    data = json.load(f)

rules = data.get('rules', {})
recommendations = []

for rule_id, counts in rules.items():
    fixed = counts.get('fixed', 0)
    ignored = counts.get('ignored', 0)
    total = fixed + ignored
    if total < 10:
        continue
    ignore_rate = ignored / total
    if ignore_rate >= 0.7:
        recommendations.append({
            'rule': rule_id,
            'action': 'downgrade',
            'reason': 'Ignored {}/{} times ({}% ignore rate). Consider downgrading severity or removing.'.format(
                ignored, total, int(ignore_rate * 100)
            ),
            'fixed': fixed,
            'ignored': ignored
        })

print(json.dumps({'recommendations': recommendations}))
ENDPY

python3 "$CALIBRATE_PY" "$CALIBRATION"
rm -f "$CALIBRATE_PY"
