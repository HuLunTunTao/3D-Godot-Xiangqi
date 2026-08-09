class_name PikafishSearchInfo
extends RefCounted

## Per-iteration search info (emitted on each completed iterative-deepening step).

var depth: int = 0
var seldepth: int = 0
## Internal search Value (STM). Convert with `PikafishUciScore.to_cp` for UCI cp.
var score: int = 0
var mate: int = 0
var nodes: int = 0
var nps: int = 0
var time_ms: int = 0
## Current dynamic soft target and fixed hard cap for clock-controlled search.
var soft_time_ms: int = 0
var hard_time_ms: int = 0
var pv: PackedInt32Array = PackedInt32Array()
## True for intermediate ID updates; false for the final summary emitted with bestmove.
var multipv: int = 1
var is_final: bool = false
## Position revision the search was started from.
var revision: int = 0
