#!/usr/bin/env bash
set -euo pipefail

# check-version.sh - Notify user if new version available
# Called by main CLI commands, runs max once per 24h
# Non-blocking: callers run this in background (&)

CURRENT_VERSION="0.1.0"
CACHE_FILE="/tmp/thymus-version-check"

# Exit silently if checked recently (within 24h)
if [ -f "$CACHE_FILE" ]; then
  LAST_CHECK=$(cat "$CACHE_FILE" 2>/dev/null || echo "0")
  NOW=$(date +%s)
  AGE=$((NOW - LAST_CHECK))
  [ "$AGE" -lt 86400 ] && exit 0
fi

# Quick GitHub API check (timeout 2s)
LATEST=$(curl -s --max-time 2 \
  "https://api.github.com/repos/dhaliwalg/thymus/releases/latest" \
  | grep '"tag_name"' \
  | sed 's/.*"tag_name": "v\?\([^"]*\)".*/\1/' 2>/dev/null || echo "")

# Update timestamp regardless of result
date +%s > "$CACHE_FILE"

# Compare versions
if [ -n "$LATEST" ] && [ "$LATEST" != "$CURRENT_VERSION" ]; then
  echo "thymus: New version available: $LATEST (current: $CURRENT_VERSION)" >&2
  echo "thymus: Update: git pull in plugin directory or re-install from marketplace" >&2
fi
