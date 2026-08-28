#!/usr/bin/env python3
"""Inject NNUE sidecar files into Godot's generated PWA service worker.

Godot 4.7 only lists files it exported. `nnue-pack.json` and `nnue-data.zip`
are packed afterwards by pack_web_nnue.py, so CI must patch the SW cache lists
or HTTPRequest will miss Cache Storage on a warm PWA.
"""
from __future__ import annotations

import argparse
import json
import re
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PRECACHES = ("nnue-pack.json",)
RUNTIME = ("nnue-data.zip",)
IS_CACHEABLE = re.compile(r"FULL_CACHE\.some\(\(v\)\s*=>\s*v\s*===\s*local\)")
IS_CACHEABLE_REPL = (
    "FULL_CACHE.some((v) => v === local || "
    "v === local.split('?')[0].split('#')[0].split('/').pop())"
)


def _const_array_re(name: str) -> re.Pattern[str]:
    return re.compile(rf"(const {re.escape(name)}\s*=\s*)(\[[^\]]*\])")


def inject_names(array_js: str, extras: tuple[str, ...]) -> str:
    arr = json.loads(array_js)
    if not isinstance(arr, list):
        raise ValueError("expected a JSON array")
    for name in extras:
        if name not in arr:
            arr.append(name)
    return json.dumps(arr, ensure_ascii=True, separators=(",", ":"))


def replace_const_array(text: str, const_name: str, extras: tuple[str, ...]) -> str:
    pattern = _const_array_re(const_name)
    match = pattern.search(text)
    if match is None:
        raise SystemExit(f"could not find {const_name} array in service worker")
    try:
        new_array = inject_names(match.group(2), extras)
    except (json.JSONDecodeError, ValueError) as exc:
        raise SystemExit(f"could not parse {const_name}: {exc}") from exc
    return text[: match.start(2)] + new_array + text[match.end(2) :]


def patch_is_cacheable(text: str) -> str:
    if IS_CACHEABLE_REPL in text:
        return text
    patched, n = IS_CACHEABLE.subn(IS_CACHEABLE_REPL, text, count=1)
    if n != 1:
        raise SystemExit(
            "could not patch FULL_CACHE.some(...) so sidecar HTTPRequest "
            "would not match Cache Storage"
        )
    return patched


def patch_service_worker_text(text: str) -> str:
    text = replace_const_array(text, "CACHED_FILES", PRECACHES)
    text = replace_const_array(text, "CACHEABLE_FILES", RUNTIME)
    text = patch_is_cacheable(text)
    for name in PRECACHES + RUNTIME:
        if name not in text:
            raise SystemExit(f"service worker still missing {name}")
    return text


def find_service_workers(web_dir: Path) -> list[Path]:
    found = sorted(web_dir.glob("*.service.worker.js"))
    if not found:
        found = sorted(web_dir.glob("*service-worker.js"))
    return found


def patch_web_dir(web_dir: Path) -> Path:
    if not web_dir.is_dir():
        raise SystemExit(f"missing web export dir {web_dir}")
    for name in PRECACHES + RUNTIME:
        path = web_dir / name
        if not path.is_file():
            raise SystemExit(f"missing sidecar {path}; pack_web_nnue.py must run first")
    workers = find_service_workers(web_dir)
    if not workers:
        raise SystemExit(
            f"no Godot service worker in {web_dir}; enable progressive_web_app "
            "on the Web preset"
        )
    patched_path = workers[0]
    original = patched_path.read_text(encoding="utf-8")
    patched_path.write_text(patch_service_worker_text(original), encoding="utf-8")
    print(f"patched {patched_path} with {', '.join(PRECACHES + RUNTIME)}")
    return patched_path


SAMPLE_SW = """\
const CACHED_FILES = ["index.html","index.js","index.offline.html","index.icon.png","index.apple-touch-icon.png","index.audio.worklet.js","index.audio.position.worklet.js"];
const CACHEABLE_FILES = ["index.wasm","index.pck"];
const FULL_CACHE = CACHED_FILES.concat(CACHEABLE_FILES);
const isCacheable = FULL_CACHE.some((v) => v === local) || (base === referrer && base.endsWith(CACHED_FILES[0]));
"""


def self_test() -> None:
    patched = patch_service_worker_text(SAMPLE_SW)
    cached = json.loads(re.search(r"const CACHED_FILES\s*=\s*(\[[^\]]*\])", patched).group(1))
    runtime = json.loads(re.search(r"const CACHEABLE_FILES\s*=\s*(\[[^\]]*\])", patched).group(1))
    assert "nnue-pack.json" in cached, cached
    assert "nnue-data.zip" in runtime, runtime
    assert "index.wasm" in runtime
    assert IS_CACHEABLE_REPL in patched
    again = patch_service_worker_text(patched)
    assert again == patched
    try:
        patch_service_worker_text("const CACHED_FILES = [];")
    except SystemExit:
        pass
    else:
        raise SystemExit("expected missing CACHEABLE_FILES to fail")
    with tempfile.TemporaryDirectory() as tmp:
        web_dir = Path(tmp)
        (web_dir / "nnue-pack.json").write_text("{}\n", encoding="utf-8")
        (web_dir / "nnue-data.zip").write_bytes(b"PK")
        try:
            patch_web_dir(web_dir)
        except SystemExit:
            pass
        else:
            raise SystemExit("expected missing service worker to fail")
        (web_dir / "index.service.worker.js").write_text(SAMPLE_SW, encoding="utf-8")
        patch_web_dir(web_dir)
        on_disk = (web_dir / "index.service.worker.js").read_text(encoding="utf-8")
        assert "nnue-pack.json" in on_disk
        assert "nnue-data.zip" in on_disk
    print("patch_web_service_worker self-test ok")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dir", type=Path, default=ROOT / "build/web")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return
    patch_web_dir(args.dir)


if __name__ == "__main__":
    main()
