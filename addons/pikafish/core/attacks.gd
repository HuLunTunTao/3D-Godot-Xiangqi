class_name PikafishAttacks
extends RefCounted

## Upstream: Pikafish 2c5c998c, src/attacks.h / attacks.cpp
## Direct formulas (sliding_attack / lame_leaper_*), bitboard-encoded results.
## Matches existing NNUE attack goldens; Between/Line/Ray from attacks.cpp init.

const T = preload("res://addons/pikafish/core/types.gd")
const BB = preload("res://addons/pikafish/core/bitboard.gd")

const ROOK_DIRS := [T.NORTH, T.SOUTH, T.EAST, T.WEST]
const BISHOP_DIRS := [2 * T.NORTH_EAST, 2 * T.SOUTH_EAST, 2 * T.SOUTH_WEST, 2 * T.NORTH_WEST]
const KNIGHT_DIRS := [
	2 * T.SOUTH + T.WEST, 2 * T.SOUTH + T.EAST, T.SOUTH + 2 * T.WEST, T.SOUTH + 2 * T.EAST,
	T.NORTH + 2 * T.WEST, T.NORTH + 2 * T.EAST, 2 * T.NORTH + T.WEST, 2 * T.NORTH + T.EAST,
]
const KING_STEPS := [T.NORTH, T.SOUTH, T.EAST, T.WEST]
const ADVISOR_STEPS := [T.NORTH_WEST, T.NORTH_EAST, T.SOUTH_WEST, T.SOUTH_EAST]

static var _ready := false
static var _pseudo: Array = []  # [pt][sq] -> [lo,hi]
static var _knight_pairs: Array = []  # [sq] PackedInt32Array [to,leg,...]
static var _bishop_pairs: Array = []
static var _line: Array = []
static var _between: Array = []
static var _ray_pass: Array = []
static var _leaper_pass: Array = []
static var _sq_buf: PackedInt32Array = PackedInt32Array()


static func init_tables() -> void:
	if _ready:
		return
	BB.ensure_tables()
	_sq_buf.resize(T.MAX_MOVES)

	_knight_pairs = []
	_bishop_pairs = []
	_knight_pairs.resize(T.SQUARE_NB)
	_bishop_pairs.resize(T.SQUARE_NB)
	for s in range(T.SQUARE_NB):
		_knight_pairs[s] = _build_leaper_pairs(T.KNIGHT, s)
		_bishop_pairs[s] = _build_leaper_pairs(T.BISHOP, s)

	# Mark ready before building pseudo so helpers can use pairs.
	_ready = true

	_pseudo = []
	_pseudo.resize(T.PIECE_TYPE_NB + 4)
	for pt in range(_pseudo.size()):
		var row: Array = []
		row.resize(T.SQUARE_NB)
		for s2 in range(T.SQUARE_NB):
			row[s2] = [0, 0]
		_pseudo[pt] = row

	for s1 in range(T.SQUARE_NB):
		_pseudo[T.NO_PIECE_TYPE][s1] = pawn_attacks_bb(T.COLOR_WHITE, s1)
		_pseudo[T.PAWN][s1] = pawn_attacks_bb(T.COLOR_BLACK, s1)
		_pseudo[T.ROOK][s1] = sliding_attack(T.ROOK, s1, 0, 0)
		_pseudo[T.BISHOP][s1] = lame_leaper_attack(T.BISHOP, s1, 0, 0)
		_pseudo[T.KNIGHT][s1] = lame_leaper_attack(T.KNIGHT, s1, 0, 0)
		_pseudo[T.KING][s1] = _pseudo_king(s1, true)
		_pseudo[T.KING + 3][s1] = _pseudo_king(s1, false)
		_pseudo[T.ADVISOR][s1] = _pseudo_advisor(s1, true)
		_pseudo[T.ADVISOR + 1][s1] = _pseudo_advisor(s1, false)

	var n := T.SQUARE_NB * T.SQUARE_NB
	_line = []
	_between = []
	_ray_pass = []
	_leaper_pass = []
	_line.resize(n)
	_between.resize(n)
	_ray_pass.resize(n)
	_leaper_pass.resize(n)
	for i in range(n):
		_line[i] = [0, 0]
		_between[i] = [0, 0]
		_ray_pass[i] = [0, 0]
		_leaper_pass[i] = [0, 0]

	for s1 in range(T.SQUARE_NB):
		for s2 in range(T.SQUARE_NB):
			var idx := s1 * T.SQUARE_NB + s2
			var rook_empty: Array = _pseudo[T.ROOK][s1]
			if BB.test_bit(rook_empty[0], rook_empty[1], s2):
				var a1: Array = _pseudo[T.ROOK][s1]
				var a2: Array = _pseudo[T.ROOK][s2]
				var line := BB.and_bb(a1[0], a1[1], a2[0], a2[1])
				line = BB.set_bit(line[0], line[1], s1)
				line = BB.set_bit(line[0], line[1], s2)
				_line[idx] = line

				var occ2 := BB.from_square(s2)
				var occ1 := BB.from_square(s1)
				var b1 := sliding_attack(T.ROOK, s1, occ2[0], occ2[1])
				var b2 := sliding_attack(T.ROOK, s2, occ1[0], occ1[1])
				_between[idx] = BB.and_bb(b1[0], b1[1], b2[0], b2[1])
				_ray_pass[idx] = sliding_attack(T.CANNON, s1, occ2[0], occ2[1])

			var kn_empty: Array = _pseudo[T.KNIGHT][s1]
			if BB.test_bit(kn_empty[0], kn_empty[1], s2):
				var path := _lame_leaper_path_bb(T.KNIGHT_TO, s2 - s1, s1)
				_between[idx] = BB.or_bb(_between[idx][0], _between[idx][1], path[0], path[1])

			_between[idx] = BB.set_bit(_between[idx][0], _between[idx][1], s2)

	for s1 in range(T.SQUARE_NB):
		for s2 in range(T.SQUARE_NB):
			var idx2 := s1 * T.SQUARE_NB + s2
			var uk: Array = _pseudo[T.KING + 3][s1]
			if BB.test_bit(uk[0], uk[1], s2):
				var kn: Array = _pseudo[T.KNIGHT][s1]
				var ua: Array = _pseudo[T.ADVISOR + 1][s2]
				var part := BB.and_bb(kn[0], kn[1], ua[0], ua[1])
				_leaper_pass[idx2] = BB.or_bb(
					_leaper_pass[idx2][0], _leaper_pass[idx2][1], part[0], part[1]
				)
			var ua1: Array = _pseudo[T.ADVISOR + 1][s1]
			if BB.test_bit(ua1[0], ua1[1], s2):
				var bi: Array = _pseudo[T.BISHOP][s1]
				var ua2: Array = _pseudo[T.ADVISOR + 1][s2]
				var part2 := BB.and_bb(bi[0], bi[1], ua2[0], ua2[1])
				_leaper_pass[idx2] = BB.or_bb(
					_leaper_pass[idx2][0], _leaper_pass[idx2][1], part2[0], part2[1]
				)


static func c_mod(a: int, b: int) -> int:
	return a - int(a / b) * b


static func _squares_to_bb(squares: Array) -> Array:
	var lo := 0
	var hi := 0
	for s in squares:
		var p := BB.set_bit(lo, hi, int(s))
		lo = p[0]
		hi = p[1]
	return [lo, hi]


static func pawn_attacks_bb(color: int, s: int) -> Array:
	## Upstream: pawn_attacks_bb<C>(Square)
	var out: Array = []
	var fwd := T.NORTH if color == T.COLOR_WHITE else T.SOUTH
	var to := s + fwd
	if T.is_ok_sq(to) and T.distance(s, to) == 1:
		out.append(to)
	if (color == T.COLOR_WHITE and T.rank_of(s) > T.RANK_4) or (
		color == T.COLOR_BLACK and T.rank_of(s) < T.RANK_5
	):
		for sd in [T.WEST, T.EAST]:
			to = s + sd
			if T.is_ok_sq(to) and T.distance(s, to) == 1:
				out.append(to)
	return _squares_to_bb(out)


static func pawn_attacks_to_bb(color: int, s: int) -> Array:
	## Upstream: pawn_attacks_to_bb<C> — inverse of pawn_attacks_bb
	var out: Array = []
	var back := T.SOUTH if color == T.COLOR_WHITE else T.NORTH
	var to := s + back
	if T.is_ok_sq(to) and T.distance(s, to) == 1:
		out.append(to)
	if (color == T.COLOR_WHITE and T.rank_of(s) > T.RANK_4) or (
		color == T.COLOR_BLACK and T.rank_of(s) < T.RANK_5
	):
		for sd in [T.WEST, T.EAST]:
			to = s + sd
			if T.is_ok_sq(to) and T.distance(s, to) == 1:
				out.append(to)
	return _squares_to_bb(out)


static func sliding_attack(pt: int, sq: int, occ_lo: int, occ_hi: int) -> Array:
	## Upstream: sliding_attack<ROOK|CANNON>
	BB.ensure_tables()
	var attack_lo := 0
	var attack_hi := 0
	for d in ROOK_DIRS:
		var hurdle := false
		var cur: int = sq + d
		while T.is_ok_sq(cur) and T.distance(cur - d, cur) == 1:
			if pt == T.ROOK or hurdle:
				attack_lo |= BB.square_bb_lo(cur)
				attack_hi |= BB.square_bb_hi(cur)
			if BB.test_bit(occ_lo, occ_hi, cur):
				if pt == T.CANNON and not hurdle:
					hurdle = true
				else:
					break
			cur += d
	return [attack_lo, attack_hi]


static func _lame_leaper_path_sq(pt: int, d: int, s: int) -> int:
	## Upstream: lame_leaper_path — returns eye square or -1
	var to := s + d
	if not T.is_ok_sq(to) or T.distance(s, to) > 3:
		return -1
	var from_sq := s
	var to_sq := to
	var dir := d
	if pt == T.KNIGHT_TO:
		var tmp := from_sq
		from_sq = to_sq
		to_sq = tmp
		dir = -d
	var dr := T.NORTH if dir > 0 else T.SOUTH
	var md := c_mod(dir, T.NORTH)
	var inner := md if absi(md) < int(T.NORTH / 2) else -md
	var df := T.WEST if inner < 0 else T.EAST
	var diff := T.dist_file(to_sq, from_sq) - T.dist_rank(to_sq, from_sq)
	var leg := from_sq
	if diff > 0:
		leg += df
	elif diff < 0:
		leg += dr
	else:
		leg += df + dr
	return leg if T.is_ok_sq(leg) else -1


static func _lame_leaper_path_bb(pt: int, d: int, s: int) -> Array:
	var leg := _lame_leaper_path_sq(pt, d, s)
	if leg < 0:
		return [0, 0]
	return BB.from_square(leg)


static func _build_leaper_pairs(pt: int, s: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	var dirs: Array = BISHOP_DIRS if pt == T.BISHOP else KNIGHT_DIRS
	for d in dirs:
		var to: int = s + int(d)
		if T.is_ok_sq(to) and T.distance(s, to) < 3:
			if pt == T.BISHOP:
				var half_black := T.rank_of(s) > T.RANK_4
				if (T.rank_of(to) > T.RANK_4) != half_black:
					continue
			var leg := _lame_leaper_path_sq(pt, int(d), s)
			out.append(to)
			out.append(leg)
	return out


static func lame_leaper_attack(pt: int, s: int, occ_lo: int, occ_hi: int) -> Array:
	## Upstream: lame_leaper_attack<KNIGHT|BISHOP|KNIGHT_TO>
	## Caller must ensure init_tables() / pairs are ready (or empty-board path uses dirs).
	BB.ensure_tables()
	var attack_lo := 0
	var attack_hi := 0
	if pt == T.KNIGHT_TO or not _ready:
		var dirs: Array = BISHOP_DIRS if pt == T.BISHOP else KNIGHT_DIRS
		var path_pt := pt
		for d in dirs:
			var to: int = s + int(d)
			if T.is_ok_sq(to) and T.distance(s, to) < 3:
				if pt == T.BISHOP:
					var half_black := T.rank_of(s) > T.RANK_4
					if (T.rank_of(to) > T.RANK_4) != half_black:
						continue
				var path := _lame_leaper_path_bb(path_pt, int(d), s)
				var blocked := false
				if path[0] != 0 or path[1] != 0:
					for eye in range(T.SQUARE_NB):
						if BB.test_bit(path[0], path[1], eye) and BB.test_bit(occ_lo, occ_hi, eye):
							blocked = true
							break
				if not blocked:
					attack_lo |= BB.square_bb_lo(to)
					attack_hi |= BB.square_bb_hi(to)
		return [attack_lo, attack_hi]

	var pairs: PackedInt32Array = _bishop_pairs[s] if pt == T.BISHOP else _knight_pairs[s]
	var i := 0
	while i < pairs.size():
		var to2: int = pairs[i]
		var leg: int = pairs[i + 1]
		if leg < 0 or not BB.test_bit(occ_lo, occ_hi, leg):
			attack_lo |= BB.square_bb_lo(to2)
			attack_hi |= BB.square_bb_hi(to2)
		i += 2
	return [attack_lo, attack_hi]


static func _pseudo_king(s: int, constrain_palace: bool) -> Array:
	var out: Array = []
	for step in KING_STEPS:
		var to: int = s + step
		if not T.is_ok_sq(to) or T.distance(s, to) > 2:
			continue
		if constrain_palace:
			if not BB.test_bit(BB.PALACE_LO, BB.PALACE_HI, s):
				continue
			if not BB.test_bit(BB.PALACE_LO, BB.PALACE_HI, to):
				continue
		out.append(to)
	return _squares_to_bb(out)


static func _pseudo_advisor(s: int, constrain_palace: bool) -> Array:
	var out: Array = []
	for step in ADVISOR_STEPS:
		var to: int = s + step
		if not T.is_ok_sq(to) or T.distance(s, to) > 2:
			continue
		if constrain_palace:
			if not BB.test_bit(BB.PALACE_LO, BB.PALACE_HI, s):
				continue
			if not BB.test_bit(BB.PALACE_LO, BB.PALACE_HI, to):
				continue
		out.append(to)
	return _squares_to_bb(out)


static func attacks_bb(pt: int, s: int, occ_lo: int = 0, occ_hi: int = 0) -> Array:
	init_tables()
	match pt:
		T.ROOK, T.CANNON:
			return sliding_attack(pt, s, occ_lo, occ_hi)
		T.BISHOP, T.KNIGHT, T.KNIGHT_TO:
			return lame_leaper_attack(pt, s, occ_lo, occ_hi)
		T.KING:
			return _pseudo[T.KING][s]
		T.ADVISOR:
			return _pseudo[T.ADVISOR][s]
		_:
			return _pseudo[pt][s]


static func attacks_bb_pawn(color: int, s: int) -> Array:
	init_tables()
	return _pseudo[T.NO_PIECE_TYPE if color == T.COLOR_WHITE else T.PAWN][s]


static func line_bb(s1: int, s2: int) -> Array:
	init_tables()
	return _line[s1 * T.SQUARE_NB + s2]


static func between_bb(s1: int, s2: int) -> Array:
	init_tables()
	return _between[s1 * T.SQUARE_NB + s2]


static func ray_pass_bb(s1: int, s2: int) -> Array:
	init_tables()
	return _ray_pass[s1 * T.SQUARE_NB + s2]


static func leaper_pass_bb(s1: int, s2: int) -> Array:
	init_tables()
	return _leaper_pass[s1 * T.SQUARE_NB + s2]


static func aligned(s1: int, s2: int, s3: int) -> bool:
	var line := line_bb(s1, s2)
	return BB.test_bit(line[0], line[1], s3)


static func collect_squares(lo: int, hi: int, out: PackedInt32Array) -> int:
	## Fills caller-owned buffer; no Dictionary / Array alloc on hot path.
	var n := 0
	var cur_lo := lo
	var cur_hi := hi
	var s := BB.lsb(cur_lo, cur_hi)
	while s >= 0:
		if n < out.size():
			out[n] = s
		n += 1
		var cleared := BB.clear_bit(cur_lo, cur_hi, s)
		cur_lo = cleared[0]
		cur_hi = cleared[1]
		s = BB.lsb(cur_lo, cur_hi)
	return n


static func bb_to_sorted_squares(lo: int, hi: int) -> Array:
	var tmp := PackedInt32Array()
	tmp.resize(T.SQUARE_NB)
	var n := collect_squares(lo, hi, tmp)
	var out: Array = []
	for i in range(n):
		out.append(tmp[i])
	out.sort()
	return out
