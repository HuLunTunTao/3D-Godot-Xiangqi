class_name XiangqiOrbitCamera
extends Camera3D

## An intentionally constrained orbit camera: the board is always readable and
## reachable, while mouse and touch both remain comfortable to use.
@export var target := Vector3.ZERO
@export var distance := 14.0
@export var yaw := 0.0
@export var pitch := deg_to_rad(52.0)
@export var min_distance := 8.0
@export var max_distance := 18.0
@export var min_pitch := deg_to_rad(32.0)
@export var max_pitch := deg_to_rad(72.0)

const ORBIT_SPEED := 0.012
const PAN_SPEED := 0.012
const TOUCH_SLOP := 14.0
## Distance-change threshold is relative to the short edge, not device pixels.
## On the deployed 1640×2360 iPad this is about 41 physical pixels.
const TWO_FINGER_DISTANCE_THRESHOLD_RATIO := 0.025

var _mouse_orbit := false
var _mouse_pan := false
var _touches: Dictionary = {}
var _touch_dragged := false
var _two_finger_mode := ""
var _two_finger_start_distance := 0.0
var _last_two_finger_distance := 0.0
var _last_two_finger_center := Vector2.ZERO


func _ready() -> void:
	update_transform()


func update_transform() -> void:
	pitch = clampf(pitch, min_pitch, max_pitch)
	distance = clampf(distance, min_distance, max_distance)
	var offset := Vector3(
		sin(yaw) * cos(pitch),
		sin(pitch),
		cos(yaw) * cos(pitch)
	) * distance
	global_position = target + offset
	look_at(target, Vector3.UP)


func reset_for_color(color: int) -> void:
	# White/red begins at the near side; black uses the symmetric view.
	yaw = 0.0 if color == 0 else PI
	pitch = deg_to_rad(52.0)
	distance = 14.0
	target = Vector3.ZERO
	update_transform()


func flip_view() -> void:
	yaw = wrapf(yaw + PI, -PI, PI)
	update_transform()


func projected_yaw() -> float:
	var delta := global_position - target
	return atan2(delta.x, delta.z)


func handle_event(event: InputEvent) -> bool:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			_mouse_orbit = event.pressed
			return true
		if event.button_index == MOUSE_BUTTON_MIDDLE:
			_mouse_pan = event.pressed
			return true
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			distance -= 0.85
			update_transform()
			return true
		if event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			distance += 0.85
			update_transform()
			return true
	if event is InputEventMouseMotion:
		if _mouse_orbit:
			yaw -= event.relative.x * ORBIT_SPEED
			pitch += event.relative.y * ORBIT_SPEED
			update_transform()
			return true
		if _mouse_pan:
			pan(event.relative)
			return true
	if event is InputEventScreenTouch:
		if event.pressed:
			_touches[event.index] = {"start": event.position, "last": event.position}
			if _touches.size() == 1:
				_touch_dragged = false
			if _touches.size() >= 2:
				_touch_dragged = true
				begin_two_finger_gesture()
		else:
			_touches.erase(event.index)
			_two_finger_mode = ""
			_last_two_finger_distance = 0.0
		return false
	if event is InputEventScreenDrag:
		if not _touches.has(event.index):
			return false
		var entry: Dictionary = _touches[event.index]
		var start: Vector2 = entry["start"]
		if event.position.distance_to(start) > TOUCH_SLOP:
			_touch_dragged = true
		entry["last"] = event.position
		_touches[event.index] = entry
		if _touches.size() == 1:
			yaw -= event.relative.x * ORBIT_SPEED
			pitch += event.relative.y * ORBIT_SPEED
			update_transform()
			return true
		if _touches.size() >= 2:
			var points: Array = _touches.values()
			var a: Vector2 = points[0]["last"]
			var b: Vector2 = points[1]["last"]
			var now := a.distance_to(b)
			var center := (a + b) * 0.5
			if _last_two_finger_distance <= 0.0:
				_last_two_finger_distance = now
				_last_two_finger_center = center
				return true
			var scale_delta := now - _last_two_finger_distance
			var center_delta := center - _last_two_finger_center
			# Decide from the change in the two-finger separation since the
			# gesture began.  Below the screen-relative threshold this is a
			# two-finger pan only; at/above it this is a pinch only.  Never add
			# pan and zoom in one event.
			var separation_change := absf(now - _two_finger_start_distance)
			if separation_change >= two_finger_distance_threshold():
				_two_finger_mode = "pinch"
				distance -= scale_delta * 0.018
			else:
				_two_finger_mode = "pan"
				pan(center_delta * 0.65)
			_last_two_finger_distance = now
			_last_two_finger_center = center
			update_transform()
			return true
	return false


func was_touch_drag() -> bool:
	return _touch_dragged


func begin_two_finger_gesture() -> void:
	var points: Array = _touches.values()
	if points.size() < 2:
		return
	var a: Vector2 = points[0]["last"]
	var b: Vector2 = points[1]["last"]
	_last_two_finger_distance = a.distance_to(b)
	_two_finger_start_distance = _last_two_finger_distance
	_last_two_finger_center = (a + b) * 0.5
	_two_finger_mode = ""


func two_finger_distance_threshold() -> float:
	var viewport_size := get_viewport().get_visible_rect().size
	var short_edge := minf(viewport_size.x, viewport_size.y)
	return maxf(12.0, short_edge * TWO_FINGER_DISTANCE_THRESHOLD_RATIO)


func pan(delta: Vector2) -> void:
	var right := global_transform.basis.x
	right.y = 0.0
	right = right.normalized()
	var forward := -global_transform.basis.z
	forward.y = 0.0
	forward = forward.normalized()
	target += (-right * delta.x + forward * delta.y) * PAN_SPEED * distance
	target.x = clampf(target.x, -2.5, 2.5)
	target.z = clampf(target.z, -2.8, 2.8)
	update_transform()
