// FinderSync 扩展的标准入口：系统托管进程通过它加载 Info.plist 里
// 指定的 NSExtensionPrincipalClass（NewDocSync）并运行事件循环。
#import <Foundation/Foundation.h>

extern int NSExtensionMain(int argc, char *argv[]);

int main(int argc, char *argv[]) {
    return NSExtensionMain(argc, argv);
}
