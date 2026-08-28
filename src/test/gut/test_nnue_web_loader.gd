extends GutTest

const Loader = preload("res://src/game/nnue_web_loader.gd")
const ExportPlugin = preload("res://addons/pikafish/tools/export_plugin.gd")


func test_join_page_url_strips_index_query_and_hash() -> void:
	assert_eq(
		Loader.join_page_url("https://example.github.io/game/index.html?x=1#y", "nnue-pack.json"),
		"https://example.github.io/game/nnue-pack.json"
	)
	assert_eq(
		Loader.join_page_url("https://example.github.io/game/", "nnue-data.zip"),
		"https://example.github.io/game/nnue-data.zip"
	)


func test_file_sha256_hashes_known_bytes_in_chunks() -> void:
	var path := "user://nnue_test_sha.bin"
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	var payload := PackedByteArray()
	payload.resize(5000)
	payload.fill(ord("x"))
	var out := FileAccess.open(path, FileAccess.WRITE)
	assert_not_null(out)
	out.store_buffer(payload)
	out.close()
	assert_eq(Loader.file_sha256(path), "c59d3c0480cc2d71d8f646e735e92da65450311eec46e81a5db8c7e6e8a92054")
	assert_eq(Loader.downloaded_byte_count(path), 5000)
	DirAccess.remove_absolute(path)


func test_file_sha256_returns_empty_for_missing_file() -> void:
	var path := "user://nnue_test_missing_sha.bin"
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	assert_eq(Loader.file_sha256(path), "")
	assert_eq(Loader.downloaded_byte_count(path), -1)


func test_empty_digest_does_not_match_pack_sha() -> void:
	var expected := "e9a70da911e7a658493854b96b34db5c9e25a75d32fc402dd0e9093a7b20c2a4"
	assert_false(Loader.pack_hash_matches("", expected))
	assert_false(Loader.pack_hash_matches("", ""))
	assert_true(Loader.pack_hash_matches(expected.to_upper(), expected))


func test_size_check_rejects_mismatch_and_empty_download() -> void:
	assert_eq(Loader.size_check_error(52602089, 52602089), OK)
	assert_eq(Loader.size_check_error(12, 52602089), ERR_INVALID_DATA)
	assert_eq(Loader.size_check_error(0, 0), ERR_FILE_CORRUPT)
	assert_eq(Loader.size_check_error(-1, 52602089), ERR_INVALID_DATA)


func test_integrity_error_includes_expected_and_actual() -> void:
	var size_err := Loader.integrity_failure_text(
		"aaa", "bbb", 12, 52602089
	)
	assert_string_contains(size_err, "12")
	assert_string_contains(size_err, "52602089")
	var hash_err := Loader.integrity_failure_text(
		"aaa", "bbb", 4, 4
	)
	assert_string_contains(hash_err, "aaa")
	assert_string_contains(hash_err, "bbb")
	assert_string_contains(hash_err, "4")
	var empty_hash := Loader.integrity_failure_text("", "bbb", 4, 4)
	assert_string_contains(empty_hash, "无法计算 SHA-256")
	assert_string_contains(empty_hash, "bbb")


func test_configure_zip_http_disables_gzip() -> void:
	var http := HTTPRequest.new()
	assert_true(http.accept_gzip)
	Loader.configure_zip_http(http)
	assert_false(http.accept_gzip)
	http.free()


func test_persist_download_writes_body_when_dest_missing() -> void:
	var path := "user://nnue_test_persist.bin"
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	assert_eq(Loader.persist_download(path, PackedByteArray()), ERR_FILE_CORRUPT)
	assert_eq(Loader.persist_download(path, PackedByteArray([9, 8, 7])), OK)
	assert_eq(FileAccess.get_file_as_bytes(path), PackedByteArray([9, 8, 7]))
	assert_eq(Loader.persist_download(path, PackedByteArray([1])), OK)
	assert_eq(FileAccess.get_file_as_bytes(path), PackedByteArray([9, 8, 7]))
	DirAccess.remove_absolute(path)


func test_headless_still_streams_zip_with_download_file() -> void:
	assert_true(Loader.uses_download_file())


func test_loader_does_not_use_fileaccess_get_sha256() -> void:
	var src := FileAccess.get_file_as_string("res://src/game/nnue_web_loader.gd")
	assert_false(src.contains("FileAccess.get_sha256("), src)
	assert_true(src.contains("HashingContext"))
	assert_true(src.contains("configure_zip_http"))


func test_extract_zip_and_cache_stamp() -> void:
	var dest := "user://nnue_test_extract"
	var zip_path := "user://nnue_test_extract.zip"
	_wipe(dest)
	if FileAccess.file_exists(zip_path):
		DirAccess.remove_absolute(zip_path)
	var packer := ZIPPacker.new()
	assert_eq(packer.open(zip_path), OK)
	packer.start_file("manifest.json")
	packer.write_file('{"ok":true}'.to_utf8_buffer())
	packer.close_file()
	packer.start_file("ft_bias.bin")
	packer.write_file(PackedByteArray([1, 2, 3, 4]))
	packer.close_file()
	packer.close()
	assert_eq(Loader.extract_zip_to_dir(zip_path, dest), OK)
	assert_true(FileAccess.file_exists(dest.path_join("manifest.json")))
	assert_eq(FileAccess.get_file_as_bytes(dest.path_join("ft_bias.bin")), PackedByteArray([1, 2, 3, 4]))
	assert_false(Loader.cache_matches(dest, "abc"))
	Loader.write_stamp(dest, "abc")
	assert_true(Loader.cache_matches(dest, "abc"))
	assert_false(Loader.cache_matches(dest, "nope"))
	_wipe(dest)
	DirAccess.remove_absolute(zip_path)


func test_web_preset_excludes_nnue_weight_dirs() -> void:
	var text := FileAccess.get_file_as_string("res://export_presets.cfg")
	assert_false(text.is_empty())
	var tokens := _web_exclude_filter_tokens(text)
	assert_gt(tokens.size(), 0)
	assert_true(tokens.has("data/*"), ",".join(tokens))
	assert_true(tokens.has("addons/pikafish/data/*"), ",".join(tokens))


func test_exclude_filter_tokens_require_root_data_entry() -> void:
	var tokens := _web_exclude_filter_tokens(
		'exclude_filter="src/test/*,addons/pikafish/data/*"\n'
	)
	assert_true(tokens.has("addons/pikafish/data/*"))
	assert_false(tokens.has("data/*"))


func test_export_plugin_skips_packing_on_web() -> void:
	assert_false(ExportPlugin.should_pack_weights(PackedStringArray(["web"])))
	assert_false(ExportPlugin.should_pack_weights(PackedStringArray(["javascript", "web", "etc2"])))
	assert_false(ExportPlugin.should_pack_weights(PackedStringArray(["Web"])))
	assert_true(ExportPlugin.should_pack_weights(PackedStringArray(["pc", "linux"])))
	assert_true(ExportPlugin.should_pack_weights(PackedStringArray(["android", "mobile"])))
	assert_true(ExportPlugin.should_pack_weights(PackedStringArray()))


func _web_exclude_filter_tokens(preset_text: String) -> PackedStringArray:
	var exclude_line := ""
	for line in preset_text.split("\n"):
		if line.begins_with("exclude_filter="):
			exclude_line = line.strip_edges()
			break
	var value := exclude_line.trim_prefix("exclude_filter=")
	if value.begins_with("\"") and value.ends_with("\"") and value.length() >= 2:
		value = value.substr(1, value.length() - 2)
	var tokens := PackedStringArray()
	for part in value.split(","):
		var token := part.strip_edges()
		if not token.is_empty():
			tokens.append(token)
	return tokens


func _wipe(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.include_hidden = true
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if name != "." and name != "..":
			dir.remove(name)
		name = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(path)
