//
//  MFModuleExport.mm — 游戏模块导出（实现）
//
#import "MFModuleExport.h"

#import <fcntl.h>
#import <unistd.h>
#import <sys/stat.h>
#import <sys/mman.h>
#include <string.h>

NSString * const MFModuleExportDir = @"/var/mobile/Media/mf-debug/modules";

// App 容器根（TrollStore / 正常安装都一样）
static NSString * const kMFAppContainerRoot = @"/var/containers/Bundle/Application";

// Mach-O 常量
static const uint32_t kMFMachMagic32      = 0xFEEDFACEu;
static const uint32_t kMFMachMagic64      = 0xFEEDFACFu;
static const uint32_t kMFMachCigam32      = 0xCEFAEDFEu;
static const uint32_t kMFMachCigam64      = 0xCFFAEDFEu;
static const uint32_t kMFFatMagic         = 0xCAFEBABEu;   // 大端
static const uint32_t kMFLCEncryptionInfo   = 0x21;
static const uint32_t kMFLCEncryptionInfo64 = 0x2C;

@implementation MFAppModule
- (NSString *)summaryLine {
    NSString *sizeText;
    double mb = self.size / (1024.0 * 1024.0);
    if (mb >= 1.0) sizeText = [NSString stringWithFormat:@"%8.1f MB", mb];
    else           sizeText = [NSString stringWithFormat:@"%8.0f KB", self.size / 1024.0];

    NSString *kind = self.isMachO ? (self.arch ?: @"Mach-O") : @"非 Mach-O";
    NSString *lock = !self.isMachO ? @""
                  : (self.encrypted ? @"🔒 加密(FairPlay)" : @"✅ 未加密");
    return [NSString stringWithFormat:@"%@  %-22s  %@  %@%@",
            sizeText, kind.UTF8String, lock, self.relativePath,
            self.note.length ? [@"  " stringByAppendingString:self.note] : @""];
}
@end

#pragma mark - Mach-O 检查

/// 解析 Mach-O 头，填 arch / encrypted / isMachO。只读文件头，不读整个文件。
static void MFInspectMachO(NSString *path, MFAppModule *m, unsigned long long fileSize) {
    int fd = open(path.fileSystemRepresentation, O_RDONLY);
    if (fd < 0) return;

    uint8_t head[64];
    ssize_t got = pread(fd, head, sizeof(head), 0);
    if (got < 32) { close(fd); return; }

    uint32_t magic = *(const uint32_t *)head;
    BOOL is64 = NO;
    uint32_t ncmds = 0, sizeofcmds = 0;
    off_t cmdOffset = 0;

    if (magic == kMFMachMagic64 || magic == kMFMachCigam64) {
        is64 = YES;
        ncmds      = *(const uint32_t *)(head + 16);
        sizeofcmds = *(const uint32_t *)(head + 20);
        cmdOffset  = 32;
    } else if (magic == kMFMachMagic32 || magic == kMFMachCigam32) {
        ncmds      = *(const uint32_t *)(head + 16);
        sizeofcmds = *(const uint32_t *)(head + 20);
        cmdOffset  = 28;
    } else if (magic == kMFFatMagic) {
        // FAT 头是大端
        uint32_t count = __builtin_bswap32(*(const uint32_t *)(head + 4));
        if (count == 0) { close(fd); return; }
        uint32_t sliceOff  = __builtin_bswap32(*(const uint32_t *)(head + 8));
        uint32_t sliceArch = __builtin_bswap32(*(const uint32_t *)(head + 12));

        uint8_t sh[32];
        if (pread(fd, sh, sizeof(sh), sliceOff) != (ssize_t)sizeof(sh)) { close(fd); return; }
        uint32_t sm = *(const uint32_t *)sh;
        if (sm != kMFMachMagic64 && sm != kMFMachMagic32) { close(fd); return; }
        is64 = (sm == kMFMachMagic64);
        ncmds      = *(const uint32_t *)(sh + 16);
        sizeofcmds = *(const uint32_t *)(sh + 20);
        cmdOffset  = sliceOff + (is64 ? 32 : 28);

        const char *an = (sliceArch == 0x0100000C) ? "arm64" : "fat-slice";
        m.arch = [NSString stringWithFormat:@"%s/FAT×%u", an, count];
    } else {
        close(fd);
        return;    // 不是 Mach-O（比如 plist / png / pak）
    }

    m.isMachO = YES;
    if (!m.arch) m.arch = is64 ? @"Mach-O 64" : @"Mach-O 32";

    // 遍历 load commands 找 LC_ENCRYPTION_INFO[_64]
    uint32_t toRead = sizeofcmds;
    if (toRead == 0 || toRead > 256 * 1024) toRead = MIN(sizeofcmds ? sizeofcmds : 4096u, 256u * 1024u);
    uint8_t *cmds = (uint8_t *)malloc(toRead);
    if (!cmds) { close(fd); return; }
    if (pread(fd, cmds, toRead, cmdOffset) != (ssize_t)toRead) { free(cmds); close(fd); return; }

    const uint8_t *p = cmds;
    const uint8_t *end = cmds + toRead;
    BOOL foundEncryptionCommand = NO;
    for (uint32_t i = 0; i < ncmds && p + 8 <= end; i++) {
        uint32_t cmd = *(const uint32_t *)p;
        uint32_t cmdsize = *(const uint32_t *)(p + 4);
        if (cmdsize < 8 || p + cmdsize > end) break;
        if (cmd == kMFLCEncryptionInfo || cmd == kMFLCEncryptionInfo64) {
            // struct encryption_info_command{,_64}: cmd, cmdsize, cryptoff, cryptsize, cryptid
            uint32_t cryptid = (cmdsize >= 20) ? *(const uint32_t *)(p + 16) : 0;
            uint32_t cryptsize = (cmdsize >= 20) ? *(const uint32_t *)(p + 12) : 0;
            m.encrypted = (cryptid != 0);
            m.note = [NSString stringWithFormat:@"cryptid=%u cryptsize=%u", cryptid, cryptsize];
            foundEncryptionCommand = YES;
            break;
        }
        p += cmdsize;
    }
    free(cmds);
    close(fd);

    if (!foundEncryptionCommand) {
        // 没有这条 command = 从来没有被 FairPlay 加密过
        m.encrypted = NO;
        m.note = @"无 LC_ENCRYPTION_INFO";
    }
}

#pragma mark - 实现

@implementation MFModuleExport

+ (NSString *)exportDirectory {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:MFModuleExportDir]) {
        [fm createDirectoryAtPath:MFModuleExportDir
      withIntermediateDirectories:YES attributes:nil error:NULL];
    }
    chmod(MFModuleExportDir.fileSystemRepresentation, 0755);
    return MFModuleExportDir;
}

+ (NSString *)appBundlePathForIdentifier:(NSString *)bundleID error:(NSString **)error {
    if (bundleID.length == 0) {
        if (error) *error = @"bundle id 为空";
        return nil;
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *listError = nil;
    NSArray<NSString *> *uuids = [fm contentsOfDirectoryAtPath:kMFAppContainerRoot
                                                        error:&listError];
    if (uuids == nil) {
        if (error) *error = [NSString stringWithFormat:
            @"读不到 %@ —— %@（no-sandbox / file-read-data 权限没生效？）",
            kMFAppContainerRoot,
            listError.localizedDescription ?: @"未知原因"];
        return nil;
    }

    for (NSString *uuid in uuids) {
        NSString *dir = [kMFAppContainerRoot stringByAppendingPathComponent:uuid];
        NSArray<NSString *> *items = [fm contentsOfDirectoryAtPath:dir error:NULL];
        for (NSString *item in items) {
            if (![item hasSuffix:@".app"]) continue;
            NSString *appPath = [dir stringByAppendingPathComponent:item];
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
                [appPath stringByAppendingPathComponent:@"Info.plist"]];
            NSString *bid = info[@"CFBundleIdentifier"];
            if ([bid isKindOfClass:NSString.class] && [bid isEqualToString:bundleID]) {
                return appPath;
            }
        }
    }
    if (error) *error = [NSString stringWithFormat:@"没有安装 %@（遍历了 %lu 个容器）",
                         bundleID, (unsigned long)uuids.count];
    return nil;
}

+ (NSArray<MFAppModule *> *)modulesInApp:(NSString *)appPath {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray<MFAppModule *> *out = [NSMutableArray array];

    void (^consider)(NSString *) = ^(NSString *full) {
        NSDictionary *attrs = [fm attributesOfItemAtPath:full error:NULL];
        if (![attrs[NSFileType] isEqual:NSFileTypeRegular]) return;
        MFAppModule *m = [[MFAppModule alloc] init];
        m.path = full;
        m.name = full.lastPathComponent;
        m.relativePath = [full hasPrefix:[appPath stringByAppendingString:@"/"]]
            ? [full substringFromIndex:appPath.length + 1] : full;
        m.size = [attrs[NSFileSize] unsignedLongLongValue];
        MFInspectMachO(full, m, m.size);
        [out addObject:m];
    };

    // ① 主可执行文件
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
        [appPath stringByAppendingPathComponent:@"Info.plist"]];
    NSString *exe = info[@"CFBundleExecutable"];
    NSString *mainBinary = nil;
    if ([exe isKindOfClass:NSString.class] && exe.length) {
        mainBinary = [appPath stringByAppendingPathComponent:exe];
        if ([fm fileExistsAtPath:mainBinary]) consider(mainBinary);
    }

    // ② Frameworks / PlugIns / 顶层 .dylib —— 递归两层，够覆盖 UE4 的布局
    NSMutableArray<NSString *> *stack = [NSMutableArray arrayWithObjects:
        [appPath stringByAppendingPathComponent:@"Frameworks"],
        [appPath stringByAppendingPathComponent:@"PlugIns"], nil];
    NSUInteger guard = 0;
    while (stack.count && guard++ < 4000) {
        NSString *dir = stack.lastObject;
        [stack removeLastObject];
        NSArray<NSString *> *items = [fm contentsOfDirectoryAtPath:dir error:NULL];
        for (NSString *item in items) {
            NSString *full = [dir stringByAppendingPathComponent:item];
            BOOL isDir = NO;
            [fm fileExistsAtPath:full isDirectory:&isDir];
            if (isDir) { [stack addObject:full]; continue; }
            if (mainBinary && [full isEqualToString:mainBinary]) continue;
            consider(full);
        }
    }

    // 大的排前面 —— 要找的 libUE4 一定是最大的那个
    [out sortUsingComparator:^NSComparisonResult(MFAppModule *a, MFAppModule *b) {
        if (a.size == b.size) return NSOrderedSame;
        return (a.size > b.size) ? NSOrderedAscending : NSOrderedDescending;
    }];
    return out;
}

+ (NSString *)scanReportForBundleID:(NSString *)bundleID {
    NSMutableString *s = [NSMutableString string];
    [s appendString:@"复刻版 · 游戏模块扫描\n─────────────────────────────\n\n"];

    NSString *error = nil;
    NSString *appPath = [self appBundlePathForIdentifier:bundleID error:&error];
    if (appPath == nil) {
        [s appendFormat:@"✗ %@\n\n", error ?: @"找不到 App"];
        [s appendString:@"排查：\n"
                      @"· 游戏是否装在这台设备上（bundle id 对不对）\n"
                      @"· 环境检测里 /Applications 是否「✓ 可见 N 项」\n"
                      @"· no-sandbox 权限是否生效\n"];
        return s;
    }
    [s appendFormat:@"App：%@\n\n", appPath];

    NSArray<MFAppModule *> *mods = [self modulesInApp:appPath];
    NSUInteger machoCount = 0, encryptedCount = 0;
    unsigned long long total = 0;
    for (MFAppModule *m in mods) {
        if (m.isMachO) machoCount++;
        if (m.encrypted) encryptedCount++;
        total += m.size;
    }
    [s appendFormat:@"共 %lu 个文件 · Mach-O %lu 个 · 加密 %lu 个 · 合计 %.1f MB\n\n",
     (unsigned long)mods.count, (unsigned long)machoCount,
     (unsigned long)encryptedCount, total / (1024.0 * 1024.0)];

    [s appendString:@"（按体积从大到小；要找的引擎模块就是最大的那个）\n\n"];
    NSUInteger shown = 0;
    for (MFAppModule *m in mods) {
        if (shown++ >= 40) { [s appendFormat:@"… 还有 %lu 个更小的文件\n",
                                              (unsigned long)(mods.count - 40)]; break; }
        [s appendFormat:@"%@\n", [m summaryLine]];
    }

    [s appendString:@"\n结论怎么看：\n"
                  @"· 最大那个往往就是 UE 引擎模块（几百 MB）\n"
                  @"· 标「✅ 未加密」→ 直接导出就能反汇编，不用脱壳\n"
                  @"· 标「🔒 加密(FairPlay)」→ 才需要脱壳工具\n"];
    return s;
}

+ (NSString *)exportFileAtPath:(NSString *)path error:(NSString **)error {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = [self exportDirectory];
    NSString *dst = [dir stringByAppendingPathComponent:path.lastPathComponent];

    if ([fm fileExistsAtPath:dst]) {
        [fm removeItemAtPath:dst error:NULL];
    }
    NSError *copyError = nil;
    if (![fm copyItemAtPath:path toPath:dst error:&copyError]) {
        if (error) *error = copyError.localizedDescription ?: @"拷贝失败";
        return nil;
    }
    // AFC 侧以 mobile 身份读，放宽一点
    chmod(dst.fileSystemRepresentation, 0644);
    return dst;
}

+ (NSString *)exportModulesForBundleID:(NSString *)bundleID
                              minBytes:(unsigned long long)minBytes {
    NSMutableString *s = [NSMutableString string];
    NSString *error = nil;
    NSString *appPath = [self appBundlePathForIdentifier:bundleID error:&error];
    if (appPath == nil) {
        [s appendFormat:@"✗ %@", error ?: @"找不到 App"];
        return s;
    }

    NSArray<MFAppModule *> *mods = [self modulesInApp:appPath];
    NSMutableArray<MFAppModule *> *targets = [NSMutableArray array];
    for (MFAppModule *m in mods) {
        if (!m.isMachO) continue;              // 只导可执行模块
        if (m.size < minBytes) continue;
        [targets addObject:m];
    }
    if (targets.count == 0) {
        [s appendFormat:@"✗ %@ 里没有满足条件的 Mach-O（阈值 %.1f MB）",
                        bundleID, minBytes / (1024.0 * 1024.0)];
        return s;
    }

    [s appendFormat:@"导出到 %@\n\n", [self exportDirectory]];
    unsigned long long done = 0;
    for (MFAppModule *m in targets) {
        NSDate *t0 = [NSDate date];
        NSString *dst = [self exportFileAtPath:m.path error:&error];
        NSTimeInterval dt = -[t0 timeIntervalSinceNow];
        if (dst == nil) {
            [s appendFormat:@"✗ %@ —— %@\n", m.relativePath, error ?: @"失败"];
            continue;
        }
        done += m.size;
        [s appendFormat:@"✓ %@ → %@\n    %.1f MB，%.1f 秒%@\n",
         m.relativePath, dst.lastPathComponent,
         m.size / (1024.0 * 1024.0), dt,
         m.encrypted ? @"（注意：这个是加密的，反汇编前要脱壳）" : @""];
    }
    [s appendFormat:@"\n合计导出 %.1f MB\n", done / (1024.0 * 1024.0)];
    [s appendString:@"\n电脑侧拉取：\n"
                  @"  python -X utf8 -m pymobiledevice3 afc pull /mf-debug/modules <本地目录>\n"];
    return s;
}

@end
