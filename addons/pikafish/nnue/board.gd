## Xiangqi board with FEN load + make/unmake for incremental NNUE.
## Square 0 = A0 (white back). Maintains piece_list / kings / counts / occ.
class_name PikafishNnueBoard
extends RefCounted
const NNUEConsts = preload("res://addons/pikafish/nnue/consts.gd")

var sq: PackedByteArray
var stm: int = NNUEConsts.WHITE

var piece_list: PackedInt32Array
var piece_list_index: PackedInt32Array  # [90], -1 for empty; enables O(1) swap-pop
var kings: PackedInt32Array
var piece_counts: PackedInt32Array
var occ: PackedByteArray


func _init() -> void:
	sq = PackedByteArray()
	sq.resize(NNUEConsts.SQUARE_NB)
	occ = PackedByteArray()
	occ.resize(NNUEConsts.SQUARE_NB)
	piece_list = PackedInt32Array()
	piece_list_index = PackedInt32Array()
	piece_list_index.resize(NNUEConsts.SQUARE_NB)
	piece_list_index.fill(-1)
	kings = PackedInt32Array([ -1, -1 ])
	piece_counts = PackedInt32Array()
	piece_counts.resize(NNUEConsts.PIECE_NB)


func load_fen(fen: String) -> void:
	_clear_board()
	var parts := fen.split(" ")
	var ranks := parts[0].split("/")
	for i in range(ranks.size()):
		var r := 9 - i
		var f := 0
		for ch in ranks[i]:
			if ch.is_valid_int():
				f += int(ch)
			else:
				var pc: int = NNUEConsts.char_to_piece(ch)
				var s := r * 9 + f
				_put_piece(s, pc)
				f += 1
	if parts.size() >= 2:
		stm = NNUEConsts.WHITE if parts[1] == "w" else NNUEConsts.BLACK


## Copy pieces from addon PikafishPosition (same piece encoding as NNUEConsts).
## Avoids FEN round-trip for search leaf eval (D006).
func load_from_position(pos) -> void:
	_clear_board()
	for s in range(NNUEConsts.SQUARE_NB):
		var pc: int = pos.board[s]
		if pc != 0:
			_put_piece(s, pc)
	stm = int(pos.side_to_move)


func _clear_board() -> void:
	sq.fill(0)
	occ.fill(0)
	piece_list.clear()
	piece_list_index.fill(-1)
	kings[0] = -1
	kings[1] = -1
	piece_counts.fill(0)


func piece_on(s: int) -> int:
	return sq[s]


func side_to_move() -> int:
	return stm


func king_square(c: int) -> int:
	return kings[c]


func count(pt: int, c: int) -> int:
	return piece_counts[NNUEConsts.make_piece(c, pt)]


func occupancy() -> PackedByteArray:
	return occ


func _put_piece(s: int, pc: int) -> void:
	sq[s] = pc
	occ[s] = 1
	piece_list.append(s)
	piece_list_index[s] = piece_list.size() - 1
	piece_counts[pc] += 1
	if pc == NNUEConsts.W_KING:
		kings[0] = s
	elif pc == NNUEConsts.B_KING:
		kings[1] = s


func _remove_piece_at(s: int) -> int:
	var pc: int = sq[s]
	if pc == 0:
		return 0
	sq[s] = 0
	occ[s] = 0
	piece_counts[pc] -= 1
	if pc == NNUEConsts.W_KING:
		kings[0] = -1
	elif pc == NNUEConsts.B_KING:
		kings[1] = -1
	# remove from piece_list (O(1) swap-pop)
	var i: int = piece_list_index[s]
	assert(i >= 0, "piece_list_index out of sync")
	var last := piece_list.size() - 1
	var last_sq: int = piece_list[last]
	piece_list[i] = last_sq
	piece_list_index[last_sq] = i
	piece_list.resize(last)
	piece_list_index[s] = -1
	return pc


## Apply a quiet or capture move. Does not validate legality.
## Returns undo dictionary: {frm, to, moved, captured, stm}.
func do_move(frm: int, to: int) -> Dictionary:
	var moved: int = sq[frm]
	assert(moved != 0, "do_move: empty from")
	var captured: int = _remove_piece_at(to) if occ[to] == 1 else 0
	_remove_piece_at(frm)
	_put_piece(to, moved)
	var prev_stm := stm
	stm ^= 1
	return {"frm": frm, "to": to, "moved": moved, "captured": captured, "stm": prev_stm}


func undo_move(u: Dictionary) -> void:
	var frm: int = u["frm"]
	var to: int = u["to"]
	var moved: int = u["moved"]
	var captured: int = u["captured"]
	_remove_piece_at(to)
	_put_piece(frm, moved)
	if captured != 0:
		_put_piece(to, captured)
	stm = u["stm"]
