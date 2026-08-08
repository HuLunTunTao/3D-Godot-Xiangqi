extends Node

## Diagnostic: re-test Godot 4.6.x iOS GPU after PCK weight-path fix.
## Writes user://gpu_probe_result.json (copied from device Documents).
## Does NOT use the old minor-version CPU gate; measures raw GPU vs CPU.

const NNUELoader = preload("res://addons/pikafish/nnue/loader.gd")
const XFeatures = preload("res://addons/pikafish/nnue/features.gd")
const XGpuInference = preload("res://addons/pikafish/nnue/gpu_inference.gd")
const XRefInference = preload("res://addons/pikafish/nnue/cpu_inference.gd")
const XBoard = preload("res://addons/pikafish/nnue/board.gd")
const PikafishEngineScript = preload("res://addons/pikafish/pikafish.gd")
const PikafishConfigScript = preload("res://addons/pikafish/config.gd")
const Reporter = preload("res://src/test/ui/test_reporter.gd")
const Dashboard = preload("res://src/test/ui/test_dashboard.gd")

const RESULT_PATH := "user://gpu_probe_result.json"


func _ready() -> void:
	_reporter = Reporter.new("Mobile GPU diagnostic")
	var dashboard = Dashboard.new()
	add_child(dashboard)
	dashboard.bind(_reporter)
	call_deferred("_run")


func _run() -> void:
	_reporter.stage("Loading NNUE weights")
	var result := {
		"device": OS.get_model_name(),
		"os": OS.get_version(),
		"godot": Engine.get_version_info(),
		"platform": OS.get_name(),
	}
	var loader := NNUELoader.new()
	var load_err: Error = loader.load_all("res://data")
	result["load_error"] = loader.load_error
	result["load_ok"] = load_err == OK
	result["network_dir"] = loader.network_dir
	result["ft_threat_w_bytes"] = loader.ft_threat_w.size() if loader.loaded else 0
	result["ft_psq_w_bytes"] = loader.ft_psq_w.size() if loader.loaded else 0
	if load_err != OK:
		_reporter.report_log("NNUE load failed: %s" % loader.load_error, "FAIL")
		_finish(result, false)
		return
	_reporter.metric("network_dir", loader.network_dir)

	var features := XFeatures.new(loader)
	var cpu := XRefInference.new(loader, features)
	var records := _load_reference()
	result["oracle_count"] = records.size()

	var boards: Array = []
	var expected := PackedInt32Array()
	expected.resize(records.size())
	for i in range(records.size()):
		var b := XBoard.new()
		b.load_fen(records[i]["fen"])
		boards.append(b)
		expected[i] = int(records[i]["internal"])

	# Facade/canary path (production selection)
	var engine = PikafishEngineScript.new()
	_reporter.stage("Production backend and GPU canary")
	var cfg = PikafishConfigScript.new()
	cfg.network_dir = "res://data"
	cfg.prefer_gpu = true
	cfg.allow_ios_gpu_probe = true
	var init_err: Error = engine.initialize(cfg)
	result["facade_init_ok"] = init_err == OK
	result["facade_backend"] = engine.backend_info()
	_reporter.metric("facade_backend", result["facade_backend"].get("backend", "unknown"))
	_reporter.metric("canary", result["facade_backend"].get("canary_ok", false))
	_reporter.report_log("facade backend=%s canary=%s" % [result["facade_backend"].get("backend", "unknown"), result["facade_backend"].get("canary_ok", false)])

	# Forced GPU construction (diagnostic — ignore canary)
	var gpu = XGpuInference.try_create(loader, features)
	result["gpu_construct_ok"] = gpu != null and gpu.ready
	if gpu == null or not gpu.ready:
		_reporter.report_log("forced GPU unavailable; validating CPU fallback", "WARN")
		result["forced_gpu"] = {"skipped": true, "reason": "try_create failed"}
		engine.shutdown()
		_finish(result, result["facade_backend"].get("backend", "") == "cpu")
		return
	_reporter.stage("Forced GPU oracle", records.size())
	result["minimal_compute_probe"] = _minimal_compute_probe(gpu)
	result["empty_output_compute_probe"] = _empty_output_compute_probe(gpu)
	result["shader_load_probe"] = _shader_load_probe()

	var sync_bad := 0
	var sync_started := Time.get_ticks_usec()
	var gpu_vals: PackedInt32Array = gpu.evaluate_batch(boards)
	var cpu_vals: PackedInt32Array = cpu.evaluate_batch(boards)
	for i in range(boards.size()):
		if absi(gpu_vals[i] - expected[i]) > 1:
			sync_bad += 1
	var cpu_bad := 0
	for i in range(boards.size()):
		if absi(cpu_vals[i] - expected[i]) > 1:
			cpu_bad += 1
	var gpu_vs_cpu_bad := 0
	for i in range(boards.size()):
		if absi(gpu_vals[i] - cpu_vals[i]) > 1:
			gpu_vs_cpu_bad += 1
	var sync_ms := float(Time.get_ticks_usec() - sync_started) / 1000.0
	result["forced_gpu"] = {
		"oracle_bad": sync_bad,
		"cpu_oracle_bad": cpu_bad,
		"gpu_vs_cpu_bad": gpu_vs_cpu_bad,
		"ms": sync_ms,
		"eval_s": boards.size() * 1000.0 / maxf(sync_ms, 0.001),
		"sample_gpu": Array(gpu_vals).slice(0, mini(5, gpu_vals.size())),
		"sample_cpu": Array(cpu_vals).slice(0, mini(5, cpu_vals.size())),
		"sample_exp": Array(expected).slice(0, mini(5, expected.size())),
	}
	_reporter.progress(records.size(), records.size(), "oracle mismatches: %d" % sync_bad)
	_reporter.metric("forced_gpu_eval_s", "%.0f" % result["forced_gpu"]["eval_s"])
	_reporter.metric("forced_gpu_oracle_bad", sync_bad)
	_reporter.report_log("forced GPU oracle: bad=%d eval/s=%.0f" % [sync_bad, result["forced_gpu"]["eval_s"]])

	# Split batch stages for iOS diagnosis. `evaluate_batch()` has already filled
	# b_acc_buf and b_out_buf: a non-zero accumulator proves uploads, bindings and
	# the first dispatch work, isolating any all-zero final result to forward.
	var acc_probe: PackedByteArray = gpu.rd.buffer_get_data(gpu.b_acc_buf, 0, 256)
	var acc_nonzero := 0
	var acc_sample := PackedInt32Array()
	for i in range(64):
		var v: int = acc_probe.decode_s32(i * 4)
		if v != 0:
			acc_nonzero += 1
		if i < 8:
			acc_sample.append(v)
	result["batch_accumulator_probe"] = {
		"nonzero_first64": acc_nonzero,
		"sample": Array(acc_sample),
	}
	result["nnue_binding_probe"] = _nnue_binding_probe(gpu)
	result["accumulator_only_probe"] = _accumulator_only_probe(gpu, boards[0])
	result["accumulator_shape_probe"] = _accumulator_shape_probe(gpu)
	# Bisect production accumulator logic on-device (bias → unpack → loops).
	result["layered_accumulator_probes"] = _layered_accumulator_probes(gpu, boards[0], cpu)

	# The original canary exercises only forward_batch.glsl. Check the scalar
	# accumulator+forward shaders separately before attributing the issue to
	# Metal compute generally.
	var scalar_gpu: int = gpu.evaluate(boards[0])
	var scalar_cpu: int = cpu.evaluate(boards[0])
	result["scalar_gpu_probe"] = {
		"gpu": scalar_gpu,
		"cpu": scalar_cpu,
		"expected": expected[0],
		"abs_diff": absi(scalar_gpu - scalar_cpu),
	}

	# 100 x batch23 if forced GPU oracle is clean
	if sync_bad == 0:
		var reps := 100
		var bad100 := 0
		var t0 := Time.get_ticks_usec()
		_reporter.stage("Forced GPU 100× oracle batch", reps)
		for rep in range(reps):
			bad100 += _count_bad(gpu.evaluate_batch(boards), expected)
			if rep % 5 == 4 or rep + 1 == reps:
				_reporter.progress(rep + 1, reps, "oracle mismatches: %d" % bad100)
				await get_tree().process_frame
		var ms100 := float(Time.get_ticks_usec() - t0) / 1000.0
		result["forced_gpu_100x23"] = {
			"bad": bad100,
			"eval_s": reps * boards.size() * 1000.0 / maxf(ms100, 0.001),
			"ms": ms100,
		}

	# Keep production GPU alive for facade async acceptance (uses engine path).
	gpu.dispose()
	var probe_ok: bool = (
		sync_bad == 0
		and result["facade_backend"].get("backend", "") == "gpu"
	)
	if not probe_ok:
		engine.shutdown()
		_finish(result, false)
		return

	# Async 100x23 via production facade (must stay on GPU after canary).
	_probe_result = result
	_probe_engine = engine
	_probe_boards = boards
	_probe_expected = expected
	_async_submitted = 0
	_async_done = 0
	_async_bad = 0
	_callback_order.clear()
	_async_started_us = Time.get_ticks_usec()
	_reporter.stage("Production async three-slot batch", 100)
	_fill_async_slots()


var _probe_result: Dictionary
var _probe_engine
var _probe_boards: Array = []
var _probe_expected := PackedInt32Array()
var _async_submitted := 0
var _async_done := 0
var _async_bad := 0
var _async_started_us := 0
var _callback_order: Array[int] = []
var _reporter


func _fill_async_slots() -> void:
	while _async_submitted < 100 and _async_submitted - _async_done < 3:
		var request_id := _async_submitted
		var error: Error = _probe_engine.evaluate_batch_async(
			_probe_boards, _on_async_batch.bind(request_id))
		if error != OK:
			_probe_result["forced_gpu_async_100x23"] = {
				"submit_error": error,
				"submitted": _async_submitted,
				"done": _async_done,
			}
			_probe_engine.shutdown()
			_finish(_probe_result, false)
			return
		_async_submitted += 1


func _on_async_batch(batch_result: PackedInt32Array, request_id: int) -> void:
	_callback_order.append(request_id)
	_async_bad += _count_bad(batch_result, _probe_expected)
	_async_done += 1
	_reporter.progress(_async_done, 100, "oracle mismatches: %d" % _async_bad)
	if _async_done < 100:
		_fill_async_slots()
		return
	var async_ms := float(Time.get_ticks_usec() - _async_started_us) / 1000.0
	var ordered := true
	for i in range(_callback_order.size()):
		if _callback_order[i] != i:
			ordered = false
			break
	_probe_result["forced_gpu_async_100x23"] = {
		"bad": _async_bad,
		"ordered": ordered,
		"eval_s": 100 * _probe_boards.size() * 1000.0 / maxf(async_ms, 0.001),
		"ms": async_ms,
		"backend": _probe_engine.backend_info().get("backend", ""),
	}
	_reporter.metric("async_eval_s", "%.0f" % _probe_result["forced_gpu_async_100x23"]["eval_s"])
	_reporter.metric("async_oracle_bad", _async_bad)
	_reporter.report_log("async batch: bad=%d ordered=%s eval/s=%.0f" % [_async_bad, ordered, _probe_result["forced_gpu_async_100x23"]["eval_s"]])
	var ok: bool = (
		_async_bad == 0
		and ordered
		and _probe_result["facade_backend"].get("backend", "") == "gpu"
	)
	_probe_engine.shutdown()
	_finish(_probe_result, ok)


func _count_bad(got: PackedInt32Array, expected: PackedInt32Array) -> int:
	if got.size() != expected.size():
		return expected.size()
	var bad := 0
	for i in range(got.size()):
		if absi(got[i] - expected[i]) > 1:
			bad += 1
	return bad


func _finish(result: Dictionary, ok: bool) -> void:
	result["ok"] = ok
	result["marker"] = "GPU_PROBE_PASS" if ok else "GPU_PROBE_FAIL"
	result["environment"] = _reporter.environment if _reporter != null else {}
	var f := FileAccess.open(RESULT_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(result, "\t"))
		f.close()
	print(result["marker"])
	print(JSON.stringify(result))
	if _reporter != null:
		_reporter.finish(ok, result["marker"])
		_reporter.report_log("report saved: %s" % RESULT_PATH)
	if OS.get_cmdline_user_args().has("--auto-quit"):
		# Give filesystem a tick on iOS before quit.
		await get_tree().create_timer(0.5).timeout
		get_tree().quit(0 if ok else 1)


static func _load_reference() -> Array:
	var file := FileAccess.open("res://data/reference.json", FileAccess.READ)
	var records: Array = JSON.parse_string(file.get_as_text())
	file.close()
	return records


func _minimal_compute_probe(gpu) -> Dictionary:
	# Isolate local RenderingDevice dispatch + storage-buffer readback from NNUE.
	var source := """#version 450
layout(local_size_x = 1) in;
layout(set = 0, binding = 0) buffer OutBuf { int out_val[]; };
void main() { out_val[0] = 12345; }
"""
	return _run_compute_probe(gpu, source, [])


func _shader_load_probe() -> Dictionary:
	# Diagnose exported-PCK remap: text FileAccess vs RDShaderFile SPIR-V.
	var path := "res://addons/pikafish/shaders/accumulator.glsl"
	var out := {"path": path}
	var res = load(path)
	out["load_class"] = res.get_class() if res != null else "null"
	out["is_rd_shader_file"] = res is RDShaderFile
	if res is RDShaderFile:
		var spirv: RDShaderSPIRV = (res as RDShaderFile).get_spirv()
		var err: String = spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
		var bytecode: PackedByteArray = spirv.get_stage_bytecode(RenderingDevice.SHADER_STAGE_COMPUTE)
		out["spirv_error"] = err
		out["spirv_bytecode_bytes"] = bytecode.size()
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		out["fileaccess_error"] = "open failed"
	else:
		var text := f.get_as_text()
		f.close()
		out["fileaccess_bytes"] = text.length()
		out["fileaccess_starts_with_version"] = text.strip_edges().begins_with("#version")
		out["fileaccess_has_ri8"] = text.contains("ri8_psq")
		out["fileaccess_prefix_hex"] = text.substr(0, mini(16, text.length())).to_utf8_buffer().hex_encode()
	return out


func _empty_output_compute_probe(gpu) -> Dictionary:
	# NNUE's acc/out buffers are created with a requested size and an empty
	# PackedByteArray. Verify that this iOS 4.6.1 path is actually writable.
	var source := """#version 450
layout(local_size_x = 1) in;
layout(set = 0, binding = 0) buffer OutBuf { int out_val[]; };
void main() { out_val[0] = 23456; }
"""
	return _run_compute_probe(gpu, source, [], true)


func _nnue_binding_probe(gpu) -> Dictionary:
	# Same large storage buffers and integer element types as accumulator.glsl,
	# but only one invocation and one deterministic output write.
	var source := """#version 450
layout(local_size_x = 1) in;
layout(set = 0, binding = 0) readonly buffer BiasBuf { int ft_bias[]; };
layout(set = 0, binding = 1) readonly buffer PsqWBuf { uint psq_w[]; };
layout(set = 0, binding = 2) readonly buffer ThreatWBuf { uint threat_w[]; };
layout(set = 0, binding = 3) readonly buffer ActvBuf { int actv[]; };
layout(set = 0, binding = 4) buffer OutBuf { int out_val[]; };
void main() {
	int v = ft_bias[0] + int(psq_w[0] & 1u) + int(threat_w[0] & 1u) + actv[0];
	out_val[0] = v;
}
"""
	return _run_compute_probe(gpu, source, [
		gpu.ft_bias_buf, gpu.psq_w_buf, gpu.threat_w_buf, gpu.b_active_buf,
	])


func _accumulator_shape_probe(gpu) -> Dictionary:
	# Preserve accumulator.glsl's 64-lane dispatch, five bindings, 1024 output
	# indexing and indirect feature index, while avoiding its feature loops.
	var source := """#version 450
layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;
layout(set = 0, binding = 0) readonly buffer BiasBuf { int ft_bias[]; };
layout(set = 0, binding = 1) readonly buffer PsqWBuf { uint psq_w[]; };
layout(set = 0, binding = 2) readonly buffer ThreatWBuf { uint threat_w[]; };
layout(set = 0, binding = 3) readonly buffer ActvBuf { int actv[]; };
layout(set = 0, binding = 4) buffer AccBuf { int acc[]; };
void main() {
	uint gid = gl_GlobalInvocationID.x;
	if (gid >= 1024u) return;
	int i = int(gid);
	uint pi = uint(actv[1] * 1024 + i) >> 2u;
	uint ti = uint(actv[66] * 1024 + i) >> 2u;
	int v = ft_bias[i] + int(psq_w[pi] & 1u) + int(threat_w[ti] & 1u) + actv[0];
	acc[i] = v;
	acc[1024 + i] = v;
}
"""
	return _dispatch_acc_probe(gpu, source)


func _layered_accumulator_probes(gpu, board, cpu) -> Dictionary:
	# Recommended bisect order for Godot 4.6.1 iOS SPIR-V→Metal accumulator failure.
	# Each stage writes acc[0..1023] (and often acc[1024..]) using production bindings.
	gpu._fill_batch_actives([board])
	var cpu_acc := _cpu_acc_sample(cpu, board)
	var out := {
		"cpu_acc_p0_sample": Array(cpu_acc["p0"]),
		"cpu_acc_p1_sample": Array(cpu_acc["p1"]),
		"actv_counts": {
			"p0_psq": int(gpu._b_active[0]),
			"p0_thr": int(gpu._b_active[65]),
			"p1_psq": int(gpu._b_active[130]),
			"p1_thr": int(gpu._b_active[195]),
		},
	}

	# a) bias-only
	out["a_bias_only"] = _dispatch_acc_probe(gpu, """#version 450
layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;
layout(set = 0, binding = 0) readonly buffer BiasBuf { int ft_bias[]; };
layout(set = 0, binding = 1) readonly buffer PsqWBuf { uint psq_w[]; };
layout(set = 0, binding = 2) readonly buffer ThreatWBuf { uint threat_w[]; };
layout(set = 0, binding = 3) readonly buffer ActvBuf { int actv[]; };
layout(set = 0, binding = 4) buffer AccBuf { int acc[]; };
void main() {
	uint gid = gl_GlobalInvocationID.x;
	if (gid >= 1024u) return;
	int i = int(gid);
	acc[i] = ft_bias[i];
	acc[1024 + i] = ft_bias[i];
}
""")

	# b) single PSQ feature raw ri8_psq unpack (production expression)
	out["b_single_psq_ri8"] = _dispatch_acc_probe(gpu, """#version 450
layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;
layout(set = 0, binding = 0) readonly buffer BiasBuf { int ft_bias[]; };
layout(set = 0, binding = 1) readonly buffer PsqWBuf { uint psq_w[]; };
layout(set = 0, binding = 2) readonly buffer ThreatWBuf { uint threat_w[]; };
layout(set = 0, binding = 3) readonly buffer ActvBuf { int actv[]; };
layout(set = 0, binding = 4) buffer AccBuf { int acc[]; };
const int L1 = 1024;
int ri8_psq(int idx) {
	uint w = psq_w[uint(idx) >> 2u];
	int b = int((w >> ((uint(idx) & 3u) * 8u)) & 0xFFu);
	return (b >= 128) ? b - 256 : b;
}
void main() {
	uint gid = gl_GlobalInvocationID.x;
	if (gid >= 1024u) return;
	int i = int(gid);
	int a = ft_bias[i];
	if (actv[0] > 0) a += ri8_psq(actv[1] * L1 + i);
	acc[i] = a;
	acc[1024 + i] = a;
}
""")

	# b2) same single PSQ but with branchless arithmetic sign-extend + fixed shifts
	out["b2_single_psq_alt_unpack"] = _dispatch_acc_probe(gpu, """#version 450
layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;
layout(set = 0, binding = 0) readonly buffer BiasBuf { int ft_bias[]; };
layout(set = 0, binding = 1) readonly buffer PsqWBuf { uint psq_w[]; };
layout(set = 0, binding = 2) readonly buffer ThreatWBuf { uint threat_w[]; };
layout(set = 0, binding = 3) readonly buffer ActvBuf { int actv[]; };
layout(set = 0, binding = 4) buffer AccBuf { int acc[]; };
const int L1 = 1024;
int ri8_psq(int idx) {
	uint w = psq_w[uint(idx) >> 2u];
	uint lane = uint(idx) & 3u;
	uint b;
	if (lane == 0u) b = w & 0xFFu;
	else if (lane == 1u) b = (w >> 8u) & 0xFFu;
	else if (lane == 2u) b = (w >> 16u) & 0xFFu;
	else b = (w >> 24u) & 0xFFu;
	return int(b << 24u) >> 24;
}
void main() {
	uint gid = gl_GlobalInvocationID.x;
	if (gid >= 1024u) return;
	int i = int(gid);
	int a = ft_bias[i];
	if (actv[0] > 0) a += ri8_psq(actv[1] * L1 + i);
	acc[i] = a;
	acc[1024 + i] = a;
}
""")

	# c) PSQ dynamic feature loop (perspective 0 only)
	out["c_psq_dynamic_loop"] = _dispatch_acc_probe(gpu, """#version 450
layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;
layout(set = 0, binding = 0) readonly buffer BiasBuf { int ft_bias[]; };
layout(set = 0, binding = 1) readonly buffer PsqWBuf { uint psq_w[]; };
layout(set = 0, binding = 2) readonly buffer ThreatWBuf { uint threat_w[]; };
layout(set = 0, binding = 3) readonly buffer ActvBuf { int actv[]; };
layout(set = 0, binding = 4) buffer AccBuf { int acc[]; };
const int L1 = 1024;
int ri8_psq(int idx) {
	uint w = psq_w[uint(idx) >> 2u];
	uint lane = uint(idx) & 3u;
	uint b;
	if (lane == 0u) b = w & 0xFFu;
	else if (lane == 1u) b = (w >> 8u) & 0xFFu;
	else if (lane == 2u) b = (w >> 16u) & 0xFFu;
	else b = (w >> 24u) & 0xFFu;
	return int(b << 24u) >> 24;
}
void main() {
	uint gid = gl_GlobalInvocationID.x;
	if (gid >= 1024u) return;
	int i = int(gid);
	int a0 = ft_bias[i];
	int p0c = actv[0];
	for (int k = 0; k < p0c; k++) { a0 += ri8_psq(actv[1 + k] * L1 + i); }
	acc[i] = a0;
	acc[1024 + i] = a0;
}
""")

	# d) single threat feature raw ri8_thr (production expression)
	out["d_single_thr_ri8"] = _dispatch_acc_probe(gpu, """#version 450
layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;
layout(set = 0, binding = 0) readonly buffer BiasBuf { int ft_bias[]; };
layout(set = 0, binding = 1) readonly buffer PsqWBuf { uint psq_w[]; };
layout(set = 0, binding = 2) readonly buffer ThreatWBuf { uint threat_w[]; };
layout(set = 0, binding = 3) readonly buffer ActvBuf { int actv[]; };
layout(set = 0, binding = 4) buffer AccBuf { int acc[]; };
const int L1 = 1024;
int ri8_thr(int idx) {
	uint w = threat_w[uint(idx) >> 2u];
	int b = int((w >> ((uint(idx) & 3u) * 8u)) & 0xFFu);
	return (b >= 128) ? b - 256 : b;
}
void main() {
	uint gid = gl_GlobalInvocationID.x;
	if (gid >= 1024u) return;
	int i = int(gid);
	int a = ft_bias[i];
	if (actv[65] > 0) a += ri8_thr(actv[66] * L1 + i);
	acc[i] = a;
	acc[1024 + i] = a;
}
""")

	# d2) single threat with alt unpack
	out["d2_single_thr_alt_unpack"] = _dispatch_acc_probe(gpu, """#version 450
layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;
layout(set = 0, binding = 0) readonly buffer BiasBuf { int ft_bias[]; };
layout(set = 0, binding = 1) readonly buffer PsqWBuf { uint psq_w[]; };
layout(set = 0, binding = 2) readonly buffer ThreatWBuf { uint threat_w[]; };
layout(set = 0, binding = 3) readonly buffer ActvBuf { int actv[]; };
layout(set = 0, binding = 4) buffer AccBuf { int acc[]; };
const int L1 = 1024;
int ri8_thr(int idx) {
	uint w = threat_w[uint(idx) >> 2u];
	uint lane = uint(idx) & 3u;
	uint b;
	if (lane == 0u) b = w & 0xFFu;
	else if (lane == 1u) b = (w >> 8u) & 0xFFu;
	else if (lane == 2u) b = (w >> 16u) & 0xFFu;
	else b = (w >> 24u) & 0xFFu;
	return int(b << 24u) >> 24;
}
void main() {
	uint gid = gl_GlobalInvocationID.x;
	if (gid >= 1024u) return;
	int i = int(gid);
	int a = ft_bias[i];
	if (actv[65] > 0) a += ri8_thr(actv[66] * L1 + i);
	acc[i] = a;
	acc[1024 + i] = a;
}
""")

	# e) threat dynamic loop (perspective 0)
	out["e_thr_dynamic_loop"] = _dispatch_acc_probe(gpu, """#version 450
layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;
layout(set = 0, binding = 0) readonly buffer BiasBuf { int ft_bias[]; };
layout(set = 0, binding = 1) readonly buffer PsqWBuf { uint psq_w[]; };
layout(set = 0, binding = 2) readonly buffer ThreatWBuf { uint threat_w[]; };
layout(set = 0, binding = 3) readonly buffer ActvBuf { int actv[]; };
layout(set = 0, binding = 4) buffer AccBuf { int acc[]; };
const int L1 = 1024;
int ri8_thr(int idx) {
	uint w = threat_w[uint(idx) >> 2u];
	uint lane = uint(idx) & 3u;
	uint b;
	if (lane == 0u) b = w & 0xFFu;
	else if (lane == 1u) b = (w >> 8u) & 0xFFu;
	else if (lane == 2u) b = (w >> 16u) & 0xFFu;
	else b = (w >> 24u) & 0xFFu;
	return int(b << 24u) >> 24;
}
void main() {
	uint gid = gl_GlobalInvocationID.x;
	if (gid >= 1024u) return;
	int i = int(gid);
	int a0 = ft_bias[i];
	int t0c = actv[65];
	for (int k = 0; k < t0c; k++) { a0 += ri8_thr(actv[66 + k] * L1 + i); }
	acc[i] = a0;
	acc[1024 + i] = a0;
}
""")

	# f) dual-perspective full accumulator with alt unpack (candidate fix)
	out["f_full_alt_unpack"] = _dispatch_acc_probe(gpu, """#version 450
layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;
layout(set = 0, binding = 0) readonly buffer BiasBuf { int ft_bias[]; };
layout(set = 0, binding = 1) readonly buffer PsqWBuf { uint psq_w[]; };
layout(set = 0, binding = 2) readonly buffer ThreatWBuf { uint threat_w[]; };
layout(set = 0, binding = 3) readonly buffer ActvBuf { int actv[]; };
layout(set = 0, binding = 4) buffer AccBuf { int acc[]; };
const int L1 = 1024;
int unpack_i8(uint w, uint idx) {
	uint lane = idx & 3u;
	uint b;
	if (lane == 0u) b = w & 0xFFu;
	else if (lane == 1u) b = (w >> 8u) & 0xFFu;
	else if (lane == 2u) b = (w >> 16u) & 0xFFu;
	else b = (w >> 24u) & 0xFFu;
	return int(b << 24u) >> 24;
}
int ri8_psq(int idx) {
	uint u = uint(idx);
	return unpack_i8(psq_w[u >> 2u], u);
}
int ri8_thr(int idx) {
	uint u = uint(idx);
	return unpack_i8(threat_w[u >> 2u], u);
}
void main() {
	uint gi = gl_GlobalInvocationID.x;
	if (gi >= 1024u) return;
	int i = int(gi);

	int a0 = ft_bias[i];
	int p0c = actv[0];
	for (int k = 0; k < p0c; k++) { a0 += ri8_psq(actv[1 + k] * L1 + i); }
	int t0c = actv[65];
	for (int k = 0; k < t0c; k++) { a0 += ri8_thr(actv[66 + k] * L1 + i); }
	acc[i] = a0;

	int a1 = ft_bias[i];
	int p1c = actv[130];
	for (int k = 0; k < p1c; k++) { a1 += ri8_psq(actv[131 + k] * L1 + i); }
	int t1c = actv[195];
	for (int k = 0; k < t1c; k++) { a1 += ri8_thr(actv[196 + k] * L1 + i); }
	acc[1024 + i] = a1;
}
""")

	# f2) full with production unpack (control)
	out["f2_full_prod_unpack"] = _dispatch_acc_probe(gpu, """#version 450
layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;
layout(set = 0, binding = 0) readonly buffer BiasBuf { int ft_bias[]; };
layout(set = 0, binding = 1) readonly buffer PsqWBuf { uint psq_w[]; };
layout(set = 0, binding = 2) readonly buffer ThreatWBuf { uint threat_w[]; };
layout(set = 0, binding = 3) readonly buffer ActvBuf { int actv[]; };
layout(set = 0, binding = 4) buffer AccBuf { int acc[]; };
const int L1 = 1024;
int ri8_psq(int idx) {
	uint w = psq_w[uint(idx) >> 2u];
	int b = int((w >> ((uint(idx) & 3u) * 8u)) & 0xFFu);
	return (b >= 128) ? b - 256 : b;
}
int ri8_thr(int idx) {
	uint w = threat_w[uint(idx) >> 2u];
	int b = int((w >> ((uint(idx) & 3u) * 8u)) & 0xFFu);
	return (b >= 128) ? b - 256 : b;
}
void main() {
	uint gi = gl_GlobalInvocationID.x;
	if (gi >= 1024u) return;
	int i = int(gi);
	int a0 = ft_bias[i];
	int p0c = actv[0];
	for (int k = 0; k < p0c; k++) { a0 += ri8_psq(actv[1 + k] * L1 + i); }
	int t0c = actv[65];
	for (int k = 0; k < t0c; k++) { a0 += ri8_thr(actv[66 + k] * L1 + i); }
	acc[i] = a0;
	int a1 = ft_bias[i];
	int p1c = actv[130];
	for (int k = 0; k < p1c; k++) { a1 += ri8_psq(actv[131 + k] * L1 + i); }
	int t1c = actv[195];
	for (int k = 0; k < t1c; k++) { a1 += ri8_thr(actv[196 + k] * L1 + i); }
	acc[1024 + i] = a1;
}
""")

	return out


func _cpu_acc_sample(cpu, board) -> Dictionary:
	# Rebuild perspective-0/1 accumulator first 8 cells via CPU reference weights.
	var loader = cpu.loader
	var features = cpu.features
	var C = preload("res://addons/pikafish/nnue/consts.gd")
	var stm: int = board.side_to_move()
	var perspectives := [stm, C.flip_color(stm)]
	var samples := {"p0": PackedInt32Array(), "p1": PackedInt32Array()}
	samples["p0"].resize(8)
	samples["p1"].resize(8)
	for p in range(2):
		var persp: int = perspectives[p]
		var fb = features.make_feature_bucket(persp, board)
		var psq_active = features.append_active_psq(persp, board, fb.bucket, fb.mirror)
		var threat_active = features.append_active_threats(persp, board, fb.mirror)
		var bias_raw: PackedByteArray = loader.ft_bias_raw
		var psqw: PackedByteArray = loader.ft_psq_w
		var tw: PackedByteArray = loader.ft_threat_w
		for i in range(8):
			var a: int = bias_raw.decode_s16(i * 2)
			for idx in psq_active:
				var b: int = psqw[idx * C.L1 + i]
				a += b if b < 128 else b - 256
			for idx in threat_active:
				var b2: int = tw[idx * C.L1 + i]
				a += b2 if b2 < 128 else b2 - 256
			if p == 0:
				samples["p0"][i] = a
			else:
				samples["p1"][i] = a
	return samples


func _dispatch_acc_probe(gpu, source: String) -> Dictionary:
	var rd: RenderingDevice = gpu.rd
	var shader_source := RDShaderSource.new()
	shader_source.set_stage_source(RenderingDevice.SHADER_STAGE_COMPUTE, source)
	var spirv: RDShaderSPIRV = rd.shader_compile_spirv_from_source(shader_source)
	var compile_error: String = spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
	if not compile_error.is_empty():
		return {"compile_error": compile_error}
	var shader: RID = rd.shader_create_from_spirv(spirv)
	if not shader.is_valid():
		return {"compile_error": "shader_create_from_spirv failed"}
	var pipeline: RID = rd.compute_pipeline_create(shader)
	# Clear first 256 bytes so a no-op dispatch cannot look like a prior success.
	var zeros := PackedByteArray()
	zeros.resize(256)
	rd.buffer_update(gpu.b_acc_buf, 0, 256, zeros)
	var uniform_set: RID = rd.uniform_set_create([
		_storage_uniform(0, gpu.ft_bias_buf), _storage_uniform(1, gpu.psq_w_buf),
		_storage_uniform(2, gpu.threat_w_buf), _storage_uniform(3, gpu.b_active_buf),
		_storage_uniform(4, gpu.b_acc_buf),
	], shader, 0)
	var cl := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cl, pipeline)
	rd.compute_list_bind_uniform_set(cl, uniform_set, 0)
	rd.compute_list_dispatch(cl, 16, 1, 1)
	rd.compute_list_end()
	rd.submit()
	rd.sync()
	var bytes: PackedByteArray = rd.buffer_get_data(gpu.b_acc_buf, 0, 256)
	var bytes_p1: PackedByteArray = rd.buffer_get_data(gpu.b_acc_buf, 1024 * 4, 32)
	var nonzero := 0
	var sample := PackedInt32Array()
	var sample_p1 := PackedInt32Array()
	for i in range(64):
		var v: int = bytes.decode_s32(i * 4)
		if v != 0:
			nonzero += 1
		if i < 8:
			sample.append(v)
	for i in range(8):
		sample_p1.append(bytes_p1.decode_s32(i * 4))
	rd.free_rid(uniform_set)
	rd.free_rid(pipeline)
	rd.free_rid(shader)
	return {
		"nonzero_first64": nonzero,
		"sample": Array(sample),
		"sample_p1": Array(sample_p1),
	}


func _accumulator_only_probe(gpu, board) -> Dictionary:
	# Re-run the exact production accumulator pipeline by itself. The ordinary
	# batch call dispatches forward immediately afterwards, so this separates a
	# failing accumulator shader from a later command-list interaction.
	gpu._fill_batch_actives([board])
	var rd: RenderingDevice = gpu.rd
	var cl := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cl, gpu.b_acc_pipe)
	rd.compute_list_bind_uniform_set(cl, gpu.b_acc_set, 0)
	rd.compute_list_dispatch(cl, 16, 1, 1)
	rd.compute_list_end()
	rd.submit()
	rd.sync()
	var bytes: PackedByteArray = rd.buffer_get_data(gpu.b_acc_buf, 0, 256)
	var nonzero := 0
	var sample := PackedInt32Array()
	for i in range(64):
		var v: int = bytes.decode_s32(i * 4)
		if v != 0:
			nonzero += 1
		if i < 8:
			sample.append(v)
	return {"nonzero_first64": nonzero, "sample": Array(sample)}


func _run_compute_probe(gpu, source: String, inputs: Array, empty_initial_data := false) -> Dictionary:
	var rd: RenderingDevice = gpu.rd
	var shader_source := RDShaderSource.new()
	shader_source.set_stage_source(RenderingDevice.SHADER_STAGE_COMPUTE, source)
	var spirv: RDShaderSPIRV = rd.shader_compile_spirv_from_source(shader_source)
	var compile_error: String = spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
	if not compile_error.is_empty():
		return {"compile_error": compile_error}
	var shader: RID = rd.shader_create_from_spirv(spirv)
	if not shader.is_valid():
		return {"compile_error": "shader_create_from_spirv failed"}
	var pipeline: RID = rd.compute_pipeline_create(shader)
	var initial_data := PackedByteArray()
	if not empty_initial_data:
		initial_data.resize(4)
	var out_buf: RID = rd.storage_buffer_create(4, initial_data)
	var uniforms: Array = []
	for i in range(inputs.size()):
		uniforms.append(_storage_uniform(i, inputs[i]))
	uniforms.append(_storage_uniform(inputs.size(), out_buf))
	var uniform_set: RID = rd.uniform_set_create(uniforms, shader, 0)
	var cl := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cl, pipeline)
	rd.compute_list_bind_uniform_set(cl, uniform_set, 0)
	rd.compute_list_dispatch(cl, 1, 1, 1)
	rd.compute_list_end()
	rd.submit()
	rd.sync()
	var value: int = rd.buffer_get_data(out_buf, 0, 4).decode_s32(0)
	rd.free_rid(uniform_set)
	rd.free_rid(out_buf)
	rd.free_rid(pipeline)
	rd.free_rid(shader)
	return {"value": value, "inputs": inputs.size(), "empty_initial_data": empty_initial_data}


func _storage_uniform(binding: int, buffer: RID) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	uniform.binding = binding
	uniform.add_id(buffer)
	return uniform
