## CPU-side incremental feature-transformer accumulator for search / continuous play.
## After refresh or do_move: keep acc[2×L1] + PSQT; evaluate via cheap forward (CPU)
## or by uploading acc to GPU forward-only (engine decides).
##
## Strategy: re-extract active feature lists after each move (threats need attack gen),
## then update accumulator by set-difference of feature indices (avoid full 1024 bias rebuild).
## King / bucket / mirror changes trigger a full perspective refresh.

class_name PikafishAccumulator
extends RefCounted
const C = preload("res://addons/pikafish/nnue/consts.gd")
const XBoard = preload("res://addons/pikafish/nnue/board.gd")
const NNUELoader = preload("res://addons/pikafish/nnue/loader.gd")
const XFeatures = preload("res://addons/pikafish/nnue/features.gd")

var loader: NNUELoader
var features: XFeatures

var acc0: PackedInt32Array
var acc1: PackedInt32Array
# PSQT for all 16 layer-stack lanes (captures can change bucket)
var psqt0: PackedInt32Array
var psqt1: PackedInt32Array

var active: PackedInt32Array  # layout like GPU: 260 ints
var _spare_active: PackedInt32Array
var feat_bucket: PackedInt32Array  # [2]
var feat_mirror: PackedByteArray   # [2]
var computed: bool = false

# Membership stamps turn feature-list differences into linear passes.
var _psq_stamp: PackedInt32Array
var _thr_stamp: PackedInt32Array
var _stamp_generation := 0
var _snapshot_pool: Array = []
var _signed_i8: PackedInt32Array

# Reused forward scratch; evaluate_incremental performs no per-call array allocation.
var _tf: PackedInt32Array
var _y0: PackedInt32Array
var _y1: PackedInt32Array
var _c2: PackedInt32Array
var _fc0_w_i32: Array = []
var _fc0_b_i32: Array = []
var _fc1_w_i32: Array = []
var _fc1_b_i32: Array = []
var _fc2_w_i32: Array = []
var _fc2_b_i32: PackedInt32Array


func _init(ld: NNUELoader, ft: XFeatures) -> void:
	loader = ld
	features = ft
	acc0 = PackedInt32Array()
	acc0.resize(C.L1)
	acc1 = PackedInt32Array()
	acc1.resize(C.L1)
	psqt0 = PackedInt32Array()
	psqt0.resize(C.PSQTBUCKETS)
	psqt1 = PackedInt32Array()
	psqt1.resize(C.PSQTBUCKETS)
	active = PackedInt32Array()
	active.resize(260)
	_spare_active = PackedInt32Array()
	_spare_active.resize(260)
	feat_bucket = PackedInt32Array([0, 0])
	feat_mirror = PackedByteArray([0, 0])
	_psq_stamp = PackedInt32Array()
	_psq_stamp.resize(C.PSQ_DIM)
	_thr_stamp = PackedInt32Array()
	_thr_stamp.resize(C.THREAT_DIM)
	_signed_i8 = PackedInt32Array()
	_signed_i8.resize(256)
	for i in range(256):
		_signed_i8[i] = i if i < 128 else i - 256
	_tf = PackedInt32Array()
	_tf.resize(C.L1)
	_y0 = PackedInt32Array()
	_y0.resize(C.FC0)
	_y1 = PackedInt32Array()
	_y1.resize(C.FC1)
	_c2 = PackedInt32Array()
	_c2.resize(128)
	_predecode_forward_weights()


func _predecode_forward_weights() -> void:
	_fc2_b_i32 = PackedInt32Array()
	_fc2_b_i32.resize(C.LAYERSTACKS)
	for stack in range(C.LAYERSTACKS):
		_fc0_w_i32.append(_decode_i8_array(loader.fc0_w[stack]))
		_fc1_w_i32.append(_decode_i8_array(loader.fc1_w[stack]))
		_fc2_w_i32.append(_decode_i8_array(loader.fc2_w[stack]))
		_fc0_b_i32.append(_decode_i32_array(loader.fc0_bias_raw[stack]))
		_fc1_b_i32.append(_decode_i32_array(loader.fc1_bias_raw[stack]))
		_fc2_b_i32[stack] = loader.fc2_bias_raw[stack].decode_s32(0)


static func _decode_i8_array(raw: PackedByteArray) -> PackedInt32Array:
	var decoded := PackedInt32Array()
	decoded.resize(raw.size())
	for i in range(raw.size()):
		var value: int = raw[i]
		decoded[i] = value if value < 128 else value - 256
	return decoded


static func _decode_i32_array(raw: PackedByteArray) -> PackedInt32Array:
	var decoded := PackedInt32Array()
	decoded.resize(raw.size() / 4)
	for i in range(decoded.size()):
		decoded[i] = raw.decode_s32(i * 4)
	return decoded


func refresh(pos: XBoard) -> void:
	var info := features.fill_active_both_info(active, 0, pos, pos.stm)
	feat_bucket[0] = info.y & 0xff
	feat_bucket[1] = info.z & 0xff
	feat_mirror[0] = (info.y >> 8) & 1
	feat_mirror[1] = (info.z >> 8) & 1
	_rebuild_persp(0, active, 0)
	_rebuild_persp(1, active, 130)
	computed = true


## Call after pos.do_move (stm has flipped). Returns a compact reversible frame.
func update_after_move(pos: XBoard) -> Dictionary:
	if not computed:
		var cold_frame := {"cold": true, "snapshot": snapshot()}
		refresh(pos)
		return cold_frame
	var old_active := active
	active = _spare_active
	var old_b0: int = feat_bucket[0]
	var old_b1: int = feat_bucket[1]
	var old_m0: int = feat_mirror[0]
	var old_m1: int = feat_mirror[1]
	# stm flipped: previous opp perspective is now stm (slot 0)
	var tmp_a := acc0
	acc0 = acc1
	acc1 = tmp_a
	var tmp_p := psqt0
	psqt0 = psqt1
	psqt1 = tmp_p

	var info := features.fill_active_both_info(active, 0, pos, pos.stm)
	var fb0 := Vector2i(info.y & 0xff, (info.y >> 8) & 1)
	var fb1 := Vector2i(info.z & 0xff, (info.z >> 8) & 1)
	var frame := {
		"cold": false,
		"old_b0": old_b0, "old_b1": old_b1,
		"old_m0": old_m0, "old_m1": old_m1,
		"psq0": _feature_delta(true, old_active, 130, active, 0),
		"thr0": _feature_delta(false, old_active, 130, active, 0),
		"psq1": _feature_delta(true, old_active, 0, active, 130),
		"thr1": _feature_delta(false, old_active, 0, active, 130),
		"snapshot0": null, "snapshot1": null,
	}
	# new slot0 <-> old slot1; new slot1 <-> old slot0
	if fb0.x != old_b1 or fb0.y != old_m1:
		frame["snapshot0"] = _take_perspective_snapshot(0)
		_rebuild_persp(0, active, 0)
	else:
		_apply_frame_delta(0, frame["psq0"], frame["thr0"], 1)
	if fb1.x != old_b0 or fb1.y != old_m0:
		frame["snapshot1"] = _take_perspective_snapshot(1)
		_rebuild_persp(1, active, 130)
	else:
		_apply_frame_delta(1, frame["psq1"], frame["thr1"], 1)
	feat_bucket[0] = fb0.x
	feat_bucket[1] = fb1.x
	feat_mirror[0] = fb0.y
	feat_mirror[1] = fb1.y
	_spare_active = old_active
	return frame


func undo_update(frame: Dictionary) -> void:
	if frame["cold"]:
		restore(frame["snapshot"])
		return
	for p in range(2):
		var snap: Variant = frame["snapshot%d" % p]
		if snap != null:
			_restore_perspective_snapshot(p, snap)
			_snapshot_pool.append(snap)
		else:
			_apply_frame_delta(p, frame["psq%d" % p], frame["thr%d" % p], -1)

	# Reconstruct the previous active lists in their pre-side-to-move slots.
	_spare_active[130] = _reconstruct_list(
		true, active, 1, active[0], _spare_active, 131, frame["psq0"])
	_spare_active[195] = _reconstruct_list(
		false, active, 66, active[65], _spare_active, 196, frame["thr0"])
	_spare_active[0] = _reconstruct_list(
		true, active, 131, active[130], _spare_active, 1, frame["psq1"])
	_spare_active[65] = _reconstruct_list(
		false, active, 196, active[195], _spare_active, 66, frame["thr1"])
	var new_active := active
	active = _spare_active
	_spare_active = new_active

	var tmp_a := acc0
	acc0 = acc1
	acc1 = tmp_a
	var tmp_p := psqt0
	psqt0 = psqt1
	psqt1 = tmp_p
	feat_bucket[0] = frame["old_b0"]
	feat_bucket[1] = frame["old_b1"]
	feat_mirror[0] = frame["old_m0"]
	feat_mirror[1] = frame["old_m1"]


func evaluate(pos: XBoard) -> int:
	var terms: Dictionary = evaluate_terms(pos)
	return int(terms["nnue_total"])


## Same units as Eval::NNUE::Network::evaluate(): each component has already
## been divided by OutputScale. Search consumes the components separately in
## order to apply upstream Eval::evaluate; public inference keeps total only.
func evaluate_terms(pos: XBoard) -> Dictionary:
	if not computed:
		refresh(pos)
	var lbucket := features.make_layer_stack_bucket(pos)
	var psqt_val: int = (psqt0[lbucket] - psqt1[lbucket]) / 2
	var positional := _forward_cpu(lbucket)
	var psqt: int = psqt_val / 16
	var positional_scaled: int = positional / 16
	return {
		"psqt": psqt,
		"positional": positional_scaled,
		"nnue_total": psqt + positional_scaled,
	}


func snapshot() -> Dictionary:
	return {
		"acc0": acc0.duplicate(),
		"acc1": acc1.duplicate(),
		"psqt0": psqt0.duplicate(),
		"psqt1": psqt1.duplicate(),
		"active": active.duplicate(),
		"feat_bucket": feat_bucket.duplicate(),
		"feat_mirror": feat_mirror.duplicate(),
		"computed": computed,
	}


func restore(s: Dictionary) -> void:
	acc0 = s["acc0"]
	acc1 = s["acc1"]
	psqt0 = s["psqt0"]
	psqt1 = s["psqt1"]
	active = s["active"]
	feat_bucket = s["feat_bucket"]
	feat_mirror = s["feat_mirror"]
	computed = s["computed"]


func _next_stamp() -> int:
	_stamp_generation += 1
	if _stamp_generation == 0x7fffffff:
		_psq_stamp.fill(0)
		_thr_stamp.fill(0)
		_stamp_generation = 1
	return _stamp_generation


func _feature_delta(
	is_psq: bool,
	old_a: PackedInt32Array, old_base: int,
	new_a: PackedInt32Array, new_base: int
) -> Dictionary:
	var old_count_off := old_base if is_psq else old_base + 65
	var new_count_off := new_base if is_psq else new_base + 65
	var old_off := old_base + (1 if is_psq else 66)
	var new_off := new_base + (1 if is_psq else 66)
	var old_n: int = old_a[old_count_off]
	var new_n: int = new_a[new_count_off]
	var stamps: PackedInt32Array = _psq_stamp if is_psq else _thr_stamp
	var removed := PackedInt32Array()
	var added := PackedInt32Array()
	var generation := _next_stamp()
	for i in range(new_n):
		stamps[new_a[new_off + i]] = generation
	for i in range(old_n):
		var idx: int = old_a[old_off + i]
		if stamps[idx] != generation:
			removed.append(idx)
	generation = _next_stamp()
	for i in range(old_n):
		stamps[old_a[old_off + i]] = generation
	for i in range(new_n):
		var idx: int = new_a[new_off + i]
		if stamps[idx] != generation:
			added.append(idx)
	return {"removed": removed, "added": added}


func _apply_frame_delta(p: int, psq_delta: Dictionary, thr_delta: Dictionary, direction: int) -> void:
	var a: PackedInt32Array = acc0 if p == 0 else acc1
	var pq: PackedInt32Array = psqt0 if p == 0 else psqt1
	for idx in psq_delta["removed"]:
		_add_psq_row(a, pq, loader.ft_psq_w, loader.ft_psqt_raw, idx, -direction)
	for idx in psq_delta["added"]:
		_add_psq_row(a, pq, loader.ft_psq_w, loader.ft_psqt_raw, idx, direction)
	for idx in thr_delta["removed"]:
		_add_thr_row(a, pq, loader.ft_threat_w, loader.ft_threat_psqt_raw, idx, -direction)
	for idx in thr_delta["added"]:
		_add_thr_row(a, pq, loader.ft_threat_w, loader.ft_threat_psqt_raw, idx, direction)


func _take_perspective_snapshot(p: int) -> Dictionary:
	var snap: Dictionary
	if _snapshot_pool.is_empty():
		var snap_acc := PackedInt32Array()
		snap_acc.resize(C.L1)
		var snap_psqt := PackedInt32Array()
		snap_psqt.resize(C.PSQTBUCKETS)
		snap = {"acc": snap_acc, "psqt": snap_psqt}
	else:
		snap = _snapshot_pool.pop_back()
	var source_acc: PackedInt32Array = acc0 if p == 0 else acc1
	var source_psqt: PackedInt32Array = psqt0 if p == 0 else psqt1
	var target_acc: PackedInt32Array = snap["acc"]
	var target_psqt: PackedInt32Array = snap["psqt"]
	for i in range(C.L1):
		target_acc[i] = source_acc[i]
	for i in range(C.PSQTBUCKETS):
		target_psqt[i] = source_psqt[i]
	return snap


func _restore_perspective_snapshot(p: int, snap: Dictionary) -> void:
	var target_acc: PackedInt32Array = acc0 if p == 0 else acc1
	var target_psqt: PackedInt32Array = psqt0 if p == 0 else psqt1
	var source_acc: PackedInt32Array = snap["acc"]
	var source_psqt: PackedInt32Array = snap["psqt"]
	for i in range(C.L1):
		target_acc[i] = source_acc[i]
	for i in range(C.PSQTBUCKETS):
		target_psqt[i] = source_psqt[i]


func _reconstruct_list(
	is_psq: bool,
	current: PackedInt32Array, current_off: int, current_n: int,
	target: PackedInt32Array, target_off: int,
	delta: Dictionary
) -> int:
	var stamps: PackedInt32Array = _psq_stamp if is_psq else _thr_stamp
	var generation := _next_stamp()
	for idx in delta["added"]:
		stamps[idx] = generation
	var count := 0
	for i in range(current_n):
		var idx: int = current[current_off + i]
		if stamps[idx] != generation:
			target[target_off + count] = idx
			count += 1
	for idx in delta["removed"]:
		target[target_off + count] = idx
		count += 1
	return count


func _rebuild_persp(p: int, act: PackedInt32Array, base: int) -> void:
	var a: PackedInt32Array = acc0 if p == 0 else acc1
	var pq: PackedInt32Array = psqt0 if p == 0 else psqt1
	var bias := loader.ft_bias_raw
	for i in range(C.L1):
		a[i] = bias.decode_s16(i * 2)
	for b in range(C.PSQTBUCKETS):
		pq[b] = 0
	var pn: int = act[base]
	var psqw := loader.ft_psq_w
	var psqt_raw := loader.ft_psqt_raw
	for k in range(pn):
		var idx: int = act[base + 1 + k]
		_add_psq_row(a, pq, psqw, psqt_raw, idx, 1)
	var tn: int = act[base + 65]
	var tw := loader.ft_threat_w
	var tpsqt := loader.ft_threat_psqt_raw
	for k in range(tn):
		var idx: int = act[base + 66 + k]
		_add_thr_row(a, pq, tw, tpsqt, idx, 1)
	if p == 0:
		acc0 = a
		psqt0 = pq
	else:
		acc1 = a
		psqt1 = pq


func _add_psq_row(a: PackedInt32Array, pq: PackedInt32Array, w: PackedByteArray, psqt_raw: PackedByteArray, idx: int, sign: int) -> void:
	var base := idx * C.L1
	var i := 0
	while i < C.L1:
		a[i] += sign * _signed_i8[w[base + i]]
		i += 1
	var pb := idx * C.PSQTBUCKETS
	for b in range(C.PSQTBUCKETS):
		pq[b] += sign * psqt_raw.decode_s32((pb + b) * 4)


func _add_thr_row(a: PackedInt32Array, pq: PackedInt32Array, w: PackedByteArray, psqt_raw: PackedByteArray, idx: int, sign: int) -> void:
	var base := idx * C.L1
	var i := 0
	while i < C.L1:
		a[i] += sign * _signed_i8[w[base + i]]
		i += 1
	var pb := idx * C.PSQTBUCKETS
	for b in range(C.PSQTBUCKETS):
		pq[b] += sign * psqt_raw.decode_s32((pb + b) * 4)


func _forward_cpu(lbucket: int) -> int:
	# Same as ref_inference forward from precomputed acc0/acc1.
	var tf: PackedInt32Array = _tf
	for p in range(2):
		var a: PackedInt32Array = acc0 if p == 0 else acc1
		var off := 512 * p
		for j in range(512):
			var s0 := clampi(a[j], 0, 255)
			var s1 := clampi(a[j + 512], 0, 255)
			tf[off + j] = (s0 * s1) / 512
	var w0: PackedInt32Array = _fc0_w_i32[lbucket]
	var b0: PackedInt32Array = _fc0_b_i32[lbucket]
	var y0: PackedInt32Array = _y0
	for o in range(C.FC0):
		var sum_: int = b0[o]
		var base := o * C.L1
		var i := 0
		while i < C.L1:
			sum_ += tf[i] * w0[base + i]
			i += 1
		y0[o] = sum_
	var c2: PackedInt32Array = _c2
	for o in range(C.FC0):
		var y := y0[o]
		c2[o] = mini(127, (y * y) >> 21)
		c2[32 + o] = clampi(y >> 7, 0, 127)
	var w1: PackedInt32Array = _fc1_w_i32[lbucket]
	var b1: PackedInt32Array = _fc1_b_i32[lbucket]
	var y1: PackedInt32Array = _y1
	for o in range(C.FC1):
		var sum_: int = b1[o]
		var base := o * 64
		var i := 0
		while i < 64:
			sum_ += c2[i] * w1[base + i]
			i += 1
		y1[o] = sum_
	for o in range(C.FC1):
		var y := y1[o]
		c2[64 + o] = mini(127, (y * y) >> 19)
		c2[96 + o] = clampi(y >> 6, 0, 127)
	var w2: PackedInt32Array = _fc2_w_i32[lbucket]
	var y2: int = _fc2_b_i32[lbucket]
	var i := 0
	while i < 128:
		y2 += c2[i] * w2[i]
		i += 1
	var fwd := y2 + (y0[30] - y0[31])
	return (fwd * 9600) / 16384
