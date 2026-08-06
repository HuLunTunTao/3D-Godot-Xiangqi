extends Node

## Debug-only JSON-RPC WebSocket bridge used by GodotTestMcp.
##
## The command implementations live in `command_handler.gd`; this autoload owns
## the socket lifecycle, project-local port discovery file, and request/response
## framing. It deliberately does nothing in release builds.

const PORT_START := 28400
const PORT_END := 28499
const PORT_FILE := "res://.godot_test_bridge_port"
const COMMAND_HANDLER := preload("res://addons/godot_test_bridge/command_handler.gd")

var _tcp_server: TCPServer
var _handler
var _peers: Array[WebSocketPeer] = []
var _port: int = -1


func _ready() -> void:
	if not OS.is_debug_build():
		set_process(false)
		return
	_handler = COMMAND_HANDLER.new()
	_handler.bridge = self
	_tcp_server = TCPServer.new()
	for candidate in range(PORT_START, PORT_END + 1):
		if _tcp_server.listen(candidate, "127.0.0.1") == OK:
			_port = candidate
			break
	if _port < 0:
		push_error("[godot_test_bridge] Could not reserve a test bridge port")
		set_process(false)
		return
	_write_port_file()
	print("[godot_test_bridge] Listening on ws://127.0.0.1:%d" % _port)


func _exit_tree() -> void:
	_remove_port_file()
	for peer in _peers:
		peer.close()
	_peers.clear()
	if _tcp_server != null:
		_tcp_server.stop()


func _process(_delta: float) -> void:
	if _tcp_server == null:
		return
	while _tcp_server.is_connection_available():
		var peer := WebSocketPeer.new()
		if peer.accept_stream(_tcp_server.take_connection()) == OK:
			_peers.append(peer)
	for i in range(_peers.size() - 1, -1, -1):
		var peer := _peers[i]
		peer.poll()
		if peer.get_ready_state() == WebSocketPeer.STATE_CLOSED:
			_peers.remove_at(i)
			continue
		if peer.get_ready_state() != WebSocketPeer.STATE_OPEN:
			continue
		while peer.get_available_packet_count() > 0:
			_handle_packet(peer, peer.get_packet().get_string_from_utf8())


func broadcast_notification(method: String, params: Dictionary) -> void:
	var message := JSON.stringify({
		"jsonrpc": "2.0",
		"method": method,
		"params": params,
	})
	for peer in _peers:
		if peer.get_ready_state() == WebSocketPeer.STATE_OPEN:
			peer.send_text(message)


func _handle_packet(peer: WebSocketPeer, raw_packet: String) -> void:
	var json := JSON.new()
	if json.parse(raw_packet) != OK or not json.data is Dictionary:
		_send_error(peer, null, -32700, "Parse error")
		return
	var request: Dictionary = json.data
	var request_id: Variant = request.get("id", null)
	var method: String = request.get("method", "")
	var params_value: Variant = request.get("params", {})
	if method.is_empty():
		_send_error(peer, request_id, -32600, "Missing method")
		return
	if not params_value is Dictionary:
		_send_error(peer, request_id, -32602, "params must be an object")
		return
	var params: Dictionary = params_value

	_handler.current_peer = peer
	_handler.current_id = request_id
	var response: Dictionary = _handler.execute(method, params)
	if request_id == null:
		return
	if response.has("error"):
		_send(peer, {"jsonrpc": "2.0", "id": request_id, "error": response.error})
	else:
		_send(peer, {"jsonrpc": "2.0", "id": request_id, "result": response.get("result", null)})


func _send_error(peer: WebSocketPeer, request_id: Variant, code: int, message: String) -> void:
	_send(peer, {
		"jsonrpc": "2.0",
		"id": request_id,
		"error": {"code": code, "message": message},
	})


func _send(peer: WebSocketPeer, payload: Dictionary) -> void:
	if peer.get_ready_state() == WebSocketPeer.STATE_OPEN:
		peer.send_text(JSON.stringify(payload))


func _write_port_file() -> void:
	var file := FileAccess.open(PORT_FILE, FileAccess.WRITE)
	if file == null:
		push_error("[godot_test_bridge] Could not write %s" % PORT_FILE)
		return
	file.store_string(str(_port))
	file.close()


func _remove_port_file() -> void:
	if FileAccess.file_exists(PORT_FILE):
		var error := DirAccess.remove_absolute(ProjectSettings.globalize_path(PORT_FILE))
		if error != OK:
			push_warning("[godot_test_bridge] Could not remove %s (error %d)" % [PORT_FILE, error])
