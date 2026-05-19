---
name: rtl-change-review
description: Review RTL/TB/model changes in WSL before committing or moving to the next phase.
disable-model-invocation: true
---

# RTL Change Review Skill

Use before committing or before moving to the next skill.

## Required commands

```bash
git status
git diff --stat
git diff
```

## Review checklist

Answer these:

1. What files changed?
2. Why was each file changed?
3. Does this preserve external signed Q8.8 Q/K/V/O?
4. Does this preserve Icarus compatibility?
5. Does this preserve AXI-Lite START/BUSY/DONE/ERROR?
6. Does this preserve base-address and stride behavior?
7. Does this preserve DMA element ordering?
8. Does this preserve core valid/ready stability?
9. Did small top E2E pass?
10. Did full-size top E2E pass or fail with a narrowed cause?
11. Was `docs/integration_adjustment_plan_2026-05-19.md` updated if results changed?

## Commit policy

Do not commit unless the user asks.

If asked to commit, use a precise message such as:

- `test: stabilize top e2e smoke`
- `fix: correct dma element indexing`
- `fix: preserve flat bus ordering in top`
- `docs: update integration smoke results`
