# tb/cocotb/test_end_to_end.py

import os
import sys

import numpy as np

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge


# ---------------------------------------------------------------------
# Python import path
# ---------------------------------------------------------------------

THIS_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(THIS_DIR, "..", ".."))
MODEL_DIR = os.path.join(PROJECT_ROOT, "model")

if THIS_DIR not in sys.path:
    sys.path.append(THIS_DIR)

if MODEL_DIR not in sys.path:
    sys.path.insert(0, MODEL_DIR)

from common.axi_driver import AXILiteMaster
from common.axi_ram import AXI4RAM

import compare_models as cmp


# ---------------------------------------------------------------------
# Register map
# ---------------------------------------------------------------------

REG_CTRL         = 0x00
REG_STATUS       = 0x04
REG_CFG          = 0x08

REG_Q_BASE_L     = 0x14
REG_Q_BASE_H     = 0x18
REG_K_BASE_L     = 0x1C
REG_K_BASE_H     = 0x20
REG_V_BASE_L     = 0x24
REG_V_BASE_H     = 0x28
REG_O_BASE_L     = 0x2C
REG_O_BASE_H     = 0x30

REG_STRIDE_BYTES = 0x34
REG_NEG_LARGE    = 0x38
REG_SCALE        = 0x3C
REG_CYCLES       = 0x40


# CTRL bits
CTRL_START_BIT      = 0
CTRL_SOFT_RESET_BIT = 1
CTRL_IRQ_EN_BIT     = 2

CTRL_START          = 1 << CTRL_START_BIT
CTRL_SOFT_RESET     = 1 << CTRL_SOFT_RESET_BIT
CTRL_IRQ_EN         = 1 << CTRL_IRQ_EN_BIT


# STATUS bits
STATUS_BUSY_BIT     = 0
STATUS_DONE_BIT     = 1
STATUS_ERROR_BIT    = 2

STATUS_BUSY         = 1 << STATUS_BUSY_BIT
STATUS_DONE         = 1 << STATUS_DONE_BIT
STATUS_ERROR        = 1 << STATUS_ERROR_BIT


# CFG bits
CFG_CAUSAL_EN       = 1 << 0


# ---------------------------------------------------------------------
# Baseline constants
# ---------------------------------------------------------------------

S_LEN        = int(cmp.cfg.S_LEN)
D_MODEL      = int(cmp.cfg.D_MODEL)
DATA_BYTES   = 2
NUM_ELEMS    = S_LEN * D_MODEL
TENSOR_BYTES = NUM_ELEMS * DATA_BYTES

DEFAULT_STRIDE = D_MODEL * DATA_BYTES

# scale = 1 / sqrt(64) = 1/8 = 0.125
# Q8.8 => 0.125 * 256 = 32 = 0x20
SCALE_Q8_8 = int(round((1.0 / np.sqrt(D_MODEL)) * int(cmp.cfg.SCALE_FACTOR)))

# -128.0 in Q8.8 = -32768 = 0x8000
# sign-extended to 32-bit = 0xFFFF8000
NEG_LARGE_Q8_8 = 0xFFFF8000

MAE_LIMIT = float(os.getenv("FLASH_ATTN_MAE_LIMIT", "0.03"))
MAXE_LIMIT = float(os.getenv("FLASH_ATTN_MAXE_LIMIT", "0.10"))

# Spec baseline performance target: < 300k cycles.
CYCLE_LIMIT = int(os.getenv("FLASH_ATTN_CYCLE_LIMIT", "300000"))

# Simulation timeout should be a little larger than the performance target,
# so that we can distinguish "completed too slowly" from "never completed".
TIMEOUT_CYCLES = int(os.getenv("FLASH_E2E_TIMEOUT_CYCLES", "350000"))
POLL_INTERVAL_CYCLES = int(os.getenv("FLASH_E2E_POLL_INTERVAL_CYCLES", "32"))

# 64 KiB spacing. Each tensor is 256 * 64 * 2 = 32768 bytes = 32 KiB.
# These bases are 8-byte aligned for AXI4 64-bit accesses.
Q_BASE = int(os.getenv("FLASH_E2E_Q_BASE", "0x00001000"), 0)
K_BASE = int(os.getenv("FLASH_E2E_K_BASE", "0x00011000"), 0)
V_BASE = int(os.getenv("FLASH_E2E_V_BASE", "0x00021000"), 0)
O_BASE = int(os.getenv("FLASH_E2E_O_BASE", "0x00031000"), 0)

# O memory is initialized to this pattern before START.
O_INIT_PATTERN = 0x5A5A


# ---------------------------------------------------------------------
# Generic helpers
# ---------------------------------------------------------------------

def has_signal(dut, name):
    try:
        getattr(dut, name)
        return True
    except Exception:
        return False


def is_one(sig):
    try:
        val = sig.value
        if hasattr(val, "is_resolvable") and not val.is_resolvable:
            return False
        return int(val) == 1
    except Exception:
        return False


def get_int(sig, name="signal"):
    val = sig.value

    if hasattr(val, "is_resolvable") and not val.is_resolvable:
        raise AssertionError(f"{name} has X/Z value: {val}")

    return int(val)


def split_u64(x):
    x = int(x) & 0xFFFFFFFFFFFFFFFF
    lo = x & 0xFFFFFFFF
    hi = (x >> 32) & 0xFFFFFFFF
    return lo, hi


def check_addr_alignment_and_overlap():
    bases = [
        ("Q", Q_BASE),
        ("K", K_BASE),
        ("V", V_BASE),
        ("O", O_BASE),
    ]

    for name, base in bases:
        assert base % 8 == 0, (
            f"{name}_BASE must be 8-byte aligned for 64-bit AXI access, "
            f"got 0x{base:X}"
        )

    regions = []
    for name, base in bases:
        regions.append((name, base, base + TENSOR_BYTES))

    for i in range(len(regions)):
        name_i, start_i, end_i = regions[i]
        for j in range(i + 1, len(regions)):
            name_j, start_j, end_j = regions[j]

            overlap = not (end_i <= start_j or end_j <= start_i)
            assert not overlap, (
                f"Memory regions overlap: "
                f"{name_i}[0x{start_i:X}, 0x{end_i:X}) and "
                f"{name_j}[0x{start_j:X}, 0x{end_j:X})"
            )


def check_required_top_ports(dut):
    required = [
        "clk",
        "rst_n",

        "s_axil_awaddr",
        "s_axil_awvalid",
        "s_axil_awready",

        "s_axil_wdata",
        "s_axil_wstrb",
        "s_axil_wvalid",
        "s_axil_wready",

        "s_axil_bresp",
        "s_axil_bvalid",
        "s_axil_bready",

        "s_axil_araddr",
        "s_axil_arvalid",
        "s_axil_arready",

        "s_axil_rdata",
        "s_axil_rresp",
        "s_axil_rvalid",
        "s_axil_rready",

        "m_axi_araddr",
        "m_axi_arlen",
        "m_axi_arsize",
        "m_axi_arburst",
        "m_axi_arvalid",
        "m_axi_arready",

        "m_axi_rdata",
        "m_axi_rresp",
        "m_axi_rlast",
        "m_axi_rvalid",
        "m_axi_rready",

        "m_axi_awaddr",
        "m_axi_awlen",
        "m_axi_awsize",
        "m_axi_awburst",
        "m_axi_awvalid",
        "m_axi_awready",

        "m_axi_wdata",
        "m_axi_wstrb",
        "m_axi_wlast",
        "m_axi_wvalid",
        "m_axi_wready",

        "m_axi_bresp",
        "m_axi_bvalid",
        "m_axi_bready",
    ]

    missing = [name for name in required if not has_signal(dut, name)]

    assert not missing, (
        "DUT does not look like flash_attn_top. "
        f"Missing required top-level ports: {missing}"
    )


async def reset_dut(dut, cycles_low=5, cycles_high=2):
    dut.rst_n.value = 0

    for _ in range(cycles_low):
        await RisingEdge(dut.clk)

    dut.rst_n.value = 1

    for _ in range(cycles_high):
        await RisingEdge(dut.clk)


async def init_testbench(dut):
    """
    Create AXI-Lite master and AXI4 RAM before reset release.

    This prevents DUT inputs from being X during reset.
    """
    check_required_top_ports(dut)
    check_addr_alignment_and_overlap()

    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())

    axil = AXILiteMaster(dut, dut.clk, dut.rst_n, timeout_cycles=5000)
    ram = AXI4RAM(dut, dut.clk, dut.rst_n)

    await reset_dut(dut)

    return axil, ram


# ---------------------------------------------------------------------
# AXI-Lite register helpers
# ---------------------------------------------------------------------

async def write_reg64(axil, reg_l, reg_h, value, name):
    lo, hi = split_u64(value)

    await axil.write(reg_l, lo)
    await axil.write(reg_h, hi)

    read_lo = await axil.read(reg_l)
    read_hi = await axil.read(reg_h)

    assert read_lo == lo, (
        f"{name}_L readback mismatch: expected=0x{lo:08X}, got=0x{read_lo:08X}"
    )

    assert read_hi == hi, (
        f"{name}_H readback mismatch: expected=0x{hi:08X}, got=0x{read_hi:08X}"
    )


async def program_e2e_config(axil):
    """
    Program all required registers for one baseline causal attention run.
    """
    await axil.write(REG_CFG, CFG_CAUSAL_EN)

    await write_reg64(axil, REG_Q_BASE_L, REG_Q_BASE_H, Q_BASE, "Q_BASE")
    await write_reg64(axil, REG_K_BASE_L, REG_K_BASE_H, K_BASE, "K_BASE")
    await write_reg64(axil, REG_V_BASE_L, REG_V_BASE_H, V_BASE, "V_BASE")
    await write_reg64(axil, REG_O_BASE_L, REG_O_BASE_H, O_BASE, "O_BASE")

    await axil.write(REG_STRIDE_BYTES, DEFAULT_STRIDE)
    await axil.write(REG_NEG_LARGE, NEG_LARGE_Q8_8)
    await axil.write(REG_SCALE, SCALE_Q8_8)

    # Readback sanity.
    cfg = await axil.read(REG_CFG)
    stride = await axil.read(REG_STRIDE_BYTES)
    neg_large = await axil.read(REG_NEG_LARGE)
    scale = await axil.read(REG_SCALE)

    assert (cfg & CFG_CAUSAL_EN) == CFG_CAUSAL_EN, (
        f"CFG.CAUSAL_EN readback mismatch, CFG=0x{cfg:08X}"
    )

    assert stride == DEFAULT_STRIDE, (
        f"STRIDE_BYTES readback mismatch: expected={DEFAULT_STRIDE}, got={stride}"
    )

    assert neg_large == (NEG_LARGE_Q8_8 & 0xFFFFFFFF), (
        f"NEG_LARGE readback mismatch: "
        f"expected=0x{NEG_LARGE_Q8_8 & 0xFFFFFFFF:08X}, got=0x{neg_large:08X}"
    )

    assert scale == SCALE_Q8_8, (
        f"SCALE readback mismatch: expected=0x{SCALE_Q8_8:08X}, got=0x{scale:08X}"
    )


async def start_accelerator(axil):
    """
    Fire CTRL.START and verify START is not sticky.
    """
    await axil.write(REG_CTRL, CTRL_START)

    for _ in range(5):
        await RisingEdge(axil.clk)

    ctrl = await axil.read(REG_CTRL)

    assert (ctrl & CTRL_START) == 0, (
        f"CTRL.START should auto-clear after write, got CTRL=0x{ctrl:08X}"
    )


async def wait_for_done(dut, axil):
    """
    Poll STATUS until DONE.

    Returns:
        dict with status, host_wait_cycles, saw_busy.
    """
    saw_busy = False
    last_status = None

    for cycle in range(TIMEOUT_CYCLES):
        await RisingEdge(dut.clk)

        if cycle % POLL_INTERVAL_CYCLES != 0:
            continue

        status = await axil.read(REG_STATUS)
        last_status = status

        if status & STATUS_BUSY:
            saw_busy = True

        if status & STATUS_ERROR:
            raise AssertionError(
                f"STATUS.ERROR asserted while waiting for DONE. "
                f"cycle={cycle}, STATUS=0x{status:08X}"
            )

        if status & STATUS_DONE:
            return {
                "status": status,
                "host_wait_cycles": cycle,
                "saw_busy": saw_busy,
            }

    final_status = await axil.read(REG_STATUS)

    raise AssertionError(
        f"Timeout waiting for STATUS.DONE after {TIMEOUT_CYCLES} cycles. "
        f"last_status=0x{last_status if last_status is not None else 0:08X}, "
        f"final_status=0x{final_status:08X}"
    )


# ---------------------------------------------------------------------
# Vector / memory helpers
# ---------------------------------------------------------------------

def load_vectors_to_ram(ram):
    """
    Load existing Q/K/V vectors into AXI RAM.

    Uses compare_models.py as the single source for:
      - hex reading
      - Q8.8 float/int conversion
      - golden O loading
    """
    Q_float, K_float, V_float, O_golden_float = cmp.load_qkv_and_golden()

    Q_int = cmp.float_to_q88_int(Q_float)
    K_int = cmp.float_to_q88_int(K_float)
    V_int = cmp.float_to_q88_int(V_float)

    assert Q_int.shape == (S_LEN, D_MODEL), (
        f"Q shape mismatch: expected {(S_LEN, D_MODEL)}, got {Q_int.shape}"
    )
    assert K_int.shape == (S_LEN, D_MODEL), (
        f"K shape mismatch: expected {(S_LEN, D_MODEL)}, got {K_int.shape}"
    )
    assert V_int.shape == (S_LEN, D_MODEL), (
        f"V shape mismatch: expected {(S_LEN, D_MODEL)}, got {V_int.shape}"
    )
    assert O_golden_float.shape == (S_LEN, D_MODEL), (
        f"Golden O shape mismatch: expected {(S_LEN, D_MODEL)}, got {O_golden_float.shape}"
    )

    ram.load_i16_array(Q_BASE, Q_int.reshape(-1).tolist())
    ram.load_i16_array(K_BASE, K_int.reshape(-1).tolist())
    ram.load_i16_array(V_BASE, V_int.reshape(-1).tolist())

    # Initialize O region with a recognizable pattern before RTL writes it.
    ram.load_i16_array(O_BASE, [O_INIT_PATTERN] * NUM_ELEMS)

    # Memory sanity check: verify first 16 Q/K/V elements survived packing.
    q_dump = np.array(ram.dump_i16_array(Q_BASE, 16), dtype=np.int64)
    k_dump = np.array(ram.dump_i16_array(K_BASE, 16), dtype=np.int64)
    v_dump = np.array(ram.dump_i16_array(V_BASE, 16), dtype=np.int64)

    assert np.array_equal(q_dump, Q_int.reshape(-1)[:16]), (
        "Q memory preload sanity check failed"
    )
    assert np.array_equal(k_dump, K_int.reshape(-1)[:16]), (
        "K memory preload sanity check failed"
    )
    assert np.array_equal(v_dump, V_int.reshape(-1)[:16]), (
        "V memory preload sanity check failed"
    )

    return Q_float, K_float, V_float, O_golden_float, Q_int, K_int, V_int


def dump_output_from_ram(ram):
    """
    Dump O output memory as signed int16 matrix [S_LEN, D_MODEL].
    """
    o_flat = ram.dump_i16_array(O_BASE, NUM_ELEMS)
    o_int = np.array(o_flat, dtype=np.int64).reshape(S_LEN, D_MODEL)
    return o_int


def maybe_dump_o_hex(ram):
    """
    Optional debug dump:
        FLASH_E2E_DUMP_O=1 make MODULE=test_end_to_end
    """
    dump_enable = os.getenv("FLASH_E2E_DUMP_O", "0") == "1"

    if not dump_enable:
        return None

    out_file = os.path.join(PROJECT_ROOT, "tb", "vectors", "rtl_o_e2e.hex")
    ram.dump_hex_i16_file(O_BASE, NUM_ELEMS, out_file)
    return out_file


# ---------------------------------------------------------------------
# Main end-to-end test
# ---------------------------------------------------------------------

@cocotb.test()
async def test_flash_attn_top_end_to_end_against_golden_hex(dut):
    """
    Top-level end-to-end test.

    This test verifies the complete baseline system path:

      1. preload Q/K/V into AXI RAM
      2. program AXI4-Lite registers
      3. write CTRL.START
      4. top/DMA reads Q/K/V through AXI4 master
      5. flash_core computes causal attention
      6. top/DMA writes O back through AXI4 master
      7. testbench dumps O from memory
      8. compare RTL O against golden_o.hex using MAE/MaxE limits

    This is intentionally different from test_flash_core.py:
      - test_flash_core.py bypasses AXI and directly mocks core handshakes
      - this file tests AXI-Lite + DMA + AXI RAM + core integration
    """

    axil, ram = await init_testbench(dut)

    dut._log.info("Starting FlashAttention top-level end-to-end test")
    dut._log.info(
        f"Baseline: S_LEN={S_LEN}, D_MODEL={D_MODEL}, "
        f"stride={DEFAULT_STRIDE}, tensor_bytes={TENSOR_BYTES}"
    )
    dut._log.info(
        f"Memory map: Q=0x{Q_BASE:X}, K=0x{K_BASE:X}, "
        f"V=0x{V_BASE:X}, O=0x{O_BASE:X}"
    )

    # -----------------------------------------------------------------
    # 1. Load Q/K/V/golden vectors
    # -----------------------------------------------------------------

    Q_float, K_float, V_float, O_golden_float, Q_int, K_int, V_int = load_vectors_to_ram(ram)

    dut._log.info("Loaded Q/K/V vectors into AXI RAM")

    # -----------------------------------------------------------------
    # 2. Reset-status sanity
    # -----------------------------------------------------------------

    status = await axil.read(REG_STATUS)

    assert (status & STATUS_BUSY) == 0, (
        f"STATUS.BUSY should be 0 after reset, got STATUS=0x{status:08X}"
    )

    assert (status & STATUS_ERROR) == 0, (
        f"STATUS.ERROR should be 0 after reset, got STATUS=0x{status:08X}"
    )

    # -----------------------------------------------------------------
    # 3. Program registers
    # -----------------------------------------------------------------

    await program_e2e_config(axil)

    dut._log.info("Programmed AXI4-Lite configuration registers")

    # -----------------------------------------------------------------
    # 4. START and wait DONE
    # -----------------------------------------------------------------

    await start_accelerator(axil)

    dut._log.info("CTRL.START accepted; polling STATUS.DONE")

    done_info = await wait_for_done(dut, axil)

    final_status = done_info["status"]

    assert (final_status & STATUS_DONE) != 0, (
        f"STATUS.DONE should be set at completion, STATUS=0x{final_status:08X}"
    )

    assert (final_status & STATUS_ERROR) == 0, (
        f"STATUS.ERROR should be 0 at completion, STATUS=0x{final_status:08X}"
    )

    assert done_info["saw_busy"], (
        "STATUS.BUSY was never observed during the end-to-end run. "
        "This may indicate busy is not connected to the status register."
    )

    cycles = await axil.read(REG_CYCLES)

    dut._log.info(
        f"End-to-end run completed: "
        f"STATUS=0x{final_status:08X}, CYCLES={cycles}, "
        f"host_wait_cycles={done_info['host_wait_cycles']}"
    )

    assert cycles > 0, (
        f"CYCLES should be non-zero after a completed run, got {cycles}"
    )

    assert cycles < CYCLE_LIMIT, (
        f"Performance target failed: CYCLES={cycles} >= {CYCLE_LIMIT}"
    )

    # -----------------------------------------------------------------
    # 5. Dump O from memory
    # -----------------------------------------------------------------

    o_rtl_int = dump_output_from_ram(ram)

    assert not np.all(o_rtl_int.reshape(-1) == O_INIT_PATTERN), (
        "O memory still equals the initialization pattern. "
        "This suggests the AXI write-back path did not write O."
    )

    dump_file = maybe_dump_o_hex(ram)
    if dump_file is not None:
        dut._log.info(f"Dumped RTL O hex to {dump_file}")

    # -----------------------------------------------------------------
    # 6. RTL-vs-golden error check
    # -----------------------------------------------------------------

    o_rtl_float = cmp.int_to_q88_float(o_rtl_int)

    result = cmp.check_error(
        O_golden_float,
        o_rtl_float,
        mae_limit=MAE_LIMIT,
        maxe_limit=MAXE_LIMIT,
    )

    abs_diff = result["abs_diff"]
    worst_flat = int(np.argmax(abs_diff))
    worst_idx = np.unravel_index(worst_flat, abs_diff.shape)

    worst_row = int(worst_idx[0])
    worst_col = int(worst_idx[1])

    dut._log.info(
        "RTL top-level error report: "
        f"MAE={result['mean_abs_error']:.6f}, "
        f"MaxE={result['max_abs_error']:.6f}, "
        f"limits=({MAE_LIMIT}, {MAXE_LIMIT}), "
        f"worst_idx=({worst_row}, {worst_col}), "
        f"golden={O_golden_float[worst_row, worst_col]:.6f}, "
        f"rtl={o_rtl_float[worst_row, worst_col]:.6f}, "
        f"diff={abs_diff[worst_row, worst_col]:.6f}"
    )

    assert result["passed"], (
        "End-to-end RTL output does not meet golden error limits: "
        f"MAE={result['mean_abs_error']:.6f} <= {MAE_LIMIT}, "
        f"MaxE={result['max_abs_error']:.6f} <= {MAXE_LIMIT}, "
        f"worst_idx=({worst_row}, {worst_col}), "
        f"golden={O_golden_float[worst_row, worst_col]:.6f}, "
        f"rtl={o_rtl_float[worst_row, worst_col]:.6f}"
    )

    # -----------------------------------------------------------------
    # 7. Causal mask corner case: i = 0 can only attend to j = 0
    # -----------------------------------------------------------------

    row0_abs_diff = np.abs(o_rtl_float[0] - V_float[0])
    row0_mean_err = float(np.mean(row0_abs_diff))
    row0_max_err = float(np.max(row0_abs_diff))

    dut._log.info(
        "Causal row-0 corner check: "
        f"mean(|O[0]-V[0]|)={row0_mean_err:.6f}, "
        f"max(|O[0]-V[0]|)={row0_max_err:.6f}"
    )

    assert row0_max_err <= MAXE_LIMIT, (
        "Causal mask corner failed for row 0. "
        "When CAUSAL_EN=1, query row i=0 should only attend to key row j=0, "
        f"so O[0] should be close to V[0]. "
        f"mean_err={row0_mean_err:.6f}, max_err={row0_max_err:.6f}, "
        f"limit={MAXE_LIMIT}"
    )

    # -----------------------------------------------------------------
    # 8. STATUS.DONE W1C check after full run
    # -----------------------------------------------------------------

    await axil.write(REG_STATUS, STATUS_DONE)

    for _ in range(4):
        await RisingEdge(dut.clk)

    status_after_clear = await axil.read(REG_STATUS)

    assert (status_after_clear & STATUS_DONE) == 0, (
        f"STATUS.DONE should clear after W1C, "
        f"got STATUS=0x{status_after_clear:08X}"
    )

    assert (status_after_clear & STATUS_ERROR) == 0, (
        f"STATUS.ERROR should remain 0 after DONE clear, "
        f"got STATUS=0x{status_after_clear:08X}"
    )

    # Optional IRQ observation. Do not fail the test on IRQ unless your team
    # decides IRQ is mandatory for baseline grading.
    if has_signal(dut, "irq"):
        try:
            irq_val = get_int(dut.irq, "irq")
            dut._log.info(f"IRQ final value = {irq_val}")
        except AssertionError as exc:
            dut._log.warning(str(exc))

    dut._log.info(
        "FlashAttention top-level end-to-end test passed: "
        f"CYCLES={cycles}, "
        f"MAE={result['mean_abs_error']:.6f}, "
        f"MaxE={result['max_abs_error']:.6f}, "
        f"row0_max_err={row0_max_err:.6f}"
    )
