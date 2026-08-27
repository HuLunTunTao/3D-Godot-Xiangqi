extends GutTest

const Notation = preload("res://src/game/move_notation.gd")
const PositionView = preload("res://addons/pikafish/core/position_view.gd")
const Types = preload("res://addons/pikafish/core/types.gd")


func test_red_and_black_use_their_own_file_numbers() -> void:
	var red: Variant = _view_with_piece(Types.make_square(0, 0), Types.W_ROOK)
	assert_eq(Notation.format(red, Types.make_move(Types.make_square(0, 0), Types.make_square(0, 1))), "车九进一")
	var black: Variant = _view_with_piece(Types.make_square(0, 9), Types.B_ROOK)
	assert_eq(Notation.format(black, Types.make_move(Types.make_square(0, 9), Types.make_square(0, 8))), "車一进一")


func test_knight_uses_destination_file_and_repeated_pieces_use_front_back() -> void:
	var horse: Variant = _view_with_piece(Types.make_square(1, 0), Types.W_KNIGHT)
	assert_eq(Notation.format(horse, Types.make_move(Types.make_square(1, 0), Types.make_square(2, 2))), "马八进七")
	var rooks: Variant = PositionView.new()
	rooks.pieces.resize(Types.SQUARE_NB)
	rooks.pieces[Types.make_square(0, 0)] = Types.W_ROOK
	rooks.pieces[Types.make_square(0, 2)] = Types.W_ROOK
	assert_eq(Notation.format(rooks, Types.make_move(Types.make_square(0, 2), Types.make_square(0, 3))), "前车进一")


func _view_with_piece(square: int, piece: int) -> Variant:
	var view: Variant = PositionView.new()
	view.pieces.resize(Types.SQUARE_NB)
	view.pieces[square] = piece
	return view
