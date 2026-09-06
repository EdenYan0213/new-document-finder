#!/usr/bin/env python3
"""构建两个 Finder「新建文档」Quick Action 工作流包（.workflow）。"""
import shutil
import uuid
import plistlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent
BUILD = ROOT / "build"

FINDER_PATH = "/System/Library/CoreServices/Finder.app"

# 快速操作里的薄壳：所有逻辑都在 newdoc（Rust）里，这里只负责转发参数。
# 路径含空格，必须整体加引号；"$@" 原样转发，无注入面。
WRAPPER = """\
bin="$HOME/Library/Application Support/NewDocument/bin/newdoc"
if [[ ! -x "$bin" ]]; then
  osascript -e 'on run argv
display alert (item 1 of argv) message (item 2 of argv)
end run' "新建文档" "未找到 newdoc，请重新运行 install.sh" >/dev/null 2>&1
  exit 1
fi
exec "$bin" run "$@"
"""


def run_shell_script_action(script: str) -> dict:
    """构造 Run Shell Script action（结构参照 macOS 26 实际生成的 workflow）。"""
    return {
        "ActionBundlePath": "/System/Library/Automator/Run Shell Script.action",
        "ActionName": "Run Shell Script",
        "ActionParameters": {
            "CheckedForUserDefaultShell": True,
            "COMMAND_STRING": WRAPPER,
            "inputMethod": 0,  # 0 = 作为参数传入 ("$@")
            "shell": "/bin/zsh",
            "source": "",
        },
        "AMAccepts": {"Container": "List", "Optional": True,
                      "Types": ["com.apple.cocoa.path"]},
        "AMActionVersion": "2.0.3",
        "AMApplication": ["Automator"],
        "AMParameterProperties": {
            "CheckedForUserDefaultShell": {},
            "COMMAND_STRING": {},
            "inputMethod": {},
            "shell": {},
            "source": {},
        },
        "AMProvides": {"Container": "List", "Types": ["com.apple.cocoa.string"]},
        "BundleIdentifier": "com.apple.RunShellScript",
        "CanShowSelectedItemsWhenRun": False,
        "CanShowWhenRun": True,
        "Category": ["AMCategoryUtilities"],
        "CFBundleVersion": "2.0.3",
        "Class Name": "RunShellScriptAction",
        "InputUUID": str(uuid.uuid4()).upper(),
        "Keywords": ["Shell", "Script"],
        "OutputUUID": str(uuid.uuid4()).upper(),
        "UnlocalizedApplications": ["Automator"],
        "UUID": str(uuid.uuid4()).upper(),
    }


def build_workflow(name: str, bundle_id: str, input_type: str,
                   send_file_types, script: str) -> Path:
    meta = {
        "serviceProcessesInput": False,
        "serviceApplicationBundleID": "com.apple.finder",
        "serviceApplicationPath": FINDER_PATH,
        "workflowTypeIdentifier": "com.apple.Automator.servicesMenu",
        "serviceOutputTypeIdentifier": "com.apple.Automator.nothing",
        "serviceInputTypeIdentifier": input_type,
    }
    doc = {
        "actions": [{"action": run_shell_script_action(script), "isViewVisible": 1}],
        "AMApplicationBuild": "521",
        "AMApplicationVersion": "2.10",
        "AMDocumentVersion": "2",
        "connectors": {},
        "workflowMetaData": meta,
    }

    nsservice = {
        "NSMessage": "runWorkflowAsService",
        "NSRequiredContext": {"NSApplicationIdentifier": "com.apple.finder"},
        "NSMenuItem": {"default": name},
    }
    if send_file_types:
        nsservice["NSSendFileTypes"] = send_file_types

    info = {
        "CFBundleShortVersionString": "1.0",
        "CFBundleIdentifier": bundle_id,
        "NSServices": [nsservice],
        "CFBundleName": name,
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleDevelopmentRegion": "zh_CN",
        "CFBundleExecutable": "",
        "CFBundlePackageType": "BNDL",
        "CFBundleVersion": "1",
    }

    bundle = BUILD / f"{name}.workflow"
    if bundle.exists():
        shutil.rmtree(bundle)
    (bundle / "Contents").mkdir(parents=True)
    with open(bundle / "Contents/document.wflow", "wb") as f:
        plistlib.dump(doc, f)
    with open(bundle / "Contents/Info.plist", "wb") as f:
        plistlib.dump(info, f)
    return bundle


def main():
    BUILD.mkdir(exist_ok=True)

    # 服务一：右键文件/文件夹时出现（快速操作 / 服务菜单）
    build_workflow(
        "新建文档",
        "com.local.newdocument.files",
        "com.apple.Automator.fileSystemObject",
        ["public.item"],
        WRAPPER,
    )
    # 服务二：右键空白处时出现（服务菜单，无输入）
    build_workflow(
        "在当前文件夹新建文档",
        "com.local.newdocument.here",
        "com.apple.Automator.nothing",
        None,
        WRAPPER,
    )
    print("已生成：")
    for p in sorted(BUILD.iterdir()):
        print(" ", p)


if __name__ == "__main__":
    main()
