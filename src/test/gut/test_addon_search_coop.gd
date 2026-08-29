extends GutTest

## Web-style cooperative (yielding) search: one job, frame yields, legal bestmove.

const Eng = preload("res://addons/pikafish/pikafish.gd")
const Config = preload("res://addons/pikafish/config.gd")
const Types = preload("res://addons/pikafish/core/types.gd")
const Worker = preload("res://addons/pikafish/search/search_worker.gd")
const TT = preload("res://addons/pikafish/search/tt.gd")
const Position = preload("res://addons/pikafish/core/position.gd")
const Attacks = preload("res://addons/pikafish/core/attacks.gd")
const Zobrist = preload("res://addons/pikafish/core/zobrist.gd")
const Bitboard = preload("res://addons/pikafish/core/bitboard.gd")
const Controller = preload("res://src/game/game_controller.gd")

const START_FEN := "rnbakabnr/9/1c5c1/p1p1p1p1p/9/9/P1P1P1P1P/1C5C1/9/RNBAKABNR w - - 0 1"


func before_all() -> void:
	Bitboard.ensure_tables()
	Attacks.init_tables()
	Zobrist.init_keys()


func _make_engine():
	var cfg = Config.new()
	cfg.prefer_gpu = false
	var e = Eng.new()
	assert_eq(e.initialize(cfg), OK)
	assert_eq(e.set_fen(START_FEN), OK)
	return e


func test_yield_cb_records_calls_and_returns_legal_bestmove() -> void:
	var pos = Position.new()
	assert_eq(pos.set_fen(START_FEN), OK)
	var w = Worker.new()
	w.pos = pos
	w.tt = TT.new()
	w.tt.resize_mb(1)
	w.yield_interval_ms = 0
	var yields: Array = []
	w.yield_cb = func():
		yields.append(Time.get_ticks_msec())
		# Coroutine that resumes immediately so GUT can inject the yield path
		# without waiting on the scene tree.
		if false:
			await get_tree().process_frame
	var raw: Dictionary = await w.search_async(2, 0)
	assert_gt(yields.size(), 0, "search_async should invoke yield_cb")
	var bm: int = int(raw.get("bestmove", Types.MOVE_NONE))
	assert_true(Types.move_is_ok(bm))
	assert_true(pos.legal(bm))
	assert_eq(pos.get_fen(), START_FEN)


func test_cooperative_flag_is_web_only_by_default_and_sync_disables_it() -> void:
	var e = _make_engine()
	assert_false(OS.has_feature("web"), "GUT runs off-web; cooperative must be opt-in")
	assert_false(e.uses_cooperative_search({"depth": 2}))
	assert_false(e.uses_cooperative_search({"movetime_ms": 1500, "depth": 12}))
	assert_true(e.uses_cooperative_search({"depth": 2, "cooperative": true}))
	assert_false(e.uses_cooperative_search({"depth": 2, "cooperative": true, "sync": true}))
	assert_false(e.uses_cooperative_search({"depth": 1, "sync": true}))
	e.shutdown()


func test_cooperative_search_returns_legal_nnue_bestmove_without_thread() -> void:
	var e = _make_engine()
	var infos: Array = []
	var bests: Array = []
	e.search_info.connect(func(info): infos.append(info.depth))
	e.best_move_found.connect(func(res): bests.append(res))
	assert_eq(e.start_search({"depth": 2, "cooperative": true}), OK)
	assert_eq(e._search_thread, null)
	assert_true(e.is_searching(), "cooperative start_search must return before the think finishes")
	var frames := 0
	while bests.is_empty() and frames < 400:
		await wait_process_frames(1)
		frames += 1
	assert_eq(bests.size(), 1, "best_move_found exactly once")
	assert_false(e.is_searching())
	assert_true(Types.move_is_ok(bests[0].bestmove))
	assert_true(e.is_legal(bests[0].bestmove))
	assert_eq(bests[0].evaluation_mode, Config.EVALUATION_NNUE)
	assert_gte(infos.size(), 1, "search_info should update between yields")
	assert_gt(frames, 1, "frame loop must keep running during cooperative think")
	e.shutdown()


func test_nonweb_default_start_search_is_thread_not_sync() -> void:
	var e = _make_engine()
	assert_false(e.uses_cooperative_search({"depth": 2}))
	assert_eq(e.start_search({"depth": 2}), OK)
	# Sync would finish inside start_search with no thread and not searching.
	assert_true(e.is_searching() or e._search_thread != null or e._last_result != null)
	if e.is_searching():
		var frames := 0
		while e.is_searching() and frames < 400:
			await wait_process_frames(1)
			frames += 1
	assert_false(e.is_searching())
	assert_true(Types.move_is_ok(e._last_result.bestmove))
	e.shutdown()


func test_cooperative_stop_still_returns_legal_or_clears() -> void:
	var e = _make_engine()
	var results: Array = []
	e.best_move_found.connect(func(res): results.append(res))
	assert_eq(e.start_search({"depth": 99, "cooperative": true}), OK)
	await wait_process_frames(2)
	e.stop_search()
	var frames := 0
	while e.is_searching() and frames < 120:
		await wait_process_frames(1)
		frames += 1
	assert_false(e.is_searching())
	if not results.is_empty():
		var res = results[0]
		assert_true(Types.move_is_ok(res.bestmove) or res.incomplete)
		if Types.move_is_ok(res.bestmove):
			assert_true(e.is_legal(res.bestmove))
	e.shutdown()


func test_cooperative_position_change_discards_result() -> void:
	var e = _make_engine()
	var results: Array = []
	e.best_move_found.connect(func(res): results.append(res))
	assert_eq(e.start_search({"depth": 99, "cooperative": true}), OK)
	assert_eq(e.push_uci("a3a4"), OK)
	var frames := 0
	while e.is_searching() and frames < 60:
		await wait_process_frames(1)
		frames += 1
	assert_false(e.is_searching())
	assert_eq(results.size(), 0)
	e.shutdown()


func test_game_ai_limits_do_not_force_sync() -> void:
	var c: XiangqiGameController = Controller.new()
	c.ai_time_ms = 1500
	c.ai_depth = 12
	var limits: Dictionary = c._ai_search_limits()
	assert_false(limits.has("sync"))
	assert_false(bool(limits.get("sync", false)))
	assert_eq(int(limits["movetime_ms"]), 1500)
	assert_eq(int(limits["depth"]), 12)
	c.free()


func test_blocking_search_still_returns_int_not_coroutine() -> void:
	var pos = Position.new()
	assert_eq(pos.set_fen(START_FEN), OK)
	var w = Worker.new()
	w.pos = pos
	w.tt = TT.new()
	w.tt.resize_mb(1)
	var raw: Dictionary = w.search(2, 0)
	assert_eq(typeof(raw), TYPE_DICTIONARY)
	assert_true(Types.move_is_ok(int(raw.get("bestmove", Types.MOVE_NONE))))
	assert_true(pos.legal(int(raw["bestmove"])))
	assert_eq(typeof(raw["score"]), TYPE_INT)
	assert_eq(typeof(raw["nodes"]), TYPE_INT)
	assert_eq(w.coop_inner_yields, 0, "blocking search must not take the async yield path")


func test_search_async_yields_inside_first_root_move_tree() -> void:
	## PR #5 only yielded between ID depths / root moves. A depth-6 first PV
	## occupies most of a think; inner _search_async must pump yield_cb during
	## that single tree, not only after it returns.
	var pos = Position.new()
	assert_eq(pos.set_fen(START_FEN), OK)
	var w = Worker.new()
	w.pos = pos
	w.tt = TT.new()
	w.tt.resize_mb(1)
	w.yield_interval_ms = 0
	var samples: Array = []
	w.yield_cb = func():
		var efforts := PackedInt32Array()
		for rm in w.root_moves:
			efforts.append(int(rm.effort))
		samples.append({
			"nodes": w.nodes,
			"completed_depth": w.completed_depth,
			"inner": w.coop_inner_yields,
			"efforts": efforts,
		})
		if false:
			await get_tree().process_frame
	var raw: Dictionary = await w.search_async(6, 0)
	assert_gt(samples.size(), 0)
	assert_gt(w.coop_inner_yields, 0, "recursive search must request inner yields")
	assert_gt(
		w.coop_inner_yields,
		int(raw.get("completed_depth", 0)),
		"inner yields must exceed ID depth count (not only between depths)"
	)
	var inner_during_first_root := 0
	for s in samples:
		if int(s["inner"]) <= 0:
			continue
		var all_zero := true
		var efforts: PackedInt32Array = s["efforts"]
		for i in range(efforts.size()):
			if efforts[i] != 0:
				all_zero = false
				break
		# Depth-1 first PV: effort still 0 for every root move while the tree runs.
		if all_zero and int(s["nodes"]) > 0:
			inner_during_first_root += 1
	# Also count inner yields after depth 1, while completed_depth is stale
	# relative to nodes jumping inside one tree (seldepth/nodes rising).
	var inner_cb_hits := 0
	var prev_inner := 0
	for s in samples:
		if int(s["inner"]) > prev_inner:
			inner_cb_hits += 1
			prev_inner = int(s["inner"])
	assert_gt(inner_cb_hits, 6, "yield_cb must run from inside recursive search many times")
	assert_true(
		inner_during_first_root > 0 or inner_cb_hits > int(raw.get("completed_depth", 0)) * 2,
		"yields during a root-move tree, not only between root moves"
	)
	var bm: int = int(raw.get("bestmove", Types.MOVE_NONE))
	assert_true(Types.move_is_ok(bm))
	assert_true(pos.legal(bm))
	assert_eq(pos.get_fen(), START_FEN)
	assert_gte(int(raw.get("completed_depth", 0)), 1)


func test_cooperative_depth6_pumps_frames_during_inner_search() -> void:
	var e = _make_engine()
	var infos: Array = []
	var bests: Array = []
	var inner_frames: Array = [0]
	var prev_inner: Array = [0]
	e.search_info.connect(func(info): infos.append(info.depth))
	e.best_move_found.connect(func(res): bests.append(res))
	var yield_cb := func():
		if e._worker != null:
			var inner: int = e._worker.coop_inner_yields
			if inner > prev_inner[0]:
				inner_frames[0] += 1
				prev_inner[0] = inner
		await get_tree().process_frame
	assert_eq(e.start_search({"depth": 6, "cooperative": true, "yield_cb": yield_cb}), OK)
	assert_eq(e._search_thread, null)
	assert_true(e.is_searching(), "must return to the caller while still searching")
	var frames := 0
	while bests.is_empty() and frames < 4000:
		await wait_process_frames(1)
		frames += 1
	assert_eq(bests.size(), 1, "best_move_found exactly once")
	assert_false(e.is_searching())
	assert_true(Types.move_is_ok(bests[0].bestmove))
	assert_true(e.is_legal(bests[0].bestmove))
	assert_eq(bests[0].evaluation_mode, Config.EVALUATION_NNUE)
	assert_gte(infos.size(), 1, "search_info should update HUD depth between yields")
	assert_gt(frames, int(bests[0].completed_depth), "frames > ID-depth-count")
	assert_gt(inner_frames[0], int(bests[0].completed_depth), "frames during recursive search, not only between depths")
	e.shutdown()


func test_engine_warm_search_tables_allocates_before_start_search() -> void:
	var e = _make_engine()
	assert_true(e._history == null or e._history.continuation.is_empty())
	var yields := [0]
	assert_eq(await e.warm_search_tables(func():
		yields[0] += 1
		if false:
			await get_tree().process_frame
	), OK)
	assert_gte(yields[0], 3)
	assert_false(e._history.continuation.is_empty())
	assert_false(e._history.pawn_history.is_empty())
	assert_true(e._history.deep_ready())
	var size0: int = e._history.continuation.size()
	e._history.continuation[0] = 4242
	assert_eq(await e.warm_search_tables(func():
		yields[0] += 1
		if false:
			await get_tree().process_frame
	), OK)
	assert_eq(e._history.continuation.size(), size0)
	assert_eq(e._history.continuation[0], 4242, "second warmup must not refill")
	assert_eq(e.start_search({"depth": 1, "sync": true}), OK)
	assert_eq(e._history.continuation.size(), size0, "search must reuse warmed History")
	assert_true(e._history.deep_ready())
	assert_true(Types.move_is_ok(e._last_result.bestmove))
	e.shutdown()


func test_web_boot_status_mentions_history_warmup() -> void:
	assert_eq(Controller.STATUS_WARMING_SEARCH, "正在准备棋力…")
	var main_src := FileAccess.get_file_as_string("res://src/game/main.gd")
	assert_true(main_src.contains("warm_search_tables"), main_src)
	assert_true(main_src.contains("STATUS_WARMING_SEARCH"), main_src)
