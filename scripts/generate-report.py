#!/usr/bin/env python3
"""Thymus generate-report.py -- HTML health report generator.

Usage: python3 generate-report.py --scan /path/to/scan.json [--projection '{"velocity":...}']
Output: writes .thymus/report.html, opens in browser, prints JSON summary to stdout

Replaces generate-report.sh with zero subprocess overhead (except browser open).
Calls append-history IN-PROCESS.

Python 3 stdlib only. No pip dependencies.
"""

import datetime
import json
import math
import os
import subprocess
import sys

# Add lib/ to path
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), 'lib'))
from core import debug_log

# Import append-history functions IN-PROCESS
from importlib.util import spec_from_file_location, module_from_spec
_append_history_mod = None


def _get_append_history_mod():
    """Lazy-load append-history.py module."""
    global _append_history_mod
    if _append_history_mod is not None:
        return _append_history_mod
    scripts_dir = os.path.dirname(os.path.abspath(__file__))
    path = os.path.join(scripts_dir, "append-history.py")
    spec = spec_from_file_location("append_history", path)
    mod = module_from_spec(spec)
    spec.loader.exec_module(mod)
    _append_history_mod = mod
    return mod


def _html_escape(s):
    """Minimal HTML escaping for user-provided strings."""
    return (str(s)
            .replace("&", "&amp;")
            .replace("<", "&lt;")
            .replace(">", "&gt;")
            .replace('"', "&quot;"))


def _compute_sparkline_polyline(vals, w, h, margin_top=4, margin_bot=4):
    """Compute SVG polyline points from a list of values."""
    if len(vals) < 2:
        return None
    mn, mx = min(vals), max(vals)
    rng = mx - mn if mx != mn else 1
    pts = []
    for i, v in enumerate(vals):
        x = i * (w - 1) / max(len(vals) - 1, 1)
        y = h - ((v - mn) / rng) * (h - margin_top - margin_bot) - margin_bot
        pts.append(f"{x:.1f},{y:.1f}")
    return " ".join(pts)


def _read_history_lines(history_file):
    """Read history.jsonl and return list of stripped lines."""
    if not os.path.isfile(history_file) or os.path.getsize(history_file) == 0:
        return []
    try:
        with open(history_file) as f:
            return [line.strip() for line in f if line.strip()]
    except OSError:
        return []


def _build_module_table_html(violations):
    """Build module breakdown HTML rows."""
    if not violations:
        return '<li class="mod-row"><div class="all-clear"><span class="clr-dot"></span>All modules clean</div></li>'

    # Group by module (first 2 path segments)
    modules = {}
    for v in violations:
        f = v.get("file", "")
        parts = f.split("/")
        module = "/".join(parts[:2]) if len(parts) >= 2 else f
        if module not in modules:
            modules[module] = {"errors": 0, "warnings": 0}
        if v.get("severity") == "error":
            modules[module]["errors"] += 1
        elif v.get("severity") == "warning":
            modules[module]["warnings"] += 1

    # Sort by errors desc, then warnings desc
    sorted_mods = sorted(modules.items(), key=lambda x: (-x[1]["errors"], -x[1]["warnings"]))
    sorted_mods = sorted_mods[:15]

    rows = []
    for mod_name, counts in sorted_mods:
        e = counts["errors"]
        w = counts["warnings"]
        e_class = " e" if e > 0 else ""
        w_class = " w" if w > 0 else ""
        rows.append(
            f'<li class="mod-row">'
            f'<span class="mod-name">{_html_escape(mod_name)}</span>'
            f'<div class="mod-counts">'
            f'<span class="cnt"><span class="dot e"></span>'
            f'<span class="cnt-n{e_class}">{e}</span></span>'
            f'<span class="cnt"><span class="dot w"></span>'
            f'<span class="cnt-n{w_class}">{w}</span></span>'
            f'</div></li>'
        )
    return "\n".join(rows)


def _build_violations_html(violations):
    """Build violations list HTML rows."""
    if not violations:
        return '<li class="viol-row" style="border-bottom:none"><div class="all-clear"><span class="clr-dot"></span>No violations found</div></li>'

    # Sort: errors first, then by rule
    sorted_viols = sorted(violations,
                          key=lambda v: (0 if v.get("severity") == "error" else 1,
                                        v.get("rule", "")))
    sorted_viols = sorted_viols[:30]

    rows = []
    for v in sorted_viols:
        severity = v.get("severity", "warning")
        rule = _html_escape(v.get("rule", ""))
        f = _html_escape(v.get("file", ""))
        line = v.get("line")
        file_display = f
        if line is not None and str(line) != "":
            file_display = f"{f}:{line}"
        sev_upper = severity.upper()
        rows.append(
            f'<li class="viol-row">'
            f'<span class="viol-bar {severity}"></span>'
            f'<div class="viol-info">'
            f'<div class="viol-rule">{rule}</div>'
            f'<div class="viol-file">{file_display}</div>'
            f'</div>'
            f'<span class="sev-tag {severity}">{sev_upper}</span></li>'
        )
    return "\n".join(rows)


def main():
    timestamp = datetime.datetime.now().strftime("%Y-%m-%dT%H:%M:%S")
    thymus_dir = os.path.join(os.getcwd(), ".thymus")

    # Parse arguments
    scan_file = ""
    projection_json_str = ""
    args = sys.argv[1:]
    i = 0
    while i < len(args):
        if args[i] == "--scan" and i + 1 < len(args):
            scan_file = args[i + 1]
            i += 2
        elif args[i] == "--projection" and i + 1 < len(args):
            projection_json_str = args[i + 1]
            i += 2
        else:
            i += 1

    if not scan_file or not os.path.isfile(scan_file):
        print("Thymus: --scan <file> is required and must exist", file=sys.stderr)
        sys.exit(1)

    debug_log(f"generate-report.py: scan={scan_file}")

    # --- Read scan data ---
    with open(scan_file) as f:
        scan = json.load(f)

    total = scan.get("stats", {}).get("total", 0)
    errors = scan.get("stats", {}).get("errors", 0)
    warnings = scan.get("stats", {}).get("warnings", 0)
    files_checked = scan.get("files_checked", 0)
    scope = scan.get("scope", "") or ""
    violations = scan.get("violations", [])

    # Count unique rules
    error_rules = set()
    warning_rules = set()
    error_count = 0
    warning_count = 0
    for v in violations:
        sev = v.get("severity", "")
        rule = v.get("rule", "")
        if sev == "error":
            error_rules.add(rule)
            error_count += 1
        elif sev == "warning":
            warning_rules.add(rule)
            warning_count += 1

    unique_error_rules = len(error_rules)
    unique_warning_rules = len(warning_rules)

    # --- Health score ---
    # rule_penalty = unique_errors*10 + unique_warnings*3
    # vol_penalty = log2(error_count+1)*3 + log2(warning_count+1)*1
    # score = max(0, 100 - rule_penalty - vol_penalty)
    rule_penalty = unique_error_rules * 10 + unique_warning_rules * 3
    vol_penalty = 0.0
    if error_count > 0:
        vol_penalty += math.log2(error_count + 1) * 3
    if warning_count > 0:
        vol_penalty += math.log2(warning_count + 1) * 1
    score = int(max(0, 100 - rule_penalty - vol_penalty))

    # --- Compliance score ---
    if files_checked > 0:
        compliance = round(((files_checked - errors) / files_checked) * 100, 1)
    else:
        compliance = 100.0

    # Format compliance with one decimal place
    compliance_str = f"{compliance:.1f}"

    # --- Read previous compliance from history ---
    history_file = os.path.join(thymus_dir, "history.jsonl")
    history_lines = _read_history_lines(history_file)

    prev_score = None
    if history_lines:
        try:
            last_entry = json.loads(history_lines[-1])
            ps = last_entry.get("compliance_score")
            if ps is not None:
                prev_score = float(ps)
        except (json.JSONDecodeError, ValueError, TypeError):
            pass

    # --- Compliance delta ---
    compliance_delta = ""
    compliance_arrow = ""
    if prev_score is not None:
        delta = compliance - prev_score
        compliance_delta = f"{delta:+.1f}"
        if compliance > prev_score:
            compliance_arrow = "\u2191"  # up
        elif compliance < prev_score:
            compliance_arrow = "\u2193"  # down
        else:
            compliance_arrow = "\u2192"  # right

    # --- Health score trend arrow ---
    if prev_score is None:
        arrow = "\u2192"
        trend_text = "First scan"
    else:
        if compliance > prev_score:
            arrow = "\u2191"
            trend_text = f"Up from {prev_score}%"
        elif compliance < prev_score:
            arrow = "\u2193"
            trend_text = f"Down from {prev_score}%"
        else:
            arrow = "\u2192"
            trend_text = f"No change from {prev_score}%"

    # --- Write history via append-history IN-PROCESS ---
    ah = _get_append_history_mod()
    entry = ah.build_history_entry(scan)
    ah.append_history(entry, thymus_dir)

    # Re-read history after appending
    history_lines = _read_history_lines(history_file)

    # --- SVG sparkline from last 30 compliance scores ---
    svg_sparkline = ""
    if history_lines:
        last_30 = history_lines[-30:]
        score_vals = []
        for line in last_30:
            try:
                e = json.loads(line)
                cs = e.get("compliance_score")
                if cs is not None:
                    score_vals.append(float(cs))
            except (json.JSONDecodeError, ValueError):
                pass

        if len(score_vals) >= 2:
            pts = _compute_sparkline_polyline(score_vals, 300, 60, 4, 4)
            if pts:
                color = "#30d158" if score_vals[-1] >= score_vals[0] else "#ff453a"
                svg_sparkline = (
                    f'<polyline points="{pts}" stroke="{color}" '
                    f'stroke-width="1.5" fill="none" '
                    f'stroke-linejoin="round" stroke-linecap="round"/>'
                )

    # --- Per-rule mini sparklines (top 5 most-violated rules) ---
    rule_sparklines_html = ""
    if history_lines:
        last_30 = history_lines[-30:]
        last_30_entries = []
        for line in last_30:
            try:
                last_30_entries.append(json.loads(line))
            except (json.JSONDecodeError, ValueError):
                pass

        # Aggregate rule totals across last 30 entries
        rule_totals = {}
        for e in last_30_entries:
            by_rule = e.get("by_rule", {})
            for rule, count in by_rule.items():
                rule_totals[rule] = rule_totals.get(rule, 0) + count

        # Top 5 by total
        top_rules = sorted(rule_totals.items(), key=lambda x: -x[1])[:5]

        # Get last entry's by_rule for current count
        last_by_rule = {}
        if last_30_entries:
            last_by_rule = last_30_entries[-1].get("by_rule", {})

        for rule, _ in top_rules:
            rule_counts = []
            for e in last_30_entries:
                rule_counts.append(e.get("by_rule", {}).get(rule, 0))

            if len(rule_counts) >= 2:
                pts = _compute_sparkline_polyline(rule_counts, 150, 30, 2, 2)
                if pts:
                    color = "#89b4fa" if rule_counts[-1] <= rule_counts[0] else "#f38ba8"
                    current_count = last_by_rule.get(rule, 0)
                    rule_svg = (
                        f'<svg width="150" height="30" '
                        f'style="display:inline-block;vertical-align:middle;overflow:visible">'
                        f'<polyline points="{pts}" stroke="{color}" '
                        f'stroke-width="1.5" fill="none" '
                        f'stroke-linejoin="round" stroke-linecap="round"/></svg>'
                    )
                    rule_sparklines_html += (
                        f'<div class="rule-trend">'
                        f'<code class="rule-name">{_html_escape(rule)}</code>'
                        f'{rule_svg}'
                        f'<span class="rule-count">{current_count}</span></div>'
                    )

    # --- Worst-drift callout ---
    worst_drift_html = ""
    if len(history_lines) >= 10:
        try:
            old_entry = json.loads(history_lines[-10])
            new_entry = json.loads(history_lines[-1])
            old_by_rule = old_entry.get("by_rule", {})
            new_by_rule = new_entry.get("by_rule", {})
            all_rules = set(list(old_by_rule.keys()) + list(new_by_rule.keys()))
            diffs = {}
            for r in all_rules:
                diff = new_by_rule.get(r, 0) - old_by_rule.get(r, 0)
                if diff > 0:
                    diffs[r] = diff
            if diffs:
                worst = max(diffs, key=diffs.get)
                worst_drift_html = (
                    f'<div class="drift-callout">'
                    f'<span class="drift-icon">\u2197</span> '
                    f'Worst drift: <code>{_html_escape(worst)}</code> '
                    f'\u2014 increased by {diffs[worst]} violation(s) over last 10 scans</div>'
                )
        except (json.JSONDecodeError, ValueError, IndexError):
            pass

    # --- Sprint summary (last 14 days, >=5 scans) ---
    sprint_html = ""
    if history_lines:
        try:
            cutoff = (datetime.datetime.utcnow() - datetime.timedelta(days=14)).isoformat() + "Z"
            recent = []
            for line in history_lines:
                try:
                    e = json.loads(line)
                    if e.get("timestamp", "") >= cutoff:
                        recent.append(e)
                except (json.JSONDecodeError, ValueError):
                    pass
            if len(recent) >= 5:
                first_score = recent[0].get("compliance_score", 0)
                last_score = recent[-1].get("compliance_score", 0)
                total_errors = sum(
                    r.get("violations", {}).get("error", 0) for r in recent
                )
                sprint_html = (
                    f'<div class="sprint-card">'
                    f'<p class="sprint-title">Sprint Summary (last 14 days)</p>'
                    f'<p class="sprint-body">{len(recent)} scans &middot; '
                    f'Compliance: {first_score}% \u2192 {last_score}% &middot; '
                    f'{total_errors} total errors</p></div>'
                )
        except Exception:
            pass

    # --- Module breakdown ---
    module_table_html = _build_module_table_html(violations)

    # --- Top violations list ---
    violations_html = _build_violations_html(violations)

    # --- Debt projection ---
    projection_html = ""
    if projection_json_str:
        try:
            proj = json.loads(projection_json_str)
            velocity = proj.get("velocity")
            proj_30 = proj.get("projection_30d", "")
            trend = proj.get("trend", "stable")
            rec = proj.get("recommendation", "")

            if velocity is not None and str(velocity) != "null":
                trend_icon = "\u2192"
                if trend == "degrading":
                    trend_icon = "\u2197"
                elif trend == "improving":
                    trend_icon = "\u2198"

                rec_html = ""
                if rec:
                    rec_html = f'<p class="proj-rec">{_html_escape(rec)}</p>'

                projection_html = (
                    f'<section><p class="sec-head">Debt Projection</p><hr>'
                    f'<div class="proj-card">'
                    f'<p class="proj-title">{trend_icon} Trend: {_html_escape(trend)}</p>'
                    f'<p class="proj-body"><b>Velocity:</b> {velocity} violations/day '
                    f'&middot; <b>30-day projection:</b> +{proj_30} violations</p>'
                    f'{rec_html}'
                    f'</div></section>'
                )
        except (json.JSONDecodeError, ValueError):
            pass

    # --- Score colors ---
    score_color = "#30d158"
    if score < 80:
        score_color = "#ff9f0a"
    if score < 50:
        score_color = "#ff453a"

    compliance_color = "#30d158"
    compliance_int = int(compliance)
    if compliance_int < 80:
        compliance_color = "#ff9f0a"
    if compliance_int < 50:
        compliance_color = "#ff453a"

    compliance_delta_class = ""
    if compliance_arrow == "\u2191":
        compliance_delta_class = "up"
    elif compliance_arrow == "\u2193":
        compliance_delta_class = "down"

    scope_label = scope if scope else "entire project"

    # --- Compliance delta HTML ---
    compliance_delta_html = ""
    if compliance_delta and compliance_arrow:
        compliance_delta_html = (
            f'      <span class="compliance-delta {compliance_delta_class}">'
            f'{compliance_arrow} {compliance_delta}</span>'
        )

    # --- Sparkline section ---
    sparkline_section = ""
    if svg_sparkline:
        sparkline_section = (
            f'  <section><p class="sec-head">Compliance Trend</p><hr>'
            f'<div class="chart-wrap"><svg width="300" height="60" '
            f'style="display:block;overflow:visible">{svg_sparkline}</svg></div></section>'
        )

    # --- Rule trends section ---
    rule_trends_section = ""
    if rule_sparklines_html:
        rule_trends_section = (
            f'  <section><p class="sec-head">Rule Trends (Top 5)</p><hr>'
            f'{rule_sparklines_html}</section>'
        )

    # --- Scan date ---
    scan_date = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")

    # --- Generate HTML ---
    os.makedirs(thymus_dir, exist_ok=True)
    report_file = os.path.join(thymus_dir, "report.html")

    html = f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Thymus Architectural Health</title>
  <style>
    *, *::before, *::after {{ box-sizing: border-box; margin: 0; padding: 0; }}
    body {{
      font-family: -apple-system, 'SF Pro Text', 'Helvetica Neue', Arial, sans-serif;
      background: #1c1c1e;
      color: #f5f5f7;
      max-width: 720px;
      margin: 0 auto;
      padding: 56px 40px 80px;
      line-height: 1.45;
      -webkit-font-smoothing: antialiased;
      -moz-osx-font-smoothing: grayscale;
    }}
    header {{
      display: flex;
      align-items: flex-start;
      justify-content: space-between;
      margin-bottom: 56px;
    }}
    .brand {{ display: flex; align-items: center; gap: 10px; }}
    .brand-mark {{
      width: 26px; height: 26px;
      background: #f5f5f7;
      border-radius: 7px;
      display: flex; align-items: center; justify-content: center;
      flex-shrink: 0;
    }}
    .brand-mark svg path {{ stroke: #1c1c1e; }}
    .brand-mark svg circle {{ fill: #1c1c1e; }}
    .brand-name {{ font-size: 14px; font-weight: 600; letter-spacing: -0.01em; }}
    .scan-meta {{ font-size: 11px; color: #8e8e93; text-align: right; line-height: 1.7; font-variant-numeric: tabular-nums; }}

    /* Score hero */
    .score-hero {{ margin-bottom: 52px; }}
    .score-display {{ display: flex; align-items: baseline; gap: 4px; margin-bottom: 10px; }}
    .score-num {{
      font-size: 108px;
      font-weight: 200;
      color: {score_color};
      line-height: 1;
      letter-spacing: -0.05em;
      font-variant-numeric: tabular-nums;
    }}
    .score-cap {{ font-size: 32px; font-weight: 200; color: #48484a; letter-spacing: -0.02em; padding-bottom: 10px; }}
    .score-trend {{ display: flex; align-items: center; gap: 8px; margin-bottom: 8px; }}
    .trend-arrow {{ font-size: 20px; color: {score_color}; line-height: 1; }}
    .trend-label {{ font-size: 13px; color: #8e8e93; }}
    .score-meta {{ font-size: 12px; color: #8e8e93; }}
    .score-meta b {{ color: #aeaeb2; font-weight: 500; }}

    /* Sections */
    section {{ margin-bottom: 44px; }}
    .sec-head {{
      font-size: 10px;
      font-weight: 600;
      letter-spacing: 0.09em;
      text-transform: uppercase;
      color: #8e8e93;
      margin-bottom: 10px;
    }}
    hr {{ border: none; border-top: 1px solid #38383a; margin-bottom: 0; }}

    /* Module rows */
    .mods {{ list-style: none; }}
    .mod-row {{
      display: flex;
      align-items: center;
      justify-content: space-between;
      padding: 11px 0;
      border-bottom: 1px solid #2c2c2e;
    }}
    .mod-row:last-child {{ border-bottom: none; }}
    .mod-name {{
      font-family: 'SF Mono', 'Fira Code', 'Cascadia Code', ui-monospace, monospace;
      font-size: 12px;
      color: #f5f5f7;
    }}
    .mod-counts {{ display: flex; gap: 20px; }}
    .cnt {{ display: flex; align-items: center; gap: 5px; font-size: 12px; font-variant-numeric: tabular-nums; }}
    .dot {{ width: 5px; height: 5px; border-radius: 50%; }}
    .dot.e {{ background: #ff453a; }}
    .dot.w {{ background: #ff9f0a; }}
    .cnt-n {{ color: #636366; font-weight: 500; }}
    .cnt-n.e {{ color: #ff453a; }}
    .cnt-n.w {{ color: #ff9f0a; }}

    /* Violation rows */
    .viols {{ list-style: none; }}
    .viol-row {{
      display: flex;
      align-items: center;
      gap: 14px;
      padding: 12px 0;
      border-bottom: 1px solid #2c2c2e;
    }}
    .viol-row:last-child {{ border-bottom: none; }}
    .viol-bar {{ width: 2px; height: 34px; border-radius: 1px; flex-shrink: 0; }}
    .viol-bar.error {{ background: #ff453a; }}
    .viol-bar.warning {{ background: #ff9f0a; }}
    .viol-info {{ flex: 1; min-width: 0; }}
    .viol-rule {{
      font-family: 'SF Mono', 'Fira Code', ui-monospace, monospace;
      font-size: 12px;
      font-weight: 500;
      color: #f5f5f7;
      margin-bottom: 3px;
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
    }}
    .viol-file {{
      font-family: 'SF Mono', 'Fira Code', ui-monospace, monospace;
      font-size: 11px;
      color: #8e8e93;
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
    }}
    .sev-tag {{
      font-size: 9px;
      font-weight: 700;
      letter-spacing: 0.07em;
      text-transform: uppercase;
      padding: 3px 7px;
      border-radius: 5px;
      flex-shrink: 0;
    }}
    .sev-tag.error {{ background: rgba(255,69,58,.15); color: #ff453a; }}
    .sev-tag.warning {{ background: rgba(255,159,10,.15); color: #ff9f0a; }}

    /* All-clear state */
    .all-clear {{ display: flex; align-items: center; gap: 8px; padding: 14px 0; font-size: 13px; color: #30d158; }}
    .clr-dot {{ width: 6px; height: 6px; border-radius: 50%; background: #30d158; flex-shrink: 0; }}

    /* Sparkline */
    .chart-wrap {{ padding: 20px 0 8px; }}
    .chart-wrap svg {{ display: block; overflow: visible; }}

    /* Debt projection */
    .proj-card {{ background: #2c2c2e; border-radius: 14px; padding: 22px 26px; }}
    .proj-title {{ font-size: 13px; font-weight: 600; color: #f5f5f7; margin-bottom: 6px; }}
    .proj-body {{ font-size: 13px; color: #8e8e93; margin-bottom: 10px; }}
    .proj-rec {{ font-size: 12px; color: #636366; border-left: 2px solid #48484a; padding-left: 12px; }}

    /* Compliance score */
    .compliance {{ margin-bottom: 16px; }}
    .compliance-num {{ font-size: 48px; font-weight: 200; line-height: 1; font-variant-numeric: tabular-nums; }}
    .compliance-pct {{ font-size: 20px; font-weight: 200; color: #48484a; }}
    .compliance-delta {{ font-size: 16px; margin-left: 8px; }}
    .compliance-delta.up {{ color: #30d158; }}
    .compliance-delta.down {{ color: #ff453a; }}

    /* Rule trends */
    .rule-trend {{ display: flex; align-items: center; gap: 12px; padding: 8px 0; border-bottom: 1px solid #2c2c2e; }}
    .rule-trend:last-child {{ border-bottom: none; }}
    .rule-name {{ font-size: 11px; color: #8e8e93; min-width: 200px; }}
    .rule-count {{ font-size: 12px; color: #f5f5f7; font-variant-numeric: tabular-nums; min-width: 30px; text-align: right; }}

    /* Drift callout */
    .drift-callout {{ background: rgba(243,139,168,.08); border-left: 2px solid #f38ba8; padding: 12px 16px; font-size: 12px; color: #cdd6f4; margin-top: 16px; border-radius: 0 8px 8px 0; }}
    .drift-icon {{ color: #f38ba8; }}

    /* Sprint card */
    .sprint-card {{ background: #2c2c2e; border-radius: 14px; padding: 22px 26px; margin-top: 16px; }}
    .sprint-title {{ font-size: 13px; font-weight: 600; color: #f5f5f7; margin-bottom: 6px; }}
    .sprint-body {{ font-size: 13px; color: #8e8e93; }}

    footer {{
      font-size: 11px;
      color: #48484a;
      text-align: center;
      margin-top: 40px;
      padding-top: 24px;
      border-top: 1px solid #2c2c2e;
    }}
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
      {scan_date}<br>
      {_html_escape(scope_label)} &middot; {files_checked} files
    </div>
  </header>

  <div class="score-hero">
    <div class="score-display">
      <span class="score-num">{score}</span>
      <span class="score-cap">/100</span>
    </div>
    <div class="score-trend">
      <span class="trend-arrow">{arrow}</span>
      <span class="trend-label">{_html_escape(trend_text)}</span>
    </div>
    <p class="score-meta">
      <b>{total}</b> violation(s) &nbsp;&middot;&nbsp; <b>{unique_error_rules}</b> error rule(s) &nbsp;&middot;&nbsp; <b>{unique_warning_rules}</b> warning rule(s)
    </p>
  </div>

  <div class="compliance">
    <div class="score-display">
      <span class="compliance-num" style="color:{compliance_color}">{compliance_str}</span>
      <span class="compliance-pct">%</span>
{compliance_delta_html}
    </div>
    <p class="score-meta">Compliance -- files passing / files checked</p>
  </div>

  <section>
    <p class="sec-head">Modules</p>
    <hr>
    <ul class="mods">
      {module_table_html}
    </ul>
  </section>

  <section>
    <p class="sec-head">Violations</p>
    <hr>
    <ul class="viols">
      {violations_html}
    </ul>
  </section>

{sparkline_section}

{rule_trends_section}

  {worst_drift_html}

  {sprint_html}

  {projection_html}

  <footer>Generated by Thymus &nbsp;&middot;&nbsp; /thymus:scan for terminal view &nbsp;&middot;&nbsp; /thymus:baseline to re-initialize</footer>
</body>
</html>"""

    with open(report_file, "w") as f:
        f.write(html)

    debug_log(f"Report written: {report_file}")

    # Open in browser unless THYMUS_NO_OPEN is set
    if not os.environ.get("THYMUS_NO_OPEN"):
        try:
            subprocess.run(["open", report_file],
                           capture_output=True, timeout=5)
        except Exception:
            try:
                subprocess.run(["xdg-open", report_file],
                               capture_output=True, timeout=5)
            except Exception:
                print(f"Thymus: Open {report_file} in your browser",
                      file=sys.stderr)

    # Output summary JSON
    summary = {
        "score": score,
        "compliance": compliance,
        "arrow": arrow,
        "trend_text": trend_text,
        "stats": {
            "total": total,
            "errors": errors,
            "warnings": warnings,
            "files_checked": files_checked,
        },
        "report_path": report_file,
    }
    json.dump(summary, sys.stdout)
    print()


if __name__ == "__main__":
    main()
