class_name XiangqiMoveNotation
extends RefCounted

## Pure Chinese-Xiangqi notation formatter.  It deliberately works from an
## immutable pre-move position so UI history never depends on a later board.
const Types = preload("res://addons/pikafish/core/types.gd")

const RED_NAMES := ["", "车", "仕", "炮", "兵", "马", "相", "帅"]
const BLACK_NAMES := ["", "車", "士", "砲", "卒", "馬", "象", "將"]
const NUMERALS := ["一", "二", "三", "四", "五", "六", "七", "八", "九"]


static func format(position, move: int) -> String:
	var from := Types.from_sq(move)
	var to := Types.to_sq(move)
	var piece: int = position.piece_at(from)
	if piece == Types.NO_PIECE:
		return Types.move_to_uci(move)
	var color := Types.color_of(piece)
	var piece_type := Types.type_of(piece)
	var origin := _origin_name(position, from, piece, color, piece_type)
	var same_file := Types.file_of(from) == Types.file_of(to)
	if not same_file and piece_type in [Types.ROOK, Types.CANNON, Types.KING, Types.PAWN]:
		return "%s平%s" % [origin, _file_name(Types.file_of(to), color)]
	var advances := Types.rank_of(to) > Types.rank_of(from) if color == Types.COLOR_WHITE else Types.rank_of(to) < Types.rank_of(from)
	var action := "进" if advances else "退"
	var target: String
	if piece_type in [Types.KNIGHT, Types.BISHOP, Types.ADVISOR]:
		target = _file_name(Types.file_of(to), color)
	else:
		target = _number(abs(Types.rank_of(to) - Types.rank_of(from)))
	return "%s%s%s" % [origin, action, target]


static func _origin_name(position, from: int, piece: int, color: int, piece_type: int) -> String:
	var matches: Array[int] = []
	for square in range(Types.SQUARE_NB):
		if position.piece_at(square) == piece and Types.file_of(square) == Types.file_of(from):
			matches.append(square)
	if matches.size() > 1:
		matches.sort_custom(func(a, b): return Types.rank_of(a) > Types.rank_of(b) if color == Types.COLOR_WHITE else Types.rank_of(a) < Types.rank_of(b))
		var index := matches.find(from)
		var qualifier := "前" if index == 0 else ("后" if index == matches.size() - 1 else _number(index + 1))
		return "%s%s" % [qualifier, _piece_name(piece_type, color)]
	return "%s%s" % [_piece_name(piece_type, color), _file_name(Types.file_of(from), color)]


static func _piece_name(piece_type: int, color: int) -> String:
	return RED_NAMES[piece_type] if color == Types.COLOR_WHITE else BLACK_NAMES[piece_type]


static func _file_name(file: int, color: int) -> String:
	# Both sides count from their own right; engine files increase from the red
	# player's left to right.
	var index := 8 - file if color == Types.COLOR_WHITE else file
	return _number(index + 1)


static func _number(value: int) -> String:
	return NUMERALS[clampi(value, 1, 9) - 1]
