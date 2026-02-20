---
name: learn
description: >-
  Teach AIS a new architectural invariant in natural language.
  Use when the user says "always", "never", "must", "should" about
  code structure. Example: /ais:learn all DB queries go through repositories
disable-model-invocation: true
argument-hint: "<natural language rule>"
---

# AIS Learn

AIS has not been initialized yet. Run `/ais:baseline` first to create
the baseline before teaching new invariants.

Once initialized, use this skill to add invariants:

  /ais:learn all database queries must go through the repository layer
  /ais:learn React components must not import from other components directly

AIS will translate your natural language rule into a formal invariant
in `.ais/invariants.yml` and confirm before saving.
