extends GutTest

## Phase F: history gravity + MovePicker stage order on fixed fixtures.

const T = preload("res://addons/pikafish/core/types.gd")
const Z = preload("res://addons/pikafish/core/zobrist.gd")
const BB = preload("res://addons/pikafish/core/bitboard.gd")
const Pos = preload("res://addons/pikafish/core/position.gd")
const MG = preload("res://addons/pikafish/core/movegen.gd")
const Hist = preload("res://addons/pikafish/search/history.gd")
const MP = preload("res://addons/pikafish/search/move_picker.gd")
const Worker = preload("res://addons/pikafish/search/search_worker.gd")

const START_FEN := "rnbakabnr/9/1c5c1/p1p1p1p1p/9/9/P1P1P1P1P/1C5C1/9/RNBAKABNR w - - 0 1"


func before_all() -> void:
	Z.init_keys()


func test_history_gravity_converges_and_clamps() -> void:
	## Upstream: entry << bonus → entry + clamp(b) - entry*|clamp(b)|/D
	var d: int = Hist.BUTTERFLY_D
	assert_eq(Hist.gravity(0, 100, d), 100)
	assert_eq(Hist.gravity(0, d + 500, d), d, "bonus clamped to +D")
	assert_eq(Hist.gravity(0, -(d + 500), d), -d, "bonus clamped to -D")
	var e: int = 0
	for _i in range(40):
		e = Hist.gravity(e, 400, d)
	assert_lte(absi(e), d)
	assert_gt(e, 0)
	# Second update with same bonus yields smaller delta (gravity).
	var e2: int = Hist.gravity(e, 400, d)
	assert_lt(e2 - e, 400)
	assert_lte(absi(e2), d)


func test_history_tables_update_via_indices() -> void:
	var h = Hist.new()
	var m: int = T.make_move(0, 1)
	h.update_butterfly(T.COLOR_WHITE, T.move_raw(m), 500)
	assert_eq(h.get_butterfly(T.COLOR_WHITE, T.move_raw(m)), 500)
	assert_eq(h.get_butterfly(T.COLOR_BLACK, T.move_raw(m)), 0)
	h.update_capture(T.W_ROOK, 10, T.CANNON, 300)
	assert_eq(h.get_capture(T.W_ROOK, 10, T.CANNON), 300)
	h.update_piece_to(T.W_CANNON, 20, 200)
	assert_eq(h.get_piece_to(T.W_CANNON, 20), 200)
	h.update_low_ply(0, T.move_raw(m), 100)
	assert_eq(h.get_low_ply(0, T.move_raw(m)), 100)
	h.update_correction(T.W_KNIGHT, 5, 50)
	assert_eq(h.get_correction(T.W_KNIGHT, 5), 50)


func test_continuation_and_pawn_history_gravity() -> void:
	## Upstream: ContinuationHistory + PawnHistory via PackedArray SoA.
	## Deep tables initialize to upstream clear fills; gravity applies on top.
	var h = Hist.new()
	h.ensure_deep()
	var base: int = h.cont_base(false, false, T.W_ROOK, 10)
	assert_eq(h.get_cont(base, T.W_CANNON, 20), Hist.CONT_FILL)
	h.update_cont(base, T.W_CANNON, 20, 400)
	assert_eq(
		h.get_cont(base, T.W_CANNON, 20),
		Hist.gravity(Hist.CONT_FILL, 400, Hist.PIECE_TO_D)
	)
	h.update_pawn(0xABCD, T.W_PAWN, 30, 200)
	var want_pawn: int = Hist.gravity(Hist.PAWN_FILL, 200, Hist.PAWN_HIST_D)
	assert_eq(h.get_pawn(0xABCD, T.W_PAWN, 30), want_pawn)
	assert_eq(
		h.get_pawn(0xABCD + Hist.PAWN_HISTORY_BASE_SIZE, T.W_PAWN, 30),
		want_pawn,
		"bucket wrap"
	)
	h.update_unified_correction(42, T.COLOR_WHITE, Hist.UC_PAWN, 80)
	assert_eq(
		h.get_unified_correction(42, T.COLOR_WHITE, Hist.UC_PAWN),
		Hist.gravity(Hist.UNIFIED_CORR_FILL, 80, Hist.CORRECTION_D)
	)


func test_ensure_deep_async_fills_then_ensure_deep_is_noop() -> void:
	var h = Hist.new()
	assert_true(h.continuation.is_empty())
	assert_true(h.pawn_history.is_empty())
	assert_true(h.unified_correction.is_empty())
	var yields: Array = []
	await h.ensure_deep_async(func():
		yields.append(Time.get_ticks_msec())
		if false:
			await get_tree().process_frame
	)
	assert_true(h.deep_ready())
	assert_eq(h.continuation.size(), h.continuation_len())
	assert_eq(h.pawn_history.size(), h.pawn_history_len())
	assert_eq(h.unified_correction.size(), h.unified_correction_len())
	assert_eq(h.continuation[0], Hist.CONT_FILL)
	assert_eq(h.pawn_history[0], Hist.PAWN_FILL)
	assert_gte(yields.size(), 3, "should yield between the three deep arrays")
	h.continuation[0] = 12345
	h.pawn_history[0] = 22222
	var n: int = yields.size()
	h.ensure_deep()
	assert_eq(h.continuation[0], 12345, "ensure_deep must not refill")
	assert_eq(h.pawn_history[0], 22222)
	await h.ensure_deep_async(func():
		yields.append(1)
		if false:
			await get_tree().process_frame
	)
	assert_eq(yields.size(), n, "second ensure_deep_async is a no-op")
	assert_eq(h.continuation[0], 12345)


func test_quiet_score_uses_check_bonus_ordering() -> void:
	## Giving check should sort ahead of a non-check quiet when histories are empty.
	var pos = Pos.new()
	# Rook a0 → f0 checks black king on f9; kings not facing.
	var fen := "5k3/9/9/9/9/9/9/9/9/R3K4 w - - 0 1"
	assert_eq(pos.set_fen(fen), OK, pos.last_error)
	var buf := PackedInt32Array()
	buf.resize(T.MAX_MOVES)
	var quiet_n: int = MG.generate(pos, MG.GEN_QUIETS, buf)
	assert_gt(quiet_n, 0)
	var check_move := T.MOVE_NONE
	var quiet_move := T.MOVE_NONE
	for i in range(quiet_n):
		var m: int = buf[i]
		var pt: int = T.type_of(pos.moved_piece(m))
		var chk: Array = pos.check_squares(pt)
		var to_sq: int = T.to_sq(m)
		var is_chk: bool = BB.test_bit(chk[0], chk[1], to_sq) and pos.see_ge(m, -75)
		if is_chk and check_move == T.MOVE_NONE:
			check_move = m
		elif not is_chk and quiet_move == T.MOVE_NONE:
			quiet_move = m
	assert_ne(check_move, T.MOVE_NONE, "fixture should have a checking quiet")
	assert_ne(quiet_move, T.MOVE_NONE)
	var picker = MP.new()
	picker.init_main(pos, T.MOVE_NONE, 4, Hist.new(), 0)
	var ordered: PackedInt32Array = picker.collect_all()
	var idx_chk := -1
	var idx_q := -1
	for i in range(ordered.size()):
		if ordered[i] == check_move:
			idx_chk = i
		if ordered[i] == quiet_move:
			idx_q = i
	assert_ne(idx_chk, -1)
	assert_ne(idx_q, -1)
	assert_lt(idx_chk, idx_q, "check quiet should sort before non-check quiet")



func test_move_picker_startpos_tt_first_then_quiets() -> void:
	var pos = Pos.new()
	assert_eq(pos.set_fen(START_FEN), OK)
	var buf := PackedInt32Array()
	buf.resize(T.MAX_MOVES)
	var quiet_n: int = MG.generate(pos, MG.GEN_QUIETS, buf)
	assert_gt(quiet_n, 10)
	var tt: int = buf[3]
	var boosted: int = buf[7]
	var other: int = buf[10]
	assert_false(pos.capture(tt))
	assert_false(pos.capture(boosted))
	assert_false(pos.capture(other))
	var h = Hist.new()
	h.update_butterfly(T.COLOR_WHITE, T.move_raw(boosted), 2000)
	var picker = MP.new()
	picker.init_main(pos, tt, 4, h, 0)
	var ordered: PackedInt32Array = picker.collect_all()
	assert_gt(ordered.size(), 0)
	assert_eq(ordered[0], tt, "TT move emitted first")
	var tt_count := 0
	for i in range(ordered.size()):
		if ordered[i] == tt:
			tt_count += 1
	assert_eq(tt_count, 1)
	var idx_boosted := -1
	var idx_other := -1
	for i in range(ordered.size()):
		if ordered[i] == boosted:
			idx_boosted = i
		if ordered[i] == other:
			idx_other = i
	assert_ne(idx_boosted, -1)
	assert_ne(idx_other, -1)
	assert_lt(idx_boosted, idx_other, "higher butterfly history sorts earlier among quiets")


func test_move_picker_skip_quiet_moves() -> void:
	var pos = Pos.new()
	assert_eq(pos.set_fen(START_FEN), OK)
	var buf := PackedInt32Array()
	buf.resize(T.MAX_MOVES)
	var cap_n: int = MG.generate(pos, MG.GEN_CAPTURES, buf)
	assert_eq(cap_n, 2, "startpos white has 2 cannon captures")
	var picker = MP.new()
	picker.init_main(pos, T.MOVE_NONE, 4, Hist.new(), 0)
	picker.skip_quiet_moves()
	var ordered: PackedInt32Array = picker.collect_all()
	assert_eq(ordered.size(), cap_n, "skip_quiet_moves emits only captures")
	for i in range(ordered.size()):
		assert_true(pos.capture(ordered[i]))


func test_move_picker_stages_tt_good_capture_before_quiet() -> void:
	## Fixture with a hanging capture; TT quiet first, then capture before other quiets.
	var pos = Pos.new()
	var fen := "4k4/9/9/4a4/9/9/9/9/4R4/4K4 w - - 0 1"
	assert_eq(pos.set_fen(fen), OK)
	var buf := PackedInt32Array()
	buf.resize(T.MAX_MOVES)
	var cap_n: int = MG.generate(pos, MG.GEN_CAPTURES, buf)
	assert_gt(cap_n, 0, "fixture should have captures")
	var capture_move: int = buf[0]
	assert_true(pos.see_ge(capture_move, 0))
	var quiet_n: int = MG.generate(pos, MG.GEN_QUIETS, buf)
	assert_gt(quiet_n, 0)
	var quiet_move: int = buf[0]
	var picker = MP.new()
	picker.init_main(pos, quiet_move, 3, Hist.new(), 0)
	var ordered: PackedInt32Array = picker.collect_all()
	assert_eq(ordered[0], quiet_move, "TT quiet first")
	var idx_cap := -1
	var idx_quiet2 := -1
	for i in range(ordered.size()):
		if ordered[i] == capture_move:
			idx_cap = i
		elif ordered[i] != quiet_move and not pos.capture(ordered[i]) and idx_quiet2 < 0:
			idx_quiet2 = i
	assert_ne(idx_cap, -1)
	assert_ne(idx_quiet2, -1)
	assert_lt(idx_cap, idx_quiet2, "good capture before non-TT quiet")


func test_move_picker_bad_captures_after_quiets() -> void:
	## White rook takes pawn protected by black rook → SEE-losing under picker threshold.
	## Upstream stage order: GOOD_QUIET then BAD_CAPTURE.
	var pos = Pos.new()
	var fen := "3k5/9/9/9/9/1r7/1p7/1R7/9/4K4 w - - 0 1"
	assert_eq(pos.set_fen(fen), OK)
	var buf := PackedInt32Array()
	buf.resize(T.MAX_MOVES)
	var cap_n: int = MG.generate(pos, MG.GEN_CAPTURES, buf)
	assert_eq(cap_n, 1)
	var bad_cap: int = buf[0]
	var victim: int = T.PIECE_VALUE[pos.piece_on(T.to_sq(bad_cap))]
	var thr: int = -int(7 * victim / 18)
	assert_false(pos.see_ge(bad_cap, thr), "fixture capture is SEE-losing for picker")
	var quiet_n: int = MG.generate(pos, MG.GEN_QUIETS, buf)
	assert_gt(quiet_n, 0)
	var sample_quiet: int = buf[0]
	var picker = MP.new()
	picker.init_main(pos, T.MOVE_NONE, 4, Hist.new(), 0)
	var ordered: PackedInt32Array = picker.collect_all()
	var idx_quiet := -1
	var idx_bad := -1
	for i in range(ordered.size()):
		if ordered[i] == sample_quiet:
			idx_quiet = i
		if ordered[i] == bad_cap:
			idx_bad = i
	assert_ne(idx_quiet, -1)
	assert_ne(idx_bad, -1)
	assert_lt(idx_quiet, idx_bad, "quiet before bad capture")


func test_search_worker_uses_move_picker() -> void:
	var pos = Pos.new()
	assert_eq(pos.set_fen(START_FEN), OK)
	var w = Worker.new()
	w.pos = pos
	var raw: Dictionary = w.search(1, 0)
	assert_true(T.move_is_ok(int(raw["bestmove"])))
	assert_true(pos.legal(int(raw["bestmove"])))
	assert_ne(w.history, null)
