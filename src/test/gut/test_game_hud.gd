extends GutTest

const Hud = preload("res://src/game/game_hud.gd")


func test_history_is_collapsed_until_requested_and_renders_bilingual_record() -> void:
	var hud: XiangqiGameHud = Hud.new()
	add_child(hud)
	hud.build(60.0, 1500, 12)
	await get_tree().process_frame
	assert_false(hud.move_panel.visible)
	assert_false(hud.action_panel.visible)
	hud.set_moves([{
		"turn": 1,
		"side": 0,
		"notation": "炮二平五",
		"uci": "h2e2",
	}])
	assert_string_contains(hud.moves_label.text, "炮二平五")
	assert_string_contains(hud.moves_label.text, "h2e2")
	hud.set_move_panel_visible(true)
	assert_true(hud.move_panel.visible)
	hud.set_action_menu_visible(true)
	assert_true(hud.action_panel.visible)
	hud.show_game_end("时间到", "本局判负")
	assert_true(hud.end_overlay.visible)
	assert_eq(hud.end_title_label.text, "时间到")
	assert_eq(hud.end_detail_label.text, "本局判负")
	remove_child(hud)
	hud.free()


func test_layout_uses_canvas_coordinates_for_landscape_and_portrait() -> void:
	var hud: XiangqiGameHud = Hud.new()
	add_child(hud)
	hud.build(60.0, 1500, 12)
	hud._root.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	for size in [Vector2(1024, 768), Vector2(768, 1024)]:
		hud._root.size = size
		hud._relayout()
		assert_true(Rect2(Vector2.ZERO, size).encloses(hud.setup_panel.get_rect()))
		hud.set_move_panel_visible(true)
		hud._relayout()
		assert_true(Rect2(Vector2.ZERO, size).encloses(hud.move_panel.get_rect()))
		hud.set_action_menu_visible(true)
		hud._relayout()
		assert_true(Rect2(Vector2.ZERO, size).encloses(hud.action_panel.get_rect()))
		assert_true(Rect2(Vector2.ZERO, size).encloses(hud.end_panel.get_rect()))
	remove_child(hud)
	hud.free()
