# 4ns 冲刺 + SRAM 调研结论（2026-06-21）

> 背景：`baseline-v2-synthopt` 的 5ns 版（`f185b97`：max树 + ACC_W34）**第四次综合两项硬约束全过**
> （见 `synth/SYNTHESIS_STATUS.md`）。本文记录在此之上**冲 4ns** 的结构性调研，以及 **SRAM 降面积**的
> 可行性结论。**两项最终都未改动已冻结的 5ns RTL**——5ns 是提交基线，本文是研究存档。
>
> 诚实边界：本地（iverilog）只能验 **bit-exact + cycles**；**4ns 的真实时序/面积必须 Genus 跑出才算数**，
> 本文所有时序/面积判断除标注 [实测] 外均为 [推理]/[估算]。

## 1. 为什么 4ns 难（真实 5ns Genus 数据）

第四次 5ns（`f185b97`，报告归档 `synth/reports_ispatial_5.000ns_f185b97_FROZEN/`）：
- 面积 7,870,282 µm² = **1,641,283 门当量（82.1%，余 17.9%）**
- 时序 **0 违例，最差 slack 仅 +5ps MET**
- 唯一报出的关键路径（导线主导）：

```
m_axi_rvalid (顶层输入, input_delay=30%·周期=1500ps@5ns)
  → axi_master_read 纯组合直通 (data=m_axi_rdata, R 通道未寄存)
  → dma_controller 缓冲写译码 (S_PF_V_RECV)
  → v_buf2_reg[9][57][9]/D   (KV 预取影子 V 缓冲)
数据通路 3365ps，含 780ps + 705ps 两段导线延迟 (594fF/739fF 大网)
```

4ns 预算 ≈ 4000 − 1200(input@30%) − 68(setup) − 50(uncert) ≈ 2682ps，需 3365ps → **差 ~685ps（~20%）**。
导线主导 → 加驱动无效，只能寄存切断或结构删除。

## 2. 五路并行子代理调研（全部本地全规模实测，bit-exact 闸门 md5=`01697fe8…`）

| 代理 | 杠杆 | 实测 | 判决 |
|---|---|---|---|
| FA-1 | **寄存 AXI R 通道** `USE_RDATA_REG`（axi_master_read 1-deep skid） | bit-exact；BQ6 +5.19%→**273,263**(<300k)；67 FF；背压注入零丢拍 | ✅ **主修** |
| FA-2 | 删 KV 预取 `USE_KV_PREFETCH=0` | bit-exact；**BQ6=304,333 > 300k FAIL** | ❌ 爆 cycle 闸；且只是"路径改名非修复" |
| FA-3 | DMA 写流水 `USE_WRDATA_PIPE` | ~0 cycle 代价；~74 FF | 🔸 同路冗余切点，留 fallback |
| FA-4 | **切 exp E1 锥** `EXP_SPLIT`（E1a\|E1b） | bit-exact；+32cyc/+0.03% | ✅ **预防第二条路** |
| FA-5 | 面积+SDC+flow 分析 | 微杠杆(`OPT_DROP_MNEW`/`OPT_L_SLACK`)可忽略(0.04%) | ✅ 关键判断见下 |

**关键交叉验证**：FA-2 从"删预取"方向独立得出——删 `v_buf2` 只是改名，因为正常加载路径写 `v_buf` 有**同深度的孪生组合锥**；
正解是**在缓冲写之前寄存 rd_data，一次修好所有孪生、与 BQ 无关、零 cycle 代价**——**这正是 FA-1**。两个代理反向收敛同一修法。

## 3. 建议的 4ns bundle（已本地验证 bit-exact，未综合）

| 改动 | 文件 | 4ns 默认 |
|---|---|---|
| `USE_RDATA_REG` 寄存 AXI R 通道（generate：0=逐字节基线，1=skid） | `rtl/axi/axi_master_read.sv` | **1** |
| `EXP_SPLIT` 切 exp E1 锥（计数 drain，`DRAIN_DEPTH=3+EXP_SPLIT`） | `rtl/core/softmax_combine.sv`(+`flash_core.sv` 串参) | **1** |
| effort 按周期条件化：≤4ns=high，5ns 保持 medium | `synth/genus_ispatial.tcl` | — |
| SDC **不动**（FA-1 寄存后 pin→reg 段已平凡；不收 input_delay 避免"挪门柱"） | — | — |

**叠加态实测**（全规模 S=256 causal，对 golden md5 `01697fe8…`）：

| 配置 | BQ16 cyc | BQ6 cyc | md5 | <300k |
|---|---|---|---|---|
| levers OFF（回归锚） | 109,446 | 259,791 | `01697fe8` | — |
| **USE_RDATA_REG=1 + EXP_SPLIT=1** | 114,566 | **273,295** | `01697fe8` ✅ | ✅ |

两改叠加无交互 bug（+5120 = FA-1 的 +5088 + FA-4 的 +32），bit-exact，cycles 仍 <300k。
**留作 opt-in fallback（默认关、已验 bit-exact）：** `USE_WRDATA_PIPE`、`OPT_DROP_MNEW`、`OPT_L_SLACK`。

> 注：本 bundle 的可运行 RTL 在临时工作区随进程重启丢失；上表的**变更规格 + 实测数完整**，可按此重建后再综合。

## 4. 4ns 可达性诚实判断：~35–45%，且大概率输在面积

- **逻辑深度层面可达**：所有修改 bit-exact、cycles<300k；FA-4 判断无不可约逻辑墙（剩余 34×17 乘法、normalizer 倒数都可继续 bit-exact 切流水）。
- **真正风险是面积**：已占 82.1%，4ns 驱动膨胀 + high effort + 新寄存器可能冲破 200 万门。参考实测先例：8ns→5ns 非核心 DMA/AXI 真实膨胀 **+33.1 万门**，0 违例下不自愈。
- **Fmax 是软分，5ns 已过全部硬闸** → 保底永远在。**打法**：跑一次 high-effort 4ns，**同时看 timing+area**，面积一旦爆立刻退回 5ns。

## 5. SRAM 降面积：调研后**否决**（对本设计是负优化）

赛题 §7 允许片上缓存 K/V 但要求"量化 SRAM 代价"。用所给 `sky130_sram_macros`（OpenRAM，`1rw1r`，最宽字 **128bit**）实测分析：

**根因——SRAM 固定外围开销靠深度摊薄，而 K/V tile 只有 16 深（最差区间）：**

| 宏（128bit 宽 × 深度） | µm²/bit |
|---|---|
| 128×16（**本设计 tile 深度**） | **105.8** |
| 128×32（双缓冲） | 60.1 |
| 128×128 | 26.5（≈追平 flop） |
| 128×256 | 15.5（此后才赢） |
| **flop（含局部逻辑，团队口径）** | **22.9** |

**架构锁死**：64 路点积 II=1 要求**每拍读一整行 K = 1024bit**；宏最宽 128bit → 必须 8 块并联，每块 16 深。
改"窄而深"会让 II 从 1 掉到 64、吞吐崩 64 倍、cycles 爆 300k。故带宽需求强制"宽而浅"——恰是 SRAM 最亏形状。

**总账**：K/V 四缓冲双缓冲化 SRAM ≈ **3.94M µm²** vs flop **≈1.5M µm²** = **大 2.6 倍（净增 ~2.4M µm²）**，
方向完全反。加之 SRAM 读 +1 拍延迟需改流水、是硬宏需布局——**即便面积打平也不值，何况大 2.6 倍。**

**结论**：flop 阵列对"宽、浅、高带宽"访问本就是面积最优解；SRAM 适合"窄、深、低带宽"大块存储，与本设计正相反。
**团队原文档"SRAM 做不了"成立**（更准确：带宽需求强迫浅阵列，浅阵列上 SRAM 比 flop 贵）。acc_block（热、需多端口、更浅）同理不适合。

## 6. 面积现状与去处（诚实小结）

- flop 域可抠的（BQ↓、位宽、`OPT_DROP_MNEW`/`OPT_L_SLACK` 微杠杆）经实测都是 **<0.05%** 的小钱。
- 面积大头是 **DMA/AXI 在 5/4ns 下时序驱动的真实驱动膨胀**，RTL 层拿不回来（不是虚胖、不自愈）。
- **故 5ns/82.1% 即当前 v2 的面积实际下限区；提交它。** 4ns 仅作免费上行赌注（见 §4）。
