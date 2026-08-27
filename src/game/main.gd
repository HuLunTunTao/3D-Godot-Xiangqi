extends Node3D

const ControllerScript = preload("res://src/game/game_controller.gd")
const BoardViewScript = preload("res://src/game/board_view.gd")
const CameraScript = preload("res://src/game/orbit_camera.gd")
const Types = preload("res://addons/pikafish/core/types.gd")
const UiFont = preload("res://assets/fonts/SourceHanSansCN-Regular.otf")

var controller: XiangqiGameController
var board: XiangqiBoardView
var camera_rig: XiangqiOrbitCamera
var selected_square := Types.SQ_NONE
var selected_targets := PackedInt32Array()

var status_label: Label
var clock_label: Label
var depth_label: Label
var moves_label: RichTextLabel
var move_panel: PanelContainer
var move_show_button: Button
var setup_panel: PanelContainer
var end_dialog: AcceptDialog
var color_option: OptionButton
var human_time: SpinBox
var ai_preset: OptionButton
var ai_time: SpinBox
var ai_depth: SpinBox


func _ready() -> void:
	# Mobile's default forward/mobile settings favour battery life.  This board
	# has many high-contrast circular edges, so request hardware MSAA first and
	# a lightweight post-process fallback for remaining shader edges.
	get_viewport().msaa_3d = Viewport.MSAA_4X
	get_viewport().screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA
	create_world()
	board = BoardViewScript.new()
	add_child(board)
	camera_rig = CameraScript.new()
	camera_rig.current = true
	camera_rig.fov = 47.0
	add_child(camera_rig)
	board.set_camera(camera_rig)
	controller = ControllerScript.new()
	add_child(controller)
	controller.board_changed.connect(_on_board_changed)
	controller.status_changed.connect(_on_status_changed)
	controller.clock_changed.connect(_on_clock_changed)
	controller.search_progress.connect(func(depth): depth_label.text = "搜索深度：%d" % depth)
	controller.game_ended.connect(_on_game_ended)
	create_interface()
	call_deferred("_show_initial_position")


func _process(_delta: float) -> void:
	board.update_face_rotation()


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


func create_interface() -> void:
	var canvas := CanvasLayer.new()
	add_child(canvas)
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# A full-screen Control defaults to STOP, which prevents iPad drags over an
	# otherwise empty board from reaching _unhandled_input.  Child buttons keep
	# their normal STOP behaviour, while the board area now receives gestures.
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.theme = chinese_theme()
	canvas.add_child(root)
	var top := PanelContainer.new()
	top.position = Vector2(18, 16)
	top.size = Vector2(330, 112)
	top.add_theme_stylebox_override("panel", panel_style(Color("202932d9")))
	root.add_child(top)
	var info := VBoxContainer.new()
	info.add_theme_constant_override("separation", 4)
	top.add_child(info)
	status_label = Label.new()
	status_label.text = "准备开始"
	status_label.add_theme_font_size_override("font_size", 20)
	info.add_child(status_label)
	clock_label = Label.new()
	clock_label.text = "单步时间：01:00"
	info.add_child(clock_label)
	depth_label = Label.new()
	depth_label.text = "搜索深度：—"
	info.add_child(depth_label)

	var actions := HBoxContainer.new()
	actions.position = Vector2(18, 142)
	actions.add_theme_constant_override("separation", 8)
	root.add_child(actions)
	add_button(actions, "新对局", func(): setup_panel.visible = true)
	add_button(actions, "撤销回合", func(): controller.undo_full_turn())
	add_button(actions, "翻转视角", func(): camera_rig.flip_view())
	add_button(actions, "复位镜头", func(): camera_rig.reset_for_color(controller.human_color))
	add_button(actions, "认输", func(): controller.resign())

	move_panel = PanelContainer.new()
	move_panel.anchor_left = 1.0
	move_panel.anchor_right = 1.0
	move_panel.offset_left = -260
	move_panel.offset_top = 16
	move_panel.offset_right = -18
	move_panel.offset_bottom = 346
	move_panel.add_theme_stylebox_override("panel", panel_style(Color("202932d9")))
	root.add_child(move_panel)
	var move_box := VBoxContainer.new()
	move_panel.add_child(move_box)
	var move_header := HBoxContainer.new()
	move_box.add_child(move_header)
	var move_title := Label.new()
	move_title.text = "走棋记录"
	move_title.add_theme_font_size_override("font_size", 18)
	move_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	move_header.add_child(move_title)
	var move_hide_button := Button.new()
	move_hide_button.text = "收起"
	move_hide_button.custom_minimum_size = Vector2(60, 36)
	move_hide_button.pressed.connect(func(): set_move_panel_visible(false))
	move_header.add_child(move_hide_button)
	moves_label = RichTextLabel.new()
	moves_label.bbcode_enabled = true
	moves_label.fit_content = false
	moves_label.custom_minimum_size = Vector2(220, 275)
	move_box.add_child(moves_label)
	move_show_button = Button.new()
	move_show_button.text = "走棋记录"
	move_show_button.anchor_left = 1.0
	move_show_button.anchor_right = 1.0
	move_show_button.offset_left = -124
	move_show_button.offset_top = 16
	move_show_button.offset_right = -18
	move_show_button.offset_bottom = 60
	move_show_button.pressed.connect(func(): set_move_panel_visible(true))
	move_show_button.visible = false
	root.add_child(move_show_button)

	setup_panel = build_setup_panel()
	root.add_child(setup_panel)
	end_dialog = AcceptDialog.new()
	end_dialog.title = "对局结束"
	end_dialog.dialog_text = ""
	end_dialog.ok_button_text = "再来一局"
	end_dialog.confirmed.connect(func(): setup_panel.visible = true)
	root.add_child(end_dialog)


func build_setup_panel() -> PanelContainer:
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.offset_left = -205
	panel.offset_top = -250
	panel.offset_right = 205
	panel.offset_bottom = 250
	panel.add_theme_stylebox_override("panel", panel_style(Color("18212af5")))
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	panel.add_child(box)
	var title := Label.new()
	title.text = "3D 象棋 · 人机对战"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 26)
	box.add_child(title)
	box.add_child(make_hint("开局设置会自动保存。对局中每步超时即判负。"))
	color_option = OptionButton.new()
	color_option.add_item("执红（先手）", 0)
	color_option.add_item("执黑（后手）", 1)
	color_option.add_item("随机（默认）", 2)
	color_option.select(2)
	box.add_child(setting_row("执棋方", color_option))
	human_time = spin(10, 600, 5, controller.human_time_limit, "秒")
	box.add_child(setting_row("人类每步时长", human_time))
	ai_preset = OptionButton.new()
	ai_preset.add_item("休闲 · 0.5 秒 / 深度 8", 0)
	ai_preset.add_item("标准 · 1.5 秒 / 深度 12", 1)
	ai_preset.add_item("挑战 · 4 秒 / 深度 16", 2)
	ai_preset.select(1)
	ai_preset.item_selected.connect(_on_preset_selected)
	box.add_child(setting_row("AI 难度", ai_preset))
	ai_time = spin(100, 10000, 100, controller.ai_time_ms, "毫秒")
	box.add_child(setting_row("AI 最大思考", ai_time))
	ai_depth = spin(1, 30, 1, controller.ai_depth, "层")
	box.add_child(setting_row("AI 最大深度", ai_depth))
	var start := Button.new()
	start.text = "开始对局"
	start.custom_minimum_size.y = 52
	start.add_theme_font_size_override("font_size", 20)
	start.pressed.connect(_start_game)
	box.add_child(start)
	return panel


func panel_style(color: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.corner_radius_top_left = 12
	style.corner_radius_top_right = 12
	style.corner_radius_bottom_left = 12
	style.corner_radius_bottom_right = 12
	style.border_color = Color("d9b97c88")
	style.set_border_width_all(1)
	style.content_margin_left = 16
	style.content_margin_right = 16
	style.content_margin_top = 14
	style.content_margin_bottom = 14
	return style


func chinese_theme() -> Theme:
	# Ship the OFL Source Han font with the game rather than depending on iOS
	# SystemFont lookup.  That lookup yielded an empty font face on device.
	var theme := Theme.new()
	theme.default_font = UiFont
	theme.default_font_size = 18
	return theme


func make_hint(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.modulate = Color("b9c7d2")
	return label


func setting_row(title: String, control: Control) -> HBoxContainer:
	var row := HBoxContainer.new()
	var label := Label.new()
	label.text = title
	label.custom_minimum_size.x = 120
	row.add_child(label)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	control.custom_minimum_size.y = 44
	row.add_child(control)
	return row


func spin(minimum: float, maximum: float, step: float, value: float, suffix: String) -> SpinBox:
	var control := SpinBox.new()
	control.min_value = minimum
	control.max_value = maximum
	control.step = step
	control.value = value
	control.suffix = suffix
	return control


func add_button(parent: Container, title: String, callback: Callable) -> void:
	var button := Button.new()
	button.text = title
	button.custom_minimum_size = Vector2(88, 44)
	button.pressed.connect(callback)
	parent.add_child(button)


func _on_preset_selected(index: int) -> void:
	var values := [[500, 8], [1500, 12], [4000, 16]]
	ai_time.value = values[index][0]
	ai_depth.value = values[index][1]


func _start_game() -> void:
	var choices := ["red", "black", "random"]
	setup_panel.visible = false
	selected_square = Types.SQ_NONE
	board.clear_selection()
	controller.start_game(choices[color_option.selected], human_time.value, int(ai_time.value), int(ai_depth.value))
	camera_rig.reset_for_color(controller.human_color)


func _on_board_changed(view, move_info) -> void:
	board.show_position(view, move_info)
	selected_square = Types.SQ_NONE
	board.clear_selection()
	var entries: Array[String] = []
	for info in controller.engine.move_history():
		entries.append(info.uci)
	moves_label.text = "[color=#d8e6ee]%s[/color]" % "\n".join(entries)


func _on_status_changed(text: String, _state: String) -> void:
	status_label.text = text


func _on_clock_changed(seconds: float) -> void:
	var whole := ceili(seconds)
	clock_label.text = "单步时间：%02d:%02d" % [whole / 60, whole % 60]


func _on_game_ended(title: String, detail: String) -> void:
	end_dialog.title = title
	end_dialog.dialog_text = detail
	end_dialog.popup_centered()


func set_move_panel_visible(visible: bool) -> void:
	move_panel.visible = visible
	move_show_button.visible = not visible


func _unhandled_input(event: InputEvent) -> void:
	var handled := camera_rig.handle_event(event)
	if handled:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		# Keep the iOS touch-to-mouse path enabled: Control buttons use it.  The
		# 3D board also accepts this one pointer stream, so a tap is committed
		# exactly once.  Native ScreenTouch below is reserved for camera gestures.
		select_at(event.position)


func select_at(screen_pos: Vector2) -> void:
	if controller.state != XiangqiGameController.State.HUMAN_TURN:
		return
	var square := board.pick_square(camera_rig, screen_pos)
	if square == Types.SQ_NONE:
		selected_square = Types.SQ_NONE
		board.clear_selection()
		return
	if square == selected_square:
		selected_square = Types.SQ_NONE
		selected_targets = PackedInt32Array()
		board.clear_selection()
		return
	if selected_square != Types.SQ_NONE and square in selected_targets:
		if controller.request_move(selected_square, square):
			selected_square = Types.SQ_NONE
			board.clear_selection()
		return
	var targets := controller.legal_targets(square)
	if targets.is_empty():
		selected_square = Types.SQ_NONE
		board.clear_selection()
		return
	selected_square = square
	selected_targets = targets
	board.show_selection(selected_square, selected_targets)
