class_name PikafishStateStack
extends RefCounted

## Upstream: Pikafish 2c5c998c, StateInfo stack — MAX_PLY SoA.

const T = preload("res://addons/pikafish/core/types.gd")

var ply: int = 0

var key: PackedInt64Array = PackedInt64Array()
var pawn_key: PackedInt64Array = PackedInt64Array()
var minor_piece_key: PackedInt64Array = PackedInt64Array()
var non_pawn_key_w: PackedInt64Array = PackedInt64Array()
var non_pawn_key_b: PackedInt64Array = PackedInt64Array()
var major_material_w: PackedInt32Array = PackedInt32Array()
var major_material_b: PackedInt32Array = PackedInt32Array()
var check10_w: PackedInt32Array = PackedInt32Array()
var check10_b: PackedInt32Array = PackedInt32Array()
var rule60: PackedInt32Array = PackedInt32Array()
var plies_from_null: PackedInt32Array = PackedInt32Array()
var checkers_lo: PackedInt64Array = PackedInt64Array()
var checkers_hi: PackedInt64Array = PackedInt64Array()
var blockers_w_lo: PackedInt64Array = PackedInt64Array()
var blockers_w_hi: PackedInt64Array = PackedInt64Array()
var blockers_b_lo: PackedInt64Array = PackedInt64Array()
var blockers_b_hi: PackedInt64Array = PackedInt64Array()
var pinners_w_lo: PackedInt64Array = PackedInt64Array()
var pinners_w_hi: PackedInt64Array = PackedInt64Array()
var pinners_b_lo: PackedInt64Array = PackedInt64Array()
var pinners_b_hi: PackedInt64Array = PackedInt64Array()
## check_squares[pt][ply] as parallel arrays — pt 0..7
var check_sq_lo: Array = []  # [PIECE_TYPE_NB] PackedInt64Array
var check_sq_hi: Array = []
var need_full_check: PackedByteArray = PackedByteArray()
var captured_piece: PackedByteArray = PackedByteArray()
var move: PackedInt32Array = PackedInt32Array()


func _init() -> void:
	reset()


func reset() -> void:
	ply = 0
	var n := T.MAX_PLY
	key.resize(n)
	pawn_key.resize(n)
	minor_piece_key.resize(n)
	non_pawn_key_w.resize(n)
	non_pawn_key_b.resize(n)
	major_material_w.resize(n)
	major_material_b.resize(n)
	check10_w.resize(n)
	check10_b.resize(n)
	rule60.resize(n)
	plies_from_null.resize(n)
	checkers_lo.resize(n)
	checkers_hi.resize(n)
	blockers_w_lo.resize(n)
	blockers_w_hi.resize(n)
	blockers_b_lo.resize(n)
	blockers_b_hi.resize(n)
	pinners_w_lo.resize(n)
	pinners_w_hi.resize(n)
	pinners_b_lo.resize(n)
	pinners_b_hi.resize(n)
	need_full_check.resize(n)
	captured_piece.resize(n)
	move.resize(n)
	check_sq_lo = []
	check_sq_hi = []
	for _pt in range(T.PIECE_TYPE_NB):
		var lo := PackedInt64Array()
		var hi := PackedInt64Array()
		lo.resize(n)
		hi.resize(n)
		check_sq_lo.append(lo)
		check_sq_hi.append(hi)
	clear_slot(0)


func clear_slot(i: int) -> void:
	key[i] = 0
	pawn_key[i] = 0
	minor_piece_key[i] = 0
	non_pawn_key_w[i] = 0
	non_pawn_key_b[i] = 0
	major_material_w[i] = 0
	major_material_b[i] = 0
	check10_w[i] = 0
	check10_b[i] = 0
	rule60[i] = 0
	plies_from_null[i] = 0
	checkers_lo[i] = 0
	checkers_hi[i] = 0
	blockers_w_lo[i] = 0
	blockers_w_hi[i] = 0
	blockers_b_lo[i] = 0
	blockers_b_hi[i] = 0
	pinners_w_lo[i] = 0
	pinners_w_hi[i] = 0
	pinners_b_lo[i] = 0
	pinners_b_hi[i] = 0
	need_full_check[i] = 0
	captured_piece[i] = 0
	move[i] = T.MOVE_NONE
	for pt in range(T.PIECE_TYPE_NB):
		check_sq_lo[pt][i] = 0
		check_sq_hi[pt][i] = 0


func copy_copied_fields(from_i: int, to_i: int) -> void:
	## Fields copied when making a move (Upstream StateInfo comment).
	pawn_key[to_i] = pawn_key[from_i]
	minor_piece_key[to_i] = minor_piece_key[from_i]
	non_pawn_key_w[to_i] = non_pawn_key_w[from_i]
	non_pawn_key_b[to_i] = non_pawn_key_b[from_i]
	major_material_w[to_i] = major_material_w[from_i]
	major_material_b[to_i] = major_material_b[from_i]
	check10_w[to_i] = check10_w[from_i]
	check10_b[to_i] = check10_b[from_i]
	rule60[to_i] = rule60[from_i]
	plies_from_null[to_i] = plies_from_null[from_i]
