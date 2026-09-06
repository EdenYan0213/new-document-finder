#!/bin/bash
# 卸载 Finder「新建文档」快速操作（连同 Rust 核心、模板、配置一并移除）
set -euo pipefail

rm -rf "$HOME/Library/Services/新建文档.workflow" \
       "$HOME/Library/Services/在当前文件夹新建文档.workflow"
rm -rf "$HOME/Library/Application Support/NewDocument"

# Finder 扩展
pluginkit -r -i com.local.newdoc.findersync 2>/dev/null || true
rm -rf "/Applications/新建文档.app" "$HOME/Applications/新建文档.app"

/System/Library/CoreServices/pbs -flush || true
/System/Library/CoreServices/pbs -update || true

echo "已卸载「新建文档」快速操作。若右键菜单仍显示，执行：killall Finder"
