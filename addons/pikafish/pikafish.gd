class_name PikafishEngine
extends RefCounted

## Public facade for the Pikafish Godot addon.
## Phase E: NNUE lives under `addons/pikafish/nnue/` (+ `shaders/`); no host `src/nnue` dependency.
##
## GDS-DIVERGENCE: PLATFORM (D001 — migrated)
## C++ behavior: single Engine owns Position/NNUE/Search threads.
## GDScript replacement: RefCounted facade; NNUE + search in addon.
## Proof: test_addon_shell.gd + NNUE GUT suite.

signal search_info(info)
signal best_move_found(result)
signal backend_changed(name: String, reason: String)
## Emitted after every accepted position mutation. `move_info` is null for set_fen/new_game.
signal position_changed(snapshot, move_info)

const NnueLoader = preload("res://addons/pikafish/nnue/loader.gd")
const NnueFeatures = preload("res://addons/pikafish/nnue/features.gd")
const NnueGpu = preload("res://addons/pikafish/nnue/gpu_inference.gd")
const NnueCpu = preload("res://addons/pikafish/nnue/cpu_inference.gd")
const NnueAcc = preload("res://addons/pikafish/nnue/accumulator.gd")
const NnueAsync = preload("res://addons/pikafish/nnue/async_batch_worker.gd")
const NnueBoard = preload("res://addons/pikafish/nnue/board.gd")
const Types = preload("res://addons/pikafish/core/types.gd")
const ConfigScript = preload("res://addons/pikafish/config.gd")
const PositionScript = preload("res://addons/pikafish/core/position.gd")
const MovegenScript = preload("res://addons/pikafish/core/movegen.gd")
const AttacksScript = preload("res://addons/pikafish/core/attacks.gd")
const ZobristScript = preload("res://addons/pikafish/core/zobrist.gd")
const BitboardScript = preload("res://addons/pikafish/core/bitboard.gd")
const SearchWorkerScript = preload("res://addons/pikafish/search/search_worker.gd")
const MaterialEvaluatorScript = preload("res://addons/pikafish/search/material_evaluator.gd")
const NnueEvaluatorScript = preload("res://addons/pikafish/search/nnue_evaluator.gd")
const TTScript = preload("res://addons/pikafish/search/tt.gd")
const ResultScript = preload("res://addons/pikafish/search/result.gd")
const TimeManScript = preload("res://addons/pikafish/search/time_manager.gd")
const TimeStateScript = preload("res://addons/pikafish/search/time_state.gd")
const InfoScript = preload("res://addons/pikafish/search/info.gd")
const LimitsScript = preload("res://addons/pikafish/search/limits.gd")
const PositionViewScript = preload("res://addons/pikafish/core/position_view.gd")
const MoveInfoScript = preload("res://addons/pikafish/core/move_info.gd")

const START_FEN := "rnbakabnr/9/1c5c1/p1p1p1p1p/9/9/P1P1P1P1P/1C5C1/9/RNBAKABNR w - - 0 1"

var config
var _pos = PositionScript.new()
var _initialized := false
var _searching := false

var loader
var features
var using_gpu: bool = false
var backend_name: String = "none"
var _backend_reason: String = "uninitialized"
var _gpu = null
var _cpu = null
var _inc = null
var _async_worker = null
var _move_history: Array = []
var _redo_stack: Array = []
var _position_revision: int = 0
## Private frames for the legacy incremental-NNUE board API below.
var _incremental_undo_stack: Array = []
var _canary_ok: bool = false
var _canary_detail: String = ""
var _tt = null
var _worker = null
var _history = null
var _time_state = TimeStateScript.new()
var _last_result = null
var _search_thread: Thread = null
var _search_stop := false
## Generation token so superseded deferred finishes are ignored.
var _search_gen: int = 0
## Raw result written by the search thread before call_deferred finish.
var _thread_raw: Dictionary = {}
var _finish_emitted_gen: int = -1
## Main-thread cooperative search (web): a Node pump owns the coroutine.
var _coop_pump: Node = null
var _coop_jobs: int = 0


func initialize(cfg = null) -> Error:
	if _initialized:
		return ERR_ALREADY_IN_USE
	config = cfg if cfg != null else ConfigScript.new()
	BitboardScript.ensure_tables()
	AttacksScript.init_tables()
	ZobristScript.init_keys()
	loader = NnueLoader.new()
	var err: Error = loader.load_all(config.resolve_network_dir())
	if err != OK:
		_backend_reason = loader.load_error
		return err
	features = NnueFeatures.new(loader)
	_cpu = NnueCpu.new(loader, features)
	_inc = NnueAcc.new(loader, features)
	err = _select_backend()
	if err != OK:
		return err
	_initialized = true
	return OK


## Adopt an already-loaded NNUE loader (test and tooling integration path).
func adopt_host_nnue(ld, ft) -> Error:
	if _initialized:
		return ERR_ALREADY_IN_USE
	config = ConfigScript.new()
	if ld == null or not ld.loaded:
		return ERR_INVALID_PARAMETER
	loader = ld
	features = ft if ft != null else NnueFeatures.new(loader)
	_cpu = NnueCpu.new(loader, features)
	_inc = NnueAcc.new(loader, features)
	var err: Error = _select_backend()
	if err != OK:
		return err
	_initialized = true
	return OK


func shutdown() -> void:
	if not _initialized and _gpu == null and _async_worker == null and _search_thread == null:
		return
	stop_search()
	_search_gen += 1  # invalidate any pending deferred finishes
	_free_coop_pump()
	if _async_worker != null:
		_async_worker.stop()
		_async_worker = null
	if _gpu != null:
		_gpu.dispose()
		_gpu = null
	_cpu = null
	_inc = null
	loader = null
	features = null
	_move_history.clear()
	_redo_stack.clear()
	_incremental_undo_stack.clear()
	_worker = null
	_history = null
	_tt = null
	_thread_raw = {}
	_initialized = false
	backend_name = "none"
	using_gpu = false
	_backend_reason = "shutdown"


func set_fen(fen: String) -> Error:
	if not _initialized:
		return ERR_UNCONFIGURED
	# Validate off to the side so a malformed FEN never corrupts the live game state.
	var next = PositionScript.new()
	var err := next.set_fen(fen)
	if err != OK:
		return err
	_invalidate_search_for_position_change()
	_pos = next
	_move_history.clear()
	_redo_stack.clear()
	_position_revision += 1
	_emit_position_changed(null)
	return OK


func new_game() -> Error:
	return set_fen(START_FEN)


func get_fen() -> String:
	return _pos.get_fen()


func position_revision() -> int:
	return _position_revision


func get_position_view():
	var view = PositionViewScript.new()
	view.revision = _position_revision
	if not _initialized:
		return view
	view.fen = _pos.get_fen()
	view.pieces = _pos.board.duplicate()
	view.side_to_move = _pos.side_to_move
	view.in_check = in_check()
	view.result = game_result()
	view.ply = _pos.game_ply
	return view


func piece_at(square: int) -> int:
	if not _initialized or not Types.is_ok_sq(square):
		return Types.NO_PIECE
	return _pos.piece_on(square)


func set_position(fen: String, moves: PackedInt32Array = PackedInt32Array()) -> Error:
	if not _initialized:
		return ERR_UNCONFIGURED
	# Validate the complete move list before replacing the visible position.
	var next = PositionScript.new()
	var err := next.set_fen(fen)
	if err != OK:
		return err
	for move in moves:
		if not _is_legal_on(next, move):
			return ERR_INVALID_PARAMETER
		next.do_move(move)
	_invalidate_search_for_position_change()
	_pos = next
	_move_history.clear()
	_redo_stack.clear()
	_position_revision += 1
	_emit_position_changed(null)
	return OK


func push_move(move: int) -> Error:
	if not _initialized:
		return ERR_UNCONFIGURED
	if not _is_legal_on(_pos, move):
		return ERR_INVALID_PARAMETER
	var info = _make_move_info(move, "move")
	_invalidate_search_for_position_change()
	_pos.do_move(move)
	info.gives_check = in_check()
	_position_revision += 1
	info.revision = _position_revision
	_move_history.append(info.duplicate_info())
	_redo_stack.clear()
	_emit_position_changed(info)
	return OK


func push_uci(text: String) -> Error:
	var move := move_from_uci(text)
	if move == Types.MOVE_NONE:
		return ERR_INVALID_PARAMETER
	return push_move(move)


func pop_move() -> Error:
	if not _initialized:
		return ERR_UNCONFIGURED
	if _move_history.is_empty():
		return ERR_INVALID_PARAMETER
	var original = _move_history.back()
	var m: int = original.move
	var info = original.duplicate_info()
	info.kind = "undo"
	_invalidate_search_for_position_change()
	_pos.undo_move(m)
	_position_revision += 1
	info.revision = _position_revision
	_redo_stack.append(original)
	_move_history.pop_back()
	_emit_position_changed(info)
	return OK


func can_undo() -> bool:
	return not _move_history.is_empty()


func can_redo() -> bool:
	return not _redo_stack.is_empty()


func redo_move() -> Error:
	if not _initialized:
		return ERR_UNCONFIGURED
	if _redo_stack.is_empty():
		return ERR_INVALID_PARAMETER
	var original = _redo_stack.back()
	var move: int = original.move
	if not _is_legal_on(_pos, move):
		return ERR_INVALID_DATA
	var info = _make_move_info(move, "redo")
	_invalidate_search_for_position_change()
	_pos.do_move(move)
	info.gives_check = in_check()
	_position_revision += 1
	info.revision = _position_revision
	_move_history.append(info.duplicate_info())
	_redo_stack.pop_back()
	_emit_position_changed(info)
	return OK


func move_history() -> Array:
	var out: Array = []
	for info in _move_history:
		out.append(info.duplicate_info())
	return out


func last_move_info():
	if _move_history.is_empty():
		return null
	return _move_history.back().duplicate_info()


func legal_moves() -> PackedInt32Array:
	var out := PackedInt32Array()
	out.resize(Types.MAX_MOVES)
	if not _initialized:
		return PackedInt32Array()
	var n: int = MovegenScript.generate(_pos, MovegenScript.GEN_LEGAL, out)
	out.resize(n)
	return out


func legal_moves_from(square: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	if not _initialized or not Types.is_ok_sq(square):
		return out
	for move in legal_moves():
		if Types.from_sq(move) == square:
			out.append(move)
	return out


func square_from_file_rank(file: int, rank: int) -> int:
	if file < 0 or file >= Types.FILE_NB or rank < 0 or rank >= Types.RANK_NB:
		return Types.SQ_NONE
	return Types.make_square(file, rank)


func file_of(square: int) -> int:
	return Types.file_of(square) if Types.is_ok_sq(square) else -1


func rank_of(square: int) -> int:
	return Types.rank_of(square) if Types.is_ok_sq(square) else -1


func is_legal(move: int) -> bool:
	if not _initialized:
		return false
	return _is_legal_on(_pos, move)


func move_from_uci(text: String) -> int:
	if text.length() != 4:
		return Types.MOVE_NONE
	var files := "abcdefghi"
	var ff := files.find(text[0])
	var tf := files.find(text[2])
	if ff < 0 or tf < 0:
		return Types.MOVE_NONE
	var fr := int(text[1])
	var tr := int(text[3])
	return Types.make_move(ff + fr * 9, tf + tr * 9)


func move_to_uci(move: int) -> String:
	if not Types.move_is_ok(move):
		return "0000"
	var files := "abcdefghi"
	var frm := Types.from_sq(move)
	var to := Types.to_sq(move)
	return "%s%d%s%d" % [files[frm % 9], frm / 9, files[to % 9], to / 9]


func in_check() -> bool:
	if not _initialized:
		return false
	var c: Array = _pos.checkers()
	return c[0] != 0 or c[1] != 0


func game_result() -> Dictionary:
	## Mate/stalemate via empty legal moves; rule60 / repetition via rule_judge.
	if not _initialized:
		return {"result": "unavailable"}
	var moves := legal_moves()
	if moves.is_empty():
		if in_check():
			return {"result": "mate", "winner": "black" if _pos.side_to_move == Types.COLOR_WHITE else "white"}
		return {"result": "stalemate"}
	var rj: Dictionary = _pos.rule_judge(0)
	if rj.get("claimed", false):
		var v: int = int(rj.get("value", Types.VALUE_DRAW))
		if v == Types.VALUE_DRAW:
			return {"result": "draw", "reason": "rule_judge"}
		if Types.is_win(v):
			return {"result": "win", "winner": "white" if _pos.side_to_move == Types.COLOR_WHITE else "black", "reason": "rule_judge"}
		if Types.is_loss(v):
			return {"result": "win", "winner": "black" if _pos.side_to_move == Types.COLOR_WHITE else "white", "reason": "rule_judge"}
	return {"result": "ongoing"}


func evaluate_static() -> int:
	if not _initialized:
		return 0
	return evaluate_board(_nnue_board_from_position(_pos))


func perft(depth: int) -> int:
	if not _initialized:
		return 0
	return MovegenScript.perft(_pos, depth)


func evaluate_batch(fens: PackedStringArray) -> PackedInt32Array:
	var boards: Array = []
	for fen in fens:
		var b := NnueBoard.new()
		b.load_fen(fen)
		boards.append(b)
	return evaluate_boards(boards)


func evaluate_board(pos) -> int:
	if using_gpu:
		return _gpu.evaluate(pos)
	return _cpu.evaluate(pos)


func evaluate_boards(positions: Array) -> PackedInt32Array:
	if using_gpu:
		return _gpu.evaluate_batch(positions)
	return _cpu.evaluate_batch(positions)


func evaluate_batch_async(positions: Array, callback: Callable) -> Error:
	if not callback.is_valid() or positions.size() > NnueGpu.BATCH_MAX:
		return ERR_INVALID_PARAMETER
	if _async_worker == null:
		_async_worker = NnueAsync.new(loader, using_gpu)
	return _async_worker.submit(positions, callback)


func start_search(limits) -> Error:
	## Start iterative-deepening search.
	## Recommended (game layer, async by default):
	##   engine.start_search({"movetime_ms": 1200})
	## Also accepts wtime/btime/winc/binc/movestogo/move_overhead_ms, depth,
	## nodes, infinite, ponder. Clock controls use dynamic soft/hard time bounds.
	## Pass sync:true only for tests/tools that must block the caller.
	## Web (single-thread export) uses a main-thread coroutine with frame yields
	## inside iterative deepening, root moves, and the recursive search tree;
	## desktop/editor keep a background Thread. Do not pass sync:true from the game.
	if not _initialized:
		return ERR_UNCONFIGURED
	if _searching:
		return ERR_BUSY
	_join_search_thread()
	_search_stop = false
	_thread_raw = {}
	_search_gen += 1
	var gen: int = _search_gen
	_searching = true
	if _tt == null:
		_tt = TTScript.new()
		_tt.resize_mb(config.hash_mb if config != null else 16)

	var packed: Dictionary = _normalize_limits(limits)
	packed["fen"] = _pos.get_fen()
	packed["_gen"] = gen
	packed["_position_revision"] = _position_revision
	if typeof(limits) == TYPE_DICTIONARY and limits.has("yield_cb"):
		packed["yield_cb"] = limits["yield_cb"]
	var run_sync: bool = bool(packed.get("sync", false))

	if run_sync:
		var raw: Dictionary = _run_search_job(packed, false)
		raw["position_revision"] = int(packed["_position_revision"])
		_finish_search(raw, gen)
		return OK
	if _should_use_cooperative(packed):
		return _start_cooperative_search(packed, gen)
	_search_thread = Thread.new()
	_search_thread.start(_search_thread_main.bind(packed, gen))
	return OK


func stop_search() -> void:
	## Idempotent. Signals the worker, joins the thread, and delivers the last
	## complete-iteration result (or legal fallback) on the calling thread when possible.
	## Cooperative (web) search cannot join; the in-flight coroutine stops at the
	## next yield / stop check and then emits on the main thread.
	_search_stop = true
	if _worker != null:
		_worker.request_stop()
	_join_search_thread()
	if _searching:
		var gen: int = _search_gen
		if not _thread_raw.is_empty():
			_finish_search(_thread_raw, gen)
		elif _coop_jobs > 0:
			pass
		else:
			_searching = false


func is_searching() -> bool:
	return _searching


## Normalize Dictionary / PikafishSearchLimits into a packed job dict.
func _normalize_limits(limits) -> Dictionary:
	var depth: int = 0
	var nodes_lim: int = 0
	var movetime_ms: int = 0
	var infinite := false
	var ponder := false
	var wtime := 0
	var btime := 0
	var winc := 0
	var binc := 0
	var movestogo := 0
	var move_overhead_ms := 10
	var sync_opt = null
	var cooperative := false

	if limits != null:
		if typeof(limits) == TYPE_DICTIONARY:
			depth = int(limits.get("depth", 0))
			nodes_lim = int(limits.get("nodes", 0))
			movetime_ms = int(limits.get("movetime_ms", limits.get("movetime", 0)))
			infinite = bool(limits.get("infinite", false))
			ponder = bool(limits.get("ponder", false))
			wtime = int(limits.get("wtime", 0))
			btime = int(limits.get("btime", 0))
			winc = int(limits.get("winc", 0))
			binc = int(limits.get("binc", 0))
			movestogo = int(limits.get("movestogo", 0))
			move_overhead_ms = int(limits.get("move_overhead_ms", 10))
			if limits.has("time_ms"):
				var t = limits["time_ms"]
				if typeof(t) == TYPE_PACKED_INT32_ARRAY or typeof(t) == TYPE_ARRAY:
					wtime = int(t[0]) if t.size() > 0 else wtime
					btime = int(t[1]) if t.size() > 1 else btime
			if limits.has("inc_ms"):
				var inc = limits["inc_ms"]
				if typeof(inc) == TYPE_PACKED_INT32_ARRAY or typeof(inc) == TYPE_ARRAY:
					winc = int(inc[0]) if inc.size() > 0 else winc
					binc = int(inc[1]) if inc.size() > 1 else binc
			if limits.has("sync"):
				sync_opt = bool(limits["sync"])
			cooperative = bool(limits.get("cooperative", false))
		else:
			depth = limits.depth
			nodes_lim = limits.nodes
			movetime_ms = limits.movetime_ms
			infinite = limits.infinite
			ponder = limits.ponder
			movestogo = limits.movestogo
			move_overhead_ms = limits.move_overhead_ms
			if limits.time_ms.size() > 0:
				wtime = int(limits.time_ms[0])
			if limits.time_ms.size() > 1:
				btime = int(limits.time_ms[1])
			if limits.inc_ms.size() > 0:
				winc = int(limits.inc_ms[0])
			if limits.inc_ms.size() > 1:
				binc = int(limits.inc_ms[1])
			if limits.sync != null:
				sync_opt = bool(limits.sync)
			cooperative = bool(limits.cooperative)

	var has_time := movetime_ms > 0 or wtime > 0 or btime > 0 or infinite
	# Default depth when caller only asks for time/nodes: deepen until limit.
	if depth <= 0:
		if has_time or nodes_lim > 0:
			depth = Types.MAX_PLY - 1
		else:
			depth = 4

	# Default async for game use; sync:true only when explicitly requested.
	var run_sync := false
	if sync_opt != null:
		run_sync = bool(sync_opt)

	return {
		"depth": depth,
		"nodes": nodes_lim,
		"movetime_ms": movetime_ms,
		"infinite": infinite,
		"ponder": ponder,
		"wtime": wtime,
		"btime": btime,
		"winc": winc,
		"binc": binc,
		"movestogo": movestogo,
		"move_overhead_ms": move_overhead_ms,
		"sync": run_sync,
		"cooperative": cooperative,
	}


func _join_search_thread() -> void:
	if _search_thread != null:
		if _search_thread.is_started():
			_search_thread.wait_to_finish()
		_search_thread = null


func _search_thread_main(packed: Dictionary, gen: int) -> void:
	## Background search owns a Position clone; main thread must not mutate _pos.
	var raw: Dictionary = _run_search_job(packed, true)
	raw["position_revision"] = int(packed.get("_position_revision", -1))
	_thread_raw = raw
	call_deferred("_finish_search_deferred", raw, gen)


func _run_search_job(packed: Dictionary, on_thread: bool) -> Dictionary:
	var worker = _setup_search_worker(packed, on_thread, on_thread)
	var raw: Dictionary = worker.search(int(packed.get("depth", 4)), int(packed.get("nodes", 0)))
	return _decorate_search_raw(raw, worker)


func uses_cooperative_search(limits = null) -> bool:
	## Web always cooperative unless sync:true. Tests may pass cooperative:true.
	if limits == null:
		return OS.has_feature("web")
	var packed: Dictionary = _normalize_limits(limits)
	if typeof(limits) == TYPE_DICTIONARY and limits.has("yield_cb"):
		packed["yield_cb"] = limits["yield_cb"]
	return _should_use_cooperative(packed)


func _should_use_cooperative(packed: Dictionary) -> bool:
	if bool(packed.get("sync", false)):
		return false
	if OS.has_feature("web"):
		return true
	if bool(packed.get("cooperative", false)):
		return true
	var cb = packed.get("yield_cb", null)
	return typeof(cb) == TYPE_CALLABLE and cb.is_valid()


func _start_cooperative_search(packed: Dictionary, gen: int) -> Error:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		var raw: Dictionary = _run_search_job(packed, false)
		raw["position_revision"] = int(packed.get("_position_revision", -1))
		_finish_search(raw, gen)
		return OK
	var pump := _CoopSearchPump.new()
	pump.name = "PikafishCoopSearch_%d" % gen
	pump.job = _cooperative_search_main.bind(packed, gen)
	_coop_pump = pump
	tree.root.add_child(pump)
	return OK


func _cooperative_search_main(packed: Dictionary, gen: int) -> void:
	_coop_jobs += 1
	var raw: Dictionary = await _run_search_job_async(packed)
	raw["position_revision"] = int(packed.get("_position_revision", -1))
	_thread_raw = raw
	_finish_search(raw, gen)
	_coop_jobs = maxi(_coop_jobs - 1, 0)


func _run_search_job_async(packed: Dictionary):
	var worker = _setup_search_worker(packed, true, false)
	var cb = packed.get("yield_cb", null)
	if typeof(cb) == TYPE_CALLABLE and cb.is_valid():
		worker.yield_cb = cb
	else:
		worker.yield_cb = _default_coop_yield
	# One frame so a single root-move tree cannot freeze the web main thread.
	worker.yield_interval_ms = 16
	var raw: Dictionary = await worker.search_async(
		int(packed.get("depth", 4)), int(packed.get("nodes", 0))
	)
	return _decorate_search_raw(raw, worker)


func _default_coop_yield() -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree != null:
		await tree.process_frame


## Fill Continuation / Pawn / UnifiedCorrection on the History instance the
## worker will reuse. Web boot calls this while the loading overlay is up so
## the first AI think does not hitch on ~80 MiB of PackedInt32 fill.
## Subsequent ensure_deep() / start_search are a no-op for those arrays.
func warm_search_tables(yield_cb: Callable = Callable()):
	if not _initialized:
		return ERR_UNCONFIGURED
	if _history == null:
		_history = preload("res://addons/pikafish/search/history.gd").new()
	var cb: Callable = yield_cb if yield_cb.is_valid() else _default_coop_yield
	await _history.ensure_deep_async(cb)
	return OK


func _free_coop_pump() -> void:
	if _coop_pump != null and is_instance_valid(_coop_pump):
		_coop_pump.queue_free()
	_coop_pump = null


func _setup_search_worker(packed: Dictionary, clone_pos: bool, defer_info: bool):
	var fen: String = str(packed.get("fen", ""))
	var gen: int = int(packed.get("_gen", -1))
	var revision: int = int(packed.get("_position_revision", -1))
	var worker = SearchWorkerScript.new()
	_worker = worker
	if clone_pos:
		var search_pos = PositionScript.new()
		search_pos.set_fen(fen)
		worker.pos = search_pos
	else:
		worker.pos = _pos
	worker.tt = _tt
	if _history == null:
		_history = preload("res://addons/pikafish/search/history.gd").new()
	worker.history = _history
	var job_gen: int = gen
	worker.external_stop_cb = func() -> bool:
		return _search_stop or job_gen != _search_gen
	if defer_info:
		worker.info_cb = func(info_dict: Dictionary) -> void:
			call_deferred("_emit_search_info", info_dict, false, gen, revision)
	else:
		worker.info_cb = func(info_dict: Dictionary) -> void:
			_emit_search_info(info_dict, false, gen, revision)
	var eval_mode := ConfigScript.EVALUATION_NNUE
	if config != null:
		eval_mode = config.resolved_evaluation_mode()
	if eval_mode == ConfigScript.EVALUATION_NNUE and loader != null and features != null:
		worker.evaluator = NnueEvaluatorScript.new(loader, features)
	else:
		worker.evaluator = MaterialEvaluatorScript.new()
		eval_mode = ConfigScript.EVALUATION_MATERIAL
	worker.set_meta("eval_mode", eval_mode)
	if config != null:
		worker.enable_probcut = config.enable_probcut
		worker.enable_singular = config.enable_singular
	var tm = TimeManScript.new()
	tm.attach_state(_time_state)
	tm.init_from_limits(packed, worker.pos.side_to_move if worker.pos != null else 0, worker.pos.game_ply if worker.pos != null else 0)
	worker.time_manager = tm
	if _search_stop:
		worker.request_stop()
	return worker


func _decorate_search_raw(raw: Dictionary, worker) -> Dictionary:
	var eval_mode = worker.get_meta("eval_mode", ConfigScript.EVALUATION_NNUE)
	raw["evaluation_mode"] = eval_mode
	if _search_stop and str(raw.get("stop_reason", "")) != "stop":
		raw["stop_reason"] = "stop"
	var tm = worker.time_manager
	raw["time_ms"] = tm.elapsed_ms() if tm != null else 0
	raw["elapsed_ms"] = raw["time_ms"]
	return raw


func _finish_search_deferred(raw: Dictionary, gen: int) -> void:
	_join_search_thread()
	_finish_search(raw, gen)


func _finish_search(raw: Dictionary, gen: int) -> void:
	if gen != _search_gen:
		return
	var revision: int = int(raw.get("position_revision", -1))
	if revision != _position_revision:
		_searching = false
		_worker = null
		return
	if _finish_emitted_gen == gen:
		_searching = false
		return
	_finish_emitted_gen = gen
	_last_result = ResultScript.new()
	_last_result.bestmove = int(raw.get("bestmove", Types.MOVE_NONE))
	_last_result.score = int(raw.get("score", 0))
	_last_result.nodes = int(raw.get("nodes", 0))
	_last_result.pv = raw.get("pv", PackedInt32Array())
	_last_result.ponder = _last_result.pv[1] if _last_result.pv.size() > 1 else Types.MOVE_NONE
	_last_result.depth = int(raw.get("depth", raw.get("completed_depth", 0)))
	_last_result.completed_depth = int(raw.get("completed_depth", _last_result.depth))
	_last_result.requested_depth = int(raw.get("requested_depth", 0))
	_last_result.seldepth = int(raw.get("seldepth", 0))
	_last_result.time_ms = int(raw.get("time_ms", raw.get("elapsed_ms", 0)))
	_last_result.elapsed_ms = _last_result.time_ms
	if _last_result.time_ms > 0:
		_last_result.nps = int(_last_result.nodes * 1000 / _last_result.time_ms)
	var reason: String = str(raw.get("stop_reason", "depth"))
	_last_result.stop_reason = reason
	_last_result.stopped = reason == "stop"
	_last_result.timed_out = reason == "movetime" or reason == "time"
	_last_result.node_limited = reason == "nodes"
	_last_result.from_complete_iteration = bool(raw.get("from_complete_iteration", true))
	_last_result.incomplete = bool(raw.get("incomplete", false))
	_last_result.revision = revision
	_last_result.evaluation_mode = str(raw.get("evaluation_mode", ""))
	_last_result.soft_time_ms = int(raw.get("soft_time_ms", 0))
	_last_result.hard_time_ms = int(raw.get("hard_time_ms", 0))
	_emit_search_info({
		"depth": _last_result.depth,
		"seldepth": _last_result.seldepth,
		"score": _last_result.score,
		"nodes": _last_result.nodes,
		"nps": _last_result.nps,
		"time_ms": _last_result.time_ms,
		"soft_time_ms": _last_result.soft_time_ms,
		"hard_time_ms": _last_result.hard_time_ms,
		"pv": _last_result.pv,
	}, true, gen, revision)
	_searching = false
	_worker = null
	best_move_found.emit(_last_result)


func _emit_search_info(info_dict: Dictionary, is_final: bool, gen: int = -1, revision: int = -1) -> void:
	if gen >= 0 and gen != _search_gen:
		return
	if revision >= 0 and revision != _position_revision:
		return
	var info = InfoScript.new()
	info.depth = int(info_dict.get("depth", 0))
	info.seldepth = int(info_dict.get("seldepth", 0))
	info.score = int(info_dict.get("score", 0))
	info.nodes = int(info_dict.get("nodes", 0))
	info.nps = int(info_dict.get("nps", 0))
	info.time_ms = int(info_dict.get("time_ms", 0))
	info.soft_time_ms = int(info_dict.get("soft_time_ms", 0))
	info.hard_time_ms = int(info_dict.get("hard_time_ms", 0))
	info.pv = info_dict.get("pv", PackedInt32Array())
	info.revision = _position_revision if revision < 0 else revision
	info.is_final = is_final
	search_info.emit(info)


func backend_info() -> Dictionary:
	return {
		"backend": backend_name,
		"using_gpu": using_gpu,
		"reason": _backend_reason,
		"canary_ok": _canary_ok,
		"canary_detail": _canary_detail,
		"network_dir": loader.network_dir if loader != null else "",
		"loaded": loader.loaded if loader != null else false,
		"initialized": _initialized,
		"position_revision": _position_revision,
	}


func _make_move_info(move: int, kind: String):
	var info = MoveInfoScript.new()
	info.kind = kind
	info.move = move
	info.from = Types.from_sq(move)
	info.to = Types.to_sq(move)
	info.moving_piece = _pos.moved_piece(move)
	info.captured_piece = _pos.piece_on(info.to)
	info.side_before = _pos.side_to_move
	info.uci = move_to_uci(move)
	return info


func _is_legal_on(pos, move: int) -> bool:
	if not Types.move_is_ok(move):
		return false
	var from := Types.from_sq(move)
	var to := Types.to_sq(move)
	if not Types.is_ok_sq(from) or not Types.is_ok_sq(to):
		return false
	return pos.pseudo_legal(move) and pos.legal(move)


func _emit_position_changed(move_info) -> void:
	position_changed.emit(get_position_view(), move_info)


func _invalidate_search_for_position_change() -> void:
	## A completed worker may still reach the main thread after cancellation.
	## Incrementing the generation and revision prevents that stale result from emitting.
	if not _searching:
		return
	_search_stop = true
	_search_gen += 1
	if _worker != null:
		_worker.request_stop()
	_join_search_thread()
	_searching = false
	_worker = null
	_thread_raw = {}


## --- Incremental NNUE board API ---

func refresh(pos) -> void:
	_inc.refresh(pos)
	_incremental_undo_stack.clear()


func evaluate_incremental(pos) -> int:
	return _inc.evaluate(pos)


func do_move(pos, frm: int, to: int) -> void:
	var u: Dictionary = pos.do_move(frm, to)
	var inc_frame = _inc.update_after_move(pos)
	_incremental_undo_stack.append({"board": u, "inc": inc_frame})


func undo_move(pos) -> void:
	assert(not _incremental_undo_stack.is_empty(), "undo_move: empty stack")
	var frame: Dictionary = _incremental_undo_stack.pop_back()
	pos.undo_move(frame["board"])
	_inc.undo_update(frame["inc"])


func _nnue_board_from_position(pos) -> Variant:
	var board := NnueBoard.new()
	board.load_from_position(pos)
	return board


func _select_backend() -> Error:
	using_gpu = false
	backend_name = "cpu"
	_backend_reason = "cpu default"
	if config != null and not config.prefer_gpu:
		_backend_reason = "prefer_gpu=false"
		backend_changed.emit(backend_name, _backend_reason)
		return OK

	# GDS-DIVERGENCE: PLATFORM (D003) — version gate removed; canary decides GPU.
	var gpu := NnueGpu.try_create(loader, features)
	if gpu == null or not gpu.ready:
		_backend_reason = "no RenderingDevice or shader init failed"
		backend_changed.emit(backend_name, _backend_reason)
		return OK

	var canary := _run_canary(gpu)
	_canary_ok = canary["ok"]
	_canary_detail = canary["detail"]
	if _canary_ok:
		_gpu = gpu
		using_gpu = true
		backend_name = "gpu"
		_backend_reason = "canary passed: " + _canary_detail
	else:
		gpu.dispose()
		_backend_reason = "canary failed: " + _canary_detail
	backend_changed.emit(backend_name, _backend_reason)
	return OK


func _run_canary(gpu) -> Dictionary:
	var path := "res://data/reference.json"
	if not FileAccess.file_exists(path):
		var addon_ref := "res://addons/pikafish/data/reference.json"
		if FileAccess.file_exists(addon_ref):
			path = addon_ref
		else:
			# No oracle file in this project copy — accept GPU if it constructs.
			return {"ok": true, "detail": "no reference.json; construction-only canary"}
	var f := FileAccess.open(path, FileAccess.READ)
	var records = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(records) != TYPE_ARRAY or records.is_empty():
		return {"ok": false, "detail": "reference.json empty/invalid"}
	var n: int = mini(config.canary_count if config != null else 5, records.size())
	# Prefer diverse indices across the 23-position set.
	var idxs: Array[int] = []
	if records.size() >= n:
		for i in range(n):
			idxs.append(int(round(float(i) * float(records.size() - 1) / float(maxi(n - 1, 1)))))
	else:
		for i in range(records.size()):
			idxs.append(i)
	var bad := 0
	for i in idxs:
		var board := NnueBoard.new()
		board.load_fen(records[i]["fen"])
		var cpu_v: int = _cpu.evaluate(board)
		var gpu_v: int = gpu.evaluate(board)
		if absi(cpu_v - gpu_v) > 1:
			bad += 1
	return {
		"ok": bad == 0,
		"detail": "checked=%d bad=%d" % [idxs.size(), bad],
	}


class _CoopSearchPump extends Node:
	## Owns a main-thread search coroutine so `await process_frame` keeps running
	## after `start_search` returns. Do not use Thread on web exports.
	var job: Callable

	func _ready() -> void:
		if job.is_valid():
			await job.call()
		queue_free()
