## DEPRECATED — use `PikafishEngine` (`res://addons/pikafish/pikafish.gd`) instead.
## This file is a one-version compatibility wrapper that forwards to PikafishEngine.
## New game/product code must not depend on XNnueEngine; migrate via
## addons/pikafish/README.md ("Migration from XNnueEngine").
##
## GDS-DIVERGENCE: PLATFORM (D001 — migrated)
## Phase E: NNUE implementation lives under `addons/pikafish/nnue/` (+ shaders).
## This wrapper remains one version for existing tests/benches.
class_name XNnueEngine

const NNUELoader = preload("res://addons/pikafish/nnue/loader.gd")
const XFeatures = preload("res://addons/pikafish/nnue/features.gd")
const XBoard = preload("res://addons/pikafish/nnue/board.gd")
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
	assert(err == OK, "XNnueEngine: failed to adopt NNUE: %s" % _engine.backend_info())
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


## Optional non-blocking batch API. Positions are read-only until callback runs.
## callback is invoked exactly once with a PackedInt32Array when OK is returned.
func evaluate_batch_async(positions: Array, callback: Callable) -> Error:
	return _engine.evaluate_batch_async(positions, callback)


## --- Incremental search API (CPU accumulator; works with or without GPU) ---

func refresh(pos) -> void:
	_engine.refresh(pos)


func evaluate_incremental(pos) -> int:
	return _engine.evaluate_incremental(pos)


func do_move(pos, frm: int, to: int) -> void:
	_engine.do_move(pos, frm, to)


func undo_move(pos) -> void:
	_engine.undo_move(pos)
