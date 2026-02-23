---
name: update
description: >-
  Update Thymus to the latest version from GitHub.
  Use when the user wants to upgrade or update the Thymus plugin.
---

# Thymus Update

Update Thymus to the latest version. Follow these steps exactly:

## Step 1: Pull latest from GitHub

Tell the user: "Pulling latest Thymus from GitHub..."

```bash
MARKETPLACE_DIR="$HOME/.claude/plugins/marketplaces/thymus"
if [ ! -d "$MARKETPLACE_DIR/.git" ]; then
  echo "ERROR: Thymus marketplace directory not found at $MARKETPLACE_DIR"
  exit 1
fi
git -C "$MARKETPLACE_DIR" pull origin main
```

If the directory isn't found, tell the user Thymus doesn't appear to be installed via the marketplace.

If the output says "Already up to date", tell the user they're on the latest version. Stop here.

## Step 2: Clear the plugin cache

```bash
rm -rf "$HOME/.claude/plugins/cache/thymus"
```

## Step 3: Tell the user

Briefly summarize what changed, then: "**Restart Claude Code** for the update to take effect. Your project's invariants and history are untouched."
