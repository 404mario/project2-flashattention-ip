# Genus 综合中途中断（TUI-234）排错记录

> 现象：`genus -f synth/genus_ispatial.tcl` 跑到一半（约 13,600 s）**突然中断**，
> 没有写出任何报告。日志 `genus (1).log1` 末尾：
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

## 3. 修复

在**两遍 generic 之间**，把所有 advstr 造出来的 `CDN_PAS_*_MUX` 组溶掉，让物理 generic
从**扁平 fan-in 锥**重新开始 —— 没有被保留的同名层级可供嵌套/跨越：

```tcl
syn_generic
predict_floorplan

# TUI-234 fix #2：溶解 advstr 的 CDN_PAS_*_MUX 组，再进物理 generic
puts "INFO: dissolving advstr CDN_PAS_*_MUX groups before physical generic (TUI-234 #2)..."
foreach_in_collection h [get_db hinsts -if {.name=~"*CDN_PAS_SKIP_MUX*" || .name=~"*CDN_PAS_CONNECTED_MUX*"}] {
    catch { set_db $h .ungroup_ok true }
    catch { set_db $h .module.ungroup_ok true }
    catch { set_db $h .module.advstr_keep_structure 0 }
    catch { ungroup -simple $h }
}

syn_generic -physical
syn_map -physical
syn_opt -spatial
```

**为什么是安全的（不改功能/面积语义）**：Genus 自己在每遍里就把绝大多数 `CDN_PAS_*_MUX`
以 `ratio=1.0` ungroup 掉了（日志里大量 `Ungrouping: ... ratio=1.0`）；我们只是把**残留的
工具自造 mux 包装**显式溶掉，**不动任何 RTL**，等价于让 advstr 重新结构化。已落地于
`synth/genus_ispatial.tcl`（搜索 `TUI-234 fix #2`），并叠加在原有 dma ungroup 之上。

## 4. 备选/兜底方案（按推荐度排序）

| 方案 | 做法 | 取舍 |
|---|---|---|
| **A（已采用）** | 两遍 generic 间溶解 `CDN_PAS_*_MUX` 组 | 改动最小、保 flash_core 层级、不动 RTL |
| **B** | 整体关掉 advanced structuring：在综合前 `set_db root: .advanced_struct_mode none`（或 `set_db design:flash_attn_top .advstr_cas false`）跨版本属性名以 `get_db -h advstr` 自查 | 一行根治、最稳；可能略损面积/时序优化 |
| **C** | 合并两遍为一遍：删掉独立 `syn_generic`，只跑 `syn_generic -physical`（advstr 只跑一次，不会同名嵌套） | 简单；但少了纯逻辑 generic 的预优化 |
| **D** | 对 flash_core 的 causal-skip mux 也 ungroup（`USE_CAUSAL_SKIP` 锥）或在 RTL 里用静态译码替换动态下标 | 改动大、可能增 mux 面积，收益为负，不推荐 |

> 若方案 A 重综合后仍在 advstr 处报错，直接切到**方案 B** 全局关 advanced structuring，
> 是最稳的"一定能跑完"路径（代价是放弃 advstr 的那部分 PPA 优化）。

## 5. 复现与验证

```bash
cd synth
./run_genus.sh            # 默认 5.000ns、high effort、retiming on
# 关注日志里：
#   "INFO: dissolving advstr CDN_PAS_*_MUX groups before physical generic"
#   之后 syn_generic -physical 不再出现 [TUI-234] / [SYNTH-3]
# 跑完后看 synth/reports_ispatial_5.000ns/10_qor.rpt
```

判定标准：日志出现 `Done synthesizing. [SYNTH-2]`（第二遍也成功）并正常写出
`reports_ispatial_*/` 全套报告，即修复成功。

---

*修复提交在分支 `codex-baseline-v2-dma-prefetch-synthopt`；本说明同步到 `main` 供评测查阅。
日志依据：`genus (1).log1`（2026-06-16，Genus 25.12-s067_1）。*
