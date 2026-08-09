extends SceneTree

## Rules observable differential vs upstream Position::rule_judge oracle JSON lines.
## Usage:
##   /tmp/pikafish-rules-oracle/src/pikafish < fixtures/core/rules_corpus.txt > /tmp/rules_oracle.jsonl
##   Godot --headless --path . -s res://src/test/diff_rules_oracle.gd -- /tmp/rules_oracle.jsonl
## Does not modify production Rules API beyond reading claimed/value.

const Z = preload("res://addons/pikafish/core/zobrist.gd")
const T = preload("res://addons/pikafish/core/types.gd")
const Pos = preload("res://addons/pikafish/core/position.gd")
const Rules = preload("res://addons/pikafish/core/rules.gd")

const CORPUS := "res://fixtures/core/rules_corpus.txt"
const REPORT := "user://rules_diff.json"


func _init() -> void:
	Z.init_keys()
	var oracle_path := ""
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		args = OS.get_cmdline_args()
	for i in range(args.size()):
		if args[i].ends_with(".jsonl") or args[i].ends_with(".json"):
			oracle_path = args[i]
	if oracle_path.is_empty():
		printerr("USAGE: pass oracle jsonl path after --")
		quit(1)
		return

	var cases := _load_corpus()
	var oracle_by_id := _load_oracle_jsonl(oracle_path)
	if cases.is_empty() or oracle_by_id.is_empty():
		printerr("RULES_DIFF_FAIL: empty corpus or oracle")
		quit(1)
		return

	var rows: Array = []
	var match_n := 0
	var total := 0
	for c in cases:
		var id: String = str(c["id"])
		if not oracle_by_id.has(id):
			rows.append({"id": id, "error": "missing oracle", "match": false})
			total += 1
			continue
		var o: Dictionary = oracle_by_id[id]
		if o.has("error"):
			rows.append({"id": id, "oracle_error": o["error"], "match": false})
			total += 1
			continue
		var got := _run_case(c)
		if got.has("error"):
			rows.append({"id": id, "godot_error": got["error"], "oracle": o, "match": false})
			total += 1
			continue
		var same := _same_obs(o, got)
		if same:
			match_n += 1
		total += 1
		var suspected := ""
		if not same:
			suspected = _suspect(o, got, c)
		rows.append({
			"id": id,
			"oracle": o,
			"godot": got,
			"match": same,
			"suspected_symbol": suspected,
		})
		print("RULES_DIFF %s match=%s oracle=%s/%s godot=%s/%s soft_o=%s soft_g=%s %s" % [
			id, same,
			o.get("claimed"), o.get("value_kind"),
			got.get("claimed"), _value_kind(int(got.get("value", T.VALUE_NONE))),
			o.get("soft"), got.get("soft"),
			suspected,
		])

	var report := {
		"marker": "RULES_DIFF_PASS" if match_n == total else "RULES_DIFF_MISMATCH",
		"summary": {"total": total, "match": match_n, "mismatch": total - match_n},
		"rows": rows,
	}
	var f := FileAccess.open(REPORT, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(report, "\t"))
		f.close()
	print("%s match=%d/%d report=%s" % [report["marker"], match_n, total, REPORT])
	quit(0 if match_n == total else 2)


func _load_corpus() -> Array:
	var path := CORPUS
	if not FileAccess.file_exists(path):
		printerr("missing " + path)
		return []
	var text := FileAccess.get_file_as_string(path)
	var cases: Array = []
	var cur: Dictionary = {}
	for raw in text.split("\n"):
		var line: String = raw.strip_edges()
		if line.is_empty() or line.begins_with("#"):
			continue
		var parts: PackedStringArray = line.split(" ", false, 1)
		var cmd: String = parts[0]
		var rest: String = parts[1] if parts.size() > 1 else ""
		match cmd:
			"CASE":
				cur = {"id": rest, "moves": [], "ply": 0, "chased": false}
			"FEN":
				cur["fen"] = rest
			"MOVES":
				cur["moves"] = rest.split(" ", false)
			"PLY":
				cur["ply"] = int(rest)
			"CHASED":
				cur["chased"] = true
			"END":
				cases.append(cur)
				cur = {}
	return cases


func _load_oracle_jsonl(path: String) -> Dictionary:
	var out := {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		# absolute path outside res://
		f = FileAccess.open(path, FileAccess.READ)
	if f == null:
		printerr("cannot open oracle " + path)
		return {}
	while not f.eof_reached():
		var line := f.get_line().strip_edges()
		if line.is_empty():
			continue
		var parsed = JSON.parse_string(line)
		if typeof(parsed) == TYPE_DICTIONARY and parsed.has("id"):
			out[str(parsed["id"])] = parsed
	f.close()
	return out


func _run_case(c: Dictionary) -> Dictionary:
	var pos = Pos.new()
	if pos.set_fen(str(c["fen"])) != OK:
		return {"error": "bad fen: " + str(pos.last_error)}
	for u in c["moves"]:
		var m: int = T.uci_to_move(str(u))
		if not pos.pseudo_legal(m) or not pos.legal(m):
			return {"error": "illegal move " + str(u)}
		pos.do_move(m)
	var ply: int = int(c.get("ply", 0))
	var rj: Dictionary = pos.rule_judge(ply)
	var claimed: bool = bool(rj.get("claimed", false))
	var value: int = int(rj.get("value", T.VALUE_NONE))
	# Soft observable gap: production returns VALUE_NONE when not claimed.
	# Expose via minimal adapter that re-reads the same dict only.
	var soft: bool = (not claimed) and value != T.VALUE_NONE
	var out := {
		"claimed": claimed,
		"value": value,
		"value_kind": _value_kind(value),
		"rule60": pos.rule60_count(),
		"check10_w": pos.stack.check10_w[pos.st()],
		"check10_b": pos.stack.check10_b[pos.st()],
		"side": "w" if pos.side_to_move == T.COLOR_WHITE else "b",
		"soft": soft,
	}
	if c.get("chased", false):
		out["chased_w"] = Rules.chased(pos, T.COLOR_WHITE)
		out["chased_b"] = Rules.chased(pos, T.COLOR_BLACK)
	return out


func _same_obs(o: Dictionary, g: Dictionary) -> bool:
	if bool(o.get("claimed")) != bool(g.get("claimed")):
		return false
	if int(o.get("value")) != int(g.get("value")):
		return false
	if int(o.get("rule60")) != int(g.get("rule60")):
		return false
	if int(o.get("check10_w")) != int(g.get("check10_w")):
		return false
	if int(o.get("check10_b")) != int(g.get("check10_b")):
		return false
	if str(o.get("side")) != str(g.get("side")):
		return false
	if bool(o.get("soft")) != bool(g.get("soft")):
		return false
	if o.has("chased_w") and int(o["chased_w"]) != int(g.get("chased_w", -1)):
		return false
	if o.has("chased_b") and int(o["chased_b"]) != int(g.get("chased_b", -1)):
		return false
	return true


func _suspect(o: Dictionary, g: Dictionary, c: Dictionary) -> String:
	if int(o.get("rule60")) != int(g.get("rule60")) or int(o.get("check10_w")) != int(g.get("check10_w")) \
			or int(o.get("check10_b")) != int(g.get("check10_b")):
		return "Position::do_move(check10/rule60)"
	if o.has("chased_w") and (int(o["chased_w"]) != int(g.get("chased_w", -1)) \
			or int(o["chased_b"]) != int(g.get("chased_b", -1))):
		return "Position::chased"
	var ok := bool(o.get("claimed"))
	var gk := bool(g.get("claimed"))
	var ov := int(o.get("value"))
	var gv := int(g.get("value"))
	if ok != gk or ov != gv:
		var moves: Array = c.get("moves", [])
		if str(c.get("id", "")).begins_with("chase") or str(c.get("id", "")).find("chase") >= 0:
			return "Position::detect_chases / chased"
		if moves.size() >= 4:
			# check vs chase branch in rule_judge
			return "Position::rule_judge"
		return "Position::rule_judge"
	if bool(o.get("soft")) != bool(g.get("soft")):
		return "Position::rule_judge(soft result)"
	return "unknown"


func _value_kind(v: int) -> String:
	if v == T.VALUE_NONE:
		return "none"
	if v == T.VALUE_DRAW:
		return "draw"
	if T.is_win(v):
		return "mate"
	if T.is_loss(v):
		return "mated"
	return "cp"
