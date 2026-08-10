extends SceneTree

## S1: isolate depth-1 PV child after b2e2 — eval / qsearch / search(d=0)
const Eng = preload("res://addons/pikafish/pikafish.gd")
const Config = preload("res://addons/pikafish/config.gd")
const Worker = preload("res://addons/pikafish/search/search_worker.gd")
const NnueEval = preload("res://addons/pikafish/search/nnue_evaluator.gd")
const HistoryScript = preload("res://addons/pikafish/search/history.gd")
const TTScript = preload("res://addons/pikafish/search/tt.gd")
const MP = preload("res://addons/pikafish/search/move_picker.gd")
const T = preload("res://addons/pikafish/core/types.gd")

const FEN := "rnbakabnr/9/1c5c1/p1p1p1p1p/9/9/P1P1P1P1P/1C5C1/9/RNBAKABNR w - - 0 1"


func _init() -> void:
	var cfg = Config.new()
	cfg.prefer_gpu = false
	cfg.evaluation_mode = Config.EVALUATION_NNUE
	cfg.hash_mb = 64
	var engine = Eng.new()
	assert(engine.initialize(cfg) == OK)
	assert(engine.set_fen(FEN) == OK)

	var worker = Worker.new()
	worker.pos = engine._pos
	worker.tt = TTScript.new()
	worker.tt.resize_mb(64)
	worker.tt.clear()
	worker.history = HistoryScript.new()
	worker.evaluator = NnueEval.new(engine.loader, engine.features)
	worker.evaluator.begin(worker.pos)
	worker.nodes = 0
	worker._ensure_helpers()
	worker._pv_stack.clear()
	for _i in range(16):
		worker._pv_stack.append(PackedInt32Array())

	var terms0: Dictionary = worker.evaluator._accumulator.evaluate_terms(worker.evaluator._board)
	var v0: int = worker.evaluator.evaluate(worker.pos)
	print("ROOT eval=%d psqt=%d positional=%d major_mat=%d" % [
		v0, int(terms0["psqt"]), int(terms0["positional"]), worker.pos.major_material(),
	])

	var move: int = T.uci_to_move("b2e2")
	worker._do_move_synced(move)

	var terms1: Dictionary = worker.evaluator._accumulator.evaluate_terms(worker.evaluator._board)
	var stand: int = worker.evaluator.evaluate(worker.pos)
	print("AFTER b2e2 stm=%d stand=%d psqt=%d positional=%d major_mat=%d" % [
		worker.pos.side_to_move, stand, int(terms1["psqt"]), int(terms1["positional"]),
		worker.pos.major_material(),
	])
	print("finalize raw_nnue=%d complexity=%d" % [
		int(terms1["psqt"]) + int(terms1["positional"]),
		absi(int(terms1["psqt"]) - int(terms1["positional"])),
	])

	# qsearch moves at this node
	var picker = MP.new()
	picker.init_main(worker.pos, T.MOVE_NONE, 0, worker.history, 1, worker._cont_hist_for_picker(1))
	var qs_moves: PackedStringArray = PackedStringArray()
	while true:
		var m: int = picker.next_move()
		if m == T.MOVE_NONE:
			break
		if not worker.pos.legal(m):
			continue
		qs_moves.append("%s%s" % [T.move_to_uci(m), ("x" if worker.pos.capture(m) else "")])
	print("QSEARCH_CANDIDATES count=%d moves=%s" % [qs_moves.size(), " ".join(qs_moves)])

	worker.nodes = 0
	var qs: int = worker._qsearch(true, -T.VALUE_INFINITE, T.VALUE_INFINITE, 1)
	print("QSEARCH_PV open_window value=%d nodes=%d" % [qs, worker.nodes])

	worker.nodes = 0
	var s0: int = worker._search(worker.NODE_PV, 0, -T.VALUE_INFINITE, T.VALUE_INFINITE, 1, false)
	print("SEARCH_D0_PV value=%d nodes=%d" % [s0, worker.nodes])
	print("ROOT_SCORE_FROM_CHILD=%d (expect -qsearch)" % -qs)

	engine.shutdown()
	print("S1_CHILD_DONE")
	quit(0)
