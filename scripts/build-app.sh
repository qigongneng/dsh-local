#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
build_root="$project_root/build"
app="$build_root/DSH Local.app"
node_source="${DSH_LOCAL_NODE_SOURCE:-$HOME/.local/bin/node}"

if [[ ! -x "$node_source" ]]; then
  print -u2 -- "Node executable is unavailable: $node_source"
  exit 66
fi

mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/bin" "$app/Contents/Resources/scripts"

icon_source="$project_root/assets/AppIcon.png"
iconset="$build_root/AppIcon.iconset"
if [[ ! -f "$icon_source" ]]; then
  print -u2 -- "Application icon is unavailable: $icon_source"
  exit 66
fi

mkdir -p "$iconset"
for pair in \
  '16 icon_16x16.png' \
  '32 icon_16x16@2x.png' \
  '32 icon_32x32.png' \
  '64 icon_32x32@2x.png' \
  '128 icon_128x128.png' \
  '256 icon_128x128@2x.png' \
  '256 icon_256x256.png' \
  '512 icon_256x256@2x.png' \
  '512 icon_512x512.png' \
  '1024 icon_512x512@2x.png'; do
  size="${pair%% *}"
  filename="${pair#* }"
  sips -z "$size" "$size" "$icon_source" --out "$iconset/$filename" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"

swiftc \
  -O \
  -framework Cocoa \
  -framework WebKit \
  "$project_root/Sources/main.swift" \
  -o "$app/Contents/MacOS/DSHLocal"

cp "$project_root/templates/Info.plist" "$app/Contents/Info.plist"
ditto "$node_source" "$app/Contents/Resources/bin/node"
chmod 755 "$app/Contents/Resources/bin/node"
for script in start-current.sh update.sh rollback.sh; do
  cp "$project_root/scripts/$script" "$app/Contents/Resources/scripts/$script"
  chmod 755 "$app/Contents/Resources/scripts/$script"
done

codesign --force --deep --sign - "$app"
codesign --verify --deep --strict --verbose=2 "$app"
print -- "$app"
