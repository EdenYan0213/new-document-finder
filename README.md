# Finder 右键「新建文档」

在 Finder 中右键即可像 Windows 一样新建各种文档：**txt / docx / xlsx / pptx / pdf / md / csv / rtf**。
核心逻辑由 Rust 编写，无常驻进程、按需运行、用完即退。

## 使用方式

| 操作 | 菜单位置 |
|---|---|
| 右键**桌面空白处** / 文件夹窗口空白处 | 右键菜单**顶层** → **新建文档** 子菜单（Finder 扩展提供）✨ |
| 右键某个**文件夹** | 顶层子菜单同上；也可走 服务 → 新建文档 → 创建在该文件夹内 |
| 右键某个**文件** | 同上 → 创建在其所在文件夹 |
| 任意位置 | 快捷键 **⌥⌘J** → 在"当前位置"新建 |
| 菜单栏 | **访达 → 服务 → 在当前文件夹新建文档** |

选择类型后文件立即创建（命名 `未命名.ext`，重名自动变为 `未命名 2.ext`…），
并自动在 Finder 中选中、弹出系统通知。创建后按 `Return` 即可重命名。

> · 扩展若未启用：系统设置 → 通用 → 登录项与扩展 → 扩展 → 添加的扩展 →
>   **Finder** → 勾选「新建文档」。
> · 首次使用快捷键/菜单栏入口时，系统会询问"是否允许控制 Finder"，点**允许**（仅一次）。
>   Finder 扩展入口**不需要任何授权**。
> · 更换/清除快捷键：访达 → 服务 → 服务设置…，或：
>   `defaults delete pbs NSServicesStatus`（清除后重启 Finder）。

### 快捷键是怎么实现的

`install.sh` 会把快捷键 ⌥⌘J 写入 `pbs.plist`（系统服务偏好，与
"系统设置 → 键盘 → 键盘快捷键 → 服务"里手动设置等效）：

```bash
defaults write pbs NSServicesStatus -dict-add \
  "com.local.newdocument.here - runWorkflowAsService - 在当前文件夹新建文档" \
  '{ "enabled_context_menu" = 1; "enabled_services_menu" = 1; \
     "presentation_modes" = { ContextMenu = 1; ServicesMenu = 1; }; \
     "NSKeyEquivalent" = { default = J; }; }'
```

想换字母，把 `default = J` 改成其他字母（系统自动加 ⌥⌘ 前缀）后执行
`/System/Library/CoreServices/pbs -flush && killall Finder`。

## 架构

```
① Finder 扩展（FinderSync）    /Applications/新建文档.app 内嵌 .appex
   └─ 桌面/任意位置右键 → 顶层「新建文档」子菜单（类型清单实时读自 config.toml）
        └─ 按需 exec → newdoc create
② 服务（Quick Action）×2      ~/Library/Services/*.workflow
   └─ 右键文件/文件夹 → 服务 → 新建文档；右键窗口空白处 → 在当前文件夹新建文档
        └─ 薄壳 exec → newdoc run
③ 快捷键 ⌥⌘J                  pbs.plist（等同系统服务快捷键设置）
        └─ 触发 ② 的无输入服务

所有入口共用核心：
   newdoc (Rust, universal2, ~1 MB)  —  选类型/原子创建/模板拷贝/Finder 定位
   ├─ config.toml                    —  类型清单，三入口共用，改一处全生效
   └─ templates/未命名.{docx,xlsx,…}  —  模板，可自行替换
```

- 扩展与 `newdoc` 之间通过 argv 传参，无 shell 拼接；扩展**不使用 AppleEvents**，
  因此该入口零授权弹窗。
- Finder 扩展基于开源项目 [MacNewFile](https://github.com/GarfieldFluffJr/MacNewFile)
  (GPL-3.0) 的实现思路二次开发（卷宗观察、bundle 结构），许可证沿用 GPL-3.0；
  创建后端、类型配置、安全设计均为本项目的 Rust 实现。

## 内存与安全设计

**内存**
- `newdoc` 核心：无守护进程，仅触发时运行，峰值内存实测 **约 1.6 MB**（服务与 CLI 入口零驻留）。
- Finder 扩展：为提供桌面右键**顶层**菜单，扩展进程由系统托管常驻（实测 RSS 约 28 MB，
  其中大部分为与系统共享的框架页）——这是 FinderSync 机制的固有成本，同类商业工具相同。
  若不接受，可仅卸载扩展（`uninstall.sh` 会一并移除；服务菜单与快捷键入口不受影响）。
- Release 构建：`opt-level="z"` + LTO + strip + `panic="abort"`，universal2 双架构核心二进制约 956 KB，
  扩展二进制仅 137 KB。

**安全**
- 所有子进程（osascript/open）通过 **argv 数组**传参，绝不拼接 shell/AppleScript 字符串。
- 文件创建使用 `OpenOptions::create_new` **原子新建**，从机制上不可能覆盖任何已有文件（防 TOCTOU）。
- 扩展名白名单（小写字母/数字，≤16 位）、文件名前缀与模板名严格校验，配置中的恶意值无法造成路径穿越。
- 模板复制失败自动**回滚**，不留半截文件。
- 纯用户态安装（只写 `~/Library/Services` 与 `~/Library/Application Support/NewDocument`），无需 sudo、不改系统目录。
- 无网络访问、无动态库依赖（静态链接 Rust 标准库以外的所有逻辑）。

**通用性**
- 类型由 `config.toml` 驱动：追加一段 `[[types]]` 并把模板文件放进 `templates/` 即可支持
  任意格式（`.pages`、`.key`、`.drawio`……App 能打开就行）。
- universal2 二进制同时支持 Apple Silicon 与 Intel Mac。
- 命令行同样可用（可脚本化）：
  ```bash
  newdoc types                                  # 列出类型
  newdoc create --dir ~/Documents --ext docx    # 非交互创建
  newdoc run <文件或文件夹路径>                  # 交互流程
  ```

## 安装 / 卸载

```bash
./install.sh     # 需要 Xcode Command Line Tools 与 Rust（cargo）；装完建议 killall Finder
./uninstall.sh   # 移除工作流、newdoc、模板与配置
```

安装内容：

| 路径 | 内容 |
|---|---|
| `~/Library/Services/新建文档.workflow` | 右键文件/文件夹入口 |
| `~/Library/Services/在当前文件夹新建文档.workflow` | 右键空白处入口 |
| `~/Library/Application Support/NewDocument/bin/newdoc` | Rust 核心 |
| `~/Library/Application Support/NewDocument/config.toml` | 类型配置（重装不会覆盖你的修改） |
| `~/Library/Application Support/NewDocument/templates/` | 文档模板（替换即自定义初始内容） |

## 自定义示例

新增"Keynote 演示"类型：把 `演示.key` 放进 `templates/`，在 `config.toml` 追加：

```toml
[[types]]
label = "Keynote 演示 (.key)"
ext = "key"
template = "演示.key"
```

想让新建的 Word 带公司抬头？直接用 Word 编辑
`~/Library/Application Support/NewDocument/templates/未命名.docx` 并保存即可。

## 故障排查

- **菜单里没有这两项**：确认已启用（系统设置 → 通用 → 登录项与扩展 → 服务；或 键盘 → 键盘快捷键 → 服务），
  再执行 `killall Finder`。
- **点"新建文档"无反应**：`~/Library/Application Support/NewDocument/bin/newdoc types` 确认核心可用。
- **提示缺少模板**：重跑 `./install.sh`，或检查 `config.toml` 里 `template` 指向的文件名。
- **"控制 Finder"弹窗**：来自空白处入口的 Apple Event 询问，点允许即可。
