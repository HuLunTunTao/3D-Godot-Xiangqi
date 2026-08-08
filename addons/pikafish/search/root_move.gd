class_name PikafishRootMove
extends RefCounted

## Compact GDScript counterpart of Stockfish::Search::RootMove. Only one PV is
## exposed today, but retaining the full root state keeps aspiration and time
## management independent from search-worker locals.

const T = preload("res://addons/pikafish/core/types.gd")

var effort: int = 0
var score: int = -T.VALUE_INFINITE
var previous_score: int = -T.VALUE_INFINITE
var average_score: int = -T.VALUE_INFINITE
var mean_squared_score: int = -T.VALUE_INFINITE * T.VALUE_INFINITE
var score_lowerbound := false
var score_upperbound := false
var previous_score_exact := false
var seldepth := 0
var pv: PackedInt32Array
var previous_pv: PackedInt32Array


func _init(move: int) -> void:
	pv = PackedInt32Array([move])
	previous_pv = PackedInt32Array([move])


func move() -> int:
	return pv[0] if not pv.is_empty() else T.MOVE_NONE


func begin_iteration(exact: bool = true) -> void:
	previous_score = score
	previous_pv = pv.duplicate()
	previous_score_exact = exact
	score_lowerbound = false
	score_upperbound = false


func set_score(value: int, alpha: int, beta: int, child_pv: PackedInt32Array, depth: int) -> void:
	var n: int = maxi(1, effort)
	var weight: int = clampi((32 * n * 2) / (n * 2 + 3 * maxi(1, effort)), 12, 24)
	var square_weight: int = mini(weight, 16)
	var v2: int = value * absi(value)
	if average_score == -T.VALUE_INFINITE:
		average_score = value
	else:
		average_score = (value * weight + average_score * (32 - weight)) / 32
	if mean_squared_score == -T.VALUE_INFINITE * T.VALUE_INFINITE:
		mean_squared_score = v2
	else:
		mean_squared_score = (v2 * square_weight + mean_squared_score * (32 - square_weight)) / 32
	score = value
	seldepth = depth
	score_lowerbound = value >= beta
	score_upperbound = value <= alpha
	pv = PackedInt32Array([move()])
	for child_move in child_pv:
		pv.append(child_move)
