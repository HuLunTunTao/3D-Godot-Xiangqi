class_name PikafishPositionView
extends RefCounted

## Immutable-by-convention position data for a game UI.
## `pieces` is a 90-square PackedByteArray using PikafishTypes piece constants.

var revision: int = 0
var fen: String = ""
var pieces: PackedByteArray = PackedByteArray()
var side_to_move: int = 0
var in_check: bool = false
var result: Dictionary = {"result": "unavailable"}
var ply: int = 0


func piece_at(square: int) -> int:
	if square < 0 or square >= pieces.size():
		return 0
	return pieces[square]
