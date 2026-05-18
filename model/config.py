import math

# ==========================================
# 🎛️ 硬件与算法核心参数
# ==========================================
S_LEN = 256       
D_MODEL = 64      
BK = 16           

TOTAL_BITS = 16   
FRAC_BITS = 8     

# 🚀 硬件级真·优化：微调表格容量，强行让步长变成 2 的幂次方！省下物理除法器！
EXP_LUT_SIZE = 257           # 原 256。改后步长完美等于 2048 (即 2^11) 🎯
RECIPROCAL_LUT_SIZE = 4081   # 实事求是扩大容量保精度！改后步长完美等于 4096 (即 2^12) 🎯
RANDOM_SEED = 42             
TEST_SCALE = 50.0            

# ==========================================
# 🤖 自动推导参数 
# ==========================================
SCALE_FACTOR = 1 << FRAC_BITS                   
MAX_VAL = (1 << (TOTAL_BITS - 1)) - 1           
MIN_VAL = -(1 << (TOTAL_BITS - 1))              
MASK_VAL = (1 << TOTAL_BITS) - 1                
SIGN_BIT_VAL = 1 << (TOTAL_BITS - 1)            
HEX_WIDTH = TOTAL_BITS // 4                     

# 🚀 内部运算的高精度缩放因子 (Q16.16 绝不动摇！)
INTERNAL_SCALE = 1 << 16

# 32位累加器绝对下限，完美充当深渊掩码
NEG_LARGE_INT = -2147483648                     

ATTN_SCALE_FLOAT = 1.0 / math.sqrt(D_MODEL)     
# 常数放大到 Q16.16
ATTN_SCALE_INT = int(round(ATTN_SCALE_FLOAT * INTERNAL_SCALE)) 

# ==========================================
# 📐 步长预计算 (全线基于 INTERNAL_SCALE) 与 硬件安全断言
# ==========================================
EXP_STEP_FLOAT = 8.0 / (EXP_LUT_SIZE - 1)
EXP_STEP_INT = max(1, int(round(EXP_STEP_FLOAT * INTERNAL_SCALE)))
# 🛡️ 硬件保命断言：确保 Verilog 里可以直接用 >> 11 替代除法！
assert EXP_STEP_INT == 2048, f"🚨 致命错误：EXP步长不是2048，当前为 {EXP_STEP_INT}，会导致综合出物理除法器！"

RECIPROCAL_STEP_FLOAT = (float(S_LEN) - 1.0) / (RECIPROCAL_LUT_SIZE - 1)
RECIPROCAL_STEP_INT = max(1, int(round(RECIPROCAL_STEP_FLOAT * INTERNAL_SCALE)))
# 🛡️ 硬件保命断言：确保 Verilog 里可以直接用 >> 12 替代除法！
assert RECIPROCAL_STEP_INT == 4096, f"🚨 致命错误：倒数步长不是4096，当前为 {RECIPROCAL_STEP_INT}，会导致综合出物理除法器！"