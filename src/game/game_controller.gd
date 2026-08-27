class_name XiangqiGameController
extends Node

const EngineScript = preload("res://addons/pikafish/pikafish.gd")
const Types = preload("res://addons/pikafish/core/types.gd")
const MoveNotation = preload("res://src/game/move_notation.gd")
const SETTINGS_PATH := "user://xiangqi_settings.cfg"

signal board_changed(view, move_info)
signal status_changed(text: String, state: String)
signal clock_changed(seconds_left: float)
signal search_progress(depth: int)
signal game_ended(title: String, detail: String)
signal game_state_changed(info: Dictionary)

enum State { SETUP, HUMAN_TURN, AI_THINKING, FINISHED }

var engine = EngineScript.new()
var state := State.SETUP
var human_color := Types.COLOR_WHITE
var human_time_limit := 60.0
var human_time_left := 60.0
var ai_time_ms := 1500
var ai_depth := 12
var _search_revision := -1
var _last_search_depth := 0
var _move_records: Array[Dictionary] = []


func _ready() -> void:
	load_settings()
	var err := engine.initialize()
	if err != OK:
		status_changed.emit("引擎初始化失败：%s" % error_string(err), "error")
		return
	engine.position_changed.connect(_on_position_changed)
	engine.best_move_found.connect(_on_best_move_found)
	engine.search_info.connect(func(info):
		_last_search_depth = info.depth
		search_progress.emit(info.depth)
		_emit_game_state()
	)
	status_changed.emit("请选择设置后开始对局", "setup")
	_emit_game_state()


func _exit_tree() -> void:
	engine.shutdown()


func load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) == OK:
		human_time_limit = float(cfg.get_value("game", "human_time", human_time_limit))
		ai_time_ms = int(cfg.get_value("game", "ai_time_ms", ai_time_ms))
		ai_depth = int(cfg.get_value("game", "ai_depth", ai_depth))


func save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("game", "human_time", human_time_limit)
	cfg.set_value("game", "ai_time_ms", ai_time_ms)
	cfg.set_value("game", "ai_depth", ai_depth)
	cfg.save(SETTINGS_PATH)


func start_game(color_choice: String, time_seconds: float, think_ms: int, depth: int) -> void:
	engine.stop_search()
	human_color = randi_range(0, 1) if color_choice == "random" else (Types.COLOR_WHITE if color_choice == "red" else Types.COLOR_BLACK)
	human_time_limit = clampf(time_seconds, 10.0, 600.0)
	ai_time_ms = clampi(think_ms, 100, 10000)
	ai_depth = clampi(depth, 1, 30)
	save_settings()
	human_time_left = human_time_limit
	_last_search_depth = 0
	_move_records.clear()
	engine.new_game()
	_after_position_change()


func request_move(from: int, to: int) -> bool:
	if state != State.HUMAN_TURN:
		return false
	for move in engine.legal_moves_from(from):
		if engine.move_to_uci(move).ends_with(_square_name(to)):
			if _push_recorded_move(move):
				_after_position_change()
				return true
	return false


func undo_full_turn() -> void:
	if state != State.HUMAN_TURN:
		return
	engine.stop_search()
	if engine.can_undo():
		_remove_last_record()
		engine.pop_move()
	if engine.can_undo():
		_remove_last_record()
		engine.pop_move()
	human_time_left = human_time_limit
	_after_position_change()


func resign() -> void:
	if state == State.FINISHED or state == State.SETUP:
		return
	engine.stop_search()
	state = State.FINISHED
	game_ended.emit("对局结束", "你已认输")
	status_changed.emit("你已认输", "finished")
	_emit_game_state()


func legal_targets(square: int) -> PackedInt32Array:
	var targets := PackedInt32Array()
	if state != State.HUMAN_TURN or engine.piece_at(square) == Types.NO_PIECE:
		return targets
	if Types.color_of(engine.piece_at(square)) != human_color:
		return targets
	for move in engine.legal_moves_from(square):
		var uci := engine.move_to_uci(move)
		var files := "abcdefghi"
		var file := files.find(uci[2])
		targets.append(engine.square_from_file_rank(file, int(uci[3])))
	return targets


func _process(delta: float) -> void:
	if state != State.HUMAN_TURN:
		return
	human_time_left = maxf(0.0, human_time_left - delta)
	clock_changed.emit(human_time_left)
	if human_time_left <= 0.0:
		state = State.FINISHED
		game_ended.emit("时间到", "你的单步思考时间已耗尽，本局判负。")
		status_changed.emit("超时判负", "finished")
		_emit_game_state()


func _after_position_change() -> void:
	var result: Dictionary = engine.game_result()
	if result.get("result", "ongoing") != "ongoing":
		state = State.FINISHED
		var winner := str(result.get("winner", ""))
		var detail := "和棋" if winner.is_empty() else ("红方胜" if winner == "white" else "黑方胜")
		game_ended.emit("对局结束", detail)
		status_changed.emit(detail, "finished")
		_emit_game_state()
		return
	var view = engine.get_position_view()
	if view.side_to_move == human_color:
		state = State.HUMAN_TURN
		human_time_left = human_time_limit
		status_changed.emit("轮到你走棋", "human")
	else:
		state = State.AI_THINKING
		status_changed.emit("AI 正在思考…", "ai")
		_search_revision = engine.position_revision()
		_last_search_depth = 0
		engine.start_search({"movetime_ms": ai_time_ms, "depth": ai_depth})
	_emit_game_state()


func _on_best_move_found(result) -> void:
	if state != State.AI_THINKING or result.revision != _search_revision:
		return
	if result.bestmove == Types.MOVE_NONE:
		_after_position_change()
		return
	if _push_recorded_move(result.bestmove):
		_after_position_change()


func _on_position_changed(view, move_info) -> void:
	board_changed.emit(view, move_info)


func move_records() -> Array[Dictionary]:
	return _move_records.duplicate(true)


func _push_recorded_move(move: int) -> bool:
	var before = engine.get_position_view()
	var record := {
		"turn": int(_move_records.size() / 2) + 1,
		"side": before.side_to_move,
		"uci": engine.move_to_uci(move),
		"notation": MoveNotation.format(before, move),
		"before_fen": before.fen,
		"capture": before.piece_at(Types.to_sq(move)) != Types.NO_PIECE,
	}
	_move_records.append(record)
	if engine.push_move(move) == OK:
		return true
	_move_records.pop_back()
	return false


func _remove_last_record() -> void:
	if not _move_records.is_empty():
		_move_records.pop_back()


func _emit_game_state() -> void:
	var side_to_move := human_color
	if engine != null:
		side_to_move = engine.get_position_view().side_to_move
	game_state_changed.emit({
		"state": State.keys()[state].to_lower(),
		"human_color": human_color,
		"side_to_move": side_to_move,
		"human_time_left": human_time_left,
		"ai_depth": _last_search_depth,
	})


func _square_name(square: int) -> String:
	var files := "abcdefghi"
	return "%s%d" % [files[engine.file_of(square)], engine.rank_of(square)]
