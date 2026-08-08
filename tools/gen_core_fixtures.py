#!/usr/bin/env python3
"""Generate minimal position/movegen/perft fixtures from upstream Pikafish (UCI).

Dev-only. Runtime GDScript must not import this module or host absolute paths.
Default oracle/net paths match the local AGENTS.md machine layout and can be overridden.
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

UPSTREAM_SHA = "2c5c998c211d524d26c38e7e3e71d51bc24cbe64"
START_FEN = "rnbakabnr/9/1c5c1/p1p1p1p1p/9/9/P1P1P1P1P/1C5C1/9/RNBAKABNR w - - 0 1"

# Upstream: types.h Move — (from << 7) | to; file a..i, rank 0..9 → sq = file + rank * 9
_FILE = {c: i for i, c in enumerate("abcdefghi")}


def uci_to_raw(uci: str) -> int:
    if len(uci) != 4:
        raise ValueError(f"bad uci move: {uci!r}")
    ff, fr, tf, tr = uci[0], uci[1], uci[2], uci[3]
    frm = _FILE[ff] + int(fr) * 9
    to = _FILE[tf] + int(tr) * 9
    return (frm << 7) | to


def raw_to_uci(raw: int) -> str:
    frm = (raw >> 7) & 0x7F
    to = raw & 0x7F
    files = "abcdefghi"
    return f"{files[frm % 9]}{frm // 9}{files[to % 9]}{to // 9}"


def run_uci(oracle: Path, commands: list[str], cwd: Path | None = None) -> str:
    payload = "\n".join(commands) + "\n"
    proc = subprocess.run(
        [str(oracle)],
        input=payload,
        text=True,
        capture_output=True,
        cwd=str(cwd) if cwd else None,
        check=False,
    )
    if proc.returncode != 0:
        raise RuntimeError(
            f"oracle exit {proc.returncode}\nstdout:\n{proc.stdout}\nstderr:\n{proc.stderr}"
        )
    return proc.stdout


def parse_perft(stdout: str) -> tuple[list[tuple[str, int]], int]:
    moves: list[tuple[str, int]] = []
    total = None
    for line in stdout.splitlines():
        m = re.match(r"^([a-i][0-9][a-i][0-9]):\s+(\d+)\s*$", line.strip())
        if m:
            moves.append((m.group(1), int(m.group(2))))
            continue
        m = re.match(r"^Nodes searched:\s+(\d+)\s*$", line.strip())
        if m:
            total = int(m.group(1))
    if total is None:
        raise RuntimeError(f"failed to parse perft output:\n{stdout}")
    return moves, total


def collect_perft(oracle: Path, fen: str, depth: int, cwd: Path) -> dict:
    out = run_uci(
        oracle,
        [
            "uci",
            "isready",
            f"position fen {fen}",
            f"go perft {depth}",
            "quit",
        ],
        cwd=cwd,
    )
    moves, total = parse_perft(out)
    moves_sorted = sorted(moves, key=lambda t: t[0])
    raw_sorted = sorted(uci_to_raw(u) for u, _ in moves_sorted)
    return {
        "depth": depth,
        "nodes": total,
        "moves_uci": [u for u, _ in moves_sorted],
        "moves_raw": raw_sorted,
        "move_nodes": {u: n for u, n in moves_sorted},
    }


def build_startpos_fixture(oracle: Path, max_perft: int, cwd: Path) -> dict:
    perfts = {}
    legal = None
    for d in range(1, max_perft + 1):
        entry = collect_perft(oracle, START_FEN, d, cwd)
        perfts[str(d)] = {"nodes": entry["nodes"]}
        if d == 1:
            legal = entry
        # Keep root split only for depth 1 (compact fixture); higher depths nodes-only.
        if d == 2:
            perfts["2"]["root_split"] = entry["move_nodes"]

    assert legal is not None
    # Round-trip encode check
    for u, r in zip(legal["moves_uci"], [uci_to_raw(u) for u in legal["moves_uci"]]):
        assert raw_to_uci(r) == u

    return {
        "format": "godot-pikafish-core-fixture/v1",
        "upstream_sha": UPSTREAM_SHA,
        "label": "startpos",
        "fen": START_FEN,
        "side_to_move": "w",
        "rule60": 0,
        "game_ply": 0,
        "legal": {
            "count": len(legal["moves_raw"]),
            "moves_uci": legal["moves_uci"],
            "moves_raw": legal["moves_raw"],
        },
        # GenType lists beyond LEGAL require a C++ dumper; LEGAL is sufficient for Phase A gate.
        "movegen": {
            "LEGAL": legal["moves_raw"],
        },
        "perft": perfts,
        "notes": (
            "Generated via upstream UCI `go perft`. "
            "captures/quiets/evasions/pseudo and key/checkers fields arrive with Phase C dumper."
        ),
    }


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--oracle",
        type=Path,
        default=Path("/Users/hltt/projects/download/pikafish/Pikafish/src/pikafish"),
        help="Compiled upstream pikafish binary",
    )
    ap.add_argument(
        "--out",
        type=Path,
        default=root / "fixtures" / "core" / "startpos.json",
        help="Output JSON path",
    )
    ap.add_argument("--max-perft", type=int, default=5)
    args = ap.parse_args()

    if not args.oracle.is_file():
        print(f"oracle not found: {args.oracle}", file=sys.stderr)
        return 1

    cwd = args.oracle.parent
    fixture = build_startpos_fixture(args.oracle, args.max_perft, cwd)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(fixture, indent=2, sort_keys=False) + "\n")
    print(
        f"wrote {args.out} legal={fixture['legal']['count']} "
        f"perft1={fixture['perft']['1']['nodes']} "
        f"perft5={fixture['perft'].get('5', {}).get('nodes', '?')} "
        f"sha={fixture['upstream_sha'][:12]}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
