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
