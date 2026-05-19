---
  name: fullsize-smoke-debug
  description: Run and debug full-size S=256 D=64 BK=16 top-level E2E smoke in WSL after small E2E passes.
  disable-model-invocation: true
  ---

  # Full-size Smoke Debug Skill for WSL

  Use this skill only after `/top-e2e-bringup` passes.

  ## Goal

  Run full-size top E2E smoke:

  - S=256
  - D=64
  - BK=16
  - causal baseline
  - signed Q8.8 external Q/K/V/O

  The goal is functional completion first, not precision.

  ## Known context

  Core-only full-size smoke previously passed:

  - S=256
  - D=64
  - BK=16
  - cycles=4404224
  - q_requests=256
  - kv_requests=4096
  - output_rows=256

  ## WSL policy

  `sim/run_top_e2e_smoke.sh` already exists and runs both small and full-size smoke.

  Always use Bash. Never run `.ps1` directly in WSL.

  If you need a full-size-only run, create `sim/run_top_e2e_fullsize.sh` by extracting the full-size block from `run_top_e2e_smoke.sh`. Do
   not invent compile flags.

  ## Full-size run policy

  Full-size Icarus simulation can be slow.

  Do not repeatedly rerun full-size without narrowing the issue.

  Capture logs under `sim/logs/`:

  ```bash
  mkdir -p sim/logs
  bash ./sim/run_top_e2e_smoke.sh 2>&1 | tee sim/logs/top_e2e_fullsize_$(date +%Y%m%d_%H%M).log

  If full-size hangs

  Debug in this exact priority order:

  1. Testbench AXI read burst timing.
  2. Testbench AXI write burst timing.
  3. DMA beat_idx_q to element index expansion.
  4. Q memory element ordering.
  5. K memory element ordering.
  6. V memory element ordering.
  7. O writeback address and lane ordering.
  8. top flat bus pack/unpack.
  9. core q_req_valid/q_req_ready.
  10. core kv_req_valid/kv_req_ready.
  11. core q_data_valid/q_data_ready.
  12. core kv_data_valid/kv_data_ready.
  13. core o_valid/o_ready.
  14. STATUS BUSY/DONE/CYCLES logic.

  If output is wrong

  Compare in this order:

  1. row 0 lane 0
  2. row 0 first 4 lanes
  3. full row 0
  4. row 1
  5. last row
  6. all rows

  Check signed Q8.8 interpretation before changing math.

  Required final report

  End with:

  - full-size command used
  - PASS/FAIL
  - timeout or completion
  - cycle count if available
  - q request count if available
  - kv request count if available
  - output row count if available
  - first failing row/lane if output mismatch
  - exact suspected module if not fixed
  - next step:
    - if full-size PASS: call /golden-error-check
    - if full-size FAIL: keep debugging here