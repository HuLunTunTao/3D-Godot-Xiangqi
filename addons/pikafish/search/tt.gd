class_name PikafishTT
extends RefCounted

## Upstream: Pikafish 2c5c998c, src/tt.cpp — single-thread SoA (no racy atomics).
## ClusterSize = 3. Fields packed like TTEntry (key16/depth8/genBound8/move16/value16/eval16).

const T = preload("res://addons/pikafish/core/types.gd")

const CLUSTER_SIZE := 3
const GENERATION_BITS := 5
const GENERATION_MASK := (1 << GENERATION_BITS) - 1
const BOUND_SHIFT := GENERATION_BITS
const BOUND_MASK := 0b11 << BOUND_SHIFT
const PV_SHIFT := BOUND_SHIFT + 2
const PV_MASK := 1 << PV_SHIFT

var cluster_count: int = 0
var generation8: int = 0

## Flat SoA: index = cluster * CLUSTER_SIZE + slot
var key16: PackedInt32Array = PackedInt32Array()
var depth8: PackedByteArray = PackedByteArray()
var gen_bound8: PackedByteArray = PackedByteArray()
var move16: PackedInt32Array = PackedInt32Array()
var value16: PackedInt32Array = PackedInt32Array()
var eval16: PackedInt32Array = PackedInt32Array()


func resize_mb(mb_size: int) -> void:
	## Approximate upstream: mb → cluster count. Entry ~10 bytes × 3 ≈ 32 bytes/cluster.
	var bytes: int = maxi(mb_size, 1) * 1024 * 1024
	cluster_count = maxi(int(bytes / 32), 1)
	var n := cluster_count * CLUSTER_SIZE
	key16.resize(n)
	depth8.resize(n)
	gen_bound8.resize(n)
	move16.resize(n)
	value16.resize(n)
	eval16.resize(n)
	clear()


func clear() -> void:
	key16.fill(0)
	depth8.fill(0)
	gen_bound8.fill(0)
	move16.fill(0)
	value16.fill(0)
	eval16.fill(0)
	generation8 = 0


func new_search() -> void:
	generation8 = (generation8 + 1) & GENERATION_MASK


func generation() -> int:
	return generation8


func _first_index(key: int) -> int:
	## Upstream first_entry: mul_hi64 style — use low bits of key.
	if cluster_count <= 0:
		return 0
	var u: int = key & 0xFFFFFFFF
	return (absi(u) % cluster_count) * CLUSTER_SIZE


func _relative_age(idx: int) -> int:
	return (generation8 - gen_bound8[idx]) & GENERATION_MASK


func _is_occupied(idx: int) -> bool:
	return depth8[idx] != 0


func probe(key: int) -> Dictionary:
	## Returns {found, move, value, eval, depth, bound, is_pv, write_index}
	var base := _first_index(key)
	var k16: int = key & 0xFFFF
	var found_idx := -1
	for i in range(CLUSTER_SIZE):
		var idx := base + i
		if key16[idx] == k16 and _is_occupied(idx):
			found_idx = idx
			break
	var replace := base
	for i in range(1, CLUSTER_SIZE):
		var idx2 := base + i
		var score_r := depth8[replace] - 8 * _relative_age(replace)
		var score_i := depth8[idx2] - 8 * _relative_age(idx2)
		if score_r > score_i:
			replace = idx2
	var write_idx := found_idx if found_idx >= 0 else replace
	if found_idx < 0:
		return {
			"found": false,
			"move": T.MOVE_NONE,
			"value": T.VALUE_NONE,
			"eval": T.VALUE_NONE,
			"depth": T.DEPTH_NONE,
			"bound": T.BOUND_NONE,
			"is_pv": false,
			"write_index": write_idx,
		}
	var gb: int = gen_bound8[found_idx]
	return {
		"found": true,
		"move": move16[found_idx],
		"value": value16[found_idx],
		"eval": eval16[found_idx],
		"depth": T.DEPTH_NONE + depth8[found_idx],
		"bound": (gb & BOUND_MASK) >> BOUND_SHIFT,
		"is_pv": (gb & PV_MASK) != 0,
		"write_index": write_idx,
	}


func write(
	write_index: int,
	key: int,
	value: int,
	is_pv: bool,
	bound: int,
	depth: int,
	move: int,
	eval: int
) -> void:
	## Upstream TTEntry::save
	var k16: int = key & 0xFFFF
	if move != T.MOVE_NONE or k16 != key16[write_index]:
		move16[write_index] = move
	if (
		bound == T.BOUND_EXACT
		or k16 != key16[write_index]
		or depth - T.DEPTH_NONE + (2 if is_pv else 0) > depth8[write_index] - 4
		or _relative_age(write_index) != 0
	):
		if depth <= T.DEPTH_NONE:
			return
		key16[write_index] = k16
		depth8[write_index] = depth - T.DEPTH_NONE
		gen_bound8[write_index] = generation8 | (bound << BOUND_SHIFT) | ((1 if is_pv else 0) << PV_SHIFT)
		value16[write_index] = value
		eval16[write_index] = eval
	elif depth8[write_index] + T.DEPTH_NONE >= 5:
		var b: int = (gen_bound8[write_index] & BOUND_MASK) >> BOUND_SHIFT
		if b != T.BOUND_EXACT:
			var v: int = value16[write_index]
			if absi(v) < T.VALUE_INFINITE and T.is_decisive(v):
				depth8[write_index] = maxi(depth8[write_index] - 1, 0)


static func value_to_tt(v: int, ply: int) -> int:
	## Upstream value_to_tt
	if v == T.VALUE_NONE:
		return v
	if T.is_win(v):
		return v + ply
	if T.is_loss(v):
		return v - ply
	return v


static func value_from_tt(v: int, ply: int, r50: int) -> int:
	## Upstream value_from_tt (simplified without 50-move mate clamp edge cases first)
	if v == T.VALUE_NONE:
		return v
	if T.is_win(v):
		return v - ply
	if T.is_loss(v):
		return v + ply
	return v
