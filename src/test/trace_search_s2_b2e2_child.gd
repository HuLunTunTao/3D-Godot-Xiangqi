extends SceneTree

## SearchParity S2: after d1 carry, trace first root move b2e2 child @ depth=1.
## Observation-only. Writes /tmp/godot_s2_b2e2_child.jsonl
## Usage: Godot --headless --path . -s res://src/test/trace_search_s2_b2e2_child.gd

const Eng = preload("res://addons/pikafish/pikafish.gd")
const Config = preload("res://addons/pikafish/config.gd")
const Worker = preload("res://addons/pikafish/search/search_worker.gd")
const NnueEval = preload("res://addons/pikafish/search/nnue_evaluator.gd")
const HistoryScript = preload("res://addons/pikafish/search/history.gd")
const TTScript = preload("res://addons/pikafish/search/tt.gd")
const MP = preload("res://addons/pikafish/search/move_picker.gd")
const UciScore = preload("res://addons/pikafish/core/uci_score.gd")
const T = preload("res://addons/pikafish/core/types.gd")

const FEN := "rnbakabnr/9/1c5c1/p1p1p1p1p/9/9/P1P1P1P1P/1C5C1/9/RNBAKABNR w - - 0 1"
const OUT_PATH := "/tmp/godot_s2_b2e2_child.jsonl"
const HASH_MB := 16


func _init() -> void:
	var out := FileAccess.open(OUT_PATH, FileAccess.WRITE)
	if out == null:
		printerr("S2_FAIL write")
		quit(1)
		return

	var cfg = Config.new()
	cfg.prefer_gpu = false
	cfg.evaluation_mode = Config.EVALUATION_NNUE
	cfg.hash_mb = HASH_MB
	var engine = Eng.new()
	assert(engine.initialize(cfg) == OK)
	assert(engine.set_fen(FEN) == OK)

	var w = Worker.new()
	w.pos = engine._pos
	w.tt = TTScript.new()
	w.tt.resize_mb(HASH_MB)
	w.tt.clear()
	w.tt.new_search()
	w.history = HistoryScript.new()
	w.evaluator = NnueEval.new(engine.loader, engine.features)
	w.enable_aspiration = true
	w.nodes = 0
	w.seldepth = 0
	w._ensure_helpers()
	w._init_search_stack()
	w._init_root_moves()
	w.evaluator.begin(w.pos)
	w._pv_stack.clear()
	w._pv_stack.resize(Worker.SS_SIZE)
	for i in range(Worker.SS_SIZE):
		w._pv_stack[i] = PackedInt32Array()

	# Run d1 exactly like production ID (to seed TT/History/root averages)
	_run_depth(w, 1)
	var carry := {
		"event": "CARRY",
		"nodes": w.nodes,
		"best": T.move_to_uci(w.best_move),
		"score": w.best_score,
		"avg0": int(w.root_moves[0].average_score),
		"mss0": int(w.root_moves[0].mean_squared_score),
	}
	out.store_string(JSON.stringify(carry) + "\n")
	print("CARRY nodes=%d best=%s score=%d avg=%d mss=%d" % [
		carry["nodes"], carry["best"], carry["score"], carry["avg0"], carry["mss0"],
	])

	# Set d2 optimism / window like production
	var avg: int = int(w.root_moves[0].average_score)
	var mss: int = int(w.root_moves[0].mean_squared_score)
	var delta: int = 10 + absi(mss) / 39605
	var alpha: int = maxi(avg - delta, -T.VALUE_INFINITE)
	var beta: int = mini(avg + delta, T.VALUE_INFINITE)
	w.reductions.set_root_delta(beta - alpha)
	w._set_root_optimism(avg)
	print("D2_WINDOW a=%d b=%d delta=%d opt_formula=%d" % [
		alpha, beta, delta, 92 * avg / (absi(avg) + 95),
	])

	# Isolate first root move b2e2 @ depth 1 PV (child of root depth 2)
	var move: int = T.uci_to_move("b2e2")
	# Ensure b2e2 is first in root_moves order for realism
	print("root0=%s" % T.move_to_uci(w.root_moves[0].move()))

	var before: int = int(w.nodes)
	w._do_move_synced(move)
	# Trace move loop at ply=1 depth=1 manually (mirrors _search without changing it)
	var table := _trace_depth1_pv(w, -beta, -alpha)
	var value: int = -int(table["best_value"])
	w._undo_move_synced(move)
	var row := {
		"event": "B2E2_CHILD",
		"child_alpha": -beta,
		"child_beta": -alpha,
		"child_best": table["best_value"],
		"parent_value": value,
		"nodes": int(w.nodes) - before,
		"moves": table["moves"],
		"eval": table["eval"],
		"tt": table["tt"],
		"note": "Godot lacks upstream Step13 shallow pruning in production _search",
	}
	out.store_string(JSON.stringify(row) + "\n")
	print("B2E2 child_best=%d parent_value=%d nodes=%d eval=%s" % [
		table["best_value"], value, row["nodes"], str(table["eval"]),
	])
	print("Order | Move | Cap | Value | Alpha | Beta | Updated | Cutoff | Notes")
	for m in table["moves"]:
		print(" %5d | %4s | %3s | %5d | %5d | %5d | %7s | %6s | %s" % [
			m["order"], m["move"], str(m["cap"]), m["value"], m["alpha_before"],
			m["beta"], str(m["updated"]), str(m["cutoff"]), m.get("note", ""),
		])

	# Also call production _search for the same window to confirm value
	before = int(w.nodes)
	w._do_move_synced(move)
	var prod: int = w._search(Worker.NODE_PV, 1, -beta, -alpha, 1, false)
	w._undo_move_synced(move)
	print("PROD_SEARCH child=%d parent=%d nodes=%d" % [prod, -prod, int(w.nodes) - before])
	out.store_string(JSON.stringify({
		"event": "PROD_CONFIRM",
		"child": prod,
		"parent": -prod,
		"nodes": int(w.nodes) - before,
	}) + "\n")

	# Wider re-search window (post fail-high) like d2 aspir
	var a2: int = maxi(beta - delta, alpha)  # mirrors fail-high update: alpha = max(beta-delta, alpha)
	# After fail-high with score 199: alpha=max(65-10,45)=55, beta=min(199+10,INF)=209 — use observed
	var alpha_rs: int = 55
	var beta_rs: int = 209
	before = int(w.nodes)
	w._do_move_synced(move)
	var prod2: int = w._search(Worker.NODE_PV, 1, -beta_rs, -alpha_rs, 1, false)
	w._undo_move_synced(move)
	print("PROD_RESEARCH child=%d parent=%d nodes=%d window=[%d,%d]" % [
		prod2, -prod2, int(w.nodes) - before, -beta_rs, -alpha_rs,
	])

	out.close()
	engine.shutdown()
	print("S2_B2E2_DONE report=%s" % OUT_PATH)
	quit(0)


func _run_depth(w, depth: int) -> void:
	for rm in w.root_moves:
		rm.begin_iteration(true)
	var root_average: int = int(w.root_moves[0].average_score)
	var root_variance: int = int(w.root_moves[0].mean_squared_score)
	var delta: int = 10 + absi(root_variance) / 39605
	var alpha: int = maxi(root_average - delta, -T.VALUE_INFINITE)
	var beta: int = mini(root_average + delta, T.VALUE_INFINITE)
	w.reductions.set_root_delta(beta - alpha)
	var score: int = T.VALUE_NONE
	var guard := 0
	while true:
		guard += 1
		w._set_root_optimism(root_average)
		score = w._search_root(depth, alpha, beta)
		w._stable_sort_root_moves()
		if score <= alpha:
			beta = alpha
			alpha = maxi(score - delta, -T.VALUE_INFINITE)
			delta += 44 * delta / 128
			w.reductions.set_root_delta(maxi(beta - alpha, 1))
		elif score >= beta:
			alpha = maxi(beta - delta, alpha)
			beta = mini(score + delta, T.VALUE_INFINITE)
			delta += 44 * delta / 128
			w.reductions.set_root_delta(maxi(beta - alpha, 1))
		else:
			break
		if guard > 24:
			break
	w.best_score = score
	w.best_move = w.root_moves[0].move()
	w.pv = w.root_moves[0].pv.duplicate()
	w.completed_depth = depth


## Manual depth=1 PV move loop with Step13 *observation* (does not alter production).
## Compares what would be pruned vs what Godot actually searches.
func _trace_depth1_pv(w, alpha: int, beta: int) -> Dictionary:
	var ply := 1
	var depth := 1
	var tt_hit: Dictionary = w._tt_probe()
	var eval: int = T.VALUE_NONE
	var in_check: bool = false
	var chk: Array = w.pos.checkers()
	in_check = chk[0] != 0 or chk[1] != 0
	if in_check:
		eval = T.VALUE_NONE
	elif tt_hit.get("found", false) and int(tt_hit.get("eval", T.VALUE_NONE)) != T.VALUE_NONE:
		eval = int(tt_hit["eval"])
	else:
		eval = w._eval()

	var improving := (not in_check and eval != T.VALUE_NONE and eval >= beta)
	var tt_move: int = int(tt_hit.get("move", T.MOVE_NONE)) if tt_hit.get("found", false) else T.MOVE_NONE
	var picker = MP.new()
	picker.init_main(w.pos, tt_move, depth, w.history, ply, w._cont_hist_for_picker(ply))

	var best_value: int = -T.VALUE_INFINITE
	var move_count := 0
	var moves: Array = []
	var alpha0 := alpha
	var step13_would_skip_quiet_at := -1

	while true:
		var m: int = picker.next_move()
		if m == T.MOVE_NONE:
			break
		if not w.pos.legal(m):
			continue
		move_count += 1
		var is_cap: bool = w.pos.capture(m)
		var gives: bool = w.pos.gives_check(m)
		var note := ""
		# Observe upstream Step13 thresholds (do NOT skip — match Godot production)
		var thr: int = (3 + depth * depth) / (2 - (1 if improving else 0))
		if move_count >= thr and step13_would_skip_quiet_at < 0:
			step13_would_skip_quiet_at = move_count
			note += "STEP13_SKIP_QUIET_START "
		if move_count >= thr and not is_cap and not gives:
			note += "WOULD_SKIP_QUIET "
		# Capture SEE margin at depth1: margin = 256*1 + captHist*34/1024 ≈ 256 if hist~0
		if is_cap or gives:
			var see_ok: bool = w.pos.see_ge(m, -256)
			if not see_ok:
				note += "WOULD_SEE_PRUNE "

		var alpha_before := alpha
		var before: int = int(w.nodes)
		w._do_move_synced(m)
		var value: int
		if move_count == 1:
			value = -w._search(Worker.NODE_PV, 0, -beta, -alpha, ply + 1, false)
		else:
			value = -w._search(Worker.NODE_NON_PV, 0, -(alpha + 1), -alpha, ply + 1, true)
			if value > alpha and value < beta:
				value = -w._search(Worker.NODE_PV, 0, -beta, -alpha, ply + 1, false)
				note += "RESEARCH "
		w._undo_move_synced(m)
		var updated := false
		var cutoff := false
		if value > best_value:
			best_value = value
		if value > alpha:
			alpha = value
			updated = true
			if alpha >= beta:
				cutoff = true
		moves.append({
			"order": move_count - 1,
			"move": T.move_to_uci(m),
			"cap": is_cap,
			"check": gives,
			"value": value,
			"alpha_before": alpha_before,
			"beta": beta,
			"updated": updated,
			"cutoff": cutoff,
			"nodes": int(w.nodes) - before,
			"note": note.strip_edges(),
		})
		if cutoff:
			break

	return {
		"best_value": best_value,
		"moves": moves,
		"eval": eval,
		"improving": improving,
		"tt": tt_hit,
		"alpha0": alpha0,
		"step13_would_skip_quiet_at": step13_would_skip_quiet_at,
	}
