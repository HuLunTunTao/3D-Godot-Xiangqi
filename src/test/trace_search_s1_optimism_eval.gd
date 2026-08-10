extends SceneTree

## S1: eval after b2e2 under different optimism; full d1 with upstream-like delta from mean_squared init
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
	var ev = NnueEval.new(engine.loader, engine.features)
	ev.begin(engine._pos)
	engine._pos.do_move(T.uci_to_move("b2e2"))
	ev.do_move(T.uci_to_move("b2e2"))

	for avg in [0, -T.VALUE_INFINITE, 14, 116, 119, -100, 50]:
		var opt: int = 92 * avg / (absi(avg) + 95)
		# black to move => uses -opt if root was white with +opt on white
		# _set_root_optimism(avg): white gets value, black gets -value
		var opt_stm: int = -opt  # black
		ev.set_optimism(opt, -opt)  # white, black as _set_root_optimism does for white root
		var v: int = ev.evaluate(engine._pos)
		print("avg=%d root_opt=%d black_opt=%d eval_after_b2e2=%d root_score_if_standpat=%d" % [
			avg, opt, -opt, v, -v,
		])

	# upstream initial delta from mean_squared = -INF*INF
	var mss: int = -T.VALUE_INFINITE * T.VALUE_INFINITE
	var delta: int = 10 + absi(mss) / 39605
	var avg2: int = -T.VALUE_INFINITE
	print("upstream_init mean_squared=%d delta=%d alpha=%d beta=%d" % [
		mss, delta, maxi(avg2 - delta, -T.VALUE_INFINITE), mini(avg2 + delta, T.VALUE_INFINITE),
	])
	engine.shutdown()
	print("S1_OPT_DONE")
	quit(0)
