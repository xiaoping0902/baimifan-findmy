//
//  MFBones.mm — 真骨骼读取（实现）
//
//  索引表按「骨头总数」选，表本身照抄参考项目 jni/src/esp.h 的 EspBone::GetIndices
//  （那套表是它对多个 UE4 人形骨架实测出来的；三角洲同为 UE4 人形，先用它试，
//   读到的点过不了几何校验就回退占位骨架 —— 不会画出乱七八糟的线）。
//
#import "MFBones.h"
#import "MFUEOffsets.h"
#import "../Read/MFReadBackend.h"
#include <math.h>

static NSString *gMFBoneErr = nil;
static int gMFBoneCount = 0;

NSString *MFBoneLastError(void) { return gMFBoneErr; }
int MFBoneLastCount(void) { return gMFBoneCount; }

/* 偏移（SDK dump） */
static const uint64_t kMeshOffset        = 0x03D0;   /* ACharacter::Mesh */
static const uint64_t kBoneArrayOffset   = 0x0A18;   /* CachedComponentSpaceTransforms */
static const uint64_t kBoneStride        = 0x30;     /* sizeof(FTransform) */
static const uint64_t kC2WOffset         = 0x0210;   /* USceneComponent::ComponentToWorld */
static const uint64_t kTransformTrans    = 0x10;     /* FTransform::translation */

/* 15 条连线（同参考实现） */
static const int kLinks[14][2] = {
    {0,1},{1,2},{1,3},{3,5},{5,7},{1,4},{4,6},{6,8},
    {2,9},{9,11},{11,13},{2,10},{10,12},{12,14}
};

void MFBoneLinks(const int **links, int *count) {
    if (links) *links = &kLinks[0][0];
    if (count) *count = 14;
}

typedef struct { int idx[15]; } MFBoneTable;

/* 照抄 EspBone::GetIndices 的 16 张表 */
static const int T68[15] = {5,4,1,11,33,12,34,13,35,55,59,56,60,57,61};
static const int T70[15] = {5,4,1,6,34,7,35,8,36,55,59,56,60,57,61};
static const int T72[15] = {5,4,1,12,34,13,35,14,36,57,61,58,62,59,63};
static const int T63[15] = {5,4,0,8,30,9,31,10,32,50,54,51,55,52,56};
static const int T64[15] = {5,4,0,7,29,8,30,9,31,51,57,52,58,53,59};
static const int T38[15] = {5,4,0,7,17,9,19,11,21,27,34,28,35,30,36};
static const int T30[15] = {5,4,0,9,14,10,15,11,16,18,22,19,23,20,24};
static const int T26[15] = {5,4,0,13,6,14,7,15,8,21,18,22,19,23,20};
static const int T27[15] = {5,4,0,7,10,8,11,9,12,14,18,15,19,16,20};
static const int T46[15] = {5,4,0,21,8,22,9,23,10,35,40,36,41,38,44};
static const int T42[15] = {16,15,0,20,31,21,32,22,33,3,8,4,9,5,10};
static const int T76[15] = {5,4,0,7,27,8,28,9,29,48,52,49,53,50,54};
static const int T61[15] = {5,4,0,6,27,7,28,8,29,48,52,49,53,50,54};
static const int T73[15] = {5,4,1,12,34,13,35,14,36,57,61,58,62,59,63};
static const int T71[15] = {5,4,1,6,34,7,35,8,36,55,59,56,60,57,61};
static const int T69[15] = {5,4,1,11,33,12,34,13,35,55,59,56,60,57,61};
static const int T65[15] = {5,4,1,11,32,12,33,13,34,52,56,53,57,54,58};

static const int *MFBoneTableFor(int n) {
    switch (n) {
        case 68: return T68;
        case 70: return T70;
        case 72: return T72;
        case 63: return T63;
        case 64: return T64;
        case 38: return T38;
        case 30: return T30;
        case 26: return T26;
        case 27: return T27;
        case 46: return T46;
        case 42: return T42;
        case 76: return T76;
        case 61: return T61;
        case 73: return T73;
        case 71: return T71;
        case 69: return T69;
        case 65: return T65;
        default: return NULL;
    }
}

/// 四元数旋转：out = q * v
static void MFBoneRotate(const float q[4], const float v[3], float out[3]) {
    const float x = q[0], y = q[1], z = q[2], w = q[3];
    /* t = 2 * cross(q.xyz, v) */
    const float tx = 2.0f * (y * v[2] - z * v[1]);
    const float ty = 2.0f * (z * v[0] - x * v[2]);
    const float tz = 2.0f * (x * v[1] - y * v[0]);
    /* v' = v + w*t + cross(q.xyz, t) */
    out[0] = v[0] + w * tx + (y * tz - z * ty);
    out[1] = v[1] + w * ty + (z * tx - x * tz);
    out[2] = v[2] + w * tz + (x * ty - y * tx);
}

static BOOL MFBoneFinite(float v) {
    return isfinite(v) && fabsf(v) < 1.0e7f;
}

BOOL MFBoneReadWorld(uint64_t actor, float out[kMFBoneCount][3]) {
    gMFBoneErr = nil;
    gMFBoneCount = 0;
    if (!MFUEIsValidPtr(actor)) { gMFBoneErr = @"actor 指针非法"; return NO; }
    if (!out) return NO;

    MFReadBackend *rb = [MFReadBackend shared];

    uint64_t mesh = 0;
    if (![rb readU64:actor + kMeshOffset out:&mesh] || !MFUEIsValidPtr(mesh)) {
        gMFBoneErr = @"Actor+0x3D0 不是合法 Mesh";
        return NO;
    }

    uint64_t data = 0;
    int32_t num = 0;
    if (![rb readU64:mesh + kBoneArrayOffset out:&data] ||
        ![rb readRemote:mesh + kBoneArrayOffset + 8 into:&num size:4]) {
        gMFBoneErr = @"TArray 头读取失败";
        return NO;
    }
    gMFBoneCount = (int)num;
    if (!MFUEIsValidPtr(data) || num <= 0 || num > 256) {
        gMFBoneErr = [NSString stringWithFormat:@"骨骼数组非法 data=0x%llx num=%d", data, num];
        return NO;
    }

    const int *table = MFBoneTableFor((int)num);
    if (!table) {
        gMFBoneErr = [NSString stringWithFormat:@"骨数 %d 没有对应索引表", num];
        return NO;
    }

    /* 组件世界变换 */
    float c2wQ[4] = {0, 0, 0, 1};
    float c2wT[3] = {0, 0, 0};
    if (![rb readRemote:mesh + kC2WOffset into:c2wQ size:16] ||
        ![rb readRemote:mesh + kC2WOffset + kTransformTrans into:c2wT size:12]) {
        gMFBoneErr = @"ComponentToWorld 读取失败";
        return NO;
    }

    float minZ = 1.0e9f, maxZ = -1.0e9f;
    for (int i = 0; i < kMFBoneCount; i++) {
        int idx = table[i];
        if (idx < 0 || idx >= num) { gMFBoneErr = @"索引越界"; return NO; }

        float local[3] = {0, 0, 0};
        if (![rb readRemote:data + (uint64_t)idx * kBoneStride + kTransformTrans
                      into:local size:12]) {
            gMFBoneErr = @"骨骼变换读取失败";
            return NO;
        }
        if (!MFBoneFinite(local[0]) || !MFBoneFinite(local[1]) || !MFBoneFinite(local[2])) {
            gMFBoneErr = @"骨骼坐标非有限值";
            return NO;
        }

        float rot[3];
        MFBoneRotate(c2wQ, local, rot);
        out[i][0] = rot[0] + c2wT[0];
        out[i][1] = rot[1] + c2wT[1];
        out[i][2] = rot[2] + c2wT[2];

        if (out[i][2] < minZ) minZ = out[i][2];
        if (out[i][2] > maxZ) maxZ = out[i][2];
    }

    /* 几何校验：人形身高应在 1.0~2.6m 之间 */
    const float height = maxZ - minZ;
    if (!(height > 100.0f && height < 260.0f)) {
        gMFBoneErr = [NSString stringWithFormat:@"身高异常 %.0fcm（索引表可能不匹配）", height];
        return NO;
    }
    gMFBoneErr = nil;
    return YES;
}
