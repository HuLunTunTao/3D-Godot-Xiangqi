@tool
extends EditorExportPlugin

## Ensures NNUE `.bin` / `.json` / `.txt` weights are packed even if the host preset
## omits them (e.g. `data/.gdignore` or missing include_filter).
##
## Recommended export preset (project root `data/` or addon copy):
##   include_filter="data/*.bin,data/*.json,data/*.txt,addons/pikafish/data/*.bin,addons/pikafish/data/*.json,addons/pikafish/data/*.txt"
##
## Runtime resolution (D002): `PikafishConfig.resolve_network_dir()` prefers
## `res://addons/pikafish/data` when `manifest.json` exists, else `res://data`.
## GDS-DIVERGENCE: PLATFORM — Godot export filters can drop non-imported binaries.


func _get_name() -> String:
	return "PikafishExportPlugin"


func _export_begin(
	_features: PackedStringArray, _is_debug: bool, _path: String, _flags: int
) -> void:
	_pack_dir("res://addons/pikafish/data")
	_pack_dir("res://data")


func _pack_dir(dir_path: String) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if not dir.current_is_dir():
			if name.ends_with(".bin") or name.ends_with(".json") or name.ends_with(".txt"):
				var res_path := dir_path.path_join(name)
				var f := FileAccess.open(res_path, FileAccess.READ)
				if f != null:
					var bytes := f.get_buffer(f.get_length())
					f.close()
					add_file(res_path, bytes, false)
		name = dir.get_next()
	dir.list_dir_end()
