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
var _optimism := PackedInt32Array([0, 0])


func _init(loader, features) -> void:
	_loader = loader
	_features = features


func begin(position) -> void:
	_board = NnueBoard.new()
	_board.load_from_position(position)
	_accumulator = NnueAccumulator.new(_loader, _features)
	_accumulator.refresh(_board)
	_undo_frames.clear()
	_optimism.fill(0)


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


func set_optimism(white: int, black: int) -> void:
	_optimism[0] = white
	_optimism[1] = black


func evaluate(position) -> int:
	if _board == null or _accumulator == null:
		return 0
	var terms: Dictionary = _accumulator.evaluate_terms(_board)
	var psqt: int = int(terms["psqt"])
	var positional: int = int(terms["positional"])
	return finalize_terms(position, psqt, positional, _optimism[position.side_to_move])


## Kept separately so upstream evaluate.cpp arithmetic is directly testable
## without creating a neural network or mutating an accumulator.
static func finalize_terms(position, psqt: int, positional: int, optimism: int) -> int:
	var nnue: int = psqt + positional
	var complexity: int = absi(psqt - positional)
	# Upstream evaluate.cpp. GDScript integer division truncates toward zero,
	# matching C++ signed integral division for these terms.
	optimism += optimism * complexity / 465
	nnue -= nnue * complexity / 11743
	var material: int = position.major_material()
	var value: int = (nnue * (17380 + material) + optimism * (3061 + material)) / 20582
	value -= value * position.rule60_count() / 253
	return clampi(value, T.VALUE_MATED_IN_MAX_PLY + 1, T.VALUE_MATE_IN_MAX_PLY - 1)


func dispose() -> void:
	_undo_frames.clear()
	_board = null
	_accumulator = null
