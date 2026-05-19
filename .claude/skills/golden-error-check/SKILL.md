 # Golden Error Check Skill for WSL

  Use this skill only after `/fullsize-smoke-debug` passes.

  ## Goal

  Measure MAE and MaxE of RTL output against a Python FP32 golden reference.

  Correctness targets:

  - MAE <= 0.03
  - MaxE <= 0.10

  ## Hard constraints

  - External Q/K/V/O are signed Q8.8 16-bit. Do not change this.
  - Python golden reference may use FP32 or Q16.16 internally — that is allowed.
  - Do not modify RTL in this phase. Only measure.

  ## Steps

  1. Locate or create a Python golden script under `tb/python/` or `scripts/`.
  2. Run it with S=256, D=64, BK=16, causal=1, same scale as RTL.
  3. Extract RTL output O values from simulation log or hex dump.
  4. Compare element-wise and compute MAE and MaxE.

  ## Script policy

  Use Bash in WSL. If a Python script already exists, run it directly:

  ```bash
  python3 tb/python/golden_check.py

  If no golden script exists, create one at tb/python/golden_check.py. Inspect existing testbench files first to understand Q8.8 format
  and memory layout before writing anything.

  Required final report

  End with:

  - script used
  - MAE value
  - MaxE value
  - PASS or FAIL against target
  - next step:
    - if PASS (MAE <= 0.03 and MaxE <= 0.10): integration baseline is done, call /rtl-change-review
    - if FAIL: call /precision-fix