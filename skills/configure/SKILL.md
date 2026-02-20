---
name: configure
description: >-
  Configure AIS thresholds, ignored paths, and rule settings.
  Use when the user wants to adjust severity levels, exclude directories,
  or change how AIS behaves in this project.
disable-model-invocation: true
argument-hint: "[setting] [value]"
---

# AIS Configure

AIS has not been initialized yet. Run `/ais:baseline` first.

Once initialized, you can configure AIS behavior in `.ais/config.yml`:

  /ais:configure ignore node_modules dist .next
  /ais:configure severity boundary error
  /ais:configure threshold health-warning 70

Configuration is stored in `.ais/config.yml` and takes effect
on the next hook invocation.
