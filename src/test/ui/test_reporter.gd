class_name PikafishTestReporter
extends RefCounted

## Shared test telemetry for interactive device scenes and desktop runners.
## Keep the retained log bounded: UI observability must not change test behaviour.

signal updated(snapshot)

const MAX_LOG_LINES := 200

var suite_name := "Pikafish test"
var environment: Dictionary = {}
var stage_name := "Waiting"
var stage_detail := ""
var progress_current := 0
var progress_total := 0
var metrics: Dictionary = {}
var log_lines: PackedStringArray = PackedStringArray()
var started_us := 0
var completed := false
var passed := false


func _init(name := "Pikafish test") -> void:
	suite_name = name
	environment = collect_environment()
	started_us = Time.get_ticks_usec()
	report_log("suite started")


static func collect_environment() -> Dictionary:
	var godot := Engine.get_version_info()
	var renderer := "unknown"
	if RenderingServer.has_method("get_current_rendering_method"):
		renderer = str(RenderingServer.get_current_rendering_method())
	var adapter := "unknown"
	if RenderingServer.has_method("get_video_adapter_name"):
		adapter = str(RenderingServer.get_video_adapter_name())
	var vendor := "unknown"
	if RenderingServer.has_method("get_video_adapter_vendor"):
		vendor = str(RenderingServer.get_video_adapter_vendor())
	return {
		"platform": OS.get_name(),
		"os_version": OS.get_version(),
		"model": OS.get_model_name(),
		"godot": "%s.%s.%s" % [godot.get("major", "?"), godot.get("minor", "?"), godot.get("patch", "?")],
		"renderer": renderer,
		"adapter": adapter,
		"vendor": vendor,
		"screen": "%dx%d" % [DisplayServer.screen_get_size().x, DisplayServer.screen_get_size().y],
	}


func stage(name: String, total := 0, detail := "") -> void:
	stage_name = name
	stage_detail = detail
	progress_current = 0
	progress_total = total
	report_log("START %s%s" % [name, " — " + detail if not detail.is_empty() else ""])
	_emit()


func progress(current: int, total := -1, detail := "") -> void:
	progress_current = current
	if total >= 0:
		progress_total = total
	if not detail.is_empty():
		stage_detail = detail
	_emit()


func metric(name: String, value) -> void:
	metrics[name] = value
	_emit()


func report_log(message: String, level := "INFO") -> void:
	var elapsed := float(Time.get_ticks_usec() - started_us) / 1000000.0
	log_lines.append("%7.2fs %-5s %s" % [elapsed, level, message])
	if log_lines.size() > MAX_LOG_LINES:
		log_lines.remove_at(0)
	print("[%s] %s" % [level, message])
	_emit()


func finish(ok: bool, detail := "") -> void:
	completed = true
	passed = ok
	stage_name = "PASS" if ok else "FAIL"
	stage_detail = detail
	report_log("suite %s%s" % [stage_name, " — " + detail if not detail.is_empty() else ""], "PASS" if ok else "FAIL")
	_emit()


func elapsed_ms() -> int:
	return int((Time.get_ticks_usec() - started_us) / 1000)


func snapshot() -> Dictionary:
	return {
		"suite": suite_name,
		"environment": environment.duplicate(true),
		"stage": stage_name,
		"detail": stage_detail,
		"progress_current": progress_current,
		"progress_total": progress_total,
		"metrics": metrics.duplicate(true),
		"log": Array(log_lines),
		"elapsed_ms": elapsed_ms(),
		"completed": completed,
		"passed": passed,
	}


func _emit() -> void:
	updated.emit(snapshot())
