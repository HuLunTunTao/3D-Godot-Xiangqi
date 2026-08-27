class_name NnueWebLoader
extends Node

## Downloads parsed NNUE blobs for the GitHub Pages build. Desktop/editor keep
## using res://data; the web PCK does not ship the ~70 MB weight pack.

const CACHE_DIR := "user://nnue"
const STAMP_NAME := ".pack_sha256"
const PACK_JSON := "nnue-pack.json"
const PACK_ZIP := "nnue-data.zip"
const MANIFEST := "manifest.json"

signal progress_changed(loaded: int, total: int, status: String)

var network_dir := CACHE_DIR
var last_error := ""

var _http: HTTPRequest
var _waiting := false
var _result: Array = []


func _ready() -> void:
	_http = HTTPRequest.new()
	_http.timeout = 600
	_http.use_threads = false
	add_child(_http)
	_http.request_completed.connect(_on_request_completed)


func _process(_delta: float) -> void:
	if not _waiting:
		return
	progress_changed.emit(_http.get_downloaded_bytes(), _http.get_body_size(), "正在下载棋力网络")


func ensure_ready() -> Error:
	if not OS.has_feature("web"):
		network_dir = ""
		return OK
	progress_changed.emit(0, 0, "正在检查棋力网络")
	var pack := await _fetch_pack_info()
	if pack.is_empty():
		return ERR_CANT_OPEN
	var sha := str(pack.get("sha256", ""))
	if sha.is_empty():
		last_error = "nnue-pack.json 缺少 sha256"
		return ERR_INVALID_DATA
	if cache_matches(CACHE_DIR, sha):
		network_dir = CACHE_DIR
		progress_changed.emit(1, 1, "已使用本地缓存")
		return OK
	var zip_name := str(pack.get("file", PACK_ZIP))
	var zip_path := "user://%s" % zip_name.get_file()
	var err := await _download_to(page_url(zip_name), zip_path)
	if err != OK:
		return err
	if FileAccess.get_sha256(zip_path) != sha:
		last_error = "权重包校验失败"
		return ERR_INVALID_DATA
	err = extract_zip_to_dir(zip_path, CACHE_DIR)
	if err != OK:
		return err
	write_stamp(CACHE_DIR, sha)
	network_dir = CACHE_DIR
	return OK


func page_url(relative: String) -> String:
	return join_page_url(_page_href(), relative)


static func join_page_url(href: String, relative: String) -> String:
	var cleaned := href.strip_edges()
	var hash_at := cleaned.find("#")
	if hash_at >= 0:
		cleaned = cleaned.substr(0, hash_at)
	var query_at := cleaned.find("?")
	if query_at >= 0:
		cleaned = cleaned.substr(0, query_at)
	if cleaned.ends_with(".html"):
		cleaned = cleaned.get_base_dir()
	if not cleaned.ends_with("/"):
		cleaned += "/"
	return cleaned + relative.lstrip("/")


static func cache_matches(dest_dir: String, sha256: String) -> bool:
	if sha256.is_empty():
		return false
	if not FileAccess.file_exists(dest_dir.path_join(MANIFEST)):
		return false
	var stamp := FileAccess.get_file_as_string(dest_dir.path_join(STAMP_NAME)).strip_edges()
	return stamp == sha256


static func write_stamp(dest_dir: String, sha256: String) -> void:
	DirAccess.make_dir_recursive_absolute(dest_dir)
	var f := FileAccess.open(dest_dir.path_join(STAMP_NAME), FileAccess.WRITE)
	if f != null:
		f.store_string(sha256)


static func extract_zip_to_dir(zip_path: String, dest_dir: String) -> Error:
	var reader := ZIPReader.new()
	var err := reader.open(zip_path)
	if err != OK:
		return err
	DirAccess.make_dir_recursive_absolute(dest_dir)
	for name in reader.get_files():
		if name.ends_with("/"):
			continue
		var base := name.get_file()
		if base.is_empty() or base.begins_with("."):
			continue
		if not (base.ends_with(".bin") or base == MANIFEST):
			continue
		var bytes: PackedByteArray = reader.read_file(name)
		if bytes.is_empty() and base != MANIFEST:
			reader.close()
			return ERR_FILE_CORRUPT
		var out := FileAccess.open(dest_dir.path_join(base), FileAccess.WRITE)
		if out == null:
			reader.close()
			return ERR_CANT_CREATE
		out.store_buffer(bytes)
	reader.close()
	if not FileAccess.file_exists(dest_dir.path_join(MANIFEST)):
		return ERR_FILE_NOT_FOUND
	return OK


func _page_href() -> String:
	if OS.has_feature("web"):
		return str(JavaScriptBridge.eval("window.location.href", true))
	return "http://127.0.0.1/"


func _fetch_pack_info() -> Dictionary:
	_http.download_file = ""
	var err := await _request(page_url(PACK_JSON))
	if err != OK:
		return {}
	var parsed = JSON.parse_string(_result[3].get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY:
		last_error = "无法解析 nnue-pack.json"
		return {}
	return parsed


func _download_to(url: String, dest: String) -> Error:
	progress_changed.emit(0, 0, "正在下载棋力网络")
	_http.download_file = dest
	var err := await _request(url)
	_http.download_file = ""
	return err


func _request(url: String) -> Error:
	last_error = ""
	_waiting = true
	var err := _http.request(url)
	if err != OK:
		_waiting = false
		last_error = "无法开始下载：%s" % error_string(err)
		return err
	await _http.request_completed
	_waiting = false
	var code := int(_result[1])
	if int(_result[0]) != OK or code < 200 or code >= 300:
		last_error = "下载失败（HTTP %d）" % code
		return ERR_CANT_OPEN
	return OK


func _on_request_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	_result = [result, response_code, _headers, body]
