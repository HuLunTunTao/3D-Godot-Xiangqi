class_name PikafishSearchResult
extends RefCounted

## Final search result delivered on `best_move_found`.
## `depth` remains the completed (stable) iteration depth for compatibility.

var bestmove: int = 0
var ponder: int = 0
var score: int = 0
var mate: int = 0  # 0 if not mate; else mate distance (signed, STM view)
var depth: int = 0
var seldepth: int = 0
var nodes: int = 0
var nps: int = 0
var time_ms: int = 0
var pv: PackedInt32Array = PackedInt32Array()
var stop_reason: String = "unavailable"

## Extended fields (additive; callers may ignore).
var requested_depth: int = 0
var completed_depth: int = 0
var elapsed_ms: int = 0
var stopped: bool = false
var timed_out: bool = false
var node_limited: bool = false
## True when bestmove/score/pv come from a fully finished ID iteration.
var from_complete_iteration: bool = true
## True when depth-1 never finished and a legal fallback move was used.
var incomplete: bool = false
## Position revision the search was started from.
var revision: int = 0
