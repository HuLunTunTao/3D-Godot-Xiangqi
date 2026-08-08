class_name PikafishTestDashboard
extends CanvasLayer

## Lightweight, test-only on-device dashboard. It builds itself so any probe Node
## can attach it without depending on a dedicated scene.

var _reporter
var _title: Label
var _environment: Label
var _stage: Label
var _progress: ProgressBar
var _metrics: Label
var _log: RichTextLabel


func bind(reporter) -> void:
	_reporter = reporter
	_build()
	reporter.updated.connect(_refresh)
	_refresh(reporter.snapshot())


func _build() -> void:
	layer = 100
	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, 18)
	panel.add_theme_stylebox_override("panel", _panel_style())
	add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	panel.add_child(box)
	_title = _label(28, Color("e7edf5"))
	box.add_child(_title)
	_environment = _label(16, Color("b8c6d8"))
	box.add_child(_environment)
	_stage = _label(20, Color("ffffff"))
	box.add_child(_stage)
	_progress = ProgressBar.new()
	_progress.custom_minimum_size = Vector2(0, 26)
	_progress.show_percentage = true
	box.add_child(_progress)
	_metrics = _label(16, Color("d3dce9"))
	box.add_child(_metrics)
	var log_title := _label(17, Color("b8c6d8"))
	log_title.text = "Live log"
	box.add_child(log_title)
	_log = RichTextLabel.new()
	_log.bbcode_enabled = false
	_log.scroll_following = true
	_log.custom_minimum_size = Vector2(0, 220)
	_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_log.add_theme_font_size_override("normal_font_size", 15)
	box.add_child(_log)


func _refresh(data: Dictionary) -> void:
	if _title == null:
		return
	_title.text = "%s  ·  %s" % [data["suite"], "PASS" if data["completed"] and data["passed"] else "FAIL" if data["completed"] else "RUNNING"]
	var env: Dictionary = data["environment"]
	_environment.text = "%s %s · %s · Godot %s\n%s · %s · %s" % [env["platform"], env["os_version"], env["model"], env["godot"], env["renderer"], env["vendor"], env["adapter"]]
	_stage.text = "%s%s  ·  %d ms" % [data["stage"], " — " + str(data["detail"]) if not str(data["detail"]).is_empty() else "", int(data["elapsed_ms"])]
	var total := int(data["progress_total"])
	var current := int(data["progress_current"])
	_progress.max_value = maxi(total, 1)
	_progress.value = clampi(current, 0, maxi(total, 1))
	_progress.show_percentage = total > 0
	_metrics.text = _format_metrics(data["metrics"])
	_log.clear()
	_log.append_text("\n".join(data["log"]))


func _format_metrics(values: Dictionary) -> String:
	if values.is_empty():
		return "Metrics: waiting"
	var lines: PackedStringArray = PackedStringArray(["Metrics"])
	for key in values:
		lines.append("%s: %s" % [str(key), str(values[key])])
	return "\n".join(lines)


func _label(size: int, color: Color) -> Label:
	var label := Label.new()
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return label


func _panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color("16202d")
	style.border_color = Color("46627f")
	style.set_border_width_all(2)
	style.set_corner_radius_all(12)
	style.content_margin_left = 24
	style.content_margin_right = 24
	style.content_margin_top = 20
	style.content_margin_bottom = 20
	return style
