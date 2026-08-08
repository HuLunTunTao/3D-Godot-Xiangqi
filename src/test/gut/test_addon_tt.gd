extends GutTest

## Targeted TT parity: value_to_tt / value_from_tt / TTWriter::penalize.
## Upstream: Pikafish 2c5c998c, src/search.cpp + src/tt.cpp

const T = preload("res://addons/pikafish/core/types.gd")
const TT = preload("res://addons/pikafish/search/tt.gd")


func test_value_to_tt_mate_ply_adjustment() -> void:
	var mate := T.mate_in(10)
	assert_eq(TT.value_to_tt(mate, 5), mate + 5)
	assert_eq(TT.value_to_tt(T.mated_in(7), 3), T.mated_in(7) - 3)
	assert_eq(TT.value_to_tt(42, 9), 42)
	assert_eq(TT.value_to_tt(T.VALUE_NONE, 4), T.VALUE_NONE)


func test_value_from_tt_mate_ply_roundtrip() -> void:
	var ply := 5
	var root_mate := T.mate_in(10)
	var stored := TT.value_to_tt(root_mate, ply)
	# r60c=0 → remaining 120; mate distance 10 is fine
	assert_eq(TT.value_from_tt(stored, ply, 0), root_mate)
	var root_loss := T.mated_in(8)
	var stored_loss := TT.value_to_tt(root_loss, ply)
	assert_eq(TT.value_from_tt(stored_loss, ply, 0), root_loss)
	assert_eq(TT.value_from_tt(T.VALUE_NONE, ply, 0), T.VALUE_NONE)
	assert_eq(TT.value_from_tt(100, ply, 0), 100)


func test_value_from_tt_rule60_fake_mate_downgrade_win() -> void:
	# TT stores mate-in-100 from current position; r60c=30 → budget 90
	var v := T.VALUE_MATE - 100
	assert_true(T.is_win(v))
	assert_eq(TT.value_from_tt(v, 4, 30), T.VALUE_MATE_IN_MAX_PLY - 1)
	# Exactly at budget: VALUE_MATE - v == 90, not greater → no downgrade
	var at_budget := T.VALUE_MATE - 90
	assert_eq(TT.value_from_tt(at_budget, 4, 30), at_budget - 4)
	# Just over budget
	var over := T.VALUE_MATE - 91
	assert_eq(TT.value_from_tt(over, 4, 30), T.VALUE_MATE_IN_MAX_PLY - 1)


func test_value_from_tt_rule60_fake_mate_downgrade_loss() -> void:
	var v := -T.VALUE_MATE + 100  # mated in 100 from current
	assert_true(T.is_loss(v))
	assert_eq(TT.value_from_tt(v, 4, 30), T.VALUE_MATED_IN_MAX_PLY + 1)
	var at_budget := -T.VALUE_MATE + 90
	assert_eq(TT.value_from_tt(at_budget, 4, 30), at_budget + 4)
	var over := -T.VALUE_MATE + 91
	assert_eq(TT.value_from_tt(over, 4, 30), T.VALUE_MATED_IN_MAX_PLY + 1)


func test_penalize_does_not_drop_below_zero() -> void:
	var tt := TT.new()
	tt.resize_mb(1)
	var key := 0x12345678
	var hit: Dictionary = tt.probe(key)
	var idx: int = int(hit["write_index"])
	tt.write(idx, key, 100, false, T.BOUND_LOWER, 5, T.MOVE_NONE, 0)
	assert_eq(tt.depth8[idx], 5 - T.DEPTH_NONE)  # depth8 = depth - DEPTH_NONE
	var before: int = tt.depth8[idx]
	tt.penalize(idx, 1)
	assert_eq(tt.depth8[idx], before - 1)
	tt.penalize(idx, 10_000)
	assert_eq(tt.depth8[idx], 0)
	tt.penalize(idx, 1)
	assert_eq(tt.depth8[idx], 0)
