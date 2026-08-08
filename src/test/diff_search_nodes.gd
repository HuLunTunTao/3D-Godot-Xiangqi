extends SceneTree

## Fixed-node NNUE differential runner.
## Usage: Godot --headless --path . -s res://src/test/diff_search_nodes.gd
## Writes user://search_node_diff.json. Differences are evidence, not failures:
## this runner fails only for invalid fixture data or illegal addon results.

const Eng = preload("res://addons/pikafish/pikafish.gd")
const Config = preload("res://addons/pikafish/config.gd")
const Types = preload("res://addons/pikafish/core/types.gd")
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
	var exact_score := 0
	var total := 0
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
			if got_move == want_move:
				exact_move += 1
			var want_score = reference.get("score", null)
			var score_match: bool = want_score != null and str(want_score.get("type", "")) == "cp" \
				and int(want_score.get("value", 999999)) == got.score
			if score_match:
				exact_score += 1
			rows.append({
				"label": label,
				"budget": budget,
				"oracle": reference,
				"addon": {
					"bestmove": got_move,
					"score": got.score,
					"nodes": got.nodes,
					"completed_depth": got.completed_depth,
					"pv": _pv_to_uci(engine, got.pv),
				},
				"match": {"legal": is_legal, "bestmove": got_move == want_move, "score": score_match},
			})
			print("NODE_DIFF %s n=%d oracle=%s/%s addon=%s/%d depth=%d nodes=%d" % [
				label, budget, want_move, str(want_score), got_move, got.score,
				got.completed_depth, got.nodes,
			])
	engine.shutdown()
	var report := {
		"marker": "NODE_DIFF_PASS" if legal == total else "NODE_DIFF_FAIL",
		"fixture": FIXTURE,
		"upstream_sha": fixture.get("upstream_sha", ""),
		"evaluation_mode": Config.EVALUATION_NNUE,
		"summary": {"total": total, "legal": legal, "exact_bestmove": exact_move, "exact_score": exact_score},
		"rows": rows,
	}
	var file := FileAccess.open(REPORT, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "\t"))
		file.close()
	print("%s total=%d legal=%d bestmove_exact=%d score_exact=%d report=%s" % [
		report["marker"], total, legal, exact_move, exact_score, REPORT,
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
