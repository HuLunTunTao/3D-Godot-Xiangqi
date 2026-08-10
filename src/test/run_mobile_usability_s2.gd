extends Node

## iPad / mobile S2 usability (fixed-depth self-play + functional + perf).
## Writes user://s2_usability_result.json (+ selfplay jsonl) for devicectl copy-from.
## Pair with a temporary 4.6.1 export whose main scene is this script's scene.

const Eng = preload("res://addons/pikafish/pikafish.gd")
const Config = preload("res://addons/pikafish/config.gd")
const UciScore = preload("res://addons/pikafish/core/uci_score.gd")
const T = preload("res://addons/pikafish/core/types.gd")
const Reporter = preload("res://src/test/ui/test_reporter.gd")
const Dashboard = preload("res://src/test/ui/test_dashboard.gd")

const START_FEN := "rnbakabnr/9/1c5c1/p1p1p1p1p/9/9/P1P1P1P1P/1C5C1/9/RNBAKABNR w - - 0 1"
const RESULT_PATH := "user://s2_usability_result.json"
const SELFPLAY_PATH := "user://s2_selfplay.jsonl"
## Keep in sync with desktop USABILITY_DEPTH for cross-device comparison.
const DEPTH := 2
const MAX_PLIES := 120

const BENCH_FENS := [
	{"label": "opening_startpos", "fen": START_FEN},
	{
		"label": "midgame_ref1",
		"fen": "r1ba1a3/4kn3/2n1b4/pNp1p1p1p/4c4/6P2/P1P2R2P/1CcC5/9/2BAKAB2 w - - 0 1",
	},
	{
		"label": "complex_ref3",
		"fen": "2bak4/9/3a5/p2Np3p/3n1P3/3pc3P/P4r1c1/B2CC2R1/4A4/3AK1B2 b - - 0 1",
	},
	{
		"label": "endgame_ref21",
		"fen": "3k5/4a4/9/9/9/9/9/9/4A4/4K4 w - - 0 1",
	},
]

var _reporter
var _engine
var _out: Dictionary = {}


func _ready() -> void:
	_reporter = Reporter.new("S2 usability")
	var dashboard = Dashboard.new()
	add_child(dashboard)
	dashboard.bind(_reporter)
	call_deferred("_run")


func _run() -> void:
	_reporter.stage("Initialize NNUE engine")
	_out = {
		"marker": "S2_USABILITY_RUNNING",
		"phase": "Usability Candidate",
		"godot": Engine.get_version_info(),
		"os": OS.get_name(),
		"cpu": OS.get_processor_name(),
		"depth": DEPTH,
		"max_plies": MAX_PLIES,
		"device": "ios" if OS.get_name() == "iOS" else OS.get_name(),
	}
	var t0: int = Time.get_ticks_msec()
	_engine = Eng.new()
	var cfg = Config.new()
	cfg.prefer_gpu = true
	cfg.evaluation_mode = Config.EVALUATION_NNUE
	cfg.hash_mb = 16
	var err: Error = _engine.initialize(cfg)
	_out["cold_start_ms"] = Time.get_ticks_msec() - t0
	if err != OK:
		_fail("initialize")
		_finish(false)
		return
	_out["backend"] = _engine.backend_info()
	_reporter.metric("backend", _out["backend"].get("backend", "?"))
	_reporter.metric("cold_start_ms", _out["cold_start_ms"])

	_out["functional"] = _functional()
	_reporter.stage("Self-play depth=%d" % DEPTH)
	_out["self_play"] = _selfplay()
	_reporter.stage("Perf benches")
	_out["perf"] = _perf()

	var ok: bool = bool(_out["functional"].get("ok", false)) and bool(_out["self_play"].get("ok", false))
	_out["marker"] = "S2_USABILITY_PASS" if ok else "S2_USABILITY_FAIL"
	_finish(ok)


func _functional() -> Dictionary:
	var steps: Array = []
	var ok := true
	var err: Error = _engine.new_game()
	ok = ok and err == OK
	steps.append({"step": "new_game", "ok": err == OK})
	err = _engine.set_fen(START_FEN)
	ok = ok and err == OK
	var legal: PackedInt32Array = _engine.legal_moves()
	ok = ok and legal.size() == 44
	steps.append({"step": "legal_moves", "count": legal.size(), "ok": legal.size() == 44})
	err = _engine.start_search({"depth": 1, "sync": true})
	var got = _engine._last_result
	var s_ok: bool = err == OK and got != null and _engine.is_legal(got.bestmove)
	ok = ok and s_ok
	steps.append({"step": "search", "ok": s_ok, "best": _engine.move_to_uci(got.bestmove) if got else ""})
	if s_ok:
		ok = ok and _engine.push_move(got.bestmove) == OK
	ok = ok and _engine.new_game() == OK
	return {"ok": ok, "steps": steps}


func _selfplay() -> Dictionary:
	var out := FileAccess.open(SELFPLAY_PATH, FileAccess.WRITE)
	if out == null:
		return {"ok": false, "error": "jsonl_open"}
	assert(_engine.new_game() == OK)
	var t0: int = Time.get_ticks_msec()
	var cumulative := 0
	var red_ms := 0
	var black_ms := 0
	var move_ms: Array = []
	var plies := 0
	var terminal: Dictionary = {"result": "ongoing"}
	while plies < MAX_PLIES:
		terminal = _engine.game_result()
		if str(terminal.get("result", "ongoing")) != "ongoing":
			break
		if _engine.legal_moves().is_empty():
			terminal = _engine.game_result()
			break
		var view = _engine.get_position_view()
		var stm: String = "w" if int(view.side_to_move) == T.COLOR_WHITE else "b"
		var fen_before: String = _engine.get_fen()
		var tm0: int = Time.get_ticks_msec()
		var err: Error = _engine.start_search({"depth": DEPTH, "nodes": 50000, "sync": true})
		var dt: int = Time.get_ticks_msec() - tm0
		if err != OK or _engine._last_result == null or not _engine.is_legal(_engine._last_result.bestmove):
			terminal = {"result": "error", "reason": "search"}
			break
		var got = _engine._last_result
		cumulative += dt
		move_ms.append(dt)
		if stm == "w":
			red_ms += dt
		else:
			black_ms += dt
		var row := {
			"ply": plies,
			"side": stm,
			"move": _engine.move_to_uci(got.bestmove),
			"depth": got.completed_depth,
			"value": got.score,
			"cp": UciScore.to_cp(int(got.score), _engine._pos),
			"nodes": got.nodes,
			"time_ms": dt,
			"nps": int(float(got.nodes) * 1000.0 / float(dt)) if dt > 0 else 0,
			"cumulative_ms": cumulative,
			"rules": _engine.game_result(),
			"fen_before": fen_before,
		}
		out.store_string(JSON.stringify(row) + "\n")
		out.flush()
		_engine.push_move(got.bestmove)
		plies += 1
		if (plies % 5) == 0:
			_reporter.metric("selfplay_ply", plies)
	terminal = _engine.game_result() if str(terminal.get("result", "")) == "ongoing" else terminal
	out.store_string(JSON.stringify({
		"event": "terminal", "plies": plies, "terminal": terminal, "fen": _engine.get_fen(),
	}) + "\n")
	out.close()
	return {
		"ok": str(terminal.get("result", "")) != "error",
		"plies": plies,
		"terminal": terminal,
		"total_ms": Time.get_ticks_msec() - t0,
		"red_ms": red_ms,
		"black_ms": black_ms,
		"move_ms_stats": _stats(move_ms),
		"selfplay_path": SELFPLAY_PATH,
	}


func _perf() -> Dictionary:
	var positions: Array = []
	for entry in BENCH_FENS:
		assert(_engine.set_fen(str(entry["fen"])) == OK)
		_engine.start_search({"depth": DEPTH, "sync": true})
		var ms_only: Array = []
		var nps_only: Array = []
		for _i in range(3):
			assert(_engine.set_fen(str(entry["fen"])) == OK)
			var t0: int = Time.get_ticks_msec()
			assert(_engine.start_search({"depth": DEPTH, "sync": true}) == OK)
			var dt: int = Time.get_ticks_msec() - t0
			var got = _engine._last_result
			ms_only.append(dt)
			nps_only.append(int(float(got.nodes) * 1000.0 / float(dt)) if dt > 0 else 0)
		positions.append({
			"label": entry["label"],
			"ms_stats": _stats(ms_only),
			"nps_stats": _stats(nps_only),
		})
		_reporter.metric(str(entry["label"]) + "_mean_ms", _stats(ms_only).get("mean", 0))
	return {"depth": DEPTH, "positions": positions}


func _stats(values: Array) -> Dictionary:
	if values.is_empty():
		return {"n": 0}
	var xs: Array = values.duplicate()
	xs.sort()
	var n: int = xs.size()
	var sum := 0.0
	for v in xs:
		sum += float(v)
	var p95_i: int = mini(n - 1, int(ceil(0.95 * float(n))) - 1)
	return {
		"n": n,
		"mean": sum / float(n),
		"median": float(xs[n / 2]),
		"p95": float(xs[maxi(0, p95_i)]),
		"max": float(xs[n - 1]),
		"min": float(xs[0]),
	}


func _fail(msg: String) -> void:
	printerr("S2_USABILITY_FAIL: %s" % msg)
	_reporter.report_log(msg, "FAIL")


func _finish(ok: bool) -> void:
	_out["failures"] = 0 if ok else 1
	var f := FileAccess.open(RESULT_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(_out, "\t"))
		f.close()
	_reporter.stage("Done %s" % _out.get("marker", ""))
	print("S2_USABILITY_MOBILE marker=%s path=%s" % [_out.get("marker"), RESULT_PATH])
	await get_tree().create_timer(0.5).timeout
	get_tree().quit(0 if ok else 1)
