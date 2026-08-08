#!/usr/bin/env python3
"""Parse pikafish.nnue (zstd-compressed) and export GPU-ready binary blobs + manifest.

Layout (after zstd decompression), per Pikafish src/nnue/network.cpp + nnue_feature_transformer.h:
  header : u32 version(0x6A448AFA) u32 hash(0x40C70FA6) u32 descSize desc[descSize]
  u32 ftHash(0x23F47EB0)
  FT params:
    LEB128(i16 bias[1024])
    raw i8 threatW[45547*1024]
    LEB128(i32 threatPsqt[45547*16])
    raw i8 psqW[16536*1024]
    LEB128(i32 psqt[16536*16])
  16 x (u32 archHash + fc_0/fc_1/fc_2 params):
    fc_0: raw i32 bias[32] + raw i8 w[32*1024]
    fc_1: raw i32 bias[32] + raw i8 w[32*64]
    fc_2: raw i32 bias[1]  + raw i8 w[1*128]
  (ClippedReLU / SqrClippedReLU are parameter-free.)

All arrays are in natural/logical order in the file (any SIMD scrambling is storage-only),
so we read sequentially and use directly.
"""
import argparse
import json
import os
import struct
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_OUT = os.path.join(ROOT, "data")

# Architecture constants (from nnue_architecture.h / nnue_common.h / features)
VERSION = 0x6A448AFA
L1 = 1024
FC0 = 32
FC1 = 32
PSQTBUCKETS = 16
LAYERSTACKS = 16
PSQ_DIM = 6 * 4 * 689          # 16536
THREAT_DIM = 45547
INPUT_DIM = PSQ_DIM + THREAT_DIM  # 62083

LEB_MAGIC = b"COMPRESSED_LEB128"


def decompress(path):
    p = subprocess.run(["zstd", "-d", "-c", path], capture_output=True, check=True)
    return p.stdout


class Reader:
    def __init__(self, data):
        self.d = data
        self.o = 0

    def take(self, n):
        b = self.d[self.o:self.o + n]
        if len(b) != n:
            raise EOFError(f"wanted {n} at {self.o}, got {len(b)}")
        self.o += n
        return b

    def u32(self):
        return struct.unpack("<I", self.take(4))[0]

    def i32(self):
        return struct.unpack("<i", self.take(4))[0]

    def raw_i8(self, count):
        # signed bytes, returned as bytes object (length count)
        return self.take(count)

    def raw_i32_array(self, count):
        return self.take(4 * count)  # little-endian i32 bytes

    def leb128(self, count):
        # signed LEB128: magic + u32 bytecount + bytes
        magic = self.take(len(LEB_MAGIC))
        assert magic == LEB_MAGIC, f"bad leb magic at {self.o}: {magic!r}"
        bytes_left = self.u32()
        out = []
        result = 0
        shift = 0
        consumed = 0
        buf = self.d
        while len(out) < count:
            assert bytes_left > 0, "leb128 underflow"
            byte = buf[self.o]
            self.o += 1
            bytes_left -= 1
            consumed += 1
            result |= (byte & 0x7f) << (shift % 32)
            shift += 7
            if (byte & 0x80) == 0:
                if shift >= 32 or (byte & 0x40) == 0:
                    val = result
                else:
                    val = result | ~((1 << shift) - 1)
                out.append(val)
                result = 0
                shift = 0
        assert bytes_left == 0, f"leb128 leftover {bytes_left}"
        return out


def write_blob(out_dir, name, data):
    p = os.path.join(out_dir, name)
    with open(p, "wb") as f:
        f.write(data)
    print(f"  {name}: {len(data)} bytes")
    return len(data)


def parse_args():
    p = argparse.ArgumentParser(description="Parse pikafish.nnue into GPU-ready binary blobs.")
    p.add_argument("src", help="Path to pikafish.nnue (zstd-compressed network file)")
    p.add_argument(
        "-o", "--out",
        default=DEFAULT_OUT,
        help=f"Output directory for weight blobs (default: {DEFAULT_OUT})",
    )
    return p.parse_args()


def main():
    args = parse_args()
    src = os.path.abspath(args.src)
    out_dir = os.path.abspath(args.out)
    if not os.path.isfile(src):
        print(f"error: network file not found: {src}", file=sys.stderr)
        sys.exit(1)

    os.makedirs(out_dir, exist_ok=True)
    print(f"Decompressing {src} ...")
    data = decompress(src)
    print(f"  decompressed: {len(data)} bytes")
    assert len(data) == 66082730, f"unexpected size {len(data)}"

    r = Reader(data)
    ver = r.u32()
    assert ver == VERSION, f"bad version 0x{ver:08X}"
    nethash = r.u32()
    descsize = r.u32()
    desc = r.take(descsize).decode("utf-8", "replace")
    print(f"  version=0x{ver:08X} hash=0x{nethash:08X} desc={desc[:60]!r}")

    fthash = r.u32()
    print(f"  ftHash=0x{fthash:08X}")

    manifest = {
        "version": f"0x{ver:08X}",
        "network_hash": f"0x{nethash:08X}",
        "ft_hash": f"0x{fthash:08X}",
        "description": desc,
        "dims": {"L1": L1, "FC0": FC0, "FC1": FC1, "PSQTBuckets": PSQTBUCKETS,
                 "LayerStacks": LAYERSTACKS, "PSQ_DIM": PSQ_DIM, "THREAT_DIM": THREAT_DIM,
                 "INPUT_DIM": INPUT_DIM},
        "files": {},
    }

    print("Feature transformer:")
    # biases i16[1024] LEB128
    bias = r.leb128(L1)
    assert all(-32768 <= v <= 32767 for v in bias)
    b = b"".join(struct.pack("<h", v) for v in bias)
    manifest["files"]["ft_bias"] = {"name": "ft_bias.bin", "dtype": "i16", "count": L1}
    write_blob(out_dir, "ft_bias.bin", b)

    # threatW raw i8 [THREAT_DIM * L1]
    tw = r.raw_i8(THREAT_DIM * L1)
    manifest["files"]["ft_threatW"] = {"name": "ft_threatW.bin", "dtype": "i8",
                                       "count": THREAT_DIM * L1, "layout": "[threat][i]"}
    write_blob(out_dir, "ft_threatW.bin", tw)

    # threatPsqt i32[THREAT_DIM * PSQTBuckets] LEB128
    tpsqt = r.leb128(THREAT_DIM * PSQTBUCKETS)
    b = b"".join(struct.pack("<i", v) for v in tpsqt)
    manifest["files"]["ft_threatPsqt"] = {"name": "ft_threatPsqt.bin", "dtype": "i32",
                                          "count": THREAT_DIM * PSQTBUCKETS, "layout": "[threat][bucket]"}
    write_blob(out_dir, "ft_threatPsqt.bin", b)

    # psqW raw i8 [PSQ_DIM * L1]
    pw = r.raw_i8(PSQ_DIM * L1)
    manifest["files"]["ft_psqW"] = {"name": "ft_psqW.bin", "dtype": "i8", "count": PSQ_DIM * L1,
                                    "layout": "[feat][i]"}
    write_blob(out_dir, "ft_psqW.bin", pw)

    # psqt i32[PSQ_DIM * PSQTBuckets] LEB128
    psqt = r.leb128(PSQ_DIM * PSQTBUCKETS)
    b = b"".join(struct.pack("<i", v) for v in psqt)
    manifest["files"]["ft_psqt"] = {"name": "ft_psqt.bin", "dtype": "i32", "count": PSQ_DIM * PSQTBUCKETS,
                                    "layout": "[feat][bucket]"}
    write_blob(out_dir, "ft_psqt.bin", b)

    print("16 network layer stacks:")
    stacks = []
    for s in range(LAYERSTACKS):
        ah = r.u32()
        # fc_0
        fc0_bias = r.raw_i32_array(FC0)
        fc0_w = r.raw_i8(FC0 * L1)
        # fc_1
        fc1_bias = r.raw_i32_array(FC1)
        fc1_w = r.raw_i8(FC1 * (FC0 * 2))
        # fc_2
        fc2_bias = r.raw_i32_array(1)
        fc2_w = r.raw_i8(1 * (FC0 * 2 + FC1 * 2))
        prefix = f"stack{s:02d}"
        write_blob(out_dir, f"{prefix}_fc0_bias.bin", fc0_bias)
        write_blob(out_dir, f"{prefix}_fc0_w.bin", fc0_w)
        write_blob(out_dir, f"{prefix}_fc1_bias.bin", fc1_bias)
        write_blob(out_dir, f"{prefix}_fc1_w.bin", fc1_w)
        write_blob(out_dir, f"{prefix}_fc2_bias.bin", fc2_bias)
        write_blob(out_dir, f"{prefix}_fc2_w.bin", fc2_w)
        stacks.append({"arch_hash": f"0x{ah:08X}", "prefix": prefix,
                       "files": {
                           "fc0_bias": f"{prefix}_fc0_bias.bin", "fc0_w": f"{prefix}_fc0_w.bin",
                           "fc1_bias": f"{prefix}_fc1_bias.bin", "fc1_w": f"{prefix}_fc1_w.bin",
                           "fc2_bias": f"{prefix}_fc2_bias.bin", "fc2_w": f"{prefix}_fc2_w.bin",
                       }})
    manifest["stacks"] = stacks

    # must have consumed everything
    print(f"  consumed {r.o} / {len(data)} bytes")
    assert r.o == len(data), f"trailing {len(data) - r.o} bytes"

    with open(os.path.join(out_dir, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=2)
    print(f"wrote {out_dir}/manifest.json")
    print("OK")


if __name__ == "__main__":
    main()
