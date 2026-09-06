// 宿主 App 的可执行文件：唯一职责是承载扩展（PlugIns/*.appex）。
// 双击运行时给出一句提示后退出（LSUIElement，无 Dock 图标）。
#import <Foundation/Foundation.h>

int main(int argc, char *argv[]) {
    @autoreleasepool {
        NSLog(@"[newdoc] 宿主 App 已运行；扩展由 Finder 按需加载。"
              @"如未启用：系统设置 → 通用 → 登录项与扩展 → 扩展 → 添加的扩展 → Finder");
    }
    return 0;
}
