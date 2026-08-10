extends SceneTree

## S1: score the single qsearch capture h7h0 after b2e2
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
	var engine = Eng.new()
	assert(engine.initialize(cfg) == OK)
	assert(engine.set_fen(FEN) == OK)
	var w = Worker.new()
	w.pos = engine._pos
	w.tt = TTScript.new()
	w.tt.resize_mb(16)
	w.tt.clear()
	w.history = HistoryScript.new()
	w.evaluator = NnueEval.new(engine.loader, engine.features)
	w.evaluator.begin(w.pos)
	w._ensure_helpers()
	w._pv_stack.clear()
	for _i in range(16):
		w._pv_stack.append(PackedInt32Array())

	w._do_move_synced(T.uci_to_move("b2e2"))
	var stand: int = w.evaluator.evaluate(w.pos)
	print("stand=%d" % stand)

	var cap: int = T.uci_to_move("h7h0")
	print("cap legal=%s capture=%s see_ge(-106)=%s piece_on_to=%d" % [
		w.pos.legal(cap), w.pos.capture(cap), w.pos.see_ge(cap, -106), w.pos.piece_on(T.to_sq(cap)),
	])

	w._do_move_synced(cap)
	var child_stand: int = w.evaluator.evaluate(w.pos)
	print("after h7h0 stm=%d child_stand=%d fen_side_hint" % [w.pos.side_to_move, child_stand])
	w.nodes = 0
	var child_qs: int = w._qsearch(true, -T.VALUE_INFINITE, T.VALUE_INFINITE, 2)
	print("child_qsearch=%d nodes=%d" % [child_qs, w.nodes])
	print("negated_for_parent=%d (compare to stand %d)" % [-child_qs, stand])
	w._undo_move_synced(cap)

	# Also: does Godot qsearch miss futility update of bestValue?
	# Re-run parent qsearch with logging via manual loop
	w.nodes = 0
	var alpha: int = -T.VALUE_INFINITE
	var beta: int = T.VALUE_INFINITE
	var best: int = stand
	if stand > alpha:
		alpha = stand
	w._do_move_synced(cap)
	var score: int = -w._qsearch(true, -beta, -alpha, 2)
	w._undo_move_synced(cap)
	print("manual_cap_score=%d alpha_was_stand_updated best_would=%d" % [score, maxi(best, score)])

	engine.shutdown()
	print("S1_CAP_DONE")
	quit(0)
