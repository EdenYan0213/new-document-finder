// seticon — 给文件设置自定义图标（Finder 将始终显示该图标，不再生成内容缩略图）
// 用法：seticon <icns路径> <目标文件>
#import <AppKit/AppKit.h>

int main(int argc, char *argv[]) {
    if (argc < 3) {
        fprintf(stderr, "usage: seticon <icns> <file>\n");
        return 2;
    }
    @autoreleasepool {
        NSImage *icon = [[NSImage alloc] initWithContentsOfFile:@(argv[1])];
        if (!icon) {
            fprintf(stderr, "cannot load icon: %s\n", argv[1]);
            return 3;
        }
        BOOL ok = [[NSWorkspace sharedWorkspace] setIcon:icon forFile:@(argv[2])
                                                options:0];
        if (!ok) {
            fprintf(stderr, "setIcon failed for %s\n", argv[2]);
            return 4;
        }
    }
    return 0;
}
