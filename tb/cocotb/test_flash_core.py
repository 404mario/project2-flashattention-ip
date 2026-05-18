# tb/cocotb/test_flash_core.py

import os
import sys

import numpy as np

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge


# ---------------------------------------------------------------------
# Path setup
# ---------------------------------------------------------------------

THIS_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(THIS_DIR, "..", ".."))
MODEL_DIR = os.path.join(PROJECT_ROOT, "model")

if MODEL_DIR not in sys.path:
    sys.path.insert(0, MODEL_DIR)

import compare_models as cmp


# ---------------------------------------------------------------------
# Baseline parameters
# ---------------------------------------------------------------------

S_LEN = int(cmp.cfg.S_LEN)
D_MODEL = int(cmp.cfg.D_MODEL)
BK = int(getattr(cmp.cfg, "BK", 16))
SCALE_FACTOR = int(cmp.cfg.SCALE_FACTOR)

DATA_W = 16

# scale = 1 / sqrt(64) = 1/8 = 0.125
# Q8.8 => 0.125 * 256 = 32 = 0x20
SCALE_Q8_8 = int(round((1.0 / np.sqrt(D_MODEL)) * SCALE_FACTOR))

# -128.0 in Q8.8 = -32768 = 0x8000
# sign-extended to 32-bit = 0xFFFF8000
NEG_LARGE_Q8_8 = 0xFFFF8000

MAE_LIMIT = float(os.getenv("FLASH_ATTN_MAE_LIMIT", "0.03"))
MAXE_LIMIT = float(os.getenv("FLASH_ATTN_MAXE_LIMIT", "0.10"))

TIMEOUT_CYCLES = int(os.getenv("FLASH_CORE_TIMEOUT_CYCLES", "500000"))

Q_READ_LATENCY = int(os.getenv("FLASH_CORE_Q_LATENCY", "1"))
KV_READ_LATENCY = int(os.getenv("FLASH_CORE_KV_LATENCY", "2"))


# ---------------------------------------------------------------------
# Signal helpers
# ---------------------------------------------------------------------

def has_signal(dut, name):
    try:
        getattr(dut, name)
        return True
    except Exception:
        return False


def is_one(sig):
    """
    Safe signal == 1 check.

    X/Z/unresolvable values return False.
    """
    try:
        val = sig.value

        if hasattr(val, "is_resolvable") and not val.is_resolvable:
            return False

        return int(val) == 1

    except Exception:
        return False


def get_int(sig, name="signal"):
    """
    Convert signal to int and fail loudly on X/Z.
    """
    val = sig.value

    if hasattr(val, "is_resolvable") and not val.is_resolvable:
        raise AssertionError(f"{name} has X/Z value: {val}")

    return int(val)


def to_u16(x):
    """
    Convert signed int to 16-bit two's complement value for RTL assignment.
    """
    return int(x) & 0xFFFF


def from_u16_to_i16(x):
    """
    Convert raw 16-bit value to signed int16.
    """
    raw = int(x) & 0xFFFF

    if raw & 0x8000:
        raw -= 0x10000

    return raw


def signal_to_i16(sig, name="signal"):
    raw = get_int(sig, name)
    return from_u16_to_i16(raw)


# ---------------------------------------------------------------------
# Input/output driving helpers
# ---------------------------------------------------------------------

def drive_input_defaults(dut):
    """
    Drive all flash_core inputs to known values.

    Important:
        q_req_ready and kv_req_ready are inputs from DMA to flash_core.
        They must not be left as X.
    """
    dut.start.value = 0

    dut.causal_en.value = 0
    dut.neg_large.value = 0
    dut.scale.value = 0

    dut.q_req_ready.value = 0
    dut.kv_req_ready.value = 0

    dut.q_data_valid.value = 0
    dut.kv_data_valid.value = 0

    dut.o_ready.value = 0

    for d in range(D_MODEL):
        dut.q_data[d].value = 0

    for b in range(BK):
        for d in range(D_MODEL):
            dut.k_tile[b][d].value = 0
            dut.v_tile[b][d].value = 0


def drive_q_row(dut, q_int, row):
    """
    Drive one Q row into dut.q_data.
    """
    for d in range(D_MODEL):
        dut.q_data[d].value = to_u16(q_int[row, d])


def drive_kv_tile(dut, k_int, v_int, start_row, req_len):
    """
    Drive one K/V tile into dut.k_tile and dut.v_tile.

    Valid tile rows:
        b = 0 ... req_len-1

    Remaining rows are zeroed.
    """
    for b in range(BK):
        row = start_row + b

        for d in range(D_MODEL):
            if b < req_len and row < S_LEN:
                dut.k_tile[b][d].value = to_u16(k_int[row, d])
                dut.v_tile[b][d].value = to_u16(v_int[row, d])
            else:
                dut.k_tile[b][d].value = 0
                dut.v_tile[b][d].value = 0


def capture_o_row(dut, o_int, seen_rows):
    """
    Capture one O row from RTL output.
    """
    row = get_int(dut.o_row, "o_row")

    assert 0 <= row < S_LEN, (
        f"o_row out of range: {row}"
    )

    assert not seen_rows[row], (
        f"Duplicate output row observed: row={row}"
    )

    for d in range(D_MODEL):
        o_int[row, d] = signal_to_i16(dut.o_data[d], f"o_data[{d}]")

    seen_rows[row] = True

    return row


# ---------------------------------------------------------------------
# Reset/start
# ---------------------------------------------------------------------

async def reset_dut(dut, cycles_low=5, cycles_high=2):
    dut.rst_n.value = 0

    for _ in range(cycles_low):
        await RisingEdge(dut.clk)

    dut.rst_n.value = 1

    for _ in range(cycles_high):
        await RisingEdge(dut.clk)


async def pulse_start(dut):
    dut.start.value = 1
    await RisingEdge(dut.clk)
    dut.start.value = 0


# ---------------------------------------------------------------------
# Mock DMA coroutines
# ---------------------------------------------------------------------

async def mock_q_dma(dut, q_int, stats, stop):
    """
    Mock DMA for Q row requests.

    Expected protocol:
      - core asserts q_req_valid/q_req_row
      - DMA accepts with q_req_ready
      - DMA later returns q_data with q_data_valid
      - core accepts with q_data_ready
    """
    dut.q_req_ready.value = 0
    dut.q_data_valid.value = 0

    while not stop["value"]:
        await RisingEdge(dut.clk)

        if not is_one(dut.rst_n):
            dut.q_req_ready.value = 0
            dut.q_data_valid.value = 0
            continue

        # Idle state: ready to accept one Q request.
        dut.q_req_ready.value = 1

        if is_one(dut.q_req_valid) and is_one(dut.q_req_ready):
            row = get_int(dut.q_req_row, "q_req_row")

            assert 0 <= row < S_LEN, (
                f"q_req_row out of range: {row}"
            )

            stats["q_reqs"] += 1
            stats["q_rows"].append(row)

            # Stop accepting new Q request while serving this one.
            dut.q_req_ready.value = 0

            for _ in range(Q_READ_LATENCY):
                await RisingEdge(dut.clk)

            drive_q_row(dut, q_int, row)
            dut.q_data_valid.value = 1

            accepted = False

            for _ in range(2000):
                await RisingEdge(dut.clk)

                if not is_one(dut.rst_n):
                    break

                if is_one(dut.q_data_ready):
                    accepted = True
                    break

            dut.q_data_valid.value = 0

            assert accepted, (
                f"Timeout waiting for q_data_ready after q_req_row={row}"
            )


async def mock_kv_dma(dut, k_int, v_int, stats, stop):
    """
    Mock DMA for K/V tile requests.

    Expected protocol:
      - core asserts kv_req_valid/kv_req_start/kv_req_len
      - DMA accepts with kv_req_ready
      - DMA later returns k_tile/v_tile with kv_data_valid
      - core accepts with kv_data_ready
    """
    dut.kv_req_ready.value = 0
    dut.kv_data_valid.value = 0

    while not stop["value"]:
        await RisingEdge(dut.clk)

        if not is_one(dut.rst_n):
            dut.kv_req_ready.value = 0
            dut.kv_data_valid.value = 0
            continue

        # Idle state: ready to accept one K/V tile request.
        dut.kv_req_ready.value = 1

        if is_one(dut.kv_req_valid) and is_one(dut.kv_req_ready):
            start_row = get_int(dut.kv_req_start, "kv_req_start")

            if has_signal(dut, "kv_req_len"):
                req_len = get_int(dut.kv_req_len, "kv_req_len")
            else:
                req_len = BK

            assert 0 <= start_row < S_LEN, (
                f"kv_req_start out of range: {start_row}"
            )

            assert 1 <= req_len <= BK, (
                f"kv_req_len out of range: {req_len}"
            )

            assert start_row + req_len <= S_LEN, (
                f"K/V tile out of bounds: "
                f"start={start_row}, len={req_len}, S_LEN={S_LEN}"
            )

            stats["kv_reqs"] += 1
            stats["kv_tiles"].append((start_row, req_len))

            # Stop accepting new K/V request while serving this one.
            dut.kv_req_ready.value = 0

            for _ in range(KV_READ_LATENCY):
                await RisingEdge(dut.clk)

            drive_kv_tile(dut, k_int, v_int, start_row, req_len)
            dut.kv_data_valid.value = 1

            accepted = False

            for _ in range(4000):
                await RisingEdge(dut.clk)

                if not is_one(dut.rst_n):
                    break

                if is_one(dut.kv_data_ready):
                    accepted = True
                    break

            dut.kv_data_valid.value = 0

            assert accepted, (
                f"Timeout waiting for kv_data_ready after "
                f"kv_req_start={start_row}, kv_req_len={req_len}"
            )


async def mock_o_sink(dut, o_int, seen_rows, stats, stop):
    """
    Mock DMA output receiver.

    Keeps o_ready high and captures O rows.
    """
    dut.o_ready.value = 0

    while not stop["value"]:
        await RisingEdge(dut.clk)

        if not is_one(dut.rst_n):
            dut.o_ready.value = 0
            continue

        dut.o_ready.value = 1

        if is_one(dut.o_valid) and is_one(dut.o_ready):
            row = capture_o_row(dut, o_int, seen_rows)

            stats["o_rows"].append(row)
            stats["o_count"] += 1

            dut._log.info(f"Captured O row {row}")


# ---------------------------------------------------------------------
# Main test
# ---------------------------------------------------------------------

@cocotb.test()
async def test_flash_core_against_golden_hex(dut):
    """
    flash_core numerical correctness test.

    This test:
      - loads Q/K/V/golden_o from tb/vectors/*.hex
      - feeds Q/K/V into flash_core through mock DMA handshakes
      - captures RTL O rows
      - compares RTL output against golden_o.hex using MAE/MaxE thresholds

    This is a core-level test:
      - it does NOT test AXI4-Lite registers
      - it does NOT test AXI master address generation
      - those belong in test_axi_lite.py and test_end_to_end.py
    """

    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())

    drive_input_defaults(dut)

    # Load existing vectors. Do not regenerate.
    Q_float, K_float, V_float, O_golden_float = cmp.load_qkv_and_golden()

    Q_int = cmp.float_to_q88_int(Q_float)
    K_int = cmp.float_to_q88_int(K_float)
    V_int = cmp.float_to_q88_int(V_float)

    o_rtl_int = np.zeros((S_LEN, D_MODEL), dtype=np.int64)
    seen_rows = np.zeros((S_LEN,), dtype=bool)

    await reset_dut(dut)

    dut._log.info("Starting flash_core golden correctness test")

    # Reset sanity.
    assert not is_one(dut.done), (
        f"done should be 0 after reset, got done={dut.done.value}"
    )

    assert not is_one(dut.busy), (
        f"busy should be 0 after reset, got busy={dut.busy.value}"
    )

    if has_signal(dut, "error"):
        assert not is_one(dut.error), (
            f"error should be 0 after reset, got error={dut.error.value}"
        )

    # Program core config.
    dut.causal_en.value = 1
    dut.neg_large.value = NEG_LARGE_Q8_8
    dut.scale.value = SCALE_Q8_8

    stats = {
        "q_reqs": 0,
        "q_rows": [],
        "kv_reqs": 0,
        "kv_tiles": [],
        "o_count": 0,
        "o_rows": [],
    }

    stop = {"value": False}

    tasks = [
        cocotb.start_soon(mock_q_dma(dut, Q_int, stats, stop)),
        cocotb.start_soon(mock_kv_dma(dut, K_int, V_int, stats, stop)),
        cocotb.start_soon(mock_o_sink(dut, o_rtl_int, seen_rows, stats, stop)),
    ]

    observed_busy = False
    done_cycle = None

    try:
        await pulse_start(dut)

        for cycle in range(TIMEOUT_CYCLES):
            await RisingEdge(dut.clk)

            if is_one(dut.busy):
                observed_busy = True

            if has_signal(dut, "error") and is_one(dut.error):
                raise AssertionError(f"flash_core asserted error at cycle {cycle}")

            if done_cycle is None and is_one(dut.done):
                done_cycle = cycle

            # Wait until both DONE and all O rows have been captured.
            if done_cycle is not None and int(np.sum(seen_rows)) == S_LEN:
                break

        assert done_cycle is not None, (
            f"Timeout waiting for flash_core.done after {TIMEOUT_CYCLES} cycles. "
            f"q_reqs={stats['q_reqs']}, "
            f"kv_reqs={stats['kv_reqs']}, "
            f"o_rows={int(np.sum(seen_rows))}"
        )

        assert observed_busy, (
            "busy was never observed high after START"
        )

        assert stats["q_reqs"] >= S_LEN, (
            f"Expected at least {S_LEN} Q row requests, got {stats['q_reqs']}"
        )

        assert stats["kv_reqs"] > 0, (
            "Expected at least one K/V tile request, got 0"
        )

        captured_rows = int(np.sum(seen_rows))

        assert captured_rows == S_LEN, (
            f"Expected {S_LEN} captured O rows, got {captured_rows}. "
            f"Missing rows sample="
            f"{np.where(~seen_rows)[0][:32].tolist()}"
        )

        # Main RTL-vs-golden error check.
        o_rtl_float = cmp.int_to_q88_float(o_rtl_int)

        result = cmp.check_error(
            O_golden_float,
            o_rtl_float,
            mae_limit=MAE_LIMIT,
            maxe_limit=MAXE_LIMIT,
        )

        dut._log.info(
            "RTL flash_core error report: "
            f"MAE={result['mean_abs_error']:.6f}, "
            f"MaxE={result['max_abs_error']:.6f}, "
            f"limits=({MAE_LIMIT}, {MAXE_LIMIT})"
        )

        assert result["passed"], (
            "RTL flash_core output does not meet golden error limits: "
            f"MAE={result['mean_abs_error']:.6f} <= {MAE_LIMIT}, "
            f"MaxE={result['max_abs_error']:.6f} <= {MAXE_LIMIT}"
        )

        # Causal mask corner sanity:
        # For row i=0, only j=0 is visible, so O[0] should be close to V[0].
        # This is a strong smoke check for causal behavior.
        row0_vs_v0 = np.abs(o_rtl_float[0] - V_float[0])
        row0_max_err = float(np.max(row0_vs_v0))
        row0_mean_err = float(np.mean(row0_vs_v0))

        dut._log.info(
            "Causal row-0 sanity check: "
            f"mean(|O[0]-V[0]|)={row0_mean_err:.6f}, "
            f"max(|O[0]-V[0]|)={row0_max_err:.6f}"
        )

        assert row0_max_err <= MAXE_LIMIT, (
            "Causal mask corner failed for row 0. "
            "When causal_en=1, row i=0 should only attend to j=0, "
            f"so O[0] should be close to V[0]. "
            f"max(|O[0]-V[0]|)={row0_max_err:.6f}, limit={MAXE_LIMIT}"
        )

        dut._log.info(
            "flash_core golden correctness test passed: "
            f"done_cycle={done_cycle}, "
            f"q_reqs={stats['q_reqs']}, "
            f"kv_reqs={stats['kv_reqs']}, "
            f"o_rows={captured_rows}, "
            f"MAE={result['mean_abs_error']:.6f}, "
            f"MaxE={result['max_abs_error']:.6f}"
        )

    finally:
        stop["value"] = True

        for task in tasks:
            try:
                task.kill()
            except Exception:
                pass
