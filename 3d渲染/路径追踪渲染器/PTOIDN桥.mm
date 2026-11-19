//
//  PTOIDN桥.mm
//  OpenImageDenoise 2.5.1 · Metal 后端零拷贝封装。
//  filter / OIDNBuffer 全部缓存，stready-state 单次降噪只花一次 GPU 提交。
//

#import "PTOIDN桥.h"
#include <OpenImageDenoise/oidn.h>
#include <stdio.h>

static inline int oidnQualityValue(PTOIDNQuality q) {
    switch (q) {
        case PTOIDNQualityFast: return OIDN_QUALITY_FAST;
        case PTOIDNQualityBalanced: return OIDN_QUALITY_BALANCED;
        case PTOIDNQualityHigh: return OIDN_QUALITY_HIGH;
    }
    return OIDN_QUALITY_BALANCED;
}

@implementation PTOIDNDenoiser {
    OIDNDevice _device;
    OIDNFilter _filter;
    OIDNBuffer _bufColor;
    OIDNBuffer _bufAlbedo;
    OIDNBuffer _bufNormal;
    OIDNBuffer _bufOutput;
    void *_wrappedColor;
    void *_wrappedAlbedo;
    void *_wrappedNormal;
    void *_wrappedOutput;
    NSUInteger _width;
    NSUInteger _height;
    int _committedQuality;
    BOOL _useMetal;
    NSString *_backendName;
    BOOL _failed;
}

- (nullable instancetype)initWithCommandQueue:(id<MTLCommandQueue>)queue
                                        width:(NSUInteger)width
                                       height:(NSUInteger)height
{
    self = [super init];
    if (!self) return nil;

    _width = width;
    _height = height;
    _committedQuality = -1;
    _backendName = @"none";

    if (width == 0 || height == 0) return nil;

    // 1) 优先 Metal 后端：直接吃 MTLBuffer，零拷贝，与渲染队列天然同序
    if (queue != nil) {
        __unsafe_unretained id<MTLCommandQueue> queueRef = queue;
        _device = oidnNewMetalDevice(&queueRef, 1);
        if (_device != NULL) {
            oidnCommitDevice(_device);
            const char *msg = NULL;
            if (oidnGetDeviceError(_device, &msg) == OIDN_ERROR_NONE) {
                _useMetal = YES;
                _backendName = @"metal";
            } else {
                fprintf(stderr, "[OIDN] metal device unusable: %s\n", msg ? msg : "?");
                oidnReleaseDevice(_device);
                _device = NULL;
            }
        }
    }

    // 2) 退路：CPU 后端不可用（private 缓冲拿不到主机指针），由调用方降级为不降噪输出
    if (_device == NULL) {
        fprintf(stderr, "[OIDN] no metal backend, denoiser disabled\n");
        _failed = YES;
        return self;
    }

    _filter = oidnNewFilter(_device, "RT");
    if (_filter == NULL) {
        fprintf(stderr, "[OIDN] filter creation failed\n");
        _failed = YES;
        return self;
    }

    // 3) 预建 4 个 OIDNBuffer（尺寸固定，绑定目标缓冲时再 wrap）
    size_t bytes = (size_t)width * (size_t)height * 3 * sizeof(float);
    _bufColor = oidnNewBuffer(_device, bytes);
    _bufAlbedo = oidnNewBuffer(_device, bytes);
    _bufNormal = oidnNewBuffer(_device, bytes);
    _bufOutput = oidnNewBuffer(_device, bytes);
    if (_bufColor == NULL || _bufAlbedo == NULL || _bufNormal == NULL || _bufOutput == NULL) {
        fprintf(stderr, "[OIDN] buffer allocation failed\n");
        _failed = YES;
        return self;
    }
    return self;
}

- (NSString *)backendName {
    return _backendName;
}

- (void)dealloc {
    if (_bufColor) oidnReleaseBuffer(_bufColor);
    if (_bufAlbedo) oidnReleaseBuffer(_bufAlbedo);
    if (_bufNormal) oidnReleaseBuffer(_bufNormal);
    if (_bufOutput) oidnReleaseBuffer(_bufOutput);
    if (_filter) oidnReleaseFilter(_filter);
    if (_device) oidnReleaseDevice(_device);
}

/// 把 MTLBuffer 临时包成 OIDNBuffer（零拷贝，只共享底层存储）。
/// 返回 0 = 失败，1 = 复用原有包装，2 = 重新包装（需要重设 filter 图像）。
- (int)bindBuffer:(id<MTLBuffer>)buffer
             cache:(OIDNBuffer *)cacheSlot
          wrapped:(void **)wrappedSlot
        imageName:(const char *)imageName
{
    if (buffer == nil) return 0;
    void *ptr = (__bridge void *)buffer;
    if (*cacheSlot != NULL && *wrappedSlot == ptr) return 1;
    {
        if (*cacheSlot != NULL) {
            oidnReleaseBuffer(*cacheSlot);
            *cacheSlot = NULL;
        }
        OIDNBuffer fresh = oidnNewSharedBufferFromMetal(_device, buffer);
        if (fresh == NULL) {
            fprintf(stderr, "[OIDN] wrap %s failed\n", imageName);
            return 0;
        }
        *cacheSlot = fresh;
        *wrappedSlot = ptr;
    }
    return 2;
}

- (BOOL)denoiseColor:(id<MTLBuffer>)color
              albedo:(id<MTLBuffer>)albedo
              normal:(id<MTLBuffer>)normal
              output:(id<MTLBuffer>)output
             quality:(PTOIDNQuality)quality
         synchronize:(BOOL)synchronize
{
    if (_failed || _device == NULL || _filter == NULL) return NO;
    if (!_useMetal) return NO;

    int c1 = [self bindBuffer:color  cache:&_bufColor  wrapped:&_wrappedColor  imageName:"color"];
    int c2 = [self bindBuffer:albedo cache:&_bufAlbedo wrapped:&_wrappedAlbedo imageName:"albedo"];
    int c3 = [self bindBuffer:normal cache:&_bufNormal wrapped:&_wrappedNormal imageName:"normal"];
    int c4 = [self bindBuffer:output cache:&_bufOutput wrapped:&_wrappedOutput imageName:"output"];
    if (c1 == 0 || c2 == 0 || c3 == 0 || c4 == 0) return NO;

    int q = oidnQualityValue(quality);
    BOOL rebind = (c1 == 2 || c2 == 2 || c3 == 2 || c4 == 2);
    if (rebind || q != _committedQuality) {
        oidnSetFilterImage(_filter, "color", _bufColor, OIDN_FORMAT_FLOAT3, _width, _height, 0, 0, 0);
        oidnSetFilterImage(_filter, "albedo", _bufAlbedo, OIDN_FORMAT_FLOAT3, _width, _height, 0, 0, 0);
        oidnSetFilterImage(_filter, "normal", _bufNormal, OIDN_FORMAT_FLOAT3, _width, _height, 0, 0, 0);
        oidnSetFilterImage(_filter, "output", _bufOutput, OIDN_FORMAT_FLOAT3, _width, _height, 0, 0, 0);
        oidnSetFilterInt(_filter, "quality", q);
        // 【关键】OIDN 默认按 LDR 处理输入。我们喂的是线性 HDR 辐射度（clamp 到 60000），
        // 不声明 hdr 的话 OIDN 会把 >1 的高光裁平、暗部抬亮，画面整体发灰发柔，
        // 看起来就是"厚涂/轻微模糊"。Blender Cycles 同样固定 hdr=true / srgb=false。
        oidnSetFilterBool(_filter, "hdr", true);
        oidnSetFilterBool(_filter, "srgb", false);
        // albedo / normal 直接来自精确 G-buffer，本身无噪。默认 cleanAux=false 会让 OIDN
        // 先把 aux 当噪声预滤一遍，几何与材质边界被抹软，再传导到颜色上 → 细节糊掉。
        oidnSetFilterBool(_filter, "cleanAux", true);
        oidnCommitFilter(_filter);
        const char *cmsg = NULL;
        if (oidnGetDeviceError(_device, &cmsg) != OIDN_ERROR_NONE) {
            fprintf(stderr, "[OIDN] commit failed: %s\n", cmsg ? cmsg : "?");
            return NO;
        }
        _committedQuality = q;
    }

    oidnExecuteFilter(_filter);
    // synchronize=YES：CPU 端要立刻读 output 时才等。
    // synchronize=NO：调用方紧接着会把「消费 output」的命令提交到同一个 MTLCommandQueue，
    // OIDN 的 Metal 后端也是排在这条队列上，GPU 顺序执行天然保证 output 已写完，
    // CPU 继续往下走即可 —— 这是把渲染从主线程链路上摘掉的关键（同步等 30ms 会直接卡住手势）。
    if (synchronize) {
        oidnSyncDevice(_device);
        const char *msg = NULL;
        if (oidnGetDeviceError(_device, &msg) != OIDN_ERROR_NONE) {
            fprintf(stderr, "[OIDN] execute failed: %s\n", msg ? msg : "?");
            return NO;
        }
    }
    return YES;
}

@end
