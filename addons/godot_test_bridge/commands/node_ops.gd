extends RefCounted

## Node operation commands: get_property, set_property, call_method, click_control

var bridge: Node


func execute(method: String, params: Dictionary) -> Dictionary:
	match method:
		"get_property":
			return _get_property(params)
		"set_property":
			return _set_property(params)
		"call_method":
			return _call_method(params)
		"click_control":
			return _click_control(params)
	return {"error": {"code": -32601, "message": "Unknown method: %s" % method}}


func _get_property(params: Dictionary) -> Dictionary:
	var node_path: String = params.get("node_path", "")
	var property: String = params.get("property", "")

	if node_path == "" or property == "":
		return {"error": {"code": -32602, "message": "Missing required params: node_path, property"}}

	var node = bridge.get_node_or_null(node_path)
	if not node:
		return {"error": {"code": -32000, "message": "Node not found: %s" % node_path}}

	var value = node.get(property)
	return {"result": {"value": _serialize_value(value), "property": property, "node_path": node_path}}


func _set_property(params: Dictionary) -> Dictionary:
	var node_path: String = params.get("node_path", "")
	var property: String = params.get("property", "")

	if node_path == "" or not params.has("value"):
		return {"error": {"code": -32602, "message": "Missing required params: node_path, property, value"}}
	if property == "":
		return {"error": {"code": -32602, "message": "Missing required param: property"}}

	var node = bridge.get_node_or_null(node_path)
	if not node:
		return {"error": {"code": -32000, "message": "Node not found: %s" % node_path}}

	var value = params.get("value")

	# Type coercion: try to match the existing property type
	var current = node.get(property)
	value = _coerce_value(value, current)

	node.set(property, value)
	return {"result": {"success": true, "node_path": node_path, "property": property}}


func _call_method(params: Dictionary) -> Dictionary:
	var node_path: String = params.get("node_path", "")
	var method_name: String = params.get("method", "")
	var args: Array = params.get("args", [])

	if node_path == "" or method_name == "":
		return {"error": {"code": -32602, "message": "Missing required params: node_path, method"}}

	var node = bridge.get_node_or_null(node_path)
	if not node:
		return {"error": {"code": -32000, "message": "Node not found: %s" % node_path}}

	if not node.has_method(method_name):
		return {"error": {"code": -32000, "message": "Method not found: %s on %s" % [method_name, node_path]}}

	# Coerce args to match method parameter types
	var converted_args = _coerce_method_args(node, method_name, args)

	var result = node.callv(method_name, converted_args)
	return {"result": {"return_value": _serialize_value(result), "method": method_name, "node_path": node_path}}


func _click_control(params: Dictionary) -> Dictionary:
	var node_path: String = params.get("node_path", "")
	# "force_synthetic" only when direct is explicitly set to false
	var force_synthetic = params.has("direct") and params.get("direct") == false

	if node_path == "":
		return {"error": {"code": -32602, "message": "Missing required param: node_path"}}

	var node = bridge.get_node_or_null(node_path)
	if not node:
		return {"error": {"code": -32000, "message": "Node not found: %s" % node_path}}

	if not node is Control:
		return {"error": {"code": -32000, "message": "Node is not a Control: %s (%s)" % [node_path, node.get_class()]}}

	# BaseButton: always emit_signal unless explicitly forced to synthetic
	if node is BaseButton and not force_synthetic:
		node.emit_signal("pressed")
		return {"result": {"success": true, "method": "direct_signal", "node_path": node_path}}

	# Explicit direct=true for non-button controls: grab focus
	if params.get("direct") == true:
		node.grab_focus()
		return {"result": {"success": true, "method": "grab_focus", "node_path": node_path}}

	# Synthetic click — prefer a script-defined _gui_input handler when available.
	var control: Control = node as Control
	var rect = control.get_global_rect()
	var center = rect.position + rect.size / 2.0
	var local_center = center - control.global_position

	var press = InputEventMouseButton.new()
	press.position = local_center
	press.global_position = center
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.button_mask = MOUSE_BUTTON_MASK_LEFT
	var method = _dispatch_control_mouse_event(control, press)

	var release = InputEventMouseButton.new()
	release.position = local_center
	release.global_position = center
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	release.button_mask = 0
	_dispatch_control_mouse_event(control, release)

	return {"result": {"success": true, "method": method, "position": {"x": center.x, "y": center.y}, "node_path": node_path}}


func _dispatch_control_mouse_event(control: Control, event: InputEvent) -> String:
	if control.has_method("_gui_input"):
		control.call("_gui_input", event)
		return "script_gui_input"

	control.gui_input.emit(event)
	return "gui_input_signal"


func _coerce_value(value: Variant, reference: Variant) -> Variant:
	if reference == null:
		return value
	if reference is Vector2 and value is Dictionary:
		return Vector2(value.get("x", 0.0), value.get("y", 0.0))
	if reference is Vector2i and value is Dictionary:
		return Vector2i(int(value.get("x", 0)), int(value.get("y", 0)))
	if reference is Vector3 and value is Dictionary:
		return Vector3(value.get("x", 0.0), value.get("y", 0.0), value.get("z", 0.0))
	if reference is Vector3i and value is Dictionary:
		return Vector3i(int(value.get("x", 0)), int(value.get("y", 0)), int(value.get("z", 0)))
	if reference is Rect2 and value is Dictionary:
		return Rect2(value.get("x", 0.0), value.get("y", 0.0), value.get("w", 0.0), value.get("h", 0.0))
	if reference is Rect2i and value is Dictionary:
		return Rect2i(int(value.get("x", 0)), int(value.get("y", 0)), int(value.get("w", 0)), int(value.get("h", 0)))
	if reference is Color and value is Dictionary:
		return Color(value.get("r", 0.0), value.get("g", 0.0), value.get("b", 0.0), value.get("a", 1.0))
	if reference is Color and value is String:
		return Color(value)
	if reference is int and value is float:
		return int(value)
	if reference is float and value is int:
		return float(value)
	if reference is NodePath and value is String:
		return NodePath(value)
	return value


func _coerce_method_args(node: Node, method_name: String, args: Array) -> Array:
	# Find the method in class_get_method_list() and extract its argument types
	var methods = ClassDB.class_get_method_list(node.get_class())
	var method_info: Dictionary = {}
	for m in methods:
		if m.get("name", "") == method_name:
			method_info = m
			break
	if method_info.is_empty():
		return args

	var method_args: Array = method_info.get("args", [])
	if method_args.size() != args.size():
		return args

	var converted: Array = []
	for i in range(args.size()):
		var arg = args[i]
		var expected_type: int = method_args[i].get("type", TYPE_NIL)
		converted.append(_coerce_arg_by_type(arg, expected_type))
	return converted


func _coerce_arg_by_type(value: Variant, type: int) -> Variant:
	match type:
		TYPE_VECTOR2I:
			if value is Dictionary:
				return Vector2i(int(value.get("x", 0)), int(value.get("y", 0)))
		TYPE_VECTOR2:
			if value is Dictionary:
				return Vector2(value.get("x", 0.0), value.get("y", 0.0))
		TYPE_VECTOR3I:
			if value is Dictionary:
				return Vector3i(int(value.get("x", 0)), int(value.get("y", 0)), int(value.get("z", 0)))
		TYPE_VECTOR3:
			if value is Dictionary:
				return Vector3(value.get("x", 0.0), value.get("y", 0.0), value.get("z", 0.0))
		TYPE_RECT2I:
			if value is Dictionary:
				return Rect2i(int(value.get("x", 0)), int(value.get("y", 0)), int(value.get("w", 0)), int(value.get("h", 0)))
		TYPE_RECT2:
			if value is Dictionary:
				return Rect2(value.get("x", 0.0), value.get("y", 0.0), value.get("w", 0.0), value.get("h", 0.0))
		TYPE_COLOR:
			if value is Dictionary:
				return Color(value.get("r", 0.0), value.get("g", 0.0), value.get("b", 0.0), value.get("a", 1.0))
			if value is String:
				return Color(value)
		TYPE_INT:
			if value is float:
				return int(value)
		TYPE_FLOAT:
			if value is int:
				return float(value)
		TYPE_NODE_PATH:
			if value is String:
				return NodePath(value)
	return value


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
