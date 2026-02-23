---
name: update
description: >-
  Update Thymus to the latest version from GitHub.
  Use when the user wants to upgrade or update the Thymus plugin.
---

# Thymus Update

Update Thymus to the latest version. Follow these steps exactly:

## Step 1: Tell the user what's about to happen

Before running any commands, explain:

"Updating Thymus — I'll pull the latest code from GitHub and clear the plugin cache. This won't affect your project files or invariants."

## Step 2: Find the marketplace directory

```bash
MARKETPLACE_DIR="$HOME/.claude/plugins/marketplaces/thymus"
if [ ! -d "$MARKETPLACE_DIR/.git" ]; then
  echo "ERROR: Thymus marketplace directory not found at $MARKETPLACE_DIR"
  exit 1
fi
echo "Found marketplace at: $MARKETPLACE_DIR"
```

If the directory isn't found, tell the user: "Thymus doesn't appear to be installed via the marketplace. If you installed it manually, `cd` into the plugin directory and run `git pull` yourself."

## Step 3: Pull latest from GitHub

```bash
git -C "$HOME/.claude/plugins/marketplaces/thymus" pull origin main
```

If the output says "Already up to date", tell the user: "You're already on the latest version of Thymus. No changes needed." Stop here.

If it pulled changes, tell the user what was updated (summarize the file list briefly).

## Step 4: Clear the plugin cache

```bash
rm -rf "$HOME/.claude/plugins/cache/thymus"
```

Tell the user: "Plugin cache cleared."

## Step 5: Wrap up

Tell the user:

"Thymus has been updated. **Start a new session** for the changes to take effect — the current session is still running the old version. Your project's invariants and history are untouched."
