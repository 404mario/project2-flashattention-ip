# Unified Bonus Completion Matrix

Branch: `codex-bonus-integrated-ppa-skeleton`

This branch is intentionally rebuilt from the PPA-passing baseline instead of directly editing the older `codex-bonus-integrated` branch. The older branch remains useful as a source of already-developed bonus patches, but every claimed item must be ported and rerun here before final submission.

## Current Status

| # | Bonus item | Status | Evidence required before final claim |
|---:|---|---|---|
| 1 | BF16/FP16 attention | Not claimed | Separate RTL datapath and error/performance comparison. |
| 2 | Multi-head support | Not claimed | Head dimension registers/addressing and full E2E verification. |
| 3 | Longer/configurable sequence | Pending port | S=512 or configurable-S simulation evidence without storing SxS matrices. |
| 4 | Padding mask | Pending port | AXI-Lite valid-length programming plus causal corner cases. |
| 5 | Other fixed-point formats | Pending port | Q6.10/Q4.12 full-size error comparison. |
| 6 | Dropout training mode | Pending port | Deterministic seed, mask evidence, and dropout golden comparison. |
| 7 | INT8/FP8 lower precision | Pending design | Low-precision datapath or block scaling evidence and error comparison. |
| 8 | AXI4-Stream interface | Pending port | Stream wrapper smoke and full-size random-vector verification. |
| 9 | DMA/task queue | Pending port | Multi-task START/DONE flow and per-task output verification. |
| 10 | Other optimization | Not claimed | Only claim if a measured performance/power/area improvement is documented. |

## Baseline Non-Regression Evidence

Inherited baseline evidence from `codex-baseline-ppa-fix`:

| Check | Result |
|---|---:|
| S=256,D=64 cycles | 269808 |
| FP32 MAE | 0.000097 |
| FP32 MaxE | 0.054688 |
| Genus timing | 10 ns MET |
| Gate equivalent | 1913697 |

The integrated bonus branch must keep this path available and rerunnable.

