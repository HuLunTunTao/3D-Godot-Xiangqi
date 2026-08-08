class_name PikafishNnueSearchEvaluator
extends "res://addons/pikafish/search/evaluator.gd"

## CPU incremental NNUE evaluator. The search tree only sees the strategy;
## paired Board/Accumulator state remains private to this implementation.

const T = preload("res://addons/pikafish/core/types.gd")
const NnueBoard = preload("res://addons/pikafish/nnue/board.gd")
const NnueAccumulator = preload("res://addons/pikafish/nnue/accumulator.gd")

var _loader
var _features
var _board = null
var _accumulator = null
var _undo_frames: Array = []


func _init(loader, features) -> void:
	_loader = loader
	_features = features


func begin(position) -> void:
	_board = NnueBoard.new()
	_board.load_from_position(position)
	_accumulator = NnueAccumulator.new(_loader, _features)
	_accumulator.refresh(_board)
	_undo_frames.clear()


func do_move(move: int) -> void:
	if _board == null or _accumulator == null:
		return
	var board_undo: Dictionary = _board.do_move(T.from_sq(move), T.to_sq(move))
	var accumulator_undo = _accumulator.update_after_move(_board)
	_undo_frames.append({"board": board_undo, "accumulator": accumulator_undo, "null": false})


func undo_move() -> void:
	if _undo_frames.is_empty() or _board == null or _accumulator == null:
		return
	var frame: Dictionary = _undo_frames.pop_back()
	if bool(frame.get("null", false)):
		_board.stm ^= 1
		_accumulator.refresh(_board)
		return
	_board.undo_move(frame["board"])
	_accumulator.undo_update(frame["accumulator"])


func do_null_move() -> void:
	if _board == null or _accumulator == null:
		return
	_board.stm ^= 1
	_accumulator.refresh(_board)
	_undo_frames.append({"null": true})


func undo_null_move() -> void:
	undo_move()


func evaluate(_position) -> int:
	if _board == null or _accumulator == null:
		return 0
	return int(_accumulator.evaluate(_board))


func dispose() -> void:
	_undo_frames.clear()
	_board = null
	_accumulator = null
