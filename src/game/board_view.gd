class_name XiangqiBoardView
extends Node3D

const Types = preload("res://addons/pikafish/core/types.gd")
const SPACING := 1.2
const BOARD_WIDTH := 8.0 * SPACING
const BOARD_DEPTH := 9.0 * SPACING

var _pieces: Dictionary = {}
var _markers: Node3D
var _camera: Camera3D


func _ready() -> void:
	name = "棋盘视图"
	create_board()
	_markers = Node3D.new()
	add_child(_markers)


func set_camera(camera: Camera3D) -> void:
	_camera = camera


func create_board() -> void:
	var base := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(BOARD_WIDTH + 1.0, 0.55, BOARD_DEPTH + 1.0)
	base.mesh = box
	base.position.y = -0.28
	var wood := StandardMaterial3D.new()
	# The whole chess table uses the dominant neutral grey from board.svg.
	wood.albedo_color = Color("3a3a3a")
	wood.metallic = 0.08
	wood.roughness = 0.66
	base.material_override = wood
	add_child(base)
	var top := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(BOARD_WIDTH, BOARD_DEPTH)
	plane.subdivide_width = 8
	plane.subdivide_depth = 9
	top.mesh = plane
	top.position.y = 0.012
	var board_material := StandardMaterial3D.new()
	board_material.albedo_texture = load("res://assets/board.svg")
	board_material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	board_material.roughness = 0.8
	top.material_override = board_material
	add_child(top)


func show_position(view, move_info = null) -> void:
	if move_info != null and (move_info.kind == "move" or move_info.kind == "redo") and _pieces.has(move_info.from):
		animate_move(move_info)
		return
	clear_pieces()
	for square in range(view.pieces.size()):
		var piece: int = view.pieces[square]
		if piece != Types.NO_PIECE:
			add_piece(square, piece)


func animate_move(info) -> void:
	var moving: Node3D = _pieces[info.from]
	if _pieces.has(info.to):
		_pieces[info.to].queue_free()
		_pieces.erase(info.to)
	_pieces.erase(info.from)
	_pieces[info.to] = moving
	var tween := create_tween()
	tween.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(moving, "position", square_to_world(info.to) + Vector3.UP * 0.28, 0.22)


func add_piece(square: int, piece: int) -> void:
	var holder := Node3D.new()
	holder.name = "棋子_%d" % square
	holder.position = square_to_world(square) + Vector3.UP * 0.28
	add_child(holder)
	var body := MeshInstance3D.new()
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = 0.46
	cylinder.bottom_radius = 0.5
	cylinder.height = 0.43
	# The iPad's high-DPI display makes the default low-poly silhouette visible.
	# A denser rim gives the round chessmen a genuinely smooth outline.
	cylinder.radial_segments = 128
	cylinder.rings = 4
	body.mesh = cylinder
	var material := StandardMaterial3D.new()
	# Keep the body in the same neutral palette as the supplied piece faces.
	material.albedo_color = Color("747474") if Types.color_of(piece) == Types.COLOR_WHITE else Color("595959")
	material.metallic = 0.12
	material.roughness = 0.45
	body.material_override = material
	holder.add_child(body)
	var face := MeshInstance3D.new()
	face.name = "棋子文字"
	var face_mesh := PlaneMesh.new()
	face_mesh.size = Vector2(0.78, 0.78)
	face.mesh = face_mesh
	face.position.y = 0.222
	var face_material := StandardMaterial3D.new()
	face_material.albedo_texture = load(piece_asset(piece))
	face_material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	face_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	face_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	face.material_override = face_material
	holder.add_child(face)
	_pieces[square] = holder


func update_face_rotation() -> void:
	if _camera == null:
		return
	# PlaneMesh's texture top is aligned to -Z at yaw 0.  Rotate *with* the
	# camera yaw, so that local -Z remains the screen-up direction.  The former
	# inverse rotation mirrored the readable orientation while orbiting.
	var yaw := atan2(_camera.global_position.x, _camera.global_position.z)
	for holder in _pieces.values():
		var face: Node3D = holder.get_node_or_null("棋子文字") as Node3D
		if face != null:
			face.rotation.y = yaw


func clear_selection() -> void:
	for child in _markers.get_children():
		child.queue_free()


func show_selection(selected: int, targets: PackedInt32Array) -> void:
	clear_selection()
	if selected >= 0:
		add_marker(selected, Color("f0c75e"), 0.58)
	for square in targets:
		add_marker(square, Color("67b7e1"), 0.30)


func add_marker(square: int, color: Color, radius: float) -> void:
	var marker := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = 0.018
	mesh.radial_segments = 96
	marker.mesh = mesh
	marker.position = square_to_world(square) + Vector3.UP * 0.035
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(color, 0.8)
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	marker.material_override = material
	_markers.add_child(marker)


func pick_square(camera: Camera3D, screen_pos: Vector2) -> int:
	var origin := camera.project_ray_origin(screen_pos)
	var normal := camera.project_ray_normal(screen_pos)
	if absf(normal.y) < 0.0001:
		return Types.SQ_NONE
	var point := origin + normal * (-origin.y / normal.y)
	var file := roundi(point.x / SPACING + 4.0)
	var rank := roundi(point.z / SPACING + 4.5)
	if file < 0 or file > 8 or rank < 0 or rank > 9:
		return Types.SQ_NONE
	return file + rank * 9


func square_to_world(square: int) -> Vector3:
	return Vector3((square % 9 - 4.0) * SPACING, 0.0, (square / 9 - 4.5) * SPACING)


func piece_asset(piece: int) -> String:
	var names := {Types.ROOK: "rook", Types.ADVISOR: "advisor", Types.CANNON: "cannon", Types.PAWN: "pawn", Types.KNIGHT: "knight", Types.BISHOP: "bishop", Types.KING: "king"}
	return "res://assets/pieces/%s%d.svg" % [names[Types.type_of(piece)], Types.color_of(piece)]


func clear_pieces() -> void:
	for piece in _pieces.values():
		piece.queue_free()
	_pieces.clear()
