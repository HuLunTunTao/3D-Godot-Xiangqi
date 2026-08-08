class_name PikafishMovePicker
extends RefCounted

## Upstream: Pikafish 2c5c998c, src/movepick.h / movepick.cpp
## Stage-based move emission. Moves + scores in PackedArray SoA (no Dictionary hot path).

const T = preload("res://addons/pikafish/core/types.gd")
const BB = preload("res://addons/pikafish/core/bitboard.gd")
const A = preload("res://addons/pikafish/core/attacks.gd")
const MG = preload("res://addons/pikafish/core/movegen.gd")
const Hist = preload("res://addons/pikafish/search/history.gd")

# Stages — Upstream: movepick.cpp anonymous enum Stages
const MAIN_TT := 0
const CAPTURE_INIT := 1
const GOOD_CAPTURE := 2
const QUIET_INIT := 3
const GOOD_QUIET := 4
const BAD_CAPTURE := 5
const BAD_QUIET := 6
const EVASION_TT := 7
const EVASION_INIT := 8
const EVASION := 9
const PROBCUT_TT := 10
const PROBCUT_INIT := 11
const PROBCUT := 12
const QSEARCH_TT := 13
const QCAPTURE_INIT := 14
const QCAPTURE := 15

var pos
var history  ## PikafishHistory or null
var tt_move: int = T.MOVE_NONE
var depth: int = 0
var ply: int = 0
var threshold: int = 0
var stage: int = MAIN_TT
var skip_quiets: bool = false
var _probcut: bool = false
## Continuation history bases for (ss-1)..(ss-6); length 6. -1 = unused/zero.
var cont_bases: PackedInt32Array = PackedInt32Array()

var moves: PackedInt32Array = PackedInt32Array()
var values: PackedInt32Array = PackedInt32Array()
var cur: int = 0
var end_cur: int = 0
var end_bad_captures: int = 0
var end_bad_quiets: int = 0


func _init() -> void:
	moves.resize(T.MAX_MOVES)
	values.resize(T.MAX_MOVES)
	cont_bases.resize(6)
	cont_bases.fill(-1)


## Main search / qsearch constructor.
## Upstream: MovePicker(Position, Move, Depth, Butterfly*, LowPly*, Capture*, PieceTo**, Shared*, ply)
func init_main(
	p, ttm: int, d: int, hist, pl: int = 0, cont: PackedInt32Array = PackedInt32Array()
) -> void:
	pos = p
	history = hist
	tt_move = ttm
	depth = d
	ply = pl
	threshold = 0
	skip_quiets = false
	_probcut = false
	cur = 0
	end_cur = 0
	end_bad_captures = 0
	end_bad_quiets = 0
	cont_bases.fill(-1)
	if not cont.is_empty():
		for i in range(mini(6, cont.size())):
			cont_bases[i] = cont[i]
	var chk: Array = pos.checkers()
	var in_check: bool = chk[0] != 0 or chk[1] != 0
	var tt_ok: bool = ttm != T.MOVE_NONE and pos.pseudo_legal(ttm)
	if in_check:
		stage = EVASION_TT + (0 if tt_ok else 1)
	elif depth > 0:
		stage = MAIN_TT + (0 if tt_ok else 1)
	else:
		stage = QSEARCH_TT + (0 if tt_ok else 1)


## ProbCut constructor.
## Upstream: MovePicker(Position, Move, threshold, CapturePieceToHistory*)
func init_probcut(p, ttm: int, th: int, hist) -> void:
	pos = p
	history = hist
	tt_move = ttm
	threshold = th
	depth = 0
	ply = 0
	skip_quiets = false
	_probcut = true
	cur = 0
	end_cur = 0
	end_bad_captures = 0
	end_bad_quiets = 0
	cont_bases.fill(-1)
	var tt_ok: bool = (
		ttm != T.MOVE_NONE and pos.capture(ttm) and pos.pseudo_legal(ttm)
	)
	stage = PROBCUT_TT + (0 if tt_ok else 1)


func skip_quiet_moves() -> void:
	## Upstream: MovePicker::skip_quiet_moves
	skip_quiets = true


func next_move() -> int:
	## Upstream: MovePicker::next_move
	while true:
		match stage:
			MAIN_TT, EVASION_TT, QSEARCH_TT, PROBCUT_TT:
				stage += 1
				return tt_move

			CAPTURE_INIT, PROBCUT_INIT, QCAPTURE_INIT:
				_init_captures()
				stage += 1
				continue

			GOOD_CAPTURE:
				var m: int = _select_good_capture()
				if m != T.MOVE_NONE:
					return m
				stage += 1
				continue

			QUIET_INIT:
				if not skip_quiets:
					_init_quiets()
				else:
					end_bad_quiets = end_bad_captures
				stage += 1
				continue

			GOOD_QUIET:
				if not skip_quiets:
					var mq: int = _select_good_quiet()
					if mq != T.MOVE_NONE:
						return mq
				cur = 0
				end_cur = end_bad_captures
				stage += 1
				continue

			BAD_CAPTURE:
				var mb: int = _select_any()
				if mb != T.MOVE_NONE:
					return mb
				cur = end_bad_captures
				end_cur = end_bad_quiets
				stage += 1
				continue

			BAD_QUIET:
				if not skip_quiets:
					return _select_any()
				return T.MOVE_NONE

			EVASION_INIT:
				_init_evasions()
				stage += 1
				continue

			EVASION, QCAPTURE:
				return _select_any()

			PROBCUT:
				return _select_probcut()

			_:
				return T.MOVE_NONE
	return T.MOVE_NONE


func collect_all() -> PackedInt32Array:
	## Test helper: drain next_move into a PackedInt32Array.
	var out := PackedInt32Array()
	while true:
		var m: int = next_move()
		if m == T.MOVE_NONE:
			break
		out.append(m)
	return out


func _init_captures() -> void:
	var n: int = MG.generate(pos, MG.GEN_CAPTURES, moves)
	end_bad_captures = 0
	cur = 0
	end_cur = n
	_score_captures(0, n)
	_partial_insertion_sort(0, n, -2147483648)


func _init_quiets() -> void:
	# Quiets land after bad-capture region.
	var start: int = end_bad_captures
	var buf := PackedInt32Array()
	buf.resize(T.MAX_MOVES)
	var n: int = MG.generate(pos, MG.GEN_QUIETS, buf)
	for i in range(n):
		var dest: int = start + i
		if dest >= moves.size():
			n = i
			break
		moves[dest] = buf[i]
	end_bad_quiets = start
	cur = start
	end_cur = start + n
	_score_quiets(start, end_cur)
	_partial_insertion_sort(start, end_cur, -3330 * depth)


func _init_evasions() -> void:
	var n: int = MG.generate(pos, MG.GEN_EVASIONS, moves)
	cur = 0
	end_cur = n
	end_bad_captures = 0
	_score_evasions(0, n)
	_partial_insertion_sort(0, n, -2147483648)


func _score_captures(begin: int, end: int) -> void:
	## Upstream: score<CAPTURES>
	for i in range(begin, end):
		var m: int = moves[i]
		var to_sq: int = T.to_sq(m)
		var pc: int = pos.moved_piece(m)
		var captured: int = pos.piece_on(to_sq)
		var hist_v: int = 0
		if history != null:
			hist_v = history.get_capture(pc, to_sq, T.type_of(captured))
		values[i] = hist_v + 7 * int(T.PIECE_VALUE[captured])


func _threat_by_lesser(them: int) -> Array:
	## Upstream: threatByLesser[PAWN..KING] bitboards for quiet scoring.
	var out: Array = []
	out.resize(T.KING + 1)
	for pt in range(T.KING + 1):
		out[pt] = [0, 0]
	var pawn_thr: Array = pos.attacks_by(T.PAWN, them)
	out[T.PAWN] = [0, 0]
	out[T.ADVISOR] = pawn_thr
	out[T.BISHOP] = pawn_thr
	var ab: Array = pos.attacks_by(T.ADVISOR, them)
	var bb: Array = pos.attacks_by(T.BISHOP, them)
	var mid: Array = BB.or_bb(ab[0], ab[1], bb[0], bb[1])
	mid = BB.or_bb(mid[0], mid[1], pawn_thr[0], pawn_thr[1])
	out[T.KNIGHT] = mid
	out[T.CANNON] = mid
	var kn: Array = pos.attacks_by(T.KNIGHT, them)
	var cn: Array = pos.attacks_by(T.CANNON, them)
	var rook_thr: Array = BB.or_bb(kn[0], kn[1], cn[0], cn[1])
	rook_thr = BB.or_bb(rook_thr[0], rook_thr[1], mid[0], mid[1])
	out[T.ROOK] = rook_thr
	out[T.KING] = [0, 0]
	return out


func _score_quiets(begin: int, end: int) -> void:
	## Upstream: score<QUIETS> — butterfly + pawn + cont[0..3,5] + check + threat + lowPly.
	var us: int = pos.side_to_move
	var them: int = T.flip_color(us)
	var threat: Array = _threat_by_lesser(them)
	var pk: int = pos.pawn_key() if history != null else 0
	var king_them: int = pos.king_square(them)
	for i in range(begin, end):
		var m: int = moves[i]
		var from_sq: int = T.from_sq(m)
		var to_sq: int = T.to_sq(m)
		var pc: int = pos.moved_piece(m)
		var pt: int = T.type_of(pc)
		var v: int = 0
		if history != null:
			v = 2 * history.get_butterfly(us, T.move_raw(m))
			v += 2 * history.get_pawn(pk, pc, to_sq)
			# contHist indices 0,1,2,3,5 (skip 4) — Upstream movepick.cpp
			for ci in [0, 1, 2, 3, 5]:
				var base: int = cont_bases[ci] if ci < cont_bases.size() else -1
				if base >= 0:
					v += history.get_cont(base, pc, to_sq)
			if ply < Hist.LOW_PLY_HISTORY_SIZE:
				v += int(8 * history.get_low_ply(ply, T.move_raw(m)) / (1 + ply))
		# Bonus for checks
		var chk_sq: Array = pos.check_squares(pt)
		if pt == T.CANNON:
			var line: Array = A.line_bb(from_sq, king_them)
			chk_sq = [chk_sq[0] & ~line[0], chk_sq[1] & ~line[1]]
		if BB.test_bit(chk_sq[0], chk_sq[1], to_sq) and pos.see_ge(m, -75):
			v += 16384
		# Threat: escape lesser / walk into lesser
		var thr: Array = threat[pt] if pt <= T.KING else [0, 0]
		var from_thr: bool = BB.test_bit(thr[0], thr[1], from_sq)
		var to_thr: bool = BB.test_bit(thr[0], thr[1], to_sq)
		var tv: int = 20 * ((1 if from_thr else 0) - (1 if to_thr else 0))
		v += int(T.PIECE_VALUE[pt]) * tv
		values[i] = v


func _score_evasions(begin: int, end: int) -> void:
	## Upstream: score<EVASIONS>
	var us: int = pos.side_to_move
	for i in range(begin, end):
		var m: int = moves[i]
		if pos.capture(m):
			values[i] = int(T.PIECE_VALUE[pos.piece_on(T.to_sq(m))]) + (1 << 28)
		else:
			var pc: int = pos.moved_piece(m)
			var v: int = 0
			if history != null:
				v = history.get_butterfly(us, T.move_raw(m))
				var base0: int = cont_bases[0] if cont_bases.size() > 0 else -1
				if base0 >= 0:
					v += history.get_cont(base0, pc, T.to_sq(m))
			values[i] = v


func _partial_insertion_sort(begin: int, end: int, limit: int) -> void:
	## Upstream: partial_insertion_sort — descending among values >= limit.
	if end - begin <= 1:
		return
	var sorted_end: int = begin
	for p in range(begin + 1, end):
		if values[p] >= limit:
			sorted_end += 1
			var tmp_m: int = moves[p]
			var tmp_v: int = values[p]
			moves[p] = moves[sorted_end]
			values[p] = values[sorted_end]
			var q: int = sorted_end
			while q != begin and values[q - 1] < tmp_v:
				moves[q] = moves[q - 1]
				values[q] = values[q - 1]
				q -= 1
			moves[q] = tmp_m
			values[q] = tmp_v


func _select_good_capture() -> int:
	## Upstream: GOOD_CAPTURE select with SEE triage into endBadCaptures.
	while cur < end_cur:
		var m: int = moves[cur]
		var v: int = values[cur]
		cur += 1
		if m == tt_move:
			continue
		# Upstream: see_ge(*cur, -cur->value / 18)
		if pos.see_ge(m, -int(v / 18)):
			return m
		moves[end_bad_captures] = m
		values[end_bad_captures] = v
		end_bad_captures += 1
	return T.MOVE_NONE


func _select_good_quiet() -> int:
	## Upstream: GOOD_QUIET — value > -14000 else defer to bad quiets.
	while cur < end_cur:
		var m: int = moves[cur]
		var v: int = values[cur]
		cur += 1
		if m == tt_move:
			continue
		if v > -14000:
			return m
		moves[end_bad_quiets] = m
		values[end_bad_quiets] = v
		end_bad_quiets += 1
	return T.MOVE_NONE


func _select_any() -> int:
	while cur < end_cur:
		var m: int = moves[cur]
		cur += 1
		if m != tt_move:
			return m
	return T.MOVE_NONE


func _select_probcut() -> int:
	while cur < end_cur:
		var m: int = moves[cur]
		cur += 1
		if m == tt_move:
			continue
		if pos.see_ge(m, threshold):
			return m
	return T.MOVE_NONE
