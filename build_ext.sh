#!/bin/bash
# 构建 FinderSync 扩展 + 宿主 App（universal2，ad-hoc 签名）
set -euo pipefail
cd "$(dirname "$0")"

ROOT="$(pwd)"
OUT="$ROOT/build"
SDK="$(xcrun --show-sdk-path)"
ARCHS="-arch arm64 -arch x86_64"

APP_NAME="新建文档"
APPEX_NAME="新建文档扩展"
APP_DIR="$OUT/$APP_NAME.app"
APPEX_DIR="$APP_DIR/Contents/PlugIns/$APPEX_NAME.appex"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/PlugIns/$APPEX_NAME.appex/Contents/MacOS"

echo "==> 编译扩展 (universal2)…"
clang $ARCHS -fobjc-arc \
  -isysroot "$SDK" \
  -framework Foundation -framework AppKit -framework FinderSync \
  "$ROOT/finder-sync/SyncExtension.m" "$ROOT/finder-sync/extmain.m" \
  -o "$APPEX_DIR/Contents/MacOS/newdoc-sync"

echo "==> 编译宿主 App (universal2)…"
clang $ARCHS -fobjc-arc \
  -isysroot "$SDK" -framework Foundation \
  "$ROOT/finder-sync/HostMain.m" \
  -o "$APP_DIR/Contents/MacOS/newdoc-host"

echo "==> 组装 bundle…"
cp "$ROOT/finder-sync/SyncExtension-Info.plist" "$APPEX_DIR/Contents/Info.plist"
cp "$ROOT/finder-sync/Host-Info.plist"          "$APP_DIR/Contents/Info.plist"
printf 'XPC!????' > "$APPEX_DIR/Contents/PkgInfo"
printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"

echo "==> 签名（ad-hoc + 沙盒授权，先扩展后宿主）…"
codesign --force --sign - --entitlements "$ROOT/finder-sync/extension.entitlements" "$APPEX_DIR"
codesign --force --sign - "$APP_DIR"

echo "==> 完成："
ls -lh "$APP_DIR/Contents/MacOS/newdoc-host" "$APPEX_DIR/Contents/MacOS/newdoc-sync"
lipo -info "$APPEX_DIR/Contents/MacOS/newdoc-sync"
codesign -dv "$APPEX_DIR" 2>&1 | grep -E 'Identifier|Signature' || true
