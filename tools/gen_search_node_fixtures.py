#!/usr/bin/env python3
"""Generate fixed-node search fixtures from the pinned upstream Pikafish oracle.

The fixture is intentionally separate from depth_corpus.json: node budgets make
search divergence measurable even when two engines finish different ID depths.
Dev-only; never used by the addon at runtime.

Units: UCI `score cp` is to_cp(Value), NOT internal Value. Optional
`internal_value` may be filled from `info string raw_value N` instrumentation.
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import time
from pathlib import Path

from gen_search_fixtures import DEFAULT_EVAL, DEFAULT_ORACLE, SEARCH_FENS, UPSTREAM_SHA

INFO_RE = re.compile(
    r"^info depth (?P<depth>\d+)\b.*?\bscore (?P<type>cp|mate) (?P<score>-?\d+)\b"
    r".*?\bnodes (?P<nodes>\d+)\b(?:.*?\bpv (?P<pv>.+))?$"
)
RAW_VALUE_RE = re.compile(r"^info string raw_value (?P<value>-?\d+)\b")
BEST_RE = re.compile(r"^bestmove\s+([a-i][0-9][a-i][0-9]|\(none\))")
DEFAULT_LABELS = {"startpos", "ref2_rook_check", "ref5_rook_lift", "ref20_mate_net"}


class UciSession:
    def __init__(self, oracle: Path, eval_file: Path) -> None:
        self.proc = subprocess.Popen(
            [str(oracle)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, text=True, cwd=str(oracle.parent), bufsize=1,
        )
        assert self.proc.stdin and self.proc.stdout
        self.expect("uciok", "uci")
        self.cmd(f"setoption name EvalFile value {eval_file}")
        self.cmd("setoption name Threads value 1")
        self.cmd("setoption name Hash value 64")
        self.cmd("setoption name MultiPV value 1")
        self.expect("readyok", "isready")

    def cmd(self, command: str) -> None:
        assert self.proc.stdin
        self.proc.stdin.write(command + "\n")
        self.proc.stdin.flush()

    def line(self, timeout: float = 120.0) -> str:
        assert self.proc.stdout
        started = time.time()
        while time.time() - started < timeout:
            line = self.proc.stdout.readline()
            if line:
                return line.rstrip("\n")
            raise RuntimeError("oracle EOF")
        raise TimeoutError("oracle readline timeout")

    def expect(self, token: str, command: str) -> None:
        self.cmd(command)
        while True:
            if token in self.line():
                return

    def go_nodes(self, fen: str, budget: int) -> dict:
        self.cmd("ucinewgame")
        self.cmd(f"position fen {fen}")
        self.cmd(f"go nodes {budget}")
        infos: list[dict] = []
        raw_values: list[int] = []
        bestmove = ""
        while True:
            line = self.line(timeout=300.0)
            raw = RAW_VALUE_RE.match(line)
            if raw:
                raw_values.append(int(raw.group("value")))
                continue
            match = INFO_RE.match(line)
            if match:
                pv = (match.group("pv") or "").split()
                entry = {
                    "depth": int(match.group("depth")),
                    "score": {"type": match.group("type"), "value": int(match.group("score"))},
                    "nodes": int(match.group("nodes")),
                    "pv": pv,
                }
                if raw_values:
                    entry["internal_value"] = raw_values[-1]
                infos.append(entry)
                continue
            match = BEST_RE.match(line)
            if match:
                bestmove = match.group(1)
                break
        final = next((entry for entry in reversed(infos) if entry["pv"]), None)
        out = {
            "budget": budget,
            "bestmove": bestmove,
            # UCI score cp / mate — NOT internal Value.
            "score": final["score"] if final else None,
            "nodes": final["nodes"] if final else 0,
            "completed_depth": final["depth"] if final else 0,
            "pv": final["pv"][:12] if final else [],
        }
        if final and "internal_value" in final:
            out["internal_value"] = final["internal_value"]
        return out

    def close(self) -> None:
        try:
            self.cmd("quit")
            self.proc.wait(timeout=5)
        except Exception:
            self.proc.kill()


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--oracle", type=Path, default=Path(DEFAULT_ORACLE))
    parser.add_argument("--eval", type=Path, default=Path(DEFAULT_EVAL))
    parser.add_argument("--out", type=Path, default=root / "fixtures/search/node_corpus.json")
    parser.add_argument("--budgets", type=int, nargs="+", default=[256, 1024])
    parser.add_argument("--all-positions", action="store_true")
    args = parser.parse_args()
    if not args.oracle.is_file() or not args.eval.is_file():
        print("oracle or nnue file not found", file=sys.stderr)
        return 1
    positions = SEARCH_FENS if args.all_positions else [p for p in SEARCH_FENS if p[0] in DEFAULT_LABELS]
    session = UciSession(args.oracle, args.eval)
    try:
        records = []
        for label, fen in positions:
            runs = []
            for budget in args.budgets:
                print(f"node fixture {label} nodes={budget}", flush=True)
                runs.append(session.go_nodes(fen, budget))
            records.append({"label": label, "fen": fen, "runs": runs})
    finally:
        session.close()
    payload = {
        "format": "godot-pikafish-node-fixture/v1",
        "upstream_sha": UPSTREAM_SHA,
        "oracle": str(args.oracle),
        "threads": 1,
        "positions": records,
        "notes": (
            "UCI go nodes N; node count can slightly exceed N at a stop-check boundary. "
            "score.value for type=cp is UCI to_cp(Value), not internal Value. "
            "Optional internal_value comes from info string raw_value instrumentation."
        ),
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(payload, indent=2) + "\n")
    print(f"wrote {args.out} positions={len(records)} budgets={args.budgets}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
