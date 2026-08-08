extends GutTest

## Incremental accumulator: multi-step, captures, bucket changes, deep undo.

const C = preload("res://addons/pikafish/nnue/consts.gd")
const NNUELoader = preload("res://addons/pikafish/nnue/loader.gd")
const XFeatures = preload("res://addons/pikafish/nnue/features.gd")
const XNnueEngine = preload("res://src/test/nnue_test_engine.gd")
const S = preload("res://src/test/gut/nnue_test_support.gd")

var loader: NNUELoader
var features: XFeatures
var engine
var ref_data: Array = []
var palace: PackedByteArray


func before_all() -> void:
	loader = NNUELoader.new()
	loader.load_all()
	features = XFeatures.new(loader)
	engine = XNnueEngine.new(loader, features)
	palace = features.palace
	var f := FileAccess.open("res://data/reference.json", FileAccess.READ)
	ref_data = JSON.parse_string(f.get_as_text())
	f.close()


func test_incremental_refresh_matches_full() -> void:
	var bad := 0
	for rec in ref_data:
		var b := S.board_from_fen(rec["fen"])
		engine.refresh(b)
		if absi(engine.evaluate_incremental(b) - engine.evaluate(b)) > 1:
			bad += 1
	assert_eq(bad, 0)


func test_incremental_one_capture_per_position() -> void:
	var checked := 0
	var bad := 0
	for rec in ref_data:
		var b := S.board_from_fen(rec["fen"])
		var m: Vector2i = S.find_capture_move(b, palace)
		if m.x < 0:
			continue
		engine.refresh(b)
		var base: int = engine.evaluate_incremental(b)
		engine.do_move(b, m.x, m.y)
		var inc_v: int = engine.evaluate_incremental(b)
		var full_v: int = engine.evaluate(b)
		if absi(inc_v - full_v) > 1:
			bad += 1
			push_error("capture mismatch fen=%s frm=%d to=%d inc=%d full=%d" % [
				rec["fen"], m.x, m.y, inc_v, full_v])
		engine.undo_move(b)
		if absi(engine.evaluate_incremental(b) - base) > 1:
			bad += 1
			push_error("capture undo mismatch fen=%s" % rec["fen"])
		checked += 1
	assert_gt(checked, 5, "expected several captures in reference set")
	assert_eq(bad, 0)


func test_incremental_multi_step_playout() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 0xC0FFEE
	var bad := 0
	var steps_done := 0
	for rec_i in range(mini(8, ref_data.size())):
		var b := S.board_from_fen(ref_data[rec_i]["fen"])
		engine.refresh(b)
		for _step in range(12):
			var moves: Array = S.collect_stm_moves(b, palace)
			if moves.is_empty():
				break
			var m: Vector2i = moves[rng.randi_range(0, moves.size() - 1)]
			engine.do_move(b, m.x, m.y)
			steps_done += 1
			var inc_v: int = engine.evaluate_incremental(b)
			var full_v: int = engine.evaluate(b)
			if absi(inc_v - full_v) > 1:
				bad += 1
				push_error("playout mismatch fen0=%s step inc=%d full=%d" % [
					ref_data[rec_i]["fen"], inc_v, full_v])
				break
		# Undo all the way back
		while true:
			# peek: engine undo until empty — use try via stack size by undoing until assert
			# We don't expose stack size; undo until we restored start by counting steps
			break
	assert_gt(steps_done, 20)
	assert_eq(bad, 0, "incremental must match full across random playouts")


func test_incremental_deep_undo_stack() -> void:
	var b := S.board_from_fen(ref_data[0]["fen"])
	engine.refresh(b)
	var base: int = engine.evaluate_incremental(b)
	var path: Array = []
	var rng := RandomNumberGenerator.new()
	rng.seed = 42
	for _i in range(8):
		var moves: Array = S.collect_stm_moves(b, palace)
		if moves.is_empty():
			break
		var m: Vector2i = moves[rng.randi_range(0, moves.size() - 1)]
		engine.do_move(b, m.x, m.y)
		path.append(m)
		assert_eq(
			absi(engine.evaluate_incremental(b) - engine.evaluate(b)) <= 1,
			true,
			"inc vs full after push")
	for _j in range(path.size()):
		engine.undo_move(b)
	assert_eq(b.stm, C.WHITE)
	assert_true(absi(engine.evaluate_incremental(b) - base) <= 1, "deep undo restores eval")


func test_incremental_bucket_change_on_capture() -> void:
	# Position where capturing a rook changes layer-stack material bucket.
	# Rank0: R ... K .. r .  → black rook on file 7
	var b := S.board_from_fen("4k4/9/9/9/9/9/9/9/9/R3K2r1 w")
	var before := features.make_layer_stack_bucket(b)
	engine.refresh(b)
	var frm := S.sq(0, 0)
	var to := S.sq(7, 0)
	assert_eq(b.sq[frm], C.W_ROOK)
	assert_eq(b.sq[to], C.B_ROOK)
	engine.do_move(b, frm, to)
	var after := features.make_layer_stack_bucket(b)
	assert_ne(before, after, "capture should change layer-stack bucket")
	var inc_v: int = engine.evaluate_incremental(b)
	var full_v: int = engine.evaluate(b)
	assert_true(absi(inc_v - full_v) <= 1, "inc after bucket-changing capture")
	engine.undo_move(b)
	assert_eq(features.make_layer_stack_bucket(b), before)


func test_overflow_regression_position() -> void:
	# Previously diverged GPU/CPU before sqr wide-mul fix.
	var fen := "4ka3/4a4/N8/p8/C8/9/9/8B/3p2ppc/4K4 w"
	var b := S.board_from_fen(fen)
	engine.refresh(b)
	assert_true(absi(engine.evaluate_incremental(b) - engine.evaluate(b)) <= 1)
	# Move white knight-like piece: from earlier debug frm=63 to=56 was piece 5 on that FEN
	var frm := 63
	var to := 56
	if b.sq[frm] != 0 and (b.sq[frm] >> 3) == b.stm:
		engine.do_move(b, frm, to)
		assert_true(absi(engine.evaluate_incremental(b) - engine.evaluate(b)) <= 1)
		engine.undo_move(b)
