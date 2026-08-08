## GPU (compute-shader) NNUE inference using RenderingDevice.
## Accumulator + forward(+PSQT) on GPU; CPU only builds active feature index lists.
## Prefer PikafishEngine / XNnueEngine for automatic CPU fallback when no RenderingDevice is available.

class_name PikafishGpuInference
extends RefCounted
const C = preload("res://addons/pikafish/nnue/consts.gd")
const XBoard = preload("res://addons/pikafish/nnue/board.gd")
const NNUELoader = preload("res://addons/pikafish/nnue/loader.gd")
const XFeatures = preload("res://addons/pikafish/nnue/features.gd")

var rd: RenderingDevice
var loader: NNUELoader
var features: XFeatures
var ready: bool = false
var _owns_rd := false
var _owned_shaders: Array[RID] = []
var _owned_pipelines: Array[RID] = []
var _owned_uniform_sets: Array[RID] = []
var _owned_buffers: Array[RID] = []

var acc_pipe: RID
var fwd_pipe: RID

var ft_bias_buf: RID
var psq_w_buf: RID
var threat_w_buf: RID
var psqt_buf: RID
var threat_psqt_buf: RID
var active_buf: RID
var acc_buf: RID
var out_buf: RID
var fwd_params_buf: RID
var acc_set: RID
var fwd_sets: Array = []  # one per layer-stack bucket (16)

const ACTIVE_SIZE = 260  # 4 * (1 + 64) ints
const BATCH_MAX = 512
const PARALLEL_FEATURE_THRESHOLD = 16
const HOST_CAPACITIES = [32, 64, 128, 256, 512]

# Reused host-side buffers
var _active: PackedInt32Array
var _params_bytes: PackedByteArray


static func try_create(ld: NNUELoader, ft: XFeatures) -> PikafishGpuInference:
	var device: RenderingDevice = RenderingServer.create_local_rendering_device()
	if device == null:
		return null
	return new(ld, ft, device, true)


func _init(
	ld: NNUELoader, ft: XFeatures,
	existing_rd: RenderingDevice = null, owns_existing_rd := false
) -> void:
	loader = ld
	features = ft
	if existing_rd != null:
		rd = existing_rd
		_owns_rd = owns_existing_rd
	else:
		rd = RenderingServer.create_local_rendering_device()
		_owns_rd = true
	if rd == null:
		push_error("PikafishGpuInference: no rendering device (use PikafishEngine for CPU fallback)")
		return
	_active = PackedInt32Array()
	_active.resize(ACTIVE_SIZE)
	_params_bytes = PackedByteArray()
	_params_bytes.resize(4)

	var acc_shader := _load_compute_shader("res://addons/pikafish/shaders/accumulator.glsl")
	acc_pipe = _create_pipeline(acc_shader)
	var fwd_shader := _load_compute_shader("res://addons/pikafish/shaders/forward.glsl")
	fwd_pipe = _create_pipeline(fwd_shader)

	ft_bias_buf = _create_storage(loader.ft_bias_i32.size(), loader.ft_bias_i32)
	psq_w_buf = _create_storage(loader.ft_psq_w.size(), loader.ft_psq_w)
	threat_w_buf = _create_storage(loader.ft_threat_w.size(), loader.ft_threat_w)
	psqt_buf = _create_storage(loader.ft_psqt_raw.size(), loader.ft_psqt_raw)
	threat_psqt_buf = _create_storage(loader.ft_threat_psqt_raw.size(), loader.ft_threat_psqt_raw)

	active_buf = _create_storage(ACTIVE_SIZE * 4, PackedByteArray())
	acc_buf = _create_storage(2 * C.L1 * 4, PackedByteArray())
	out_buf = _create_storage(4, PackedByteArray())
	fwd_params_buf = _create_storage(4, PackedByteArray())

	acc_set = _create_uniform_set([
		_u(0, ft_bias_buf), _u(1, psq_w_buf), _u(2, threat_w_buf),
		_u(3, active_buf), _u(4, acc_buf)], acc_shader, 0)

	for s in range(C.LAYERSTACKS):
		var fc0w := _create_storage(loader.fc0_w[s].size(), loader.fc0_w[s])
		var fc0b := _create_storage(loader.fc0_bias_raw[s].size(), loader.fc0_bias_raw[s])
		var fc1w := _create_storage(loader.fc1_w[s].size(), loader.fc1_w[s])
		var fc1b := _create_storage(loader.fc1_bias_raw[s].size(), loader.fc1_bias_raw[s])
		var fc2w := _create_storage(loader.fc2_w[s].size(), loader.fc2_w[s])
		var fc2b := _create_storage(loader.fc2_bias_raw[s].size(), loader.fc2_bias_raw[s])
		fwd_sets.append(_create_uniform_set([
			_u(0, acc_buf), _u(1, fc0w), _u(2, fc0b), _u(3, fc1w), _u(4, fc1b),
			_u(5, fc2w), _u(6, fc2b), _u(7, out_buf),
			_u(8, active_buf), _u(9, psqt_buf), _u(10, threat_psqt_buf),
			_u(11, fwd_params_buf)], fwd_shader, 0))
	ready = true


func dispose() -> void:
	ready = false
	if rd != null and _owns_rd:
		for rid in _owned_uniform_sets:
			if rid.is_valid():
				rd.free_rid(rid)
		for rid in _owned_pipelines:
			if rid.is_valid():
				rd.free_rid(rid)
		for rid in _owned_buffers:
			if rid.is_valid():
				rd.free_rid(rid)
		for rid in _owned_shaders:
			if rid.is_valid():
				rd.free_rid(rid)
		_owned_uniform_sets.clear()
		_owned_pipelines.clear()
		_owned_buffers.clear()
		_owned_shaders.clear()
		rd.free()
	rd = null


func _create_storage(size: int, data: PackedByteArray) -> RID:
	var rid := rd.storage_buffer_create(size, data)
	_owned_buffers.append(rid)
	return rid


func _create_pipeline(shader: RID) -> RID:
	var rid := rd.compute_pipeline_create(shader)
	_owned_pipelines.append(rid)
	return rid


func _create_uniform_set(uniforms: Array, shader: RID, set_index: int) -> RID:
	var rid := rd.uniform_set_create(uniforms, shader, set_index)
	_owned_uniform_sets.append(rid)
	return rid


static func _u(binding: int, buffer: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u.binding = binding
	u.add_id(buffer)
	return u


func _load_compute_shader(path: String) -> RID:
	# Exported projects remap *.glsl to imported RDShaderFile (SPIR-V). Reading
	# that path via FileAccess.get_as_text() yields binary garbage and produces
	# no-op pipelines on iOS. Prefer the importer bytecode; fall back to source
	# compile for unpackaged desktop checkouts.
	var spirv: RDShaderSPIRV
	var shader_file = load(path)
	if shader_file is RDShaderFile:
		spirv = (shader_file as RDShaderFile).get_spirv()
	else:
		var f := FileAccess.open(path, FileAccess.READ)
		assert(f != null, "cannot open shader " + path)
		var src := f.get_as_text()
		f.close()
		src = src.replace("#[compute]\n", "")
		var s := RDShaderSource.new()
		s.set_stage_source(RenderingDevice.SHADER_STAGE_COMPUTE, src)
		spirv = rd.shader_compile_spirv_from_source(s)
	var err: String = spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
	if err != "":
		push_error("shader compile error in " + path + ": " + err)
	var rid: RID = rd.shader_create_from_spirv(spirv)
	assert(rid.is_valid(), "failed to compile shader " + path)
	_owned_shaders.append(rid)
	return rid


func evaluate(pos: XBoard) -> int:
	assert(ready, "PikafishGpuInference not ready")
	var lbucket := features.fill_active_both(_active, 0, pos, pos.stm)
	_params_bytes.encode_s32(0, lbucket)
	rd.buffer_update(active_buf, 0, ACTIVE_SIZE * 4, _active.to_byte_array())
	rd.buffer_update(fwd_params_buf, 0, 4, _params_bytes)

	var cl := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cl, acc_pipe)
	rd.compute_list_bind_uniform_set(cl, acc_set, 0)
	rd.compute_list_dispatch(cl, 16, 1, 1)
	rd.compute_list_add_barrier(cl)
	rd.compute_list_bind_compute_pipeline(cl, fwd_pipe)
	rd.compute_list_bind_uniform_set(cl, fwd_sets[lbucket], 0)
	rd.compute_list_dispatch(cl, 1, 1, 1)
	rd.compute_list_end()
	rd.submit()
	rd.sync()
	return rd.buffer_get_data(out_buf).decode_s32(0)


# ---------------- batched ----------------
var batch_ready := false
var b_acc_pipe: RID
var b_fwd_pipe: RID
var b_active_buf: RID
var b_acc_buf: RID
var b_out_buf: RID
var b_bucket_buf: RID
var b_params_buf: RID
var b_fc0_w_buf: RID
var b_fc0_b_buf: RID
var b_fc1_w_buf: RID
var b_fc1_b_buf: RID
var b_fc2_w_buf: RID
var b_fc2_b_buf: RID
var b_acc_set: RID
var b_fwd_set: RID
var _b_active: PackedInt32Array
var _b_buckets: PackedInt32Array
var _b_host_capacity := 0
var _feature_workers: Array = []


func _init_batch() -> void:
	if batch_ready:
		return
	batch_ready = true
	var acc_shader := _load_compute_shader("res://addons/pikafish/shaders/accumulator_batch.glsl")
	b_acc_pipe = _create_pipeline(acc_shader)
	var fwd_shader := _load_compute_shader("res://addons/pikafish/shaders/forward_batch.glsl")
	b_fwd_pipe = _create_pipeline(fwd_shader)

	var fc0w := PackedByteArray()
	var fc0b := PackedByteArray()
	var fc1w := PackedByteArray()
	var fc1b := PackedByteArray()
	var fc2w := PackedByteArray()
	var fc2b := PackedByteArray()
	for s in range(C.LAYERSTACKS):
		fc0w.append_array(loader.fc0_w[s])
		fc0b.append_array(loader.fc0_bias_raw[s])
		fc1w.append_array(loader.fc1_w[s])
		fc1b.append_array(loader.fc1_bias_raw[s])
		fc2w.append_array(loader.fc2_w[s])
		fc2b.append_array(loader.fc2_bias_raw[s])
	b_fc0_w_buf = _create_storage(fc0w.size(), fc0w)
	b_fc0_b_buf = _create_storage(fc0b.size(), fc0b)
	b_fc1_w_buf = _create_storage(fc1w.size(), fc1w)
	b_fc1_b_buf = _create_storage(fc1b.size(), fc1b)
	b_fc2_w_buf = _create_storage(fc2w.size(), fc2w)
	b_fc2_b_buf = _create_storage(fc2b.size(), fc2b)

	b_active_buf = _create_storage(BATCH_MAX * 260 * 4, PackedByteArray())
	b_acc_buf = _create_storage(BATCH_MAX * 2048 * 4, PackedByteArray())
	b_out_buf = _create_storage(BATCH_MAX * 4, PackedByteArray())
	b_bucket_buf = _create_storage(BATCH_MAX * 4, PackedByteArray())
	b_params_buf = _create_storage(4, PackedByteArray())

	_b_active = PackedInt32Array()
	_b_buckets = PackedInt32Array()
	var worker_count := clampi(OS.get_processor_count() - 1, 1, 4)
	for _i in range(worker_count):
		_feature_workers.append(XFeatures.new(loader))

	b_acc_set = _create_uniform_set([
		_u(0, ft_bias_buf), _u(1, psq_w_buf), _u(2, threat_w_buf),
		_u(3, b_active_buf), _u(4, b_acc_buf), _u(5, b_params_buf)], acc_shader, 0)
	b_fwd_set = _create_uniform_set([
		_u(0, b_acc_buf), _u(1, b_fc0_w_buf), _u(2, b_fc0_b_buf), _u(3, b_fc1_w_buf),
		_u(4, b_fc1_b_buf), _u(5, b_fc2_w_buf), _u(6, b_fc2_b_buf),
		_u(7, b_bucket_buf), _u(8, b_out_buf),
		_u(9, b_active_buf), _u(10, psqt_buf), _u(11, threat_psqt_buf)], fwd_shader, 0)


func _ensure_host_capacity(n: int) -> void:
	var wanted := 0
	for cap in HOST_CAPACITIES:
		if n <= cap:
			wanted = cap
			break
	if wanted == 0:
		wanted = BATCH_MAX
	if wanted == _b_host_capacity:
		return
	_b_host_capacity = wanted
	_b_active.resize(wanted * ACTIVE_SIZE)
	_b_buckets.resize(wanted)


func _fill_feature_worker(worker_idx: int, positions: Array, worker_count: int) -> void:
	var ft: XFeatures = _feature_workers[worker_idx]
	var pos_i := worker_idx
	while pos_i < positions.size():
		var pos: XBoard = positions[pos_i]
		_b_buckets[pos_i] = ft.fill_active_both(
			_b_active, pos_i * ACTIVE_SIZE, pos, pos.stm)
		pos_i += worker_count


func _build_batch_host(positions: Array) -> int:
	var n := positions.size()
	_ensure_host_capacity(n)
	if n >= PARALLEL_FEATURE_THRESHOLD and _feature_workers.size() > 1:
		# Two workers amortize best for the latency-sensitive 16-63 range;
		# larger batches can keep all four performance cores busy.
		var worker_count := mini(2 if n < 64 else _feature_workers.size(), n)
		var task_id := WorkerThreadPool.add_group_task(
			_fill_feature_worker.bind(positions, worker_count), worker_count, worker_count)
		WorkerThreadPool.wait_for_group_task_completion(task_id)
	else:
		for i in range(n):
			var pos: XBoard = positions[i]
			_b_buckets[i] = features.fill_active_both(
				_b_active, i * ACTIVE_SIZE, pos, pos.stm)
	return n


func _fill_batch_actives(positions: Array) -> int:
	var n := _build_batch_host(positions)
	rd.buffer_update(b_active_buf, 0, n * 260 * 4, _b_active.to_byte_array())
	rd.buffer_update(b_bucket_buf, 0, n * 4, _b_buckets.to_byte_array())
	_params_bytes.encode_s32(0, n)
	rd.buffer_update(b_params_buf, 0, 4, _params_bytes)
	return n


func evaluate_batch(positions: Array) -> PackedInt32Array:
	assert(ready, "PikafishGpuInference not ready")
	var n := positions.size()
	if n == 0:
		return PackedInt32Array()
	_init_batch()
	assert(n <= BATCH_MAX, "batch too large (max %d)" % BATCH_MAX)
	_fill_batch_actives(positions)

	var cl := rd.compute_list_begin()
	var groups := int((n * 1024 + 63) / 64)
	rd.compute_list_bind_compute_pipeline(cl, b_acc_pipe)
	rd.compute_list_bind_uniform_set(cl, b_acc_set, 0)
	rd.compute_list_dispatch(cl, groups, 1, 1)
	rd.compute_list_add_barrier(cl)
	rd.compute_list_bind_compute_pipeline(cl, b_fwd_pipe)
	rd.compute_list_bind_uniform_set(cl, b_fwd_set, 0)
	rd.compute_list_dispatch(cl, n, 1, 1)
	rd.compute_list_end()
	rd.submit()
	rd.sync()

	var out_bytes := rd.buffer_get_data(b_out_buf, 0, n * 4)
	var res := PackedInt32Array()
	res.resize(n)
	for i in range(n):
		res[i] = out_bytes.decode_s32(i * 4)
	return res
