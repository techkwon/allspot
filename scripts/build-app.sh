#!/bin/bash
# Allspot.app을 만든다: 릴리스 빌드 → 앱 번들 구성 → 아이콘 → 임시(ad-hoc) 서명
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product Allspot
swift build -c release --product allspot-tool
BIN="$(swift build -c release --show-bin-path)"
FINAL="build/Allspot.app"
# 새 번들은 옆에서 다 만든 뒤 한 번에 바꿔 끼운다. 앱·MCP 서버가 쓰는 Helpers/allspot이 빌드 중에 사라지지 않게.
APP="build/Allspot.app.new"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$BIN/Allspot" "$APP/Contents/MacOS/Allspot"
# AI용 명령줄 도구·MCP 서버
cp "$BIN/allspot-tool" "$APP/Contents/Helpers/allspot"
cp Resources/Info.plist "$APP/Contents/Info.plist"

if [ ! -f Resources/AppIcon.icns ]; then
  ICONSET="build/AppIcon.iconset"
  rm -rf "$ICONSET"
  swift scripts/make-icon.swift "$ICONSET"
  iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
  rm -rf "$ICONSET"
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"

codesign --force --sign - "$APP"

rm -rf "$FINAL.old"
[ -d "$FINAL" ] && mv "$FINAL" "$FINAL.old"
mv "$APP" "$FINAL"
rm -rf "$FINAL.old"
echo "완성: $FINAL"
