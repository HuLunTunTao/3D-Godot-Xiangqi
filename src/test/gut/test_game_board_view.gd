extends GutTest

const BoardView = preload("res://src/game/board_view.gd")
const OrbitCamera = preload("res://src/game/orbit_camera.gd")
const Types = preload("res://addons/pikafish/core/types.gd")


func test_all_ninety_squares_have_a_stable_world_mapping() -> void:
	var board = BoardView.new()
	var seen: Dictionary = {}
	for square in range(Types.SQUARE_NB):
		var point: Vector3 = board.square_to_world(square)
		assert_false(seen.has(point), "square %d overlaps another square" % square)
		seen[point] = true
		var expected_x := (square % 9 - 4.0) * BoardView.SPACING
		var expected_z := (square / 9 - 4.5) * BoardView.SPACING
		assert_almost_eq(point.x, expected_x, 0.001)
		assert_almost_eq(point.z, expected_z, 0.001)
	assert_eq(seen.size(), Types.SQUARE_NB)
	board.free()


func test_camera_is_clamped_and_flips_to_the_opposite_side() -> void:
	var camera = OrbitCamera.new()
	add_child(camera)
	camera.distance = 100.0
	camera.pitch = deg_to_rad(90.0)
	camera.update_transform()
	assert_eq(camera.distance, camera.max_distance)
	assert_eq(camera.pitch, camera.max_pitch)
	camera.reset_for_color(Types.COLOR_WHITE)
	var white_yaw: float = camera.yaw
	assert_almost_eq(absf(wrapf(white_yaw - PI, -PI, PI)), 0.0, 0.001)
	camera.reset_for_color(Types.COLOR_BLACK)
	assert_almost_eq(absf(wrapf(camera.yaw, -PI, PI)), 0.0, 0.001)
	camera.reset_for_color(Types.COLOR_WHITE)
	camera.flip_view()
	assert_almost_eq(absf(wrapf(camera.yaw - white_yaw, -PI, PI)), PI, 0.001)
	remove_child(camera)
	camera.free()


func test_piece_assets_resolve_for_both_sides() -> void:
	var board = BoardView.new()
	assert_eq(board.piece_asset(Types.W_KING), "res://assets/pieces/king0.svg")
	assert_eq(board.piece_asset(Types.B_KING), "res://assets/pieces/king1.svg")
	board.free()


func test_longer_piece_moves_have_a_higher_bounded_arc() -> void:
	var board = BoardView.new()
	var one_step := board.move_arc_height(Vector3.ZERO, Vector3(BoardView.SPACING, 0.0, 0.0))
	var knight_step := board.move_arc_height(Vector3.ZERO, Vector3(BoardView.SPACING, 0.0, BoardView.SPACING * 2.0))
	var long_step := board.move_arc_height(Vector3.ZERO, Vector3(BoardView.SPACING * 8.0, 0.0, 0.0))
	assert_gt(knight_step, one_step)
	assert_gt(long_step, knight_step)
	assert_eq(long_step, 0.55)
	board.free()
