extends SceneTree

## SearchParity S1: startpos @ 256 nodes — ID / root summary harness.
## Zero production search-behavior change (uses public Eng + info_cb side effects only).
## Usage:
##   Godot --headless --path . -s res://src/test/trace_search_s1_startpos256.gd
## Writes /tmp/godot_s1_startpos256.jsonl

const Eng = preload("res://addons/pikafish/pikafish.gd")
const Config = preload("res://addons/pikafish/config.gd")
const T = preload("res://addons/pikafish/core/types.gd")

const FEN := "rnbakabnr/9/1c5c1/p1p1p1p1p/9/9/P1P1P1P1P/1C5C1/9/RNBAKABNR w - - 0 1"
const BUDGET := 256
const OUT_PATH := "/tmp/godot_s1_startpos256.jsonl"
const HASH_MB := 64


func _init() -> void:
	var out := FileAccess.open(OUT_PATH, FileAccess.WRITE)
	if out == null:
		printerr("S1_FAIL: cannot write %s" % OUT_PATH)
		quit(1)
		return

	var cfg = Config.new()
	cfg.prefer_gpu = false
	cfg.evaluation_mode = Config.EVALUATION_NNUE
	cfg.hash_mb = HASH_MB

	var engine = Eng.new()
	if engine.initialize(cfg) != OK:
		printerr("S1_FAIL: initialize")
		quit(1)
		return
	if engine.set_fen(FEN) != OK:
		printerr("S1_FAIL: set_fen")
		quit(1)
		return

	# Fresh TT generation + clear history for deterministic start.
	if engine._tt != null:
		engine._tt.clear()
		engine._tt.new_search()
	engine._history = null

	var iterations: Array = []
	engine.search_info.connect(func(info) -> void:
		if info == null:
			return
		if bool(info.is_final):
			return
		var roots: Array = []
		var worker = engine._worker
		if worker != null:
			for i in range(mini(worker.root_moves.size(), 44)):
				var rm = worker.root_moves[i]
				var sc: int = int(rm.score)
				# Keep scored / PV-ish root moves + first few unscored for ordering evidence.
				if sc == -T.VALUE_INFINITE and i >= 12:
					continue
				roots.append({
					"order": i,
					"move": T.move_to_uci(rm.move()),
					"score": sc,
					"previous_score": int(rm.previous_score),
					"average_score": int(rm.average_score),
					"effort": int(rm.effort),
					"upperbound": bool(rm.score_upperbound),
					"lowerbound": bool(rm.score_lowerbound),
					"pv": _pv_uci(rm.pv),
				})
		var row := {
			"event": "ITERATION",
			"depth": int(info.depth),
			"seldepth": int(info.seldepth),
			"score": int(info.score),
			"nodes": int(info.nodes),
			"pv": _pv_uci(info.pv),
			"root_moves": roots,
		}
		iterations.append(row)
		out.store_string(JSON.stringify(row) + "\n")
	)

	if engine.start_search({"nodes": BUDGET, "sync": true}) != OK:
		printerr("S1_FAIL: start_search")
		quit(1)
		return

	var got = engine._last_result
	var final_roots: Array = []
	var worker = engine._worker
	if worker != null:
		for i in range(worker.root_moves.size()):
			var rm = worker.root_moves[i]
			final_roots.append({
				"order": i,
				"move": T.move_to_uci(rm.move()),
				"score": int(rm.score),
				"previous_score": int(rm.previous_score),
				"average_score": int(rm.average_score),
				"effort": int(rm.effort),
				"upperbound": bool(rm.score_upperbound),
				"lowerbound": bool(rm.score_lowerbound),
				"pv": _pv_uci(rm.pv),
			})

	var summary := {
		"event": "FINAL",
		"bestmove": engine.move_to_uci(got.bestmove),
		"score": got.score,
		"nodes": got.nodes,
		"completed_depth": got.completed_depth,
		"stop_reason": got.stop_reason,
		"incomplete": got.incomplete,
		"from_complete_iteration": got.from_complete_iteration,
		"pv": _pv_uci(got.pv),
		"iterations": iterations.size(),
		"root_moves_top": final_roots.slice(0, mini(16, final_roots.size())),
		"hash_mb": HASH_MB,
		"budget": BUDGET,
		"fen": FEN,
	}
	out.store_string(JSON.stringify(summary) + "\n")
	out.close()

	print("=== S1 Godot startpos@%d hash=%d ===" % [BUDGET, HASH_MB])
	for it in iterations:
		print("ITER depth=%d score=%d nodes=%d pv=%s roots_logged=%d" % [
			it["depth"], it["score"], it["nodes"], " ".join(it["pv"]), it["root_moves"].size(),
		])
		for rm in it["root_moves"]:
			if int(rm["score"]) == -T.VALUE_INFINITE:
				continue
			print("  #%d %s score=%d effort=%d ub=%s lb=%s" % [
				rm["order"], rm["move"], rm["score"], rm["effort"],
				rm["upperbound"], rm["lowerbound"],
			])
	print("FINAL best=%s score=%d depth=%d nodes=%d reason=%s incomplete=%s" % [
		summary["bestmove"], summary["score"], summary["completed_depth"],
		summary["nodes"], summary["stop_reason"], summary["incomplete"],
	])
	print("S1_GODOT_DONE report=%s" % OUT_PATH)
	engine.shutdown()
	quit(0)


func _pv_uci(pv) -> PackedStringArray:
	var result := PackedStringArray()
	if pv == null:
		return result
	if typeof(pv) == TYPE_PACKED_INT32_ARRAY or typeof(pv) == TYPE_ARRAY:
		for m in pv:
			result.append(T.move_to_uci(int(m)))
	return result
