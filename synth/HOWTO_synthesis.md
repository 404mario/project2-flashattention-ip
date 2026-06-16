# 综合工作流 HOWTO（Cadence Genus iSpatial）—— 踩坑记录与正确步骤

> 本文沉淀"正确把 v2 综合跑出真实 PPA"的完整流程，避免重复踩坑。
> 适用所有 v2 分支（`*-v2-*`）。综合在校内 EDA 服务器（RHEL 8.8 + DDI 25.12）上跑，本地无 PDK。

## TL;DR（一条命令）
```bash
# 在分支根目录（synth/ 的上一级），先 git pull 拿最新
./synth/run_genus.sh            # 已内含 module load + 正确的 ispatial 流 + 5ns 默认
# 结果：synth/reports_ispatial_5.000ns/10_qor.rpt
```
等价的手动三步（后端同学验证过的正确姿势）：
```bash
module load ddi/251/25.12.000                 # ① 必须先 load，否则 genus: Command not found
genus -f synth/genus_ispatial.tcl             # ② 一定用 _ispatial（物理流），不是 genus.tcl
#    （从分支根目录跑；脚本会自动 cd 到根目录定位 filelist/sdc）
```

## 四个真实踩过的坑（按出现顺序）

### 坑 1：`genus: Command not found`
没先 `module load ddi/251/25.12.000`。genus 不在默认 PATH，必须先 load 这个 module（同时 checkout license）。

### 坑 2：source 错了脚本 / 路径不对
现象：`source synth/genus.tcl` → `File 'synth/genus.tcl' does not exist`。
- 原因：当时 cwd 在 `.../baseline/synth` 里，又写相对路径 `synth/genus.tcl`，自然找不到；
- 而且 **`genus.tcl` 是旧的逻辑流，不是我们要的**。

### 坑 3：用错了流 —— `genus.tcl`（逻辑） vs `genus_ispatial.tcl`（物理）★最重要
| | `genus.tcl`（逻辑流） | `genus_ispatial.tcl`（物理/iSpatial 流）★用这个 |
|---|---|---|
| 加载 | 只标准单元 .lib | + LEF + QRC 物理库 |
| 综合 | 纯逻辑、wireload 估时 | 布局感知（placement-aware）|
| Net Area | 0 | 真实布线面积 |
| 时序/面积 | 偏乐观、不准 | **真实 PPA（提交/评测要这个）** |
| 报告目录 | `synth/reports/` | `synth/reports_ispatial_<period>ns/` |

→ 后端同学"专门做 ispatial"是对的。`run_genus.sh` 现已改为调用 `genus_ispatial.tcl`。

### 坑 4：`TUI-234 ... [group]` 在 `syn_generic -physical` 阶段退出
- 根因：iSpatial 的 **advanced-structuring** 步骤会对组合逻辑锥做内部 `group`，当它跨
  `dma↔core` 边界去 group `dma_controller` 的 `CDN_PAS_SKIP_MUX` 时报 TUI-234。
- 修法：`genus_ispatial.tcl` 里 **ungroup 仅 `u_dma_controller`**（溶解这一个小块边界，
  不是整设计砸平）。真·8ns baseline 当年就这么干、干净跑完 ≈7.8h。
- **自检**：`grep -c "ungroup -simple" synth/genus_ispatial.tcl` 必须 ≥ 1。

### 坑 5（附带）：`./run_genus.sh` → permission denied
git 里该脚本曾掉成 `100644`。已修为 `100755`。临时绕过：`tcsh synth/run_genus.sh`。

## 跑之前的 3 条自检（30 秒）
```bash
grep -c "ungroup -simple" synth/genus_ispatial.tcl   # 期望 >=1（坑4）
grep "genus_ispatial.tcl" synth/run_genus.sh         # 确认调物理流（坑3）
grep "CLK_PERIOD" synth/constraints.sdc | head -1    # 看目标周期（默认 5.000ns）
```

## 关于"用户名变 root"的澄清
genus 启动后提示符是 `@genus:root:` —— 那是 **Genus 自己 Tcl 解释器的根命名空间**，
不是 Linux root 用户。退出 genus 后 shell 提示符仍是普通用户。无权限/安全问题。

## 跑完看什么
`synth/reports_ispatial_<period>ns/10_qor.rpt` 里：
- `clk` 周期、`Slack`、`TNS`、`Violating Paths`（=0 才算 clean）
- `Cell Area` → 等效门数 = Cell Area / 4.7952（NAND2_X1），门限 200 万
把这几行发出来即可判断 5ns 是否收敛、要不要补流水。

## 备注：扫多个频率
```bash
./synth/run_sweep.sh 8 6 5      # 各周期独立写 reports_ispatial_<P>ns/，互不覆盖
```
