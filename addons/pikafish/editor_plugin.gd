@tool
extends EditorPlugin

## Registers the optional EditorExportPlugin so host export presets keep NNUE weights.
const ExportPluginScript = preload("res://addons/pikafish/tools/export_plugin.gd")

var _export_plugin: EditorExportPlugin


func _enter_tree() -> void:
	_export_plugin = ExportPluginScript.new()
	add_export_plugin(_export_plugin)


func _exit_tree() -> void:
	if _export_plugin != null:
		remove_export_plugin(_export_plugin)
		_export_plugin = null
