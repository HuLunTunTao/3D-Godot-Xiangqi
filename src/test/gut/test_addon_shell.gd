extends GutTest

## Phase A: addon facade, types, fixtures, and deprecated XNnueEngine wrapper.

const PikafishEngineScript = preload("res://addons/pikafish/pikafish.gd")
const PikafishConfigScript = preload("res://addons/pikafish/config.gd")
const LimitsScript = preload("res://addons/pikafish/search/limits.gd")
const Types = preload("res://addons/pikafish/core/types.gd")
const NNUELoader = preload("res://src/nnue/nnue_loader.gd")
const XFeatures = preload("res://src/nnue/features.gd")
const XNnueEngine = preload("res://src/nnue/nnue_engine.gd")
const S = preload("res://src/test/gut/nnue_test_support.gd")

const START_FEN := "rnbakabnr/9/1c5c1/p1p1p1p1p/9/9/P1P1P1P1P/1C5C1/9/RNBAKABNR w - - 0 1"


func test_plugin_cfg_exists() -> void:
	assert_true(FileAccess.file_exists("res://addons/pikafish/plugin.cfg"))


func test_types_move_encoding_matches_upstream() -> void:
	# Upstream Move(Square from, Square to): (from << 7) + to; a3a4
	var a3 := 0 + 3 * 9
	var a4 := 0 + 4 * 9
	var mv := Types.make_move(a3, a4)
	assert_eq(mv, (a3 << 7) | a4)
	assert_eq(Types.from_sq(mv), a3)
	assert_eq(Types.to_sq(mv), a4)
	assert_eq(Types.MOVE_NONE, 0)
	assert_eq(Types.MOVE_NULL, 129)
	assert_eq(Types.MAX_MOVES, 128)
	assert_eq(Types.MAX_PLY, 246)


func test_engine_initialize_and_backend_info() -> void:
	var engine = PikafishEngineScript.new()
	var cfg = PikafishConfigScript.new()
	cfg.network_dir = "res://data"
	assert_eq(engine.initialize(cfg), OK)
	var info: Dictionary = engine.backend_info()
	assert_true(info["initialized"])
	assert_true(info["loaded"])
	assert_true(info["backend"] == "gpu" or info["backend"] == "cpu")
	assert_eq(engine.set_fen(START_FEN), OK)
	assert_eq(engine.get_fen(), START_FEN)
	assert_eq(engine.legal_moves().size(), 44)
	engine.shutdown()


func test_uci_move_helpers() -> void:
	var engine = PikafishEngineScript.new()
	assert_eq(engine.initialize(PikafishConfigScript.new()), OK)
	var mv: int = engine.move_from_uci("a3a4")
	assert_true(Types.move_is_ok(mv))
	assert_eq(engine.move_to_uci(mv), "a3a4")
	engine.shutdown()


func test_startpos_fixture_format() -> void:
	var path := "res://fixtures/core/startpos.json"
	assert_true(FileAccess.file_exists(path), "run tools/gen_core_fixtures.py")
	var f := FileAccess.open(path, FileAccess.READ)
	var fx: Dictionary = JSON.parse_string(f.get_as_text())
	f.close()
	assert_eq(fx["upstream_sha"], "2c5c998c211d524d26c38e7e3e71d51bc24cbe64")
	assert_eq(fx["fen"], START_FEN)
	assert_eq(int(fx["legal"]["count"]), 44)
	assert_eq(fx["legal"]["moves_raw"].size(), 44)
	assert_eq(int(fx["perft"]["1"]["nodes"]), 44)
	assert_true(int(fx["perft"]["5"]["nodes"]) > 0)
	# Encode round-trip for first legal move
	var raw0: int = int(fx["legal"]["moves_raw"][0])
	var engine = PikafishEngineScript.new()
	assert_eq(engine.initialize(PikafishConfigScript.new()), OK)
	var uci0: String = fx["legal"]["moves_uci"][0]
	assert_eq(engine.move_from_uci(uci0), raw0)
	assert_eq(engine.move_to_uci(raw0), uci0)
	engine.shutdown()


func test_xnue_wrapper_forwards_to_addon() -> void:
	var loader := NNUELoader.new()
	assert_eq(loader.load_all("res://data"), OK)
	var engine = XNnueEngine.new(loader, XFeatures.new(loader))
	assert_true(engine.backend_name == "gpu" or engine.backend_name == "cpu")
	var f := FileAccess.open("res://data/reference.json", FileAccess.READ)
	var ref_data: Array = JSON.parse_string(f.get_as_text())
	f.close()
	var b = S.board_from_fen(ref_data[0]["fen"])
	assert_true(absi(engine.evaluate(b) - int(ref_data[0]["internal"])) <= 1)
	var batch: PackedInt32Array = engine.evaluate_batch([b])
	assert_eq(batch.size(), 1)
	assert_true(absi(batch[0] - int(ref_data[0]["internal"])) <= 1)
