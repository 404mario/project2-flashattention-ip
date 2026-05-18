# model/compare_models.py

import numpy as np
import config as cfg

# 继续复用你现有 gen_vectors.py / model_fixed.py 里面的函数和路径
from gen_vectors import hex_to_float_fixed, Q_FILE, K_FILE, V_FILE, O_FILE
from model_fixed import flash_attn_fixed_sim


MAE_LIMIT_DEFAULT = 0.03
MAXE_LIMIT_DEFAULT = 0.10


def load_qkv_and_golden():
    """
    Load Q/K/V/golden O from existing .hex files.

    Returns:
        Q_float:        shape [S_LEN, D_MODEL], float
        K_float:        shape [S_LEN, D_MODEL], float
        V_float:        shape [S_LEN, D_MODEL], float
        O_golden_float: shape [S_LEN, D_MODEL], float

    Note:
        This function does NOT regenerate vectors.
        It only reads the already-generated hex files.
    """
    shape = (cfg.S_LEN, cfg.D_MODEL)

    Q_float = hex_to_float_fixed(Q_FILE, shape)
    K_float = hex_to_float_fixed(K_FILE, shape)
    V_float = hex_to_float_fixed(V_FILE, shape)
    O_golden_float = hex_to_float_fixed(O_FILE, shape)

    return Q_float, K_float, V_float, O_golden_float


def float_to_q88_int(x):
    """
    Convert float array to signed Q8.8 int array.

    Example:
        0.125 -> 32
        -1.0  -> -256
    """
    arr = np.asarray(x, dtype=np.float64)
    out = np.round(arr * cfg.SCALE_FACTOR).astype(np.int64)
    out = np.clip(out, -32768, 32767)
    return out


def int_to_q88_float(x):
    """
    Convert signed Q8.8 integer array to float array.
    """
    arr = np.asarray(x, dtype=np.int64)
    return arr.astype(np.float64) / float(cfg.SCALE_FACTOR)


def compute_error(o_golden_float, o_test_float):
    """
    Compute MAE and MaxE between golden output and tested output.
    """
    golden = np.asarray(o_golden_float, dtype=np.float64)
    test = np.asarray(o_test_float, dtype=np.float64)

    assert golden.shape == test.shape, (
        f"Shape mismatch: golden shape={golden.shape}, test shape={test.shape}"
    )

    abs_diff = np.abs(golden - test)

    return {
        "mean_abs_error": float(np.mean(abs_diff)),
        "max_abs_error": float(np.max(abs_diff)),
        "abs_diff": abs_diff,
    }


def check_error(
    o_golden_float,
    o_test_float,
    mae_limit=MAE_LIMIT_DEFAULT,
    maxe_limit=MAXE_LIMIT_DEFAULT,
):
    """
    Check output against error thresholds.

    Returns a dictionary:
        {
            passed,
            mean_abs_error,
            max_abs_error,
            mae_limit,
            maxe_limit,
            abs_diff
        }
    """
    result = compute_error(o_golden_float, o_test_float)

    mean_err = result["mean_abs_error"]
    max_err = result["max_abs_error"]

    result["mae_limit"] = float(mae_limit)
    result["maxe_limit"] = float(maxe_limit)
    result["passed"] = (mean_err <= mae_limit) and (max_err <= maxe_limit)

    return result


def compare_fixed_model_against_golden(
    mae_limit=MAE_LIMIT_DEFAULT,
    maxe_limit=MAXE_LIMIT_DEFAULT,
):
    """
    Original compare_models.py behavior:

        golden_o.hex
        vs
        model_fixed.flash_attn_fixed_sim(Q, K, V)

    This validates the Python fixed-point model.
    """
    Q_float, K_float, V_float, O_golden_float = load_qkv_and_golden()

    Q_int = float_to_q88_int(Q_float)
    K_int = float_to_q88_int(K_float)
    V_int = float_to_q88_int(V_float)

    O_fixed_int = flash_attn_fixed_sim(Q_int, K_int, V_int)
    O_fixed_float = int_to_q88_float(O_fixed_int)

    return check_error(
        O_golden_float,
        O_fixed_float,
        mae_limit=mae_limit,
        maxe_limit=maxe_limit,
    )


def compare_output_int_against_golden(
    o_test_int,
    mae_limit=MAE_LIMIT_DEFAULT,
    maxe_limit=MAXE_LIMIT_DEFAULT,
):
    """
    Compare an external Q8.8 integer output against golden_o.hex.

    This is intended for cocotb tests:
        RTL o_data int16 -> o_test_int -> compare against golden.
    """
    _, _, _, O_golden_float = load_qkv_and_golden()

    o_test_float = int_to_q88_float(o_test_int)

    return check_error(
        O_golden_float,
        o_test_float,
        mae_limit=mae_limit,
        maxe_limit=maxe_limit,
    )


def print_error_report(result, title="误差分析报告"):
    """
    Pretty-print error result dictionary.
    """
    print(f"\n================ 📊 {title} ==================")
    print(
        f"📉 平均绝对误差 (MAE): "
        f"{result['mean_abs_error']:.6f}  "
        f"(标准: <= {result['mae_limit']})"
    )
    print(
        f"📈 最大绝对误差 (MaxE): "
        f"{result['max_abs_error']:.6f}  "
        f"(标准: <= {result['maxe_limit']})"
    )

    print("\n================ 🏆 验收结果判定 ==================")

    if result["passed"]:
        print("🎉🎉🎉 恭喜！双重指标全部 PASS！🏆")
        print("✅ MAE 达标！")
        print("✅ MaxE 达标！")
        print("🚀 定点架构验证通过，可以继续对齐 RTL！")
    else:
        print("🚨🚨🚨 警报！FAIL！误差未满足赛题要求！❌")

        if result["mean_abs_error"] > result["mae_limit"]:
            print(
                f"⚠️ MAE 超标：当前 "
                f"{result['mean_abs_error']:.6f} > {result['mae_limit']}"
            )

        if result["max_abs_error"] > result["maxe_limit"]:
            print(
                f"⚠️ MaxE 超标：当前 "
                f"{result['max_abs_error']:.6f} > {result['maxe_limit']}"
            )


if __name__ == "__main__":
    print("🥊 华山论剑：基于 .hex 弹药库的终极定点对决！\n")
    print("📥 正在从 tb/vectors/ 读取现成的 Q/K/V/golden O...")
    print("🧱 正在运行 model_fixed.py 定点硬件模拟器...")

    result = compare_fixed_model_against_golden()

    print_error_report(result, title="model_fixed.py vs golden_o.hex 误差分析报告")

    if not result["passed"]:
        raise SystemExit(1)
