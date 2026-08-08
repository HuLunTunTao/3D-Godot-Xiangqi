class_name PikafishConfig
extends RefCounted

## Runtime configuration for PikafishEngine.
## network_dir must be a FileAccess-compatible res:// (or user://) directory.

var network_dir: String = ""
## Prefer GPU when available; canary must pass before GPU is selected.
var prefer_gpu: bool = true
## Diagnostic: allow GPU even on platforms previously version-gated.
var allow_ios_gpu_probe: bool = true
## Minimum canary positions that must match CPU within abs(diff)<=1.
var canary_count: int = 5
var hash_mb: int = 16
var threads: int = 1  # Phase A/G: single worker only
const EVALUATION_NNUE := "nnue"
const EVALUATION_MATERIAL := "material"
## Search static evaluator. Empty selects the compatibility default: NNUE.
## Set to `EVALUATION_MATERIAL` only for diagnostics and constrained benchmarks.
var evaluation_mode: String = ""
## Deprecated compatibility switch. Used only when `evaluation_mode` is empty;
## its default is NNUE so existing callers that do not set it get upstream mode.
var use_nnue_eval: bool = true
## Opt-in ProbCut / singular extension (default off until fixed-node parity is strong).
var enable_probcut: bool = false
var enable_singular: bool = false


func resolve_network_dir() -> String:
	if not network_dir.is_empty():
		return network_dir
	var addon_data := "res://addons/pikafish/data"
	if FileAccess.file_exists(addon_data.path_join("manifest.json")):
		return addon_data
	return "res://data"


func resolved_evaluation_mode() -> String:
	if evaluation_mode == EVALUATION_MATERIAL:
		return EVALUATION_MATERIAL
	if evaluation_mode == EVALUATION_NNUE:
		return EVALUATION_NNUE
	return EVALUATION_NNUE if use_nnue_eval else EVALUATION_MATERIAL
