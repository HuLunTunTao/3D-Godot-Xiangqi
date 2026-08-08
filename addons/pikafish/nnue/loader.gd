## Loads pikafish NNUE weights (GPU blobs from tools/parse_nnue.py) and feature tables.
## Keeps everything as raw PackedByteArray (no slow bulk GDScript decode); accessors decode on demand.
## GPU uploads the raw bytes directly.
##
## GDS-DIVERGENCE: PLATFORM
## C++ behavior: weights loaded from EvalFile filesystem path.
## GDScript replacement: FileAccess on res:// (or configured) network_dir for PCK.
## Proof: mobile PCK export + oracle; never use globalize_path for runtime weights.
class_name PikafishNnueLoader
extends RefCounted
const C = preload("res://addons/pikafish/nnue/consts.gd")

# Feature transformer (raw bytes)
var ft_bias_raw: PackedByteArray      # i16[1024]
var ft_bias_i32: PackedByteArray      # i32[1024] (for GPU)
var ft_psq_w: PackedByteArray         # i8[PSQ_DIM * L1]
var ft_psqt_raw: PackedByteArray      # i32[PSQ_DIM * PSQTBuckets]
var ft_threat_w: PackedByteArray      # i8[THREAT_DIM * L1]
var ft_threat_psqt_raw: PackedByteArray  # i32[THREAT_DIM * PSQTBuckets]

# 16 network stacks (raw bytes)
var fc0_w: Array = []      # PackedByteArray i8[32*1024]
var fc0_bias_raw: Array = []  # PackedByteArray i32[32]
var fc1_w: Array = []
var fc1_bias_raw: Array = []
var fc2_w: Array = []
var fc2_bias_raw: Array = []

# Feature tables
var psq_offsets: PackedInt32Array       # [16*90], -1 if invalid
var threat_offsets: PackedByteArray     # u16[16*90*90*16] LE; 0xFFFF == invalid

var loaded: bool = false
var network_dir: String = "res://data"
var load_error: String = ""
var manifest: Dictionary = {}


func _read_bytes(name: String) -> PackedByteArray:
	# Keep the res:// path intact so FileAccess can read files embedded in a PCK.
	var path := network_dir.path_join(name)
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		load_error = "cannot open " + path
		return PackedByteArray()
	var b := f.get_buffer(f.get_length())
	f.close()
	return b


func _expect_size(name: String, data: PackedByteArray, expected: int) -> bool:
	if data.is_empty():
		return false
	if expected > 0 and data.size() != expected:
		load_error = "%s size %d != expected %d" % [name, data.size(), expected]
		return false
	return true


func load_all(dir: String = "") -> Error:
	if not dir.is_empty():
		network_dir = dir
	load_error = ""
	loaded = false
	fc0_w.clear()
	fc0_bias_raw.clear()
	fc1_w.clear()
	fc1_bias_raw.clear()
	fc2_w.clear()
	fc2_bias_raw.clear()

	var manifest_path := network_dir.path_join("manifest.json")
	var mf := FileAccess.open(manifest_path, FileAccess.READ)
	if mf == null:
		load_error = "missing manifest: " + manifest_path
		return ERR_FILE_NOT_FOUND
	var parsed = JSON.parse_string(mf.get_as_text())
	mf.close()
	if typeof(parsed) != TYPE_DICTIONARY:
		load_error = "invalid manifest JSON"
		return ERR_FILE_CORRUPT
	manifest = parsed

	ft_bias_raw = _read_bytes("ft_bias.bin")
	if not _expect_size("ft_bias.bin", ft_bias_raw, C.L1 * 2):
		return ERR_FILE_CORRUPT
	ft_psq_w = _read_bytes("ft_psqW.bin")
	if ft_psq_w.is_empty():
		return ERR_FILE_CORRUPT
	ft_psqt_raw = _read_bytes("ft_psqt.bin")
	if ft_psqt_raw.is_empty():
		return ERR_FILE_CORRUPT
	ft_threat_w = _read_bytes("ft_threatW.bin")
	if ft_threat_w.is_empty():
		return ERR_FILE_CORRUPT
	ft_threat_psqt_raw = _read_bytes("ft_threatPsqt.bin")
	if ft_threat_psqt_raw.is_empty():
		return ERR_FILE_CORRUPT
	# build i32 bias for GPU (1024 conversions)
	ft_bias_i32 = PackedByteArray()
	ft_bias_i32.resize(C.L1 * 4)
	for i in range(C.L1):
		ft_bias_i32.encode_s32(i * 4, ft_bias_raw.decode_s16(i * 2))

	for s in range(C.LAYERSTACKS):
		var pre := "stack%02d" % s
		var w0 := _read_bytes(pre + "_fc0_w.bin")
		var b0 := _read_bytes(pre + "_fc0_bias.bin")
		var w1 := _read_bytes(pre + "_fc1_w.bin")
		var b1 := _read_bytes(pre + "_fc1_bias.bin")
		var w2 := _read_bytes(pre + "_fc2_w.bin")
		var b2 := _read_bytes(pre + "_fc2_bias.bin")
		if w0.is_empty() or b0.is_empty() or w1.is_empty() or b1.is_empty() or w2.is_empty() or b2.is_empty():
			return ERR_FILE_CORRUPT
		fc0_w.append(w0)
		fc0_bias_raw.append(b0)
		fc1_w.append(w1)
		fc1_bias_raw.append(b1)
		fc2_w.append(w2)
		fc2_bias_raw.append(b2)

	# psq_offsets: u16[16*90] -> PackedInt32Array, 0xFFFF -> -1 (small, fast)
	var raw := _read_bytes("psq_offsets.bin")
	if not _expect_size("psq_offsets.bin", raw, 16 * 90 * 2):
		return ERR_FILE_CORRUPT
	psq_offsets = PackedInt32Array()
	psq_offsets.resize(16 * 90)
	for i in range(16 * 90):
		var v := raw[i * 2] | (raw[i * 2 + 1] << 8)
		psq_offsets[i] = -1 if v == 0xFFFF else v

	threat_offsets = _read_bytes("threat_offsets.bin")
	if threat_offsets.is_empty():
		return ERR_FILE_CORRUPT
	loaded = true
	return OK


# ---- accessors ----
static func get_i8(arr: PackedByteArray, idx: int) -> int:
	var b := arr[idx]
	return b if b < 128 else b - 256


static func get_i32(arr: PackedByteArray, idx: int) -> int:
	return arr.decode_s32(idx * 4)


func psq_offset(pc: int, sq: int) -> int:
	return psq_offsets[pc * 90 + sq]


func threat_offset(a: int, frm: int, to: int, atk: int) -> int:
	var idx := ((a * 90 + frm) * 90 + to) * 16 + atk
	var off := idx * 2
	return threat_offsets[off] | (threat_offsets[off + 1] << 8)
