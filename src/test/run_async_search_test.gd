extends SceneTree

## Headless async search + stop stress (desktop).
## Usage:
##   Godot --headless --path . -s res://src/test/run_async_search_test.gd
## Exit 0 on pass; non-zero on failure.

const Eng = preload("res://addons/pikafish/pikafish.gd")
const Config = preload("res://addons/pikafish/config.gd")
const Types = preload("res://addons/pikafish/core/types.gd")

const START := "rnbakabnr/9/1c5c1/p1p1p1p1p/9/9/P1P1P1P1P/1C5C1/9/RNBAKABNR w - - 0 1"
const STOP_CYCLES := 100

var _engine
var _failures := 0
var _pending := 0
var _got_best := 0
var _info_depths: Array = []


func _fail(msg: String) -> void:
	_failures += 1
	printerr("ASYNC_SEARCH_FAIL: %s" % msg)


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_engine = Eng.new()
	var cfg = Config.new()
	cfg.prefer_gpu = false
	if _engine.initialize(cfg) != OK:
		_fail("initialize")
		quit(1)
		return
	if _engine.set_fen(START) != OK:
		_fail("set_fen")
		quit(1)
		return

	# Ordered async depth-3 with info + single bestmove.
	_engine.search_info.connect(_on_info)
	_engine.best_move_found.connect(_on_best)
	_pending = 1
	if _engine.start_search({"depth": 3, "sync": false}) != OK:
		_fail("start_search async")
		quit(1)
		return
	var frames := 0
	while _pending > 0 and frames < 900:
		await process_frame
		frames += 1
	if _pending > 0:
		_fail("async depth3 timeout")
		quit(1)
		return
	if _got_best != 1:
		_fail("best_move_found count=%d" % _got_best)
		quit(1)
		return
	print("async depth3 infos=%s best_ok" % str(_info_depths))

	# 100 start/stop cycles: no crash, legal bestmove when delivered.
	var stop_samples: PackedInt32Array = PackedInt32Array()
	for i in range(STOP_CYCLES):
		if _engine.set_fen(START) != OK:
			_fail("set_fen cycle %d" % i)
			break
		if _engine.start_search({"depth": 99, "sync": false}) != OK:
			_fail("start cycle %d" % i)
			break
		OS.delay_msec(1 + (i % 5))
		var t0: int = Time.get_ticks_msec()
		_engine.stop_search()
		_engine.stop_search()  # idempotent
		var dt: int = Time.get_ticks_msec() - t0
		stop_samples.append(dt)
		if _engine.is_searching():
			_fail("still searching after stop cycle %d" % i)
			break
		var res = _engine._last_result
		if res == null or not Types.move_is_ok(res.bestmove):
			_fail("illegal/missing bestmove cycle %d" % i)
			break
		if not _engine.is_legal(res.bestmove):
			_fail("bestmove not legal cycle %d" % i)
			break
	stop_samples.sort()
	var p50: int = stop_samples[stop_samples.size() / 2] if stop_samples.size() else -1
	var p95: int = stop_samples[int(stop_samples.size() * 0.95)] if stop_samples.size() else -1
	print("STOP_CYCLES=%d stop_p50=%d stop_p95=%d (target p95<=50)" % [STOP_CYCLES, p50, p95])
	if p95 > 50:
		_fail("stop p95=%d > 50" % p95)

	# Movetime async returns once.
	_got_best = 0
	_pending = 1
	_engine.best_move_found.connect(_on_best_movetime, CONNECT_ONE_SHOT)
	if _engine.start_search({"movetime_ms": 150, "sync": false}) != OK:
		_fail("movetime start")
		quit(1)
		return
	frames = 0
	while _pending > 0 and frames < 900:
		await process_frame
		frames += 1
	if _pending > 0:
		_engine.stop_search()
		_fail("movetime async timeout")
		quit(1)
		return

	_engine.shutdown()
	if _failures > 0:
		print("ASYNC_SEARCH_FAIL count=%d" % _failures)
		quit(1)
		return
	print("ASYNC_SEARCH_PASS")
	quit(0)


func _on_info(info) -> void:
	_info_depths.append(info.depth)


func _on_best(res) -> void:
	_got_best += 1
	_pending = 0
	if not Types.move_is_ok(res.bestmove) or not _engine.is_legal(res.bestmove):
		_fail("async best illegal")


func _on_best_movetime(res) -> void:
	_pending = 0
	if not Types.move_is_ok(res.bestmove) or not _engine.is_legal(res.bestmove):
		_fail("movetime best illegal")
	print("movetime async depth=%d nodes=%d elapsed=%d" % [
		res.completed_depth, res.nodes, res.elapsed_ms
	])
