# GDScript divergences from upstream Pikafish

Baseline upstream: `2c5c998c211d524d26c38e7e3e71d51bc24cbe64`  
Godot project baseline: `6399456c0041f793ea0bd88040f10ab7b58ab4cf`

Allowed categories: **SEMANTIC** · **PLATFORM** · **PERF**.  
Every entry needs a differential test and/or benchmark before it is accepted as lasting.

## Active ledger

| ID | Category | Area | Summary | Proof | Status |
|---|---|---|---|---|---|
| D001 | PLATFORM | addon layout | Phase E migrated NNUE + shaders into `addons/pikafish/nnue/` and `addons/pikafish/shaders/`. Runtime `PikafishEngine` preloads addon modules only. `res://src/nnue/*` remains as thin deprecated shims (`extends` addon / `XNnueEngine` wrapper) for existing tests. | `test_addon_shell.gd` + NNUE GUT | accepted (migrated) |
| D002 | PLATFORM | NNUE path | Loader accepts configurable `network_dir` (FileAccess / `res://` only). Defaults try `res://addons/pikafish/data` then `res://data`. No `globalize_path` / absolute host paths at runtime. | existing GUT oracle + addon init test | accepted |
| D003 | PLATFORM | iOS GPU shaders | Historical hard gate forced CPU on Godot 4.6.x + iOS before PCK weight packaging was fixed. Phase A removed the hard minor-version gate; `PikafishEngine` selects GPU only when canary passes. 2026-08-08 root cause: exported PCK remaps `*.glsl` to `RDShaderFile` SPIR-V; `FileAccess.get_as_text()` failed / no-op pipelines (GPU all-zero; canary correctly fell back to CPU). Fix: `_load_compute_shader` prefers `RDShaderFile.get_spirv()`, source-compile fallback for unpackaged desktop. Independent retest same day (iPad Air 5 / iPadOS 18.7.0 / Godot 4.6.1 Mobile): facade `backend=gpu`, canary `checked=5 bad=0`, forced GPU scalar+batch 23/23 (`diff=0`), sync 100×23 ~6314 eval/s `bad=0`, async 3-slot 100×23 ~3916 eval/s `bad=0` ordered; `shader_load_probe` confirms SPIR-V load + FileAccess open failure. Canary retained. GPU remains batch-inference only; search leaf NNUE stays CPU incremental. Harness: `src/test/run_mobile_gpu_probe.gd` + `tools/ios_gpu_probe_export.sh`. | `/tmp/godot-pikafish-ios-gpu-probe-verify-fresh.json`; Mac GUT 91 pass + 1 risky; `run_gpu_test` 23/23 | accepted (GPU via RDShaderFile load) |
| D004 | SEMANTIC | u128 Bitboard | C++ `Bitboard = u128` with square bit `1 << sq`. GDScript stores `(lo, hi)` signed int64 pairs; bit 63 is the sign bit of `lo`. `PackedByteArray[90]` remains the reference/conversion surface for NNUE occ and fixtures. Active representation: dual64 (`PikafishBitboard.ACTIVE_REP`). Cross-tested at sq 63/64; attack outputs match NNUE goldens + `fixtures/core/attacks_blockers.json`. | `test_addon_bitboard.gd` (9/9); `tools/bench_attack_rep.py` | accepted |
| D005 | PLATFORM | detect_chases rollback | C++ `memcpy` Position excluding `filter` for chase rollback. GDScript `clone_for_rollback()` deep-copies board/bitboards/SoA stack prefix and leaves bloom filter zeroed. Light `do_move`/`undo_move` used inside `chased` match upstream pair API. | `test_addon_rules.gd` perpetual-check claim | accepted |
| D006 | PERF | search leaf eval | C++ maintains incremental NNUE accumulators at every leaf. Addon now keeps a paired NNUE board/accumulator in `SearchWorker`, updating it together with each normal or null `Position` do/undo; `use_nnue_eval` remains opt-in and material remains the default. The full-refresh `evaluate_cb` is retained only as a caller fallback. Narrow NNUE parity covers four positions through depth 5, with FEN restoration asserted after every search; full corpus depth 8 is still intentionally out of scope for GDScript runtime. ProbCut/singular remain off by default. | `test_addon_search.gd`, `test_addon_search_fixtures.gd` NNUE narrow + smoke | accepted |
| D007 | PLATFORM | search thread | C++ multi-thread Workers share racy TT. Addon: one Godot `Thread`, Position clone by FEN, TT single-writer; results via `call_deferred`. `start_search` defaults to async; `sync:true` for GUT/tools. Per-iteration `search_info` deferred to main. History reused across searches. | `test_addon_search_time.gd` + `run_async_search_test.gd` | accepted |
| D008 | PERF | deep history memory | C++ `ContinuationHistory` ≈16 MiB i16 + `PawnHistory` (8192 buckets) ≈ shared DynStats. GDScript uses PackedInt32Array (~33 MiB cont + ~45 MiB pawn) lazy-allocated via `ensure_deep()` on first search; UnifiedCorrection ~0.5 MiB. Clear fills match upstream (-436 / -1247 / -6). Acceptable on M1 Pro; iPad peak budget still tracked under Phase I. | `test_addon_history_picker.gd` + `/tmp/check_hist.gd` sizes | accepted |
| D009 | PLATFORM | search clock | C++ `now()` steady TimePoint. GDScript `Time.get_ticks_msec()` monotonic ms. Soft stop finishes the current ID iteration; hard/movetime/nodes/stop abort ASAP and return last complete iteration (or legal fallback). Stop join p95 target ≤50ms after History reuse. Falling-eval / instability time scaling from upstream ID not fully ported (uses optimum as soft bound). | `test_addon_search_time.gd`, `bench_search_time.gd`, `run_async_search_test.gd` | accepted |

## Template for new entries

```text
### D0xx — TITLE
- Category:
- C++ behavior:
- GDScript replacement:
- Proof: test / benchmark before → after
- Decision: keep / revert
```

Code comments for accepted divergences:

```gdscript
# GDS-DIVERGENCE: PERF|SEMANTIC|PLATFORM
# C++ behavior: ...
# GDScript replacement: ...
# Proof: ...
```
