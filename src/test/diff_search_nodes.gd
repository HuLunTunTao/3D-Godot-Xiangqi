extends SceneTree

## Fixed-node NNUE differential runner.
## Usage: Godot --headless --path . -s res://src/test/diff_search_nodes.gd
## Writes user://search_node_diff.json. Differences are evidence, not failures:
## this runner fails only for invalid fixture data or illegal addon results.
##
## Units: fixture `score` is official UCI `score cp` (to_cp(Value)).
## Godot `result.score` is internal Value. Never compare them directly.

const Eng = preload("res://addons/pikafish/pikafish.gd")
const Config = preload("res://addons/pikafish/config.gd")
const Types = preload("res://addons/pikafish/core/types.gd")
const UciScore = preload("res://addons/pikafish/core/uci_score.gd")
const FIXTURE := "res://fixtures/search/node_corpus.json"
const REPORT := "user://search_node_diff.json"


func _init() -> void:
	var fixture := _load_fixture()
	if fixture.is_empty():
		quit(1)
		return
	var cfg = Config.new()
	cfg.prefer_gpu = false
	cfg.evaluation_mode = Config.EVALUATION_NNUE
	var engine = Eng.new()
	if engine.initialize(cfg) != OK:
		printerr("NODE_DIFF_FAIL: initialize")
		quit(1)
		return
	var rows: Array = []
	var legal := 0
	var exact_move := 0
	var exact_value := 0
	var exact_cp := 0
	var cp_abs_deltas: Array = []
	var mate_rows := 0
	var total := 0
	print("| Case | PF Depth | GD Depth | PF Value | GD Value | PF CP | GD CP | Bestmove Match |")
	print("|---|---:|---:|---:|---:|---:|---:|:---:|")
	for position in fixture["positions"]:
		var label := str(position["label"])
		var fen := str(position["fen"])
		for reference in position["runs"]:
			total += 1
			if engine.set_fen(fen) != OK:
				printerr("NODE_DIFF_FAIL: set_fen " + label)
				engine.shutdown()
				quit(1)
				return
			var budget := int(reference["budget"])
			if engine.start_search({"nodes": budget, "sync": true}) != OK:
				printerr("NODE_DIFF_FAIL: start " + label)
				engine.shutdown()
				quit(1)
				return
			var got = engine._last_result
			var got_move := engine.move_to_uci(got.bestmove)
			var want_move := str(reference.get("bestmove", ""))
			var is_legal := Types.move_is_ok(got.bestmove) and engine.is_legal(got.bestmove)
			if is_legal:
				legal += 1
			var bestmove_match: bool = got_move == want_move
			if bestmove_match:
				exact_move += 1

			var gd_value: int = int(got.score)
			var gd_cp: int = UciScore.to_cp(gd_value, engine._pos)
			var want_score = reference.get("score", null)
			var pf_cp = null
			var pf_value = null
			var pf_value_source := "missing"
			var is_mate := false
			if want_score != null:
				var stype := str(want_score.get("type", ""))
				if stype == "mate":
					is_mate = true
					mate_rows += 1
					pf_cp = null
					pf_value = null
					pf_value_source = "mate"
				elif stype == "cp":
					pf_cp = int(want_score.get("value", 0))
					if reference.has("value") and reference["value"] != null:
						pf_value = int(reference["value"])
						pf_value_source = "instrumented"
					elif reference.has("internal_value") and reference["internal_value"] != null:
						pf_value = int(reference["internal_value"])
						pf_value_source = "instrumented"
					else:
						pf_value = UciScore.from_cp_estimate(int(pf_cp), engine._pos)
						pf_value_source = "from_cp_estimate"

			var value_match: bool = (
				not is_mate
				and pf_value != null
				and pf_value_source == "instrumented"
				and int(pf_value) == gd_value
			)
			var cp_match: bool = not is_mate and pf_cp != null and int(pf_cp) == gd_cp
			# Estimated PF Value must not drive "Value exact"; CP is the UCI-grounded check.
			if value_match:
				exact_value += 1
			if cp_match:
				exact_cp += 1
			if not is_mate and pf_cp != null:
				cp_abs_deltas.append(absi(int(pf_cp) - gd_cp))

			var pf_depth := int(reference.get("completed_depth", 0))
			var gd_depth := int(got.completed_depth)
			var pf_nodes := int(reference.get("nodes", 0))
			var gd_nodes := int(got.nodes)
			rows.append({
				"label": label,
				"budget": budget,
				"oracle": {
					"bestmove": want_move,
					"score_uci": want_score,
					"value": pf_value,
					"value_source": pf_value_source,
					"cp": pf_cp,
					"nodes": pf_nodes,
					"completed_depth": pf_depth,
					"pv": reference.get("pv", []),
				},
				"addon": {
					"bestmove": got_move,
					"value": gd_value,
					"cp": gd_cp,
					"nodes": gd_nodes,
					"completed_depth": gd_depth,
					"pv": _pv_to_uci(engine, got.pv),
				},
				"match": {
					"legal": is_legal,
					"bestmove": bestmove_match,
					"value": value_match,
					"cp": cp_match,
					"mate": is_mate,
				},
			})
			print("| %s@%d | %d | %d | %s | %d | %s | %d | %s |" % [
				label, budget, pf_depth, gd_depth,
				str(pf_value) if pf_value != null else "n/a",
				gd_value,
				str(pf_cp) if pf_cp != null else ("mate" if is_mate else "n/a"),
				gd_cp,
				"Y" if bestmove_match else "N",
			])
			print("NODE_DIFF %s n=%d pf=%s/v=%s/cp=%s/d=%d/nodes=%d gd=%s/v=%d/cp=%d/d=%d/nodes=%d value_src=%s" % [
				label, budget, want_move, str(pf_value), str(pf_cp), pf_depth, pf_nodes,
				got_move, gd_value, gd_cp, gd_depth, gd_nodes, pf_value_source,
			])
	engine.shutdown()
	var mean_abs_cp := 0.0
	var median_abs_cp := 0.0
	if not cp_abs_deltas.is_empty():
		var sum_abs := 0
		for d in cp_abs_deltas:
			sum_abs += int(d)
		mean_abs_cp = float(sum_abs) / float(cp_abs_deltas.size())
		var sorted_d: Array = cp_abs_deltas.duplicate()
		sorted_d.sort()
		var mid: int = sorted_d.size() / 2
		if sorted_d.size() % 2 == 0:
			median_abs_cp = float(int(sorted_d[mid - 1]) + int(sorted_d[mid])) / 2.0
		else:
			median_abs_cp = float(sorted_d[mid])
	var report := {
		"marker": "NODE_DIFF_PASS" if legal == total else "NODE_DIFF_FAIL",
		"fixture": FIXTURE,
		"upstream_sha": fixture.get("upstream_sha", ""),
		"evaluation_mode": Config.EVALUATION_NNUE,
		"units": {
			"pf_score_in_fixture": "uci_cp_via_to_cp",
			"gd_result_score": "internal_value",
			"note": "Do not compare raw Value to UCI cp. Old CP-exact baselines are measurement invalid / pre-node-parity.",
		},
		"summary": {
			"total": total,
			"legal": legal,
			"exact_bestmove": exact_move,
			"exact_value": exact_value,
			"exact_cp": exact_cp,
			"mate_cases": mate_rows,
			"mean_abs_delta_cp": mean_abs_cp,
			"median_abs_delta_cp": median_abs_cp,
		},
		"rows": rows,
	}
	var file := FileAccess.open(REPORT, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "\t"))
		file.close()
	print("%s total=%d legal=%d bestmove_exact=%d value_exact=%d cp_exact=%d mean_|dcp|=%.2f median_|dcp|=%.2f report=%s" % [
		report["marker"], total, legal, exact_move, exact_value, exact_cp,
		mean_abs_cp, median_abs_cp, REPORT,
	])
	quit(0 if legal == total else 1)


func _load_fixture() -> Dictionary:
	if not FileAccess.file_exists(FIXTURE):
		printerr("NODE_DIFF_FAIL: missing fixture " + FIXTURE)
		return {}
	var file := FileAccess.open(FIXTURE, FileAccess.READ)
	var parsed = JSON.parse_string(file.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY or str(parsed.get("format", "")) != "godot-pikafish-node-fixture/v1":
		printerr("NODE_DIFF_FAIL: invalid fixture")
		return {}
	return parsed


func _pv_to_uci(engine, pv: PackedInt32Array) -> PackedStringArray:
	var result := PackedStringArray()
	for move in pv:
		result.append(engine.move_to_uci(move))
	return result
