#!/usr/bin/env python3
"""Generate attack fixtures for dual-track (core / nnue) parity tests.

Pure-Python mirror of Pikafish attacks.h / attacks.cpp:
  sliding_attack, lame_leaper_*, PseudoAttacks init, Line/Between/RayPass/LeaperPass.

Writes:
  fixtures/core/attacks_blockers.json  — shared attack cases (rook/cannon/knight/bishop)
  fixtures/core/attacks_parity.json    — extended dual-track + query tables + expected diffs
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

UPSTREAM_SHA = "2c5c998c211d524d26c38e7e3e71d51bc24cbe64"
SQUARE_NB = 90
FILE_NB = 9
NORTH, SOUTH, EAST, WEST = 9, -9, 1, -1
NORTH_EAST, SOUTH_EAST, SOUTH_WEST, NORTH_WEST = 10, -8, -10, 8
ROOK, ADVISOR, CANNON, PAWN, KNIGHT, BISHOP, KING = 1, 2, 3, 4, 5, 6, 7
KNIGHT_TO = 8
ROOK_DIRS = [NORTH, SOUTH, EAST, WEST]
BISHOP_DIRS = [20, -16, -20, 16]
KNIGHT_DIRS = [-19, -17, -11, -7, 7, 11, 17, 19]
KING_STEPS = [NORTH, SOUTH, EAST, WEST]
ADVISOR_STEPS = [NORTH_WEST, NORTH_EAST, SOUTH_WEST, SOUTH_EAST]


def is_ok(s: int) -> bool:
    return 0 <= s < SQUARE_NB


def file_of(s: int) -> int:
    return s % FILE_NB


def rank_of(s: int) -> int:
    return s // FILE_NB


def dist(a: int, b: int) -> int:
    return max(abs(file_of(a) - file_of(b)), abs(rank_of(a) - rank_of(b)))


def c_mod(a: int, b: int) -> int:
    return a - (a // b) * b


def palace_set() -> set[int]:
    out: set[int] = set()
    for r in (0, 1, 2, 7, 8, 9):
        for f in (3, 4, 5):
            out.add(r * FILE_NB + f)
    return out


PALACE = palace_set()


def sliding_attack(pt: int, sq: int, occ: set[int]) -> list[int]:
    out: list[int] = []
    for d in ROOK_DIRS:
        hurdle = False
        s = sq + d
        while is_ok(s) and dist(s - d, s) == 1:
            if pt == ROOK or hurdle:
                out.append(s)
            if s in occ:
                if pt == CANNON and not hurdle:
                    hurdle = True
                else:
                    break
            s += d
    return sorted(set(out))


def lame_path(pt: int, d: int, s: int) -> int | None:
    to = s + d
    if not is_ok(to) or dist(s, to) > 3:
        return None
    from_sq, to_sq, dir_ = s, to, d
    if pt == KNIGHT_TO:
        from_sq, to_sq = to_sq, from_sq
        dir_ = -d
    dr = NORTH if dir_ > 0 else SOUTH
    md = c_mod(dir_, NORTH)
    inner = md if abs(md) < NORTH // 2 else -md
    df = WEST if inner < 0 else EAST
    diff = abs(file_of(to_sq) - file_of(from_sq)) - abs(rank_of(to_sq) - rank_of(from_sq))
    leg = from_sq
    if diff > 0:
        leg += df
    elif diff < 0:
        leg += dr
    else:
        leg += df + dr
    return leg if is_ok(leg) else None


def lame_attack(pt: int, s: int, occ: set[int]) -> list[int]:
    dirs = BISHOP_DIRS if pt == BISHOP else KNIGHT_DIRS
    path_pt = pt
    out: list[int] = []
    for d in dirs:
        to = s + d
        if not (is_ok(to) and dist(s, to) < 3):
            continue
        if pt == BISHOP:
            half_black = rank_of(s) > 4
            if (rank_of(to) > 4) != half_black:
                continue
        leg = lame_path(path_pt, d, s)
        if leg is None or leg not in occ:
            out.append(to)
    return sorted(set(out))


def pawn_attacks(color: int, s: int) -> list[int]:
    out: list[int] = []
    fwd = NORTH if color == 0 else SOUTH
    to = s + fwd
    if is_ok(to) and dist(s, to) == 1:
        out.append(to)
    if (color == 0 and rank_of(s) > 4) or (color == 1 and rank_of(s) < 5):
        for sd in (WEST, EAST):
            to = s + sd
            if is_ok(to) and dist(s, to) == 1:
                out.append(to)
    return sorted(set(out))


def safe_destination(s: int, step: int) -> int | None:
    to = s + step
    if is_ok(to) and dist(s, to) <= 2:
        return to
    return None


def pseudo_king(s: int, constrain: bool) -> list[int]:
    out: list[int] = []
    for step in KING_STEPS:
        to = safe_destination(s, step)
        if to is None:
            continue
        if constrain:
            if s not in PALACE or to not in PALACE:
                continue
        out.append(to)
    return sorted(set(out))


def pseudo_advisor(s: int, constrain: bool) -> list[int]:
    out: list[int] = []
    for step in ADVISOR_STEPS:
        to = safe_destination(s, step)
        if to is None:
            continue
        if constrain:
            if s not in PALACE or to not in PALACE:
                continue
        out.append(to)
    return sorted(set(out))


def nnue_pseudo_king(s: int) -> list[int]:
    """NNUE gate: only palace[to], not palace[s] (known divergence)."""
    out: list[int] = []
    for step in KING_STEPS:
        to = s + step
        if is_ok(to) and dist(s, to) <= 2 and to in PALACE:
            out.append(to)
    return sorted(set(out))


def nnue_pseudo_advisor(s: int) -> list[int]:
    out: list[int] = []
    for step in ADVISOR_STEPS:
        to = s + step
        if is_ok(to) and dist(s, to) <= 2 and to in PALACE:
            out.append(to)
    return sorted(set(out))


def make_attack_cases() -> list[dict]:
    cases: list[dict] = []

    def add(label: str, pt: int, sq: int, occ: list[int], *, tracks: str = "both") -> None:
        oset = set(occ)
        if pt in (ROOK, CANNON):
            atk = sliding_attack(pt, sq, oset)
        elif pt in (KNIGHT, BISHOP, KNIGHT_TO):
            atk = lame_attack(pt, sq, oset)
        else:
            raise ValueError(pt)
        cases.append(
            {
                "label": label,
                "pt": pt,
                "sq": sq,
                "occ": occ,
                "attacks": atk,
                "tracks": tracks,
            }
        )

    for sq in [0, 4, 40, 44, 63, 64, 85, 89]:
        add(f"rook_empty_{sq}", ROOK, sq, [])
        add(f"cannon_empty_{sq}", CANNON, sq, [])
        add(f"knight_empty_{sq}", KNIGHT, sq, [])
        add(f"bishop_empty_{sq}", BISHOP, sq, [])

    e4 = 4 + 4 * 9
    blockers = [
        [e4 + NORTH],
        [e4 + SOUTH],
        [e4 + EAST],
        [e4 + WEST],
        [e4 + NORTH, e4 + 2 * NORTH],
        [e4 + NORTH, e4 + SOUTH, e4 + EAST, e4 + WEST],
        [63],
        [64],
        [63, 64],
        list(range(9, 18)),  # rank 1 full
    ]
    for i, occ in enumerate(blockers):
        for pt, name in [(ROOK, "rook"), (CANNON, "cannon"), (KNIGHT, "knight"), (BISHOP, "bishop")]:
            add(f"{name}_e4_blk_{i}", pt, e4, occ)

    # Cannon screen / capture edges (gives_check uses cannon with screen semantics)
    a0 = 0
    add("cannon_screen_a0_a2_a4", CANNON, a0, [18, 36])  # a2, a4
    add("cannon_double_hurdle_a0", CANNON, a0, [9, 18, 36])  # a1 hurdle, a2, a4
    add("cannon_edge_file_a_rank", CANNON, a0, [81])  # only far blocker a9
    add("rook_edge_stop_a3", ROOK, a0, [27])
    add("rook_edge_63_64", ROOK, 63, [64])

    # Horse / elephant blockers near palace and river
    add("knight_leg_e4_north", KNIGHT, e4, [e4 + NORTH])
    add("knight_to_e6_from_e4", KNIGHT_TO, e4 + 2 * NORTH, [e4 + NORTH], tracks="core")
    c2 = 2 + 2 * 9
    add("bishop_eye_c2_ne", BISHOP, c2, [3 + 3 * 9])  # d3 eye

    return cases


def make_leaper_nonslide_cases() -> list[dict]:
    """King / advisor / pawn — shared when on legal squares; NNUE differs OOB palace."""
    cases: list[dict] = []
    for s in sorted(PALACE):
        cases.append(
            {
                "label": f"king_palace_{s}",
                "kind": "king",
                "sq": s,
                "core": pseudo_king(s, True),
                "nnue": nnue_pseudo_king(s),
                "upstream": pseudo_king(s, True),
            }
        )
        cases.append(
            {
                "label": f"advisor_palace_{s}",
                "kind": "advisor",
                "sq": s,
                "core": pseudo_advisor(s, True),
                "nnue": nnue_pseudo_advisor(s),
                "upstream": pseudo_advisor(s, True),
            }
        )
    for color, sq, label in [
        (0, 0 + 3 * 9, "pawn_w_a3"),
        (0, 4 + 5 * 9, "pawn_w_e5"),
        (1, 4 + 4 * 9, "pawn_b_e4"),
        (1, 4 + 6 * 9, "pawn_b_e6"),
    ]:
        atk = pawn_attacks(color, sq)
        cases.append(
            {
                "label": label,
                "kind": "pawn",
                "color": color,
                "sq": sq,
                "core": atk,
                "nnue": atk,
                "upstream": atk,
            }
        )
    return cases


def build_query_tables() -> dict:
    """Mirror attacks.cpp init for Line / Between / RayPass / LeaperPass."""
    pseudo_rook = [set(sliding_attack(ROOK, s, set())) for s in range(SQUARE_NB)]
    pseudo_knight = [set(lame_attack(KNIGHT, s, set())) for s in range(SQUARE_NB)]
    pseudo_bishop = [set(lame_attack(BISHOP, s, set())) for s in range(SQUARE_NB)]
    uking = [set(pseudo_king(s, False)) for s in range(SQUARE_NB)]
    uadv = [set(pseudo_advisor(s, False)) for s in range(SQUARE_NB)]

    line: dict[str, list[int]] = {}
    between: dict[str, list[int]] = {}
    ray_pass: dict[str, list[int]] = {}
    leaper_pass: dict[str, list[int]] = {}

    for s1 in range(SQUARE_NB):
        for s2 in range(SQUARE_NB):
            key = f"{s1},{s2}"
            bet: set[int] = set()
            if s2 in pseudo_rook[s1]:
                a1 = set(sliding_attack(ROOK, s1, set()))
                a2 = set(sliding_attack(ROOK, s2, set()))
                ln = (a1 & a2) | {s1, s2}
                line[key] = sorted(ln)
                b1 = set(sliding_attack(ROOK, s1, {s2}))
                b2 = set(sliding_attack(ROOK, s2, {s1}))
                bet |= b1 & b2
                ray_pass[key] = sliding_attack(CANNON, s1, {s2})
            if s2 in pseudo_knight[s1]:
                leg = lame_path(KNIGHT_TO, s2 - s1, s1)
                if leg is not None:
                    bet.add(leg)
            bet.add(s2)
            between[key] = sorted(bet)

            lp: set[int] = set()
            if s2 in uking[s1]:
                lp |= pseudo_knight[s1] & uadv[s2]
            if s2 in uadv[s1]:
                lp |= pseudo_bishop[s1] & uadv[s2]
            if lp:
                leaper_pass[key] = sorted(lp)

    # Compact sample for fixture size: interesting pairs + densify around e0/e4/e9
    sample_pairs: list[tuple[int, int]] = []
    anchors = [0, 4, 40, 44, 45, 63, 64, 76, 85, 89]
    for s1 in anchors:
        for s2 in anchors:
            sample_pairs.append((s1, s2))
    # Rook-ray pairs on file E and rank 0
    for r in range(10):
        sample_pairs.append((4, 4 + r * 9))
        sample_pairs.append((4 + r * 9, 4))
    for f in range(9):
        sample_pairs.append((f, 4))
        sample_pairs.append((4, f))
    # Knight adjacency samples
    e4 = 40
    for d in KNIGHT_DIRS:
        to = e4 + d
        if is_ok(to) and dist(e4, to) < 3:
            sample_pairs.append((e4, to))
            sample_pairs.append((to, e4))
    # King-step / advisor-step for leaper_pass
    e0 = 4
    for d in KING_STEPS + ADVISOR_STEPS:
        to = e0 + d
        if is_ok(to):
            sample_pairs.append((e0, to))
            sample_pairs.append((to, e0))

    uniq = sorted(set(sample_pairs))
    queries: list[dict] = []
    for s1, s2 in uniq:
        key = f"{s1},{s2}"
        queries.append(
            {
                "s1": s1,
                "s2": s2,
                "line": line.get(key, []),
                "between": between.get(key, [s2]),
                "ray_pass": ray_pass.get(key, []),
                "leaper_pass": leaper_pass.get(key, []),
            }
        )
    return {
        "pair_count": len(queries),
        "pairs": queries,
    }


def make_expected_differences() -> list[dict]:
    diffs: list[dict] = []
    # Out-of-palace king/advisor: core (upstream) empty; NNUE may still list palace targets.
    for s in range(SQUARE_NB):
        if s in PALACE:
            continue
        ck, nk = pseudo_king(s, True), nnue_pseudo_king(s)
        if ck != nk:
            diffs.append(
                {
                    "id": "king_outside_palace",
                    "label": f"king_oob_{s}",
                    "sq": s,
                    "core": ck,
                    "nnue": nk,
                    "upstream": ck,
                    "verdict": (
                        "core matches upstream PseudoAttacks[KING] which gates Palace&s1; "
                        "nnue only gates palace[to]. Meaningful only for illegal king squares."
                    ),
                    "fix": False,
                }
            )
        ca, na = pseudo_advisor(s, True), nnue_pseudo_advisor(s)
        if ca != na:
            diffs.append(
                {
                    "id": "advisor_outside_palace",
                    "label": f"advisor_oob_{s}",
                    "sq": s,
                    "core": ca,
                    "nnue": na,
                    "upstream": ca,
                    "verdict": (
                        "core matches upstream PseudoAttacks[ADVISOR] Palace&s1 gate; "
                        "nnue only gates palace[to]."
                    ),
                    "fix": False,
                }
            )
    diffs.append(
        {
            "id": "nnue_missing_query_tables",
            "label": "ray_pass_leaper_pass_line_between",
            "verdict": (
                "core/attacks.gd builds Line/Between/RayPass/LeaperPass like attacks.cpp; "
                "nnue/attacks.gd has no equivalents (threat path only). Not a formula bug."
            ),
            "fix": False,
        }
    )
    diffs.append(
        {
            "id": "nnue_missing_knight_to",
            "label": "KNIGHT_TO",
            "verdict": (
                "core exposes KNIGHT_TO (attackers_to / gives_check helpers); "
                "nnue lame_leaper_path does not swap for KNIGHT_TO. Core-only API."
            ),
            "fix": False,
        }
    )
    return diffs


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--blockers-out",
        type=Path,
        default=Path("fixtures/core/attacks_blockers.json"),
    )
    ap.add_argument(
        "--parity-out",
        type=Path,
        default=Path("fixtures/core/attacks_parity.json"),
    )
    args = ap.parse_args()

    attack_cases = make_attack_cases()
    # Blockers file keeps v1 shape for existing test_addon_bitboard.gd
    blockers_cases = [
        {k: c[k] for k in ("label", "pt", "sq", "occ", "attacks")}
        for c in attack_cases
        if c["pt"] in (ROOK, CANNON, KNIGHT, BISHOP) and c.get("tracks", "both") == "both"
    ]
    # Drop the newly added both-track extras that were not in original 72? Keep them —
    # bitboard test only checks attacks match; more cases is fine. But original had exactly
    # the empty+e4_blk set. Extra cases still valid for that test.
    blockers_payload = {
        "format": "godot-pikafish-attacks-fixture/v1",
        "upstream_sha": UPSTREAM_SHA,
        "cases": blockers_cases,
    }
    args.blockers_out.parent.mkdir(parents=True, exist_ok=True)
    args.blockers_out.write_text(json.dumps(blockers_payload, indent=2) + "\n")
    print(f"wrote {args.blockers_out} cases={len(blockers_cases)}")

    parity = {
        "format": "godot-pikafish-attacks-parity/v1",
        "upstream_sha": UPSTREAM_SHA,
        "notes": (
            "Dual-track: core/attacks.gd (bitboard) vs nnue/attacks.gd (occ90). "
            "Do not merge implementations. Query tables are core-only."
        ),
        "attack_cases": attack_cases,
        "leaper_cases": make_leaper_nonslide_cases(),
        "queries": build_query_tables(),
        "expected_differences": make_expected_differences(),
    }
    args.parity_out.write_text(json.dumps(parity, indent=2) + "\n")
    print(
        f"wrote {args.parity_out} "
        f"attacks={len(parity['attack_cases'])} "
        f"leapers={len(parity['leaper_cases'])} "
        f"query_pairs={parity['queries']['pair_count']} "
        f"diffs={len(parity['expected_differences'])}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
