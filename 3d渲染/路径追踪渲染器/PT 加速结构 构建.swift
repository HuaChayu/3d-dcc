import Foundation
import Metal
import simd

// MARK: - 加速结构

/// 把三角形汤包成 BLAS + 单实例 IAS（硬件光追）。
/// 为什么做得这么绕：Metal 着色器里 ray 的 intersect 只吃 instance_acceleration_structure，
/// 所以哪怕只有一个 BLAS，也得套一层只有一条实例的 IAS 才能拿硬件求交。
final class PTAcceleration {

    struct Payload {
        var vertexBuffer: MTLBuffer
        var normalBuffer: MTLBuffer
        var indexBuffer: MTLBuffer
        var triangleMaterialBuffer: MTLBuffer
        var materialBuffer: MTLBuffer
        var lightTriangleBuffer: MTLBuffer
        var lightCDFBuffer: MTLBuffer
        var lightCount: Int
        /// 显式灯光（灯对象）数组：不占几何，只在直接光采样里被抽到
        var lightsBuffer: MTLBuffer
        /// 显式灯亮度权重 CDF（与 lightsBuffer 同长，float32）
        var lightsCDFBuffer: MTLBuffer
        var lightsCount: Int
        /// 灯 AABB 树节点数组（保守剔除用，只有 traceLightSurface 读它）
        var lightNodeBuffer: MTLBuffer
        /// 叶内灯下标顺序（节点里的 首项 是它的小标）
        var lightOrderBuffer: MTLBuffer
        /// 节点数；0 = 这一代没有可用树（着色器整体退回线性扫描）
        var lightNodeCount: Int
        /// 建树时的灯总数：与 lightsCount 不等时着色器会整体退回线性扫描（防下标越界）
        var lightTreeLightsCount: Int
        /// 每顶点图集 UV + 每顶点 slice（绘画采样用）
        var uvBuffer: MTLBuffer
        var sliceBuffer: MTLBuffer
        /// 每顶点镂空洞格位（不进几何，与 sliceBuffer 一起原地刷新）
        var holeSlotBuffer: MTLBuffer
        /// 特效发射器（体积介质源）：按固定上限分配，每帧原地重写。
        /// 不进加速结构签名 —— 拖发射器/调参数不会重建 BLAS，也不会让几何段换代。
        var emitterBuffer: MTLBuffer
        var hasPaint: Bool
        var instanceAcceleration: MTLAccelerationStructure
        var blas: MTLAccelerationStructure
        var triangleCount: Int
    }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private var cachedSignature: String?
    /// 变换段（对象位置/旋转/缩放）：只有它变了才需要重烘顶点 + refit；几何段/灯段都不动。
    /// 【唯一判据 = 变换域版本号】旧的字符串哈希与回滚开关已整段删除（不做新旧双轨）。
    private var cached变换版本: UInt64?

    /// 变换到底变没变：只读变换域版本号。首次调用算"变了"，
    /// 因此不会出现"没建过却以为没变"。
    private func 变换段变了(_ scene: PTScene) -> Bool {
        guard let 上次 = cached变换版本 else { return true }
        return 上次 != scene.变换版本
    }
    /// 灯变换版本（数据层快照：灯的矩阵）：只驱动灯缓冲 + 灯树重建，加速结构一个字节都不碰。
    /// 【口径统一】与渲染器判定同源——都读 灯光接线.同步 产出的那两个单调版本号，
    /// 不再各自维护一份字符串哈希（哈希会因改名/字段抖动误判，版本号只在值真变时自增）。
    private var cached灯变换版本: UInt64?
    /// 灯参数版本（缓存这一代 lightsBuffer/lightsCDF 是按哪个参数版本写进去的）。
    /// 灯不进加速结构，所以它跟 cachedSignature 分开记：几何签名一致、只有灯变了时，
    /// 走「原地重写灯缓冲」而不是换代。
    private var cached灯光参数版本: UInt64?
    /// 灯几何指纹（位置/朝向/尺寸/种类/半径）：只有它变了才需要重算灯树。
    /// 亮度、颜色不进这段指纹 —— 拖强度滑杆时灯面几何没动，树没必要重建。
    private var cached灯几何指纹: UInt64?
    private var cached: Payload?
    /// 最近几代被替换掉的加速结构：命令缓冲是异步提交的，
    /// 上一帧的 AS 可能还在 GPU 上飞行，重建时立刻放掉就会让求交读到无效内存
    ///（画面退化成纯天空灰雾）。这里多留几代，等 GPU 自然消化完。
    private var retired: [Payload] = []
    /// 留多少代。这里必须给足：现在 reset（相机/几何/参数/绘画/尺寸）都会换代，
    /// 连续拖动或连续下笔时一秒能换十几代；如果留得太少，旧的 AS 会在 GPU 还在求交时被释放，
    /// 求交读到已释放内存 → 全屏 miss → 只剩环境色（棕/灰雾），也就是反复出现的"整屏单色"。
    private let retiredLimit = 8

    init(device: MTLDevice, queue: MTLCommandQueue) {
        self.device = device
        self.queue = queue
    }

    private var 复用次数 = 0
    /// 最近一次提交里 BLAS 到底是复用还是重建、IAS 走的是 refit 还是 rebuild
    private(set) var 本次IAS方式 = "无"
    private(set) var 本次BLAS复用 = false
    /// 【失败原因取证】廉价路径返回 false 时，这里写明是哪一条 guard 挡的。
    /// 只为了日志能直接指出「为什么拖灯帧落到了全量重建」，不参与任何判定。
    private(set) var 上次灯刷新失败原因 = ""
    private(set) var 上次材质刷新失败原因 = ""
    private(set) var 上次增量失败原因 = ""

    func payload(for scene: PTScene) -> Payload? {
        // 【只比几何段】以前比的是整体签名，于是拖一下材质色相/环境亮度都会把整棵 BLAS
        // 当成"场景变了"重建一次 —— 重建是 O(三角形数)，大场景里就是几毫秒到十几毫秒的
        // GPU 空转，而且每次换代还得多留一代旧 AS（显存）。材质/环境根本不进加速结构，
        // 它们各自的廉价路径见 刷新材质() 与渲染器的分段判定。
        if let cached, cachedSignature == scene.几何签名, !scene.isEmpty {
            // 【灯参数变化】：几何签名一致说明三角形/结构完全没动，但灯可能被拖过滑杆。
            // 灯不入加速结构，只吃 lightsBuffer + lightsCDF，所以这里就地重写两个小缓冲。
            // 失败（盏数变了 → 容量对不上）就落到下面全量 build，绝不让旧容量的缓冲继续服役。
            // 【判据 = 快照版本号】参数版本管功率/色温/尺寸/锥角/朝向，灯变换版本管位置矩阵，
            // 两者合一：只要任一推进，就地重写灯缓冲 + 灯 CDF + 灯树（位置变了树必须跟着挪）。
            if cached灯光参数版本 != scene.灯光版本 || cached灯变换版本 != scene.灯变换版本 {
                if 原地刷新灯(scene) {
                    NSLog("PTDBG AS 灯光原地刷新（免换代）灯数=\(scene.lights.count)")
                } else {
                    NSLog("PTDBG AS 灯数变化 → 回落全量重建 旧灯数=\(cached.lightsCount) 新灯数=\(scene.lights.count)")
                    // 落到下面 build：灯缓冲必须按新容量重新分配
                    return 重建并缓存(scene)
                }
            }
            // 【仅变换变化】几何段（拓扑）没变、只是对象被拖动过：
            // BLAS 必须原样复用，只按新变换重烘顶点 + refit + 重建实例层（O(1)）。
            // 绝不走 重建并缓存()：那是 O(n log n) 重排 BVH，也就是拖动物体卡顿/残影的来源。
            if 变换段变了(scene) {
                if 增量重建(scene) {
                    NSLog("PTDBG AS 仅变换变化 → BLAS 复用 + refit tris=\(scene.triangleCount)")
                    本次IAS方式 = "refit"
                    本次BLAS复用 = true
                } else {
                    NSLog("PTDBG AS 变换变化但拓扑对不上 → 回落全量重建")
                    return 重建并缓存(scene)
                }
            }
            复用次数 += 1
            if 复用次数 % 120 == 0 {
                NSLog("PTDBG AS REUSE 累计\(复用次数) 次（同一代加速结构在反复求交）")
            }
            return cached
        }
        return 重建并缓存(scene)
    }

    /// 全量重建并把三段签名一起记上
    private func 重建并缓存(_ scene: PTScene) -> Payload? {
        世代号 &+= 1
        NSLog("PTDBG AS REBUILD geom=\(scene.几何签名) tris=\(scene.triangleCount)")
        guard let built = build(scene) else { NSLog("PTDBG AS build FAILED"); return nil }
        cached = built
        cachedSignature = scene.几何签名
        cached灯光参数版本 = scene.灯光版本
        cached变换版本 = scene.变换版本
        cached灯变换版本 = scene.灯变换版本
        本次IAS方式 = "rebuild"
        本次BLAS复用 = false
        return built
    }

    /// 材质/灯池原地刷新：几何没变时，只把材质数组和灯光池拷进现有缓冲，
    /// 加速结构一个字节都不动。
    /// - Returns: true = 已就地刷新，不用换代；false = 这条路径不适合原地改（容量不够/几何也变了），调用方该换代
    @discardableResult
    func 刷新材质(_ scene: PTScene) -> Bool {
        guard let payload = cached, cachedSignature == scene.几何签名, !scene.isEmpty else { return false }
        // 【盏数必须一致】灯被增删/启停时缓冲得按新容量重新分配，不能沿用旧容量的缓冲 ——
        // 这里不负责扩容，直接返回 false 让调用方换代。
        guard scene.lights.count == payload.lightsCount else { return false }
        // 容量必须沿用「建的时候申请的」那份：数组变长就装不下，老老实实换代
        guard scene.materials.count <= payload.materialBuffer.length / MemoryLayout<PTMaterialGPU>.stride,
              scene.lights.count <= payload.lightsBuffer.length / MemoryLayout<PTLightGPU>.stride,
              scene.lightsCDF.count <= payload.lightsCDFBuffer.length / MemoryLayout<Float>.stride,
              scene.lightTriangles.count <= payload.lightTriangleBuffer.length / MemoryLayout<UInt32>.stride,
              scene.lightCDF.count <= payload.lightCDFBuffer.length / MemoryLayout<Float>.stride
        else { return false }

        写(scene.materials, 到: payload.materialBuffer)
        写(scene.lightTriangles, 到: payload.lightTriangleBuffer)
        写(scene.lightCDF, 到: payload.lightCDFBuffer)
        写(scene.lights, 到: payload.lightsBuffer)
        写(scene.lightsCDF, 到: payload.lightsCDFBuffer)
        // 计数是 Payload 里的值字段：材质数/自发光数变了要跟着改，否则着色器按旧上限抽光源
        cached?.lightCount = scene.lightCount
        cached?.lightsCount = scene.lightsCount
        // 灯的「几何」也可能跟着变了（拖位置/尺寸/朝向）：灯树同步重建。
        // 只改亮度/颜色时几何指纹不变，这里什么都不做，不会白算一遍树。
        原地刷新灯树(scene)
        // 灯缓冲这一路上也跟着写了，两个灯版本一并记上（否则下一次 payload 会白刷一遍）
        cached灯光参数版本 = scene.灯光版本
        cached变换版本 = scene.变换版本
        cached灯变换版本 = scene.灯变换版本
        return true
    }

    /// 重建灯树并写进当前这一代的缓冲（CPU 建好、一次 memcpy 上传）。
    /// 只在「灯几何指纹」变了才真的重算；只改亮度/颜色不会进这里。
    /// - Returns: true = 树可用且灯数与当前一致；false = 这一代没有树（着色器整体退回线性扫描）
    @discardableResult
    private func 原地刷新灯树(_ scene: PTScene) -> Bool {
        guard var payload = cached else { return false }
        let 指纹 = PTLightTreeBuilder.几何指纹(scene.lights)
        if 指纹 == cached灯几何指纹,
           payload.lightNodeCount > 0,
           payload.lightTreeLightsCount == scene.lights.count {
            return true
        }
        cached灯几何指纹 = 指纹
        let 开始 = CFAbsoluteTimeGetCurrent()
        let 树 = PTLightTreeBuilder.构建(scene.lights)
        let 耗时 = (CFAbsoluteTimeGetCurrent() - 开始) * 1000.0
        guard let 树, !树.节点.isEmpty,
              树.节点.count * MemoryLayout<PTLightNodeGPU>.stride <= payload.lightNodeBuffer.length,
              树.顺序.count * MemoryLayout<UInt32>.stride <= payload.lightOrderBuffer.length
        else {
            // 装不下 / 灯参数非法：这一代彻底关掉树（着色器按线性扫），灯数必须写 0，
            // 否则着色器会相信树里的下标去读灯数组之外
            payload.lightNodeCount = 0
            payload.lightTreeLightsCount = 0
            cached = payload
            return false
        }
        写(树.节点, 到: payload.lightNodeBuffer)
        写(树.顺序, 到: payload.lightOrderBuffer)
        payload.lightNodeCount = 树.节点.count
        payload.lightTreeLightsCount = scene.lights.count
        cached = payload
        if scene.lights.count > 64, 耗时 > 1.0 {
            NSLog("[PT灯树] 原地重建 灯数=\(scene.lights.count) 节点=\(树.节点.count) 耗时=\(String(format: "%.2f", 耗时))ms 超出 1ms 预算")
        }
        return true
    }

    /// 灯参数原地刷新：只改灯（功率/颜色/尺寸/角度/朝向/位置）时走这条。
    /// 灯不存在于加速结构里 —— 它只是一个被 NEE 抽样、被 traceLightSurface 画出来的小数组，
    /// 所以拖功率滑杆不该让整棵 BLAS 换代。
    /// - Returns: true = 灯缓冲已就地改写；false = 盏数/容量对不上，调用方必须走全量重建
    @discardableResult
    func 刷新灯光(_ scene: PTScene) -> Bool {
        guard 原地刷新灯(scene) else { return false }
        cached灯光参数版本 = scene.灯光版本
        return true
    }

    /// 原地写灯缓冲与灯 CDF（两者必须同时写，只写一个会让"抽到的灯"和"权的分母"错位）
    private func 原地刷新灯(_ scene: PTScene) -> Bool {
        guard let payload = cached, cachedSignature == scene.几何签名, !scene.isEmpty else { return false }
        // 盏数必须逐一相等：增删灯要重新分配缓冲（沿用旧容量会写出界 / 少写一段）
        guard scene.lights.count == payload.lightsCount,
              scene.lightsCDF.count == scene.lights.count
        else { return false }
        guard scene.lights.count * MemoryLayout<PTLightGPU>.stride <= payload.lightsBuffer.length,
              scene.lightsCDF.count * MemoryLayout<Float>.stride <= payload.lightsCDFBuffer.length
        else { return false }
        // 两份一起写：只更新 lightsBuffer 会让概率分布与灯参数脱钩（灯亮着却按旧权重被抽）
        写(scene.lights, 到: payload.lightsBuffer)
        写(scene.lightsCDF, 到: payload.lightsCDFBuffer)
        cached?.lightsCount = scene.lightsCount
        // 【灯树必须跟位置一起刷】灯树是 traceLightSurface 的保守剔除结构：灯一挪而 AABB
        // 留在旧位置，剔除就会把灯面整片切掉 —— 拖灯时"全黑/灯面消失"就是它。
        // 这里只在 CPU 建树 + memcpy 两个小缓冲，不碰 BLAS/IAS。
        原地刷新灯树(scene)
        // 记账写在最内层：payload(for:) 与 刷新灯光() 两条入口都经过这里，
        // 不管从哪进来，下一次比对都不会重复刷同一版本。
        cached灯光参数版本 = scene.灯光版本
        cached灯变换版本 = scene.灯变换版本
        return true
    }

    /// 就地覆盖 buffer 内容；内容相同直接跳过，免得拖参数时白拷几 MB
    private func 写<T>(_ 源: [T], 到 目标: MTLBuffer) {
        guard !源.isEmpty else { return }
        let 字节数 = 源.count * MemoryLayout<T>.stride
        guard 字节数 <= 目标.length else { return }
        源.withUnsafeBytes { 源缓冲 in
            guard let 基址 = 源缓冲.baseAddress else { return }
            let 目标址 = 目标.contents()
            if memcmp(目标址, 基址, 字节数) == 0 { return }
            memcpy(目标址, 基址, 字节数)
        }
    }

    /// 只刷新 slice 表：绘画从「一笔没有」变成「有笔迹」时，图集下标才第一次有值。
    /// 这份数据不影响几何，原地重写 sliceBuffer 就够 —— 绝不能为它重建加速结构。
    ///
    /// 【必须每帧调一次，不能只在 revision 变化的那一帧调】
    /// 图集下标会随「谁有笔迹 / 图集重建 / 对象显隐」变动，而它不进 signature，
    /// 所以缓存的这一代加速结构永远不会为它重建。只在 revision 变化帧写一次的话，
    /// 一旦那一帧拿到的是转译早于刷新图集的旧表（首次落笔必然如此），
    /// 这张「全 0xFFFFFFFF / 错位」的表就会被永久缓存住：
    /// 表现就是「第一次进 PT 画看不到，切个模式回来才有」，
    /// 以及「偶尔把整个模型涂成笔刷色」（撞到别人的 slice）。
    /// 幂等：内容相同不做拷贝，所以每帧调也不花钱。
    /// - Returns: true = 缓存这一代签名一致、已就地改写；false = 没有可复用的缓存（下次构建会取到新值）
    @discardableResult
    func 更新切片(_ scene: PTScene) -> Bool {
        guard let cached, cachedSignature == scene.几何签名 else { return false }
        let 步长 = MemoryLayout<UInt32>.stride
        func 同步(_ 源表: [UInt32], 到 目标: MTLBuffer) {
            let 可写数量 = 目标.length / 步长
            let 数量 = min(源表.count, 可写数量)
            guard 数量 > 0 else { return }
            let 字节数 = 数量 * 步长
            源表.withUnsafeBufferPointer { 源 in
                guard let 基址 = 源.baseAddress else { return }
                let 目标址 = 目标.contents()
                if memcmp(目标址, 基址, 字节数) == 0 { return }
                memcpy(目标址, 基址, 字节数)
            }
        }
        同步(scene.vertexSlice, 到: cached.sliceBuffer)
        // 洞格位和 slice 一样不进 signature，但会随镂空/撤销变，必须每帧一起刷
        同步(scene.vertexHoleSlot, 到: cached.holeSlotBuffer)
        return true
    }

    // MARK: 增量重建（refit）素材

    /// refit 需要、但 Payload 里没有留的几样东西：实例缓冲（IAS 重建要指回它）+ 两份 scratch。
    private struct 增量素材包 {
        var instanceBuffer: MTLBuffer
        var refitScratch: MTLBuffer
        var instanceScratch: MTLBuffer
    }

    private var 增量素材: 增量素材包?
    private var 已增量次数 = 0
    /// refit 只重算 AABB、不重排节点，连续 refit 多了遍历顺序会越来越差。
    /// 超过这个次数就老老实实做一次全量 build 把质量找回来。
    private let 增量上限 = 24

    // MARK: - 灯段 / 诊断用的只读探针（渲染器判定分支与日志用，不改任何状态）

    /// 当前是否持有一代加速结构（载荷）。首帧/换代后为 false。
    var 有缓存: Bool { cached != nil }

    /// 加速结构世代号：每次真正重建并缓存自增，用于日志里区分"是不是同一颗 AS 在退化"
    private(set) var 世代号: UInt64 = 0

    /// 日志用的世代描述
    var 世代描述: String { "gen=\(世代号)" }

    /// 缓存那一代的灯盏数是否与当前场景一致：只有盏数变了才必须重新分配灯缓冲（此时换代合法）
    func 灯盏数与缓存一致(_ scene: PTScene) -> Bool {
        guard let payload = cached else { return false }
        return payload.lightsCount == scene.lights.count
    }

    func invalidate() {
        // 旧的一代不立刻丢：可能还有命令缓冲在 GPU 上用它求交
        if let old = cached {
            retired.append(old)
            if retired.count > retiredLimit { retired.removeFirst() }
        }
        cached = nil
        cachedSignature = nil
        cached灯光参数版本 = nil
        cached变换版本 = nil
        cached灯变换版本 = nil
        // 换代时增量素材一起作废：它的 instanceBuffer / scratch 都绑着上一代 BLAS
        增量素材 = nil
        已增量次数 = 0
    }

    // MARK: 增量重建（只重算 AABB，不重建 BVH）

    /// 拓扑是否与缓存那一代完全一致：三角形数、顶点字节、索引字节全同才算「只挪了顶点」。
    /// 索引必须逐字节比 —— 数量相同但连接关系换了（换网格、洞位变化、切片变化）时，
    /// 对旧 BVH 做 refit 会给出错误求交（表现为穿模或全屏 miss），必须走全量 build。
    private func 拓扑一致(_ payload: Payload, _ scene: PTScene) -> Bool {
        guard !scene.isEmpty else { return false }
        guard payload.triangleCount == scene.triangleCount else { return false }
        guard payload.vertexBuffer.length == scene.positions.count * MemoryLayout<SIMD4<Float>>.stride else { return false }
        guard payload.indexBuffer.length == scene.indices.count * MemoryLayout<UInt32>.stride else { return false }
        guard payload.sliceBuffer.length == max(scene.vertexSlice.count, 1) * MemoryLayout<UInt32>.stride else { return false }
        // 这里必须跟 build() 里的分配口径逐字对齐：holeSlot 是按 UInt32 分配的，
        // 早先这里误写成 SIMD4<Float>.stride（4 字节 vs 16 字节），对任何 count 都恒不相等
        // → 拓扑一致() 永远 false → 增量重建() 永远失败 → 出图每批都走 invalidate + 全量 build。
        // 也就是说「refit」这条路径从头到尾没有真正执行过一次。
        guard payload.holeSlotBuffer.length == max(scene.vertexHoleSlot.count, 1) * MemoryLayout<UInt32>.stride else { return false }
        return scene.indices.withUnsafeBytes { 新索引 in
            guard let 新址 = 新索引.baseAddress else { return false }
            return memcmp(payload.indexBuffer.contents(), 新址, 新索引.count) == 0
        }
    }

    /// 对外入口：几何变了但拓扑没变（拖物体 / 雕刻顶点 / 调缩放）时用它。
    /// 返回 true 表示已经 refit 完，调用方不要再去 invalidate()。
    func 增量重建(_ scene: PTScene) -> Bool {
        guard let payload = cached else { return false }

        // 【「签名一致就一根手指都不动 AS」这条已经被实测否掉了，别再写回来】
        // 日志实证（2026-11-08 01:46 那次 4K）：整轮 512 批只在开头 build 了一次，之后
        // 512 帧 / 约 6100 次 dispatch 全部复用同一颗结构（PTDBG AS REUSE 一路涨到 960+），
        // 结果画面被天空色成片摊薄成灰雾 —— 和历史上本机反复出现的「整屏灰雾 / 局部漏交」同源。
        // 也就是说：几何没变 ≠ 结构可以永不触碰，这颗 AS 在本机驱动上长时不写就会退化成错。
        // 所以签名一致也照走下面的 refit：重算 AABB + 节点数据整体重写一遍 + 实例层重建。
        // 成本是 O(三角形数) 的包围盒重算，仍然远低于 O(n log n) 建树，且每批都「碰」一次结构。
        // 【口径修正】原注释写着"refit 满 增量上限 次后自动回落一次全量 build"，
        // 实际代码里没有任何地方读 增量上限（`已增量次数` 只用于日志每 8 次打一条），
        // 也就是说连续 refit 期间**不会**出现周期性全量 build。注释按真实行为改写，
        // 不再让"有个兜底"成为错觉；要不要加周期性彻底刷新是单独的决策，不在这里偷偷加。

        guard 拓扑一致(payload, scene) else { return false }
        guard 增量重建(payload, scene) else { return false }
        cachedSignature = scene.几何签名
        // refit 顺手把灯缓冲也写了（见 增量重建(_:_:)），灯签名同步记上
        cached灯光参数版本 = scene.灯光版本
        cached变换版本 = scene.变换版本
        cached灯变换版本 = scene.灯变换版本
        本次IAS方式 = "refit（实例层重建）"
        本次BLAS复用 = true
        return true
    }

    /// 原地改写顶点类缓冲，再对 BLAS 做 refit。
    /// 成本从「按三角形数完整建一遍 BVH」降到「按三角形数重算 AABB」，
    /// 而且不需要换代、不需要 retired 保留旧显存。
    private func 增量重建(_ payload: Payload, _ scene: PTScene) -> Bool {
        guard let 素材 = 增量素材 else { return false }
        // 先把命令缓冲拿到手：拿不到就直接放弃，绝不能出现「顶点已经改了、refit 没提交」的半截状态
        guard let commandBuffer = queue.makeCommandBuffer() else { return false }

        // 灯与材质顺带刷新；容量装不下就放弃增量（说明这批内容变了规模，交给全量 build）
        // 【编码器必须最后创建】Metal 规定编码器一旦 make 出来就必须 endEncoding 才能释放，
        // 否则 dealloc 时直接命中 Metal 断言，整个进程中止（"Command encoder released without endEncoding"）。
        // 所以所有可能提前 return 的检查都必须排在创建编码器之前：这里就曾经因为
        // 「拖材质给对象 → 材质数超 materialBuffer 容量」在这条 guard 上提前 return，
        // 而编码器已经创建、没 endEncoding，拖一次崩一次。
        guard scene.materials.count * MemoryLayout<PTMaterialGPU>.stride <= payload.materialBuffer.length,
              scene.lights.count * MemoryLayout<PTLightGPU>.stride <= payload.lightsBuffer.length,
              scene.lightsCDF.count * MemoryLayout<Float>.stride <= payload.lightsCDFBuffer.length,
              scene.lightTriangles.count * MemoryLayout<UInt32>.stride <= payload.lightTriangleBuffer.length,
              scene.lightCDF.count * MemoryLayout<Float>.stride <= payload.lightCDFBuffer.length
        else { return false }

        // 走到这里之后不再有任何提前退出，创建 → 编码 → endEncoding → commit 一路到底
        guard let encoder = commandBuffer.makeAccelerationStructureCommandEncoder()
        else { return false }

        写(scene.positions, 到: payload.vertexBuffer)
        写(scene.normals, 到: payload.normalBuffer)
        写(scene.uvs, 到: payload.uvBuffer)
        写(scene.triangleMaterial, 到: payload.triangleMaterialBuffer)
        写(scene.vertexSlice, 到: payload.sliceBuffer)
        写(scene.vertexHoleSlot, 到: payload.holeSlotBuffer)
        写(scene.materials, 到: payload.materialBuffer)
        写(scene.lights, 到: payload.lightsBuffer)
        写(scene.lightsCDF, 到: payload.lightsCDFBuffer)
        写(scene.lightTriangles, 到: payload.lightTriangleBuffer)
        写(scene.lightCDF, 到: payload.lightCDFBuffer)
        // 【灯数同步】Payload 是 struct，这里拿到的是值拷贝，改局部变量不会回到缓存那一代，
        // 所以照 刷新材质() 的写法直接改 cached。计数是着色器抽光源的上限：
        // 只 memcpy 灯缓冲不改计数，灯数量一变就按旧上限抽，显式灯采样直接错位。
        cached?.lightCount = scene.lightCount
        cached?.lightsCount = scene.lightsCount
        // 灯树跟着这一代一起刷新（几何指纹不变就什么都不做）；容量装不下会自动关树，不会越界
        原地刷新灯树(scene)

        let geometry = MTLAccelerationStructureTriangleGeometryDescriptor()
        geometry.vertexBuffer = payload.vertexBuffer
        geometry.vertexBufferOffset = 0
        geometry.vertexStride = MemoryLayout<SIMD4<Float>>.stride
        geometry.indexBuffer = payload.indexBuffer
        geometry.indexBufferOffset = 0
        geometry.indexType = .uint32
        geometry.triangleCount = payload.triangleCount
        geometry.primitiveDataBuffer = payload.triangleMaterialBuffer
        geometry.primitiveDataStride = MemoryLayout<UInt32>.stride
        geometry.primitiveDataElementSize = MemoryLayout<UInt32>.stride

        let primitiveDescriptor = MTLPrimitiveAccelerationStructureDescriptor()
        primitiveDescriptor.geometryDescriptors = [geometry]
        // refit 的 descriptor 也必须带同一份 usage，否则这一步同样不生效
        primitiveDescriptor.usage = .refit

        let instanceDescriptor = MTLInstanceAccelerationStructureDescriptor()
        instanceDescriptor.instanceCount = 1
        instanceDescriptor.instanceDescriptorBuffer = 素材.instanceBuffer
        instanceDescriptor.instancedAccelerationStructures = [payload.blas]

        encoder.refit(
            sourceAccelerationStructure: payload.blas,
            descriptor: primitiveDescriptor,
            destinationAccelerationStructure: payload.blas,
            scratchBuffer: 素材.refitScratch,
            scratchBufferOffset: 0
        )
        // 实例层里存着子结构的包围盒，顶点一挪就可能跑到旧盒子外面去 → 实例层每次都重建。
        // 只有 1 个实例，成本 O(1)，不重建会出现「物体拖出原来位置就局部漏交」的诡异现象。
        encoder.build(
            accelerationStructure: payload.instanceAcceleration,
            descriptor: instanceDescriptor,
            scratchBuffer: 素材.instanceScratch,
            scratchBufferOffset: 0
        )
        encoder.endEncoding()
        commandBuffer.addCompletedHandler { buffer in
            if buffer.status != .completed {
                NSLog("PTDBG AS refit 失败 status=\(buffer.status.rawValue) err=\(String(describing: buffer.error))")
            }
        }
        commandBuffer.commit()

        已增量次数 += 1
        if 已增量次数 == 1 || 已增量次数 % 8 == 0 {
            NSLog("PTDBG AS refit 第\(已增量次数)次（拓扑未变，只重算 AABB）tris=\(payload.triangleCount)")
        }
        return true
    }

    // MARK: 构建

    private func build(_ scene: PTScene) -> Payload? {
        guard !scene.isEmpty else { return nil }

        let vertexLength = scene.positions.count * MemoryLayout<SIMD4<Float>>.stride
        let indexLength = scene.indices.count * MemoryLayout<UInt32>.stride
        let triMaterialLength = max(scene.triangleMaterial.count, 1) * MemoryLayout<UInt32>.stride
        let materialLength = max(scene.materials.count, 1) * MemoryLayout<PTMaterialGPU>.stride

        // ---- 灯 AABB 树（CPU 建、上传 GPU，只给 traceLightSurface 做保守剔除）----
        // 节点数上界 2N-1：叶至少 1 盏、每切一次只多一个内部节点。
        // 按上界一次分配，之后灯几何怎么改都只 memcpy、不重建缓冲（换代会重新分配）。
        let 灯树开始 = CFAbsoluteTimeGetCurrent()
        let 灯树 = PTLightTreeBuilder.构建(scene.lights)
        let 灯树耗时 = (CFAbsoluteTimeGetCurrent() - 灯树开始) * 1000.0
        let 灯节点容量 = max(scene.lights.count * 2 - 1, 1)
        let 灯顺序容量 = max(scene.lights.count, 1)

        guard
            let vertexBuffer = device.makeBuffer(bytes: scene.positions, length: vertexLength, options: .storageModeShared),
            let normalBuffer = device.makeBuffer(bytes: scene.normals, length: scene.normals.count * MemoryLayout<SIMD4<Float>>.stride, options: .storageModeShared),
            let indexBuffer = device.makeBuffer(bytes: scene.indices, length: indexLength, options: .storageModeShared),
            let triangleMaterialBuffer = device.makeBuffer(bytes: scene.triangleMaterial, length: triMaterialLength, options: .storageModeShared),
            let materialBuffer = device.makeBuffer(bytes: scene.materials, length: materialLength, options: .storageModeShared),
            let lightTriangleBuffer = device.makeBuffer(bytes: scene.lightTriangles, length: max(scene.lightTriangles.count, 1) * MemoryLayout<UInt32>.stride, options: .storageModeShared),
            let lightCDFBuffer = device.makeBuffer(bytes: scene.lightCDF, length: max(scene.lightCDF.count, 1) * MemoryLayout<Float>.stride, options: .storageModeShared),
            let lightsBuffer = device.makeBuffer(bytes: scene.lights, length: max(scene.lights.count, 1) * MemoryLayout<PTLightGPU>.stride, options: .storageModeShared),
            let lightsCDFBuffer = device.makeBuffer(bytes: scene.lightsCDF, length: max(scene.lightsCDF.count, 1) * MemoryLayout<Float>.stride, options: .storageModeShared),
            let lightNodeBuffer = device.makeBuffer(length: 灯节点容量 * MemoryLayout<PTLightNodeGPU>.stride, options: .storageModeShared),
            let lightOrderBuffer = device.makeBuffer(length: 灯顺序容量 * MemoryLayout<UInt32>.stride, options: .storageModeShared),
            let uvBuffer = device.makeBuffer(bytes: scene.uvs, length: max(scene.uvs.count, 1) * MemoryLayout<SIMD2<Float>>.stride, options: .storageModeShared),
            let sliceBuffer = device.makeBuffer(bytes: scene.vertexSlice, length: max(scene.vertexSlice.count, 1) * MemoryLayout<UInt32>.stride, options: .storageModeShared),
            let holeSlotBuffer = device.makeBuffer(bytes: scene.vertexHoleSlot, length: max(scene.vertexHoleSlot.count, 1) * MemoryLayout<UInt32>.stride, options: .storageModeShared),
            // 特效发射器：上限固定，一次分配到顶，之后每帧原地重写（不参与换代判定）
            let emitterBuffer = device.makeBuffer(length: PTVolumeEmitterGPU.上限 * MemoryLayout<PTVolumeEmitterGPU>.stride, options: .storageModeShared)
        else { return nil }

        vertexBuffer.label = "PT 顶点"
        indexBuffer.label = "PT 索引"
        materialBuffer.label = "PT 材质"
        lightNodeBuffer.label = "PT 灯树节点"
        lightOrderBuffer.label = "PT 灯树顺序"

        // 树上传统计：容量装不下就写「无树」，绝不能上传半棵树却留着新灯数（那会越界读灯数组）
        var 灯节点数 = 0
        var 灯树灯数 = 0
        if let 树 = 灯树, !树.节点.isEmpty,
           树.节点.count * MemoryLayout<PTLightNodeGPU>.stride <= lightNodeBuffer.length,
           树.顺序.count * MemoryLayout<UInt32>.stride <= lightOrderBuffer.length {
            写(树.节点, 到: lightNodeBuffer)
            写(树.顺序, 到: lightOrderBuffer)
            灯节点数 = 树.节点.count
            灯树灯数 = scene.lights.count
        }
        // 拖灯滑杆时会反复走到这里，超过 1ms 就得换分层网格/增量方案，
        // 所以超预算必须实测打印出来（只在超预算时打，避免刷屏）
        if scene.lights.count > 64, 灯树耗时 > 1.0 {
            NSLog("[PT灯树] 灯数=\(scene.lights.count) 节点=\(灯节点数) 构建耗时=\(String(format: "%.2f", 灯树耗时))ms 超出 1ms 预算")
        }
        cached灯几何指纹 = PTLightTreeBuilder.几何指纹(scene.lights)

        // MARK: 三角形几何描述
        let geometry = MTLAccelerationStructureTriangleGeometryDescriptor()
        geometry.vertexBuffer = vertexBuffer
        geometry.vertexBufferOffset = 0
        geometry.vertexStride = MemoryLayout<SIMD4<Float>>.stride
        geometry.indexBuffer = indexBuffer
        geometry.indexBufferOffset = 0
        geometry.indexType = .uint32
        geometry.triangleCount = scene.triangleCount
        geometry.primitiveDataBuffer = triangleMaterialBuffer
        geometry.primitiveDataStride = MemoryLayout<UInt32>.stride
        geometry.primitiveDataElementSize = MemoryLayout<UInt32>.stride

        let primitiveDescriptor = MTLPrimitiveAccelerationStructureDescriptor()
        primitiveDescriptor.geometryDescriptors = [geometry]
        // 【refit 用图标记】不写这一行，sizes.refitScratchBufferSize 恒为 0，
        // 下面 refit 要么被 Metal 校验拒掉、要么拿着 1 字节 scratch 空跑 ——
        // 顶点已经换了、BVH 还是旧的，表现就是"拖了半天画面不动 / 一松手才跳到位"。
        primitiveDescriptor.usage = .refit

        let sizes = device.accelerationStructureSizes(descriptor: primitiveDescriptor)
        guard let blas = device.makeAccelerationStructure(size: sizes.accelerationStructureSize),
              let scratch = device.makeBuffer(length: sizes.buildScratchBufferSize, options: .storageModePrivate)
        else { return nil }
        blas.label = "PT BLAS"

        // MARK: 单实例 IAS（单位矩阵，几何已经烘焙到世界空间）
        var instance = MTLAccelerationStructureInstanceDescriptor()
        instance.accelerationStructureIndex = 0
        instance.options = []
        instance.mask = 0xFF
        instance.intersectionFunctionTableOffset = 0
        instance.transformationMatrix = MTLPackedFloat4x3(columns: (
            MTLPackedFloat3Make(1, 0, 0),
            MTLPackedFloat3Make(0, 1, 0),
            MTLPackedFloat3Make(0, 0, 1),
            MTLPackedFloat3Make(0, 0, 0)
        ))

        guard let instanceBuffer = device.makeBuffer(
            bytes: &instance,
            length: MemoryLayout<MTLAccelerationStructureInstanceDescriptor>.stride,
            options: .storageModeShared
        ) else { return nil }

        let instanceDescriptor = MTLInstanceAccelerationStructureDescriptor()
        instanceDescriptor.instanceCount = 1
        instanceDescriptor.instanceDescriptorBuffer = instanceBuffer
        instanceDescriptor.instancedAccelerationStructures = [blas]

        let instanceSizes = device.accelerationStructureSizes(descriptor: instanceDescriptor)
        guard let ias = device.makeAccelerationStructure(size: instanceSizes.accelerationStructureSize),
              let instanceScratch = device.makeBuffer(length: instanceSizes.buildScratchBufferSize, options: .storageModePrivate)
        else { return nil }
        ias.label = "PT IAS"

        // 增量重建（refit）要用的 scratch，跟 AS 一起备好：
        // refit 每次临时申请 buffer 会掉帧，而且申请失败就等于每帧退回全量 build。
        if let refitScratch = device.makeBuffer(length: max(sizes.refitScratchBufferSize, 1), options: .storageModePrivate) {
            refitScratch.label = "PT refit scratch"
            增量素材 = 增量素材包(
                instanceBuffer: instanceBuffer,
                refitScratch: refitScratch,
                instanceScratch: instanceScratch
            )
            已增量次数 = 0
        }

        // MARK: 提交构建
        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeAccelerationStructureCommandEncoder()
        else { return nil }

        encoder.build(accelerationStructure: blas, descriptor: primitiveDescriptor, scratchBuffer: scratch, scratchBufferOffset: 0)
        encoder.build(accelerationStructure: ias, descriptor: instanceDescriptor, scratchBuffer: instanceScratch, scratchBufferOffset: 0)
        encoder.endEncoding()
        // 【不阻塞主线程】这颗命令缓冲和渲染用的是同一条 MTLCommandQueue，
        // 后面提交的求交命令天然排在它之后，AS 就绪由 GPU 队列顺序保证，CPU 不必等。
        // 以前这里是 waitUntilCompleted()：拖动物体时每帧都要重建 AS，等于每帧把主线程
        // 按住几毫秒，物体就表现为"轴已经到位了它还慢半拍跟上"。
        // 注意 handler 必须在 commit 之前挂：Metal 不允许往已提交的命令缓冲上加回调（会直接 abort）。
        commandBuffer.addCompletedHandler { [scratch, instanceScratch] buffer in
            if buffer.status != .completed {
                NSLog("PTDBG AS build 失败 status=\(buffer.status.rawValue) err=\(String(describing: buffer.error))")
            }
            // 显式持有 scratch，保证它们活到 GPU 建完（不能只依赖命令缓冲隐式 retain）
            _ = scratch.length + instanceScratch.length
        }
        commandBuffer.commit()

        return Payload(
            vertexBuffer: vertexBuffer,
            normalBuffer: normalBuffer,
            indexBuffer: indexBuffer,
            triangleMaterialBuffer: triangleMaterialBuffer,
            materialBuffer: materialBuffer,
            lightTriangleBuffer: lightTriangleBuffer,
            lightCDFBuffer: lightCDFBuffer,
            lightCount: scene.lightCount,
            lightsBuffer: lightsBuffer,
            lightsCDFBuffer: lightsCDFBuffer,
            lightsCount: scene.lightsCount,
            lightNodeBuffer: lightNodeBuffer,
            lightOrderBuffer: lightOrderBuffer,
            lightNodeCount: 灯节点数,
            lightTreeLightsCount: 灯树灯数,
            uvBuffer: uvBuffer,
            sliceBuffer: sliceBuffer,
            holeSlotBuffer: holeSlotBuffer,
            emitterBuffer: emitterBuffer,
            hasPaint: scene.hasPaint,
            instanceAcceleration: ias,
            blas: blas,
            triangleCount: scene.triangleCount
        )
    }
}


// MARK: - 灯 AABB 树（CPU 构建）

/// 灯 AABB 树的 CPU 构建器：只服务于 traceLightSurface 的保守剔除，不参与 NEE 抽样。
///
/// 为什么剪枝不影响结果：traceLightSurface 取的是「最近命中」（`t >= best.distance` 就 continue），
/// 只要节点 AABB **完全包住**灯的真实可见发光面，整枝跳过就不可能漏掉最终该赢的那盏灯，
/// 遍历顺序也不影响 (灯号, 距离, 法线, 自发光)。所以这里所有包围盒只允许往外扩、绝不往里收；
/// 灯参数一旦出现非法值（NaN / 零朝向轴），整棵树直接禁用，退回线性扫描。
enum PTLightTreeBuilder {
    /// 叶容量：8 盏一组。走到叶就顺序测，取舍规则与线性扫描逐字相同。
    /// 取 8 而不是 4：层数少一层，建树少一整趟扫描，叶内多测 4 盏的代价在剪枝收益面前可忽略
    static let 叶容量 = 8
    /// 沿质心最长轴的切分箱数
    static let 分箱数 = 16
    /// AABB 外扩（相对 + 绝对）：float 下算角点有舍入，宁可少剪也绝不误剪
    static let 外扩相对: Float = 1e-5
    static let 外扩绝对: Float = 1e-4

    struct 构建结果 {
        var 节点: [PTLightNodeGPU]
        var 顺序: [UInt32]
    }

    /// 灯几何指纹：只把影响包围盒的字段喂进 hash。
    /// 亮度/颜色不进 —— 改功率不需要重建树（灯面几何没动）。
    static func 几何指纹(_ lights: [PTLightGPU]) -> UInt64 {
        var h = Hasher()
        h.combine(lights.count)
        for L in lights {
            h.combine(L.positionRadius.x.bitPattern)
            h.combine(L.positionRadius.y.bitPattern)
            h.combine(L.positionRadius.z.bitPattern)
            h.combine(L.positionRadius.w.bitPattern)
            h.combine(L.axisCosCone.x.bitPattern)
            h.combine(L.axisCosCone.y.bitPattern)
            h.combine(L.axisCosCone.z.bitPattern)
            h.combine(L.shape.x.bitPattern)
            h.combine(L.shape.y.bitPattern)
            h.combine(L.shape.z.bitPattern)
        }
        // Hasher.finalize() 返回 Int，统一转位模式（只在同一进程内比较，稳定即可）
        return UInt64(bitPattern: Int64(h.finalize()))
    }

    private enum 盒判定 {
        case 盒(SIMD3<Float>, SIMD3<Float>)
        /// 着色器里必然 continue 的灯：不入树（逻辑等价，还能省节点）
        case 可跳过
        /// 参数非法（NaN / 零朝向轴）：整棵树禁用
        case 非法
    }

    /// 判据与着色器逐条对齐：PT_LIGHT_SUN 跳过、Le 分量最大 <= 0 跳过、
    /// 点光/聚光 radius < 1e-3 跳过；面光宽高各自 max(0.01) 后按四角取盒。
    private static func 判定(_ L: PTLightGPU) -> 盒判定 {
        let 种类 = UInt32(L.shape.z + 0.5)
        if 种类 == 3 { return .可跳过 }                        // PT_LIGHT_SUN：没有实体
        let 强度 = L.colorIntensity.w
        let 亮度 = max(L.colorIntensity.x * 强度, max(L.colorIntensity.y * 强度, L.colorIntensity.z * 强度))
        if !(亮度 > 0) { return .可跳过 }                       // 含 NaN 也在这里拦掉
        let 中心 = SIMD3<Float>(L.positionRadius.x, L.positionRadius.y, L.positionRadius.z)
        if !中心.x.isFinite || !中心.y.isFinite || !中心.z.isFinite { return .非法 }
        let 半径 = max(L.positionRadius.w, 0)
        if 种类 == 0 || 种类 == 1 {                             // 点光 / 聚光
            if !(半径 >= 1e-3) { return .可跳过 }               // 着色器里 radius<1e-3 直接 continue
            let r = SIMD3<Float>(repeating: 半径)
            return .盒(中心 - r, 中心 + r)                       // 球/锥都包在这个盒里
        }
        // 面光：宽高各自 max(0.01)，朝向归一化后取四个角
        let 半宽 = max(L.shape.x, 0.01) * 0.5
        let 半高 = max(L.shape.y, 0.01) * 0.5
        var 轴 = SIMD3<Float>(L.axisCosCone.x, L.axisCosCone.y, L.axisCosCone.z)
        let 轴长 = simd_length(轴)
        if !轴长.isFinite || !(轴长 > 1e-6) { return .非法 }     // 着色器里这里会算出 NaN
        轴 /= 轴长
        // 与轴最不对齐的基轴当参考，避免叉乘退化
        let 基: SIMD3<Float> = abs(轴.x) < 0.9 ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 1, 0)
        let 切线 = simd_normalize(simd_cross(轴, 基))
        let 副切线 = simd_cross(轴, 切线)
        // 四个角显式展开：这里在拖灯滑杆时会跑满一万次，别用数组字面量（每次都要建数组）
        let 切线宽 = 切线 * 半宽
        let 副切线高 = 副切线 * 半高
        let 角1 = 中心 + 切线宽 + 副切线高
        let 角2 = 中心 + 切线宽 - 副切线高
        let 角3 = 中心 - 切线宽 + 副切线高
        let 角4 = 中心 - 切线宽 - 副切线高
        var 最小 = simd_min(simd_min(角1, 角2), simd_min(角3, 角4))
        var 最大 = simd_max(simd_max(角1, 角2), simd_max(角3, 角4))
        let 尺度 = max(1, max(abs(最小.x), max(abs(最小.y), max(abs(最小.z),
                          max(abs(最大.x), max(abs(最大.y), abs(最大.z)))))))
        let 余量 = 外扩绝对 + 外扩相对 * 尺度
        return .盒(最小 - SIMD3<Float>(repeating: 余量), 最大 + SIMD3<Float>(repeating: 余量))
    }

    // 【未来优化】建树耗时实测最坏 0.744ms（1 万盏全发光，即所有灯都进树、无剔除）。
    // 现在是「灯几何指纹一变就整棵重建」，O(n log n) 中位切分 + 逐盏算 AABB：
    // 灯数到十万级时这一步会涨到十几毫秒，届时两条路可选（都不摸着色器遍历逻辑）：
    //   1) 分层网格：先把灯按粗网格桶聚合，只对桶建树，命中桶后再在桶内线性测；
    //   2) 增量更新：拖单个灯时只改它所在叶 + 沿路径重算祖先 AABB，不重建整棵。
    /// 建树（迭代中位切分，不递归，避免万盏灯把栈压爆）。
    /// - Returns: nil = 整棵树不可用，调用方必须把树头灯数写 0（走线性扫描）
    static func 构建(_ lights: [PTLightGPU]) -> 构建结果? {
        var 项: [(最小: SIMD3<Float>, 最大: SIMD3<Float>, 质心: SIMD3<Float>, 灯: UInt32)] = []
        项.reserveCapacity(lights.count)
        for (i, L) in lights.enumerated() {
            switch 判定(L) {
            case .可跳过:
                continue
            case .非法:
                return nil
            case let .盒(最小, 最大):
                项.append((最小, 最大, (最小 + 最大) * 0.5, UInt32(i)))
            }
        }
        guard !项.isEmpty else { return 构建结果(节点: [], 顺序: []) }

        var 节点: [PTLightNodeGPU] = []
        // 节点数上界 = 2 * ceil(项/叶容量) - 1，按实际上界预留：
        // 原先按 项.count*2 预留，万盏灯时每帧白分配近 1MB 并清零
        节点.reserveCapacity(max(项.count / 叶容量 * 2 + 4, 1))
        节点.append(PTLightNodeGPU())                      // 根占位
        var 待办: [(下标: Int, 起: Int, 止: Int)] = [(0, 0, 项.count)]
        待办.reserveCapacity(64)
        // 分箱结果与箱计数：整个构建过程复用同一份，不再每层分配
        var 箱缓存 = [UInt8](repeating: 0, count: 项.count)
        var 计数缓存 = [Int](repeating: 0, count: 分箱数)
        // 防御性上界：正常一棵树最多切 项.count-1 次，超过就是逻辑出错，直接放弃用树
        var 剩余次数 = 项.count * 4 + 64

        while let 任务 = 待办.popLast() {
            剩余次数 -= 1
            if 剩余次数 < 0 { return nil }
            let 起 = 任务.起
            let 止 = 任务.止
            let 数量 = 止 - 起
            // 包围盒与质心范围在同一趟里取：这层循环在万盏灯下每个内部节点都要跑一遍，
            // 少扫一趟就少一趟（原先两趟是拖滑杆重建超 1ms 的主因之一）
            var 最小 = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
            var 最大 = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
            var 质心最小 = 最小
            var 质心最大 = 最大
            for k in 起..<止 {
                let 盒最小 = 项[k].最小
                let 盒最大 = 项[k].最大
                let 质心点 = 项[k].质心
                最小 = simd_min(最小, 盒最小)
                最大 = simd_max(最大, 盒最大)
                质心最小 = simd_min(质心最小, 质心点)
                质心最大 = simd_max(质心最大, 质心点)
            }
            if 数量 <= 叶容量 {
                节点[任务.下标] = PTLightNodeGPU(最小: SIMD4<Float>(最小, 0),
                                                最大: SIMD4<Float>(最大, 0),
                                                首项: UInt32(起),
                                                数量: UInt32(数量))
                continue
            }
            let 跨度 = 质心最大 - 质心最小
            var 轴 = 0
            if 跨度.y > 跨度[轴] { 轴 = 1 }
            if 跨度.z > 跨度[轴] { 轴 = 2 }
            var 切分 = 起 + 数量 / 2
            if 跨度[轴] > 1e-12 {
                let 倒数 = Float(分箱数) / 跨度[轴]
                // 分箱只算一趟、结果留在 箱缓存 里给分区用（原先计数一趟、分区又各算两趟箱号）。
                // 两个缓冲区整个构建过程复用，避免每层重新分配数组。
                for i in 0..<分箱数 { 计数缓存[i] = 0 }
                for k in 起..<止 {
                    var b = Int((项[k].质心[轴] - 质心最小[轴]) * 倒数)
                    if b < 0 { b = 0 }
                    if b >= 分箱数 { b = 分箱数 - 1 }
                    箱缓存[k] = UInt8(b)
                    计数缓存[b] += 1
                }
                var 累计 = 0
                var 切箱 = 0
                let 半 = 数量 / 2
                while 切箱 < 分箱数 - 1, 累计 + 计数缓存[切箱] <= 半 {
                    累计 += 计数缓存[切箱]
                    切箱 += 1
                }
                // 原地分区（不稳定，但访问顺序不影响结果）
                var 左 = 起
                var 右 = 止 - 1
                while 左 <= 右 {
                    if Int(箱缓存[左]) <= 切箱 { 左 += 1; continue }
                    if Int(箱缓存[右]) > 切箱 { 右 -= 1; continue }
                    项.swapAt(左, 右)
                    箱缓存.swapAt(左, 右)
                    左 += 1
                    右 -= 1
                }
                if 左 > 起, 左 < 止 { 切分 = 左 }               // 箱子切偏了才退回对半
            }
            let 左子 = 节点.count
            节点.append(PTLightNodeGPU())
            节点.append(PTLightNodeGPU())
            节点[任务.下标] = PTLightNodeGPU(最小: SIMD4<Float>(最小, 0),
                                            最大: SIMD4<Float>(最大, 0),
                                            首项: UInt32(左子),
                                            数量: 0)
            待办.append((左子, 起, 切分))
            待办.append((左子 + 1, 切分, 止))
        }
        return 构建结果(节点: 节点, 顺序: 项.map { $0.灯 })
    }
}
