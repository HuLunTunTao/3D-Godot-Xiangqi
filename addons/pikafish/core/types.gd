class_name PikafishTypes
extends RefCounted

## Upstream: Pikafish 2c5c998c, src/types.h
## Full Value/Depth/Piece/Square/Move helpers for the search core.

const MAX_MOVES := 128
const MAX_PLY := 246

const VALUE_ZERO := 0
const VALUE_DRAW := 0
const VALUE_NONE := 32002
const VALUE_INFINITE := 32001
const VALUE_MATE := 32000
const VALUE_MATE_IN_MAX_PLY := VALUE_MATE - MAX_PLY
const VALUE_MATED_IN_MAX_PLY := -VALUE_MATE_IN_MAX_PLY

const ROOK_VALUE := 1305
const ADVISOR_VALUE := 219
const CANNON_VALUE := 773
const PAWN_VALUE := 144
const KNIGHT_VALUE := 720
const BISHOP_VALUE := 187

const MOVE_NONE := 0
const MOVE_NULL := 129

const COLOR_WHITE := 0
const COLOR_BLACK := 1
const COLOR_NB := 2

const BOUND_NONE := 0
const BOUND_UPPER := 1
const BOUND_LOWER := 2
const BOUND_EXACT := 3  # BOUND_UPPER | BOUND_LOWER

const NO_PIECE_TYPE := 0
const ALL_PIECES := 0  ## Upstream: ALL_PIECES = 0 (same slot as NO_PIECE_TYPE)
const ROOK := 1
const ADVISOR := 2
const CANNON := 3
const PAWN := 4
const KNIGHT := 5
const BISHOP := 6
const KING := 7
const KNIGHT_TO := 8
const PAWN_TO := 9
const PIECE_TYPE_NB := 8

## Upstream: PieceToChar = " RACPNBK racpnbk"
const PIECE_TO_CHAR := " RACPNBK racpnbk"

const NO_PIECE := 0
const W_ROOK := 1
const W_ADVISOR := 2
const W_CANNON := 3
const W_PAWN := 4
const W_KNIGHT := 5
const W_BISHOP := 6
const W_KING := 7
const B_ROOK := 9
const B_ADVISOR := 10
const B_CANNON := 11
const B_PAWN := 12
const B_KNIGHT := 13
const B_BISHOP := 14
const B_KING := 15
const PIECE_NB := 16

const SQUARE_NB := 90
const FILE_NB := 9
const RANK_NB := 10
const SQ_NONE := 90

const FILE_A := 0
const FILE_I := 8
const RANK_0 := 0
const RANK_4 := 4
const RANK_5 := 5
const RANK_9 := 9

const NORTH := 9
const EAST := 1
const SOUTH := -9
const WEST := -1
const NORTH_EAST := 10
const SOUTH_EAST := -8
const SOUTH_WEST := -10
const NORTH_WEST := 8

const DEPTH_QS := 0
const DEPTH_UNSEARCHED := -2
const DEPTH_NONE := -3

## PieceValue[PIECE_NB] — Upstream: types.h PieceValue
const PIECE_VALUE := [
	VALUE_ZERO, ROOK_VALUE, ADVISOR_VALUE, CANNON_VALUE, PAWN_VALUE, KNIGHT_VALUE, BISHOP_VALUE, VALUE_ZERO,
	VALUE_ZERO, ROOK_VALUE, ADVISOR_VALUE, CANNON_VALUE, PAWN_VALUE, KNIGHT_VALUE, BISHOP_VALUE, VALUE_ZERO,
]


static func is_valid_value(value: int) -> bool:
	return value != VALUE_NONE


static func is_win(value: int) -> bool:
	return value >= VALUE_MATE_IN_MAX_PLY


static func is_loss(value: int) -> bool:
	return value <= VALUE_MATED_IN_MAX_PLY


static func is_decisive(value: int) -> bool:
	return is_win(value) or is_loss(value)


static func mate_in(ply: int) -> int:
	return VALUE_MATE - ply


static func mated_in(ply: int) -> int:
	return -VALUE_MATE + ply


static func make_move(frm: int, to: int) -> int:
	## Upstream: Move(Square from, Square to) → (from << 7) + to
	return (frm << 7) + to


static func from_sq(move: int) -> int:
	return (move >> 7) & 0x7F


static func to_sq(move: int) -> int:
	return move & 0x7F


static func move_is_ok(move: int) -> bool:
	return move != MOVE_NONE and move != MOVE_NULL


static func move_raw(move: int) -> int:
	return move & 0xFFFF


static func make_square(f: int, r: int) -> int:
	return r * FILE_NB + f


static func file_of(s: int) -> int:
	return s % FILE_NB


static func rank_of(s: int) -> int:
	return int(s / FILE_NB)


static func is_ok_sq(s: int) -> bool:
	return s >= 0 and s < SQUARE_NB


static func flip_rank(s: int) -> int:
	return make_square(file_of(s), RANK_9 - rank_of(s))


static func flip_file(s: int) -> int:
	return make_square(FILE_I - file_of(s), rank_of(s))


static func flip_color(c: int) -> int:
	return c ^ COLOR_BLACK


static func make_piece(c: int, pt: int) -> int:
	return (c << 3) + pt


static func type_of(pc: int) -> int:
	return pc & 7


static func color_of(pc: int) -> int:
	return pc >> 3


static func flip_piece(pc: int) -> int:
	return pc ^ 8


static func dist_file(x: int, y: int) -> int:
	return absi(file_of(x) - file_of(y))


static func dist_rank(x: int, y: int) -> int:
	return absi(rank_of(x) - rank_of(y))


static func distance(x: int, y: int) -> int:
	## Upstream: king-step Chebyshev distance
	return maxi(dist_file(x, y), dist_rank(x, y))


static func square_to_uci(s: int) -> String:
	var files := "abcdefghi"
	return "%s%d" % [files[file_of(s)], rank_of(s)]


static func move_to_uci(move: int) -> String:
	return square_to_uci(from_sq(move)) + square_to_uci(to_sq(move))


static func uci_to_square(token: String) -> int:
	var files := "abcdefghi"
	var f := files.find(token[0])
	var r := int(token.substr(1, 1))
	return make_square(f, r)


static func uci_to_move(uci: String) -> int:
	return make_move(uci_to_square(uci.substr(0, 2)), uci_to_square(uci.substr(2, 2)))


static func char_to_piece(ch: String) -> int:
	## Upstream: PieceToChar.find(token) — copied here so addon core does not preload host NNUE.
	var idx := PIECE_TO_CHAR.find(ch)
	if idx < 0:
		return NO_PIECE
	return idx


static func piece_to_char(pc: int) -> String:
	if pc <= 0 or pc >= PIECE_TO_CHAR.length():
		return "?"
	return PIECE_TO_CHAR[pc]
