class_name XiangqiExternalGameSource
extends Node

## Read-only local spectator feed. Producers must treat this as lossy from
## their perspective: the viewer drains input on its own schedule and retains
## only the newest valid snapshot per frame.
signal snapshot_received(snapshot: Dictionary)
signal connection_changed(state: String, detail: String)

const MAX_LINE_BYTES := 65536
const MAX_LINES_PER_FRAME := 32
const RETRY_SECONDS := 1.0

var _peer := StreamPeerTCP.new()
var _host := "127.0.0.1"
var _port := 19190
var _buffer := ""
var _next_retry_ms := 0
var _last_seq := -1
var _session := ""
var _state := "disconnected"


func start(host: String, port: int) -> void:
	_host = host.strip_edges()
	_port = clampi(port, 1, 65535)
	_last_seq = -1
	_session = ""
	_buffer = ""
	_connect_now()


func stop() -> void:
	_peer.disconnect_from_host()
	_set_state("disconnected", "已停止外部观战连接")


func _process(_delta: float) -> void:
	# StreamPeerTCP does not advance a non-blocking connect by itself. Without
	# poll(), get_status() remains STATUS_CONNECTING forever on desktop Godot.
	_peer.poll()
	var status := _peer.get_status()
	if status == StreamPeerTCP.STATUS_CONNECTED:
		_drain_input()
		return
	if status == StreamPeerTCP.STATUS_CONNECTING:
		return
	if Time.get_ticks_msec() >= _next_retry_ms:
		_connect_now()


func _connect_now() -> void:
	_peer.disconnect_from_host()
	_peer = StreamPeerTCP.new()
	var err := _peer.connect_to_host(_host, _port)
	_next_retry_ms = Time.get_ticks_msec() + int(RETRY_SECONDS * 1000.0)
	if err != OK:
		_set_state("reconnecting", "观战服务暂不可用，正在重试")
		return
	_set_state("connecting", "正在连接观战服务…")


func _drain_input() -> void:
	if _state != "connected":
		_set_state("connected", "观战服务已连接")
	var latest: Dictionary = {}
	var lines := 0
	while _peer.get_available_bytes() > 0 and lines < MAX_LINES_PER_FRAME:
		var chunk := _peer.get_utf8_string(mini(_peer.get_available_bytes(), 4096))
		if chunk.is_empty():
			break
		_buffer += chunk
		if _buffer.length() > MAX_LINE_BYTES:
			_buffer = ""
			_set_state("connected", "收到过长数据行，已丢弃并等待下一快照")
			break
		while true:
			var end := _buffer.find("\n")
			if end < 0 or lines >= MAX_LINES_PER_FRAME:
				break
			var line := _buffer.substr(0, end).strip_edges()
			_buffer = _buffer.substr(end + 1)
			lines += 1
			var event := decode_snapshot(line)
			if not event.is_empty():
				latest = event
	if not latest.is_empty():
		snapshot_received.emit(latest)


func decode_snapshot(line: String) -> Dictionary:
	## Public and pure enough for protocol tests. Unknown fields are retained so
	## a relay can add presentation metadata without a client update.
	if line.is_empty():
		return {}
	var json := JSON.new()
	if json.parse(line) != OK or not json.data is Dictionary:
		return {}
	var event: Dictionary = json.data
	if str(event.get("type", "snapshot")) not in ["snapshot", "reset"]:
		return {}
	var fen := str(event.get("fen", "")).strip_edges()
	if fen.is_empty():
		return {}
	var session := str(event.get("session", "default"))
	var seq := int(event.get("seq", -1))
	if session != _session:
		_session = session
		_last_seq = -1
	if seq >= 0:
		if seq <= _last_seq:
			return {}
		_last_seq = seq
	event["fen"] = fen
	return event


func _set_state(state: String, detail: String) -> void:
	if _state == state and detail.is_empty():
		return
	_state = state
	connection_changed.emit(state, detail)
