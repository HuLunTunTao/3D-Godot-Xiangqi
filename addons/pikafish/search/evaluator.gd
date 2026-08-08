class_name PikafishSearchEvaluator
extends RefCounted

## Static-evaluation strategy owned by one SearchWorker.
##
## Search owns Position and calls these hooks immediately after its matching
## Position do/undo operation. Implementations may therefore keep a private
## incremental representation without leaking it into alpha-beta code.

func begin(_position) -> void:
	pass


func do_move(_move: int) -> void:
	pass


func undo_move() -> void:
	pass


func do_null_move() -> void:
	pass


func undo_null_move() -> void:
	pass


## Upstream Eval::evaluate receives a root-side optimism value.  Keeping the
## hook on the strategy makes the search independent from a concrete evaluator.
func set_optimism(_white: int, _black: int) -> void:
	pass


func evaluate(_position) -> int:
	return 0


func dispose() -> void:
	pass
