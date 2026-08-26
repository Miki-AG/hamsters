---
description: pstack per-role model choices for Antigravity (overrides skill defaults)
alwaysApply: true
---
# pstack model configuration for Antigravity
# Model tiers available:
# - pro: High reasoning, complex algorithms, subtle architecture, adversarial critique, deep judgment.
# - flash: Fast mechanical edits, exploration, documentation sweeps, worker tasks.
# - flash_lite: Ultra-fast simple lookups.
# - inherit: Inherits parent chat model.

feature, refactoring: flash
bug-fix: pro
perf-issue: pro
hillclimb: pro
judgment and prose: pro
hardest tasks: pro
how explorer: flash
how explainer: pro
how critics: pro, flash, inherit
why investigators: flash
why synthesizer: pro
reflect tooling: pro
reflect judgment, divergent, synthesizer: pro
arena runners: pro, flash, inherit
arena cross-judge pool: pro, flash, inherit
swarm workers: flash
architect runners: pro, flash, inherit
interrogate reviewers: pro, flash, inherit
