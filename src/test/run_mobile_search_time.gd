extends Node

## iPad / mobile timed-search acceptance (material + optional NNUE).
## Writes user://search_time_result.json for devicectl copy-from Documents.
## Main scene for tools/ios_search_time_export.sh.

const Eng = preload("res://addons/pikafish/pikafish.gd")
const Config = preload("res://addons/pikafish/config.gd")
const Types = preload("res://addons/pikafish/core/types.gd")

const START := "rnbakabnr/9/1c5c1/p1p1p1p1p/9/9/P1P1P1P1P/1C5C1/9/RNBAKABNR w - - 0 1"
const RESULT_PATH := "user://search_time_result.json"
const STOP_CYCLES := 100
const MOVETIME_BUDGETS := [300, 1200, 2000]

var _out: Dictionary = {}
var _engine
var _failures := 0


func _ready() -> void:
	call_deferred("_run")


func _fail(msg: String) -> void:
	_failures += 1
	printerr("SEARCH_TIME_FAIL: %s" % msg)


func _run() -> void:
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
	if _engine.set_fen(START) != OK:
		_fail("set_fen")
		_finish(false)
		return

	_out["material"] = _bench_leaf(false)
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
	_out["nnue"] = _bench_leaf(true)

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

	for budget in MOVETIME_BUDGETS:
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

	# Async start/stop stress
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
	return section


func _finish(ok: bool) -> void:
	_out["failures"] = _failures
	if not ok:
		_out["marker"] = "SEARCH_TIME_FAIL"
	var f := FileAccess.open(RESULT_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(_out, "\t"))
		f.close()
	print(_out.get("marker", "?"))
	# Keep process alive briefly so Documents flush is visible to host copy.
	await get_tree().create_timer(0.5).timeout
	get_tree().quit(0 if ok else 1)
