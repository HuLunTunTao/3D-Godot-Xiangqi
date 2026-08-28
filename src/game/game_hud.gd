class_name XiangqiGameHud
extends CanvasLayer

## Empty canvas space stays transparent to input; controls retain their own hit
## testing while 3D piece selection and camera gestures own the board.
signal game_started(color_choice: String, human_seconds: float, ai_think_ms: int, ai_depth: int)
signal undo_requested
signal flip_requested
signal reset_view_requested
signal resign_requested

const UiFont = preload("res://assets/fonts/SourceHanSansCN-Regular.otf")
const LoaderScript = preload("res://src/game/nnue_web_loader.gd")
const RED_TINT := Color("b66d68")
const MUTED := Color("aab4ba")
const HOMESCREEN_HINT_STAMP := "user://web_homescreen_hint_dismissed"
const HOMESCREEN_HINT_TEXT := "添加到主屏幕后，棋力网络更不容易被清掉。"

var _root: Control
var status_panel: PanelContainer
var action_panel: PanelContainer
var action_show_button: Button
var move_panel: PanelContainer
var move_show_button: Button
var setup_panel: PanelContainer
var end_overlay: ColorRect
var end_panel: PanelContainer
var end_title_label: Label
var end_detail_label: Label
var load_overlay: ColorRect
var load_panel: PanelContainer
var load_title_label: Label
var load_detail_label: Label
var load_bar: ProgressBar
var homescreen_hint: Control
var status_label: Label
var player_label: Label
var clock_label: Label
var depth_label: Label
var moves_label: RichTextLabel
var color_option: OptionButton
var human_time: SpinBox
var ai_preset: OptionButton
var ai_time: SpinBox
var ai_depth: SpinBox
var _gameplay_nodes: Array[Control] = []
var _move_open := false
var _action_open := false
var _move_tween: Tween
var _action_tween: Tween


func build(default_human_time: float, default_ai_time_ms: int, default_ai_depth: int) -> void:
	_root = Control.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.theme = chinese_theme()
	add_child(_root)
	build_status(_root)
	build_actions(_root)
	build_move_history(_root)
	setup_panel = build_setup_panel(default_human_time, default_ai_time_ms, default_ai_depth)
	_root.add_child(setup_panel)
	build_end_overlay(_root)
	build_load_overlay(_root)
	_root.resized.connect(_relayout)
	set_gameplay_visible(false)
	call_deferred("_relayout")


func set_status(text: String, state := "") -> void:
	status_label.text = text
	status_label.modulate = RED_TINT if state == "finished" else Color.WHITE


func set_game_state(info: Dictionary) -> void:
	var human_is_red := int(info.get("human_color", 0)) == 0
	var side_is_red := int(info.get("side_to_move", 0)) == 0
	player_label.text = "你：%s　 AI：%s" % ["红方" if human_is_red else "黑方", "黑方" if human_is_red else "红方"]
	player_label.modulate = RED_TINT if human_is_red else MUTED
	var state := str(info.get("state", "setup"))
	clock_label.visible = state == "human_turn"
	clock_label.text = "本步 %s" % _format_time(float(info.get("human_time_left", 0.0)))
	depth_label.visible = state == "ai_thinking"
	depth_label.text = "AI 思考中 · 深度 %s" % ("—" if int(info.get("ai_depth", 0)) <= 0 else str(info.get("ai_depth", 0)))
	if state in ["human_turn", "ai_thinking"]:
		status_label.text = "%s行棋" % ("红方" if side_is_red else "黑方")
		status_label.modulate = RED_TINT if side_is_red else Color.WHITE


func set_clock(seconds: float) -> void:
	clock_label.text = "本步 %s" % _format_time(seconds)


func set_search_depth(depth: int) -> void:
	depth_label.text = "AI 思考中 · 深度 %d" % depth


func set_moves(history: Array) -> void:
	if history.is_empty():
		moves_label.text = "[color=#9da8ae]尚无走棋记录[/color]"
		return
	var lines: Array[String] = []
	for record in history:
		var turn := int(record.get("turn", 0))
		var side := "红" if int(record.get("side", 0)) == 0 else "黑"
		var notation := str(record.get("notation", record.get("uci", "")))
		var uci := str(record.get("uci", ""))
		lines.append("[color=#b8c2c7]第 %d 回合 · %s方[/color]\n[font_size=20][color=#edf1f2]%s[/color][/font_size]\n[color=#8d9aa1]%s[/color]" % [turn, side, notation, uci])
	moves_label.text = "\n\n".join(lines)
	moves_label.scroll_to_line(maxi(0, moves_label.get_line_count() - 1))


func show_game_end(title: String, detail: String) -> void:
	set_move_panel_visible(false)
	set_action_menu_visible(false)
	end_title_label.text = title
	end_detail_label.text = detail
	end_overlay.visible = true
	call_deferred("_relayout")


func show_setup() -> void:
	set_move_panel_visible(false)
	set_action_menu_visible(false)
	set_gameplay_visible(false)
	setup_panel.visible = true
	call_deferred("_relayout")


func build_status(root: Control) -> void:
	status_panel = PanelContainer.new()
	status_panel.add_theme_stylebox_override("panel", panel_style())
	root.add_child(status_panel)
	_gameplay_nodes.append(status_panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 3)
	status_panel.add_child(box)
	status_label = Label.new()
	status_label.text = "准备开始"
	status_label.add_theme_font_size_override("font_size", 21)
	box.add_child(status_label)
	player_label = Label.new()
	player_label.text = "你：—　 AI：—"
	player_label.add_theme_font_size_override("font_size", 15)
	box.add_child(player_label)
	clock_label = Label.new()
	clock_label.text = "本步 01:00"
	clock_label.add_theme_font_size_override("font_size", 17)
	box.add_child(clock_label)
	depth_label = Label.new()
	depth_label.text = "AI 思考中 · 深度 —"
	depth_label.add_theme_font_size_override("font_size", 16)
	box.add_child(depth_label)


func build_actions(root: Control) -> void:
	action_panel = PanelContainer.new()
	action_panel.add_theme_stylebox_override("panel", panel_style())
	root.add_child(action_panel)
	_gameplay_nodes.append(action_panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	action_panel.add_child(box)
	var game_label := menu_section_label("对局")
	box.add_child(game_label)
	var game_actions := GridContainer.new()
	game_actions.columns = 2
	game_actions.add_theme_constant_override("h_separation", 8)
	game_actions.add_theme_constant_override("v_separation", 8)
	box.add_child(game_actions)
	add_menu_button(game_actions, "新对局", show_setup)
	add_menu_button(game_actions, "撤销回合", func(): undo_requested.emit())
	box.add_child(separator())
	box.add_child(menu_section_label("视角"))
	var camera_actions := GridContainer.new()
	camera_actions.columns = 2
	camera_actions.add_theme_constant_override("h_separation", 8)
	camera_actions.add_theme_constant_override("v_separation", 8)
	box.add_child(camera_actions)
	add_menu_button(camera_actions, "翻转视角", func(): flip_requested.emit())
	add_menu_button(camera_actions, "复位镜头", func(): reset_view_requested.emit())
	var resign := Button.new()
	resign.text = "认输"
	resign.custom_minimum_size = Vector2(0, 44)
	resign.add_theme_stylebox_override("normal", button_style(Color("3a292b")))
	resign.add_theme_stylebox_override("hover", button_style(Color("543638")))
	resign.pressed.connect(func():
		set_action_menu_visible(false)
		resign_requested.emit()
	)
	box.add_child(resign)
	action_show_button = Button.new()
	action_show_button.text = "操作"
	action_show_button.custom_minimum_size = Vector2(64, 44)
	action_show_button.add_theme_stylebox_override("normal", button_style(Color("252d32")))
	action_show_button.add_theme_stylebox_override("hover", button_style(Color("3a464d")))
	action_show_button.pressed.connect(func(): set_action_menu_visible(not _action_open))
	root.add_child(action_show_button)
	_gameplay_nodes.append(action_show_button)
	set_action_menu_visible(false)


func build_move_history(root: Control) -> void:
	move_panel = PanelContainer.new()
	move_panel.add_theme_stylebox_override("panel", panel_style())
	root.add_child(move_panel)
	_gameplay_nodes.append(move_panel)
	var move_box := VBoxContainer.new()
	move_box.add_theme_constant_override("separation", 10)
	move_panel.add_child(move_box)
	var header := HBoxContainer.new()
	move_box.add_child(header)
	var title := Label.new()
	title.text = "棋谱"
	title.add_theme_font_size_override("font_size", 20)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var hide_button := Button.new()
	hide_button.text = "收起"
	hide_button.custom_minimum_size = Vector2(56, 44)
	hide_button.add_theme_stylebox_override("normal", button_style(Color("2b3338")))
	hide_button.pressed.connect(func(): set_move_panel_visible(false))
	header.add_child(hide_button)
	moves_label = RichTextLabel.new()
	moves_label.bbcode_enabled = true
	moves_label.fit_content = false
	moves_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	moves_label.custom_minimum_size = Vector2(250, 240)
	move_box.add_child(moves_label)
	move_show_button = Button.new()
	move_show_button.text = "棋谱"
	move_show_button.custom_minimum_size = Vector2(72, 44)
	move_show_button.add_theme_stylebox_override("normal", button_style(Color("252d32")))
	move_show_button.pressed.connect(func(): set_move_panel_visible(true))
	root.add_child(move_show_button)
	_gameplay_nodes.append(move_show_button)
	set_move_panel_visible(false)


func build_end_overlay(root: Control) -> void:
	end_overlay = ColorRect.new()
	end_overlay.color = Color("10161bb8")
	end_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	end_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	end_overlay.visible = false
	root.add_child(end_overlay)
	end_panel = PanelContainer.new()
	end_panel.add_theme_stylebox_override("panel", panel_style(Color("20272c")))
	end_overlay.add_child(end_panel)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	end_panel.add_child(scroll)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(box)
	var eyebrow := Label.new()
	eyebrow.text = "对局结束"
	eyebrow.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	eyebrow.modulate = MUTED
	eyebrow.add_theme_font_size_override("font_size", 15)
	box.add_child(eyebrow)
	end_title_label = Label.new()
	end_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	end_title_label.add_theme_font_size_override("font_size", 28)
	box.add_child(end_title_label)
	end_detail_label = Label.new()
	end_detail_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	end_detail_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	end_detail_label.modulate = MUTED
	end_detail_label.add_theme_font_size_override("font_size", 18)
	box.add_child(end_detail_label)
	var divider := separator()
	box.add_child(divider)
	var restart := Button.new()
	restart.text = "新对局"
	restart.custom_minimum_size.y = 48
	restart.add_theme_font_size_override("font_size", 19)
	restart.add_theme_stylebox_override("normal", button_style(Color("d3d9dc")))
	restart.add_theme_stylebox_override("hover", button_style(Color("e3e8ea")))
	restart.add_theme_color_override("font_color", Color("172026"))
	restart.add_theme_color_override("font_hover_color", Color("172026"))
	restart.pressed.connect(func():
		end_overlay.visible = false
		show_setup()
	)
	box.add_child(restart)


func build_load_overlay(root: Control) -> void:
	load_overlay = ColorRect.new()
	load_overlay.color = Color("10161bb8")
	load_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	load_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	load_overlay.visible = false
	root.add_child(load_overlay)
	load_panel = PanelContainer.new()
	load_panel.add_theme_stylebox_override("panel", panel_style(Color("20272c")))
	load_overlay.add_child(load_panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	load_panel.add_child(box)
	load_title_label = Label.new()
	load_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	load_title_label.add_theme_font_size_override("font_size", 24)
	load_title_label.text = "正在准备"
	box.add_child(load_title_label)
	load_detail_label = Label.new()
	load_detail_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	load_detail_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	load_detail_label.modulate = MUTED
	box.add_child(load_detail_label)
	load_bar = ProgressBar.new()
	load_bar.min_value = 0
	load_bar.max_value = 1
	load_bar.show_percentage = false
	load_bar.custom_minimum_size.y = 12
	box.add_child(load_bar)


func show_loading(title: String, detail: String = "") -> void:
	load_title_label.text = title
	load_detail_label.text = detail
	load_bar.value = 0
	load_overlay.visible = true
	call_deferred("_relayout")


func set_loading_progress(loaded: int, total: int, status: String) -> void:
	load_detail_label.text = status
	if total > 0:
		load_bar.max_value = total
		load_bar.value = loaded
	else:
		load_bar.max_value = 1
		load_bar.value = 0
	if not load_overlay.visible:
		load_overlay.visible = true
		call_deferred("_relayout")


func hide_loading() -> void:
	load_overlay.visible = false


static func should_show_homescreen_hint(is_web: bool, is_standalone: bool, dismissed: bool) -> bool:
	return is_web and not is_standalone and not dismissed


static func is_homescreen_hint_dismissed() -> bool:
	return FileAccess.file_exists(HOMESCREEN_HINT_STAMP)


static func dismiss_homescreen_hint() -> void:
	var f := FileAccess.open(HOMESCREEN_HINT_STAMP, FileAccess.WRITE)
	if f != null:
		f.store_string("1")
		f.close()
	if OS.has_feature("web"):
		LoaderScript.flush_web_fs()


func maybe_show_homescreen_hint() -> void:
	if homescreen_hint == null:
		return
	homescreen_hint.visible = should_show_homescreen_hint(
		OS.has_feature("web"),
		LoaderScript.is_standalone_web_app(),
		is_homescreen_hint_dismissed()
	)


func _build_homescreen_hint() -> Control:
	var wrap := VBoxContainer.new()
	wrap.add_theme_constant_override("separation", 8)
	wrap.visible = false
	homescreen_hint = wrap
	var text := make_hint(HOMESCREEN_HINT_TEXT)
	text.add_theme_font_size_override("font_size", 14)
	wrap.add_child(text)
	var dismiss := Button.new()
	dismiss.text = "知道了"
	dismiss.custom_minimum_size.y = 36
	dismiss.add_theme_font_size_override("font_size", 15)
	dismiss.add_theme_stylebox_override("normal", button_style(Color("2b3338")))
	dismiss.add_theme_stylebox_override("hover", button_style(Color("3a464d")))
	dismiss.pressed.connect(func():
		dismiss_homescreen_hint()
		homescreen_hint.visible = false
	)
	wrap.add_child(dismiss)
	return wrap


func build_setup_panel(default_human_time: float, default_ai_time_ms: int, default_ai_depth: int) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", panel_style(Color("20272c")))
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(scroll)
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 14)
	scroll.add_child(box)
	var title := Label.new()
	title.text = "3D 象棋"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 28)
	box.add_child(title)
	var subtitle := make_hint("人机对战 · 设置会自动保存\n每步计时归零即判负")
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(subtitle)
	box.add_child(_build_homescreen_hint())
	color_option = OptionButton.new()
	color_option.add_item("执红（先手）", 0)
	color_option.add_item("执黑（后手）", 1)
	color_option.add_item("随机（默认）", 2)
	color_option.select(2)
	box.add_child(setting_row("执棋方", color_option))
	human_time = spin(10, 600, 5, default_human_time, " 秒")
	box.add_child(setting_row("人类每步时长", human_time))
	ai_preset = OptionButton.new()
	ai_preset.add_item("休闲 · 0.5 秒 / 深度 8", 0)
	ai_preset.add_item("标准 · 1.5 秒 / 深度 12", 1)
	ai_preset.add_item("挑战 · 4 秒 / 深度 16", 2)
	ai_preset.select(1)
	ai_preset.item_selected.connect(_on_preset_selected)
	box.add_child(setting_row("AI 难度", ai_preset))
	ai_time = spin(100, 10000, 100, default_ai_time_ms, " 毫秒")
	box.add_child(setting_row("AI 最大思考", ai_time))
	ai_depth = spin(1, 30, 1, default_ai_depth, " 层")
	box.add_child(setting_row("AI 最大深度", ai_depth))
	var start := Button.new()
	start.text = "开始对局"
	start.custom_minimum_size.y = 52
	start.add_theme_font_size_override("font_size", 20)
	start.add_theme_stylebox_override("normal", button_style(Color("d3d9dc")))
	start.add_theme_stylebox_override("hover", button_style(Color("e3e8ea")))
	start.add_theme_color_override("font_color", Color("172026"))
	start.add_theme_color_override("font_hover_color", Color("172026"))
	start.pressed.connect(_emit_game_started)
	box.add_child(start)
	return panel


func _emit_game_started() -> void:
	var choices := ["red", "black", "random"]
	setup_panel.visible = false
	set_action_menu_visible(false)
	set_gameplay_visible(true)
	game_started.emit(choices[color_option.selected], human_time.value, int(ai_time.value), int(ai_depth.value))


func _on_preset_selected(index: int) -> void:
	var values := [[500, 8], [1500, 12], [4000, 16]]
	ai_time.value = values[index][0]
	ai_depth.value = values[index][1]


func set_move_panel_visible(visible: bool) -> void:
	_move_open = visible
	if _move_tween != null and _move_tween.is_valid():
		_move_tween.kill()
	move_panel.visible = visible
	if visible:
		move_panel.modulate.a = 0.0
		_move_tween = create_tween()
		_move_tween.tween_property(move_panel, "modulate:a", 1.0, 0.16)
	move_show_button.visible = not visible and not setup_panel.visible if setup_panel != null else not visible
	call_deferred("_relayout")


func set_action_menu_visible(visible: bool) -> void:
	_action_open = visible
	if _action_tween != null and _action_tween.is_valid():
		_action_tween.kill()
	action_panel.visible = visible
	if visible:
		action_panel.modulate.a = 0.0
		_action_tween = create_tween()
		_action_tween.tween_property(action_panel, "modulate:a", 1.0, 0.16)
	action_show_button.text = "收起" if visible else "操作"
	call_deferred("_relayout")


func set_gameplay_visible(visible: bool) -> void:
	for node in _gameplay_nodes:
		node.visible = visible
	if visible:
		move_panel.visible = _move_open
		move_show_button.visible = not _move_open
		action_panel.visible = _action_open
		action_show_button.visible = true


func _relayout() -> void:
	if _root == null:
		return
	var size := _root.size
	if size.x <= 0.0 or size.y <= 0.0:
		return
	# DisplayServer reports iOS safe areas in physical display pixels, while
	# CanvasItem layout uses stretched viewport coordinates.  Mixing the two
	# pushes controls off-screen on Retina iPads, so layout is intentionally
	# based on the canvas rect only.
	var safe := Rect2(Vector2.ZERO, size)
	var margin := 16.0
	status_panel.position = safe.position + Vector2(margin, margin)
	status_panel.size = Vector2(292.0, 116.0)
	if _action_open:
		action_panel.position = status_panel.position + Vector2(0.0, status_panel.size.y + 10.0)
		action_panel.size = Vector2(248.0, 238.0)
	if _move_open:
		if safe.size.x < 720.0 or safe.size.y < 560.0:
			move_panel.position = Vector2(safe.position.x + margin, safe.end.y - 300.0 - margin)
			move_panel.size = Vector2(safe.size.x - margin * 2.0, 300.0)
		else:
			move_panel.position = Vector2(safe.end.x - 306.0 - margin, safe.position.y + margin)
			move_panel.size = Vector2(306.0, minf(480.0, safe.size.y - margin * 2.0))
	move_show_button.position = Vector2(safe.end.x - 72.0 - margin, safe.position.y + margin)
	action_show_button.position = Vector2(status_panel.position.x + status_panel.size.x + 8.0, status_panel.position.y)
	var setup_width := minf(448.0, safe.size.x - margin * 2.0)
	var setup_height := minf(552.0, safe.size.y - margin * 2.0)
	setup_panel.position = safe.position + Vector2((safe.size.x - setup_width) * 0.5, (safe.size.y - setup_height) * 0.5)
	setup_panel.size = Vector2(setup_width, setup_height)
	var end_width := maxf(1.0, minf(360.0, safe.size.x - margin * 2.0))
	var end_height := maxf(1.0, minf(260.0, safe.size.y - margin * 2.0))
	end_panel.position = safe.position + Vector2((safe.size.x - end_width) * 0.5, (safe.size.y - end_height) * 0.5)
	end_panel.size = Vector2(end_width, end_height)
	if load_panel == null:
		return
	var load_width := maxf(1.0, minf(360.0, safe.size.x - margin * 2.0))
	var load_height := maxf(1.0, minf(200.0, safe.size.y - margin * 2.0))
	load_panel.position = safe.position + Vector2((safe.size.x - load_width) * 0.5, (safe.size.y - load_height) * 0.5)
	load_panel.size = Vector2(load_width, load_height)


func panel_style(color := Color("20272c")) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.corner_radius_top_left = 8
	style.corner_radius_top_right = 8
	style.corner_radius_bottom_left = 8
	style.corner_radius_bottom_right = 8
	style.border_color = Color("647078")
	style.set_border_width_all(1)
	style.content_margin_left = 16
	style.content_margin_right = 16
	style.content_margin_top = 14
	style.content_margin_bottom = 14
	return style


func button_style(background: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = background
	style.border_color = Color("6b777e")
	style.set_border_width_all(1)
	style.corner_radius_top_left = 6
	style.corner_radius_top_right = 6
	style.corner_radius_bottom_left = 6
	style.corner_radius_bottom_right = 6
	style.content_margin_left = 10
	style.content_margin_right = 10
	return style


func chinese_theme() -> Theme:
	var theme := Theme.new()
	theme.default_font = UiFont
	theme.default_font_size = 18
	theme.set_color("font_color", "Button", Color("edf1f2"))
	return theme


func make_hint(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.modulate = MUTED
	return label


func setting_row(title: String, control: Control) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	var label := Label.new()
	label.text = title
	label.custom_minimum_size.x = 128
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


func add_button(parent: Container, title: String, callback: Callable, danger := false) -> void:
	var button := Button.new()
	button.text = title
	button.custom_minimum_size = Vector2(88, 44)
	button.add_theme_stylebox_override("normal", button_style(Color("3a292b") if danger else Color("2b3338")))
	button.add_theme_stylebox_override("hover", button_style(Color("543638") if danger else Color("3a464d")))
	button.pressed.connect(callback)
	parent.add_child(button)


func add_menu_button(parent: Container, title: String, callback: Callable) -> void:
	var button := Button.new()
	button.text = title
	button.custom_minimum_size = Vector2(104, 44)
	button.add_theme_stylebox_override("normal", button_style(Color("2b3338")))
	button.add_theme_stylebox_override("hover", button_style(Color("3a464d")))
	button.pressed.connect(func():
		set_action_menu_visible(false)
		callback.call()
	)
	parent.add_child(button)


func menu_section_label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.modulate = MUTED
	label.add_theme_font_size_override("font_size", 14)
	return label


func separator() -> HSeparator:
	var line := HSeparator.new()
	line.modulate = Color("7d888e")
	return line


func _format_time(seconds: float) -> String:
	var whole := ceili(maxf(0.0, seconds))
	return "%02d:%02d" % [whole / 60, whole % 60]
