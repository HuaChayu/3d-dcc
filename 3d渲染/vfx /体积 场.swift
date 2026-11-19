import Foundation
import Metal
import simd

// ============================================================================
// 体积 场（GPU 欧拉网格）
// ----------------------------------------------------------------------------
// 一个体积发射器 = 一套 3D 网格纹理 + 自己的流体时钟。
// 模拟跑在 GPU 上（见 体积 模拟.metal），这里只负责：建纹理、按 id 复用、
// 按预算调度、每帧把参数编码进命令队列。
//
// 【为什么不是粒子】火的形态是密度场被速度场撕裂出来的丝，粒子只能得到珠子。
// 【为什么不是解析场】解析场没有速度场，密度只能按距离画圆 —— 任何角度都是球。
// ============================================================================

/// 与 Metal 侧 VolSimParams 逐字节一致（3×16 + 64 = 192 字节）
struct 体积模拟参数 {
    var 世界: simd_float4x4 = matrix_identity_float4x4
    /// x=半宽(米) y=高(米) z=网格边长 w=体素边长(米)
    var 域: SIMD4<Float> = SIMD4<Float>(0.5, 1, 64, 0.02)
    /// x=时间 y=dt z=涡量强度 w=浮力
    var 时间: SIMD4<Float> = .zero
    /// x=速度耗散 y=密度耗散 z=重力强度 w=湍流幅度
    var 动力: SIMD4<Float> = SIMD4<Float>(0.9, 0.75, 1.2, 1.5)
    /// x=燃烧强度 y=温度衰减 z=烟生成 w=喷口射流速度
    var 燃烧: SIMD4<Float> = SIMD4<Float>(1, 1.8, 1.2, 3)
    /// x=喷口半径 y=喷口厚度 z=是否发射 w=初始温度
    var 源: SIMD4<Float> = SIMD4<Float>(0.06, 0.04, 1, 1.6)
    /// xyz=风 w=预热时间
    var 外力: SIMD4<Float> = .zero
    /// x=球数 y=地面高度 z=地面开关 w=保留
    var 碰撞: SIMD4<Float> = .zero
    /// x=消光 y=发光 z=自阴影 w=密度死区
    var 配色: SIMD4<Float> = SIMD4<Float>(6, 1, 1, 0)
    /// x=每帧子步数 y=压力迭代次数 z=浮力倍率 w=源温倍率
    var 调参: SIMD4<Float> = SIMD4<Float>(1, 40, 1, 1)

    static let 字节数 = MemoryLayout<体积模拟参数>.stride
}

/// 与 Metal 侧 VolCollider 一致
struct 体积碰撞球 {
    var 球心半径: SIMD4<Float> = .zero
}

// MARK: - 网格预算

enum 体积网格 {
    /// 近处 / 主角用的分辨率
    static let 高 = 64
    /// 远处 / 数量爆炸时的降级分辨率（体素少 8 倍）
    static let 低 = 32
    /// 同时高精度模拟的上限：超出的自动降到低分辨率，保证"无数个火"也不崩
    static let 高精度上限 = 3
}

// MARK: - 单个发射器的场

final class 体积场 {
    let id: UUID
    private(set) var 边长: Int

    private(set) var 速A: MTLTexture
    private(set) var 速B: MTLTexture
    private(set) var 密A: MTLTexture
    private(set) var 密B: MTLTexture
    private(set) var 压A: MTLTexture
    private(set) var 压B: MTLTexture
    private(set) var 散度: MTLTexture
    /// 固体遮罩（1=被 SDF 占住）：压力求解靠它做 Neumann 边界
    private(set) var 固体: MTLTexture
    /// 宿主几何的表面距离场（米，与模拟纹理逐体素对齐）。
    /// kernel 在 |d| < 源厚 的薄壳里供料 —— 火于是从"用户选中的那个几何"表面长出来，
    /// 而不是从对象中心的一个圆盘里喷出来。
    private(set) var 表面场: MTLTexture
    /// 已上传到 表面场 的那份数据是谁（键一致就不重复上传，CPU 逐层写纹理不便宜）
    private(set) var 已上传表面键: String?

    /// 当前哪一套是"最新"的（平流/投影会来回翻）
    var 速在A = true
    var 密在A = true
    /// 流体自己的时钟：不吃真实帧间隔，掉帧也不会让火忽快忽慢
    var 时刻: Float = 0
    /// 首帧需要清零
    var 需要清零 = true

    init?(device: MTLDevice, id: UUID, 边长: Int) {
        guard let 速A = Self.建(device: device, 边长: 边长, 格式: .rgba16Float),
              let 速B = Self.建(device: device, 边长: 边长, 格式: .rgba16Float),
              let 密A = Self.建(device: device, 边长: 边长, 格式: .r16Float),
              let 密B = Self.建(device: device, 边长: 边长, 格式: .r16Float),
              let 压A = Self.建(device: device, 边长: 边长, 格式: .r16Float),
              let 压B = Self.建(device: device, 边长: 边长, 格式: .r16Float),
              let 散度 = Self.建(device: device, 边长: 边长, 格式: .r16Float),
              let 固体 = Self.建(device: device, 边长: 边长, 格式: .r16Float),
              let 表面 = Self.建表面(device: device, 边长: 边长)
        else { return nil }
        self.id = id
        self.边长 = 边长
        self.速A = 速A; self.速B = 速B
        self.密A = 密A; self.密B = 密B
        self.压A = 压A; self.压B = 压B
        self.散度 = 散度
        self.固体 = 固体
        self.表面场 = 表面
    }

    /// 表面距离场专用的 R32F 纹理：必须 shared —— 这玩意儿由 CPU 体素化后逐层写进来，
    /// private 纹理得走 blit 中转，纯属白忙。初值 1e3 表示"离任何几何都远"（不会供料）。
    private static func 建表面(device: MTLDevice, 边长: Int) -> MTLTexture? {
        let d = MTLTextureDescriptor()
        d.textureType = .type3D
        d.pixelFormat = .r32Float
        d.width = 边长
        d.height = 边长
        d.depth = 边长
        d.mipmapLevelCount = 1
        d.usage = [.shaderRead]
        d.storageMode = .shared
        guard let 纹 = device.makeTexture(descriptor: d) else { return nil }
        let 远 = [Float](repeating: 1e3, count: 边长 * 边长 * 边长)
        远.withUnsafeBytes { raw in
            guard let 基 = raw.baseAddress else { return }
            for z in 0..<边长 {
                纹.replace(region: MTLRegionMake3D(0, 0, z, 边长, 边长, 1), mipmapLevel: 0, slice: 0,
                          withBytes: 基 + z * 边长 * 边长 * MemoryLayout<Float>.stride,
                          bytesPerRow: 边长 * MemoryLayout<Float>.stride,
                          bytesPerImage: 边长 * 边长 * MemoryLayout<Float>.stride)
            }
        }
        return 纹
    }

    /// 把 CPU 体素化出来的表面场推进纹理。键没变就整套跳过。
    func 更新表面(_ 场: 对象表面场?) {
        guard let 场, 场.边长 == 边长 else {
            // 没有几何（例如导入网格还没进池）：填回"远"，kernel 就不会在旧壳上继续烧
            if 已上传表面键 != nil {
                已上传表面键 = nil
                let 远 = [Float](repeating: 1e3, count: 边长 * 边长 * 边长)
                上传(远)
            }
            return
        }
        if 已上传表面键 == 场.键 { return }
        if 上传(场.距离) { 已上传表面键 = 场.键 }
    }

    @discardableResult
    private func 上传(_ 距离: [Float]) -> Bool {
        guard 距离.count == 边长 * 边长 * 边长 else { return false }
        let n = 边长
        let 行 = n * MemoryLayout<Float>.stride
        距离.withUnsafeBytes { raw in
            guard let 基 = raw.baseAddress else { return }
            for z in 0..<n {
                表面场.replace(region: MTLRegionMake3D(0, 0, z, n, n, 1), mipmapLevel: 0, slice: 0,
                             withBytes: 基 + z * rowStride(n),
                             bytesPerRow: 行, bytesPerImage: 行 * n)
            }
        }
        return true
    }

    private func rowStride(_ n: Int) -> Int { n * n * MemoryLayout<Float>.stride }

    private static func 建(device: MTLDevice, 边长: Int, 格式: MTLPixelFormat) -> MTLTexture? {
        let d = MTLTextureDescriptor()
        d.textureType = .type3D
        d.pixelFormat = 格式
        d.width = 边长
        d.height = 边长
        d.depth = 边长
        d.mipmapLevelCount = 1
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .private
        return device.makeTexture(descriptor: d)
    }

    /// 当前最新状态（渲染用）
    var 当前速: MTLTexture { 速在A ? 速A : 速B }
    var 当前密: MTLTexture { 密在A ? 密A : 密B }
}

// MARK: - 出图登记

/// 视口 → 路径追踪的「同一份密度/温度」桥。
///
/// 视口的体积场是渲染器私有的（跟着 LOD 预算逐帧换边长），PT 侧拿不到；
/// 但出图必须和视口长得一模一样，所以由视口每帧把**本帧真正在跑的场**登记进来，
/// PT 转译按 object.id 取最新纹理直接采样，两边吃的是同一批体素。
///
/// 不持有所有权（只存引用），也不做生命周期管理：场被渲染器换掉后，下一帧提交就自动指到新场；
/// 停用的火不再出现在提交表里，PT 侧也就不会再画它。
enum 体积场登记 {
    struct 项 {
        let 场: 体积场
        /// 域盒半宽（米），与模拟 kernel 的 参.域.x 同源
        let 半宽: Float
        /// 域盒高（米），与模拟 kernel 的 参.域.y 同源
        let 高: Float
        /// 网格边长（体素数）
        let 边长: Float
    }

    /// 本帧在跑的场。主线程写、主线程读（都在渲染前），不加锁。
    private(set) static var 当前: [UUID: 项] = [:]

    /// 槽集版本：**只在"有哪些发射器正在跑模拟"这件事变了时才自增**。
    ///
    /// 为什么不每帧自增：PT 的场景转译很贵（材质求值 + 逐顶点变换 + 灯 CDF），
    /// 每帧自增等于每帧重译，视口直接卡死。
    /// 为什么必须要有这个版本：PT 视口的场景缓存 key 只有 objects / 材质版本 / 设置 / 绘画 rev，
    /// 而"火从没有模拟场变成有模拟场"时这四样一个字节都不变（模拟场出不出现，取决于
    /// 视口粒子渲染器有没有先跑过一帧），缓存于是永远命中那份 `模拟.z == 0` 的旧场景，
    /// 出图就只能一直走解析场 —— 这就是"永远是球"的来路之一。
    private(set) static var 版本: UInt64 = 0

    static func 提交(_ 表: [UUID: 项]) {
        if Set(表.keys) != Set(当前.keys) { 版本 &+= 1 }
        当前 = 表
    }
}

// MARK: - 模拟器

final class 体积模拟器 {

    private let device: MTLDevice
    private var 力管线: MTLComputePipelineState?
    private var 平流管线: MTLComputePipelineState?
    private var 燃烧管线: MTLComputePipelineState?
    private var 散度管线: MTLComputePipelineState?
    private var 压力管线: MTLComputePipelineState?
    private var 投影管线: MTLComputePipelineState?
    private var 碰撞管线: MTLComputePipelineState?
    private var 固体管线: MTLComputePipelineState?
    private var 清空管线: MTLComputePipelineState?

    /// 压力迭代次数：泊松解要让压力从喷口传到域顶，至少要 N/2 次雅可比；
    /// 早期只跑 12 次，压力根本传不出去 → 投影形同虚设 → 浮力被散度吃掉，
    /// 火只能瘫在喷口（用户看到的"一坨球"就是这个）。64³ 取 40 次是速度/质量的平衡点。
    private let 压力迭代 = 40
    /// 每帧子步：2 步 = 稳定 + 速度之间的最佳折中
    private let 子步数 = 1
    /// 模拟 dt 固定 1/60：真实帧时长喂进去会让高帧率下 dt 过小、涡量约束失效
    private let 固定dt: Float = 1.0 / 60.0

    init?(device: MTLDevice) {
        self.device = device
        guard let library = device.makeDefaultLibrary() else { return nil }
        func 取(_ 名: String) -> MTLComputePipelineState? {
            guard let f = library.makeFunction(name: 名) else { return nil }
            return try? device.makeComputePipelineState(function: f)
        }
        力管线 = 取("volSimForce")
        平流管线 = 取("volSimAdvect")
        燃烧管线 = 取("volSimBurn")
        散度管线 = 取("volSimDivergence")
        压力管线 = 取("volSimJacobi")
        投影管线 = 取("volSimProject")
        碰撞管线 = 取("volSimCollide")
        固体管线 = 取("volSimSolid")
        清空管线 = 取("volSimClear")
        if 力管线 == nil || 平流管线 == nil || 燃烧管线 == nil
            || 散度管线 == nil || 压力管线 == nil || 投影管线 == nil {
            NSLog("体积模拟：管线建不起来（体积 模拟.metal 没编进默认库？）")
            return nil
        }
    }

    var 可用: Bool { 力管线 != nil }

    /// 跑一个场的一次完整步进。调用方负责先建 compute encoder。
    func 步进(场: 体积场, 参数: 体积模拟参数, 球: [体积碰撞球], encoder: MTLCommandEncoder) {
        let 边长 = 场.边长
        let 线宽 = MTLSize(width: 边长, height: 边长, depth: 边长)
        guard let enc = encoder as? MTLComputeCommandEncoder else { return }
        enc.label = "体积 模拟"

        var 参 = 参数
        enc.setBytes(&参, length: 体积模拟参数.字节数, index: 0)

        // 首帧清零：private 纹理不保证是 0
        if 场.需要清零, let 清 = 清空管线 {
            enc.setComputePipelineState(清)
            enc.setTexture(场.速A, index: 0)
            enc.setTexture(场.速B, index: 1)
            enc.setTexture(场.密A, index: 2)
            enc.setTexture(场.密B, index: 3)
            enc.setTexture(场.压A, index: 4)
            enc.setTexture(场.压B, index: 5)
            enc.dispatchThreads(线宽, threadsPerThreadgroup: 线程组(边长))
            场.需要清零 = false
        }

        guard let 力 = 力管线, let 平流 = 平流管线, let 燃烧 = 燃烧管线,
              let 散度 = 散度管线, let 压 = 压力管线, let 投影 = 投影管线
        else { return }

        var 球们 = 球
        let 球空 = 体积碰撞球()
        let 球数 = 球们.count
        if 球数 == 0 { 球们 = [球空] }

        // 子步 / 压力迭代由 UI 逐发射器控制（参.调参），出问题可以单只火降档
        let 本次子步 = max(1, min(4, Int(参.调参.x.rounded())))
        let 本次迭代 = max(8, min(120, Int(参.调参.y.rounded())))

        for _ in 0..<本次子步 {
            场.时刻 += 固定dt
            var 步参 = 参
            步参.时间 = SIMD4<Float>(场.时刻, 固定dt, 参.时间.z, 参.时间.w)
            enc.setBytes(&步参, length: 体积模拟参数.字节数, index: 0)

            // 1) 涡量约束 + 浮力 + 外力 + 湍流 + 射流    源速 → 目标速
            enc.setComputePipelineState(力)
            enc.setTexture(场.当前速, index: 0)
            enc.setTexture(场.速在A ? 场.速B : 场.速A, index: 1)
            enc.setTexture(场.当前密, index: 2)
            // 3 号槽 = 宿主几何表面距离场：射流方向改为沿表面法向外推
            enc.setTexture(场.表面场, index: 3)
            enc.dispatchThreads(线宽, threadsPerThreadgroup: 线程组(边长))
            场.速在A.toggle()

            // 2) 自平流（速度 + 密度一起）   当前 → 另一套
            enc.setComputePipelineState(平流)
            enc.setTexture(场.当前速, index: 0)
            enc.setTexture(场.当前密, index: 1)
            enc.setTexture(场.速在A ? 场.速B : 场.速A, index: 2)
            enc.setTexture(场.密在A ? 场.密B : 场.密A, index: 3)
            enc.dispatchThreads(线宽, threadsPerThreadgroup: 线程组(边长))
            场.速在A.toggle()
            场.密在A.toggle()

            // 3) 燃烧 + 源注入（就地）
            enc.setComputePipelineState(燃烧)
            enc.setTexture(场.当前速, index: 0)
            enc.setTexture(场.当前密, index: 1)
            // 2 号槽 = 宿主几何表面距离场：供料区 = 贴着几何表面的薄壳
            enc.setTexture(场.表面场, index: 2)
            enc.dispatchThreads(线宽, threadsPerThreadgroup: 线程组(边长))

            // 3.5) SDF 碰撞前置：先写边界条件（法向速度清零），再让压力求解看到墙
            //      —— 老顺序(碰撞在投影之后)的问题：墙写进去的法向=0 会被下一次投影
            //      当成散度抹平，火贴着物体表面会被"吸"进去或贴着墙抖。
            let 有碰撞 = 步参.碰撞.x > 0.5 || 步参.碰撞.z > 0.5
            if 有碰撞, let 碰 = 碰撞管线 {
                enc.setComputePipelineState(碰)
                enc.setTexture(场.当前速, index: 0)
                enc.setTexture(场.当前密, index: 1)
                球们.withUnsafeBytes { 原 in
                    if let 基 = 原.baseAddress { enc.setBytes(基, length: 原.count, index: 0) }
                }
                var 碰参 = 步参
                enc.setBytes(&碰参, length: 体积模拟参数.字节数, index: 1)
                enc.dispatchThreads(线宽, threadsPerThreadgroup: 线程组(边长))
            }

            // 3.6) 固体遮罩：压力求解的边界依据
            if 有碰撞, let 固 = 固体管线 {
                enc.setComputePipelineState(固)
                enc.setTexture(场.固体, index: 0)
                球们.withUnsafeBytes { 原 in
                    if let 基 = 原.baseAddress { enc.setBytes(基, length: 原.count, index: 0) }
                }
                var 固参 = 步参
                enc.setBytes(&固参, length: 体积模拟参数.字节数, index: 1)
                enc.dispatchThreads(线宽, threadsPerThreadgroup: 线程组(边长))
            }

            // 4) 散度（固体体素内散度=0）
            // 【为什么这里必须重绑 buffer(0)】上面碰撞/固体两个 kernel 把球数组绑到了 buffer(0)
            // （它们把参数放在 buffer(1)），而散度/压力/投影的参数都在 buffer(0)。
            // 不重绑就会把 3 个球的 48 字节当成 VolSimParams(208) 传进去，
            // Metal 直接抛 ValidateComputeFunctionArguments 断言 —— 一开碰撞就崩在这里。
            enc.setBytes(&步参, length: 体积模拟参数.字节数, index: 0)
            enc.setComputePipelineState(散度)
            enc.setTexture(场.当前速, index: 0)
            enc.setTexture(场.散度, index: 1)
            enc.setTexture(场.固体, index: 2)
            enc.dispatchThreads(线宽, threadsPerThreadgroup: 线程组(边长))

            // 5) 压力 Jacobi
            enc.setComputePipelineState(压)
            var 读压 = 场.压A
            var 写压 = 场.压B
            for _ in 0..<本次迭代 {
                enc.setTexture(场.散度, index: 0)
                enc.setTexture(读压, index: 1)
                enc.setTexture(写压, index: 2)
                enc.setTexture(场.固体, index: 3)
                enc.dispatchThreads(线宽, threadsPerThreadgroup: 线程组(边长))
                swap(&读压, &写压)
            }

            // 6) 减梯度（就地）
            enc.setComputePipelineState(投影)
            enc.setTexture(场.当前速, index: 0)
            enc.setTexture(读压, index: 1)
            enc.setTexture(场.固体, index: 2)
            enc.dispatchThreads(线宽, threadsPerThreadgroup: 线程组(边长))

            // 7) SDF 碰撞收尾（就地）：投影可能把一点速度推回墙里，再压一次
            if 有碰撞, let 碰 = 碰撞管线 {
                enc.setComputePipelineState(碰)
                enc.setTexture(场.当前速, index: 0)
                enc.setTexture(场.当前密, index: 1)
                球们.withUnsafeBytes { 原 in
                    if let 基 = 原.baseAddress {
                        enc.setBytes(基, length: 原.count, index: 0)
                    }
                }
                var 碰参 = 步参
                enc.setBytes(&碰参, length: 体积模拟参数.字节数, index: 1)
                enc.dispatchThreads(线宽, threadsPerThreadgroup: 线程组(边长))
            }
        }
    }

    private func 线程组(_ 边长: Int) -> MTLSize {
        // 8×8×4 = 256 线程/组，对 3D 场是cache 友好的默认值
        MTLSize(width: 8, height: 8, depth: 4)
    }
}

// MARK: - 域盒派生（Swift 与着色器同式）

extension 特效设置 {
    /// 体积喷口的世界矩阵：把对象矩阵沿**本地 +Y** 抬到包围球顶。
    /// 视口模拟、视口渲染、路径追踪出图三处必须都拿这个结果，
    /// 否则就是两套位置口径（用户红线：出图与视口必须同源）。
    static func 体积喷口世界(_ 世界: simd_float4x4, 对象顶部: Float) -> simd_float4x4 {
        guard 对象顶部 > 0 else { return 世界 }
        return 世界 * simd_float4x4(columns: (SIMD4<Float>(1, 0, 0, 0),
                                             SIMD4<Float>(0, 1, 0, 0),
                                             SIMD4<Float>(0, 0, 1, 0),
                                             SIMD4<Float>(0, 对象顶部, 0, 1)))
    }

    /// 局部包围盒：局部原点在喷口，+Y 是喷流方向
    /// 返回 (半宽, 高)
    ///
    /// 对象半径 = 该对象局部包围球半径。以前域盒只按美术参数（初速 × 寿命）推，
    /// 对象一大，火就只是对象中心那一小撮 —— 火焰该是"从这玩意儿上烧起来的"，
    /// 尺寸不能比对象本体还小，所以这里给域盒兜一个对象尺度下限。
    func 体积域盒(对象半径: Float = 0) -> (半宽: Float, 高: Float) {
        let 寿命 = Float(max(self.寿命, 0.02))
        let 初速 = Float(max(self.初速, 0.02))
        let 羽流长 = 初速 * 寿命
        let 起始半径 = Float(max(self.起始尺寸, 0.0005))
        let 半角 = Float(min(max(self.扩散角, 0), 179)) * .pi / 180
        let 张开 = tan(半角)
        let 重力 = Float(max(0, min(4, self.重力倍率)))
        var 半宽 = 起始半径 * 1.5 + 羽流长 * (0.35 * 张开 + 0.18)
        var 高 = 羽流长 * (1.0 + 0.22 * 重力) + 起始半径 * 2.0 + 0.15
        if 对象半径 > 0 {
            // 横向略比对象胖一点（火苗会往外卷），纵向至少盖住两个对象高
            半宽 = max(半宽, 对象半径 * 1.15)
            高 = max(高, 对象半径 * 2.2)
        }
        return (max(半宽, 0.05), max(高, 0.1))
    }

    /// 几何表面发射用的域盒：把**对象本体整个装进来**，上方再留一段羽流。
    /// 返回 (半宽, 高, 底偏移)。底偏移 = 域盒底面在对象局部空间里的 y，
    /// 世界矩阵要沿本地 -Y 平移它，模拟局部 y=0 才落在对象底部而不是原点。
    func 体积域盒(几何: 对象几何数据?) -> (半宽: Float, 高: Float, 底: Float) {
        let 基础 = 体积域盒(对象半径: 几何?.半宽 ?? 0)
        guard let 几何 else { return (基础.半宽, 基础.高, 0) }
        let 对象高 = 几何.高
        // 横向：至少包住对象，再留一点火苗外卷的余量
        let 半宽 = max(基础.半宽, 几何.半宽 * 1.2 + 0.03)
        // 纵向：对象 + 上方羽流。风一吹火会往上窜，比例取 1.5 倍对象高起步
        let 高 = max(基础.高 + 对象高 * 0.5, 对象高 * 1.5 + 0.25)
        let 底 = 几何.最小.y - max(高 * 0.04, 0.01)
        return (半宽, 高, 底)
    }

    /// 把美术参数翻译成流体参数。这里是"UI 调参"真正的落点：
    /// 扩散角 → 域宽、初速 × 寿命 → 域高与射流、湍流 → 扰动与涡量、
    /// 重力倍率 → 浮力与下落、不透明度 → 消光、颜色 → 火/烟配色。
    ///
    /// 传了 表面 就走"几何表面发射"：域盒按对象本体撑开、世界矩阵下沉到底面，
    /// 源模式 = 2（kernel 在贴面薄壳里供料）。不传则维持老的圆盘喷口，旧工程外观不变。
    func 制造模拟参数(物理域: 物理域, 世界: simd_float4x4, 时间: Float, dt: Float, 网格边长: Int,
                  对象顶部: Float = 0, 对象半径: Float = 0, 表面: 对象表面场? = nil) -> 体积模拟参数 {
        let 盒 = 表面.map { (半宽: $0.半宽, 高: $0.高) } ?? 体积域盒(对象半径: 对象半径)
        let 体素 = 盒.高 / Float(max(网格边长, 1))
        var 参 = 体积模拟参数()
        if let 表面 {
            // 域盒局部 y=0 落在对象底部：世界矩阵沿本地 -Y 下移底偏移
            参.世界 = 世界 * simd_float4x4(columns: (SIMD4<Float>(1, 0, 0, 0),
                                                  SIMD4<Float>(0, 1, 0, 0),
                                                  SIMD4<Float>(0, 0, 1, 0),
                                                  SIMD4<Float>(0, -表面.底偏移, 0, 1)))
        } else {
            // 喷口对齐对象顶部：域盒局部 y=0 就落在世界矩阵原点上，
            // 直接拿对象矩阵的话火是从几何中心往外长（用户看到的就是"中心一点点"）。
            // 抬升逻辑抽在 体积喷口世界 里，PT 出图调的是同一个函数。
            参.世界 = Self.体积喷口世界(世界, 对象顶部: 对象顶部)
        }
        参.域 = SIMD4<Float>(盒.半宽, 盒.高, Float(网格边长), 体素)

        let 湍流 = Float(min(max(self.湍流, 0), 1))
        // UI 高级调参（nil = 出厂值，所以旧工程乘 1.0，外观完全不变）
        let 浮力倍率 = Float(max(0.05, min(6, self.浮力倍率 ?? 1)))
        let 源温倍率 = Float(max(0.05, min(4, self.源温倍率 ?? 1)))
        let 死区倍率 = Float(max(0.05, min(6, self.死区倍率 ?? 1)))
        let 子步 = Float(max(1, min(4, self.子步数 ?? 1)))
        let 迭代 = Float(max(8, min(120, self.压力迭代 ?? 40)))
        let 重力倍率 = Float(max(0, min(4, self.重力倍率)))
        let 是火 = self.种类 == .火
        // 真实世界的重力（物理域关掉时按 0 处理，粒子那边同一口径）
        let 重力量 = 物理域.启用 ? abs(Float(物理域.重力.y)) : 0
        let 重力 = 重力量 * 重力倍率

        参.时间 = SIMD4<Float>(时间, dt,
                             0.55 + 1.1 * 湍流,      // 涡量强度：始终有底噪，湍流越大撕得越碎
                             (8.0 + 2.2 * 重力) * 浮力倍率)  // 浮力：实测标定 —— 必须显著大于 g(9.8) 才有火舌
        参.动力 = SIMD4<Float>(0.85,                            // 速度耗散 /秒
                             是火 ? 0.42 : 0.30,                // 密度耗散（实测标定：0.65 时火柱只到域高 1/3）
                             重力 * 0.35,                       // 重力强度（只压冷却的烟，见 kernel 烟权）
                             2.2 + 3.4 * 湍流)                  // 湍流幅度
        参.燃烧 = SIMD4<Float>(是火 ? 1.0 : 0.0,   // 燃烧强度（烟 = 0，纯热浮力）
                             是火 ? 1.9 : 2.6,   // 温度衰减 /秒
                             是火 ? 1.5 : 1.0,   // 温度 → 烟密度
                             Float(self.初速) * 1.5)  // 喷口射流速度

        let 起始半径 = Float(max(self.起始尺寸, 0.045))
        // 喷口半径必须跟着对象尺度走：域盒放大到对象级别后，源区还只留 6cm，
        // 出来的就是对象顶上一根细蜡烛 —— 用户看到的"中心一点点"一半是位置、一半是这个。
        // 半宽的 25% 约等于从对象顶面一片区域往上烧，而不是一根柱子。
        let 喷口半径 = max(起始半径, 盒.半宽 * 0.25)
        if 表面 != nil {
            // 表面模式：没有"轴"这个概念，x 只留个存在感；y = 薄壳厚度；
            // z = 2 是 kernel 认表面发射的开关（1 才是老圆盘喷口）
            let 侧体素 = 2 * 盒.半宽 / Float(max(网格边长, 1))
            参.源 = SIMD4<Float>(侧体素 * 2, 侧体素 * 2.5, 2, (是火 ? 3.2 : 1.1) * 源温倍率)
        } else {
            参.源 = SIMD4<Float>(喷口半径, 体素 * 2.5, 1, (是火 ? 3.2 : 1.1) * 源温倍率)
        }
        let 风力 = Float(max(0, min(4, self.风力倍率)))
        参.外力 = SIMD4<Float>(Float(物理域.启用 ? 物理域.风.x : 0) * 风力,
                             Float(物理域.启用 ? 物理域.风.y : 0) * 风力,
                             Float(物理域.启用 ? 物理域.风.z : 0) * 风力, 0)
        参.碰撞 = SIMD4<Float>(0, 体素 * 0.5, self.碰撞 ? 1 : 0, 0)

        // 消光：不透明度小 = 更透（烟必须薄才有层次，火要厚才压得住背景）
        let 消光 = Float(1.2 + 7.0 * min(max(self.不透明度, 0), 1)) * (是火 ? 1.0 : 0.7)
        // 配色.w = 密度死区：低于它的体素在模拟里直接归零。
        // 那层"到处都在、把外轮廓撑成圆球"的尾雾，就是这个量没掐住造成的。
        // 火给得稍狠（火要有清晰边缘），烟给得轻（烟本来就该是绒的）。
        // 取值来自 64³ 离线单测的实测分布：本场峰值密度约 0.52、均值 0.014，
        // 取 0.015 恰好切掉那层均值附近的尾雾（非零体素从 56% 降到 20%），
        // 火芯（>0.05）不受影响。注意只在渲染端生效，模拟场本身不动。
        let 死区 = (是火 ? Float(0.015) : Float(0.006)) * 死区倍率
        参.配色 = SIMD4<Float>(消光, 是火 ? 1.0 : 0.35, 1.0, 死区)
        // 调参 → 模拟内核：子步数 / 压力迭代次数 / 浮力倍率 / 源温倍率
        参.调参 = SIMD4<Float>(子步, 迭代, 浮力倍率, 源温倍率)
        return 参
    }
}

// ============================================================================
// MARK: - 宿主几何 → 表面场
//
// 【为什么需要这一层】火/烟/水/粒子原先都从"对象局部原点上方的一个圆盘"里生出来（喷口）。
// 喷口天生只能表达"点状火源"，表达不了"沿实体表面燃烧"——所以用户选了个圈，
// 火却在场景/对象中心冒，而不是从圈上冒。
//
// 这一层把对象的**真实三角形**体素化成一张与模拟网格同尺寸的距离场（薄壳），
// kernel 只在 |d| < 源厚 的体素里供料，于是"发射体"就是几何本身。
// 距离场随网格尺寸缓存；三角形来自程序网格生成器或导入网格池，与画面用的是同一份几何。
// ============================================================================

/// 对象局部空间的三角汤：每 3 个点一个三角形，坐标 = 对象局部坐标
final class 对象几何数据 {
    let 键: String
    let 三角点: [SIMD3<Float>]
    let 最小: SIMD3<Float>
    let 最大: SIMD3<Float>

    init(键: String, 三角点: [SIMD3<Float>]) {
        self.键 = 键
        self.三角点 = 三角点
        guard !三角点.isEmpty else {
            最小 = .zero; 最大 = .zero
            return
        }
        var 小 = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var 大 = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for p in 三角点 {
            小 = simd_min(小, p)
            大 = simd_max(大, p)
        }
        最小 = 小; 最大 = 大
    }

    /// 横向半径（局部 xz 里离原点最远的那个轴）
    var 半宽: Float {
        max(max(abs(最小.x), abs(最大.x)), max(abs(最小.z), abs(最大.z)))
    }
    /// 纵向高度
    var 高: Float { max(最大.y - 最小.y, 0.01) }
}

/// 几何取用 + 缓存。
/// 程序网格（圆环/立方体/球…）现算现缓存；导入网格按"网格 id + 版本"缓存，重导入自动失效。
enum 对象几何库 {
    private static let 锁 = NSLock()
    private static var 缓存: [String: 对象几何数据] = [:]

    static func 取(_ 物: SceneObject) -> 对象几何数据? {
        var 键 = ""
        var 点: [SIMD3<Float>] = []
        // 几何来源以几何域记录为准（与画面同一份），域里还没同步时退回对象自身字段
        let 形状 = 几何接线.共享.取值(键: 物.id.uuidString)?.程序网格形状 ?? 物.mesh

        if let 网格 = 物.导入网格ID {
            键 = "导入:\(网格.uuidString):\(几何接线.共享.版本号(网格))"
            点 = 几何接线.共享.三角点列(网格)
            guard !点.isEmpty else { return nil }
        } else {
            键 = "程序:\(形状.rawValue)"
        }

        锁.lock()
        let 命中 = 缓存[键]
        锁.unlock()
        if let 命中 { return 命中 }

        if 点.isEmpty {
            // 程序网格：走画面同一份生成器，保证"看到的形状"就是"烧的形状"
            for 片 in PTGeometry.piece(for: 形状) {
                let n = 片.indices.count - 片.indices.count % 3
                var i = 0
                while i < n {
                    点.append(片.positions[Int(片.indices[i])])
                    点.append(片.positions[Int(片.indices[i + 1])])
                    点.append(片.positions[Int(片.indices[i + 2])])
                    i += 3
                }
            }
        }
        guard !点.isEmpty else { return nil }

        let 数据 = 对象几何数据(键: 键, 三角点: 点)
        锁.lock()
        if 缓存.count > 32 { 缓存.removeAll() }
        缓存[键] = 数据
        锁.unlock()
        return 数据
    }
}

/// 一张体素化的表面距离场（米）。渲染线程只读，构建完就不再变。
final class 对象表面场 {
    let 键: String
    let 边长: Int
    /// 域盒半宽（米）
    let 半宽: Float
    /// 域盒高（米），域盒局部 y 从 0 到 高
    let 高: Float
    /// 域盒底面在对象局部空间里的 y
    let 底偏移: Float
    /// 距离场，索引 = x + n*(y + n*z)，x 最快 —— 与模拟纹理逐体素对齐
    let 距离: [Float]
    /// 表面采样点（局部坐标，已含底偏移），给粒子类发射用
    let 点: [SIMD4<Float>]
    /// 对应法向
    let 法向: [SIMD4<Float>]

    init(键: String, 边长: Int, 半宽: Float, 高: Float, 底偏移: Float,
         距离: [Float], 点: [SIMD4<Float>], 法向: [SIMD4<Float>]) {
        self.键 = 键; self.边长 = 边长; self.半宽 = 半宽; self.高 = 高
        self.底偏移 = 底偏移; self.距离 = 距离; self.点 = 点; self.法向 = 法向
    }
}

/// 表面场的构建与缓存（按 几何 + 域盒 + 网格尺寸 三元组）
enum 对象表面场库存 {
    private static let 锁 = NSLock()
    private static var 缓存: [String: 对象表面场] = [:]

    /// 取（必要时构建）。几何为空（网格还没进池等）时返回 nil，调用方退回老喷口行为。
    static func 取(几何: 对象几何数据?, 设置: 特效设置, 网格边长: Int) -> 对象表面场? {
        guard let 几何, !几何.三角点.isEmpty else { return nil }
        let n = max(8, 网格边长)
        let 盒 = 设置.体积域盒(几何: 几何)
        let 键 = "\(几何.键)|\(n)|\(盒.半宽)|\(盒.高)|\(盒.底)"
        锁.lock()
        let 命中 = 缓存[键]
        锁.unlock()
        if let 命中 { return 命中 }

        let 场 = 构建(几何: 几何, 半宽: 盒.半宽, 高: 盒.高, 底: 盒.底, 边长: n, 键: 键)
        锁.lock()
        if 缓存.count > 8 { 缓存.removeAll() }
        缓存[键] = 场
        锁.unlock()
        return 场
    }

    // MARK: 体素化

    private static func 构建(几何: 对象几何数据, 半宽: Float, 高: Float, 底: Float,
                           边长 n: Int, 键: String) -> 对象表面场 {
        let 体x = 2 * 半宽 / Float(n)
        let 体y = 高 / Float(n)
        // 远离几何的体素保持"很远"，kernel 读到它就不会供料
        var 距 = [Float](repeating: 1e3, count: n * n * n)
        let 点 = 几何.三角点
        let 三角数 = 点.count / 3
        // 三角形包围盒外扩 2 个体素：薄壳不至于在体素尺度上被切出锯齿洞
        let 外扩 = 2

        距.withUnsafeMutableBufferPointer { buf in
            guard let 基 = buf.baseAddress else { return }
            var t = 0
            while t < 三角数 {
                // 场坐标：y 减去底偏移，让域盒底面 = 0
                let A = 场点(点[t * 3], 底)
                let B = 场点(点[t * 3 + 1], 底)
                let C = 场点(点[t * 3 + 2], 底)
                let 小 = simd_min(simd_min(A, B), C)
                let 大 = simd_max(simd_max(A, B), C)

                let ix0 = max(0, Int(floor((小.x + 半宽) / 体x - 0.5)) - 外扩)
                let ix1 = min(n - 1, Int(ceil((大.x + 半宽) / 体x - 0.5)) + 外扩)
                let iy0 = max(0, Int(floor(小.y / 体y - 0.5)) - 外扩)
                let iy1 = min(n - 1, Int(ceil(大.y / 体y - 0.5)) + 外扩)
                let iz0 = max(0, Int(floor((小.z + 半宽) / 体x - 0.5)) - 外扩)
                let iz1 = min(n - 1, Int(ceil((大.z + 半宽) / 体x - 0.5)) + 外扩)
                if ix0 > ix1 || iy0 > iy1 || iz0 > iz1 {
                    t += 1
                    continue
                }

                for iz in iz0...iz1 {
                    let pz = (Float(iz) + 0.5) * 体x - 半宽
                    for iy in iy0...iy1 {
                        let py = (Float(iy) + 0.5) * 体y
                        let 行基 = n * (iy + n * iz)
                        for ix in ix0...ix1 {
                            let px = (Float(ix) + 0.5) * 体x - 半宽
                            let d = 点三角距离(SIMD3<Float>(px, py, pz), A, B, C)
                            if d < 基[行基 + ix] { 基[行基 + ix] = d }
                        }
                    }
                }
                t += 1
            }
        }

        let (采样点, 采样法向) = 表面采样(点: 点, 底: 底, 上限: 512)
        return 对象表面场(键: 键, 边长: n, 半宽: 半宽, 高: 高, 底偏移: 底,
                     距离: 距, 点: 采样点, 法向: 采样法向)
    }

    @inline(__always)
    private static func 场点(_ p: SIMD3<Float>, _ 底: Float) -> SIMD3<Float> {
        SIMD3<Float>(p.x, p.y - 底, p.z)
    }

    /// 点到三角形的最近距离（Ericson, Real-Time Collision Detection §5.1.5）
    @inline(__always)
    private static func 点三角距离(_ p: SIMD3<Float>,
                              _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> Float {
        let ab = b - a, ac = c - a, ap = p - a
        let d1 = simd_dot(ab, ap), d2 = simd_dot(ac, ap)
        if d1 <= 0 && d2 <= 0 { return simd_length(ap) }

        let bp = p - b
        let d3 = simd_dot(ab, bp), d4 = simd_dot(ac, bp)
        if d3 >= 0 && d4 <= d3 { return simd_length(bp) }

        let vc = d1 * d4 - d3 * d2
        if vc <= 0 && d1 >= 0 && d3 <= 0 {
            let v = d1 / (d1 - d3)
            return simd_length(p - (a + ab * v))
        }

        let cp = p - c
        let d5 = simd_dot(ab, cp), d6 = simd_dot(ac, cp)
        if d6 >= 0 && d5 <= d6 { return simd_length(cp) }

        let vb = d5 * d2 - d1 * d6
        if vb <= 0 && d2 >= 0 && d6 <= 0 {
            let w = d2 / (d2 - d6)
            return simd_length(p - (a + ac * w))
        }

        let va = d3 * d6 - d5 * d4
        if va <= 0 && (d4 - d3) >= 0 && (d5 - d6) >= 0 {
            let w = (d4 - d3) / ((d4 - d3) + (d5 - d6))
            return simd_length(p - (b + (c - b) * w))
        }

        let 倒数 = 1 / (va + vb + vc)
        let v = vb * 倒数, w = vc * 倒数
        return simd_length(p - (a + ab * v + ac * w))
    }

    /// 表面面积加权采样：粒子类发射要用"表面上随便一个点 + 那个点的法向"
    private static func 表面采样(点: [SIMD3<Float>], 底: Float,
                           上限: Int) -> ([SIMD4<Float>], [SIMD4<Float>]) {
        let 三角数 = 点.count / 3
        guard 三角数 > 0 else { return ([], []) }
        var 累积 = [Float](repeating: 0, count: 三角数)
        var 总: Float = 0
        for t in 0..<三角数 {
            let a = 点[t * 3], b = 点[t * 3 + 1], c = 点[t * 3 + 2]
            总 += 0.5 * simd_length(simd_cross(b - a, c - a))
            累积[t] = 总
        }
        guard 总 > 1e-9 else { return ([], []) }

        var 采样点: [SIMD4<Float>] = []
        var 采样法向: [SIMD4<Float>] = []
        采样点.reserveCapacity(上限)
        采样法向.reserveCapacity(上限)
        var 种子: UInt64 = 0x9E3779B97F4A7C15
        func 随机() -> Float {
            种子 = 种子 &* 6364136223846793005 &+ 1442695040888963407
            return Float((种子 >> 33) & 0xFFFFFF) / Float(0xFFFFFF)
        }
        for _ in 0..<上限 {
            let r = 随机() * 总
            // 二分找面积前缀
            var 低 = 0, 高 = 三角数 - 1
            while 低 < 高 {
                let 中 = (低 + 高) / 2
                if 累积[中] < r { 低 = 中 + 1 } else { 高 = 中 }
            }
            let t = 低
            let a = 点[t * 3], b = 点[t * 3 + 1], c = 点[t * 3 + 2]
            var u = 随机(), v = 随机()
            if u + v > 1 { u = 1 - u; v = 1 - v }
            let 位置 = a + (b - a) * u + (c - a) * v
            var 法 = simd_cross(b - a, c - a)
            let 长 = simd_length(法)
            法 = 长 > 1e-9 ? 法 / 长 : SIMD3<Float>(0, 1, 0)
            采样点.append(SIMD4<Float>(位置.x, 位置.y - 底, 位置.z, 1))
            采样法向.append(SIMD4<Float>(法, 0))
        }
        return (采样点, 采样法向)
    }
}
