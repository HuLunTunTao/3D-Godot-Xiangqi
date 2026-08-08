extends Node

## On-device Mobile renderer acceptance: 100 synchronous and asynchronous
## 23-position oracle batches. Prints MOBILE_TEST_PASS only after all callbacks.

const NNUELoader = preload("res://addons/pikafish/nnue/loader.gd")
const XFeatures = preload("res://addons/pikafish/nnue/features.gd")
const XNnueEngine = preload("res://src/test/nnue_test_engine.gd")
const XBoard = preload("res://addons/pikafish/nnue/board.gd")
const Reporter = preload("res://src/test/ui/test_reporter.gd")
const Dashboard = preload("res://src/test/ui/test_dashboard.gd")

const REPS = 100
const RESULT_PATH := "user://mobile_test_result.json"

var _engine
var _boards: Array = []
var _expected := PackedInt32Array()
var _async_submitted := 0
var _async_done := 0
var _async_bad := 0
var _async_started_us := 0
var _callback_order: Array[int] = []
var _reporter
var _sync_bad := 0
var _sync_ms := 0.0


func _ready() -> void:
	_reporter = Reporter.new("Mobile batch acceptance")
	var dashboard = Dashboard.new()
	add_child(dashboard)
	dashboard.bind(_reporter)
	call_deferred("_run")


func _run() -> void:
	_reporter.stage("Loading NNUE weights")
	var loader := NNUELoader.new()
	var load_error := loader.load_all()
	if load_error != OK:
		_finish(false, "NNUE load failed: %s" % loader.load_error)
		return
	_engine = XNnueEngine.new(loader, XFeatures.new(loader))
	_reporter.metric("backend", _engine.backend_name)
	_reporter.metric("network_dir", loader.network_dir)
	var records := _load_reference()
	_expected.resize(records.size())
	for i in range(records.size()):
		var board := XBoard.new()
		board.load_fen(records[i]["fen"])
		_boards.append(board)
		_expected[i] = int(records[i]["internal"])

	_reporter.stage("Synchronous GPU/CPU oracle batches", REPS, "%d positions per batch" % _boards.size())
	var sync_started := Time.get_ticks_usec()
	for rep in range(REPS):
		_sync_bad += _count_bad(_engine.evaluate_batch(_boards))
		if rep % 5 == 4 or rep + 1 == REPS:
			_reporter.progress(rep + 1, REPS, "oracle mismatches: %d" % _sync_bad)
			await get_tree().process_frame
	_sync_ms = float(Time.get_ticks_usec() - sync_started) / 1000.0
	print("MOBILE_SYNC device=%s os=%s backend=%s batches=%d eval_s=%.0f bad=%d" % [
		OS.get_model_name(), OS.get_version(), _engine.backend_name, REPS,
		REPS * _boards.size() * 1000.0 / _sync_ms, _sync_bad])
	_reporter.metric("sync_eval_s", "%.0f" % (REPS * _boards.size() * 1000.0 / _sync_ms))
	_reporter.metric("sync_oracle_bad", _sync_bad)
	if _sync_bad != 0:
		_finish(false, "synchronous oracle mismatch")
		return
	_async_started_us = Time.get_ticks_usec()
	_reporter.stage("Async three-slot oracle batches", REPS, "%d positions per batch" % _boards.size())
	_fill_async_slots()


func _fill_async_slots() -> void:
	while _async_submitted < REPS and _async_submitted - _async_done < 3:
		var request_id := _async_submitted
		var error: Error = _engine.evaluate_batch_async(
			_boards, _on_async_batch.bind(request_id))
		if error != OK:
			_finish(false, "async submit failed: %d" % error)
			return
		_async_submitted += 1


func _on_async_batch(result: PackedInt32Array, request_id: int) -> void:
	_callback_order.append(request_id)
	_async_bad += _count_bad(result)
	_async_done += 1
	_reporter.progress(_async_done, REPS, "oracle mismatches: %d" % _async_bad)
	if _async_done < REPS:
		_fill_async_slots()
		return
	var async_ms := float(Time.get_ticks_usec() - _async_started_us) / 1000.0
	var ordered := true
	for i in range(_callback_order.size()):
		if _callback_order[i] != i:
			ordered = false
	print("MOBILE_ASYNC batches=%d eval_s=%.0f bad=%d ordered=%s" % [
		REPS, REPS * _boards.size() * 1000.0 / async_ms, _async_bad, str(ordered)])
	_reporter.metric("async_eval_s", "%.0f" % (REPS * _boards.size() * 1000.0 / async_ms))
	_reporter.metric("async_oracle_bad", _async_bad)
	_reporter.metric("async_callback_ordered", ordered)
	_finish(_async_bad == 0 and ordered, "MOBILE_TEST_PASS" if _async_bad == 0 and ordered else "async acceptance failed")


func _finish(ok: bool, detail: String) -> void:
	if _engine != null:
		_engine = null
	_reporter.finish(ok, detail)
	print("MOBILE_TEST_PASS" if ok else "MOBILE_TEST_FAIL")
	var report: Dictionary = _reporter.snapshot()
	report["sync"] = {"batches": REPS, "bad": _sync_bad, "ms": _sync_ms}
	var file := FileAccess.open(RESULT_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "\t"))
		file.close()
	_reporter.report_log("report saved: %s" % RESULT_PATH)
	if OS.get_cmdline_user_args().has("--auto-quit"):
		await get_tree().create_timer(0.5).timeout
		get_tree().quit(0 if ok else 1)


func _count_bad(result: PackedInt32Array) -> int:
	if result.size() != _expected.size():
		return 1
	var bad := 0
	for i in range(result.size()):
		if absi(result[i] - _expected[i]) > 1:
			bad += 1
	return bad


static func _load_reference() -> Array:
	var file := FileAccess.open("res://data/reference.json", FileAccess.READ)
	var records: Array = JSON.parse_string(file.get_as_text())
	file.close()
	return records
