## Non-blocking batch facade backed by one dedicated inference thread.
## Godot 4.7 local RenderingDevices require submit()+sync(), while asynchronous
## compute readback is not reliable. Keeping sync on this worker preserves a
## responsive caller and bounds queued work without tripling NNUE GPU weights.

class_name PikafishAsyncBatchWorker
extends RefCounted
const NNUELoader = preload("res://addons/pikafish/nnue/loader.gd")
const FeaturesScript = preload("res://addons/pikafish/nnue/features.gd")
const GpuScript = preload("res://addons/pikafish/nnue/gpu_inference.gd")
const CpuScript = preload("res://addons/pikafish/nnue/cpu_inference.gd")

const CAPACITY = 3

var loader
var _queue: Array = []
var _mutex := Mutex.new()
var _semaphore := Semaphore.new()
var _thread := Thread.new()
var _stopping := false
var _pending := 0
var _prefer_gpu := true


func _init(ld, prefer_gpu := true) -> void:
	loader = ld
	_prefer_gpu = prefer_gpu
	_thread.start(_thread_main)


func submit(positions: Array, callback: Callable) -> Error:
	if not callback.is_valid() or positions.size() > GpuScript.BATCH_MAX:
		return ERR_INVALID_PARAMETER
	if positions.is_empty():
		callback.call_deferred(PackedInt32Array())
		return OK
	_mutex.lock()
	if _stopping:
		_mutex.unlock()
		return ERR_UNAVAILABLE
	if _pending >= CAPACITY:
		_mutex.unlock()
		return ERR_BUSY
	_pending += 1
	_queue.append({"positions": positions.duplicate(), "callback": callback})
	_mutex.unlock()
	_semaphore.post()
	return OK


func stop() -> void:
	if _thread == null:
		return
	_mutex.lock()
	if _stopping:
		_mutex.unlock()
		return
	_stopping = true
	_mutex.unlock()
	_semaphore.post()
	if _thread.is_started():
		_thread.wait_to_finish()


func _thread_main() -> void:
	var features := FeaturesScript.new(loader)
	var gpu = null
	if _prefer_gpu:
		gpu = GpuScript.try_create(loader, features)
	var cpu = null
	if gpu == null or not gpu.ready:
		cpu = CpuScript.new(loader, features)
	while true:
		_semaphore.wait()
		_mutex.lock()
		if _stopping and _queue.is_empty():
			_mutex.unlock()
			break
		if _queue.is_empty():
			_mutex.unlock()
			continue
		var job: Dictionary = _queue.pop_front()
		_mutex.unlock()
		var positions: Array = job["positions"]
		var result: PackedInt32Array
		if gpu != null and gpu.ready:
			result = gpu.evaluate_batch(positions)
		else:
			result = cpu.evaluate_batch(positions)
		call_deferred("_complete", job["callback"], result)
	if gpu != null:
		gpu.dispose()


func _complete(callback: Callable, result: PackedInt32Array) -> void:
	_mutex.lock()
	_pending -= 1
	_mutex.unlock()
	if callback.is_valid():
		callback.call(result)
