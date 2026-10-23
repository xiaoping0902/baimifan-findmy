//
//  MFExternalFeed.mm — 外部数据源实现（Frida agent → 本机 UDP）
//
#import "MFExternalFeed.h"

#import <arpa/inet.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <fcntl.h>
#import <unistd.h>
#include <errno.h>
#include <float.h>
#include <string.h>

const uint16_t MFExternalFeedDefaultPort = 25000;
const NSTimeInterval MFExternalFeedStaleAfter = 2.0;

// 协议常量（与 dfm_stream.js 必须一致）
static const uint32_t kMFFeedMagic       = 0x4446464D;   // 'MFFD' little-endian
static const uint16_t kMFFeedVersion     = 1;
static const uint32_t kMFFeedHeaderSize  = 44;           // magic(4)+ver(2)+hdr(2)+count(4)+seq(4)+cam(6*4)+flags(4)
static const uint32_t kMFFeedEntitySize  = 20;
static const uint32_t kMFFeedMaxEntities = 2048;
static const uint32_t kMFFeedFlagHasCamera = 1u << 0;

#pragma mark - MFFeedEntity

@implementation MFFeedEntity
- (NSString *)description {
    return [NSString stringWithFormat:@"<feed %.1f,%.1f,%.1f bot=%d dead=%d kind=%d>",
            self.worldX, self.worldY, self.worldZ, self.isBot, self.isDead, self.kind];
}
@end

#pragma mark - MFExternalFeed

@implementation MFExternalFeed {
    int _fd;
    dispatch_source_t _readSource;
    dispatch_queue_t _queue;
    NSMutableArray<MFFeedEntity *> *_entities;
    MFCamera _camera;
    BOOL _hasCamera;
    // 注意：port / packetCount / errorCount / lastSequence 是头文件的 readonly property，
    // 由编译器自动合成 _port / _packetCount / _errorCount / _lastSequence，这里不能重复声明。
    uint64_t _lastPacketTicks;      // 0 = 从未收到
}

+ (instancetype)shared {
    static MFExternalFeed *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[MFExternalFeed alloc] init]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _fd = -1;
        _entities = [NSMutableArray array];
        _queue = dispatch_queue_create("com.mf.externalfeed", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)dealloc { [self stop]; }

#pragma mark - 生命周期

- (BOOL)startOnPort:(uint16_t)port error:(NSString **)error {
    if (_fd >= 0 && _running) return YES;
    if (port == 0) port = MFExternalFeedDefaultPort;
    _port = port;

    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) {
        if (error) *error = [NSString stringWithFormat:@"socket() errno=%d", errno];
        return NO;
    }

    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    // 收缓冲给大一点，避免高频推流时丢包
    int rcvbuf = 1 << 20;
    setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof(rcvbuf));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);   // 只听回环：Frida agent 在同一设备上

    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        int e = errno;
        close(fd);
        if (error) *error = [NSString stringWithFormat:@"bind(127.0.0.1:%u) errno=%d", port, e];
        return NO;
    }
    // 非阻塞
    int flags = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);

    _fd = fd;
    _readSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, _queue);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_readSource, ^{
        [weakSelf drain];
    });
    dispatch_source_set_cancel_handler(_readSource, ^{
        close(fd);
    });
    dispatch_resume(_readSource);

    NSLog(@"[MF][Feed] 外部数据源监听 127.0.0.1:%u", port);
    return YES;
}

- (void)stop {
    if (_readSource) {
        dispatch_source_cancel(_readSource);
        _readSource = nil;
    }
    if (_fd >= 0) {
        // cancel handler 会 close；这里只清标记
        _fd = -1;
    }
    @synchronized (self) {
        [_entities removeAllObjects];
        _hasCamera = NO;
    }
}

- (BOOL)running { return _fd >= 0; }

#pragma mark - 收包

- (void)drain {
    if (_fd < 0) return;

    // 单帧最大：header + 2048 * 20 = 41000 字节；留足缓冲
    uint8_t buf[65536];
    for (int i = 0; i < 64; i++) {          // 一次最多处理 64 个包，防饿死
        ssize_t n = recv(_fd, buf, sizeof(buf), 0);
        if (n <= 0) break;
        [self decode:buf length:(NSUInteger)n];
    }
}

- (void)decode:(const uint8_t *)buf length:(NSUInteger)len {
    if (len < kMFFeedHeaderSize) { _errorCount++; return; }

    uint32_t magic;
    memcpy(&magic, buf + 0, 4);
    if (magic != kMFFeedMagic) { _errorCount++; return; }

    uint16_t version, headerSize;
    memcpy(&version, buf + 4, 2);
    memcpy(&headerSize, buf + 6, 2);
    if (version != kMFFeedVersion || headerSize < kMFFeedHeaderSize) { _errorCount++; return; }

    uint32_t count, seq, flags;
    memcpy(&count, buf + 8, 4);
    memcpy(&seq, buf + 12, 4);
    if (count > kMFFeedMaxEntities) { _errorCount++; return; }

    NSUInteger need = headerSize + (NSUInteger)count * kMFFeedEntitySize;
    if (len < need) { _errorCount++; return; }

    float cam[6];
    memcpy(cam, buf + 16, sizeof(cam));     // camX,Y,Z,pitch,yaw,fov
    memcpy(&flags, buf + 40, 4);

    NSMutableArray<MFFeedEntity *> *list = [NSMutableArray arrayWithCapacity:count];
    const uint8_t *p = buf + headerSize;
    for (uint32_t i = 0; i < count; i++, p += kMFFeedEntitySize) {
        MFFeedEntity *e = [[MFFeedEntity alloc] init];
        float vx, vy, vz;
        uint32_t cid;
        memcpy(&vx, p + 0, 4);
        memcpy(&vy, p + 4, 4);
        memcpy(&vz, p + 8, 4);
        memcpy(&cid, p + 16, 4);
        e.worldX = vx;
        e.worldY = vy;
        e.worldZ = vz;
        e.isBot  = (p[12] != 0);
        e.isDead = (p[13] != 0);
        e.kind   = p[14];
        e.classId = cid;
        [list addObject:e];
    }

    MFCamera camera = {0};
    camera.x = cam[0]; camera.y = cam[1]; camera.z = cam[2];
    camera.pitch = cam[3]; camera.yaw = cam[4]; camera.roll = 0;
    camera.fov = cam[5];

    @synchronized (self) {
        _entities = list;
        _camera = camera;
        _hasCamera = (flags & kMFFeedFlagHasCamera) != 0;
        _lastSequence = seq;
        _packetCount++;
        struct timespec ts;
        clock_gettime(CLOCK_MONOTONIC, &ts);
        _lastPacketTicks = (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
    }
}

#pragma mark - 查询

- (NSTimeInterval)lastPacketAge {
    uint64_t last;
    @synchronized (self) { last = _lastPacketTicks; }
    if (last == 0) return DBL_MAX;
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    uint64_t now = (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
    if (now <= last) return 0;
    return (NSTimeInterval)(now - last) / 1e9;
}

- (BOOL)fresh { return [self lastPacketAge] <= MFExternalFeedStaleAfter; }

- (NSArray<MFFeedEntity *> *)snapshotEntities {
    @synchronized (self) { return [_entities copy]; }
}

- (BOOL)snapshotCamera:(MFCamera *)outCamera {
    @synchronized (self) {
        if (!_hasCamera) return NO;
        if (outCamera) *outCamera = _camera;
        return YES;
    }
}

- (uint32_t)lastSequence {
    @synchronized (self) { return _lastSequence; }
}

- (NSUInteger)packetCount { @synchronized (self) { return _packetCount; } }
- (NSUInteger)errorCount  { @synchronized (self) { return _errorCount; } }

- (NSString *)statusText {
    if (!self.running) return @"未监听";
    if (!self.fresh) {
        return [NSString stringWithFormat:@"等待 Frida（%lu 包 · %lu 错）",
                (unsigned long)self.packetCount, (unsigned long)self.errorCount];
    }
    NSTimeInterval age = [self lastPacketAge];
    return [NSString stringWithFormat:@"已连接 · %lu 包 · %.0fms 前 · seq=%u",
            (unsigned long)self.packetCount, age * 1000.0, self.lastSequence];
}

@end
