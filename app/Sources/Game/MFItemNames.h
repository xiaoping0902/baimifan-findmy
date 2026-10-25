// MFItemNames.h — 物品 ID → 中文名（自动生成，勿手改）
//
// 数据来源：《内置字典ID对应表》（891 条），从中提取 ID 与中文名。
// 用途：手持武器、头/甲/包显示真实名字，而不是裸 ID。

#import <Foundation/Foundation.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

/// 按物品 ID 查中文名；查不到返回 NULL
const char * _Nullable MFItemNameForID(uint64_t itemId);

/// 表内条目数
int MFItemNameCount(void);

NS_ASSUME_NONNULL_END
