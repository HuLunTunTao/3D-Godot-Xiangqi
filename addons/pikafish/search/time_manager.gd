class_name PikafishTimeManager
extends RefCounted

## Upstream: Pikafish 2c5c998c, src/timeman.* — movetime + clock/inc/movestogo optimum–maximum.

const LimitsScript = preload("res://addons/pikafish/search/limits.gd")

var start_msec: int = 0
var depth_limit: int = 0
var node_limit: int = 0
var movetime_ms: int = 0
var infinite: bool = false
var ponder: bool = false
## Soft/hard time bounds (ms from start). 0 = unused.
var optimum_ms: int = 0
var maximum_ms: int = 0
## Move overhead (ms) — Upstream option "Move Overhead", default 10.
var move_overhead_ms: int = 10
## Persists across searches for basetime optScale adjust (Upstream originalTimeAdjust).
var original_time_adjust: float = -1.0
## Dynamic soft target after a completed ID iteration. Hard maximum remains fixed.
var soft_target_ms: int = 0
var previous_time_reduction: float = 1.0
var _state = null  ## PikafishSearchTimeState, optional for direct test users.


func attach_state(state) -> void:
	_state = state
	if _state != null:
		original_time_adjust = _state.original_time_adjust
		previous_time_reduction = _state.previous_time_reduction


func init_from_limits(limits, side_to_move: int = 0, ply: int = 0) -> void:
	start_msec = Time.get_ticks_msec()
	depth_limit = 0
	node_limit = 0
	movetime_ms = 0
	infinite = false
	ponder = false
	optimum_ms = 0
	maximum_ms = 0
	soft_target_ms = 0
	if limits == null:
		return
	var time_ms := PackedInt32Array([0, 0])
	var inc_ms := PackedInt32Array([0, 0])
	var movestogo: int = 0
	if typeof(limits) == TYPE_DICTIONARY:
		depth_limit = int(limits.get("depth", 0))
		node_limit = int(limits.get("nodes", 0))
		movetime_ms = int(limits.get("movetime_ms", limits.get("movetime", 0)))
		infinite = bool(limits.get("infinite", false))
		ponder = bool(limits.get("ponder", false))
		movestogo = int(limits.get("movestogo", 0))
		if limits.has("time_ms"):
			var t = limits["time_ms"]
			if typeof(t) == TYPE_PACKED_INT32_ARRAY or typeof(t) == TYPE_ARRAY:
				time_ms[0] = int(t[0]) if t.size() > 0 else 0
				time_ms[1] = int(t[1]) if t.size() > 1 else 0
		else:
			time_ms[0] = int(limits.get("wtime", 0))
			time_ms[1] = int(limits.get("btime", 0))
		if limits.has("inc_ms"):
			var inc = limits["inc_ms"]
			if typeof(inc) == TYPE_PACKED_INT32_ARRAY or typeof(inc) == TYPE_ARRAY:
				inc_ms[0] = int(inc[0]) if inc.size() > 0 else 0
				inc_ms[1] = int(inc[1]) if inc.size() > 1 else 0
		else:
			inc_ms[0] = int(limits.get("winc", 0))
			inc_ms[1] = int(limits.get("binc", 0))
		move_overhead_ms = int(limits.get("move_overhead_ms", move_overhead_ms))
	else:
		depth_limit = limits.depth
		node_limit = limits.nodes
		movetime_ms = limits.movetime_ms
		infinite = limits.infinite
		ponder = limits.ponder
		movestogo = limits.movestogo
		time_ms = limits.time_ms
		inc_ms = limits.inc_ms

	# Upstream: movetime is a hard wall-clock cap (SearchManager::check_time).
	# Soft == hard so ID stops starting new iterations once the budget is reached;
	# hard stop still aborts mid-iteration via should_stop().
	if movetime_ms > 0:
		optimum_ms = movetime_ms
		maximum_ms = movetime_ms
		soft_target_ms = optimum_ms
		return

	var us: int = clampi(side_to_move, 0, 1)
	var our_time: int = int(time_ms[us]) if time_ms.size() > us else 0
	if our_time <= 0:
		return

	# Upstream TimeManagement::init — clock / inc / movestogo.
	var our_inc: int = int(inc_ms[us]) if inc_ms.size() > us else 0
	var overhead: int = move_overhead_ms
	var mtg: int = mini(movestogo, 50) if movestogo > 0 else 50
	if our_time < 1000:
		mtg = int(our_time * 0.05)
		mtg = maxi(mtg, 1)

	var time_left: int = maxi(
		1, our_time + our_inc * (mtg - 1) - overhead * (2 + mtg)
	)

	var opt_scale: float
	var max_scale: float
	if movestogo == 0:
		# x basetime (+ z increment)
		if original_time_adjust < 0.0:
			original_time_adjust = 0.3356 * log(float(time_left)) / log(10.0) - 0.4903
		var log_time_in_sec: float = log(maxi(our_time, 1) / 1000.0) / log(10.0)
		var opt_constant: float = minf(0.0034013 + 0.00020657 * log_time_in_sec, 0.004536)
		var max_constant: float = maxf(3.7803 + 2.8003 * log_time_in_sec, 2.5470)
		opt_scale = (
			minf(
				0.017244 + pow(float(ply) + 2.71111, 0.43433) * opt_constant,
				0.20577 * float(our_time) / float(time_left)
			)
			* original_time_adjust
		)
		max_scale = minf(7.002, max_constant + float(ply) / 13.184)
	else:
		# x moves in y seconds (+ z increment)
		opt_scale = minf(
			(0.88 + float(ply) / 116.4) / float(mtg),
			0.88 * float(our_time) / float(time_left)
		)
		max_scale = 1.3 + 0.11 * float(mtg)

	optimum_ms = maxi(1, int(opt_scale * float(time_left)))
	var max_from_clock: int = int(0.8237 * float(our_time) - float(overhead))
	maximum_ms = maxi(
		optimum_ms,
		mini(max_from_clock, int(max_scale * float(optimum_ms)))
	)
	# Upstream: options["Ponder"] adds 25% to optimum. We honour limits.ponder.
	if ponder:
		optimum_ms += optimum_ms / 4
	soft_target_ms = optimum_ms
	if _state != null:
		_state.original_time_adjust = original_time_adjust


func use_time_management() -> bool:
	## Clock mode (wtime/btime) — not pure movetime/depth/nodes.
	return maximum_ms > 0 and movetime_ms <= 0


func elapsed_ms() -> int:
	# GDS-DIVERGENCE: PLATFORM (D009)
	# C++ behavior: Steady-clock TimePoint via now() - startTime.
	# GDScript replacement: Time.get_ticks_msec() monotonic ms since engine start.
	# Proof: test_addon_search_time.gd + bench_search_time.gd
	return Time.get_ticks_msec() - start_msec


func optimum() -> int:
	return optimum_ms


func maximum() -> int:
	return maximum_ms


func soft_target() -> int:
	return soft_target_ms


func update_after_iteration(stats: Dictionary) -> int:
	## Upstream Search::Worker::iterative_deepening time multiplier. `stats` is
	## deliberately scalar so SearchWorker remains independent from UI/Engine.
	if not use_time_management() or ponder:
		return soft_target_ms
	var best_previous_average: float = float(stats.get("best_previous_average", 0))
	var best_value: float = float(stats.get("best_value", 0))
	var iter_value: float = float(stats.get("iter_value", best_value))
	var falling_eval := (16.93 + 2.73 * (best_previous_average - best_value)
		+ 0.8 * (iter_value - best_value)) / 100.0
	falling_eval = clampf(falling_eval, 0.610, 1.860)

	var root_depth: float = float(stats.get("depth", 1))
	var last_best_depth: float = float(stats.get("last_best_move_depth", 0))
	# Exact linear interpolation used by current upstream around [8, 17].
	var t := clampf((root_depth - last_best_depth - 8.0) / 9.0, 0.0, 1.0)
	var time_reduction := clampf(0.670 + (1.440 - 0.670) * t, 0.670, 1.440)
	var reduction := (2.100 + previous_time_reduction) / (2.480 * time_reduction)

	var threads: float = maxf(1.0, float(stats.get("threads", 1)))
	var changes: float = float(stats.get("best_move_changes", 0.0))
	var instability := 0.960 + 1.630 * changes / threads
	var total_nodes: float = maxf(1.0, float(stats.get("nodes", 1)))
	var effort: float = float(stats.get("best_effort_nodes", 0)) * 100000.0 / total_nodes
	var e := clampf((effort - 78000.0) / 16000.0, 0.0, 1.0)
	var high_effort := 0.960 + (0.740 - 0.960) * e

	soft_target_ms = clampi(
		int(float(optimum_ms) * falling_eval * reduction * instability * high_effort),
		1, maximum_ms
	)
	previous_time_reduction = time_reduction
	if _state != null:
		_state.previous_time_reduction = previous_time_reduction
	return soft_target_ms


func commit_search_score(score: int) -> void:
	if _state == null:
		return
	_state.best_previous_score = score
	# RootMove's true EMA is not available in the compact GDS root picker yet;
	# the completed root score is the conservative equivalent until it is ported.
	_state.best_previous_average_score = score
	_state.has_previous_score = true


## True when search must stop for time / nodes (depth checked by iterative loop).
func should_stop(nodes: int, stop_flag: bool) -> bool:
	if stop_flag:
		return true
	if infinite:
		return false
	# Ponder: soft/hard time does not abort until ponderhit/stop (upstream check_time).
	if ponder:
		if node_limit > 0 and nodes >= node_limit:
			return true
		return false
	if node_limit > 0 and nodes >= node_limit:
		return true
	if maximum_ms > 0 and elapsed_ms() >= maximum_ms:
		return true
	return false


## Soft check: past optimum time (caller finishes current iteration, then stops ID).
func past_optimum() -> bool:
	if ponder:
		return false
	return soft_target_ms > 0 and elapsed_ms() >= soft_target_ms
