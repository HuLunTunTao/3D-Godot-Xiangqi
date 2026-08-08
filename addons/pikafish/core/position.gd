class_name PikafishPosition
extends RefCounted

## Upstream: Pikafish 2c5c998c, src/position.*
## Phase C: FEN, bitboard reps, checkers/blockers, do/undo, legal, SEE, rule_judge wiring.

const T = preload("res://addons/pikafish/core/types.gd")
const BB = preload("res://addons/pikafish/core/bitboard.gd")
const A = preload("res://addons/pikafish/core/attacks.gd")
const Z = preload("res://addons/pikafish/core/zobrist.gd")
const StateStack = preload("res://addons/pikafish/core/state_stack.gd")
const Rules = preload("res://addons/pikafish/core/rules.gd")
const MG = preload("res://addons/pikafish/core/movegen.gd")

var board: PackedByteArray = PackedByteArray()
## by_type[pt] = [lo, hi]; by_color[c] = [lo, hi]
var by_type: Array = []
var by_color: Array = []
var piece_count: PackedInt32Array = PackedInt32Array()
var side_to_move: int = T.COLOR_WHITE
var game_ply: int = 0
var stack = StateStack.new()
## Bloom filter 1<<14 bytes for adjust_key60
var filter: PackedByteArray = PackedByteArray()
var id_board: PackedInt32Array = PackedInt32Array()
var last_error: String = ""


func _init() -> void:
	board.resize(T.SQUARE_NB)
	piece_count.resize(T.PIECE_NB)
	by_type = []
	for _i in range(T.PIECE_TYPE_NB):
		by_type.append([0, 0])
	by_color = [[0, 0], [0, 0]]
	filter.resize(1 << 14)
	id_board.resize(T.SQUARE_NB)
	BB.ensure_tables()
	A.init_tables()
	Z.init_keys()


func st() -> int:
	return stack.ply


func set_fen(fen: String) -> Error:
	## Upstream: Position::set — simplified validation sufficient for engine use.
	last_error = ""
	var parts := fen.strip_edges().split(" ", false)
	if parts.is_empty():
		last_error = "empty fen"
		return ERR_INVALID_PARAMETER

	board.fill(0)
	piece_count.fill(0)
	for i in range(T.PIECE_TYPE_NB):
		by_type[i] = [0, 0]
	by_color = [[0, 0], [0, 0]]
	filter.fill(0)
	id_board.fill(0)
	stack.reset()

	var ranks := parts[0].split("/")
	if ranks.size() != 10:
		last_error = "expected 10 ranks"
		return ERR_INVALID_PARAMETER
	for i in range(10):
		var r := 9 - i
		var f := 0
		for ch in ranks[i]:
			if str(ch).is_valid_int():
				f += int(ch)
				if f > T.FILE_NB:
					last_error = "file overflow"
					return ERR_INVALID_PARAMETER
			elif ch == "/":
				last_error = "bad slash"
				return ERR_INVALID_PARAMETER
			else:
				var pc: int = T.char_to_piece(ch)
				if pc == T.NO_PIECE:
					last_error = "bad piece char"
					return ERR_INVALID_PARAMETER
				if f >= T.FILE_NB:
					last_error = "file overflow"
					return ERR_INVALID_PARAMETER
				_put_piece(T.make_square(f, r), pc)
				f += 1
		if f != T.FILE_NB:
			last_error = "rank width"
			return ERR_INVALID_PARAMETER

	if parts.size() >= 2:
		if parts[1] == "w":
			side_to_move = T.COLOR_WHITE
		elif parts[1] == "b":
			side_to_move = T.COLOR_BLACK
		else:
			last_error = "bad stm"
			return ERR_INVALID_PARAMETER
	else:
		side_to_move = T.COLOR_WHITE

	var rule60_v := 0
	var fullmove := 1
	# Pikafish FEN: pieces stm - rule60 fullmove  OR classic with castle '-' skip
	# Format from dump: "... w - - 0 1"
	if parts.size() >= 5 and parts[2] == "-" and parts[3] == "-":
		rule60_v = int(parts[4])
		if parts.size() >= 6:
			fullmove = int(parts[5])
	elif parts.size() >= 4:
		# pieces stm rule60 fullmove
		rule60_v = int(parts[2])
		fullmove = int(parts[3])

	stack.rule60[0] = rule60_v
	game_ply = maxi(2 * (fullmove - 1), 0) + (1 if side_to_move == T.COLOR_BLACK else 0)

	if king_square(T.COLOR_WHITE) < 0 or king_square(T.COLOR_BLACK) < 0:
		last_error = "missing king"
		return ERR_INVALID_PARAMETER

	_set_state()
	# Opponent must not already be in check to move (king capturable)
	var opp_ksq := king_square(T.flip_color(side_to_move))
	var chk := checkers_to(side_to_move, opp_ksq)
	if chk[0] != 0 or chk[1] != 0:
		last_error = "king can be captured"
		return ERR_INVALID_PARAMETER
	return OK


func get_fen() -> String:
	var ss := ""
	for r in range(9, -1, -1):
		var empty := 0
		for f in range(T.FILE_NB):
			var pc: int = board[T.make_square(f, r)]
			if pc == T.NO_PIECE:
				empty += 1
			else:
				if empty:
					ss += str(empty)
					empty = 0
				ss += T.piece_to_char(pc)
		if empty:
			ss += str(empty)
		if r > 0:
			ss += "/"
	ss += " w " if side_to_move == T.COLOR_WHITE else " b "
	ss += "- - "
	ss += str(stack.rule60[st()])
	ss += " "
	ss += str(1 + int((game_ply - (1 if side_to_move == T.COLOR_BLACK else 0)) / 2))
	return ss


func piece_on(s: int) -> int:
	return board[s]


func empty_sq(s: int) -> bool:
	return board[s] == T.NO_PIECE


func pieces_all() -> Array:
	return by_type[T.ALL_PIECES]


func pieces_color(c: int) -> Array:
	return by_color[c]


func pieces_type(pt: int) -> Array:
	return by_type[pt]


func pieces_color_type(c: int, pt: int) -> Array:
	return BB.and_bb(by_color[c][0], by_color[c][1], by_type[pt][0], by_type[pt][1])


func king_square(c: int) -> int:
	var b: Array = pieces_color_type(c, T.KING)
	return BB.lsb(b[0], b[1])


func side_to_move_color() -> int:
	return side_to_move


func rule60_count() -> int:
	return stack.rule60[st()]


func checkers() -> Array:
	return [stack.checkers_lo[st()], stack.checkers_hi[st()]]


func blockers_for_king(c: int) -> Array:
	if c == T.COLOR_WHITE:
		return [stack.blockers_w_lo[st()], stack.blockers_w_hi[st()]]
	return [stack.blockers_b_lo[st()], stack.blockers_b_hi[st()]]


func pinners(c: int) -> Array:
	if c == T.COLOR_WHITE:
		return [stack.pinners_w_lo[st()], stack.pinners_w_hi[st()]]
	return [stack.pinners_b_lo[st()], stack.pinners_b_hi[st()]]


func key() -> int:
	return _adjust_key60(stack.key[st()], false)


func raw_key() -> int:
	return stack.key[st()]


func pawn_key() -> int:
	## Upstream: Position::pawn_key
	return stack.pawn_key[st()]


func minor_piece_key() -> int:
	## Upstream: Position::minor_piece_key
	return stack.minor_piece_key[st()]


func non_pawn_key(c: int) -> int:
	## Upstream: Position::non_pawn_key
	if c == T.COLOR_WHITE:
		return stack.non_pawn_key_w[st()]
	return stack.non_pawn_key_b[st()]


func check_squares(pt: int) -> Array:
	## Upstream: Position::check_squares — returns (lo, hi) bitboard.
	var i: int = st()
	return [stack.check_sq_lo[pt][i], stack.check_sq_hi[pt][i]]


func attacks_by(pt: int, c: int) -> Array:
	## Upstream: Position::attacks_by<Pt>(Color) — union of attacks from side c pieces of type pt.
	var attackers: Array = pieces_color_type(c, pt)
	var threats_lo: int = 0
	var threats_hi: int = 0
	var lo: int = attackers[0]
	var hi: int = attackers[1]
	var s: int = BB.lsb(lo, hi)
	var occ: Array = pieces_all()
	while s >= 0:
		var att: Array
		if pt == T.PAWN:
			att = A.attacks_bb_pawn(c, s)
		else:
			att = A.attacks_bb(pt, s, occ[0], occ[1])
		threats_lo |= att[0]
		threats_hi |= att[1]
		var cleared: Array = BB.clear_bit(lo, hi, s)
		lo = cleared[0]
		hi = cleared[1]
		s = BB.lsb(lo, hi)
	return [threats_lo, threats_hi]


func _adjust_key60(k: int, after_move: bool) -> int:
	## Upstream: adjust_key60 — BloomFilter indexes by raw key `k`.
	var r60: int = stack.rule60[st()]
	var thr := 14 - (1 if after_move else 0)
	var out := k
	if r60 >= thr:
		out ^= Z.make_key(int((r60 - thr) / 8))
	var slot: int = k & ((1 << 14) - 1)
	if filter[slot] != 0:
		out ^= Z.make_key(14)
	return out


func count_pt(pt: int, c: int = -1) -> int:
	if c < 0:
		return int(piece_count[T.make_piece(T.COLOR_WHITE, pt)]) + int(
			piece_count[T.make_piece(T.COLOR_BLACK, pt)]
		)
	return int(piece_count[T.make_piece(c, pt)])


func major_material(c: int = -1) -> int:
	## Upstream: Position::major_material
	if c < 0:
		return stack.major_material_w[st()] + stack.major_material_b[st()]
	if c == T.COLOR_WHITE:
		return stack.major_material_w[st()]
	return stack.major_material_b[st()]


func clone_for_rollback():
	## Upstream: memcpy Position excluding filter for detect_chases.
	var p = (get_script() as GDScript).new()
	p.board = board.duplicate()
	p.piece_count = piece_count.duplicate()
	p.side_to_move = side_to_move
	p.game_ply = game_ply
	p.id_board = id_board.duplicate()
	p.by_type = []
	for i in range(by_type.size()):
		p.by_type.append([by_type[i][0], by_type[i][1]])
	p.by_color = [[by_color[0][0], by_color[0][1]], [by_color[1][0], by_color[1][1]]]
	# filter stays zeroed (upstream offsetof excludes it)
	p.stack.ply = stack.ply
	_copy_stack_prefix(p.stack, stack, stack.ply)
	return p


func _copy_stack_prefix(dst, src, last_ply: int) -> void:
	for i in range(last_ply + 1):
		dst.key[i] = src.key[i]
		dst.pawn_key[i] = src.pawn_key[i]
		dst.minor_piece_key[i] = src.minor_piece_key[i]
		dst.non_pawn_key_w[i] = src.non_pawn_key_w[i]
		dst.non_pawn_key_b[i] = src.non_pawn_key_b[i]
		dst.major_material_w[i] = src.major_material_w[i]
		dst.major_material_b[i] = src.major_material_b[i]
		dst.check10_w[i] = src.check10_w[i]
		dst.check10_b[i] = src.check10_b[i]
		dst.rule60[i] = src.rule60[i]
		dst.plies_from_null[i] = src.plies_from_null[i]
		dst.checkers_lo[i] = src.checkers_lo[i]
		dst.checkers_hi[i] = src.checkers_hi[i]
		dst.blockers_w_lo[i] = src.blockers_w_lo[i]
		dst.blockers_w_hi[i] = src.blockers_w_hi[i]
		dst.blockers_b_lo[i] = src.blockers_b_lo[i]
		dst.blockers_b_hi[i] = src.blockers_b_hi[i]
		dst.pinners_w_lo[i] = src.pinners_w_lo[i]
		dst.pinners_w_hi[i] = src.pinners_w_hi[i]
		dst.pinners_b_lo[i] = src.pinners_b_lo[i]
		dst.pinners_b_hi[i] = src.pinners_b_hi[i]
		dst.need_full_check[i] = src.need_full_check[i]
		dst.captured_piece[i] = src.captured_piece[i]
		dst.move[i] = src.move[i]
		for pt in range(T.PIECE_TYPE_NB):
			dst.check_sq_lo[pt][i] = src.check_sq_lo[pt][i]
			dst.check_sq_hi[pt][i] = src.check_sq_hi[pt][i]


func do_move_light(m: int) -> Array:
	## Upstream: Position::do_move(Move) light chase helper. Returns [captured, id].
	var frm: int = T.from_sq(m)
	var to: int = T.to_sq(m)
	var captured: int = board[to]
	var id: int = id_board[to]
	id_board[to] = id_board[frm]
	id_board[frm] = 0
	if captured != T.NO_PIECE:
		_remove_piece(to)
	_move_piece(frm, to)
	side_to_move = T.flip_color(side_to_move)
	return [captured, id]


func undo_move_light(m: int, captured: int, id: int = 0) -> void:
	## Upstream: Position::undo_move(Move, Piece, int) light chase helper.
	side_to_move = T.flip_color(side_to_move)
	var frm: int = T.from_sq(m)
	var to: int = T.to_sq(m)
	id_board[frm] = id_board[to]
	id_board[to] = id
	_move_piece(to, frm)
	if captured != T.NO_PIECE:
		_put_piece(to, captured)


func rule_judge(ply: int = 0) -> Dictionary:
	return Rules.rule_judge(self, ply)


func chased(c: int) -> int:
	return Rules.chased(self, c)


func chase_legal(m: int) -> bool:
	return Rules.chase_legal(self, m)


func _put_piece(s: int, pc: int) -> void:
	board[s] = pc
	var pt: int = T.type_of(pc)
	var c: int = T.color_of(pc)
	by_type[T.ALL_PIECES] = BB.set_bit(by_type[T.ALL_PIECES][0], by_type[T.ALL_PIECES][1], s)
	by_type[pt] = BB.set_bit(by_type[pt][0], by_type[pt][1], s)
	by_color[c] = BB.set_bit(by_color[c][0], by_color[c][1], s)
	piece_count[pc] += 1


func _remove_piece(s: int) -> int:
	var pc: int = board[s]
	if pc == T.NO_PIECE:
		return T.NO_PIECE
	var pt: int = T.type_of(pc)
	var c: int = T.color_of(pc)
	board[s] = T.NO_PIECE
	by_type[T.ALL_PIECES] = BB.clear_bit(by_type[T.ALL_PIECES][0], by_type[T.ALL_PIECES][1], s)
	by_type[pt] = BB.clear_bit(by_type[pt][0], by_type[pt][1], s)
	by_color[c] = BB.clear_bit(by_color[c][0], by_color[c][1], s)
	piece_count[pc] -= 1
	return pc


func _move_piece(frm: int, to: int) -> void:
	var pc: int = board[frm]
	_remove_piece(frm)
	_put_piece(to, pc)


func attackers_to(s: int, occ_lo: int = -1, occ_hi: int = -1) -> Array:
	## Upstream: attackers_to(s, occupied)
	var occ: Array
	if occ_lo == -1:
		occ = pieces_all()
	else:
		occ = [occ_lo, occ_hi]
	var pawn_w := A.pawn_attacks_to_bb(T.COLOR_WHITE, s)
	var pawn_b := A.pawn_attacks_to_bb(T.COLOR_BLACK, s)
	var out := [0, 0]
	var pw := pieces_color_type(T.COLOR_WHITE, T.PAWN)
	var pb := pieces_color_type(T.COLOR_BLACK, T.PAWN)
	out = BB.or_bb(out[0], out[1], BB.and_bb(pawn_w[0], pawn_w[1], pw[0], pw[1])[0], BB.and_bb(pawn_w[0], pawn_w[1], pw[0], pw[1])[1])
	var t := BB.and_bb(pawn_b[0], pawn_b[1], pb[0], pb[1])
	out = BB.or_bb(out[0], out[1], t[0], t[1])
	var kn := A.attacks_bb(T.KNIGHT_TO, s, occ[0], occ[1])
	var knp := pieces_type(T.KNIGHT)
	t = BB.and_bb(kn[0], kn[1], knp[0], knp[1])
	out = BB.or_bb(out[0], out[1], t[0], t[1])
	var rk := A.attacks_bb(T.ROOK, s, occ[0], occ[1])
	var rkp := pieces_type(T.ROOK)
	t = BB.and_bb(rk[0], rk[1], rkp[0], rkp[1])
	out = BB.or_bb(out[0], out[1], t[0], t[1])
	var cn := A.attacks_bb(T.CANNON, s, occ[0], occ[1])
	var cnp := pieces_type(T.CANNON)
	t = BB.and_bb(cn[0], cn[1], cnp[0], cnp[1])
	out = BB.or_bb(out[0], out[1], t[0], t[1])
	var bi := A.attacks_bb(T.BISHOP, s, occ[0], occ[1])
	var bip := pieces_type(T.BISHOP)
	t = BB.and_bb(bi[0], bi[1], bip[0], bip[1])
	out = BB.or_bb(out[0], out[1], t[0], t[1])
	var ad := A.attacks_bb(T.ADVISOR, s)
	var adp := pieces_type(T.ADVISOR)
	t = BB.and_bb(ad[0], ad[1], adp[0], adp[1])
	out = BB.or_bb(out[0], out[1], t[0], t[1])
	var kg := A.attacks_bb(T.KING, s)
	var kgp := pieces_type(T.KING)
	t = BB.and_bb(kg[0], kg[1], kgp[0], kgp[1])
	out = BB.or_bb(out[0], out[1], t[0], t[1])
	return out


func checkers_to(c: int, s: int, occ_lo: int = -1, occ_hi: int = -1) -> Array:
	## Upstream: checkers_to
	var occ: Array
	if occ_lo == -1:
		occ = pieces_all()
	else:
		occ = [occ_lo, occ_hi]
	var out := [0, 0]
	var pawn_to := A.pawn_attacks_to_bb(c, s)
	var pawns := pieces_type(T.PAWN)
	var t := BB.and_bb(pawn_to[0], pawn_to[1], pawns[0], pawns[1])
	out = BB.or_bb(out[0], out[1], t[0], t[1])
	var kn := A.attacks_bb(T.KNIGHT_TO, s, occ[0], occ[1])
	var knp := pieces_type(T.KNIGHT)
	t = BB.and_bb(kn[0], kn[1], knp[0], knp[1])
	out = BB.or_bb(out[0], out[1], t[0], t[1])
	var rk := A.attacks_bb(T.ROOK, s, occ[0], occ[1])
	var king_rook := BB.or_bb(pieces_type(T.KING)[0], pieces_type(T.KING)[1], pieces_type(T.ROOK)[0], pieces_type(T.ROOK)[1])
	t = BB.and_bb(rk[0], rk[1], king_rook[0], king_rook[1])
	out = BB.or_bb(out[0], out[1], t[0], t[1])
	var cn := A.attacks_bb(T.CANNON, s, occ[0], occ[1])
	var cnp := pieces_type(T.CANNON)
	t = BB.and_bb(cn[0], cn[1], cnp[0], cnp[1])
	out = BB.or_bb(out[0], out[1], t[0], t[1])
	var us := pieces_color(c)
	return BB.and_bb(out[0], out[1], us[0], us[1])


func _update_blockers(c: int) -> void:
	## Upstream: update_blockers<c>
	var ksq := king_square(c)
	var blockers := [0, 0]
	var pins := [0, 0]
	var rook_ray := A.attacks_bb(T.ROOK, ksq, 0, 0)
	var snipers := BB.and_bb(
		rook_ray[0],
		rook_ray[1],
		BB.or_bb(
			BB.or_bb(pieces_type(T.ROOK)[0], pieces_type(T.ROOK)[1], pieces_type(T.CANNON)[0], pieces_type(T.CANNON)[1])[0],
			BB.or_bb(pieces_type(T.ROOK)[0], pieces_type(T.ROOK)[1], pieces_type(T.CANNON)[0], pieces_type(T.CANNON)[1])[1],
			pieces_type(T.KING)[0],
			pieces_type(T.KING)[1]
		)[0],
		BB.or_bb(
			BB.or_bb(pieces_type(T.ROOK)[0], pieces_type(T.ROOK)[1], pieces_type(T.CANNON)[0], pieces_type(T.CANNON)[1])[0],
			BB.or_bb(pieces_type(T.ROOK)[0], pieces_type(T.ROOK)[1], pieces_type(T.CANNON)[0], pieces_type(T.CANNON)[1])[1],
			pieces_type(T.KING)[0],
			pieces_type(T.KING)[1]
		)[1]
	)
	var kn_at := A.attacks_bb(T.KNIGHT, ksq, 0, 0)
	var kn_snip := BB.and_bb(kn_at[0], kn_at[1], pieces_type(T.KNIGHT)[0], pieces_type(T.KNIGHT)[1])
	snipers = BB.or_bb(snipers[0], snipers[1], kn_snip[0], kn_snip[1])
	var them := pieces_color(T.flip_color(c))
	snipers = BB.and_bb(snipers[0], snipers[1], them[0], them[1])

	var allp: Array = pieces_all()
	var cannons: Array = pieces_type(T.CANNON)
	var not_cannon: Array = BB.xor_bb(BB.from_squares_all()[0], BB.from_squares_all()[1], cannons[0], cannons[1])
	var snip_non_cannon: Array = BB.and_bb(snipers[0], snipers[1], not_cannon[0], not_cannon[1])
	var occupancy: Array = BB.xor_bb(allp[0], allp[1], snip_non_cannon[0], snip_non_cannon[1])

	var cur_lo: int = snipers[0]
	var cur_hi: int = snipers[1]
	var sq: int = BB.lsb(cur_lo, cur_hi)
	while sq >= 0:
		var is_cannon: bool = T.type_of(board[sq]) == T.CANNON
		var between: Array = A.between_bb(ksq, sq)
		var b: Array
		if is_cannon:
			var px: Array = BB.clear_bit(allp[0], allp[1], sq)
			b = BB.and_bb(between[0], between[1], px[0], px[1])
		else:
			b = BB.and_bb(between[0], between[1], occupancy[0], occupancy[1])
		if (b[0] != 0 or b[1] != 0) and (
			(not is_cannon and not BB.more_than_one(b[0], b[1]))
			or (is_cannon and BB.popcount(b[0], b[1]) == 2)
		):
			blockers = BB.or_bb(blockers[0], blockers[1], b[0], b[1])
			var us_pieces: Array = pieces_color(c)
			var pinned: Array = BB.and_bb(b[0], b[1], us_pieces[0], us_pieces[1])
			if pinned[0] != 0 or pinned[1] != 0:
				pins = BB.set_bit(pins[0], pins[1], sq)
		var cleared: Array = BB.clear_bit(cur_lo, cur_hi, sq)
		cur_lo = cleared[0]
		cur_hi = cleared[1]
		sq = BB.lsb(cur_lo, cur_hi)

	if c == T.COLOR_WHITE:
		stack.blockers_w_lo[st()] = blockers[0]
		stack.blockers_w_hi[st()] = blockers[1]
		stack.pinners_b_lo[st()] = pins[0]
		stack.pinners_b_hi[st()] = pins[1]
	else:
		stack.blockers_b_lo[st()] = blockers[0]
		stack.blockers_b_hi[st()] = blockers[1]
		stack.pinners_w_lo[st()] = pins[0]
		stack.pinners_w_hi[st()] = pins[1]


func _set_check_info() -> void:
	_update_blockers(T.COLOR_WHITE)
	_update_blockers(T.COLOR_BLACK)
	var ksq := king_square(T.flip_color(side_to_move))
	var our_king := king_square(side_to_move)
	# Upstream: attacks_bb<ROOK>(king) with no occupancy → PseudoAttacks (empty-board rays).
	# Any enemy cannon on the same file/rank forces the slow legal() path so hurdle
	# moves that create a cannon check (e.g. e6e5 into e5) are rejected.
	var rook_from_our_king := A.attacks_bb(T.ROOK, our_king, 0, 0)
	var their_cannons := pieces_color_type(T.flip_color(side_to_move), T.CANNON)
	var hollow := BB.and_bb(rook_from_our_king[0], rook_from_our_king[1], their_cannons[0], their_cannons[1])
	var chk := checkers()
	stack.need_full_check[st()] = 1 if (chk[0] != 0 or chk[1] != 0 or hollow[0] != 0 or hollow[1] != 0) else 0

	var i := st()
	var pto := A.pawn_attacks_to_bb(side_to_move, ksq)
	stack.check_sq_lo[T.PAWN][i] = pto[0]
	stack.check_sq_hi[T.PAWN][i] = pto[1]
	var kn := A.attacks_bb(T.KNIGHT_TO, ksq, pieces_all()[0], pieces_all()[1])
	stack.check_sq_lo[T.KNIGHT][i] = kn[0]
	stack.check_sq_hi[T.KNIGHT][i] = kn[1]
	var cn := A.attacks_bb(T.CANNON, ksq, pieces_all()[0], pieces_all()[1])
	stack.check_sq_lo[T.CANNON][i] = cn[0]
	stack.check_sq_hi[T.CANNON][i] = cn[1]
	var rk := A.attacks_bb(T.ROOK, ksq, pieces_all()[0], pieces_all()[1])
	stack.check_sq_lo[T.ROOK][i] = rk[0]
	stack.check_sq_hi[T.ROOK][i] = rk[1]
	for pt in [T.KING, T.ADVISOR, T.BISHOP]:
		stack.check_sq_lo[pt][i] = 0
		stack.check_sq_hi[pt][i] = 0

	var hollow_c: Array = BB.and_bb(rk[0], rk[1], pieces_color_type(side_to_move, T.CANNON)[0], pieces_color_type(side_to_move, T.CANNON)[1])
	var hc_lo: int = hollow_c[0]
	var hc_hi: int = hollow_c[1]
	var hsq: int = BB.lsb(hc_lo, hc_hi)
	while hsq >= 0:
		var disc: Array = A.between_bb(hsq, ksq)
		for pt2 in range(T.ROOK, T.KING):
			stack.check_sq_lo[pt2][i] |= disc[0]
			stack.check_sq_hi[pt2][i] |= disc[1]
		var cleared2: Array = BB.clear_bit(hc_lo, hc_hi, hsq)
		hc_lo = cleared2[0]
		hc_hi = cleared2[1]
		hsq = BB.lsb(hc_lo, hc_hi)


func _set_state() -> void:
	var i := st()
	stack.key[i] = 0
	stack.minor_piece_key[i] = 0
	stack.non_pawn_key_w[i] = 0
	stack.non_pawn_key_b[i] = 0
	stack.pawn_key[i] = Z.no_pawns_key()
	stack.major_material_w[i] = 0
	stack.major_material_b[i] = 0
	var chk := checkers_to(T.flip_color(side_to_move), king_square(side_to_move))
	stack.checkers_lo[i] = chk[0]
	stack.checkers_hi[i] = chk[1]
	stack.move[i] = T.MOVE_NONE
	_set_check_info()
	var allp: Array = pieces_all()
	var lo: int = allp[0]
	var hi: int = allp[1]
	var s: int = BB.lsb(lo, hi)
	while s >= 0:
		var pc: int = board[s]
		var pt: int = T.type_of(pc)
		var c: int = T.color_of(pc)
		stack.key[i] ^= Z.psq_key(pc, s)
		if pt == T.PAWN:
			stack.pawn_key[i] ^= Z.psq_key(pc, s)
		else:
			if c == T.COLOR_WHITE:
				stack.non_pawn_key_w[i] ^= Z.psq_key(pc, s)
			else:
				stack.non_pawn_key_b[i] ^= Z.psq_key(pc, s)
			# Upstream: if (pt != KING && (pt & 1)) major; if != ROOK minor
			if pt != T.KING and (pt & 1) != 0:
				if c == T.COLOR_WHITE:
					stack.major_material_w[i] += T.PIECE_VALUE[pc]
				else:
					stack.major_material_b[i] += T.PIECE_VALUE[pc]
				if pt != T.ROOK:
					stack.minor_piece_key[i] ^= Z.psq_key(pc, s)
		var cleared := BB.clear_bit(lo, hi, s)
		lo = cleared[0]
		hi = cleared[1]
		s = BB.lsb(lo, hi)
	if side_to_move == T.COLOR_BLACK:
		stack.key[i] ^= Z.side_key()


func capture(m: int) -> bool:
	return not empty_sq(T.to_sq(m))


func moved_piece(m: int) -> int:
	return board[T.from_sq(m)]


func legal(m: int) -> bool:
	## Upstream: Position::legal
	var us := side_to_move
	var frm := T.from_sq(m)
	var to := T.to_sq(m)
	var occ := BB.clear_bit(pieces_all()[0], pieces_all()[1], frm)
	occ = BB.set_bit(occ[0], occ[1], to)
	if T.type_of(board[frm]) == T.KING:
		var att := checkers_to(T.flip_color(us), to, occ[0], occ[1])
		return att[0] == 0 and att[1] == 0
	var ksq := king_square(us)
	if stack.need_full_check[st()] == 0:
		var blockers := blockers_for_king(us)
		if not BB.test_bit(blockers[0], blockers[1], frm) or (
			((T.type_of(board[frm]) != T.CANNON) or not capture(m)) and A.aligned(frm, to, ksq)
		):
			return true
	var chk := checkers_to(T.flip_color(us), ksq, occ[0], occ[1])
	chk = BB.clear_bit(chk[0], chk[1], to)
	return chk[0] == 0 and chk[1] == 0


func pseudo_legal(m: int) -> bool:
	## Upstream: Position::pseudo_legal
	if not T.move_is_ok(m):
		return false
	var frm := T.from_sq(m)
	var to := T.to_sq(m)
	var pc: int = board[frm]
	if pc == T.NO_PIECE or T.color_of(pc) != side_to_move:
		return false
	if board[to] != T.NO_PIECE and T.color_of(board[to]) == side_to_move:
		return false
	var pt: int = T.type_of(pc)
	var occ := pieces_all()
	var attacks: Array
	if pt == T.PAWN:
		attacks = A.attacks_bb_pawn(side_to_move, frm)
	elif pt == T.CANNON:
		# Upstream: CANNON quiet uses rook attacks; capture uses cannon attacks
		if board[to] != T.NO_PIECE:
			attacks = A.attacks_bb(T.CANNON, frm, occ[0], occ[1])
		else:
			attacks = A.attacks_bb(T.ROOK, frm, occ[0], occ[1])
	else:
		attacks = A.attacks_bb(pt, frm, occ[0], occ[1])
	if not BB.test_bit(attacks[0], attacks[1], to):
		return false
	# Upstream: if checkers(), require MoveList<EVASIONS>.contains(m)
	var chk := checkers()
	if chk[0] != 0 or chk[1] != 0:
		var buf := PackedInt32Array()
		buf.resize(T.MAX_MOVES)
		var n: int = MG.generate(self, MG.GEN_EVASIONS, buf)
		for i in range(n):
			if buf[i] == m:
				return true
		return false
	return true


func gives_check(m: int) -> bool:
	## Upstream: Position::gives_check (incl. cannon ray_pass_bb special case)
	var frm := T.from_sq(m)
	var to := T.to_sq(m)
	var ksq: int = king_square(T.flip_color(side_to_move))
	var pt: int = T.type_of(board[frm])
	var i := st()

	# Direct check — hollow-cannon capture beyond self uses rook check_squares + ray_pass_bb
	if (
		pt == T.CANNON
		and BB.test_bit(stack.check_sq_lo[T.ROOK][i], stack.check_sq_hi[T.ROOK][i], frm)
		and A.aligned(frm, to, ksq)
	):
		if capture(m):
			var ray: Array = A.ray_pass_bb(ksq, frm)
			if BB.test_bit(ray[0], ray[1], to):
				return true
	elif BB.test_bit(stack.check_sq_lo[pt][i], stack.check_sq_hi[pt][i], to):
		return true

	# Discovered check — Upstream: blockers_for_king(~us) & from
	var blockers: Array = blockers_for_king(T.flip_color(side_to_move))
	if BB.test_bit(blockers[0], blockers[1], frm) and (
		not A.aligned(frm, to, ksq) or capture(m)
	):
		return true
	return false


func do_move(m: int) -> void:
	## Upstream do_move simplified (no TT/Dirties/NNUE).
	# Bloom filter: ++filter[old key] before transitioning (Upstream).
	var prev_key: int = stack.key[st()]
	var prev_slot: int = prev_key & ((1 << 14) - 1)
	filter[prev_slot] = mini(int(filter[prev_slot]) + 1, 255)

	var gives := gives_check(m)
	var us := side_to_move
	var them := T.flip_color(us)
	var frm := T.from_sq(m)
	var to := T.to_sq(m)
	var pc: int = board[frm]
	var captured: int = board[to]

	var prev := st()
	var nxt := prev + 1
	assert(nxt < T.MAX_PLY)
	stack.copy_copied_fields(prev, nxt)
	stack.ply = nxt
	stack.move[nxt] = m
	stack.captured_piece[nxt] = captured

	var k: int = stack.key[prev] ^ Z.side_key()

	# Upstream: Position::do_move — gamePly / check10 / rule60
	# Clamp to 10 checks per side; capture resets below. Pawn moves do NOT reset rule60.
	game_ply += 1
	var enter_counters := true
	if gives:
		if us == T.COLOR_WHITE:
			stack.check10_w[nxt] = stack.check10_w[nxt] + 1
			enter_counters = stack.check10_w[nxt] <= 10
		else:
			stack.check10_b[nxt] = stack.check10_b[nxt] + 1
			enter_counters = stack.check10_b[nxt] <= 10
	if enter_counters:
		var opp_c10: int = (
			stack.check10_b[nxt] if us == T.COLOR_WHITE else stack.check10_w[nxt]
		)
		var prev_in_check: bool = (
			stack.checkers_lo[prev] != 0 or stack.checkers_hi[prev] != 0
		)
		if opp_c10 > 10 and prev_in_check:
			# Upstream: ++st->check10[~sideToMove] when opponent already over 10
			if us == T.COLOR_WHITE:
				stack.check10_b[nxt] = stack.check10_b[nxt] + 1
			else:
				stack.check10_w[nxt] = stack.check10_w[nxt] + 1
		else:
			stack.rule60[nxt] = stack.rule60[nxt] + 1
	stack.plies_from_null[nxt] = stack.plies_from_null[prev] + 1

	if captured != T.NO_PIECE:
		_remove_piece(to)
		k ^= Z.psq_key(captured, to)
		var cpt: int = T.type_of(captured)
		if cpt == T.PAWN:
			stack.pawn_key[nxt] ^= Z.psq_key(captured, to)
		else:
			if them == T.COLOR_WHITE:
				stack.non_pawn_key_w[nxt] ^= Z.psq_key(captured, to)
			else:
				stack.non_pawn_key_b[nxt] ^= Z.psq_key(captured, to)
			if cpt != T.KING and (cpt & 1) != 0:
				if them == T.COLOR_WHITE:
					stack.major_material_w[nxt] -= T.PIECE_VALUE[captured]
				else:
					stack.major_material_b[nxt] -= T.PIECE_VALUE[captured]
				if cpt != T.ROOK:
					stack.minor_piece_key[nxt] ^= Z.psq_key(captured, to)
		# Upstream: st->check10[WHITE] = st->check10[BLACK] = st->rule60 = 0
		stack.check10_w[nxt] = 0
		stack.check10_b[nxt] = 0
		stack.rule60[nxt] = 0

	_move_piece(frm, to)
	k ^= Z.psq_key(pc, frm) ^ Z.psq_key(pc, to)
	if T.type_of(pc) == T.PAWN:
		stack.pawn_key[nxt] ^= Z.psq_key(pc, frm) ^ Z.psq_key(pc, to)
	else:
		if us == T.COLOR_WHITE:
			stack.non_pawn_key_w[nxt] ^= Z.psq_key(pc, frm) ^ Z.psq_key(pc, to)
		else:
			stack.non_pawn_key_b[nxt] ^= Z.psq_key(pc, frm) ^ Z.psq_key(pc, to)
		if T.type_of(pc) != T.KING and (T.type_of(pc) & 1) != 0 and T.type_of(pc) != T.ROOK:
			stack.minor_piece_key[nxt] ^= Z.psq_key(pc, frm) ^ Z.psq_key(pc, to)

	side_to_move = them
	stack.key[nxt] = k
	var chk := checkers_to(us, king_square(them))
	stack.checkers_lo[nxt] = chk[0]
	stack.checkers_hi[nxt] = chk[1]
	_set_check_info()


func undo_move(m: int) -> void:
	var frm := T.from_sq(m)
	var to := T.to_sq(m)
	var captured: int = stack.captured_piece[st()]
	side_to_move = T.flip_color(side_to_move)
	game_ply -= 1
	_move_piece(to, frm)
	if captured != T.NO_PIECE:
		_put_piece(to, captured)
	stack.ply -= 1
	# Bloom filter: --filter[restored key] (Upstream)
	var slot: int = stack.key[st()] & ((1 << 14) - 1)
	if filter[slot] > 0:
		filter[slot] -= 1


func do_null_move() -> void:
	## Upstream: Position::do_null_move — does NOT increment gamePly or rule60
	var prev_key: int = stack.key[st()]
	var prev_slot: int = prev_key & ((1 << 14) - 1)
	filter[prev_slot] = mini(int(filter[prev_slot]) + 1, 255)

	var prev := st()
	var nxt := prev + 1
	stack.copy_copied_fields(prev, nxt)
	stack.ply = nxt
	stack.key[nxt] = stack.key[prev] ^ Z.side_key()
	stack.move[nxt] = T.MOVE_NULL
	stack.captured_piece[nxt] = T.NO_PIECE
	# rule60 stays as copied; game_ply unchanged
	stack.plies_from_null[nxt] = 0
	side_to_move = T.flip_color(side_to_move)
	stack.checkers_lo[nxt] = 0
	stack.checkers_hi[nxt] = 0
	_set_check_info()


func undo_null_move() -> void:
	## Upstream: Position::undo_null_move — gamePly untouched
	side_to_move = T.flip_color(side_to_move)
	stack.ply -= 1
	var slot: int = stack.key[st()] & ((1 << 14) - 1)
	if filter[slot] > 0:
		filter[slot] -= 1


func see_ge(m: int, threshold: int = 0) -> bool:
	## Upstream: Position::see_ge — Static Exchange Evaluation >= threshold.
	var frm: int = T.from_sq(m)
	var to: int = T.to_sq(m)
	var swap: int = T.PIECE_VALUE[board[to]] - threshold
	if swap < 0:
		return false
	swap = T.PIECE_VALUE[board[frm]] - swap
	if swap <= 0:
		return true

	var occupied: Array = BB.xor_bb(
		pieces_all()[0],
		pieces_all()[1],
		BB.from_square(frm)[0],
		BB.from_square(frm)[1]
	)
	occupied = BB.xor_bb(occupied[0], occupied[1], BB.from_square(to)[0], BB.from_square(to)[1])
	var stm: int = side_to_move
	var attackers: Array = attackers_to(to, occupied[0], occupied[1])

	var kings: Array = pieces_type(T.KING)
	var king_attacks: bool = (
		BB.and_bb(attackers[0], attackers[1], kings[0], kings[1])[0] != 0
		or BB.and_bb(attackers[0], attackers[1], kings[0], kings[1])[1] != 0
	)
	if king_attacks:
		var rook_ray: Array = A.attacks_bb(T.ROOK, to, occupied[0], occupied[1])
		attackers = BB.or_bb(
			attackers[0],
			attackers[1],
			BB.and_bb(rook_ray[0], rook_ray[1], kings[0], kings[1])[0],
			BB.and_bb(rook_ray[0], rook_ray[1], kings[0], kings[1])[1]
		)

	var cannons_all: Array = pieces_type(T.CANNON)
	var non_cannons: Array = BB.and_bb(
		attackers[0],
		attackers[1],
		BB.xor_bb(BB.from_squares_all()[0], BB.from_squares_all()[1], cannons_all[0], cannons_all[1])[0],
		BB.xor_bb(BB.from_squares_all()[0], BB.from_squares_all()[1], cannons_all[0], cannons_all[1])[1]
	)
	var cannons: Array = BB.and_bb(attackers[0], attackers[1], cannons_all[0], cannons_all[1])
	var res: int = 1

	while true:
		stm = T.flip_color(stm)
		attackers = BB.and_bb(attackers[0], attackers[1], occupied[0], occupied[1])
		var stm_pieces: Array = pieces_color(stm)
		var stm_attackers: Array = BB.and_bb(attackers[0], attackers[1], stm_pieces[0], stm_pieces[1])
		if stm_attackers[0] == 0 and stm_attackers[1] == 0:
			break

		var pin_side: int = T.flip_color(stm)
		var pins: Array = pinners(pin_side)
		if BB.and_bb(pins[0], pins[1], occupied[0], occupied[1])[0] != 0 \
				or BB.and_bb(pins[0], pins[1], occupied[0], occupied[1])[1] != 0:
			var blockers: Array = blockers_for_king(stm)
			stm_attackers = BB.and_bb(
				stm_attackers[0],
				stm_attackers[1],
				BB.xor_bb(BB.from_squares_all()[0], BB.from_squares_all()[1], blockers[0], blockers[1])[0],
				BB.xor_bb(BB.from_squares_all()[0], BB.from_squares_all()[1], blockers[0], blockers[1])[1]
			)
			if stm_attackers[0] == 0 and stm_attackers[1] == 0:
				break

		res ^= 1
		var bb: Array
		bb = BB.and_bb(stm_attackers[0], stm_attackers[1], pieces_type(T.PAWN)[0], pieces_type(T.PAWN)[1])
		if bb[0] != 0 or bb[1] != 0:
			swap = T.PAWN_VALUE - swap
			if swap < res:
				break
			occupied = _xor_lsb(occupied, bb)
			non_cannons = _see_add_rook_line(non_cannons, to, occupied, king_attacks)
			cannons = BB.and_bb(
				A.attacks_bb(T.CANNON, to, occupied[0], occupied[1])[0],
				A.attacks_bb(T.CANNON, to, occupied[0], occupied[1])[1],
				cannons_all[0],
				cannons_all[1]
			)
			attackers = BB.or_bb(non_cannons[0], non_cannons[1], cannons[0], cannons[1])
			continue

		bb = BB.and_bb(stm_attackers[0], stm_attackers[1], pieces_type(T.BISHOP)[0], pieces_type(T.BISHOP)[1])
		if bb[0] != 0 or bb[1] != 0:
			swap = T.BISHOP_VALUE - swap
			if swap < res:
				break
			occupied = _xor_lsb(occupied, bb)
			continue

		bb = BB.and_bb(stm_attackers[0], stm_attackers[1], pieces_type(T.ADVISOR)[0], pieces_type(T.ADVISOR)[1])
		if bb[0] != 0 or bb[1] != 0:
			swap = T.ADVISOR_VALUE - swap
			if swap < res:
				break
			occupied = _xor_lsb(occupied, bb)
			var kn: Array = A.attacks_bb(T.KNIGHT_TO, to, occupied[0], occupied[1])
			non_cannons = BB.or_bb(
				non_cannons[0],
				non_cannons[1],
				BB.and_bb(kn[0], kn[1], pieces_type(T.KNIGHT)[0], pieces_type(T.KNIGHT)[1])[0],
				BB.and_bb(kn[0], kn[1], pieces_type(T.KNIGHT)[0], pieces_type(T.KNIGHT)[1])[1]
			)
			attackers = BB.or_bb(non_cannons[0], non_cannons[1], cannons[0], cannons[1])
			continue

		bb = BB.and_bb(stm_attackers[0], stm_attackers[1], pieces_type(T.CANNON)[0], pieces_type(T.CANNON)[1])
		if bb[0] != 0 or bb[1] != 0:
			swap = T.CANNON_VALUE - swap
			if swap < res:
				break
			occupied = _xor_lsb(occupied, bb)
			cannons = BB.and_bb(
				A.attacks_bb(T.CANNON, to, occupied[0], occupied[1])[0],
				A.attacks_bb(T.CANNON, to, occupied[0], occupied[1])[1],
				cannons_all[0],
				cannons_all[1]
			)
			attackers = BB.or_bb(non_cannons[0], non_cannons[1], cannons[0], cannons[1])
			continue

		bb = BB.and_bb(stm_attackers[0], stm_attackers[1], pieces_type(T.KNIGHT)[0], pieces_type(T.KNIGHT)[1])
		if bb[0] != 0 or bb[1] != 0:
			swap = T.KNIGHT_VALUE - swap
			if swap < res:
				break
			occupied = _xor_lsb(occupied, bb)
			continue

		bb = BB.and_bb(stm_attackers[0], stm_attackers[1], pieces_type(T.ROOK)[0], pieces_type(T.ROOK)[1])
		if bb[0] != 0 or bb[1] != 0:
			swap = T.ROOK_VALUE - swap
			occupied = _xor_lsb(occupied, bb)
			non_cannons = _see_add_rook_line(non_cannons, to, occupied, king_attacks)
			cannons = BB.and_bb(
				A.attacks_bb(T.CANNON, to, occupied[0], occupied[1])[0],
				A.attacks_bb(T.CANNON, to, occupied[0], occupied[1])[1],
				cannons_all[0],
				cannons_all[1]
			)
			attackers = BB.or_bb(non_cannons[0], non_cannons[1], cannons[0], cannons[1])
			continue

		# KING — if opponent still has attackers, reverse
		var opp: Array = BB.and_bb(
			attackers[0],
			attackers[1],
			BB.xor_bb(
				BB.from_squares_all()[0],
				BB.from_squares_all()[1],
				pieces_color(stm)[0],
				pieces_color(stm)[1]
			)[0],
			BB.xor_bb(
				BB.from_squares_all()[0],
				BB.from_squares_all()[1],
				pieces_color(stm)[0],
				pieces_color(stm)[1]
			)[1]
		)
		if opp[0] != 0 or opp[1] != 0:
			return (res ^ 1) != 0
		return res != 0

	return res != 0


func _xor_lsb(occupied: Array, bb: Array) -> Array:
	var s: int = BB.lsb(bb[0], bb[1])
	return BB.xor_bb(occupied[0], occupied[1], BB.from_square(s)[0], BB.from_square(s)[1])


func _see_add_rook_line(non_cannons: Array, to: int, occupied: Array, king_attacks: bool) -> Array:
	var rook_ray: Array = A.attacks_bb(T.ROOK, to, occupied[0], occupied[1])
	var line_pieces: Array
	if king_attacks:
		line_pieces = BB.or_bb(
			pieces_type(T.KING)[0],
			pieces_type(T.KING)[1],
			pieces_type(T.ROOK)[0],
			pieces_type(T.ROOK)[1]
		)
	else:
		line_pieces = pieces_type(T.ROOK)
	return BB.or_bb(
		non_cannons[0],
		non_cannons[1],
		BB.and_bb(rook_ray[0], rook_ray[1], line_pieces[0], line_pieces[1])[0],
		BB.and_bb(rook_ray[0], rook_ray[1], line_pieces[0], line_pieces[1])[1]
	)