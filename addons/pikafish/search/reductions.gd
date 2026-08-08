class_name PikafishReductions
extends RefCounted

## Upstream: Pikafish 2c5c998c, Search::Worker reductions table + reduction().
## reductions[i] = int(17.40 * log(i)); used by LMR when enable_lmr is on.

const T = preload("res://addons/pikafish/core/types.gd")

## Indexed by depth or moveNumber; size MAX_PLY + 10 like upstream.
var table: PackedInt32Array = PackedInt32Array()
var root_delta: int = 1


func _init() -> void:
	init_tables()


func init_tables() -> void:
	var n: int = T.MAX_PLY + 10
	table.resize(n)
	table[0] = 0
	for i in range(1, n):
		table[i] = int(1740.0 / 100.0 * log(float(i)))


func set_root_delta(delta: int) -> void:
	root_delta = maxi(delta, 1)


## Upstream: Search::Worker::reduction(improving, depth, moveNumber, delta)
func reduction(improving: bool, depth: int, move_number: int, delta: int) -> int:
	var d: int = clampi(depth, 0, table.size() - 1)
	var mn: int = clampi(move_number, 0, table.size() - 1)
	var scale: int = table[d] * table[mn]
	var r: int = scale - delta * 1138 / root_delta + 1934
	if not improving:
		r += scale * 166 / 512
	return r
