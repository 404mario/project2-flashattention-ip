# FlashAttention IP Unified Bonus Version

Branch: `codex-bonus-integrated-ppa-skeleton`

This branch is the clean unified bonus skeleton based on the PPA-passing baseline branch `codex-baseline-ppa-fix` at commit `02b8334`.

The final bonus submission should use one integrated bonus branch. Individual bonus experiments can remain as development branches, but their final, verified RTL and tests must be ported here so the bonus version is evaluated as one independent project.

## Baseline Inherited by This Branch

This branch starts from the baseline that passed simulation and Genus checks:

| Metric | Result |
|---|---:|
| Full-size cycles | 269808 |
| RD_BYTES | 589824 |
| WR_BYTES | 32768 |
| FP32 MAE | 0.000097 |
| FP32 MaxE | 0.054688 |
| Genus clock | 10 ns |
| Genus timing | MET, slack 0 ps |
| Total cell area | 9176561.366 |
| NAND2 equivalent gates | 1913697 |

Bonus changes must not modify the required baseline behavior when bonus controls are left at their default disabled values.

## Non-Regression Rules

- Keep the baseline AXI4-Lite + AXI master/DMA path intact.
- Keep default configuration equivalent to the passing baseline: single batch, single head, S=256, D=64, Q8.8, causal enabled.
- Do not lower the baseline synthesis target below 10 ns unless a separate bonus-only report clearly marks the tradeoff.
- Run the baseline-shaped top E2E vector test after every bonus integration.
- If a bonus adds datapath logic, rerun Genus on the integrated bonus branch and compare timing/area against the baseline report.

## Planned Unified Bonus Claims

| # | Bonus item | Integration status in this branch |
|---:|---|---|
| 3 | Longer/configurable sequence | Planned port from old integrated branch. |
| 4 | Padding mask | Planned port from old integrated branch. |
| 5 | Other fixed-point formats | Planned port from old integrated branch. |
| 6 | Dropout training mode | Planned port from old integrated branch. |
| 7 | Lower precision INT8/FP8 exploration | Planned; low-precision work must land here before final submission. |
| 8 | AXI4-Stream interface | Planned port from old integrated branch. |
| 9 | DMA/task queue | Planned port from old integrated branch. |

Do not claim an item in the final report until the corresponding full-size or item-specific evidence has been rerun on this branch.

## Verification Entry Points

Baseline sanity inherited by this branch:

```bash
./sim/run_top_compile.sh
./sim/run_top_e2e_smoke.sh
RUN_VECTORS=1 ./sim/run_top_e2e_smoke.sh
```

Unified bonus regression entry point:

```bash
bash ./sim/run_bonus_all.sh
```

At this skeleton stage, `run_bonus_all.sh` only runs the inherited baseline checks and records that bonus feature ports are still pending.

