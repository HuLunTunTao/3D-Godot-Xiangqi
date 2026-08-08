extends GutTest

## GPU/CPU parity, batch edge cases, engine facade.

const NNUELoader = preload("res://addons/pikafish/nnue/loader.gd")
const XFeatures = preload("res://addons/pikafish/nnue/features.gd")
const XGpuInference = preload("res://addons/pikafish/nnue/gpu_inference.gd")
const XRefInference = preload("res://addons/pikafish/nnue/cpu_inference.gd")
const XNnueEngine = preload("res://src/test/nnue_test_engine.gd")
const XBoard = preload("res://addons/pikafish/nnue/board.gd")
const S = preload("res://src/test/gut/nnue_test_support.gd")

var loader: NNUELoader
var features: XFeatures
var ref: XRefInference
var gpu
var engine
var ref_data: Array = []


func before_all() -> void:
	loader = NNUELoader.new()
	loader.load_all()
	features = XFeatures.new(loader)
	ref = XRefInference.new(loader, features)
	gpu = XGpuInference.try_create(loader, features)
	engine = XNnueEngine.new(loader, features)
	var f := FileAccess.open("res://data/reference.json", FileAccess.READ)
	ref_data = JSON.parse_string(f.get_as_text())
	f.close()


func test_engine_backend_is_gpu_or_cpu() -> void:
	assert_true(engine.backend_name == "gpu" or engine.backend_name == "cpu")
	assert_eq(engine.using_gpu, engine.backend_name == "gpu")


func test_gpu_matches_cpu_reference() -> void:
	if gpu == null or not gpu.ready:
		pass_test("skipped: no RenderingDevice")
		return
	var bad := 0
	for rec in ref_data:
		var b := S.board_from_fen(rec["fen"])
		var c: int = ref.evaluate(b)
		var g: int = gpu.evaluate(b)
		if absi(c - g) > 1:
			bad += 1
			push_error("gpu!=cpu fen=%s cpu=%d gpu=%d" % [rec["fen"], c, g])
	assert_eq(bad, 0)


func test_gpu_matches_cpu_after_move_overflow_case() -> void:
	if gpu == null or not gpu.ready:
		pass_test("skipped: no RenderingDevice")
		return
	var b := S.board_from_fen("4ka3/4a4/N8/p8/C8/9/9/8B/3p2ppc/4K4 w")
	b.do_move(63, 56)
	assert_true(absi(ref.evaluate(b) - gpu.evaluate(b)) <= 1)


func test_batch_single_matches_evaluate() -> void:
	var b := S.board_from_fen(ref_data[0]["fen"])
	var one: PackedInt32Array = engine.evaluate_batch([b])
	assert_eq(one.size(), 1)
	assert_true(absi(one[0] - engine.evaluate(b)) <= 1)


func test_batch_empty_returns_empty() -> void:
	var res: PackedInt32Array = engine.evaluate_batch([])
	assert_eq(res.size(), 0)


func test_batch_duplicates_consistent() -> void:
	var boards: Array = []
	var b0 := S.board_from_fen(ref_data[0]["fen"])
	for _i in range(16):
		boards.append(b0)
	var res: PackedInt32Array = engine.evaluate_batch(boards)
	assert_eq(res.size(), 16)
	for i in range(16):
		assert_eq(res[i], res[0], "duplicate boards same eval")


func test_batch_large_repeats_within_limit() -> void:
	if gpu == null or not gpu.ready:
		# CPU path is slow; keep modest
		var boards: Array = []
		for i in range(mini(32, ref_data.size())):
			boards.append(S.board_from_fen(ref_data[i % ref_data.size()]["fen"]))
		var res: PackedInt32Array = engine.evaluate_batch(boards)
		assert_eq(res.size(), boards.size())
		return
	var n := 128
	var boards: Array = []
	for i in range(n):
		boards.append(S.board_from_fen(ref_data[i % ref_data.size()]["fen"]))
	var res: PackedInt32Array = gpu.evaluate_batch(boards)
	assert_eq(res.size(), n)
	for i in range(n):
		var want: int = int(ref_data[i % ref_data.size()]["internal"])
		assert_true(absi(res[i] - want) <= 1, "large batch idx %d" % i)


func test_batch_matches_per_position_evaluate() -> void:
	var boards: Array = []
	for rec in ref_data:
		boards.append(S.board_from_fen(rec["fen"]))
	var batched: PackedInt32Array = engine.evaluate_batch(boards)
	var bad := 0
	for i in range(boards.size()):
		var single: int = engine.evaluate(boards[i])
		if absi(batched[i] - single) > 1:
			bad += 1
	assert_eq(bad, 0)


func test_try_create_null_safe_when_called_twice() -> void:
	var g2 = XGpuInference.try_create(loader, features)
	# May be null headless; must not crash
	if g2 != null:
		assert_true(g2.ready)
		assert_true(absi(g2.evaluate(S.board_from_fen(ref_data[0]["fen"]))
			- int(ref_data[0]["internal"])) <= 1)
