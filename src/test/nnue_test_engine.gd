## Test-only adapter for NNUE regression runners.
## Production code must instantiate PikafishEngine directly.

const PikafishEngineScript = preload("res://addons/pikafish/pikafish.gd")

var loader
var features
var using_gpu: bool = false
var backend_name: String = "cpu"
var _engine


func _init(ld, ft) -> void:
	loader = ld
	features = ft
	_engine = PikafishEngineScript.new()
	var err: Error = _engine.adopt_host_nnue(ld, ft)
	assert(err == OK, "NnueTestEngine: failed to adopt NNUE: %s" % _engine.backend_info())
	using_gpu = _engine.using_gpu
	backend_name = _engine.backend_name


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _engine != null:
		_engine.shutdown()
		_engine = null


func evaluate(pos) -> int:
	return _engine.evaluate_board(pos)


func evaluate_batch(positions: Array) -> PackedInt32Array:
	return _engine.evaluate_boards(positions)


func evaluate_batch_async(positions: Array, callback: Callable) -> Error:
	return _engine.evaluate_batch_async(positions, callback)


func refresh(pos) -> void:
	_engine.refresh(pos)


func evaluate_incremental(pos) -> int:
	return _engine.evaluate_incremental(pos)


func do_move(pos, frm: int, to: int) -> void:
	_engine.do_move(pos, frm, to)


func undo_move(pos) -> void:
	_engine.undo_move(pos)
