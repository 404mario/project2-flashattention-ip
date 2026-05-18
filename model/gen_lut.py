# model/gen_lut.py

import os
import sys
import argparse
import numpy as np


# ---------------------------------------------------------------------
# Path setup
# ---------------------------------------------------------------------

MODEL_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(MODEL_DIR)

if MODEL_DIR not in sys.path:
    sys.path.insert(0, MODEL_DIR)

import config as cfg

# Critical:
#   These are the exact LUT arrays used by model_fixed.py.
#   Do NOT regenerate independently as the main source of truth.
from model_fixed import EXP_LUT_INT, RECIPROCAL_LUT_INT


DEFAULT_LUT_DIR = os.path.join(MODEL_DIR, "luts")
DEFAULT_RTL_INCLUDE_DIR = os.path.join(PROJECT_ROOT, "rtl", "include")

EXP_LUT_FILE = "exp_lut_q16_16.hex"
RECIPROCAL_LUT_FILE = "reciprocal_lut_q16_16.hex"
PARAM_SVH_FILE = "flash_lut_params.svh"


# ---------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------

def ensure_dir(path):
    os.makedirs(path, exist_ok=True)


def u32_hex(value):
    return f"{int(value) & 0xFFFFFFFF:08X}"


def write_hex_file(path, values):
    """
    Write one unsigned 32-bit hex value per line.

    The LUT values themselves are Q16.16 non-negative integers.
    """
    with open(path, "w") as f:
        for v in values:
            f.write(u32_hex(v) + "\n")


def read_hex_file(path):
    values = []

    with open(path, "r") as f:
        for line in f:
            s = line.strip()
            if not s:
                continue
            values.append(int(s, 16) & 0xFFFFFFFF)

    return np.array(values, dtype=np.int64)


# ---------------------------------------------------------------------
# Strict validation
# ---------------------------------------------------------------------

def recompute_exp_lut_same_as_model_fixed():
    """
    Independent recomputation using the exact formula currently in model_fixed.py.

    This is only used as a guardrail. The generated file still uses
    model_fixed.EXP_LUT_INT as the source of truth.
    """
    exp_min_x_fixed = -(cfg.EXP_LUT_SIZE - 1) * cfg.EXP_STEP_INT

    exp_x_fixed = (
        exp_min_x_fixed
        + np.arange(cfg.EXP_LUT_SIZE, dtype=np.int64) * cfg.EXP_STEP_INT
    )

    exp_x_float = exp_x_fixed / cfg.INTERNAL_SCALE

    return np.round(np.exp(exp_x_float) * cfg.INTERNAL_SCALE).astype(np.int64)


def recompute_reciprocal_lut_same_as_model_fixed():
    """
    Independent recomputation using the exact formula currently in model_fixed.py.

    This is only used as a guardrail. The generated file still uses
    model_fixed.RECIPROCAL_LUT_INT as the source of truth.
    """
    recip_min_l_fixed = 1 * cfg.INTERNAL_SCALE

    recip_x_fixed = (
        recip_min_l_fixed
        + np.arange(cfg.RECIPROCAL_LUT_SIZE, dtype=np.int64)
        * cfg.RECIPROCAL_STEP_INT
    )

    recip_x_float = recip_x_fixed / cfg.INTERNAL_SCALE

    return np.round((1.0 / recip_x_float) * cfg.INTERNAL_SCALE).astype(np.int64)


def validate_config():
    """
    These checks protect the RTL indexing assumptions.

    Current model_fixed.py assumes:
      EXP_STEP_INT        = 2048 = 2^11
      RECIPROCAL_STEP_INT = 4096 = 2^12
    """
    assert cfg.INTERNAL_SCALE == (1 << 16), (
        f"INTERNAL_SCALE must be 2^16 for Q16.16, got {cfg.INTERNAL_SCALE}"
    )

    assert cfg.EXP_LUT_SIZE == 257, (
        f"EXP_LUT_SIZE changed. Expected 257, got {cfg.EXP_LUT_SIZE}"
    )

    assert cfg.EXP_STEP_INT == 2048, (
        f"EXP_STEP_INT changed. Expected 2048 for >> 11, got {cfg.EXP_STEP_INT}"
    )

    assert cfg.RECIPROCAL_LUT_SIZE == 4081, (
        f"RECIPROCAL_LUT_SIZE changed. Expected 4081, got {cfg.RECIPROCAL_LUT_SIZE}"
    )

    assert cfg.RECIPROCAL_STEP_INT == 4096, (
        f"RECIPROCAL_STEP_INT changed. Expected 4096 for >> 12, "
        f"got {cfg.RECIPROCAL_STEP_INT}"
    )


def validate_luts_match_model_fixed():
    """
    Validate that imported model_fixed LUTs are exactly what model_fixed.py
    formula generates today.

    If this fails, someone changed model_fixed.py or config.py in a way that
    must be reviewed before regenerating RTL LUT files.
    """
    exp_from_model = np.asarray(EXP_LUT_INT, dtype=np.int64)
    recip_from_model = np.asarray(RECIPROCAL_LUT_INT, dtype=np.int64)

    exp_recomputed = recompute_exp_lut_same_as_model_fixed()
    recip_recomputed = recompute_reciprocal_lut_same_as_model_fixed()

    assert exp_from_model.shape == (cfg.EXP_LUT_SIZE,), (
        f"EXP_LUT_INT shape mismatch: expected {(cfg.EXP_LUT_SIZE,)}, "
        f"got {exp_from_model.shape}"
    )

    assert recip_from_model.shape == (cfg.RECIPROCAL_LUT_SIZE,), (
        f"RECIPROCAL_LUT_INT shape mismatch: "
        f"expected {(cfg.RECIPROCAL_LUT_SIZE,)}, got {recip_from_model.shape}"
    )

    assert np.array_equal(exp_from_model, exp_recomputed), (
        "EXP_LUT_INT does not match the model_fixed.py recomputation. "
        "Do not generate RTL LUTs until this is resolved."
    )

    assert np.array_equal(recip_from_model, recip_recomputed), (
        "RECIPROCAL_LUT_INT does not match the model_fixed.py recomputation. "
        "Do not generate RTL LUTs until this is resolved."
    )

    # Endpoint checks.
    assert abs(int(exp_from_model[-1]) - cfg.INTERNAL_SCALE) <= 1, (
        f"exp(0) endpoint should be ~{cfg.INTERNAL_SCALE}, "
        f"got {int(exp_from_model[-1])}"
    )

    assert abs(int(recip_from_model[0]) - cfg.INTERNAL_SCALE) <= 1, (
        f"1/1 endpoint should be ~{cfg.INTERNAL_SCALE}, "
        f"got {int(recip_from_model[0])}"
    )

    assert abs(int(recip_from_model[-1]) - 256) <= 1, (
        f"1/256 endpoint should be ~256, got {int(recip_from_model[-1])}"
    )

    assert np.all(np.diff(exp_from_model) >= 0), (
        "EXP_LUT_INT must be monotonic nondecreasing"
    )

    assert np.all(np.diff(recip_from_model) <= 0), (
        "RECIPROCAL_LUT_INT must be monotonic nonincreasing"
    )


def roundtrip_check(path, expected_values, name):
    actual = read_hex_file(path)
    expected = np.asarray(expected_values, dtype=np.int64) & 0xFFFFFFFF

    assert np.array_equal(actual, expected), (
        f"{name} hex roundtrip mismatch. "
        "The file written to disk is not identical to the model_fixed.py LUT."
    )


# ---------------------------------------------------------------------
# Optional RTL parameter include
# ---------------------------------------------------------------------

def write_lut_param_svh(path):
    """
    Generate parameters that help RTL stay aligned with config.py.

    The actual LUT contents are still loaded from .hex files.
    """
    exp_min_x_fixed = -(cfg.EXP_LUT_SIZE - 1) * cfg.EXP_STEP_INT

    recip_min_fixed = cfg.INTERNAL_SCALE
    recip_max_fixed = (
        cfg.INTERNAL_SCALE
        + (cfg.RECIPROCAL_LUT_SIZE - 1) * cfg.RECIPROCAL_STEP_INT
    )

    content = f"""// Auto-generated by model/gen_lut.py
// Source of truth: model_fixed.py EXP_LUT_INT and RECIPROCAL_LUT_INT.
// Do not edit by hand.

`ifndef FLASH_LUT_PARAMS_SVH
`define FLASH_LUT_PARAMS_SVH

localparam int LUT_DATA_W = 32;
localparam int LUT_FRAC_W = 16;

// EXP LUT:
//   input  x: Q16.16
//   range  x: [-8.0, 0.0]
//   output y: Q16.16 exp(x)
localparam int EXP_LUT_SIZE    = {cfg.EXP_LUT_SIZE};
localparam int EXP_STEP_INT    = {cfg.EXP_STEP_INT};
localparam int EXP_STEP_SHIFT  = 11;
localparam int EXP_MIN_X_FIXED = {exp_min_x_fixed};
localparam int EXP_MAX_X_FIXED = 0;

// RECIPROCAL LUT:
//   input  l: Q16.16
//   range  l: [1.0, 256.0]
//   output y: Q16.16 1/l
localparam int RECIPROCAL_LUT_SIZE    = {cfg.RECIPROCAL_LUT_SIZE};
localparam int RECIPROCAL_STEP_INT    = {cfg.RECIPROCAL_STEP_INT};
localparam int RECIPROCAL_STEP_SHIFT  = 12;
localparam int RECIPROCAL_MIN_FIXED   = {recip_min_fixed};
localparam int RECIPROCAL_MAX_FIXED   = {recip_max_fixed};

`endif
"""

    with open(path, "w") as f:
        f.write(content)


# ---------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------

def print_summary(exp_lut, recip_lut, exp_path, recip_path, svh_path=None):
    exp_min_x_fixed = -(cfg.EXP_LUT_SIZE - 1) * cfg.EXP_STEP_INT
    exp_max_x_fixed = 0

    recip_min_fixed = cfg.INTERNAL_SCALE
    recip_max_fixed = (
        cfg.INTERNAL_SCALE
        + (cfg.RECIPROCAL_LUT_SIZE - 1) * cfg.RECIPROCAL_STEP_INT
    )

    print("\n================ LUT Generation Summary ================")

    print("\n[EXP LUT]")
    print("  source             : model_fixed.EXP_LUT_INT")
    print(f"  output file         : {exp_path}")
    print(f"  size                : {len(exp_lut)}")
    print(f"  x fixed range       : [{exp_min_x_fixed}, {exp_max_x_fixed}]")
    print(
        f"  x float range       : "
        f"[{exp_min_x_fixed / cfg.INTERNAL_SCALE:.6f}, "
        f"{exp_max_x_fixed / cfg.INTERNAL_SCALE:.6f}]"
    )
    print(f"  step fixed          : {cfg.EXP_STEP_INT}")
    print("  step shift          : 11")
    print(f"  first               : {int(exp_lut[0])} / 0x{u32_hex(exp_lut[0])}")
    print(f"  last                : {int(exp_lut[-1])} / 0x{u32_hex(exp_lut[-1])}")

    print("\n[RECIPROCAL LUT]")
    print("  source             : model_fixed.RECIPROCAL_LUT_INT")
    print(f"  output file         : {recip_path}")
    print(f"  size                : {len(recip_lut)}")
    print(f"  l fixed range       : [{recip_min_fixed}, {recip_max_fixed}]")
    print(
        f"  l float range       : "
        f"[{recip_min_fixed / cfg.INTERNAL_SCALE:.6f}, "
        f"{recip_max_fixed / cfg.INTERNAL_SCALE:.6f}]"
    )
    print(f"  step fixed          : {cfg.RECIPROCAL_STEP_INT}")
    print("  step shift          : 12")
    print(f"  first               : {int(recip_lut[0])} / 0x{u32_hex(recip_lut[0])}")
    print(f"  last                : {int(recip_lut[-1])} / 0x{u32_hex(recip_lut[-1])}")

    if svh_path is not None:
        print("\n[SVH PARAMS]")
        print(f"  output file         : {svh_path}")

    print("\n✅ Generated LUT files are bit-identical to model_fixed.py arrays.")
    print("========================================================\n")


# ---------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description=(
            "Dump the exact LUT arrays used by model_fixed.py into RTL-friendly "
            "$readmemh hex files."
        )
    )

    parser.add_argument(
        "--lut-dir",
        default=DEFAULT_LUT_DIR,
        help=f"Directory for generated LUT hex files. Default: {DEFAULT_LUT_DIR}",
    )

    parser.add_argument(
        "--rtl-include-dir",
        default=DEFAULT_RTL_INCLUDE_DIR,
        help=(
            "Directory for generated SystemVerilog parameter include file. "
            f"Default: {DEFAULT_RTL_INCLUDE_DIR}"
        ),
    )

    parser.add_argument(
        "--no-svh",
        action="store_true",
        help="Do not generate flash_lut_params.svh.",
    )

    parser.add_argument(
        "--quiet",
        action="store_true",
        help="Suppress summary output.",
    )

    args = parser.parse_args()

    validate_config()
    validate_luts_match_model_fixed()

    exp_lut = np.asarray(EXP_LUT_INT, dtype=np.int64)
    recip_lut = np.asarray(RECIPROCAL_LUT_INT, dtype=np.int64)

    ensure_dir(args.lut_dir)

    exp_path = os.path.join(args.lut_dir, EXP_LUT_FILE)
    recip_path = os.path.join(args.lut_dir, RECIPROCAL_LUT_FILE)

    write_hex_file(exp_path, exp_lut)
    write_hex_file(recip_path, recip_lut)

    roundtrip_check(exp_path, exp_lut, "EXP LUT")
    roundtrip_check(recip_path, recip_lut, "RECIPROCAL LUT")

    svh_path = None

    if not args.no_svh:
        ensure_dir(args.rtl_include_dir)
        svh_path = os.path.join(args.rtl_include_dir, PARAM_SVH_FILE)
        write_lut_param_svh(svh_path)

    if not args.quiet:
        print_summary(exp_lut, recip_lut, exp_path, recip_path, svh_path)


if __name__ == "__main__":
    main()
