extends SceneTree

## Quick perft corpus check (same assertions as test_perft_corpus_depth_1_to_4).
const Z = preload("res://addons/pikafish/core/zobrist.gd")
const Pos = preload("res://addons/pikafish/core/position.gd")
const MG = preload("res://addons/pikafish/core/movegen.gd")
const PERFT_FX := "res://fixtures/core/perft_corpus.json"


func _init() -> void:
	Z.init_keys()
	var f := FileAccess.open(PERFT_FX, FileAccess.READ)
	var fx = JSON.parse_string(f.get_as_text())
	f.close()
	var positions: Array = fx.get("positions", [])
	var pos = Pos.new()
	var d5_checked := 0
	for entry in positions:
		var fen: String = str(entry["fen"])
		var label: String = str(entry.get("label", fen))
		if pos.set_fen(fen) != OK:
			printerr("PERFT_FAIL set_fen " + label)
			quit(1)
			return
		var perft: Dictionary = entry["perft"]
		for d in range(1, 5):
			var key := str(d)
			if not perft.has(key):
				continue
			var want: int = int(perft[key]["nodes"])
			var got: int = MG.perft(pos, d)
			if got != want:
				printerr("PERFT_FAIL %s d=%d want=%d got=%d" % [label, d, want, got])
				quit(1)
				return
		if perft.has("5") and int(perft["5"]["nodes"]) < 500000:
			var want5: int = int(perft["5"]["nodes"])
			var got5: int = MG.perft(pos, 5)
			if got5 != want5:
				printerr("PERFT_FAIL %s d=5 want=%d got=%d" % [label, want5, got5])
				quit(1)
				return
			d5_checked += 1
	print("PERFT_PASS positions=%d d5_checked=%d" % [positions.size(), d5_checked])
	quit(0)
