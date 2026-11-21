#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
output_dir="${BUILD_DIR:-build}"
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
stage=$(mktemp -d "$output_dir/.tricolor.XXXXXX")
trap 'rm -rf "$stage"' EXIT
app="$stage/三色桌宠.app"
content="$app/Contents"
mkdir -p "$content/MacOS" "$content/Resources"
cp Info.plist "$content/Info.plist"
clang -arch x86_64 -arch arm64 -mmacosx-version-min=12.0 -fobjc-arc -O2 -Wall \
    -framework Cocoa -framework CoreGraphics -framework ImageIO -lz Cat.m PetFrameAtlas.m PetGazeMap.m -o "$content/MacOS/TriColorPet"
for role in blue amber frost; do
    mkdir "$content/Resources/$role"
    cp "windows/packed/$role/atlas.png" "windows/packed/$role/frames.z" "$content/Resources/$role/"
done
mkdir "$content/Resources/gaze"
cp windows/gaze/{blue,amber,frost}.gaze "$content/Resources/gaze/"
cp windows/assets/{0,1,2}.wav "$content/Resources/"
"$content/MacOS/TriColorPet" --check
codesign --force --sign - "$app"
codesign --verify --strict --all-architectures "$app"
dest="$output_dir/三色桌宠.app"
if [[ -d "$dest" ]]; then mv "$dest" "$stage/previous.app"; fi
if ! mv "$app" "$dest"; then
    if [[ -d "$stage/previous.app" ]]; then mv "$stage/previous.app" "$dest"; fi
    exit 1
fi
printf '已生成 %s\n' "$dest"
