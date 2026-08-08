# 性能与正确性演进记录

本文档记录 Godot 计算着色器 NNUE 推理相对 C++ pikafish 的**正确性验证**与**性能对比**，
按 commit 追踪每次改动、测得结果与相对上一代的改进。README 只保留项目概览；数字以本文为准。

**约束**:不使用 GDExtension；特征提取留在 GDScript，网络累加/前向走 GPU compute shader。

**环境**(除非单条另注):
- 机器:Apple M1 Pro
- Godot:`4.7.1.stable`
- 局面集:`data/reference.json` 中 23 个 FEN(来自 pikafish bench)
- 计时:完整链路(特征 → 累加器 → 前向 → 输出),不含启动/加载
- GPU 批量稳态:`bench_gpu.gd` 预热 10 次、正式采样 100 次，报告 p50/p95
- C++ 基线:`pikafish` `bench ... eval` ≈ **0.17 ms/eval** (~5750 evals/s),NEON-dotprod + 增量累加器

**如何复测**:

```bash
# 正确性(参考 / GPU / GUT)
Godot --headless --path . -s res://src/test/run_ref_test.gd -- 23
Godot --path . -s res://src/test/run_gpu_test.gd
Godot --path . -s addons/gut/gut_cmdln.gd -gdir=res://src/test/gut -gexit

# 性能拆分(逐局面 CPU/GPU + 批量稳态)
Godot --path . -s res://src/test/bench_gpu.gd
# 输出同时写入 /tmp/bench_gpu.txt
```

---

## 当前快照(最新 commit)

| 实现 | ms/eval | evals/s | 说明 |
|---|---|---|---|
| C++ pikafish | **~0.17** | ~5750 | 基线 |
| GPU 批量 (p50, 23/批) | **0.1783** | **5610** | 4.100 ms/batch；p95 6.316 ms |
| GPU 单局面 (p50) | 0.839 | 1192 | 调度与同步仍难以摊薄 |
| 纯 GDScript 参考 | ~11.2 | ~89 | 解释执行 |

相对初版批量 **0.97 → 0.1783 ms/eval**(约 **5.4×**);相对本轮优化前基线
**0.3076 → 0.1783 ms/eval**，延迟降低 **42.0%**，吞吐 **3251 → 5610 evals/s**
(提升 **72.6%**，约 **1.73×**)。

正确性:Python / GDScript 参考 / GPU 单局面 / GPU 批量均为 **23/23**(diff=0)；
最新 GUT 为 91 passing、1 个既有 risky(无断言)，无失败。
iPad Air 5 / Godot 4.6.1 在 RDShaderFile SPIR-V 加载修复后 facade 选 GPU；
batch 同步 ~6314 eval/s、异步 ~3916 eval/s（均为 100×23，`bad=0`）。搜索叶子仍为 CPU 增量。

**双路径 API**(见下节 `cf61822`):
- 搜索 / 连续走子 → `XNnueEngine.refresh` / `do_move` / `undo_move` / `evaluate_incremental`(CPU 增量累加器)
- 大批无关局面 → `evaluate_batch`(PSQT 在 GPU,`BATCH_MAX=512`)

---

## 方法论说明

1. NNUE 网络很小(累加器 1024、前向 32/32/1),**逐局面** GPU dispatch+sync(~4 ms)远大于计算本身。
2. **批量**把调度开销摊薄后,端到端瓶颈回到 GDScript **特征提取**(桶 / 威胁索引)。
3. GPU 默认可从零重算;`XNnueEngine` 另提供 CPU 增量累加器供搜索。C++ 为增量累加器。
4. 不引入 GDExtension 时:搜索优先增量;bulk 评测优先更大 batch + GPU 侧 PSQT。

「特征提取」= GPU 之前的 CPU 工作:桶与镜像、PSQ/威胁活跃索引(攻击生成)。PSQT 求和在 GPU forward 中完成。

---

## 按 commit 的演进

### `947e673` — init

仓库初始化。尚无 NNUE 推理实现。

---

### `797f3b1` — feat: 初步实现推理引擎移植

**改动摘要**
- 完整移植:棋盘、攻击、HalfKAv2_hm + FullThreats 特征、权重加载、GDScript 参考推理
- GPU:`accumulator.glsl` / `forward.glsl` 及批量版;宿主 `gpu_inference.gd`
- 工具链:`parse_nnue.py` / `gen_tables.py` / `gen_reference.py` / `ref_inference.py`
- 测试:`run_ref_test` / `run_gpu_test` / `bench_gpu` / GUT

**正确性**

| 实现 | 结果 |
|---|---|
| Python 参考 | 23/23 (diff=0) |
| GDScript 参考 | 23/23 (diff=0) |
| GPU 单局面 | 23/23 (diff=0) |
| GPU 批量 | 23/23 (diff=0) |

**性能**(初版基线)

| 实现 | ms/eval | evals/s |
|---|---|---|
| C++ | ~0.17 | ~5750 |
| GPU 批量 steady | **~0.97** | ~1027 |
| GPU 逐局面 | ~4.5 | ~220 |
| GDScript 参考 | ~11.5 | ~87 |
| CPU 特征(拆分) | ~0.82 | — |
| GPU dispatch+sync(逐局面拆分) | ~3.7 | — |

**相对上一代**:从无到有;批量端到端约 6× 慢于 C++,瓶颈在 CPU 特征(~0.82 ms)与逐局面 sync。

---

### `b55dae0` — feat: 优化CPU特征提取以改进性能

**改动摘要**
- 棋盘缓存:棋子列表 / 将位 / 棋子计数 / occupancy,避免反复扫 90 格
- 延迟 `mid_mirror`:仅在 `!m1 && m2 && !m3 && m4` 时计算
- PSQT 只累加当前 layer-stack 的 **1** 个 bucket(原先 16 维)
- 攻击方向/非滑动子力表预计算;`append_attacks` 少分配
- 累加器与前向合并为一次 submit(`compute_list_add_barrier`)

**正确性**:23/23(参考 + GPU 单/批);GUT 5/5

**性能**

| 指标 | 本 commit | 相对 `797f3b1` |
|---|---|---|
| CPU 特征 | **~0.37 ms** | 0.82 → 0.37 (**~2.2×**) |
| GPU 批量 steady | **~0.51 ms** (~1950/s) | 0.97 → 0.51 (**~1.9×**) |
| vs C++ | ~3× | 原 ~6× |

**改进效果**:特征路径微优化把批量端到端接近腰斩;相对 C++ 从约 6× 收到约 3×。

---

### `298bff3` — feat: 优化推理性能

**改动摘要**
- 威胁只生成占用格上的攻击(`append_captures`),避免遍历空格攻击
- **双视角共享攻击生成**:捕获对与视角无关,各视角只做镜像/旋转索引映射
- 特征直接写入 GPU active 缓冲(`fill_both_perspectives`);主机侧复用数组
- 去掉有问题的射线表捷径(曾导致错误),保留与参考一致的滑动实现

**正确性**:23/23(参考 + GPU 单/批);GUT 5/5 (21 asserts)

**性能**

| 指标 | 本 commit | 相对 `b55dae0` | 相对初版 `797f3b1` |
|---|---|---|---|
| CPU 特征 | **~0.23 ms** | 0.37 → 0.23 | 0.82 → 0.23 (**~3.6×**) |
| GPU 批量 steady | **~0.33 ms** (~3000/s) | 0.51 → 0.33 | 0.97 → 0.33 (**~2.9×**) |
| GPU 逐局面 | ~4.4 ms | 大致持平(仍被 sync 主导) | — |
| GDScript 参考 | ~11.2 ms | 大致持平 | — |
| vs C++ | **~2×** | 原 ~3× | 原 ~6× |

**改进效果**:共享攻击 + 吃子-only 威胁是本轮主收益;批量约 3000 evals/s,端到端距 C++ 约 2×。

---

## 累计对照表

| Commit | 批量 ms/eval | 批量 evals/s | CPU 特征 ms | vs C++(约) | 正确性 |
|---|---|---|---|---|---|
| `797f3b1` 初版 | 0.97 | 1027 | 0.82 | 6× | 23/23 |
| `b55dae0` 特征优化 | 0.51 | 1950 | 0.37 | 3× | 23/23 |
| `298bff3` 共享攻击等 | **0.33** | **3000** | **0.23** | **2×** | 23/23 |
| `cf61822` 增量+GPU PSQT | ~0.33 | ~3000 | ~0.24 | ~2× | 23/23 |
| `85b5121` 本轮优化前基线 | 0.3076 | 3251 | — | ~1.8× | 23/23 |
| `498d7b1` 本轮最终矩阵 | **0.1783** | **5610** | **0.1314** | **~1.05×** | 23/23 |

---

### `cf61822` — feat: 增量累加器 + GPU PSQT/大batch，并修复 sqr 宽乘

**改动摘要**
- `board.gd`: `do_move` / `undo_move` + `piece_list` 维护
- `inc_accumulator.gd`: CPU 增量累加器(stm 翻转换槽;桶/镜像变则重建,否则特征集合差分)
- `nnue_engine.gd`: `refresh` / `evaluate_incremental` / `do_move` / `undo_move`
- GPU forward 内求和 PSQT;`BATCH_MAX` 提至 **512**;CPU 只上传活跃索引
- `sqr_clip`: 用 32×32→64 位乘法模拟 Pikafish `(long long)y*y`(修复 Metal 上 `int` 平方溢出)

**正确性**:ref/GPU/batch **23/23**;GUT **9/9**(含增量 vs 全量、do/undo)。

**性能**(23/批稳态仍约 **0.33 ms/eval**;更大 batch 可吃满 `BATCH_MAX=512`。增量路径避免每步全量 FT,搜索场景收益为主。)

**用法**

```gdscript
# 搜索 / 连续走子
engine.refresh(pos)
var e0 := engine.evaluate_incremental(pos)
engine.do_move(pos, frm, to)
var e1 := engine.evaluate_incremental(pos)
engine.undo_move(pos)

# 大批无关局面
var scores: PackedInt32Array = engine.evaluate_batch(boards)  # ≤512
```

---

### `8fcd65d` → `498d7b1` — 批量、shader 与增量路径优化系列

这一系列改动以 `85b5121` 的实测基线为起点。中间各 commit 没有保留完全同条件的独立
100-sample 性能矩阵，因此这里只记录改动归属和最终统一复测结果，不推测中间成绩。

**主要改动**

- `8fcd65d`:减少棋盘、特征和增量热路径分配。
- `5939e5d`:以 32-lane workgroup 并行化单局面和批量 forward shader。
- `e6f1435`:按 32/64/128/256/512 分档复用批量 host buffer。
- `94700f2`:增加容量为 3 的有界异步批量 worker。
- `526b851`:用可逆差分 frame 代替逐节点完整 accumulator 快照。
- `b8b9475`:批量特征并行提取并直接写入复用缓冲。
- `e2cc2ba`:预解码增量前向权重，降低 GDScript 内层分支开销。
- `6abc272`:扩展异步、fallback 和移动端验收覆盖。
- `498d7b1`:建立 batch 1/8/23/64/128/256/512 的统一性能矩阵。

**统一复测结果**(M1 Pro，Godot 4.7.1，warmup 10，samples 100)

| batch | p50 ms/batch | p95 ms/batch | p50 ms/eval | evals/s |
|---:|---:|---:|---:|---:|
| 1 | 0.839 | 1.660 | 0.8390 | 1192 |
| 8 | 1.990 | 2.926 | 0.2487 | 4020 |
| 23 | 4.100 | 6.316 | **0.1783** | **5610** |
| 64 | 10.122 | 12.509 | 0.1582 | 6323 |
| 128 | 19.464 | 24.349 | 0.1521 | 6576 |
| 256 | 35.902 | 42.218 | 0.1402 | 7131 |
| 512 | 71.959 | 80.381 | 0.1405 | 7115 |

23 局面连续三次 p50 为 **0.1526 / 0.1673 / 0.1783 ms/eval**，均达到
`<= 0.20 ms/eval` 的验收门槛。以统一矩阵的 0.1783 计，相对本轮基线延迟降低
**42.0%**；最佳一次降低 **50.4%**。

23 局面阶段拆分为 features 3.023、conversion 0.016、upload 0.008、accumulator
0.528、forward 0.509、readback 0.273 ms/batch。独立阶段中位数不可直接相加，
但可以确认 CPU 特征提取仍是下一轮的主要瓶颈。

增量 `do/evaluate/undo` 从 `85b5121` 的 8.166 ms p50 降至聚焦复测的 6.015 ms，
提升 **26.3%**；最终统一矩阵测得 5.727 ms p50、8.016 ms p95。三槽异步流水线
100 x 23 batches 为 526.791 ms、4366 eval/s，回调有序且无误差。

### iPad / Godot 4.6.1 兼容结果（历史故障 → 已修复）

Xcode 16.4 无法链接 Godot 4.7.x iOS 模板，因此真机使用 Godot 4.6.1 模板。

**历史故障（已修复，勿再当作当前结论）**：导出 PCK 把 `*.glsl` remap 成 `RDShaderFile` SPIR-V 后，`_load_compute_shader` 仍用 `FileAccess.get_as_text()` 读源码，管线空跑、GPU 全 0；canary 5/5 bad 后 facade 正确回退 CPU。当时 iPad Air 5 / iPadOS 18.7.0 在 CPU 路径上同步约 94 eval/s、异步约 93 eval/s（`bad=0`）。

**当前结论（2026-08-08 独立复验）**：`_load_compute_shader` 优先 `RDShaderFile.get_spirv()`，桌面无 import 时回退源码编译。canary 仍保留作安全网。详见下文「iPad GPU probe — 2026-08-08（修复后复验）」。

---

## 维护约定

每次有意图的性能/正确性改动落地后:

1. 跑通 `run_ref_test`(23)、`run_gpu_test` 或 GUT、以及 `bench_gpu.gd`。
2. 在本文「按 commit 的演进」追加一节:`hash`、改动摘要、正确性表、性能表、相对上一节的倍数。
3. 更新「当前快照」与「累计对照表」。
4. README 仅保留指向本文的链接与一行当前数字,不在 README 展开历史。

---

## 运行时后端 / 无 GPU

对外请使用 `XNnueEngine`(`src/nnue/nnue_engine.gd`):

- 能创建 local `RenderingDevice` → `backend_name == "gpu"`(`XGpuInference`)
- 否则 → `backend_name == "cpu"`(`XRefInference`),并 `push_warning`

`XGpuInference.try_create(...)` 在无设备时返回 `null`,不再 `assert` 崩掉。
CPU 路径可正确评棋但慢(~11 ms/eval);批量在 CPU 上是逐局面循环。

### search stop / clock TM (auto)

Superseded by「时间预算搜索」section below (2026-08-08 evening).

### iPad GPU probe — 2026-08-08（修复前故障快照）

- Device: iPad Air 5 (`iPad13,16`), iPadOS 18.7.0; Godot 4.6.1 Mobile.
- Export: complete `res://data` weight PCK; `ft_threatW=46,640,128` bytes, `ft_psqW=16,932,864` bytes; CPU oracle `0/23` bad.
- Forced GPU constructs, but returns zero for all 23 positions: GPU-vs-CPU `23/23` bad, oracle `23/23` bad, 252.162 ms/batch (91.2 eval/s).
- Root cause: remapped `*.glsl` opened via `FileAccess.get_as_text()` → empty/invalid runtime compile; `shader_load_probe` later showed `RDShaderFile` SPIR-V (~5836 B) while `FileAccess` open failed.
- Production canary reported `checked=5 bad=5` and selected CPU (safe fallback).

### iPad GPU probe — 2026-08-08（RDShaderFile 修复后复验）

独立复验：`tools/ios_gpu_probe_export.sh` → 安装 → 启动 → `user://gpu_probe_result.json`（Documents 拷回）。**不是** alpha-beta 搜索叶子性能。

| 项 | 结果 |
|---|---|
| Device / OS / Godot | iPad Air 5 (`iPad13,16`) / iPadOS 18.7.0 / 4.6.1 Mobile |
| Weights | `ft_threatW=46,640,128`；`ft_psqW=16,932,864`；PCK ~139 MiB |
| Facade | `backend=gpu`；canary `checked=5 bad=0` |
| Forced GPU scalar | abs_diff=0（首局面 149） |
| Forced GPU batch 23 | oracle / GPU-vs-CPU / CPU-oracle 均为 `bad=0` |
| Sync 100×23 | **6314 eval/s**，364.246 ms，`bad=0` |
| Async 3-slot 100×23 | **3916 eval/s**，587.276 ms，`bad=0`，callbacks ordered |
| Marker | `GPU_PROBE_PASS` |

GPU 仅用于公开 batch inference（含 facade 异步槽）。alpha-beta 搜索仍走 CPU 增量 NNUE accumulator；未把单叶 GPU 接入搜索。

### 完整搜索单步延迟 — 2026-08-08

起始局面、同步 `start_search`；计时只覆盖搜索与叶子评分（不含 engine 初始化、权重读取和 GPU canary）。每个模式复用同一 engine 顺序搜索 depth 1→3，因此 depth 2/3 会受已有 TT/history 影响，代表连续游玩而非冷启动。

| 设备 / 运行时 | 叶子评估 | depth 1 | depth 2 | depth 3 | depth 3 nodes |
|---|---:|---:|---:|---:|---:|
| M1 Pro / Godot 4.7.1 | material（默认） | 81.0 ms | 653.0 ms | 962.2 ms | 1,912 |
| M1 Pro / Godot 4.7.1 | incremental NNUE（opt-in） | 437.9 ms | 1,234.4 ms | 2,046.3 ms | 799 |
| iPad Air 5 / Godot 4.6.1 | material（默认） | 76.2 ms | 683.7 ms | 1,005.9 ms | 1,912 |
| iPad Air 5 / Godot 4.6.1 | incremental NNUE（CPU accumulator；搜索未接 GPU batch） | 415.4 ms | 1,207.6 ms | 2,018.6 ms | 799 |

这不是完整 Pikafish 深搜索强度；当前默认 material 叶子较快但棋力有限。上表 iPad NNUE 行测于 GPU canary 失败、CPU fallback 时期；搜索叶子仍为 CPU 增量路径，与上方修复后的 GPU **batch** 吞吐不可混算。

### 时间预算搜索（movetime / stop）— 2026-08-08

`start_search` 默认异步；`sync:true` 仅用于测量。复用 History 后避免每次搜索重填 ~80 MiB。GPU batch **未**接入 alpha-beta 叶子。

**M1 Pro / Godot 4.7.1 — material**

| movetime | wall | completed depth | nodes | nps | best |
|---:|---:|---:|---:|---:|---|
| 300ms | 301ms | 3 | 674 | 2246 | a3a4 |
| 1200ms | 1206ms | 4 | 2257 | 1873 | a3a4 |
| 2000ms | 2001ms | 4 | 3974 | 1987 | a3a4 |

Stop latency n=20: p50=16ms p95=**18ms**. Async 100× start/stop: p95=5ms（`run_async_search_test.gd`）。

**M1 Pro / Godot 4.7.1 — incremental NNUE（opt-in）**

| movetime | wall | completed depth | nodes | nps | best |
|---:|---:|---:|---:|---:|---|
| 300ms | 336ms | 1 | 134 | 443 | b2e2 |
| 1200ms | 1236ms | 3 | 471 | 391 | b2e2 |
| 2000ms | 2036ms | 3 | 832 | 415 | b2e2 |

Stop latency n=20: p50=35ms p95=**36ms**（≤50ms）。Clock TM: 60s+1s ply10 → optimum=3723 / maximum=26068；30s mtg20 ply5 → 1374 / 4809。

**iPad Air 5 / iPadOS 18.7.0 / Godot 4.6.1 Mobile**（`tools/ios_search_time_export.sh` → `user://search_time_result.json`）

- Facade：`backend=gpu`，canary `checked=5 bad=0`（搜索叶子仍为 CPU；GPU 仅 batch inference）。
- Marker：`SEARCH_TIME_PASS`，failures=0。

| leaf | movetime | wall | depth | nodes | nps | best | complete |
|---|---:|---:|---:|---:|---:|---|---|
| material | 300 | 312 | 1 | 528 | 1748 | a3a4 | yes |
| material | 1200 | 1202 | 3 | 2374 | 1975 | a3a4 | yes |
| material | 2000 | 2000 | 4 | 4199 | 2099 | a3a4 | yes |
| NNUE CPU | 300 | 343 | 0 | 90 | 296 | a3a4 | **fallback**（depth1 未完成） |
| NNUE CPU | 1200 | 1233 | 1 | 396 | 330 | b2e2 | yes |
| NNUE CPU | 2000 | 2038 | 3 | 812 | 405 | b2e2 | yes |

Stop 100× async：material p50=1 / p95=**4ms**；NNUE p50=37 / p95=**40ms**（≤50）；illegal=0。主线程未因搜索阻塞（async + deferred 回调）。

复测：

```bash
Godot --headless --path . -s res://tools/bench_search_time.gd -- --write-log
Godot --headless --path . -s res://tools/bench_search_time.gd -- --nnue --write-log
Godot --headless --path . -s res://src/test/run_async_search_test.gd
bash tools/ios_search_time_export.sh   # then install/launch; copy Documents/search_time_result.json
```
