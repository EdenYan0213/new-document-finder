#!/bin/bash
# 安装 Finder「新建文档」快速操作（Rust 核心 + 模板 + 工作流）
set -euo pipefail
cd "$(dirname "$0")"

APP_DIR="$HOME/Library/Application Support/NewDocument"
SERVICES="$HOME/Library/Services"

echo "==> 构建 newdoc（Rust，Release）…"
./build.sh

echo "==> 安装 newdoc 与模板…"
mkdir -p "$APP_DIR/bin" "$APP_DIR/templates"
cp -f build/newdoc "$APP_DIR/bin/newdoc"
chmod 755 "$APP_DIR/bin/newdoc"
cp -f templates/未命名.* "$APP_DIR/templates/"
# 已有用户配置不覆盖，保留自定义
if [[ ! -f "$APP_DIR/config.toml" ]]; then
  cp -f newdoc/config.toml "$APP_DIR/config.toml"
fi

echo "==> 构建并安装 Finder 快速操作…"
python3 build.py
rm -rf "$SERVICES/新建文档.workflow" "$SERVICES/在当前文件夹新建文档.workflow"
cp -R "build/新建文档.workflow" build/在当前文件夹新建文档.workflow "$SERVICES/"

echo "==> 安装 Finder 扩展（桌面右键顶层菜单）…"
./build_ext.sh >/dev/null
APP_SRC="build/新建文档.app"
if [[ -w /Applications ]]; then
  APP_DST="/Applications/新建文档.app"
else
  mkdir -p "$HOME/Applications"
  APP_DST="$HOME/Applications/新建文档.app"
fi
rm -rf "$APP_DST"
cp -R "$APP_SRC" "$APP_DST"
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
"$LSREG" -f "$APP_DST" || true
# 关键：启动一次宿主 App 触发 pluginkit 索引（LSUIElement，闪退无界面）
open -g "$APP_DST" 2>/dev/null || true
sleep 2
pluginkit -a "$APP_DST/Contents/PlugIns/新建文档扩展.appex" || true
pluginkit -e use -i com.local.newdoc.findersync || true
if pluginkit -m -v -i com.local.newdoc.findersync 2>/dev/null | grep -q "^+"; then
  echo "✅ Finder 扩展已注册并启用：$APP_DST"
else
  echo "⚠️ 扩展未自动启用，请到：系统设置 → 通用 → 登录项与扩展 → 扩展 → 添加的扩展 → Finder 勾选「新建文档」"
fi

echo "==> 绑定快捷键 ⌥⌘J（已自定义过则不覆盖）…"
if ! defaults read pbs NSServicesStatus 2>/dev/null | grep -q "com.local.newdocument.here"; then
  defaults write pbs NSServicesStatus -dict-add \
    "com.local.newdocument.here - runWorkflowAsService - 在当前文件夹新建文档" \
    '{ "enabled_context_menu" = 1; "enabled_services_menu" = 1; "presentation_modes" = { ContextMenu = 1; ServicesMenu = 1; }; "NSKeyEquivalent" = { default = J; }; }' || true
fi

echo "==> 刷新系统服务缓存…"
/System/Library/CoreServices/pbs -flush || true
/System/Library/CoreServices/pbs -update || true

echo "==> 验证注册…"
# pbs -dump 会把中文转义为 \Uxxxx，因此用 bundle ID 匹配
if /System/Library/CoreServices/pbs -dump 2>/dev/null | grep -q "com.local.newdocument"; then
  echo "✅ 安装完成。若右键菜单暂未出现，执行：killall Finder"
else
  echo "⚠️ 未在 pbs 缓存中找到，请注销并重新登录后再试"
fi
