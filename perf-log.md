# godot-pikafish performance log

- Date: 2026-08-07 01:07:20
- Godot: 4.7.1-stable (official)
- CPU threads: 10
- Warmup / samples: 10 / 100
- Initialization: 177 ms
- Oracle correctness: 23/23 (tolerance <= 1)

## Synchronous batch end-to-end

| batch | p50 ms/batch | p95 ms/batch | p50 ms/eval | throughput eval/s |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 0.839 | 1.660 | 0.8390 | 1192 |
| 8 | 1.990 | 2.926 | 0.2487 | 4020 |
| 23 | 4.100 | 6.316 | 0.1783 | 5610 |
| 64 | 10.122 | 12.509 | 0.1582 | 6323 |
| 128 | 19.464 | 24.349 | 0.1521 | 6576 |
| 256 | 35.902 | 42.218 | 0.1402 | 7131 |
| 512 | 71.959 | 80.381 | 0.1405 | 7115 |

## 23-position timing decomposition

- features: 3.023 ms/batch
- conversion: 0.016 ms/batch
- upload: 0.008 ms/batch
- accumulator: 0.528 ms/batch
- forward: 0.509 ms/batch
- readback: 0.273 ms/batch

## Incremental search helper

- 1000 x do/evaluate/undo p50: 5.727 ms, p95: 8.016 ms

## Three-slot asynchronous pipeline

- 100 x 23 batches: 526.791 ms, 4366 eval/s
- callbacks ordered: true; mismatches: 0; backend: gpu

## Acceptance notes

- Consecutive 23-position p50 runs: 0.1526, 0.1673, 0.1783 ms/eval (all <= 0.20).
- Pre-optimization incremental history (`85b5121`): 8.166 ms p50; focused final run: 6.015 ms p50 (26.3% faster).
- iPad Air (5th generation), iPad13,16, iPadOS 18.7.0: Godot 4.6.1 Mobile renderer package built and ran with Xcode 16.4.
- Godot 4.6.x iOS compute failed the oracle, so the version-gated CPU fallback was used: sync 94 eval/s, async 93 eval/s, 100 x 23 batches on both paths, mismatches 0, callbacks ordered.
