## Pure-GDScript full NNUE inference (accumulator + transform + forward).
## Slow but obviously-correct reference. Must match the pikafish oracle internal integer.
class_name PikafishCpuInference
extends RefCounted
const C = preload("res://addons/pikafish/nnue/consts.gd")
const XBoard = preload("res://addons/pikafish/nnue/board.gd")
const NNUELoader = preload("res://addons/pikafish/nnue/loader.gd")
const XFeatures = preload("res://addons/pikafish/nnue/features.gd")

var loader: NNUELoader
var features: XFeatures


func _init(ld: NNUELoader, ft: XFeatures) -> void:
	loader = ld
	features = ft


static func _i8(arr: PackedByteArray, idx: int) -> int:
	var b := arr[idx]
	return b if b < 128 else b - 256


func evaluate(pos: XBoard) -> int:
	var terms: Dictionary = evaluate_terms(pos)
	return int(terms["nnue_total"])


## Raw Network::evaluate components. This deliberately does not apply the
## search-only Eval::evaluate scaling wrapper.
func evaluate_terms(pos: XBoard) -> Dictionary:
	var stm := pos.side_to_move()
	var perspectives := [stm, C.flip_color(stm)]
	var lbucket := features.make_layer_stack_bucket(pos)

	var acc0 := PackedInt32Array()
	var acc1 := PackedInt32Array()
	acc0.resize(C.L1)
	acc1.resize(C.L1)
	var accs := [acc0, acc1]
	var psqt0 := 0
	var psqt1 := 0
	var psqt_raw: PackedByteArray = loader.ft_psqt_raw
	var tpsqt_raw: PackedByteArray = loader.ft_threat_psqt_raw

	for p in range(2):
		var persp: int = perspectives[p]
		var fb := features.make_feature_bucket(persp, pos)
		var bucket: int = fb.bucket
		var mirror: bool = fb.mirror
		var psq_active := features.append_active_psq(persp, pos, bucket, mirror)
		var threat_active := features.append_active_threats(persp, pos, mirror)

		var a: PackedInt32Array = accs[p]
		var bias_raw := loader.ft_bias_raw
		for i in range(C.L1):
			a[i] = bias_raw.decode_s16(i * 2)
		var psqw := loader.ft_psq_w
		for idx in psq_active:
			var base := idx * C.L1
			var i := 0
			while i < C.L1:
				var b := psqw[base + i]
				a[i] += b if b < 128 else b - 256
				i += 1
		var tw := loader.ft_threat_w
		for idx in threat_active:
			var base := idx * C.L1
			var i := 0
			while i < C.L1:
				var b := tw[base + i]
				a[i] += b if b < 128 else b - 256
				i += 1
		accs[p] = a  # PackedInt32Array is a value type; write back

		var psqt_sum := 0
		for idx in psq_active:
			psqt_sum += psqt_raw.decode_s32((idx * C.PSQTBUCKETS + lbucket) * 4)
		for idx in threat_active:
			psqt_sum += tpsqt_raw.decode_s32((idx * C.PSQTBUCKETS + lbucket) * 4)
		if p == 0:
			psqt0 = psqt_sum
		else:
			psqt1 = psqt_sum

	var psqt_val: int = (psqt0 - psqt1) / 2

	# transform -> 1024 u8
	var tf := PackedByteArray()
	tf.resize(C.L1)
	for p in range(2):
		var a: PackedInt32Array = accs[p]
		var off := 512 * p
		for j in range(512):
			var s0 := clampi(a[j], 0, 255)
			var s1 := clampi(a[j + 512], 0, 255)
			tf[off + j] = (s0 * s1) / 512

	# forward pass for network[lbucket]
	var st := lbucket
	var w0: PackedByteArray = loader.fc0_w[st]
	var b0_raw: PackedByteArray = loader.fc0_bias_raw[st]
	var y0 := PackedInt32Array()
	y0.resize(C.FC0)
	for o in range(C.FC0):
		var sum_ := b0_raw.decode_s32(o * 4)
		var base := o * C.L1
		var i := 0
		while i < C.L1:
			var b := w0[base + i]
			sum_ += int(tf[i]) * (b if b < 128 else b - 256)
			i += 1
		y0[o] = sum_

	var concat2 := PackedByteArray()
	concat2.resize(128)
	for o in range(C.FC0):
		var y := y0[o]
		concat2[o] = mini(127, (y * y) >> 21)        # sqr0 (64-bit mul like C++ long long)
		concat2[32 + o] = clampi(y >> 7, 0, 127)      # clip0

	var w1: PackedByteArray = loader.fc1_w[st]
	var b1_raw: PackedByteArray = loader.fc1_bias_raw[st]
	var y1 := PackedInt32Array()
	y1.resize(C.FC1)
	for o in range(C.FC1):
		var sum_ := b1_raw.decode_s32(o * 4)
		var base := o * 64
		var i := 0
		while i < 64:
			var b := w1[base + i]
			sum_ += int(concat2[i]) * (b if b < 128 else b - 256)
			i += 1
		y1[o] = sum_

	for o in range(C.FC1):
		var y := y1[o]
		concat2[64 + o] = mini(127, (y * y) >> 19)    # sqr1
		concat2[96 + o] = clampi(y >> 6, 0, 127)      # clip1

	var w2: PackedByteArray = loader.fc2_w[st]
	var y2: int = loader.fc2_bias_raw[st].decode_s32(0)
	var i := 0
	while i < 128:
		var b := w2[i]
		y2 += int(concat2[i]) * (b if b < 128 else b - 256)
		i += 1

	var fwd_out := y2 + (y0[30] - y0[31])
	var positional := (fwd_out * 9600) / 16384

	var psqt: int = psqt_val / 16
	var positional_scaled: int = positional / 16
	return {
		"psqt": psqt,
		"positional": positional_scaled,
		"nnue_total": psqt + positional_scaled,
	}


func evaluate_batch(positions: Array) -> PackedInt32Array:
	var n := positions.size()
	var res := PackedInt32Array()
	res.resize(n)
	for i in range(n):
		res[i] = evaluate(positions[i])
	return res
