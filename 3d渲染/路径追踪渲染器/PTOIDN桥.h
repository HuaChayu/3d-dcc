//
//  PTOIDN桥.h
//  OpenImageDenoise 的 ObjC 封装：把 Metal 缓冲直接交给 OIDN 的 Metal 后端做零拷贝降噪。
//  Swift 侧通过 bridging header 使用，不需要改任何 Metal 命令编码习惯。
//

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, PTOIDNQuality) {
    PTOIDNQualityFast = 0,      // 交互/拖动时用（M4 Max 1280x720 约 10ms）
    PTOIDNQualityBalanced = 1,  // 默认
    PTOIDNQualityHigh = 2,      // 停手后的最终帧
};

/// 一个尺寸绑定的降噪器实例：filter / 缓冲区包装全部缓存，避免每次重建（重建约 150ms）。
@interface PTOIDNDenoiser : NSObject

/// 内部优先用 Metal 后端（与传入队列共享，零拷贝），失败自动退到 CPU 后端。
- (nullable instancetype)initWithCommandQueue:(nonnull id<MTLCommandQueue>)queue
                                        width:(NSUInteger)width
                                       height:(NSUInteger)height;

/// 最近一次使用的后端名字，便于日志排查："metal" / "cpu" / "none"
@property (nonatomic, readonly) NSString *backendName;

/// 降噪。四个缓冲都是紧密排列的 float3（width * height * 3 * 4 字节）。
/// synchronize=YES 会在 execute 后同步等待 GPU 写完 output（CPU 端要立刻读时用）；
/// 传 NO 表示调用方随后还会在**同一个命令队列**上提交消费 output 的命令，
/// 由 GPU 队列顺序保证正确性，CPU 立刻返回、不阻塞调用线程。
/// 返回 YES 表示已成功提交（synchronize=NO 时不再校验 GPU 侧错误）。
- (BOOL)denoiseColor:(nonnull id<MTLBuffer>)color
              albedo:(nonnull id<MTLBuffer>)albedo
              normal:(nonnull id<MTLBuffer>)normal
              output:(nonnull id<MTLBuffer>)output
             quality:(PTOIDNQuality)quality
         synchronize:(BOOL)synchronize;

@end

NS_ASSUME_NONNULL_END
