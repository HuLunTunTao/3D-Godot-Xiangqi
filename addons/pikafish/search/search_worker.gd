class_name PikafishSearchWorker
extends RefCounted

## Upstream: Pikafish 2c5c998c, search.cpp — Phase G PVS + Phase H stop checks.
## PV / NonPV / Root, aspiration (flagged), TT probe/cutoff/write, mate distance,
## null-move / razoring / futility / LMR / ProbCut / singular flags (default off).

const T = preload("res://addons/pikafish/core/types.gd")
const MG = preload("res://addons/pikafish/core/movegen.gd")
const Hist = preload("res://addons/pikafish/search/history.gd")
const MP = preload("res://addons/pikafish/search/move_picker.gd")
const Reductions = preload("res://addons/pikafish/search/reductions.gd")
const TimeMan = preload("res://addons/pikafish/search/time_manager.gd")
const MaterialEvaluator = preload("res://addons/pikafish/search/material_evaluator.gd")
const RootMove = preload("res://addons/pikafish/search/root_move.gd")

const NODE_NON_PV := 0
const NODE_PV := 1
const NODE_ROOT := 2

## Stop-check cadence (avoid per-node Time.get_ticks_msec).
## Tighter than upstream-style 512–2048 so NNUE leaf latency still meets stop p95.
const STOP_CHECK_MASK := 255
## Upstream: Stack[MAX_PLY+10] with ss = stack+7 for (ss-7)..(ss+2).
const SS_OFFSET := 7
const SS_SIZE := 256  # T.MAX_PLY(246) + 10

var pos
var tt
var history = null  ## PikafishHistory
var reductions = null  ## PikafishReductions
var time_manager = null  ## PikafishTimeManager
## Injected static-evaluation strategy. Direct SearchWorker users get material
## fallback; PikafishEngine injects CPU incremental NNUE by default.
var evaluator = null  ## PikafishSearchEvaluator
## Optional external stop (engine sets via Thread); polled with stop_flag.
var external_stop_cb: Callable
## Optional per-iteration info: Callable(Dictionary) after each completed ID step.
var info_cb: Callable
## Optional cooperative yield for web/main-thread search. Blocking `search()`
## never calls this. `search_async()` awaits it between ID depths and after
## root moves when `yield_interval_ms` has elapsed. The callable may be a
## coroutine or return a Signal; a no-op/immediate callable is valid for tests.
var yield_cb: Callable
## Minimum wall time between non-forced root-move yields (tens of ms, not a full movetime).
var yield_interval_ms: int = 40
var _last_yield_msec: int = 0
var stop_flag := false
var nodes: int = 0
var seldepth: int = 0
var best_move: int = T.MOVE_NONE
var best_score: int = T.VALUE_NONE
var pv: PackedInt32Array = PackedInt32Array()
var completed_depth: int = 0
var requested_depth: int = 0
## Stable snapshot from the last fully finished iteration (not mid-iteration root updates).
var _stable_best: int = T.MOVE_NONE
var _stable_score: int = T.VALUE_ZERO
var _stable_pv: PackedInt32Array = PackedInt32Array()
var _from_complete_iteration := false
var _incomplete := false
var _stop_reason: String = ""
## Root-only work statistics consumed by TimeManager after each completed ID step.
var _root_effort_by_move: Dictionary = {}
var _root_best_move_changes: int = 0
var root_moves: Array = []  ## Array[PikafishRootMove], stable across ID iterations.
var _pv_stack: Array = []  ## Array[PackedInt32Array], indexed by search ply.

## Search stack SoA — continuation bases / currentMove / inCheck (Upstream Stack).
var ss_cont_base: PackedInt32Array = PackedInt32Array()
var ss_current_move: PackedInt32Array = PackedInt32Array()
var ss_in_check: PackedByteArray = PackedByteArray()

# Feature flags (plan §G) — enable safe baseline; ProbCut/singular opt-in via tests/config.
var enable_null_move := true
var enable_lmr := true
var enable_futility := true
var enable_razoring := true
var enable_aspiration := true
var enable_probcut := false
var enable_singular := false
func _ensure_helpers() -> void:
	if history == null:
		history = Hist.new()
	if reductions == null:
		reductions = Reductions.new()
	if ss_cont_base.size() != SS_SIZE:
		ss_cont_base.resize(SS_SIZE)
		ss_current_move.resize(SS_SIZE)
		ss_in_check.resize(SS_SIZE)


func _init_search_stack() -> void:
	_ensure_helpers()
	history.ensure_deep()
	var sent: int = history.sentinel_cont_base()
	ss_cont_base.fill(sent)
	ss_current_move.fill(T.MOVE_NONE)
	ss_in_check.fill(0)
	_pv_stack.clear()
	_pv_stack.resize(SS_SIZE)
	for i in range(SS_SIZE):
		_pv_stack[i] = PackedInt32Array()


func _init_root_moves() -> void:
	root_moves.clear()
	if pos == null:
		return
	var legal := PackedInt32Array()
	legal.resize(T.MAX_MOVES)
	var count: int = MG.generate(pos, MG.GEN_LEGAL, legal)
	for i in range(count):
		root_moves.append(RootMove.new(legal[i]))


func _stable_sort_root_moves() -> void:
	# Insertion sort is stable, allocation-free for this tiny list, and preserves
	# upstream's invariant that equal non-PV root moves retain their old order.
	for i in range(1, root_moves.size()):
		var candidate = root_moves[i]
		var j := i - 1
		while j >= 0 and int(root_moves[j].score) < int(candidate.score):
			root_moves[j + 1] = root_moves[j]
			j -= 1
		root_moves[j + 1] = candidate


func _ss(ply: int) -> int:
	return ply + SS_OFFSET


func _cont_hist_for_picker(ply: int) -> PackedInt32Array:
	## Upstream: contHist[] = {(ss-1)..(ss-6)->continuationHistory}
	var out := PackedInt32Array()
	out.resize(6)
	for i in range(6):
		out[i] = ss_cont_base[_ss(ply - 1 - i)]
	return out


func _do_move_synced(m: int) -> void:
	## Upstream Worker::do_move increments nodes here (not at search/qsearch entry).
	nodes += 1
	pos.do_move(m)
	evaluator.do_move(m)


func _undo_move_synced(m: int) -> void:
	pos.undo_move(m)
	evaluator.undo_move()


func _do_null_synced() -> void:
	pos.do_null_move()
	evaluator.do_null_move()


func _undo_null_synced() -> void:
	pos.undo_null_move()
	evaluator.undo_null_move()


func search(depth_limit: int, node_limit: int = 0) -> Dictionary:
	var st: Dictionary = _prepare_search(depth_limit, node_limit)
	depth_limit = int(st["depth_limit"])
	node_limit = int(st["node_limit"])
	for depth in range(1, depth_limit + 1):
		if _id_should_abort_before_depth():
			break
		var snap: Dictionary = _id_begin_depth(st)
		_id_setup_window(snap)
		if bool(snap["use_aspiration"]):
			while true:
				if _should_stop():
					break
				_set_root_optimism(int(snap["root_average"]))
				snap["score"] = _search_root(depth, int(snap["alpha"]), int(snap["beta"]))
				_stable_sort_root_moves()
				if _should_stop():
					break
				if not _id_aspiration_widen(snap):
					break
		else:
			_set_root_optimism(int(st["avg_score"]))
			snap["score"] = _search_root(depth, int(snap["alpha"]), int(snap["beta"]))
			_stable_sort_root_moves()
		if _id_restore_if_stopped(snap):
			break
		if _id_commit_depth(depth, int(snap["score"]), st, node_limit):
			break
	return _finish_search_result()


## Main-thread cooperative search: one job / one TT.new_search, with awaits at
## ID boundaries and (time-gated) root-move boundaries so the scene tree can run.
func search_async(depth_limit: int, node_limit: int = 0):
	var st: Dictionary = _prepare_search(depth_limit, node_limit)
	depth_limit = int(st["depth_limit"])
	node_limit = int(st["node_limit"])
	for depth in range(1, depth_limit + 1):
		await _maybe_yield(true)
		if _id_should_abort_before_depth():
			break
		var snap: Dictionary = _id_begin_depth(st)
		_id_setup_window(snap)
		if bool(snap["use_aspiration"]):
			while true:
				if _should_stop():
					break
				_set_root_optimism(int(snap["root_average"]))
				snap["score"] = await _search_root_async(depth, int(snap["alpha"]), int(snap["beta"]))
				_stable_sort_root_moves()
				if _should_stop():
					break
				if not _id_aspiration_widen(snap):
					break
		else:
			_set_root_optimism(int(st["avg_score"]))
			snap["score"] = await _search_root_async(depth, int(snap["alpha"]), int(snap["beta"]))
			_stable_sort_root_moves()
		if _id_restore_if_stopped(snap):
			break
		if _id_commit_depth(depth, int(snap["score"]), st, node_limit):
			break
	return _finish_search_result()


func _prepare_search(depth_limit: int, node_limit: int) -> Dictionary:
	stop_flag = false
	nodes = 0
	seldepth = 0
	best_move = T.MOVE_NONE
	best_score = T.VALUE_ZERO
	pv = PackedInt32Array()
	completed_depth = 0
	requested_depth = 0
	_stable_best = T.MOVE_NONE
	_stable_score = T.VALUE_ZERO
	_stable_pv = PackedInt32Array()
	_from_complete_iteration = false
	_incomplete = false
	_stop_reason = ""
	_last_yield_msec = Time.get_ticks_msec()
	if evaluator == null:
		evaluator = MaterialEvaluator.new()
	_init_search_stack()
	_init_root_moves()
	evaluator.begin(pos)
	if tt != null:
		tt.new_search()
	if time_manager != null and node_limit <= 0 and time_manager.node_limit > 0:
		node_limit = time_manager.node_limit
	if time_manager != null and depth_limit <= 0 and time_manager.depth_limit > 0:
		depth_limit = time_manager.depth_limit
	# 0 / negative → iterative deepen toward MAX_PLY (movetime / clock / nodes).
	if depth_limit <= 0:
		depth_limit = T.MAX_PLY - 1
	requested_depth = depth_limit
	var avg_score: int = T.VALUE_ZERO
	var iter_values := PackedInt32Array([T.VALUE_ZERO, T.VALUE_ZERO, T.VALUE_ZERO, T.VALUE_ZERO])
	var previous_search_average := T.VALUE_ZERO
	if time_manager != null and time_manager._state != null and time_manager._state.has_previous_score:
		avg_score = time_manager._state.best_previous_score
		previous_search_average = time_manager._state.best_previous_average_score
		iter_values.fill(avg_score)
	_root_effort_by_move.clear()
	return {
		"depth_limit": depth_limit,
		"node_limit": node_limit,
		"avg_score": avg_score,
		"iter_values": iter_values,
		"iter_index": 0,
		"previous_iteration_best": T.MOVE_NONE,
		"last_best_move_depth": 0,
		"total_best_move_changes": 0.0,
		"previous_search_average": previous_search_average,
	}


func _id_should_abort_before_depth() -> bool:
	# Soft stop: do not begin a deeper iteration past optimum.
	if time_manager != null and time_manager.past_optimum() and completed_depth >= 1:
		if _stop_reason.is_empty():
			_stop_reason = "movetime" if time_manager.movetime_ms > 0 else "time"
		return true
	return _should_stop()


func _id_begin_depth(st: Dictionary) -> Dictionary:
	st["total_best_move_changes"] = float(st["total_best_move_changes"]) * 0.5
	_root_best_move_changes = 0
	for root_move in root_moves:
		root_move.begin_iteration(true)
	# Snapshot working root best before this iteration; restore if aborted mid-ID.
	return {
		"pre_best": best_move,
		"pre_score": best_score,
		"pre_pv": pv.duplicate(),
		"alpha": -T.VALUE_INFINITE,
		"beta": T.VALUE_INFINITE,
		"delta": T.VALUE_INFINITE,
		"score": T.VALUE_NONE,
		"use_aspiration": false,
		"root_average": 0,
	}


func _id_setup_window(snap: Dictionary) -> void:
	if enable_aspiration and not root_moves.is_empty():
		# Upstream iterative deepening: always set alpha/beta/optimism from
		# RootMove averageScore / meanSquaredScore (including -VALUE_INFINITE
		# / -VALUE_INFINITE^2 on depth 1). No depth>=4 gate; no avg fallback.
		var root_average: int = int(root_moves[0].average_score)
		var root_variance: int = int(root_moves[0].mean_squared_score)
		var delta: int = 10 + absi(root_variance) / 39605
		snap["root_average"] = root_average
		snap["delta"] = delta
		snap["alpha"] = maxi(root_average - delta, -T.VALUE_INFINITE)
		snap["beta"] = mini(root_average + delta, T.VALUE_INFINITE)
		snap["use_aspiration"] = true
		reductions.set_root_delta(int(snap["beta"]) - int(snap["alpha"]))
	else:
		snap["use_aspiration"] = false
		snap["delta"] = T.VALUE_INFINITE
		reductions.set_root_delta(T.VALUE_INFINITE)


func _id_aspiration_widen(snap: Dictionary) -> bool:
	var score: int = int(snap["score"])
	var alpha: int = int(snap["alpha"])
	var beta: int = int(snap["beta"])
	var delta: int = int(snap["delta"])
	if score <= alpha:
		snap["beta"] = alpha
		snap["alpha"] = maxi(score - delta, -T.VALUE_INFINITE)
		delta += 44 * delta / 128
		snap["delta"] = delta
		reductions.set_root_delta(maxi(int(snap["beta"]) - int(snap["alpha"]), 1))
		return true
	if score >= beta:
		snap["alpha"] = maxi(beta - delta, alpha)
		snap["beta"] = mini(score + delta, T.VALUE_INFINITE)
		delta += 44 * delta / 128
		snap["delta"] = delta
		reductions.set_root_delta(maxi(int(snap["beta"]) - int(snap["alpha"]), 1))
		return true
	return false


func _id_restore_if_stopped(snap: Dictionary) -> bool:
	if not _should_stop():
		return false
	# Discard mid-iteration root updates; keep last complete iteration.
	best_move = _stable_best if _stable_best != T.MOVE_NONE else int(snap["pre_best"])
	best_score = _stable_score if _stable_best != T.MOVE_NONE else int(snap["pre_score"])
	pv = _stable_pv if _stable_best != T.MOVE_NONE else snap["pre_pv"]
	return true


func _id_commit_depth(depth: int, score: int, st: Dictionary, node_limit: int) -> bool:
	if score != T.VALUE_NONE:
		st["avg_score"] = score
		best_score = score
		if best_move != int(st["previous_iteration_best"]):
			st["last_best_move_depth"] = depth
			st["previous_iteration_best"] = best_move
		st["total_best_move_changes"] = float(st["total_best_move_changes"]) + float(_root_best_move_changes)
		var iter_values: PackedInt32Array = st["iter_values"]
		var iter_index: int = int(st["iter_index"])
		var previous_iter_value: int = iter_values[iter_index]
		iter_values[iter_index] = score
		st["iter_values"] = iter_values
		st["iter_index"] = (iter_index + 1) & 3
		_commit_iteration(depth)
		_emit_iteration_info(depth)
		if time_manager != null and time_manager.use_time_management():
			time_manager.update_after_iteration({
				"best_previous_average": int(st["previous_search_average"]),
				"best_value": score,
				"iter_value": previous_iter_value,
				"depth": depth,
				"last_best_move_depth": int(st["last_best_move_depth"]),
				"best_move_changes": float(st["total_best_move_changes"]),
				"best_effort_nodes": int(root_moves[0].effort) if not root_moves.is_empty() else 0,
				"nodes": nodes,
				"threads": 1,
			})
	if node_limit > 0 and nodes >= node_limit:
		if _stop_reason.is_empty():
			_stop_reason = "nodes"
		return true
	# Soft stop after completing this iteration.
	if time_manager != null and time_manager.past_optimum() and depth >= 1:
		if _stop_reason.is_empty():
			_stop_reason = "movetime" if time_manager.movetime_ms > 0 else "time"
		return true
	return false


func _finish_search_result() -> Dictionary:
	_finalize_bestmove_or_fallback()
	if time_manager != null and _from_complete_iteration:
		time_manager.commit_search_score(best_score)
	return _result_dict()


func _maybe_yield(force: bool = false):
	if not yield_cb.is_valid():
		return
	var now: int = Time.get_ticks_msec()
	if not force and (now - _last_yield_msec) < yield_interval_ms:
		return
	_last_yield_msec = now
	await yield_cb.call()

func _set_root_optimism(average: int) -> void:
	if evaluator == null:
		return
	var root_color: int = pos.side_to_move if pos != null else 0
	var value: int = 92 * average / (absi(average) + 95)
	if root_color == T.COLOR_WHITE:
		evaluator.set_optimism(value, -value)
	else:
		evaluator.set_optimism(-value, value)


func _search_root(depth: int, alpha: int, beta: int) -> int:
	## RootMove counterpart of upstream search<Root>. Root moves are deliberately
	## not yielded by MovePicker: their PV, score history and stable ordering are
	## persistent state across iterative deepening.
	var ctx: Dictionary = _search_root_open(depth, alpha, beta)
	if bool(ctx.get("done", false)):
		return int(ctx["value"])
	for root_move in root_moves:
		var step: Dictionary = _search_root_step(root_move, ctx)
		if bool(step.get("return", false)):
			return int(step["value"])
	return _search_root_close(ctx)


func _search_root_async(depth: int, alpha: int, beta: int):
	var ctx: Dictionary = _search_root_open(depth, alpha, beta)
	if bool(ctx.get("done", false)):
		return int(ctx["value"])
	for root_move in root_moves:
		var step: Dictionary = _search_root_step(root_move, ctx)
		if bool(step.get("return", false)):
			return int(step["value"])
		if not bool(step.get("skipped", false)):
			await _maybe_yield(false)
			if _should_stop():
				return int(ctx["alpha"])
	return _search_root_close(ctx)


func _search_root_open(depth: int, alpha: int, beta: int) -> Dictionary:
	if _maybe_check_stop():
		return {"done": true, "value": alpha}
	if root_moves.is_empty():
		var v: int = T.mated_in(0) if (pos.checkers()[0] != 0 or pos.checkers()[1] != 0) else T.VALUE_DRAW
		return {"done": true, "value": v}
	return {
		"done": false,
		"depth": depth,
		"alpha": alpha,
		"beta": beta,
		"alpha0": alpha,
		"best_value": -T.VALUE_INFINITE,
		"move_count": 0,
	}


func _search_root_step(root_move, ctx: Dictionary) -> Dictionary:
	var move: int = root_move.move()
	if move == T.MOVE_NONE or not pos.legal(move):
		return {"skipped": true}
	var depth: int = int(ctx["depth"])
	var alpha: int = int(ctx["alpha"])
	var beta: int = int(ctx["beta"])
	var alpha0: int = int(ctx["alpha0"])
	ctx["move_count"] = int(ctx["move_count"]) + 1
	var move_count: int = int(ctx["move_count"])
	var before := nodes
	_do_move_synced(move)
	var value: int
	if move_count == 1:
		value = -_search(NODE_PV, depth - 1, -beta, -alpha, 1, false)
	else:
		value = -_search(NODE_NON_PV, depth - 1, -(alpha + 1), -alpha, 1, true)
		if value > alpha and value < beta:
			value = -_search(NODE_PV, depth - 1, -beta, -alpha, 1, false)
	var child_pv: PackedInt32Array = _pv_stack[1].duplicate()
	_undo_move_synced(move)
	var searched_nodes: int = maxi(0, nodes - before)
	root_move.effort += searched_nodes
	_root_effort_by_move[move] = int(_root_effort_by_move.get(move, 0)) + searched_nodes
	if _should_stop():
		return {"return": true, "value": alpha}
	if value > int(ctx["best_value"]):
		ctx["best_value"] = value
	if move_count == 1 or value > alpha:
		root_move.set_score(value, alpha0, beta, child_pv, seldepth, searched_nodes)
		if value > alpha:
			if best_move != T.MOVE_NONE and best_move != move:
				_root_best_move_changes += 1
			best_move = move
			pv = root_move.pv.duplicate()
			ctx["alpha"] = value
			if value >= beta:
				return {"return": true, "value": _search_root_close(ctx)}
	else:
		root_move.score = -T.VALUE_INFINITE
	return {}


func _search_root_close(ctx: Dictionary) -> int:
	var best_value: int = int(ctx["best_value"])
	return best_value if best_value != -T.VALUE_INFINITE else int(ctx["alpha"])


func request_stop() -> void:
	stop_flag = true
	if _stop_reason.is_empty():
		_stop_reason = "stop"


func _commit_iteration(depth: int) -> void:
	completed_depth = depth
	_stable_best = best_move
	_stable_score = best_score
	_stable_pv = pv.duplicate()
	_from_complete_iteration = _stable_best != T.MOVE_NONE


func _emit_iteration_info(depth: int) -> void:
	if not info_cb.is_valid():
		return
	var elapsed: int = time_manager.elapsed_ms() if time_manager != null else 0
	var nps: int = int(nodes * 1000 / elapsed) if elapsed > 0 else 0
	info_cb.call({
		"depth": depth,
		"seldepth": seldepth,
		"score": best_score,
		"nodes": nodes,
		"nps": nps,
		"time_ms": elapsed,
		"soft_time_ms": time_manager.soft_target() if time_manager != null else 0,
		"hard_time_ms": time_manager.maximum() if time_manager != null else 0,
		"pv": pv.duplicate(),
		"is_final": false,
	})


func _finalize_bestmove_or_fallback() -> void:
	if _stable_best != T.MOVE_NONE:
		best_move = _stable_best
		best_score = _stable_score
		pv = _stable_pv
		_from_complete_iteration = true
		_incomplete = false
		return
	# Depth 1 never completed: legal fallback (first legal move).
	_incomplete = true
	_from_complete_iteration = false
	if best_move != T.MOVE_NONE and pos != null and pos.legal(best_move):
		# Prefer any root move already probed, still mark incomplete.
		pv = PackedInt32Array([best_move])
		return
	best_move = _fallback_legal_move()
	best_score = T.VALUE_ZERO
	pv = PackedInt32Array([best_move]) if best_move != T.MOVE_NONE else PackedInt32Array()


func _fallback_legal_move() -> int:
	if pos == null:
		return T.MOVE_NONE
	var list := PackedInt32Array()
	list.resize(T.MAX_MOVES)
	var n: int = MG.generate(pos, MG.GEN_LEGAL, list)
	if n <= 0:
		return T.MOVE_NONE
	return list[0]


func _result_dict() -> Dictionary:
	var reason := _stop_reason
	if reason.is_empty():
		if time_manager != null and time_manager.node_limit > 0 and nodes >= time_manager.node_limit:
			reason = "nodes"
		elif time_manager != null and time_manager.maximum_ms > 0 \
				and time_manager.elapsed_ms() >= time_manager.maximum_ms:
			reason = "movetime" if time_manager.movetime_ms > 0 else "time"
		elif completed_depth >= requested_depth:
			reason = "depth"
		else:
			reason = "depth"
	return {
		"bestmove": best_move,
		"score": best_score,
		"nodes": nodes,
		"pv": pv,
		"depth": completed_depth,
		"completed_depth": completed_depth,
		"requested_depth": requested_depth,
		"seldepth": seldepth,
		"soft_time_ms": time_manager.soft_target() if time_manager != null else 0,
		"hard_time_ms": time_manager.maximum() if time_manager != null else 0,
		"from_complete_iteration": _from_complete_iteration,
		"incomplete": _incomplete,
		"stop_reason": reason,
	}


func _should_stop() -> bool:
	if stop_flag:
		return true
	if external_stop_cb.is_valid() and bool(external_stop_cb.call()):
		stop_flag = true
		if _stop_reason.is_empty():
			_stop_reason = "stop"
		return true
	if time_manager != null and time_manager.should_stop(nodes, stop_flag):
		stop_flag = true
		if _stop_reason.is_empty():
			if time_manager.node_limit > 0 and nodes >= time_manager.node_limit:
				_stop_reason = "nodes"
			elif time_manager.movetime_ms > 0:
				_stop_reason = "movetime"
			else:
				_stop_reason = "time"
		return true
	return false


func _maybe_check_stop() -> bool:
	if stop_flag:
		return true
	if external_stop_cb.is_valid() and bool(external_stop_cb.call()):
		stop_flag = true
		return true
	if (nodes & STOP_CHECK_MASK) == 0:
		return _should_stop()
	return false


func _tt_probe() -> Dictionary:
	if tt == null or pos == null:
		return {"found": false, "move": T.MOVE_NONE, "value": T.VALUE_NONE, "eval": T.VALUE_NONE,
			"depth": T.DEPTH_NONE, "bound": T.BOUND_NONE, "is_pv": false, "write_index": -1}
	return tt.probe(pos.key())


func _value_draw() -> int:
	## Upstream search.cpp value_draw(nodes): break 3-fold blindness with ±1 noise.
	return T.VALUE_DRAW - 1 + (nodes & 0x2)


func _search(
	node_type: int,
	depth: int,
	alpha: int,
	beta: int,
	ply: int,
	cut_node: bool,
	excluded_move: int = 0
) -> int:
	## Upstream: search.cpp template search<> — ProbCut + singular behind flags.
	## excluded_move: T.MOVE_NONE (0) unless singular-extension exclusion.
	var pv_node: bool = node_type != NODE_NON_PV
	var root_node: bool = node_type == NODE_ROOT
	if ply >= 0 and ply < _pv_stack.size():
		_pv_stack[ply] = PackedInt32Array()

	if ply > seldepth:
		seldepth = ply
	if _maybe_check_stop():
		return alpha

	# Upstream Step 2 (search.cpp ~720–738): rule_judge only off-root.
	# claimed → return (DRAW via value_draw); soft → clamp α/β, do not return mate.
	if not root_node:
		var rj: Dictionary = pos.rule_judge(ply)
		var rj_value: int = int(rj.get("value", T.VALUE_NONE))
		if rj.get("claimed", false):
			return _value_draw() if rj_value == T.VALUE_DRAW else rj_value
		elif rj_value != T.VALUE_NONE:
			if rj_value > T.VALUE_DRAW:
				alpha = maxi(alpha, T.VALUE_DRAW - 1)
			else:
				beta = mini(beta, T.VALUE_DRAW + 1)

	if depth <= 0:
		return _qsearch(pv_node, alpha, beta, ply)

	depth = mini(depth, T.MAX_PLY - 1)

	# Mate distance pruning (upstream Step 3).
	if not root_node:
		alpha = maxi(T.mated_in(ply), alpha)
		beta = mini(T.mate_in(ply + 1), beta)
		if alpha >= beta:
			return alpha

	var tt_hit: Dictionary = _tt_probe()
	var tt_move: int = int(tt_hit.get("move", T.MOVE_NONE)) if tt_hit.get("found", false) else T.MOVE_NONE
	var tt_value: int = T.VALUE_NONE
	var tt_depth: int = T.DEPTH_NONE
	var tt_bound: int = T.BOUND_NONE
	var tt_eval: int = T.VALUE_NONE
	var tt_pv: bool = pv_node
	var write_index: int = int(tt_hit.get("write_index", -1))
	if tt_hit.get("found", false):
		tt_value = tt.value_from_tt(int(tt_hit["value"]), ply, pos.rule60_count())
		tt_depth = int(tt_hit["depth"])
		tt_bound = int(tt_hit["bound"])
		tt_eval = int(tt_hit["eval"])
		tt_pv = pv_node or bool(tt_hit.get("is_pv", false))

	# NonPV TT cutoff (simplified; no next-position verification yet).
	if (
		not pv_node
		and excluded_move == T.MOVE_NONE
		and tt_hit.get("found", false)
		and tt_depth > depth - (1 if tt_value <= beta else 0)
		and T.is_valid_value(tt_value)
		and (tt_bound & (T.BOUND_LOWER if tt_value >= beta else T.BOUND_UPPER)) != 0
		and pos.rule60_count() < 116
	):
		return tt_value

	var in_check: bool = false
	var chk: Array = pos.checkers()
	in_check = chk[0] != 0 or chk[1] != 0
	ss_in_check[_ss(ply)] = 1 if in_check else 0

	var eval: int = T.VALUE_NONE
	var improving := false
	if in_check:
		eval = T.VALUE_NONE
	elif tt_hit.get("found", false) and tt_eval != T.VALUE_NONE:
		eval = tt_eval
		if T.is_valid_value(tt_value) and (
			(tt_bound & T.BOUND_LOWER) != 0 and tt_value > eval
			or (tt_bound & T.BOUND_UPPER) != 0 and tt_value < eval
		):
			eval = tt_value
	else:
		eval = _eval()
		if tt != null and write_index >= 0:
			tt.write(
				write_index, pos.key(), T.VALUE_NONE, tt_pv, T.BOUND_NONE,
				T.DEPTH_UNSEARCHED, T.MOVE_NONE, eval
			)

	# Razoring (flagged).
	if enable_razoring and not pv_node and not in_check and eval < alpha - 1370 - 244 * depth * depth:
		return _qsearch(false, alpha, beta, ply)

	# Futility pruning: child node (flagged, simplified margin).
	if (
		enable_futility
		and not tt_pv
		and not in_check
		and depth < 15
		and eval >= beta
		and not T.is_loss(beta)
		and not T.is_win(eval)
	):
		var futility_mult: int = mini(40 + depth * 4, 129)
		var futility_margin: int = futility_mult * depth
		if eval - futility_margin >= beta:
			return (716 * beta + 308 * eval) / 1024

	# Null-move pruning (flagged).
	if (
		enable_null_move
		and cut_node
		and not in_check
		and excluded_move == T.MOVE_NONE
		and eval != T.VALUE_NONE
		and eval >= beta - 8 * depth + 187
		and pos.major_material(pos.side_to_move) > 0
		and ply >= 1
		and beta >= -2000
	):
		var R: int = 8 + depth / 3 + maxi((eval - beta) / 256, 0)
		_do_null_synced()
		ss_current_move[_ss(ply)] = T.MOVE_NULL
		ss_cont_base[_ss(ply)] = history.sentinel_cont_base()
		var null_value: int = -_search(
			NODE_NON_PV, depth - R, -beta, -beta + 1, ply + 1, false, T.MOVE_NONE
		)
		_undo_null_synced()
		ss_current_move[_ss(ply)] = T.MOVE_NONE
		if null_value >= beta and not T.is_win(null_value):
			return null_value

	# Without staticEval stack: improving ≈ eval >= beta (upstream uses prior ply).
	improving = (not in_check and eval != T.VALUE_NONE and eval >= beta)

	# Step 10. ProbCut (flagged) — Upstream: search.cpp ProbCut.
	if (
		enable_probcut
		and not in_check
		and depth >= 3
		and not T.is_decisive(beta)
		and not (T.is_valid_value(tt_value) and tt_value < beta + 251 - 66 * (1 if improving else 0))
	):
		var prob_cut_beta: int = beta + 251 - 66 * (1 if improving else 0)
		var pc_picker = MP.new()
		var pc_thr: int = prob_cut_beta - eval if eval != T.VALUE_NONE else prob_cut_beta
		pc_picker.init_probcut(pos, tt_move, pc_thr, history)
		var prob_cut_depth: int = depth - (5 if improving else 3)
		while true:
			var pcm: int = pc_picker.next_move()
			if pcm == T.MOVE_NONE:
				break
			if pcm == excluded_move or not pos.legal(pcm):
				continue
			if not pos.capture(pcm):
				continue
			_do_move_synced(pcm)
			var pc_value: int = -_qsearch(false, -prob_cut_beta, -prob_cut_beta + 1, ply + 1)
			if pc_value >= prob_cut_beta and prob_cut_depth > 0:
				pc_value = -_search(
					NODE_NON_PV, prob_cut_depth, -prob_cut_beta, -prob_cut_beta + 1,
					ply + 1, not cut_node, T.MOVE_NONE
				)
			_undo_move_synced(pcm)
			if pc_value >= prob_cut_beta:
				if tt != null and write_index >= 0 and excluded_move == T.MOVE_NONE:
					tt.write(
						write_index, pos.key(), tt.value_to_tt(pc_value, ply), tt_pv,
						T.BOUND_LOWER, prob_cut_depth + 1, pcm,
						eval if eval != T.VALUE_NONE else T.VALUE_NONE
					)
				if not T.is_decisive(pc_value):
					return pc_value - (prob_cut_beta - beta)

	# Step 11. Small ProbCut idea (flagged).
	if enable_probcut and not T.is_decisive(beta) and T.is_valid_value(tt_value):
		var small_pc_beta: int = beta + 470
		if (
			(tt_bound & T.BOUND_LOWER) != 0
			and tt_depth >= depth - 4
			and tt_value >= small_pc_beta
			and not T.is_decisive(tt_value)
		):
			return small_pc_beta

	var picker = MP.new()
	picker.init_main(pos, tt_move, depth, history, ply, _cont_hist_for_picker(ply))

	var best_value: int = -T.VALUE_INFINITE
	var local_best := T.MOVE_NONE
	var move_count := 0
	var quiets_searched := PackedInt32Array()
	var captures_searched := PackedInt32Array()
	var alpha0: int = alpha

	while true:
		var m: int = picker.next_move()
		if m == T.MOVE_NONE:
			break
		if m == excluded_move:
			continue
		if not pos.legal(m):
			continue
		move_count += 1
		var is_cap: bool = pos.capture(m)
		var root_nodes_before: int = nodes if root_node else 0
		var moved_pc: int = pos.moved_piece(m)
		var captured_pt: int = T.type_of(pos.piece_on(T.to_sq(m))) if is_cap else T.NO_PIECE_TYPE
		var new_depth: int = depth - 1
		var extension: int = 0
		var value: int

		# Step 14. Singular extension (flagged) — Upstream: search.cpp singular.
		if (
			enable_singular
			and not root_node
			and m == tt_move
			and excluded_move == T.MOVE_NONE
			and depth >= 5 + (1 if tt_pv else 0)
			and T.is_valid_value(tt_value)
			and not T.is_decisive(tt_value)
			and (tt_bound & T.BOUND_LOWER) != 0
			and tt_depth >= depth - 3
		):
			var singular_beta: int = (
				tt_value - (44 + 72 * (1 if tt_pv and not pv_node else 0)) * depth / 69
			)
			var singular_depth: int = int(new_depth / 2)
			var se_value: int = _search(
				NODE_NON_PV, singular_depth, singular_beta - 1, singular_beta,
				ply, cut_node, m
			)
			if se_value < singular_beta:
				extension = 1
				depth += 1
			elif se_value >= beta and not T.is_decisive(se_value):
				return se_value
			elif tt_value >= beta or cut_node:
				extension = -3

		new_depth += extension
		# Upstream Worker::do_move — set continuationHistory before recurse.
		ss_current_move[_ss(ply)] = m
		ss_cont_base[_ss(ply)] = history.cont_base(in_check, 1 if is_cap else 0, moved_pc, T.to_sq(m))
		_do_move_synced(m)

		# PVS: first move full window; later moves null-window (+ LMR when flagged).
		if pv_node and move_count == 1:
			value = -_search(NODE_PV, new_depth, -beta, -alpha, ply + 1, false, T.MOVE_NONE)
		else:
			var d: int = new_depth
			var did_lmr := false
			if (
				enable_lmr
				and depth >= 2
				and move_count > 1 + (1 if root_node else 0)
				and not is_cap
			):
				var r: int = reductions.reduction(improving, depth, move_count, beta - alpha0)
				r += 855
				d = maxi(1, mini(new_depth - r / 1024, new_depth + 2))
				did_lmr = d < new_depth
			value = -_search(NODE_NON_PV, d, -(alpha + 1), -alpha, ply + 1, true, T.MOVE_NONE)
			if did_lmr and value > alpha:
				value = -_search(
					NODE_NON_PV, new_depth, -(alpha + 1), -alpha, ply + 1, not cut_node, T.MOVE_NONE
				)
			if pv_node and value > alpha:
				value = -_search(NODE_PV, new_depth, -beta, -alpha, ply + 1, false, T.MOVE_NONE)

		_undo_move_synced(m)
		var child_pv: PackedInt32Array = _pv_stack[ply + 1].duplicate() if ply + 1 < _pv_stack.size() else PackedInt32Array()
		ss_current_move[_ss(ply)] = T.MOVE_NONE
		if root_node:
			_root_effort_by_move[m] = int(_root_effort_by_move.get(m, 0)) + maxi(0, nodes - root_nodes_before)

		if _should_stop():
			return alpha

		if value > best_value:
			best_value = value
			local_best = m
			if value > alpha:
				alpha = value
				if pv_node and ply < _pv_stack.size():
					var line := PackedInt32Array([m])
					for child_move in child_pv:
						line.append(child_move)
					_pv_stack[ply] = line
				if root_node or ply == 0:
					if root_node and best_move != T.MOVE_NONE and best_move != m:
						_root_best_move_changes += 1
					best_move = m
					pv = PackedInt32Array([m])
				if alpha >= beta:
					_update_histories_on_cutoff(
						m, is_cap, moved_pc, captured_pt, depth, ply,
						quiets_searched, captures_searched
					)
					break
		if is_cap:
			captures_searched.append(m)
		else:
			quiets_searched.append(m)

	if move_count == 0:
		# Upstream: if excludedMove, return alpha (fail-low softbound for singular).
		if excluded_move != T.MOVE_NONE:
			return alpha
		if in_check:
			return T.mated_in(ply)
		return T.VALUE_DRAW

	if root_node and local_best != T.MOVE_NONE and best_move == T.MOVE_NONE:
		best_move = local_best

	# TT write
	if tt != null and write_index >= 0 and excluded_move == T.MOVE_NONE:
		var bound: int
		if best_value >= beta:
			bound = T.BOUND_LOWER
		elif pv_node and local_best != T.MOVE_NONE:
			bound = T.BOUND_EXACT
		else:
			bound = T.BOUND_UPPER
		tt.write(
			write_index,
			pos.key(),
			tt.value_to_tt(best_value, ply),
			tt_pv,
			bound,
			depth,
			local_best,
			eval if eval != T.VALUE_NONE else T.VALUE_NONE
		)

	return best_value


func _update_histories_on_cutoff(
	best: int,
	is_cap: bool,
	moved_pc: int,
	captured_pt: int,
	depth: int,
	ply: int,
	quiets_searched: PackedInt32Array,
	captures_searched: PackedInt32Array
) -> void:
	## Upstream: update_all_stats + update_quiet_histories (continuation + pawn).
	if history == null:
		return
	var us: int = pos.side_to_move
	var bonus: int = mini(162 * depth - 87, 1602)
	var malus: int = mini(870 * depth - 148, 2000)
	var pk: int = pos.pawn_key()
	if not is_cap:
		history.update_quiet(
			us, best, moved_pc, T.to_sq(best), ply, int(bonus * 899 / 1024),
			pk, ss_cont_base, ss_current_move, ss_in_check, SS_OFFSET
		)
		var actual_malus: int = int(malus * 1100 / 1024)
		for i in range(quiets_searched.size()):
			actual_malus = int(actual_malus * 950 / 1024)
			var qm: int = quiets_searched[i]
			history.update_quiet(
				us, qm, pos.moved_piece(qm), T.to_sq(qm), ply, -actual_malus,
				pk, ss_cont_base, ss_current_move, ss_in_check, SS_OFFSET
			)
	else:
		history.update_capture(moved_pc, T.to_sq(best), captured_pt, int(bonus * 1455 / 1024))
	for i in range(captures_searched.size()):
		var cm: int = captures_searched[i]
		var cpc: int = pos.moved_piece(cm)
		var cpt: int = T.type_of(pos.piece_on(T.to_sq(cm)))
		history.update_capture(cpc, T.to_sq(cm), cpt, -int(malus * 1440 / 1024))


func _qsearch(pv_node: bool, alpha: int, beta: int, ply: int) -> int:
	if ply >= 0 and ply < _pv_stack.size():
		_pv_stack[ply] = PackedInt32Array()
	if ply > seldepth:
		seldepth = ply
	if ply > 32:
		return _eval()
	if _maybe_check_stop():
		return alpha

	# Upstream qsearch Step 2 (search.cpp ~1567–1586): claimed return; soft clamp + cutoff.
	var rj: Dictionary = pos.rule_judge(ply)
	var rj_value: int = int(rj.get("value", T.VALUE_NONE))
	if rj.get("claimed", false):
		return rj_value
	elif rj_value != T.VALUE_NONE:
		if rj_value > T.VALUE_DRAW:
			alpha = maxi(alpha, T.VALUE_DRAW)
		else:
			beta = mini(beta, T.VALUE_DRAW)
		if alpha >= beta:
			return alpha

	# Upstream qsearch Step 3–4 (search.cpp): TT cutoff, TT eval/value stand-pat, softbound.
	var tt_hit: Dictionary = _tt_probe()
	var tt_move := T.MOVE_NONE
	var tt_value: int = T.VALUE_NONE
	var tt_eval: int = T.VALUE_NONE
	var tt_depth: int = T.DEPTH_NONE
	var tt_bound: int = T.BOUND_NONE
	var write_index: int = int(tt_hit.get("write_index", -1))
	var found: bool = bool(tt_hit.get("found", false))
	if found:
		tt_move = int(tt_hit.get("move", T.MOVE_NONE))
		tt_value = tt.value_from_tt(int(tt_hit["value"]), ply, pos.rule60_count())
		tt_eval = int(tt_hit["eval"])
		tt_depth = int(tt_hit["depth"])
		tt_bound = int(tt_hit["bound"])
		if (
			not pv_node
			and tt_depth >= T.DEPTH_QS
			and T.is_valid_value(tt_value)
			and (tt_bound & (T.BOUND_LOWER if tt_value >= beta else T.BOUND_UPPER)) != 0
		):
			return tt_value

	var chk: Array = pos.checkers()
	var in_check: bool = chk[0] != 0 or chk[1] != 0
	var unadjusted_static_eval: int = T.VALUE_NONE
	var best_value: int
	# GDS-DIVERGENCE: SEMANTIC — correction history skipped in qsearch (S2 secondary gap).
	if in_check:
		best_value = -T.VALUE_INFINITE
	else:
		if found:
			unadjusted_static_eval = tt_eval
			if not T.is_valid_value(unadjusted_static_eval):
				unadjusted_static_eval = _eval()
			best_value = unadjusted_static_eval
			# ttValue can be used as a better position evaluation
			if (
				T.is_valid_value(tt_value)
				and not T.is_decisive(tt_value)
				and (tt_bound & (T.BOUND_LOWER if tt_value > best_value else T.BOUND_UPPER)) != 0
			):
				best_value = tt_value
		else:
			unadjusted_static_eval = _eval()
			best_value = unadjusted_static_eval

		# Stand pat. Softbound then optional TT save when !ttHit.
		if best_value >= beta:
			if not T.is_decisive(best_value):
				best_value = (467 * best_value + 557 * beta) / 1024
			if not found and tt != null and write_index >= 0:
				tt.write(
					write_index, pos.key(), T.VALUE_NONE, false,
					T.BOUND_LOWER, T.DEPTH_UNSEARCHED, T.MOVE_NONE, unadjusted_static_eval
				)
			return best_value

		if best_value > alpha:
			alpha = best_value

	var picker = MP.new()
	picker.init_main(pos, tt_move, 0, history, ply, _cont_hist_for_picker(ply))
	var local_best := T.MOVE_NONE
	while true:
		var m: int = picker.next_move()
		if m == T.MOVE_NONE:
			break
		if not pos.legal(m):
			continue
		# Quiescence: prefer captures; still allow checks via picker stages.
		_do_move_synced(m)
		var score: int = -_qsearch(pv_node, -beta, -alpha, ply + 1)
		_undo_move_synced(m)
		var child_pv: PackedInt32Array = _pv_stack[ply + 1].duplicate() if ply + 1 < _pv_stack.size() else PackedInt32Array()
		if score > best_value:
			best_value = score
			local_best = m
		if score >= beta:
			if tt != null and write_index >= 0:
				tt.write(
					write_index, pos.key(), tt.value_to_tt(score, ply), pv_node,
					T.BOUND_LOWER, T.DEPTH_QS, m, unadjusted_static_eval
				)
			return score
		if score > alpha:
			alpha = score
			if pv_node and ply < _pv_stack.size():
				var line := PackedInt32Array([m])
				for child_move in child_pv:
					line.append(child_move)
				_pv_stack[ply] = line

	if tt != null and write_index >= 0:
		var bound: int = T.BOUND_EXACT if pv_node and local_best != T.MOVE_NONE else T.BOUND_UPPER
		tt.write(
			write_index, pos.key(), tt.value_to_tt(best_value, ply), pv_node,
			bound, T.DEPTH_QS, local_best, unadjusted_static_eval
		)
	return best_value


func _eval() -> int:
	return evaluator.evaluate(pos)
