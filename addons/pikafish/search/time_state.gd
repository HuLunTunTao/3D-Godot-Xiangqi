class_name PikafishSearchTimeState
extends RefCounted

## Small persistent subset of upstream SearchManager state used by time control.
## One PikafishEngine owns one instance and never runs two searches concurrently.

var original_time_adjust: float = -1.0
var previous_time_reduction: float = 1.0
var best_previous_score: int = 0
var best_previous_average_score: int = 0
var has_previous_score: bool = false
