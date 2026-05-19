---
  name: precision-fix
  description: Fix RTL precision after MAE/MaxE measurements exceed targets in WSL.
  disable-model-invocation: true
  ---

  # Precision Fix Skill for WSL

  Use this skill only after `/golden-error-check` reports MAE or MaxE out of target.

  Targets:

  - MAE <= 0.03
  - MaxE <= 0.10

  ## Hard constraints

  - Do not change external Q/K/V/O format from signed Q8.8 16-bit.
  - Q16.16 or wider is allowed only inside: softmax, reciprocal, normalization, Python golden references.
  - Do not change AXI/DMA/top external memory payloads.
  - Preserve Icarus compatibility.
  - Do not improve performance — only fix precision.

  ## Investigation order

  Check in this order before changing any RTL:

  1. Softmax accumulator width — wide enough to avoid overflow?
  2. Reciprocal approximation — accurate enough for scale used?
  3. Normalizer divide — is Q16.16 or wider used internally?
  4. Value accumulator — rounding or truncation loss?
  5. quantize_saturate — output clipping correct for Q8.8?
  6. Scale factor (SCALE_Q8_8=32 for S=256, D=64) — applied correctly?

  ## After each fix

  1. Run `/rtl-change-review` to check the diff.
  2. Re-run small E2E smoke to confirm no regression:
     ```bash
     bash ./sim/run_top_e2e_smoke.sh
  3. Re-run /golden-error-check to measure updated MAE/MaxE.

  Required final report

  End with:

  - files changed
  - what was fixed
  - new MAE value
  - new MaxE value
  - PASS or FAIL against target
  - next step:
    - if PASS: call /rtl-change-review then commit
    - if FAIL: continue debugging in this skill