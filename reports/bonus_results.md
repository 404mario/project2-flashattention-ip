# Unified Bonus Results

Branch: `codex-bonus-integrated-ppa-skeleton`

This file starts the evidence log for the unified bonus branch rebuilt on top of the PPA-passing baseline. At this skeleton stage, no bonus item is claimed yet; results below record only the inherited baseline reference and the required acceptance thresholds.

## Baseline Reference

| Case | Shape | Cycles | RD_BYTES | WR_BYTES | FP32 MAE | FP32 MaxE |
|---|---:|---:|---:|---:|---:|---:|
| AXI-Lite + AXI master/DMA top E2E | S=256,D=64,BK=16,BQ=16 | 269808 | 589824 | 32768 | 0.000097 | 0.054688 |

Acceptance thresholds:

| Metric | Requirement |
|---|---:|
| Mean absolute error | <= 0.03 |
| Max absolute error | <= 0.10 |
| Baseline cycles | < 300000 |
| Baseline equivalent gates | <= 2000000 |

## Pending Bonus Evidence

Each bonus item must add its command, shape, cycles, RD_BYTES/WR_BYTES if applicable, and FP32 error result here after being ported to this branch.

