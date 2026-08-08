# 设备测试仪表盘

`src/test/mobile_test.tscn`、`mobile_gpu_probe.tscn` 与
`mobile_search_time.tscn` 都会显示同一个测试专用仪表盘。它不属于
`addons/pikafish` 的游戏运行时 API。

仪表盘运行时读取并展示：

- `OS` / `Engine` / `RenderingServer` / `DisplayServer` 提供的平台、系统、设备标识、
  Godot 版本、renderer、图形适配器与屏幕尺寸；
- addon 的实际 backend、GPU canary 与权重目录；
- 当前测试阶段、进度、吞吐、错误数和最近 200 条日志；
- 搜索 depth、NPS、stop p95 等测试实时指标。

三个场景结束后会停留在绿色 `PASS` 或红色 `FAIL` 页面，便于在 iPad 上确认结果。
同时仍输出标准日志并写入 `user://` JSON 报告：

| 场景 | 报告 |
|---|---|
| `mobile_test.tscn` | `user://mobile_test_result.json` |
| `mobile_gpu_probe.tscn` | `user://gpu_probe_result.json` |
| `mobile_search_time.tscn` | `user://search_time_result.json` |

自动化或命令行调用时加 `--auto-quit`，测试在写完报告后退出。例如：

```bash
Godot --path . res://src/test/mobile_search_time.tscn -- --auto-quit
```

在 iOS 上，两个 `tools/ios_*_export.sh` 脚本会直接选用仓库内的可视化场景；无需再
临时生成空的 `Node` 场景。
