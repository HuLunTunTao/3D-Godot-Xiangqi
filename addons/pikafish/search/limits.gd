class_name PikafishSearchLimits
extends RefCounted

## Upstream: Pikafish 2c5c998c, Search::LimitsType (subset).
## Prefer Dictionary form for game callers, e.g.:
##   engine.start_search({"movetime_ms": 1200})
## Supported keys (Dictionary or these fields): movetime_ms/movetime,
## wtime, btime, winc, binc, movestogo, move_overhead_ms, depth, nodes,
## infinite, ponder, sync, cooperative.

var depth: int = 0
var nodes: int = 0
var movetime_ms: int = 0
var time_ms: PackedInt32Array = PackedInt32Array([0, 0])  # wtime, btime
var inc_ms: PackedInt32Array = PackedInt32Array([0, 0])  # winc, binc
var movestogo: int = 0
var mate: int = 0
var infinite: bool = false
var ponder: bool = false
## Account for UI / animation / transport delay before the clock hard cap.
var move_overhead_ms: int = 10
## When true, start_search blocks until done (GUT / smoke / tools).
## null / unset → async (game-default).
var sync = null
## When true, run as a main-thread coroutine with frame yields (web / tests).
## Ignored if sync is true. Desktop game-default remains a background Thread.
var cooperative: bool = false
