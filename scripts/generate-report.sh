#!/usr/bin/env bash
set -euo pipefail

# Thymus generate-report.sh — HTML health report generator
# Usage: bash generate-report.sh --scan /path/to/scan.json [--projection '{"velocity":...}']
# Output: writes .thymus/report.html, opens in browser, prints JSON summary to stdout

DEBUG_LOG="/tmp/thymus-debug.log"
TIMESTAMP=$(date '+%Y-%m-%dT%H:%M:%S')
THYMUS_DIR="$PWD/.thymus"

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
  echo "Thymus: --scan <file> is required and must exist" >&2
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
HISTORY_DIR="$THYMUS_DIR/history"
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
  jq '.score // empty' "$f" 2>/dev/null || true
done | grep -E '^[0-9]+$' | tr '\n' ' ')

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
color = '#34c759' if vals[-1] >= vals[0] else '#ff3b30'
print(f'<polyline points=\"{\" \".join(pts)}\" stroke=\"{color}\" stroke-width=\"1.5\" fill=\"none\" stroke-linejoin=\"round\" stroke-linecap=\"round\"/>')
" 2>/dev/null || true)
fi

# --- Module breakdown ---
MODULE_TABLE_HTML=$(echo "$SCAN" | jq -r '
  if (.violations | length) == 0 then
    "<li class=\"mod-row\"><div class=\"all-clear\"><span class=\"clr-dot\"></span>All modules clean</div></li>"
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
    | "<li class=\"mod-row\"><span class=\"mod-name\">\(.module)</span><div class=\"mod-counts\"><span class=\"cnt\"><span class=\"dot e\"></span><span class=\"cnt-n \(if .errors > 0 then "e" else "" end)\">\(.errors)</span></span><span class=\"cnt\"><span class=\"dot w\"></span><span class=\"cnt-n \(if .warnings > 0 then "w" else "" end)\">\(.warnings)</span></span></div></li>"
  end
' 2>/dev/null || echo "<li><p style=\"color:#aeaeb2\">Error computing modules</p></li>")

# --- Top violations list ---
VIOLATIONS_HTML=$(echo "$SCAN" | jq -r '
  if (.violations | length) == 0 then
    "<li class=\"viol-row\" style=\"border-bottom:none\"><div class=\"all-clear\"><span class=\"clr-dot\"></span>No violations found</div></li>"
  else
    .violations
    | sort_by(if .severity == "error" then 0 else 1 end, .rule)
    | .[:30]
    | .[]
    | "<li class=\"viol-row\"><span class=\"viol-bar \(.severity)\"></span><div class=\"viol-info\"><div class=\"viol-rule\">\(.rule)</div><div class=\"viol-file\">\(.file)\(if (.line != null and .line != "") then ":\(.line)" else "" end)</div></div><span class=\"sev-tag \(.severity)\">\(.severity | ascii_upcase)</span></li>"
  end
' 2>/dev/null || echo "<li><p style=\"color:#aeaeb2\">Error computing violations</p></li>")

# --- Debt projection callout ---
PROJECTION_HTML=""
if [ -n "$PROJECTION_JSON" ]; then
  VELOCITY=$(echo "$PROJECTION_JSON" | jq -r '.velocity // ""')
  PROJ_30=$(echo "$PROJECTION_JSON" | jq -r '.projection_30d // ""')
  TREND=$(echo "$PROJECTION_JSON" | jq -r '.trend // "stable"')
  REC=$(echo "$PROJECTION_JSON" | jq -r '.recommendation // ""')
  if [ -n "$VELOCITY" ] && [ "$VELOCITY" != "null" ]; then
    TREND_ICON="→"
    [ "$TREND" = "degrading" ] && TREND_ICON="↗"
    [ "$TREND" = "improving" ] && TREND_ICON="↘"
    PROJECTION_HTML="<section><p class=\"sec-head\">Debt Projection</p><hr><div class=\"proj-card\"><p class=\"proj-title\">$TREND_ICON Trend: $TREND</p><p class=\"proj-body\"><b>Velocity:</b> $VELOCITY violations/day &middot; <b>30-day projection:</b> +$PROJ_30 violations</p>$([ -n "$REC" ] && echo "<p class=\"proj-rec\">$REC</p>")</div></section>"
  fi
fi

# --- Score color ---
SCORE_COLOR="#34c759"
[ "$SCORE" -lt 80 ] && SCORE_COLOR="#ff9500"
[ "$SCORE" -lt 50 ] && SCORE_COLOR="#ff3b30"

SCOPE_LABEL="entire project"
[ -n "$SCOPE" ] && SCOPE_LABEL="$SCOPE"

# --- Generate HTML ---
REPORT_FILE="$THYMUS_DIR/report.html"
cat > "$REPORT_FILE" <<HTMLEOF
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Thymus Architectural Health</title>
  <style>
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      font-family: -apple-system, 'SF Pro Text', 'Helvetica Neue', Arial, sans-serif;
      background: #fff;
      color: #1d1d1f;
      max-width: 720px;
      margin: 0 auto;
      padding: 56px 40px 80px;
      line-height: 1.45;
      -webkit-font-smoothing: antialiased;
      -moz-osx-font-smoothing: grayscale;
    }
    header {
      display: flex;
      align-items: flex-start;
      justify-content: space-between;
      margin-bottom: 56px;
    }
    .brand { display: flex; align-items: center; gap: 10px; }
    .brand-mark {
      width: 26px; height: 26px;
      background: #1d1d1f;
      border-radius: 7px;
      display: flex; align-items: center; justify-content: center;
      flex-shrink: 0;
    }
    .brand-name { font-size: 14px; font-weight: 600; letter-spacing: -0.01em; }
    .scan-meta { font-size: 11px; color: #aeaeb2; text-align: right; line-height: 1.7; font-variant-numeric: tabular-nums; }

    /* Score hero */
    .score-hero { margin-bottom: 52px; }
    .score-display { display: flex; align-items: baseline; gap: 4px; margin-bottom: 10px; }
    .score-num {
      font-size: 108px;
      font-weight: 200;
      color: ${SCORE_COLOR};
      line-height: 1;
      letter-spacing: -0.05em;
      font-variant-numeric: tabular-nums;
    }
    .score-cap { font-size: 32px; font-weight: 200; color: #c7c7cc; letter-spacing: -0.02em; padding-bottom: 10px; }
    .score-trend { display: flex; align-items: center; gap: 8px; margin-bottom: 8px; }
    .trend-arrow { font-size: 20px; color: ${SCORE_COLOR}; line-height: 1; }
    .trend-label { font-size: 13px; color: #6e6e73; }
    .score-meta { font-size: 12px; color: #aeaeb2; }
    .score-meta b { color: #6e6e73; font-weight: 500; }

    /* Sections */
    section { margin-bottom: 44px; }
    .sec-head {
      font-size: 10px;
      font-weight: 600;
      letter-spacing: 0.09em;
      text-transform: uppercase;
      color: #aeaeb2;
      margin-bottom: 10px;
    }
    hr { border: none; border-top: 1px solid #e5e5ea; margin-bottom: 0; }

    /* Module rows */
    .mods { list-style: none; }
    .mod-row {
      display: flex;
      align-items: center;
      justify-content: space-between;
      padding: 11px 0;
      border-bottom: 1px solid #f2f2f7;
    }
    .mod-row:last-child { border-bottom: none; }
    .mod-name {
      font-family: 'SF Mono', 'Fira Code', 'Cascadia Code', ui-monospace, monospace;
      font-size: 12px;
      color: #1d1d1f;
    }
    .mod-counts { display: flex; gap: 20px; }
    .cnt { display: flex; align-items: center; gap: 5px; font-size: 12px; font-variant-numeric: tabular-nums; }
    .dot { width: 5px; height: 5px; border-radius: 50%; }
    .dot.e { background: #ff3b30; }
    .dot.w { background: #ff9500; }
    .cnt-n { color: #aeaeb2; font-weight: 500; }
    .cnt-n.e { color: #ff3b30; }
    .cnt-n.w { color: #ff9500; }

    /* Violation rows */
    .viols { list-style: none; }
    .viol-row {
      display: flex;
      align-items: center;
      gap: 14px;
      padding: 12px 0;
      border-bottom: 1px solid #f2f2f7;
    }
    .viol-row:last-child { border-bottom: none; }
    .viol-bar { width: 2px; height: 34px; border-radius: 1px; flex-shrink: 0; }
    .viol-bar.error { background: #ff3b30; }
    .viol-bar.warning { background: #ff9500; }
    .viol-info { flex: 1; min-width: 0; }
    .viol-rule {
      font-family: 'SF Mono', 'Fira Code', ui-monospace, monospace;
      font-size: 12px;
      font-weight: 500;
      color: #1d1d1f;
      margin-bottom: 3px;
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
    }
    .viol-file {
      font-family: 'SF Mono', 'Fira Code', ui-monospace, monospace;
      font-size: 11px;
      color: #aeaeb2;
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
    }
    .sev-tag {
      font-size: 9px;
      font-weight: 700;
      letter-spacing: 0.07em;
      text-transform: uppercase;
      padding: 3px 7px;
      border-radius: 5px;
      flex-shrink: 0;
    }
    .sev-tag.error { background: rgba(255,59,48,.08); color: #ff3b30; }
    .sev-tag.warning { background: rgba(255,149,0,.08); color: #ff9500; }

    /* All-clear state */
    .all-clear { display: flex; align-items: center; gap: 8px; padding: 14px 0; font-size: 13px; color: #34c759; }
    .clr-dot { width: 6px; height: 6px; border-radius: 50%; background: #34c759; flex-shrink: 0; }

    /* Sparkline */
    .chart-wrap { padding: 20px 0 8px; }
    .chart-wrap svg { display: block; overflow: visible; }

    /* Debt projection */
    .proj-card { background: #f5f5f7; border-radius: 14px; padding: 22px 26px; }
    .proj-title { font-size: 13px; font-weight: 600; color: #1d1d1f; margin-bottom: 6px; }
    .proj-body { font-size: 13px; color: #6e6e73; margin-bottom: 10px; }
    .proj-rec { font-size: 12px; color: #aeaeb2; border-left: 2px solid #d1d1d6; padding-left: 12px; }

    footer {
      font-size: 11px;
      color: #d1d1d6;
      text-align: center;
      margin-top: 40px;
      padding-top: 24px;
      border-top: 1px solid #f2f2f7;
    }
  </style>
</head>
<body>
  <header>
    <div class="brand">
      <div class="brand-mark">
        <svg width="14" height="14" viewBox="0 0 14 14" fill="none">
          <path d="M7 1.5L12.5 4.5V9.5L7 12.5L1.5 9.5V4.5L7 1.5Z" stroke="white" stroke-width="1.25" fill="none" stroke-linejoin="round"/>
          <circle cx="7" cy="7" r="1.75" fill="white"/>
        </svg>
      </div>
      <span class="brand-name">Thymus</span>
    </div>
    <div class="scan-meta">
      $(date '+%Y-%m-%d %H:%M')<br>
      $SCOPE_LABEL &middot; $FILES_CHECKED files
    </div>
  </header>

  <div class="score-hero">
    <div class="score-display">
      <span class="score-num">$SCORE</span>
      <span class="score-cap">/100</span>
    </div>
    <div class="score-trend">
      <span class="trend-arrow">$ARROW</span>
      <span class="trend-label">$TREND_TEXT</span>
    </div>
    <p class="score-meta">
      <b>$TOTAL</b> violation(s) &nbsp;&middot;&nbsp; <b>$UNIQUE_ERROR_RULES</b> error rule(s) &nbsp;&middot;&nbsp; <b>$UNIQUE_WARNING_RULES</b> warning rule(s)
    </p>
  </div>

  <section>
    <p class="sec-head">Modules</p>
    <hr>
    <ul class="mods">
      ${MODULE_TABLE_HTML}
    </ul>
  </section>

  <section>
    <p class="sec-head">Violations</p>
    <hr>
    <ul class="viols">
      ${VIOLATIONS_HTML}
    </ul>
  </section>

$(if [ -n "$SVG_SPARKLINE" ]; then
  echo "  <section><p class=\"sec-head\">Health Trend</p><hr><div class=\"chart-wrap\"><svg width=\"300\" height=\"60\" style=\"display:block;overflow:visible\">$SVG_SPARKLINE</svg></div></section>"
fi)

  ${PROJECTION_HTML}

  <footer>Generated by Thymus &nbsp;&middot;&nbsp; /thymus:scan for terminal view &nbsp;&middot;&nbsp; /thymus:baseline to re-initialize</footer>
</body>
</html>
HTMLEOF

echo "[$TIMESTAMP] Report written: $REPORT_FILE" >> "$DEBUG_LOG"
open "$REPORT_FILE" 2>/dev/null || xdg-open "$REPORT_FILE" 2>/dev/null || echo "Thymus: Open $REPORT_FILE in your browser" >&2

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
