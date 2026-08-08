class_name PikafishMovegen
extends RefCounted

## Upstream: Pikafish 2c5c998c, src/movegen.cpp
## Writes raw moves into caller-owned PackedInt32Array; returns count.

const T = preload("res://addons/pikafish/core/types.gd")
const BB = preload("res://addons/pikafish/core/bitboard.gd")
const A = preload("res://addons/pikafish/core/attacks.gd")

const GEN_CAPTURES := 0
const GEN_QUIETS := 1
const GEN_EVASIONS := 2
const GEN_PSEUDO_LEGAL := 3
const GEN_LEGAL := 4


static func generate(pos, gen_type: int, out: PackedInt32Array) -> int:
	var n := 0
	match gen_type:
		GEN_CAPTURES:
			n = _generate_all(pos, GEN_CAPTURES, out, 0)
		GEN_QUIETS:
			n = _generate_all(pos, GEN_QUIETS, out, 0)
		GEN_PSEUDO_LEGAL:
			n = _generate_all(pos, GEN_PSEUDO_LEGAL, out, 0)
		GEN_EVASIONS:
			n = _generate_evasions(pos, out)
		GEN_LEGAL:
			var chk: Array = pos.checkers()
			if chk[0] != 0 or chk[1] != 0:
				n = _generate_evasions(pos, out)
			else:
				n = _generate_all(pos, GEN_PSEUDO_LEGAL, out, 0)
			var w := 0
			for i in range(n):
				if pos.legal(out[i]):
					out[w] = out[i]
					w += 1
			n = w
	return n


static func _append_move(out: PackedInt32Array, n: int, frm: int, to: int) -> int:
	if n < out.size():
		out[n] = T.make_move(frm, to)
	return n + 1


static func _generate_all(pos, gen_type: int, out: PackedInt32Array, n0: int) -> int:
	var us: int = pos.side_to_move
	var target: Array
	if gen_type == GEN_PSEUDO_LEGAL:
		var us_bb: Array = pos.pieces_color(us)
		var allb: Array = BB.from_squares_all()
		target = BB.xor_bb(allb[0], allb[1], us_bb[0], us_bb[1])
	elif gen_type == GEN_CAPTURES:
		target = pos.pieces_color(T.flip_color(us))
	else:
		var allp: Array = pos.pieces_all()
		var allb2: Array = BB.from_squares_all()
		target = BB.xor_bb(allb2[0], allb2[1], allp[0], allp[1])

	var n: int = n0
	n = _gen_piece(pos, us, T.PAWN, gen_type, target, out, n)
	n = _gen_piece(pos, us, T.BISHOP, gen_type, target, out, n)
	n = _gen_piece(pos, us, T.ADVISOR, gen_type, target, out, n)
	n = _gen_piece(pos, us, T.KNIGHT, gen_type, target, out, n)
	n = _gen_piece(pos, us, T.CANNON, gen_type, target, out, n)
	n = _gen_piece(pos, us, T.ROOK, gen_type, target, out, n)

	if gen_type != GEN_EVASIONS:
		var ksq: int = pos.king_square(us)
		var king_at: Array = A.attacks_bb(T.KING, ksq)
		var b: Array = BB.and_bb(king_at[0], king_at[1], target[0], target[1])
		var lo: int = b[0]
		var hi: int = b[1]
		var to: int = BB.lsb(lo, hi)
		while to >= 0:
			n = _append_move(out, n, ksq, to)
			var cleared: Array = BB.clear_bit(lo, hi, to)
			lo = cleared[0]
			hi = cleared[1]
			to = BB.lsb(lo, hi)
	return n


static func _gen_piece(
	pos, us: int, pt: int, gen_type: int, target: Array, out: PackedInt32Array, n0: int
) -> int:
	var n: int = n0
	var bb: Array = pos.pieces_color_type(us, pt)
	var lo: int = bb[0]
	var hi: int = bb[1]
	var frm: int = BB.lsb(lo, hi)
	var occ: Array = pos.pieces_all()
	while frm >= 0:
		var b: Array = [0, 0]
		if pt == T.CANNON:
			if gen_type != GEN_QUIETS:
				var cap: Array = A.attacks_bb(T.CANNON, frm, occ[0], occ[1])
				var them: Array = pos.pieces_color(T.flip_color(us))
				var cap_t: Array = BB.and_bb(cap[0], cap[1], them[0], them[1])
				b = BB.or_bb(b[0], b[1], cap_t[0], cap_t[1])
			if gen_type != GEN_CAPTURES:
				var quiet: Array = A.attacks_bb(T.ROOK, frm, occ[0], occ[1])
				var allb: Array = BB.from_squares_all()
				var empty: Array = BB.xor_bb(allb[0], allb[1], occ[0], occ[1])
				var q_t: Array = BB.and_bb(quiet[0], quiet[1], empty[0], empty[1])
				b = BB.or_bb(b[0], b[1], q_t[0], q_t[1])
			if gen_type == GEN_EVASIONS:
				b = BB.and_bb(b[0], b[1], target[0], target[1])
		elif pt == T.PAWN:
			var atk: Array = A.attacks_bb_pawn(us, frm)
			b = BB.and_bb(atk[0], atk[1], target[0], target[1])
		else:
			var atk2: Array = A.attacks_bb(pt, frm, occ[0], occ[1])
			b = BB.and_bb(atk2[0], atk2[1], target[0], target[1])

		var tlo: int = b[0]
		var thi: int = b[1]
		var to: int = BB.lsb(tlo, thi)
		while to >= 0:
			n = _append_move(out, n, frm, to)
			var c2: Array = BB.clear_bit(tlo, thi, to)
			tlo = c2[0]
			thi = c2[1]
			to = BB.lsb(tlo, thi)

		var c1: Array = BB.clear_bit(lo, hi, frm)
		lo = c1[0]
		hi = c1[1]
		frm = BB.lsb(lo, hi)
	return n


static func _generate_evasions(pos, out: PackedInt32Array) -> int:
	var chk: Array = pos.checkers()
	if BB.more_than_one(chk[0], chk[1]):
		return _generate_all(pos, GEN_PSEUDO_LEGAL, out, 0)

	var us: int = pos.side_to_move
	var ksq: int = pos.king_square(us)
	var checksq: int = BB.lsb(chk[0], chk[1])
	var pt: int = T.type_of(pos.piece_on(checksq))
	var between: Array = A.between_bb(ksq, checksq)
	var us_bb: Array = pos.pieces_color(us)
	var allb: Array = BB.from_squares_all()
	var not_us: Array = BB.xor_bb(allb[0], allb[1], us_bb[0], us_bb[1])
	var target: Array = BB.and_bb(between[0], between[1], not_us[0], not_us[1])

	var n: int = 0
	n = _gen_piece(pos, us, T.PAWN, GEN_EVASIONS, target, out, n)
	n = _gen_piece(pos, us, T.BISHOP, GEN_EVASIONS, target, out, n)
	n = _gen_piece(pos, us, T.ADVISOR, GEN_EVASIONS, target, out, n)
	n = _gen_piece(pos, us, T.KNIGHT, GEN_EVASIONS, target, out, n)
	n = _gen_piece(pos, us, T.CANNON, GEN_EVASIONS, target, out, n)
	n = _gen_piece(pos, us, T.ROOK, GEN_EVASIONS, target, out, n)

	var king_at: Array = A.attacks_bb(T.KING, ksq)
	var b: Array = BB.and_bb(king_at[0], king_at[1], not_us[0], not_us[1])
	if pt == T.ROOK or pt == T.CANNON:
		var line: Array = A.line_bb(checksq, ksq)
		var them: Array = pos.pieces_color(T.flip_color(us))
		var not_line: Array = BB.xor_bb(allb[0], allb[1], line[0], line[1])
		var allow: Array = BB.or_bb(not_line[0], not_line[1], them[0], them[1])
		b = BB.and_bb(b[0], b[1], allow[0], allow[1])
	var lo: int = b[0]
	var hi: int = b[1]
	var to: int = BB.lsb(lo, hi)
	while to >= 0:
		n = _append_move(out, n, ksq, to)
		var cleared: Array = BB.clear_bit(lo, hi, to)
		lo = cleared[0]
		hi = cleared[1]
		to = BB.lsb(lo, hi)

	if pt == T.CANNON:
		var hurdle: Array = BB.and_bb(between[0], between[1], us_bb[0], us_bb[1])
		hurdle = BB.clear_bit(hurdle[0], hurdle[1], checksq)
		hurdle = BB.clear_bit(hurdle[0], hurdle[1], ksq)
		if hurdle[0] != 0 or hurdle[1] != 0:
			var hsq: int = BB.lsb(hurdle[0], hurdle[1])
			var hpt: int = T.type_of(pos.piece_on(hsq))
			var occ: Array = pos.pieces_all()
			var hb: Array = [0, 0]
			var line2: Array = A.line_bb(checksq, hsq)
			var not_line2: Array = BB.xor_bb(allb[0], allb[1], line2[0], line2[1])
			if hpt == T.PAWN:
				var pa: Array = A.attacks_bb_pawn(us, hsq)
				hb = BB.and_bb(pa[0], pa[1], not_line2[0], not_line2[1])
				hb = BB.and_bb(hb[0], hb[1], not_us[0], not_us[1])
			elif hpt == T.CANNON:
				var rq: Array = A.attacks_bb(T.ROOK, hsq, occ[0], occ[1])
				var empty: Array = BB.xor_bb(allb[0], allb[1], occ[0], occ[1])
				hb = BB.and_bb(rq[0], rq[1], empty[0], empty[1])
				hb = BB.and_bb(hb[0], hb[1], not_line2[0], not_line2[1])
				var cap: Array = A.attacks_bb(T.CANNON, hsq, occ[0], occ[1])
				var them2: Array = pos.pieces_color(T.flip_color(us))
				var cap_t: Array = BB.and_bb(cap[0], cap[1], them2[0], them2[1])
				hb = BB.or_bb(hb[0], hb[1], cap_t[0], cap_t[1])
			else:
				var at: Array = A.attacks_bb(hpt, hsq, occ[0], occ[1])
				hb = BB.and_bb(at[0], at[1], not_line2[0], not_line2[1])
				hb = BB.and_bb(hb[0], hb[1], not_us[0], not_us[1])
			var hlo: int = hb[0]
			var hhi: int = hb[1]
			var ht: int = BB.lsb(hlo, hhi)
			while ht >= 0:
				n = _append_move(out, n, hsq, ht)
				var c3: Array = BB.clear_bit(hlo, hhi, ht)
				hlo = c3[0]
				hhi = c3[1]
				ht = BB.lsb(hlo, hhi)
	return n


static func perft(pos, depth: int) -> int:
	if depth == 0:
		return 1
	var buf := PackedInt32Array()
	buf.resize(T.MAX_MOVES)
	var n: int = generate(pos, GEN_LEGAL, buf)
	if depth == 1:
		return n
	var nodes := 0
	for i in range(n):
		var m: int = buf[i]
		pos.do_move(m)
		nodes += perft(pos, depth - 1)
		pos.undo_move(m)
	return nodes
