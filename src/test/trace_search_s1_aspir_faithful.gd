extends SceneTree

## S1: upstream-faithful depth1 aspiration (avg=-INF, delta from mean_squared init, TT kept)
const Eng = preload("res://addons/pikafish/pikafish.gd")
const Config = preload("res://addons/pikafish/config.gd")
const Worker = preload("res://addons/pikafish/search/search_worker.gd")
const NnueEval = preload("res://addons/pikafish/search/nnue_evaluator.gd")
const HistoryScript = preload("res://addons/pikafish/search/history.gd")
const TTScript = preload("res://addons/pikafish/search/tt.gd")
const T = preload("res://addons/pikafish/core/types.gd")
const FEN := "rnbakabnr/9/1c5c1/p1p1p1p1p/9/9/P1P1P1P1P/1C5C1/9/RNBAKABNR w - - 0 1"


func _init() -> void:
	var cfg = Config.new()
	cfg.prefer_gpu = false
	cfg.evaluation_mode = Config.EVALUATION_NNUE
	cfg.hash_mb = 64
	var engine = Eng.new()
	assert(engine.initialize(cfg) == OK)

	var mss: int = -T.VALUE_INFINITE * T.VALUE_INFINITE
	var delta0: int = 10 + absi(mss) / 39605
	print("delta0=%d mss=%d" % [delta0, mss])

	for clear_tt in [false, true]:
		var label := "keep_tt" if not clear_tt else "clear_tt"
		var r := _aspirate(engine, delta0, clear_tt)
		print("=== %s final_score=%d best=%s nodes=%d iters=%d ===" % [
			label, r["score"], r["best"], r["nodes"], r["iters"].size(),
		])
		for it in r["iters"]:
			print("  a=%d b=%d score=%d %s nodes+=%d best=%s" % [
				it["a"], it["b"], it["score"], it["tag"], it["dn"], it["best"],
			])

	engine.shutdown()
	print("S1_FAITHFUL_DONE")
	quit(0)


func _aspirate(engine, delta0: int, clear_tt_each: bool) -> Dictionary:
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

	var avg: int = -T.VALUE_INFINITE
	var delta: int = delta0
	var alpha: int = maxi(avg - delta, -T.VALUE_INFINITE)
	var beta: int = mini(avg + delta, T.VALUE_INFINITE)
	var iters: Array = []
	var score: int = T.VALUE_NONE
	for _k in range(20):
		if clear_tt_each:
			w.tt.clear()
			w.tt.new_search()
		w._set_root_optimism(avg)
		for rm in w.root_moves:
			rm.begin_iteration(true)
			rm.score = -T.VALUE_INFINITE
		var before: int = w.nodes
		score = w._search_root(1, alpha, beta)
		w._stable_sort_root_moves()
		var tag := "exact"
		if score <= alpha:
			tag = "fail_low"
		elif score >= beta:
			tag = "fail_high"
		iters.append({
			"a": alpha, "b": beta, "score": score, "tag": tag,
			"dn": w.nodes - before,
			"best": T.move_to_uci(w.root_moves[0].move()),
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
	return {
		"score": score,
		"best": T.move_to_uci(w.root_moves[0].move()),
		"nodes": w.nodes,
		"iters": iters,
	}
