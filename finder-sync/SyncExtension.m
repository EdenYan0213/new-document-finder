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

static NSString *NewdocBinPath(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:
            @"Library/Application Support/NewDocument/bin/newdoc"];
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
    NSString *cfg = [NSHomeDirectory() stringByAppendingPathComponent:
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
    if (whichMenu != FIMenuKindContextualMenuForContainer &&
        whichMenu != FIMenuKindContextualMenuForItems) {
        return nil;
    }
    // 菜单打开时顺带刷新卷宗与类型（无轮询定时器，零空闲 CPU）
    [self updateDirectoryURLs];
    [self reloadTypesIfNeeded];

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
    NSString *dir = [self resolveTargetDir];
    if (dir.length == 0) {
        NSLog(@"[newdoc-sync] 无法确定目标文件夹");
        return;
    }
    NSString *bin = NewdocBinPath();
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:bin]) {
        NSLog(@"[newdoc-sync] 未找到 newdoc：%@", bin);
        return;
    }
    [NSTask launchedTaskWithLaunchPath:bin
                            arguments:@[@"create", @"--dir", dir,
                                        @"--ext", sender.representedObject]];
}

@end
