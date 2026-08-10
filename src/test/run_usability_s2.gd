extends SceneTree

## S2 Usability Candidate — public-API functional + self-play + desktop perf.
## Usage:
##   Godot --headless --path . -s res://src/test/run_usability_s2.gd
## Env (optional):
##   USABILITY_DEPTH=3   fixed search depth for self-play and benches (default 3)
##   USABILITY_MAX_PLIES=200
## Writes:
##   /tmp/godot_s2_usability_report.json
##   /tmp/godot_s2_selfplay.jsonl

const Eng = preload("res://addons/pikafish/pikafish.gd")
const Config = preload("res://addons/pikafish/config.gd")
const UciScore = preload("res://addons/pikafish/core/uci_score.gd")
const T = preload("res://addons/pikafish/core/types.gd")

const START_FEN := "rnbakabnr/9/1c5c1/p1p1p1p1p/9/9/P1P1P1P1P/1C5C1/9/RNBAKABNR w - - 0 1"
const REPORT_PATH := "/tmp/godot_s2_usability_report.json"
const SELFPLAY_PATH := "/tmp/godot_s2_selfplay.jsonl"

## Opening / midgame / complex / endgame representatives (public API FENs).
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


func _init() -> void:
	var depth: int = int(OS.get_environment("USABILITY_DEPTH")) if not OS.get_environment("USABILITY_DEPTH").is_empty() else 2
	var max_plies: int = int(OS.get_environment("USABILITY_MAX_PLIES")) if not OS.get_environment("USABILITY_MAX_PLIES").is_empty() else 120
	depth = clampi(depth, 1, 8)
	max_plies = clampi(max_plies, 2, 400)

	var report := {
		"marker": "S2_USABILITY",
		"phase": "Usability Candidate",
		"commit": _git_head(),
		"godot": Engine.get_version_info(),
		"os": OS.get_name(),
		"cpu": OS.get_processor_name(),
		"threads_option": 1,
		"depth": depth,
		"max_plies": max_plies,
		"nnue": "res://data (via config.resolve_network_dir)",
	}

	var t_init0: int = Time.get_ticks_msec()
	var engine = Eng.new()
	var cfg = Config.new()
	cfg.prefer_gpu = false
	cfg.evaluation_mode = Config.EVALUATION_NNUE
	cfg.hash_mb = 16
	cfg.threads = 1
	var init_err: Error = engine.initialize(cfg)
	var init_ms: int = Time.get_ticks_msec() - t_init0
	report["cold_start_ms"] = init_ms
	report["init_error"] = error_string(init_err) if init_err != OK else "OK"
	if init_err != OK:
		_write_report(report)
		printerr("USABILITY_FAIL initialize")
		quit(1)
		return
	report["backend"] = engine.backend_info()
	print("INIT ok cold_start_ms=%d backend=%s" % [init_ms, str(report["backend"].get("backend", "?"))])

	report["functional"] = _phase_c_functional(engine)
	print("PHASE_C functional ok=%s" % str(report["functional"].get("ok", false)))

	report["self_play"] = _phase_d_selfplay(engine, depth, max_plies)
	print("PHASE_D selfplay plies=%s terminal=%s total_ms=%s" % [
		str(report["self_play"].get("plies", 0)),
		str(report["self_play"].get("terminal", {})),
		str(report["self_play"].get("total_ms", 0)),
	])

	report["perf"] = _phase_ef_perf(engine, depth)
	print("PHASE_EF perf benches=%d" % int(report["perf"].get("positions", []).size()))

	engine.shutdown()
	_write_report(report)
	print("S2_USABILITY_DONE report=%s selfplay=%s" % [REPORT_PATH, SELFPLAY_PATH])
	quit(0 if bool(report["functional"].get("ok", false)) else 1)


func _phase_c_functional(engine) -> Dictionary:
	var steps: Array = []
	var ok := true

	var err: Error = engine.new_game()
	steps.append({"step": "new_game", "ok": err == OK})
	ok = ok and err == OK

	err = engine.set_fen(START_FEN)
	steps.append({"step": "set_fen_startpos", "ok": err == OK, "fen": engine.get_fen()})
	ok = ok and err == OK

	var legal: PackedInt32Array = engine.legal_moves()
	steps.append({"step": "legal_moves", "ok": legal.size() == 44, "count": legal.size()})
	ok = ok and legal.size() == 44

	err = engine.start_search({"depth": 1, "sync": true})
	var got = engine._last_result
	var best_uci: String = engine.move_to_uci(got.bestmove) if got != null else ""
	var search_ok: bool = err == OK and got != null and engine.is_legal(got.bestmove)
	steps.append({
		"step": "search_depth1",
		"ok": search_ok,
		"bestmove": best_uci,
		"score": got.score if got else null,
		"nodes": got.nodes if got else null,
	})
	ok = ok and search_ok

	err = engine.push_move(got.bestmove)
	steps.append({"step": "push_bestmove", "ok": err == OK, "fen": engine.get_fen()})
	ok = ok and err == OK

	err = engine.start_search({"depth": 1, "sync": true})
	got = engine._last_result
	var cont_ok: bool = err == OK and got != null and engine.is_legal(got.bestmove)
	steps.append({
		"step": "search_continue",
		"ok": cont_ok,
		"bestmove": engine.move_to_uci(got.bestmove) if got else "",
	})
	ok = ok and cont_ok
	if cont_ok:
		engine.push_move(got.bestmove)

	# Artificial terminal: empty-legal mate-like via known mate net if available; else rule check ongoing.
	var gr: Dictionary = engine.game_result()
	steps.append({"step": "game_result_mid", "ok": gr.get("result", "") != "unavailable", "result": gr})

	err = engine.new_game()
	steps.append({"step": "reset_new_game", "ok": err == OK, "fen": engine.get_fen()})
	ok = ok and err == OK and engine.get_fen().begins_with("rnbakabnr")

	# Terminal API probe on a tactical midgame fixture (ongoing expected).
	err = engine.set_fen("5a3/3k5/3aR4/9/5r3/5n3/9/3A1A3/5K3/2BC2B2 w - - 0 1")
	var after_set := err == OK
	var terminal_probe: Dictionary = engine.game_result()
	steps.append({
		"step": "terminal_probe_ongoing_or_claim",
		"ok": after_set,
		"result": terminal_probe,
	})
	ok = ok and after_set

	err = engine.new_game()
	var reset_ok: bool = err == OK
	steps.append({"step": "final_reset", "ok": reset_ok})
	ok = ok and reset_ok

	return {"ok": ok, "steps": steps}


func _phase_d_selfplay(engine, depth: int, max_plies: int) -> Dictionary:
	var out := FileAccess.open(SELFPLAY_PATH, FileAccess.WRITE)
	if out == null:
		return {"ok": false, "error": "cannot write selfplay jsonl"}

	assert(engine.new_game() == OK)
	var t0: int = Time.get_ticks_msec()
	var cumulative_ms: int = 0
	var red_ms: int = 0
	var black_ms: int = 0
	var move_ms: Array = []
	var plies := 0
	var terminal: Dictionary = {"result": "ongoing"}

	while plies < max_plies:
		var fen_before: String = engine.get_fen()
		var view = engine.get_position_view()
		var stm: String = "w" if int(view.side_to_move) == T.COLOR_WHITE else "b"
		terminal = engine.game_result()
		if str(terminal.get("result", "ongoing")) != "ongoing":
			break
		var legal: PackedInt32Array = engine.legal_moves()
		if legal.is_empty():
			terminal = engine.game_result()
			break

		var t_move0: int = Time.get_ticks_msec()
		# Depth primary; nodes cap prevents rare endgame search blow-ups.
		var err: Error = engine.start_search({"depth": depth, "nodes": 50000, "sync": true})
		var dt: int = Time.get_ticks_msec() - t_move0
		if err != OK or engine._last_result == null:
			terminal = {"result": "error", "reason": "search_failed", "err": error_string(err)}
			break
		var got = engine._last_result
		if not engine.is_legal(got.bestmove):
			terminal = {"result": "error", "reason": "illegal_bestmove", "uci": engine.move_to_uci(got.bestmove)}
			break

		cumulative_ms += dt
		move_ms.append(dt)
		if stm == "w":
			red_ms += dt
		else:
			black_ms += dt

		var nps: float = (float(got.nodes) * 1000.0 / float(dt)) if dt > 0 else 0.0
		var row := {
			"ply": plies,
			"side": stm,
			"move": engine.move_to_uci(got.bestmove),
			"depth": got.completed_depth,
			"value": got.score,
			"cp": UciScore.to_cp(int(got.score), engine._pos),
			"nodes": got.nodes,
			"time_ms": dt,
			"nps": int(nps),
			"cumulative_ms": cumulative_ms,
			"rules": engine.game_result(),
			"fen_before": fen_before,
		}
		out.store_string(JSON.stringify(row) + "\n")
		out.flush()
		engine.push_move(got.bestmove)
		plies += 1
		if (plies % 10) == 0:
			print("SELFPLAY ply=%d move=%s cum_ms=%d" % [plies, row["move"], cumulative_ms])

	terminal = engine.game_result() if str(terminal.get("result", "")) == "ongoing" else terminal
	var end_row := {
		"event": "terminal",
		"plies": plies,
		"terminal": terminal,
		"fen": engine.get_fen(),
		"total_ms": Time.get_ticks_msec() - t0,
	}
	out.store_string(JSON.stringify(end_row) + "\n")
	out.close()

	return {
		"ok": str(terminal.get("result", "")) != "error",
		"plies": plies,
		"terminal": terminal,
		"total_ms": Time.get_ticks_msec() - t0,
		"red_ms": red_ms,
		"black_ms": black_ms,
		"move_ms_stats": _stats(move_ms),
		"jsonl": SELFPLAY_PATH,
		"depth": depth,
		"hit_max_plies": plies >= max_plies,
	}


func _phase_ef_perf(engine, depth: int) -> Dictionary:
	var positions: Array = []
	var all_ms: Array = []
	for entry in BENCH_FENS:
		assert(engine.set_fen(str(entry["fen"])) == OK)
		var samples: Array = []
		# Warm-up discarded.
		engine.start_search({"depth": depth, "sync": true})
		for _i in range(5):
			assert(engine.set_fen(str(entry["fen"])) == OK)
			var t0: int = Time.get_ticks_msec()
			assert(engine.start_search({"depth": depth, "sync": true}) == OK)
			var dt: int = Time.get_ticks_msec() - t0
			var got = engine._last_result
			samples.append({
				"ms": dt,
				"nodes": got.nodes,
				"nps": int(float(got.nodes) * 1000.0 / float(dt)) if dt > 0 else 0,
				"best": engine.move_to_uci(got.bestmove),
				"value": got.score,
				"cp": UciScore.to_cp(int(got.score), engine._pos),
				"depth": got.completed_depth,
			})
			all_ms.append(dt)
		var ms_only: Array = []
		var nps_only: Array = []
		for s in samples:
			ms_only.append(int(s["ms"]))
			nps_only.append(int(s["nps"]))
		positions.append({
			"label": entry["label"],
			"fen": entry["fen"],
			"samples": samples,
			"ms_stats": _stats(ms_only),
			"nps_stats": _stats(nps_only),
		})
		print("PERF %s mean_ms=%s p95=%s mean_nps=%s" % [
			entry["label"],
			str(_stats(ms_only).get("mean")),
			str(_stats(ms_only).get("p95")),
			str(_stats(nps_only).get("mean")),
		])

	return {
		"depth": depth,
		"positions": positions,
		"all_move_ms_stats": _stats(all_ms),
		"note": "per-move search only; cold_start_ms recorded separately",
	}


func _stats(values: Array) -> Dictionary:
	if values.is_empty():
		return {"n": 0}
	var xs: Array = values.duplicate()
	xs.sort()
	var n: int = xs.size()
	var sum := 0.0
	for v in xs:
		sum += float(v)
	var mean: float = sum / float(n)
	var mid: float
	if n % 2 == 1:
		mid = float(xs[n / 2])
	else:
		mid = 0.5 * (float(xs[n / 2 - 1]) + float(xs[n / 2]))
	var p95_i: int = mini(n - 1, int(ceil(0.95 * float(n))) - 1)
	p95_i = maxi(0, p95_i)
	return {
		"n": n,
		"mean": mean,
		"median": mid,
		"p95": float(xs[p95_i]),
		"max": float(xs[n - 1]),
		"min": float(xs[0]),
	}


func _git_head() -> String:
	var out: Array = []
	var err: int = OS.execute("git", ["-C", ProjectSettings.globalize_path("res://"), "rev-parse", "--short", "HEAD"], out, true)
	if err != 0 or out.is_empty():
		return "unknown"
	return str(out[0]).strip_edges()


func _write_report(report: Dictionary) -> void:
	var f := FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	if f == null:
		printerr("cannot write %s" % REPORT_PATH)
		return
	f.store_string(JSON.stringify(report, "\t"))
	f.close()
