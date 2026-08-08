extends GutTest

## Targeted parity vs Pikafish Position::do_move / do_null_move / gives_check / pseudo_legal
## Upstream baseline: 2c5c998c

const T = preload("res://addons/pikafish/core/types.gd")
const Z = preload("res://addons/pikafish/core/zobrist.gd")
const Pos = preload("res://addons/pikafish/core/position.gd")
const MG = preload("res://addons/pikafish/core/movegen.gd")

const START_FEN := "rnbakabnr/9/1c5c1/p1p1p1p1p/9/9/P1P1P1P1P/1C5C1/9/RNBAKABNR w - - 0 1"


func before_all() -> void:
	Z.init_keys()


func test_quiet_non_check_increments_rule60_not_check10() -> void:
	# Upstream do_move: !givesCheck → ++rule60; check10 unchanged. Pawn does NOT reset.
	var pos = Pos.new()
	assert_eq(pos.set_fen(START_FEN), OK)
	var m: int = T.uci_to_move("a3a4")
	assert_true(pos.pseudo_legal(m) and pos.legal(m))
	assert_false(pos.gives_check(m))
	pos.do_move(m)
	assert_eq(pos.rule60_count(), 1)
	assert_eq(pos.stack.check10_w[pos.st()], 0)
	assert_eq(pos.stack.check10_b[pos.st()], 0)


func test_check_increments_check10_and_rule60_while_le_10() -> void:
	# Oracle: 4k4/9/9/4p4/9/9/9/9/3C5/3K5 w — d1e1 checks; fen after shows rule60=1
	var pos = Pos.new()
	assert_eq(pos.set_fen("4k4/9/9/4p4/9/9/9/9/3C5/3K5 w - - 0 1"), OK)
	var m: int = T.uci_to_move("d1e1")
	assert_true(pos.gives_check(m))
	pos.do_move(m)
	assert_eq(pos.stack.check10_w[pos.st()], 1)
	assert_eq(pos.rule60_count(), 1)
	var chk: Array = pos.checkers()
	assert_true(chk[0] != 0 or chk[1] != 0)


func test_check_beyond_10_skips_rule60() -> void:
	# Upstream: givesCheck && ++check10[us] > 10 → do not ++rule60
	var pos = Pos.new()
	assert_eq(pos.set_fen("4k4/9/9/4p4/9/9/9/9/3C5/3K5 w - - 5 1"), OK)
	pos.stack.check10_w[pos.st()] = 10
	var m: int = T.uci_to_move("d1e1")
	assert_true(pos.gives_check(m))
	pos.do_move(m)
	assert_eq(pos.stack.check10_w[pos.st()], 11)
	assert_eq(pos.rule60_count(), 5, "rule60 frozen while check10 exceeds 10")


func test_capture_resets_check10_and_rule60() -> void:
	# Upstream capture: check10[W]=check10[B]=rule60=0
	# FEN pawn is on e6 (rank 6); rook e2 takes with e2e6.
	var pos = Pos.new()
	assert_eq(pos.set_fen("4k4/9/9/4p4/9/9/9/4R4/9/3K5 w - - 7 1"), OK)
	pos.stack.check10_w[pos.st()] = 3
	pos.stack.check10_b[pos.st()] = 2
	var m: int = T.uci_to_move("e2e6")
	assert_true(pos.capture(m), "rook captures pawn on e6")
	pos.do_move(m)
	assert_eq(pos.rule60_count(), 0)
	assert_eq(pos.stack.check10_w[pos.st()], 0)
	assert_eq(pos.stack.check10_b[pos.st()], 0)


func test_opp_check10_extension_when_prev_in_check() -> void:
	# Upstream: if check10[~us] > 10 && previous->checkersBB → ++opp check10 else ++rule60
	var pos = Pos.new()
	# Black in check from rook; black flees e9f9 (not a check)
	assert_eq(pos.set_fen("4k4/9/4R4/9/9/9/9/9/9/3K5 b - - 4 1"), OK)
	pos.stack.check10_w[pos.st()] = 11
	var chk0: Array = pos.checkers()
	assert_true(chk0[0] != 0 or chk0[1] != 0)
	var m: int = T.uci_to_move("e9f9")
	assert_false(pos.gives_check(m))
	pos.do_move(m)
	assert_eq(pos.stack.check10_w[pos.st()], 12, "extend opponent check10 instead of rule60")
	assert_eq(pos.rule60_count(), 4)


func test_do_null_move_does_not_bump_game_ply_or_rule60() -> void:
	# Upstream: Position::do_null_move — no gamePly / rule60 increment
	var pos = Pos.new()
	assert_eq(pos.set_fen(START_FEN), OK)
	var ply0: int = pos.game_ply
	var r0: int = pos.rule60_count()
	var stm0: int = pos.side_to_move
	pos.do_null_move()
	assert_eq(pos.game_ply, ply0)
	assert_eq(pos.rule60_count(), r0)
	assert_eq(pos.side_to_move, T.flip_color(stm0))
	assert_eq(pos.stack.plies_from_null[pos.st()], 0)
	pos.undo_null_move()
	assert_eq(pos.game_ply, ply0)
	assert_eq(pos.side_to_move, stm0)


func test_cannon_hollow_capture_gives_check_via_ray_pass() -> void:
	# Oracle-validated: 4k4/9/9/9/9/9/4C4/4R4/4p4/3K5 w moves e3e1 → checkers e1 e2
	var pos = Pos.new()
	assert_eq(pos.set_fen("4k4/9/9/9/9/9/4C4/4R4/4p4/3K5 w - - 0 1"), OK)
	var m: int = T.uci_to_move("e3e1")
	assert_true(pos.gives_check(m), "hollow cannon capture beyond self")
	pos.do_move(m)
	var chk: Array = pos.checkers()
	assert_true(chk[0] != 0 or chk[1] != 0)
	assert_eq(pos.rule60_count(), 0, "capture resets rule60")


func test_pseudo_legal_requires_evasions_when_in_check() -> void:
	# Upstream: if checkers() → MoveList<EVASIONS>.contains(m)
	var pos = Pos.new()
	assert_eq(pos.set_fen("4k4/9/4R4/9/9/9/9/9/8p/3K5 b - - 0 1"), OK)
	var chk: Array = pos.checkers()
	assert_true(chk[0] != 0 or chk[1] != 0)
	var flee: int = T.uci_to_move("e9f9")
	assert_true(pos.pseudo_legal(flee), "king flee is an evasion")
	var non_ev: int = T.uci_to_move("i1i0")
	# Geometric pawn step may be attack-legal, but must fail EVASIONS filter
	var occ_ok: bool = true
	var pc: int = pos.board[T.from_sq(non_ev)]
	if pc == T.NO_PIECE or T.color_of(pc) != pos.side_to_move:
		occ_ok = false
	assert_true(occ_ok)
	assert_false(pos.pseudo_legal(non_ev), "non-evasion rejected while in check")
	# Sanity: non_ev not in generated evasions
	var buf := PackedInt32Array()
	buf.resize(T.MAX_MOVES)
	var n: int = MG.generate(pos, MG.GEN_EVASIONS, buf)
	var found := false
	for i in range(n):
		if buf[i] == non_ev:
			found = true
			break
	assert_false(found)
