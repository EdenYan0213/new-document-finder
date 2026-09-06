// seticon — 给文件设置自定义图标（Finder 将始终显示该图标，不再生成内容缩略图）
// 用法：
//   seticon --resolve <file>   捕获系统当前为该文件解析的类型图标并固化为自定义图标
//   seticon <icns路径> <文件>   用指定 icns 设置自定义图标
#import <AppKit/AppKit.h>

static int apply_icon(NSImage *icon, NSString *file) {
    if (!icon) return 3;
    BOOL ok = [[NSWorkspace sharedWorkspace] setIcon:icon forFile:file options:0];
    if (!ok) {
        fprintf(stderr, "setIcon failed for %s\n", file.UTF8String);
        return 4;
    }
    return 0;
}

int main(int argc, char *argv[]) {
    if (argc < 2) {
        fprintf(stderr, "usage: seticon --resolve <file> | <icns> <file>\n");
        return 2;
    }
    @autoreleasepool {
        if (strcmp(argv[1], "--resolve") == 0 && argc >= 3) {
            NSString *file = @(argv[2]);
            // 系统解析的类型图标 = 新建瞬间一闪而过的那一个
            NSImage *icon = [[NSWorkspace sharedWorkspace] iconForFile:file];
            fprintf(stderr, "resolve icon=%@\n", icon ? @"ok" : @"nil");
            return apply_icon(icon, file);
        }
        if (argc >= 3) {
            NSImage *icon = [[NSImage alloc] initWithContentsOfFile:@(argv[1])];
            if (!icon) {
                fprintf(stderr, "cannot load icon: %s\n", argv[1]);
                return 3;
            }
            return apply_icon(icon, @(argv[2]));
        }
    }
    return 2;
}
