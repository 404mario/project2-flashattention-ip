# gen_vectors.py
import numpy as np
import os
import sys
import config as cfg
from model_fp32 import standard_attention_fp32


if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")

# --- 📁 局部路径与文件名管理 (遵守 README 规范) ---
BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VECTOR_DIR = os.path.join(BASE_DIR, "tb", "vectors")
Q_FILE = "input_q.hex"
K_FILE = "input_k.hex"
V_FILE = "input_v.hex"
O_FILE = "golden_o.hex"

def float_to_fixed_hex(float_array, filename):
    """
    将浮点数组转换为 Q8.8 格式并保存到指定路径 [cite: 29]
    """
    os.makedirs(VECTOR_DIR, exist_ok=True)
    target_path = os.path.join(VECTOR_DIR, filename)
    
    # 使用 config 中的参数进行量化截断，杜绝硬编码
    fixed_array = np.round(float_array * cfg.SCALE_FACTOR).astype(np.int64)
    fixed_array = np.clip(fixed_array, cfg.MIN_VAL, cfg.MAX_VAL)
    
    with open(target_path, 'w') as f:
        for row in fixed_array:
            for val in row:
                # 动态适配位宽的 hex 转换
                hex_str = f"{val & cfg.MASK_VAL:0{cfg.HEX_WIDTH}X}"
                f.write(hex_str + '\n')
    print(f"📦 向量已入库: {target_path}")

def hex_to_float_fixed(filename, shape):
    """
    从指定路径读取 hex 文件并还原为浮点数
    """
    source_path = os.path.join(VECTOR_DIR, filename)
    with open(source_path, 'r') as f:
        lines = f.readlines()
    
    arr = np.zeros(shape[0] * shape[1])
    for i, line in enumerate(lines):
        val = int(line.strip(), 16)
        if val >= cfg.SIGN_BIT_VAL:
            val -= (cfg.MASK_VAL + 1)
        arr[i] = val / cfg.SCALE_FACTOR
    return arr.reshape(shape)

if __name__ == "__main__":
    np.random.seed(cfg.RANDOM_SEED) 
    
    print(f"🎲 正在生成随机测试数据 (Scale: {cfg.TEST_SCALE})...")
    # 使用 cfg 里的尺寸参数，拒绝硬编码 [cite: 23, 24]
    Q_raw = np.random.randn(cfg.S_LEN, cfg.D_MODEL) * cfg.TEST_SCALE
    K_raw = np.random.randn(cfg.S_LEN, cfg.D_MODEL) * cfg.TEST_SCALE
    V_raw = np.random.randn(cfg.S_LEN, cfg.D_MODEL) * cfg.TEST_SCALE

    # 1. 导出输入数据
    float_to_fixed_hex(Q_raw, Q_FILE)
    float_to_fixed_hex(K_raw, K_FILE)
    float_to_fixed_hex(V_raw, V_FILE)

    # 2. 从文件回读（确保 Golden Model 的输入与硬件完全一致）
    Q_real = hex_to_float_fixed(Q_FILE, (cfg.S_LEN, cfg.D_MODEL))
    K_real = hex_to_float_fixed(K_FILE, (cfg.S_LEN, cfg.D_MODEL))
    V_real = hex_to_float_fixed(V_FILE, (cfg.S_LEN, cfg.D_MODEL))

    # 3. 计算 Golden 答案
    print("🧠 正在调用 FP32 模型生成标准答案...")
    O_fp = standard_attention_fp32(Q_real, K_real, V_real)

    # 4. 导出 Golden 答案
    float_to_fixed_hex(O_fp, O_FILE)

    print(f"\n✅ 弹药库 ( {VECTOR_DIR} ) 已填充完毕！")
