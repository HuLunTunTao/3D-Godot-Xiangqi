class_name PikafishUciScore
extends RefCounted

## Upstream: UCIEngine::to_cp / win_rate_params (uci.cpp).
## Converts internal search Value ↔ UCI `score cp`. These are NOT the same unit.

const T = preload("res://addons/pikafish/core/types.gd")

const _AS := [220.59891365, -810.35730430, 928.68185198, 79.83955423]
const _BS := [61.99287416, -233.72674182, 325.85508322, -68.72720854]


static func material_count(position) -> int:
	## Upstream win_rate_params material: both colors, piece-type weights.
	return (
		10 * position.count_pt(T.ROOK)
		+ 5 * position.count_pt(T.KNIGHT)
		+ 5 * position.count_pt(T.CANNON)
		+ 3 * position.count_pt(T.BISHOP)
		+ 2 * position.count_pt(T.ADVISOR)
		+ position.count_pt(T.PAWN)
	)


static func win_rate_params(position) -> Vector2:
	var material: int = material_count(position)
	var m: float = clampf(float(material), 17.0, 110.0) / 65.0
	var a: float = (((_AS[0] * m + _AS[1]) * m + _AS[2]) * m) + _AS[3]
	var b: float = (((_BS[0] * m + _BS[1]) * m + _BS[2]) * m) + _BS[3]
	return Vector2(a, b)


static func to_cp(value: int, position) -> int:
	## Upstream UCIEngine::to_cp — non-mate InternalUnits only.
	var a: float = win_rate_params(position).x
	return int(round(100.0 * float(value) / a))


static func from_cp_estimate(cp: int, position) -> int:
	## Best-effort inverse of to_cp (not unique under rounding). Prefer
	## instrumented internal Value when available.
	var a: float = win_rate_params(position).x
	var approx: int = int(round(float(cp) * a / 100.0))
	var best: int = approx
	var best_err: int = 0x7fffffff
	for v in range(approx - 4, approx + 5):
		var err: int = absi(to_cp(v, position) - cp)
		if err < best_err or (err == best_err and absi(v - approx) < absi(best - approx)):
			best_err = err
			best = v
	return best
