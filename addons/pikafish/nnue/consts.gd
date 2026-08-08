## Shared constants and helpers for the pikafish NNUE port.
## Square = rank * 9 + file (0..89). Piece = (color << 3) + type.

class_name PikafishNnueConsts
extends RefCounted
# Colors
const WHITE = 0
const BLACK = 1

# Piece types
const NO_PIECE_TYPE = 0
const ROOK = 1
const ADVISOR = 2
const CANNON = 3
const PAWN = 4
const KNIGHT = 5
const BISHOP = 6
const KING = 7
const PIECE_TYPE_NB = 8

# Pieces (white 1..7, black 9..15, NO_PIECE 0)
const W_ROOK = 1
const W_ADVISOR = 2
const W_CANNON = 3
const W_PAWN = 4
const W_KNIGHT = 5
const W_BISHOP = 6
const W_KING = 7
const B_ROOK = 9
const B_ADVISOR = 10
const B_CANNON = 11
const B_PAWN = 12
const B_KNIGHT = 13
const B_BISHOP = 14
const B_KING = 15
const NO_PIECE = 0
const PIECE_NB = 16

const SQUARE_NB = 90
const FILE_NB = 9
const RANK_NB = 10

# Directions (square deltas)
const NORTH = 9
const SOUTH = -9
const EAST = 1
const WEST = -1
const NORTH_EAST = 10
const NORTH_WEST = 8
const SOUTH_EAST = -8
const SOUTH_WEST = -10

# Architecture
const L1 = 1024
const FC0 = 32
const FC1 = 32
const PSQTBUCKETS = 16
const LAYERSTACKS = 16
const PSQ_DIM = 16536
const THREAT_DIM = 45547
const INPUT_DIM = PSQ_DIM + THREAT_DIM  # 62083
const OUTPUT_SCALE = 16
const WEIGHT_SCALE_BITS = 6
const FT_MAX_VAL = 255
const HIDDEN_ONE_VAL = 128

const ALL_PIECES = [W_ROOK, W_ADVISOR, W_CANNON, W_PAWN, W_KNIGHT, W_BISHOP, W_KING,
					B_ROOK, B_ADVISOR, B_CANNON, B_PAWN, B_KNIGHT, B_BISHOP, B_KING]

# Palace squares (both palaces) as a 90-bool array
const PALACE_SQUARES: Array = []


static func _init_static() -> void:
	# godot doesn't run const array init with loops; build lazily
	pass


static func make_square(f: int, r: int) -> int:
	return r * FILE_NB + f


static func file_of(s: int) -> int:
	return s % FILE_NB


static func rank_of(s: int) -> int:
	return int(s / FILE_NB)


static func is_ok(s: int) -> bool:
	return s >= 0 and s < SQUARE_NB


static func dist_file(x: int, y: int) -> int:
	return abs(file_of(x) - file_of(y))


static func dist_rank(x: int, y: int) -> int:
	return abs(rank_of(x) - rank_of(y))


static func dist_sq(x: int, y: int) -> int:
	return max(dist_file(x, y), dist_rank(x, y))


static func make_piece(c: int, pt: int) -> int:
	return (c << 3) + pt


static func type_of(pc: int) -> int:
	return pc & 7


static func color_of(pc: int) -> int:
	return pc >> 3


static func flip_color(c: int) -> int:  # operator~ for Color (c^1)
	return c ^ 1


static func flip_piece(pc: int) -> int:  # operator~ for Piece (pc^8)
	return pc ^ 8


static func flip_file(s: int) -> int:
	return make_square(8 - file_of(s), rank_of(s))


static func flip_rank(s: int) -> int:
	return make_square(file_of(s), 9 - rank_of(s))


static func palace_squares() -> PackedByteArray:
	# Build once; returns a 90-byte mask (1 if square is in either palace)
	var b := PackedByteArray()
	b.resize(SQUARE_NB)
	for r in [0, 1, 2, 7, 8, 9]:
		for f in [3, 4, 5]:
			b[make_square(f, r)] = 1
	return b


static func char_to_piece(ch: String) -> int:
	# " RACPNBK racpnbk"
	var pt := NO_PIECE_TYPE
	match ch.to_upper():
		"R": pt = ROOK
		"A": pt = ADVISOR
		"C": pt = CANNON
		"P": pt = PAWN
		"N": pt = KNIGHT
		"B": pt = BISHOP
		"K": pt = KING
		_: return NO_PIECE
	var c := WHITE if ch == ch.to_upper() else BLACK
	return make_piece(c, pt)
