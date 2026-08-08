extends Node

## On-device Mobile renderer acceptance: 100 synchronous and asynchronous
## 23-position oracle batches. Prints MOBILE_TEST_PASS only after all callbacks.

const NNUELoader = preload("res://addons/pikafish/nnue/loader.gd")
const XFeatures = preload("res://addons/pikafish/nnue/features.gd")
const XNnueEngine = preload("res://src/test/nnue_test_engine.gd")
const XBoard = preload("res://addons/pikafish/nnue/board.gd")

const REPS = 100

var _engine
var _boards: Array = []
var _expected := PackedInt32Array()
var _async_submitted := 0
var _async_done := 0
var _async_bad := 0
var _async_started_us := 0
var _callback_order: Array[int] = []


func _ready() -> void:
	var loader := NNUELoader.new()
	loader.load_all()
	_engine = XNnueEngine.new(loader, XFeatures.new(loader))
	var records := _load_reference()
	_expected.resize(records.size())
	for i in range(records.size()):
		var board := XBoard.new()
		board.load_fen(records[i]["fen"])
		_boards.append(board)
		_expected[i] = int(records[i]["internal"])

	var sync_bad := 0
	var sync_started := Time.get_ticks_usec()
	for _rep in range(REPS):
		sync_bad += _count_bad(_engine.evaluate_batch(_boards))
	var sync_ms := float(Time.get_ticks_usec() - sync_started) / 1000.0
	print("MOBILE_SYNC device=%s os=%s backend=%s batches=%d eval_s=%.0f bad=%d" % [
		OS.get_model_name(), OS.get_version(), _engine.backend_name, REPS,
		REPS * _boards.size() * 1000.0 / sync_ms, sync_bad])
	if sync_bad != 0:
		push_error("mobile synchronous oracle mismatch")
		get_tree().quit(1)
		return
	_async_started_us = Time.get_ticks_usec()
	_fill_async_slots()


func _fill_async_slots() -> void:
	while _async_submitted < REPS and _async_submitted - _async_done < 3:
		var request_id := _async_submitted
		var error := _engine.evaluate_batch_async(
			_boards, _on_async_batch.bind(request_id))
		if error != OK:
			push_error("mobile async submit failed: %d" % error)
			get_tree().quit(1)
			return
		_async_submitted += 1


func _on_async_batch(result: PackedInt32Array, request_id: int) -> void:
	_callback_order.append(request_id)
	_async_bad += _count_bad(result)
	_async_done += 1
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
	if _async_bad == 0 and ordered:
		print("MOBILE_TEST_PASS")
		get_tree().quit(0)
	else:
		push_error("mobile asynchronous acceptance failed")
		get_tree().quit(1)


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
