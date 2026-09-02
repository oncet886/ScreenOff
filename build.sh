#!/bin/zsh
# 编译并打包 关屏不待机.app
# 默认临时签名(仅本机可用);要让「辅助功能」授权在重编译后仍有效,传入你的证书名:
#   CODESIGN_IDENTITY="Apple Development: you@example.com (TEAMID)" ./build.sh
set -e
cd "$(dirname "$0")"
APP="关屏不待机.app"
IDENTITY="${CODESIGN_IDENTITY:--}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -o "$APP/Contents/MacOS/ScreenOff" src/main.swift -framework Cocoa -framework IOKit
cp Info.plist "$APP/Contents/"
cp assets/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign "$IDENTITY" "$APP"
echo "built: $PWD/$APP"
