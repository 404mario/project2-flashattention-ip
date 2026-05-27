# FlashAttention IP Bonus Branch: AXI4-Stream Interface

Branch: `codex-bonus-axi-stream`

This branch extends the stable bonus branch `codex-bonus-3-4-5-9-stable` with Bonus #8: an AXI4-Stream data interface. The original AXI4-Lite + AXI master/DMA top remains available as `flash_attn_top`; the stream version is provided as an additional wrapper, not as a replacement.

## Added Module

| File | Purpose |
|---|---|
| `rtl/top/flash_attn_axis_top.sv` | AXI4-Stream wrapper around `flash_core`. |
| `tb/sv/tb_flash_attn_axis_top_smoke.sv` | Stream-interface smoke testbench. |
| `sim/run_bonus_axis_stream_smoke.sh` | Compile, simulate, and check the stream wrapper output. |

## Interface Shape

The stream wrapper uses simple element-wide AXI4-Stream channels:

| Channel | Direction | Payload | Packet rule |
|---|---|---|---|
| `s_axis_q_*` | input | one Q element per beat | `TLAST` at end of each Q row |
| `s_axis_kv_*` | input | K tile elements followed by V tile elements | `TLAST` at end of the V tile |
| `m_axis_o_*` | output | one O element per beat | `TLAST` at end of each O row |

The wrapper caches only the current Q row, current K/V tile, and current O row. It does not store a full score matrix or probability matrix.

## Stream Ordering Contract

The stream producer must provide Q rows and K/V tiles in the order requested internally by `flash_core`. For the smoke configuration `S=8,D=8,BK=4,BQ=4`, the K/V tile sequence is:

```text
tile_start = 0
tile_start = 0
tile_start = 4
```

Each K/V tile packet streams all K elements row-major, then all V elements row-major.

## Verification

Run:

```bash
bash ./sim/run_bonus_axis_stream_smoke.sh
```

Local result on 2026-05-20:

| Case | Shape | Result | Wait cycles | FP32 MAE | FP32 MaxE |
|---|---:|---|---:|---:|---:|
| AXI4-Stream smoke | S=8,D=8,BK=4,BQ=4 | PASS | 563 | 0.001770 | 0.003906 |

The test also checks:

- Q stream row `TLAST`.
- K/V stream tile `TLAST`.
- O stream row `TLAST`.
- Causal row-0 corner: `O[0] == V[0]`.
- Full output against the RTL fixed-point mirror via `model/check_top_e2e_output.py`.

## Scope

This is a bonus interface wrapper. It does not replace the baseline DMA implementation and does not change the required baseline branch. For backend/PPA, synthesize the baseline separately, and optionally synthesize this stream wrapper as an additional bonus configuration if time permits.
