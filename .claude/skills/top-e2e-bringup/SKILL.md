 ---
  name: top-e2e-bringup
  description: Bring up FlashAttention top-level compile and small E2E smoke in WSL before full-size or precision work.
  disable-model-invocation: true
  ---

  # Top E2E Bring-up Skill for WSL

  Use this skill first.

  ## Goal

  Confirm that the top-level RTL still compiles and the small top E2E smoke still passes.

  Do not run full-size first.

  ## Hard constraints

  - External Q/K/V/O remain signed Q8.8 16-bit.
  - Do not change baseline external format to Q16.16.
  - Preserve Icarus compatibility.
  - Preserve packed flat bus paths between DMA/top/core unless replacing with an equally tested Icarus-safe path.
  - Do not optimize precision or performance in this phase.

  ## WSL setup checks

  Run from repository root:

  ```bash
  pwd
  git status
  git branch --show-current
  git rev-parse --short HEAD
  which iverilog
  which vvp
  which python3

  If the repository path starts with /mnt/c/, warn that WSL simulation may be slow and suggest moving the repo to the Linux filesystem,
  such as ~/project2-flashattention-ip.

  Script policy

  Always use Bash scripts in WSL. Never run .ps1 directly.

  These files already exist (created 2026-05-19):

  - sim/run_top_compile.sh
  - sim/run_top_e2e_smoke.sh

  If a Bash script is missing for a future step, inspect the corresponding .ps1 and create a .sh equivalent. Do not guess compile flags.

  Required commands

  bash ./sim/run_top_compile.sh
  bash ./sim/run_top_e2e_smoke.sh

  Expected known result

  Previous known small top E2E:

  - S=8
  - D=8
  - BK=4
  - bit-exact PASS
  - cycles=1384

  If compile fails

  Inspect in this order:

  1. rtl/top/*
  2. rtl/axi/*
  3. rtl/core/* flat bus boundary
  4. tb/sv/tb_flash_attn_top_e2e_smoke.sv
  5. sim/run_top_compile.sh

  Fix the smallest compile issue first.

  If small E2E fails

  Inspect in this order:

  1. AXI-Lite register write/read sequence.
  2. CTRL.START pulse.
  3. STATUS.BUSY/DONE/ERROR behavior.
  4. Q/K/V/O base addresses.
  5. STRIDE_BYTES, expected default D * 2.
  6. DMA read ordering.
  7. DMA write ordering.
  8. flat bus pack/unpack between DMA/top/core.
  9. core handshake stability.

  Required final report

  End with:

  - commands run
  - PASS/FAIL
  - cycle count if available
  - changed files
  - next step:
    - if small E2E PASS: call /fullsize-smoke-debug
    - if small E2E FAIL: state exact failing module or handshake
  