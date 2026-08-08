extends SceneTree

## Phase J: end-to-end public API smoke for PikafishEngine.
## Usage:
##   Godot --headless --path . -s res://tools/smoke_addon_headless.gd
## Prints SMOKE_PASS on success; exits 1 on failure.

const EngineScript = preload("res://addons/pikafish/pikafish.gd")
const ConfigScript = preload("res://addons/pikafish/config.gd")
const LimitsScript = preload("res://addons/pikafish/search/limits.gd")
const Types = preload("res://addons/pikafish/core/types.gd")

const START_FEN := "rnbakabnr/9/1c5c1/p1p1p1p1p/9/9/P1P1P1P1P/1C5C1/9/RNBAKABNR w - - 0 1"

var _engine
var _async_done := false
var _async_bestmove: int = Types.MOVE_NONE
var _fail_reason := ""


func _init() -> void:
	call_deferred("_run")


func _fail(msg: String) -> void:
	_fail_reason = msg
	printerr("SMOKE_FAIL: %s" % msg)
	quit(1)


func _run() -> void:
	_engine = EngineScript.new()
	var cfg = ConfigScript.new()
	# Prefer host data when present (repo layout); addon data is also OK.
	if FileAccess.file_exists("res://data/manifest.json"):
		cfg.network_dir = "res://data"
	var err: Error = _engine.initialize(cfg)
	if err != OK:
		_fail("initialize failed: %s %s" % [error_string(err), _engine.backend_info()])
		return

	var info: Dictionary = _engine.backend_info()
	print("smoke: backend=%s loaded=%s" % [info.get("backend", "?"), info.get("loaded", false)])
	if not bool(info.get("initialized", false)) or not bool(info.get("loaded", false)):
		_fail("backend_info not initialized/loaded: %s" % info)
		return

	err = _engine.set_fen(START_FEN)
	if err != OK:
		_fail("set_fen failed: %s" % error_string(err))
		return
	if _engine.get_fen() != START_FEN:
		_fail("get_fen mismatch")
		return

	var moves: PackedInt32Array = _engine.legal_moves()
	if moves.size() != 44:
		_fail("legal_moves startpos expected 44 got %d" % moves.size())
		return
	print("smoke: legal_moves=%d ok" % moves.size())

	# Sync search
	var lim = LimitsScript.new()
	lim.depth = 2
	lim.sync = true
	var got_info := [false]
	var got_best := [false]
	_engine.search_info.connect(func(_i): got_info[0] = true)
	_engine.best_move_found.connect(func(res):
		got_best[0] = true
		if not Types.move_is_ok(res.bestmove):
			_fail_reason = "sync bestmove invalid"
	)
	err = _engine.start_search(lim)
	if err != OK:
		_fail("start_search sync failed: %s" % error_string(err))
		return
	if not got_info[0] or not got_best[0]:
		_fail("sync search did not emit search_info/best_move_found")
		return
	if not _fail_reason.is_empty():
		_fail(_fail_reason)
		return
	if _engine.is_searching():
		_fail("still searching after sync start_search")
		return
	var sync_bm: int = _engine._last_result.bestmove
	if not _engine.is_legal(sync_bm):
		_fail("sync bestmove not legal: %s" % _engine.move_to_uci(sync_bm))
		return
	print("smoke: sync search bestmove=%s nodes=%d" % [
		_engine.move_to_uci(sync_bm), _engine._last_result.nodes
	])

	# Async search + stop path
	_async_done = false
	_async_bestmove = Types.MOVE_NONE
	_engine.best_move_found.connect(_on_async_best, CONNECT_ONE_SHOT)
	err = _engine.start_search({"depth": 3, "sync": false})
	if err != OK:
		_fail("start_search async failed: %s" % error_string(err))
		return
	var frames := 0
	while not _async_done and frames < 600:
		await process_frame
		frames += 1
	if not _async_done:
		_engine.stop_search()
		_fail("async search timed out after %d frames" % frames)
		return
	if not Types.move_is_ok(_async_bestmove) or not _engine.is_legal(_async_bestmove):
		_fail("async bestmove invalid/illegal")
		return
	print("smoke: async search bestmove=%s frames=%d" % [
		_engine.move_to_uci(_async_bestmove), frames
	])

	# stop_search must not crash mid-flight
	err = _engine.start_search({"depth": 99, "sync": false})
	if err != OK:
		_fail("start_search for stop failed: %s" % error_string(err))
		return
	await process_frame
	await process_frame
	_engine.stop_search()
	if _engine.is_searching():
		_fail("is_searching still true after stop_search")
		return
	if _engine.legal_moves().size() != 44:
		_fail("legal_moves broken after stop_search")
		return
	print("smoke: stop_search ok")

	_engine.shutdown()
	print("SMOKE_PASS")
	quit(0)


func _on_async_best(res) -> void:
	_async_done = true
	_async_bestmove = res.bestmove
