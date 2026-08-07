# Pikafish NNUE 推理 — Godot 计算着色器 (GDS) vs C++ 性能试验

用 Godot 计算着色器 (compute shader) 实现与 `pikafish.nnue` 权重**完全兼容**的 NNUE 推理
(棋盘 + HalfKAv2_hm 累加器 + FullThreats 威胁特征 + 前向网络),与从源码构建的 pikafish C++
二进制逐位对齐,并对比 GPU (GDS) 与 C++ 的推理性能。

## 正确性与性能

正确性已全部对齐 oracle(23/23,diff=0)。当前 Apple M1 Pro 上 23 局面 GPU 批量 p50 为
**0.1783 ms/eval**(5610 eval/s),已接近 C++(~0.17 ms);详细数字、每次 commit 的改动与复测方法见:

**→ [docs/perf-log.md](docs/perf-log.md)**(性能与正确性演进记录)

游戏/产品代码请用 addon 门面 **`PikafishEngine`**(见
[addons/pikafish/README.md](addons/pikafish/README.md)):有 GPU 走 compute,无
`RenderingDevice` 时自动回退到纯 GDScript CPU 参考。`XNnueEngine` 已弃用,仅作兼容包装。
两条评测路径:

- **搜索 / 连续走子**:`refresh` → `do_move` / `undo_move` → `evaluate_incremental`(CPU 增量累加器)
- **大批无关局面**:`evaluate` / `evaluate_batch`(PSQT 在 GPU,batch 上限 512)

头烟测试:`Godot --headless --path . -s res://tools/smoke_addon_headless.gd`(期望 `SMOKE_PASS`)。

## 项目结构

```
tools/
  parse_nnue.py         zstd 解压 + 解析 pikafish.nnue → data/ 权重块 + manifest
  gen_tables.py         预计算 ValidBB / PSQOffsets / ThreatOffsets(计数=689/45547 已验证)
  gen_reference.py      用 oracle 对 23 个 FEN 生成参考数据 data/reference.json
  ref_inference.py      Python 参考推理(与 oracle 逐位对齐)
src/nnue/
  nnue_consts.gd        常量/坐标/棋子编码
  board.gd              象棋棋盘 + FEN + do_move/undo_move
  attacks.gd            全棋子攻击生成(车炮马象士将兵,含塞马腿/象眼/炮翻山/过河兵)
  features.gd           PSQ/Threat 索引、桶选择、fill_active_both(活跃列表)
  nnue_loader.gd        权重/表格加载(原始字节 + 按需解码,加载 <100 ms)
  nnue_engine.gd        对外入口:GPU/CPU + 增量搜索 API
  inc_accumulator.gd    CPU 增量特征变换累加器(搜索用)
  ref_inference.gd      纯 GDScript 完整推理(黄金参考 / CPU fallback)
  gpu_inference.gd      RenderingDevice 宿主:逐局面 + 批量(≤512)
src/shaders/
  accumulator.glsl      累加器:活跃特征行求和 → acc[2×1024]
  forward.glsl          前向 + PSQT → eval(含 64 位 sqr_clip)
  accumulator_batch.glsl / forward_batch.glsl  批量版
src/test/
  run_ref_test.gd       headless:GDScript 参考 vs oracle
  run_gpu_test.gd       XNnueEngine vs oracle(GPU 或 CPU fallback)
  bench_gpu.gd          窗口:性能基准(逐局面 + 批量,含 CPU/GPU 拆分)
  gut/                  GUT 测试套件(oracle/特征/攻击/棋盘/增量/GPU 边界)
docs/
  perf-log.md           性能/正确性演进(按 commit 记录测得结果与改进)
data/                   权重块 + 参考数据(65 MB,不入 git)
Copying.txt             GNU GPL v3 全文(与 Pikafish 相同)
```

## 如何运行

```bash
# 权重/tables/参考数据(需先有 pikafish.nnue 与编译好的 pikafish oracle):
NNUE=/path/to/pikafish.nnue
ORACLE=/path/to/pikafish
python3 tools/parse_nnue.py "$NNUE"
python3 tools/gen_tables.py
python3 tools/gen_reference.py --oracle "$ORACLE" --net "$NNUE"

# Python 参考验证(需 oracle 二进制):
python3 tools/ref_inference.py

# GDScript 参考(headless):
/Applications/Godot/Godot_v4.7.1.app/Contents/MacOS/Godot --headless \
  --path . -s res://src/test/run_ref_test.gd -- 23

# GPU 推理(有 GPU 时走 compute;无设备自动 CPU fallback):
...Godot --path . -s res://src/test/run_gpu_test.gd
# 也可用 headless 验证 fallback:
...Godot --headless --path . -s res://src/test/run_gpu_test.gd

# 性能基准(含 C++ 对比数据):
...Godot --path . -s res://src/test/bench_gpu.gd

# GUT 测试套件:
...Godot --path . -s addons/gut/gut_cmdln.gd -gdir=res://src/test/gut -gexit

# C++ 基线(oracle / bench):
cd ../Pikafish/src
printf 'bench 16 1 1 ../../godot-pikafish/data/fens.txt eval\nquit\n' | ./pikafish
```

## 关键移植细节

- 权重文件:zstd 压缩,解压后 header(version 0x6A448AFA / hash 0x40C70FA6 / desc)+
  FT 参数(bias/psqt 为 LEB128,psqW/threatW 为裸 i8)+ 16 个网络栈(裸 i32/i8)。
  文件中为**自然序**(SIMD 重排仅存在于内存),直接顺序读取即可。
- 推理链:`acc[p][i] = bias[i] + Σ psqW[idx·1024+i] + Σ threatW[idx·1024+i]`
  → `tf = clamp(acc[j],0,255)·clamp(acc[j+512],0,255)/512`
  → fc0(1024→32) `sqr=min(127,((long long)y²)>>21)`、`clip=clamp(y>>7,0,127)`
  → fc1(64→32) shift 19/6 → fc2(128→1)
  → `fwd = y2 + (y0[30]-y0[31])`,`positional = fwd·9600/16384`;
  `eval = psqt/16 + positional/16`(psqt=(psqtAcc[stm][b]-psqtAcc[opp][b])/2)。
- 坑:`flip` 对 Color 是 `^1`、对 Piece 是 `^8`;PackedInt32Array 是值类型
  (累加需写回);GLSL 中 `active` 是保留字;GDScript `/` 向零截断;GPU `y*y` 必须
  用宽乘(与 C++ `long long` 一致),否则大激活会因 int32 溢出与 oracle 分歧。

## 协议 / Terms of use

本仓库的许可安排对齐 [Pikafish](https://github.com/official-pikafish/Pikafish) 的做法
(引擎本体 GPL v3;网络训练数据 / `.nnue` 相关 ODbL)。本项目是与 `pikafish.nnue`
兼容的 **NNUE 推理实现**(Godot / GDScript / compute shader),**不是**完整 UCI 象棋引擎;
UCI 命令协议见 [Pikafish Wiki: UCI & Commands](https://github.com/official-pikafish/Pikafish/wiki/UCI-&-Commands)。

### GNU General Public License version 3

本项目源代码(含 `src/`、`tools/`、`src/shaders/` 等,第三方插件除外)以
[**GNU GPL v3**](Copying.txt) 发布,全文见仓库根目录 `Copying.txt`(与 Pikafish 的
`Copying.txt` 相同)。

要点与 Pikafish 一致:你可以自由使用、修改、再分发(包括商用或嵌入更大软件),
但**只要分发本程序或其衍生作品,就必须同时提供 GPL v3 许可与完整对应源码**
(或明确指向可取得该源码的位置);你的修改也必须以 GPL v3 提供。

上游致谢:[Pikafish](https://github.com/official-pikafish/Pikafish) /
[Stockfish](https://github.com/official-stockfish/Stockfish) 的 NNUE 求值设计与实现。

### 神经网络权重 (`.nnue` / `data/` 权重块)

评测所用的 `pikafish.nnue` 及由 `tools/parse_nnue.py` 解出的权重块,来自 Pikafish
发布的网络。Pikafish 声明其网络训练数据来自
[Pika Xiangqi Zero](https://www.kaggle.com/datasets/pikacat/px0data),并以
[Open Database License (ODbL)](https://opendatacommons.org/licenses/odbl/odbl-10.txt)
提供。再分发或基于该网络做衍生数据库时,请遵守 ODbL(含署名与相同许可分享等义务)。
`data/` 默认不入 git,需自行从官方网络生成或获取。先用 `tools/parse_nnue.py` 解析
`pikafish.nnue`(位置参数),再用 `tools/gen_tables.py` 生成特征表,最后用
`tools/gen_reference.py --oracle <pikafish> --net <pikafish.nnue>` 生成 oracle 参考数据;
`--out` / `-o` 可指定输出路径,默认写入 `data/`。

### 第三方组件

| 组件 | 许可 | 说明 |
|---|---|---|
| [GUT](addons/gut/) | MIT | 测试框架,见 `addons/gut/LICENSE.md` |
| Godot Engine | 其自身许可 | 本仓库不附带引擎二进制;运行测试需自行安装 Godot |
