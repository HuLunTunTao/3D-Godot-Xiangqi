# 固定节点搜索差分

该差分器是搜索对齐的基线，不是“通过/失败”的棋力测试。它以锁定的上游
`2c5c998c211d524d26c38e7e3e71d51bc24cbe64`、单线程 C++ Pikafish 的 `go nodes N`
结果为参考，再使用 addon 的 CPU 增量 NNUE 在同一 FEN 和节点预算重放。

## 运行

```bash
# 仅在上游提交或权重改变时重新生成并审查 fixture：
/Users/hltt/.local/bin/mlpython3119 tools/gen_search_node_fixtures.py

# addon 对照；报告写入 user://search_node_diff.json：
Godot --headless --path . -s res://src/test/diff_search_nodes.gd
```

`fixtures/search/node_corpus.json` 默认包含 4 个代表局面 × 256 / 1024 nodes。两端在
停止检查边界都可能略超出预算；报告保留实际 `nodes`，不把它误判为语义差异。

## 当前基线（2026-08-09）

| 指标 | 结果 |
|---|---:|
| 对照运行 | 8 |
| addon 合法最佳着 | 8 / 8 |
| 最佳着精确一致 | 6 / 8 |
| CP 分数精确一致 | 0 / 8 |

分数不一致是预期的、可行动的信号：当前优先检查 NNUE 原始输出到官方
`Eval::evaluate` 最终分数之间的包装语义，以及根部 aspiration / TT / score 传播；
不要据此直接开启更多剪枝开关。每次移植一项上游逻辑后复跑并记录这些指标。
