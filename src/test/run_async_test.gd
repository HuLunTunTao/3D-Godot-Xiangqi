extends Node

## GPU/CPU async batch smoke and three-slot saturation test.
## For headless CLI, use:
##   Godot --path . -s res://src/test/run_async_test_cli.gd
## (loads async_test.tscn). Do not pass this Node script to `Godot -s` directly.

const NNUELoader = preload("res://src/nnue/nnue_loader.gd")
const XFeatures = preload("res://src/nnue/features.gd")
const XNnueEngine = preload("res://src/nnue/nnue_engine.gd")
const XBoard = preload("res://src/nnue/board.gd")

var _expected: PackedInt32Array
var _engine: XNnueEngine
var _completed := 0
var _empty_completed := 0
var _failures := 0
var _deadline_ms := 0
var _callback_order: Array[int] = []


func _ready() -> void:
	var loader := NNUELoader.new()
	loader.load_all()
	_engine = XNnueEngine.new(loader, XFeatures.new(loader))
	var records: Array = _load_reference()
	var boards: Array = []
	_expected = PackedInt32Array()
	_expected.resize(records.size())
	for i in range(records.size()):
		var board := XBoard.new()
		board.load_fen(records[i]["fen"])
		boards.append(board)
		_expected[i] = int(records[i]["internal"])
	if _engine.evaluate_batch_async(boards, Callable()) != ERR_INVALID_PARAMETER:
		push_error("invalid callback must return ERR_INVALID_PARAMETER")
		_failures += 1
	var oversized := boards.duplicate()
	while oversized.size() <= 512:
		oversized.append(boards[oversized.size() % boards.size()])
	if _engine.evaluate_batch_async(oversized, _on_batch.bind(98)) != ERR_INVALID_PARAMETER:
		push_error("batch > 512 must return ERR_INVALID_PARAMETER")
		_failures += 1
	if _engine.evaluate_batch_async([], _on_empty) != OK:
		push_error("empty async batch must return OK")
		_failures += 1

	for request_id in range(3):
		var err := _engine.evaluate_batch_async(boards, _on_batch.bind(request_id))
		if err != OK:
			push_error("async submit %d failed: %d" % [request_id, err])
			_failures += 1
	var busy_err := _engine.evaluate_batch_async(boards, _on_batch.bind(99))
	if busy_err != ERR_BUSY:
		push_error("fourth async submit must return ERR_BUSY, got %d" % busy_err)
		_failures += 1
	var sync_result := _engine.evaluate_batch([boards[0]])
	if sync_result.size() != 1 or absi(sync_result[0] - _expected[0]) > 1:
		push_error("sync/async interleave mismatch")
		_failures += 1
	_deadline_ms = Time.get_ticks_msec() + 10000


func _process(_delta: float) -> void:
	if _completed >= 3:
		if _empty_completed != 1:
			push_error("empty callback count=%d" % _empty_completed)
			_failures += 1
		if _callback_order != [0, 1, 2]:
			push_error("callback order=%s" % str(_callback_order))
			_failures += 1
		print("async correctness: %d/3 callbacks, failures=%d" % [_completed, _failures])
		get_tree().quit(0 if _failures == 0 else 1)
		return
	if Time.get_ticks_msec() > _deadline_ms:
		push_error("async timeout: completed=%d" % _completed)
		get_tree().quit(1)


func _on_batch(result: PackedInt32Array, request_id: int) -> void:
	_callback_order.append(request_id)
	var bad := 0
	if result.size() != _expected.size():
		bad += 1
	else:
		for i in range(result.size()):
			if absi(result[i] - _expected[i]) > 1:
				bad += 1
	if bad > 0:
		push_error("async request %d mismatches=%d" % [request_id, bad])
		_failures += 1
	_completed += 1


func _on_empty(result: PackedInt32Array) -> void:
	if not result.is_empty():
		_failures += 1
	_empty_completed += 1


func _load_reference() -> Array:
	var f := FileAccess.open("res://data/reference.json", FileAccess.READ)
	var records: Array = JSON.parse_string(f.get_as_text())
	f.close()
	return records
