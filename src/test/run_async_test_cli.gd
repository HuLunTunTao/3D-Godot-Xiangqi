extends SceneTree

## Headless CLI runner for the Node-based async batch test.
## Usage:
##   Godot --path . -s res://src/test/run_async_test_cli.gd
## Loads `async_test.tscn` (Node script). Do not pass the Node script to `-s` directly.
## Exit code is non-zero on failure.

func _init() -> void:
	call_deferred("_boot")


func _boot() -> void:
	var packed := load("res://src/test/async_test.tscn")
	if packed == null:
		push_error("async_test.tscn missing")
		quit(1)
		return
	var node: Node = packed.instantiate()
	root.add_child(node)
	# Node._ready runs; Node._process drives quit with status.
