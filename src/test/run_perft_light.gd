extends SceneTree
const Z = preload("res://addons/pikafish/core/zobrist.gd")
const Pos = preload("res://addons/pikafish/core/position.gd")
const MG = preload("res://addons/pikafish/core/movegen.gd")
func _init():
	Z.init_keys()
	var fx = JSON.parse_string(FileAccess.get_file_as_string("res://fixtures/core/perft_corpus.json"))
	var pos = Pos.new()
	for entry in fx["positions"]:
		var fen = str(entry["fen"])
		var label = str(entry.get("label", fen))
		assert(pos.set_fen(fen) == OK)
		var perft = entry["perft"]
		for d in range(1, 4):
			var key = str(d)
			if not perft.has(key):
				continue
			var want = int(perft[key]["nodes"])
			var got = MG.perft(pos, d)
			if got != want:
				printerr("FAIL %s d=%d want=%d got=%d" % [label, d, want, got])
				quit(1)
				return
	# hard gate
	assert(pos.set_fen("2bak4/9/3a5/p2Np3p/3n1P3/3pc3P/P4r1c1/B2CC2R1/4A4/3AK1B2 b - - 0 1") == OK)
	var n = MG.perft(pos, 3)
	if n != 31825:
		printerr("FAIL ref3 d3 want=31825 got=%d" % n)
		quit(1)
		return
	print("PERFT_LIGHT_PASS positions=%d + ref3_d3" % fx["positions"].size())
	quit(0)
