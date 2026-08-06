extends RefCounted

## Routes JSON-RPC methods to command implementations.

var bridge: Node  # Reference to TestBridge

# Current request context (for async commands)
var current_peer: Object = null  # WebSocketPeer
var current_id: Variant = null

var _scene_tree_cmd: RefCounted
var _input_cmd: RefCounted
var _node_ops_cmd: RefCounted
var _screenshot_cmd: RefCounted
var _signals_cmd: RefCounted

# Method -> command object mapping
var _routes: Dictionary = {}


func _init() -> void:
	_scene_tree_cmd = load("res://addons/godot_test_bridge/commands/scene_tree.gd").new()
	_input_cmd = load("res://addons/godot_test_bridge/commands/input_sim.gd").new()
	_node_ops_cmd = load("res://addons/godot_test_bridge/commands/node_ops.gd").new()
	_screenshot_cmd = load("res://addons/godot_test_bridge/commands/screenshot.gd").new()
	_signals_cmd = load("res://addons/godot_test_bridge/commands/signals.gd").new()

	_routes = {
		# Scene tree
		"get_scene_tree": _scene_tree_cmd,
		"get_node_info": _scene_tree_cmd,
		"find_nodes": _scene_tree_cmd,
		"find_control_by_text": _scene_tree_cmd,
		# Input simulation
		"mouse_click": _input_cmd,
		"mouse_move": _input_cmd,
		"mouse_drag": _input_cmd,
		"key_press": _input_cmd,
		"key_release": _input_cmd,
		"key_type": _input_cmd,
		"action_press": _input_cmd,
		"action_release": _input_cmd,
		# Node operations
		"get_property": _node_ops_cmd,
		"set_property": _node_ops_cmd,
		"call_method": _node_ops_cmd,
		"click_control": _node_ops_cmd,
		# Screenshot
		"capture_screenshot": _screenshot_cmd,
		# Signals
		"watch_signal": _signals_cmd,
		"unwatch_signal": _signals_cmd,
		"get_watched_signals": _signals_cmd,
		# Meta
		"ping": null,
		"get_viewport_size": null,
		"eval_expression": null,
		"eval_script": null,
	}


func execute(method: String, params: Dictionary) -> Dictionary:
	if not _routes.has(method):
		return {"error": {"code": -32601, "message": "Method not found: %s" % method}}

	# Built-in meta methods
	if method == "ping":
		return {"result": {"pong": true, "timestamp": Time.get_unix_time_from_system()}}

	if method == "get_viewport_size":
		var vp = bridge.get_viewport()
		if vp:
			var size = vp.get_visible_rect().size
			return {"result": {"width": size.x, "height": size.y}}
		return {"error": {"code": -32000, "message": "No viewport available"}}

	if method == "eval_expression":
		return _eval_expression(params)

	if method == "eval_script":
		return _eval_script(params)

	var cmd = _routes[method]
	if cmd == null:
		return {"error": {"code": -32603, "message": "Internal error: no handler for %s" % method}}

	# Pass bridge reference for commands that need scene tree access
	cmd.bridge = bridge
	return cmd.execute(method, params)


func _eval_expression(params: Dictionary) -> Dictionary:
	var expression_str: String = params.get("expression", "")
	var base_path: String = params.get("base_node_path", "/root")

	if expression_str == "":
		return {"error": {"code": -32602, "message": "Missing required param: expression"}}

	var base_node = bridge.get_node_or_null(base_path)
	if not base_node:
		return {"error": {"code": -32000, "message": "Base node not found: %s" % base_path}}

	var expr = Expression.new()
	var err = expr.parse(expression_str)
	if err != OK:
		return {"error": {"code": -32000, "message": "Parse error: %s" % expr.get_error_text()}}

	var result = expr.execute([], base_node)
	if expr.has_execute_failed():
		return {"error": {"code": -32000, "message": "Execution error: %s" % expr.get_error_text()}}

	return {"result": {"value": _serialize_value(result), "expression": expression_str}}


func _eval_script(params: Dictionary) -> Dictionary:
	var script_source: String = params.get("script", "")
	var base_path: String = params.get("base_node_path", "/root")

	if script_source == "":
		return {"error": {"code": -32602, "message": "Missing required param: script"}}

	var base_node = bridge.get_node_or_null(base_path)
	if not base_node:
		return {"error": {"code": -32000, "message": "Base node not found: %s" % base_path}}

	# Engine singletons are globally available in GDScript. Re-declaring names such
	# as DisplayServer here would shadow native classes and fail to compile.
	var full_script = "extends RefCounted\n\n"
	full_script += "var _base: Node\n\n"
	full_script += "func _run():\n"
	for line in script_source.split("\n"):
		full_script += "\t" + line + "\n"
	full_script += "\n"

	var script = GDScript.new()
	script.set_source_code(full_script)
	var err = script.reload()
	if err != OK:
		return {"error": {"code": -32000, "message": "Script compile error (code %d)" % err}}

	var instance = script.new()
	instance.set("_base", base_node)

	var result = instance.call("_run")
	# `instance` inherits RefCounted, so it is released automatically when this
	# function returns. Calling `free()` here is illegal and pauses a debug game.

	return {"result": {"value": _serialize_value(result), "script": script_source}}


## Returns a Dictionary of engine singleton names -> objects for use in Expression.
static func _get_engine_singletons() -> Dictionary:
	return {
		"DisplayServer": DisplayServer,
		"Engine": Engine,
		"OS": OS,
		"Input": Input,
		"InputMap": InputMap,
		"ProjectSettings": ProjectSettings,
		"TranslationServer": TranslationServer,
		"IP": IP,
		"Geometry2D": Geometry2D,
		"Geometry3D": Geometry3D,
		"ClassDB": ClassDB,
		"Time": Time,
		"Performance": Performance,
	}


func _serialize_value(value: Variant) -> Variant:
	if value == null:
		return null
	if value is bool or value is int or value is float or value is String:
		return value
	if value is Vector2:
		return {"x": value.x, "y": value.y}
	if value is Vector2i:
		return {"x": value.x, "y": value.y}
	if value is Vector3:
		return {"x": value.x, "y": value.y, "z": value.z}
	if value is Vector3i:
		return {"x": value.x, "y": value.y, "z": value.z}
	if value is Rect2:
		return {"x": value.position.x, "y": value.position.y, "w": value.size.x, "h": value.size.y}
	if value is Rect2i:
		return {"x": value.position.x, "y": value.position.y, "w": value.size.x, "h": value.size.y}
	if value is Color:
		return {"r": value.r, "g": value.g, "b": value.b, "a": value.a}
	if value is NodePath:
		return str(value)
	if value is Array:
		var arr: Array = []
		for item in value:
			arr.append(_serialize_value(item))
		return arr
	if value is Dictionary:
		var dict: Dictionary = {}
		for key in value:
			dict[str(key)] = _serialize_value(value[key])
		return dict
	return var_to_str(value)
