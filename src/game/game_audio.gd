class_name XiangqiGameAudio
extends Node

## Local, pre-synthesized voice playback.  Only the human side gets action
## calls: its moving piece may attack, and its captured piece may react.
const Types = preload("res://addons/pikafish/core/types.gd")
const AUDIO_ROOT := "res://assets/audio/chess/"

var _player: AudioStreamPlayer
var _queue: Array[String] = []
var _playing := false


func _ready() -> void:
	_player = AudioStreamPlayer.new()
	_player.name = "语音播放器"
	_player.volume_db = -2.0
	_player.bus = &"Master"
	_player.finished.connect(_play_next)
	add_child(_player)


func play_move(move_info, human_color: int) -> void:
	if move_info == null or move_info.kind not in ["move", "redo"]:
		return
	var moving_piece: int = int(move_info.moving_piece)
	var captured_piece: int = int(move_info.captured_piece)
	var mover_is_human := Types.color_of(moving_piece) == human_color
	# AI moves never announce an attack.  If AI captures a human piece, only
	# that human piece's hit reaction is queued.
	if mover_is_human:
		_enqueue_piece_event(moving_piece, "capture" if captured_piece != Types.NO_PIECE else "attack")
		# This branch is defensive; legal Xiangqi moves cannot capture own pieces.
		if captured_piece != Types.NO_PIECE and Types.color_of(captured_piece) == human_color:
			_enqueue_piece_event(captured_piece, "hit")
	elif captured_piece != Types.NO_PIECE and Types.color_of(captured_piece) == human_color:
		_enqueue_piece_event(captured_piece, "hit")


func _enqueue_piece_event(piece: int, event: String) -> void:
	var piece_name := _piece_name(Types.type_of(piece))
	if piece_name.is_empty():
		return
	_enqueue("%s%s.mp3" % [piece_name, event])


func _enqueue(filename: String) -> void:
	var path := AUDIO_ROOT + filename
	if not ResourceLoader.exists(path):
		return
	_queue.append(path)
	if not _playing:
		_play_next()


func _play_next() -> void:
	if _queue.is_empty():
		_playing = false
		return
	_playing = true
	var path: String = _queue.pop_front()
	var stream := load(path) as AudioStream
	if stream == null:
		_play_next()
		return
	_player.stream = stream
	_player.play()


func _piece_name(piece_type: int) -> String:
	match piece_type:
		Types.KING:
			return "king_"
		Types.ADVISOR:
			return "advisor_"
		Types.BISHOP:
			return "elephant_"
		Types.KNIGHT:
			return "horse_"
		Types.ROOK:
			return "chariot_"
		Types.CANNON:
			return "cannon_"
		Types.PAWN:
			return "pawn_"
	return ""
