class_name PikafishZobrist
extends RefCounted

## Upstream: Pikafish 2c5c998c, Position::init — PRNG(1070372)
## Keys loaded from hex strings (JSON numbers are not int64-safe).

const T = preload("res://addons/pikafish/core/types.gd")

static var _ready := false
static var psq: Array = []  # [16][90] int
static var side: int = 0
static var no_pawns: int = 0


static func hex_to_i64(h: String) -> int:
	## Parse 16-hex-digit u64 into signed int64 bit pattern.
	var hi32 := ("0x" + h.substr(0, 8)).hex_to_int()
	var lo32 := ("0x" + h.substr(8, 8)).hex_to_int()
	return (hi32 << 32) | (lo32 & 0xFFFFFFFF)


static func init_keys() -> void:
	if _ready:
		return
	var path := "res://fixtures/core/zobrist.json"
	var f := FileAccess.open(path, FileAccess.READ)
	assert(f != null, "missing zobrist fixture")
	var data: Dictionary = JSON.parse_string(f.get_as_text())
	side = hex_to_i64(str(data["side_hex"]))
	no_pawns = hex_to_i64(str(data["no_pawns_hex"]))
	psq = []
	psq.resize(T.PIECE_NB)
	var raw: Array = data["psq_hex"]
	for pc in range(T.PIECE_NB):
		var row: Array = []
		row.resize(T.SQUARE_NB)
		for s in range(T.SQUARE_NB):
			row[s] = hex_to_i64(str(raw[pc][s]))
		psq[pc] = row
	_ready = true


static func psq_key(pc: int, s: int) -> int:
	init_keys()
	return psq[pc][s]


static func side_key() -> int:
	init_keys()
	return side


static func no_pawns_key() -> int:
	init_keys()
	return no_pawns


static func make_key(seed: int) -> int:
	return seed * 6364136223846793005 + 1442695040888963407
