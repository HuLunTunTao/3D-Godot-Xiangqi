#!/usr/bin/env python3
"""Run the built pikafish oracle on a set of FENs and dump eval traces to data/reference.json.

For each FEN, capture: side to move, all 16 buckets (material/positional in pawns),
the correct (layer-stack) bucket, and the internal integer eval (the exact match target).
"""
import argparse
import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_OUT = os.path.join(ROOT, "data", "reference.json")

# Diverse Xiangqi positions (from pikafish benchmark Defaults). Board + side only.
FENS = [
    "rnbakabnr/9/1c5c1/p1p1p1p1p/9/9/P1P1P1P1P/1C5C1/9/RNBAKABNR w",
    "r1ba1a3/4kn3/2n1b4/pNp1p1p1p/4c4/6P2/P1P2R2P/1CcC5/9/2BAKAB2 w",
    "1cbak4/9/n2a5/2p1p3p/5cp2/2n2N3/6PCP/3AB4/2C6/3A1K1N1 w",
    "5a3/3k5/3aR4/9/5r3/5n3/9/3A1A3/5K3/2BC2B2 w",
    "2bak4/9/3a5/p2Np3p/3n1P3/3pc3P/P4r1c1/B2CC2R1/4A4/3AK1B2 b",
    "1r1akabr1/1c7/2n1b1n2/p1p1p3p/6p2/PN3R3/1cP1P1P1P/2C1C1N2/1R7/2BAKAB2 b",
    "2b1ka2r/3na2c1/4b3n/8R/8C/4C1P2/P1P1P3P/4B1N2/1r2A4/2BAK4 w",
    "2bckab2/4a4/5n3/CR3N2p/5r3/P3P1B2/9/2n1B4/4A4/3AK1C2 w",
    "2b1kab1C/1N2a4/n3ccn2/p5r1p/4p4/P1P2RN2/2r1P3P/C3B4/4A4/2BAK2R1 w",
    "2bakab2/9/2n1c1R1c/3r4p/4N4/r8/6P1P/6C1C/4A4/1RBAK1B2 w",
    "2bak1b1r/4a4/2n4cn/p6C1/4pN3/P2N4R/4P1P1P/3CB4/4A2r1/c1BAKR3 w",
    "1r2kabr1/4a4/2C1b2c1/p3p3p/1c3n3/2p3R2/P3P3P/N3C1N2/7R1/2BAKAB2 b",
    "3ak1b2/4a4/2n1b1R2/p1N1pc2p/7r1/2PN1r3/P3P3P/3RB4/4A4/1C2KAB1c w",
    "2baka1r1/9/c5n1c/p3p1CCp/2p3p2/4P4/P6RP/2r1B1N2/4A4/1RB1KA3 w",
    "3akabr1/9/4c4/p1pRn2Cp/4rcp2/2P1p4/P3P1P1P/3CB1N2/9/3AKABR1 w",
    "3akab2/3r5/8n/8p/2P1C1b2/8P/cR2N2r1/2n1B1N2/4A4/2B1KR3 w",
    "2bak4/4a1R2/2n1ccn1b/p3p1C1p/9/2p3P2/P1r1P3P/2N1BCN2/4A4/2BAK4 w",
    "4kabr1/4a4/2n1b3n/p1C1p3p/6p2/PNP6/4P1P2/1C2B4/4A4/1R2KAB1c w",
    "3ak1bn1/4a4/1c2b1c2/r3p1N1p/p1p6/6P2/n1P1P3P/N1C1C3B/3R5/2BAKA3 w",
    "1rb1kabr1/4a4/1c7/p1p1R3p/7n1/2P3p2/P3P1c1P/C1N6/4N4/1RBAKAB2 w",
    "r1b1kabr1/4a1c2/1cn3n2/p1p1pR2p/3NP4/2P6/P5p1P/1C2C4/9/RNBAKAB2 b",
    "4ka3/3Pa4/r6R1/2C4C1/9/9/8n/9/4p3r/3K3R1 w",
    "4ka3/4a4/N8/p8/C8/9/9/8B/3p2ppc/4K4 w",
    "C3kab2/4a4/2Rnb3n/8p/6p2/1p2c3r/P5P2/4B3N/3CA4/2BAK4 w",
]


def run_eval(oracle, net, fen):
    cmd = f"setoption name EvalFile value {net}\nisready\nposition fen {fen}\neval\nquit\n"
    p = subprocess.run([oracle], input=cmd, capture_output=True, text=True, timeout=30)
    return p.stdout


ROW = re.compile(r"\|\s*(\d+)\s*\|\s*([+-]?[\d.]+)\s*\|\s*([+-]?[\d.]+)\s*\|\s*([+-]?[\d.]+)\s*\|(\s*<--)?")
STM = re.compile(r"\((White|Black) to move\)")
INTERNAL = re.compile(r"NNUE evaluation\s+([+-]?\d+)\s+\(side to move, internal units\)")
WHITEPV = re.compile(r"NNUE evaluation\s+([+-]?[\d.]+)\s+\(white side\)")
ERR = re.compile(r"ERROR", re.I)


def parse(out, fen):
    if ERR.search(out):
        return None
    rec = {"buckets": [], "correct_bucket": None, "internal": None, "white_pawns": None, "stm": None}
    m = STM.search(out)
    if m:
        rec["stm"] = m.group(1).lower()
    # stm is always available from the FEN (trailing w/b); used when trace is omitted (in-check)
    fen_stm = fen.strip().split()[-1]
    if fen_stm in ("w", "b"):
        rec["stm"] = fen_stm
    for line in out.splitlines():
        m = ROW.search(line)
        if m:
            b = int(m.group(1))
            rec["buckets"].append({
                "bucket": b,
                "material": float(m.group(2)),
                "positional": float(m.group(3)),
                "total": float(m.group(4)),
            })
            if m.group(5):
                rec["correct_bucket"] = b
    m = INTERNAL.search(out)
    if m:
        rec["internal"] = int(m.group(1))
    m = WHITEPV.search(out)
    if m:
        rec["white_pawns"] = float(m.group(1))
    return rec


def parse_args():
    p = argparse.ArgumentParser(description="Generate oracle reference evals for benchmark FENs.")
    p.add_argument("--oracle", required=True, help="Path to built pikafish binary")
    p.add_argument("--net", required=True, help="Path to pikafish.nnue eval network file")
    p.add_argument(
        "-o", "--out",
        default=DEFAULT_OUT,
        help=f"Output JSON path (default: {DEFAULT_OUT})",
    )
    return p.parse_args()


def main():
    args = parse_args()
    oracle = os.path.abspath(args.oracle)
    net = os.path.abspath(args.net)
    out_path = os.path.abspath(args.out)
    for label, path in (("oracle", oracle), ("net", net)):
        if not os.path.isfile(path):
            print(f"error: {label} not found: {path}", file=sys.stderr)
            sys.exit(1)

    records = []
    for i, fen in enumerate(FENS):
        out = run_eval(oracle, net, fen)
        rec = parse(out, fen)
        if rec is None or rec["internal"] is None:
            print(f"[{i:02d}] FAILED: {fen}")
            print(out[-300:])
            continue
        rec["fen"] = fen
        records.append(rec)
        cb = rec["correct_bucket"]
        print(f"[{i:02d}] stm={rec['stm']} bucket={cb} internal={rec['internal']:+d} "
              f"white={rec['white_pawns']:+.2f}  {fen[:40]}")
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "w") as f:
        json.dump(records, f, indent=2)
    print(f"\nwrote {len(records)} records to {out_path}")


if __name__ == "__main__":
    main()
