#!/bin/bash
# 构建 newdoc：先构建本机架构，若可用则再构建 x86_64 并 lipo 成 universal2
set -euo pipefail
cd "$(dirname "$0")/newdoc"

OUT="$(cd .. && pwd)/build"
mkdir -p "$OUT"

echo "==> cargo build --release (aarch64)…"
cargo build --release --quiet
cp -f target/release/newdoc "$OUT/newdoc-aarch64"

if rustup target list --installed | grep -q '^x86_64-apple-darwin$'; then
  echo "==> cargo build --release (x86_64)…"
  cargo build --release --target x86_64-apple-darwin --quiet
  echo "==> lipo 合并 universal2…"
  lipo -create -output "$OUT/newdoc" \
    target/release/newdoc \
    target/x86_64-apple-darwin/release/newdoc
  rm -f "$OUT/newdoc-aarch64"
else
  echo "==> 跳过 x86_64（执行 rustup target add x86_64-apple-darwin 可启用 universal2）"
  mv -f "$OUT/newdoc-aarch64" "$OUT/newdoc"
fi

echo "==> 产物："
ls -lh "$OUT/newdoc"
lipo -info "$OUT/newdoc" 2>/dev/null || true
codesign -dv "$OUT/newdoc" 2>&1 | head -3 || true
