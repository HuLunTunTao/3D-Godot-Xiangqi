## Shared helpers for GUT tests (not a GutTest itself).
const C = preload("res://src/nnue/nnue_consts.gd")
const XBoard = preload("res://src/nnue/board.gd")
const XAttacks = preload("res://src/nnue/attacks.gd")


static func sq(file: int, rank: int) -> int:
	return C.make_square(file, rank)


static func empty_occ() -> PackedByteArray:
	var occ := PackedByteArray()
	occ.resize(C.SQUARE_NB)
	return occ


static func sorted_ints(arr) -> PackedInt32Array:
	var out := PackedInt32Array()
	for v in arr:
		out.append(int(v))
	out.sort()
	return out


static func sorted_unique(arr) -> PackedInt32Array:
	var s := sorted_ints(arr)
	if s.is_empty():
		return s
	var out := PackedInt32Array()
	out.append(s[0])
	for i in range(1, s.size()):
		if s[i] != s[i - 1]:
			out.append(s[i])
	return out


static func board_from_fen(fen: String) -> XBoard:
	var b := XBoard.new()
	b.load_fen(fen)
	return b


## Collect pseudo-legal stm moves: attacks to empty or enemy (no own-piece dest).
## Cannon: quiet slides like a rook until blocked; captures need a hurdle (append_captures).
static func collect_stm_moves(pos: XBoard, palace: PackedByteArray) -> Array:
	var moves: Array = []
	var buf := PackedInt32Array()
	buf.resize(36)
	for frm in pos.piece_list:
		var pc: int = pos.sq[frm]
		if (pc >> 3) != pos.stm:
			continue
		var pt := pc & 7
		var col := pc >> 3
		var atks: Array = []
		if pt == C.PAWN:
			atks = XAttacks.pawn_attacks_bb(col, frm)
		elif pt == C.CANNON:
			# Quiet: rook-style until first piece (do not include that piece).
			for d in [C.NORTH, C.SOUTH, C.EAST, C.WEST]:
				var cur: int = frm + d
				while C.is_ok(cur) and C.dist_sq(cur - d, cur) == 1:
					if pos.occ[cur] == 1:
						break
					atks.append(cur)
					cur += d
			var ncap: int = XAttacks.append_captures(C.CANNON, frm, pos.occ, col, buf)
			for i in range(ncap):
				atks.append(buf[i])
		else:
			atks = XAttacks.attacks_bb(pt, frm, pos.occ, col, palace)
		for to_any in atks:
			var to: int = to_any
			if pos.occ[to] == 1 and (pos.sq[to] >> 3) == pos.stm:
				continue
			moves.append(Vector2i(frm, to))
	return moves


static func find_capture_move(pos: XBoard, palace: PackedByteArray) -> Vector2i:
	for m in collect_stm_moves(pos, palace):
		var to: int = m.y
		if pos.occ[to] == 1 and (pos.sq[to] >> 3) != pos.stm:
			return m
	return Vector2i(-1, -1)


static func find_quiet_move(pos: XBoard, palace: PackedByteArray) -> Vector2i:
	for m in collect_stm_moves(pos, palace):
		if pos.occ[m.y] == 0:
			return m
	return Vector2i(-1, -1)
