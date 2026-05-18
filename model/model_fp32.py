# model_fp32.py
import numpy as np
import config as cfg

def standard_attention_fp32(Q, K, V):
    """
    计算标准的浮点数 Scaled Dot-Product Attention (带 Causal Mask)
    """
    # 1. 算点积并缩放: Q * K^T / sqrt(d)
    scale = 1.0 / np.sqrt(cfg.D_MODEL)
    scores = np.dot(Q, K.T) * scale
    
    # 2. 加上因果掩码 (Causal Mask)
    # 利用配置中的 S_LEN 找到右上角
    upper_triangle_indices = np.triu_indices(cfg.S_LEN, 1)
    scores[upper_triangle_indices] = -float('inf') 
    
    # 3. 计算 Softmax (减去最大值防指数爆炸)
    scores_max = np.max(scores, axis=1, keepdims=True)
    exp_scores = np.exp(scores - scores_max)
    
    sum_exp_scores = np.sum(exp_scores, axis=1, keepdims=True)
    probabilities = exp_scores / sum_exp_scores
    
    # 4. 乘以 V 得到最终输出 O
    O = np.dot(probabilities, V)
    
    return O

if __name__ == "__main__":
    print("🚀 正在生成随机的 Q, K, V 测试数据...")
    test_Q = np.random.randn(cfg.S_LEN, cfg.D_MODEL)
    test_K = np.random.randn(cfg.S_LEN, cfg.D_MODEL)
    test_V = np.random.randn(cfg.S_LEN, cfg.D_MODEL)
    
    print("🧮 正在计算 FP32 的正确答案...")
    golden_O = standard_attention_fp32(test_Q, test_K, test_V)
    
    print("✅ 计算完成！输出矩阵 O 的形状是:", golden_O.shape)
    
    # 👇 我们在这里加上你提到的核心验证逻辑 👇
    
    v_top_left = test_V[0, 0]
    o_top_left = golden_O[0, 0]
    
    print("\n🔍 --- 开始关键数值验证 --- 🔍")
    print(f"📦 原始 V 矩阵左上角的数字是: {v_top_left}")
    print(f"🎯 输出 O 矩阵左上角的数字是: {o_top_left}")
    
    # 🤖 自动判断逻辑：使用 np.isclose 容忍浮点数的微小误差 (atol=1e-6)
    is_equal = np.isclose(v_top_left, o_top_left, atol=1e-6)
    
    if is_equal:
        print("🎉 自动检查通过：O 和 V 的左上角数字完美相等！Causal Mask 逻辑绝对正确！😎")
    else:
        print("🚨 警告警告：O 和 V 的左上角数字竟然不相等！代码里一定潜伏着 Bug！🐛")
        
    # 🛑 严谨的程序通常会用 assert 来强行拦截错误，如果不相等程序会直接红字报错退出！
    assert is_equal, "致命错误：第一行的注意力未能完全集中在自己身上，Mask 失败！"