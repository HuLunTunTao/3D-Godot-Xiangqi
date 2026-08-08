extends GutTest

## Board FEN load + do_move/undo_move restoration (quiet, capture, king move).

const C = preload("res://addons/pikafish/nnue/consts.gd")
const XBoard = preload("res://addons/pikafish/nnue/board.gd")
const S = preload("res://src/test/gut/nnue_test_support.gd")

const START := "rnbakabnr/9/1c5c1/p1p1p1p1p/9/9/P1P1P1P1P/1C5C1/9/RNBAKABNR w"


func _assert_board_restored(b: XBoard, snap: Dictionary) -> void:
	assert_eq(b.stm, snap.stm)
	assert_eq(b.sq, snap.sq)
	assert_eq(b.occ, snap.occ)
	assert_eq(b.piece_counts, snap.counts)
	assert_eq(b.kings, snap.kings)
	var occupied := PackedInt32Array()
	for s in range(C.SQUARE_NB):
		if b.occ[s] == 1:
			occupied.append(s)
	var pl := b.piece_list.duplicate()
	occupied.sort()
	pl.sort()
	assert_eq(pl, occupied)


func _snapshot(b: XBoard) -> Dictionary:
	return {
		"stm": b.stm,
		"sq": b.sq.duplicate(),
		"occ": b.occ.duplicate(),
		"counts": b.piece_counts.duplicate(),
		"kings": b.kings.duplicate(),
	}


func test_fen_startpos_basics() -> void:
	var b := S.board_from_fen(START)
	assert_eq(b.stm, C.WHITE)
	assert_eq(b.kings[C.WHITE], S.sq(4, 0))
	assert_eq(b.kings[C.BLACK], S.sq(4, 9))
	assert_eq(b.piece_list.size(), 32)
	assert_eq(b.count(C.ROOK, C.WHITE), 2)
	assert_eq(b.count(C.PAWN, C.BLACK), 5)
	assert_eq(b.sq[S.sq(0, 0)], C.W_ROOK)
	assert_eq(b.sq[S.sq(4, 9)], C.B_KING)


func test_fen_black_to_move() -> void:
	var b := S.board_from_fen("4k4/9/9/9/9/9/9/9/9/4K4 b")
	assert_eq(b.stm, C.BLACK)
	assert_eq(b.piece_list.size(), 2)


func test_quiet_pawn_push_undo() -> void:
	var b := S.board_from_fen(START)
	var snap := _snapshot(b)
	var frm := S.sq(0, 3)  # a3 white pawn... start has pawns on rank 3: a3=c? 
	# Start FEN pawns on rank 3: files 0,2,4,6,8 → a3,c3,e3,g3,i3
	frm = S.sq(0, 3)
	assert_eq(b.sq[frm], C.W_PAWN)
	var to := S.sq(0, 4)
	var u: Dictionary = b.do_move(frm, to)
	assert_eq(u["captured"], 0)
	assert_eq(b.stm, C.BLACK)
	assert_eq(b.sq[to], C.W_PAWN)
	assert_eq(b.sq[frm], 0)
	b.undo_move(u)
	_assert_board_restored(b, snap)


func test_capture_undo_restores_piece_and_counts() -> void:
	# White rook a0 captures black pawn? Put a simple position.
	var b := S.board_from_fen("4k4/9/9/p8/9/9/9/9/9/R3K4 w")
	var snap := _snapshot(b)
	var frm := S.sq(0, 0)
	var to := S.sq(0, 6)  # black pawn on a6 = file0 rank6
	assert_eq(b.sq[frm], C.W_ROOK)
	assert_eq(b.sq[to], C.B_PAWN)
	var before_w_r := b.count(C.ROOK, C.WHITE)
	var before_b_p := b.count(C.PAWN, C.BLACK)
	var u: Dictionary = b.do_move(frm, to)
	assert_eq(u["captured"], C.B_PAWN)
	assert_eq(b.count(C.PAWN, C.BLACK), before_b_p - 1)
	assert_eq(b.count(C.ROOK, C.WHITE), before_w_r)
	assert_eq(b.sq[to], C.W_ROOK)
	assert_eq(b.piece_list.size(), 3)  # K, k, R
	b.undo_move(u)
	_assert_board_restored(b, snap)
	assert_eq(b.count(C.PAWN, C.BLACK), before_b_p)


func test_king_move_updates_kings_array() -> void:
	var b := S.board_from_fen("4k4/9/9/9/9/9/9/9/9/4K4 w")
	var snap := _snapshot(b)
	var frm := S.sq(4, 0)
	var to := S.sq(4, 1)
	var u: Dictionary = b.do_move(frm, to)
	assert_eq(b.kings[C.WHITE], to)
	assert_eq(b.kings[C.BLACK], S.sq(4, 9))
	b.undo_move(u)
	_assert_board_restored(b, snap)
	assert_eq(b.kings[C.WHITE], frm)
