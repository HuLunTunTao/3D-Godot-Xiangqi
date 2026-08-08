#!/usr/bin/env python3
"""Microbench dual64 bitboard vs occ90 attack queries (Phase B representation pick).

Runs formula attacks in Python (same as gen_attack_fixtures) over 100k queries.
GDScript hot path uses dual64; occ90 is the reference conversion surface.
"""
from __future__ import annotations

import random
import time
from pathlib import Path

# Reuse fixture generator formulas
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from gen_attack_fixtures import (  # type: ignore
    BISHOP,
    CANNON,
    KNIGHT,
    ROOK,
    SQUARE_NB,
    lame_attack,
    sliding_attack,
)

N = 100_000


def main() -> int:
    rng = random.Random(2)
    queries = []
    for _ in range(N):
        pt = rng.choice([ROOK, CANNON, KNIGHT, BISHOP])
        sq = rng.randrange(SQUARE_NB)
        occ = {rng.randrange(SQUARE_NB) for _ in range(rng.randrange(0, 8))}
        queries.append((pt, sq, occ))

    t0 = time.perf_counter()
    checksum = 0
    for pt, sq, occ in queries:
        if pt in (ROOK, CANNON):
            atk = sliding_attack(pt, sq, occ)
        else:
            atk = lame_attack(pt, sq, occ)
        checksum ^= len(atk) * (sq + 1)
        for s in atk:
            checksum ^= s
    dt = time.perf_counter() - t0
    print(
        f"queries={N} time_s={dt:.4f} qps={N / dt:.0f} checksum={checksum} "
        f"rep=formula_list (reference; GD dual64 selected for u128 parity + bit63/64)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
