extends Node

## iPad / mobile timed-search acceptance (material + optional NNUE).
## Writes user://search_time_result.json for devicectl copy-from Documents.
## Main scene for tools/ios_search_time_export.sh.

const Eng = preload("res://addons/pikafish/pikafish.gd")
const Config = preload("res://addons/pikafish/config.gd")
const Types = preload("res://addons/pikafish/core/types.gd")
const Reporter = preload("res://src/test/ui/test_reporter.gd")
const Dashboard = preload("res://src/test/ui/test_dashboard.gd")

const START := "rnbakabnr/9/1c5c1/p1p1p1p1p/9/9/P1P1P1P1P/1C5C1/9/RNBAKABNR w - - 0 1"
const RESULT_PATH := "user://search_time_result.json"
const STOP_CYCLES := 100
const MOVETIME_BUDGETS := [300, 1200, 2000]
## Render only four times during this latency-sensitive loop. More frequent UI frames
## perturb the very stop latency the acceptance test is measuring.
const STOP_UI_CHUNK := 25

var _out: Dictionary = {}
var _engine
var _failures := 0
var _reporter


func _ready() -> void:
	_reporter = Reporter.new("Mobile search acceptance")
	var dashboard = Dashboard.new()
	add_child(dashboard)
	dashboard.bind(_reporter)
	call_deferred("_run")


func _fail(msg: String) -> void:
	_failures += 1
	printerr("SEARCH_TIME_FAIL: %s" % msg)
	_reporter.report_log(msg, "FAIL")


func _run() -> void:
	_reporter.stage("Loading material search backend")
	_out = {
		"marker": "SEARCH_TIME_RUNNING",
		"godot": Engine.get_version_info(),
		"os": OS.get_name(),
		"failures": 0,
	}
	_engine = Eng.new()
	var cfg = Config.new()
	cfg.prefer_gpu = true  # canary still selects; search leaf stays CPU
	cfg.use_nnue_eval = false
	var err: Error = _engine.initialize(cfg)
	if err != OK:
		_fail("initialize %s" % error_string(err))
		_finish(false)
		return
	_out["backend"] = _engine.backend_info()
	_reporter.metric("backend", _out["backend"].get("backend", "unknown"))
	_reporter.metric("canary", _out["backend"].get("canary_ok", false))
	if _engine.set_fen(START) != OK:
		_fail("set_fen")
		_finish(false)
		return

	_out["material"] = await _bench_leaf(false)
	# Re-init for NNUE leaf path.
	_engine.shutdown()
	_engine = Eng.new()
	cfg = Config.new()
	cfg.prefer_gpu = true
	cfg.use_nnue_eval = true
	if _engine.initialize(cfg) != OK:
		_fail("initialize nnue")
		_finish(false)
		return
	_reporter.stage("Loading incremental NNUE search backend")
	_out["nnue"] = await _bench_leaf(true)
	_out["nnue_clock"] = await _bench_nnue_clock()

	_out["failures"] = _failures
	_out["marker"] = "SEARCH_TIME_PASS" if _failures == 0 else "SEARCH_TIME_FAIL"
	_finish(_failures == 0)


func _bench_leaf(use_nnue: bool) -> Dictionary:
	var section := {
		"use_nnue_eval": use_nnue,
		"movetime": [],
		"stop": {},
		"async_cycles": STOP_CYCLES,
	}
	if _engine.set_fen(START) != OK:
		_fail("set_fen leaf")
		return section

	_reporter.stage("%s timed search" % ("NNUE" if use_nnue else "Material"), MOVETIME_BUDGETS.size())
	for index in range(MOVETIME_BUDGETS.size()):
		var budget = MOVETIME_BUDGETS[index]
		if _engine.set_fen(START) != OK:
			_fail("set_fen movetime")
			continue
		var t0: int = Time.get_ticks_msec()
		# Sync for precise wall measurement on device.
		if _engine.start_search({"movetime_ms": budget, "sync": true}) != OK:
			_fail("movetime start %d" % budget)
			continue
		var wall: int = Time.get_ticks_msec() - t0
		var res = _engine._last_result
		if res == null or not Types.move_is_ok(res.bestmove) or not _engine.is_legal(res.bestmove):
			_fail("movetime best %d" % budget)
			continue
		section["movetime"].append({
			"budget_ms": budget,
			"wall_ms": wall,
			"elapsed_ms": res.elapsed_ms,
			"depth": res.completed_depth,
			"nodes": res.nodes,
			"nps": res.nps,
			"bestmove": _engine.move_to_uci(res.bestmove),
			"reason": res.stop_reason,
			"from_complete": res.from_complete_iteration,
		})
		_reporter.progress(index + 1, MOVETIME_BUDGETS.size(), "%d ms · depth %d · %d nps" % [budget, res.completed_depth, res.nps])
		_reporter.metric("%s_depth" % ("nnue" if use_nnue else "material"), res.completed_depth)
		_reporter.metric("%s_nps" % ("nnue" if use_nnue else "material"), res.nps)
		_reporter.report_log("%s %dms: depth=%d nodes=%d nps=%d" % ["NNUE" if use_nnue else "Material", budget, res.completed_depth, res.nodes, res.nps])
		await get_tree().process_frame

	# Async start/stop stress
	_reporter.stage("%s async stop stress" % ("NNUE" if use_nnue else "Material"), STOP_CYCLES)
	var stop_samples: PackedInt32Array = PackedInt32Array()
	var illegal := 0
	for i in range(STOP_CYCLES):
		if _engine.set_fen(START) != OK:
			_fail("set_fen stop")
			break
		if _engine.start_search({"depth": 99, "sync": false}) != OK:
			_fail("async start")
			break
		OS.delay_msec(1 + (i % 5))
		var t0s: int = Time.get_ticks_msec()
		_engine.stop_search()
		_engine.stop_search()
		stop_samples.append(Time.get_ticks_msec() - t0s)
		if _engine.is_searching():
			_fail("still searching")
			break
		var res2 = _engine._last_result
		if res2 == null or not Types.move_is_ok(res2.bestmove) or not _engine.is_legal(res2.bestmove):
			illegal += 1
		if i % STOP_UI_CHUNK == STOP_UI_CHUNK - 1 or i + 1 == STOP_CYCLES:
			_reporter.progress(i + 1, STOP_CYCLES, "illegal results: %d" % illegal)
			await get_tree().process_frame
	stop_samples.sort()
	var p50 := 0
	var p95 := 0
	if stop_samples.size() > 0:
		p50 = stop_samples[stop_samples.size() / 2]
		p95 = stop_samples[int(stop_samples.size() * 0.95)]
	section["stop"] = {
		"n": stop_samples.size(),
		"p50_ms": p50,
		"p95_ms": p95,
		"illegal": illegal,
	}
	if p95 > 50:
		_fail("stop p95=%d > 50 (%s)" % [p95, "nnue" if use_nnue else "material"])
	if illegal > 0:
		_fail("illegal bestmoves=%d" % illegal)
	_reporter.metric("%s_stop_p95_ms" % ("nnue" if use_nnue else "material"), p95)
	_reporter.report_log("%s stop: p50=%dms p95=%dms illegal=%d" % ["NNUE" if use_nnue else "Material", p50, p95, illegal])
	return section


func _bench_nnue_clock() -> Dictionary:
	## Exercises the official-style dynamic soft target, distinct from movetime.
	var section := {"wtime_ms": 30000, "winc_ms": 0}
	_reporter.stage("NNUE clock time management", 1)
	if _engine.set_fen(START) != OK:
		_fail("set_fen clock")
		return section
	var t0: int = Time.get_ticks_msec()
	if _engine.start_search({
		"wtime": 30000,
		"btime": 30000,
		"winc": 0,
		"binc": 0,
		"sync": true,
	}) != OK:
		_fail("clock start")
		return section
	var res = _engine._last_result
	section.merge({
		"wall_ms": Time.get_ticks_msec() - t0,
		"depth": res.completed_depth if res != null else 0,
		"nodes": res.nodes if res != null else 0,
		"nps": res.nps if res != null else 0,
		"soft_time_ms": res.soft_time_ms if res != null else 0,
		"hard_time_ms": res.hard_time_ms if res != null else 0,
		"bestmove": _engine.move_to_uci(res.bestmove) if res != null else "",
	})
	if res == null or not Types.move_is_ok(res.bestmove) or not _engine.is_legal(res.bestmove):
		_fail("clock bestmove")
	elif res.soft_time_ms <= 0 or res.hard_time_ms < res.soft_time_ms:
		_fail("clock bounds")
	_reporter.progress(1, 1, "depth %d · soft/hard %d/%d ms" % [
		section["depth"], section["soft_time_ms"], section["hard_time_ms"]
	])
	_reporter.metric("nnue_clock_soft_ms", section["soft_time_ms"])
	_reporter.metric("nnue_clock_hard_ms", section["hard_time_ms"])
	_reporter.report_log("NNUE clock: depth=%d soft=%d hard=%d" % [
		section["depth"], section["soft_time_ms"], section["hard_time_ms"]
	])
	await get_tree().process_frame
	return section


func _finish(ok: bool) -> void:
	_out["failures"] = _failures
	if not ok:
		_out["marker"] = "SEARCH_TIME_FAIL"
	var f := FileAccess.open(RESULT_PATH, FileAccess.WRITE)
	_out["environment"] = _reporter.environment
	if f != null:
		f.store_string(JSON.stringify(_out, "\t"))
		f.close()
	print(_out.get("marker", "?"))
	_reporter.finish(ok, str(_out.get("marker", "?")))
	_reporter.report_log("report saved: %s" % RESULT_PATH)
	if OS.get_cmdline_user_args().has("--auto-quit"):
		await get_tree().create_timer(0.5).timeout
		get_tree().quit(0 if ok else 1)
