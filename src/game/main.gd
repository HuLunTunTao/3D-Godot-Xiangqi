extends Node3D

## Coordinates the 3D board, camera, engine controller, and HUD.  Visual UI
## construction lives in game_hud.gd to keep this scene coordinator focused.
const ControllerScript = preload("res://src/game/game_controller.gd")
const BoardViewScript = preload("res://src/game/board_view.gd")
const CameraScript = preload("res://src/game/orbit_camera.gd")
const HudScript = preload("res://src/game/game_hud.gd")
const AudioScript = preload("res://src/game/game_audio.gd")
const LoaderScript = preload("res://src/game/nnue_web_loader.gd")
const Types = preload("res://addons/pikafish/core/types.gd")

var controller: XiangqiGameController
var board: XiangqiBoardView
var camera_rig: XiangqiOrbitCamera
var hud: XiangqiGameHud
var game_audio: XiangqiGameAudio
var selected_square := Types.SQ_NONE
var selected_targets := PackedInt32Array()


func _ready() -> void:
	# High-contrast round chessmen benefit from mobile hardware AA.
	if not OS.has_feature("web"):
		get_viewport().msaa_3d = Viewport.MSAA_4X
		get_viewport().screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA
	create_world()
	create_game_nodes()
	create_hud()
	if await _boot_game():
		_show_initial_position()


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
	game_audio = AudioScript.new()
	add_child(game_audio)


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
	controller.status_changed.connect(hud.set_status)
	controller.clock_changed.connect(hud.set_clock)
	controller.search_progress.connect(hud.set_search_depth)
	controller.game_state_changed.connect(hud.set_game_state)
	controller.game_ended.connect(hud.show_game_end)
	controller.board_changed.connect(_on_audio_board_changed)


func _boot_game() -> bool:
	var network_dir := ""
	if OS.has_feature("web"):
		hud.show_loading("正在准备", "正在下载棋力网络…")
		var loader: NnueWebLoader = LoaderScript.new()
		add_child(loader)
		loader.progress_changed.connect(hud.set_loading_progress)
		var err := await loader.ensure_ready()
		if err != OK:
			hud.show_loading("无法开始", loader.last_error)
			return false
		network_dir = loader.network_dir
	if controller.boot_engine(network_dir) != OK:
		hud.show_loading("无法开始", "引擎初始化失败")
		return false
	hud.hide_loading()
	return true


func _show_initial_position() -> void:
	if controller.engine != null:
		board.show_position(controller.engine.get_position_view())


func create_world() -> void:
	var environment := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color("182029")
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	# Neutral lighting preserves the intended grey palette without flattening
	# the physical response of the board and chessmen.
	env.ambient_light_color = Color.WHITE
	env.ambient_light_energy = 0.32
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	environment.environment = env
	add_child(environment)
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-58, -28, 0)
	key.light_color = Color.WHITE
	key.light_energy = 1.05
	# Board and chessmen preserve their source greys via unshaded materials;
	# the board view supplies its own soft contact shadows without shadow-map
	# aliasing or colour shifts.
	key.shadow_enabled = false
	key.directional_shadow_max_distance = 24.0
	key.directional_shadow_fade_start = 0.8
	key.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	key.directional_shadow_blend_splits = true
	add_child(key)
	var fill := OmniLight3D.new()
	fill.position = Vector3(-5, 7, 4)
	fill.light_color = Color.WHITE
	fill.light_energy = 1.6
	fill.omni_range = 18.0
	add_child(fill)


func _start_game(color_choice: String, human_seconds: float, ai_think_ms: int, ai_depth: int) -> void:
	clear_selection()
	controller.start_game(color_choice, human_seconds, ai_think_ms, ai_depth)
	camera_rig.reset_for_color(controller.human_color)


func _on_board_changed(view, move_info) -> void:
	board.show_position(view, move_info)
	clear_selection()
	hud.set_moves(controller.move_records())


func _on_audio_board_changed(_view, move_info) -> void:
	if game_audio != null:
		game_audio.play_move(move_info, controller.human_color)


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
