import numpy as np
import config as cfg

# ==========================================
# 🧮 硬件 LUT 数据生成与线性插值模拟
# ==========================================

# 1. EXP LUT (基于 INTERNAL_SCALE)
_exp_min_x_fixed = - (cfg.EXP_LUT_SIZE - 1) * cfg.EXP_STEP_INT
_exp_x_fixed = _exp_min_x_fixed + np.arange(cfg.EXP_LUT_SIZE) * cfg.EXP_STEP_INT
_exp_x_float = _exp_x_fixed / cfg.INTERNAL_SCALE
EXP_LUT_INT = np.round(np.exp(_exp_x_float) * cfg.INTERNAL_SCALE).astype(np.int64)

def hardware_exp_lut_interp(x_fixed):
    """ 模拟硬件带线性插值的 exp 查表 (输入输出皆为 Q16.16) 📈 """
    min_x_lut = - (cfg.EXP_LUT_SIZE - 1) * cfg.EXP_STEP_INT
    
    if x_fixed < min_x_lut:
        return 0
        
    x_clip = np.clip(x_fixed, min_x_lut, 0)
    x_offset = x_clip - min_x_lut 
    
    idx = x_offset // cfg.EXP_STEP_INT
    rem = x_offset % cfg.EXP_STEP_INT
    
    if idx >= cfg.EXP_LUT_SIZE - 1:
        idx = cfg.EXP_LUT_SIZE - 2
        rem = cfg.EXP_STEP_INT
        
    idx, rem = int(idx), int(rem)
    y0, y1 = EXP_LUT_INT[idx], EXP_LUT_INT[idx + 1]
    
    return y0 + ((y1 - y0) * rem + (cfg.EXP_STEP_INT // 2)) // cfg.EXP_STEP_INT

# 2. 倒数 LUT (1/x) (基于 INTERNAL_SCALE)
_recip_min_l_fixed = 1 * cfg.INTERNAL_SCALE
_recip_x_fixed = _recip_min_l_fixed + np.arange(cfg.RECIPROCAL_LUT_SIZE) * cfg.RECIPROCAL_STEP_INT
_recip_x_float = _recip_x_fixed / cfg.INTERNAL_SCALE

RECIPROCAL_LUT_INT = np.round((1.0 / _recip_x_float) * cfg.INTERNAL_SCALE).astype(np.int64)

def hardware_reciprocal_lut_interp(l_fixed):
    """ 模拟硬件带线性插值的倒数查表 (输入输出皆为 Q16.16) 📉 """
    min_l = 1 * cfg.INTERNAL_SCALE
    max_l_lut = min_l + (cfg.RECIPROCAL_LUT_SIZE - 1) * cfg.RECIPROCAL_STEP_INT
    
    l_clip = np.clip(l_fixed, min_l, max_l_lut)
    l_offset = l_clip - min_l
    
    idx = l_offset // cfg.RECIPROCAL_STEP_INT
    rem = l_offset % cfg.RECIPROCAL_STEP_INT
    
    if idx >= cfg.RECIPROCAL_LUT_SIZE - 1:
        idx = cfg.RECIPROCAL_LUT_SIZE - 2
        rem = cfg.RECIPROCAL_STEP_INT
        
    idx, rem = int(idx), int(rem)
    y0, y1 = RECIPROCAL_LUT_INT[idx], RECIPROCAL_LUT_INT[idx + 1]
    
    return y0 + ((y1 - y0) * rem + (cfg.RECIPROCAL_STEP_INT // 2)) // cfg.RECIPROCAL_STEP_INT

# ==========================================
# ⚙️ 究极定点化注意力计算核心
# ==========================================
def flash_attn_fixed_sim(Q_fixed, K_fixed, V_fixed):
    S, D, BK = cfg.S_LEN, cfg.D_MODEL, cfg.BK
    O_fixed_out = np.zeros((S, D), dtype=np.int64)

    for i in range(S):
        qi = Q_fixed[i:i+1, :] 
        
        # m_fixed 初始值在后续计算中会被当做 Q16.16 减去，用 NEG_LARGE_INT 非常安全 🛡️
        m_fixed = cfg.NEG_LARGE_INT 
        # l_fixed 和 acc_fixed 初始化为 0，它们将全程保持 Q16.16 精度！
        l_fixed = 0
        acc_fixed = np.zeros((1, D), dtype=np.int64)

        for j_start in range(0, S, BK):
            j_end = j_start + BK
            ki_tile = K_fixed[j_start:j_end, :]
            vi_tile = V_fixed[j_start:j_end, :]

            # qi (Q8.8) * ki (Q8.8) = raw_qk_dot (Q16.16)
            raw_qk_dot_16_16 = np.dot(qi, ki_tile.T)
            # raw_qk_dot (Q16.16) * ATTN_SCALE (Q16.16) = Q32.32
            # 除以 INTERNAL_SCALE (右移 16 位) = qk_dot_fixed (Q16.16)
            qk_dot_fixed = (raw_qk_dot_16_16 * cfg.ATTN_SCALE_INT) // cfg.INTERNAL_SCALE
            
            # 掩码
            for j_idx in range(j_start, j_end):
                if j_idx > i:
                    qk_dot_fixed[0, j_idx - j_start] = cfg.NEG_LARGE_INT

            m_tile_fixed = np.max(qk_dot_fixed)
            m_new_fixed = max(m_fixed, m_tile_fixed)
            
            # alpha_fixed 查表输出 Q16.16
            alpha_fixed = hardware_exp_lut_interp(m_fixed - m_new_fixed)
            
            exp_qk_fixed = np.zeros_like(qk_dot_fixed)
            for r in range(qk_dot_fixed.shape[0]):
                for c in range(qk_dot_fixed.shape[1]):
                    # exp_qk_fixed 查表输出 Q16.16
                    exp_qk_fixed[r, c] = hardware_exp_lut_interp(qk_dot_fixed[r, c] - m_new_fixed)
            
            # 🚀 核心修正 1：l_fixed 全程 Q16.16 无损累加！
            # l_fixed (Q16.16) * alpha (Q16.16) = Q32.32 -> 恢复到 Q16.16 需要除以 INTERNAL_SCALE
            l_fixed = (l_fixed * alpha_fixed) // cfg.INTERNAL_SCALE + np.sum(exp_qk_fixed)
            
            acc_scaled = (acc_fixed * alpha_fixed) // cfg.INTERNAL_SCALE
            
            # 🚀 核心修正 2：acc_fixed 全程 Q16.16 无损累加！
            # exp_qk (Q16.16) * vi_tile (Q8.8) = Q24.24 -> 恢复到 Q16.16 需要除以 SCALE_FACTOR (8位)
            exp_v_dot = np.dot(exp_qk_fixed, vi_tile) // cfg.SCALE_FACTOR
            acc_fixed = acc_scaled + exp_v_dot
            
            m_fixed = m_new_fixed 

        # recip_l_fixed 查表输出 Q16.16
        recip_l_fixed = hardware_reciprocal_lut_interp(l_fixed)
        
        # 🚀 核心修正 3：最终降维输出！
        # acc_fixed (Q16.16) * recip (Q16.16) = Q32.32
        # 要得到 Q8.8 输出，必须除以 2^24 (即 INTERNAL_SCALE * SCALE_FACTOR)
        o_row_fixed = (acc_fixed * recip_l_fixed) // (cfg.INTERNAL_SCALE * cfg.SCALE_FACTOR)
        
        O_fixed_out[i:i+1, :] = np.clip(o_row_fixed, cfg.MIN_VAL, cfg.MAX_VAL)

    return O_fixed_out