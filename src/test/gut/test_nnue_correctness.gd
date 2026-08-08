extends GutTest

## Correctness tests: GDScript reference, GPU (when available), and XNnueEngine
## facade (GPU with CPU fallback) must match the pikafish oracle.

const NNUELoader = preload("res://src/nnue/nnue_loader.gd")
const XFeatures = preload("res://src/nnue/features.gd")
const XGpuInference = preload("res://src/nnue/gpu_inference.gd")
const XRefInference = preload("res://src/nnue/ref_inference.gd")
const XNnueEngine = preload("res://src/nnue/nnue_engine.gd")
const XBoard = preload("res://src/nnue/board.gd")

var loader: NNUELoader
var features: XFeatures
var ref: XRefInference
var gpu: XGpuInference
var engine: XNnueEngine
var ref_data: Array = []


func before_all() -> void:
	loader = NNUELoader.new()
	loader.load_all()
	features = XFeatures.new(loader)
	ref = XRefInference.new(loader, features)
	gpu = XGpuInference.try_create(loader, features)
	engine = XNnueEngine.new(loader, features)
	var f := FileAccess.open("res://data/reference.json", FileAccess.READ)
	assert_true(f != null, "cannot open reference.json")
	ref_data = JSON.parse_string(f.get_as_text())
	f.close()


func _board_for(rec) -> XBoard:
	var b := XBoard.new()
	b.load_fen(rec["fen"])
	return b


func test_loader_sizes() -> void:
	assert_eq(loader.ft_psq_w.size(), 16536 * 1024)
	assert_eq(loader.ft_threat_w.size(), 45547 * 1024)
	assert_eq(loader.ft_bias_raw.size(), 1024 * 2)
	assert_eq(loader.ft_psqt_raw.size(), 16536 * 16 * 4)
	assert_eq(loader.ft_threat_psqt_raw.size(), 45547 * 16 * 4)
	assert_eq(loader.psq_offsets.size(), 16 * 90)
	assert_eq(loader.threat_offsets.size(), 16 * 90 * 90 * 16 * 2)
	assert_eq(loader.fc0_w.size(), 16)
	assert_eq(loader.fc0_w[0].size(), 32 * 1024)
	assert_eq(loader.fc1_w[0].size(), 32 * 64)
	assert_eq(loader.fc2_w[0].size(), 128)


func test_ref_inference_matches_oracle() -> void:
	assert_gt(ref_data.size(), 0)
	var mismatches := 0
	for rec in ref_data:
		var got: int = ref.evaluate(_board_for(rec))
		var want: int = int(rec["internal"])
		if absi(got - want) > 1:
			mismatches += 1
			push_error("ref mismatch fen=%s got=%d want=%d" % [rec["fen"], got, want])
	assert_eq(mismatches, 0, "GDScript reference must match oracle (tolerance 1)")


func test_gpu_inference_matches_oracle() -> void:
	if gpu == null or not gpu.ready:
		pass_test("skipped: no RenderingDevice (CPU-only environment)")
		return
	assert_gt(ref_data.size(), 0)
	var mismatches := 0
	for rec in ref_data:
		var got: int = gpu.evaluate(_board_for(rec))
		var want: int = int(rec["internal"])
		if absi(got - want) > 1:
			mismatches += 1
			push_error("gpu mismatch fen=%s got=%d want=%d" % [rec["fen"], got, want])
	assert_eq(mismatches, 0, "GPU inference must match oracle (tolerance 1)")


func test_gpu_batched_matches_oracle() -> void:
	if gpu == null or not gpu.ready:
		pass_test("skipped: no RenderingDevice (CPU-only environment)")
		return
	assert_gt(ref_data.size(), 0)
	var boards := []
	for rec in ref_data:
		boards.append(_board_for(rec))
	var res: PackedInt32Array = gpu.evaluate_batch(boards)
	var mismatches := 0
	for i in range(ref_data.size()):
		var want: int = int(ref_data[i]["internal"])
		if absi(res[i] - want) > 1:
			mismatches += 1
	assert_eq(mismatches, 0, "GPU batched inference must match oracle (tolerance 1)")


func test_engine_matches_oracle() -> void:
	# Facade always works: GPU when available, else CPU reference.
	assert_true(engine != null)
	assert_true(engine.backend_name == "gpu" or engine.backend_name == "cpu")
	assert_gt(ref_data.size(), 0)
	var mismatches := 0
	for rec in ref_data:
		var got: int = engine.evaluate(_board_for(rec))
		var want: int = int(rec["internal"])
		if absi(got - want) > 1:
			mismatches += 1
			push_error("engine(%s) mismatch fen=%s got=%d want=%d" % [
				engine.backend_name, rec["fen"], got, want])
	assert_eq(mismatches, 0, "XNnueEngine must match oracle (tolerance 1)")


func test_engine_batch_matches_oracle() -> void:
	var boards := []
	for rec in ref_data:
		boards.append(_board_for(rec))
	var res: PackedInt32Array = engine.evaluate_batch(boards)
	var mismatches := 0
	for i in range(ref_data.size()):
		var want: int = int(ref_data[i]["internal"])
		if absi(res[i] - want) > 1:
			mismatches += 1
	assert_eq(mismatches, 0, "XNnueEngine.evaluate_batch must match oracle")


func test_features_bucket_and_counts() -> void:
	# startpos sanity: layer-stack bucket 11, 32 pieces
	var b := _board_for(ref_data[0])
	assert_eq(features.make_layer_stack_bucket(b), 11)
	var psq := features.append_active_psq(0, b, 7, false)
	assert_eq(psq.size(), 32)
	var thr := features.append_active_threats(0, b, false)
	assert_gt(thr.size(), 0)


func test_incremental_matches_full_eval() -> void:
	# Start from reference FEN, play a capture/non-capture style move if present.
	# Compare incremental eval to fresh full evaluate after each do/undo.
	var mismatches := 0
	var checked := 0
	for rec in ref_data:
		var b := _board_for(rec)
		# Find a legal-ish move: first piece of stm that can capture or step to empty
		# Use a simple scan: try moving each stm piece one attack/capture target.
		engine.refresh(b)
		var base: int = engine.evaluate_incremental(b)
		var full0: int = engine.evaluate(b)
		if absi(base - full0) > 1:
			mismatches += 1
			push_error("inc refresh mismatch got=%d full=%d fen=%s" % [base, full0, rec["fen"]])
		var moved := false
		for frm in b.piece_list:
			var pc: int = b.sq[frm]
			if (pc >> 3) != b.stm:
				continue
			# Prefer an adjacent empty or occupied square via attack generator
			var XAttacks = preload("res://src/nnue/attacks.gd")
			var attacks: Array
			var pt := pc & 7
			if pt == 4:  # PAWN
				attacks = XAttacks.pawn_attacks_bb(pc >> 3, frm)
			else:
				attacks = XAttacks.attacks_bb(pt, frm, b.occ, pc >> 3, features.palace)
			for to_any in attacks:
				var to: int = to_any
				# skip if destination occupied by own piece
				if b.occ[to] == 1 and (b.sq[to] >> 3) == b.stm:
					continue
				engine.do_move(b, frm, to)
				var inc_v: int = engine.evaluate_incremental(b)
				var full_v: int = engine.evaluate(b)
				if absi(inc_v - full_v) > 1:
					mismatches += 1
					push_error("inc after move mismatch inc=%d full=%d frm=%d to=%d fen=%s" % [
						inc_v, full_v, frm, to, rec["fen"]])
				engine.undo_move(b)
				var back: int = engine.evaluate_incremental(b)
				if absi(back - base) > 1:
					mismatches += 1
					push_error("inc after undo mismatch got=%d want=%d" % [back, base])
				moved = true
				checked += 1
				break
			if moved:
				break
		if not moved:
			checked += 1  # still counted refresh check
	assert_gt(checked, 0)
	assert_eq(mismatches, 0, "incremental accumulator must match full eval")


func test_board_do_undo_restores() -> void:
	var b := _board_for(ref_data[0])
	var snap_sq := b.sq.duplicate()
	var snap_stm := b.stm
	var snap_counts := b.piece_counts.duplicate()
	var snap_kings := b.kings.duplicate()
	var frm := -1
	var to := -1
	for s in b.piece_list:
		if b.sq[s] == 4:  # W_PAWN
			frm = s
			to = s + 9  # north
			if to < 90 and b.occ[to] == 0:
				break
			frm = -1
	if frm < 0:
		pass_test("no simple white pawn push in startpos scan")
		return
	var u: Dictionary = b.do_move(frm, to)
	assert_ne(b.stm, snap_stm)
	b.undo_move(u)
	assert_eq(b.stm, snap_stm)
	assert_eq(b.sq, snap_sq)
	assert_eq(b.piece_counts, snap_counts)
	assert_eq(b.kings, snap_kings)
	# piece_list order may change (swap-pop); content must match occupied squares
	var occupied := PackedInt32Array()
	for s in range(90):
		if b.occ[s] == 1:
			occupied.append(s)
	var pl := b.piece_list.duplicate()
	occupied.sort()
	pl.sort()
	assert_eq(pl, occupied)
