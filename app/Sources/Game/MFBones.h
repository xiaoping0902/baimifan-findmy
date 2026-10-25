//
//  MFBones.h — 真骨骼（ComponentSpaceTransforms 路径）
//
//  链路（全部取自 SDK 1.201.37117 的 dump，不是猜的）：
//      AActor/APawn + 0x03D0            → ACharacter::Mesh (USkeletalMeshComponent*)
//      Mesh + 0x0A18                    → TArray<FTransform> CachedComponentSpaceTransforms
//                                          { Data@0x0, Num@0x8(int32), Max@0xC }
//      Mesh + 0x210                     → ComponentToWorld (FTransform)
//      数据元素 stride = 0x30，Translation @ +0x10
//
//  世界坐标 = C2W.Translation + C2W.Rotation.Rotate(bone.Translation)
//
//  关节点顺序（与参考项目 jni/src/esp.h 的 EspBone 一致）：
//      [0]头 [1]胸 [2]盆骨 [3]左肩 [4]右肩 [5]左肘 [6]右肘
//      [7]左腕 [8]右腕 [9]左腿 [10]右腿 [11]左膝 [12]右膝 [13]左脚 [14]右脚
//
#import <Foundation/Foundation.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

enum { kMFBoneCount = 15 };

/**
 * 读一个角色的 15 个关节点世界坐标（cm）。
 * 返回 YES 表示读到并通过了几何校验；NO 时 out 内容未定义，调用方应回退到占位骨架。
 */
BOOL MFBoneReadWorld(uint64_t actor, float out[kMFBoneCount][3]);

/// 最近一次失败原因（诊断用，可能为 nil）
NSString * _Nullable MFBoneLastError(void);

/// 最近一次读到的骨骼总数（0 = 没读到）
int MFBoneLastCount(void);

/// 骨骼连线拓扑（14 条）
void MFBoneLinks(const int **links, int *count);

NS_ASSUME_NONNULL_END
