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
	var iter_index := 0
	var previous_iteration_best: int = T.MOVE_NONE
	var last_best_move_depth := 0
	var total_best_move_changes := 0.0
	var previous_search_average := T.VALUE_ZERO
	if time_manager != null and time_manager._state != null and time_manager._state.has_previous_score:
		avg_score = time_manager._state.best_previous_score
		previous_search_average = time_manager._state.best_previous_average_score
		iter_values.fill(avg_score)
	_root_effort_by_move.clear()
	for depth in range(1, depth_limit + 1):
		# Soft stop: do not begin a deeper iteration past optimum.
		if time_manager != null and time_manager.past_optimum() and completed_depth >= 1:
			if _stop_reason.is_empty():
				_stop_reason = "movetime" if time_manager.movetime_ms > 0 else "time"
			break
		if _should_stop():
			break
		total_best_move_changes *= 0.5
		_root_best_move_changes = 0
		for root_move in root_moves:
			root_move.begin_iteration(true)
		# Snapshot working root best before this iteration; restore if aborted mid-ID.
		var pre_best: int = best_move
		var pre_score: int = best_score
		var pre_pv: PackedInt32Array = pv.duplicate()
		var alpha: int = -T.VALUE_INFINITE
		var beta: int = T.VALUE_INFINITE
		var delta: int = T.VALUE_INFINITE
		var score: int = T.VALUE_NONE

		if enable_aspiration and depth >= 4 and not root_moves.is_empty():
			var root_average: int = int(root_moves[0].average_score)
			if root_average == -T.VALUE_INFINITE:
				root_average = avg_score
			var root_variance: int = int(root_moves[0].mean_squared_score)
			if root_variance < 0:
				root_variance = 0
			delta = 10 + absi(root_variance) / 39605
			alpha = maxi(root_average - delta, -T.VALUE_INFINITE)
			beta = mini(root_average + delta, T.VALUE_INFINITE)
			reductions.set_root_delta(beta - alpha)
			while true:
				if _should_stop():
					break
				_set_root_optimism(root_average)
				score = _search_root(depth, alpha, beta)
				_stable_sort_root_moves()
				if _should_stop():
					break
				if score <= alpha:
					beta = alpha
					alpha = maxi(score - delta, -T.VALUE_INFINITE)
					delta += 44 * delta / 128
					reductions.set_root_delta(maxi(beta - alpha, 1))
				elif score >= beta:
					alpha = maxi(beta - delta, alpha)
					beta = mini(score + delta, T.VALUE_INFINITE)
					delta += 44 * delta / 128
					reductions.set_root_delta(maxi(beta - alpha, 1))
				else:
					break
		else:
			reductions.set_root_delta(T.VALUE_INFINITE)
			_set_root_optimism(avg_score)
			score = _search_root(depth, alpha, beta)
			_stable_sort_root_moves()

		if _should_stop():
			# Discard mid-iteration root updates; keep last complete iteration.
			best_move = _stable_best if _stable_best != T.MOVE_NONE else pre_best
			best_score = _stable_score if _stable_best != T.MOVE_NONE else pre_score
			pv = _stable_pv if _stable_best != T.MOVE_NONE else pre_pv
			break

		if score != T.VALUE_NONE:
			best_score = score
			avg_score = score
			if best_move != previous_iteration_best:
				last_best_move_depth = depth
				previous_iteration_best = best_move
			total_best_move_changes += float(_root_best_move_changes)
			var previous_iter_value: int = iter_values[iter_index]
			iter_values[iter_index] = score
			iter_index = (iter_index + 1) & 3
			_commit_iteration(depth)
			_emit_iteration_info(depth)
			if time_manager != null and time_manager.use_time_management():
				time_manager.update_after_iteration({
					"best_previous_average": previous_search_average,
					"best_value": score,
					"iter_value": previous_iter_value,
					"depth": depth,
					"last_best_move_depth": last_best_move_depth,
					"best_move_changes": total_best_move_changes,
					"best_effort_nodes": int(root_moves[0].effort) if not root_moves.is_empty() else 0,
					"nodes": nodes,
					"threads": 1,
				})

		if node_limit > 0 and nodes >= node_limit:
			if _stop_reason.is_empty():
				_stop_reason = "nodes"
			break
		# Soft stop after completing this iteration.
		if time_manager != null and time_manager.past_optimum() and depth >= 1:
			if _stop_reason.is_empty():
				_stop_reason = "movetime" if time_manager.movetime_ms > 0 else "time"
			break

	_finalize_bestmove_or_fallback()
	if time_manager != null and _from_complete_iteration:
		time_manager.commit_search_score(best_score)
	return _result_dict()


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
	nodes += 1
	if _maybe_check_stop():
		return alpha
	if root_moves.is_empty():
		return T.mated_in(0) if (pos.checkers()[0] != 0 or pos.checkers()[1] != 0) else T.VALUE_DRAW
	var alpha0 := alpha
	var best_value := -T.VALUE_INFINITE
	var move_count := 0
	for root_move in root_moves:
		var move: int = root_move.move()
		if move == T.MOVE_NONE or not pos.legal(move):
			continue
		move_count += 1
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
			return alpha
		if value > best_value:
			best_value = value
		if move_count == 1 or value > alpha:
			root_move.set_score(value, alpha0, beta, child_pv, seldepth, searched_nodes)
			if value > alpha:
				if best_move != T.MOVE_NONE and best_move != move:
					_root_best_move_changes += 1
				best_move = move
				pv = root_move.pv.duplicate()
				alpha = value
				if alpha >= beta:
					break
		else:
			root_move.score = -T.VALUE_INFINITE
	return best_value if best_value != -T.VALUE_INFINITE else alpha


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

	nodes += 1
	if ply > seldepth:
		seldepth = ply
	if _maybe_check_stop():
		return alpha

	var rj: Dictionary = pos.rule_judge(ply)
	if rj.get("claimed", false):
		return int(rj["value"])

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
	nodes += 1
	if ply > seldepth:
		seldepth = ply
	if ply > 32:
		return _eval()
	if _maybe_check_stop():
		return alpha

	var rj: Dictionary = pos.rule_judge(ply)
	if rj.get("claimed", false):
		return int(rj["value"])

	var tt_hit: Dictionary = _tt_probe()
	var tt_move := T.MOVE_NONE
	var write_index: int = int(tt_hit.get("write_index", -1))
	if tt_hit.get("found", false):
		tt_move = int(tt_hit.get("move", T.MOVE_NONE))
		var tt_value: int = tt.value_from_tt(int(tt_hit["value"]), ply, pos.rule60_count())
		var tt_bound: int = int(tt_hit["bound"])
		if (
			not pv_node
			and T.is_valid_value(tt_value)
			and (tt_bound & (T.BOUND_LOWER if tt_value >= beta else T.BOUND_UPPER)) != 0
		):
			return tt_value

	var stand: int = _eval()
	var best_value: int = stand
	if stand >= beta:
		if tt != null and write_index >= 0 and not tt_hit.get("found", false):
			tt.write(
				write_index, pos.key(), tt.value_to_tt(stand, ply), false,
				T.BOUND_LOWER, T.DEPTH_QS, T.MOVE_NONE, stand
			)
		return stand
	if stand > alpha:
		alpha = stand

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
					T.BOUND_LOWER, T.DEPTH_QS, m, stand
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
			bound, T.DEPTH_QS, local_best, stand
		)
	return best_value


func _eval() -> int:
	return evaluator.evaluate(pos)
