extends Node3D

## Coordinates the 3D board, camera, engine controller, and HUD.  Visual UI
## construction lives in game_hud.gd to keep this scene coordinator focused.
const ControllerScript = preload("res://src/game/game_controller.gd")
const BoardViewScript = preload("res://src/game/board_view.gd")
const CameraScript = preload("res://src/game/orbit_camera.gd")
const HudScript = preload("res://src/game/game_hud.gd")
const AudioScript = preload("res://src/game/game_audio.gd")
const LoaderScript = preload("res://src/game/nnue_web_loader.gd")
const ExternalSourceScript = preload("res://src/game/external_game_source.gd")
const Types = preload("res://addons/pikafish/core/types.gd")
const MAX_QUEUED_EXTERNAL_SNAPSHOTS := 512

var controller: XiangqiGameController
var board: XiangqiBoardView
var camera_rig: XiangqiOrbitCamera
var hud: XiangqiGameHud
var game_audio: XiangqiGameAudio
var external_source
var _external_presentation := {
	"red_name": "红方",
	"black_name": "黑方",
	"latency_ms": 0,
	"info": "",
}
var selected_square := Types.SQ_NONE
var selected_targets := PackedInt32Array()
var _queued_external_snapshots: Array[Dictionary] = []


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
	board.move_animation_finished.connect(_on_board_move_animation_finished)
	camera_rig = CameraScript.new()
	camera_rig.current = true
	camera_rig.fov = 47.0
	add_child(camera_rig)
	board.set_camera(camera_rig)
	controller = ControllerScript.new()
	add_child(controller)
	external_source = ExternalSourceScript.new()
	add_child(external_source)
	external_source.snapshot_received.connect(_on_external_snapshot)
	external_source.connection_changed.connect(_on_external_connection_changed)
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
	hud.external_requested.connect(_start_external_spectator)
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
		hud.show_loading("正在准备", "%s…" % LoaderScript.STATUS_CHECKING)
		LoaderScript.request_persistent_storage()
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
	if OS.has_feature("web"):
		hud.show_loading("正在准备", XiangqiGameController.STATUS_WARMING_SEARCH)
		await get_tree().process_frame
		await controller.warm_search_tables()
	hud.hide_loading()
	hud.maybe_show_homescreen_hint()
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
	external_source.stop()
	_queued_external_snapshots.clear()
	LoaderScript.request_persistent_storage()
	clear_selection()
	hud.set_spectator_mode(false)
	controller.start_game(color_choice, human_seconds, ai_think_ms, ai_depth)
	camera_rig.reset_for_color(controller.human_color)


func _start_external_spectator(config: Dictionary) -> void:
	clear_selection()
	_queued_external_snapshots.clear()
	_external_presentation = {
		"red_name": str(config.get("red_name", "红方")),
		"black_name": str(config.get("black_name", "黑方")),
		"latency_ms": int(config.get("latency_ms", 0)),
		"info": str(config.get("info", "")),
	}
	hud.set_spectator_mode(true)
	hud.set_external_presentation(
		str(_external_presentation.red_name), str(_external_presentation.black_name),
		int(_external_presentation.latency_ms), str(_external_presentation.info)
	)
	controller.start_external_spectator()
	hud.set_external_endpoint(str(config.get("host", "127.0.0.1")), int(config.get("port", 19190)))
	hud.set_external_connection("connecting")
	camera_rig.reset_for_color(Types.COLOR_WHITE)
	external_source.start(str(config.get("host", "127.0.0.1")), int(config.get("port", 19190)))


func _on_external_snapshot(event: Dictionary) -> void:
	# The producer is never back-pressured by presentation.  Keep every normal
	# snapshot while the 0.34 s board animation runs; on an extreme backlog,
	# retain only the newest authoritative FEN and resynchronise cleanly.
	if _queued_external_snapshots.size() >= MAX_QUEUED_EXTERNAL_SNAPSHOTS:
		_queued_external_snapshots.clear()
	_queued_external_snapshots.append(event)
	_drain_external_snapshots()


func _drain_external_snapshots() -> void:
	if board.is_move_animating() or _queued_external_snapshots.is_empty():
		return
	var event: Dictionary = _queued_external_snapshots.pop_front()
	# Event metadata is optional: configuration values remain visible until the
	# authoritative producer provides a replacement.
	for key in ["red_name", "black_name", "latency_ms", "info"]:
		if event.has(key):
			_external_presentation[key] = event[key]
	hud.set_external_presentation(
		str(_external_presentation.red_name), str(_external_presentation.black_name),
		int(_external_presentation.latency_ms), str(_external_presentation.info)
	)
	var thinking_side := str(event.get("thinking_side", ""))
	if thinking_side in ["red", "black"]:
		hud.set_external_turn(
			str(event.get("thinking_name", "红方" if thinking_side == "red" else "黑方")),
			thinking_side == "red",
			str(event.get("completed_name", "")),
			int(event.get("think_ms", -1)),
			str(event.get("info", ""))
		)
	if controller.apply_external_snapshot(event) == OK:
		hud.set_moves(controller.move_records())
		var result := str(event.get("result", "ongoing"))
		if result in ["finished", "error"]:
			hud.set_external_result(result, str(event.get("info", "")))
			if result == "finished":
				var winner := str(event.get("winner", ""))
				var winner_name := ""
				if winner == "red":
					winner_name = str(event.get("red_name", _external_presentation.red_name))
				elif winner == "black":
					winner_name = str(event.get("black_name", _external_presentation.black_name))
				hud.show_game_end("对局结束" if winner_name.is_empty() else "%s 胜" % winner_name, str(event.get("info", "")))
	if not board.is_move_animating() and not _queued_external_snapshots.is_empty():
		call_deferred("_drain_external_snapshots")


func _on_board_move_animation_finished() -> void:
	if controller.state == XiangqiGameController.State.EXTERNAL_SPECTATOR:
		_drain_external_snapshots()


func _on_external_connection_changed(state: String, detail: String) -> void:
	if controller.state == XiangqiGameController.State.EXTERNAL_SPECTATOR:
		hud.set_external_connection(state)
		hud.set_status(detail, "external" if state == "connected" else "error")


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
