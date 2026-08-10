extends SceneTree

## S2: compare eval/qsearch after b2e2 then h7h0 (first ply1 move).
## Writes /tmp/godot_s2_h7h0.jsonl

const Eng = preload("res://addons/pikafish/pikafish.gd")
const Config = preload("res://addons/pikafish/config.gd")
const Worker = preload("res://addons/pikafish/search/search_worker.gd")
const NnueEval = preload("res://addons/pikafish/search/nnue_evaluator.gd")
const HistoryScript = preload("res://addons/pikafish/search/history.gd")
const TTScript = preload("res://addons/pikafish/search/tt.gd")
const MP = preload("res://addons/pikafish/search/move_picker.gd")
const UciScore = preload("res://addons/pikafish/core/uci_score.gd")
const T = preload("res://addons/pikafish/core/types.gd")

const FEN := "rnbakabnr/9/1c5c1/p1p1p1p1p/9/9/P1P1P1P1P/1C5C1/9/RNBAKABNR w - - 0 1"
const OUT := "/tmp/godot_s2_h7h0.jsonl"


func _init() -> void:
	var out := FileAccess.open(OUT, FileAccess.WRITE)
	var cfg = Config.new()
	cfg.prefer_gpu = false
	cfg.evaluation_mode = Config.EVALUATION_NNUE
	cfg.hash_mb = 16
	var engine = Eng.new()
	assert(engine.initialize(cfg) == OK)
	assert(engine.set_fen(FEN) == OK)

	var w = Worker.new()
	w.pos = engine._pos
	w.tt = TTScript.new()
	w.tt.resize_mb(16)
	w.tt.clear()
	w.tt.new_search()
	w.history = HistoryScript.new()
	w.evaluator = NnueEval.new(engine.loader, engine.features)
	w.nodes = 0
	w.seldepth = 0
	w._ensure_helpers()
	w._init_search_stack()
	w._init_root_moves()
	w.evaluator.begin(w.pos)
	w._pv_stack.clear()
	w._pv_stack.resize(Worker.SS_SIZE)
	for i in range(Worker.SS_SIZE):
		w._pv_stack[i] = PackedInt32Array()

	# Seed d1 like production
	_run_depth(w, 1)
	print("after_d1 nodes=%d score=%d" % [w.nodes, w.best_score])

	# d2 optimism
	var avg := 55
	w._set_root_optimism(avg)
	var opt_w: int = int(w.evaluator.get("_optimism")[0])
	var opt_b: int = int(w.evaluator.get("_optimism")[1])
	print("optimism w=%d b=%d" % [opt_w, opt_b])

	var b2e2: int = T.uci_to_move("b2e2")
	var h7h0: int = T.uci_to_move("h7h0")

	w._do_move_synced(b2e2)
	var eval_b: int = w._eval()
	var terms_b = w.evaluator._accumulator.evaluate_terms(w.evaluator._board)
	print("AFTER b2e2 stm=%d eval=%d psqt=%d pos=%d" % [
		w.pos.side_to_move, eval_b, int(terms_b["psqt"]), int(terms_b["positional"]),
	])

	# TT at this node?
	var tt1: Dictionary = w._tt_probe()
	print("TT_after_b2e2 found=%s value=%s eval=%s depth=%s move=%s" % [
		str(tt1.get("found")), str(tt1.get("value")), str(tt1.get("eval")),
		str(tt1.get("depth")), T.move_to_uci(int(tt1.get("move", 0))) if int(tt1.get("move", 0)) != 0 else "",
	])

	w._do_move_synced(h7h0)
	var eval_w: int = w._eval()
	var terms_w = w.evaluator._accumulator.evaluate_terms(w.evaluator._board)
	print("AFTER h7h0 stm=%d eval=%d psqt=%d pos=%d major=%d" % [
		w.pos.side_to_move, eval_w, int(terms_w["psqt"]), int(terms_w["positional"]),
		w.pos.major_material(),
	])
	print("finalize_terms check: side_opt=%d" % opt_w)

	var tt2: Dictionary = w._tt_probe()
	print("TT_after_h7h0 found=%s value=%s eval=%s depth=%s bound=%s move=%s" % [
		str(tt2.get("found")), str(tt2.get("value")), str(tt2.get("eval")),
		str(tt2.get("depth")), str(tt2.get("bound")),
		T.move_to_uci(int(tt2.get("move", 0))) if int(tt2.get("move", 0)) != 0 else "",
	])

	# qsearch mirrors: after b2e2 child calls -qsearch(PV, -(-45), -(-65)) = -qsearch(PV, 45, 65)
	# wait: child window alpha=-65 beta=-45, first move:
	# value = -_search(PV, 0, -beta, -alpha) = -_qsearch(PV, 45, 65, ply2)
	w.nodes = 0
	var qs_narrow: int = w._qsearch(true, 45, 65, 2)
	print("QS_PV window[45,65] value=%d nodes=%d (PF expects ~262)" % [qs_narrow, w.nodes])

	w.nodes = 0
	var qs_open: int = w._qsearch(true, -T.VALUE_INFINITE, T.VALUE_INFINITE, 2)
	print("QS_PV open value=%d nodes=%d" % [qs_open, w.nodes])

	w.nodes = 0
	var qs_nonpv: int = w._qsearch(false, 45, 65, 2)
	print("QS_NonPV window[45,65] value=%d nodes=%d" % [qs_nonpv, w.nodes])

	# List qsearch candidates and first few scores
	var picker = MP.new()
	picker.init_main(w.pos, T.MOVE_NONE, 0, w.history, 2, w._cont_hist_for_picker(2))
	var cands: Array = []
	while true:
		var m: int = picker.next_move()
		if m == T.MOVE_NONE:
			break
		if not w.pos.legal(m):
			continue
		var before := int(w.nodes)
		w._do_move_synced(m)
		var sc: int = -w._qsearch(true, -65, -45, 3)
		w._undo_move_synced(m)
		cands.append({
			"move": T.move_to_uci(m),
			"cap": w.pos.capture(m),
			"score": sc,
			"nodes": int(w.nodes) - before,
		})
		if cands.size() >= 12:
			break
	print("QS_CANDIDATES (first 12 under parent window):")
	for c in cands:
		print("  %s cap=%s score=%d nodes=%d" % [c["move"], str(c["cap"]), c["score"], c["nodes"]])

	var row := {
		"eval_after_b2e2": eval_b,
		"eval_after_h7h0": eval_w,
		"qs_narrow": qs_narrow,
		"qs_open": qs_open,
		"tt_h7h0": tt2,
		"cands": cands,
		"optimism": {"w": opt_w, "b": opt_b},
	}
	out.store_string(JSON.stringify(row) + "\n")
	out.close()
	engine.shutdown()
	print("S2_H7H0_DONE")
	quit(0)


func _run_depth(w, depth: int) -> void:
	for rm in w.root_moves:
		rm.begin_iteration(true)
	var root_average: int = int(w.root_moves[0].average_score)
	var root_variance: int = int(w.root_moves[0].mean_squared_score)
	var delta: int = 10 + absi(root_variance) / 39605
	var alpha: int = maxi(root_average - delta, -T.VALUE_INFINITE)
	var beta: int = mini(root_average + delta, T.VALUE_INFINITE)
	w.reductions.set_root_delta(beta - alpha)
	var score: int = T.VALUE_NONE
	var guard := 0
	while true:
		guard += 1
		w._set_root_optimism(root_average)
		score = w._search_root(depth, alpha, beta)
		w._stable_sort_root_moves()
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
		if guard > 24:
			break
	w.best_score = score
	w.best_move = w.root_moves[0].move()
	w.pv = w.root_moves[0].pv.duplicate()
