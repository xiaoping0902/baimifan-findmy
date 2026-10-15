//
//  MFEnvCheck.h — 环境检测
//
//  对照《白米饭补充分析》§4 已核验的「高级设置」8 个标题之一：**环境检测**
//  （三重复核：CFString 对象 + 字符缓冲 + 长度 + Block invoke）
//
//  ⚠️ 分析报告明确写：「环境检测的**完整判定范围尚未还原**」。
//     所以这里是按「一个这类工具真正需要知道的运行环境」来设计的，
//     不声称与作者原版逐项一致。每条都标明它检测什么、依据是什么。
//
//  用途：装机后第一件事跑一遍，把「为什么某个功能不好使」的原因一次性列出来。
//
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, MFEnvStatus) {
    MFEnvStatusPass = 0,    // ✓ 正常
    MFEnvStatusWarn,        // ⚠ 能跑但有问题
    MFEnvStatusFail,        // ✗ 不可用
    MFEnvStatusInfo,        // · 仅供参考
};

@interface MFEnvItem : NSObject
@property (nonatomic, copy)   NSString *name;      // 检测项名
@property (nonatomic, copy)   NSString *value;     // 结果值
@property (nonatomic, copy)   NSString *detail;    // 说明 / 依据
@property (nonatomic, assign) MFEnvStatus status;
@end

@interface MFEnvCheck : NSObject

+ (instancetype)shared;

/// 跑全部检测（同步，约几十毫秒）。返回 MFEnvItem 数组。
- (NSArray<MFEnvItem *> *)run;

/// 纯文本报告（可直接复制/导出）
- (NSString *)report;

/// 一行摘要，例如「环境 9/11 通过 · 2 项警告」
- (NSString *)summaryLine;

@end

NS_ASSUME_NONNULL_END
