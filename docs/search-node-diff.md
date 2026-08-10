# 固定节点搜索差分

该差分器是搜索对齐的基线，不是“通过/失败”的棋力测试。它以锁定的上游
`2c5c998c211d524d26c38e7e3e71d51bc24cbe64`、单线程 C++ Pikafish 的 `go nodes N`
结果为参考，再使用 addon 的 CPU 增量 NNUE 在同一 FEN 和节点预算重放。

## 单位（必读）

| 字段 | 含义 |
|---|---|
| Godot `result.score` | 搜索内部 `Value` |
| Fixture / UCI `score cp` | `UCIEngine::to_cp(Value, pos)`，**不是**内部 Value |
| Godot `to_cp` | `addons/pikafish/core/uci_score.gd`，与上游同式 |

**禁止**把 Godot raw Value 与 Pikafish UCI cp 直接判等。旧报告里的
“CP exact / score exact”若未区分这两套单位，一律视为
`measurement invalid / pre-node-parity`。

比较时分别记录：PF/GD internal Value、PF/GD `to_cp`、completed depth、nodes、
bestmove。Pikafish internal Value 若 fixture 未带 instrumentation 字段，则用
`from_cp_estimate` 反推并标注来源；**Value exact** 仅在 instrumentation 可得时计。

## 运行

```bash
# 仅在上游提交或权重改变时重新生成并审查 fixture：
/Users/hltt/.local/bin/mlpython3119 tools/gen_search_node_fixtures.py

# addon 对照；报告写入 user://search_node_diff.json：
Godot --headless --path . -s res://src/test/diff_search_nodes.gd
```

`fixtures/search/node_corpus.json` 默认包含 4 个代表局面 × 256 / 1024 nodes。两端在
停止检查边界都可能略超出预算；报告保留实际 `nodes`，不把它误判为语义差异。

## 结果表列

`| Case | PF Depth | GD Depth | PF Value | GD Value | PF CP | GD CP | Bestmove Match |`

## 当前基线（2026-08-09，S1 remediation 后）

旧报告在未区分 Value / UCI cp、且 node accounting 未对齐前的 `exact_score` /
“CP 可直接比 Value”结论一律作废（`measurement invalid / pre-node-parity`）。

| 指标 | 结果 |
|---|---:|
| 对照运行 | 8 |
| addon 合法最佳着 | 8 / 8 |
| 最佳着精确一致 | 5 / 8 |
| Value 精确一致（需 PF instrumentation） | 0 / 8 |
| CP 精确一致（`to_cp`） | 0 / 8 |
| mean \|Δcp\| | 35.88 |
| median \|Δcp\| | 23.50 |

`startpos@256`：d1 已与上游对齐（Value 55 / cp 14）；最终仍停在 completed_depth=2
（Value 199 / cp 50），上游为 depth4 upperbound（cp 116）。

## Usability Candidate 冻结（2026-08-10，S2 qsearch remediation 后）

**状态：Usability Candidate（SearchParity 自动推进暂停）**

- 已修复：`_qsearch` TT stand-pat（消费 TT eval/value）+ fail-high softbound `(467*best+557*beta)/1024`（commit `dd7ec83`）。
- first-divergence path `d2/b2e2/h7h0/qsearch`：GD 现返回 262，与 PF 对齐。
- d2 root 仍未与 PF 收敛（GD ≈199/cp50 vs PF ≈338/cp85），主因是次要缺口（Step13 shallow pruning 等），**不**自动进入 S3/LMR/History/pruning。
- 不全等于 PF ≠ 继续改代码的充分理由；后续以可用性与性能验收为主。
