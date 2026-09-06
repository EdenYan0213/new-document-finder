# 新建文档 for macOS

在 Finder 中**右键即可新建各类文档**——补上 macOS 缺失的 Windows 式「新建文件」功能。
支持 **txt / docx / xlsx / pptx / pdf / md / csv / rtf / Pages / Numbers / Keynote** 共 11 种类型，
新建的文件带有清晰的**类型徽章图标**，一眼可辨。

核心逻辑由 **Rust** 编写，按需运行、用完即退、零注入面；Finder 扩展负责把
「新建文档」子菜单放到**桌面与任意文件夹的右键菜单顶层**。

## 功能一览

- **三个创建入口**，行为一致：
  - 右键菜单**顶层**「新建文档」子菜单（Finder 扩展；桌面空白处同样可用）
    —— 单击父项弹出类型选择框，悬停展开子菜单直达
  - 右键 → 服务 →「新建文档」（右键文件/文件夹时）/「在当前文件夹新建文档」（窗口空白处）
  - 全局快捷键 **⌥⌘J**（在桌面或当前 Finder 窗口位置新建）
- **类型徽章图标**：新建的文件自动写入自定义类型图标（DOC/XLS/PPT/PDF…），
  优先级高于内容缩略图——空白文档也不会显示成一张白纸
- 文件名 `未命名.ext`，重名自动顺延（`未命名 2.ext`…），创建后自动在 Finder 中选中
- **零授权弹窗**（扩展入口不使用 AppleEvents）；快捷键入口首次使用需允许一次「控制 Finder」
- 11 种类型全部由 `config.toml` 驱动，**改一处三个入口同步生效**

## 系统要求与安装

要求 macOS 12+（在 macOS 26.6 Tahoe 上开发实测），安装过程需要 Rust（cargo）与 Xcode Command Line Tools。

```bash
./install.sh      # 一键安装（构建 + 安装 + 注册扩展 + 绑定快捷键）
./uninstall.sh    # 一键卸载（无任何残留）
```

安装后若菜单未出现：`killall Finder`。扩展可在
系统设置 → 通用 → 登录项与扩展 → 扩展 → 添加的扩展 → **Finder** 中开关。

## 架构

```
┌─ 入口层 ────────────────────────────────────────────────┐
│ ① FinderSync 扩展    /Applications/新建文档.app（内嵌 .appex）│
│    右键顶层「新建文档」子菜单 + 单击父项弹选择框                │
│ ② 服务 ×2            ~/Library/Services/*.workflow        │
│    右键文件/文件夹、窗口空白处（服务子菜单）                     │
│ ③ 快捷键 ⌥⌘J          系统服务快捷键（pbs.plist）            │
└──────────────────────┬───────────────────────────────────┘
                       ▼  全部按需调起（argv 传参，无 shell 拼接）
┌─ 核心层（Rust）──────────────────────────────────────────┐
│ newdoc create --dir <目录> --ext <类型>                    │
│   原子创建（create_new 防覆盖）→ 模板拷贝 → 写入类型徽章图标   │
│   → 在 Finder 中定位                                       │
│ newdoc run [路径…]      交互流程（服务入口用）               │
│ newdoc types [--tsv]    类型清单（扩展菜单实时读取）          │
├─ 配置与资源（~/Library/Application Support/NewDocument/）  │
│   config.toml   类型清单（11 种，可增删）                    │
│   templates/    空白模板（替换即自定义初始内容）               │
│   icons/        类型图标（写入自定义图标用）                  │
│   bin/          newdoc + seticon                           │
└─────────────────────────────────────────────────────────┘
```

## 项目位置

| 位置 | 内容 |
|---|---|
| **源码仓库（本地）** | `~/…/workspace/default/new-document-finder/`（本目录） |
| **源码仓库（远程）** | [github.com/EdenYan0213/new-document-finder](https://github.com/EdenYan0213/new-document-finder) |
| Finder 扩展宿主 App | `/Applications/新建文档.app` |
| 服务工作流 | `~/Library/Services/新建文档.workflow`、`~/Library/Services/在当前文件夹新建文档.workflow` |
| 核心 / 配置 / 模板 / 图标 | `~/Library/Application Support/NewDocument/` |
| 快捷键注册 | `~/Library/Preferences/pbs.plist`（系统服务快捷键） |

## 源码结构

```
├── install.sh / uninstall.sh   一键安装 / 卸载
├── build.sh                    构建 newdoc（Rust）与 seticon（universal2）
├── build_ext.sh                构建 FinderSync 扩展 + 宿主 App（无需 Xcode，clang 直编）
├── build.py                    生成两个 .workflow 服务包
├── newdoc/                     Rust 核心（原子创建 / 模板 / 配置校验 / 自定义图标调度）
│   ├── src/main.rs
│   ├── config.toml             默认类型清单（安装时复制，已有用户配置不覆盖）
│   └── Cargo.toml
├── finder-sync/                Finder 扩展（ObjC）+ 宿主 App + UTI/沙盒声明
├── seticon/seticon.m           写入自定义图标的小工具（支持 --resolve 固化系统图标）
├── icons/gen_icons.py          图标生成管线（Pillow → PNG → iconutil → icns）
├── scripts/gen_templates.py    空白模板生成（docx/pptx/xlsx/pdf/rtf）
└── templates/                  8 个模板文件（pages/key/numbers 来自 MacNewFile）
```

## 自定义

**增删文档类型**：编辑 `~/Library/Application Support/NewDocument/config.toml`（保存即生效，
右键菜单下一次打开就会刷新），例如添加 Keynote 变体或 `.drawio`：

```toml
[[types]]
label = "Keynote 演示 (.key)"
ext = "key"
template = "未命名.key"   # templates/ 下的文件；留空 = 创建空文件
```

**更换新文档初始内容**：直接替换 `templates/` 里的同名模板文件。
**重新生成空白模板 / 图标**：

```bash
python3 scripts/gen_templates.py   # 需 python-docx / python-pptx / openpyxl
python3 icons/gen_icons.py         # 需 Pillow；产物 icons/icon-*.icns
```

**更换快捷键**：访达 → 服务 → 服务设置…，或修改 install.sh 中 `NSKeyEquivalent` 后重装。

## 设计说明

**内存**：`newdoc` 按需运行（峰值约 1.6 MB，用完即退）；Finder 扩展私有内存约 4.5 MB
（`ps` 显示的 28 MB 绝大部分是全系统共享的只读框架页）——这是右键顶层菜单机制（FinderSync）
的固有成本；无守护进程、无登录项、无 LaunchAgents。

**安全**：所有子进程经 argv 数组传参，AppleScript 动态数据走 argv，无注入面；文件以
`create_new` 原子创建，绝不覆盖已有文件；扩展名/文件名/模板名白名单校验，配置恶意值无法
路径穿越；模板复制失败自动回滚；纯用户态安装，卸载无残留。

**通用性**：类型配置化；universal2 双架构（Apple Silicon + Intel）；CLI 可脚本化：

```bash
newdoc types                                  # 列出类型
newdoc create --dir ~/Documents --ext docx    # 非交互创建
```

## 开发与测试

```bash
(cd newdoc && cargo test)   # 单元测试：配置校验 / 唯一命名 / 原子创建 / 沙盒 HOME 等
./build.sh && ./build_ext.sh && python3 build.py   # 构建全部组件
./install.sh                # 构建并安装
```

调试：`touch /tmp/newdoc-sync-debug.enabled` 开启扩展诊断日志（`/tmp/newdoc-sync-debug.log`）。

## 故障排查

| 现象 | 处理 |
|---|---|
| 右键菜单没有「新建文档」 | `killall Finder`；确认扩展已勾选（系统设置 → 通用 → 登录项与扩展 → 扩展 → 添加的扩展 → Finder） |
| 新建无反应 | `~/Library/Application Support/NewDocument/bin/newdoc types` 确认核心可用 |
| 图标显示为白纸 | 删除旧文件重建（修复前创建的文件不含自定义图标）；或该类型被其他 App 抢占声明 |
| 快捷键 ⌥⌘J 无反应 | 首次使用需允许「控制 Finder」；或重新勾选服务（键盘快捷键 → 服务） |

## 致谢与许可

Finder 扩展基于开源项目 [MacNewFile](https://github.com/GarfieldFluffJr/MacNewFile)
（GPL-3.0）二次开发：沿用其卷宗观察与 bundle 组织思路，创建后端、类型配置、图标体系、
安全设计均为本项目实现。全项目以 **GPL-3.0** 许可发布（见 [LICENSE](LICENSE)）。
