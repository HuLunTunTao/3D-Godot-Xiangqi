class_name PikafishRules
extends RefCounted

## Upstream: Pikafish 2c5c998c, src/position.cpp
## Position::rule_judge / detect_chases / chased / chase_legal

const T = preload("res://addons/pikafish/core/types.gd")
const BB = preload("res://addons/pikafish/core/bitboard.gd")
const A = preload("res://addons/pikafish/core/attacks.gd")
const MG = preload("res://addons/pikafish/core/movegen.gd")


## Returns {"claimed": bool, "value": int}.
## Upstream out-param: claimed=true → hard claim; claimed=false with value!=VALUE_NONE → soft
## 2-fold mate/chase (search clamps alpha/beta). rule60 / insufficient still override after loop.
static func rule_judge(pos: RefCounted, ply: int = 0) -> Dictionary:
	## Upstream: Position::rule_judge
	var st_i: int = pos.st()
	var stack = pos.stack
	var end: int = mini(
		stack.rule60[st_i]
		+ maxi(0, stack.check10_w[st_i] - 10)
		+ maxi(0, stack.check10_b[st_i] - 10),
		stack.plies_from_null[st_i]
	)
	var key_now: int = stack.key[st_i]
	var filter_slot: int = key_now & ((1 << 14) - 1)
	# Upstream Value& result left set when returning false after a 2-fold mate/chase.
	var soft_value: int = T.VALUE_NONE

	if end >= 4 and pos.filter[filter_slot] >= 1:
		var cnt := 0
		var stp: int = st_i - 2
		var check_them: bool = _has_checkers(pos, st_i) and _has_checkers(pos, stp)
		var check_us: bool = _has_checkers(pos, st_i - 1) and _has_checkers(pos, stp - 1)
		var i := 4
		while i <= end:
			stp -= 2
			if stp < 0:
				break
			check_them = check_them and _has_checkers(pos, stp)
			if stack.key[stp] == key_now:
				cnt += 1
				if cnt == 2 or ply > i:
					var result_value: int
					if not check_them and not check_us:
						var rollback = pos.clone_for_rollback()
						result_value = detect_chases(rollback, i, ply)
					else:
						if not check_us:
							result_value = T.mate_in(ply)
						elif not check_them:
							result_value = T.mated_in(ply)
						else:
							result_value = T.VALUE_DRAW

					if result_value == T.VALUE_DRAW or cnt == 2:
						return {"claimed": true, "value": result_value}

					# Non-draw 2-fold (mate/chase): may hard-claim or leave soft result.
					soft_value = result_value
					if pos.filter[filter_slot] <= 1:
						if stack.rule60[st_i] < 120 and st_i >= 1 and stp >= 1 \
								and stack.key[st_i - 1] == stack.key[stp - 1]:
							var prev: int = st_i - 1
							var ok := true
							while prev != stp:
								prev -= 1
								if prev < stp:
									ok = false
									break
								var pk: int = stack.key[prev] & ((1 << 14) - 1)
								if pos.filter[pk] > 1:
									ok = false
									break
							if ok and prev == stp:
								return {"claimed": true, "value": result_value}
						break
			if i + 1 <= end and stp >= 1:
				check_us = check_us and _has_checkers(pos, stp - 1)
			i += 2

	# 60 move rule (120 half-moves)
	if stack.rule60[st_i] >= 120:
		var buf := PackedInt32Array()
		buf.resize(T.MAX_MOVES)
		var n: int = MG.generate(pos, MG.GEN_LEGAL, buf)
		var v: int = T.VALUE_DRAW if n > 0 else T.mated_in(ply)
		return {"claimed": true, "value": v}

	# Insufficient material
	if pos.count_pt(T.PAWN) == 0:
		var level: int = _insufficient_draw_level(pos)
		# 0=NO_DRAW, 1=DIRECT_DRAW, 2=MATE_DRAW
		if level != 0:
			if level == 2:
				var buf2 := PackedInt32Array()
				buf2.resize(T.MAX_MOVES)
				var n2: int = MG.generate(pos, MG.GEN_LEGAL, buf2)
				if n2 == 0:
					return {"claimed": true, "value": T.mated_in(ply)}
				for mi in range(n2):
					pos.do_move(buf2[mi])
					var buf3 := PackedInt32Array()
					buf3.resize(T.MAX_MOVES)
					var n3: int = MG.generate(pos, MG.GEN_LEGAL, buf3)
					pos.undo_move(buf2[mi])
					if n3 == 0:
						# Upstream returns false without clearing a prior soft result.
						return {"claimed": false, "value": soft_value}
			return {"claimed": true, "value": T.VALUE_DRAW}

	return {"claimed": false, "value": soft_value}


static func _has_checkers(pos: RefCounted, idx: int) -> bool:
	if idx < 0:
		return false
	return pos.stack.checkers_lo[idx] != 0 or pos.stack.checkers_hi[idx] != 0


static func _insufficient_draw_level(pos: RefCounted) -> int:
	## Upstream rule_judge insufficient-material lambda. 0/1/2 = NO/DIRECT/MATE_DRAW.
	var majors: int = pos.major_material()
	if majors == 0:
		return 1
	if majors == T.CANNON_VALUE:
		var cannon_side: int = (
			T.COLOR_WHITE if pos.major_material(T.COLOR_WHITE) == T.CANNON_VALUE else T.COLOR_BLACK
		)
		if pos.count_pt(T.ADVISOR, cannon_side) == 0:
			var opp: int = T.flip_color(cannon_side)
			var opp_adv: int = pos.count_pt(T.ADVISOR, opp)
			if opp_adv == 0:
				return 1
			if opp_adv == 1:
				return 1 if pos.count_pt(T.BISHOP, cannon_side) == 0 else 2
			if pos.count_pt(T.BISHOP, cannon_side) == 0:
				return 2
	if (
		pos.major_material(T.COLOR_WHITE) == T.CANNON_VALUE
		and pos.major_material(T.COLOR_BLACK) == T.CANNON_VALUE
		and pos.count_pt(T.ADVISOR) == 0
	):
		return 1 if pos.count_pt(T.BISHOP) == 0 else 2
	return 0


static func detect_chases(pos: RefCounted, d: int, ply: int = 0) -> int:
	## Upstream: Position::detect_chases — mutates pos (rollback clone).
	var white_id := 0
	var black_id := 0
	for s in range(T.SQUARE_NB):
		var pc: int = pos.board[s]
		if pc != T.NO_PIECE:
			if T.color_of(pc) == T.COLOR_WHITE:
				pos.id_board[s] = white_id
				white_id += 1
			else:
				pos.id_board[s] = black_id
				black_id += 1
		else:
			pos.id_board[s] = 0

	var us: int = pos.side_to_move
	var them: int = T.flip_color(us)
	var chase_w: int = 0xFFFF
	var chase_b: int = 0xFFFF

	for _step in range(d):
		var chk: Array = pos.checkers()
		if chk[0] != 0 or chk[1] != 0:
			return T.VALUE_DRAW
		var stm: int = pos.side_to_move
		var chase_them: int = chase_b if stm == T.COLOR_WHITE else chase_w
		var chase_us: int = chase_w if stm == T.COLOR_WHITE else chase_b
		if chase_them == 0:
			if chase_us == 0:
				break
			_undo_one_for_chase(pos)
		else:
			var after: int = chased(pos, T.flip_color(stm))
			_undo_one_for_chase(pos)
			# After undo, side_to_move is previous; chase[sideToMove] uses that.
			var stm2: int = pos.side_to_move
			var before: int = chased(pos, stm2)
			var masked: int = after & ~before
			if stm2 == T.COLOR_WHITE:
				chase_w &= masked
			else:
				chase_b &= masked

	var chase_us_f: int = chase_w if us == T.COLOR_WHITE else chase_b
	var chase_them_f: int = chase_b if us == T.COLOR_WHITE else chase_w
	var us_chasing: bool = chase_us_f != 0
	var them_chasing: bool = chase_them_f != 0
	if us_chasing != them_chasing:
		return T.mated_in(ply) if us_chasing else T.mate_in(ply)
	return T.VALUE_DRAW


static func _undo_one_for_chase(pos: RefCounted) -> void:
	var i: int = pos.st()
	var m: int = pos.stack.move[i]
	var captured: int = pos.stack.captured_piece[i]
	pos.undo_move_light(m, captured, 0)
	pos.stack.ply = i - 1


static func chase_legal(pos: RefCounted, m: int) -> bool:
	## Upstream: Position::chase_legal
	var us: int = pos.side_to_move
	var frm: int = T.from_sq(m)
	var to: int = T.to_sq(m)
	var occ: Array = BB.clear_bit(pos.pieces_all()[0], pos.pieces_all()[1], frm)
	occ = BB.set_bit(occ[0], occ[1], to)
	if T.type_of(pos.board[frm]) == T.KING:
		var att: Array = pos.checkers_to(T.flip_color(us), to, occ[0], occ[1])
		return att[0] == 0 and att[1] == 0
	var ksq: int = pos.king_square(us)
	var chk: Array = pos.checkers_to(T.flip_color(us), ksq, occ[0], occ[1])
	chk = BB.clear_bit(chk[0], chk[1], to)
	return chk[0] == 0 and chk[1] == 0


static func chased(pos: RefCounted, c: int) -> int:
	## Upstream: Position::chased — returns u16 bitset of chased piece ids.
	var chase: int = 0
	# std::swap(c, sideToMove)
	var saved_stm: int = pos.side_to_move
	pos.side_to_move = c

	var stm: int = pos.side_to_move
	var them: int = T.flip_color(stm)
	# King and pawn can legally perpetual chase — exclude them from attackers
	var attackers: Array = pos.pieces_color(stm)
	var king_pawn: Array = BB.or_bb(
		pos.pieces_color_type(stm, T.KING)[0],
		pos.pieces_color_type(stm, T.KING)[1],
		pos.pieces_color_type(stm, T.PAWN)[0],
		pos.pieces_color_type(stm, T.PAWN)[1]
	)
	attackers = BB.xor_bb(attackers[0], attackers[1], king_pawn[0], king_pawn[1])

	var cur_lo: int = attackers[0]
	var cur_hi: int = attackers[1]
	var frm: int = BB.lsb(cur_lo, cur_hi)
	while frm >= 0:
		var attacker_type: int = T.type_of(pos.board[frm])
		var attacks: Array = A.attacks_bb(attacker_type, frm, pos.pieces_all()[0], pos.pieces_all()[1])
		var blockers: Array = pos.blockers_for_king(stm)
		if BB.test_bit(blockers[0], blockers[1], frm):
			# attacks &= pinners(~sideToMove) & ~pieces(KING);
			var pins: Array = pos.pinners(them)
			var kings: Array = pos.pieces_type(T.KING)
			var pin_no_king: Array = BB.and_bb(
				pins[0],
				pins[1],
				BB.xor_bb(BB.from_squares_all()[0], BB.from_squares_all()[1], kings[0], kings[1])[0],
				BB.xor_bb(BB.from_squares_all()[0], BB.from_squares_all()[1], kings[0], kings[1])[1]
			)
			attacks = BB.and_bb(attacks[0], attacks[1], pin_no_king[0], pin_no_king[1])
		else:
			# Restrict: opp pieces except king/unpromoted pawns, plus promoted pawns
			var half: Array = BB.half_bb(stm)
			var opp: Array = pos.pieces_color(them)
			var opp_king_pawn: Array = BB.or_bb(
				pos.pieces_color_type(them, T.KING)[0],
				pos.pieces_color_type(them, T.KING)[1],
				pos.pieces_color_type(them, T.PAWN)[0],
				pos.pieces_color_type(them, T.PAWN)[1]
			)
			var non_kp: Array = BB.xor_bb(opp[0], opp[1], opp_king_pawn[0], opp_king_pawn[1])
			var promo_pawns: Array = BB.and_bb(
				pos.pieces_color_type(them, T.PAWN)[0],
				pos.pieces_color_type(them, T.PAWN)[1],
				half[0],
				half[1]
			)
			var targets: Array = BB.or_bb(non_kp[0], non_kp[1], promo_pawns[0], promo_pawns[1])
			attacks = BB.and_bb(attacks[0], attacks[1], targets[0], targets[1])

		var at_lo: int = attacks[0]
		var at_hi: int = attacks[1]
		var to: int = BB.lsb(at_lo, at_hi)
		while to >= 0:
			var m: int = T.make_move(frm, to)
			if chase_legal(pos, m):
				var victim_type: int = T.type_of(pos.board[to])
				if (attacker_type == T.KNIGHT or attacker_type == T.CANNON) and victim_type == T.ROOK:
					chase |= 1 << pos.id_board[to]
				elif (attacker_type == T.ADVISOR or attacker_type == T.BISHOP) and (victim_type & 1) != 0:
					chase |= 1 << pos.id_board[to]
				else:
					var true_chase := true
					var light: Array = pos.do_move_light(m)
					var recaptures: Array = pos.attackers_to(to)
					recaptures = BB.and_bb(
						recaptures[0],
						recaptures[1],
						pos.pieces_color(pos.side_to_move)[0],
						pos.pieces_color(pos.side_to_move)[1]
					)
					var r_lo: int = recaptures[0]
					var r_hi: int = recaptures[1]
					var s: int = BB.lsb(r_lo, r_hi)
					while s >= 0:
						if chase_legal(pos, T.make_move(s, to)):
							true_chase = false
							break
						var clr: Array = BB.clear_bit(r_lo, r_hi, s)
						r_lo = clr[0]
						r_hi = clr[1]
						s = BB.lsb(r_lo, r_hi)
					pos.undo_move_light(m, light[0], light[1])

					if true_chase:
						if attacker_type == T.type_of(pos.board[to]):
							pos.side_to_move = T.flip_color(pos.side_to_move)
							var between: Array = A.between_bb(frm, to)
							between = BB.xor_bb(between[0], between[1], BB.from_square(to)[0], BB.from_square(to)[1])
							var blocked_knight: bool = (
								attacker_type == T.KNIGHT
								and (
									BB.and_bb(between[0], between[1], pos.pieces_all()[0], pos.pieces_all()[1])[0] != 0
									or BB.and_bb(between[0], between[1], pos.pieces_all()[0], pos.pieces_all()[1])[1] != 0
								)
							)
							if blocked_knight or not chase_legal(pos, T.make_move(to, frm)):
								chase |= 1 << pos.id_board[to]
							pos.side_to_move = T.flip_color(pos.side_to_move)
						else:
							chase |= 1 << pos.id_board[to]
			var clr2: Array = BB.clear_bit(at_lo, at_hi, to)
			at_lo = clr2[0]
			at_hi = clr2[1]
			to = BB.lsb(at_lo, at_hi)

		var clr_a: Array = BB.clear_bit(cur_lo, cur_hi, frm)
		cur_lo = clr_a[0]
		cur_hi = clr_a[1]
		frm = BB.lsb(cur_lo, cur_hi)

	pos.side_to_move = saved_stm
	return chase & 0xFFFF
