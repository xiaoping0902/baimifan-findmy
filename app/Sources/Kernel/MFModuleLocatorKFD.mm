//
//  MFModuleLocatorKFD.mm — 主模块基址的 KFD 路径（[M5.207]）
//
//  为什么单独一个文件：
//    这条路径要调 mf_pid_chain / mfpt_lowest_mapped_page / mfpt_read，
//    也就是把整个内核桥接与页表层拉进链接。而 tests/run_hud_regressions.sh 里
//    的 hud_binding_native_regressions 只链接 MFModuleLocator.mm + MFHUDPassiveState.mm
//    （故意不碰内核层），把它写在 MFModuleLocator.mm 里会让那个测试报
//    Undefined symbols。
//
//    所以：与内核相关的定位实现放这里，纯端口的旧实现留在 MFModuleLocator.mm。
//    测试不编译本文件；App 侧因为 project.yml 按 Sources 目录 glob，会自动包含。
//
#import "MFModuleLocator.h"

#import <Foundation/Foundation.h>
#import "MFKernelBridge.h"    /* mf_pid_chain：pid → pmap 根表 */
#import "MFPageTable.h"       /* mfpt_read / mfpt_lowest_mapped_page */
#import "../Read/MFReadBackend.h"

@implementation MFModuleLocator (KFD)

+ (MFModuleInfo *)mainModuleForPidViaKFD:(pid_t)pid error:(NSString **)error {
    NSMutableString *rep = [NSMutableString stringWithFormat:
                            @"=== 模块定位（KFD 页表） ===\npid=%d\n", pid];

    if (pid <= 0) {
        if (error) *error = @"pid 无效";
        return nil;
    }

    // ① pmap 根表：已绑定的后端优先，避免重复解析同一进程
    uint64_t root = 0;
    MFReadBackend *backend = [MFReadBackend shared];
    if (backend.kfdPid == pid && backend.kfdRoot != 0) {
        root = backend.kfdRoot;
        [rep appendString:@"✓ 复用已绑定的 KFD 根表\n"];
    } else {
        char why[192] = {0};
        int rc = mf_pid_chain(pid, NULL, NULL, NULL, NULL, &root, why, sizeof(why));
        if (rc != 0 || root == 0) {
            [rep appendFormat:@"✗ mf_pid_chain 失败 rc=%d %s\n", rc, why];
            NSLog(@"[MF][Module][KFD] %@", rep);
            if (error) *error = [NSString stringWithFormat:@"拿不到该进程的 pmap 根表：%s", why];
            return nil;
        }
        [rep appendString:@"✓ 已解析 pmap 根表（未绑定到读取后端）\n"];
    }
    [rep appendFormat:@"  root = %#llx\n", (unsigned long long)root];

    // ② 主程序是进程里最低的映像：从 4GB 起找第一张映射页
    uint64_t base = 0;
    if (mfpt_lowest_mapped_page(root, 0x100000000ULL, &base) != 0 || base == 0) {
        [rep appendString:@"✗ 找不到最低映射页\n"];
        NSLog(@"[MF][Module][KFD] %@", rep);
        if (error) *error = @"页表里找不到最低映射页（目标可能尚未加载主程序）";
        return nil;
    }

    // ③ 校验 Mach-O 头：magic / cputype / filetype 三道都要过
    struct {
        uint32_t magic, cputype, cpusubtype, filetype;
    } mh = {0};
    if (mfpt_read(root, base, &mh, sizeof(mh)) != 0) {
        [rep appendFormat:@"✗ 读 %#llx 的 Mach-O 头失败\n", (unsigned long long)base];
        NSLog(@"[MF][Module][KFD] %@", rep);
        if (error) *error = @"读主模块头失败";
        return nil;
    }
    [rep appendFormat:@"  候选基址 %#llx: magic=%#x cputype=%#x filetype=%u\n",
        (unsigned long long)base, mh.magic, mh.cputype, mh.filetype];

    const uint32_t kMHMagic64 = 0xfeedfacf;
    const uint32_t kCPUTypeARM64 = 0x0100000c;
    const uint32_t kMHExecute = 2;
    const uint32_t kMHFileset = 0xc;
    if (mh.magic != kMHMagic64 || mh.cputype != kCPUTypeARM64 ||
        (mh.filetype != kMHExecute && mh.filetype != kMHFileset)) {
        [rep appendString:@"✗ 该页不是 arm64 Mach-O 主映像，拒绝当作模块基址\n"];
        NSLog(@"[MF][Module][KFD] %@", rep);
        if (error) *error = @"最低映射页不是 arm64 Mach-O 主映像";
        return nil;
    }

    MFModuleInfo *m = [[MFModuleInfo alloc] init];
    m.base = base;
    m.path = @"(KFD 未解析路径)";
    m.name = mh.filetype == kMHFileset ? @"(fileset 主映像)" : @"(主可执行映像)";
    m.size = 0;
    m.isMain = YES;

    [rep appendFormat:@"\n=== 判定结果 ===\n基址：%#llx\n依据：最低映射页 + Mach-O 头校验\n",
        (unsigned long long)base];
    NSLog(@"[MF][Module][KFD] %@\n主模块 base=0x%llx",
          rep, (unsigned long long)base);
    return m;
}

@end
