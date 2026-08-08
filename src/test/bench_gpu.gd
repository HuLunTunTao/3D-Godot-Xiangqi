extends SceneTree

## Reproducible NNUE benchmark. Run with a graphical renderer:
## Godot --path . -s res://src/test/bench_gpu.gd

const C = preload("res://src/nnue/nnue_consts.gd")
const NNUELoader = preload("res://src/nnue/nnue_loader.gd")
const XFeatures = preload("res://src/nnue/features.gd")
const XGpuInference = preload("res://src/nnue/gpu_inference.gd")
const XRefInference = preload("res://src/nnue/ref_inference.gd")
const XIncAccumulator = preload("res://src/nnue/inc_accumulator.gd")
const XNnueEngine = preload("res://src/nnue/nnue_engine.gd")
const XBoard = preload("res://src/nnue/board.gd")
const TestSupport = preload("res://src/test/gut/nnue_test_support.gd")

const BATCH_SIZES = [1, 8, 23, 64, 128, 256, 512]
const WARMUP_REPS = 10
const MEASURE_REPS = 100
const BREAKDOWN_REPS = 10

var _lines: PackedStringArray = []
var _async_done := 0
var _async_bad := 0
var _async_order: Array[int] = []


func _log(line := "") -> void:
	_lines.append(line)
	print(line)


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_log("# godot-pikafish performance log")
	_log("")
	_log("- Date: %s" % Time.get_datetime_string_from_system(false, true))
	_log("- Godot: %s" % Engine.get_version_info()["string"])
	_log("- CPU threads: %d" % OS.get_processor_count())
	_log("- Warmup / samples: %d / %d" % [WARMUP_REPS, MEASURE_REPS])

	var init_start := Time.get_ticks_msec()
	var loader := NNUELoader.new()
	loader.load_all()
	var features := XFeatures.new(loader)
	var gpu := XGpuInference.new(loader, features)
	var records := _load_reference()
	var base_boards := _make_boards(records, records.size())
	_log("- Initialization: %d ms" % (Time.get_ticks_msec() - init_start))

	var correct := _check_oracle(gpu, base_boards, records)
	_log("- Oracle correctness: %d/%d (tolerance <= 1)" % [correct, records.size()])
	_log("")
	_log("## Synchronous batch end-to-end")
	_log("")
	_log("| batch | p50 ms/batch | p95 ms/batch | p50 ms/eval | throughput eval/s |")
	_log("| ---: | ---: | ---: | ---: | ---: |")
	for n in BATCH_SIZES:
		var boards := _make_boards(records, n)
		for _i in range(WARMUP_REPS):
			gpu.evaluate_batch(boards)
		var samples := PackedFloat64Array()
		for _i in range(MEASURE_REPS):
			var started := Time.get_ticks_usec()
			gpu.evaluate_batch(boards)
			samples.append(float(Time.get_ticks_usec() - started) / 1000.0)
		var p50 := _percentile(samples, 0.50)
		var p95 := _percentile(samples, 0.95)
		_log("| %d | %.3f | %.3f | %.4f | %.0f |" % [
			n, p50, p95, p50 / n, n * 1000.0 / p50])

	_log("")
	_log("## 23-position timing decomposition")
	_log("")
	var breakdown := _measure_breakdown(gpu, _make_boards(records, 23))
	for key in ["features", "conversion", "upload", "accumulator", "forward", "readback"]:
		_log("- %s: %.3f ms/batch" % [key, breakdown[key]])

	_log("")
	_log("## Incremental search helper")
	_log("")
	var incremental := _measure_incremental(loader, features, records[0]["fen"])
	_log("- 1000 x do/evaluate/undo p50: %.3f ms, p95: %.3f ms" % [
		incremental.x, incremental.y])

	_log("")
	_log("## Three-slot asynchronous pipeline")
	_log("")
	var async_engine := XNnueEngine.new(loader, features)
	var async_boards := _make_boards(records, 23)
	# Initialize the worker/device and warm it with ten batches.
	_async_done = 0
	_async_bad = 0
	_async_order.clear()
	var async_submitted := 0
	while _async_done < WARMUP_REPS:
		while async_submitted < WARMUP_REPS and async_submitted - _async_done < 3:
			var warm_error := async_engine.evaluate_batch_async(
				async_boards, _on_async_batch.bind(async_submitted, records))
			assert(warm_error == OK, "async warmup submit failed: %d" % warm_error)
			async_submitted += 1
		await process_frame

	_async_done = 0
	_async_bad = 0
	_async_order.clear()
	async_submitted = 0
	var async_started := Time.get_ticks_usec()
	while _async_done < MEASURE_REPS:
		while async_submitted < MEASURE_REPS and async_submitted - _async_done < 3:
			var error := async_engine.evaluate_batch_async(
				async_boards, _on_async_batch.bind(async_submitted, records))
			assert(error == OK, "async benchmark submit failed: %d" % error)
			async_submitted += 1
		await process_frame
	var async_ms := float(Time.get_ticks_usec() - async_started) / 1000.0
	var ordered := true
	for i in range(_async_order.size()):
		if _async_order[i] != i:
			ordered = false
	_log("- %d x 23 batches: %.3f ms, %.0f eval/s" % [
		MEASURE_REPS, async_ms, MEASURE_REPS * 23.0 * 1000.0 / async_ms])
	_log("- callbacks ordered: %s; mismatches: %d; backend: %s" % [
		str(ordered), _async_bad, async_engine.backend_name])

	var out := FileAccess.open("res://perf-log.md", FileAccess.WRITE)
	assert(out != null, "cannot write perf-log.md")
	out.store_string("\n".join(_lines) + "\n")
	out.close()
	gpu.dispose()
	quit(0 if correct == records.size() and _async_bad == 0 else 1)


func _on_async_batch(
	result: PackedInt32Array, request_id: int, records: Array
) -> void:
	_async_order.append(request_id)
	if result.size() != 23:
		_async_bad += 1
	else:
		for i in range(result.size()):
			if absi(result[i] - int(records[i % records.size()]["internal"])) > 1:
				_async_bad += 1
	_async_done += 1


func _measure_breakdown(gpu: XGpuInference, positions: Array) -> Dictionary:
	var totals := {
		"features": 0.0, "conversion": 0.0, "upload": 0.0,
		"accumulator": 0.0, "forward": 0.0, "readback": 0.0,
	}
	var n := positions.size()
	gpu._init_batch()
	for _rep in range(BREAKDOWN_REPS):
		var started := Time.get_ticks_usec()
		gpu._build_batch_host(positions)
		totals["features"] += Time.get_ticks_usec() - started

		started = Time.get_ticks_usec()
		var active_bytes := gpu._b_active.to_byte_array()
		var bucket_bytes := gpu._b_buckets.to_byte_array()
		totals["conversion"] += Time.get_ticks_usec() - started

		started = Time.get_ticks_usec()
		gpu.rd.buffer_update(gpu.b_active_buf, 0, n * XGpuInference.ACTIVE_SIZE * 4, active_bytes)
		gpu.rd.buffer_update(gpu.b_bucket_buf, 0, n * 4, bucket_bytes)
		gpu._params_bytes.encode_s32(0, n)
		gpu.rd.buffer_update(gpu.b_params_buf, 0, 4, gpu._params_bytes)
		totals["upload"] += Time.get_ticks_usec() - started

		started = Time.get_ticks_usec()
		var cl := gpu.rd.compute_list_begin()
		gpu.rd.compute_list_bind_compute_pipeline(cl, gpu.b_acc_pipe)
		gpu.rd.compute_list_bind_uniform_set(cl, gpu.b_acc_set, 0)
		gpu.rd.compute_list_dispatch(cl, int((n * C.L1 + 63) / 64), 1, 1)
		gpu.rd.compute_list_end()
		gpu.rd.submit()
		gpu.rd.sync()
		totals["accumulator"] += Time.get_ticks_usec() - started

		started = Time.get_ticks_usec()
		cl = gpu.rd.compute_list_begin()
		gpu.rd.compute_list_bind_compute_pipeline(cl, gpu.b_fwd_pipe)
		gpu.rd.compute_list_bind_uniform_set(cl, gpu.b_fwd_set, 0)
		gpu.rd.compute_list_dispatch(cl, n, 1, 1)
		gpu.rd.compute_list_end()
		gpu.rd.submit()
		gpu.rd.sync()
		totals["forward"] += Time.get_ticks_usec() - started

		started = Time.get_ticks_usec()
		gpu.rd.buffer_get_data(gpu.b_out_buf, 0, n * 4)
		totals["readback"] += Time.get_ticks_usec() - started
	for key in totals:
		totals[key] = totals[key] / (1000.0 * BREAKDOWN_REPS)
	return totals


func _measure_incremental(loader: NNUELoader, features: XFeatures, fen: String) -> Vector2:
	var board := XBoard.new()
	board.load_fen(fen)
	var inc := XIncAccumulator.new(loader, features)
	inc.refresh(board)
	var moves: Array = TestSupport.collect_stm_moves(board, features.palace)
	assert(not moves.is_empty(), "benchmark position has no moves")
	var samples := PackedFloat64Array()
	for i in range(1000):
		var move: Vector2i = moves[i % moves.size()]
		var started := Time.get_ticks_usec()
		var board_frame := board.do_move(move.x, move.y)
		var inc_frame := inc.update_after_move(board)
		inc.evaluate(board)
		board.undo_move(board_frame)
		inc.undo_update(inc_frame)
		samples.append(float(Time.get_ticks_usec() - started) / 1000.0)
	return Vector2(_percentile(samples, 0.50), _percentile(samples, 0.95))


static func _percentile(values: PackedFloat64Array, fraction: float) -> float:
	var sorted := Array(values)
	sorted.sort()
	var index := clampi(ceili(fraction * sorted.size()) - 1, 0, sorted.size() - 1)
	return sorted[index]


static func _make_boards(records: Array, n: int) -> Array:
	var boards: Array = []
	boards.resize(n)
	for i in range(n):
		var board := XBoard.new()
		board.load_fen(records[i % records.size()]["fen"])
		boards[i] = board
	return boards


static func _check_oracle(gpu: XGpuInference, boards: Array, records: Array) -> int:
	var result := gpu.evaluate_batch(boards)
	var correct := 0
	for i in range(records.size()):
		if absi(result[i] - int(records[i]["internal"])) <= 1:
			correct += 1
	return correct


static func _load_reference() -> Array:
	var file := FileAccess.open("res://data/reference.json", FileAccess.READ)
	assert(file != null, "cannot open reference.json")
	var records: Array = JSON.parse_string(file.get_as_text())
	file.close()
	return records
