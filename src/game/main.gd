extends Node3D

## Coordinates the 3D board, camera, engine controller, and HUD.  Visual UI
## construction lives in game_hud.gd to keep this scene coordinator focused.
const ControllerScript = preload("res://src/game/game_controller.gd")
const BoardViewScript = preload("res://src/game/board_view.gd")
const CameraScript = preload("res://src/game/orbit_camera.gd")
const HudScript = preload("res://src/game/game_hud.gd")
const Types = preload("res://addons/pikafish/core/types.gd")

var controller: XiangqiGameController
var board: XiangqiBoardView
var camera_rig: XiangqiOrbitCamera
var hud: XiangqiGameHud
var selected_square := Types.SQ_NONE
var selected_targets := PackedInt32Array()


func _ready() -> void:
	# High-contrast round chessmen benefit from mobile hardware AA.
	get_viewport().msaa_3d = Viewport.MSAA_4X
	get_viewport().screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA
	create_world()
	create_game_nodes()
	create_hud()
	call_deferred("_show_initial_position")


func _process(_delta: float) -> void:
	board.update_face_rotation()


func create_game_nodes() -> void:
	board = BoardViewScript.new()
	add_child(board)
	camera_rig = CameraScript.new()
	camera_rig.current = true
	camera_rig.fov = 47.0
	add_child(camera_rig)
	board.set_camera(camera_rig)
	controller = ControllerScript.new()
	add_child(controller)


func create_hud() -> void:
	hud = HudScript.new()
	add_child(hud)
	hud.build(controller.human_time_limit, controller.ai_time_ms, controller.ai_depth)
	hud.game_started.connect(_start_game)
	hud.undo_requested.connect(controller.undo_full_turn)
	hud.flip_requested.connect(camera_rig.flip_view)
	hud.reset_view_requested.connect(func(): camera_rig.reset_for_color(controller.human_color))
	hud.resign_requested.connect(controller.resign)
	# The controller may emit status as soon as it receives a move, so connect
	# only after the HUD instance and its labels have been built.
	controller.board_changed.connect(_on_board_changed)
	controller.status_changed.connect(func(text, _state): hud.set_status(text))
	controller.clock_changed.connect(hud.set_clock)
	controller.search_progress.connect(hud.set_search_depth)
	controller.game_ended.connect(hud.show_game_end)


func _show_initial_position() -> void:
	if controller.engine != null:
		board.show_position(controller.engine.get_position_view())


func create_world() -> void:
	var environment := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color("182029")
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color("d9c4a4")
	env.ambient_light_energy = 0.55
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	environment.environment = env
	add_child(environment)
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-58, -28, 0)
	key.light_color = Color("ffd9ac")
	key.light_energy = 1.25
	key.shadow_enabled = true
	key.directional_shadow_max_distance = 24.0
	key.directional_shadow_fade_start = 0.8
	key.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	key.directional_shadow_blend_splits = true
	add_child(key)
	var fill := OmniLight3D.new()
	fill.position = Vector3(-5, 7, 4)
	fill.light_color = Color("8fc8ff")
	fill.light_energy = 3.0
	fill.omni_range = 18.0
	add_child(fill)


func _start_game(color_choice: String, human_seconds: float, ai_think_ms: int, ai_depth: int) -> void:
	clear_selection()
	controller.start_game(color_choice, human_seconds, ai_think_ms, ai_depth)
	camera_rig.reset_for_color(controller.human_color)


func _on_board_changed(view, move_info) -> void:
	board.show_position(view, move_info)
	clear_selection()
	hud.set_moves(controller.engine.move_history())


func _unhandled_input(event: InputEvent) -> void:
	if camera_rig.handle_event(event):
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		# iOS controls and the board share this single emulated mouse stream.
		select_at(event.position)


func select_at(screen_pos: Vector2) -> void:
	if controller.state != XiangqiGameController.State.HUMAN_TURN:
		return
	var square := board.pick_square(camera_rig, screen_pos)
	if square == Types.SQ_NONE:
		clear_selection()
		return
	if square == selected_square:
		clear_selection()
		return
	if selected_square != Types.SQ_NONE and square in selected_targets:
		if controller.request_move(selected_square, square):
			clear_selection()
		return
	var targets := controller.legal_targets(square)
	if targets.is_empty():
		clear_selection()
		return
	selected_square = square
	selected_targets = targets
	board.show_selection(selected_square, selected_targets)


func clear_selection() -> void:
	selected_square = Types.SQ_NONE
	selected_targets = PackedInt32Array()
	board.clear_selection()
