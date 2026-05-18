# tb/cocotb/test_axi_lite.py

import os
import sys

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge


# ---------------------------------------------------------------------
# Python import path
# ---------------------------------------------------------------------

THIS_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.append(THIS_DIR)

from common.axi_driver import AXILiteMaster

try:
    from common.axi_ram import AXI4RAM
except ImportError:
    AXI4RAM = None


# ---------------------------------------------------------------------
# Register map from README / spec
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
CTRL_START_BIT     = 0
CTRL_SOFT_RESET_BIT = 1
CTRL_IRQ_EN_BIT    = 2

CTRL_START         = 1 << CTRL_START_BIT
CTRL_SOFT_RESET    = 1 << CTRL_SOFT_RESET_BIT
CTRL_IRQ_EN        = 1 << CTRL_IRQ_EN_BIT


# STATUS bits
STATUS_BUSY_BIT    = 0
STATUS_DONE_BIT    = 1
STATUS_ERROR_BIT   = 2

STATUS_BUSY        = 1 << STATUS_BUSY_BIT
STATUS_DONE        = 1 << STATUS_DONE_BIT
STATUS_ERROR       = 1 << STATUS_ERROR_BIT


# Baseline constants
S_LEN              = 256
D_MODEL            = 64
DATA_BYTES         = 2
DEFAULT_STRIDE     = D_MODEL * DATA_BYTES       # 128 bytes
SCALE_Q8_8         = 0x00000020                 # 1/sqrt(64)=1/8, Q8.8 = 32
NEG_LARGE_Q8_8     = 0xFFFF8000                 # -128.0 in sign-extended Q8.8


# ---------------------------------------------------------------------
# Generic helpers
# ---------------------------------------------------------------------

def has_signal(dut, name):
    try:
        getattr(dut, name)
        return True
    except Exception:
        return False


def try_get_signal(dut, names):
    for name in names:
        try:
            return getattr(dut, name)
        except Exception:
            pass
    return None


def maybe_create_axi_ram(dut):
    """
    If the DUT is flash_attn_top, it should have m_axi_* ports.
    Instantiate AXI4RAM before reset so AXI master-side inputs are not X.

    If the DUT is only axi_lite_regs, it will not have m_axi_* ports.
    Then this helper returns None.
    """
    if AXI4RAM is None:
        return None

    required_ports = [
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

    if all(has_signal(dut, p) for p in required_ports):
        return AXI4RAM(dut, dut.clk, dut.rst_n)

    return None


async def reset_dut(dut, cycles_low=5, cycles_high=2):
    dut.rst_n.value = 0

    for _ in range(cycles_low):
        await RisingEdge(dut.clk)

    dut.rst_n.value = 1

    for _ in range(cycles_high):
        await RisingEdge(dut.clk)


async def init_testbench(dut):
    """
    Important:
        AXILiteMaster and optional AXI4RAM are created before reset.
        This prevents DUT inputs from being X during reset.
    """
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())

    axil = AXILiteMaster(dut, dut.clk, dut.rst_n, timeout_cycles=2000)
    ram = maybe_create_axi_ram(dut)

    await reset_dut(dut)

    return axil, ram


async def write_read_check(axil, addr, value, name):
    await axil.write(addr, value)
    actual = await axil.read(addr)

    expected = value & 0xFFFFFFFF

    assert actual == expected, (
        f"{name} register R/W mismatch: "
        f"addr=0x{addr:02X}, expected=0x{expected:08X}, actual=0x{actual:08X}"
    )

    return actual


async def read_check_mask(axil, addr, expected, mask, name):
    actual = await axil.read(addr)

    assert (actual & mask) == (expected & mask), (
        f"{name} masked read mismatch: "
        f"addr=0x{addr:02X}, mask=0x{mask:08X}, "
        f"expected=0x{expected & mask:08X}, actual=0x{actual & mask:08X}, "
        f"raw_actual=0x{actual:08X}"
    )

    return actual


async def program_minimal_valid_config(axil):
    """
    Program a minimal legal baseline configuration before START.
    """
    await axil.write(REG_CFG, 0x00000001)          # CAUSAL_EN = 1

    await axil.write(REG_Q_BASE_L, 0x00001000)
    await axil.write(REG_Q_BASE_H, 0x00000000)

    await axil.write(REG_K_BASE_L, 0x00011000)
    await axil.write(REG_K_BASE_H, 0x00000000)

    await axil.write(REG_V_BASE_L, 0x00021000)
    await axil.write(REG_V_BASE_H, 0x00000000)

    await axil.write(REG_O_BASE_L, 0x00031000)
    await axil.write(REG_O_BASE_H, 0x00000000)

    await axil.write(REG_STRIDE_BYTES, DEFAULT_STRIDE)
    await axil.write(REG_NEG_LARGE, NEG_LARGE_Q8_8)
    await axil.write(REG_SCALE, SCALE_Q8_8)


# ---------------------------------------------------------------------
# Test 1: reset defaults and normal R/W registers
# ---------------------------------------------------------------------

@cocotb.test()
async def test_axi_lite_reset_defaults_and_rw(dut):
    """
    AXI4-Lite baseline register test.

    Covers:
      - reset default sanity
      - CFG R/W
      - Q/K/V/O base low/high R/W
      - STRIDE_BYTES default and R/W
      - NEG_LARGE R/W
      - SCALE R/W
      - CTRL.IRQ_EN R/W behavior
      - CYCLES readable
    """

    axil, _ = await init_testbench(dut)

    dut._log.info("Starting AXI4-Lite reset/default/register R/W test")

    # CTRL.START must not be stuck high after reset.
    ctrl = await axil.read(REG_CTRL)
    assert (ctrl & CTRL_START) == 0, (
        f"CTRL.START should be 0 after reset, got CTRL=0x{ctrl:08X}"
    )

    # STATUS.ERROR should not be high immediately after reset.
    status = await axil.read(REG_STATUS)
    assert (status & STATUS_ERROR) == 0, (
        f"STATUS.ERROR should be 0 after reset, got STATUS=0x{status:08X}"
    )

    # STRIDE_BYTES default must be d * 2 = 128 bytes according to spec.
    stride = await axil.read(REG_STRIDE_BYTES)
    assert stride == DEFAULT_STRIDE, (
        f"STRIDE_BYTES default mismatch: "
        f"expected {DEFAULT_STRIDE}, got {stride}"
    )

    # CYCLES is read-only/readable.
    cycles = await axil.read(REG_CYCLES)
    dut._log.info(f"Initial CYCLES = 0x{cycles:08X}")

    # CTRL bit2 IRQ_EN should be a normal config bit.
    # Do not test START here because START is pulse/auto-clear.
    # Do not force SOFT_RESET readback because it may be implemented as a pulse.
    await axil.write(REG_CTRL, CTRL_IRQ_EN)
    ctrl = await axil.read(REG_CTRL)
    assert (ctrl & CTRL_IRQ_EN) == CTRL_IRQ_EN, (
        f"CTRL.IRQ_EN readback mismatch, CTRL=0x{ctrl:08X}"
    )
    assert (ctrl & CTRL_START) == 0, (
        f"CTRL.START should not become sticky, CTRL=0x{ctrl:08X}"
    )

    # Main writable register map.
    writable_regs = [
        (REG_CFG,          0x00000001, "CFG"),

        (REG_Q_BASE_L,     0x89ABC000, "Q_BASE_L"),
        (REG_Q_BASE_H,     0x00000001, "Q_BASE_H"),

        (REG_K_BASE_L,     0x89ABD000, "K_BASE_L"),
        (REG_K_BASE_H,     0x00000002, "K_BASE_H"),

        (REG_V_BASE_L,     0x89ABE000, "V_BASE_L"),
        (REG_V_BASE_H,     0x00000003, "V_BASE_H"),

        (REG_O_BASE_L,     0x89ABF000, "O_BASE_L"),
        (REG_O_BASE_H,     0x00000004, "O_BASE_H"),

        # R/W test uses a non-default legal stride first.
        # Later tests set it back to DEFAULT_STRIDE.
        (REG_STRIDE_BYTES, 0x00000100, "STRIDE_BYTES"),

        # README/spec: NEG_LARGE is Q8.8 -inf approximation.
        (REG_NEG_LARGE,    NEG_LARGE_Q8_8, "NEG_LARGE"),

        # 1/sqrt(64)=1/8. If SCALE is Q8.8, value is 0.125*256 = 32 = 0x20.
        (REG_SCALE,        SCALE_Q8_8, "SCALE"),
    ]

    for addr, value, name in writable_regs:
        dut._log.info(f"Testing {name}: write 0x{value:08X} to 0x{addr:02X}")
        await write_read_check(axil, addr, value, name)

    dut._log.info("AXI4-Lite reset/default/register R/W test passed")


# ---------------------------------------------------------------------
# Test 2: CTRL.START auto-clear / pulse behavior
# ---------------------------------------------------------------------

@cocotb.test()
async def test_axi_lite_start_autoclear(dut):
    """
    Test CTRL.START behavior.

    Expected by spec:
      - host writes CTRL.START = 1
      - hardware consumes it as a start pulse
      - START bit auto-clears / reads back as 0
    """

    axil, _ = await init_testbench(dut)

    dut._log.info("Starting AXI4-Lite CTRL.START auto-clear test")

    await program_minimal_valid_config(axil)

    # Preserve IRQ_EN while firing START.
    await axil.write(REG_CTRL, CTRL_IRQ_EN | CTRL_START)

    # Give RTL a few cycles to consume START pulse.
    for _ in range(5):
        await RisingEdge(dut.clk)

    ctrl = await axil.read(REG_CTRL)

    assert (ctrl & CTRL_START) == 0, (
        f"CTRL.START should auto-clear after write, got CTRL=0x{ctrl:08X}"
    )

    assert (ctrl & CTRL_IRQ_EN) == CTRL_IRQ_EN, (
        f"CTRL.IRQ_EN should remain set after START, got CTRL=0x{ctrl:08X}"
    )

    status = await axil.read(REG_STATUS)

    assert (status & STATUS_ERROR) == 0, (
        f"STATUS.ERROR asserted after START, got STATUS=0x{status:08X}"
    )

    dut._log.info("AXI4-Lite CTRL.START auto-clear test passed")


# ---------------------------------------------------------------------
# Test 3: STATUS.DONE W1C if testing axi_lite_regs directly
# ---------------------------------------------------------------------

@cocotb.test()
async def test_axi_lite_status_done_w1c_if_possible(dut):
    """
    Test STATUS.DONE write-one-to-clear behavior when possible.

    This test is mainly for axi_lite_regs.sv unit testing, where busy/done/error
    are usually direct input ports.

    If the DUT is flash_attn_top, DONE is normally generated internally by the
    core/DMA flow. In that case, this test logs and returns. The full
    START/BUSY/DONE flow should be covered by test_end_to_end.py.
    """

    axil, _ = await init_testbench(dut)

    dut._log.info("Starting optional STATUS.DONE W1C test")

    busy_sig = try_get_signal(dut, ["busy", "status_busy", "core_busy", "dma_busy"])
    done_sig = try_get_signal(dut, ["done", "status_done", "core_done", "dma_done"])
    error_sig = try_get_signal(dut, ["error", "status_error", "core_error", "dma_error"])
    cycles_sig = try_get_signal(dut, ["cycles", "cycle_count", "status_cycles"])

    if done_sig is None:
        dut._log.info(
            "No direct done/status_done input port found. "
            "Skipping STATUS.DONE W1C unit check for this DUT."
        )
        return

    if busy_sig is not None:
        busy_sig.value = 0

    if error_sig is not None:
        error_sig.value = 0

    if cycles_sig is not None:
        cycles_sig.value = 0x00001234

    # Drive DONE high from the status source.
    done_sig.value = 1

    for _ in range(2):
        await RisingEdge(dut.clk)

    status = await axil.read(REG_STATUS)

    assert (status & STATUS_DONE) != 0, (
        f"STATUS.DONE should be 1 when done input is high, got STATUS=0x{status:08X}"
    )

    # Write 1 to DONE bit to clear it.
    await axil.write(REG_STATUS, STATUS_DONE)

    for _ in range(2):
        await RisingEdge(dut.clk)

    # Drop done input after W1C to model a completed clear.
    done_sig.value = 0

    for _ in range(2):
        await RisingEdge(dut.clk)

    status = await axil.read(REG_STATUS)

    assert (status & STATUS_DONE) == 0, (
        f"STATUS.DONE should clear after W1C, got STATUS=0x{status:08X}"
    )

    dut._log.info("Optional STATUS.DONE W1C test passed")
