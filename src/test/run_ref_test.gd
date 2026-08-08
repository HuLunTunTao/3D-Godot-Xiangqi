extends SceneTree

## Headless test runner: load weights, run GDScript reference inference on all
## reference FENs, compare to the pikafish oracle internal integer.
## Usage: godot --headless -s res://src/test/run_ref_test.gd

const NNUELoader = preload("res://src/nnue/nnue_loader.gd")
const XFeatures = preload("res://src/nnue/features.gd")
const XRefInference = preload("res://src/nnue/ref_inference.gd")
const XBoard = preload("res://src/nnue/board.gd")

var _logf: FileAccess


func _log(s: String) -> void:
	_logf.store_line(s)
	_logf.flush()


func _init() -> void:
	_logf = FileAccess.open("/tmp/gd_progress.txt", FileAccess.WRITE)
	_log("start")
	var t0 := Time.get_ticks_msec()
	var loader: NNUELoader = NNUELoader.new()
	loader.load_all()
	var features: XFeatures = XFeatures.new(loader)
	var inf: XRefInference = XRefInference.new(loader, features)
	var load_ms := Time.get_ticks_msec() - t0
	_log("load+init: %d ms" % load_ms)

	var ref_data: Array = _load_reference()
	var arg := OS.get_cmdline_user_args()
	var limit := ref_data.size()
	if arg.size() > 0:
		limit = mini(int(arg[0]), limit)
	var ok := 0
	var bad := 0
	var worst := 0
	for idx in range(limit):
		var rec = ref_data[idx]
		var board: XBoard = XBoard.new()
		board.load_fen(rec["fen"])
		var t1 := Time.get_ticks_msec()
		var got: int = inf.evaluate(board)
		var ms := Time.get_ticks_msec() - t1
		var want: int = int(rec["internal"])
		var diff: int = absi(got - want)
		var status := "OK "
		if diff <= 1:
			ok += 1
		else:
			bad += 1
			status = "FAIL"
			if diff > worst:
				worst = diff
		_log("%s [%2d] stm=%s got=%+d want=%+d diff=%d %dms  %s" % [status, idx, rec["stm"], got, want, diff, ms, rec["fen"].substr(0, 38)])

	_log("result: ok=%d bad=%d worst_diff=%d" % [ok, bad, worst])
	_logf.close()
	quit(0 if bad == 0 else 1)


func _load_reference() -> Array:
	var f := FileAccess.open("res://data/reference.json", FileAccess.READ)
	assert(f != null, "cannot open reference.json")
	var text := f.get_as_text()
	f.close()
	return JSON.parse_string(text)
