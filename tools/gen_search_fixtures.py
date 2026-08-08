#!/usr/bin/env python3
"""Dump search + expanded perft fixtures from upstream Pikafish UCI (plan §G).

Uses an interactive UCI session so NNUE is loaded before `go depth`.
Dev-only; do not import from runtime GDScript.
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import time
from pathlib import Path

UPSTREAM_SHA = "2c5c998c211d524d26c38e7e3e71d51bc24cbe64"
START_FEN = "rnbakabnr/9/1c5c1/p1p1p1p1p/9/9/P1P1P1P1P/1C5C1/9/RNBAKABNR w - - 0 1"
DEFAULT_EVAL = "/Users/hltt/projects/download/pikafish/pikafish.nnue"
DEFAULT_ORACLE = "/Users/hltt/projects/download/pikafish/Pikafish/src/pikafish"

# startpos + ~10 tactical/midgame FENs from local reference corpus (full FEN).
SEARCH_FENS: list[tuple[str, str]] = [
    ("startpos", START_FEN),
    (
        "ref1_opening_mid",
        "r1ba1a3/4kn3/2n1b4/pNp1p1p1p/4c4/6P2/P1P2R2P/1CcC5/9/2BAKAB2 w - - 0 1",
    ),
    (
        "ref2_rook_check",
        "5a3/3k5/3aR4/9/5r3/5n3/9/3A1A3/5K3/2BC2B2 w - - 0 1",
    ),
    (
        "ref3_complex_b",
        "2bak4/9/3a5/p2Np3p/3n1P3/3pc3P/P4r1c1/B2CC2R1/4A4/3AK1B2 b - - 0 1",
    ),
    (
        "ref4_double_rook",
        "1r1akabr1/1c7/2n1b1n2/p1p1p3p/6p2/PN3R3/1cP1P1P1P/2C1C1N2/1R7/2BAKAB2 b - - 0 1",
    ),
    (
        "ref5_rook_lift",
        "2b1ka2r/3na2c1/4b3n/8R/8C/4C1P2/P1P1P3P/4B1N2/1r2A4/2BAK4 w - - 0 1",
    ),
    (
        "ref6_exchange",
        "2bckab2/4a4/5n3/CR3N2p/5r3/P3P1B2/9/2n1B4/4A4/3AK1C2 w - - 0 1",
    ),
    (
        "ref7_tactical",
        "2b1kab1C/1N2a4/n3ccn2/p5r1p/4p4/P1P2RN2/2r1P3P/C3B4/4A4/2BAK2R1 w - - 0 1",
    ),
    (
        "ref8_pressure",
        "2bakab2/9/2n1c1R1c/3r4p/4N4/r8/6P1P/6C1C/4A4/1RBAK1B2 w - - 0 1",
    ),
    (
        "ref20_mate_net",
        "4ka3/3Pa4/r6R1/2C4C1/9/9/8n/9/4p3r/3K3R1 w - - 0 1",
    ),
    (
        "ref21_endgame",
        "4ka3/4a4/N8/p8/C8/9/9/8B/3p2ppc/4K4 w - - 0 1",
    ),
]

_FILE = {c: i for i, c in enumerate("abcdefghi")}
_INFO_RE = re.compile(
    r"^info depth (?P<depth>\d+)\b.*?\bmultipv (?P<multipv>\d+)\b"
    r".*?\bscore (?P<stype>cp|mate) (?P<sval>-?\d+)\b"
    r".*?\bnodes (?P<nodes>\d+)\b"
    r"(?:.*?\bpv (?P<pv>.+))?$"
)
_BEST_RE = re.compile(r"^bestmove\s+([a-i][0-9][a-i][0-9]| \(none\))")


def uci_to_raw(uci: str) -> int:
    ff, fr, tf, tr = uci[0], uci[1], uci[2], uci[3]
    frm = _FILE[ff] + int(fr) * 9
    to = _FILE[tf] + int(tr) * 9
    return (frm << 7) | to


class UciSession:
    def __init__(self, oracle: Path, eval_file: Path, cwd: Path) -> None:
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
        self.cmd(f"setoption name EvalFile value {eval_file}")
        self.cmd("setoption name Hash value 64")
        self.cmd("setoption name Threads value 1")
        self._expect("readyok", send="isready")

    def cmd(self, line: str) -> None:
        assert self.proc.stdin
        self.proc.stdin.write(line + "\n")
        self.proc.stdin.flush()

    def _readline(self, timeout: float = 120.0) -> str:
        assert self.proc.stdout
        start = time.time()
        while time.time() - start < timeout:
            line = self.proc.stdout.readline()
            if not line:
                raise RuntimeError("oracle EOF")
            return line.rstrip("\n")
        raise TimeoutError("oracle readline timeout")

    def _expect(self, token: str, send: str | None = None, timeout: float = 120.0) -> list[str]:
        if send is not None:
            self.cmd(send)
        lines: list[str] = []
        start = time.time()
        while time.time() - start < timeout:
            line = self._readline(timeout=timeout)
            lines.append(line)
            if token in line:
                return lines
        raise TimeoutError(f"waiting for {token!r}")

    def go_depth(self, fen: str, depth: int, multipv: int = 8) -> dict:
        self.cmd(f"setoption name MultiPV value {multipv}")
        self.cmd(f"position fen {fen}")
        self.cmd(f"go depth {depth}")
        infos: list[dict] = []
        bestmove = ""
        while True:
            line = self._readline(timeout=300.0)
            m = _INFO_RE.match(line)
            if m:
                pv_raw = (m.group("pv") or "").strip()
                pv_moves = pv_raw.split() if pv_raw else []
                infos.append(
                    {
                        "depth": int(m.group("depth")),
                        "multipv": int(m.group("multipv")),
                        "score_type": m.group("stype"),
                        "score": int(m.group("sval")),
                        "nodes": int(m.group("nodes")),
                        "pv": pv_moves,
                        "move": pv_moves[0] if pv_moves else "",
                    }
                )
                continue
            bm = _BEST_RE.match(line)
            if bm:
                bestmove = bm.group(1)
                break
        final = [i for i in infos if i["depth"] == depth and i["move"]]
        # Fallback: last completed depth with PVs.
        if not final:
            max_d = max((i["depth"] for i in infos if i["move"]), default=0)
            final = [i for i in infos if i["depth"] == max_d and i["move"]]
        final.sort(key=lambda x: x["multipv"])
        root_moves = [i["move"] for i in final if i["move"]]
        top = final[0] if final else None
        unique = False
        if top is not None:
            if len(final) <= 1:
                unique = True
            else:
                s0 = _score_key(top)
                s1 = _score_key(final[1])
                # Unique when clear gap: mate vs non-mate, or cp gap >= 50.
                if top["score_type"] == "mate" and final[1]["score_type"] != "mate":
                    unique = True
                elif top["score_type"] == "cp" and final[1]["score_type"] == "cp":
                    unique = (s0 - s1) >= 50
                elif top["score_type"] == "mate" and final[1]["score_type"] == "mate":
                    unique = abs(top["score"]) < abs(final[1]["score"])
        if bestmove and bestmove not in root_moves:
            root_moves = [bestmove] + root_moves
        score_obj = None
        if top is not None:
            score_obj = {"type": top["score_type"], "value": top["score"]}
        nodes = top["nodes"] if top is not None else (infos[-1]["nodes"] if infos else 0)
        return {
            "bestmove": bestmove,
            "bestmove_raw": uci_to_raw(bestmove) if len(bestmove) == 4 else 0,
            "score": score_obj,
            "nodes": nodes,
            "unique": unique,
            "root_moves": root_moves,
            "root_moves_raw": [uci_to_raw(u) for u in root_moves if len(u) == 4],
            "multipv": [
                {
                    "rank": i["multipv"],
                    "move": i["move"],
                    "score": {"type": i["score_type"], "value": i["score"]},
                    "pv": i["pv"][:6],
                }
                for i in final
            ],
        }

    def go_perft(self, fen: str, depth: int) -> dict:
        self.cmd(f"position fen {fen}")
        self.cmd(f"go perft {depth}")
        moves: list[tuple[str, int]] = []
        total = None
        while True:
            line = self._readline(timeout=300.0)
            m = re.match(r"^([a-i][0-9][a-i][0-9]):\s+(\d+)\s*$", line.strip())
            if m:
                moves.append((m.group(1), int(m.group(2))))
                continue
            m = re.match(r"^Nodes searched:\s+(\d+)\s*$", line.strip())
            if m:
                total = int(m.group(1))
                break
        if total is None:
            raise RuntimeError(f"perft parse failed for depth {depth}")
        moves_sorted = sorted(moves, key=lambda t: t[0])
        return {
            "depth": depth,
            "nodes": total,
            "moves_uci": [u for u, _ in moves_sorted],
            "moves_raw": [uci_to_raw(u) for u, _ in moves_sorted],
            "move_nodes": {u: n for u, n in moves_sorted},
        }

    def close(self) -> None:
        try:
            self.cmd("quit")
            self.proc.wait(timeout=5)
        except Exception:
            self.proc.kill()


def _score_key(info: dict) -> int:
    """Order scores so larger is better for side to move (mate preferred)."""
    if info["score_type"] == "mate":
        v = int(info["score"])
        if v > 0:
            return 100000 - v
        return -100000 - v
    return int(info["score"])


def build_search_corpus(session: UciSession, max_depth: int) -> dict:
    positions = []
    for label, fen in SEARCH_FENS:
        depths = {}
        for d in range(1, max_depth + 1):
            print(f"  search {label} depth {d}...", flush=True)
            depths[str(d)] = session.go_depth(fen, d, multipv=8)
        positions.append({"label": label, "fen": fen, "depths": depths})
    return {
        "format": "godot-pikafish-search-fixture/v1",
        "upstream_sha": UPSTREAM_SHA,
        "max_depth": max_depth,
        "positions": positions,
        "notes": (
            "Generated via interactive UCI `go depth N` + MultiPV. "
            "unique=true when top multipv leads by >=50cp or clearer mate. "
            "Addon search may diverge in root ordering; GUT asserts exact when unique, "
            "else bestmove ∈ root_moves."
        ),
    }


def build_perft_corpus(session: UciSession, max_depth: int, deep_depth: int) -> dict:
    """Perft for the same FEN set; deep_depth only when quick enough."""
    positions = []
    for label, fen in SEARCH_FENS:
        perfts = {}
        for d in range(1, max_depth + 1):
            print(f"  perft {label} depth {d}...", flush=True)
            entry = session.go_perft(fen, d)
            rec: dict = {"nodes": entry["nodes"]}
            if d <= 2:
                rec["root_split"] = entry["move_nodes"]
                rec["moves_uci"] = entry["moves_uci"]
                rec["moves_raw"] = entry["moves_raw"]
            perfts[str(d)] = rec
        for d in range(max_depth + 1, deep_depth + 1):
            print(f"  perft {label} depth {d} (deep)...", flush=True)
            t0 = time.time()
            entry = session.go_perft(fen, d)
            elapsed = time.time() - t0
            perfts[str(d)] = {"nodes": entry["nodes"], "elapsed_s": round(elapsed, 3)}
            if elapsed > 8.0:
                print(f"    slow ({elapsed:.1f}s); skipping deeper for this FEN", flush=True)
                break
        positions.append(
            {
                "label": label,
                "fen": fen,
                "legal_count": perfts.get("1", {}).get("nodes"),
                "perft": perfts,
            }
        )
    return {
        "format": "godot-pikafish-perft-fixture/v1",
        "upstream_sha": UPSTREAM_SHA,
        "positions": positions,
        "notes": "Expanded perft corpus; depth 1–3 always; 4–5 when quick.",
    }


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--oracle", type=Path, default=Path(DEFAULT_ORACLE))
    ap.add_argument("--eval", type=Path, default=Path(DEFAULT_EVAL))
    ap.add_argument(
        "--search-out",
        type=Path,
        default=root / "fixtures" / "search" / "depth_corpus.json",
    )
    ap.add_argument(
        "--perft-out",
        type=Path,
        default=root / "fixtures" / "core" / "perft_corpus.json",
    )
    ap.add_argument("--max-depth", type=int, default=6, help="search depths 1..N (try 8)")
    ap.add_argument("--perft-depth", type=int, default=3)
    ap.add_argument("--perft-deep", type=int, default=5)
    ap.add_argument("--skip-search", action="store_true")
    ap.add_argument("--skip-perft", action="store_true")
    args = ap.parse_args()

    if not args.oracle.is_file():
        print(f"oracle not found: {args.oracle}", file=sys.stderr)
        return 1
    if not args.eval.is_file():
        print(f"eval not found: {args.eval}", file=sys.stderr)
        return 1

    cwd = args.oracle.parent
    session = UciSession(args.oracle, args.eval, cwd)
    try:
        if not args.skip_search:
            print(f"building search corpus depth 1..{args.max_depth}", flush=True)
            search = build_search_corpus(session, args.max_depth)
            args.search_out.parent.mkdir(parents=True, exist_ok=True)
            args.search_out.write_text(json.dumps(search, indent=2) + "\n")
            npos = len(search["positions"])
            print(f"wrote {args.search_out} positions={npos} max_depth={args.max_depth}")
        if not args.skip_perft:
            print(
                f"building perft corpus depth 1..{args.perft_depth} "
                f"(deep to {args.perft_deep})",
                flush=True,
            )
            perft = build_perft_corpus(session, args.perft_depth, args.perft_deep)
            args.perft_out.parent.mkdir(parents=True, exist_ok=True)
            args.perft_out.write_text(json.dumps(perft, indent=2) + "\n")
            print(f"wrote {args.perft_out} positions={len(perft['positions'])}")
    finally:
        session.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
