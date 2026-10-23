//
//  MFExternalFeed.h — 外部数据源（Frida agent → 本机 UDP）
//
//  ── 为什么需要它 ──
//
//  真机实测（iPad14,4 / iPadOS 16.1 / A15）：
//      task_for_pid(launchd/SpringBoard/游戏) 全部 kr=0x5 KERN_FAILURE
//      processor_set_tasks 全部 kr=0x4 KERN_INVALID_ARGUMENT
//  这是 A12+ / iOS 15+ 的 PPL 在保护 csblob 里的私有 entitlements，
//  跟我们的签名没关系 —— 也就是说【本进程永远拿不到游戏的 task port】。
//
//  但设备已经用 Dopamine 3.0.12 越狱，跑着 frida-server 17.24.3。
//  Frida 用 ptrace(PT_ATTACHEXC) 注入 agent 到游戏进程【内部】，
//  agent 读内存就是读自己的地址空间 —— 这一层完全没有 PPL 限制。
//
//  所以数据通路变成：
//
//      游戏进程
//        └─ Frida agent（dfm_stream.js）
//             读 GWorld → ULevel → Actors → 坐标 / 类名 / bIsPlayerAI
//             ↓ UDP 127.0.0.1:25000（本机回环，零延迟）
//      复刻版 App
//        └─ MFExternalFeed（本类）→ 绘制层
//
//  ── 协议（二进制，小端）──
//
//  Header 44 字节：
//      uint32 magic      = 0x4446464D  ('MFFD')
//      uint16 version    = 1
//      uint16 headerSize = 44
//      uint32 count
//      uint32 seq
//      float  camX, camY, camZ
//      float  camPitch, camYaw, camFov
//      uint32 flags      bit0 = 带相机
//
//  Entity 20 字节 × count：
//      float  x, y, z              世界坐标（和 UE4 的 FVector 一致）
//      uint8  isBot                1 = 人机
//      uint8  isDead
//      uint8  kind                 0=未知 1=人物 2=物资 3=盒子
//      uint8  pad
//      uint32 classId
//
#import <Foundation/Foundation.h>
#import "../Game/MFProjection.h"

NS_ASSUME_NONNULL_BEGIN

/// 默认监听端口（Frida agent 往这里推）
extern const uint16_t MFExternalFeedDefaultPort;
/// 超过这么久没收到包就算“数据过期”，绘制层回退到本地 UE4 链
extern const NSTimeInterval MFExternalFeedStaleAfter;

/// 一帧里的一个实体
@interface MFFeedEntity : NSObject
@property (nonatomic, assign) float worldX, worldY, worldZ;
@property (nonatomic, assign) BOOL isBot;
@property (nonatomic, assign) BOOL isDead;
@property (nonatomic, assign) int kind;          // 0未知 1人物 2物资 3盒子
@property (nonatomic, assign) uint32_t classId;
@end

@interface MFExternalFeed : NSObject

+ (instancetype)shared;

/// 开始监听（幂等）。端口传 0 用 MFExternalFeedDefaultPort。
- (BOOL)startOnPort:(uint16_t)port error:(NSString *_Nullable *_Nullable)error;
- (void)stop;

@property (nonatomic, readonly) BOOL running;
@property (nonatomic, readonly) uint16_t port;
/// 收到过多少包 / 解码失败多少包
@property (nonatomic, readonly) NSUInteger packetCount;
@property (nonatomic, readonly) NSUInteger errorCount;
/// 最近一包距今多少秒（never received 时返回 DBL_MAX）
@property (nonatomic, readonly) NSTimeInterval lastPacketAge;
/// 数据是否新鲜（最近 MFExternalFeedStaleAfter 内收到过）
@property (nonatomic, readonly) BOOL fresh;

/// 最近一帧的实体（拷贝，线程安全）
- (NSArray<MFFeedEntity *> *)snapshotEntities;
/// 最近一帧的相机（hasCamera 为 NO 时结构体未定义）
- (BOOL)snapshotCamera:(MFCamera *)outCamera;
/// 一帧的序号（丢包/乱序观察用）
@property (nonatomic, readonly) uint32_t lastSequence;

/// 给 UI 用的一行状态
- (NSString *)statusText;

@end

NS_ASSUME_NONNULL_END
