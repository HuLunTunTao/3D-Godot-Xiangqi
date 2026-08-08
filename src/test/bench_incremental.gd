extends SceneTree

## Focused 1000-iteration do/evaluate/undo benchmark for revision comparisons.

const NNUELoader = preload("res://addons/pikafish/nnue/loader.gd")
const XFeatures = preload("res://addons/pikafish/nnue/features.gd")
const XNnueEngine = preload("res://src/test/nnue_test_engine.gd")
const XBoard = preload("res://addons/pikafish/nnue/board.gd")
const TestSupport = preload("res://src/test/gut/nnue_test_support.gd")


func _init() -> void:
	var loader := NNUELoader.new()
	loader.load_all()
	var features := XFeatures.new(loader)
	var engine := XNnueEngine.new(loader, features)
	var records := _load_reference()
	var board := XBoard.new()
	board.load_fen(records[0]["fen"])
	engine.refresh(board)
	var moves: Array = TestSupport.collect_stm_moves(board, features.palace)
	for i in range(10):
		_run_once(engine, board, moves[i % moves.size()])
	var samples := PackedFloat64Array()
	var do_samples := PackedFloat64Array()
	var eval_samples := PackedFloat64Array()
	var undo_samples := PackedFloat64Array()
	for i in range(1000):
		var started := Time.get_ticks_usec()
		var move: Vector2i = moves[i % moves.size()]
		engine.do_move(board, move.x, move.y)
		var after_do := Time.get_ticks_usec()
		engine.evaluate_incremental(board)
		var after_eval := Time.get_ticks_usec()
		engine.undo_move(board)
		var after_undo := Time.get_ticks_usec()
		do_samples.append(float(after_do - started) / 1000.0)
		eval_samples.append(float(after_eval - after_do) / 1000.0)
		undo_samples.append(float(after_undo - after_eval) / 1000.0)
		samples.append(float(after_undo - started) / 1000.0)
	var sorted := Array(samples)
	sorted.sort()
	print("incremental p50=%.3f ms p95=%.3f ms" % [sorted[499], sorted[949]])
	print("phases p50 do=%.3f eval=%.3f undo=%.3f ms" % [
		_median(do_samples), _median(eval_samples), _median(undo_samples)])
	quit()


static func _run_once(engine, board: XBoard, move: Vector2i) -> void:
	engine.do_move(board, move.x, move.y)
	engine.evaluate_incremental(board)
	engine.undo_move(board)


static func _median(values: PackedFloat64Array) -> float:
	var sorted := Array(values)
	sorted.sort()
	return sorted[499]


static func _load_reference() -> Array:
	var file := FileAccess.open("res://data/reference.json", FileAccess.READ)
	var records: Array = JSON.parse_string(file.get_as_text())
	file.close()
	return records
