# Verification Plan

## Scope

This plan covers the Member A delivery:

- `rtl/axi/axi_lite_regs.sv`
- `rtl/axi/axi_master_read.sv`
- `rtl/axi/axi_master_write.sv`
- `rtl/axi/dma_controller.sv`
- `rtl/top/flash_attn_top.sv`

The goals are:

1. Register programming is correct and stable.
2. AXI burst generation is protocol-clean for the supported baseline flows.
3. DMA address generation matches the documented memory layout.
4. Top-level `BUSY`, `DONE`, `ERROR`, `CYCLES`, and `IRQ` semantics are correct.
5. End-to-end execution works with the existing Member B core interface.

## Test Levels

### 1. `axi_lite_regs` Unit Tests

#### Register Read / Write

- Write and read back `CFG`, `Q/K/V/O_BASE`, `STRIDE_BYTES`, `NEG_LARGE`, `SCALE`.
- Check partial-byte writes through `WSTRB`.
- Confirm read-only `STATUS` / `CYCLES` are not overwritten.

#### Pulse Behavior

- Writing `CTRL.START=1` generates a one-cycle `start_pulse`.
- Writing `CTRL.SOFT_RESET=1` generates a one-cycle `soft_reset`.
- `CTRL.IRQ_EN` remains sticky until changed by software.

#### Sticky Status Behavior

- `done` input sets sticky `STATUS.DONE`.
- `error` input sets sticky `STATUS.ERROR`.
- Writing `1` to `STATUS.DONE` clears only the done bit.
- Writing `1` to `STATUS.ERROR` clears only the error bit.
- Starting a new run clears stale `DONE` / `ERROR` state.

#### IRQ Behavior

- `IRQ_EN=0`: no interrupt after completion.
- `IRQ_EN=1`: `irq` asserts when sticky done is set.
- Clearing `STATUS.DONE` clears `irq`.

### 2. `axi_master_read` Unit Tests

#### Nominal Row Read

- Issue a 128-byte request.
- Check one AXI `AR` burst is emitted with correct `addr`, `arlen`, `arsize`, `arburst`.
- Return 16 beats and confirm `data_valid/data/data_last` mirror the AXI `R` channel.

#### Backpressure

- Hold `data_ready=0` for several cycles while `RVALID=1`.
- Confirm `m_axi_rready` deasserts and no beat is dropped.

#### Error Response

- Inject non-OKAY `RRESP` on one beat.
- Confirm the module sets `error`.

### 3. `axi_master_write` Unit Tests

#### Nominal Row Write

- Issue a 128-byte request.
- Check one AXI `AW` burst is emitted with correct `addr`, `awlen`, `awsize`, `awburst`.
- Drive 16 data beats with `data_last` on the final beat.
- Confirm completion waits for the AXI `B` response.

#### Backpressure

- Hold `m_axi_wready=0` intermittently.
- Confirm `data_ready` deasserts and no beat is skipped or duplicated.

#### Error Response

- Inject non-OKAY `BRESP`.
- Confirm the module sets `error`.

### 4. `dma_controller` Unit Tests

#### Q Row Fetch

- Drive `q_req_valid/q_req_row` from a core stub.
- Check DMA emits one read request to:

      q_base + q_req_row * stride_bytes

- Return 16 beats and verify the unpacked `q_data[d]` matches the input memory image.
- Confirm `q_data_valid` remains asserted until `q_data_ready`.

#### K/V Tile Fetch

- Drive `kv_req_valid/kv_req_start/kv_req_len`.
- Confirm DMA emits **row-by-row** reads for K and then V:

      k_base + (kv_req_start + r) * stride_bytes
      v_base + (kv_req_start + r) * stride_bytes

- Check all valid tile rows are unpacked correctly.
- Check rows `r >= kv_req_len` are zero-filled.
- Repeat with `stride_bytes = 128` and with `stride_bytes > 128`.

#### O Row Writeback

- Drive `o_valid/o_row/o_data`.
- Confirm DMA captures one row, issues one write request to:

      o_base + o_row * stride_bytes

- Verify the 16 outgoing data beats pack `o_data[d]` in row-major order.
- Confirm DMA does not return idle until the write response completes.

#### Error / Robustness

- Drive illegal `kv_req_len = 0` and confirm `error` sets.
- Confirm `start` clears stale DMA error state.

### 5. `flash_attn_top` Integration Tests

#### Control-Plane Smoke Test

- Program all configuration registers through AXI4-Lite.
- Start one run.
- Confirm `STATUS.BUSY` goes high, `CYCLES` increments, and `STATUS.DONE` sets after completion.

#### IRQ Test

- With `IRQ_EN=1`, verify `irq` asserts after end-to-end completion.
- With `IRQ_EN=0`, verify no interrupt is observed.

#### End-To-End With Core Stub

Use a lightweight stub in place of `flash_core` to force a known sequence:

1. Request one Q row.
2. Request one K/V tile.
3. Emit one O row.

Check the top-level AXI reads/writes and status timing without depending on attention math.

#### End-To-End With Real Core

Run the integrated top with the existing Member B `flash_core` and memory-backed vectors:

- Preload `Q`, `K`, `V` memory.
- Program bases, stride, scale, and mask config.
- Start the accelerator.
- Wait for `DONE` / `irq`.
- Read back `O` memory and compare against the provided golden output.

## Suggested Testbench Split

### SystemVerilog

- `tb/sv/tb_axi_lite_regs.sv`
- `tb/sv/tb_axi_master_read.sv`
- `tb/sv/tb_axi_master_write.sv`
- `tb/sv/tb_dma_controller_row_stride.sv`
- `tb/sv/tb_flash_attn_top_smoke.sv`

### Cocotb

- `tb/cocotb/test_axi_lite.py`
- `tb/cocotb/test_dma_controller.py`
- `tb/cocotb/test_end_to_end.py`

## Pass Criteria

A-side delivery is considered complete when:

1. All register-map behaviors match the README / interface spec.
2. All row/tile addresses match the documented layout exactly.
3. No AXI beat is lost under backpressure.
4. `DONE` is only raised after core completion and DMA drain.
5. End-to-end output memory matches the golden data within the agreed fixed-point tolerance.
