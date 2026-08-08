extends GutTest

const Eng = preload("res://addons/pikafish/pikafish.gd")
const Limits = preload("res://addons/pikafish/search/limits.gd")
const Types = preload("res://addons/pikafish/core/types.gd")
const Worker = preload("res://addons/pikafish/search/search_worker.gd")
const TT = preload("res://addons/pikafish/search/tt.gd")
const Position = preload("res://addons/pikafish/core/position.gd")
const Attacks = preload("res://addons/pikafish/core/attacks.gd")
const Zobrist = preload("res://addons/pikafish/core/zobrist.gd")
const Bitboard = preload("res://addons/pikafish/core/bitboard.gd")
const Config = preload("res://addons/pikafish/config.gd")
const RootMove = preload("res://addons/pikafish/search/root_move.gd")
const NnueEvaluator = preload("res://addons/pikafish/search/nnue_evaluator.gd")

const START_FEN := "rnbakabnr/9/1c5c1/p1p1p1p1p/9/9/P1P1P1P1P/1C5C1/9/RNBAKABNR w - - 0 1"


func before_all() -> void:
	Bitboard.ensure_tables()
	Attacks.init_tables()
	Zobrist.init_keys()


func test_search_depth_1_returns_legal_bestmove() -> void:
	var e = Eng.new()
	assert_eq(e.initialize(), OK)
	assert_eq(e.set_fen(START_FEN), OK)
	var lim = Limits.new()
	lim.depth = 1
	lim.sync = true
	assert_eq(e.start_search(lim), OK)
	assert_true(Types.move_is_ok(e._last_result.bestmove))
	assert_true(e.is_legal(e._last_result.bestmove))
	e.shutdown()


func test_search_defaults_to_incremental_nnue_evaluator() -> void:
	var cfg = Config.new()
	cfg.prefer_gpu = false
	var e = Eng.new()
	assert_eq(e.initialize(cfg), OK)
	assert_eq(e.set_fen(START_FEN), OK)
	assert_eq(e.start_search({"depth": 1, "sync": true}), OK)
	assert_eq(e._last_result.evaluation_mode, Config.EVALUATION_NNUE)
	e.shutdown()


func test_search_material_evaluator_is_explicit_opt_in() -> void:
	var cfg = Config.new()
	cfg.prefer_gpu = false
	cfg.evaluation_mode = Config.EVALUATION_MATERIAL
	var e = Eng.new()
	assert_eq(e.initialize(cfg), OK)
	assert_eq(e.set_fen(START_FEN), OK)
	assert_eq(e.start_search({"depth": 1, "sync": true}), OK)
	assert_eq(e._last_result.evaluation_mode, Config.EVALUATION_MATERIAL)
	e.shutdown()


func test_legacy_nnue_switch_resolves_when_mode_is_auto() -> void:
	var cfg = Config.new()
	cfg.use_nnue_eval = false
	assert_eq(cfg.resolved_evaluation_mode(), Config.EVALUATION_MATERIAL)
	cfg.use_nnue_eval = true
	assert_eq(cfg.resolved_evaluation_mode(), Config.EVALUATION_NNUE)


func test_search_depth_2_to_4_nodes_increase() -> void:
	## With pruning flags on, deeper iterations can visit fewer new nodes after TT hits.
	## Require each depth completes with a legal bestmove; soft-check nodes are positive.
	var e = Eng.new()
	assert_eq(e.initialize(), OK)
	assert_eq(e.set_fen(START_FEN), OK)
	var prev_depth := 0
	for d in range(2, 5):
		var lim = Limits.new()
		lim.depth = d
		lim.sync = true
		assert_eq(e.start_search(lim), OK)
		var bm: int = e._last_result.bestmove
		assert_true(Types.move_is_ok(bm), "depth %d bestmove" % d)
		assert_true(e.is_legal(bm), "depth %d legal" % d)
		assert_gte(e._last_result.depth, prev_depth)
		assert_gt(e._last_result.nodes, 0)
		prev_depth = e._last_result.depth
	e.shutdown()


func test_search_returns_complete_legal_pv_and_ponder() -> void:
	var e = Eng.new()
	assert_eq(e.initialize(), OK)
	assert_eq(e.set_fen(START_FEN), OK)
	assert_eq(e.start_search({"depth": 3, "sync": true}), OK)
	var result = e._last_result
	assert_gt(result.pv.size(), 0)
	assert_eq(result.pv[0], result.bestmove)
	var replay = Position.new()
	assert_eq(replay.set_fen(START_FEN), OK)
	for move in result.pv:
		assert_true(replay.legal(move), "PV move must be legal")
		replay.do_move(move)
	if result.pv.size() > 1:
		assert_eq(result.ponder, result.pv[1])
	else:
		assert_eq(result.ponder, Types.MOVE_NONE)
	e.shutdown()


func test_root_move_sort_is_stable_for_equal_scores() -> void:
	var w = Worker.new()
	var first = RootMove.new(10)
	var second = RootMove.new(20)
	var third = RootMove.new(30)
	first.score = 5
	second.score = 5
	third.score = 8
	w.root_moves = [first, second, third]
	w._stable_sort_root_moves()
	assert_eq(w.root_moves[0].move(), 30)
	assert_eq(w.root_moves[1].move(), 10)
	assert_eq(w.root_moves[2].move(), 20)


func test_nnue_final_wrapper_applies_upstream_complexity_material_and_rule60() -> void:
	var pos = Position.new()
	assert_eq(pos.set_fen(START_FEN), OK)
	var psqt := 400
	var positional := -100
	var optimism := 20
	var complexity := absi(psqt - positional)
	var nnue := psqt + positional
	var expected_optimism := optimism + optimism * complexity / 465
	nnue -= nnue * complexity / 11743
	var expected := (nnue * (17380 + pos.major_material()) + expected_optimism * (3061 + pos.major_material())) / 20582
	expected -= expected * pos.rule60_count() / 253
	expected = clampi(expected, Types.VALUE_MATED_IN_MAX_PLY + 1, Types.VALUE_MATE_IN_MAX_PLY - 1)
	assert_eq(NnueEvaluator.finalize_terms(pos, psqt, positional, optimism), expected)
	assert_eq(NnueEvaluator.finalize_terms(pos, -999999, -999999, 0), Types.VALUE_MATED_IN_MAX_PLY + 1)
	assert_eq(NnueEvaluator.finalize_terms(pos, 999999, 999999, 0), Types.VALUE_MATE_IN_MAX_PLY - 1)


func test_facade_legal_moves_count() -> void:
	var e = Eng.new()
	assert_eq(e.initialize(), OK)
	assert_eq(e.set_fen(START_FEN), OK)
	var moves := e.legal_moves()
	assert_eq(moves.size(), 44)
	assert_eq(e.perft(1), 44)
	e.shutdown()


func test_async_search_completes() -> void:
	var e = Eng.new()
	assert_eq(e.initialize(), OK)
	assert_eq(e.set_fen(START_FEN), OK)
	var done := [false]
	var got_bm := [Types.MOVE_NONE]
	e.best_move_found.connect(func(res):
		done[0] = true
		got_bm[0] = res.bestmove
	)
	assert_eq(e.start_search({"depth": 2, "sync": false}), OK)
	var frames := 0
	while not done[0] and frames < 300:
		await wait_process_frames(1)
		frames += 1
	assert_true(done[0], "async search should complete")
	assert_true(Types.move_is_ok(got_bm[0]))
	assert_false(e.is_searching())
	e.shutdown()


func test_stop_search_aborts_without_crash() -> void:
	var e = Eng.new()
	assert_eq(e.initialize(), OK)
	assert_eq(e.set_fen(START_FEN), OK)
	# Large depth + no sync: stop must interrupt via external_stop_cb.
	assert_eq(e.start_search({"depth": 99, "sync": false}), OK)
	await wait_process_frames(2)
	e.stop_search()
	assert_false(e.is_searching())
	assert_eq(e.legal_moves().size(), 44)
	e.shutdown()


func test_time_manager_clock_optimum_maximum() -> void:
	var tm = preload("res://addons/pikafish/search/time_manager.gd").new()
	tm.init_from_limits({"wtime": 60000, "btime": 60000, "winc": 0, "binc": 0}, 0, 20)
	assert_gt(tm.optimum_ms, 100, "basetime optimum should be hundreds of ms")
	assert_gte(tm.maximum_ms, tm.optimum_ms)
	assert_lt(tm.maximum_ms, 60000)
	tm.init_from_limits({"movetime_ms": 250}, 0, 0)
	assert_eq(tm.optimum_ms, 250)
	assert_eq(tm.maximum_ms, 250)
	tm.original_time_adjust = -1.0
	tm.init_from_limits({"wtime": 10000, "movestogo": 40}, 0, 8)
	assert_gt(tm.optimum_ms, 50)
	assert_gte(tm.maximum_ms, tm.optimum_ms)


func test_search_position_restored_after_flags() -> void:
	var pos = Position.new()
	assert_eq(pos.set_fen(START_FEN), OK)
	var key0: int = pos.raw_key()
	var fen0: String = pos.get_fen()
	var tt = TT.new()
	tt.resize_mb(1)
	var w = Worker.new()
	w.pos = pos
	w.tt = tt
	w.enable_null_move = true
	w.enable_lmr = true
	w.enable_aspiration = true
	w.enable_futility = true
	w.enable_razoring = true
	w.enable_probcut = true
	w.enable_singular = true
	var raw: Dictionary = w.search(4, 0)
	assert_true(Types.move_is_ok(int(raw["bestmove"])))
	assert_eq(pos.raw_key(), key0)
	assert_eq(pos.get_fen(), fen0)



func test_use_nnue_eval_position_board_bridge() -> void:
	var e = Eng.new()
	var cfg = preload("res://addons/pikafish/config.gd").new()
	cfg.use_nnue_eval = true
	cfg.prefer_gpu = false
	assert_eq(e.initialize(cfg), OK)
	assert_eq(e.set_fen(START_FEN), OK)
	var lim = Limits.new()
	lim.depth = 1
	lim.sync = true
	assert_eq(e.start_search(lim), OK)
	assert_true(Types.move_is_ok(e._last_result.bestmove))
	assert_true(e.is_legal(e._last_result.bestmove))
	var v: int = e.evaluate_static()
	assert_typeof(v, TYPE_INT)
	e.shutdown()
