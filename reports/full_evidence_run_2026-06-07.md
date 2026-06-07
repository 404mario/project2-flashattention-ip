# Full Evidence Run 2026-06-07

Branch: `codex-bonus-integrated-static-scale-fmax`
Commit under test: current branch head, with full-size evidence originally recorded before
the later simulation-script portability fix.

This file records the complete simulation evidence set for the current integrated bonus
branch. Genus synthesis evidence is intentionally separate.

## Core Regression Evidence

| Command | Scope | Result |
|---|---|---|
| `./sim/run_top_compile.sh` | RTL compile smoke | PASS |
| `./sim/run_bonus_all.sh` | Integrated quick bonus suite, rerun after script portability fix | PASS |
| `RUN_FULL=1 ./sim/run_top_e2e_smoke.sh` | Default Q8.8 full-size generated tensors | PASS |
| `RUN_VECTORS=1 ./sim/run_top_e2e_smoke.sh` | Default Q8.8 full-size supplied random vectors | PASS |
| `RUN_FULL=1 ./sim/run_bonus_bf16_smoke.sh` | BF16 I/O full-size | PASS |

## Full-Size Results

| Case | Shape | Cycles | RD_BYTES | WR_BYTES | RTL MAE | RTL MaxE | FP32 MAE | FP32 MaxE | Note |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---|
| Q8.8 default | S=256,D=64,BK=16,BQ=16 | 233312 | 589824 | 32768 | 0.000000 | 0.000000 | 0.000015 | 0.003906 | `RUN_FULL=1` |
| Q8.8 random vectors | S=256,D=64,BK=16,BQ=16 | 233312 | 589824 | 32768 | 0.000000 | 0.000000 | 0.000097 | 0.054688 | `RUN_VECTORS=1` |
| BF16 I/O | S=256,D=64,BK=16,BQ=16 | 233312 | 589824 | 32768 | 0.000000 | 0.000000 | 0.000015 | 0.003906 | external tensor/storage mode |
| INT8/Q4.4 | S=256,D=64,BK=16,BQ=16 | 196320 | 294912 | 16384 | 0.000000 | 0.000000 | 0.005238 | 0.187500 | lossy low-precision bandwidth trade-off |
| FP8/E4M3 | S=256,D=64,BK=16,BQ=16 | 196320 | 294912 | 16384 | 0.000000 | 0.000000 | 0.000043 | 0.011719 | half external tensor bytes |

## Low-Precision Full-Size Commands

The full-size low-precision cases were run as single direct VVP cases to avoid the Windows
PowerShell/Git Bash pipeline timeout observed when the whole low-precision script was run as
one long command.

INT8/Q4.4 full-size:

```powershell
& 'D:\iverilog\bin\vvp.exe' `
  sim_build\tb_flash_attn_top_e2e_lowprecision_s256_d64.vvp `
  +OUT_HEX=sim_build\tb_flash_attn_top_e2e_lowprecision_s256_d64_direct_o.hex
```

Simulator PASS line:

```text
tb_flash_attn_top_e2e_smoke PASS S=256 D=64 BK=16 BQ=16 bitexact=0 cycles=196320 wait_cycles=174512 rd_bytes=294912 wr_bytes=16384
```

Checker:

```text
RTL output vs RTL fixed-point mirror:
  MAE          = 0.000000
  MaxE         = 0.000000
RTL output vs FP32 softmax golden:
  MAE          = 0.005238
  MaxE         = 0.187500
```

FP8/E4M3 full-size:

```powershell
& 'D:\iverilog\bin\vvp.exe' `
  sim_build\tb_flash_attn_top_e2e_fp8_s256_d64_direct.vvp `
  +OUT_HEX=sim_build\tb_flash_attn_top_e2e_fp8_s256_d64_direct_o.hex
```

Simulator PASS line:

```text
tb_flash_attn_top_e2e_smoke PASS S=256 D=64 BK=16 BQ=16 bitexact=0 cycles=196320 wait_cycles=174512 rd_bytes=294912 wr_bytes=16384
```

Checker:

```text
RTL output vs RTL fixed-point mirror:
  MAE          = 0.000000
  MaxE         = 0.000000
RTL output vs FP32 softmax golden:
  MAE          = 0.000043
  MaxE         = 0.011719
```

## Acceptance Notes

Default Q8.8, random-vector Q8.8, BF16 I/O, and FP8/E4M3 satisfy the handout FP32 error
threshold `MAE <= 0.03` and `MaxE <= 0.10`.

INT8/Q4.4 is kept as a lossy low-precision exploration: it is exact against the RTL
fixed-point mirror and halves external tensor traffic, but its FP32 `MaxE=0.187500` exceeds
the baseline-quality threshold. It should be described as a bandwidth/precision trade-off,
not as a strict replacement for Q8.8.

All full-size cases listed above meet the latency target `<300000 cycles`.
