# Genus 综合失败（TUI-234）排错记录与根治

> **结论先行（2026-06-17 复盘）**：综合不是"被服务器中断"，而是 `syn_generic -physical`
> 阶段先因 **TUI-234 失败**（`[SYNTH-3]`），脚本返回 1 之后才被 Ctrl-C。根因是
> `rtl/core/softmax_combine.sv` 的 `v_tile[j_q]` 动态行选 mux 跨 `u_combine` 边界被 advstr
> 结构化。**已在 RTL 治本**（V 流式喂入，见 §3），bit-exact 验证通过。脚本侧 fix#1/fix#2
> 退为冗余安全网。
>
> 现象：`genus -f synth/genus_ispatial.tcl` 跑到 `syn_generic -physical`（约 13,600 s）后
> 报错失败、没有写出报告。日志 `genus (1).log1` 末尾：
>
> ```
> Error : Not all instances belong to the same hierarchy. [TUI-234] [group]
>       : Instance 'hinst:flash_attn_top/u_flash_core/CDN_PAS_SKIP_MUX_0i' is part of
>         (sub)design 'flash_core_..._832'. Instance
>         '.../CDN_PAS_SKIP_MUX_0i/CDN_PAS_SKIP_MUX_0i/g100416' is not part of ...
>       : The 'edit_netlist group' command can only group instances contained
>         within the same hierarchy.
> ...
> Info : Synthesizing failed. [SYNTH-3]
>      : Synthesizing to generic gates failed in 'flash_attn_top'.
> Encountered problems processing file: synth/genus_ispatial.tcl
> ```

---

## 1. 它崩在哪一步

`genus_ispatial.tcl` 的综合流程是两遍 generic：

```tcl
syn_generic            ; # 第 1 遍：逻辑 generic —— 日志显示成功
predict_floorplan      ; # 成功（floorplan prediction 完成）
syn_generic -physical  ; # 第 2 遍：物理 generic —— ★ 在这里崩 ★
syn_map -physical
syn_opt -spatial
```

日志对应：
- `@file(genus_ispatial.tcl) 154: syn_generic` → `Done synthesizing. [SYNTH-2]` ✅
- `@file(genus_ispatial.tcl) 156: syn_generic -physical` → 紧接着 TUI-234 → `[SYNTH-3]` ❌

所以是**第二遍 generic 中断**，不是第一遍，也不是 map/opt。

## 2. 真正的根因

崩溃实例是 **flash_core 的 causal-skip mux**，不是 dma：

```
hinst flash_attn_top/u_flash_core/CDN_PAS_SKIP_MUX_0i           ← 第 1 遍 advstr 保留的层级
.../CDN_PAS_SKIP_MUX_0i/CDN_PAS_SKIP_MUX_0i/g100416             ← 第 2 遍又建的同名嵌套
```

Genus 的 **advanced-structuring（CAS）** 子步骤会在**每次** `syn_generic` 里对组合
fan-in 锥做内部 `group [all_fanin ...]`。流程是：

1. **第 1 遍 `syn_generic`**：advstr 把 `CDN_PAS_SKIP_MUX_0i` 识别为 CAS 层级并**保留**
   （日志 `Identified hierarchy for CAS: .../CDN_PAS_SKIP_MUX_0i`，并置
   `advstr_keep_structure=1`、`advstr_cas=1`）。
2. **第 2 遍 `syn_generic -physical`**：advstr **重新**分析同一个锥，在被保留的
   `CDN_PAS_SKIP_MUX_0i` **内部**又建了一个**同名嵌套** `CDN_PAS_SKIP_MUX_0i`，随后
   `group` 把 `all_fanin` 收进来时跨越了这层嵌套边界 → **TUI-234**（一个 group 不能
   跨越不同 (sub)design 层级）。

这些 skip mux 来自 `USE_CAUSAL_SKIP=1`，位于 `u_flash_core` 内部 —— 而我们**故意保留**
`flash_core` 的层级，所以**原来只 ungroup dma 的修法够不着它们**。

`CDN_PAS_SKIP_MUX` / `CDN_PAS_CONNECTED_MUX` 是 Genus 为**动态数组下标访问**综合出的
muxing 中间结构（`CDN_PAS` = Cadence Pre-/Post-Assign Synthesis）。

### 为什么之前以为是 dma 的问题

`genus.tcl`（旧脚本）和 `genus_ispatial.tcl` 都只 `ungroup u_dma_controller`，并在注释
里断定"只有 dma 跨边界那个 group 会失败、flash_core 不会"。**日志推翻了这个判断**：
dma ungroup 后，第二遍 generic 仍因 flash_core 的 skip mux 崩。dma ungroup **必要但不充分**。

## 2b. 三份日志交叉验证（2026-06-17 复盘）

后续又拿到两份失败日志，三方交叉确认根因唯一、且与 effort / 脚本无关：

| 日志 | 跑的脚本 | 含 fix#2？ | 失败点 |
|---|---|---|---|
| `genus (1).log1` | `genus_ispatial.tcl`(旧) | 否 | TUI-234 @ `u_flash_core/u_combine` skip-mux |
| `genus.log2` | `genus.tcl` | 否 | **同一处** TUI-234 @ `u_combine` |
| `genus (2).log1` | `genus_ispatial.tcl`(旧) | 否 | **同一处** TUI-234，失败后才被 Ctrl-C（中断是结果不是原因）|

关键纠正几个曾经的误判：
1. **不是 effort 问题**：真正跑出 8ns 的 baseline 分支 `8nsclean-baseline`（旧名 codex-baseline-core-pipeline-fmax）
   用的 `genus.tcl` 与当前几乎相同（medium effort、只 flatten dma），唯一差异是 **baseline 的
   `filelist.f` 里没有 `softmax_combine.sv`**。
2. **不是 ispatial vs 普通脚本的问题**：两份脚本都是物理流程，差异只在 effort/retime/报告目录。
3. **真凶精确定位在 `rtl/core/softmax_combine.sv`**：
   - 行197 `score_in[j_q]`、行215 `v_tile[j_q][mk]` —— `j_q` 是运行时递增的 key 索引，
     这是一个 16:1 × 1024-bit 的**动态行选 mux**，直接喂 64-wide 组合乘法器阵列。
   - `v_tile` 是 `softmax_combine` 的输入端口，该动态 mux 的组合锥**跨 `flash_core/u_combine`
     边界**。`syn_generic -physical` 的 advanced-structuring（CAS）把它结构化成 `CDN_PAS_SKIP_MUX`
     并跨边界 `group` → TUI-234。
   - 对照 `dot_stream` 处理 `k_tile[feed_idx_q]`（`flash_core.sv:150`）：它的 mux 输出立刻进
     dot_stream 第一级寄存器（`node_q[0] <= q*k`），**寄存器边界切断了组合锥**，所以 advstr 不挑它。
4. **`fix #2`（pass 间 ungroup CDN_PAS_*_MUX）大概率不够**：从 `genus (2).log1` 看，真正肇事的
   嵌套 skip-mux（`g100416`）是 **pass2(`syn_generic -physical`) 运行时新造的**，而 fix#2 在 pass2
   **之前**清理，清不掉 pass2 自己生成的那个。fix#2 因此**退为冗余安全网**，不再是主修复。

## 3. 修复（RTL 治本：把 V 流式喂进 softmax_combine）

**思路**：复制 `dot_stream` 对 `k` 的 "mux→寄存器→再跨界" 范式。`softmax_combine` 不再接收整块
`v_tile` 然后内部动态索引，而是**提前一拍**向 `flash_core` 请求下一个 key 的索引；`flash_core`
用寄存器锁存 `v_tile[idx]`/`score[idx]` 再喂回。动态 mux 移到 `flash_core` 且经寄存器跨界，
组合锥被切断 → advstr 不再造跨 `u_combine` 边界的 skip-mux，TUI-234 从根上消除，且 **hierarchy
全保留**（flash_core 不被 flatten）。

**改动文件**：
- `rtl/core/softmax_combine.sv`：删 `v_tile` 端口；增 `vreq_valid`/`vreq_idx`(输出)、
  `v_row_in`/`score_cur_in`(输入)；行197/215 改用流入的 `score_cur_in`/`v_row_in`；保留
  `score_in[0:BK-1]`（仅 `max_comb` 静态归约用，advstr 安全）。新增：
  ```
  assign vreq_valid = (state_q==S_IDLE && start) || (state_q==S_MAC && j_q != len_q-1);
  assign vreq_idx   = (state_q==S_MAC && j_q != len_q-1) ? (j_q+1) : '0;   // 上界 = len-1 <= BK-1，不越界
  ```
- `rtl/core/flash_core.sv`：增 `sc_vreq_*`、`v_row_q[0:D_MODEL-1]`、`score_cur_q` + 预取
  `always_ff`（`if (sc_vreq_valid) { v_row_q<=v_tile[sc_vreq_idx]; score_cur_q<=buf_score[cons_buf_q][sc_vreq_idx]; }`），
  `u_combine` 例化改连线。`v_tile` 仍是 flash_core 输入端口（喂预取 mux）。
- `tb/sv/tb_softmax_combine.sv`：TB 侧加同款预取寄存器镜像 flash_core，以便继续 bit-exact 验证。

**逐拍对齐（II=1、cycle 数不变）**：寄存器引入的 1 拍延迟被原有的 `CS_KICK`/`S_IDLE` 那一拍吸收
（key0 在那拍预取），combine 在 MAC key k 的那拍喂进来的 `v_row_q` 恰好 = `v_tile[k]`。首 key、
末 key、`S_MAC→S_MOLD` 切换均精确对齐。

**bit-exact 证明（iverilog 实测，2026-06-17）**：
| 验证 | 结果 |
|---|---|
| `tb_softmax_combine` 单元 | MAE=0.000672 MaxE=0.001272（与改前**逐位一致**），PASS |
| 顶层 S=8 改前 vs 改后 输出 hex | **逐位完全相同**，cycles=309 两者一致 |
| 顶层 S=8 FP32 黄金（numpy） | MAE=0.000061 MaxE=0.003906（≪ 0.03/0.10）PASS |
| 全规模 S=256/D=64 向量 | 见 `reports/v2_evidence.md`（与 golden 对比）|

## 4. fix #2 与其它备选（保留为安全网）

主修复是上面的 RTL 治本。`synth/genus_ispatial.tcl` 里仍保留两层脚本兜底（理论上 RTL 改后不再触发）：
1. `ungroup u_dma_controller`（dma 的 beat 索引动态访问仍会造少量 skip-mux，溶其边界）。
2. `fix #2`：两遍 generic 间溶解 `CDN_PAS_*_MUX` 组。

若 RTL 改后重综合**仍**在 advstr 处报 TUI-234（例如 USE_CAUSAL_SKIP 路径另有动态锥），按此优先级处置：
| 方案 | 做法 | 取舍 |
|---|---|---|
| 全局关 advstr | 综合前 `set_db design:flash_attn_top .advstr_cas false`（属性名以 `get_db -h *advstr*` 自查） | 一行根治、最稳；略损 datapath PPA |
| 合并两遍 generic | 删独立 `syn_generic`，只跑 `syn_generic -physical`（advstr 只跑一次，不会同名嵌套） | 简单；少了纯逻辑预优化 |
| 定向 ungroup u_combine | 把 dma 的 ungroup 同款套到 `*u_combine*`（已被 RTL 治本取代，仅应急） | 溶一个小块边界，PPA 影响小 |

## 5. 复现与验证

```bash
# RTL bit-exact 回归（本机 iverilog）
iverilog -g2012 -o sim_build/tb_softmax_combine.vvp rtl/core/softmax_combine.sv tb/sv/tb_softmax_combine.sv
vvp sim_build/tb_softmax_combine.vvp            # 期望 tb_softmax_combine PASS，MAE/MaxE 不变
bash sim/run_top_compile.sh                     # 顶层编译（已补回 dot_stream/softmax_combine 文件）
bash sim/run_top_e2e_smoke.sh                   # 小/中规模
RUN_VECTORS=1 bash sim/run_top_e2e_smoke.sh     # 全规模向量（需 numpy）

# 综合（EDA 机）
cd synth && ./run_genus.sh                       # 默认 5.000ns、high effort、retiming on，调 genus_ispatial.tcl
# 期望：syn_generic -physical 不再出现 [TUI-234]/[SYNTH-3]，正常写出 reports_ispatial_*/10_qor.rpt
```

判定标准：单元/E2E bit-exact 不变；综合日志出现两遍 `Done synthesizing. [SYNTH-2]` 且写出全套报告。

---

*修复提交在分支 `baseline-v2-synthopt`；本说明可同步到其它 v2 分支与 `main` 供评测查阅。
脚本侧已合并为单一 `genus_ispatial.tcl`（删除冗余 `genus.tcl`）。
日志依据：`genus (1).log1` / `genus.log2` / `genus (2).log1`（2026-06-16~17，Genus 25.12-s067_1）。*
