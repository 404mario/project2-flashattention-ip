# Bonus-on-5ns-core 证据报告（分支 `bonus-v2-5ns-core`）

> **目标**：把 `bonus-v2-synthopt` 的 9 个 bonus 嫁接到**已冻结、真综合通过的 5ns 核**上，
> 得到「9 bonus + 5ns 干净核」——bonus 全关时与 baseline 逐字节一致、按 baseline 面积综合；bonus 由参数/寄存器门控。
> 这比「bonus 骑旧超标核」（bonus-v2 旧态：ACC36/BQ16，10.285M 超面积 7.2%）严格更优。
>
> **诚实边界**：本地（iverilog）只证 **bit-exact + cycles + bonus 功能 smoke**；bonus 开启时的真实面积/频率需 Genus。

## 方法：以共同祖先 `7c01722` 为基的三方合并

- 新分支从 `baseline-v2-synthopt`（`e95c391`，冻结 5ns 核）开出。
- `flash_core.sv` / `flash_attn_top.sv`：`git merge-file`（baseline 5ns 核 ⊕ 祖先 `7c01722` ⊕ bonus-v2 钩子）——**零文本冲突**。bonus-v2 未改祖先的老式 combine-feed，故 baseline 的新 `vreq_*`/`v_row_in` 流式接口（TUI-234 根因修复）原样保留，bonus 钩子落在不相交区域。
- `softmax_combine.sv`：取 baseline（max 树 + vreq 端口）。
- `axi_lite_regs.sv`：取 bonus-v2（+106 行 bonus 控制寄存器超集：dropout/window/head/task）。
- 9 个 bonus 文件 + filelist + 6 个 bonus 验证支持文件（4 单元 TB + 2 golden 模型）+ bonus 控制 TB + bonus-v2 的 633 行 e2e checker + bonus-v2 的 e2e TB（支持 bonus 模式参数、无 DMA-generate 路径探针问题）拷入。

## 闸 1（决定性）✅ — bonus 全关 = baseline 逐字节一致

全规模 S=256 causal、ACC_W=34、BQ=6、所有 bonus 模式=0：

```
cycles = 259,791          （== baseline）
md5    = 01697fe8fe972d47231bc0de559f53d5   （== baseline / Python 定点镜像）
golden: MAE<=0.03 MaxE<=0.10 PASS
```

**证明：骨架换对了，且 bonus 全关默认综合 = baseline 的 82.1% 面积 / 0 违例。**

## 闸 2 ✅ — 10 个 bonus 在新核上的 smoke（5 子代理并行验证 + 诊断）

| Bonus | RTL 结果 | 与原 bonus-v2 对比 |
|---|---|---|
| window（滑窗） | **PASS rc=0**（4 窗口尺寸全过，cycle 随窗变窄递减，clamp 生效） | — |
| block_quant | 集成 E2E **PASS**（BLOCK_QUANT_MODE mux 与新 vreq 路径共存） | byte-identical |
| multi_head | RTL **PASS**（cycles=1578，跑满 4 头） | **输出逐字节一致** |
| task_queue | RTL **PASS**（跑满 2 任务） | **输出逐字节一致** |
| sequence（valid_len） | RTL **PASS**（cycles=7544） | **输出逐字节一致（md5 385e9392）** |
| axis_stream | RTL **PASS**（AXIS 包装器干净绑定新核，所有 bonus 端口在） | **输出逐字节一致（md5 29956c1a）** |
| dropout | RTL **PASS**（kept=30 dropped=6；flash_core dropout 区与 bonus-v2 byte-identical） | 数值逐位一致 |
| bf16 | sim **PASS**（cycles=425，FP32 MAE 0.000061/MaxE 0.0039 ≪ 容差） | — |
| int8 | sim **PASS**（cycles=367，FP32 MAE 0.0020/MaxE 0.0625 ≪ 容差） | — |
| fp_softmax / fp_exp / fp_recip | 单元 **PASS**（恢复 4 个单元 TB 后） | RTL byte-identical |

**关键结论（子代理交叉验证）**：merged `flash_core` 的 window+dropout+valid-count 区与 bonus-v2 **逐字节一致**，唯一 merged delta 是 baseline 的 28 行 vreq 流式 feed。**骨架换未改任何 bonus 逻辑。**

## 两类"非 PASS"——均非骨架换回归（已在原 bonus-v2 树复现）

- **问题 A（合并工件，已修）**：三方合并保留了 baseline 的旧版 `check_top_e2e_output.py`（342 行）而非 bonus-v2 超集（633 行），导致 `--bf16-io/--valid-len/--dropout-*` 等参数 `unrecognized` → smoke rc=2。**已修**：取 bonus-v2 的 633 行 checker + 6 个支持文件 + bonus 控制 TB。
- **问题 B（bonus-v2 既有，非本次引入，未修）**：checker 的「RTL vs 定点镜像」**1-LSB 硬门**（`check_top_e2e_output.py:600-602`，无容差旋钮）对 lossy/中点舍入 case 报错（MaxE 0.0039 ≪ FP32 容差 0.10）；以及 dropout 全丢行的 0/0 角（共享 `normalizer.sv` 无 denom==0 guard）。**两者在原 bonus-v2 树上以完全相同的数值复现**，属既有测试/RTL 角点，超出"换骨架"范围，留作 owner 决定（如给镜像门加容差、或给 normalizer 加 denom==0 guard）。

## 落地
- 分支 `bonus-v2-5ns-core`，**不动** `baseline-v2-synthopt`、`bonus-v2-synthopt`。
- 综合：`synth/filelist.f`（含 bonus）+ baseline 的 `constraints.sdc`/`genus_ispatial.tcl`（5ns + TUI-234 修复）。bonus 全关默认 = baseline 面积。
- **待 Genus 确认**：bonus 开启时真实面积/频率；以及评分口径下「bonus 门控关闭时是否仍计 bonus 分」——这是是否真比 `8nsclean-bonus`（已综合，但 8ns）更优的关键，需向老师/评分确认。
