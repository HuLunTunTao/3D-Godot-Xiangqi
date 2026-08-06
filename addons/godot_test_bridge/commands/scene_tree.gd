extends RefCounted

## Scene tree query commands: get_scene_tree, get_node_info, find_nodes, find_control_by_text

var bridge: Node


func execute(method: String, params: Dictionary) -> Dictionary:
	match method:
		"get_scene_tree":
			return _get_scene_tree(params)
		"get_node_info":
			return _get_node_info(params)
		"find_nodes":
			return _find_nodes(params)
		"find_control_by_text":
			return _find_control_by_text(params)
	return {"error": {"code": -32601, "message": "Unknown method: %s" % method}}


func _get_scene_tree(params: Dictionary) -> Dictionary:
	var root_path: String = params.get("root_path", "/root")
	var max_depth = int(params.get("max_depth", 10))

	var root_node = bridge.get_node_or_null(root_path)
	if not root_node:
		return {"error": {"code": -32000, "message": "Node not found: %s" % root_path}}

	var tree = _serialize_node(root_node, max_depth, 0)
	return {"result": tree}


func _get_node_info(params: Dictionary) -> Dictionary:
	var node_path: String = params.get("node_path", "")
	if node_path == "":
		return {"error": {"code": -32602, "message": "Missing required param: node_path"}}

	var node = bridge.get_node_or_null(node_path)
	if not node:
		return {"error": {"code": -32000, "message": "Node not found: %s" % node_path}}

	var info: Dictionary = {
		"name": node.name,
		"class": node.get_class(),
		"path": str(node.get_path()),
		"child_count": node.get_child_count(),
		"children": [],
	}

	# List children names and types
	for child in node.get_children():
		info["children"].append({
			"name": child.name,
			"class": child.get_class(),
			"path": str(child.get_path()),
		})

	# Common properties based on node type
	var props: Dictionary = {}

	if node is Node2D:
		props["position"] = _vec2_to_dict(node.position)
		props["rotation"] = node.rotation
		props["scale"] = _vec2_to_dict(node.scale)
		props["visible"] = node.visible
		props["global_position"] = _vec2_to_dict(node.global_position)

	if node is Node3D:
		props["position"] = _vec3_to_dict(node.position)
		props["rotation"] = _vec3_to_dict(node.rotation)
		props["scale"] = _vec3_to_dict(node.scale)
		props["visible"] = node.visible
		props["global_position"] = _vec3_to_dict(node.global_position)

	if node is Control:
		props["position"] = _vec2_to_dict(node.position)
		props["size"] = _vec2_to_dict(node.size)
		props["visible"] = node.visible
		props["text"] = node.get("text") if node.get("text") != null else ""
		props["global_position"] = _vec2_to_dict(node.global_position)

	if node is CanvasItem:
		props["modulate"] = _color_to_dict(node.modulate)

	# Exported properties
	var exported: Dictionary = {}
	for prop in node.get_property_list():
		if prop["usage"] & PROPERTY_USAGE_SCRIPT_VARIABLE:
			var val = node.get(prop["name"])
			exported[prop["name"]] = _serialize_value(val)
	if exported.size() > 0:
		props["exported"] = exported

	# Signals list
	var signals_list: Array = []
	for sig in node.get_signal_list():
		signals_list.append(sig["name"])
	props["signals"] = signals_list

	info["properties"] = props
	return {"result": info}


func _find_nodes(params: Dictionary) -> Dictionary:
	var selector: Dictionary = params.get("selector", {})
	if not selector is Dictionary:
		return {"error": {"code": -32602, "message": "selector must be a Dictionary"}}

	var root_path: String = params.get("root_path", "/root")
	var limit: int = int(params.get("limit", 50))
	if limit <= 0:
		limit = 50

	var root_node = bridge.get_node_or_null(root_path)
	if not root_node:
		return {"error": {"code": -32000, "message": "Node not found: %s" % root_path}}

	var matches: Array = []
	_collect_matching_nodes(root_node, selector, matches, limit)
	return {
		"result": {
			"nodes": matches,
			"count": matches.size(),
			"selector": selector,
			"root_path": root_path,
		}
	}


func _find_control_by_text(params: Dictionary) -> Dictionary:
	var text: String = str(params.get("text", ""))
	if text == "":
		return {"error": {"code": -32602, "message": "Missing required param: text"}}

	var root_path: String = params.get("root_path", "/root")
	var limit: int = int(params.get("limit", 20))
	if limit <= 0:
		limit = 20

	var selector: Dictionary = {
		"class": "Control",
		"text": text,
	}
	if params.has("visible"):
		selector["visible"] = params.get("visible")

	var root_node = bridge.get_node_or_null(root_path)
	if not root_node:
		return {"error": {"code": -32000, "message": "Node not found: %s" % root_path}}

	var matches: Array = []
	_collect_matching_nodes(root_node, selector, matches, limit)
	return {
		"result": {
			"nodes": matches,
			"count": matches.size(),
			"text": text,
			"root_path": root_path,
		}
	}


func _serialize_node(node: Node, max_depth: int, current_depth: int) -> Dictionary:
	var result: Dictionary = {
		"name": node.name,
		"class": node.get_class(),
		"path": str(node.get_path()),
	}

	if current_depth < max_depth and node.get_child_count() > 0:
		var children: Array = []
		for child in node.get_children():
			children.append(_serialize_node(child, max_depth, current_depth + 1))
		result["children"] = children
	elif node.get_child_count() > 0:
		result["child_count"] = node.get_child_count()

	return result


func _collect_matching_nodes(node: Node, selector: Dictionary, matches: Array, limit: int) -> void:
	if matches.size() >= limit:
		return

	if _matches_selector(node, selector):
		matches.append(_summarize_node(node))
		if matches.size() >= limit:
			return

	for child in node.get_children():
		_collect_matching_nodes(child, selector, matches, limit)
		if matches.size() >= limit:
			return


func _matches_selector(node: Node, selector: Dictionary) -> bool:
	if selector.is_empty():
		return true

	if selector.has("class"):
		var target_class = str(selector["class"])
		if node.get_class() != target_class and not node.is_class(target_class):
			return false

	if selector.has("name") and str(node.name) != str(selector["name"]):
		return false

	if selector.has("path_prefix") and not str(node.get_path()).begins_with(str(selector["path_prefix"])):
		return false

	if selector.has("group") and not node.is_in_group(str(selector["group"])):
		return false

	if selector.has("text"):
		var node_text = _get_node_text(node)
		if node_text == null or str(node_text) != str(selector["text"]):
			return false

	if selector.has("visible"):
		var expected_visible: bool = bool(selector["visible"])
		if _get_node_visible(node) != expected_visible:
			return false

	if selector.has("property_equals"):
		var expected_props = selector["property_equals"]
		if not expected_props is Dictionary:
			return false
		for key in expected_props.keys():
			if node.get(key) != expected_props[key]:
				return false

	return true


func _summarize_node(node: Node) -> Dictionary:
	var summary: Dictionary = {
		"path": str(node.get_path()),
		"name": node.name,
		"class": node.get_class(),
	}

	var visible = _get_node_visible(node)
	if visible != null:
		summary["visible"] = visible

	var text = _get_node_text(node)
	if text != null and str(text) != "":
		summary["text"] = text

	var props: Dictionary = {}
	if node is Control:
		props["position"] = _vec2_to_dict(node.position)
		props["size"] = _vec2_to_dict(node.size)
	if node is Node2D:
		props["position"] = _vec2_to_dict(node.position)
	if props.size() > 0:
		summary["properties"] = props

	return summary


func _get_node_text(node: Node) -> Variant:
	if not node.has_method("get"):
		return null
	var value = node.get("text")
	if value == null:
		return null
	return str(value)


func _get_node_visible(node: Node) -> Variant:
	if node is CanvasItem:
		return node.is_visible_in_tree()
	return null


func _serialize_value(value: Variant) -> Variant:
	if value == null:
		return null
	if value is bool or value is int or value is float or value is String:
		return value
	if value is Vector2:
		return _vec2_to_dict(value)
	if value is Vector2i:
		return {"x": value.x, "y": value.y}
	if value is Vector3:
		return _vec3_to_dict(value)
	if value is Vector3i:
		return {"x": value.x, "y": value.y, "z": value.z}
	if value is Rect2:
		return {"x": value.position.x, "y": value.position.y, "w": value.size.x, "h": value.size.y}
	if value is Rect2i:
		return {"x": value.position.x, "y": value.position.y, "w": value.size.x, "h": value.size.y}
	if value is Color:
		return _color_to_dict(value)
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
	if value is NodePath:
		return str(value)
	if value is Resource:
		return {"_type": "Resource", "path": value.resource_path, "class": value.get_class()}
	# Fallback
	return var_to_str(value)


func _vec2_to_dict(v: Vector2) -> Dictionary:
	return {"x": v.x, "y": v.y}


func _vec3_to_dict(v: Vector3) -> Dictionary:
	return {"x": v.x, "y": v.y, "z": v.z}


func _color_to_dict(c: Color) -> Dictionary:
	return {"r": c.r, "g": c.g, "b": c.b, "a": c.a}
