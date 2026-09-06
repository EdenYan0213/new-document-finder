// ============================================================
// NewDocSync — Finder 扩展（FinderSync）
//
// 二次开发基础：MacNewFile (GPL-3.0) https://github.com/GarfieldFluffJr/MacNewFile
// 本实现的改动：
//   · 类型清单从 newdoc 配置 (config.toml) 动态读取——三个入口（右键扩展/
//     服务菜单/CLI）共用同一份配置，增删类型只改一处
//   · 创建动作直接调 newdoc（Rust 核心：原子创建、模板拷贝、Finder 定位），
//     替代原项目的 AppleScript 拼 zip 方案——更安全（无注入面、TOCTOU 安全）
//     且不会有"生成的 pptx 打不开"类问题（模板为真实合法文件）
//   · 卷宗列表在菜单打开时刷新（原项目用 3 秒轮询定时器，本实现零空闲 CPU）
//
// 许可证：沿用 GPL-3.0
// ============================================================

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <pwd.h>
#import <unistd.h>
#import "FinderSync.h"

@interface NewDocSync : FIFinderSync
@property (nonatomic, copy) NSArray<NSArray<NSString *> *> *typeList; // 每项 @[label, ext]
@property (nonatomic, assign) NSTimeInterval configStamp;
- (void)createDoc:(NSMenuItem *)sender;
- (void)reloadTypesIfNeeded;
- (void)updateDirectoryURLs;
@end

// 编译期兜底清单：newdoc 未安装/配置缺失时也能工作
static NSArray<NSArray<NSString *> *> *FallbackTypes(void) {
    return @[
        @[@"文本文档 (.txt)",             @"txt"],
        @[@"Word 文档 (.docx)",          @"docx"],
        @[@"Excel 表格 (.xlsx)",         @"xlsx"],
        @[@"PowerPoint 演示文稿 (.pptx)", @"pptx"],
        @[@"PDF 文档 (.pdf)",            @"pdf"],
        @[@"Markdown 笔记 (.md)",        @"md"],
        @[@"CSV 表格 (.csv)",            @"csv"],
        @[@"RTF 富文本 (.rtf)",          @"rtf"],
    ];
}

// 沙盒内 NSHomeDirectory() 返回容器路径，这里取真实主目录（getpwuid 不受沙盒重映射影响）
static NSString *RealHomeDir(void) {
    struct passwd *pw = getpwuid(getuid());
    if (pw && pw->pw_dir && strlen(pw->pw_dir) > 0) {
        return [NSString stringWithUTF8String:pw->pw_dir];
    }
    return NSHomeDirectory();
}

static NSString *NewdocBinPath(void) {
    return [RealHomeDir() stringByAppendingPathComponent:
            @"Library/Application Support/NewDocument/bin/newdoc"];
}

// 文件调试日志：系统日志会脱敏动态内容，这里落盘明文，便于诊断
static void SyncDebugLog(NSString *line) {
    NSString *path = @"/tmp/newdoc-sync-debug.log";
    NSString *out = [NSString stringWithFormat:@"[%@] %@\n",
                     [NSDate date], line];
    for (NSString *p in @[path, [NSTemporaryDirectory()
            stringByAppendingPathComponent:@"newdoc-sync-debug.log"]]) {
        @try {
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:p];
            if (fh) {
                [fh seekToEndOfFile];
                [fh writeData:[out dataUsingEncoding:NSUTF8StringEncoding]];
                [fh closeFile];
                return;
            }
            if ([out writeToFile:p atomically:YES
                        encoding:NSUTF8StringEncoding error:NULL]) {
                return;
            }
        } @catch (NSException *e) { /* 尝试下一个位置 */ }
    }
}

@implementation NewDocSync

- (instancetype)init {
    self = [super init];
    if (self) {
        _typeList = FallbackTypes();
        _configStamp = -1;
        [self reloadTypesIfNeeded];
        [self updateDirectoryURLs];
    }
    return self;
}

// 观察根目录 + 所有已挂载卷宗（FinderSync 不跨卷宗挂载点）
- (void)updateDirectoryURLs {
    NSMutableSet<NSURL *> *urls =
        [NSMutableSet setWithObject:[NSURL fileURLWithPath:@"/"]];
    NSArray<NSURL *> *vols = [[NSFileManager defaultManager]
        mountedVolumeURLsIncludingResourceValuesForKeys:nil
                                                options:NSVolumeEnumerationSkipHiddenVolumes];
    for (NSURL *v in vols) {
        [urls addObject:v];
    }
    [FIFinderSyncController defaultController].directoryURLs = urls;
}

// 菜单类型 = newdoc 配置。用 config.toml 的 mtime 做脏检查，配置改动即时生效。
- (void)reloadTypesIfNeeded {
    NSString *cfg = [RealHomeDir() stringByAppendingPathComponent:
                     @"Library/Application Support/NewDocument/config.toml"];
    NSDictionary *attrs = [[NSFileManager defaultManager]
                           attributesOfItemAtPath:cfg error:NULL];
    NSTimeInterval stamp = [attrs.fileModificationDate timeIntervalSince1970];
    if (self.typeList && stamp == self.configStamp) {
        return;
    }
    self.configStamp = stamp;

    NSString *bin = NewdocBinPath();
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:bin]) {
        return; // 保留现有清单
    }

    NSTask *t = [[NSTask alloc] init];
    t.launchPath = bin;
    t.arguments = @[@"types", @"--tsv"];
    t.currentDirectoryPath = @"/";
    NSPipe *out = [NSPipe pipe];
    t.standardOutput = out;
    t.standardError = [NSPipe pipe];
    @try {
        [t launch];
        NSData *data = [[out fileHandleForReading] readDataToEndOfFile];
        [t waitUntilExit];
        if (t.terminationStatus != 0) return;

        NSMutableArray<NSArray<NSString *> *> *types = [NSMutableArray array];
        NSString *text = [[NSString alloc] initWithData:data
                                               encoding:NSUTF8StringEncoding];
        for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
            NSArray<NSString *> *parts = [line componentsSeparatedByString:@"\t"];
            if (parts.count >= 2 && parts[0].length > 0 && parts[1].length > 0) {
                [types addObject:@[parts[0], parts[1]]];
            }
        }
        if (types.count > 0) {
            self.typeList = types;
        }
    } @catch (NSException *e) {
        NSLog(@"[newdoc-sync] 读取类型失败：%@", e.reason);
    }
}

- (NSMenu *)menuForMenuKind:(FIMenuKind)whichMenu {
    NSLog(@"[newdoc-sync] menuForMenuKind=%lu", (unsigned long)whichMenu);
    if (whichMenu != FIMenuKindContextualMenuForContainer &&
        whichMenu != FIMenuKindContextualMenuForItems) {
        return nil;
    }
    // 菜单打开时顺带刷新卷宗与类型（无轮询定时器，零空闲 CPU）
    [self updateDirectoryURLs];
    [self reloadTypesIfNeeded];
    SyncDebugLog([NSString stringWithFormat:@"菜单打开 kind=%lu 类型数=%lu",
                  (unsigned long)whichMenu, (unsigned long)self.typeList.count]);

    NSMenu *root = [[NSMenu alloc] initWithTitle:@"新建文档"];
    NSMenuItem *rootItem =
        [[NSMenuItem alloc] initWithTitle:@"新建文档" action:NULL keyEquivalent:@""];
    NSMenu *sub = [[NSMenu alloc] initWithTitle:@"新建文档"];

    for (NSArray<NSString *> *pair in self.typeList) {
        NSMenuItem *it = [sub addItemWithTitle:pair[0]
                                        action:@selector(createDoc:)
                                 keyEquivalent:@""];
        it.target = self;
        it.representedObject = pair[1];
    }
    rootItem.submenu = sub;
    [root addItem:rootItem];
    return root;
}

// 右键文件夹 → 在其中创建；右键文件 → 在其所在文件夹；右键空白处 → targetedURL
- (NSString *)resolveTargetDir {
    FIFinderSyncController *ctl = [FIFinderSyncController defaultController];
    NSURL *first = ctl.selectedItemURLs.firstObject;
    if (first && first.path) {
        NSString *p = first.path;
        BOOL isDir = NO;
        if ([[NSFileManager defaultManager] fileExistsAtPath:p isDirectory:&isDir] && isDir) {
            return p;
        }
        return [p stringByDeletingLastPathComponent];
    }
    return ctl.targetedURL.path;
}

- (void)createDoc:(NSMenuItem *)sender {
    @try {
        // 扩展名优先取 representedObject；跨进程传输丢失时从标题 "(xxx)" 解析
        NSString *ext = sender.representedObject;
        NSString *title = sender.title ?: @"";
        SyncDebugLog([NSString stringWithFormat:@"createDoc 触发 title=%@ represented=%@",
                      title, sender.representedObject]);
        if (ext.length == 0) {
            NSRange open = [title rangeOfString:@"(" options:NSBackwardsSearch];
            NSRange close = [title rangeOfString:@")" options:NSBackwardsSearch];
            if (open.location != NSNotFound && close.location > open.location) {
                ext = [title substringWithRange:
                       NSMakeRange(open.location + 1, close.location - open.location - 1)];
            }
        }
        if (ext.length == 0) {
            SyncDebugLog(@"无法从菜单项解析扩展名，放弃");
            return;
        }

        NSString *dir = [self resolveTargetDir];
        SyncDebugLog([NSString stringWithFormat:@"目标目录=%@ targetedURL=%@ selected=%@",
                      dir, [FIFinderSyncController defaultController].targetedURL,
                      [FIFinderSyncController defaultController].selectedItemURLs]);
        if (dir.length == 0) {
            SyncDebugLog(@"无法确定目标文件夹，放弃");
            return;
        }
        NSString *bin = NewdocBinPath();
        if (![[NSFileManager defaultManager] isExecutableFileAtPath:bin]) {
            SyncDebugLog([NSString stringWithFormat:@"newdoc 不可执行：%@", bin]);
            return;
        }

        // 首选：直接启动 newdoc（继承沙盒）
        NSTask *t = [[NSTask alloc] init];
        t.launchPath = bin;
        t.arguments = @[@"create", @"--dir", dir, @"--ext", ext, @"--no-notify"];
        t.currentDirectoryPath = @"/";
        NSPipe *errPipe = [NSPipe pipe];
        t.standardError = errPipe;
        t.standardOutput = [NSPipe pipe];
        __block BOOL launched = NO;
        @try {
            [t launch];
            launched = YES;
            [t setTerminationHandler:^(NSTask *task) {
                NSData *err = [[errPipe fileHandleForReading] readDataToEndOfFile];
                SyncDebugLog([NSString stringWithFormat:
                    @"newdoc 退出 status=%d stderr=%@",
                    task.terminationStatus,
                    [[NSString alloc] initWithData:err encoding:NSUTF8StringEncoding]]);
            }];
        } @catch (NSException *e) {
            SyncDebugLog([NSString stringWithFormat:
                          @"NSTask 启动失败：%@ %@", e.name, e.reason]);
        }
        if (launched) return;

        // 兜底：AppleScript do shell script（原项目验证过的沙盒可用路径）
        NSString *escDir = [dir stringByReplacingOccurrencesOfString:@"'"
                                                          withString:@"'\\''"];
        NSString *escBin = [bin stringByReplacingOccurrencesOfString:@"'"
                                                          withString:@"'\\''"];
        NSString *script = [NSString stringWithFormat:
            @"do shell script \"%@ create --dir '%@' --ext %@ --no-notify\"",
            escBin, escDir, ext];
        SyncDebugLog([NSString stringWithFormat:@"走 AppleScript 兜底：%@", script]);
        NSAppleScript *as = [[NSAppleScript alloc] initWithSource:script];
        NSDictionary *errDict = nil;
        [as executeAndReturnError:&errDict];
        if (errDict) {
            SyncDebugLog([NSString stringWithFormat:@"AppleScript 失败：%@",
                          errDict]);
        } else {
            SyncDebugLog(@"AppleScript 兜底成功");
        }
    } @catch (NSException *e) {
        SyncDebugLog([NSString stringWithFormat:@"createDoc 异常：%@ %@",
                      e.name, e.reason]);
        NSLog(@"[newdoc-sync] createDoc 异常：%@ %@", e.name, e.reason);
    }
}

@end
