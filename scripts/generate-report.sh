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
ERROR_COUNT=$(echo "$SCAN" | jq '[.violations[] | select(.severity=="error")] | length')
WARNING_COUNT=$(echo "$SCAN" | jq '[.violations[] | select(.severity=="warning")] | length')

# Health score: penalizes both unique rules and volume (log-scaled)
# Base: unique rules penalty + per-violation penalty using log scale
SCORE=$(echo "$UNIQUE_ERROR_RULES $UNIQUE_WARNING_RULES $ERROR_COUNT $WARNING_COUNT" | awk '{
  rule_penalty = $1*10 + $2*3;
  vol_penalty = 0;
  if ($3 > 0) vol_penalty += log($3+1)/log(2) * 3;
  if ($4 > 0) vol_penalty += log($4+1)/log(2) * 1;
  s = 100 - rule_penalty - vol_penalty;
  printf "%d", (s<0 ? 0 : s);
}')

# --- Compliance score ---
if [ "$FILES_CHECKED" -gt 0 ]; then
  COMPLIANCE=$(echo "$FILES_CHECKED $ERRORS" | awk '{printf "%.1f", (($1 - $2) / $1) * 100}')
else
  COMPLIANCE="100.0"
fi

# --- Read previous compliance score from JSONL history ---
HISTORY_FILE="$THYMUS_DIR/history.jsonl"
PREV_SCORE=""
if [ -f "$HISTORY_FILE" ] && [ -s "$HISTORY_FILE" ]; then
  PREV_SCORE=$(tail -1 "$HISTORY_FILE" | jq -r '.compliance_score // empty' 2>/dev/null || true)
fi

# --- Compliance delta ---
COMPLIANCE_DELTA=""
COMPLIANCE_ARROW=""
if [ -n "$PREV_SCORE" ] && [ "$PREV_SCORE" != "null" ]; then
  COMPLIANCE_DELTA=$(echo "$COMPLIANCE $PREV_SCORE" | awk '{d=$1-$2; printf "%+.1f", d}')
  if [ "$(echo "$COMPLIANCE $PREV_SCORE" | awk '{print ($1>$2)}')" = "1" ]; then
    COMPLIANCE_ARROW="↑"
  elif [ "$(echo "$COMPLIANCE $PREV_SCORE" | awk '{print ($1<$2)}')" = "1" ]; then
    COMPLIANCE_ARROW="↓"
  else
    COMPLIANCE_ARROW="→"
  fi
fi

# --- Health score trend arrow (uses compliance as proxy) ---
if [ -z "$PREV_SCORE" ]; then
  ARROW="→"
  TREND_TEXT="First scan"
else
  # Compare current compliance to previous
  COMP_CMP=$(echo "$COMPLIANCE $PREV_SCORE" | awk '{if ($1>$2) print "up"; else if ($1<$2) print "down"; else print "same"}')
  if [ "$COMP_CMP" = "up" ]; then
    ARROW="↑"
    TREND_TEXT="Up from ${PREV_SCORE}%"
  elif [ "$COMP_CMP" = "down" ]; then
    ARROW="↓"
    TREND_TEXT="Down from ${PREV_SCORE}%"
  else
    ARROW="→"
    TREND_TEXT="No change from ${PREV_SCORE}%"
  fi
fi

# --- Write history via append-history.sh ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
bash "$SCRIPT_DIR/append-history.sh" --scan "$SCAN_FILE"

# --- Compute SVG sparkline from last 30 compliance scores ---
SVG_SPARKLINE=""
if [ -f "$HISTORY_FILE" ] && [ -s "$HISTORY_FILE" ]; then
  SCORE_HISTORY=$(tail -30 "$HISTORY_FILE" | jq -r '.compliance_score // empty' 2>/dev/null | grep -E '^[0-9]' | tr '\n' ' ')

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
color = '#30d158' if vals[-1] >= vals[0] else '#ff453a'
print(f'<polyline points=\"{\" \".join(pts)}\" stroke=\"{color}\" stroke-width=\"1.5\" fill=\"none\" stroke-linejoin=\"round\" stroke-linecap=\"round\"/>')
" 2>/dev/null || true)
  fi
fi

# --- Per-rule mini sparklines (top 5 most-violated rules) ---
RULE_SPARKLINES_HTML=""
if [ -f "$HISTORY_FILE" ] && [ -s "$HISTORY_FILE" ]; then
  TOP_RULES=$(tail -30 "$HISTORY_FILE" | jq -s '[.[].by_rule // {} | to_entries[]] | group_by(.key) | map({rule: .[0].key, total: (map(.value) | add)}) | sort_by(-.total) | .[0:5] | .[].rule' -r 2>/dev/null || true)

  for rule in $TOP_RULES; do
    RULE_COUNTS=$(tail -30 "$HISTORY_FILE" | jq -r --arg r "$rule" '.by_rule[$r] // 0' 2>/dev/null | tr '\n' ' ')
    RULE_SVG=$(echo "$RULE_COUNTS" | python3 -c "
import sys
vals = list(map(float, sys.stdin.read().split()))
if len(vals) < 2:
    sys.exit()
w, h = 150, 30
mn, mx = min(vals), max(vals)
rng = mx - mn if mx != mn else 1
pts = []
for i, v in enumerate(vals):
    x = i * (w - 1) / max(len(vals) - 1, 1)
    y = h - ((v - mn) / rng) * (h - 4) - 2
    pts.append(f'{x:.1f},{y:.1f}')
color = '#89b4fa' if vals[-1] <= vals[0] else '#f38ba8'
print(f'<svg width=\"{w}\" height=\"{h}\" style=\"display:inline-block;vertical-align:middle;overflow:visible\"><polyline points=\"{\" \".join(pts)}\" stroke=\"{color}\" stroke-width=\"1.5\" fill=\"none\" stroke-linejoin=\"round\" stroke-linecap=\"round\"/></svg>')
" 2>/dev/null || true)
    CURRENT_COUNT=$(tail -1 "$HISTORY_FILE" | jq -r --arg r "$rule" '.by_rule[$r] // 0' 2>/dev/null || echo "0")
    if [ -n "$RULE_SVG" ]; then
      RULE_SPARKLINES_HTML="${RULE_SPARKLINES_HTML}<div class=\"rule-trend\"><code class=\"rule-name\">${rule}</code>${RULE_SVG}<span class=\"rule-count\">${CURRENT_COUNT}</span></div>"
    fi
  done
fi

# --- Worst-drift callout ---
WORST_DRIFT_HTML=""
if [ -f "$HISTORY_FILE" ]; then
  LINE_COUNT=$(wc -l < "$HISTORY_FILE" | tr -d ' ')
  if [ "$LINE_COUNT" -ge 10 ]; then
    WORST_DRIFT=$(python3 -c "
import json, sys
lines = open('$HISTORY_FILE').readlines()
if len(lines) >= 10:
    old = json.loads(lines[-10]).get('by_rule', {})
    new = json.loads(lines[-1]).get('by_rule', {})
    diffs = {}
    for r in set(list(old.keys()) + list(new.keys())):
        diff = new.get(r, 0) - old.get(r, 0)
        if diff > 0:
            diffs[r] = diff
    if diffs:
        worst = max(diffs, key=diffs.get)
        print(f'{worst}|{diffs[worst]}')
" 2>/dev/null || true)
    if [ -n "$WORST_DRIFT" ]; then
      DRIFT_RULE=$(echo "$WORST_DRIFT" | cut -d'|' -f1)
      DRIFT_INCREASE=$(echo "$WORST_DRIFT" | cut -d'|' -f2)
      WORST_DRIFT_HTML="<div class=\"drift-callout\"><span class=\"drift-icon\">↗</span> Worst drift: <code>$DRIFT_RULE</code> — increased by $DRIFT_INCREASE violation(s) over last 10 scans</div>"
    fi
  fi
fi

# --- Sprint summary (last 14 days, 5+ scans) ---
SPRINT_HTML=""
if [ -f "$HISTORY_FILE" ]; then
  SPRINT_DATA=$(python3 -c "
import json, sys
from datetime import datetime, timedelta
lines = open('$HISTORY_FILE').readlines()
cutoff = (datetime.utcnow() - timedelta(days=14)).isoformat() + 'Z'
recent = [json.loads(l) for l in lines if json.loads(l).get('timestamp','') >= cutoff]
if len(recent) >= 5:
    first_score = recent[0].get('compliance_score', 0)
    last_score = recent[-1].get('compliance_score', 0)
    total_errors = sum(r.get('violations',{}).get('error',0) for r in recent)
    print(f'{len(recent)}|{first_score}|{last_score}|{total_errors}')
" 2>/dev/null || true)
  if [ -n "$SPRINT_DATA" ]; then
    SPRINT_COUNT=$(echo "$SPRINT_DATA" | cut -d'|' -f1)
    SPRINT_FIRST=$(echo "$SPRINT_DATA" | cut -d'|' -f2)
    SPRINT_LAST=$(echo "$SPRINT_DATA" | cut -d'|' -f3)
    SPRINT_ERRORS=$(echo "$SPRINT_DATA" | cut -d'|' -f4)
    SPRINT_HTML="<div class=\"sprint-card\"><p class=\"sprint-title\">Sprint Summary (last 14 days)</p><p class=\"sprint-body\">${SPRINT_COUNT} scans &middot; Compliance: ${SPRINT_FIRST}% → ${SPRINT_LAST}% &middot; ${SPRINT_ERRORS} total errors</p></div>"
  fi
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
' 2>/dev/null || echo "<li><p style=\"color:#636366\">Error computing modules</p></li>")

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
' 2>/dev/null || echo "<li><p style=\"color:#636366\">Error computing violations</p></li>")

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
SCORE_COLOR="#30d158"
[ "$SCORE" -lt 80 ] && SCORE_COLOR="#ff9f0a"
[ "$SCORE" -lt 50 ] && SCORE_COLOR="#ff453a"

COMPLIANCE_COLOR="#30d158"
COMPLIANCE_INT=$(echo "$COMPLIANCE" | awk '{printf "%d", $1}')
[ "$COMPLIANCE_INT" -lt 80 ] && COMPLIANCE_COLOR="#ff9f0a"
[ "$COMPLIANCE_INT" -lt 50 ] && COMPLIANCE_COLOR="#ff453a"

COMPLIANCE_DELTA_CLASS=""
if [ -n "$COMPLIANCE_ARROW" ]; then
  [ "$COMPLIANCE_ARROW" = "↑" ] && COMPLIANCE_DELTA_CLASS="up"
  [ "$COMPLIANCE_ARROW" = "↓" ] && COMPLIANCE_DELTA_CLASS="down"
fi

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
      background: #1c1c1e;
      color: #f5f5f7;
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
      background: #f5f5f7;
      border-radius: 7px;
      display: flex; align-items: center; justify-content: center;
      flex-shrink: 0;
    }
    .brand-mark svg path { stroke: #1c1c1e; }
    .brand-mark svg circle { fill: #1c1c1e; }
    .brand-name { font-size: 14px; font-weight: 600; letter-spacing: -0.01em; }
    .scan-meta { font-size: 11px; color: #8e8e93; text-align: right; line-height: 1.7; font-variant-numeric: tabular-nums; }

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
    .score-cap { font-size: 32px; font-weight: 200; color: #48484a; letter-spacing: -0.02em; padding-bottom: 10px; }
    .score-trend { display: flex; align-items: center; gap: 8px; margin-bottom: 8px; }
    .trend-arrow { font-size: 20px; color: ${SCORE_COLOR}; line-height: 1; }
    .trend-label { font-size: 13px; color: #8e8e93; }
    .score-meta { font-size: 12px; color: #8e8e93; }
    .score-meta b { color: #aeaeb2; font-weight: 500; }

    /* Sections */
    section { margin-bottom: 44px; }
    .sec-head {
      font-size: 10px;
      font-weight: 600;
      letter-spacing: 0.09em;
      text-transform: uppercase;
      color: #8e8e93;
      margin-bottom: 10px;
    }
    hr { border: none; border-top: 1px solid #38383a; margin-bottom: 0; }

    /* Module rows */
    .mods { list-style: none; }
    .mod-row {
      display: flex;
      align-items: center;
      justify-content: space-between;
      padding: 11px 0;
      border-bottom: 1px solid #2c2c2e;
    }
    .mod-row:last-child { border-bottom: none; }
    .mod-name {
      font-family: 'SF Mono', 'Fira Code', 'Cascadia Code', ui-monospace, monospace;
      font-size: 12px;
      color: #f5f5f7;
    }
    .mod-counts { display: flex; gap: 20px; }
    .cnt { display: flex; align-items: center; gap: 5px; font-size: 12px; font-variant-numeric: tabular-nums; }
    .dot { width: 5px; height: 5px; border-radius: 50%; }
    .dot.e { background: #ff453a; }
    .dot.w { background: #ff9f0a; }
    .cnt-n { color: #636366; font-weight: 500; }
    .cnt-n.e { color: #ff453a; }
    .cnt-n.w { color: #ff9f0a; }

    /* Violation rows */
    .viols { list-style: none; }
    .viol-row {
      display: flex;
      align-items: center;
      gap: 14px;
      padding: 12px 0;
      border-bottom: 1px solid #2c2c2e;
    }
    .viol-row:last-child { border-bottom: none; }
    .viol-bar { width: 2px; height: 34px; border-radius: 1px; flex-shrink: 0; }
    .viol-bar.error { background: #ff453a; }
    .viol-bar.warning { background: #ff9f0a; }
    .viol-info { flex: 1; min-width: 0; }
    .viol-rule {
      font-family: 'SF Mono', 'Fira Code', ui-monospace, monospace;
      font-size: 12px;
      font-weight: 500;
      color: #f5f5f7;
      margin-bottom: 3px;
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
    }
    .viol-file {
      font-family: 'SF Mono', 'Fira Code', ui-monospace, monospace;
      font-size: 11px;
      color: #8e8e93;
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
    .sev-tag.error { background: rgba(255,69,58,.15); color: #ff453a; }
    .sev-tag.warning { background: rgba(255,159,10,.15); color: #ff9f0a; }

    /* All-clear state */
    .all-clear { display: flex; align-items: center; gap: 8px; padding: 14px 0; font-size: 13px; color: #30d158; }
    .clr-dot { width: 6px; height: 6px; border-radius: 50%; background: #30d158; flex-shrink: 0; }

    /* Sparkline */
    .chart-wrap { padding: 20px 0 8px; }
    .chart-wrap svg { display: block; overflow: visible; }

    /* Debt projection */
    .proj-card { background: #2c2c2e; border-radius: 14px; padding: 22px 26px; }
    .proj-title { font-size: 13px; font-weight: 600; color: #f5f5f7; margin-bottom: 6px; }
    .proj-body { font-size: 13px; color: #8e8e93; margin-bottom: 10px; }
    .proj-rec { font-size: 12px; color: #636366; border-left: 2px solid #48484a; padding-left: 12px; }

    /* Compliance score */
    .compliance { margin-bottom: 16px; }
    .compliance-num { font-size: 48px; font-weight: 200; line-height: 1; font-variant-numeric: tabular-nums; }
    .compliance-pct { font-size: 20px; font-weight: 200; color: #48484a; }
    .compliance-delta { font-size: 16px; margin-left: 8px; }
    .compliance-delta.up { color: #30d158; }
    .compliance-delta.down { color: #ff453a; }

    /* Rule trends */
    .rule-trend { display: flex; align-items: center; gap: 12px; padding: 8px 0; border-bottom: 1px solid #2c2c2e; }
    .rule-trend:last-child { border-bottom: none; }
    .rule-name { font-size: 11px; color: #8e8e93; min-width: 200px; }
    .rule-count { font-size: 12px; color: #f5f5f7; font-variant-numeric: tabular-nums; min-width: 30px; text-align: right; }

    /* Drift callout */
    .drift-callout { background: rgba(243,139,168,.08); border-left: 2px solid #f38ba8; padding: 12px 16px; font-size: 12px; color: #cdd6f4; margin-top: 16px; border-radius: 0 8px 8px 0; }
    .drift-icon { color: #f38ba8; }

    /* Sprint card */
    .sprint-card { background: #2c2c2e; border-radius: 14px; padding: 22px 26px; margin-top: 16px; }
    .sprint-title { font-size: 13px; font-weight: 600; color: #f5f5f7; margin-bottom: 6px; }
    .sprint-body { font-size: 13px; color: #8e8e93; }

    footer {
      font-size: 11px;
      color: #48484a;
      text-align: center;
      margin-top: 40px;
      padding-top: 24px;
      border-top: 1px solid #2c2c2e;
    }
  </style>
</head>
<body>
  <header>
    <div class="brand">
      <div class="brand-mark">
        <svg width="14" height="14" viewBox="0 0 14 14" fill="none">
          <path d="M7 1.5L12.5 4.5V9.5L7 12.5L1.5 9.5V4.5L7 1.5Z" stroke="#1c1c1e" stroke-width="1.25" fill="none" stroke-linejoin="round"/>
          <circle cx="7" cy="7" r="1.75" fill="#1c1c1e"/>
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

  <div class="compliance">
    <div class="score-display">
      <span class="compliance-num" style="color:${COMPLIANCE_COLOR}">${COMPLIANCE}</span>
      <span class="compliance-pct">%</span>
$(if [ -n "$COMPLIANCE_DELTA" ] && [ -n "$COMPLIANCE_ARROW" ]; then
  echo "      <span class=\"compliance-delta ${COMPLIANCE_DELTA_CLASS}\">${COMPLIANCE_ARROW} ${COMPLIANCE_DELTA}</span>"
fi)
    </div>
    <p class="score-meta">Compliance — files passing / files checked</p>
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
  echo "  <section><p class=\"sec-head\">Compliance Trend</p><hr><div class=\"chart-wrap\"><svg width=\"300\" height=\"60\" style=\"display:block;overflow:visible\">$SVG_SPARKLINE</svg></div></section>"
fi)

$(if [ -n "$RULE_SPARKLINES_HTML" ]; then
  echo "  <section><p class=\"sec-head\">Rule Trends (Top 5)</p><hr>${RULE_SPARKLINES_HTML}</section>"
fi)

  ${WORST_DRIFT_HTML}

  ${SPRINT_HTML}

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
  --argjson compliance "$COMPLIANCE" \
  --arg arrow "$ARROW" \
  --arg trend_text "$TREND_TEXT" \
  --argjson total "$TOTAL" \
  --argjson errors "$ERRORS" \
  --argjson warnings "$WARNINGS" \
  --argjson files_checked "$FILES_CHECKED" \
  --arg report_path "$REPORT_FILE" \
  '{score:$score, compliance:$compliance, arrow:$arrow, trend_text:$trend_text,
    stats:{total:$total,errors:$errors,warnings:$warnings,files_checked:$files_checked},
    report_path:$report_path}'
