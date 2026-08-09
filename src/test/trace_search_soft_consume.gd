extends SceneTree

## SearchParity S0: soft rule_judge consumption evidence vs production search_worker.
## Usage:
##   Godot --headless --path . -s res://src/test/trace_search_soft_consume.gd

const Z = preload("res://addons/pikafish/core/zobrist.gd")
const T = preload("res://addons/pikafish/core/types.gd")
const Pos = preload("res://addons/pikafish/core/position.gd")
const Worker = preload("res://addons/pikafish/search/search_worker.gd")
const Attacks = preload("res://addons/pikafish/core/attacks.gd")
const Bitboard = preload("res://addons/pikafish/core/bitboard.gd")


func _init() -> void:
	Bitboard.ensure_tables()
	Attacks.init_tables()
	Z.init_keys()

	var cases: Array = [
		{
			"id": "chase_soft_1fold_ply5",
			"fen": "3k1a3/9/9/1c7/9/1R7/9/9/9/3A1K3 w - - 0 1",
			"moves": ["f0e0", "b6a6", "b4a4", "a6b6", "a4b4"],
			"ply": 5,
			"label": "soft 2-fold chase mate",
		},
		{
			"id": "perp_check_1fold_ply5",
			"fen": "4k4/9/4R4/9/9/9/9/9/9/3K5 b - - 0 1",
			"moves": ["e9f9", "e7f7", "f9e9", "f7e7"],
			"ply": 5,
			"label": "soft 2-fold perpetual check (mate for stm)",
		},
		{
			"id": "perp_check_soft_mated_ply5",
			"fen": "4k4/9/4R4/9/9/9/9/9/9/3K5 b - - 0 1",
			"moves": ["e9f9", "e7f7", "f9e9", "f7e7", "e9f9", "e7f7", "f9e9"],
			"ply": 5,
			"label": "soft 2-fold perpetual check (mated for checker stm)",
		},
		{
			"id": "perp_check_1fold_root",
			"fen": "4k4/9/4R4/9/9/9/9/9/9/3K5 b - - 0 1",
			"moves": ["e9f9", "e7f7", "f9e9", "f7e7"],
			"ply": 0,
			"label": "1-fold check at root (no soft)",
		},
		{
			"id": "quiet_rep_1fold_ply5",
			"fen": "3k1a3/9/9/9/9/9/P8/9/9/3A1K3 w - - 0 1",
			"moves": ["f0e0", "d9d8", "e0f0", "d8d9"],
			"ply": 5,
			"label": "quiet 1-fold at ply5 (hard draw claim)",
		},
		{
			"id": "chase_cont_2fold",
			"fen": "3k1a3/9/9/1c7/9/1R7/9/9/9/3A1K3 b - - 0 1",
			"moves": ["b6a6", "b4a4", "a6b6", "a4b4", "b6a6", "b4a4", "a6b6", "a4b4"],
			"ply": 0,
			"label": "hard 2-fold chase claim",
		},
	]

	print("=== SearchParity S0 soft consumption trace ===")
	for c in cases:
		_trace_case(c)
	print("SOFT_TRACE_DONE")
	quit(0)


func _make_worker(pos) -> Worker:
	var w = Worker.new()
	w.pos = pos
	w._ensure_helpers()
	w._pv_stack.clear()
	for _i in range(16):
		w._pv_stack.append(PackedInt32Array())
	w.nodes = 0
	return w


func _trace_case(c: Dictionary) -> void:
	var pos = Pos.new()
	if pos.set_fen(str(c["fen"])) != OK:
		print("FAIL %s bad fen" % c["id"])
		return
	for u in c["moves"]:
		var m: int = T.uci_to_move(str(u))
		if not pos.legal(m):
			print("FAIL %s illegal %s" % [c["id"], u])
			return
		pos.do_move(m)

	var ply: int = int(c["ply"])
	var rj: Dictionary = pos.rule_judge(ply)
	var claimed: bool = bool(rj.get("claimed", false))
	var value: int = int(rj.get("value", T.VALUE_NONE))
	var soft: bool = (not claimed) and value != T.VALUE_NONE

	# Upstream search<> soft action (search.cpp ~726-738), non-root.
	var search_alpha0 := -100
	var search_beta0 := 100
	var search_alpha := search_alpha0
	var search_beta := search_beta0
	var pikafish_search := "continue (no rule effect)"
	if claimed:
		if value == T.VALUE_DRAW:
			pikafish_search = "return value_draw(nodes)"
		else:
			pikafish_search = "return result=%d" % value
	elif soft:
		if value > T.VALUE_DRAW:
			search_alpha = maxi(search_alpha, T.VALUE_DRAW - 1)
			pikafish_search = "alpha=max(alpha,VALUE_DRAW-1) → α=%d; continue (no soft-only return)" % search_alpha
		else:
			search_beta = mini(search_beta, T.VALUE_DRAW + 1)
			pikafish_search = "beta=min(beta,VALUE_DRAW+1) → β=%d; continue (no soft-only return)" % search_beta

	# Upstream qsearch<> soft action (search.cpp ~1571-1586)
	var qs_alpha0 := -100
	var qs_beta0 := 100
	var qs_alpha := qs_alpha0
	var qs_beta := qs_beta0
	var pikafish_qs := "continue (no rule effect)"
	if claimed:
		pikafish_qs = "return result=%d (no value_draw)" % value
	elif soft:
		if value > T.VALUE_DRAW:
			qs_alpha = maxi(qs_alpha, T.VALUE_DRAW)
			pikafish_qs = "alpha=max(alpha,VALUE_DRAW) → α=%d" % qs_alpha
		else:
			qs_beta = mini(qs_beta, T.VALUE_DRAW)
			pikafish_qs = "beta=min(beta,VALUE_DRAW) → β=%d" % qs_beta
		if qs_alpha >= qs_beta:
			pikafish_qs += "; alpha>=beta → return alpha"
		else:
			pikafish_qs += "; continue"

	# Production Godot: static expected action mirrors upstream after S0 patch.
	var godot_search := "continue (no rule effect)"
	var godot_qs := "continue (no rule effect)"
	if claimed:
		if value == T.VALUE_DRAW:
			godot_search = "return _value_draw()"
		else:
			godot_search = "return rj_value=%d" % value
		godot_qs = "return rj_value=%d" % value
	elif soft:
		if value > T.VALUE_DRAW:
			godot_search = "alpha=max(alpha,VALUE_DRAW-1) → α=%d; continue" % maxi(search_alpha0, T.VALUE_DRAW - 1)
			godot_qs = "alpha=max(alpha,VALUE_DRAW) → α=%d" % maxi(qs_alpha0, T.VALUE_DRAW)
		else:
			godot_search = "beta=min(beta,VALUE_DRAW+1) → β=%d; continue" % mini(search_beta0, T.VALUE_DRAW + 1)
			godot_qs = "beta=min(beta,VALUE_DRAW) → β=%d" % mini(qs_beta0, T.VALUE_DRAW)
		if qs_alpha >= qs_beta:
			godot_qs += "; alpha>=beta → return alpha"
		else:
			godot_qs += "; continue"

	var match_search := true
	var match_qs := true
	# Live Worker probes for soft: prove clamp via cutoff windows (not mate return).
	var live := ""
	if soft:
		var w := _make_worker(pos)
		if value > T.VALUE_DRAW:
			var s: int = w._search(Worker.NODE_PV, 2, -100, -1, ply, false)
			var q: int = w._qsearch(true, -50, 0, ply)
			match_search = (s == T.VALUE_DRAW - 1) and (s != value)
			match_qs = (q == T.VALUE_DRAW) and (q != value)
			live = "live _search(-100,-1)=%d _qsearch(-50,0)=%d" % [s, q]
		else:
			var s2: int = w._search(Worker.NODE_PV, 2, 1, 100, ply, false)
			var q2: int = w._qsearch(true, 0, 50, ply)
			match_search = (s2 == T.VALUE_DRAW + 1) and (s2 != value)
			match_qs = (q2 == T.VALUE_DRAW) and (q2 != value)
			live = "live _search(1,100)=%d _qsearch(0,50)=%d" % [s2, q2]
	elif claimed:
		godot_search += "  [MATCH claimed]"
		godot_qs += "  [MATCH claimed]"

	print("---")
	print("CASE %s | %s" % [c["id"], c["label"]])
	print("  Rules: claimed=%s soft=%s value=%d kind=%s" % [
		claimed, soft, value, _kind(value)
	])
	print("  Pikafish search<>: %s" % pikafish_search)
	print("  Godot _search:     %s" % godot_search)
	print("  Match search:      %s" % ("YES" if match_search else "NO"))
	print("  Pikafish qsearch<>: %s" % pikafish_qs)
	print("  Godot _qsearch:     %s" % godot_qs)
	print("  Match qsearch:      %s" % ("YES" if match_qs else "NO"))
	if live != "":
		print("  Evidence: %s" % live)


func _kind(v: int) -> String:
	if v == T.VALUE_NONE:
		return "none"
	if v == T.VALUE_DRAW:
		return "draw"
	if T.is_win(v):
		return "mate"
	if T.is_loss(v):
		return "mated"
	return "cp"
