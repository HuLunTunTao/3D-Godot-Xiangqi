## Feature indexing, bucket selection, mirror logic, and active-feature collection.
## Ports HalfKAv2_hm + FullThreats from pikafish src/nnue/features.
class_name PikafishNnueFeatures
extends RefCounted
const C = preload("res://addons/pikafish/nnue/consts.gd")
const XAttacks = preload("res://addons/pikafish/nnue/attacks.gd")
const XBoard = preload("res://addons/pikafish/nnue/board.gd")
const NNUELoader = preload("res://addons/pikafish/nnue/loader.gd")
const PS_NB = 689

var loader: NNUELoader
var palace: PackedByteArray
var king_buckets: PackedByteArray  # [90] raw byte values (bucket | (mirror<<3))
var mid_mirror_encoding: Array     # [16] -> PackedInt64Array
var layer_stack_buckets: Array     # flat [3][3][5][5]
var attack_bucket_table: Array     # flat [3][3][3]
var balance_encoding: int

# Square transform lookup tables
var flip_file_t: PackedInt32Array   # [90]
var flip_rank_t: PackedInt32Array   # [90]
var flip_fr_t: PackedInt32Array     # flip_rank(flip_file(s))

# Reused scratch (avoids per-call alloc)
var _cap_scratch: PackedInt32Array
var _psq_scratch: PackedInt32Array
var _pair_scratch: PackedInt32Array


func _init(ld: NNUELoader) -> void:
	loader = ld
	palace = C.palace_squares()
	_build_king_buckets()
	_build_mid_mirror_encoding()
	_build_layer_stack_buckets()
	_build_attack_bucket_table()
	_build_flip_tables()
	balance_encoding = -0x5B56D58B16762C59  # == 0xa4a92a74e989d3a7 (u64)
	_cap_scratch = PackedInt32Array()
	_cap_scratch.resize(16)
	_psq_scratch = PackedInt32Array()
	_psq_scratch.resize(40)
	_pair_scratch = PackedInt32Array()
	_pair_scratch.resize(128)
	XAttacks.ensure_tables()


func _build_flip_tables() -> void:
	flip_file_t = PackedInt32Array()
	flip_rank_t = PackedInt32Array()
	flip_fr_t = PackedInt32Array()
	flip_file_t.resize(90)
	flip_rank_t.resize(90)
	flip_fr_t.resize(90)
	for s in range(90):
		var f := s % 9
		var r := int(s / 9)
		var ff := r * 9 + (8 - f)
		var fr := (9 - r) * 9 + f
		flip_file_t[s] = ff
		flip_rank_t[s] = fr
		# Compute directly: flip_rank_t[ff] may not have been initialized yet.
		flip_fr_t[s] = (9 - r) * 9 + (8 - f)


# ---------- table builders ----------
func _build_king_buckets() -> void:
	king_buckets = PackedByteArray()
	king_buckets.resize(90)
	var rows := [
		[0, 0, 0, 0, 1, 8, 0, 0, 0],
		[0, 0, 0, 2, 3, 10, 0, 0, 0],
		[0, 0, 0, 4, 5, 12, 0, 0, 0],
		[0, 0, 0, 0, 0, 0, 0, 0, 0],
		[0, 0, 0, 0, 0, 0, 0, 0, 0],
		[0, 0, 0, 0, 0, 0, 0, 0, 0],
		[0, 0, 0, 0, 0, 0, 0, 0, 0],
		[0, 0, 0, 4, 5, 12, 0, 0, 0],
		[0, 0, 0, 2, 3, 10, 0, 0, 0],
		[0, 0, 0, 0, 1, 8, 0, 0, 0],
	]
	for r in range(10):
		for f in range(9):
			king_buckets[r * 9 + f] = rows[r][f]


func _index_map(mirror: bool, rotate: bool, s: int) -> int:
	if mirror and rotate:
		return flip_fr_t[s]
	if mirror:
		return flip_file_t[s]
	if rotate:
		return flip_rank_t[s]
	return s


func _build_mid_mirror_encoding() -> void:
	var shifts := [[0, 0], [44, 0], [60, 36], [47, 7], [53, 21], [50, 14], [57, 29], [0, 0]]
	mid_mirror_encoding = []
	for pc in range(16):
		mid_mirror_encoding.append(PackedInt64Array())
		mid_mirror_encoding[pc].resize(90)
	for c in [C.WHITE, C.BLACK]:
		for pt in range(C.ROOK, C.KING + 1):
			for r in range(10):
				for f in range(9):
					var encoding := 0
					if f != 4 and pt != C.KING:
						var r_ := r if c == C.WHITE else 9 - r
						var f_ := f if f < 4 else 8 - f
						var s1: int = shifts[pt][0]
						var s2: int = shifts[pt][1]
						encoding = (1 << s1) | (((4 - f_) * 10 + r_) << s2)
						if f > 4:
							encoding = -encoding
					elif f != 4 and pt == C.KING:
						encoding = 1 << 63
					var p := C.make_piece(c, pt)
					var sq := C.make_square(f, r)
					mid_mirror_encoding[p][sq] = encoding


func _build_layer_stack_buckets() -> void:
	layer_stack_buckets = []
	for ur in range(3):
		for orr in range(3):
			for ukc in range(5):
				for okc in range(5):
					var v := 0
					if ur == orr:
						v = ur * 4 + (2 if ukc + okc >= 4 else 0) + (1 if ukc == okc else 0)
					elif ur == 2 and orr == 1:
						v = 12
					elif ur == 1 and orr == 2:
						v = 13
					elif ur > 0 and orr == 0:
						v = 14
					else:
						v = 15
					layer_stack_buckets.append(v)


func _lsb(us_r: int, opp_r: int, us_kc: int, opp_kc: int) -> int:
	return layer_stack_buckets[((us_r * 3 + opp_r) * 5 + us_kc) * 5 + opp_kc]


func _build_attack_bucket_table() -> void:
	attack_bucket_table = []
	for rk in range(3):
		for kn in range(3):
			for cn in range(3):
				attack_bucket_table.append((1 if rk > 0 else 0) * 2 + (1 if kn + cn > 0 else 0))


func _ab(rk: int, kn: int, cn: int) -> int:
	return attack_bucket_table[(rk * 3 + kn) * 3 + cn]


static func u64_lt(a: int, b: int) -> bool:
	var sa := (a >> 63) & 1
	var sb := (b >> 63) & 1
	if sa != sb:
		return sa == 0
	return a < b


func make_attack_bucket(pos: XBoard, c: int) -> int:
	var rk := mini(pos.count(C.ROOK, c), 2)
	var kn := mini(pos.count(C.KNIGHT, c), 2)
	var cn := mini(pos.count(C.CANNON, c), 2)
	return _ab(rk, kn, cn)


func mid_encoding(pos: XBoard, c: int) -> int:
	var mid := balance_encoding
	var enc: Array = mid_mirror_encoding
	for s in pos.piece_list:
		var pc: int = pos.sq[s]
		if (pc >> 3) == c:
			mid += enc[pc][s]
	return mid


func requires_mid_mirror(pos: XBoard, c: int) -> bool:
	var mc := mid_encoding(pos, c)
	var mo := mid_encoding(pos, c ^ 1)
	if ((mc >> 63) & 1) and ((mo >> 63) & 1):
		if u64_lt(mc, balance_encoding):
			return true
		if mc == balance_encoding and u64_lt(mo, balance_encoding):
			return true
	return false


## Returns Vector2i(bucket, mirror_as_0_or_1). Prefer over Dictionary.
func make_feature_bucket_v(perspective: int, pos: XBoard) -> Vector2i:
	var ksq := pos.kings[perspective]
	var oksq := pos.kings[perspective ^ 1]
	var kb_ := king_buckets[ksq]
	var king_bucket := kb_ & 7
	var okb_ := king_buckets[oksq]
	var m1 := (kb_ >> 3) != 0
	var m2 := (king_bucket & 1) != 0
	var m3 := (okb_ >> 3) != 0
	var m4 := (okb_ & 1) != 0
	var mirror: bool
	if m1:
		mirror = true
	elif not m2:
		mirror = false
	elif m3:
		mirror = true
	elif m4:
		mirror = requires_mid_mirror(pos, perspective)
	else:
		mirror = false
	var attack_bucket := make_attack_bucket(pos, perspective)
	return Vector2i(king_bucket * 4 + attack_bucket, 1 if mirror else 0)


func make_feature_bucket(perspective: int, pos: XBoard) -> Dictionary:
	var v := make_feature_bucket_v(perspective, pos)
	return {"bucket": v.x, "mirror": v.y != 0, "attack_bucket": v.x & 3}


func make_layer_stack_bucket(pos: XBoard) -> int:
	var us := pos.stm
	var opp := us ^ 1
	var us_r := mini(pos.count(C.ROOK, us), 2)
	var opp_r := mini(pos.count(C.ROOK, opp), 2)
	var us_kc := mini(pos.count(C.KNIGHT, us) + pos.count(C.CANNON, us), 4)
	var opp_kc := mini(pos.count(C.KNIGHT, opp) + pos.count(C.CANNON, opp), 4)
	return _lsb(us_r, opp_r, us_kc, opp_kc)


func make_index_psq(perspective: int, s: int, pc: int, bucket: int, mirror: bool) -> int:
	s = _index_map(mirror, perspective == C.BLACK, s)
	if perspective == C.BLACK:
		pc = C.flip_piece(pc)
	var off := loader.psq_offset(pc, s)
	if off < 0:
		return -1
	return off + PS_NB * bucket


func make_index_threat(perspective: int, attacker: int, frm: int, to: int, attacked: int, mirror: bool) -> int:
	frm = _index_map(mirror, perspective == C.BLACK, frm)
	to = _index_map(mirror, perspective == C.BLACK, to)
	if perspective == C.BLACK:
		attacker = C.flip_piece(attacker)
		attacked = C.flip_piece(attacked)
	return loader.threat_offset(attacker, frm, to, attacked)


func append_active_psq(perspective: int, pos: XBoard, bucket: int, mirror: bool) -> PackedInt32Array:
	var out := PackedInt32Array()
	out.resize(pos.piece_list.size())
	var n := _write_psq(out, 0, perspective, pos, bucket, mirror)
	out.resize(n)
	return out


func append_active_threats(perspective: int, pos: XBoard, mirror: bool) -> PackedInt32Array:
	var out := PackedInt32Array()
	out.resize(64)
	var n := _write_threats(out, 0, perspective, pos, mirror)
	out.resize(n)
	return out


## Write both perspectives' active feature lists into `active` at `base`.
## Returns Vector3i(layer bucket, packed fb0, packed fb1), where a packed feature
## bucket is bucket | (mirror << 8). This lets callers reuse the bucket work.
func fill_active_both_info(active: PackedInt32Array, base: int, pos: XBoard, stm: int) -> Vector3i:
	var fb0 := make_feature_bucket_v(stm, pos)
	var fb1 := make_feature_bucket_v(stm ^ 1, pos)
	var pn0 := _write_psq(active, base + 1, stm, pos, fb0.x, fb0.y != 0)
	active[base + 0] = pn0
	var pn1 := _write_psq(active, base + 131, stm ^ 1, pos, fb1.x, fb1.y != 0)
	active[base + 130] = pn1

	var pairs: PackedInt32Array = _pair_scratch
	var np := 0
	var occ: PackedByteArray = pos.occ
	var scratch: PackedInt32Array = _cap_scratch
	for frm in pos.piece_list:
		var attacker: int = pos.sq[frm]
		var an: int = XAttacks.append_captures(attacker & 7, frm, occ, attacker >> 3, scratch)
		for ai in range(an):
			if np + 2 > pairs.size():
				pairs.resize(pairs.size() * 2)
				_pair_scratch = pairs
			pairs[np] = frm
			pairs[np + 1] = scratch[ai]
			np += 2

	active[base + 65] = _map_threats(active, base + 66, pos, stm, fb0.y != 0, pairs, np)
	active[base + 195] = _map_threats(active, base + 196, pos, stm ^ 1, fb1.y != 0, pairs, np)
	return Vector3i(
		make_layer_stack_bucket(pos),
		fb0.x | (fb0.y << 8),
		fb1.x | (fb1.y << 8))


## Compatibility wrapper for callers that only need the layer-stack bucket.
func fill_active_both(active: PackedInt32Array, base: int, pos: XBoard, stm: int) -> int:
	return fill_active_both_info(active, base, pos, stm).x


## Write actives + CPU PSQT (for reference / incremental). Returns Vector2i(psqt0, psqt1).
func fill_both_perspectives(
	active: PackedInt32Array,
	base: int,
	pos: XBoard,
	stm: int,
	lbucket: int,
	psqt_raw: PackedByteArray,
	tpsqt_raw: PackedByteArray
) -> Vector2i:
	var got_bucket := fill_active_both(active, base, pos, stm)
	var lane := lbucket if lbucket >= 0 else got_bucket
	var pn0: int = active[base + 0]
	var tn0: int = active[base + 65]
	var pn1: int = active[base + 130]
	var tn1: int = active[base + 195]
	var psqt0 := 0
	var psqt1 := 0
	for k in range(pn0):
		psqt0 += psqt_raw.decode_s32((active[base + 1 + k] * C.PSQTBUCKETS + lane) * 4)
	for k in range(tn0):
		psqt0 += tpsqt_raw.decode_s32((active[base + 66 + k] * C.PSQTBUCKETS + lane) * 4)
	for k in range(pn1):
		psqt1 += psqt_raw.decode_s32((active[base + 131 + k] * C.PSQTBUCKETS + lane) * 4)
	for k in range(tn1):
		psqt1 += tpsqt_raw.decode_s32((active[base + 196 + k] * C.PSQTBUCKETS + lane) * 4)
	return Vector2i(psqt0, psqt1)


func _map_threats(
	out: PackedInt32Array, out_off: int, pos: XBoard, perspective: int, mirror: bool,
	pairs: PackedInt32Array, np: int
) -> int:
	var n := 0
	var rotate := perspective == C.BLACK
	var thr_raw: PackedByteArray = loader.threat_offsets
	var i := 0
	while i < np:
		var frm: int = pairs[i]
		var to: int = pairs[i + 1]
		i += 2
		var attacker: int = pos.sq[frm]
		var attacked: int = pos.sq[to]
		var f: int = frm
		var t: int = to
		var atk: int = attacker
		var atd: int = attacked
		if mirror and rotate:
			f = flip_fr_t[f]
			t = flip_fr_t[t]
		elif mirror:
			f = flip_file_t[f]
			t = flip_file_t[t]
		elif rotate:
			f = flip_rank_t[f]
			t = flip_rank_t[t]
		if rotate:
			atk = C.flip_piece(atk)
			atd = C.flip_piece(atd)
		var idx: int = ((atk * 90 + f) * 90 + t) * 16 + atd
		var off: int = idx * 2
		var v: int = thr_raw[off] | (thr_raw[off + 1] << 8)
		if v < C.THREAT_DIM and n < 64:
			out[out_off + n] = v
			n += 1
	return n


func _write_psq(out: PackedInt32Array, out_off: int, perspective: int, pos: XBoard, bucket: int, mirror: bool) -> int:
	var n := 0
	var rotate := perspective == C.BLACK
	var psq_off: PackedInt32Array = loader.psq_offsets
	var bucket_base := PS_NB * bucket
	for s in pos.piece_list:
		var pc: int = pos.sq[s]
		var ss := s
		if mirror and rotate:
			ss = flip_fr_t[ss]
		elif mirror:
			ss = flip_file_t[ss]
		elif rotate:
			ss = flip_rank_t[ss]
		if rotate:
			pc = C.flip_piece(pc)
		var off: int = psq_off[pc * 90 + ss]
		if off >= 0:
			out[out_off + n] = off + bucket_base
			n += 1
	return n


func _write_threats(out: PackedInt32Array, out_off: int, perspective: int, pos: XBoard, mirror: bool) -> int:
	var n := 0
	var occ: PackedByteArray = pos.occ
	var rotate := perspective == C.BLACK
	var thr_raw: PackedByteArray = loader.threat_offsets
	var scratch: PackedInt32Array = _cap_scratch
	if scratch.size() < 36:
		scratch.resize(36)
		_cap_scratch = scratch
	for frm in pos.piece_list:
		var attacker: int = pos.sq[frm]
		var pt := attacker & 7
		var col := attacker >> 3
		var an: int = XAttacks.append_captures(pt, frm, occ, col, scratch)
		for ai in range(an):
			var to: int = scratch[ai]
			var attacked: int = pos.sq[to]
			var f: int = frm
			var t: int = to
			var atk: int = attacker
			var atd: int = attacked
			if mirror and rotate:
				f = flip_fr_t[f]
				t = flip_fr_t[t]
			elif mirror:
				f = flip_file_t[f]
				t = flip_file_t[t]
			elif rotate:
				f = flip_rank_t[f]
				t = flip_rank_t[t]
			if rotate:
				atk = C.flip_piece(atk)
				atd = C.flip_piece(atd)
			var idx: int = ((atk * 90 + f) * 90 + t) * 16 + atd
			var off: int = idx * 2
			var v: int = thr_raw[off] | (thr_raw[off + 1] << 8)
			if v < C.THREAT_DIM and n < 64:
				out[out_off + n] = v
				n += 1
	return n
