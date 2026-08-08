#!/usr/bin/env python3
"""Generate random legal playout fixtures (≥1000 steps; scales toward 10000).

Stores start FEN + UCI move lists from upstream `go perft 1`. GUT replays with
addon Position and checks undo restores fen/key/rule60 after each ply.

Dev-only; do not import from runtime GDScript.
"""
from __future__ import annotations

import argparse
import json
import random
import re
import subprocess
import sys
import time
from pathlib import Path

UPSTREAM_SHA = "2c5c998c211d524d26c38e7e3e71d51bc24cbe64"
START_FEN = "rnbakabnr/9/1c5c1/p1p1p1p1p/9/9/P1P1P1P1P/1C5C1/9/RNBAKABNR w - - 0 1"
DEFAULT_ORACLE = "/Users/hltt/projects/download/pikafish/Pikafish/src/pikafish"

_FILE = {c: i for i, c in enumerate("abcdefghi")}


def uci_to_raw(uci: str) -> int:
    frm = _FILE[uci[0]] + int(uci[1]) * 9
    to = _FILE[uci[2]] + int(uci[3]) * 9
    return (frm << 7) | to


class UciSession:
    def __init__(self, oracle: Path, cwd: Path) -> None:
        self.proc = subprocess.Popen(
            [str(oracle)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            cwd=str(cwd),
            bufsize=1,
        )
        assert self.proc.stdin and self.proc.stdout
        self._expect("uciok", send="uci")
        self._expect("readyok", send="isready")

    def cmd(self, line: str) -> None:
        assert self.proc.stdin
        self.proc.stdin.write(line + "\n")
        self.proc.stdin.flush()

    def _readline(self, timeout: float = 60.0) -> str:
        assert self.proc.stdout
        start = time.time()
        while time.time() - start < timeout:
            line = self.proc.stdout.readline()
            if not line:
                raise RuntimeError("oracle EOF")
            return line.rstrip("\n")
        raise TimeoutError("readline timeout")

    def _expect(self, token: str, send: str | None = None, timeout: float = 60.0) -> None:
        if send is not None:
            self.cmd(send)
        start = time.time()
        while time.time() - start < timeout:
            if token in self._readline(timeout=timeout):
                return
        raise TimeoutError(f"waiting for {token}")

    def legal_uci(self, start_fen: str, moves: list[str]) -> list[str]:
        pos = f"position fen {start_fen}"
        if moves:
            pos += " moves " + " ".join(moves)
        self.cmd(pos)
        self.cmd("go perft 1")
        legal: list[str] = []
        while True:
            line = self._readline()
            m = re.match(r"^([a-i][0-9][a-i][0-9]):\s+(\d+)\s*$", line.strip())
            if m:
                legal.append(m.group(1))
                continue
            if line.startswith("Nodes searched:"):
                break
        return legal

    def close(self) -> None:
        try:
            self.cmd("quit")
            self.proc.wait(timeout=5)
        except Exception:
            self.proc.kill()


def generate(session: UciSession, games: int, max_plies: int, target_steps: int, seed: int) -> dict:
    rng = random.Random(seed)
    game_records: list[dict] = []
    step_count = 0
    for g in range(games):
        if step_count >= target_steps:
            break
        moves: list[str] = []
        for _ply in range(max_plies):
            if step_count >= target_steps:
                break
            legal = session.legal_uci(START_FEN, moves)
            if not legal:
                break
            mv = rng.choice(legal)
            moves.append(mv)
            step_count += 1
        game_records.append(
            {
                "game": g,
                "start_fen": START_FEN,
                "moves_uci": moves,
                "moves_raw": [uci_to_raw(u) for u in moves],
            }
        )
    return {
        "format": "godot-pikafish-playout-fixture/v1",
        "upstream_sha": UPSTREAM_SHA,
        "seed": seed,
        "step_count": step_count,
        "game_count": len(game_records),
        "start_fen": START_FEN,
        "mode": "move_list",
        "games": game_records,
        "notes": (
            "Random legal playouts as UCI move lists (oracle perft-1). "
            "GUT replays with addon Position; after each do_move records fen/key/rule60 "
            "and checks undo restores them."
        ),
    }


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--oracle", type=Path, default=Path(DEFAULT_ORACLE))
    ap.add_argument("--out", type=Path, default=root / "fixtures" / "core" / "playouts.json")
    ap.add_argument("--steps", type=int, default=1000)
    ap.add_argument("--games", type=int, default=80)
    ap.add_argument("--max-plies", type=int, default=40)
    ap.add_argument("--seed", type=int, default=20260807)
    args = ap.parse_args()
    if not args.oracle.is_file():
        print(f"oracle not found: {args.oracle}", file=sys.stderr)
        return 1
    session = UciSession(args.oracle, args.oracle.parent)
    try:
        print(f"generating ~{args.steps} playout steps (seed={args.seed})", flush=True)
        data = generate(session, args.games, args.max_plies, args.steps, args.seed)
    finally:
        session.close()
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(data, indent=2) + "\n")
    print(f"wrote {args.out} steps={data['step_count']} games={data['game_count']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
