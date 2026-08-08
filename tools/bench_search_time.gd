extends SceneTree

## Micro-bench: movetime budgets, stop latency, clock TM, start/stop cycles.
## Usage:
##   Godot --headless --path . -s res://tools/bench_search_time.gd [--write-log] [--nnue]
## Writes a short section into docs/perf-log.md when --write-log is passed.

const Eng = preload("res://addons/pikafish/pikafish.gd")
const Config = preload("res://addons/pikafish/config.gd")
const TimeMan = preload("res://addons/pikafish/search/time_manager.gd")
const Types = preload("res://addons/pikafish/core/types.gd")

const START := "rnbakabnr/9/1c5c1/p1p1p1p1p/9/9/P1P1P1P1P/1C5C1/9/RNBAKABNR w - - 0 1"
const LEAK_CYCLES := 100
const STOP_SAMPLES := 20
const PERF_LOG := "res://docs/perf-log.md"
const MOVETIME_BUDGETS := [300, 1200, 2000]


func _init() -> void:
	var args := OS.get_cmdline_user_args() + OS.get_cmdline_args()
	var write_log := "--write-log" in args
	var use_nnue := "--nnue" in args
	var lines: PackedStringArray = PackedStringArray()
	lines.append("")
	lines.append("### search time-budget / stop (auto %s)" % [
		"NNUE" if use_nnue else "material"
	])
	lines.append("")
	lines.append("- host: desktop Godot 4.7.1; leaf=%s" % ("incremental NNUE" if use_nnue else "material"))

	# Clock optimum/maximum sanity
	var tm = TimeMan.new()
	tm.init_from_limits({"wtime": 60000, "btime": 60000, "winc": 1000, "binc": 1000}, 0, 10)
	assert(tm.optimum_ms > 0 and tm.maximum_ms >= tm.optimum_ms)
	lines.append(
		"- clock 60s+1s inc ply10: optimum=%dms maximum=%dms" % [tm.optimum_ms, tm.maximum_ms]
	)
	tm.init_from_limits({"wtime": 30000, "movestogo": 20}, 0, 5)
	lines.append(
		"- clock 30s mtg20 ply5: optimum=%dms maximum=%dms" % [tm.optimum_ms, tm.maximum_ms]
	)

	var cfg = Config.new()
	cfg.prefer_gpu = false
	cfg.use_nnue_eval = use_nnue
	var e = Eng.new()
	assert(e.initialize(cfg) == OK)
	assert(e.set_fen(START) == OK)

	# Sync depth still works
	assert(e.start_search({"depth": 3, "sync": true}) == OK)
	assert(Types.move_is_ok(e._last_result.bestmove))
	lines.append("- sync depth3: nodes=%d best=%s completed=%d" % [
		e._last_result.nodes,
		Types.move_to_uci(e._last_result.bestmove),
		e._last_result.completed_depth,
	])

	# Movetime budgets (sync so we can measure wall elapsed precisely)
	for budget in MOVETIME_BUDGETS:
		assert(e.set_fen(START) == OK)
		var t0: int = Time.get_ticks_msec()
		assert(e.start_search({"movetime_ms": budget, "sync": true}) == OK)
		var wall: int = Time.get_ticks_msec() - t0
		var res = e._last_result
		var nps: int = res.nps
		lines.append(
			"- movetime %dms: wall=%dms elapsed=%dms depth=%d nodes=%d nps=%d best=%s reason=%s complete=%s" % [
				budget, wall, res.elapsed_ms, res.completed_depth, res.nodes, nps,
				Types.move_to_uci(res.bestmove), res.stop_reason, str(res.from_complete_iteration),
			]
		)
		print("MOVETIME %d wall=%d depth=%d nodes=%d best=%s" % [
			budget, wall, res.completed_depth, res.nodes, Types.move_to_uci(res.bestmove)
		])

	# Stop latency
	var stop_samples: PackedInt32Array = PackedInt32Array()
	for _i in range(STOP_SAMPLES):
		assert(e.set_fen(START) == OK)
		assert(e.start_search({"depth": 99, "sync": false}) == OK)
		OS.delay_msec(5)
		var t0s: int = Time.get_ticks_msec()
		e.stop_search()
		var dt: int = Time.get_ticks_msec() - t0s
		stop_samples.append(dt)
		assert(not e.is_searching())
		assert(Types.move_is_ok(e._last_result.bestmove))
	stop_samples.sort()
	var p50: int = stop_samples[stop_samples.size() / 2]
	var p95: int = stop_samples[int(stop_samples.size() * 0.95)]
	lines.append("- stop latency n=%d: p50=%dms p95=%dms (target p95<=50)" % [
		STOP_SAMPLES, p50, p95
	])
	print("STOP_LATENCY p50=%d p95=%d" % [p50, p95])

	# Bounded start/stop leak smoke
	for i in range(LEAK_CYCLES):
		assert(e.set_fen(START) == OK)
		assert(e.start_search({"depth": 2, "sync": true}) == OK)
		if i % 2 == 0:
			assert(e.start_search({"depth": 99, "sync": false}) == OK)
			e.stop_search()
	lines.append("- start/stop cycles: %d" % LEAK_CYCLES)
	print("LEAK_CYCLES %d ok" % LEAK_CYCLES)

	e.shutdown()
	for ln in lines:
		print(ln)

	if write_log:
		var f := FileAccess.open(PERF_LOG, FileAccess.READ_WRITE)
		if f == null:
			f = FileAccess.open(PERF_LOG, FileAccess.WRITE_READ)
		if f != null:
			f.seek_end()
			f.store_string("\n".join(lines) + "\n")
			f.close()
			print("WROTE ", PERF_LOG)

	print("BENCH_SEARCH_TIME_PASS")
	quit(0)
