extends SceneTree

## S1: reproduce Pikafish depth-1 aspiration/optimism vs Godot open-window.
## Does NOT modify production search; drives Worker APIs from a harness only.
const Eng = preload("res://addons/pikafish/pikafish.gd")
const Config = preload("res://addons/pikafish/config.gd")
const Worker = preload("res://addons/pikafish/search/search_worker.gd")
const NnueEval = preload("res://addons/pikafish/search/nnue_evaluator.gd")
const HistoryScript = preload("res://addons/pikafish/search/history.gd")
const TTScript = preload("res://addons/pikafish/search/tt.gd")
const T = preload("res://addons/pikafish/core/types.gd")
const FEN := "rnbakabnr/9/1c5c1/p1p1p1p1p/9/9/P1P1P1P1P/1C5C1/9/RNBAKABNR w - - 0 1"
const OUT := "/tmp/godot_s1_aspiration_repro.jsonl"


func _init() -> void:
	var out := FileAccess.open(OUT, FileAccess.WRITE)
	var cfg = Config.new()
	cfg.prefer_gpu = false
	cfg.evaluation_mode = Config.EVALUATION_NNUE
	cfg.hash_mb = 64
	var engine = Eng.new()
	assert(engine.initialize(cfg) == OK)

	# --- A: production-like depth1 (open window, optimism from avg=0) ---
	var a := _run_case(engine, {
		"label": "godot_prod_depth1",
		"use_aspiration": false,
		"avg_for_optimism": 0,
		"alpha": -T.VALUE_INFINITE,
		"beta": T.VALUE_INFINITE,
	})
	out.store_string(JSON.stringify(a) + "\n")
	print("A prod: best=%s score=%d nodes=%d" % [a["bestmove"], a["score"], a["nodes"]])

	# --- B: upstream-like initial aspiration with avg=-INF (NO fallback) ---
	var avg: int = -T.VALUE_INFINITE
	var delta: int = 10
	var alpha: int = maxi(avg - delta, -T.VALUE_INFINITE)
	var beta: int = mini(avg + delta, T.VALUE_INFINITE)
	var b := _run_aspiration(engine, avg, alpha, beta, delta, "upstream_aspir_depth1")
	out.store_string(JSON.stringify(b) + "\n")
	print("B upstream-aspir: best=%s score=%d nodes=%d iters=%d" % [
		b["bestmove"], b["score"], b["nodes"], b["aspir_iters"].size(),
	])
	for it in b["aspir_iters"]:
		print("  aspir alpha=%d beta=%d score=%d result=%s" % [
			it["alpha"], it["beta"], it["score"], it["result"],
		])

	# --- C: only optimism from avg=-INF, but open window ---
	var c := _run_case(engine, {
		"label": "optimism_neg_inf_open_window",
		"use_aspiration": false,
		"avg_for_optimism": -T.VALUE_INFINITE,
		"alpha": -T.VALUE_INFINITE,
		"beta": T.VALUE_INFINITE,
	})
	out.store_string(JSON.stringify(c) + "\n")
	print("C optimism-only: best=%s score=%d nodes=%d" % [c["bestmove"], c["score"], c["nodes"]])

	out.close()
	engine.shutdown()
	print("S1_ASPIR_DONE report=%s" % OUT)
	quit(0)


func _make_worker(engine) -> Worker:
	assert(engine.set_fen(FEN) == OK)
	var w = Worker.new()
	w.pos = engine._pos
	w.tt = TTScript.new()
	w.tt.resize_mb(64)
	w.tt.clear()
	w.tt.new_search()
	w.history = HistoryScript.new()
	w.evaluator = NnueEval.new(engine.loader, engine.features)
	w.evaluator.begin(w.pos)
	w.nodes = 0
	w.seldepth = 0
	w._ensure_helpers()
	w._init_search_stack()
	w._init_root_moves()
	w._pv_stack.clear()
	for _i in range(64):
		w._pv_stack.append(PackedInt32Array())
	return w


func _run_case(engine, opts: Dictionary) -> Dictionary:
	var w = _make_worker(engine)
	w._set_root_optimism(int(opts["avg_for_optimism"]))
	var score: int = w._search_root(1, int(opts["alpha"]), int(opts["beta"]))
	w._stable_sort_root_moves()
	var tops: Array = []
	for i in range(mini(5, w.root_moves.size())):
		var rm = w.root_moves[i]
		if int(rm.score) == -T.VALUE_INFINITE:
			continue
		tops.append({"move": T.move_to_uci(rm.move()), "score": int(rm.score)})
	return {
		"label": opts["label"],
		"bestmove": T.move_to_uci(w.root_moves[0].move()) if not w.root_moves.is_empty() else "",
		"score": score,
		"nodes": w.nodes,
		"top": tops,
		"optimism_avg": int(opts["avg_for_optimism"]),
		"alpha": int(opts["alpha"]),
		"beta": int(opts["beta"]),
	}


func _run_aspiration(engine, avg: int, alpha0: int, beta0: int, delta0: int, label: String) -> Dictionary:
	var w = _make_worker(engine)
	var alpha := alpha0
	var beta := beta0
	var delta := delta0
	var iters: Array = []
	var score: int = T.VALUE_NONE
	for _k in range(16):
		w._set_root_optimism(avg)
		# Reset root move scores between aspiration re-searches like begin_iteration
		for rm in w.root_moves:
			rm.begin_iteration(true)
			rm.score = -T.VALUE_INFINITE
		var before: int = w.nodes
		score = w._search_root(1, alpha, beta)
		w._stable_sort_root_moves()
		var result := "exact"
		if score <= alpha:
			result = "fail_low"
		elif score >= beta:
			result = "fail_high"
		iters.append({
			"alpha": alpha, "beta": beta, "delta": delta, "score": score,
			"result": result, "nodes_delta": w.nodes - before,
			"best": T.move_to_uci(w.root_moves[0].move()) if not w.root_moves.is_empty() else "",
		})
		if score <= alpha:
			beta = alpha
			alpha = maxi(score - delta, -T.VALUE_INFINITE)
			delta += 44 * delta / 128
		elif score >= beta:
			alpha = maxi(beta - delta, alpha)
			beta = mini(score + delta, T.VALUE_INFINITE)
			delta += 44 * delta / 128
		else:
			break
	var tops: Array = []
	for i in range(mini(5, w.root_moves.size())):
		var rm = w.root_moves[i]
		if int(rm.score) == -T.VALUE_INFINITE:
			continue
		tops.append({"move": T.move_to_uci(rm.move()), "score": int(rm.score)})
	return {
		"label": label,
		"bestmove": T.move_to_uci(w.root_moves[0].move()) if not w.root_moves.is_empty() else "",
		"score": score,
		"nodes": w.nodes,
		"top": tops,
		"aspir_iters": iters,
		"avg": avg,
	}
