extends GutTest

## Dual-track attacks parity: core/attacks.gd vs nnue/attacks.gd + query tables.
## Fixture: fixtures/core/attacks_parity.json (tools/gen_attack_fixtures.py).
## Does not merge the two implementations.

const T = preload("res://addons/pikafish/core/types.gd")
const BB = preload("res://addons/pikafish/core/bitboard.gd")
const A = preload("res://addons/pikafish/core/attacks.gd")
const C = preload("res://addons/pikafish/nnue/consts.gd")
const XAttacks = preload("res://addons/pikafish/nnue/attacks.gd")
const S = preload("res://src/test/gut/nnue_test_support.gd")

const PARITY_PATH := "res://fixtures/core/attacks_parity.json"
const UPSTREAM_SHA := "2c5c998c211d524d26c38e7e3e71d51bc24cbe64"

var _parity: Dictionary = {}


func before_all() -> void:
	BB.ensure_tables()
	A.init_tables()
	XAttacks.ensure_tables()
	assert_true(FileAccess.file_exists(PARITY_PATH), "attacks_parity.json missing")
	var f := FileAccess.open(PARITY_PATH, FileAccess.READ)
	_parity = JSON.parse_string(f.get_as_text())
	assert_eq(_parity.get("upstream_sha", ""), UPSTREAM_SHA)


func _bb_squares(pair: Array) -> Array:
	return A.bb_to_sorted_squares(pair[0], pair[1])


func _assert_set_eq(got: Array, want: Array, label: String) -> void:
	assert_eq(S.sorted_unique(got), S.sorted_unique(want), label)


func _occ_from_squares(occ_squares: Array) -> PackedByteArray:
	var occ := S.empty_occ()
	for s in occ_squares:
		occ[int(s)] = 1
	return occ


func test_attack_cases_core_matches_fixture_and_nnue_when_shared() -> void:
	var palace := C.palace_squares()
	for case in _parity["attack_cases"]:
		var label: String = case["label"]
		var pt: int = case["pt"]
		var sq: int = case["sq"]
		var want: Array = case["attacks"]
		var tracks: String = case.get("tracks", "both")
		var occ := _occ_from_squares(case["occ"])
		var occ_bb := BB.from_occ90(occ)

		var core_got := A.attacks_bb(pt, sq, occ_bb[0], occ_bb[1])
		_assert_set_eq(_bb_squares(core_got), want, "core " + label)

		if tracks == "core":
			# KNIGHT_TO etc. — NNUE has no API; skip dual compare.
			continue
		if pt == T.KNIGHT_TO:
			continue

		var nnue_got: Array
		match pt:
			T.ROOK, T.CANNON:
				nnue_got = XAttacks.sliding_attack(pt, sq, occ)
			T.KNIGHT, T.BISHOP:
				nnue_got = XAttacks.lame_leaper_attack(pt, sq, occ)
			_:
				nnue_got = XAttacks.attacks_bb(pt, sq, occ, C.WHITE, palace)
		_assert_set_eq(nnue_got, want, "nnue " + label)
		_assert_set_eq(_bb_squares(core_got), nnue_got, "core==nnue " + label)


func test_leaper_nonslide_cases_agree_on_legal_squares() -> void:
	var palace := C.palace_squares()
	for case in _parity["leaper_cases"]:
		var label: String = case["label"]
		var kind: String = case["kind"]
		var sq: int = case["sq"]
		var want_up: Array = case["upstream"]
		var want_core: Array = case["core"]
		var want_nnue: Array = case["nnue"]
		assert_eq(S.sorted_unique(want_core), S.sorted_unique(want_up), "fixture core=upstream " + label)

		match kind:
			"king":
				_assert_set_eq(_bb_squares(A.attacks_bb(T.KING, sq)), want_core, "core king " + label)
				_assert_set_eq(XAttacks.pseudo_king(sq, palace), want_nnue, "nnue king " + label)
				# On palace squares fixture guarantees core==nnue.
				_assert_set_eq(want_core, want_nnue, "palace dual " + label)
			"advisor":
				_assert_set_eq(_bb_squares(A.attacks_bb(T.ADVISOR, sq)), want_core, "core adv " + label)
				_assert_set_eq(XAttacks.pseudo_advisor(sq, palace), want_nnue, "nnue adv " + label)
				_assert_set_eq(want_core, want_nnue, "palace dual " + label)
			"pawn":
				var color: int = case["color"]
				_assert_set_eq(
					_bb_squares(A.attacks_bb_pawn(color, sq)),
					want_core,
					"core pawn " + label
				)
				_assert_set_eq(XAttacks.pawn_attacks_bb(color, sq), want_nnue, "nnue pawn " + label)
			_:
				fail_test("unknown leaper kind " + kind)


func test_query_tables_line_between_ray_pass_leaper_pass() -> void:
	## Core-only tables used by gives_check / discovery in upstream (ray_pass, leaper_pass).
	for q in _parity["queries"]["pairs"]:
		var s1: int = q["s1"]
		var s2: int = q["s2"]
		var tag := "%d->%d" % [s1, s2]
		_assert_set_eq(_bb_squares(A.line_bb(s1, s2)), q["line"], "line " + tag)
		_assert_set_eq(_bb_squares(A.between_bb(s1, s2)), q["between"], "between " + tag)
		_assert_set_eq(_bb_squares(A.ray_pass_bb(s1, s2)), q["ray_pass"], "ray_pass " + tag)
		_assert_set_eq(_bb_squares(A.leaper_pass_bb(s1, s2)), q["leaper_pass"], "leaper_pass " + tag)


func test_ray_pass_is_cannon_through_single_blocker() -> void:
	## Upstream: RayPassBB[s1][s2] = attacks_bb<CANNON>(s1, square_bb(s2)) when rook-aligned.
	var s1 := S.sq(4, 0)  # e0
	var s2 := S.sq(4, 5)  # e5 on file
	var rp := A.ray_pass_bb(s1, s2)
	var occ := S.empty_occ()
	occ[s2] = 1
	var cannon := XAttacks.sliding_attack(C.CANNON, s1, occ)
	_assert_set_eq(_bb_squares(rp), cannon, "ray_pass == cannon(s1,{s2})")
	# Screen at e5 → cannon sees empty squares beyond (e6..) and not the hurdle itself.
	assert_false(BB.test_bit(rp[0], rp[1], s2), "ray_pass does not include hurdle s2")
	assert_true(BB.test_bit(rp[0], rp[1], S.sq(4, 6)), "ray_pass includes square beyond screen")


func test_expected_oob_palace_difference_is_recorded_not_silent() -> void:
	## Meaningful expected difference: NNUE king/advisor ignore palace[s] gate.
	var oob_king := 0
	var oob_adv := 0
	for d in _parity["expected_differences"]:
		var id: String = str(d.get("id", ""))
		if id == "king_outside_palace":
			oob_king += 1
			assert_eq(d.get("fix", true), false)
			assert_eq(S.sorted_unique(d["core"]), S.sorted_unique(d["upstream"]))
			assert_ne(S.sorted_unique(d["core"]), S.sorted_unique(d["nnue"]), d["label"])
			# Live check against both implementations
			var sq: int = d["sq"]
			_assert_set_eq(_bb_squares(A.attacks_bb(T.KING, sq)), d["core"], "live core " + d["label"])
			_assert_set_eq(
				XAttacks.pseudo_king(sq, C.palace_squares()),
				d["nnue"],
				"live nnue " + d["label"]
			)
		elif id == "advisor_outside_palace":
			oob_adv += 1
			assert_eq(d.get("fix", true), false)
			var sq2: int = d["sq"]
			_assert_set_eq(_bb_squares(A.attacks_bb(T.ADVISOR, sq2)), d["core"], "live core " + d["label"])
			_assert_set_eq(
				XAttacks.pseudo_advisor(sq2, C.palace_squares()),
				d["nnue"],
				"live nnue " + d["label"]
			)
	assert_gt(oob_king, 0, "recorded king OOB diffs")
	assert_gt(oob_adv, 0, "recorded advisor OOB diffs")


func test_cannon_screen_and_blocker_edges_dual() -> void:
	var labels := [
		"cannon_screen_a0_a2_a4",
		"cannon_double_hurdle_a0",
		"rook_edge_stop_a3",
		"rook_edge_63_64",
		"knight_leg_e4_north",
		"bishop_eye_c2_ne",
	]
	var by_label := {}
	for case in _parity["attack_cases"]:
		by_label[case["label"]] = case
	for name in labels:
		assert_true(by_label.has(name), "missing case " + name)
		var case: Dictionary = by_label[name]
		var occ := _occ_from_squares(case["occ"])
		var occ_bb := BB.from_occ90(occ)
		var pt: int = case["pt"]
		var sq: int = case["sq"]
		var core_got := A.attacks_bb(pt, sq, occ_bb[0], occ_bb[1])
		var nnue_got: Array
		if pt == T.ROOK or pt == T.CANNON:
			nnue_got = XAttacks.sliding_attack(pt, sq, occ)
		else:
			nnue_got = XAttacks.lame_leaper_attack(pt, sq, occ)
		_assert_set_eq(_bb_squares(core_got), case["attacks"], "core " + name)
		_assert_set_eq(nnue_got, case["attacks"], "nnue " + name)


func test_knight_to_path_matches_fixture_core_only() -> void:
	var found := false
	for case in _parity["attack_cases"]:
		if int(case["pt"]) != T.KNIGHT_TO:
			continue
		found = true
		var occ := _occ_from_squares(case["occ"])
		var occ_bb := BB.from_occ90(occ)
		var got := A.attacks_bb(T.KNIGHT_TO, case["sq"], occ_bb[0], occ_bb[1])
		_assert_set_eq(_bb_squares(got), case["attacks"], "core KNIGHT_TO " + case["label"])
	assert_true(found, "expected KNIGHT_TO fixture case")
