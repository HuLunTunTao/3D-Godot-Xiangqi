extends GutTest

## Game-layer facade: snapshots, move metadata, history, and stale-search safety.

const Eng = preload("res://addons/pikafish/pikafish.gd")
const Config = preload("res://addons/pikafish/config.gd")
const Types = preload("res://addons/pikafish/core/types.gd")

const START_FEN := "rnbakabnr/9/1c5c1/p1p1p1p1p/9/9/P1P1P1P1P/1C5C1/9/RNBAKABNR w - - 0 1"


func _make_engine():
	var cfg = Config.new()
	cfg.prefer_gpu = false
	var engine = Eng.new()
	assert_eq(engine.initialize(cfg), OK)
	assert_eq(engine.new_game(), OK)
	return engine


func test_new_game_snapshot_and_square_helpers() -> void:
	var engine = _make_engine()
	var view = engine.get_position_view()
	assert_eq(view.fen, START_FEN)
	assert_eq(view.revision, engine.position_revision())
	assert_eq(view.pieces.size(), Types.SQUARE_NB)
	var a3 := engine.square_from_file_rank(0, 3)
	assert_eq(engine.piece_at(a3), Types.W_PAWN)
	assert_eq(view.piece_at(a3), Types.W_PAWN)
	assert_eq(engine.file_of(a3), 0)
	assert_eq(engine.rank_of(a3), 3)
	assert_eq(engine.square_from_file_rank(-1, 0), Types.SQ_NONE)
	engine.shutdown()


func test_move_event_targets_history_and_redo() -> void:
	var engine = _make_engine()
	var events: Array = []
	engine.position_changed.connect(func(view, info): events.append({"view": view, "info": info}))
	var a3 := engine.square_from_file_rank(0, 3)
	var moves := engine.legal_moves_from(a3)
	assert_eq(moves.size(), 1)
	assert_eq(engine.push_move(moves[0]), OK)
	assert_eq(events.size(), 1)
	var info = events[0]["info"]
	assert_eq(info.kind, "move")
	assert_eq(info.moving_piece, Types.W_PAWN)
	assert_eq(info.uci, "a3a4")
	assert_eq(info.revision, engine.position_revision())
	assert_true(engine.can_undo())
	assert_false(engine.can_redo())
	assert_eq(engine.move_history().size(), 1)
	assert_eq(engine.pop_move(), OK)
	assert_true(engine.can_redo())
	assert_eq(events[1]["info"].kind, "undo")
	assert_eq(engine.redo_move(), OK)
	assert_eq(events[2]["info"].kind, "redo")
	assert_eq(engine.piece_at(engine.square_from_file_rank(0, 4)), Types.W_PAWN)
	engine.shutdown()


func test_push_uci_clears_redo_and_revision_is_monotonic() -> void:
	var engine = _make_engine()
	var r0 := engine.position_revision()
	assert_eq(engine.push_uci("a3a4"), OK)
	var r1 := engine.position_revision()
	assert_gt(r1, r0)
	assert_eq(engine.pop_move(), OK)
	assert_eq(engine.redo_move(), OK)
	assert_gt(engine.position_revision(), r1)
	assert_eq(engine.pop_move(), OK)
	assert_true(engine.can_redo())
	assert_eq(engine.push_uci("c3c4"), OK)
	assert_false(engine.can_redo())
	assert_eq(engine.push_uci("oops"), ERR_INVALID_PARAMETER)
	engine.shutdown()


func test_set_position_is_atomic_and_emits_once() -> void:
	var engine = _make_engine()
	var events: Array = []
	engine.position_changed.connect(func(_view, _info): events.append(true))
	var a3a4 := engine.move_from_uci("a3a4")
	assert_eq(engine.set_position(START_FEN, PackedInt32Array([a3a4])), OK)
	assert_eq(events.size(), 1)
	assert_eq(engine.piece_at(engine.square_from_file_rank(0, 4)), Types.W_PAWN)
	var preserved := engine.get_fen()
	assert_eq(engine.set_position(START_FEN, PackedInt32Array([Types.MOVE_NONE])), ERR_INVALID_PARAMETER)
	assert_eq(engine.get_fen(), preserved)
	assert_eq(events.size(), 1)
	engine.shutdown()


func test_position_change_discards_async_search_result() -> void:
	var engine = _make_engine()
	var results: Array = []
	engine.best_move_found.connect(func(result): results.append(result))
	assert_eq(engine.start_search({"depth": 99, "sync": false}), OK)
	assert_eq(engine.push_uci("a3a4"), OK)
	await get_tree().process_frame
	await get_tree().process_frame
	assert_false(engine.is_searching())
	assert_eq(results.size(), 0)
	engine.shutdown()
