class_name PikafishHistory
extends RefCounted

## Upstream: Pikafish 2c5c998c, src/history.h
## PackedArray SoA histories with gravity update. Single-thread (no atomics).

const T = preload("res://addons/pikafish/core/types.gd")

const UINT_16_HISTORY_SIZE := 65536
const LOW_PLY_HISTORY_SIZE := 5
const CORRECTION_HISTORY_LIMIT := 1024
## Upstream: PAWN_HISTORY_BASE_SIZE (power of 2). Single-thread DynStats size = this.
const PAWN_HISTORY_BASE_SIZE := 8192
## Upstream: CORRHIST_BASE_SIZE == UINT_16_HISTORY_SIZE (power of 2).
const CORRHIST_BASE_SIZE := UINT_16_HISTORY_SIZE

const BUTTERFLY_D := 7183
const CAPTURE_D := 10692
const PIECE_TO_D := 30000
const PAWN_HIST_D := 8192
const CORRECTION_D := CORRECTION_HISTORY_LIMIT

## ButterflyHistory[COLOR_NB][move_raw]
var butterfly: PackedInt32Array = PackedInt32Array()

## LowPlyHistory[LOW_PLY][move_raw]
var low_ply: PackedInt32Array = PackedInt32Array()

## CapturePieceToHistory[PIECE_NB][SQUARE_NB][PIECE_TYPE_NB]
var capture: PackedInt32Array = PackedInt32Array()

## PieceToHistory[PIECE_NB][SQUARE_NB] — quiet piece-to (non-continuation)
var piece_to: PackedInt32Array = PackedInt32Array()

## CorrectionHistory<PieceTo>[PIECE_NB][SQUARE_NB]
var correction_piece_to: PackedInt32Array = PackedInt32Array()

## ContinuationHistory[2 inCheck][2 capture][PIECE_NB][SQUARE_NB] → PieceToHistory
## Flat: base(inCheck,cap,prevPc,prevTo) + pc*SQUARE_NB + to
## Lazy-allocated (ensure_deep) — ~8.3M entries ≈ 33 MiB.
var continuation: PackedInt32Array = PackedInt32Array()

## PawnHistory[bucket][PIECE_NB][SQUARE_NB], bucket = pawn_key & (SIZE-1)
## Lazy-allocated — ~11.8M entries ≈ 45 MiB.
var pawn_history: PackedInt32Array = PackedInt32Array()

## UnifiedCorrectionHistory[bucket][COLOR_NB][4 fields: pawn,minor,npW,npB]
## Lazy-allocated — 65536 * 2 * 4 ≈ 0.5M entries.
var unified_correction: PackedInt32Array = PackedInt32Array()

const CONT_FILL := -436
const PAWN_FILL := -1247
const UNIFIED_CORR_FILL := -6

## ContHistBonus weights — Upstream: update_continuation_histories
const CONTHIST_I := [1, 2, 3, 4, 5, 6]
const CONTHIST_W := [1076, 639, 293, 523, 129, 445]
const CMHC_MULT := [96, 100, 100, 100, 115, 118, 129]


func _init() -> void:
	butterfly.resize(T.COLOR_NB * UINT_16_HISTORY_SIZE)
	low_ply.resize(LOW_PLY_HISTORY_SIZE * UINT_16_HISTORY_SIZE)
	capture.resize(T.PIECE_NB * T.SQUARE_NB * T.PIECE_TYPE_NB)
	piece_to.resize(T.PIECE_NB * T.SQUARE_NB)
	correction_piece_to.resize(T.PIECE_NB * T.SQUARE_NB)
	clear_shallow()


## Allocate Continuation / Pawn / UnifiedCorrection (once per History instance).
func ensure_deep() -> void:
	if continuation.is_empty():
		var cont_len: int = (
			2 * 2 * T.PIECE_NB * T.SQUARE_NB * T.PIECE_NB * T.SQUARE_NB
		)
		continuation.resize(cont_len)
		continuation.fill(CONT_FILL)
	if pawn_history.is_empty():
		var pawn_len: int = PAWN_HISTORY_BASE_SIZE * T.PIECE_NB * T.SQUARE_NB
		pawn_history.resize(pawn_len)
		pawn_history.fill(PAWN_FILL)
	if unified_correction.is_empty():
		var uc_len: int = CORRHIST_BASE_SIZE * T.COLOR_NB * 4
		unified_correction.resize(uc_len)
		unified_correction.fill(UNIFIED_CORR_FILL)


func clear_shallow() -> void:
	butterfly.fill(0)
	low_ply.fill(0)
	capture.fill(0)
	piece_to.fill(0)
	correction_piece_to.fill(0)


func clear() -> void:
	clear_shallow()
	if not continuation.is_empty():
		continuation.fill(CONT_FILL)
	if not pawn_history.is_empty():
		pawn_history.fill(PAWN_FILL)
	if not unified_correction.is_empty():
		unified_correction.fill(UNIFIED_CORR_FILL)


## Upstream: StatsEntry::operator<< — gravity update into [-D, D].
static func gravity(entry: int, bonus: int, d_limit: int) -> int:
	var clamped: int = clampi(bonus, -d_limit, d_limit)
	# GDS-DIVERGENCE: SEMANTIC — GDScript `/` is float; use int() for trunc toward zero like C++ on positives.
	return entry + clamped - int(entry * absi(clamped) / d_limit)


func _bf_idx(color: int, move_raw: int) -> int:
	return color * UINT_16_HISTORY_SIZE + (move_raw & 0xFFFF)


func _lp_idx(ply: int, move_raw: int) -> int:
	return ply * UINT_16_HISTORY_SIZE + (move_raw & 0xFFFF)


func _cap_idx(pc: int, to_sq: int, captured_pt: int) -> int:
	return (pc * T.SQUARE_NB + to_sq) * T.PIECE_TYPE_NB + captured_pt


func _pt_idx(pc: int, to_sq: int) -> int:
	return pc * T.SQUARE_NB + to_sq


## Upstream: &continuationHistory[inCheck][capture][prevPc][prevTo]
func cont_base(in_check: int, is_capture: int, prev_pc: int, prev_to: int) -> int:
	ensure_deep()
	var ic: int = 1 if in_check else 0
	var cap: int = 1 if is_capture else 0
	var pc: int = clampi(prev_pc, 0, T.PIECE_NB - 1)
	var to: int = clampi(prev_to, 0, T.SQUARE_NB - 1)
	return (((ic * 2 + cap) * T.PIECE_NB + pc) * T.SQUARE_NB + to) * T.PIECE_NB * T.SQUARE_NB


func sentinel_cont_base() -> int:
	## Upstream: &continuationHistory[0][0][NO_PIECE][0]
	return cont_base(0, 0, T.NO_PIECE, 0)


func get_cont(base: int, pc: int, to_sq: int) -> int:
	if continuation.is_empty() or base < 0:
		return 0
	return continuation[base + _pt_idx(pc, to_sq)]


func update_cont(base: int, pc: int, to_sq: int, bonus: int) -> void:
	if base < 0:
		return
	ensure_deep()
	var i: int = base + _pt_idx(pc, to_sq)
	continuation[i] = gravity(continuation[i], bonus, PIECE_TO_D)


func _pawn_bucket(pawn_key: int) -> int:
	return int(pawn_key) & (PAWN_HISTORY_BASE_SIZE - 1)


func get_pawn(pawn_key: int, pc: int, to_sq: int) -> int:
	if pawn_history.is_empty():
		return 0
	var i: int = _pawn_bucket(pawn_key) * T.PIECE_NB * T.SQUARE_NB + _pt_idx(pc, to_sq)
	return pawn_history[i]


func update_pawn(pawn_key: int, pc: int, to_sq: int, bonus: int) -> void:
	ensure_deep()
	var i: int = _pawn_bucket(pawn_key) * T.PIECE_NB * T.SQUARE_NB + _pt_idx(pc, to_sq)
	pawn_history[i] = gravity(pawn_history[i], bonus, PAWN_HIST_D)


## Unified correction field indices.
const UC_PAWN := 0
const UC_MINOR := 1
const UC_NP_W := 2
const UC_NP_B := 3


func _uc_idx(bucket: int, color: int, field: int) -> int:
	return (bucket * T.COLOR_NB + color) * 4 + field


func get_unified_correction(key: int, color: int, field: int) -> int:
	if unified_correction.is_empty():
		return 0
	var b: int = int(key) & (CORRHIST_BASE_SIZE - 1)
	return unified_correction[_uc_idx(b, color, field)]


func update_unified_correction(key: int, color: int, field: int, bonus: int) -> void:
	ensure_deep()
	var b: int = int(key) & (CORRHIST_BASE_SIZE - 1)
	var i: int = _uc_idx(b, color, field)
	unified_correction[i] = gravity(unified_correction[i], bonus, CORRECTION_D)


func get_butterfly(color: int, move_raw: int) -> int:
	return butterfly[_bf_idx(color, move_raw)]


func get_low_ply(ply: int, move_raw: int) -> int:
	if ply < 0 or ply >= LOW_PLY_HISTORY_SIZE:
		return 0
	return low_ply[_lp_idx(ply, move_raw)]


func get_capture(pc: int, to_sq: int, captured_pt: int) -> int:
	return capture[_cap_idx(pc, to_sq, captured_pt)]


func get_piece_to(pc: int, to_sq: int) -> int:
	return piece_to[_pt_idx(pc, to_sq)]


func get_correction(pc: int, to_sq: int) -> int:
	return correction_piece_to[_pt_idx(pc, to_sq)]


func update_butterfly(color: int, move_raw: int, bonus: int) -> void:
	var i := _bf_idx(color, move_raw)
	butterfly[i] = gravity(butterfly[i], bonus, BUTTERFLY_D)


func update_low_ply(ply: int, move_raw: int, bonus: int) -> void:
	if ply < 0 or ply >= LOW_PLY_HISTORY_SIZE:
		return
	var i := _lp_idx(ply, move_raw)
	low_ply[i] = gravity(low_ply[i], bonus, BUTTERFLY_D)


func update_capture(pc: int, to_sq: int, captured_pt: int, bonus: int) -> void:
	var i := _cap_idx(pc, to_sq, captured_pt)
	capture[i] = gravity(capture[i], bonus, CAPTURE_D)


func update_piece_to(pc: int, to_sq: int, bonus: int) -> void:
	var i := _pt_idx(pc, to_sq)
	piece_to[i] = gravity(piece_to[i], bonus, PIECE_TO_D)


func update_correction(pc: int, to_sq: int, bonus: int) -> void:
	var i := _pt_idx(pc, to_sq)
	correction_piece_to[i] = gravity(correction_piece_to[i], bonus, CORRECTION_D)


## Upstream: update_continuation_histories(ss, pc, to, bonus)
## ss_cont_base / ss_current_move indexed with SS_OFFSET; ply is absolute search ply.
func update_continuation_histories(
	ss_cont_base: PackedInt32Array,
	ss_current_move: PackedInt32Array,
	ss_in_check: PackedByteArray,
	ss_offset: int,
	ply: int,
	pc: int,
	to_sq: int,
	bonus: int
) -> void:
	ensure_deep()
	var positive_count: int = 0
	var in_check_now: bool = ss_in_check[ss_offset + ply] != 0
	for bi in range(CONTHIST_I.size()):
		var i: int = int(CONTHIST_I[bi])
		var weight: int = int(CONTHIST_W[bi])
		if in_check_now and i > 2:
			break
		var ssi: int = ss_offset + ply - i
		if ssi < 0 or ssi >= ss_current_move.size():
			continue
		var cm: int = ss_current_move[ssi]
		if not T.move_is_ok(cm):
			continue
		var base: int = ss_cont_base[ssi]
		var entry: int = get_cont(base, pc, to_sq)
		if entry > 0:
			positive_count += 1
		var multiplier: int = int(CMHC_MULT[mini(positive_count, CMHC_MULT.size() - 1)])
		var adj: int = int(bonus * weight * multiplier / 131072) + (83 if i < 2 else 0)
		update_cont(base, pc, to_sq, adj)


## Upstream: update_quiet_histories (+ continuation + pawn).
func update_quiet(
	color: int,
	move: int,
	pc: int,
	to_sq: int,
	ply: int,
	bonus: int,
	pawn_key: int = 0,
	ss_cont_base: PackedInt32Array = PackedInt32Array(),
	ss_current_move: PackedInt32Array = PackedInt32Array(),
	ss_in_check: PackedByteArray = PackedByteArray(),
	ss_offset: int = 0
) -> void:
	var raw: int = T.move_raw(move)
	update_butterfly(color, raw, bonus)
	if ply < LOW_PLY_HISTORY_SIZE:
		update_low_ply(ply, raw, int(bonus * 693 / 1024))
	# Upstream: continuation gets bonus*972/1024 (not piece_to).
	if not ss_cont_base.is_empty():
		update_continuation_histories(
			ss_cont_base, ss_current_move, ss_in_check, ss_offset, ply, pc, to_sq,
			int(bonus * 972 / 1024)
		)
	var pawn_bonus: int = int(bonus * (913 if bonus > -7 else 553) / 1024)
	update_pawn(pawn_key, pc, to_sq, pawn_bonus)
