#!/usr/bin/env python3
"""Dump Zobrist keys matching Pikafish Position::init (PRNG seed 1070372)."""
from __future__ import annotations

import argparse
import json
from pathlib import Path

UPSTREAM_SHA = "2c5c998c211d524d26c38e7e3e71d51bc24cbe64"
MASK = (1 << 64) - 1
PIECES = [1, 2, 3, 4, 5, 6, 7, 9, 10, 11, 12, 13, 14, 15]


class PRNG:
    def __init__(self, seed: int) -> None:
        self.s = seed & MASK

    def rand64(self) -> int:
        s = self.s
        s ^= (s >> 12) & MASK
        s ^= (s << 25) & MASK
        s ^= (s >> 27) & MASK
        self.s = s & MASK
        return (self.s * 2685821657736338717) & MASK


def to_signed(u: int) -> int:
    return u - (1 << 64) if u >= (1 << 63) else u


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("-o", "--out", type=Path, default=Path("fixtures/core/zobrist.json"))
    args = ap.parse_args()

    rng = PRNG(1070372)
    psq = [[0] * 90 for _ in range(16)]
    for pc in PIECES:
        for s in range(90):
            psq[pc][s] = rng.rand64()
    side = rng.rand64()
    no_pawns = rng.rand64()

    payload = {
        "format": "godot-pikafish-zobrist/v1",
        "upstream_sha": UPSTREAM_SHA,
        "seed": 1070372,
        "side_hex": f"{side:016X}",
        "no_pawns_hex": f"{no_pawns:016X}",
        "psq_hex": [[f"{v:016X}" for v in row] for row in psq],
        "startpos_key_hex": "FDA3193C470C785C",
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(payload) + "\n")
    print(f"wrote {args.out} side={payload['side_hex']} no_pawns={payload['no_pawns_hex']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
