#!/usr/bin/env python3
"""Pack parsed NNUE blobs for the GitHub Pages sidecar download (not the PCK)."""
from __future__ import annotations

import argparse
import hashlib
import json
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SKIP_NAMES = {".gdignore", "reference.json", "fens.txt"}


def pack(data_dir: Path, zip_path: Path, meta_path: Path) -> None:
    if not (data_dir / "manifest.json").is_file():
        raise SystemExit(f"missing {data_dir / 'manifest.json'}; run parse_nnue.py and gen_tables.py first")
    zip_path.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(zip_path, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        for path in sorted(data_dir.iterdir()):
            if not path.is_file() or path.name in SKIP_NAMES:
                continue
            if path.suffix not in {".bin", ".json"}:
                continue
            zf.write(path, arcname=path.name)
    digest = hashlib.sha256(zip_path.read_bytes()).hexdigest()
    meta = {
        "file": zip_path.name,
        "sha256": digest,
        "bytes": zip_path.stat().st_size,
    }
    meta_path.write_text(json.dumps(meta, indent=2) + "\n")
    print(f"wrote {zip_path} ({meta['bytes']} bytes, sha256={digest})")
    print(f"wrote {meta_path}")


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--data", type=Path, default=ROOT / "data")
    p.add_argument("--zip", type=Path, default=ROOT / "build/web/nnue-data.zip")
    p.add_argument("--meta", type=Path, default=ROOT / "build/web/nnue-pack.json")
    args = p.parse_args()
    pack(args.data, args.zip, args.meta)


if __name__ == "__main__":
    main()
