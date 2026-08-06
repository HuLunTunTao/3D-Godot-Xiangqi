extends RefCounted

## Input simulation commands.
##
## Due to Godot 4.3+ regression (godotengine/godot#89757), Viewport.push_input()
## does NOT trigger _gui_input for MouseMotion events. This means push_input
## cannot reliably simulate clicks on Control nodes.
##
## Strategy:
## - For mouse events: find the target Control at the position and dispatch the
##   event as close as possible to the control's own handler chain.
##   BaseButton uses a direct pressed shortcut; scripted controls prefer calling
##   their script-defined _gui_input(event); plain controls fall back to
##   emitting gui_input. Non-GUI nodes still use push_input.
## - For keyboard/action events: push_input works fine (no GUI routing issue).
## - click_control: BaseButton → emit "pressed" signal; other Control → control dispatch.
##
## No real cursor movement occurs. Supports background windows and multi-project.

var bridge: Node

var _key_map: Dictionary = {}


func _init() -> void:
	_key_map = {
		"space": KEY_SPACE, "enter": KEY_ENTER, "return": KEY_ENTER,
		"escape": KEY_ESCAPE, "esc": KEY_ESCAPE, "tab": KEY_TAB,
		"backspace": KEY_BACKSPACE, "delete": KEY_DELETE,
		"up": KEY_UP, "down": KEY_DOWN, "left": KEY_LEFT, "right": KEY_RIGHT,
		"shift": KEY_SHIFT, "ctrl": KEY_CTRL, "control": KEY_CTRL,
		"alt": KEY_ALT, "meta": KEY_META, "super": KEY_META, "cmd": KEY_META,
		"a": KEY_A, "b": KEY_B, "c": KEY_C, "d": KEY_D, "e": KEY_E,
		"f": KEY_F, "g": KEY_G, "h": KEY_H, "i": KEY_I, "j": KEY_J,
		"k": KEY_K, "l": KEY_L, "m": KEY_M, "n": KEY_N, "o": KEY_O,
		"p": KEY_P, "q": KEY_Q, "r": KEY_R, "s": KEY_S, "t": KEY_T,
		"u": KEY_U, "v": KEY_V, "w": KEY_W, "x": KEY_X, "y": KEY_Y,
		"z": KEY_Z,
		"0": KEY_0, "1": KEY_1, "2": KEY_2, "3": KEY_3, "4": KEY_4,
		"5": KEY_5, "6": KEY_6, "7": KEY_7, "8": KEY_8, "9": KEY_9,
		"f1": KEY_F1, "f2": KEY_F2, "f3": KEY_F3, "f4": KEY_F4,
		"f5": KEY_F5, "f6": KEY_F6, "f7": KEY_F7, "f8": KEY_F8,
		"f9": KEY_F9, "f10": KEY_F10, "f11": KEY_F11, "f12": KEY_F12,
		"minus": KEY_MINUS, "equal": KEY_EQUAL, "plus": KEY_EQUAL,
		"comma": KEY_COMMA, "period": KEY_PERIOD, "dot": KEY_PERIOD,
		"slash": KEY_SLASH, "semicolon": KEY_SEMICOLON,
	}


func execute(method: String, params: Dictionary) -> Dictionary:
	match method:
		"mouse_click":
			return _mouse_click(params)
		"mouse_move":
			return _mouse_move(params)
		"mouse_drag":
			return _mouse_drag(params)
		"key_press":
			return _key_press(params)
		"key_release":
			return _key_release(params)
		"key_type":
			return _key_type(params)
		"action_press":
			return _action_press(params)
		"action_release":
			return _action_release(params)
	return {"error": {"code": -32601, "message": "Unknown method: %s" % method}}


# ─── GUI hit testing ───

## Find the topmost visible Control at a screen position that accepts mouse input.
## Traverses the tree in reverse child order (last child = drawn on top = highest priority).
## Respects CanvasLayer ordering and mouse_filter.
func _find_control_at(position: Vector2) -> Control:
	var root = bridge.get_tree().root
	# First check CanvasLayers (sorted by layer, highest first)
	var layers: Array = []
	_collect_canvas_layers(root, layers)
	layers.sort_custom(func(a, b): return a.layer > b.layer)

	for layer in layers:
		var result = _hit_test_children(layer, position)
		if result:
			return result

	# Then check nodes directly under root (default canvas)
	return _hit_test_children(root, position)


func _collect_canvas_layers(node: Node, layers: Array) -> void:
	for child in node.get_children():
		if child is CanvasLayer:
			layers.append(child)
		_collect_canvas_layers(child, layers)


func _hit_test_children(node: Node, position: Vector2) -> Control:
	# Reverse order: last child is drawn on top
	for i in range(node.get_child_count() - 1, -1, -1):
		var child = node.get_child(i)
		# Skip invisible CanvasItems
		if child is CanvasItem and not child.visible:
			continue
		# Recurse first (children are drawn on top of parents)
		var result = _hit_test_children(child, position)
		if result:
			return result
		# Then check this node
		if child is Control:
			var ctrl: Control = child as Control
			if ctrl.mouse_filter == Control.MOUSE_FILTER_IGNORE:
				continue
			if ctrl.get_global_rect().has_point(position):
				return ctrl
	return null


func _resolve_dispatch_target(control: Control) -> Control:
	var current: Control = control
	while current.mouse_filter == Control.MOUSE_FILTER_PASS and current.get_parent() is Control:
		current = current.get_parent() as Control
	return current


func _dispatch_control_mouse_event(control: Control, event: InputEvent) -> String:
	if control.has_method("_gui_input"):
		control.call("_gui_input", event)
		return "script_gui_input"

	control.gui_input.emit(event)
	return "gui_input_signal"


func _button_mask_for(button: int, pressed: bool) -> int:
	if not pressed:
		return 0
	match button:
		MOUSE_BUTTON_LEFT:
			return MOUSE_BUTTON_MASK_LEFT
		MOUSE_BUTTON_RIGHT:
			return MOUSE_BUTTON_MASK_RIGHT
		MOUSE_BUTTON_MIDDLE:
			return MOUSE_BUTTON_MASK_MIDDLE
	return 0


## Dispatch a click sequence directly to a control.
func _dispatch_click_on_control(control: Control, position: Vector2, button: int, double_click: bool = false) -> String:
	if control is BaseButton and button == MOUSE_BUTTON_LEFT:
		control.emit_signal("pressed")
		return "direct_signal"

	var local_pos = position - control.global_position

	var press = InputEventMouseButton.new()
	press.position = local_pos
	press.global_position = position
	press.button_index = button
	press.pressed = true
	press.double_click = double_click
	press.button_mask = _button_mask_for(button, true)
	var method = _dispatch_control_mouse_event(control, press)

	var release = InputEventMouseButton.new()
	release.position = local_pos
	release.global_position = position
	release.button_index = button
	release.pressed = false
	release.button_mask = _button_mask_for(button, false)
	_dispatch_control_mouse_event(control, release)

	return method


# ─── Mouse commands ───

func _mouse_click(params: Dictionary) -> Dictionary:
	var x = _to_float(params.get("x", 0.0))
	var y = _to_float(params.get("y", 0.0))
	var button = _to_int(params.get("button", MOUSE_BUTTON_LEFT))
	var double_click = _to_bool(params.get("double_click", false))
	var position = Vector2(x, y)

	# Try to find a Control at this position
	var target = _find_control_at(position)
	if target:
		target = _resolve_dispatch_target(target)
		var method = _dispatch_click_on_control(target, position, button, double_click)
		return {"result": {"success": true, "position": {"x": x, "y": y}, "target": str(target.get_path()), "method": method}}

	# No Control found — push_input for non-GUI nodes (_input, _unhandled_input, Area2D etc.)
	var viewport = bridge.get_viewport()
	var press = InputEventMouseButton.new()
	press.position = position
	press.global_position = position
	press.button_index = button
	press.pressed = true
	press.double_click = double_click
	viewport.push_input(press)

	var release = InputEventMouseButton.new()
	release.position = position
	release.global_position = position
	release.button_index = button
	release.pressed = false
	viewport.push_input(release)

	return {"result": {"success": true, "position": {"x": x, "y": y}, "method": "push_input"}}


func _mouse_move(params: Dictionary) -> Dictionary:
	var x = _to_float(params.get("x", 0.0))
	var y = _to_float(params.get("y", 0.0))
	var position = Vector2(x, y)

	var motion = InputEventMouseMotion.new()
	motion.position = position
	motion.global_position = position
	bridge.get_viewport().push_input(motion)
	return {"result": {"success": true, "position": {"x": x, "y": y}}}


func _mouse_drag(params: Dictionary) -> Dictionary:
	var from_x = _to_float(params.get("from_x", 0.0))
	var from_y = _to_float(params.get("from_y", 0.0))
	var to_x = _to_float(params.get("to_x", 0.0))
	var to_y = _to_float(params.get("to_y", 0.0))
	var button = _to_int(params.get("button", MOUSE_BUTTON_LEFT))
	var steps = _to_int(params.get("steps", 10))

	var from = Vector2(from_x, from_y)
	var to = Vector2(to_x, to_y)
	var btn_mask = MOUSE_BUTTON_MASK_LEFT if button == MOUSE_BUTTON_LEFT else MOUSE_BUTTON_MASK_RIGHT

	# Find Control at start position
	var target = _find_control_at(from)

	if target:
		target = _resolve_dispatch_target(target)
		# Press
		var press = InputEventMouseButton.new()
		press.position = from - target.global_position
		press.global_position = from
		press.button_index = button
		press.pressed = true
		press.button_mask = btn_mask
		var method = _dispatch_control_mouse_event(target, press)

		# Drag steps
		var prev_pos = from
		for i in range(1, steps + 1):
			var t = float(i) / float(steps)
			var pos = from.lerp(to, t)
			var drag = InputEventMouseMotion.new()
			drag.position = pos - target.global_position
			drag.global_position = pos
			drag.relative = pos - prev_pos
			drag.button_mask = btn_mask
			method = _dispatch_control_mouse_event(target, drag)
			prev_pos = pos

		# Release
		var release = InputEventMouseButton.new()
		release.position = to - target.global_position
		release.global_position = to
		release.button_index = button
		release.pressed = false
		release.button_mask = _button_mask_for(button, false)
		_dispatch_control_mouse_event(target, release)

		return {"result": {"success": true, "from": {"x": from_x, "y": from_y}, "to": {"x": to_x, "y": to_y}, "target": str(target.get_path()), "method": method}}

	# Fallback: push_input for non-GUI
	var viewport = bridge.get_viewport()

	var press = InputEventMouseButton.new()
	press.position = from
	press.global_position = from
	press.button_index = button
	press.pressed = true
	viewport.push_input(press)

	for i in range(1, steps + 1):
		var t = float(i) / float(steps)
		var pos = from.lerp(to, t)
		var drag = InputEventMouseMotion.new()
		drag.position = pos
		drag.global_position = pos
		drag.button_mask = btn_mask
		viewport.push_input(drag)

	var release = InputEventMouseButton.new()
	release.position = to
	release.global_position = to
	release.button_index = button
	release.pressed = false
	viewport.push_input(release)

	return {"result": {"success": true, "from": {"x": from_x, "y": from_y}, "to": {"x": to_x, "y": to_y}, "method": "push_input"}}


# ─── Keyboard commands (immediate, push_input works fine) ───

func _key_press(params: Dictionary) -> Dictionary:
	var key_name: String = params.get("key", "")
	var shift = _to_bool(params.get("shift", false))
	var ctrl = _to_bool(params.get("ctrl", false))
	var alt = _to_bool(params.get("alt", false))
	var meta = _to_bool(params.get("meta", false))

	var keycode = _resolve_key(key_name)
	if keycode == KEY_NONE:
		return {"error": {"code": -32602, "message": "Unknown key: %s" % key_name}}

	var event = InputEventKey.new()
	event.keycode = keycode
	event.physical_keycode = keycode
	event.pressed = true
	event.shift_pressed = shift
	event.ctrl_pressed = ctrl
	event.alt_pressed = alt
	event.meta_pressed = meta
	bridge.get_viewport().push_input(event)

	return {"result": {"success": true, "key": key_name}}


func _key_release(params: Dictionary) -> Dictionary:
	var key_name: String = params.get("key", "")

	var keycode = _resolve_key(key_name)
	if keycode == KEY_NONE:
		return {"error": {"code": -32602, "message": "Unknown key: %s" % key_name}}

	var event = InputEventKey.new()
	event.keycode = keycode
	event.physical_keycode = keycode
	event.pressed = false
	bridge.get_viewport().push_input(event)

	return {"result": {"success": true, "key": key_name}}


func _key_type(params: Dictionary) -> Dictionary:
	var text: String = params.get("text", "")
	if text == "":
		return {"error": {"code": -32602, "message": "Missing required param: text"}}

	var viewport = bridge.get_viewport()
	for ch in text:
		var key_name = ch.to_lower()
		var keycode = _resolve_key(key_name)
		var is_upper = ch != ch.to_lower()

		if keycode != KEY_NONE:
			var press = InputEventKey.new()
			press.keycode = keycode
			press.physical_keycode = keycode
			press.unicode = ch.unicode_at(0)
			press.pressed = true
			press.shift_pressed = is_upper
			viewport.push_input(press)

			var release = InputEventKey.new()
			release.keycode = keycode
			release.physical_keycode = keycode
			release.unicode = ch.unicode_at(0)
			release.pressed = false
			release.shift_pressed = is_upper
			viewport.push_input(release)

	return {"result": {"success": true, "text": text, "length": text.length()}}


# ─── Action commands (immediate) ───

func _action_press(params: Dictionary) -> Dictionary:
	var action: String = params.get("action", "")
	var strength = _to_float(params.get("strength", 1.0))
	if action == "":
		return {"error": {"code": -32602, "message": "Missing required param: action"}}
	if not InputMap.has_action(action):
		return {"error": {"code": -32000, "message": "Action not found: %s" % action}}

	Input.action_press(action, strength)
	return {"result": {"success": true, "action": action}}


func _action_release(params: Dictionary) -> Dictionary:
	var action: String = params.get("action", "")
	if action == "":
		return {"error": {"code": -32602, "message": "Missing required param: action"}}
	if not InputMap.has_action(action):
		return {"error": {"code": -32000, "message": "Action not found: %s" % action}}

	Input.action_release(action)
	return {"result": {"success": true, "action": action}}


# ─── Key resolution ───

func _resolve_key(key_name: String) -> Key:
	var lower = key_name.to_lower()
	if _key_map.has(lower):
		return _key_map[lower]
	if key_name.length() == 1:
		var code = key_name.to_upper().unicode_at(0)
		if code >= 32 and code <= 126:
			return code as Key
	return KEY_NONE


# ─── Safe type conversion ───

func _to_bool(value) -> bool:
	if value is bool:
		return value
	if value is int:
		return value != 0
	if value is String:
		return value.to_lower() == "true" or value == "1"
	return true if value else false


func _to_int(value) -> int:
	if value is int:
		return value
	if value is float:
		return int(value)
	if value is String:
		return value.to_int()
	return 0


func _to_float(value) -> float:
	if value is float:
		return value
	if value is int:
		return float(value)
	if value is String:
		return value.to_float()
	return 0.0
