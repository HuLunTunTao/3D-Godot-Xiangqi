# Pikafish addon smoke example

Minimal instructions for exercising `PikafishEngine` outside the full host tree.

## Preferred (in-repo)

```bash
/Applications/Godot/Godot_v4.7.1.app/Contents/MacOS/Godot --headless \
  --path /path/to/godot-pikafish -s res://tools/smoke_addon_headless.gd
```

Expect `SMOKE_PASS`.

## Isolated copy

```bash
bash tools/make_smoke_project.sh
```

That script copies `addons/pikafish`, `data/`, and (until NNUE is fully inside the
addon) host `src/nnue` + `src/shaders` into `/tmp/godot-pikafish-smoke-*`, then
runs the same headless smoke.

## Manual consumer project

1. Copy `addons/pikafish/` into your Godot 4.7 project.
2. Provide NNUE weights at `res://addons/pikafish/data/` (with `manifest.json`)
   or `res://data/`.
3. Enable the Pikafish editor plugin if you need export packing of `.bin` weights.
4. See `addons/pikafish/README.md` for `initialize` / `set_fen` / `legal_moves` /
   `start_search` / signals.
