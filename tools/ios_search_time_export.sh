#!/usr/bin/env bash
# Build Godot 4.6.1 iOS package for timed-search / stop acceptance.
# Machine-local helper (see AGENTS.md). Not part of runtime.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAMP="$(date +%Y%m%d_%H%M%S)"
TMP="/tmp/godot-pikafish-ios-search-${STAMP}"
GODOT461="/Applications/Godot/Godot_v4.6.1_mono.app/Contents/MacOS/Godot"
TEAM_ID="${IOS_TEAM_ID:-2X7TR627K2}"
BUNDLE_ID="${IOS_BUNDLE_ID:-com.hltt.godotpikafishbench461}"

if [[ ! -x "$GODOT461" ]]; then
  echo "missing Godot 4.6.1 mono at $GODOT461" >&2
  exit 1
fi

echo "Copying project -> $TMP"
rm -rf "$TMP"
mkdir -p "$TMP"
rsync -a --exclude '.git' --exclude '.godot' --exclude 'addons/gut' \
  --exclude 'addons/godot_test_bridge' \
  "$ROOT/" "$TMP/"

# 4.6.1 compatibility adjustments
python3 - <<'PY' "$TMP"
import pathlib, re, sys
root = pathlib.Path(sys.argv[1])
pg = (root / "project.godot").read_text()
pg = pg.replace('PackedStringArray("4.7", "Mobile")', 'PackedStringArray("4.6", "Mobile")')
pg = re.sub(r'(?m)^GodotTestBridge=.*\n', '', pg)
pg = re.sub(
    r'enabled=PackedStringArray\([^)]*\)',
    'enabled=PackedStringArray("res://addons/pikafish/plugin.cfg")',
    pg,
)
pg = re.sub(
    r'(?m)^config/name=.*$',
    'config/name="PikafishSearchTime"',
    pg,
)
# Main scene -> mobile gpu probe runner scene if present, else keep.
(root / "project.godot").write_text(pg)
# Drop data/.gdignore so weights pack.
ignore = root / "data" / ".gdignore"
if ignore.exists():
    ignore.unlink()
print("project.godot patched for 4.6.1")
PY

# Minimal main scene that runs the probe script
cat > "$TMP/src/test/mobile_search_time.tscn" <<'EOF'
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://src/test/run_mobile_search_time.gd" id="1"]

[node name="MobileSearchTime" type="Node"]
script = ExtResource("1")
EOF

python3 - <<'PY' "$TMP"
import pathlib, sys
root = pathlib.Path(sys.argv[1])
pg = (root / "project.godot").read_text()
if "run/main_scene" in pg:
    import re
    pg = re.sub(r'(?m)^run/main_scene=.*$', 'run/main_scene="res://src/test/mobile_search_time.tscn"', pg)
else:
    pg = pg.replace("[application]\n", "[application]\nrun/main_scene=\"res://src/test/mobile_search_time.tscn\"\n")
(root / "project.godot").write_text(pg)
PY

mkdir -p "$TMP/export"
EXPORT_CFG="$TMP/export_presets.cfg"
cat > "$EXPORT_CFG" <<EOF
[preset.0]

name="iOS"
platform="iOS"
runnable=true
advanced_options=false
dedicated_server=false
custom_features=""
export_filter="all_resources"
include_filter="data/*.bin,data/*.json,data/*.txt,fixtures/**/*.json"
exclude_filter=""
export_path="export/pikafish_search_time.ipa"
encryption_include_filters=""
encryption_exclude_filters=""
encrypt_pck=false
encrypt_directory=false
script_export_mode=2

[preset.0.options]

custom_template/debug=""
custom_template/release=""
architectures/arm64=true
application/app_store_team_id="$TEAM_ID"
application/bundle_identifier="$BUNDLE_ID"
application/export_method_debug=1
application/export_method_release=1
application/targeted_device_family=2
application/min_ios_version="15.0"
application/short_version="0.1.0"
application/version="0.1.0"
application/icon_interpolation=4
capabilities/access_wifi=false
capabilities/push_notifications=false
privacy/camera_usage_description=""
privacy/microphone_usage_description=""
privacy/photolibrary_usage_description=""
EOF

echo "Exporting Xcode project with Godot 4.6.1..."
"$GODOT461" --headless --path "$TMP" --export-debug "iOS" "$TMP/export/pikafish_search_time.xcodeproj" 2>&1 | tee "$TMP/export.log" || true

# Godot iOS export may emit .xcodeproj directory or .ipa depending on version; find it.
echo "TMP=$TMP"
find "$TMP/export" -maxdepth 3 -type d -name '*.xcodeproj' -o -name '*.ipa' -o -name 'project.pbxproj' 2>/dev/null | head -40
ls -lah "$TMP/export" || true
# PCK size hint from export log / data
du -sh "$TMP/data" || true
wc -c "$TMP"/export/*.pck 2>/dev/null || true
find "$TMP" -name '*.pck' 2>/dev/null | head
echo "DONE_TMP=$TMP"
