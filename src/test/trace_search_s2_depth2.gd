extends SceneTree

## SearchParity S2: startpos fixed depth=2 — carry state + root-move table.
## Zero production behavior change. Observation-only harness.
## Usage:
##   Godot --headless --path . -s res://src/test/trace_search_s2_depth2.gd
## Writes /tmp/godot_s2_depth2.jsonl

const Eng = preload("res://addons/pikafish/pikafish.gd")
const Config = preload("res://addons/pikafish/config.gd")
const Worker = preload("res://addons/pikafish/search/search_worker.gd")
const NnueEval = preload("res://addons/pikafish/search/nnue_evaluator.gd")
const HistoryScript = preload("res://addons/pikafish/search/history.gd")
const TTScript = preload("res://addons/pikafish/search/tt.gd")
const UciScore = preload("res://addons/pikafish/core/uci_score.gd")
const T = preload("res://addons/pikafish/core/types.gd")

const FEN := "rnbakabnr/9/1c5c1/p1p1p1p1p/9/9/P1P1P1P1P/1C5C1/9/RNBAKABNR w - - 0 1"
const OUT_PATH := "/tmp/godot_s2_depth2.jsonl"
const HASH_MB := 16


func _init() -> void:
	var out := FileAccess.open(OUT_PATH, FileAccess.WRITE)
	if out == null:
		printerr("S2_FAIL: cannot write %s" % OUT_PATH)
		quit(1)
		return

	var cfg = Config.new()
	cfg.prefer_gpu = false
	cfg.evaluation_mode = Config.EVALUATION_NNUE
	cfg.hash_mb = HASH_MB

	var engine = Eng.new()
	if engine.initialize(cfg) != OK:
		printerr("S2_FAIL: initialize")
		quit(1)
		return
	if engine.set_fen(FEN) != OK:
		printerr("S2_FAIL: set_fen")
		quit(1)
		return

	# --- Path A: public API go depth 2 (fresh TT/History) ---
	if engine._tt != null:
		engine._tt.clear()
		engine._tt.new_search()
	engine._history = null

	var api_iters: Array = []
	engine.search_info.connect(func(info) -> void:
		if info == null or bool(info.is_final):
			return
		var w = engine._worker
		var roots := _dump_roots(w, 16)
		var row := {
			"event": "API_ITERATION",
			"depth": int(info.depth),
			"seldepth": int(info.seldepth),
			"score": int(info.score),
			"cp": UciScore.to_cp(int(info.score), engine._pos),
			"nodes": int(info.nodes),
			"pv": _pv_uci(info.pv),
			"root_moves": roots,
		}
		api_iters.append(row)
		out.store_string(JSON.stringify(row) + "\n")
	)

	if engine.start_search({"depth": 2, "sync": true}) != OK:
		printerr("S2_FAIL: start_search depth 2")
		quit(1)
		return

	var got = engine._last_result
	var api_final := {
		"event": "API_FINAL",
		"bestmove": engine.move_to_uci(got.bestmove),
		"score": got.score,
		"cp": UciScore.to_cp(int(got.score), engine._pos),
		"nodes": got.nodes,
		"completed_depth": got.completed_depth,
		"pv": _pv_uci(got.pv),
		"root_moves": _dump_roots(engine._worker, 16),
	}
	out.store_string(JSON.stringify(api_final) + "\n")
	print("=== S2 API go depth 2 ===")
	print("FINAL best=%s value=%d cp=%d nodes=%d depth=%d" % [
		api_final["bestmove"], api_final["score"], api_final["cp"],
		api_final["nodes"], api_final["completed_depth"],
	])
	for it in api_iters:
		print("ITER d=%d value=%d cp=%d nodes=%d pv=%s" % [
			it["depth"], it["score"], it["cp"], it["nodes"], " ".join(it["pv"]),
		])

	# --- Path B: manual ID with full carry + aspiration + per-root-move table ---
	assert(engine.set_fen(FEN) == OK)
	var manual := _manual_depth2(engine)
	out.store_string(JSON.stringify(manual) + "\n")
	_print_manual(manual)

	out.close()
	engine.shutdown()
	print("S2_GODOT_DONE report=%s" % OUT_PATH)
	quit(0)


func _manual_depth2(engine) -> Dictionary:
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

	var events: Array = []
	var d1 := _run_id_depth(w, 1, events, "D1")
	var carry := {
		"event": "CARRY_D1_TO_D2",
		"nodes": w.nodes,
		"bestmove": T.move_to_uci(w.best_move),
		"best_score": w.best_score,
		"best_cp": UciScore.to_cp(w.best_score, w.pos),
		"optimism": _optimism_pair(w),
		"root_moves": _dump_roots(w, 44),
		"tt_probe_best": _tt_probe_root(w),
	}
	events.append(carry)

	var d2 := _run_id_depth(w, 2, events, "D2")

	return {
		"event": "MANUAL_DEPTH2",
		"d1": d1,
		"carry": carry,
		"d2": d2,
		"events": events,
		"final": {
			"bestmove": T.move_to_uci(w.best_move),
			"score": w.best_score,
			"cp": UciScore.to_cp(w.best_score, w.pos),
			"nodes": w.nodes,
			"root_moves": _dump_roots(w, 16),
		},
	}


func _run_id_depth(w, depth: int, events: Array, tag: String) -> Dictionary:
	for root_move in w.root_moves:
		root_move.begin_iteration(true)

	var root_average: int = int(w.root_moves[0].average_score)
	var root_variance: int = int(w.root_moves[0].mean_squared_score)
	var delta: int = 10 + absi(root_variance) / 39605
	var alpha: int = maxi(root_average - delta, -T.VALUE_INFINITE)
	var beta: int = mini(root_average + delta, T.VALUE_INFINITE)
	w.reductions.set_root_delta(beta - alpha)

	var asp_iters: Array = []
	var score: int = T.VALUE_NONE
	var re_search_count := 0
	while true:
		w._set_root_optimism(root_average)
		var opt := _optimism_pair(w)
		var nodes_before: int = w.nodes
		# Per-root-move instrumentation for this aspiration attempt
		var move_table: Array = []
		score = _search_root_traced(w, depth, alpha, beta, move_table)
		w._stable_sort_root_moves()
		var asp_tag := "exact"
		if score <= alpha:
			asp_tag = "fail_low"
		elif score >= beta:
			asp_tag = "fail_high"
		var asp_row := {
			"event": "%s_ASPIRATION" % tag,
			"depth": depth,
			"avg": root_average,
			"mss": root_variance,
			"delta": delta,
			"alpha": alpha,
			"beta": beta,
			"score": score,
			"cp": UciScore.to_cp(score, w.pos) if score != T.VALUE_NONE else null,
			"tag": asp_tag,
			"nodes_delta": w.nodes - nodes_before,
			"nodes_total": w.nodes,
			"optimism": opt,
			"best_after": T.move_to_uci(w.root_moves[0].move()) if not w.root_moves.is_empty() else "",
			"move_table": move_table,
			"root_top": _dump_roots(w, 12),
		}
		asp_iters.append(asp_row)
		events.append(asp_row)
		if score <= alpha:
			beta = alpha
			alpha = maxi(score - delta, -T.VALUE_INFINITE)
			delta += 44 * delta / 128
			w.reductions.set_root_delta(maxi(beta - alpha, 1))
			re_search_count += 1
		elif score >= beta:
			alpha = maxi(beta - delta, alpha)
			beta = mini(score + delta, T.VALUE_INFINITE)
			delta += 44 * delta / 128
			w.reductions.set_root_delta(maxi(beta - alpha, 1))
			re_search_count += 1
		else:
			break
		if re_search_count > 24:
			break

	w.best_score = score
	if not w.root_moves.is_empty():
		w.best_move = w.root_moves[0].move()
		w.pv = w.root_moves[0].pv.duplicate()
	w.completed_depth = depth
	return {
		"depth": depth,
		"score": score,
		"cp": UciScore.to_cp(score, w.pos),
		"nodes": w.nodes,
		"re_searches": re_search_count,
		"aspiration": asp_iters,
		"root_moves": _dump_roots(w, 16),
		"bestmove": T.move_to_uci(w.best_move),
	}


## Observation wrapper around root search: same call sequence as _search_root,
## but records per-move window / value / re-search / nodes. Does not alter values.
func _search_root_traced(w, depth: int, alpha: int, beta: int, move_table: Array) -> int:
	if w.root_moves.is_empty():
		return T.mated_in(0) if (w.pos.checkers()[0] != 0 or w.pos.checkers()[1] != 0) else T.VALUE_DRAW
	var alpha0 := alpha
	var best_value := -T.VALUE_INFINITE
	var move_count := 0
	for root_move in w.root_moves:
		var move: int = root_move.move()
		if move == T.MOVE_NONE or not w.pos.legal(move):
			continue
		move_count += 1
		var before: int = int(w.nodes)
		var win_a: int = 0
		var win_b: int = 0
		var researched := false
		w._do_move_synced(move)
		var value: int = 0
		if move_count == 1:
			win_a = -beta
			win_b = -alpha
			value = -w._search(Worker.NODE_PV, depth - 1, -beta, -alpha, 1, false)
		else:
			win_a = -(alpha + 1)
			win_b = -alpha
			value = -w._search(Worker.NODE_NON_PV, depth - 1, -(alpha + 1), -alpha, 1, true)
			if value > alpha and value < beta:
				researched = true
				win_a = -beta
				win_b = -alpha
				value = -w._search(Worker.NODE_PV, depth - 1, -beta, -alpha, 1, false)
		var child_pv: PackedInt32Array = w._pv_stack[1].duplicate()
		w._undo_move_synced(move)
		var searched_nodes: int = maxi(0, int(w.nodes) - before)
		root_move.effort += searched_nodes
		w._root_effort_by_move[move] = int(w._root_effort_by_move.get(move, 0)) + searched_nodes
		var updated := false
		if value > best_value:
			best_value = value
		if move_count == 1 or value > alpha:
			root_move.set_score(value, alpha0, beta, child_pv, w.seldepth, searched_nodes)
			updated = true
			if value > alpha:
				if w.best_move != T.MOVE_NONE and w.best_move != move:
					w._root_best_move_changes += 1
				w.best_move = move
				w.pv = root_move.pv.duplicate()
				alpha = value
				if alpha >= beta:
					move_table.append({
						"order": move_count - 1,
						"move": T.move_to_uci(move),
						"child_alpha": win_a,
						"child_beta": win_b,
						"depth": depth - 1,
						"value": value,
						"cp": UciScore.to_cp(value, w.pos),
						"re_search": researched,
						"nodes": searched_nodes,
						"updated": updated,
						"cutoff": true,
						"final_alpha": alpha,
					})
					break
		else:
			root_move.score = -T.VALUE_INFINITE
		move_table.append({
			"order": move_count - 1,
			"move": T.move_to_uci(move),
			"child_alpha": win_a,
			"child_beta": win_b,
			"depth": depth - 1,
			"value": value,
			"cp": UciScore.to_cp(value, w.pos),
			"re_search": researched,
			"nodes": searched_nodes,
			"updated": updated,
			"cutoff": false,
			"final_alpha": alpha,
		})
	return best_value if best_value != -T.VALUE_INFINITE else alpha


func _dump_roots(w, limit: int) -> Array:
	var roots: Array = []
	if w == null:
		return roots
	for i in range(mini(w.root_moves.size(), limit)):
		var rm = w.root_moves[i]
		roots.append({
			"order": i,
			"move": T.move_to_uci(rm.move()),
			"score": int(rm.score),
			"previous_score": int(rm.previous_score),
			"average_score": int(rm.average_score),
			"mean_squared_score": int(rm.mean_squared_score),
			"effort": int(rm.effort),
			"upperbound": bool(rm.score_upperbound),
			"lowerbound": bool(rm.score_lowerbound),
			"pv": _pv_uci(rm.pv),
		})
	return roots


func _optimism_pair(w) -> Dictionary:
	if w.evaluator == null:
		return {"white": 0, "black": 0}
	# NnueEvaluator keeps private _optimism; mirror via set formula from average.
	# Read through script property if exposed, else 0.
	var ow := 0
	var ob := 0
	if w.evaluator.get("_optimism") != null:
		var o = w.evaluator.get("_optimism")
		if typeof(o) == TYPE_PACKED_INT32_ARRAY and o.size() >= 2:
			ow = int(o[0])
			ob = int(o[1])
	return {"white": ow, "black": ob}


func _tt_probe_root(w) -> Dictionary:
	if w.tt == null or w.pos == null:
		return {}
	var key: int = int(w.pos.key())
	var e: Dictionary = w.tt.probe(key)
	if e.is_empty() or not bool(e.get("hit", false)):
		# Some TT APIs return {found:..} — accept either.
		if not bool(e.get("found", false)) and not e.has("depth"):
			return {"hit": false}
	return {
		"hit": true,
		"depth": int(e.get("depth", e.get("depth8", 0))),
		"value": int(e.get("value", e.get("value16", 0))),
		"bound": int(e.get("bound", e.get("gen_bound", 0))),
		"move": T.move_to_uci(int(e.get("move", e.get("move16", 0)))) if int(e.get("move", e.get("move16", 0))) != 0 else "",
		"raw": e,
	}


func _pv_uci(pv) -> PackedStringArray:
	var result := PackedStringArray()
	if pv == null:
		return result
	if typeof(pv) == TYPE_PACKED_INT32_ARRAY or typeof(pv) == TYPE_ARRAY:
		for m in pv:
			result.append(T.move_to_uci(int(m)))
	return result


func _print_manual(manual: Dictionary) -> void:
	print("=== S2 MANUAL depth2 ===")
	var carry: Dictionary = manual["carry"]
	print("--- CARRY d1→d2 ---")
	print("best=%s value=%d cp=%d nodes=%d" % [
		carry["bestmove"], carry["best_score"], carry["best_cp"], carry["nodes"],
	])
	print("optimism=%s" % str(carry["optimism"]))
	for rm in carry["root_moves"]:
		if int(rm["score"]) == -T.VALUE_INFINITE and int(rm["average_score"]) == -T.VALUE_INFINITE:
			continue
		if int(rm["order"]) > 8 and int(rm["score"]) == -T.VALUE_INFINITE:
			continue
		print("  #%d %s score=%d prev=%d avg=%d mss=%d effort=%d pv=%s" % [
			rm["order"], rm["move"], rm["score"], rm["previous_score"],
			rm["average_score"], rm["mean_squared_score"], rm["effort"],
			" ".join(rm["pv"]),
		])
	for tag in ["d1", "d2"]:
		var block: Dictionary = manual[tag]
		print("--- %s final value=%d cp=%d nodes=%d re_searches=%d best=%s ---" % [
			tag.to_upper(), block["score"], block["cp"], block["nodes"],
			block["re_searches"], block["bestmove"],
		])
		for asp in block["aspiration"]:
			print("  ASP a=%d b=%d delta=%d avg=%d score=%d tag=%s dn=%d opt=%s" % [
				asp["alpha"], asp["beta"], asp["delta"], asp["avg"],
				asp["score"], asp["tag"], asp["nodes_delta"], str(asp["optimism"]),
			])
			print("  Order | Move | ChildWin | Depth | Value | CP | ReSearch | Nodes | Updated")
			for m in asp["move_table"]:
				print("  %5d | %4s | [%d,%d] | %5d | %5d | %3d | %8s | %5d | %s" % [
					m["order"], m["move"], m["child_alpha"], m["child_beta"],
					m["depth"], m["value"], m["cp"], str(m["re_search"]),
					m["nodes"], str(m["updated"]),
				])
