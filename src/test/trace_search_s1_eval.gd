extends SceneTree
const Eng = preload("res://addons/pikafish/pikafish.gd")
const Config = preload("res://addons/pikafish/config.gd")
const NnueEval = preload("res://addons/pikafish/search/nnue_evaluator.gd")
const T = preload("res://addons/pikafish/core/types.gd")
const FEN := "rnbakabnr/9/1c5c1/p1p1p1p1p/9/9/P1P1P1P1P/1C5C1/9/RNBAKABNR w - - 0 1"
func _init() -> void:
	var cfg = Config.new()
	cfg.prefer_gpu = false
	cfg.evaluation_mode = Config.EVALUATION_NNUE
	var e = Eng.new()
	assert(e.initialize(cfg) == OK)
	assert(e.set_fen(FEN) == OK)
	var ev = NnueEval.new(e.loader, e.features)
	ev.begin(e._pos)
	var v0 = ev.evaluate(e._pos)
	print("EVAL startpos stm=%d value=%d" % [e._pos.side_to_move, v0])
	var m = T.uci_to_move("b2e2")
	e._pos.do_move(m)
	ev.do_move(m)
	var v1 = ev.evaluate(e._pos)
	print("EVAL after_b2e2 stm=%d value=%d" % [e._pos.side_to_move, v1])
	print("NEGATED_FOR_ROOT=%d" % -v1)
	e.shutdown()
	quit(0)
