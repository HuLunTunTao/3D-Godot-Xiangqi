#!/usr/bin/env python3
"""Generate generic blocker attack fixtures (Phase B).

Pure-Python mirror of Pikafish attacks.h sliding_attack / lame_leaper_attack
(formulas identical to src/nnue/attacks.gd). Embeds upstream SHA.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

UPSTREAM_SHA = "2c5c998c211d524d26c38e7e3e71d51bc24cbe64"
SQUARE_NB = 90
FILE_NB = 9
NORTH, SOUTH, EAST, WEST = 9, -9, 1, -1
ROOK, ADVISOR, CANNON, PAWN, KNIGHT, BISHOP, KING = 1, 2, 3, 4, 5, 6, 7
ROOK_DIRS = [NORTH, SOUTH, EAST, WEST]
BISHOP_DIRS = [20, -16, -20, 16]
KNIGHT_DIRS = [-19, -17, -11, -7, 7, 11, 17, 19]


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
    dr = NORTH if d > 0 else SOUTH
    md = c_mod(d, NORTH)
    inner = md if abs(md) < NORTH // 2 else -md
    df = WEST if inner < 0 else EAST
    diff = abs(file_of(to) - file_of(s)) - abs(rank_of(to) - rank_of(s))
    leg = s
    if diff > 0:
        leg += df
    elif diff < 0:
        leg += dr
    else:
        leg += df + dr
    return leg if is_ok(leg) else None


def lame_attack(pt: int, s: int, occ: set[int]) -> list[int]:
    dirs = BISHOP_DIRS if pt == BISHOP else KNIGHT_DIRS
    out: list[int] = []
    for d in dirs:
        to = s + d
        if not (is_ok(to) and dist(s, to) < 3):
            continue
        if pt == BISHOP:
            half_black = rank_of(s) > 4
            if (rank_of(to) > 4) != half_black:
                continue
        leg = lame_path(pt, d, s)
        if leg is None or leg not in occ:
            out.append(to)
    return sorted(set(out))


def make_cases() -> list[dict]:
    cases: list[dict] = []

    def add(label: str, pt: int, sq: int, occ: list[int]) -> None:
        oset = set(occ)
        if pt in (ROOK, CANNON):
            atk = sliding_attack(pt, sq, oset)
        else:
            atk = lame_attack(pt, sq, oset)
        cases.append(
            {
                "label": label,
                "pt": pt,
                "sq": sq,
                "occ": occ,
                "attacks": atk,
            }
        )

    # Empty-board rook/cannon/knight/bishop samples across board + around bit 63/64
    for sq in [0, 4, 40, 44, 63, 64, 85, 89]:
        add(f"rook_empty_{sq}", ROOK, sq, [])
        add(f"cannon_empty_{sq}", CANNON, sq, [])
        add(f"knight_empty_{sq}", KNIGHT, sq, [])
        add(f"bishop_empty_{sq}", BISHOP, sq, [])

    # Generic blockers on files/ranks through mid-board
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

    return cases


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("-o", "--out", type=Path, default=Path("fixtures/core/attacks_blockers.json"))
    args = ap.parse_args()
    payload = {
        "format": "godot-pikafish-attacks-fixture/v1",
        "upstream_sha": UPSTREAM_SHA,
        "cases": make_cases(),
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(payload, indent=2) + "\n")
    print(f"wrote {args.out} cases={len(payload['cases'])}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
