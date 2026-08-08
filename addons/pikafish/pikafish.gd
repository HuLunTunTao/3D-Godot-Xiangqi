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
const TTScript = preload("res://addons/pikafish/search/tt.gd")
const ResultScript = preload("res://addons/pikafish/search/result.gd")
const TimeManScript = preload("res://addons/pikafish/search/time_manager.gd")
const InfoScript = preload("res://addons/pikafish/search/info.gd")
const LimitsScript = preload("res://addons/pikafish/search/limits.gd")

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
var _undo_stack: Array = []
var _canary_ok: bool = false
var _canary_detail: String = ""
var _tt = null
var _worker = null
var _history = null
var _last_result = null
var _search_thread: Thread = null
var _search_stop := false
## Generation token so superseded deferred finishes are ignored.
var _search_gen: int = 0
## Raw result written by the search thread before call_deferred finish.
var _thread_raw: Dictionary = {}
var _finish_emitted_gen: int = -1


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
	_undo_stack.clear()
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
	return _pos.set_fen(fen)


func get_fen() -> String:
	return _pos.get_fen()


func set_position(fen: String, moves: PackedInt32Array = PackedInt32Array()) -> Error:
	var err := set_fen(fen)
	if err != OK:
		return err
	if moves.size() > 0:
		return ERR_UNAVAILABLE  # Phase C
	return OK


func push_move(move: int) -> Error:
	if not _initialized:
		return ERR_UNCONFIGURED
	if not _pos.legal(move):
		return ERR_INVALID_PARAMETER
	_pos.do_move(move)
	return OK


func pop_move() -> Error:
	if not _initialized:
		return ERR_UNCONFIGURED
	var i: int = _pos.st()
	if i <= 0:
		return ERR_INVALID_PARAMETER
	var m: int = _pos.stack.move[i]
	_pos.undo_move(m)
	return OK


func legal_moves() -> PackedInt32Array:
	var out := PackedInt32Array()
	out.resize(Types.MAX_MOVES)
	if not _initialized:
		return PackedInt32Array()
	var n: int = MovegenScript.generate(_pos, MovegenScript.GEN_LEGAL, out)
	out.resize(n)
	return out


func is_legal(move: int) -> bool:
	if not _initialized:
		return false
	return _pos.legal(move)


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
	## Also accepts wtime/btime/winc/binc/movestogo, depth, nodes, infinite, ponder.
	## Pass sync:true only for tests/tools that must block the caller.
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
	var run_sync: bool = bool(packed.get("sync", false))

	if run_sync:
		var raw: Dictionary = _run_search_job(packed, false)
		_finish_search(raw, gen)
		return OK
	_search_thread = Thread.new()
	_search_thread.start(_search_thread_main.bind(packed, gen))
	return OK


func stop_search() -> void:
	## Idempotent. Signals the worker, joins the thread, and delivers the last
	## complete-iteration result (or legal fallback) on the calling thread when possible.
	_search_stop = true
	if _worker != null:
		_worker.request_stop()
	_join_search_thread()
	if _searching:
		var gen: int = _search_gen
		if not _thread_raw.is_empty():
			_finish_search(_thread_raw, gen)
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
		else:
			depth = limits.depth
			nodes_lim = limits.nodes
			movetime_ms = limits.movetime_ms
			infinite = limits.infinite
			ponder = limits.ponder
			movestogo = limits.movestogo
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
	}


func _join_search_thread() -> void:
	if _search_thread != null:
		if _search_thread.is_started():
			_search_thread.wait_to_finish()
		_search_thread = null


func _search_thread_main(packed: Dictionary, gen: int) -> void:
	## Background search owns a Position clone; main thread must not mutate _pos.
	var raw: Dictionary = _run_search_job(packed, true)
	_thread_raw = raw
	call_deferred("_finish_search_deferred", raw, gen)


func _run_search_job(packed: Dictionary, on_thread: bool) -> Dictionary:
	var depth: int = int(packed.get("depth", 4))
	var nodes_lim: int = int(packed.get("nodes", 0))
	var fen: String = str(packed.get("fen", ""))
	var worker = SearchWorkerScript.new()
	_worker = worker
	if on_thread:
		var thread_pos = PositionScript.new()
		thread_pos.set_fen(fen)
		worker.pos = thread_pos
	else:
		worker.pos = _pos
	worker.tt = _tt
	# Reuse deep history across searches (avoid re-filling ~80 MiB each start).
	if _history == null:
		_history = preload("res://addons/pikafish/search/history.gd").new()
	worker.history = _history
	worker.external_stop_cb = func() -> bool:
		return _search_stop
	# Per-iteration info → main thread via call_deferred when on worker thread.
	if on_thread:
		worker.info_cb = func(info_dict: Dictionary) -> void:
			call_deferred("_emit_search_info", info_dict, false)
	else:
		worker.info_cb = func(info_dict: Dictionary) -> void:
			_emit_search_info(info_dict, false)
	# D006: Prefer incremental NNUE (board+acc synced with search do/undo).
	worker.use_nnue_eval = config != null and config.use_nnue_eval
	if worker.use_nnue_eval and loader != null and features != null:
		worker.nnue_board = NnueBoard.new()
		worker.nnue_board.load_from_position(worker.pos)
		worker.nnue_acc = NnueAcc.new(loader, features)
		worker.nnue_acc.refresh(worker.nnue_board)
	worker.evaluate_cb = func(p) -> int:
		return evaluate_board(_nnue_board_from_position(p))
	if config != null:
		worker.enable_probcut = config.enable_probcut
		worker.enable_singular = config.enable_singular
	var tm = TimeManScript.new()
	tm.init_from_limits(packed, worker.pos.side_to_move if worker.pos != null else 0, worker.pos.game_ply if worker.pos != null else 0)
	worker.time_manager = tm
	if _search_stop:
		worker.request_stop()
	var raw: Dictionary = worker.search(depth, nodes_lim)
	if _search_stop and str(raw.get("stop_reason", "")) != "stop":
		raw["stop_reason"] = "stop"
	raw["time_ms"] = tm.elapsed_ms()
	raw["elapsed_ms"] = raw["time_ms"]
	return raw


func _finish_search_deferred(raw: Dictionary, gen: int) -> void:
	_join_search_thread()
	_finish_search(raw, gen)


func _finish_search(raw: Dictionary, gen: int) -> void:
	if gen != _search_gen:
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
	_emit_search_info({
		"depth": _last_result.depth,
		"seldepth": _last_result.seldepth,
		"score": _last_result.score,
		"nodes": _last_result.nodes,
		"nps": _last_result.nps,
		"time_ms": _last_result.time_ms,
		"pv": _last_result.pv,
	}, true)
	_searching = false
	_worker = null
	best_move_found.emit(_last_result)


func _emit_search_info(info_dict: Dictionary, is_final: bool) -> void:
	var info = InfoScript.new()
	info.depth = int(info_dict.get("depth", 0))
	info.seldepth = int(info_dict.get("seldepth", 0))
	info.score = int(info_dict.get("score", 0))
	info.nodes = int(info_dict.get("nodes", 0))
	info.nps = int(info_dict.get("nps", 0))
	info.time_ms = int(info_dict.get("time_ms", 0))
	info.pv = info_dict.get("pv", PackedInt32Array())
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
	}


## --- Incremental NNUE board API ---

func refresh(pos) -> void:
	_inc.refresh(pos)
	_undo_stack.clear()


func evaluate_incremental(pos) -> int:
	return _inc.evaluate(pos)


func do_move(pos, frm: int, to: int) -> void:
	var u: Dictionary = pos.do_move(frm, to)
	var inc_frame = _inc.update_after_move(pos)
	_undo_stack.append({"board": u, "inc": inc_frame})


func undo_move(pos) -> void:
	assert(not _undo_stack.is_empty(), "undo_move: empty stack")
	var frame: Dictionary = _undo_stack.pop_back()
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
