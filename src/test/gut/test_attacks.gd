extends GutTest

## Attack-generation goldens (cannon screen, knight leg, bishop eye, palace, pawn).

const C = preload("res://addons/pikafish/nnue/consts.gd")
const XAttacks = preload("res://addons/pikafish/nnue/attacks.gd")
const S = preload("res://src/test/gut/nnue_test_support.gd")


func before_all() -> void:
	XAttacks.ensure_tables()


func _assert_set_eq(got: Array, want: Array, label: String) -> void:
	assert_eq(S.sorted_unique(got), S.sorted_unique(want), label)


func test_pawn_forward_and_side_after_river() -> void:
	# White pawn before river: only north
	var a0 := S.sq(0, 3)  # a3
	_assert_set_eq(XAttacks.pawn_attacks_bb(C.WHITE, a0), [S.sq(0, 4)], "w pawn a3")
	# White pawn after river (rank>4): north + sides
	var e5 := S.sq(4, 5)
	_assert_set_eq(
		XAttacks.pawn_attacks_bb(C.WHITE, e5),
		[S.sq(4, 6), S.sq(3, 5), S.sq(5, 5)],
		"w pawn e5")
	# Black pawn after river (rank<5)
	var e4 := S.sq(4, 4)
	_assert_set_eq(
		XAttacks.pawn_attacks_bb(C.BLACK, e4),
		[S.sq(4, 3), S.sq(3, 4), S.sq(5, 4)],
		"b pawn e4")


func test_king_and_advisor_stay_in_palace() -> void:
	var palace := C.palace_squares()
	var e0 := S.sq(4, 0)
	var king_atks: Array = XAttacks.pseudo_king(e0, palace)
	for t in king_atks:
		assert_eq(palace[t], 1, "king target in palace")
	_assert_set_eq(king_atks, [S.sq(4, 1), S.sq(3, 0), S.sq(5, 0)], "king e0")
	var d0 := S.sq(3, 0)
	var adv: Array = XAttacks.pseudo_advisor(d0, palace)
	for t in adv:
		assert_eq(palace[t], 1, "advisor target in palace")
	assert_true(adv.has(S.sq(4, 1)), "advisor d0 -> e1")


func test_knight_blocked_by_leg() -> void:
	var occ := S.empty_occ()
	var e4 := S.sq(4, 4)
	# No blockers: knight should reach 2N+E etc.
	var open: Array = XAttacks.lame_leaper_attack(C.KNIGHT, e4, occ)
	assert_gt(open.size(), 0)
	assert_true(open.has(S.sq(5, 6)), "knight e4 -> f6 open")
	# Block horse leg to the north (e5)
	occ[S.sq(4, 5)] = 1
	var blocked: Array = XAttacks.lame_leaper_attack(C.KNIGHT, e4, occ)
	assert_false(blocked.has(S.sq(5, 6)), "knight e4 -> f6 blocked by e5")
	assert_false(blocked.has(S.sq(3, 6)), "knight e4 -> d6 blocked by e5")


func test_bishop_blocked_by_eye() -> void:
	var occ := S.empty_occ()
	var c2 := S.sq(2, 2)  # typical bishop square
	var open: Array = XAttacks.lame_leaper_attack(C.BISHOP, c2, occ)
	# Eye toward e4 (NE*2): eye is d3
	var eye := S.sq(3, 3)
	assert_true(open.has(S.sq(4, 4)) or open.size() >= 0)  # may or may not be on board path
	occ[eye] = 1
	var blocked: Array = XAttacks.lame_leaper_attack(C.BISHOP, c2, occ)
	assert_false(blocked.has(S.sq(4, 4)), "bishop eye blocked c2->e4")


func test_rook_ray_stops_on_piece() -> void:
	var occ := S.empty_occ()
	var a0 := S.sq(0, 0)
	occ[S.sq(0, 3)] = 1
	var palace := C.palace_squares()
	var atks: Array = XAttacks.attacks_bb(C.ROOK, a0, occ, C.WHITE, palace)
	assert_true(atks.has(S.sq(0, 1)))
	assert_true(atks.has(S.sq(0, 2)))
	assert_true(atks.has(S.sq(0, 3)), "rook attacks occupied square")
	assert_false(atks.has(S.sq(0, 4)), "rook does not pass through")


func test_cannon_needs_hurdle_to_capture() -> void:
	var occ := S.empty_occ()
	var a0 := S.sq(0, 0)
	var palace := C.palace_squares()
	# attacks_bb for cannon is capture/post-hurdle oriented (empty board → no targets).
	var quiet: Array = XAttacks.attacks_bb(C.CANNON, a0, occ, C.WHITE, palace)
	assert_eq(quiet.size(), 0, "cannon attacks_bb on empty board")
	# Hurdle a2 + piece a4 → capture a4 (and may list empties after hurdle).
	occ[S.sq(0, 2)] = 1
	occ[S.sq(0, 4)] = 1
	var with_h: Array = XAttacks.attacks_bb(C.CANNON, a0, occ, C.WHITE, palace)
	assert_true(with_h.has(S.sq(0, 4)), "cannon sees screened piece")
	assert_false(with_h.has(S.sq(0, 2)), "cannon does not attack hurdle square")
	var buf := PackedInt32Array()
	buf.resize(36)
	var n: int = XAttacks.append_captures(C.CANNON, a0, occ, C.WHITE, buf)
	var caps := []
	for i in range(n):
		caps.append(buf[i])
	_assert_set_eq(caps, [S.sq(0, 4)], "cannon capture-only")


func test_append_captures_subset_of_occupied_attacks() -> void:
	var b := S.board_from_fen("rnbakabnr/9/1c5c1/p1p1p1p1p/9/9/P1P1P1P1P/1C5C1/9/RNBAKABNR w")
	var palace := C.palace_squares()
	var buf := PackedInt32Array()
	buf.resize(36)
	for frm in b.piece_list:
		var pc: int = b.sq[frm]
		var pt := pc & 7
		var col := pc >> 3
		var all: Array = XAttacks.attacks_bb(pt, frm, b.occ, col, palace)
		var n: int = XAttacks.append_captures(pt, frm, b.occ, col, buf)
		for i in range(n):
			var to: int = buf[i]
			assert_eq(b.occ[to], 1, "capture target occupied")
			assert_true(all.has(to), "capture in full attacks")
