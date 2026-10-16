//
//  MFModuleExport.h — 把游戏 App 里的 Mach-O 模块导出到 AFC 够得着的地方
//
//  ── 为什么需要 ──
//
//  要补上血量 / 骨骼 / 武器这些字段，必须拿到游戏的 **libUE4 模块本体**做逆向。
//  它在 /var/containers/Bundle/Application/<UUID>/<App>.app/ 里面，
//  而 AFC（pymobiledevice3 唯一能直接读的通道）只暴露 /var/mobile/Media —— 够不着。
//
//  但我们有 no-sandbox + file-read-data + 全盘读写例外，
//  所以可以让 App **自己**把模块拷到 Media 去，电脑一条命令拉走。
//
//  ── ★ 关键事实：大概率不需要脱壳 ★ ──
//
//  iOS 上 FairPlay 只加密【主可执行文件】。App 包里内嵌的
//  .framework / .dylib / PlugIns 是**不加密**的。
//  UE4 游戏在 iOS 上通常把引擎编成独立 framework（体积几百 MB 的那个就是），
//  所以直接拷贝就能拿去反汇编 —— 不需要 frida-ios-dump / CrackerXI 那一套。
//
//  本文件提供的能力正好用来确认这一点：扫描时会逐条列出
//  每个模块的大小、架构、以及 LC_ENCRYPTION_INFO 的 cryptid。
//    cryptid = 0 → 没加密，直接能用
//    cryptid ≠ 0 → 被 FairPlay 加密，才需要脱壳工具
//
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// AFC 能直接读到的模块导出目录
extern NSString * const MFModuleExportDir;

/// 一个候选模块（Mach-O 文件）
@interface MFAppModule : NSObject
@property (nonatomic, copy) NSString *path;              // 设备上的绝对路径
@property (nonatomic, copy) NSString *name;              // 文件名
@property (nonatomic, copy) NSString *relativePath;      // 相对 .app 的路径
@property (nonatomic, assign) unsigned long long size;
@property (nonatomic, assign) BOOL isMachO;
@property (nonatomic, assign) BOOL encrypted;            // FairPlay cryptid != 0
@property (nonatomic, copy, nullable) NSString *arch;
@property (nonatomic, copy, nullable) NSString *note;
- (NSString *)summaryLine;
@end

@interface MFModuleExport : NSObject

/// 按 bundle id 在 /var/containers/Bundle/Application 下找 .app
+ (nullable NSString *)appBundlePathForIdentifier:(NSString *)bundleID
                                            error:(NSString **)error;

/// 列出 .app 里的全部 Mach-O（主二进制 + Frameworks/** + PlugIns/** + 顶层 .dylib）
+ (NSArray<MFAppModule *> *)modulesInApp:(NSString *)appPath;

/// 人读的扫描报告 —— 找不到 App 时返回可读原因，不抛异常
+ (NSString *)scanReportForBundleID:(NSString *)bundleID;

/// 导出目录（/var/mobile/Media/mf-debug/modules）
+ (NSString *)exportDirectory;

/// 复制一个文件进导出目录，返回目标路径
+ (nullable NSString *)exportFileAtPath:(NSString *)path error:(NSString **)error;

/// 导出指定 bundle 的模块。minBytes 用来滤掉一堆小 dylib（0 = 全部导出）。
/// 同步执行，几百 MB 会慢 —— 调用方放在后台队列。
+ (NSString *)exportModulesForBundleID:(NSString *)bundleID
                              minBytes:(unsigned long long)minBytes;

@end

NS_ASSUME_NONNULL_END
