extends GutTest

## Targeted parity: search.cpp value_draw + rule_judge DRAW scoring in _search.

const T = preload("res://addons/pikafish/core/types.gd")
const Worker = preload("res://addons/pikafish/search/search_worker.gd")
const Position = preload("res://addons/pikafish/core/position.gd")
const Attacks = preload("res://addons/pikafish/core/attacks.gd")
const Zobrist = preload("res://addons/pikafish/core/zobrist.gd")
const Bitboard = preload("res://addons/pikafish/core/bitboard.gd")


func before_all() -> void:
	Bitboard.ensure_tables()
	Attacks.init_tables()
	Zobrist.init_keys()


func test_value_draw_matches_upstream_formula() -> void:
	var w = Worker.new()
	w.nodes = 0
	assert_eq(w._value_draw(), T.VALUE_DRAW - 1)
	w.nodes = 1
	assert_eq(w._value_draw(), T.VALUE_DRAW - 1)
	w.nodes = 2
	assert_eq(w._value_draw(), T.VALUE_DRAW - 1 + 2)
	w.nodes = 3
	assert_eq(w._value_draw(), T.VALUE_DRAW - 1 + 2)
	w.nodes = 4
	assert_eq(w._value_draw(), T.VALUE_DRAW - 1)


func test_search_rule_judge_draw_uses_value_draw() -> void:
	## rule60 claim at non-root ply must return value_draw(nodes), not plain 0.
	var pos = Position.new()
	assert_eq(
		pos.set_fen("rnbakabnr/9/1c5c1/p1p1p1p1p/9/9/P1P1P1P1P/1C5C1/9/RNBAKABNR w - - 120 60"),
		OK
	)
	var rj: Dictionary = pos.rule_judge(1)
	assert_true(rj.get("claimed", false))
	assert_eq(int(rj["value"]), T.VALUE_DRAW)

	var w = Worker.new()
	w.pos = pos
	w._ensure_helpers()
	w._pv_stack.clear()
	for _i in range(8):
		w._pv_stack.append(PackedInt32Array())

	# Nodes only advance in do_move (upstream); entry itself does not ++nodes.
	w.nodes = 0
	var score_odd: int = w._search(Worker.NODE_PV, 1, -T.VALUE_INFINITE, T.VALUE_INFINITE, 1, false)
	assert_eq(score_odd, T.VALUE_DRAW - 1)

	w.nodes = 2
	var score_even: int = w._search(Worker.NODE_PV, 1, -T.VALUE_INFINITE, T.VALUE_INFINITE, 1, false)
	assert_eq(score_even, T.VALUE_DRAW - 1 + 2)
