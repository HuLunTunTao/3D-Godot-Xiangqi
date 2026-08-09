extends GutTest

## SearchParity S0: soft rule_judge α/β clamp in _search / _qsearch (search.cpp 726–738, 1571–1586).

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


func _soft_chase_mate_pos() -> Position:
	## Soft 2-fold chase mate at ply=5: claimed=false, value=mate_in(5).
	var pos = Position.new()
	assert_eq(pos.set_fen("3k1a3/9/9/1c7/9/1R7/9/9/9/3A1K3 w - - 0 1"), OK)
	for uci in ["f0e0", "b6a6", "b4a4", "a6b6", "a4b4"]:
		var m: int = T.uci_to_move(uci)
		assert_true(pos.legal(m), uci)
		pos.do_move(m)
	return pos


func _soft_perp_mated_pos() -> Position:
	## Soft 2-fold perpetual check as the checker (STM): claimed=false, mated_in(5).
	var pos = Position.new()
	assert_eq(pos.set_fen("4k4/9/4R4/9/9/9/9/9/9/3K5 b - - 0 1"), OK)
	for uci in ["e9f9", "e7f7", "f9e9", "f7e7", "e9f9", "e7f7", "f9e9"]:
		var m: int = T.uci_to_move(uci)
		assert_true(pos.legal(m), uci)
		pos.do_move(m)
	return pos


func _rule60_draw_pos() -> Position:
	var pos = Position.new()
	assert_eq(
		pos.set_fen("rnbakabnr/9/1c5c1/p1p1p1p1p/9/9/P1P1P1P1P/1C5C1/9/RNBAKABNR w - - 120 60"),
		OK
	)
	return pos


func _make_worker(pos: Position) -> Worker:
	var w = Worker.new()
	w.pos = pos
	w._ensure_helpers()
	w._pv_stack.clear()
	for _i in range(16):
		w._pv_stack.append(PackedInt32Array())
	w.nodes = 0
	return w


func test_soft_chase_rules_result_not_claimed() -> void:
	var pos := _soft_chase_mate_pos()
	var rj: Dictionary = pos.rule_judge(5)
	assert_false(rj.get("claimed", true))
	assert_eq(int(rj["value"]), T.mate_in(5))


func test_search_soft_mate_clamps_alpha_no_immediate_mate_return() -> void:
	## Soft mate raises α to VALUE_DRAW-1; must not return mate_in(ply).
	## Window (-100, -1): after clamp α=-1 ≥ β → mate-distance prune returns -1.
	var pos := _soft_chase_mate_pos()
	var w := _make_worker(pos)
	var score: int = w._search(Worker.NODE_PV, 2, -100, -1, 5, false)
	assert_ne(score, T.mate_in(5), "soft must not return mate")
	assert_eq(score, T.VALUE_DRAW - 1)


func test_search_soft_mated_clamps_beta_no_immediate_mated_return() -> void:
	## Soft mated lowers β to VALUE_DRAW+1; must not return mated_in(ply).
	## Window (1, 100): after clamp β=1 ≤ α → mate-distance prune returns 1.
	var pos := _soft_perp_mated_pos()
	var rj: Dictionary = pos.rule_judge(5)
	assert_false(rj.get("claimed", true))
	assert_true(T.is_loss(int(rj["value"])), "expect soft mated")
	var w := _make_worker(pos)
	var score: int = w._search(Worker.NODE_PV, 2, 1, 100, 5, false)
	assert_ne(score, int(rj["value"]), "soft must not return mated")
	assert_eq(score, T.VALUE_DRAW + 1)


func test_qsearch_soft_mate_cutoff_returns_alpha() -> void:
	## Soft mate: α=max(α, VALUE_DRAW); with α=-50,β=0 → α=0≥β → return α.
	var pos := _soft_chase_mate_pos()
	var w := _make_worker(pos)
	var score: int = w._qsearch(true, -50, 0, 5)
	assert_ne(score, T.mate_in(5), "qsearch soft must not return mate")
	assert_eq(score, T.VALUE_DRAW)


func test_qsearch_soft_mated_cutoff_returns_alpha() -> void:
	## Soft mated: β=min(β, VALUE_DRAW); with α=0,β=50 → β=0≤α → return α.
	var pos := _soft_perp_mated_pos()
	var w := _make_worker(pos)
	var score: int = w._qsearch(true, 0, 50, 5)
	assert_eq(score, T.VALUE_DRAW)


func test_root_skips_rule_judge_in_search_step2() -> void:
	## Upstream search<> only rule_judges when !rootNode.
	## Non-root depth 0: claimed draw → value_draw before qsearch.
	## Root depth 0: Step 2 skipped → qsearch returns plain VALUE_DRAW.
	var pos := _rule60_draw_pos()
	assert_true(pos.rule_judge(0).get("claimed", false))
	var w := _make_worker(pos)
	w.nodes = 0
	var non_root: int = w._search(Worker.NODE_PV, 0, -T.VALUE_INFINITE, T.VALUE_INFINITE, 1, false)
	assert_eq(non_root, T.VALUE_DRAW - 1)
	w.nodes = 0
	var root_score: int = w._search(Worker.NODE_ROOT, 0, -T.VALUE_INFINITE, T.VALUE_INFINITE, 0, false)
	assert_eq(root_score, T.VALUE_DRAW)
