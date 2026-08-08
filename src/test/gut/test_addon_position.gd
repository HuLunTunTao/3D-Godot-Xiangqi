extends GutTest

const T = preload("res://addons/pikafish/core/types.gd")
const Z = preload("res://addons/pikafish/core/zobrist.gd")
const Pos = preload("res://addons/pikafish/core/position.gd")
const MG = preload("res://addons/pikafish/core/movegen.gd")

const START_FEN := "rnbakabnr/9/1c5c1/p1p1p1p1p/9/9/P1P1P1P1P/1C5C1/9/RNBAKABNR w - - 0 1"
const START_KEY_HEX := "FDA3193C470C785C"


func before_all() -> void:
	Z.init_keys()


func test_startpos_key() -> void:
	var pos = Pos.new()
	assert_eq(pos.set_fen(START_FEN), OK)
	assert_eq(pos.raw_key(), Z.hex_to_i64(START_KEY_HEX), "startpos zobrist key")


func test_startpos_fen_roundtrip() -> void:
	var pos = Pos.new()
	assert_eq(pos.set_fen(START_FEN), OK)
	var fen := pos.get_fen()
	assert_true(fen.begins_with("rnbakabnr/9/1c5c1/p1p1p1p1p/9/9/P1P1P1P1P/1C5C1/9/RNBAKABNR"))
	assert_true(fen.contains(" w "))


func test_startpos_legal_moves_match_fixture() -> void:
	var f := FileAccess.open("res://fixtures/core/startpos.json", FileAccess.READ)
	var data: Dictionary = JSON.parse_string(f.get_as_text())
	var want: Array = []
	for v in data["legal"]["moves_raw"]:
		want.append(int(v))
	want.sort()
	var pos = Pos.new()
	assert_eq(pos.set_fen(START_FEN), OK)
	var buf := PackedInt32Array()
	buf.resize(T.MAX_MOVES)
	var n := MG.generate(pos, MG.GEN_LEGAL, buf)
	var got: Array = []
	for i in range(n):
		got.append(buf[i])
	got.sort()
	assert_eq(n, 44)
	assert_eq(got, want)


func test_do_undo_restores_key_and_fen() -> void:
	var pos = Pos.new()
	assert_eq(pos.set_fen(START_FEN), OK)
	var k0 := pos.raw_key()
	var fen0 := pos.get_fen()
	var buf := PackedInt32Array()
	buf.resize(T.MAX_MOVES)
	var n := MG.generate(pos, MG.GEN_LEGAL, buf)
	assert_gt(n, 0)
	pos.do_move(buf[0])
	assert_ne(pos.raw_key(), k0)
	pos.undo_move(buf[0])
	assert_eq(pos.raw_key(), k0)
	assert_eq(pos.get_fen(), fen0)


func test_perft_depth_1_and_2() -> void:
	var pos = Pos.new()
	assert_eq(pos.set_fen(START_FEN), OK)
	assert_eq(MG.perft(pos, 1), 44)
	assert_eq(MG.perft(pos, 2), 1920)


func test_checkers_empty_at_startpos() -> void:
	var pos = Pos.new()
	assert_eq(pos.set_fen(START_FEN), OK)
	var c := pos.checkers()
	assert_eq(c[0], 0)
	assert_eq(c[1], 0)
