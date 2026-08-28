class_name NnueWebLoader
extends Node

## Downloads parsed NNUE blobs for the GitHub Pages build. Desktop/editor keep
## using res://data; the web PCK does not ship the ~70 MB weight pack.

const CACHE_DIR := "user://nnue"
const STAMP_NAME := ".pack_sha256"
const PACK_JSON := "nnue-pack.json"
const PACK_ZIP := "nnue-data.zip"
const MANIFEST := "manifest.json"
## 256 KiB keeps WASM memory stable while hashing the ~52 MB sidecar.
const HASH_CHUNK := 262144
const STATUS_CHECKING := "正在检查棋力网络"
const STATUS_PREPARING := "正在准备棋力网络"
const STATUS_DOWNLOADING := "正在下载棋力网络"
const STATUS_VERIFYING := "正在校验棋力网络"
const STATUS_CACHED := "已使用本地缓存"

signal progress_changed(loaded: int, total: int, status: String)

var network_dir := CACHE_DIR
var last_error := ""

var _http: HTTPRequest
var _waiting := false
var _progress_status := STATUS_CHECKING
var _result: Array = []
var _web_hash_cb: JavaScriptObject
var _web_hash := ""
var _web_hash_done := false


func _ready() -> void:
	_http = HTTPRequest.new()
	_http.timeout = 600
	_http.use_threads = false
	add_child(_http)
	_http.request_completed.connect(_on_request_completed)


func _process(_delta: float) -> void:
	if not _waiting:
		return
	progress_changed.emit(_http.get_downloaded_bytes(), _http.get_body_size(), _progress_status)


func ensure_ready() -> Error:
	if not OS.has_feature("web"):
		network_dir = ""
		return OK
	request_persistent_storage()
	progress_changed.emit(0, 0, STATUS_CHECKING)
	var pack := await _fetch_pack_info()
	if pack.is_empty():
		return ERR_CANT_OPEN
	var sha := str(pack.get("sha256", "")).strip_edges().to_lower()
	if sha.is_empty():
		last_error = "nnue-pack.json 缺少 sha256"
		return ERR_INVALID_DATA
	var zip_name := str(pack.get("file", PACK_ZIP))
	var zip_path := "user://%s" % zip_name.get_file()
	if cache_matches(CACHE_DIR, sha):
		# A previous extract may have left the sidecar zip in IDBFS.
		discard_zip_after_extract(zip_path)
		network_dir = CACHE_DIR
		progress_changed.emit(1, 1, STATUS_CACHED)
		return OK
	var expected_bytes := int(pack.get("bytes", 0))
	var err := await _download_to(page_url(zip_name), zip_path)
	if err != OK:
		return err
	flush_web_fs()
	var actual_bytes := downloaded_byte_count(zip_path)
	err = size_check_error(actual_bytes, expected_bytes)
	if err != OK:
		last_error = integrity_failure_text("", sha, actual_bytes, expected_bytes)
		return err
	progress_changed.emit(actual_bytes, actual_bytes, STATUS_VERIFYING)
	var actual_sha := await sha256_downloaded(zip_path)
	if not pack_hash_matches(actual_sha, sha):
		last_error = integrity_failure_text(actual_sha, sha, actual_bytes, expected_bytes)
		return ERR_INVALID_DATA
	err = extract_zip_to_dir(zip_path, CACHE_DIR)
	if err != OK:
		return err
	write_stamp(CACHE_DIR, sha)
	discard_zip_after_extract(zip_path)
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


## Godot 4.7 FileAccess.get_sha256 returns "" on open failure and can stop on
## short reads (`br < 4096`), which is enough to false-fail a ~52 MB user://
## download on Web. Hash in chunks until EOF instead.
static func file_sha256(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var digest := PackedByteArray()
	var ctx := HashingContext.new()
	var ok := ctx.start(HashingContext.HASH_SHA256) == OK
	if ok:
		var total := file.get_length()
		while ok and file.get_position() < total:
			var remaining := total - file.get_position()
			var chunk := file.get_buffer(mini(remaining, HASH_CHUNK))
			if chunk.is_empty() or ctx.update(chunk) != OK:
				ok = false
				break
		if ok and file.get_position() == total:
			digest = ctx.finish()
	file.close()
	if not ok or digest.size() != 32:
		return ""
	return digest.hex_encode()


static func downloaded_byte_count(path: String) -> int:
	if not FileAccess.file_exists(path):
		return -1
	var size := FileAccess.get_size(path)
	if size >= 0:
		return size
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return -1
	var length := file.get_length()
	file.close()
	return length


static func size_check_error(actual_bytes: int, expected_bytes: int) -> Error:
	if expected_bytes > 0 and actual_bytes != expected_bytes:
		return ERR_INVALID_DATA
	if actual_bytes <= 0:
		return ERR_FILE_CORRUPT
	return OK


static func pack_hash_matches(actual_sha: String, expected_sha: String) -> bool:
	if expected_sha.is_empty() or actual_sha.is_empty():
		return false
	return actual_sha.to_lower() == expected_sha.to_lower()


static func integrity_failure_text(
	actual_sha: String, expected_sha: String, actual_bytes: int, expected_bytes: int
) -> String:
	if actual_bytes < 0:
		return "权重包校验失败（无法读取文件大小，期望 %d）" % expected_bytes
	if expected_bytes > 0 and actual_bytes != expected_bytes:
		return "权重包校验失败（大小 %d，期望 %d）" % [actual_bytes, expected_bytes]
	if actual_sha.is_empty():
		return "权重包校验失败（无法计算 SHA-256，大小 %d，期望 sha256 %s）" % [actual_bytes, expected_sha]
	return "权重包校验失败（sha256 %s，期望 %s，大小 %d）" % [actual_sha, expected_sha, actual_bytes]


static func configure_zip_http(http: HTTPRequest) -> void:
	http.accept_gzip = false


## HTML5 `HTTPRequest.download_file` can finish RESULT_SUCCESS with an empty
## dest file and an empty signal body, which looks like a checksum failure.
static func uses_download_file() -> bool:
	return not OS.has_feature("web")


static func persist_download(dest: String, body: PackedByteArray) -> Error:
	if body.is_empty():
		# Desktop download_file already wrote dest; the signal body is empty.
		return OK if downloaded_byte_count(dest) > 0 else ERR_FILE_CORRUPT
	var out := FileAccess.open(dest, FileAccess.WRITE)
	if out == null:
		return ERR_CANT_CREATE
	out.store_buffer(body)
	out.close()
	if downloaded_byte_count(dest) != body.size():
		return ERR_FILE_CANT_WRITE
	return OK


static func flush_web_fs() -> void:
	if not OS.has_feature("web"):
		return
	JavaScriptBridge.force_fs_sync()


static func discard_zip_after_extract(zip_path: String) -> void:
	if zip_path.is_empty():
		return
	if FileAccess.file_exists(zip_path):
		DirAccess.remove_absolute(zip_path)
	flush_web_fs()


## Ask the browser to keep IndexedDB / IDBFS. Never blocks loading; unsupported
## or denied persist() is ignored. Must not be used to skip a real zip download.
static func request_persistent_storage() -> bool:
	if not OS.has_feature("web"):
		return false
	var script := (
		"(function(){try{var s=navigator.storage;if(s&&s.persist){s.persist();}return true;}catch(e){return false;}})()"
	)
	var ok = JavaScriptBridge.eval(script, true)
	return ok == true or str(ok).to_lower() in ["true", "1"]


static func is_standalone_web_app() -> bool:
	if not OS.has_feature("web"):
		return false
	var script := (
		"(function(){try{return Boolean((window.matchMedia&&window.matchMedia('(display-mode: standalone)').matches)||(navigator.standalone===true));}catch(e){return false;}})()"
	)
	var ok = JavaScriptBridge.eval(script, true)
	return ok == true or str(ok).to_lower() in ["true", "1"]


func sha256_downloaded(path: String) -> String:
	var digest := file_sha256(path)
	if not digest.is_empty() or not OS.has_feature("web"):
		return digest
	return await _sha256_web_crypto(path)


func _page_href() -> String:
	if OS.has_feature("web"):
		return str(JavaScriptBridge.eval("window.location.href", true))
	return "http://127.0.0.1/"


func _fetch_pack_info() -> Dictionary:
	_http.download_file = ""
	_http.accept_gzip = true
	var err := await _request(page_url(PACK_JSON), STATUS_CHECKING)
	if err != OK:
		return {}
	var parsed = JSON.parse_string(_result[3].get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY:
		last_error = "无法解析 nnue-pack.json"
		return {}
	return parsed


func _download_to(url: String, dest: String) -> Error:
	progress_changed.emit(0, 0, STATUS_DOWNLOADING)
	_http.download_file = dest if uses_download_file() else ""
	configure_zip_http(_http)
	var err := await _request(url, STATUS_DOWNLOADING)
	_http.download_file = ""
	if err != OK:
		return err
	var body: PackedByteArray = _result[3] if _result.size() > 3 else PackedByteArray()
	var body_size := body.size()
	err = persist_download(dest, body)
	if _result.size() > 3:
		_result[3] = PackedByteArray()
	if err != OK:
		last_error = "下载失败（无法保存权重包，HTTP %d，body %d，文件 %d）" % [
			int(_result[1]) if _result.size() > 1 else 0,
			body_size,
			downloaded_byte_count(dest),
		]
		return err
	return OK


func _request(url: String, status: String = STATUS_CHECKING) -> Error:
	last_error = ""
	_progress_status = status
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


func _on_web_hash(args: Array) -> void:
	_web_hash = str(args[0]) if not args.is_empty() else ""
	_web_hash_done = true


func _sha256_web_crypto(path: String) -> String:
	_web_hash = ""
	_web_hash_done = false
	if _web_hash_cb == null:
		_web_hash_cb = JavaScriptBridge.create_callback(_on_web_hash)
	var window = JavaScriptBridge.get_interface("window")
	if window == null:
		return ""
	window._nnueOnSha256 = _web_hash_cb
	var js_path := ProjectSettings.globalize_path(path)
	var script := (
		"(async()=>{try{const p=%s;const data=FS.readFile(p);const buf=await crypto.subtle.digest('SHA-256',data);const hex=Array.from(new Uint8Array(buf)).map(b=>b.toString(16).padStart(2,'0')).join('');window._nnueOnSha256(hex);}catch(e){window._nnueOnSha256('');}})();"
		% JSON.stringify(js_path)
	)
	JavaScriptBridge.eval(script, true)
	var frames := 0
	while not _web_hash_done and frames < 600:
		await get_tree().process_frame
		frames += 1
	return _web_hash.to_lower()
