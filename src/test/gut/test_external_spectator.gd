extends GutTest

const ExternalSource = preload("res://src/game/external_game_source.gd")
const Hud = preload("res://src/game/game_hud.gd")

const START_FEN := "rnbakabnr/9/1c5c1/p1p1p1p1p/9/9/P1P1P1P1P/1C5C1/9/RNBAKABNR w - - 0 1"


func test_external_snapshot_protocol_filters_duplicates_and_keeps_metadata() -> void:
	var source = ExternalSource.new()
	var line := JSON.stringify({
		"session": "match-a", "seq": 4, "fen": START_FEN,
		"red_name": "甲", "black_name": "乙", "latency_ms": 17, "info": "测试",
	})
	var event: Dictionary = source.decode_snapshot(line)
	assert_eq(event.fen, START_FEN)
	assert_eq(event.red_name, "甲")
	assert_eq(event.latency_ms, 17)
	assert_true(source.decode_snapshot(line).is_empty(), "same sequence is ignored")
	assert_true(source.decode_snapshot("{bad json").is_empty())
	assert_true(source.decode_snapshot(JSON.stringify({"seq": 5})).is_empty(), "FEN is required")
	var new_session: Dictionary = source.decode_snapshot(JSON.stringify({"session": "match-b", "seq": 1, "fen": START_FEN}))
	assert_eq(new_session.seq, 1, "new session resets sequence tracking")
	source.free()


func test_external_setup_inputs_and_presentation_are_visible() -> void:
	var hud: XiangqiGameHud = Hud.new()
	add_child(hud)
	hud.build(60.0, 1500, 12)
	hud._on_mode_selected(1)
	assert_true(hud.external_settings.visible)
	hud.set_external_presentation("红队", "黑队", 23, "裁判进程")
	assert_string_contains(hud.player_label.text, "红队")
	assert_string_contains(hud.external_meta_label.text, "23 ms")
	assert_string_contains(hud.external_meta_label.text, "裁判进程")
	hud.set_spectator_mode(true)
	assert_true(hud._local_only_actions[0].disabled)
	remove_child(hud)
	hud.free()
