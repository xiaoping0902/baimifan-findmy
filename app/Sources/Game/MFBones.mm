//
//  MFBones.mm — 真骨骼读取（实现）
//
//  所有常量都来自《完整数据读取清单》（欧易 2.0 反编译）并在本机真机用 Frida 验证：
//    · Mesh + 0x750 读出 num=80 的骨骼数组，前 6 根局部 Z = 157/141/136/109/94/87
//    · Mesh + 0x210 = ComponentToWorld，平移与 Actor 世界坐标一致
//
#import "MFBones.h"
#import "MFUEOffsets.h"
#include "MFBoneGeometry.h"
#import "../Read/MFReadBackend.h"
#include <math.h>
#include <string.h>   /* memcpy */

static NSString *gMFBoneErr = nil;
static int gMFBoneCount = 0;

NSString *MFBoneLastError(void) { return gMFBoneErr; }
int MFBoneLastCount(void) { return gMFBoneCount; }

static const uint64_t kMeshOffset      = 0x03D0;   /* ACharacter::Mesh */
static const uint64_t kBoneArrayOffset = 0x0750;   /* 骨骼数组（活数组，真机验证） */
static const uint64_t kBoneStride      = 0x30;     /* sizeof(FTransform) */
static const uint64_t kC2WOffset       = 0x0210;   /* ComponentToWorld */
static const uint64_t kTransformTrans  = 0x10;

/* 19 个关节索引（0x10062E320 原样） */
static const int kIndices[kMFBoneCount] = {
    32, 30, 5, 3, 2, 1, 6, 7, 8, 34, 35, 36, 58, 59, 60, 62, 63, 64, 0
};

/* 17 条连线（0x10062E40C 原样，按 (from,to) 顺序展开） */
static const int kLinks[17 * 2] = {
    0,1,  1,2,  2,3,  3,4,  4,5,
    2,6,  6,7,  7,8,
    2,9,  9,10, 10,11,
    5,12, 12,13, 13,14,
    5,15, 15,16, 16,17
};

void MFBoneLinks(const int **links, int *count) {
    if (links) *links = kLinks;
    if (count) *count = 17;
}

static void MFBoneRotate(const float q[4], const float v[3], float out[3]) {
    const float x = q[0], y = q[1], z = q[2], w = q[3];
    const float tx = 2.0f * (y * v[2] - z * v[1]);
    const float ty = 2.0f * (z * v[0] - x * v[2]);
    const float tz = 2.0f * (x * v[1] - y * v[0]);
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
    if (!MFUEIsValidPtr(actor)) { gMFBoneErr = @"actor 非法"; return NO; }
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
        gMFBoneErr = @"骨骼数组头读取失败";
        return NO;
    }
    gMFBoneCount = (int)num;
    if (!MFUEIsValidPtr(data) || num < 20 || num > 256) {
        gMFBoneErr = [NSString stringWithFormat:@"骨骼数组非法 data=%#llx num=%d",
                      data, num];
        return NO;
    }

    float c2wQ[4] = {0, 0, 0, 1};
    float c2wT[3] = {0, 0, 0};
    if (![rb readRemote:mesh + kC2WOffset into:c2wQ size:16] ||
        ![rb readRemote:mesh + kC2WOffset + kTransformTrans into:c2wT size:12]) {
        gMFBoneErr = @"ComponentToWorld 读取失败";
        return NO;
    }
    if (!MFBoneFinite(c2wT[0]) || !MFBoneFinite(c2wT[1]) || !MFBoneFinite(c2wT[2])) {
        gMFBoneErr = @"ComponentToWorld 非有限值";
        return NO;
    }

    /* 一次读把 19 根需要的变换全拿下来（跨度 = (max-min)*0x30 + 0x30，通常 < 4KB） */
    int lo = kIndices[0], hi = kIndices[0];
    for (int i = 1; i < kMFBoneCount; i++) {
        if (kIndices[i] < lo) lo = kIndices[i];
        if (kIndices[i] > hi) hi = kIndices[i];
    }
    if (hi >= num) { gMFBoneErr = @"索引超出骨骼数量"; return NO; }

    const size_t spanBytes = (size_t)(hi - lo + 1) * kBoneStride;
    if (spanBytes > 8192) { gMFBoneErr = @"骨骼跨度太大"; return NO; }

    uint8_t buf[8192];
    if (![rb readRemote:data + (uint64_t)lo * kBoneStride into:buf size:spanBytes]) {
        gMFBoneErr = @"批量读骨骼失败";
        return NO;
    }

    for (int i = 0; i < kMFBoneCount; i++) {
        const uint8_t *p = buf + (size_t)(kIndices[i] - lo) * kBoneStride + kTransformTrans;
        float local[3];
        memcpy(local, p, sizeof(local));
        if (!MFBoneFinite(local[0]) || !MFBoneFinite(local[1]) || !MFBoneFinite(local[2])) {
            gMFBoneErr = @"骨骼坐标非有限值";
            return NO;
        }
        float rot[3];
        MFBoneRotate(c2wQ, local, rot);
        out[i][0] = rot[0] + c2wT[0];
        out[i][1] = rot[1] + c2wT[1];
        out[i][2] = rot[2] + c2wT[2];
    }

    if (!MFBoneGeometryValid(out, kMFBoneCount, kLinks, 17)) {
        gMFBoneErr = @"骨骼空间范围或连线异常";
        return NO;
    }
    gMFBoneErr = nil;
    return YES;
}
