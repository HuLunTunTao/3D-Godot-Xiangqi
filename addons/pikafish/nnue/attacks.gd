## Xiangqi attack generation (direct formulas, no magic bitboards).
## Returns attack squares as Arrays. Occupancy is a 90-byte PackedByteArray (1=occupied).
## Mirrors tools/gen_tables.py exactly.
## Non-sliding pieces use precomputed (to, leg) tables to avoid per-call direction math.
class_name PikafishNnueAttacks
extends RefCounted
const C = preload("res://addons/pikafish/nnue/consts.gd")

# Direction tables as plain Arrays of int literals (must be const-expressions)
const ROOK_DIRS := [9, -9, 1, -1]  # N S E W
const KING_STEPS := [9, -9, 1, -1]
const ADVISOR_STEPS := [8, 10, -10, -8]  # NW NE SW SE
const BISHOP_DIRS := [20, -16, -20, 16]  # 2*NE, 2*SE, 2*SW, 2*NW
const KNIGHT_DIRS := [
	-19, -17, -11, -7, 7, 11, 17, 19]  # 2S+W, 2S+E, S+2W, S+2E, N+2W, N+2E, 2N+W, 2N+E
const PAWN_SIDES := [-1, 1]

# Lazy-built tables: pawn_atk[color][sq] -> PackedInt32Array of targets
# leaper_atk[pt][sq] -> PackedInt32Array interleaved [to, leg, to, leg, ...] (leg=-1 if none)
# king_atk[sq] / advisor_atk[sq] -> PackedInt32Array of targets
static var _tables_ready := false
static var pawn_atk: Array = []
static var knight_moves: Array = []  # [90] PackedInt32Array [to,leg,...]
static var bishop_moves: Array = []
static var king_atk: Array = []
static var advisor_atk: Array = []


static func ensure_tables() -> void:
	if _tables_ready:
		return
	_tables_ready = true
	var palace := C.palace_squares()
	pawn_atk = [[], []]
	knight_moves = []
	bishop_moves = []
	king_atk = []
	advisor_atk = []
	for s in range(C.SQUARE_NB):
		var pw := PackedInt32Array()
		var pb := PackedInt32Array()
		for t in pawn_attacks_bb_raw(C.WHITE, s):
			pw.append(t)
		for t in pawn_attacks_bb_raw(C.BLACK, s):
			pb.append(t)
		pawn_atk[0].append(pw)
		pawn_atk[1].append(pb)
		knight_moves.append(_build_leaper_pairs(C.KNIGHT, s))
		bishop_moves.append(_build_leaper_pairs(C.BISHOP, s))
		var ka := PackedInt32Array()
		for t in pseudo_king_raw(s, palace):
			ka.append(t)
		king_atk.append(ka)
		var aa := PackedInt32Array()
		for t in pseudo_advisor_raw(s, palace):
			aa.append(t)
		advisor_atk.append(aa)


static func c_mod(a: int, b: int) -> int:
	# C-style truncated modulo (toward zero)
	return a - (int(a / b)) * b


static func pawn_attacks_bb_raw(c: int, s: int) -> Array:
	var out := []
	var fwd := C.NORTH if c == C.WHITE else C.SOUTH
	var to := s + fwd
	if C.is_ok(to) and C.dist_sq(s, to) == 1:
		out.append(to)
	if (c == C.WHITE and C.rank_of(s) > 4) or (c == C.BLACK and C.rank_of(s) < 5):
		for sd in PAWN_SIDES:
			to = s + int(sd)
			if C.is_ok(to) and C.dist_sq(s, to) == 1:
				out.append(to)
	return out


static func pawn_attacks_bb(c: int, s: int) -> Array:
	ensure_tables()
	var arr: PackedInt32Array = pawn_atk[c][s]
	var out := []
	for i in range(arr.size()):
		out.append(arr[i])
	return out


static func sliding_attack(pt: int, sq0: int, occ: PackedByteArray) -> Array:
	# pt is ROOK or CANNON
	var out := []
	for d_any in ROOK_DIRS:
		var d: int = d_any
		var hurdle := false
		var s: int = sq0 + d
		while C.is_ok(s) and C.dist_sq(s - d, s) == 1:
			if pt == C.ROOK or hurdle:
				out.append(s)
			if occ[s] == 1:
				if pt == C.CANNON and not hurdle:
					hurdle = true
				else:
					break
			s += d
	return out


static func lame_leaper_path(pt: int, d: int, s: int) -> int:
	# Returns the leg square (or -1 if none). KNIGHT_TO not handled (unused).
	var to := s + d
	if not C.is_ok(to) or C.dist_sq(s, to) > 3:
		return -1
	var dr := C.NORTH if d > 0 else C.SOUTH
	var md := c_mod(d, C.NORTH)
	var amod: int = absi(md)
	var inner := md if amod < (C.NORTH / 2) else -md
	var df := C.WEST if inner < 0 else C.EAST
	var diff := absi(C.file_of(to) - C.file_of(s)) - absi(C.rank_of(to) - C.rank_of(s))
	var leg := s
	if diff > 0:
		leg += df
	elif diff < 0:
		leg += dr
	else:
		leg += df + dr
	return leg


static func _build_leaper_pairs(pt: int, s: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	var dirs: Array = BISHOP_DIRS if pt == C.BISHOP else KNIGHT_DIRS
	for d_any in dirs:
		var d: int = d_any
		var to: int = s + d
		if C.is_ok(to) and C.dist_sq(s, to) < 3:
			if pt == C.BISHOP:
				var half := 1 if C.rank_of(s) > 4 else 0
				if (C.rank_of(to) > 4) != (half == 1):
					continue
			var leg := lame_leaper_path(pt, d, s)
			out.append(to)
			out.append(leg)
	return out


static func lame_leaper_attack(pt: int, s: int, occ: PackedByteArray) -> Array:
	ensure_tables()
	var pairs: PackedInt32Array = bishop_moves[s] if pt == C.BISHOP else knight_moves[s]
	var out := []
	var i := 0
	while i < pairs.size():
		var to: int = pairs[i]
		var leg: int = pairs[i + 1]
		if leg < 0 or occ[leg] == 0:
			out.append(to)
		i += 2
	return out


static func pseudo_king_raw(s: int, palace: PackedByteArray) -> Array:
	var out := []
	for step_any in KING_STEPS:
		var step: int = step_any
		var to: int = s + step
		if C.is_ok(to) and C.dist_sq(s, to) <= 2 and palace[to] == 1:
			out.append(to)
	return out


static func pseudo_advisor_raw(s: int, palace: PackedByteArray) -> Array:
	var out := []
	for step_any in ADVISOR_STEPS:
		var step: int = step_any
		var to: int = s + step
		if C.is_ok(to) and C.dist_sq(s, to) <= 2 and palace[to] == 1:
			out.append(to)
	return out


static func pseudo_king(s: int, palace: PackedByteArray) -> Array:
	ensure_tables()
	var arr: PackedInt32Array = king_atk[s]
	var out := []
	for i in range(arr.size()):
		out.append(arr[i])
	return out


static func pseudo_advisor(s: int, palace: PackedByteArray) -> Array:
	ensure_tables()
	var arr: PackedInt32Array = advisor_atk[s]
	var out := []
	for i in range(arr.size()):
		out.append(arr[i])
	return out


## Fast path: append attack targets into `out` (no Array alloc).
static func append_attacks(pt: int, s: int, occ: PackedByteArray, c: int, out: PackedInt32Array) -> int:
	ensure_tables()
	var n := 0
	match pt:
		C.PAWN:
			var arr: PackedInt32Array = pawn_atk[c][s]
			for i in range(arr.size()):
				out[n] = arr[i]
				n += 1
		C.ROOK, C.CANNON:
			for d_any in ROOK_DIRS:
				var d: int = d_any
				var hurdle := false
				var cur: int = s + d
				while C.is_ok(cur) and C.dist_sq(cur - d, cur) == 1:
					if pt == C.ROOK or hurdle:
						out[n] = cur
						n += 1
					if occ[cur] == 1:
						if pt == C.CANNON and not hurdle:
							hurdle = true
						else:
							break
					cur += d
		C.KNIGHT:
			var pairs: PackedInt32Array = knight_moves[s]
			var i := 0
			while i < pairs.size():
				var to: int = pairs[i]
				var leg: int = pairs[i + 1]
				if leg < 0 or occ[leg] == 0:
					out[n] = to
					n += 1
				i += 2
		C.BISHOP:
			var pairs: PackedInt32Array = bishop_moves[s]
			var i := 0
			while i < pairs.size():
				var to: int = pairs[i]
				var leg: int = pairs[i + 1]
				if leg < 0 or occ[leg] == 0:
					out[n] = to
					n += 1
				i += 2
		C.KING:
			var arr: PackedInt32Array = king_atk[s]
			for i in range(arr.size()):
				out[n] = arr[i]
				n += 1
		C.ADVISOR:
			var arr: PackedInt32Array = advisor_atk[s]
			for i in range(arr.size()):
				out[n] = arr[i]
				n += 1
	return n


## Threat hot path: only occupied targets (FullThreats only needs those).
static func append_captures(pt: int, s: int, occ: PackedByteArray, c: int, out: PackedInt32Array) -> int:
	ensure_tables()
	var n := 0
	match pt:
		C.PAWN:
			var arr: PackedInt32Array = pawn_atk[c][s]
			for i in range(arr.size()):
				var to: int = arr[i]
				if occ[to] == 1:
					out[n] = to
					n += 1
		C.ROOK:
			for d_any in ROOK_DIRS:
				var d: int = d_any
				var cur: int = s + d
				while C.is_ok(cur) and C.dist_sq(cur - d, cur) == 1:
					if occ[cur] == 1:
						out[n] = cur
						n += 1
						break
					cur += d
		C.CANNON:
			for d_any in ROOK_DIRS:
				var d: int = d_any
				var hurdle := false
				var cur: int = s + d
				while C.is_ok(cur) and C.dist_sq(cur - d, cur) == 1:
					if occ[cur] == 1:
						if hurdle:
							out[n] = cur
							n += 1
							break
						hurdle = true
					cur += d
		C.KNIGHT:
			var pairs: PackedInt32Array = knight_moves[s]
			var i := 0
			while i < pairs.size():
				var to: int = pairs[i]
				var leg: int = pairs[i + 1]
				if (leg < 0 or occ[leg] == 0) and occ[to] == 1:
					out[n] = to
					n += 1
				i += 2
		C.BISHOP:
			var pairs: PackedInt32Array = bishop_moves[s]
			var i := 0
			while i < pairs.size():
				var to: int = pairs[i]
				var leg: int = pairs[i + 1]
				if (leg < 0 or occ[leg] == 0) and occ[to] == 1:
					out[n] = to
					n += 1
				i += 2
		C.KING:
			var arr: PackedInt32Array = king_atk[s]
			for i in range(arr.size()):
				var to: int = arr[i]
				if occ[to] == 1:
					out[n] = to
					n += 1
		C.ADVISOR:
			var arr: PackedInt32Array = advisor_atk[s]
			for i in range(arr.size()):
				var to: int = arr[i]
				if occ[to] == 1:
					out[n] = to
					n += 1
	return n


static func attacks_bb(pt: int, s: int, occ: PackedByteArray, c: int, palace: PackedByteArray) -> Array:
	match pt:
		C.PAWN:
			return pawn_attacks_bb(c, s)
		C.ROOK:
			return sliding_attack(C.ROOK, s, occ)
		C.CANNON:
			return sliding_attack(C.CANNON, s, occ)
		C.KNIGHT:
			return lame_leaper_attack(C.KNIGHT, s, occ)
		C.BISHOP:
			return lame_leaper_attack(C.BISHOP, s, occ)
		C.KING:
			return pseudo_king(s, palace)
		C.ADVISOR:
			return pseudo_advisor(s, palace)
	return []
