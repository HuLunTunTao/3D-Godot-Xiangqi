class_name PikafishBitboard
extends RefCounted

## Upstream: Pikafish 2c5c998c, src/bitboard.h — Bitboard = u128, square bit = 1 << sq.
## GDS-DIVERGENCE: SEMANTIC (D004) — GDScript ints are signed 64-bit; store u128 as (lo, hi).
## Bit 63 lives in the sign bit of `lo`; bitwise ops remain correct. Cross-tested at sq 63/64.

const T = preload("res://addons/pikafish/core/types.gd")

## Representation id chosen after Phase B microbench (see docs/divergences.md D004).
const REP_DUAL64 := 0
const REP_OCC90 := 1
const ACTIVE_REP := REP_DUAL64

## Precomputed square masks: SquareBB[s] = {lo, hi}
static var _square_lo: PackedInt64Array = PackedInt64Array()
static var _square_hi: PackedInt64Array = PackedInt64Array()
static var _tables_ready := false

## File / rank / palace constants as (lo, hi) pairs — Upstream: bitboard.h
static var FILE_A_LO: int = 0
static var FILE_A_HI: int = 0
static var FILE_I_LO: int = 0
static var FILE_I_HI: int = 0
static var RANK_0_LO: int = 0x1FF
static var RANK_0_HI: int = 0
static var RANK_9_LO: int = 0
static var RANK_9_HI: int = 0
static var PALACE_LO: int = 0
static var PALACE_HI: int = 0
static var HALF_LO: PackedInt64Array = PackedInt64Array()
static var HALF_HI: PackedInt64Array = PackedInt64Array()


static func ensure_tables() -> void:
	if _tables_ready:
		return
	_tables_ready = true
	_square_lo.resize(T.SQUARE_NB)
	_square_hi.resize(T.SQUARE_NB)
	for s in range(T.SQUARE_NB):
		var p := _mask_from_sq(s)
		_square_lo[s] = p[0]
		_square_hi[s] = p[1]

	# FileABB = repeating every 9 bits across 90 squares
	FILE_A_LO = 0
	FILE_A_HI = 0
	for r in range(T.RANK_NB):
		var s := T.make_square(T.FILE_A, r)
		FILE_A_LO |= _square_lo[s]
		FILE_A_HI |= _square_hi[s]
	var fi := shift_east_pair(FILE_A_LO, FILE_A_HI, 8)
	FILE_I_LO = fi[0]
	FILE_I_HI = fi[1]

	RANK_0_LO = 0x1FF
	RANK_0_HI = 0
	var r9 := shift_north_pair(RANK_0_LO, RANK_0_HI, 9)
	RANK_9_LO = r9[0]
	RANK_9_HI = r9[1]

	# Palace = 0x70381C << 64 | 0xE07038  (Upstream constexpr)
	PALACE_LO = 0xE07038
	PALACE_HI = 0x70381C

	HALF_LO = PackedInt64Array([0, 0])
	HALF_HI = PackedInt64Array([0, 0])
	# HalfBB[WHITE] = ranks 0..4, HalfBB[BLACK] = ranks 5..9
	for r in range(5):
		var rl := _rank_lo(r)
		var rh := _rank_hi(r)
		HALF_LO[T.COLOR_WHITE] |= rl
		HALF_HI[T.COLOR_WHITE] |= rh
	for r in range(5, 10):
		var rl2 := _rank_lo(r)
		var rh2 := _rank_hi(r)
		HALF_LO[T.COLOR_BLACK] |= rl2
		HALF_HI[T.COLOR_BLACK] |= rh2


static func _mask_from_sq(s: int) -> Array:
	## Returns [lo, hi] for bit s. GDS signed: bit 63 is negative lo.
	if s < 64:
		return [1 << s, 0]
	return [0, 1 << (s - 64)]


static func _rank_lo(r: int) -> int:
	var lo := 0
	for f in range(T.FILE_NB):
		lo |= _mask_from_sq(T.make_square(f, r))[0]
	return lo


static func _rank_hi(r: int) -> int:
	var hi := 0
	for f in range(T.FILE_NB):
		hi |= _mask_from_sq(T.make_square(f, r))[1]
	return hi


static func square_bb_lo(s: int) -> int:
	ensure_tables()
	return _square_lo[s]


static func square_bb_hi(s: int) -> int:
	ensure_tables()
	return _square_hi[s]


static func empty_pair() -> Array:
	return [0, 0]


static func from_square(s: int) -> Array:
	ensure_tables()
	return [_square_lo[s], _square_hi[s]]


static func set_bit(lo: int, hi: int, s: int) -> Array:
	ensure_tables()
	return [lo | _square_lo[s], hi | _square_hi[s]]


static func clear_bit(lo: int, hi: int, s: int) -> Array:
	ensure_tables()
	return [lo & ~_square_lo[s], hi & ~_square_hi[s]]


static func test_bit(lo: int, hi: int, s: int) -> bool:
	ensure_tables()
	if s < 64:
		return (lo & _square_lo[s]) != 0
	return (hi & _square_hi[s]) != 0


static func more_than_one(lo: int, hi: int) -> bool:
	## Upstream: bool(b & (b - 1)) on u128.
	return popcount(lo, hi) > 1


static func popcount(lo: int, hi: int) -> int:
	return _popcount64(lo) + _popcount64(hi)


static func _popcount64(x: int) -> int:
	# Brian Kernighan; works with signed bit patterns.
	var n := 0
	var v := x
	while v != 0:
		v &= v - 1
		n += 1
	return n


static func lsb(lo: int, hi: int) -> int:
	## Index of least-set bit, or -1 if empty.
	if lo != 0:
		for b in range(64):
			if (lo & (1 << b)) != 0:
				return b
	if hi != 0:
		for b in range(64):
			if (hi & (1 << b)) != 0:
				return 64 + b
	return -1


static func _lsb64(_x: int) -> int:
	return -1  # unused; kept for API stability


static func to_occ90(lo: int, hi: int) -> PackedByteArray:
	ensure_tables()
	var occ := PackedByteArray()
	occ.resize(T.SQUARE_NB)
	for s in range(T.SQUARE_NB):
		occ[s] = 1 if test_bit(lo, hi, s) else 0
	return occ


static func from_occ90(occ: PackedByteArray) -> Array:
	ensure_tables()
	var lo := 0
	var hi := 0
	for s in range(mini(occ.size(), T.SQUARE_NB)):
		if occ[s] != 0:
			lo |= _square_lo[s]
			hi |= _square_hi[s]
	return [lo, hi]


static func squares_list(lo: int, hi: int) -> PackedInt32Array:
	## Allocating helper for tests — hot path should use bit ops / pop into buffer.
	var out := PackedInt32Array()
	var s := lsb(lo, hi)
	var cur_lo := lo
	var cur_hi := hi
	while s >= 0:
		out.append(s)
		var cleared := clear_bit(cur_lo, cur_hi, s)
		cur_lo = cleared[0]
		cur_hi = cleared[1]
		s = lsb(cur_lo, cur_hi)
	return out


static func shift_north_pair(lo: int, hi: int, steps: int = 1) -> Array:
	## Shift toward higher ranks by `steps` ranks (9 squares each). Caller masks edges.
	return _shift_left(lo, hi, T.NORTH * steps)


static func shift_east_pair(lo: int, hi: int, steps: int = 1) -> Array:
	return _shift_left(lo, hi, steps)


static func _shift_left(lo: int, hi: int, n: int) -> Array:
	## Logical left shift of u128 by n (0..127).
	if n <= 0:
		return [lo, hi]
	if n >= 128:
		return [0, 0]
	if n >= 64:
		return [0, _logical_shl64(lo, n - 64)]
	var new_hi := _logical_shl64(hi, n) | _logical_shr64(lo, 64 - n)
	var new_lo := _logical_shl64(lo, n)
	return [new_lo, new_hi]


static func _logical_shl64(x: int, n: int) -> int:
	if n <= 0:
		return x
	if n >= 64:
		return 0
	# GDScript << is fine for n < 63; for shifting into bit 63 use multiply carefully.
	return x << n


static func _logical_shr64(x: int, n: int) -> int:
	if n <= 0:
		return x
	if n >= 64:
		return 0
	# Arithmetic >> would sign-extend; mask to logical.
	if x >= 0:
		return x >> n
	# Unsigned semantics for negative
	var ux := x & 0x7FFFFFFFFFFFFFFF
	var top := 1 if (x < 0) else 0  # bit 63
	var out := ux >> n
	if top and n < 64:
		out |= (1 << (63 - n))
	return out


static func rank_bb(r: int) -> Array:
	ensure_tables()
	return [_rank_lo(r), _rank_hi(r)]


static func file_bb(f: int) -> Array:
	ensure_tables()
	var lo := 0
	var hi := 0
	for r in range(T.RANK_NB):
		var s := T.make_square(f, r)
		lo |= _square_lo[s]
		hi |= _square_hi[s]
	return [lo, hi]


static func palace_bb() -> Array:
	ensure_tables()
	return [PALACE_LO, PALACE_HI]


static func half_bb(color: int) -> Array:
	ensure_tables()
	return [HALF_LO[color], HALF_HI[color]]


static func and_bb(a_lo: int, a_hi: int, b_lo: int, b_hi: int) -> Array:
	return [a_lo & b_lo, a_hi & b_hi]


static func or_bb(a_lo: int, a_hi: int, b_lo: int, b_hi: int) -> Array:
	return [a_lo | b_lo, a_hi | b_hi]


static func xor_bb(a_lo: int, a_hi: int, b_lo: int, b_hi: int) -> Array:
	return [a_lo ^ b_lo, a_hi ^ b_hi]


static func not_bb(lo: int, hi: int) -> Array:
	## Only lower 90 bits are meaningful; clear bits 90+.
	ensure_tables()
	var nlo := ~lo
	var nhi := ~hi
	# Mask to 90 bits
	var mask90 := from_squares_all()
	return [nlo & mask90[0], nhi & mask90[1]]


static func from_squares_all() -> Array:
	ensure_tables()
	var lo := 0
	var hi := 0
	for s in range(T.SQUARE_NB):
		lo |= _square_lo[s]
		hi |= _square_hi[s]
	return [lo, hi]


static func equals(a_lo: int, a_hi: int, b_lo: int, b_hi: int) -> bool:
	return a_lo == b_lo and a_hi == b_hi
