extends GutTest

## Time-budget, stop, and async delivery semantics for PikafishEngine search.

const Eng = preload("res://addons/pikafish/pikafish.gd")
const Config = preload("res://addons/pikafish/config.gd")
const Limits = preload("res://addons/pikafish/search/limits.gd")
const TimeMan = preload("res://addons/pikafish/search/time_manager.gd")
const Types = preload("res://addons/pikafish/core/types.gd")
const Worker = preload("res://addons/pikafish/search/search_worker.gd")
const TT = preload("res://addons/pikafish/search/tt.gd")
const Position = preload("res://addons/pikafish/core/position.gd")
const Attacks = preload("res://addons/pikafish/core/attacks.gd")
const Zobrist = preload("res://addons/pikafish/core/zobrist.gd")
const Bitboard = preload("res://addons/pikafish/core/bitboard.gd")
const MG = preload("res://addons/pikafish/core/movegen.gd")

const START_FEN := "rnbakabnr/9/1c5c1/p1p1p1p1p/9/9/P1P1P1P1P/1C5C1/9/RNBAKABNR w - - 0 1"
## Allow modest scheduler slack over hard movetime.
const MOVETIME_SLACK_MS := 80


func before_all() -> void:
	Bitboard.ensure_tables()
	Attacks.init_tables()
	Zobrist.init_keys()


func _make_engine(prefer_gpu := false):
	var cfg = Config.new()
	cfg.prefer_gpu = prefer_gpu
	var e = Eng.new()
	assert_eq(e.initialize(cfg), OK)
	assert_eq(e.set_fen(START_FEN), OK)
	return e


func test_movetime_ms_100_300_do_not_grossly_overrun() -> void:
	var e = _make_engine()
	for budget in [100, 300]:
		assert_eq(e.set_fen(START_FEN), OK)
		var t0: int = Time.get_ticks_msec()
		assert_eq(e.start_search({"movetime_ms": budget, "sync": true}), OK)
		var elapsed: int = Time.get_ticks_msec() - t0
		var res = e._last_result
		assert_true(Types.move_is_ok(res.bestmove), "budget %d bestmove" % budget)
		assert_true(e.is_legal(res.bestmove), "budget %d legal" % budget)
		assert_true(res.from_complete_iteration or res.incomplete)
		# Soft/hard stop should keep wall time near budget; allow slack for GDScript.
		assert_lt(elapsed, budget + MOVETIME_SLACK_MS + 200, "budget %d elapsed=%d" % [budget, elapsed])
		assert_true(res.timed_out or res.completed_depth >= 1 or res.incomplete)
	e.shutdown()


func test_clock_inc_movestogo_optimum_maximum() -> void:
	var tm = TimeMan.new()
	tm.init_from_limits({"wtime": 60000, "btime": 60000, "winc": 1000, "binc": 1000}, 0, 10)
	assert_gt(tm.optimum_ms, 500)
	assert_gte(tm.maximum_ms, tm.optimum_ms)
	assert_lt(tm.maximum_ms, 60000)
	tm.original_time_adjust = -1.0
	tm.init_from_limits({"wtime": 30000, "movestogo": 20}, 0, 5)
	assert_gt(tm.optimum_ms, 200)
	assert_gte(tm.maximum_ms, tm.optimum_ms)
	tm.init_from_limits({"movetime_ms": 1200}, 0, 0)
	assert_eq(tm.optimum_ms, 1200)
	assert_eq(tm.maximum_ms, 1200)
	# Ponder adds 25% to optimum for identical clock inputs.
	tm.original_time_adjust = -1.0
	tm.init_from_limits({"wtime": 60000, "winc": 1000}, 0, 10)
	var base_opt: int = tm.optimum_ms
	tm.original_time_adjust = -1.0
	tm.init_from_limits({"wtime": 60000, "winc": 1000, "ponder": true}, 0, 10)
	assert_eq(tm.optimum_ms, base_opt + base_opt / 4)
	# Move overhead reduces available timeLeft vs zero overhead.
	tm.original_time_adjust = -1.0
	tm.init_from_limits({"wtime": 10000, "move_overhead_ms": 10}, 0, 8)
	var with_oh: int = tm.maximum_ms
	tm.original_time_adjust = -1.0
	tm.init_from_limits({"wtime": 10000, "move_overhead_ms": 200}, 0, 8)
	assert_lte(tm.maximum_ms, with_oh)


func test_clock_soft_target_adapts_to_iteration_stability() -> void:
	var stable = TimeMan.new()
	stable.init_from_limits({"wtime": 60000, "winc": 1000}, 0, 10)
	var base: int = stable.soft_target()
	var stable_target: int = stable.update_after_iteration({
		"best_previous_average": 0,
		"best_value": 0,
		"iter_value": 0,
		"depth": 6,
		"last_best_move_depth": 1,
		"best_move_changes": 0.0,
		"best_effort_nodes": 1000,
		"nodes": 10000,
		"threads": 1,
	})
	assert_gt(base, 0)
	assert_gte(stable_target, 1)
	assert_lte(stable_target, stable.maximum())

	var unstable = TimeMan.new()
	unstable.init_from_limits({"wtime": 60000, "winc": 1000}, 0, 10)
	var unstable_target: int = unstable.update_after_iteration({
		"best_previous_average": 300,
		"best_value": -300,
		"iter_value": -100,
		"depth": 6,
		"last_best_move_depth": 6,
		"best_move_changes": 3.0,
		"best_effort_nodes": 1000,
		"nodes": 10000,
		"threads": 1,
	})
	assert_gt(unstable_target, stable_target)
	assert_lte(unstable_target, unstable.maximum())


func test_clock_search_reports_dynamic_soft_and_hard_bounds() -> void:
	var e = _make_engine()
	assert_eq(e.start_search({
		"wtime": 1000,
		"btime": 1000,
		"winc": 0,
		"binc": 0,
		"sync": true,
	}), OK)
	var res = e._last_result
	assert_true(Types.move_is_ok(res.bestmove))
	assert_true(e.is_legal(res.bestmove))
	assert_gt(res.soft_time_ms, 0)
	assert_gte(res.hard_time_ms, res.soft_time_ms)
	e.shutdown()


func test_immediate_and_repeat_stop_idempotent() -> void:
	var e = _make_engine()
	assert_eq(e.start_search({"depth": 99, "sync": false}), OK)
	e.stop_search()
	e.stop_search()
	e.stop_search()
	assert_false(e.is_searching())
	assert_ne(e._last_result, null)
	assert_true(Types.move_is_ok(e._last_result.bestmove) or e._last_result.incomplete)
	if Types.move_is_ok(e._last_result.bestmove):
		assert_true(e.is_legal(e._last_result.bestmove))
	e.shutdown()


func test_random_moment_stop_returns_complete_or_fallback() -> void:
	var e = _make_engine()
	var best_counts := {}
	for i in range(6):
		assert_eq(e.set_fen(START_FEN), OK)
		assert_eq(e.start_search({"depth": 99, "sync": false}), OK)
		OS.delay_msec(2 + (i % 3) * 3)
		e.stop_search()
		assert_false(e.is_searching())
		var res = e._last_result
		assert_ne(res, null)
		assert_true(Types.move_is_ok(res.bestmove))
		assert_true(e.is_legal(res.bestmove))
		if res.from_complete_iteration:
			assert_gte(res.completed_depth, 1)
			assert_false(res.incomplete)
		else:
			assert_true(res.incomplete)
		var u: String = e.move_to_uci(res.bestmove)
		best_counts[u] = int(best_counts.get(u, 0)) + 1
	e.shutdown()


func test_node_limit_stops_and_marks_result() -> void:
	var e = _make_engine()
	assert_eq(e.start_search({"nodes": 500, "sync": true}), OK)
	var res = e._last_result
	assert_true(Types.move_is_ok(res.bestmove))
	assert_true(e.is_legal(res.bestmove))
	assert_true(res.node_limited or res.nodes <= 5000)
	assert_lte(res.nodes, 5000)  # hard stop may overrun slightly inside a node chunk
	e.shutdown()


func test_async_info_order_and_bestmove_once() -> void:
	var e = _make_engine()
	var infos: Array = []
	var bests: Array = []
	e.search_info.connect(func(info): infos.append(info.depth))
	e.best_move_found.connect(func(res): bests.append(res))
	assert_eq(e.start_search({"depth": 3, "sync": false}), OK)
	var frames := 0
	while bests.is_empty() and frames < 600:
		await wait_process_frames(1)
		frames += 1
	assert_eq(bests.size(), 1, "best_move_found exactly once")
	assert_false(e.is_searching())
	assert_true(Types.move_is_ok(bests[0].bestmove))
	# Non-decreasing completed depths among infos (iteration + final).
	var prev := 0
	for d in infos:
		assert_gte(int(d), 0)
		if int(d) > 0:
			assert_gte(int(d), prev)
			prev = int(d)
	assert_gte(infos.size(), 1)
	e.shutdown()


func test_sync_async_interleave() -> void:
	var e = _make_engine()
	assert_eq(e.start_search({"depth": 2, "sync": true}), OK)
	var sync_bm: int = e._last_result.bestmove
	assert_true(e.is_legal(sync_bm))
	var done := [false]
	e.best_move_found.connect(func(_r): done[0] = true, CONNECT_ONE_SHOT)
	assert_eq(e.start_search({"depth": 2, "sync": false}), OK)
	var frames := 0
	while not done[0] and frames < 400:
		await wait_process_frames(1)
		frames += 1
	assert_true(done[0])
	assert_eq(e.start_search({"depth": 1, "sync": true}), OK)
	assert_true(e.is_legal(e._last_result.bestmove))
	e.shutdown()


func test_shutdown_during_and_after_async() -> void:
	var e = _make_engine()
	assert_eq(e.start_search({"depth": 99, "sync": false}), OK)
	await wait_process_frames(1)
	e.shutdown()
	assert_false(e.is_searching())
	# Fresh engine after prior shutdown.
	e = _make_engine()
	var done := [false]
	e.best_move_found.connect(func(_r): done[0] = true, CONNECT_ONE_SHOT)
	assert_eq(e.start_search({"depth": 2, "sync": false}), OK)
	var frames := 0
	while not done[0] and frames < 400:
		await wait_process_frames(1)
		frames += 1
	assert_true(done[0])
	e.shutdown()
	assert_false(e.is_searching())


func test_incomplete_depth1_fallback_legal() -> void:
	## Force stop before depth 1 can commit by stopping with an already-stopped worker
	## path: request_stop before search via external flag simulation on Worker.
	var pos = Position.new()
	assert_eq(pos.set_fen(START_FEN), OK)
	var w = Worker.new()
	w.pos = pos
	w.tt = TT.new()
	w.tt.resize_mb(1)
	w.external_stop_cb = func() -> bool:
		return true
	var raw: Dictionary = w.search(5, 0)
	assert_true(bool(raw.get("incomplete", false)) or int(raw.get("completed_depth", 0)) >= 1)
	var bm: int = int(raw["bestmove"])
	assert_true(Types.move_is_ok(bm))
	assert_true(pos.legal(bm))
	# Explicit fallback path: empty stable → first legal.
	var list := PackedInt32Array()
	list.resize(Types.MAX_MOVES)
	var n: int = MG.generate(pos, MG.GEN_LEGAL, list)
	assert_gt(n, 0)
	assert_true(list.has(bm) or pos.legal(bm))


func test_result_from_last_complete_iteration_under_movetime() -> void:
	var e = _make_engine()
	assert_eq(e.start_search({"movetime_ms": 200, "sync": true}), OK)
	var res = e._last_result
	assert_true(Types.move_is_ok(res.bestmove))
	assert_true(e.is_legal(res.bestmove))
	if res.completed_depth >= 1:
		assert_true(res.from_complete_iteration)
		assert_false(res.incomplete)
		assert_eq(res.depth, res.completed_depth)
	assert_gt(res.elapsed_ms, 0)
	e.shutdown()


func test_default_start_search_is_async() -> void:
	var e = _make_engine()
	assert_eq(e.start_search({"depth": 2}), OK)
	assert_true(e.is_searching() or e._last_result != null)
	# If still searching, wait for completion.
	if e.is_searching():
		var frames := 0
		while e.is_searching() and frames < 400:
			await wait_process_frames(1)
			frames += 1
	assert_false(e.is_searching())
	assert_true(Types.move_is_ok(e._last_result.bestmove))
	e.shutdown()
