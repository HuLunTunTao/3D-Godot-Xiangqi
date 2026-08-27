class_name XiangqiGameHud
extends CanvasLayer

## Owns all 2D UI.  Game state and 3D interaction remain in main.gd.
signal game_started(color_choice: String, human_seconds: float, ai_think_ms: int, ai_depth: int)
signal undo_requested
signal flip_requested
signal reset_view_requested
signal resign_requested

const UiFont = preload("res://assets/fonts/SourceHanSansCN-Regular.otf")

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


func build(default_human_time: float, default_ai_time_ms: int, default_ai_depth: int) -> void:
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# UI controls retain their own hit testing; empty board space falls through
	# to the scene's _unhandled_input for camera gestures and piece selection.
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.theme = chinese_theme()
	add_child(root)
	build_status(root)
	build_actions(root)
	build_move_history(root)
	setup_panel = build_setup_panel(default_human_time, default_ai_time_ms, default_ai_depth)
	root.add_child(setup_panel)
	end_dialog = AcceptDialog.new()
	end_dialog.title = "对局结束"
	end_dialog.ok_button_text = "再来一局"
	end_dialog.confirmed.connect(show_setup)
	root.add_child(end_dialog)


func set_status(text: String) -> void:
	status_label.text = text


func set_clock(seconds: float) -> void:
	var whole := ceili(seconds)
	clock_label.text = "单步时间：%02d:%02d" % [whole / 60, whole % 60]


func set_search_depth(depth: int) -> void:
	depth_label.text = "搜索深度：%d" % depth


func set_moves(history: Array) -> void:
	var entries: Array[String] = []
	for info in history:
		entries.append(info.uci)
	moves_label.text = "[color=#d8e6ee]%s[/color]" % "\n".join(entries)


func show_game_end(title: String, detail: String) -> void:
	end_dialog.title = title
	end_dialog.dialog_text = detail
	end_dialog.popup_centered()


func show_setup() -> void:
	setup_panel.visible = true


func build_status(root: Control) -> void:
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


func build_actions(root: Control) -> void:
	var actions := HBoxContainer.new()
	actions.position = Vector2(18, 142)
	actions.add_theme_constant_override("separation", 8)
	root.add_child(actions)
	add_button(actions, "新对局", show_setup)
	add_button(actions, "撤销回合", func(): undo_requested.emit())
	add_button(actions, "翻转视角", func(): flip_requested.emit())
	add_button(actions, "复位镜头", func(): reset_view_requested.emit())
	add_button(actions, "认输", func(): resign_requested.emit())


func build_move_history(root: Control) -> void:
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
	var header := HBoxContainer.new()
	move_box.add_child(header)
	var title := Label.new()
	title.text = "走棋记录"
	title.add_theme_font_size_override("font_size", 18)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var hide_button := Button.new()
	hide_button.text = "收起"
	hide_button.custom_minimum_size = Vector2(60, 36)
	hide_button.pressed.connect(func(): set_move_panel_visible(false))
	header.add_child(hide_button)
	moves_label = RichTextLabel.new()
	moves_label.bbcode_enabled = true
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


func build_setup_panel(default_human_time: float, default_ai_time_ms: int, default_ai_depth: int) -> PanelContainer:
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
	human_time = spin(10, 600, 5, default_human_time, "秒")
	box.add_child(setting_row("人类每步时长", human_time))
	ai_preset = OptionButton.new()
	ai_preset.add_item("休闲 · 0.5 秒 / 深度 8", 0)
	ai_preset.add_item("标准 · 1.5 秒 / 深度 12", 1)
	ai_preset.add_item("挑战 · 4 秒 / 深度 16", 2)
	ai_preset.select(1)
	ai_preset.item_selected.connect(_on_preset_selected)
	box.add_child(setting_row("AI 难度", ai_preset))
	ai_time = spin(100, 10000, 100, default_ai_time_ms, "毫秒")
	box.add_child(setting_row("AI 最大思考", ai_time))
	ai_depth = spin(1, 30, 1, default_ai_depth, "层")
	box.add_child(setting_row("AI 最大深度", ai_depth))
	var start := Button.new()
	start.text = "开始对局"
	start.custom_minimum_size.y = 52
	start.add_theme_font_size_override("font_size", 20)
	start.pressed.connect(_emit_game_started)
	box.add_child(start)
	return panel


func _emit_game_started() -> void:
	var choices := ["red", "black", "random"]
	setup_panel.visible = false
	game_started.emit(choices[color_option.selected], human_time.value, int(ai_time.value), int(ai_depth.value))


func _on_preset_selected(index: int) -> void:
	var values := [[500, 8], [1500, 12], [4000, 16]]
	ai_time.value = values[index][0]
	ai_depth.value = values[index][1]


func set_move_panel_visible(visible: bool) -> void:
	move_panel.visible = visible
	move_show_button.visible = not visible


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
