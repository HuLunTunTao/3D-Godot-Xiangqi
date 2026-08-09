# Pikafish Godot Addon

Pure GDScript + Godot compute-shader Chinese chess engine for Godot Mobile.
No board UI, rendering, networking, or save system — engine API only.

**Minimum Godot:** 4.7.x (Mobile renderer recommended). Desktop development uses
Godot 4.7.1. iOS device packages on some machines may still use matching 4.6.1
templates; see the host repo `AGENTS.md`. Backend selection uses a CPU/GPU
canary, not a hard-coded minor-version gate.

## Status

- Public `PikafishEngine` facade API is frozen.
- NNUE evaluate / batch / async / incremental live under `addons/pikafish/nnue/`
  with compute shaders in `addons/pikafish/shaders/` (Phase E migration).
- Position, movegen, rules, and search are in `addons/pikafish/core/` + `search/`.
- Default weights: `res://addons/pikafish/data` if `manifest.json` exists, else
  `res://data` (D002).

## Public API

| Symbol | Path |
|---|---|
| `PikafishEngine` | `res://addons/pikafish/pikafish.gd` |
| `PikafishConfig` | `res://addons/pikafish/config.gd` |
| `PikafishSearchLimits` | `res://addons/pikafish/search/limits.gd` |

### `initialize` / `shutdown`

```gdscript
var engine := PikafishEngine.new()
var cfg := PikafishConfig.new()
# cfg.network_dir = "res://addons/pikafish/data"  # optional override
# Default: addon data if manifest.json exists, else res://data
assert(engine.initialize(cfg) == OK)
print(engine.backend_info())  # backend, canary, network_dir, …
engine.shutdown()
```

### `set_fen` / `legal_moves`

```gdscript
const START := "rnbakabnr/9/1c5c1/p1p1p1p1p/9/9/P1P1P1P1P/1C5C1/9/RNBAKABNR w - - 0 1"
assert(engine.set_fen(START) == OK)
var moves: PackedInt32Array = engine.legal_moves()  # startpos → 44
print(engine.move_to_uci(moves[0]))
```

Also available: `get_fen()`, `push_move` / `pop_move`, `is_legal`,
`move_from_uci` / `move_to_uci`, `in_check`, `game_result`, `perft`,
`evaluate_static` / `evaluate_batch`.

### Game UI state and move history

Use the facade rather than parsing FEN or accessing `core/position.gd` from a game.
Every accepted position change increments `position_revision()` and emits one
`position_changed(snapshot, move_info)` signal. A search result is emitted only when
its revision still matches the current position, so a late worker result cannot play
on a replacement board.

```gdscript
engine.position_changed.connect(func(view, move):
	# `move` is null after set_fen/new_game, otherwise PikafishMoveInfo.
	redraw_board(view.pieces, view.side_to_move)
)

assert(engine.new_game() == OK)
var square := engine.square_from_file_rank(0, 3) # a3
var candidates := engine.legal_moves_from(square)
assert(engine.push_move(candidates[0]) == OK)

assert(engine.can_undo())
engine.pop_move()
assert(engine.can_redo())
engine.redo_move()
```

`get_position_view()` returns a `PikafishPositionView` with `revision`, `fen`,
90-square `pieces`, `side_to_move`, `in_check`, `result`, and `ply`. Treat it as
read-only. `piece_at(square)`, `file_of(square)`, `rank_of(square)`, and
`square_from_file_rank(file, rank)` avoid leaking board encoding into UI code.

`PikafishMoveInfo` records `kind` (`move`/`undo`/`redo`), packed `move`, source and
target squares, moving/captured pieces, UCI text, check flag, and resulting revision.
`move_history()` and `last_move_info()` return copies suitable for a move list.
`push_uci("a3a4")` is provided for persistence and network adapters.
`set_position(fen, moves)` validates the complete supplied move list before replacing
the live position; it emits one snapshot event and starts a new undo history.

### `start_search` (async by default) / `stop_search`

Recommended game-layer call — **async**, time budget, no main-thread block:

```gdscript
engine.best_move_found.connect(func(result):
	# Delivered on the main thread after a complete ID iteration (or legal fallback).
	print(engine.move_to_uci(result.bestmove), result.score, result.completed_depth)
	print(result.from_complete_iteration, result.stop_reason, result.elapsed_ms)
)
engine.search_info.connect(func(info):
	# One emission per completed iterative-deepening step (+ a final summary).
	print("depth", info.depth, "nodes", info.nodes, "final", info.is_final)
)
engine.start_search({"movetime_ms": 1200})
# Also: wtime/btime/winc/binc/movestogo, depth, nodes, infinite, ponder
# Abort (idempotent; joins worker; p95 stop wait target ≤50ms on device):
engine.stop_search()
```

`result.score` / `search_info.score` 是引擎内部 `Value`（与上游搜索一致）。
官方 UCI 的 `score cp` 还要再经 `UCIEngine::to_cp(Value, pos)`（见
`addons/pikafish/core/uci_score.gd`）；二者单位不同，差分时勿直接判等。

Dictionary and `PikafishSearchLimits` both accept: `movetime_ms` (or `movetime`),
`wtime`/`btime`, `winc`/`binc`, `movestogo`, `depth`, `nodes`, `infinite`,
`ponder`, `sync`.

- **Default is async** (background `Thread`; signals via `call_deferred` on main).
- Pass `sync: true` only for GUT / smoke / tools that must block.
- Soft time (`optimum` / movetime): finish the current ID iteration, then stop.
- Hard time / nodes / `stop_search`: abort ASAP; result is the **last complete
  iteration** PV. If depth 1 never finished, a legal fallback move is returned
  with `incomplete=true` / `from_complete_iteration=false`.

```gdscript
# Tests / tools only:
engine.start_search({"depth": 4, "sync": true})
```

### Signals

| Signal | Payload | When |
|---|---|---|
| `search_info(info)` | `PikafishSearchInfo` | Each completed ID iteration (`is_final=false`) and once with the final summary (`is_final=true`); clock search includes `soft_time_ms` / `hard_time_ms` |
| `best_move_found(result)` | `PikafishSearchResult` | Once per search: `bestmove`, `score`, `nodes`, `completed_depth`, `evaluation_mode`, `soft_time_ms`, `hard_time_ms`, `stop_reason`, `from_complete_iteration`, … |
| `backend_changed(name, reason)` | `String`, `String` | GPU/CPU selection or fallback |
| `position_changed(snapshot, move_info)` | `PikafishPositionView`, `PikafishMoveInfo?` | Every accepted `set_fen`, new game, move, undo, or redo |

**Search leaf eval:** default is CPU incremental NNUE, matching the upstream normal
path. Set `PikafishConfig.evaluation_mode = PikafishConfig.EVALUATION_MATERIAL` only
for diagnostics or constrained benchmarks. `use_nnue_eval` remains a compatibility
switch when `evaluation_mode` is empty. GPU is used for public `evaluate_batch` /
async batch only — not for alpha-beta leaves (do not treat batch eval/s as search
speedup).

**对局时钟：**推荐传入 `wtime`、`btime`、`winc`、`binc` 与可选 `movestogo`，而不是
固定深度。搜索每完成一层会更新 `soft_time_ms`，评分下跌或最佳着不稳定时会延长思考；
`hard_time_ms` 始终是不可越过的上限。`move_overhead_ms`（默认 10）应包含 UI 动画或
通信延迟。

## Data packing (export)

Weights must be readable via `res://…` + `FileAccess` (PCK-safe). Do **not** use
`ProjectSettings.globalize_path()` or absolute host paths at runtime.

Default resolve order (`PikafishConfig.resolve_network_dir`):

1. `cfg.network_dir` if set
2. `res://addons/pikafish/data` when `manifest.json` exists
3. else `res://data`

Host `data/.gdignore` can omit weights from default Godot export. For device
packages:

1. Prefer shipping weights under `addons/pikafish/data/` (self-contained), **or**
   keep them at project `res://data/`.
2. Remove `data/.gdignore` in the export copy / temp project.
3. Set an include filter, for example:

```ini
include_filter="data/*.bin,data/*.json,data/*.txt,addons/pikafish/data/*.bin,addons/pikafish/data/*.json,addons/pikafish/data/*.txt"
```

4. Optionally enable this addon’s editor plugin so `tools/export_plugin.gd`
   force-packs `res://addons/pikafish/data/*.{bin,json,txt}`.

A correct full PCK is on the order of tens of MiB (weights dominate). A ~1–2 MiB
PCK or empty oracle arrays usually means weights were not packed.

Generate host `data/` with the repo `tools/parse_nnue.py`, `gen_tables.py`, and
`gen_reference.py` (see root README / `AGENTS.md`).

## Smoke check

From the host project (Godot 4.7.1):

```bash
/Applications/Godot/Godot_v4.7.1.app/Contents/MacOS/Godot --headless \
  --path . -s res://tools/smoke_addon_headless.gd
```

Expect `SMOKE_PASS`. Optional isolated copy:

```bash
bash tools/make_smoke_project.sh
```

Async runners (non-zero exit on failure):

```bash
# GPU/CPU async batch (loads async_test.tscn; do not `-s` the Node script)
Godot --path . -s res://src/test/run_async_test_cli.gd
# Search time-budget / stop stress
Godot --headless --path . -s res://src/test/run_async_search_test.gd
```

See also `examples/smoke_addon/README.md`.

## Licenses

- Engine source: GNU GPL v3 — `LICENSES/GPL-3.0.txt` (repo `Copying.txt`)
- NNUE weight database / training data lineage: ODbL — `LICENSES/ODbL-NNUE.txt`

Distributing the addon or a derivative requires GPL v3 source offer for the
engine code, and ODbL compliance when redistributing the weight database.
