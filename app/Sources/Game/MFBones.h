//
//  MFBones.h — 真骨骼（数据全部来自《完整数据读取清单》并在真机验证通过）
//
//  链路（Frida 现场验证：本地 Pawn 读出 80 根骨、ComponentToWorld 平移正确）：
//      Actor + 0x03D0 → Mesh (USkeletalMeshComponent*)
//      Mesh  + 0x0750 → TArray<FTransform> 骨骼数组 { Data@0, Num@8(int32), Max@12 }
//      Mesh  + 0x0210 → ComponentToWorld（四元数 @0，平移 @0x10）
//      条目 stride = 0x30，取 Translation @ +0x10
//
//  世界坐标 = C2W.Translation + C2W.Rotation.Rotate(bone.Translation)
//
//  19 个关节索引（@0x10062E320，实机 80 骨骨架验证：局部 Z 从 157cm 单调降到 87cm）：
//      [32,30,5,3,2,1,6,7,8,34,35,36,58,59,60,62,63,64,0]
//  17 条连线（@0x10062E40C）：
//      躯干 (0,1)(1,2)(2,3)(3,4)(4,5)   左臂 (2,6)(6,7)(7,8)
//      右臂 (2,9)(9,10)(10,11)          左腿 (5,12)(12,13)(13,14)
//      右腿 (5,15)(15,16)(16,17)
//
#import <Foundation/Foundation.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

enum { kMFBoneCount = 19 };

/**
 * 读一个角色的 19 个关节点世界坐标（cm）。
 * 返回 YES 表示读到并通过了几何校验；NO 时 out 未定义，调用方应回退占位骨架。
 */
BOOL MFBoneReadWorld(uint64_t actor, float out[kMFBoneCount][3]);

/// 最近一次失败原因（诊断用）
NSString * _Nullable MFBoneLastError(void);

/// 最近一次读到的骨骼总数（0 = 没读到）
int MFBoneLastCount(void);

/// 连线表（17 条，每条 2 个索引，顺序排列）
void MFBoneLinks(const int **links, int *count);

NS_ASSUME_NONNULL_END
