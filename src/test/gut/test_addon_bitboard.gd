extends GutTest

## Phase B: types / dual64 bitboard / attacks vs NNUE goldens + cross bit-63/64.

const T = preload("res://addons/pikafish/core/types.gd")
const BB = preload("res://addons/pikafish/core/bitboard.gd")
const A = preload("res://addons/pikafish/core/attacks.gd")
const C = preload("res://addons/pikafish/nnue/consts.gd")
const XAttacks = preload("res://addons/pikafish/nnue/attacks.gd")
const S = preload("res://src/test/gut/nnue_test_support.gd")


func before_all() -> void:
	BB.ensure_tables()
	A.init_tables()
	XAttacks.ensure_tables()


func _bb_squares(lo: int, hi: int) -> Array:
	return A.bb_to_sorted_squares(lo, hi)


func _assert_set_eq(got: Array, want: Array, label: String) -> void:
	assert_eq(S.sorted_unique(got), S.sorted_unique(want), label)


func test_move_encoding_matches_upstream() -> void:
	assert_eq(T.make_move(0, 9), 9)
	assert_eq(T.from_sq(148), 1)
	assert_eq(T.to_sq(148), 20)
	assert_eq(T.MOVE_NONE, 0)
	assert_eq(T.MOVE_NULL, 129)
	assert_eq(T.uci_to_move("a0a2"), T.make_move(0, 18))
	assert_eq(T.move_to_uci(T.make_move(0, 18)), "a0a2")


func test_square_helpers() -> void:
	assert_eq(T.make_square(4, 0), 4)
	assert_eq(T.file_of(13), 4)
	assert_eq(T.rank_of(13), 1)
	assert_eq(T.flip_rank(4), T.make_square(4, 9))
	assert_eq(T.flip_file(0), 8)
	assert_eq(T.mate_in(3), T.VALUE_MATE - 3)
	assert_eq(T.mated_in(3), -T.VALUE_MATE + 3)


func test_bitboard_sq_63_and_64() -> void:
	## Cross 63/64-bit boundary — GDS signed lo bit 63.
	var a := BB.from_square(63)
	var b := BB.from_square(64)
	assert_true(BB.test_bit(a[0], a[1], 63), "bit 63 set")
	assert_false(BB.test_bit(a[0], a[1], 64), "bit 63 only")
	assert_true(BB.test_bit(b[0], b[1], 64), "bit 64 set")
	assert_false(BB.test_bit(b[0], b[1], 63), "bit 64 only")
	assert_eq(BB.lsb(a[0], a[1]), 63)
	assert_eq(BB.lsb(b[0], b[1]), 64)
	var both := BB.or_bb(a[0], a[1], b[0], b[1])
	assert_eq(BB.popcount(both[0], both[1]), 2)
	assert_true(BB.more_than_one(both[0], both[1]))
	var occ := BB.to_occ90(both[0], both[1])
	assert_eq(occ[63], 1)
	assert_eq(occ[64], 1)
	var round := BB.from_occ90(occ)
	assert_true(BB.equals(round[0], round[1], both[0], both[1]), "occ90 roundtrip")


func test_palace_constant() -> void:
	var palace := BB.palace_bb()
	var count := BB.popcount(palace[0], palace[1])
	assert_eq(count, 18, "two palaces × 9")
	assert_true(BB.test_bit(palace[0], palace[1], T.make_square(4, 0)))
	assert_true(BB.test_bit(palace[0], palace[1], T.make_square(4, 9)))


func test_attacks_match_nnue_pawn_king_knight_rook() -> void:
	var palace := C.palace_squares()
	# Pawn
	_assert_set_eq(
		_bb_squares_arr(A.attacks_bb_pawn(T.COLOR_WHITE, S.sq(0, 3))),
		XAttacks.pawn_attacks_bb(C.WHITE, S.sq(0, 3)),
		"w pawn a3")
	_assert_set_eq(
		_bb_squares_arr(A.attacks_bb_pawn(T.COLOR_WHITE, S.sq(4, 5))),
		XAttacks.pawn_attacks_bb(C.WHITE, S.sq(4, 5)),
		"w pawn e5")
	# King
	_assert_set_eq(
		_bb_squares_arr(A.attacks_bb(T.KING, S.sq(4, 0))),
		XAttacks.pseudo_king(S.sq(4, 0), palace),
		"king e0")
	# Knight blocked
	var occ := S.empty_occ()
	var e4 := S.sq(4, 4)
	var open_bb := A.attacks_bb(T.KNIGHT, e4, 0, 0)
	_assert_set_eq(_bb_squares_arr(open_bb), XAttacks.lame_leaper_attack(C.KNIGHT, e4, occ), "knight open")
	occ[S.sq(4, 5)] = 1
	var occ_bb := BB.from_occ90(occ)
	var blocked_bb := A.attacks_bb(T.KNIGHT, e4, occ_bb[0], occ_bb[1])
	_assert_set_eq(
		_bb_squares_arr(blocked_bb),
		XAttacks.lame_leaper_attack(C.KNIGHT, e4, occ),
		"knight blocked")
	# Rook ray
	occ = S.empty_occ()
	occ[S.sq(0, 3)] = 1
	occ_bb = BB.from_occ90(occ)
	var rook_bb := A.attacks_bb(T.ROOK, S.sq(0, 0), occ_bb[0], occ_bb[1])
	_assert_set_eq(
		_bb_squares_arr(rook_bb),
		XAttacks.sliding_attack(C.ROOK, S.sq(0, 0), occ),
		"rook a0 blocked a3")


func _bb_squares_arr(pair: Array) -> Array:
	return _bb_squares(pair[0], pair[1])


func test_cannon_screen_matches_nnue() -> void:
	var occ := S.empty_occ()
	# Screen at e4, target beyond
	occ[S.sq(4, 4)] = 1
	occ[S.sq(4, 7)] = 1
	var occ_bb := BB.from_occ90(occ)
	var got := A.attacks_bb(T.CANNON, S.sq(4, 0), occ_bb[0], occ_bb[1])
	_assert_set_eq(
		_bb_squares_arr(got),
		XAttacks.sliding_attack(C.CANNON, S.sq(4, 0), occ),
		"cannon e0 screen e4")


func test_between_includes_target_on_rook_ray() -> void:
	var a0 := S.sq(0, 0)
	var a5 := S.sq(0, 5)
	var bet := A.between_bb(a0, a5)
	assert_true(BB.test_bit(bet[0], bet[1], a5), "between includes target")
	assert_true(BB.test_bit(bet[0], bet[1], S.sq(0, 3)), "between includes mid")
	var line := A.line_bb(a0, a5)
	assert_true(A.aligned(a0, a5, S.sq(0, 2)))
	assert_true(BB.test_bit(line[0], line[1], a0))


func test_collect_squares_zero_array_alloc_buffer() -> void:
	var buf := PackedInt32Array()
	buf.resize(T.MAX_MOVES)
	var pair := A.attacks_bb(T.ROOK, 0, 0, 0)
	var n := A.collect_squares(pair[0], pair[1], buf)
	assert_gt(n, 0)
	assert_eq(n, BB.popcount(pair[0], pair[1]))


func test_generic_blocker_fixture_file_if_present() -> void:
	var path := "res://fixtures/core/attacks_blockers.json"
	if not FileAccess.file_exists(path):
		pending("attacks_blockers.json not generated yet")
		return
	var f := FileAccess.open(path, FileAccess.READ)
	var data: Dictionary = JSON.parse_string(f.get_as_text())
	assert_eq(data.get("upstream_sha", ""), "2c5c998c211d524d26c38e7e3e71d51bc24cbe64")
	for case in data["cases"]:
		var sq: int = case["sq"]
		var pt: int = case["pt"]
		var occ_squares: Array = case["occ"]
		var want: Array = case["attacks"]
		var occ := S.empty_occ()
		for s in occ_squares:
			occ[int(s)] = 1
		var occ_bb := BB.from_occ90(occ)
		var got_bb := A.attacks_bb(pt, sq, occ_bb[0], occ_bb[1])
		_assert_set_eq(_bb_squares_arr(got_bb), want, case.get("label", "case"))
		# Dual-track: shared rook/cannon/knight/bishop cases must also match NNUE.
		if pt == T.ROOK or pt == T.CANNON:
			_assert_set_eq(
				XAttacks.sliding_attack(pt, sq, occ),
				want,
				"nnue " + str(case.get("label", "case"))
			)
		elif pt == T.KNIGHT or pt == T.BISHOP:
			_assert_set_eq(
				XAttacks.lame_leaper_attack(pt, sq, occ),
				want,
				"nnue " + str(case.get("label", "case"))
			)
