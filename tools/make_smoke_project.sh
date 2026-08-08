#!/usr/bin/env bash
# Build an isolated smoke project under /tmp and run the Phase J headless smoke.
# Until NNUE is fully self-contained in the addon, also copies host src/nnue +
# src/shaders so PikafishEngine can initialize (bridge for concurrent Phase E).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${SMOKE_DEST:-/tmp/godot-pikafish-smoke-$$}"
GODOT="${GODOT:-/Applications/Godot/Godot_v4.7.1.app/Contents/MacOS/Godot}"

if [[ ! -x "$GODOT" ]]; then
  echo "Godot not found at $GODOT (set GODOT=...)" >&2
  exit 1
fi

if [[ ! -f "$ROOT/data/manifest.json" ]]; then
  echo "Missing $ROOT/data/manifest.json — generate weights first (see AGENTS.md)." >&2
  exit 1
fi

rm -rf "$DEST"
mkdir -p "$DEST"

# Minimal Godot 4.7 project
cat > "$DEST/project.godot" <<'EOF'
; Engine configuration file.
config_version=5

[application]
config/name="Pikafish Addon Smoke"
config/features=PackedStringArray("4.7", "Mobile")
run/main_scene=""

[rendering]
renderer/rendering_method="mobile"
EOF

mkdir -p "$DEST/addons" "$DEST/src" "$DEST/tools" "$DEST/examples/smoke_addon"
cp -R "$ROOT/addons/pikafish" "$DEST/addons/"
# Weights: host data/ is authoritative; also mirror under addon data for resolve order.
mkdir -p "$DEST/data" "$DEST/addons/pikafish/data"
# Prefer rsync when available; fall back to cp -R (skip .gdignore for packing realism).
if command -v rsync >/dev/null 2>&1; then
  rsync -a --exclude='.gdignore' "$ROOT/data/" "$DEST/data/"
  rsync -a --exclude='.gdignore' "$ROOT/data/" "$DEST/addons/pikafish/data/"
else
  cp -R "$ROOT/data/." "$DEST/data/"
  rm -f "$DEST/data/.gdignore"
  cp -R "$ROOT/data/." "$DEST/addons/pikafish/data/"
  rm -f "$DEST/addons/pikafish/data/.gdignore"
fi

# Temporary host bridges:
# - fixtures/core (zobrist keys required by Position/search)
# - src/nnue thin shims if still present (Phase E may remove them)
if [[ -d "$ROOT/fixtures" ]]; then
  cp -R "$ROOT/fixtures" "$DEST/"
fi
if [[ -d "$ROOT/src/nnue" ]]; then
  cp -R "$ROOT/src/nnue" "$DEST/src/"
fi
# Shaders now live under the addon; keep host copy only if present.
if [[ -d "$ROOT/src/shaders" ]]; then
  cp -R "$ROOT/src/shaders" "$DEST/src/"
fi
cp "$ROOT/tools/smoke_addon_headless.gd" "$DEST/tools/"
if [[ -f "$ROOT/examples/smoke_addon/README.md" ]]; then
  cp "$ROOT/examples/smoke_addon/README.md" "$DEST/examples/smoke_addon/"
fi

echo "Smoke project at $DEST"
"$GODOT" --headless --path "$DEST" -s res://tools/smoke_addon_headless.gd
echo "make_smoke_project: done (exit $?)"
