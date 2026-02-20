#!/usr/bin/env bash
set -euo pipefail

# AIS generate-report.sh — HTML health report generator
# Usage: bash generate-report.sh --scan /path/to/scan.json [--projection '{"velocity":...}']
# Output: writes .ais/report.html, opens in browser, prints JSON summary to stdout

DEBUG_LOG="/tmp/ais-debug.log"
TIMESTAMP=$(date '+%Y-%m-%dT%H:%M:%S')
AIS_DIR="$PWD/.ais"

SCAN_FILE=""
PROJECTION_JSON=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scan) SCAN_FILE="$2"; shift 2 ;;
    --projection) PROJECTION_JSON="$2"; shift 2 ;;
    *) shift ;;
  esac
done

if [ -z "$SCAN_FILE" ] || [ ! -f "$SCAN_FILE" ]; then
  echo "AIS: --scan <file> is required and must exist" >&2
  exit 1
fi

echo "[$TIMESTAMP] generate-report.sh: scan=$SCAN_FILE" >> "$DEBUG_LOG"

# --- Read scan data ---
SCAN=$(cat "$SCAN_FILE")
TOTAL=$(echo "$SCAN" | jq '.stats.total')
ERRORS=$(echo "$SCAN" | jq '.stats.errors')
WARNINGS=$(echo "$SCAN" | jq '.stats.warnings')
FILES_CHECKED=$(echo "$SCAN" | jq '.files_checked')
SCOPE=$(echo "$SCAN" | jq -r '.scope // ""')

UNIQUE_ERROR_RULES=$(echo "$SCAN" | jq '[.violations[] | select(.severity=="error") | .rule] | unique | length')
UNIQUE_WARNING_RULES=$(echo "$SCAN" | jq '[.violations[] | select(.severity=="warning") | .rule] | unique | length')

# Health score: 100 - unique_error_rules×10 - unique_warning_rules×3, floor 0
SCORE=$(echo "$UNIQUE_ERROR_RULES $UNIQUE_WARNING_RULES" | awk '{s=100-$1*10-$2*3; print (s<0?0:s)}')

# --- Trend arrow (compare to last history snapshot) ---
PREV_SCORE=""
HISTORY_DIR="$AIS_DIR/history"
mkdir -p "$HISTORY_DIR"

if [ -d "$HISTORY_DIR" ]; then
  LAST_SNAP=$(find "$HISTORY_DIR" -name "*.json" -type f | sort | tail -1)
  if [ -n "$LAST_SNAP" ]; then
    PREV_SCORE=$(jq '.score // empty' "$LAST_SNAP" 2>/dev/null || true)
  fi
fi

if [ -z "$PREV_SCORE" ]; then
  ARROW="→"
  TREND_TEXT="First scan"
elif [ "$SCORE" -gt "$PREV_SCORE" ]; then
  ARROW="↑"
  TREND_TEXT="Up from $PREV_SCORE"
elif [ "$SCORE" -lt "$PREV_SCORE" ]; then
  ARROW="↓"
  TREND_TEXT="Down from $PREV_SCORE"
else
  ARROW="→"
  TREND_TEXT="No change from $PREV_SCORE"
fi

# --- Write history snapshot ---
SNAPSHOT_FILE="$HISTORY_DIR/$(date -u +%Y-%m-%dT%H-%M-%S).json"
echo "$SCAN" | jq \
  --argjson score "$SCORE" \
  --arg ts "$TIMESTAMP" \
  '{score: $score, timestamp: $ts, stats: .stats, violations: .violations}' \
  > "$SNAPSHOT_FILE"
echo "[$TIMESTAMP] History snapshot: $SNAPSHOT_FILE" >> "$DEBUG_LOG"

# --- Compute SVG sparkline from history scores ---
SVG_SPARKLINE=""
SCORE_HISTORY=$(find "$HISTORY_DIR" -name "*.json" -type f | sort | tail -10 | while read -r f; do
  jq '.score // 0' "$f" 2>/dev/null || echo 0
done | tr '\n' ' ')

if [ "$(echo "$SCORE_HISTORY" | wc -w | tr -d ' ')" -ge 2 ]; then
  SVG_SPARKLINE=$(echo "$SCORE_HISTORY" | python3 -c "
import sys
vals = list(map(float, sys.stdin.read().split()))
if len(vals) < 2:
    sys.exit()
w, h = 300, 60
mn, mx = min(vals), max(vals)
rng = mx - mn if mx != mn else 1
pts = []
for i, v in enumerate(vals):
    x = i * (w - 1) / max(len(vals) - 1, 1)
    y = h - ((v - mn) / rng) * (h - 8) - 4
    pts.append(f'{x:.1f},{y:.1f}')
color = '#4ade80' if vals[-1] >= vals[0] else '#f87171'
print(f'<polyline points=\"{\" \".join(pts)}\" stroke=\"{color}\" stroke-width=\"2\" fill=\"none\" stroke-linejoin=\"round\"/>')
" 2>/dev/null || true)
fi

# --- Module breakdown table ---
MODULE_TABLE_HTML=$(echo "$SCAN" | jq -r '
  if (.violations | length) == 0 then
    "<tr><td colspan=\"3\" style=\"color:#4ade80\">All modules clean ✓</td></tr>"
  else
    .violations
    | group_by(.file | split("/")[0:2] | join("/"))
    | map({
        module: (.[0].file | split("/")[0:2] | join("/")),
        errors: (map(select(.severity=="error")) | length),
        warnings: (map(select(.severity=="warning")) | length)
      })
    | sort_by(-.errors, -.warnings)
    | .[:15]
    | .[]
    | "<tr><td><code>\(.module)</code></td><td class=\"e\">\(.errors)</td><td class=\"w\">\(.warnings)</td></tr>"
  end
' 2>/dev/null || echo "<tr><td colspan=\"3\">Error computing modules</td></tr>")

# --- Top violations list ---
VIOLATIONS_HTML=$(echo "$SCAN" | jq -r '
  if (.violations | length) == 0 then
    "<p style=\"color:#4ade80\">No violations found ✓</p>"
  else
    .violations
    | sort_by(if .severity == "error" then 0 else 1 end, .rule)
    | .[:30]
    | .[]
    | "<div class=\"v \(.severity)\"><span class=\"badge\">\(.severity | ascii_upcase)</span> <code>\(.rule)</code> — <span class=\"filepath\">\(.file)\(if (.line != null and .line != "") then ":\(.line)" else "" end)</span></div>"
  end
' 2>/dev/null || echo "<p>Error computing violations</p>")

# --- Debt projection callout ---
PROJECTION_HTML=""
if [ -n "$PROJECTION_JSON" ]; then
  VELOCITY=$(echo "$PROJECTION_JSON" | jq -r '.velocity // ""')
  PROJ_30=$(echo "$PROJECTION_JSON" | jq -r '.projection_30d // ""')
  TREND=$(echo "$PROJECTION_JSON" | jq -r '.trend // "stable"')
  REC=$(echo "$PROJECTION_JSON" | jq -r '.recommendation // ""')
  if [ -n "$VELOCITY" ] && [ "$VELOCITY" != "null" ]; then
    TREND_ICON="→"
    [ "$TREND" = "degrading" ] && TREND_ICON="📈"
    [ "$TREND" = "improving" ] && TREND_ICON="📉"
    PROJECTION_HTML="<div class=\"proj\"><h2>$TREND_ICON Debt Projection</h2><p><strong>Trend:</strong> $TREND | <strong>30-day projection:</strong> +$PROJ_30 violations at current rate ($VELOCITY/day)</p>$([ -n "$REC" ] && echo "<p class=\"rec\">$REC</p>")</div>"
  fi
fi

# --- Score color ---
SCORE_COLOR="#4ade80"
[ "$SCORE" -lt 80 ] && SCORE_COLOR="#facc15"
[ "$SCORE" -lt 50 ] && SCORE_COLOR="#f87171"

SCOPE_LABEL="entire project"
[ -n "$SCOPE" ] && SCOPE_LABEL="$SCOPE"

# --- Generate HTML ---
REPORT_FILE="$AIS_DIR/report.html"
cat > "$REPORT_FILE" <<HTMLEOF
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>AIS Health Report</title>
  <style>
    *, *::before, *::after { box-sizing: border-box; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
      background: #0f172a; color: #e2e8f0;
      max-width: 960px; margin: 0 auto; padding: 32px 24px;
      line-height: 1.5;
    }
    h1 { font-size: 24px; font-weight: 700; color: #f8fafc; margin: 0 0 4px; }
    h2 { font-size: 16px; font-weight: 600; color: #94a3b8; text-transform: uppercase;
         letter-spacing: .05em; border-bottom: 1px solid #1e293b;
         padding-bottom: 8px; margin: 32px 0 12px; }
    .meta { color: #475569; font-size: 13px; margin-bottom: 28px; }
    .score-row { display: flex; align-items: baseline; gap: 12px; margin-bottom: 8px; }
    .score { font-size: 80px; font-weight: 800; color: ${SCORE_COLOR}; line-height: 1; }
    .arrow { font-size: 40px; color: ${SCORE_COLOR}; }
    .score-sub { color: #64748b; font-size: 14px; }
    .summary { color: #94a3b8; font-size: 14px; margin: 4px 0 0; }
    table { width: 100%; border-collapse: collapse; font-size: 14px; }
    th { color: #64748b; font-weight: 500; text-align: left; padding: 6px 10px;
         border-bottom: 2px solid #1e293b; }
    td { padding: 7px 10px; border-bottom: 1px solid #1e293b; }
    .e { color: #f87171; font-weight: 600; }
    .w { color: #facc15; font-weight: 600; }
    .v { padding: 8px 12px; margin: 4px 0; border-radius: 6px;
         background: #1e293b; font-size: 13px; }
    .v.error { border-left: 3px solid #f87171; }
    .v.warning { border-left: 3px solid #facc15; }
    .badge { font-size: 10px; font-weight: 700; padding: 2px 6px; border-radius: 3px;
             margin-right: 8px; vertical-align: middle; }
    .error .badge { background: #450a0a; color: #fca5a5; }
    .warning .badge { background: #422006; color: #fde68a; }
    code { font-family: 'SF Mono', 'Fira Code', monospace; font-size: 12px; color: #93c5fd; }
    .filepath { color: #94a3b8; font-size: 12px; font-family: monospace; }
    .chart-wrap { background: #1e293b; border-radius: 8px; padding: 16px;
                  display: inline-block; margin: 4px 0; }
    .proj { background: #1e293b; border-radius: 8px; padding: 20px; margin: 8px 0; }
    .proj h2 { margin-top: 0; border: none; padding: 0; }
    .rec { color: #94a3b8; font-size: 13px; margin: 8px 0 0;
           border-left: 3px solid #334155; padding-left: 12px; }
    footer { color: #1e293b; font-size: 11px; margin-top: 48px; text-align: center; }
  </style>
</head>
<body>
  <h1>🏥 AIS Architectural Health</h1>
  <p class="meta">$(date '+%Y-%m-%d %H:%M') · Scanned $SCOPE_LABEL · $FILES_CHECKED file(s)</p>

  <div class="score-row">
    <span class="score">$SCORE</span>
    <span class="arrow">$ARROW</span>
    <span class="score-sub">/ 100</span>
  </div>
  <p class="summary">$TREND_TEXT · $TOTAL violation(s) · $UNIQUE_ERROR_RULES unique error rule(s) · $UNIQUE_WARNING_RULES unique warning rule(s)</p>

  <h2>Module Breakdown</h2>
  <table>
    <tr><th>Module</th><th>Errors</th><th>Warnings</th></tr>
    ${MODULE_TABLE_HTML}
  </table>

  <h2>Violations</h2>
  ${VIOLATIONS_HTML}

$(if [ -n "$SVG_SPARKLINE" ]; then
  echo "  <h2>Health Trend</h2>"
  echo "  <div class=\"chart-wrap\">"
  echo "    <svg width=\"300\" height=\"60\" style=\"display:block;overflow:visible\">"
  echo "      $SVG_SPARKLINE"
  echo "    </svg>"
  echo "  </div>"
fi)

  ${PROJECTION_HTML}

  <footer>Generated by AIS · Run /ais:scan for terminal view · /ais:baseline to re-initialize</footer>
</body>
</html>
HTMLEOF

echo "[$TIMESTAMP] Report written: $REPORT_FILE" >> "$DEBUG_LOG"
open "$REPORT_FILE" 2>/dev/null || xdg-open "$REPORT_FILE" 2>/dev/null || echo "AIS: Open $REPORT_FILE in your browser" >&2

# Output summary JSON for Claude to narrate
jq -n \
  --argjson score "$SCORE" \
  --arg arrow "$ARROW" \
  --arg trend_text "$TREND_TEXT" \
  --argjson total "$TOTAL" \
  --argjson errors "$ERRORS" \
  --argjson warnings "$WARNINGS" \
  --argjson files_checked "$FILES_CHECKED" \
  --arg report_path "$REPORT_FILE" \
  '{score:$score, arrow:$arrow, trend_text:$trend_text,
    stats:{total:$total,errors:$errors,warnings:$warnings,files_checked:$files_checked},
    report_path:$report_path}'
