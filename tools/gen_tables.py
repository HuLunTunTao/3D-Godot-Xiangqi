#!/usr/bin/env python3
"""Precompute bitboard-derived tables for the GDScript NNUE port.

Outputs (in data/):
  valid_bb.bin        : per-piece valid square sets. 16 pieces; for each, a u8 count + count u8 squares.
                        (kept simple: 16 * 90 u8 mask, 1 if square valid for piece)
  psq_offsets.bin     : u16[16][90], PSQOffsets[pc][sq] (0..688), 0xFFFF if invalid
  threat_offsets.bin  : u16[16][90][90][16], ThreatOffsets[a][from][to][attacked], 0xFFFF==invalid(=Dimensions)

Validates: PSQOffsets has exactly 689 valid entries; ThreatOffsets has exactly 45547 valid entries.
"""
import os
import struct

OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "data")

# ---- types ----
WHITE, BLACK = 0, 1
NO_PIECE_TYPE, ROOK, ADVISOR, CANNON, PAWN, KNIGHT, BISHOP, KING = 0, 1, 2, 3, 4, 5, 6, 7
PIECE_TYPE_NB = 8
# Piece enum: W_ROOK=1..W_KING=7, B_ROOK=9..B_KING=15
def make_piece(c, pt): return (c << 3) + pt
def type_of(pc): return pc & 7
def color_of(pc): return pc >> 3
AllPieces = [make_piece(WHITE, pt) for pt in range(ROOK, KING + 1)] + \
            [make_piece(BLACK, pt) for pt in range(ROOK, KING + 1)]

SQUARE_NB = 90
FILE_NB = 9
RANK_NB = 10
def make_square(f, r): return r * FILE_NB + f
def file_of(s): return s % FILE_NB
def rank_of(s): return s // FILE_NB
def is_ok(s): return 0 <= s < SQUARE_NB
def dist_file(x, y): return abs(file_of(x) - file_of(y))
def dist_rank(x, y): return abs(rank_of(x) - rank_of(y))
def dist_sq(x, y): return max(dist_file(x, y), dist_rank(x, y))

NORTH, EAST, SOUTH, WEST = 9, 1, -9, -1
NORTH_EAST, NORTH_WEST, SOUTH_EAST, SOUTH_WEST = NORTH + EAST, NORTH + WEST, SOUTH + EAST, SOUTH + WEST

# ---- bitboard as python int (90-bit) ----
def square_bb(s): return 1 << s
Palace = 0
for r in (0, 1, 2, 7, 8, 9):
    for f in (3, 4, 5):
        Palace |= square_bb(make_square(f, r))
FileABB = 0
for r in range(RANK_NB):
    FileABB |= square_bb(make_square(0, r))
FileIBB = 0
for r in range(RANK_NB):
    FileIBB |= square_bb(make_square(8, r))
FileEBB = 0
for r in range(RANK_NB):
    FileEBB |= square_bb(make_square(4, r))
FileDBB = FileABB << 3
FileFBB = FileABB << 5
FileCBB = FileABB << 2
FileGBB = FileABB << 6
def rank_bb(r): return ((1 << FILE_NB) - 1) << (FILE_NB * r)
Rank0BB, Rank2BB, Rank4BB, Rank5BB, Rank7BB, Rank9BB = rank_bb(0), rank_bb(2), rank_bb(4), rank_bb(5), rank_bb(7), rank_bb(9)
HalfBB = [rank_bb(0) | rank_bb(1) | rank_bb(2) | rank_bb(3) | rank_bb(4),
          rank_bb(5) | rank_bb(6) | rank_bb(7) | rank_bb(8) | rank_bb(9)]
PawnFileBB = FileABB | FileCBB | FileEBB | FileGBB | FileIBB
PawnBB = [HalfBB[BLACK] | ((rank_bb(3) | rank_bb(4)) & PawnFileBB),
          HalfBB[WHITE] | ((rank_bb(6) | rank_bb(5)) & PawnFileBB)]

def bb_squares(bb):
    s = []
    i = 0
    while bb:
        if bb & 1:
            s.append(i)
        bb >>= 1
        i += 1
    return s

# ---- attack functions (direct, no magic) ----
def pawn_attacks_bb(c, s):
    attack = 0
    fwd = NORTH if c == WHITE else SOUTH
    to = s + fwd
    if is_ok(to) and dist_sq(s, to) == 1:
        attack |= square_bb(to)
    if (c == WHITE and rank_of(s) > 4) or (c == BLACK and rank_of(s) < 5):
        for sd in (WEST, EAST):
            to = s + sd
            if is_ok(to) and dist_sq(s, to) == 1:
                attack |= square_bb(to)
    return attack

def sliding_attack(pt, sq, occ):
    attack = 0
    for d in (NORTH, SOUTH, EAST, WEST):
        hurdle = False
        s = sq + d
        while is_ok(s) and dist_sq(s - d, s) == 1:
            if pt == ROOK or hurdle:
                attack |= square_bb(s)
            if (occ >> s) & 1:
                if pt == CANNON and not hurdle:
                    hurdle = True
                else:
                    break
            s += d
    return attack

def get_directions(pt):
    if pt == BISHOP:
        return [2 * NORTH_EAST, 2 * SOUTH_EAST, 2 * SOUTH_WEST, 2 * NORTH_WEST]
    return [2 * SOUTH + WEST, 2 * SOUTH + EAST, SOUTH + 2 * WEST, SOUTH + 2 * EAST,
            NORTH + 2 * WEST, NORTH + 2 * EAST, 2 * NORTH + WEST, 2 * NORTH + EAST]

def lame_leaper_path(pt, d, s):
    to = s + d
    if not is_ok(to) or dist_sq(s, to) > 3:
        return 0
    # KNIGHT_TO not used here
    dr = NORTH if d > 0 else SOUTH
    mod = d % NORTH  # C++ truncates toward zero
    amod = abs(mod)
    inner = mod if amod < (NORTH // 2) else -mod
    df = WEST if inner < 0 else EAST
    diff = abs(file_of(to) - file_of(s)) - abs(rank_of(to) - rank_of(s))
    if diff > 0:
        s += df
    elif diff < 0:
        s += dr
    else:
        s += df + dr
    return square_bb(s)

def lame_leaper_attack(pt, s, occ):
    b = 0
    for d in get_directions(pt):
        to = s + d
        if is_ok(to) and dist_sq(s, to) < 3 and not (lame_leaper_path(pt, d, s) & occ):
            b |= square_bb(to)
    if pt == BISHOP:
        b &= HalfBB[1 if rank_of(s) > 4 else 0]
    return b

def safe_destination(s, step):
    to = s + step
    return square_bb(to) if is_ok(to) and dist_sq(s, to) <= 2 else 0

# PseudoAttacks indexed by piece type (0..7) plus KING+3=10, ADVISOR+1=3? no: ADVISOR+1=3 overlaps CANNON.
# The C++ uses array size PIECE_TYPE_NB+3 = 11, indices: NO_PIECE_TYPE=0,PAWN=4,ROOK=1,ADVISOR=2,CANNON=3,
# KNIGHT=5,BISHOP=6,KING=7, and KING+3=10, ADVISOR+1=3? Wait ADVISOR+1=3==CANNON. That's a bug? No:
# In C++ ADVISOR+1 is index 3 which == CANNON index. But PseudoAttacks is size PIECE_TYPE_NB+3=11, and
# ADVISOR+1=3 would alias CANNON. Let me re-check: the code writes PseudoAttacks[KING+3] and PseudoAttacks[ADVISOR+1].
# KING+3=10, ADVISOR+1=3. Index 3 is CANNON. That aliasing would clobber CANNON with unconstrained advisor.
# But order matters: ADVISOR unconstrained is written AFTER CANNON's sliding? CANNON has no pseudo entry
# (cannon pseudo not set in init!). Actually CANNON pseudo isn't initialized -> stays 0. So index 3 (CANNON)
# is unused for pseudo, and ADVISOR+1=3 reuses it for unconstrained advisor. Clever. So:
#   PseudoAttacks[3] = unconstrained advisor (ADVISOR+1)
#   PseudoAttacks[10] = unconstrained king (KING+3)
PseudoAttacks = [[0] * SQUARE_NB for _ in range(11)]
for s in range(SQUARE_NB):
    PseudoAttacks[NO_PIECE_TYPE][s] = pawn_attacks_bb(WHITE, s)
    PseudoAttacks[PAWN][s] = pawn_attacks_bb(BLACK, s)
    PseudoAttacks[ROOK][s] = sliding_attack(ROOK, s, 0)
    PseudoAttacks[BISHOP][s] = lame_leaper_attack(BISHOP, s, 0)
    PseudoAttacks[KNIGHT][s] = lame_leaper_attack(KNIGHT, s, 0)
    for step in (NORTH, SOUTH, WEST, EAST):
        if Palace & square_bb(s):
            PseudoAttacks[KING][s] |= safe_destination(s, step) & Palace
        PseudoAttacks[KING + 3][s] |= safe_destination(s, step)  # unconstrained king
    for step in (NORTH_WEST, NORTH_EAST, SOUTH_WEST, SOUTH_EAST):
        if Palace & square_bb(s):
            PseudoAttacks[ADVISOR][s] |= safe_destination(s, step) & Palace
        PseudoAttacks[ADVISOR + 1][s] |= safe_destination(s, step)  # unconstrained advisor (index 3!)

def unconstrained_attacks_bb_king(s): return PseudoAttacks[KING + 3][s]
def pseudo(pt, s):
    # pt in {ROOK,ADVISOR,CANNON,PAWN,KNIGHT,BISHOP,KING}
    return PseudoAttacks[pt][s]

def attacks_bb_pt(pt, s, occ, c=WHITE):
    if pt == PAWN:
        return pawn_attacks_bb(c, s)
    if pt == ROOK: return sliding_attack(ROOK, s, occ)
    if pt == CANNON: return sliding_attack(CANNON, s, occ)
    if pt == BISHOP: return lame_leaper_attack(BISHOP, s, occ)
    if pt == KNIGHT: return lame_leaper_attack(KNIGHT, s, occ)
    return PseudoAttacks[pt][s]  # KING, ADVISOR

# ---- ValidBB (from half_ka_v2_hm.h literal) ----
# Indexed by Piece enum (0..15). Built from the bitboard expressions.
R0, R1, R2, R3, R4, R5, R6, R7, R8, R9 = [rank_bb(r) for r in range(10)]
ValidBB = [0] * 16
ValidBB[make_piece(WHITE, ROOK)] = HalfBB[WHITE] | HalfBB[BLACK]
ValidBB[make_piece(WHITE, ADVISOR)] = ((R0 | R2) & (FileDBB | FileFBB)) | (R1 & FileEBB)
ValidBB[make_piece(WHITE, CANNON)] = HalfBB[WHITE] | HalfBB[BLACK]
ValidBB[make_piece(WHITE, PAWN)] = PawnBB[WHITE]
ValidBB[make_piece(WHITE, KNIGHT)] = HalfBB[WHITE] | HalfBB[BLACK]
ValidBB[make_piece(WHITE, BISHOP)] = ((R0 | R4) & (FileCBB | FileGBB)) | (R2 & (FileABB | FileEBB | FileIBB))
ValidBB[make_piece(WHITE, KING)] = HalfBB[WHITE] & Palace & ~FileFBB
ValidBB[make_piece(BLACK, ROOK)] = HalfBB[WHITE] | HalfBB[BLACK]
ValidBB[make_piece(BLACK, ADVISOR)] = ((R7 | R9) & (FileDBB | FileFBB)) | (R8 & FileEBB)
ValidBB[make_piece(BLACK, CANNON)] = HalfBB[WHITE] | HalfBB[BLACK]
ValidBB[make_piece(BLACK, PAWN)] = PawnBB[BLACK]
ValidBB[make_piece(BLACK, KNIGHT)] = HalfBB[WHITE] | HalfBB[BLACK]
ValidBB[make_piece(BLACK, BISHOP)] = ((R5 | R9) & (FileCBB | FileGBB)) | (R7 & (FileABB | FileEBB | FileIBB))
ValidBB[make_piece(BLACK, KING)] = HalfBB[BLACK] & Palace

# ---- PSQOffsets ----
PSQOffsets = [[0xFFFF] * SQUARE_NB for _ in range(16)]
cumulative = 0
for pc in AllPieces:
    for s in range(SQUARE_NB):
        if ValidBB[pc] & square_bb(s):
            PSQOffsets[pc][s] = cumulative
            cumulative += 1
assert cumulative == 689, f"PSQOffsets count {cumulative} != 689"
print(f"PSQOffsets: {cumulative} valid (expect 689) OK")

# ---- ThreatOffsets (from full_threats.cpp) ----
ValidPairs = [
 [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],
 [0,1,1,1,1,1,1,1,0,1,1,1,1,1,1,0],
 [0,1,1,1,0,1,0,0,0,1,0,1,1,1,0,0],
 [0,1,1,1,1,1,1,1,0,1,1,1,1,1,1,0],
 [0,0,0,1,1,1,1,0,0,0,1,1,1,1,1,0],
 [0,1,1,1,1,1,1,1,0,1,1,1,1,1,1,0],
 [0,1,0,1,1,1,1,1,0,1,0,1,1,1,0,0],
 [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],
 [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],
 [0,1,1,1,1,1,1,0,0,1,1,1,1,1,1,1],
 [0,1,0,1,1,1,0,0,0,1,1,1,0,1,0,1],
 [0,1,1,1,1,1,1,0,0,1,1,1,1,1,1,1],
 [0,0,1,1,1,1,1,0,0,0,0,1,1,1,1,0],
 [0,1,1,1,1,1,1,0,0,1,1,1,1,1,1,1],
 [0,1,0,1,1,1,0,0,0,1,0,1,1,1,1,1],
 [0,0,0,1,1,1,0,0,0,0,1,1,0,1,1,0],
]
THREAT_DIM = 45547
ThreatOffsets = [[[[0xFFFF] * 16 for _ in range(90)] for _ in range(90)] for _ in range(16)]
cumulative = 0
for attacker in AllPieces:
    pt = type_of(attacker)
    for frm in range(SQUARE_NB):
        if not (ValidBB[attacker] & square_bb(frm)):
            continue
        if pt == PAWN:
            attacks = pawn_attacks_bb(color_of(attacker), frm)
        elif pt == CANNON:
            attacks = sliding_attack(CANNON, frm, unconstrained_attacks_bb_king(frm))
        else:
            attacks = PseudoAttacks[pt][frm]
        for attacked in AllPieces:
            if not ValidPairs[attacker][attacked]:
                continue
            targets = attacks & ValidBB[attacked]
            for to in bb_squares(targets):
                enemy = color_of(attacker) != color_of(attacked)
                same_file = file_of(frm) == file_of(to)
                same_rank = rank_of(frm) == rank_of(to)
                semi_excluded = (pt == type_of(attacked)
                                 and (pt != PAWN or (enemy and same_file) or (not enemy and same_rank))
                                 and pt != KNIGHT)
                if not semi_excluded or frm > to:
                    ThreatOffsets[attacker][frm][to][attacked] = cumulative
                    cumulative += 1
assert cumulative == THREAT_DIM, f"ThreatOffsets count {cumulative} != {THREAT_DIM}"
print(f"ThreatOffsets: {cumulative} valid (expect {THREAT_DIM}) OK")

# ---- export ----
def _export():
    os.makedirs(OUT, exist_ok=True)
    # valid_bb.bin: 16*90 u8 mask
    with open(os.path.join(OUT, "valid_bb.bin"), "wb") as f:
        for pc in range(16):
            for s in range(90):
                f.write(bytes([1 if ValidBB[pc] & square_bb(s) else 0]))
    # psq_offsets.bin: u16[16][90]
    with open(os.path.join(OUT, "psq_offsets.bin"), "wb") as f:
        for pc in range(16):
            for s in range(90):
                f.write(struct.pack("<H", PSQOffsets[pc][s]))
    # threat_offsets.bin: u16[16][90][90][16]
    with open(os.path.join(OUT, "threat_offsets.bin"), "wb") as f:
        for a in range(16):
            for frm in range(90):
                for to in range(90):
                    for atk in range(16):
                        f.write(struct.pack("<H", ThreatOffsets[a][frm][to][atk]))
    print("wrote valid_bb.bin, psq_offsets.bin, threat_offsets.bin")
    print(f"threat_offsets.bin size = {16*90*90*16*2} bytes")


if __name__ == "__main__":
    _export()
