import Foundation
import Metal
import simd

// MARK: - 粒子离线烘焙器
//
// 职责：把视口那套「按真实帧时长积分」的模拟，换成**固定步长 1/帧率**离线跑一遍。
//
// 为什么不能直接复用 粒子渲染器：
// - 它跟 MTKView 的 draw 绑死，步长来自真实帧间隔（掉帧就变大），池状态也私有；
// - 烘焙要的是确定性：同样参数跑两遍结果必须逐字节一样，否则缓存没意义。
//
// 复用的是什么：
// - **同一套 compute 管线**（particleEmit / particleStep）与同一份 GPU 结构，
//   所以烘出来的形态跟视口里看到的是同一条物理链路，不是第二套实现。
// - 池的推进规则（待发射累积、帧序号、时刻）逐行照搬 粒子渲染器，两边不许分叉。

/// 一个发射器在一次烘焙会话里的模拟状态。
///
/// 跟 粒子渲染器 里的私有 `粒子池` 同构，区别是这里的池**能被读回 CPU** 并落盘。
final class 烘焙池会话 {

    let id: UUID
    let 容量: Int
    let 粒子: MTLBuffer
    let 写指针: MTLBuffer

    /// 小数发射累积：每秒几个的低发射率也要能发出来
    var 待发射: Double = 0
    var 时刻: Float = 0
    var 帧序号: UInt32 = 0

    init?(device: MTLDevice, id: UUID, 容量: Int) {
        let 上限 = max(256, min(200_000, 容量))
        let 字节 = 上限 * MemoryLayout<粒子GPU>.stride
        guard let 粒子 = device.makeBuffer(length: 字节, options: .storageModeShared),
              let 写指针 = device.makeBuffer(length: MemoryLayout<UInt32>.stride,
                                            options: .storageModeShared)
        else { return nil }
        memset(粒子.contents(), 0, 字节)
        memset(写指针.contents(), 0, MemoryLayout<UInt32>.stride)
        粒子.label = "烘焙池 \(上限)"
        self.id = id
        self.容量 = 上限
        self.粒子 = 粒子
        self.写指针 = 写指针
    }

    /// 把这一帧的池状态读回 CPU（只取活着的粒子，空槽不占缓存体积）
    func 导出() -> 烘焙发射器帧 {
        let 指针值 = 写指针.contents().load(as: UInt32.self)
        let 基 = 粒子.contents().bindMemory(to: 粒子GPU.self, capacity: 容量)

        var 活的: [粒子GPU] = []
        活的.reserveCapacity(容量 / 8)
        for i in 0..<容量 {
            let 颗 = 基[i]
            // 速度_总活.w 是总寿命，0 = 这个槽空着（见 粒子 着色器.metal 的发射分支）
            if 颗.速度_总活.w > 0 {
                活的.append(颗)
            }
        }
        return 烘焙发射器帧(写指针: 指针值, 时刻: 时刻, 帧序号: 帧序号, 粒子: 活的)
    }

    /// 把一帧缓存灌回池（回放用）。先清零再铺，保证没有上一帧的残影。
    func 导入(_ 帧: 烘焙发射器帧) {
        let 字节 = 容量 * MemoryLayout<粒子GPU>.stride
        memset(粒子.contents(), 0, 字节)

        let 基 = 粒子.contents().bindMemory(to: 粒子GPU.self, capacity: 容量)
        let 数 = min(容量, 帧.粒子.count)
        for i in 0..<数 { 基[i] = 帧.粒子[i] }

        写指针.contents().storeBytes(of: min(帧.写指针, UInt32(容量)), as: UInt32.self)
        时刻 = 帧.时刻
        帧序号 = 帧.帧序号
        待发射 = 0
    }
}

// MARK: - 烘焙器

/// GPU 侧的模拟推进一步。一次烘焙会话（一次「烘焙全部特效」）只用一台。
final class 粒子烘焙器 {

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let 发射管线: MTLComputePipelineState
    private let 步进管线: MTLComputePipelineState

    /// 单帧步长上限：与实时渲染器同一个上限，保证烘焙出来的形态跟视口一致
    private static let 最大步长: Float = 1.0 / 20.0

    init?(device: MTLDevice) {
        guard let queue = device.makeCommandQueue(),
              let 库 = device.makeDefaultLibrary(),
              let 发 = 库.makeFunction(name: "particleEmit"),
              let 步 = 库.makeFunction(name: "particleStep"),
              let 发射管线 = try? device.makeComputePipelineState(function: 发),
              let 步进管线 = try? device.makeComputePipelineState(function: 步)
        else {
            NSLog("烘焙：粒子 compute 管线建不起来（着色器名对不上？）")
            return nil
        }
        self.device = device
        self.queue = queue
        self.发射管线 = 发射管线
        self.步进管线 = 步进管线
    }

    /// 起一个新池（发射器第一次出现在烘焙里时调）
    func 建池(id: UUID, 设置: 特效设置) -> 烘焙池会话? {
        烘焙池会话(device: device, id: id, 容量: 设置.池容量上限)
    }

    /// 推进一帧。
    ///
    /// - 步长固定 `1/帧率`：这是烘焙与实时现算唯一的口径差别，也是为了可复现。
    /// - 池的待发射 / 帧序号 / 时刻推进规则与 粒子渲染器.draw 完全一致。
    func 步进一帧(池: 烘焙池会话,
                快照: 粒子发射器快照,
                域 输入域: 物理域,
                球: [SIMD4<Float>],
                帧率: Double) async {

        let 步长 = min(Float(1.0 / max(帧率, 1)), Self.最大步长)
        guard 步长 > 0 else { return }

        // 全局力：物理域关掉 = 不施力，发射器自己的初速/湍流照旧（与视口同口径）
        var 域 = 输入域
        if !域.启用 {
            域.重力 = .zero
            域.风 = .zero
            域.流 = .zero
            域.湍流 = 0
        }

        池.时刻 += 步长
        池.帧序号 &+= 1

        var 待发: UInt32 = 0
        if 快照.设置.启用 {
            池.待发射 += 快照.设置.发射率 * Double(步长)
            let 可发 = min(池.待发射, Double(池.容量))
            if 可发 >= 1 {
                待发 = UInt32(可发)
                池.待发射 -= Double(待发)
            }
        } else {
            池.待发射 = 0
        }

        var 参数 = 快照.设置.参数(物理域: 域,
                               世界: 快照.世界,
                               dt: 步长,
                               池容量: UInt32(池.容量),
                               发射数: 待发,
                               帧序号: 池.帧序号,
                               球数: UInt32(球.count))
        参数.流.w = 池.时刻

        guard let cmd = queue.makeCommandBuffer() else { return }
        cmd.label = "烘焙 帧 \(池.帧序号)"

        if let enc = cmd.makeComputeCommandEncoder() {
            enc.label = "烘焙 模拟"
            let 组宽 = MTLSize(width: 64, height: 1, depth: 1)

            if 参数.发射数 > 0 {
                enc.setComputePipelineState(发射管线)
                enc.setBuffer(池.粒子, offset: 0, index: 0)
                enc.setBytes(&参数, length: MemoryLayout<粒子发射参数>.stride, index: 1)
                enc.setBuffer(池.写指针, offset: 0, index: 2)
                enc.dispatchThreads(MTLSize(width: Int(参数.发射数), height: 1, depth: 1),
                                    threadsPerThreadgroup: 组宽)
            }

            // 碰撞球：空的时候也要给一份合法内存（着色器按 e.球数 判空，不会读到越界）
            var 球垫 = 球
            if 球垫.isEmpty { 球垫 = [SIMD4<Float>(0, 0, 0, 0)] }

            enc.setComputePipelineState(步进管线)
            enc.setBuffer(池.粒子, offset: 0, index: 0)
            enc.setBytes(&参数, length: MemoryLayout<粒子发射参数>.stride, index: 1)
            球垫.withUnsafeBytes { 原 in
                enc.setBytes(原.baseAddress!, length: 原.count, index: 2)
            }
            enc.dispatchThreads(MTLSize(width: 池.容量, height: 1, depth: 1),
                                threadsPerThreadgroup: 组宽)

            enc.endEncoding()
        }

        // 逐帧等 GPU 落地才读回：缓存要的是"这一帧的确定状态"，不能和下一帧的写入打架。
        // 顺序不能反：往**已提交**的命令缓冲上挂回调，Metal 会直接 abort（MTLReportFailure）。
        // 工程里 PT 侧也是同一条规矩：handler 先挂，commit 在闭包里最后一步。
        // 帧号必须提前取成局部值，别在回调里碰 @MainActor 隔离的池。
        let 本帧号 = 池.帧序号
        await withCheckedContinuation { (续: CheckedContinuation<Void, Never>) in
            cmd.addCompletedHandler { 完成 in
                if 完成.status != .completed {
                    NSLog("VFXDBG 烘焙步进失败 帧=%u status=%d err=%@",
                          本帧号, 完成.status.rawValue, String(describing: 完成.error))
                }
                续.resume()
            }
            cmd.commit()
        }
    }
}
