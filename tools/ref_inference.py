#!/usr/bin/env python3
"""Fast Python reference inference (pure python + array module) to validate formulas
against the oracle. Reuses attack logic from gen_tables. If this matches the oracle,
the GDScript and compute-shader ports (same formulas) are correct.
"""
import json
import os
import sys
from array import array

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_tables as G

DATA = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "data")
MASK64 = (1 << 64) - 1
BALANCE = 0xA4A92A74E989D3A7 & MASK64
PS_NB = 689
L1 = 1024
FC0 = 32
FC1 = 32
PSQ_DIM = 16536

def flip_color(c): return c ^ 1
def flip_file(s): return G.make_square(8 - G.file_of(s), G.rank_of(s))
def flip_rank(s): return G.make_square(G.file_of(s), 9 - G.rank_of(s))
def char_to_piece(ch):
    pt = {"R":G.ROOK,"A":G.ADVISOR,"C":G.CANNON,"P":G.PAWN,"N":G.KNIGHT,"B":G.BISHOP,"K":G.KING}.get(ch.upper())
    if pt is None: return 0
    c = G.WHITE if ch == ch.upper() else G.BLACK
    return G.make_piece(c, pt)

def cdiv(a, b):
    # integer division truncating toward zero (C++ semantics)
    q = a // b
    if (a % b != 0) and ((a < 0) != (b < 0)):
        q += 1
    return q

# ---- load weights ----
def _i16(path):
    return array('i', struct_iter_i16(open(path, "rb").read()))
def _i32(path):
    return array('i', struct_iter_i32(open(path, "rb").read()))
def _i8(path):
    return array('b', open(path, "rb").read())  # signed bytes

def struct_iter_i16(b):
    out = []
    for i in range(0, len(b), 2):
        v = b[i] | (b[i+1] << 8)
        out.append(v - 65536 if v >= 32768 else v)
    return out
def struct_iter_i32(b):
    out = []
    for i in range(0, len(b), 4):
        v = b[i] | (b[i+1] << 8) | (b[i+2] << 16) | (b[i+3] << 24)
        out.append(v - (1 << 32) if v >= (1 << 31) else v)
    return out

ft_bias = _i16(os.path.join(DATA, "ft_bias.bin"))             # 1024
ft_psq_w = _i8(os.path.join(DATA, "ft_psqW.bin"))             # 16536*1024
ft_psqt = _i32(os.path.join(DATA, "ft_psqt.bin"))             # 16536*16
ft_threat_w = _i8(os.path.join(DATA, "ft_threatW.bin"))       # 45547*1024
ft_threat_psqt = _i32(os.path.join(DATA, "ft_threatPsqt.bin"))# 45547*16

fc0_bias = []; fc0_w = []; fc1_bias = []; fc1_w = []; fc2_bias = []; fc2_w = []
for s in range(16):
    pre = f"stack{s:02d}"
    fc0_bias.append(_i32(os.path.join(DATA, pre + "_fc0_bias.bin")))
    fc0_w.append(_i8(os.path.join(DATA, pre + "_fc0_w.bin")))
    fc1_bias.append(_i32(os.path.join(DATA, pre + "_fc1_bias.bin")))
    fc1_w.append(_i8(os.path.join(DATA, pre + "_fc1_w.bin")))
    fc2_bias.append(_i32(os.path.join(DATA, pre + "_fc2_bias.bin")))
    fc2_w.append(_i8(os.path.join(DATA, pre + "_fc2_w.bin")))

# ---- MidMirrorEncoding ----
def _build_mid_encoding():
    shifts = [[0, 0], [44, 0], [60, 36], [47, 7], [53, 21], [50, 14], [57, 29], [0, 0]]
    enc = [[0] * 90 for _ in range(16)]
    for c in (G.WHITE, G.BLACK):
        for pt in range(G.ROOK, G.KING + 1):
            for r in range(10):
                for f in range(9):
                    e = 0
                    if f != 4 and pt != G.KING:
                        r_ = r if c == G.WHITE else 9 - r
                        f_ = f if f < 4 else 8 - f
                        s1, s2 = shifts[pt]
                        e = (1 << s1) | (((4 - f_) * 10 + r_) << s2)
                        if f > 4:
                            e = (-e) & MASK64
                    elif f != 4 and pt == G.KING:
                        e = 1 << 63
                    p = G.make_piece(c, pt)
                    sq = G.make_square(f, r)
                    enc[p][sq] = e
    return enc

MID_ENC = _build_mid_encoding()

KING_BUCKETS = [0]*90
_rows = [
    [0,0,0,0,1,8,0,0,0],[0,0,0,2,3,10,0,0,0],[0,0,0,4,5,12,0,0,0],
    [0,0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0,0],
    [0,0,0,4,5,12,0,0,0],[0,0,0,2,3,10,0,0,0],[0,0,0,0,1,8,0,0,0],
]
for r in range(10):
    for f in range(9):
        KING_BUCKETS[r*9+f] = _rows[r][f]


def index_map(mirror, rotate, s):
    ss = s
    if mirror: ss = flip_file(ss)
    if rotate: ss = flip_rank(ss)
    return ss


class Board:
    def __init__(self, fen):
        self.sq = [0] * 90
        parts = fen.split()
        ranks = parts[0].split("/")
        for i, rank in enumerate(ranks):
            r = 9 - i
            f = 0
            for ch in rank:
                if ch.isdigit():
                    f += int(ch)
                else:
                    self.sq[r * 9 + f] = char_to_piece(ch)
                    f += 1
        self.stm = G.WHITE if parts[1] == "w" else G.BLACK
    def piece_on(self, s): return self.sq[s]
    def king_square(self, c):
        t = G.make_piece(c, G.KING)
        for s in range(90):
            if self.sq[s] == t: return s
        return -1
    def count(self, pt, c):
        t = G.make_piece(c, pt)
        return sum(1 for s in range(90) if self.sq[s] == t)
    def occupancy(self):
        b = 0
        for s in range(90):
            if self.sq[s]: b |= 1 << s
        return b
    def pieces(self):
        return [(s, p) for s, p in enumerate(self.sq) if p]


def mid_encoding(pos, c):
    mid = BALANCE
    for s, pc in pos.pieces():
        if G.color_of(pc) == c:
            mid = (mid + MID_ENC[pc][s]) & MASK64
    return mid


def requires_mid_mirror(pos, c):
    mc = mid_encoding(pos, c)
    mo = mid_encoding(pos, flip_color(c))
    if ((mc >> 63) & 1) and ((mo >> 63) & 1):
        if mc < BALANCE: return True
        if mc == BALANCE and mo < BALANCE: return True
    return False


_AB = [[[ (1 if rk>0 else 0)*2 + (1 if kn+cn>0 else 0) for cn in range(3)] for kn in range(3)] for rk in range(3)]
def make_attack_bucket(pos, c):
    return _AB[min(pos.count(G.ROOK,c),2)][min(pos.count(G.KNIGHT,c),2)][min(pos.count(G.CANNON,c),2)]


def make_feature_bucket(perspective, pos):
    ksq = pos.king_square(perspective)
    oksq = pos.king_square(flip_color(perspective))
    midm = requires_mid_mirror(pos, perspective)
    kb_ = KING_BUCKETS[ksq]; king_bucket = kb_ & 7
    okb_ = KING_BUCKETS[oksq]
    m1 = (kb_ >> 3) != 0; m2 = (king_bucket & 1) != 0
    m3 = (okb_ >> 3) != 0; m4 = (okb_ & 1) != 0
    mirror = m1 or (m2 and (m3 or (m4 and midm)))
    return king_bucket * 4 + make_attack_bucket(pos, perspective), mirror


def make_layer_stack_bucket(pos):
    us = pos.stm; opp = flip_color(us)
    ur = min(pos.count(G.ROOK,us),2); orr = min(pos.count(G.ROOK,opp),2)
    ukc = min(pos.count(G.KNIGHT,us)+pos.count(G.CANNON,us),4)
    okc = min(pos.count(G.KNIGHT,opp)+pos.count(G.CANNON,opp),4)
    if ur==orr: return ur*4 + (2 if ukc+okc>=4 else 0) + (1 if ukc==okc else 0)
    if ur==2 and orr==1: return 12
    if ur==1 and orr==2: return 13
    if ur>0 and orr==0: return 14
    return 15


def make_index_psq(persp, s, pc, bucket, mirror):
    s = index_map(mirror, persp == G.BLACK, s)
    if persp == G.BLACK: pc = pc ^ 8
    off = G.PSQOffsets[pc][s]
    if off == 0xFFFF: return -1
    return off + PS_NB * bucket


def make_index_threat(persp, attacker, frm, to, attacked, mirror):
    frm = index_map(mirror, persp == G.BLACK, frm)
    to = index_map(mirror, persp == G.BLACK, to)
    if persp == G.BLACK:
        attacker = attacker ^ 8; attacked = attacked ^ 8
    return G.ThreatOffsets[attacker][frm][to][attacked]


def append_active_psq(persp, pos, bucket, mirror):
    out = []
    for s, pc in pos.pieces():
        idx = make_index_psq(persp, s, pc, bucket, mirror)
        if idx >= 0: out.append(idx)
    return out


def append_active_threats(persp, pos, mirror):
    out = []
    occ = pos.occupancy()
    for frm, attacker in pos.pieces():
        pt = G.type_of(attacker); col = G.color_of(attacker)
        attacks = G.attacks_bb_pt(pt, frm, occ, col)
        for to in G.bb_squares(attacks & occ):
            idx = make_index_threat(persp, attacker, frm, to, pos.piece_on(to), mirror)
            if idx < G.THREAT_DIM:
                out.append(idx)
    return out


def evaluate(pos):
    stm = pos.stm
    perspectives = [stm, flip_color(stm)]
    accs = [None, None]; psqts = [None, None]
    for p in range(2):
        persp = perspectives[p]
        bucket, mirror = make_feature_bucket(persp, pos)
        psq = append_active_psq(persp, pos, bucket, mirror)
        thr = append_active_threats(persp, pos, mirror)
        a = list(ft_bias)
        for idx in psq:
            base = idx * L1
            a = [x + y for x, y in zip(a, ft_psq_w[base:base+L1])]
        for idx in thr:
            base = idx * L1
            a = [x + y for x, y in zip(a, ft_threat_w[base:base+L1])]
        accs[p] = a
        pa = [0]*16
        for idx in psq:
            base = idx * 16
            pa = [pa[b] + ft_psqt[base+b] for b in range(16)]
        for idx in thr:
            base = idx * 16
            pa = [pa[b] + ft_threat_psqt[base+b] for b in range(16)]
        psqts[p] = pa

    lbucket = make_layer_stack_bucket(pos)
    psqt_val = cdiv(psqts[0][lbucket] - psqts[1][lbucket], 2)

    # transform
    tf = [0]*L1
    for p in range(2):
        a = accs[p]; off = 512*p
        for j in range(512):
            s0 = a[j]; s0 = 0 if s0 < 0 else (255 if s0 > 255 else s0)
            s1 = a[j+512]; s1 = 0 if s1 < 0 else (255 if s1 > 255 else s1)
            tf[off+j] = (s0 * s1) // 512

    st = lbucket
    w0 = fc0_w[st]; b0 = fc0_bias[st]
    y0 = [0]*FC0
    for o in range(FC0):
        base = o*L1
        s = b0[o] + sum(tf[i] * w0[base+i] for i in range(L1))
        y0[o] = s
    sqr0 = [min(127, (y*y) >> 21) for y in y0]
    clip0 = [0 if (y>>7) < 0 else (127 if (y>>7) > 127 else (y>>7)) for y in y0]
    c1 = sqr0 + clip0
    w1 = fc1_w[st]; b1 = fc1_bias[st]
    y1 = [0]*FC1
    for o in range(FC1):
        base = o*64
        y1[o] = b1[o] + sum(c1[i] * w1[base+i] for i in range(64))
    sqr1 = [min(127, (y*y) >> 19) for y in y1]
    clip1 = [0 if (y>>6) < 0 else (127 if (y>>6) > 127 else (y>>6)) for y in y1]
    c2 = sqr0 + clip0 + sqr1 + clip1
    w2 = fc2_w[st]
    y2 = fc2_bias[st][0] + sum(c2[i] * w2[i] for i in range(128))
    fwd = y2 + (y0[30] - y0[31])
    positional = cdiv(fwd * 9600, 16384)
    return cdiv(psqt_val, 16) + cdiv(positional, 16)


def _debug_evaluate(pos):
    stm = pos.stm
    perspectives = [stm, flip_color(stm)]
    for p in range(2):
        persp = perspectives[p]
        bucket, mirror = make_feature_bucket(persp, pos)
        psq = append_active_psq(persp, pos, bucket, mirror)
        thr = append_active_threats(persp, pos, mirror)
        print(f"  persp{persp} bucket={bucket} mirror={mirror} psq#{len(psq)} thr#{len(thr)} midm={requires_mid_mirror(pos, persp)}")
    print("  layer_bucket=", make_layer_stack_bucket(pos))


def main():
    ref = json.load(open(os.path.join(DATA, "reference.json")))
    # debug first position
    rec0 = ref[0]
    b0 = Board(rec0["fen"])
    _debug_evaluate(b0)
    ok = bad = 0; worst = 0
    for i, rec in enumerate(ref):
        b = Board(rec["fen"])
        got = evaluate(b)
        want = int(rec["internal"])
        diff = abs(got - want)
        status = "OK " if diff <= 1 else "FAIL"
        if diff <= 1: ok += 1
        else:
            bad += 1
            if diff > worst: worst = diff
        print(f"{status} [{i:02d}] stm={rec['stm']} got={got:+d} want={want:+d} diff={diff}  {rec['fen'][:38]}")
    print(f"\nresult: ok={ok} bad={bad} worst_diff={worst}")


if __name__ == "__main__":
    main()
