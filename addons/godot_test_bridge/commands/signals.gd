extends RefCounted

## Signal watching commands: watch_signal, unwatch_signal, get_watched_signals

var bridge: Node

# {node_path + "::" + signal_name} -> Array of emission records
var _watched: Dictionary = {}
# Track callable references for disconnection
var _connections: Dictionary = {}


func execute(method: String, params: Dictionary) -> Dictionary:
	match method:
		"watch_signal":
			return _watch_signal(params)
		"unwatch_signal":
			return _unwatch_signal(params)
		"get_watched_signals":
			return _get_watched_signals(params)
	return {"error": {"code": -32601, "message": "Unknown method: %s" % method}}


func _watch_signal(params: Dictionary) -> Dictionary:
	var node_path: String = params.get("node_path", "")
	var signal_name: String = params.get("signal_name", "")

	if node_path == "" or signal_name == "":
		return {"error": {"code": -32602, "message": "Missing required params: node_path, signal_name"}}

	var node = bridge.get_node_or_null(node_path)
	if not node:
		return {"error": {"code": -32000, "message": "Node not found: %s" % node_path}}

	if not node.has_signal(signal_name):
		return {"error": {"code": -32000, "message": "Signal not found: %s on %s" % [signal_name, node_path]}}

	var key = node_path + "::" + signal_name

	# Already watching
	if _watched.has(key):
		return {"result": {"success": true, "already_watching": true, "key": key}}

	_watched[key] = []

	# Connect with a lambda that captures context
	var callable = func(args = []):
		_on_signal_emitted(key, node_path, signal_name, args)

	# Use CONNECT_DEFERRED to be safe
	# We need to handle signals with varying argument counts
	# Using a variadic approach with bind
	var cb = _create_signal_callback(key, node_path, signal_name)
	node.connect(signal_name, cb)
	_connections[key] = {"node_path": node_path, "signal_name": signal_name, "callable": cb}

	return {"result": {"success": true, "key": key}}


func _unwatch_signal(params: Dictionary) -> Dictionary:
	var node_path: String = params.get("node_path", "")
	var signal_name: String = params.get("signal_name", "")

	if node_path == "" or signal_name == "":
		return {"error": {"code": -32602, "message": "Missing required params: node_path, signal_name"}}

	var key = node_path + "::" + signal_name

	if not _watched.has(key):
		return {"result": {"success": true, "was_watching": false}}

	# Disconnect
	if _connections.has(key):
		var conn = _connections[key]
		var node = bridge.get_node_or_null(node_path)
		if node and node.is_connected(signal_name, conn["callable"]):
			node.disconnect(signal_name, conn["callable"])
		_connections.erase(key)

	_watched.erase(key)
	return {"result": {"success": true, "was_watching": true}}


func _get_watched_signals(params: Dictionary) -> Dictionary:
	var clear_val = params.get("clear", true)
	var clear = true
	if clear_val is bool:
		clear = clear_val
	elif clear_val is int:
		clear = clear_val != 0
	elif clear_val is String:
		clear = clear_val.to_lower() != "false" and clear_val != "0"

	var emissions: Dictionary = {}
	for key in _watched:
		if _watched[key].size() > 0:
			emissions[key] = _watched[key].duplicate()

	if clear:
		for key in _watched:
			_watched[key] = []

	return {"result": {"emissions": emissions, "watched_count": _watched.size()}}


func _create_signal_callback(key: String, node_path: String, signal_name: String) -> Callable:
	# This callback captures any number of arguments via a wrapper
	return func(arg1 = "__NONE__", arg2 = "__NONE__", arg3 = "__NONE__", arg4 = "__NONE__"):
		var args: Array = []
		for a in [arg1, arg2, arg3, arg4]:
			if a is String and a == "__NONE__":
				break
			args.append(a)
		_on_signal_emitted(key, node_path, signal_name, args)


func _on_signal_emitted(key: String, node_path: String, signal_name: String, args: Array) -> void:
	if not _watched.has(key):
		return

	var record = {
		"timestamp": Time.get_unix_time_from_system(),
		"signal_name": signal_name,
		"node_path": node_path,
		"args": args,
	}

	_watched[key].append(record)

	# Also broadcast as notification to connected clients
	if bridge and bridge.has_method("broadcast_notification"):
		bridge.broadcast_notification("signal_emitted", record)
