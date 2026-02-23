---
name: update
description: >-
  Update Thymus to the latest version from GitHub.
  Use when the user wants to upgrade or update the Thymus plugin.
---

# Thymus Update

Update Thymus to the latest version. Follow these steps exactly:

## Step 1: Find the marketplace directory

```bash
MARKETPLACE_DIR="$HOME/.claude/plugins/marketplaces/thymus"
if [ ! -d "$MARKETPLACE_DIR/.git" ]; then
  echo "ERROR: Thymus marketplace directory not found at $MARKETPLACE_DIR"
  exit 1
fi
echo "Found marketplace at: $MARKETPLACE_DIR"
```

## Step 2: Pull latest from GitHub

```bash
git -C "$HOME/.claude/plugins/marketplaces/thymus" pull origin main
```

Report the output to the user. If it says "Already up to date", tell them they're on the latest version and stop here.

## Step 3: Clear the plugin cache

```bash
rm -rf "$HOME/.claude/plugins/cache/thymus"
```

## Step 4: Tell the user

Report:
- What changed (from the git pull output)
- That the cache has been cleared
- **They need to restart Claude Code** (start a new session) for changes to take effect
