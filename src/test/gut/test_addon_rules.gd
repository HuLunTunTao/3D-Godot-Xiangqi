extends GutTest

const T = preload("res://addons/pikafish/core/types.gd")
const Z = preload("res://addons/pikafish/core/zobrist.gd")
const Pos = preload("res://addons/pikafish/core/position.gd")
const Rules = preload("res://addons/pikafish/core/rules.gd")

## Perpetual check cycle validated against Pikafish 2c5c998c UCI:
## fen 4k4/9/4R4/9/9/9/9/9/9/3K5 b - - 0 1
## moves e9f9 e7f7 f9e9 f7e7 (×2) → search reports mate (checker loses).
const PERP_CHECK_FEN := "4k4/9/4R4/9/9/9/9/9/9/3K5 b - - 0 1"
const PERP_CHECK_CYCLE := ["e9f9", "e7f7", "f9e9", "f7e7"]


func before_all() -> void:
	Z.init_keys()


func test_rule60_draw_when_legal_moves_exist() -> void:
	var pos = Pos.new()
	# Startpos with rule60 already at threshold; still has legal moves → draw claim.
	assert_eq(pos.set_fen("rnbakabnr/9/1c5c1/p1p1p1p1p/9/9/P1P1P1P1P/1C5C1/9/RNBAKABNR w - - 120 60"), OK)
	assert_eq(pos.rule60_count(), 120)
	var rj: Dictionary = pos.rule_judge(0)
	assert_true(rj.get("claimed", false), "rule60 >= 120 should claim")
	assert_eq(int(rj.get("value", T.VALUE_NONE)), T.VALUE_DRAW)


func test_rule60_with_legal_escape_is_draw() -> void:
	# Even while in check, rule60 claim is DRAW if there is still a legal escape.
	var pos = Pos.new()
	assert_eq(pos.set_fen("4k4/9/4R4/9/9/9/9/9/9/3K5 b - - 120 60"), OK)
	var rj: Dictionary = pos.rule_judge(0)
	assert_true(rj.get("claimed", false))
	assert_eq(int(rj.get("value", T.VALUE_NONE)), T.VALUE_DRAW)


func test_perpetual_check_claim_after_two_cycles() -> void:
	var pos = Pos.new()
	assert_eq(pos.set_fen(PERP_CHECK_FEN), OK)
	for _n in range(2):
		for uci in PERP_CHECK_CYCLE:
			var m: int = T.uci_to_move(uci)
			assert_true(pos.pseudo_legal(m) and pos.legal(m), "move %s" % uci)
			pos.do_move(m)
	# Side to move is black, still in check; white has been perpetually checking.
	var chk: Array = pos.checkers()
	assert_true(chk[0] != 0 or chk[1] != 0)
	var rj: Dictionary = pos.rule_judge(0)
	assert_true(rj.get("claimed", false), "2-fold perpetual check should claim")
	var v: int = int(rj.get("value", T.VALUE_NONE))
	# checkThem only → mate_in for side to move (black wins; white is the checker)
	assert_true(T.is_win(v), "perpetual checker loses; stm wins: %s" % v)


func test_see_ge_hanging_pawn() -> void:
	var pos = Pos.new()
	assert_eq(pos.set_fen("4k4/9/9/9/4p4/9/9/4R4/9/3K5 w - - 0 1"), OK)
	var m: int = T.uci_to_move("e2e5")
	assert_true(pos.see_ge(m, 0), "rook takes hanging pawn")
	assert_false(pos.see_ge(m, T.ROOK_VALUE), "not worth a full rook")


func test_chase_legal_king_flee() -> void:
	var pos = Pos.new()
	assert_eq(pos.set_fen("4k4/9/4R4/9/9/9/9/9/9/3K5 b - - 0 1"), OK)
	var flee: int = T.uci_to_move("e9f9")
	assert_true(Rules.chase_legal(pos, flee))


func test_soft_chase_mate_preserves_value_when_not_claimed() -> void:
	## Upstream oracle: after preamble + 1 chase cycle at ply=5, rule_judge returns
	## claimed=false with value=mate_in(5)=31995 (soft 2-fold for search window clamp).
	var pos = Pos.new()
	assert_eq(pos.set_fen("3k1a3/9/9/1c7/9/1R7/9/9/9/3A1K3 w - - 0 1"), OK)
	for uci in ["f0e0", "b6a6", "b4a4", "a6b6", "a4b4"]:
		var m: int = T.uci_to_move(uci)
		assert_true(pos.pseudo_legal(m) and pos.legal(m), uci)
		pos.do_move(m)
	var rj: Dictionary = pos.rule_judge(5)
	assert_false(rj.get("claimed", true), "soft result is not a hard claim")
	assert_eq(int(rj.get("value", T.VALUE_NONE)), T.mate_in(5))


func test_continuous_chase_2fold_claims_mate() -> void:
	## Black flees first under rook attack; 2 cycles → stm (black) mates (white chased).
	var pos = Pos.new()
	assert_eq(pos.set_fen("3k1a3/9/9/1c7/9/1R7/9/9/9/3A1K3 b - - 0 1"), OK)
	for uci in ["b6a6", "b4a4", "a6b6", "a4b4", "b6a6", "b4a4", "a6b6", "a4b4"]:
		var m: int = T.uci_to_move(uci)
		assert_true(pos.legal(m), uci)
		pos.do_move(m)
	var rj: Dictionary = pos.rule_judge(0)
	assert_true(rj.get("claimed", false))
	assert_true(T.is_win(int(rj.get("value", T.VALUE_NONE))))
