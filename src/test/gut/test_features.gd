extends GutTest

## Feature extraction: fill_active_both vs append_* ; buckets ; PSQT lane.

const C = preload("res://addons/pikafish/nnue/consts.gd")
const NNUELoader = preload("res://addons/pikafish/nnue/loader.gd")
const XFeatures = preload("res://addons/pikafish/nnue/features.gd")
const S = preload("res://src/test/gut/nnue_test_support.gd")

var loader: NNUELoader
var features: XFeatures
var ref_data: Array = []


func before_all() -> void:
	loader = NNUELoader.new()
	loader.load_all()
	features = XFeatures.new(loader)
	var f := FileAccess.open("res://data/reference.json", FileAccess.READ)
	ref_data = JSON.parse_string(f.get_as_text())
	f.close()


func _lists_equal(a: PackedInt32Array, off: int, n: int, arr: PackedInt32Array) -> bool:
	if n != arr.size():
		return false
	# Compare as sets (order of piece_list / captures may differ)
	return S.sorted_unique(_slice(a, off, n)) == S.sorted_unique(arr)


func _slice(a: PackedInt32Array, off: int, n: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	out.resize(n)
	for i in range(n):
		out[i] = a[off + i]
	return out


func test_startpos_layer_stack_bucket() -> void:
	var b := S.board_from_fen(ref_data[0]["fen"])
	assert_eq(features.make_layer_stack_bucket(b), 11)
	assert_eq(b.piece_list.size(), 32)


func test_fill_active_matches_append_all_reference() -> void:
	var act := PackedInt32Array()
	act.resize(260)
	var mismatches := 0
	for rec in ref_data:
		var b := S.board_from_fen(rec["fen"])
		var stm: int = b.stm
		features.fill_active_both(act, 0, b, stm)
		for p in range(2):
			var persp: int = stm if p == 0 else stm ^ 1
			var base := p * 130
			var fb := features.make_feature_bucket_v(persp, b)
			var psq: PackedInt32Array = features.append_active_psq(persp, b, fb.x, fb.y != 0)
			var thr: PackedInt32Array = features.append_active_threats(persp, b, fb.y != 0)
			if not _lists_equal(act, base + 1, act[base], psq):
				mismatches += 1
				push_error("psq mismatch p=%d fen=%s" % [p, rec["fen"]])
			if not _lists_equal(act, base + 66, act[base + 65], thr):
				mismatches += 1
				push_error("thr mismatch p=%d fen=%s fill_n=%d app_n=%d" % [
					p, rec["fen"], act[base + 65], thr.size()])
	assert_eq(mismatches, 0, "fill_active_both must match append_active_*")


func test_fill_returns_layer_stack_bucket() -> void:
	for rec in ref_data:
		var b := S.board_from_fen(rec["fen"])
		var act := PackedInt32Array()
		act.resize(260)
		var got: int = features.fill_active_both(act, 0, b, b.stm)
		assert_eq(got, features.make_layer_stack_bucket(b))


func test_psqt_lane_matches_manual_sum() -> void:
	var act := PackedInt32Array()
	act.resize(260)
	for rec in ref_data:
		var b := S.board_from_fen(rec["fen"])
		var lbucket := features.make_layer_stack_bucket(b)
		var pair: Vector2i = features.fill_both_perspectives(
			act, 0, b, b.stm, lbucket, loader.ft_psqt_raw, loader.ft_threat_psqt_raw)
		# Re-sum from actives
		var p0 := 0
		var p1 := 0
		for k in range(act[0]):
			p0 += loader.ft_psqt_raw.decode_s32((act[1 + k] * C.PSQTBUCKETS + lbucket) * 4)
		for k in range(act[65]):
			p0 += loader.ft_threat_psqt_raw.decode_s32((act[66 + k] * C.PSQTBUCKETS + lbucket) * 4)
		for k in range(act[130]):
			p1 += loader.ft_psqt_raw.decode_s32((act[131 + k] * C.PSQTBUCKETS + lbucket) * 4)
		for k in range(act[195]):
			p1 += loader.ft_threat_psqt_raw.decode_s32((act[196 + k] * C.PSQTBUCKETS + lbucket) * 4)
		assert_eq(pair.x, p0, "psqt0 fen=%s" % rec["fen"])
		assert_eq(pair.y, p1, "psqt1 fen=%s" % rec["fen"])


func test_feature_bucket_in_range() -> void:
	for rec in ref_data:
		var b := S.board_from_fen(rec["fen"])
		for persp in [b.stm, b.stm ^ 1]:
			var fb := features.make_feature_bucket_v(persp, b)
			assert_true(fb.x >= 0 and fb.x < 32, "feature bucket range")
			assert_true(fb.y == 0 or fb.y == 1, "mirror flag")
