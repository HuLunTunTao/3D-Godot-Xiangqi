class_name PikafishMoveInfo
extends RefCounted

## Structured description of one accepted move-state transition.
## `kind` is one of `move`, `undo`, or `redo`.

var kind: String = "move"
var revision: int = 0
var move: int = 0
var from: int = 0
var to: int = 0
var moving_piece: int = 0
var captured_piece: int = 0
var side_before: int = 0
var uci: String = "0000"
var gives_check: bool = false


func duplicate_info():
	var copy = get_script().new()
	copy.kind = kind
	copy.revision = revision
	copy.move = move
	copy.from = from
	copy.to = to
	copy.moving_piece = moving_piece
	copy.captured_piece = captured_piece
	copy.side_before = side_before
	copy.uci = uci
	copy.gives_check = gives_check
	return copy
