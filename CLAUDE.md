# CLAUDE.md

This repository is `404mario/project2-flashattention-ip`.

Current task: finish Project 2 FlashAttention baseline top-level integration on branch `codex-top-e2e-integration-fixes`.

Hard constraints:

- Baseline external Q/K/V/O format is signed Q8.8 16-bit.
- Do not change AXI/DMA/top external memory payloads to Q16.16.
- Q16.16 or wider formats are allowed only inside softmax / reciprocal / normalization / Python golden references.
- Baseline shape is single batch, single head, S=256, D=64.
- Must use FlashAttention-style tiling and online softmax.
- Must not store the full S×S attention matrix.
- AXI4-Lite must support START/BUSY/DONE/ERROR, base address registers, stride, scale, neg_large, and CYCLES.
- AXI Master/DMA must read Q/K/V and write O.
- Final correctness target: MAE <= 0.03 and MaxE <= 0.10 against FP32 golden.

WSL workflow:

1. Use `/top-e2e-bringup` first.
2. Use `/fullsize-smoke-debug` only after small top E2E passes.
3. Use `/golden-error-check` only after full-size top smoke passes.
4. Use `/precision-fix` only after MAE/MaxE are measured.
5. Use `/rtl-change-review` before committing or moving to the next phase.

Script policy (WSL/Linux):

- Always use Bash `.sh` scripts. Never use `.ps1` scripts directly in WSL.
- If only `.ps1` scripts exist for a step, inspect them and create equivalent `.sh` scripts before running.
- Do not guess compile flags — always translate from the existing `.ps1`.

Current script status (update this when new `.sh` files are created):

| Script | Status | Notes |
|---|---|---|
| `sim/run_top_compile.sh` | EXISTS | Translated from `run_top_compile.ps1` |
| `sim/run_top_e2e_smoke.sh` | EXISTS | Runs small (S=8,D=8) then full-size (S=256,D=64) smoke |
| `sim/run_member_b_week1.sh` | MISSING | Needs translation from `run_member_b_week1.ps1` |
| `sim/run_member_b_fullsize.sh` | MISSING | Needs translation from `run_member_b_fullsize.ps1` |

Suggested startup prompt for new sessions:

```
WSL/Linux. Read CLAUDE.md.
sim/run_top_compile.sh and sim/run_top_e2e_smoke.sh already exist — use bash to run them directly.
sim/run_member_b_week1.sh and sim/run_member_b_fullsize.sh still need to be created from their .ps1 counterparts.
Current status: [paste last PASS/FAIL result and cycle count here]
Next step: /top-e2e-bringup
```

Do not optimize performance or precision before baseline top-level E2E is reproducible.
