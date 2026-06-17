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

### 坑 3：用错了脚本 —— 只剩 `genus_ispatial.tcl`（物理/iSpatial 流）★最重要
**2026-06-17 起：冗余的 `genus.tcl` 已删除，synth/ 下只保留 `genus_ispatial.tcl` 一份。**
之前 `genus.tcl` 与 `genus_ispatial.tcl` 几乎相同却容易被手误 `genus -f genus.tcl` 跑到，造成混乱。
`run_genus.sh`/`run_sweep.sh` 一直调 `genus_ispatial.tcl`，不受影响。

iSpatial（物理）流的价值：加载 LEF+QRC 物理库、布局感知综合、真实布线面积与 PPA
（提交/评测必须用它），报告写到 `synth/reports_ispatial_<period>ns/`。

### 坑 4：`TUI-234 ... [group]` 在 `syn_generic -physical` 阶段退出 ★已 RTL 治本
- 根因（最终定位）：`syn_generic -physical` 的 **advanced-structuring** 把 `softmax_combine`
  里的 `v_tile[j_q]` 动态行选 mux（行215）结构化成 `CDN_PAS_SKIP_MUX`，其组合锥跨
  `flash_core/u_combine` 边界 `group` → TUI-234。详见 `docs/genus_synthesis_troubleshooting.md`。
- **治本修法（已落地）**：在 RTL 把 V 改为**流式喂入**（`flash_core` 用寄存器逐行喂给
  `softmax_combine`，仿 `dot_stream` 喂 `k` 的范式），消除跨边界动态 mux。bit-exact、cycle 数不变。
- 脚本侧仍保留两层兜底（理论上 RTL 改后不触发）：`ungroup u_dma_controller` + 两遍 generic 间
  溶解 `CDN_PAS_*_MUX`（搜 `TUI-234 fix #2`）。
- **自检**：`grep -c "ungroup -simple" synth/genus_ispatial.tcl` 应 ≥ 1。

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
