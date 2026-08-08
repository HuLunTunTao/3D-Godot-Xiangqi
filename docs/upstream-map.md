# Upstream map — Pikafish → godot-pikafish addon

Frozen baselines (do not silently advance):

| Tree | Path | SHA | Verified (Phase A) |
|---|---|---|---|
| Godot project | `/Users/hltt/projects/download/pikafish/godot-pikafish` | `6399456c0041f793ea0bd88040f10ab7b58ab4cf` | `git rev-parse HEAD` matches (dirty worktree = Phase A files only) |
| Upstream Pikafish | `/Users/hltt/projects/download/pikafish/Pikafish` | `2c5c998c211d524d26c38e7e3e71d51bc24cbe64` (2026-08-03) | `git rev-parse HEAD` exact match |

Status legend: `todo` · `stub` · `partial` · `done` · `n/a`

## File / module mapping

| Pikafish C++ | Addon GDScript | Status | Notes |
|---|---|---|---|
| `types.h` | `addons/pikafish/core/types.gd` | done | Value/Depth/Piece/Square/Move helpers |
| `bitboard.h/cpp`, `magics.h` | `addons/pikafish/core/bitboard.gd` | partial | dual64 `(lo,hi)` u128; magic tables still unused (formulas) |
| `attacks.h/cpp` | `addons/pikafish/core/attacks.gd` | partial | Formula attacks + Between/Line/RayPass; magics TBD |
| `position.h/cpp` | `addons/pikafish/core/position.gd` | partial | FEN/do/undo/legal/SEE; `need_full_check` uses empty-board rook rays (upstream `PseudoAttacks[ROOK]`) |
| `position` state | `addons/pikafish/core/state_stack.gd` | partial | MAX_PLY SoA |
| `position` rules | `addons/pikafish/core/rules.gd` | partial | rule_judge / detect_chases / chased / chase_legal |
| `movegen.h/cpp` | `addons/pikafish/core/movegen.gd` | partial | Five GenTypes; perft corpus depth 1–4 hard match, plus eligible fast depth-5 cases (incl. `ref3_complex_b`=31825) |
| Zobrist (in position) | `addons/pikafish/core/zobrist.gd` | done | hex fixture, PRNG seed 1070372 |
| `evaluate.*`, `nnue/*` | `addons/pikafish/nnue/*`, `addons/pikafish/shaders/` | done | addon authoritative; `src/` only retains tests |
| `tt.*` | `addons/pikafish/search/tt.gd` | partial | SoA ClusterSize=3 |
| `history.h` | `addons/pikafish/search/history.gd` | done | Butterfly/LowPly/Capture/PieceTo/Correction + Continuation[2][2]/PawnHistory/UnifiedCorrection (lazy PackedArray); gravity |
| `movepick.*` | `addons/pikafish/search/move_picker.gd` | done | Main/evasion/qsearch/probcut stages; SEE good/bad; skip_quiet; quiet score: threat/check/pawn/cont[0..3,5] |
| `search.*` | `addons/pikafish/search/search_worker.gd`, `reductions.gd` | partial | PVS + ID + qsearch; contHist stack + update_quiet continuation/pawn; ProbCut/singular flags default off; CPU incremental NNUE leaf default (D006). Narrow NNUE soft parity: startpos+3 FENs depth 1–5 |
| `timeman.*` | `addons/pikafish/search/time_manager.gd`, `time_state.gd` | partial | movetime hard cap; clock/inc/movestogo optimum–maximum; Move Overhead; ponder +25% optimum; node limit; after-ID falling-eval / best-move stability / root-effort / instability soft-target multiplier. RootMove EMA remains a compact-score proxy. |
| `thread.*` | facade + one Thread | done | `start_search` async by default; `sync:true` for tests; per-iteration `search_info` + single `best_move_found` on main thread; reusable History |
| `uci.*` | optional later | n/a | Core API is not text-protocol |

## Function-level tracking (seed)

| Upstream | Target | Status |
|---|---|---|
| `Move` encoding `(from<<7)\|to`, none=0, null=129 | `core/types.gd` | done |
| `square_bb` / file/rank/palace / popcount/lsb | `core/bitboard.gd` | done (dual64) |
| `sliding_attack` / `lame_leaper_*` / `attacks_bb` | `core/attacks.gd` | done (formulas) |
| `LineBB` / `BetweenBB` / `RayPassBB` / `LeaperPassBB` | `core/attacks.gd` | done |
| `Position::set` / `fen` | `core/position.gd` | done |
| `Position::legal` / `pseudo_legal` / `gives_check` | `core/position.gd` | partial (`gives_check` approximate; `need_full_check` aligned with upstream empty rook rays) |
| `Position::see_ge` | `core/position.gd` | done |
| `Position::do_move` / `undo_move` / null | `core/position.gd`, `state_stack.gd` | partial |
| `Position::rule_judge` / `detect_chases` / `chased` / `chase_legal` | `core/rules.gd` | partial |
| `generate<CAPTURES/QUIETS/EVASIONS/PSEUDO_LEGAL/LEGAL>` | `core/movegen.gd` | partial |
| `Benchmark::perft` | facade `perft()` | done (via movegen) |
| NNUE evaluate / batch / incremental | `addons/pikafish/nnue/*` via `PikafishEngine` | done (Phase E) |
| `TranspositionTable` | `search/tt.gd` | partial |
| `StatsEntry::operator<<` gravity | `search/history.gd` `gravity()` | done |
| `ButterflyHistory` / `LowPlyHistory` / `CapturePieceToHistory` / `PieceToHistory` / `CorrectionHistory<PieceTo>` | `search/history.gd` | done |
| `ContinuationHistory` / `PawnHistory` / `SharedHistories` / `UnifiedCorrectionHistory` | `search/history.gd` | done | Lazy SoA; SharedHistories single-thread size; UnifiedCorrection allocated (eval wiring still partial) |
| `MovePicker` stages + `next_move` / `skip_quiet_moves` | `search/move_picker.gd` | done |
| `MovePicker::score` threat / check / pawn / contHist[1..5] | `search/move_picker.gd` | done | cont indices 0,1,2,3,5 as upstream |
| Killers (removed upstream; history replaces) | n/a | n/a |
| `TimeManagement` | `search/time_manager.gd` | done | movetime + clock TM; soft/hard used by SearchWorker ID loop |
| `Search::Worker` iterative deepening / PVS / qsearch | `search/search_worker.gd` | partial | Complete-iteration commit; legal fallback if depth 1 incomplete; info_cb per ID step |
| `Search::Worker::reduction` + reductions[] | `search/reductions.gd` | partial |

## Fixture corpus

| Fixture | Generator | Upstream SHA embedded | Status |
|---|---|---|---|
| `fixtures/core/startpos.json` | `tools/gen_core_fixtures.py` | yes | Phase A minimal (fen, keys, movegen lists, perft 1–5) |
| `fixtures/core/attacks_blockers.json` | `tools/gen_attack_fixtures.py` | yes | Phase B generic blocker attack cases (72) |
| `fixtures/search/depth_corpus.json` | `tools/gen_search_fixtures.py` | yes | Plan §G: startpos + ~10 FENs, depth 1..N bestmove/score/root_moves/unique. Default NNUE GUT remains soft outside its narrow depth≤5 subset |
| `fixtures/search/node_corpus.json` | `tools/gen_search_node_fixtures.py` + `src/test/diff_search_nodes.gd` | yes | locked upstream `go nodes` baseline; 4 FEN × 256/1024, reports legal/move/score/PV/depth/node deltas without conflating current search gaps with fixture validity |
| `fixtures/core/perft_corpus.json` | `tools/gen_search_fixtures.py` | yes | Expanded perft; depth 1–4 hard match plus eligible fast depth-5 cases after `need_full_check` empty-ray fix |
| `fixtures/core/playouts.json` | `tools/gen_playout_fixtures.py` | yes | ≥1000 random legal playout steps (move lists) |

Update this table as each Phase B–J port lands. Every ported function comment must cite:

```gdscript
# Upstream: Pikafish 2c5c998c, src/<file>, <symbol>
```

## Phase J — addon 收口 (docs / smoke / deprecation)

| Item | Status | Notes |
|---|---|---|
| `addons/pikafish/README.md` public API | done | init, set_fen, legal_moves, start_search sync/async, stop, signals, Godot min, GPL/ODbL, data packing |
| `tools/smoke_addon_headless.gd` | done | `--path . -s …` → `SMOKE_PASS` |
| `tools/make_smoke_project.sh` + `examples/smoke_addon/` | done | copies addon+data (+ host NNUE bridge until Phase E) to `/tmp` |
| Root README pointer | done | points to addon README |
| Self-contained addon (no runtime `src/` dependency) | done (Phase E) | Facade and tests preload `addons/pikafish/nnue/*` + shaders directly |
| iPad GPU 23/23 retest | blocked (device) | not part of desktop Phase J; see D003 |
| Isolated `/tmp` smoke needs `fixtures/core` | done | `make_smoke_project.sh` copies fixtures for zobrist |
