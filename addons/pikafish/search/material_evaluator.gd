class_name PikafishMaterialEvaluator
extends "res://addons/pikafish/search/evaluator.gd"

## Deliberately simple diagnostic fallback. It is not the normal engine mode.

const T = preload("res://addons/pikafish/core/types.gd")


func evaluate(position) -> int:
	var material := 0
	for square in range(T.SQUARE_NB):
		var piece: int = position.piece_on(square)
		if piece == T.NO_PIECE:
			continue
		var value: int = T.PIECE_VALUE[piece]
		if T.color_of(piece) == position.side_to_move:
			material += value
		else:
			material -= value
	return material
