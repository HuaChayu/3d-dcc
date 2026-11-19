import Foundation
import Metal
import MetalKit
import simd

// MARK: - 路径追踪渲染器

/// 一个独立的离屏渲染器：自己持有一条命令队列和自己的累积纹理，
/// 不碰 RealityKit 的 drawable。渐进式累积，相机一动就清空重来。
///
/// 每帧的 GPU 流水：ptTrace（1 spp 累积 + 写 G-buffer）
///                → ptPackOIDN（解成线性 HDR + albedo + normal）
///                → OIDN 神经网络降噪
///                → ptResolveOIDN（ACES + sRGB）
final class PTPathTracer: NSObject, MTKViewDelegate {

    // MARK: 渲染资源

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    /// 四颗主内核改成后台编译 + 编完自动唤醒。
    /// 首次进路径追踪要转圈，根因就在这里：8 次 makeComputePipelineState 同步跑在
    /// makeNSView 的主线程上，MSL 首次编译要几百毫秒甚至几秒，窗口还没画就先僵住。
    /// 现在视图先挂上去，绘制在未就绪时直接返回，编完再叫醒，界面全程可交互。
    /// 用 IUO 而不是 Optional：使用点十几处，全改解包噪音大且容易漏。
    private(set) var tracePipeline: MTLComputePipelineState!
    private(set) var resolvePipeline: MTLComputePipelineState!
    /// OIDN 通路：累积缓冲 → 紧密 float3 线性图 → 神经网络降噪 → 色调映射
    private(set) var packOIDNPipeline: MTLComputePipelineState!
    private(set) var resolveOIDNPipeline: MTLComputePipelineState!
    private let acceleration: PTAcceleration

    // MARK: 眩光辉光（屏幕空间后处理）

    /// 高光提取：累积缓冲版 / OIDN 缓冲版（两条通路的源格式不同，后面全共用）
    private(set) var glowFromAccumPipeline: MTLComputePipelineState?
    private(set) var glowFromBufferPipeline: MTLComputePipelineState?
    private(set) var glowDownPipeline: MTLComputePipelineState?
    private(set) var glowUpPipeline: MTLComputePipelineState?
    /// 内核是否编完（主线程读写）
    private var 内核就绪 = false
    /// 各级辉光图（rgba16Float，从内部渲染分辨率逐级减半）
    private var glowLevels: [MTLTexture] = []
    private var glowSourceWidth = 0
    private var glowSourceHeight = 0
    /// 辉光关闭时的占位纹理：内核里靠 strength=0 短路，但只要声明了纹理就必须绑定
    private var 占位辉光纹理: MTLTexture?

    private var accumTexture: MTLTexture?
    /// 补偿求和的低位缓冲（Neumaier）：rgb 存每一步的舍入误差，与 accum 同尺寸；
    /// 真实积分值 = accum.rgb + accumComp.rgb。a 通道不用。
    private var accumCompTexture: MTLTexture?
    /// 第一跳法线（xyz）+ 相机距离（w，0 表示天空）
    private var gNormalDepthTexture: MTLTexture?
    /// 第一跳基底色，给降噪做材质边界保护
    private var gAlbedoTexture: MTLTexture?
    private var accumSize = CGSize.zero
    /// 1x1 的占位图集（texture2d_array）：绘图集不可用时占住 texture(3) 槽位，
    /// 避免「声明了纹理却未绑定」引发未定义采样值。全零内容 + slice 表无编号时不会被读到。
    private var 占位图集: MTLTexture?

    // MARK: 求交健康度诊断（只诊断，绝不自动重建）

    /// 1 个 uint：本帧"首发命中"的像素数。每帧清零后由 ptTrace 原子累加，下一帧开头读回。
    /// 它现在只服务诊断日志与 Debug 断言 —— 出现整屏 0 命中时渲染器**不再自动换代**：
    /// "坏了就重来"会掩盖真正的退化成因，还会在拖灯中途把 payload 清空，反向诱发全量重建。
    private var 命中计数缓冲: MTLBuffer?
    /// 上一次确实命中的帧号：诊断日志里用来给出"距上次成功命中多少帧"
    private var 上次命中帧号: UInt64 = 0
    /// 追踪帧号：每进一次 draw 自增，仅用于日志里的帧号对照
    private var 追踪帧号: UInt64 = 0
    /// 连续零命中帧数
    private var 连续零命中帧: UInt32 = 0
    /// 本次退化是否已打过诊断日志（恢复命中后复位，避免刷屏也避免漏报首次）
    private var 已报求交退化 = false


    // MARK: 自适应采样（只加速观察，不改结果）

    /// 像素压缩：筛出"还需要样本"的像素写成一维队列；参数换算：把原子计数变成间接派发组数
    private(set) var adaptiveQueuePipeline: MTLComputePipelineState?
    private(set) var adaptiveArgsPipeline: MTLComputePipelineState?
    /// 队列本体：宽度×高度 个 uint2，容量按内部渲染分辨率给足
    private var 像素队列缓冲: MTLBuffer?
    /// 1 个 uint，本趟入队数量（每趟由 GPU 原子累加，编码前清零）
    private var 自适应计数缓冲: MTLBuffer?
    /// 4 个 uint 的间接派发参数（threadgroupsPerGrid）
    private var 自适应参数缓冲: MTLBuffer?
    /// 1 个 uint，本趟队列有效长度，ptTrace 用它剔除组边界多出来的线程
    private var 自适应上限缓冲: MTLBuffer?
    private var 自适应缓冲容量 = 0
    /// 预热帧数：前几帧一律全屏采，先把 G-buffer 与基础信号打出来，别一上来就挑像素。
    /// 累积上限默认 48，预热只占 4 趟（约 8%），留足中段给自适应。
    private let 自适应预热帧: UInt32 = 4
    /// 收敛末段退回全网格的起点比例：末段不跳像素，把落后的像素补齐到同一目标 spp，
    /// 保证"最终每个像素的样本数完全一致"，像素语义与不做自适应时相同。
    private let 自适应补齐起点: Double = 0.8

    private func 取命中计数缓冲() -> MTLBuffer? {
        if let 命中计数缓冲 { return 命中计数缓冲 }
        guard let 缓冲 = device.makeBuffer(length: MemoryLayout<UInt32>.stride, options: .storageModeShared) else { return nil }
        缓冲.label = "PT 命中计数"
        缓冲.contents().storeBytes(of: UInt32(0), as: UInt32.self)
        命中计数缓冲 = 缓冲
        return 缓冲
    }

    /// 求交健康度诊断：**只记录、只打日志、Debug 下断言，绝不重建、绝不自动恢复。**
    /// 判定：本帧跑过追踪 → 上一帧整屏 0 命中，且此前确实命中过（否则相机对着天空也会被误判）。
    @discardableResult
    private func 检查求交退化(camera: PTCamera, 三角数: Int = 0, 灯数: Int = 0) -> Bool {
        guard sampleIndex > 0, let 缓冲 = 命中计数缓冲 else { return false }
        let 命中 = 缓冲.contents().load(as: UInt32.self)
        if 命中 > 0 {
            上次命中帧号 = 追踪帧号
            连续零命中帧 = 0
            已报求交退化 = false
            return false
        }
        guard 上次命中帧号 > 0 else { return false }

        连续零命中帧 &+= 1
        if 已报求交退化 { return true }
        已报求交退化 = true
        let 帧距 = 追踪帧号 &- 上次命中帧号
        NSLog("[PT 求交退化] 帧=%llu 距上次成功命中=%llu 帧 连续零命中=%u 三角数=%d 灯数=%d AS=%@ 相机pos=(%.2f,%.2f,%.2f) 目标=(%.2f,%.2f,%.2f) fov=%.1f —— 按设计显性失败：不重建、不恢复累积",
              追踪帧号, 帧距, 连续零命中帧, 三角数, 灯数, acceleration.世代描述,
              camera.position.x, camera.position.y, camera.position.z,
              camera.target.x, camera.target.y, camera.target.z, camera.fieldOfViewDegrees)
        #if DEBUG
        // 【这里刻意不断言】命中计数=0 有一条真噪声来源：高帧率下命令缓冲被跳过或被驱动掐断时，
        // 读到的是上一帧没更新的旧计数值，会被误判成"求解退化"。历史上那次反复强换代正是踩这条。
        // 想把它变成崩溃做深挖，临时设环境变量 PT_ASSERT_HIT_ZERO=1。
        if ProcessInfo.processInfo.environment["PT_ASSERT_HIT_ZERO"] != nil {
            assertionFailure("[PT 求交退化] 帧=\(追踪帧号) 距上次成功命中=\(帧距) 帧：上一帧整屏 0 命中")
        }
        #endif
        return true
    }

    private func 取占位图集() -> MTLTexture? {
        if let 占位图集 { return 占位图集 }
        let desc = MTLTextureDescriptor()
        desc.textureType = .type2DArray
        desc.pixelFormat = .rgba8Unorm
        desc.width = 1
        desc.height = 1
        desc.arrayLength = 1
        desc.mipmapLevelCount = 1
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        let tex = device.makeTexture(descriptor: desc)
        tex?.label = "PT 占位图集"
        占位图集 = tex
        return tex
    }

    // ---------------- 材质贴图图集 ----------------

    private var 材质图集: MTLTexture?
    /// 层表：下标 = 切片号，值 = 该层贴图 UUID
    private var 材质图集层: [UUID] = []
    private var 材质图集边长 = 0
    /// 建这张图集时用的纹理档：档位一变，像素来源就换了，
    /// 即便边长凑巧相同（源图比档小）也必须按新档重画。
    private var 材质图集档 = 0
    /// 每层上次上传时的像素代际：逐层判断「这一层的像素换没换」，
    /// 换了的才重传，没换的直接沿用上一帧的切片。
    private var 材质图集层代际: [UInt64] = []
    /// 建/校验这张图集时的材质版本（材质域给的段版本）：回答「这批材质动过没有」
    private var 材质图集材质版本: UInt64 = 0
    /// 建/校验这张图集时的源图代际：源图增删 / 换了工程没有
    private var 材质图集源图代际: UInt64 = 0
    /// 建/校验这张图集时的全库像素写计数：计数没动就等于「所有层像素都没重写过」，
    /// 逐层比代际这一步可以直接跳过。
    private var 材质图集像素计数: UInt64 = 0
    private var 材质图集暂存: [UInt8] = []
    /// 上一次取图集实际重传了哪些层（自检断言用；正常运行只看日志，不依赖它）
    private(set) var 材质图集上次重传层: [Int] = []
    /// 已有一批补烘在跑：避免每帧重复下单
    private var 材质补烘在跑 = false

    /// 把没烘到档的贴图丢后台补烘，烘完让下一帧重取图集。
    /// 这是「首帧不阻塞」的配套：首帧用低档图先出画面，高清档随后补上，
    /// 视觉上是「先出图、再变清楚」，而不是「转圈十几秒才出第一帧」。
    private func 请求补烘材质(_ 表: [UUID], 档: Int) {
        guard !材质补烘在跑 else { return }
        材质补烘在跑 = true
        var 剩余 = 表.count
        // 回调都在主队列串行到齐，最后一个落地时才换图，避免多次重传
        for id in 表 {
            视口纹理库.后台补烘(id, 最长边: 档) { [weak self] in
                guard let self else { return }
                剩余 -= 1
                guard 剩余 <= 0 else { return }
                self.材质补烘在跑 = false
                // 不在这里动手改图集状态：补烘写完像素会推进该图的像素代际与全库写计数，
                // 下一帧取图集时自然算出「只这几层脏」，不必要也不该在这一层再置布尔。
                NSLog("PT 材质图集高清补烘完成：已换入 %d 档贴图", 档)
                // 贴图换了要重开累积：旧样本按低档/原图算的，新老混在一起会花
                self.restart()
            }
        }
    }

    /// 把「材质贴图 UUID 表」拼成一张 2D 数组纹理：一片一个材质的贴图。
    ///
    /// 【失效判据全部来自账，不自拼键、不靠布尔兜底】
    /// 早先这里自己拼了个 `"id,id,id|档"` 的字符串键，另配一个 `需重传` 布尔。
    /// 两者本质都是渲染侧在猜「材质到底动没动」：派生图的 id 不变、像素原地更新，
    /// 猜不出来就只能靠布尔兜整张图集全层重传。现在判据全取自有账的一方：
    ///  · 材质版本（`PTScene.材质版本` ← 材质接线.场景材质版本）：这批材质动过没有；
    ///  · 纹理档：边长与烘焙档换了没有；
    ///  · 源图代际（`视口纹理库.源图代际`）：源图增删 / 换工程了没有；
    ///  · 全库像素写计数（`视口纹理库.像素写计数`）：任何一张图重写过没有。
    /// 前三者决定「要不要重新校对」，最后一项决定「校对时还值不值得逐层比代际」。
    /// 校对结果落在 dirty 集合里：只重传真正变掉的那几层，图层 id 与像素都没动的直接复用。
    /// - 参数 阻塞烘焙：为 true 时没烘到档就当场同步烘（出图通路要最终质量）；
    ///   为 false 时只用现成图，高清档丢后台补，补完再换图集（视口首帧不能等）。
    private func 取材质图集(_ 表: [UUID], 档 最长边: Int, 材质版本: UInt64, 阻塞烘焙: Bool = true) -> MTLTexture? {
        guard !表.isEmpty else { return nil }
        let 源图代 = 视口纹理库.源图代际
        let 像素计数 = 视口纹理库.像素写计数
        // 快路径：层表 / 档 / 材质版本 / 源图代际 / 全库写计数全都没动 → 现成图集直接交回。
        // 材质多的时候逐层查代际也要开销，能整段跳过就跳过。
        if let 已有 = 材质图集,
           已有.arrayLength == 表.count,
           材质图集层 == 表,
           材质图集档 == 最长边,
           材质图集材质版本 == 材质版本,
           材质图集源图代际 == 源图代,
           材质图集像素计数 == 像素计数 {
            return 已有
        }

        var 图们: [CGImage] = []
        图们.reserveCapacity(表.count)
        var 待补档: [UUID] = []
        for id in 表 {
            if 阻塞烘焙 {
                guard let 图 = 视口纹理库.取图(id, 最长边: 最长边) else { return nil }
                图们.append(图)
            } else {
                // 派生贴图的高清档是「逐像素烘焙」，400 万像素在主线程上就是十几秒，
                // 首帧绝不能等它：先拿手上的现成图顶上，烘好由 请求补烘 换图。
                guard let 取 = 视口纹理库.取图即时(id, 最长边: 最长边) else { return nil }
                图们.append(取.图)
                if !取.已达档 { 待补档.append(id) }
            }
        }
        if !待补档.isEmpty { 请求补烘材质(待补档, 档: 最长边) }

        // 数组纹理要求各片等尺寸：统一到「最大那张边长」并取 2 的幂，小图整体拉伸
        var 边长 = 64
        for 图 in 图们 { 边长 = max(边长, max(图.width, 图.height)) }
        边长 = min(边长, 4096)
        var 取整 = 64
        while 取整 < 边长 { 取整 <<= 1 }
        边长 = 取整

        if let 已有 = 材质图集, 边长 == 材质图集边长, 已有.arrayLength == 图们.count {
            // 整层作废的三种情形：档换了（像素来源换档）、源图代际换了（源图增删 / 换工程）、
            // 层数对不上（层表结构变了）。这三种必须每层都重画，逐层比较没有意义。
            let 整层作废 = (材质图集档 != 最长边)
                || (材质图集源图代际 != 源图代)
                || (材质图集层.count != 表.count)
            let 重传 = Self.图集脏层(表: 表, 上次层: 材质图集层, 上次代际: 材质图集层代际,
                                    整层作废: 整层作废) { 视口纹理库.像素代际($0) }
            for 层 in 重传 { 上传图层(已有, 层: 层, 图: 图们[层], 边长: 边长) }
            材质图集上次重传层 = 重传
            if !重传.isEmpty {
                NSLog("[PT 材质图集] 复用纹理 %d 层，重传 %d 层（材质版本=%llu 档=%d 源图代际=%llu）",
                      图们.count, 重传.count, 材质版本, 最长边, 源图代)
            }
            记图集元信息(表, 档: 最长边, 材质版本: 材质版本, 源图代际: 源图代, 像素计数: 视口纹理库.像素写计数)
            return 已有
        }

        let desc = MTLTextureDescriptor()
        desc.textureType = .type2DArray
        desc.pixelFormat = .rgba8Unorm
        desc.width = 边长
        desc.height = 边长
        desc.arrayLength = 图们.count
        desc.mipmapLevelCount = 1
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        for (层, 图) in 图们.enumerated() {
            上传图层(tex, 层: 层, 图: 图, 边长: 边长)
        }
        材质图集上次重传层 = Array(图们.indices)

        材质图集 = tex
        材质图集层 = 表
        材质图集边长 = 边长
        // 新建时全层都是刚传的，元信息照实记一遍；像素计数取「传完之后」的值，
        // 以免把上传期间（例如别的线程补烘完一层）写进去的改动误判成"已同步"。
        记图集元信息(表, 档: 最长边, 材质版本: 材质版本, 源图代际: 源图代, 像素计数: 视口纹理库.像素写计数)
        return tex
    }

    /// 记下这次图集对应的四笔账（层表 / 档 / 材质版本 / 源图代际 / 像素计数 + 每层代际）。
    /// 只在这一处写，避免几个分支各写一半导致判据自相矛盾。
    private func 记图集元信息(_ 表: [UUID], 档 最长边: Int, 材质版本: UInt64, 源图代际: UInt64, 像素计数: UInt64) {
        材质图集层 = 表
        材质图集档 = 最长边
        材质图集材质版本 = 材质版本
        材质图集源图代际 = 源图代际
        材质图集像素计数 = 像素计数
        材质图集层代际 = 表.map { 视口纹理库.像素代际($0) }
    }

    /// 图集重传层判定（纯逻辑，不碰 GPU / 不加锁）。
    /// 判据只有两条：层身份（UUID 换了 = 换成另一张贴图）、该层像素代际（内容重写过）。
    /// 拆成独立函数是为了能被断言 —— 这里判断错一层，结果要么是「贴图停在旧图」，
    /// 要么是「整张图集白重传一遍」，两种都是肉眼可见的故障。
    static func 图集脏层(表: [UUID], 上次层: [UUID], 上次代际: [UInt64],
                        整层作废: Bool, 代际: (UUID) -> UInt64) -> [Int] {
        if 整层作废 { return Array(表.indices) }
        var 脏: [Int] = []
        脏.reserveCapacity(表.count)
        for (层, id) in 表.enumerated() {
            if 层 >= 上次层.count || 上次层[层] != id
                || 层 >= 上次代际.count || 上次代际[层] != 代际(id) {
                脏.append(层)
            }
        }
        return 脏
    }

    #if DEBUG
    /// 【材质图集自检】真纹理级：用两张 4×4 假源图走完整 取材质图集，
    /// 依次验证「首次建纹理全层上传 / 参数不变走快路径 / 换一张图的像素只重传那一层 /
    /// 换档全层重传」，最后把自检贴图从库里移除并释放图集。
    /// 只在库为空时跑（视口刚建时），库非空直接跳过，绝不碰用户的真实贴图。
    private func 自检材质图集() {
        guard 材质图集 == nil, 视口纹理库.全部编号.isEmpty else { return }
        func 假图(_ r: Double, _ g: Double, _ b: Double) -> CGImage? {
            let w = 4, h = 4
            var buf = [UInt8](repeating: 0, count: w * h * 4)
            for i in 0..<(w * h) {
                buf[i * 4 + 0] = UInt8(max(0, min(255, r * 255)))
                buf[i * 4 + 1] = UInt8(max(0, min(255, g * 255)))
                buf[i * 4 + 2] = UInt8(max(0, min(255, b * 255)))
                buf[i * 4 + 3] = 255
            }
            return buf.withUnsafeMutableBytes { raw -> CGImage? in
                guard let base = raw.baseAddress,
                      let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
                else { return nil }
                return ctx.makeImage()
            }
        }
        guard let 图甲 = 假图(0.9, 0.2, 0.2), let 图乙 = 假图(0.2, 0.8, 0.3),
              let 图丙 = 假图(0.2, 0.3, 0.9) else {
            NSLog("【材质图集自检】✗ 假源图造不出来，跳过")
            return
        }
        let 甲 = 视口纹理库.登记(图甲)
        let 乙 = 视口纹理库.登记(图乙)
        let 层表 = [甲, 乙]
        let 版本: UInt64 = 0xA11A
        defer {
            // 自检只用这两张假图：从库里移除（同时会带掉它们的派生与记账），图集置空
            视口纹理库.移除([甲, 乙])
            材质图集 = nil
            材质图集层 = []
            材质图集层代际 = []
            材质图集边长 = 0
            材质图集上次重传层 = []
        }
        var 断言: [(String, Bool, String)] = []

        guard let 一 = 取材质图集(层表, 档: 128, 材质版本: 版本) else {
            NSLog("【材质图集自检】✗ 首次取图集失败（返回 nil）")
            return
        }
        断言.append(("①首次：建纹理并全 2 层上传", 一.arrayLength == 2 && 材质图集上次重传层 == [0, 1],
                 "层数=\(一.arrayLength) 重传=\(材质图集上次重传层)"))

        let 二 = 取材质图集(层表, 档: 128, 材质版本: 版本)
        断言.append(("②层表/档/版本都不变：交回同一张纹理、零重传",
                 (二 === 一) && 材质图集上次重传层 == [0, 1],
                 "同一对象=\(二 === 一) 上次重传=\(材质图集上次重传层)"))

        // 甲原地换像素（材质参数改了 / 后台补烘落到高清档，走的就是这条路）
        视口纹理库.登记(图丙, id: 甲)
        let 三 = 取材质图集(层表, 档: 128, 材质版本: 版本)
        断言.append(("③只有甲换了像素：复用纹理且只重传第 0 层",
                 (三 === 一) && 材质图集上次重传层 == [0],
                 "同一对象=\(三 === 一) 重传=\(材质图集上次重传层)"))

        let 四 = 取材质图集(层表, 档: 256, 材质版本: 版本)
        断言.append(("④换档 128→256：整表作废，2 层全重传",
                 (四 === 一) && 材质图集上次重传层 == [0, 1],
                 "同一对象=\(四 === 一) 重传=\(材质图集上次重传层)"))

        for (名, 过, 实测) in 断言 {
            NSLog("【材质图集自检】%@ %@ —— %@", 过 ? "PASS" : "FAIL", 名, 实测)
        }
        let 过数 = 断言.filter { $0.1 }.count
        NSLog("【材质图集自检】结论：%d/%d 项通过%@", 过数, 断言.count, 过数 == 断言.count ? "" : "（有失败项，见上）")
    }

    /// 【图集脏层自检】用固定 UUID 与假代际跑五种情形，逐项打印实测脏层号。
    /// 不碰 GPU、不碰贴图库，纯逻辑断言。
    static func 自检图集脏层() {
        let 甲 = UUID(), 乙 = UUID(), 丙 = UUID(), 丁 = UUID()
        var 代: [UUID: UInt64] = [甲: 7, 乙: 8, 丙: 9, 丁: 10]
        func 脏(_ 表: [UUID], _ 上次层: [UUID], _ 上次代际: [UInt64], 作废: Bool = false) -> [Int] {
            图集脏层(表: 表, 上次层: 上次层, 上次代际: 上次代际, 整层作废: 作废) { 代[$0] ?? 0 }
        }
        var 断言: [(String, Bool, String)] = []
        var 层表现 = [甲, 乙, 丙]
        let 情形1 = 脏(层表现, [甲, 乙, 丙], [7, 8, 9])
        断言.append(("①层与代际全同 → 不重传任何层", 情形1.isEmpty, "脏层=\(情形1)"))
        let 情形2 = 脏(层表现, [甲, 丁, 丙], [7, 10, 9])
        断言.append(("②第 2 层换了贴图 → 只重传 [1]", 情形2 == [1], "脏层=\(情形2)"))
        代[乙] = 99   // 乙 的像素被重写过（如材质参数改了、后台补烘落到高清档）
        let 情形3 = 脏(层表现, [甲, 乙, 丙], [7, 8, 9])
        断言.append(("③第 2 层像素代际变了 → 只重传 [1]", 情形3 == [1], "脏层=\(情形3)"))
        let 情形4 = 脏(层表现, [甲, 乙, 丙], [7, 8, 9], 作废: true)
        断言.append(("④整层作废（档 / 源图代际变了）→ 全层重传", 情形4 == [0, 1, 2], "脏层=\(情形4)"))
        层表现 = [甲, 乙, 丙, 丁]
        代[丁] = 10
        let 情形5 = 脏(层表现, [甲, 乙, 丙], [7, 8, 9], 作废: false)
        断言.append(("⑤上次只记了 3 层、现在 4 层 → 新增层算脏", 情形5.contains(3) && !情形5.contains(0),
                   "脏层=\(情形5)"))
        for (名, 过, 实测) in 断言 {
            NSLog("【图集脏层自检】%@ %@ —— %@", 过 ? "PASS" : "FAIL", 名, 实测)
        }
        let 过数 = 断言.filter { $0.1 }.count
        NSLog("【图集脏层自检】结论：%d/%d 项通过%@", 过数, 断言.count, 过数 == 断言.count ? "" : "（有失败项，见上）")
    }
    #endif

    /// 画一层再上传。像素缓冲复用，避免每层临时申请边长²×4 的内存。
    private func 上传图层(_ tex: MTLTexture, 层: Int, 图: CGImage, 边长: Int) {
        let 需 = 边长 * 边长 * 4
        if 材质图集暂存.count != 需 { 材质图集暂存 = [UInt8](repeating: 0, count: 需) }
        材质图集暂存.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            base.initializeMemory(as: UInt8.self, repeating: 0, count: 需)
            guard let ctx = CGContext(
                data: base, width: 边长, height: 边长,
                bitsPerComponent: 8, bytesPerRow: 边长 * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return }
            ctx.interpolationQuality = .high
            ctx.draw(图, in: CGRect(x: 0, y: 0, width: 边长, height: 边长))
        }
        材质图集暂存.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            tex.replace(
                region: MTLRegionMake2D(0, 0, 边长, 边长), mipmapLevel: 0, slice: 层,
                withBytes: base, bytesPerRow: 边长 * 4, bytesPerImage: 需
            )
        }
    }

    private var 占位洞图: MTLTexture?

    /// 模拟体素的空占位（1×1×1 全零）：Metal 要求 `array<texture3d, N>` 的 N 个槽全部绑上，
    /// 少一个就整条管道拒绝执行。没被占用的槽统一绑它，着色器那边靠 sim.z == 0 提前跳过，
    /// 一次采样都不会发生。
    private var 占位模拟图: MTLTexture?

    private func 取占位模拟图() -> MTLTexture? {
        if let 占位模拟图 { return 占位模拟图 }
        let desc = MTLTextureDescriptor()
        desc.textureType = .type3D
        desc.pixelFormat = .rgba16Float
        desc.width = 1
        desc.height = 1
        desc.depth = 1
        desc.mipmapLevelCount = 1
        desc.usage = [.shaderRead]
        desc.storageMode = .private
        let tex = device.makeTexture(descriptor: desc)
        tex?.label = "PT 占位模拟体素"
        占位模拟图 = tex
        return tex
    }

    /// 洞图的 1×1 兜底（r8）。没有洞 / 洞图还没建出来的帧用它占纹理槽位，
    /// 否则 shader 里声明了 texture(4) 却未绑定，校验层会报错。
    private func 取占位洞图() -> MTLTexture? {
        if let 占位洞图 { return 占位洞图 }
        let desc = MTLTextureDescriptor()
        desc.textureType = .type2DArray
        desc.pixelFormat = .r8Unorm
        desc.width = 1
        desc.height = 1
        desc.arrayLength = 1
        desc.mipmapLevelCount = 1
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        let tex = device.makeTexture(descriptor: desc)
        tex?.label = "PT 占位洞图"
        占位洞图 = tex
        return tex
    }

    // MARK: OIDN 资源

    /// OIDN 要的是紧密 float3（color / albedo / normal 三进一出），
    /// 所以每帧从纹理解包到这四个线性缓冲里
    private var oidnColorBuffer: MTLBuffer?
    private var oidnAlbedoBuffer: MTLBuffer?
    private var oidnNormalBuffer: MTLBuffer?
    private var oidnOutputBuffer: MTLBuffer?
    /// 降噪器按渲染尺寸缓存（**多份**，不是一份）。
    /// 交互档与成片档分辨率不同，两边来回切；只留一份的话每次切都要重建 OIDN filter
    /// （实测 150~230ms，含内核编译），表现就是"停手后糊一屏再变干净"。
    /// 现在两份常驻，切换只查字典，一帧完成，彻底没有噪点/糊屏阶段。
    private var oidnDenoisers: [String: PTOIDNDenoiser] = [:]
    /// 插入顺序，超过上限时按最久未用淘汰
    private var oidnDenoiserKeys: [String] = []
    private let oidnDenoiser上限 = 3
    /// 后端日志只打一次
    private var oidnLogged = false
    /// 收敛计时（诊断用）：重置时刻 → 达到 maxSamples 的时刻
    private var convergeStart: CFAbsoluteTime = 0
    private var convergeLogged = false

    // MARK: 输入

    /// 场景来源：内容变了靠签名触发加速结构重建
    var sceneProvider: (() -> PTScene)?
    /// 相机来源：直接抄轨道相机，保证两个模式构图完全一致
    var cameraProvider: (() -> PTCamera?)?
    /// 介质动画的累计时间偏移（秒）。只由内部收敛推进，不进 settings，避免污染设置比对。
    private var 介质时钟: Float = 0
    var settings = PathTraceSettings.standard {
        didSet {
            guard settings != oldValue else { return }
            // 只改了辉光（强度/范围/屏蔽自身/阈值）→ 不重开累积，只重画一帧。
            // 辉光是呈现期的后处理，累积缓冲里一个样本都没变；
            // 拖滑杆时要是每格都 restart，画面会一路"归零 → 噪 → 收敛 → 再归零"。
            if settings.除辉光外相同(oldValue) {
                // 【必须走专用重绘】收敛后 draw 一进去就 return（屏幕停在最后一帧），
                // 单纯 setNeedsDisplay 什么都不会重画 → 拖辉光滑杆、开关眩光全都没反应。
                辉光待重绘 = true
                只重绘()
                return
            }
            辉光待重绘 = false
            restart()
        }
    }

    // MARK: 状态

    private(set) var sampleIndex: UInt32 = 0
    private var sceneSignature = ""
    /// 分段指纹。以前只比整体签名，材质色/环境亮度一动都当"场景变了"处理，
    /// 于是拖一下粗糙度就重建整棵 BLAS —— 大场景里那是 O(三角形数)，卡顿的主因。
    /// 现在拆成三段：几何段变了才换代，材质段走缓冲原地改写，环境段只清累积。
    private var scene几何签名 = ""
    /// 上次见到的材质段版本（数据层材质域口径，不是自建签名）
    private var scene材质版本: UInt64 = 0
    private var scene环境签名 = ""
    /// 变换段（对象位置/旋转/缩放）：只驱动顶点重烘 + BLAS refit，不驱动 BLAS 重建。
    /// 变换域版本号影子值：**变换变更的唯一判据**（nil = 还没取过，首帧必然算"变了"）。
    /// 旧哈希影子值与回滚开关已整段删除（不做新旧双轨）。
    private var scene变换版本: UInt64?

    /// 变换到底变没变：只读变换域版本号。首次调用视为"变了"，
    /// 因此不会出现"没建过却以为没变"。
    private func 变换段变了(_ scene: PTScene) -> Bool {
        guard let 上次 = scene变换版本 else { return true }
        return 上次 != scene.变换版本
    }
    /// 灯段版本号（数据层灯光接线记账）：灯的变更判定只认这两个数，不再算任何哈希
    private var scene灯光版本: UInt64 = 0
    /// 特效段版本号（数据层特效记账）：发射器参数变了 = 介质场变了 = 旧样本作废。
    /// 只清累积、不换代（介质的场是解析的，加速结构里没有它一个字节）
    private var scene特效版本: UInt64 = 0
    private var scene灯变换版本: UInt64 = 0
    /// 绘画图集版本：笔迹变了只重开累积，绝不重建加速结构（这是整个绘画方案的前提）
    private var paintRevision = -1
    private var lastCamera: PTCamera?
    private weak var metalView: MTKView?
    /// 样本数变化回调（给角标显示用），节流到每秒几次
    var onSampleUpdate: ((UInt32) -> Void)?
    private var lastReported: UInt32 = .max
    /// restart() 只打标记，真正的重开统一放到 draw 里做。
    /// 之前 restart() 里直接把 sampleIndex 归零、却没有重建加速结构，
    /// 于是"改降噪参数/曝光"这条路径绕过了 AS 重建 → 画面整屏退化成纯天空灰雾，
    /// 得再手动转一下视口（走相机 reset 分支）才恢复。
    private var pendingRestart = false
    /// drawable 尺寸变了（拖分栏 / 拖窗口）。单独标记，不走 restart()：
    /// 尺寸每帧都在变时如果每次都 restart，累积每帧归零，画面就一直停在噪点态。
    private var pendingResize = false
    /// 上一次收到的 drawable 尺寸。
    /// MTKView 在被裁剪/重新布局时会以同样的尺寸重复回调，
    /// 那种"假 resize"不该清累积 —— 一次多余的 reset 就会白丢一整轮收敛。
    private var 上次drawable尺寸: CGSize = .zero
    /// 最近一次尺寸变化的时刻，以及当时沿用的内部渲染尺寸。
    /// 尺寸在短时间内连续变化（拖分栏）时沿用旧尺寸，避免每帧重建累积纹理与降噪器。
    private var 尺寸变化时间: CFTimeInterval = 0
    private var 冻结内部尺寸: CGSize?
    /// 是否已经成功呈现过至少一帧。
    /// 首次进入路径追踪时 OIDN 要现建 filter（150~230ms），这段时间屏幕是黑的；
    /// 用这个标记让第一帧先走"未降噪直出"抢画面，OIDN 从第二帧再上场。
    private var hasPresentedFrame = false
    /// 改了辉光参数，但累积不能重开：等下一帧 draw 用现成累积重跑一遍辉光 + 色调映射
    private var 辉光待重绘 = false
    /// 屏幕上那一帧是从哪条通路出来的（决定辉光重绘走降噪通路还是直出通路）
    private var 最后帧走降噪 = false

    /// 最近一次"输入在动"的时刻（相机变/场景变/参数变）。
    /// 交互窗口内的帧走低规格管线：内部分辨率压到 0.5、只打 1 spp、跳过 OIDN。
    /// 这是让轴向控件/手柄拖动跟手的关键——成片管线（全分辨率 + 8spp + OIDN 18ms）
    /// 单帧就要 20ms 以上，交互期根本来不及。
    private var lastInteractionTime: CFTimeInterval = 0
    /// 停手后多长时间算"出交互窗口"。120~150ms 是肉眼察觉不到、但够把最后一帧变化消化掉的值。
    private let 交互保持时长: CFTimeInterval = 0.10
    /// 交互期内部渲染分辨率上限。
    /// 曾因为"0.5↔1.0 切换要重建 OIDN filter（150ms 级）"把这里改成 1.0，
    /// 结果交互期 GPU 单帧涨到 20ms 以上，画面刷新率掉到 30fps，轴比物体跑得快。
    /// 现在降噪器按尺寸多份常驻，切换只是查字典，重建问题从根上没了，
    /// 所以交互期重新压到 0.6：像素量约 0.36，追踪 + 降噪一起变便宜（单帧 15ms 级），
    /// 画面刷新率够用且清晰度肉眼可接受；而每帧照样过 OIDN，拖动过程中看不到噪点。
    /// 0.6 = 像素量 0.36（相对 0.5 的 0.25 多 44%），单帧约 15~16ms ≈ 62fps，
    /// 仍卡在 60Hz 回调之上，跟手不会因此变差；再往上（0.65+）就跌破 60fps，得不偿失。
    private let 交互分辨率上限: Double = 0.6

    /// 上一次重建加速结构的时刻（仅用于日志/排查，换代已不做节流）
    private var 上次换代时间: CFTimeInterval = 0

    /// 【渲染与交互解耦】在飞帧闸门。
    /// draw 回调跑在主线程上，以前 OIDN 在里面同步等 GPU（30ms+），等于每帧把主线程按住，
    /// 拖手柄/拖物体时 SwiftUI 手势自然就掉帧 —— 表现就是「轴先到、物体后跟」。
    /// 现在 OIDN 只提交不同步，且用这个信号量把在飞帧限成 1：
    /// 上一帧还没渲染完就**直接跳过本帧**（画面上保留上一帧，肉眼几乎不可见），
    /// 主线程永远只是编码命令、立刻返回，手势链路不再被渲染拖住。
    /// 同时 value=1 也保证了累积纹理 / OIDN 缓冲不会被两帧同时读写。
    private let 在飞 = DispatchSemaphore(value: 1)

    // MARK: 分阶段计时（PTDBG 诊断）

    /// 只在 NSLog 里汇总，不参与任何渲染决策。
    private struct 诊断 {
        var 帧数 = 0
        var 转译: Double = 0
        var 加速: Double = 0
        var 降噪: Double = 0
        var 帧总: Double = 0
        var 最慢帧: Double = 0
        var 交互帧 = 0
        mutating func 清空() { self = 诊断() }
    }
    private var 计时 = 诊断()

    // MARK: 性能面板的数据采集

    /// 统计窗口的起点（每 30 帧结算一次 FPS）
    private var 统计窗口起点: CFTimeInterval = 0
    /// 本帧提交过的命令缓冲（下一帧开头一次性读它们的 GPU 起止时间）
    private var 本帧缓冲: [MTLCommandBuffer] = []
    /// 上一帧的命令缓冲组
    private var 上帧缓冲: [MTLCommandBuffer] = []
    /// 统计窗口内的 GPU 总时长（毫秒）
    private var GPU窗口累计: Double = 0
    /// 上一帧结算出来的 GPU 毫秒（瞬时值，给面板高频显示用）
    private var 上帧GPU毫秒: Double = 0
    /// 最近若干帧的起始时刻，用来算瞬时帧率
    private var 帧时间戳: [CFTimeInterval] = []
    /// 面板上次推送的时刻（高频节流）
    private var 上次推送时间: CFTimeInterval = 0
    /// 面板推送间隔下限/上限：帧快时贴着走，帧慢时也别超过 0.1s 才动一次
    private let 推送间隔下限: CFTimeInterval = 0.033
    private let 推送间隔上限: CFTimeInterval = 0.10

    /// 结算上一帧的 GPU 耗时。
    /// 不往 completedHandler 里塞闭包去回传——那样得处理跨线程写状态；
    /// 命令缓冲到下一帧必然已经完成，直接在主线程读 gpuStartTime/gpuEndTime 就够了。
    private func 结算上帧GPU() {
        guard !上帧缓冲.isEmpty else { return }
        var 起点 = Double.greatestFiniteMagnitude
        var 终点 = 0.0
        for buffer in 上帧缓冲 {
            guard buffer.status == .completed, buffer.gpuStartTime > 0, buffer.gpuEndTime > 0 else {
                continue
            }
            起点 = min(起点, buffer.gpuStartTime)
            终点 = max(终点, buffer.gpuEndTime)
        }
        上帧缓冲.removeAll(keepingCapacity: true)
        guard 终点 > 起点, 起点 < .greatestFiniteMagnitude else { return }
        let 毫秒 = (终点 - 起点) * 1000
        GPU窗口累计 += 毫秒
        上帧GPU毫秒 = 毫秒
    }

    // MARK: 灰雾探针（临时诊断，定位后可删）

    /// 每次 reset 后连续抓几帧 drawable 的实际像素，用来区分
    /// "画面真的是天空色（求交全 miss）" 与 "drawable 压根没被写入（灰/旧帧）"。
    private var 探针Buffer: MTLBuffer?
    private var 探针待打印 = 0
    private var 探针序号 = 0

    // MARK: 初始化

    init?(device: MTLDevice, queue: MTLCommandQueue) {
        // 结构体与着色器逐字节对齐的自检：改了字段忘同步两边，Debug 里当场炸，不留隐患。
        PTVolumeEmitterGPU.布局自检()
        // 只做取函数，不编内核：makeFunction 只是按名字查，几毫秒级；
        // 真正贵的是 makeComputePipelineState（首次要把整份 MSL 编成机器码）。
        guard let library = device.makeDefaultLibrary(),
              let traceFunction = library.makeFunction(name: "ptTrace"),
              let resolveFunction = library.makeFunction(name: "ptResolve"),
              let packOIDNFunction = library.makeFunction(name: "ptPackOIDN"),
              let resolveOIDNFunction = library.makeFunction(name: "ptResolveOIDN"),
              // 自适应采样是可选加速：拿不到这两个内核就整体退回全网格，不影响出图
              let adaptiveQueueFunction = library.makeFunction(name: "ptAdaptiveQueue"),
              let adaptiveArgsFunction = library.makeFunction(name: "ptAdaptiveArgs")
        else { return nil }

        self.device = device
        self.queue = queue
        self.acceleration = PTAcceleration(device: device, queue: queue)
        super.init()

        #if DEBUG
        // 材质图集失效判据的纯逻辑自检：不碰 GPU，开机跑一次，印证「只重传该重传的层」
        Self.自检图集脏层()
        // 真纹理级自检：走完整 取材质图集 通路（建纹理 / 复用 / 逐层重传 / 换档），
        // 断言「没变的层不重传、变了的层必重传」，跑完把自检贴图与图集全部清掉。
        自检材质图集()
        #endif

        // 【跨设备自校准】读本机上次量到的单样本耗时系数 k（毫秒 / 百万像素·样本）。
        // key 里拼了 GPU 型号与系统版本：换机或换系统后读不到，自动退回"首批 1 spp"的保守行为，
        // 绝不会拿别台设备的数去估本机批样本数。
        离屏每Mpx样本ms = UserDefaults.standard.object(forKey: Self.校准Key(设备: device)) as? Double

        // 后台编内核：编完回主线程落属性并唤醒视图。
        // 就绪前这些 pipeline 一次都不会被用到（draw / 离屏渲染入口都有 内核就绪 守卫）。
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let trace = try? device.makeComputePipelineState(function: traceFunction)
            let resolve = try? device.makeComputePipelineState(function: resolveFunction)
            let packOIDN = try? device.makeComputePipelineState(function: packOIDNFunction)
            let resolveOIDN = try? device.makeComputePipelineState(function: resolveOIDNFunction)
            // 自适应采样：编不出来就当成没这个功能（Optional 属性，用点会判空）
            let adaptiveQueue = try? device.makeComputePipelineState(function: adaptiveQueueFunction)
            let adaptiveArgs = try? device.makeComputePipelineState(function: adaptiveArgsFunction)
            // 辉光：任一内核缺失就把整条链降级成不发光，绝不因为一个可选效果让渲染器起不来
            let c1 = library.makeFunction(name: "ptGlowFromAccum")
                .flatMap { try? device.makeComputePipelineState(function: $0) }
            let c2 = library.makeFunction(name: "ptGlowFromBuffer")
                .flatMap { try? device.makeComputePipelineState(function: $0) }
            let c3 = library.makeFunction(name: "ptGlowDown")
                .flatMap { try? device.makeComputePipelineState(function: $0) }
            let c4 = library.makeFunction(name: "ptGlowUp")
                .flatMap { try? device.makeComputePipelineState(function: $0) }

            DispatchQueue.main.async {
                guard let self else { return }
                guard let trace, let resolve, let packOIDN, let resolveOIDN else {
                    NSLog("PT 内核编译失败：路径追踪不可用")
                    return
                }
                self.tracePipeline = trace
                self.resolvePipeline = resolve
                self.packOIDNPipeline = packOIDN
                self.resolveOIDNPipeline = resolveOIDN
                self.glowFromAccumPipeline = c1
                self.glowFromBufferPipeline = c2
                self.glowDownPipeline = c3
                self.glowUpPipeline = c4
                self.adaptiveQueuePipeline = adaptiveQueue
                self.adaptiveArgsPipeline = adaptiveArgs
                self.内核就绪 = true
                NSLog("PT 内核就绪，唤醒视口")
                self.restart()
            }
        }
    }

    /// 把辉光图绑到色调映射内核上（关闭时绑 1x1 占位图 + 强度 0）。
    /// 内核里声明了纹理就必须绑：未绑定时采样结果是未定义的，所以关掉也要塞一张占位。
    private func 绑定辉光(_ encoder: MTLComputeCommandEncoder,
                          图: MTLTexture?,
                          textureIndex: Int,
                          strengthBufferIndex: Int,
                          selfMaskBufferIndex: Int) {
        var strength: Float = 0
        var selfMask: Float = 0
        if let 图 {
            encoder.setTexture(图, index: textureIndex)
            strength = settings.glowStrength
            // 屏蔽自身：没辉光图时 strength 就是 0，内核直接早退，这里给 0 即可
            selfMask = min(max(settings.glowSelfMask, 0), 1)
        } else if let 占位 = 取占位辉光() ?? glowLevels.first {
            encoder.setTexture(占位, index: textureIndex)
        }
        encoder.setBytes(&strength, length: MemoryLayout<Float>.stride, index: strengthBufferIndex)
        encoder.setBytes(&selfMask, length: MemoryLayout<Float>.stride, index: selfMaskBufferIndex)
    }

    // MARK: 眩光辉光编码

    /// HDR 源：两条呈现通路只是"喂进来的是哪种图"不同，后面的辉光链完全共用。
    /// 这就是"一个函数"的落点：不管自发光来自节点还是绘画，都只是 HDR 里的高亮像素。
    private enum 辉光源 {
        /// 累积缓冲（低分辨率，rgb = 样本和 / a = 样本数）
        case 累积(MTLTexture)
        /// OIDN 输出的紧密 float3 线性 HDR（未乘曝光）
        case 降噪缓冲(MTLBuffer, width: Int, height: Int)
    }

    private func 取占位辉光() -> MTLTexture? {
        if let 占位辉光纹理 { return 占位辉光纹理 }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                                                            width: 1, height: 1, mipmapped: false)
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .private
        let tex = device.makeTexture(descriptor: desc)
        tex?.label = "PT 辉光占位 1x1"
        占位辉光纹理 = tex
        return tex
    }

    /// 按内部渲染尺寸准备各级辉光图，返回实际可用层数（最多 6 级，最小 1x1）
    private func ensureGlowLevels(width: Int, height: Int) -> Int {
        let w = max(width, 1), h = max(height, 1)
        if glowSourceWidth == w, glowSourceHeight == h, !glowLevels.isEmpty { return glowLevels.count }
        var levels: [MTLTexture] = []
        var cw = w, ch = h
        for i in 0..<6 {
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                                                                width: max(cw, 1), height: max(ch, 1),
                                                                mipmapped: false)
            desc.usage = [.shaderRead, .shaderWrite]
            desc.storageMode = .private
            guard let tex = device.makeTexture(descriptor: desc) else { break }
            tex.label = "PT 辉光 L\(i) \(cw)x\(ch)"
            levels.append(tex)
            if cw <= 1 && ch <= 1 { break }
            cw = max(cw / 2, 1)
            ch = max(ch / 2, 1)
        }
        glowLevels = levels
        glowSourceWidth = w
        glowSourceHeight = h
        return levels.count
    }

    /// 【统一辉光入口】把任意 HDR 源变成一张辉光图。
    /// 节点自发光、绘画自发光、亮金属高光全都在这张图里 —— 调用方不需要区分来源，
    /// 只要把当前帧的 HDR 递进来，拿回去的辉光图在色调映射前叠回原图即可。
    /// 返回 nil 表示本帧不出辉光（开关关 / 强度为 0 / 内核缺失 / 分配失败）。
    private func encodeGlow(commandBuffer: MTLCommandBuffer,
                            源: 辉光源,
                            width: Int,
                            height: Int) -> MTLTexture? {
        guard settings.glowEnabled, settings.glowStrength > 0 else { return nil }
        guard let down = glowDownPipeline, let up = glowUpPipeline else { return nil }
        let 可用层数 = ensureGlowLevels(width: width, height: height)
        let 层数 = min(max(settings.glowRadius, 1), 可用层数)
        guard 层数 > 0, glowLevels.count >= 层数 else { return nil }

        var params = PTGlowParams(threshold: settings.glowThreshold,
                                  smoothness: max(settings.glowSmoothness, 0.0001),
                                  maxBrightness: settings.glowMaxBrightness,
                                  strength: settings.glowStrength)
        var exposure = Float(pow(2.0, Double(settings.exposure)))

        // ① 高光提取 → L0
        guard let 提取 = commandBuffer.makeComputeCommandEncoder() else { return nil }
        提取.label = "PT 辉光 高光提取"
        switch 源 {
        case .累积(let accum):
            guard let pipeline = glowFromAccumPipeline else { 提取.endEncoding(); return nil }
            提取.setComputePipelineState(pipeline)
            提取.setTexture(accum, index: 0)
            提取.setTexture(glowLevels[0], index: 1)
            提取.setBytes(&params, length: MemoryLayout<PTGlowParams>.stride, index: 0)
            提取.setBytes(&exposure, length: MemoryLayout<Float>.stride, index: 1)
            dispatch(encoder: 提取, pipeline: pipeline, width: glowLevels[0].width, height: glowLevels[0].height)
        case .降噪缓冲(let buffer, let sw, let sh):
            guard let pipeline = glowFromBufferPipeline else { 提取.endEncoding(); return nil }
            提取.setComputePipelineState(pipeline)
            提取.setBuffer(buffer, offset: 0, index: 0)
            提取.setTexture(glowLevels[0], index: 1)
            提取.setBytes(&params, length: MemoryLayout<PTGlowParams>.stride, index: 2)
            提取.setBytes(&exposure, length: MemoryLayout<Float>.stride, index: 3)
            var srcSize = SIMD2<UInt32>(UInt32(max(sw, 1)), UInt32(max(sh, 1)))
            提取.setBytes(&srcSize, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 4)
            dispatch(encoder: 提取, pipeline: pipeline, width: glowLevels[0].width, height: glowLevels[0].height)
        }
        提取.endEncoding()

        // ② 逐级 13-tap 下采样
        if 层数 > 1 {
            guard let 下采 = commandBuffer.makeComputeCommandEncoder() else { return glowLevels[0] }
            下采.label = "PT 辉光 下采样"
            下采.setComputePipelineState(down)
            for i in 1..<层数 {
                let dst = glowLevels[i]
                下采.setTexture(glowLevels[i - 1], index: 0)
                下采.setTexture(dst, index: 1)
                dispatch(encoder: 下采, pipeline: down, width: dst.width, height: dst.height)
                下采.memoryBarrier(scope: .textures)
            }
            下采.endEncoding()
        }

        // ③ 由深到浅 3x3 tent 上采样并累加（这一步决定光晕能铺多远）
        if 层数 > 1 {
            guard let 上采 = commandBuffer.makeComputeCommandEncoder() else { return glowLevels[0] }
            上采.label = "PT 辉光 上采样"
            上采.setComputePipelineState(up)
            for i in stride(from: 层数 - 1, through: 1, by: -1) {
                let dst = glowLevels[i - 1]
                上采.setTexture(glowLevels[i], index: 0)
                上采.setTexture(dst, index: 1)
                dispatch(encoder: 上采, pipeline: up, width: dst.width, height: dst.height)
                上采.memoryBarrier(scope: .textures)
            }
            上采.endEncoding()
        }

        return glowLevels[0]
    }

    // MARK: 外部驱动

    func attach(_ view: MTKView) {
        metalView = view
        // 只登记，不改预览逻辑：出图时按登记表暂停预览，出图结束恢复
        PT视口登记.shared.登记(view)
    }

    /// 清空累积、重新开始（相机/场景/参数变更时调用）。
    // MARK: 空场景

    /// 空场景的温和降耗：**保留 draw 回调**，只降低出帧频率。
    /// 阈值：连续 `空场景降频阈值` 帧仍为空才降；恢复时按原值写回。
    /// 降频期间输入照旧被检测 —— draw 仍在跑，只是节奏从 60fps 变成 10fps，
    /// 最坏延迟 100ms 就能看到相机/参数的反应，且任何非空帧立刻回到满速。
    private func 空场景降频(_ view: MTKView) {
        空场景帧数 &+= 1
        guard 空场景帧数 == 空场景降频阈值 else { return }
        let 原 = view.preferredFramesPerSecond
        guard 原 > 空场景帧率 else { return }
        空场景前帧率 = 原
        view.preferredFramesPerSecond = 空场景帧率
        // 仲裁器的目标帧间隔基准跟着改：否则出图会拿 60fps 的基准判断"视口帧被挤掉"，
        // 而这段时间视口本来就该慢
        PT并发仲裁.shared.设置目标帧率(空场景帧率)
        NSLog("PT 空场景：连续 %d 帧无几何，出帧频率 %d→%d fps（未暂停，输入照样能被检测）",
              空场景帧数, 原, 空场景帧率)
    }

    /// 场景重新有内容：帧率立即写回，并把计数归零（下次空档重新计 30 帧）
    private func 恢复空场景帧率(_ view: MTKView) {
        guard 空场景帧数 > 0 else { return }
        let 空了 = 空场景帧数
        空场景帧数 = 0
        空场景末次相机 = nil
        guard 空场景前帧率 > 0 else { return }
        let 帧率 = 空场景前帧率
        空场景前帧率 = 0
        view.preferredFramesPerSecond = 帧率
        PT并发仲裁.shared.设置目标帧率(帧率)
        NSLog("PT 空场景恢复：连续 %d 帧无几何后重新拿到场景，出帧频率回到 %d fps", 空了, 帧率)
    }

    /// 注意：这里只打标记，归零 + 加速结构重建放在 draw 里统一执行，
    /// 保证"重开累积"和"重建 AS"永远成对出现。
    func restart() {
        pendingRestart = true
        lastReported = .max
        // 反正要重开累积，辉光自然跟着新参数重算，专用重绘标记作废
        辉光待重绘 = false
        只重绘()
    }

    /// 不清累积、只求再画一帧。给「后处理参数」用（辉光强度/范围/屏蔽自身）：
    /// 这些参数只改呈现，改完立刻要看到效果，但不该把辛苦攒的样本丢掉。
    private func 只重绘() {
        if let view = metalView {
            view.isPaused = false
            // 空场景降频期间改了参数（辉光/后处理/选中…），说明有人在交互：立即回满速
            恢复空场景帧率(view)
            view.setNeedsDisplay(view.bounds)
        }
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // 只打标记，把"重开累积 + 续画"放到 draw 里做。
        // 原来这里是 restart()：拖分栏时尺寸每帧都变，等于每帧把累积清零，
        // 拖动全程画面都是单样本噪点，看起来像渲染停住了。
        //
        // 视口渲染画布现在尺寸恒定、分栏只改裁剪范围，理论上这里不该再被调用；
        // 但 SwiftUI 重排仍可能带着同样尺寸回调进来，所以先比对一次：
        // 尺寸实质没变就当作没发生，不要白白清掉已经收敛的那一轮累积。
        let 变了 = abs(size.width - 上次drawable尺寸.width) >= 0.5
            || abs(size.height - 上次drawable尺寸.height) >= 0.5
        上次drawable尺寸 = size
        view.isPaused = false
        guard 变了 else { return }
        pendingResize = true
        view.setNeedsDisplay(view.bounds)
    }

    func draw(in view: MTKView) {
        // 内核还在后台编：这一帧什么都不做。既不建命令缓冲也不碰 drawable，
        // 窗口正常显示、可交互，编完由 init 里的回调 restart() 接手。
        guard 内核就绪 else { return }
        // 【离屏出图分支】出图会话给渲染器注入 离屏任务 后，draw 一进来就切走：
        // 不读 view.drawableSize、不取 currentDrawable、不做交互期 0.5 降分辨率、不 present，
        // 全分辨率累积到目标采样数后把结果交给出图会话。
        // 离屏任务为 nil 时走的还是下面原有那段代码，预览行为一个字节没改。
        if 离屏任务 != nil {
            离屏渲染一帧()
            return
        }
        let 帧起点 = CFAbsoluteTimeGetCurrent()
        // 先结上一帧的 GPU 账，再把本帧要提交的缓冲换上来
        结算上帧GPU()
        上帧缓冲 = 本帧缓冲
        本帧缓冲.removeAll(keepingCapacity: true)
        let 转译起点 = 帧起点
        guard var scene = sceneProvider?(), !scene.isEmpty else {
            // 【不暂停，只跳过本帧】isPaused = true 会让 MTKView 彻底停止回调 draw（见本文件
            // 「收敛了也到此为止」那段注释），而相机 / 轨道 / 辉光 / 参数全都只在 draw 里才被检测 ——
            // 一旦"空一帧"就暂停，就再没有任何输入能叫醒它，只能靠 objects 数组变化触发 restart，
            // 于是短暂的"暂时没有可见几何"被放大成"长时间黑屏，动一下别的东西才回来"。
            // 这里保留上一帧画面、什么都不改（不碰累积、不碰加速结构），下一帧自然重算。
            //
            // 【降频但不失手感】空场景连续太久会降到 10fps 省电，可相机一动就说明有人在操作，
            // 必须当帧回满速、并把"连续空帧"计数清零重新计 —— 这样拖视角全程都是 60fps，
            // 手一停满 30 帧才重新降频。降频只是"没人动且确实没东西"时的省电，永不冻结回调。
            let 空时相机 = cameraProvider.flatMap { $0() } ?? .fallback
            if 空时相机 != 空场景末次相机 {
                空场景末次相机 = 空时相机
                恢复空场景帧率(view)
            }
            空场景降频(view)
            return
        }
        // 场景回来了：立刻把出帧频率写回原值，保证"恢复"只差这一帧
        恢复空场景帧率(view)
        // 【转译与刷新图集是两条线程】
        // sceneProvider 里的转译会在开头读一次绘画快照，而主线程「落笔 → 刷新图集」
        // 完全可能正好挤在「转译读完快照」和「draw 后面那次读快照」之间。
        // 那样这份 scene 带的就是旧 slice 表，而 slice 不进 signature →
        // 缓存的加速结构永远不会为它重建 → 错表被永久缓存：
        //   · 旧表全是 0xFFFFFFFF → 第一次进 PT 画的笔迹看不到（切模式重建才好）；
        //   · 旧表里是上一轮的编号 → 物体撞到别人的图集片，整个模型被涂成同一个颜色。
        // 发现快照比转译新，就再转译一次，用当帧最新的表。
        var 绘画快照 = PaintGPUSnapshot.shared.读()
        if scene.paintRevision != 绘画快照.revision {
            if let 重译 = sceneProvider?(), !重译.isEmpty {
                scene = 重译
                绘画快照 = PaintGPUSnapshot.shared.读()
            }
        }
        let 转译耗时 = CFAbsoluteTimeGetCurrent() - 转译起点

        // 相机变了 → 之前的样本作废
        let camera = cameraProvider.flatMap { $0() } ?? .fallback
        var cameraMoved = false
        if camera != lastCamera {
            lastCamera = camera
            cameraMoved = true
        }

        // 场景内容变了 → 重建加速结构 + 重开累积
        var 几何变了 = false
        var 材质变了 = false
        if scene.几何签名 != scene几何签名 {
            scene几何签名 = scene.几何签名
            几何变了 = true
        }
        // 【材质唯一所有者】材质动没动只读材质域版本，不再比自拼签名
        if scene.材质版本 != scene材质版本 {
            scene材质版本 = scene.材质版本
            材质变了 = true
        }
        // 【环境段必须能单独触发重算】环境（天顶色/地平色/环境强度/环境旋转/主光方向）
        // 只走 uniform（每帧 setBytes 上传 PTEnvironmentGPU），不动几何、材质、灯缓冲。
        // 以前这里只把签名抄过去、不置任何"变了"标志，于是拖摄影棚亮度滑杆时：
        // 累积没被重置，而画面早已收敛（sampleIndex 已到 maxSamples）→ 后续 draw 在
        // 「收敛了就到此为止」那道 guard 处直接 return，一帧都不再跑 ——
        // 表现就是"亮度滑杆拖动完全没反应"，直到手动转一下相机（cameraMoved）才生效。
        var 环境变了 = false
        if scene.环境签名 != scene环境签名 {
            scene环境签名 = scene.环境签名
            环境变了 = true
        }
        // 【灯段：版本号接管】灯的变更判定不再算哈希，直接读数据层的两个灯段版本号。
        // 参数版本只被"灯参数真的变了"推动，灯变换版本只被"灯的矩阵真的变了"推动：
        // 拖物体不会让它们动，拖灯也不会连带几何/材质段。
        var 灯光变了 = false
        if scene.灯光版本 != scene灯光版本 {
            scene灯光版本 = scene.灯光版本
            灯光变了 = true
        }
        // 【变换段独立记账】对象拖动只让 变换变了 为真：几何段（拓扑）不动，
        // 所以这一路只允许「重烘顶点 + refit」，任何情况下都不许重建 BLAS。
        var 变换变了 = false
        if 变换段变了(scene) {
            scene变换版本 = scene.变换版本
            变换变了 = true
        }
        // 灯位置单独记账：灯不产几何，位置变只刷灯缓冲 + 灯树，连 refit 都不做
        var 灯变换变了 = false
        if scene.灯变换版本 != scene灯变换版本 {
            scene灯变换版本 = scene.灯变换版本
            灯变换变了 = true
        }
        // sceneChanged 仍是"画面得重算"的口径（任何一段变都要清累积），语义不变
        // 环境段也在内：环境只换 uniform，不必换代，但旧样本是按旧亮度积的，必须清零重积
        let sceneChanged = 几何变了 || 材质变了 || 灯光变了 || 变换变了 || 灯变换变了 || 环境变了

        // 【特效段：只清累积，不动加速结构】
        // 发射器没有一个字节进 BLAS/IAS —— 介质是解析场，所以这里绝不能并进 sceneChanged，
        // 否则拖一下「扩散角」滑杆就要白白重建一次加速结构（GPU 几毫秒 + 求交窗口）。
        var 特效变了 = false
        if scene.特效版本 != scene特效版本 {
            scene特效版本 = scene.特效版本
            特效变了 = true
        }

        // 参数变更（降噪档位/曝光/采样上限…）→ 也要重开累积
        let settingsRestart = pendingRestart
        pendingRestart = false

        // drawable 尺寸变了（拖分栏/拖窗口）→ 累积作废，但不算"参数变更"
        let 尺寸变化 = pendingResize
        pendingResize = false
        if 尺寸变化 { 尺寸变化时间 = CFAbsoluteTimeGetCurrent() }

        // 笔迹变化：图集内容改了，之前累积的样本里画的是旧笔迹，必须重开累积。
        // 但它不属于几何变化 —— 加速结构和 uv 缓冲一个字节都没动，所以不进 invalidate 分支。
        绘画快照 = PaintGPUSnapshot.shared.读()
        var paintChanged = false
        if 绘画快照.revision != paintRevision {
            paintRevision = 绘画快照.revision
            paintChanged = true
        }

        // slice 表不在这里写：它必须跟着「当帧 payload」走，见下面 payload 之后那次 更新切片。
        // 放在这里的旧写法只在 revision 变化的那一帧写一次，写错了就再也没机会纠正。

        let reset = cameraMoved || sceneChanged || settingsRestart || 尺寸变化 || paintChanged || 特效变了
        if reset {
            // 只重置计数，GPU 端的旧累加和在 ptTrace 里按 sampleIndex==0 丢弃
            sampleIndex = 0
            lastReported = .max
            convergeStart = CFAbsoluteTimeGetCurrent()
            convergeLogged = false
            // 【加速结构换代策略】
            // 以前这里是无条件 invalidate()：相机每动一帧就重建 BLAS+IAS，而重建内部是
            // 同步 waitUntilCompleted，等于每帧把渲染线程钉住十几毫秒 —— 拖手柄/点轴向控件
            // 时「轴飞过去了物体才慢慢跟上」就是它。
            // 但改成"相机完全不换代"之后，灰色天空 bug 又回来了（相机操作后求交整体失效），
            // 说明这套 AS 在当前 Metal 驱动/用法下并不能跨大量相机变动长期复用。
            // 【最终方案：每次 reset 都无条件换代】
            // 8Hz 节流只是把灰雾窗口压到几帧，极端拖拽下仍会闪；而 AS 构建早已改成异步
            // 不阻塞主线程、GPU 成本仅几毫秒，所以不再做任何节流 —— 只要进入 reset
            // （相机动/几何动/参数动），一律换代，从根上消除复用退化带来的灰雾。
            let 换代时间 = CFAbsoluteTimeGetCurrent()
            // 【参数/场景变了必须换代】参数切换只重置了累积计数、没有换加速结构，
            // 而当时在用的那颗 AS 可能已经处于"硬件求交失效"状态（历史灰雾 bug 的残留），
            // 表现就是：一改参数画面立刻整屏灰掉，非要去拖一下视口（那才会触发相机换代）才恢复。
            // 现在 AS 构建是异步不阻塞主线程的，换代成本只是 GPU 上几毫秒，可以放心每次重置都换。
            // 【整屏单色 bug 的根因修复】上面这段条件换代漏掉了两条路径：
            //   · paintChanged（绘画 revision 变 → 画一笔 / 改绘画参数）
            //   · 尺寸变化（走 ensureAccum 重建纹理）
            // 只要 reset 了却没换代，追踪就会继续用那颗已经处于"求交失效"状态的 AS：
            // 所有像素全部 miss → 整屏只剩环境色（棕/灰雾），一笔上去立刻全屏一个颜色；
            // 而"操作一下视口"必然触发 cameraMoved → 掩盖在条件里换代 → 画面才回来。
            // 这就是用户反复报的"参数一动/画一笔整屏一个色，动下视口就恢复"。
            // 结论：reset 与换代必须成对，不再做任何条件筛。
            上次换代时间 = 换代时间
            NSLog("PT 重建加速结构 scene=\(sceneChanged ? 1 : 0) cam=\(cameraMoved ? 1 : 0) settings=\(settingsRestart ? 1 : 0) paint=\(paintChanged ? 1 : 0) size=\(尺寸变化 ? 1 : 0) tris=\(scene.triangleCount) lights=\(scene.lightCount)")
            // 材质高频路径免换代：拖材质颜色/粗糙度滑杆时几何一个字节都没动，
            // 以前这里无条件 invalidate()，每帧重建 O(三角形数) 的 BLAS，
            // 场景一大就直接卡成幻灯片。这条路径只把材质数组原地拷进现有缓冲，
            // 加速结构原样复用，成本从按三角形数降到按材质数。
            // 其余路径（相机/几何/尺寸/绘画/参数档）保持无条件换代：那些场景下
            // 换代的成本远小于复用退化导致求交失效、整屏灰雾的代价。
            // 【只改灯】灯不入加速结构：拖灯只允许"重写灯缓冲 + 灯 CDF + 灯树 AABB + 清累积"。
            // 判定走版本号，并把"灯参数变 / 灯变换变"合并成一条 —— 二者做的是同一件事。
            // 以前拆成两条（只改灯 / 只改灯位）且各自要求"另一段没变"才成立：
            // 一次拖灯同时改位置与朝向时两条都不成立，直接 fallthrough 到全量重建。
            // 【只改环境】摄影棚亮度 / 环境旋转 / 换环境预设：环境只是 uniform，
            // 三角形、材质缓冲、灯缓冲一个字节都没动，加速结构可以原样复用。
            // 若落到最后的 else 分支就会每拖一次滑杆重建一次 BLAS（场景一大直接卡顿），
            // 所以单独劈一条：只清累积重积（与「只改材质」同一级别，不换代）。
            let 只改环境 = 环境变了
                && !灯光变了
                && !灯变换变了
                && !变换变了
                && !几何变了
                && !材质变了
                && !cameraMoved
                && !尺寸变化
                && !paintChanged
                && !settingsRestart
            let 只改灯 = (灯光变了 || 灯变换变了)
                && !变换变了
                && !几何变了
                && !材质变了
                && !cameraMoved
                && !尺寸变化
                && !paintChanged
                && !settingsRestart
            let 只改材质 = 材质变了
                && !几何变了
                && !cameraMoved
                && !尺寸变化
                && !paintChanged
                && !settingsRestart
            // 第二档：几何变了但拓扑没变（拖物体 / 改缩放 / 雕刻顶点 / 绘画）。
            // 这些操作每帧都在挪顶点坐标，索引一个字节都没动 —— 重建整棵 BVH 纯属白费，
            // refit 只重算 AABB 就够，成本常数小一大截，还不占新一代显存。
            // 拓扑真变了（换网格 / 洞位变化 / 切片变化）时 增量重建(scene) 会自己返回 false，自动退回换代。
            // 【仅对象变换变化】位置/旋转/缩放变了、拓扑没变：重烘顶点 + refit + 重建实例层，
            // BLAS 原样复用。相机/绘画/参数档不在此列（它们仍走换代，保持既有补丁逻辑）。
            let 只改变换 = 变换变了
                && !几何变了
                && !材质变了
                && !cameraMoved
                && !尺寸变化
                && !paintChanged
                && !settingsRestart
            let 试试增量 = 几何变了 && !尺寸变化 && !settingsRestart
            // 【只改灯】拖功率/色温/尺寸/角度滑杆时三角形一个都没动，灯也不在加速结构里 ——
            // 只把 lightsBuffer + lightsCDF 原地重写，连材质缓冲都不碰。
            // 刷新灯光() 内部对「盏数变了」返回 false（容量对不上必须重新分配），落到下面换代。
            if 只改环境 {
                // 环境 uniform 每帧都会重传，这里只需让累积重开（已在上面的 reset 里清零）
                NSLog("PT 环境原地刷新（只清累积，加速结构复用）环境签名=\(scene.环境签名.prefix(6))")
            } else if 只改灯 {
                if acceleration.刷新灯光(scene) {
                    NSLog("PT 灯原地刷新（版本接管，BLAS/IAS 未动）参数版本=\(scene.灯光版本) 灯变换版本=\(scene.灯变换版本) 灯数=\(scene.lights.count)")
                } else if !acceleration.灯盏数与缓存一致(scene) || !acceleration.有缓存 {
                    // 唯一允许换代的灯路径：盏数变了（灯被增删/启停），灯缓冲与 CDF 容量对不上
                    NSLog("PT 灯盏数变化 → 重新分配灯缓冲并换代 灯数=\(scene.lights.count) blas=rebuild ias=rebuild")
                    acceleration.invalidate()
                } else {
                    // 显性失败：不重建、不清累积。Debug 直接断言，"坏了就重来"不再作为兜底
                    NSLog("PT 灯原地刷新失败（显性失败：不重建、不清累积）灯数=\(scene.lights.count) 三角数=\(scene.triangleCount)")
                    #if DEBUG
                    assertionFailure("[PT 灯原地刷新失败] 灯数=\(scene.lights.count) 三角数=\(scene.triangleCount)")
                    #endif
                }
            } else if 只改材质, acceleration.刷新材质(scene) {
                NSLog("PT 材质原地刷新（几何未变，加速结构复用）mats=\(scene.materials.count)")
            } else if 只改变换, acceleration.增量重建(scene) {
                NSLog("PT 仅变换变化（对象）→ BLAS 复用 + refit tris=\(scene.triangleCount)")
            } else if 试试增量, acceleration.增量重建(scene) {
                NSLog("PT 顶点增量重建（拓扑未变，只 refit）tris=\(scene.triangleCount)")
            } else {
                acceleration.invalidate()
            }
            // 【阶段1验收日志】每次提交一行：四个版本号 + BLAS 是否复用 + IAS 方式 + 是否清累积。
            // 拖动物体/拖灯全程 blas=reuse 计数不变即证明几何没有被误判。
            NSLog("PT 提交 geom=\(scene.几何签名.prefix(6)) 变换版本=\(scene.变换版本)(域) 材质版本=\(scene.材质版本) 灯参数版本=\(scene.灯光版本) 灯变换版本=\(scene.灯变换版本) blas=\(acceleration.本次BLAS复用 ? "reuse" : "rebuild") ias=\(acceleration.本次IAS方式) 清累积=1")
            view.isPaused = false
            // 重置后连抓 3 帧像素：如果这几帧里几何全丢了，说明求交在 reset 后失效
            // 纯尺寸变化不抓探针：读回像素要等 GPU，拖动时每帧都做等于自己给自己加卡顿
            if sceneChanged || settingsRestart || cameraMoved || paintChanged {
                探针待打印 = 3
                NSLog(String(
                    format: "PTDBG RESET cam=%d scene=%d settings=%d 相机pos=(%.2f,%.2f,%.2f) 目标=(%.2f,%.2f,%.2f) fov=%.1f",
                    cameraMoved ? 1 : 0,
                    sceneChanged ? 1 : 0,
                    settingsRestart ? 1 : 0,
                    camera.position.x, camera.position.y, camera.position.z,
                    camera.target.x, camera.target.y, camera.target.z,
                    camera.fieldOfViewDegrees
                ))
            }
        }

        // 交互窗口：相机/场景每帧都在变的那段时间。
        // 窗口内一切按"手感优先"跑（低分辨率 + 1spp + 不降噪），停手后自动回到成片管线。
        // 用时间窗而不是布尔量，是为了让最后一帧变化之后还有一点点缓冲，
        // 避免"正好在最后一帧切换到高质量管线"导致画面闪一下分辨率。
        // 注意只认相机和场景：改参数（降噪档位/曝光/采样上限）是低频操作，
        // 让它直接走成片管线一把收敛，否则用户改完先糊一屏噪点反而更难看。
        let now = CFAbsoluteTimeGetCurrent()
        // 尺寸变化也算"输入在动"：一次尺寸变化会把累积清零，
        // 若此时按成片管线（全分辨率 + 8spp + OIDN）跑，单帧就二十毫秒起，
        // 拖动期间主线程被按住 → 观感是"渲染停住了，动一下才回来"。
        if cameraMoved || sceneChanged || 尺寸变化 || paintChanged {
            lastInteractionTime = now
        }
        let interactive = (now - lastInteractionTime) < 交互保持时长

        // 收敛了就到此为止：不打命令缓冲，屏幕上保留最后一帧。
        // 注意不能 isPaused = true —— 那会让 MTKView 彻底停止回调 draw，
        // 之后相机再怎么动都检测不到，画面就永远定住了。
        // 【收敛后改辉光参数】下面那个 guard 一收敛就直接 return，屏幕永远停在最后一帧，
        // 于是拖辉光强度/范围/屏蔽自身、开关眩光全都"没反应"（参数是改了，但没人重画）。
        // 这里补一条专用路径：不重跑追踪、不动累积，只拿现成结果重跑一遍辉光 + 色调映射。
        if 辉光待重绘 {
            // 借用同一道在飞闸门（present 后由 completedHandler 归还）
            guard 在飞.wait(timeout: .now()) == .success else { return }
            辉光待重绘 = false
            var 已接管 = false
            if let drawable = view.currentDrawable, let accum = accumTexture {
                let 需要字节 = accum.width * accum.height * 3 * MemoryLayout<Float>.stride
                if 最后帧走降噪, let 降噪图 = oidnOutputBuffer, 降噪图.length == 需要字节 {
                    已接管 = presentOIDN(drawable: drawable, width: accum.width, height: accum.height)
                } else {
                    已接管 = presentUndenoised(drawable: drawable, accumTexture: accum)
                }
            }
            if !已接管 { 在飞.signal() }
            return
        }

        // 【介质动画】PT 是累积渲染器：墙钟驱动的时间会让每帧都是新画面、永远收敛不了。
        // 折中：一轮累积收敛后把介质时间往前推一格再重开累积 —— 视口里是低帧率动画，
        // 出图走的是另一条快照路径（不带这份时钟），仍然是定格。
        if !settings.volumeAnimate { 介质时钟 = 0 }

        guard sampleIndex < UInt32(settings.maxSamples) else {
            if settings.volumeAnimate {
                介质时钟 += 0.12
                restart()
                return
            }
            if !convergeLogged {
                convergeLogged = true
                let ms = (CFAbsoluteTimeGetCurrent() - convergeStart) * 1000
                NSLog("PT 收敛完成 \(sampleIndex) spp / \(settings.samplesPerFrame) spp每帧，用时 %.0f ms", ms)
            }
            reportSamples()
            // 【收敛后也不放过】收敛意味着后面不会再有 draw 去渲染了，如果最后这一轮画出来的
            // 正好是"求交退化"的单色，就再也没机会自愈。这里等一次在飞归还（不阻塞主线程：
            // 拿不到就直接放弃），读命中数，退化就换代重开并主动要一帧重画。
            // 【收敛后也只诊断】原来这里会"退化就换代重开并主动要一帧"，
            // 现在只把诊断打出来：自动重开等于把退化藏进一次莫名的闪屏里。
            if 在飞.wait(timeout: .now()) == .success {
                检查求交退化(camera: camera)
                在飞.signal()
            }
            return
        }

        // 【解耦闸门】draw 跑在主线程上，这里绝不阻塞：上一帧还没在 GPU 上跑完，
        // 就跳过本帧（屏幕上保留上一帧，追赶期间看不出差别），把主线程立刻还给 SwiftUI。
        // 手势（拖轴 / 拖物体）因此拿到满帧率，物体与坐标轴一起跟手。
        guard 在飞.wait(timeout: .now()) == .success else { return }
        // 上一帧已在 GPU 上跑完：顺手读一次命中数，只做诊断。
        // 【不再自愈】原来这里会 invalidate() 强换代，会在拖灯中途把 cached payload 清成 nil，
        // 让"只改灯"分支里的 刷新灯光() 拿不到 payload 返回 false，一路 fallthrough 到全量重建
        // —— 这正是实测拖灯帧 blas=rebuild 的真凶。现在退化只报日志，不碰加速结构。
        追踪帧号 &+= 1
        检查求交退化(camera: camera, 三角数: scene.triangleCount, 灯数: scene.lights.count)
        var 已提交 = false
        // 没走到提交（任何 guard 提前退出）就把闸门还回去，避免永久卡死
        defer { if !已提交 { 在飞.signal() } }

        let 加速起点 = CFAbsoluteTimeGetCurrent()
        guard let payload = acceleration.payload(for: scene) else { return }
        // 【每帧对齐 slice 表】签名没变时 payload 是复用的旧那一代，而图集编号只活在
        // sliceBuffer 里、不进签名。所以持不持 payload 都要幂等核一次：
        // 内容相同不拷贝，只有「谁有笔迹 / 图集重建 / 对象显隐」真变了才写。
        acceleration.更新切片(scene)
        let 加速耗时 = CFAbsoluteTimeGetCurrent() - 加速起点
        guard let drawable = view.currentDrawable else { return }

        // 交互期把内部分辨率压到 0.5：像素量降到 1/4，追踪与 OIDN 成本同比降，
        // 停手后自动回到设置里的全分辨率重新收敛。
        let 基准比例 = max(min(settings.resolutionScale, 1.0), 0.25)
        let scale = interactive ? max(min(基准比例, 交互分辨率上限), 0.25) : 基准比例
        var target = CGSize(
            width: max(Double(view.drawableSize.width) * scale, 16),
            height: max(Double(view.drawableSize.height) * scale, 16)
        )
        // 尺寸在短时间内连续变化（拖分栏）时沿用旧尺寸：
        // 每帧都换一次尺寸就要重建累积纹理、法线/反照率缓冲和降噪器，
        // 这三样加起来是十几毫秒级的开销，串联起来就是拖不动。
        // 停手 0.15s 后自动切到新尺寸，只重建一次。
        if now - 尺寸变化时间 <= 0.15, let 冻结 = 冻结内部尺寸 {
            target = 冻结
        } else {
            冻结内部尺寸 = target
        }
        guard ensureAccum(size: CGSize(width: Int(target.width), height: Int(target.height))) else { return }
        guard let accumTexture,
              let accumCompTexture,
              let gNormalDepthTexture,
              let gAlbedoTexture,
              let commandBuffer = queue.makeCommandBuffer()
        else { return }

        // 命中计数每帧清零：ptTrace 里原子累加，下一帧开头读回来判求交是否退化
        if let 计数缓冲 = 取命中计数缓冲(), let 清零 = commandBuffer.makeBlitCommandEncoder() {
            清零.label = "PT 命中计数清零"
            清零.fill(buffer: 计数缓冲, range: 0..<MemoryLayout<UInt32>.stride, value: 0)
            清零.endEncoding()
        }

        // ---- 1. 追踪：本帧累积 sppPerFrame 个样本（同一个命令缓冲里连发，最终只色调映射一次）
        // 拖动/切视角时累积马上又被丢掉，多打样本纯属浪费，只跑 1 spp 保手感；
        // 纯参数变更（降噪档位 / 曝光 / 采样上限）不用保手感，直接打满，免得改完先糊一屏噪点
        // 左键按住期间（拖节点、拖材质、拖滑杆）：视口这边一点都不该跟着改写，
        // 但 PT 若照旧每帧打满 8 spp、还开着自适应那两条全屏 compute，GPU 一整帧都被占死，
        // AppKit 的拖影/虚线框就跟不上手 —— 用户看到的是「还没到 48spp 的上限，拖一下就卡」。
        // 这里只把「每帧样本数」和「自适应采样」让出去，累积不清零、分辨率不降：
        // 松手即恢复满档，画面也不会因为降分辨率而糊一下。
        let 交互让路 = interactive || 视口纹理库.拖动中
        let sppPerFrame = 交互让路 ? 1 : max(min(settings.samplesPerFrame, 8), 1)

        // ---- 0. 自适应采样预处理：本帧只追"还需要样本的像素" ----
        // 只在相机静止的收敛中段开：交互期每帧都在丢累积，跳像素只会让画面出现跟不上的空洞；
        // 末段（收敛最后 20%）退回全网格，把落后的像素补齐，保证最终每像素样本数一致。
        let 采样目标 = UInt32(max(settings.maxSamples, 1))
        let 补齐起点 = UInt32(Double(采样目标) * 自适应补齐起点)
        var 本帧走队列 = false
        if !交互让路,
           sampleIndex >= 自适应预热帧,
           sampleIndex < 补齐起点,
           ensureAdaptiveBuffers(width: accumTexture.width, height: accumTexture.height),
           let 压缩 = adaptiveQueuePipeline,
           let 换算 = adaptiveArgsPipeline,
           let 队列 = 像素队列缓冲,
           let 计数 = 自适应计数缓冲,
           let 参数 = 自适应参数缓冲,
           let 上限 = 自适应上限缓冲,
           let 清零 = commandBuffer.makeBlitCommandEncoder() {
            清零.label = "PT 自适应计数清零"
            清零.fill(buffer: 计数, range: 0..<MemoryLayout<UInt32>.stride, value: 0)
            清零.endEncoding()
            if let 预编码 = commandBuffer.makeComputeCommandEncoder() {
                预编码.label = "PT 自适应压缩"
                // 1) 全屏过一遍累积图，够干净的像素直接丢掉，只把还需要的写进队列
                预编码.setComputePipelineState(压缩)
                预编码.setTexture(accumTexture, index: 0)
                预编码.setBuffer(队列, offset: 0, index: 0)
                预编码.setBuffer(计数, offset: 0, index: 1)
                var 目标 = 采样目标
                // 相对亮度差阈值：超过 6% 的邻域跳变视为边缘/高光，必采；
                // 保底概率 0.3 让平滑区也稳定推进，实测比 0.1 更不容易留"没铺满"的斑块
                var 边缘阈值: Float = 0.06
                var 保底概率: Float = 0.3
                var 种子 = sampleIndex
                预编码.setBytes(&目标, length: MemoryLayout<UInt32>.stride, index: 2)
                预编码.setBytes(&边缘阈值, length: MemoryLayout<Float>.stride, index: 3)
                预编码.setBytes(&保底概率, length: MemoryLayout<Float>.stride, index: 4)
                预编码.setBytes(&种子, length: MemoryLayout<UInt32>.stride, index: 5)
                dispatch(encoder: 预编码, pipeline: 压缩, width: accumTexture.width, height: accumTexture.height)
                // 2) 把原子计数换算成间接派发的组数（{组数,1,1}），顺手把队列长度交给追踪内核
                预编码.setComputePipelineState(换算)
                var 每组线程 = UInt32(tracePipeline.threadExecutionWidth)
                预编码.setBuffer(计数, offset: 0, index: 0)
                预编码.setBuffer(参数, offset: 0, index: 1)
                预编码.setBuffer(上限, offset: 0, index: 2)
                预编码.setBytes(&每组线程, length: MemoryLayout<UInt32>.stride, index: 3)
                预编码.dispatchThreadgroups(
                    MTLSize(width: 1, height: 1, depth: 1),
                    threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1)
                )
                预编码.endEncoding()
                本帧走队列 = true
            }
        }

        if let encoder = commandBuffer.makeComputeCommandEncoder() {
            encoder.label = "PT 追踪"
            encoder.setComputePipelineState(tracePipeline)

            var gpuCamera = camera.gpu(aspect: Float(target.width / target.height),
                                       介质时间: settings.volumeTime + 介质时钟,
                                       介质湍流: settings.volumeTurbulence)
            var bounces = UInt32(max(settings.maxBounces, 1))

            encoder.setBytes(&gpuCamera, length: MemoryLayout<PTCameraGPU>.stride, index: 0)
            var environment = scene.environment
            encoder.setBytes(&environment, length: MemoryLayout<PTEnvironmentGPU>.stride, index: 1)
            encoder.setBuffer(payload.vertexBuffer, offset: 0, index: 2)
            encoder.setBuffer(payload.normalBuffer, offset: 0, index: 3)
            encoder.setBuffer(payload.indexBuffer, offset: 0, index: 4)
            encoder.setBuffer(payload.triangleMaterialBuffer, offset: 0, index: 5)
            encoder.setBuffer(payload.materialBuffer, offset: 0, index: 6)
            encoder.setAccelerationStructure(payload.instanceAcceleration, bufferIndex: 7)
            encoder.setTexture(accumTexture, index: 0)
            encoder.setTexture(gNormalDepthTexture, index: 1)
            encoder.setTexture(gAlbedoTexture, index: 2)
            encoder.setTexture(accumCompTexture, index: 12)
            encoder.setBytes(&bounces, length: MemoryLayout<UInt32>.stride, index: 9)
            encoder.setBuffer(payload.lightTriangleBuffer, offset: 0, index: 10)
            encoder.setBuffer(payload.lightCDFBuffer, offset: 0, index: 11)
            var lightCount = UInt32(payload.lightCount)
            encoder.setBytes(&lightCount, length: MemoryLayout<UInt32>.stride, index: 12)

            // ---- 绘画：图集纹理 + 逐顶点 UV / slice ----
            encoder.setBuffer(payload.uvBuffer, offset: 0, index: 13)
            encoder.setBuffer(payload.sliceBuffer, offset: 0, index: 14)
            // 必须看「当帧快照」，不能看 payload：payload 是加速结构那一代建的时候抄下来的值，
            // 签名没变就一直是旧的。首次进 PT 后才第一次落笔时 payload.hasPaint 恒为 false，
            // 着色器整条绘画分支都被跳过 —— 就是「有几个对象非得切模式才看得见」。
            var hasPaint = UInt32((绘画快照.有绘画 && 绘画快照.atlas != nil) ? 1 : 0)
            encoder.setBytes(&hasPaint, length: MemoryLayout<UInt32>.stride, index: 15)
            // 没笔迹时也绑一张 1x1 的占位数组纹理：着色器走不到采样分支，
            // 但 Metal 对「声明了却没绑定」的纹理仍会在校验层报错。
            // 注意这里必须有无条件兜底：图集正在重建（arrayLength 变了要重建新纹理）的那一帧
            // 快照里 atlas 可能还是 nil，而 slice 表里已经有编号 —— 此时 texture(3) 未绑定，
            // atlas.sample 的返回值完全未定义，常见结果是让整屏采样出同一个常量色。
            if let atlas = 绘画快照.atlas {
                encoder.setTexture(atlas, index: 3)
            } else if let 占位 = 取占位图集() {
                encoder.setTexture(占位, index: 3)
            }
            // ---- 通道图集（颜色以外的 OpenPBR 参数）----
            // 槽位必须与 PT 着色器签名一致：5 粗糙度 / 6 金属度 / 7 清漆权重 /
            // 8 清漆粗糙度 / 9 自发光 / 10 法线。
            // 没落过笔的通道绑 1x1 占位、掩码位留 0 —— 着色器那一位是 0 就完全不采样，
            // 这样「只画了粗糙度」的物体不会因为其它图集是空纹理而采到乱七八糟的值。
            var 通道掩码: UInt32 = 0
            let 通道槽: [(PaintChannel, UInt32, Int)] = [
                (.roughness, 1, 5),
                (.metalness, 2, 6),
                (.coatWeight, 4, 7),
                (.coatRoughness, 8, 8),
                (.emission, 16, 9),
                (.normal, 32, 10)
            ]
            let 空图集 = 取占位图集()
            for (通道, 位, 槽) in 通道槽 {
                if let tex = 绘画快照.通道图集[通道] {
                    encoder.setTexture(tex, index: 槽)
                    通道掩码 |= 位
                } else if let 空图集 {
                    encoder.setTexture(空图集, index: 槽)
                }
            }
            encoder.setBytes(&通道掩码, length: MemoryLayout<UInt32>.stride, index: 18)
            // ---- 材质贴图（导入的基础色图）：一片一个材质 ----
            // 层序靠着色器保证：贴图只当"底"，笔迹再盖上去，这里的绑定不影响绘画可见性。
            if let 材质 = 取材质图集(scene.材质贴图, 档: settings.textureTier, 材质版本: scene.材质版本, 阻塞烘焙: false) {
                encoder.setTexture(材质, index: 11)
            } else if let 空图集 {
                encoder.setTexture(空图集, index: 11)
            }
            // ---- 显式灯光（不是几何，直接光采样用）----
            encoder.setBuffer(payload.lightsBuffer, offset: 0, index: 19)
            var 灯数 = UInt32(payload.lightsCount)
            encoder.setBytes(&灯数, length: MemoryLayout<UInt32>.stride, index: 20)
            // 显式灯亮度 CDF（重要性采样）：index 26 是当前唯一空位，别跟 0-14 / 21-25 撞
            encoder.setBuffer(payload.lightsCDFBuffer, offset: 0, index: 26)
            // 灯 AABB 树（保守剔除）：27 节点 / 28 叶内灯顺序 / 29 树头。
            // 树头灯数与当前灯数不一致时着色器会整体退回线性扫描，所以这里照实传，不做猜测。
            encoder.setBuffer(payload.lightNodeBuffer, offset: 0, index: 27)
            encoder.setBuffer(payload.lightOrderBuffer, offset: 0, index: 28)
            var 灯树头 = PTLightTreeHeaderGPU(节点数: UInt32(max(payload.lightNodeCount, 0)),
                                              灯数: UInt32(max(payload.lightTreeLightsCount, 0)))
            encoder.setBytes(&灯树头, length: MemoryLayout<PTLightTreeHeaderGPU>.stride, index: 29)
            // ---- 特效发射器（体积介质源）：只有数组，占 30 号槽 ----
            // Metal 的 buffer 索引上限就是 0…30，0…29 已用满，30 是最后一个空位，
            // 所以数量不单独占槽位：**有效项连续在前，其余全零**，着色器遇全零即停。
            // 固定上限缓冲每帧原地重写照帧快照（不看 payload 抄下来的旧值）。
            // 没有发射器时整段全零，着色器整段跳过 —— 逐像素与接入前完全一致。
            let 发射器数 = min(scene.特效发射器.count, PTVolumeEmitterGPU.上限)
            let 发射器缓冲长 = PTVolumeEmitterGPU.上限 * MemoryLayout<PTVolumeEmitterGPU>.stride
            memset(payload.emitterBuffer.contents(), 0, 发射器缓冲长)
            if 发射器数 > 0 {
                scene.特效发射器.withUnsafeBytes { 源 in
                    if let 首 = 源.baseAddress {
                        payload.emitterBuffer.contents().copyMemory(
                            from: 首,
                            byteCount: 发射器数 * MemoryLayout<PTVolumeEmitterGPU>.stride
                        )
                    }
                }
            }
            encoder.setBuffer(payload.emitterBuffer, offset: 0, index: 30)
            // ---- 模拟场体素：13…20 密、21…28 温 ----
            // 和视口绑的是同一批 MTLTexture（同一份体素内容），
            // 出图与预览因此不是"算得像"，而是读同一堆体素。
            // 每个槽都必须绑：Metal 不允许 texture 数组缺项，空槽用 1×1×1 占位顶上，
            // 着色器按 sim.z == 0 提前跳过，不会真去采。
            if let 占位模拟 = 取占位模拟图() {
                for 槽 in 0..<PTVolumeEmitterGPU.模拟上限 {
                    let 密 = 槽 < scene.特效模拟密.count ? scene.特效模拟密[槽] : nil
                    let 温 = 槽 < scene.特效模拟温.count ? scene.特效模拟温[槽] : nil
                    encoder.setTexture(密 ?? 占位模拟, index: 13 + 槽)
                    encoder.setTexture(温 ?? 占位模拟, index: 21 + 槽)
                }
            }
            // ---- 镂空：逐顶点洞格位 + 洞图 ----
            encoder.setBuffer(payload.holeSlotBuffer, offset: 0, index: 17)
            if let 洞图 = 绘画快照.holeAtlas, 绘画快照.有洞 {
                encoder.setTexture(洞图, index: 4)
            } else if let 占位 = 取占位洞图() {
                encoder.setTexture(占位, index: 4)
            }
            // 求交健康度计数（ptTrace 里按首发命中原子累加）
            if let 计数缓冲 = 取命中计数缓冲() {
                encoder.setBuffer(计数缓冲, offset: 0, index: 16)
            }

            var 队列长度: UInt32 = 0
            for _ in 0..<sppPerFrame {
                guard sampleIndex < UInt32(settings.maxSamples) else { break }
                // 采样序号只做 RNG 种子与收敛上限；累积分母改成逐像素自增，
                // 自适应跳过的像素那一趟不 +1，被跳过也就不会把分母虚高。
                var sample = sampleIndex
                var 清零标记: UInt32 = sample == 0 ? 1 : 0
                encoder.setBytes(&sample, length: MemoryLayout<UInt32>.stride, index: 8)
                encoder.setBytes(&清零标记, length: MemoryLayout<UInt32>.stride, index: 23)
                if 本帧走队列,
                   let 队列 = 像素队列缓冲,
                   let 上限 = 自适应上限缓冲,
                   let 参数 = 自适应参数缓冲 {
                    // 队列模式：组数已由压缩内核写好，这里照单派发，只算还需要的像素
                    encoder.setBuffer(队列, offset: 0, index: 21)
                    encoder.setBuffer(上限, offset: 0, index: 22)
                    // 这条路是间接派发、不经过 dispatch() 包装，分块原点得自己补一个零值，
                    // 否则 kernel 读到的 buffer(24) 是未绑定内容。视口永远整图，恒为 (0,0)。
                    var 队列原点 = SIMD2<UInt32>.zero
                    encoder.setBytes(&队列原点, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 24)
                    // 间接派发同样不经过 dispatch() 包装，sppCount 也得自己补：视口恒为 1
                    var 视口样本数: UInt32 = 1
                    encoder.setBytes(&视口样本数, length: MemoryLayout<UInt32>.stride, index: 25)
                    encoder.dispatchThreadgroups(
                        indirectBuffer: 参数,
                        indirectBufferOffset: 0,
                        threadsPerThreadgroup: MTLSize(
                            width: tracePipeline.threadExecutionWidth,
                            height: 1,
                            depth: 1
                        )
                    )
                } else {
                    // 全网格（交互 / 预热 / 末段补齐 / 内核缺失）：与原行为完全一致
                    if let 队列 = 像素队列缓冲 { encoder.setBuffer(队列, offset: 0, index: 21) }
                    encoder.setBytes(&队列长度, length: MemoryLayout<UInt32>.stride, index: 22)
                    dispatch(encoder: encoder, pipeline: tracePipeline,
                             width: accumTexture.width, height: accumTexture.height, spp: 1)
                }
                sampleIndex += 1
            }
            encoder.endEncoding()
        }

        let width = accumTexture.width
        let height = accumTexture.height

        // ---- 2. 降噪 + 色调映射
        // 走 OIDN：它是训练过的降噪网络，2~4 spp 的输入就能出干净画面，
        // 不需要几百帧慢慢收敛（对标 Blender 设低采样直接出图的那种手感）。
        //
        // 首帧例外：OIDN 第一次要现建 filter（实测 150~230ms，切档还要重编译内核），
        // 这段 CPU 时间卡在 draw 里、一帧都出不来，屏幕上就是"切进路径追踪黑一下"。
        // 所以第一帧先走未降噪直出把画面抢出来，OIDN 从第二帧再上。
        // 交互期照样每帧过 OIDN —— 用户看不到噪点，这是硬要求。
        // 省时间的做法不是"跳过降噪"，而是把分辨率压到 0.5（降噪成本随像素量线性降），
        // 而且降噪器按尺寸常驻，交互档/成片档来回切都不重建。
        let denoiseAvailable = hasPresentedFrame || !oidnDenoisers.isEmpty
        if !hasPresentedFrame {
            NSLog("PTDBG 首帧未降噪直出（OIDN 延迟到第二帧）")
        }
        if settings.denoiseEnabled,
           denoiseAvailable,
           let oidnBuffers = ensureOIDNBuffers(width: width, height: height),
           let denoiser = ensureDenoiser(width: width, height: height) {
            encodePackOIDN(
                commandBuffer: commandBuffer,
                width: width,
                height: height,
                colorBuffer: oidnBuffers.color,
                albedoBuffer: oidnBuffers.albedo,
                normalBuffer: oidnBuffers.normal
            )
            // 追踪 + 打包先提交，OIDN 在本队列上排在其后，天然同序
            commandBuffer.commit()
            本帧缓冲.append(commandBuffer)

            // 固定 high 档：实测 1280x720 单次 execute 约 18ms，且切档会触发一次
            // 内核重编译（约 230ms 卡顿），索性全程用最高质量不切档。
            let quality: PTOIDNQuality = .high
            let 降噪起点 = CFAbsoluteTimeGetCurrent()
            let ok = denoiser.denoiseColor(
                oidnBuffers.color,
                albedo: oidnBuffers.albedo,
                normal: oidnBuffers.normal,
                output: oidnBuffers.output,
                quality: quality,
                // 【解耦核心】不同步等 GPU：OIDN 排在与追踪/色调映射同一条队列上，
                // 后续那条 present 命令缓冲天然排在它后面，顺序由 GPU 保证。
                // 以前这里 oidnSyncDevice 同步等 30ms+，直接把主线程钉死，手势全变成幻灯片。
                synchronize: false
            )
            let 降噪耗时 = CFAbsoluteTimeGetCurrent() - 降噪起点
            if ok {
                // OIDN 只提交不同步，这里立刻返回，主线程不再被 30ms 级别的 GPU 等待按住
                if presentOIDN(drawable: drawable, width: width, height: height) { 已提交 = true }
            } else {
                // OIDN 出错时不做降噪，直接色调映射原始累积结果，画面不中断
                NSLog("PT OIDN 降噪失败，输出未降噪画面")
                if presentUndenoised(drawable: drawable, accumTexture: accumTexture) { 已提交 = true }
            }
            reportSamples()
            记录(转译: 转译耗时, 加速: 加速耗时, 降噪: 降噪耗时, 帧起点: 帧起点, interactive: interactive, 尺寸: "\(width)x\(height)", 宽度: width, 高度: height)
            return
        }
        // ---- 交互期 / 降噪关闭：直接色调映射未降噪的累积结果
        // 眩光：和降噪通路走同一条辉光链，这里只是把源换成未降噪的累积缓冲
        let 辉光图 = encodeGlow(commandBuffer: commandBuffer,
                                源: .累积(accumTexture),
                                width: accumTexture.width,
                                height: accumTexture.height)
        if let encoder = commandBuffer.makeComputeCommandEncoder() {
            encoder.label = "PT 色调映射"
            encoder.setComputePipelineState(resolvePipeline)
            encoder.setTexture(accumTexture, index: 0)
            encoder.setTexture(drawable.texture, index: 1)
            encoder.setTexture(accumCompTexture, index: 3)
            绑定辉光(encoder, 图: 辉光图, textureIndex: 2, strengthBufferIndex: 2, selfMaskBufferIndex: 3)
            var invSamples: Float = 1
            var exposure = Float(pow(2.0, Double(settings.exposure)))
            encoder.setBytes(&invSamples, length: MemoryLayout<Float>.stride, index: 0)
            encoder.setBytes(&exposure, length: MemoryLayout<Float>.stride, index: 1)
            dispatch(encoder: encoder, pipeline: resolvePipeline, width: drawable.texture.width, height: drawable.texture.height)
            encoder.endEncoding()
        }
        采样探针(texture: drawable.texture, commandBuffer: commandBuffer)
        commandBuffer.addCompletedHandler { [在飞] 完成 in
            在飞.signal()
            // 材质槽延迟回收的唯一触发点：这一帧真的从 GPU 下来、切回主线程后才轮询
            // （在飞帧数 >0 期间一律不释放材质槽，见 材质接线.尝试回收）
            Task { @MainActor in _ = 材质接线.共享.帧完成() }
            // 【AIMD 反馈的取样点】用 GPU 结束时间戳算相邻两帧的间隔（与出图侧同一口径），
            // 只在 present 的完成回调里记，样本天然就是"用户真正看到的帧节奏"。
            PT并发仲裁.shared.视口帧完成(gpuEndTime: 完成.gpuEndTime)
            PT并发仲裁.shared.视口归还()
        }
        // 告诉出图侧"视口刚提交了一帧"：出图在视口有帧在飞时直接让出（批预算不再由这里决定，
        // 改由 AIMD 闭环按视口实测帧间隔 P95 自动调节）
        PT并发仲裁.shared.视口提交了()
        commandBuffer.present(drawable)
        材质接线.共享.提交帧()
        commandBuffer.commit()
        本帧缓冲.append(commandBuffer)
        已提交 = true
        hasPresentedFrame = true

        // sampleIndex 已在追踪循环里逐样本推进
        reportSamples()
        记录(转译: 转译耗时, 加速: 加速耗时, 降噪: 0, 帧起点: 帧起点, interactive: interactive, 尺寸: "\(width)x\(height)", 宽度: width, 高度: height)
    }

    /// 每帧记一次；面板按 10Hz 高频推送瞬时值，30 帧窗口只用来打诊断日志
    private func 记录(转译: Double, 加速: Double, 降噪: Double, 帧起点: CFTimeInterval,
                     interactive: Bool, 尺寸: String, 宽度: Int, 高度: Int) {
        计时.帧数 += 1
        if interactive { 计时.交互帧 += 1 }
        计时.转译 += 转译
        计时.加速 += 加速
        计时.降噪 += 降噪
        let 帧总 = CFAbsoluteTimeGetCurrent() - 帧起点
        计时.帧总 += 帧总
        计时.最慢帧 = max(计时.最慢帧, 帧总)

        // ---- 面板：高频推送（瞬时值）
        // 以前只在 30 帧窗口结束时推一次，低帧率下要等好几秒才变一个数，看得很闷。
        // 现在改成每帧记录、10Hz 节流推送：FPS 取最近 0.6s 的滑动窗口，
        // CPU/GPU/降噪都是"这一帧"的真实值，拖动手感和数值变化同步。
        let 现在 = CFAbsoluteTimeGetCurrent()
        帧时间戳.append(帧起点)
        while let 首 = 帧时间戳.first, 现在 - 首 > 0.6 { 帧时间戳.removeFirst() }
        // 推送间隔自适应：60fps 时 30Hz 贴着画面走，6fps 时就是每帧一推（10Hz 上限兜底）
        let 间隔 = min(推送间隔上限, max(推送间隔下限, 帧总 * 2))
        if 现在 - 上次推送时间 >= 间隔 {
            上次推送时间 = 现在
            let 跨度 = max(现在 - (帧时间戳.first ?? 现在), 0.001)
            let 瞬时帧率 = 帧时间戳.count > 1 ? Double(帧时间戳.count - 1) / 跨度 : 0
            PT性能统计.shared.提交(
                帧率: 瞬时帧率,
                CPU毫秒: 帧总 * 1000,
                GPU毫秒: 上帧GPU毫秒,
                降噪毫秒: 降噪 * 1000,
                宽度: 宽度,
                高度: 高度,
                样本: Int(sampleIndex),
                样本上限: settings.maxSamples,
                交互中: interactive
            )
        }

        guard 计时.帧数 >= 30 else { return }
        let n = Double(计时.帧数)
        // 首窗口没有起点，就用窗口内实际耗时代替，免得 FPS 首屏跳一个离谱值
        let 窗口秒 = 现在 - (统计窗口起点 > 0 ? 统计窗口起点 : 现在 - 计时.帧总)
        NSLog(String(
            format: "PTDBG 帧均值[%@] 转译%.2fms 加速%.2fms 降噪%.2fms 帧%.2fms 最慢%.1fms 交互帧%d/%d 窗口FPS%.1f",
            尺寸,
            计时.转译 / n * 1000,
            计时.加速 / n * 1000,
            计时.降噪 / n * 1000,
            计时.帧总 / n * 1000,
            计时.最慢帧 * 1000,
            计时.交互帧,
            计时.帧数,
            n / max(窗口秒, 0.001)
        ))
        计时.清空()
        GPU窗口累计 = 0
        统计窗口起点 = 现在
    }

    // MARK: 内部
    // MARK: OIDN

    /// 累积缓冲 → OIDN 需要的三张紧密 float3 线性图
    private func encodePackOIDN(commandBuffer: MTLCommandBuffer,
                                width: Int,
                                height: Int,
                                colorBuffer: MTLBuffer,
                                albedoBuffer: MTLBuffer,
                                normalBuffer: MTLBuffer) {
        // 先把可选值校验完再创建编码器：编码器一旦创建就必须 endEncoding，不能夹在多绑定 guard 里
        guard let accumTexture,
              let accumCompTexture,
              let gNormalDepthTexture,
              let gAlbedoTexture
        else { return }
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.label = "PT 打包 OIDN 输入"
        encoder.setComputePipelineState(packOIDNPipeline)
        encoder.setTexture(accumTexture, index: 0)
        encoder.setTexture(gNormalDepthTexture, index: 1)
        encoder.setTexture(gAlbedoTexture, index: 2)
        encoder.setTexture(accumCompTexture, index: 3)
        encoder.setBuffer(colorBuffer, offset: 0, index: 0)
        encoder.setBuffer(albedoBuffer, offset: 0, index: 1)
        encoder.setBuffer(normalBuffer, offset: 0, index: 2)
        // 萤火虫压制沿用自适应档位里的亮度上限
        var ceiling = settings.denoisePlan(samples: sampleIndex).luminosityCeiling
        if ceiling <= 0 { ceiling = 16 }
        encoder.setBytes(&ceiling, length: MemoryLayout<Float>.stride, index: 3)
        dispatch(encoder: encoder, pipeline: packOIDNPipeline, width: width, height: height)
        encoder.endEncoding()
    }

    /// OIDN 结果 → ACES → drawable（异步提交，不影响 draw 回调返回）
    /// 返回 true 表示命令已提交并接管了在飞闸门的归还（由 completedHandler 归还）。
    @discardableResult
    private func presentOIDN(drawable: CAMetalDrawable, width: Int, height: Int) -> Bool {
        guard let outputBuffer = oidnOutputBuffer,
              let commandBuffer = queue.makeCommandBuffer()
        else { return false }
        // 眩光：源是 OIDN 输出的线性 HDR。降噪是异步提交在同一条队列上，
        // 这条命令缓冲天然排在它后面，所以这里读到的一定是降噪后的结果。
        let 辉光图 = encodeGlow(commandBuffer: commandBuffer,
                                源: .降噪缓冲(outputBuffer, width: width, height: height),
                                width: width,
                                height: height)
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return false }
        encoder.label = "PT OIDN 色调映射"
        encoder.setComputePipelineState(resolveOIDNPipeline)
        encoder.setBuffer(outputBuffer, offset: 0, index: 0)
        encoder.setTexture(drawable.texture, index: 1)
        绑定辉光(encoder, 图: 辉光图, textureIndex: 3, strengthBufferIndex: 3, selfMaskBufferIndex: 4)
        var exposure = Float(pow(2.0, Double(settings.exposure)))
        encoder.setBytes(&exposure, length: MemoryLayout<Float>.stride, index: 1)
        var srcSize = SIMD2<UInt32>(UInt32(width), UInt32(height))
        encoder.setBytes(&srcSize, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 2)
        dispatch(encoder: encoder, pipeline: resolveOIDNPipeline, width: drawable.texture.width, height: drawable.texture.height)
        encoder.endEncoding()
        最后帧走降噪 = true
        采样探针(texture: drawable.texture, commandBuffer: commandBuffer)
        commandBuffer.addCompletedHandler { [在飞] _ in
            在飞.signal()
            // 材质槽回收与上面 提交帧() 配对：帧到 GPU 完成后回主线程才轮询
            Task { @MainActor in _ = 材质接线.共享.帧完成() }
            PT并发仲裁.shared.视口归还()
        }
        PT并发仲裁.shared.视口提交了()
        commandBuffer.present(drawable)
        材质接线.共享.提交帧()
        commandBuffer.commit()
        本帧缓冲.append(commandBuffer)
        hasPresentedFrame = true
        return true
    }

    /// 四个紧密 float3 缓冲（内部渲染分辨率）
    private func ensureOIDNBuffers(width: Int, height: Int) -> (color: MTLBuffer, albedo: MTLBuffer, normal: MTLBuffer, output: MTLBuffer)? {
        let bytes = width * height * 3 * MemoryLayout<Float>.stride
        func valid(_ buffer: MTLBuffer?) -> Bool { (buffer?.length ?? 0) == bytes }
        if !(valid(oidnColorBuffer) && valid(oidnAlbedoBuffer) && valid(oidnNormalBuffer) && valid(oidnOutputBuffer)) {
            // OIDN 的 oidnNewSharedBufferFromMetal 要求可共享存储，统一内存下 Shared 零成本
            let options: MTLResourceOptions = .storageModeShared
            oidnColorBuffer = device.makeBuffer(length: bytes, options: options)
            oidnAlbedoBuffer = device.makeBuffer(length: bytes, options: options)
            oidnNormalBuffer = device.makeBuffer(length: bytes, options: options)
            oidnOutputBuffer = device.makeBuffer(length: bytes, options: options)
        }
        guard let color = oidnColorBuffer,
              let albedo = oidnAlbedoBuffer,
              let normal = oidnNormalBuffer,
              let output = oidnOutputBuffer
        else { return nil }
        return (color, albedo, normal, output)
    }

    /// 降噪器按尺寸查缓存（新建 filter + 缓冲包装约 150~230ms，绝不能每次切换都做）
    private func ensureDenoiser(width: Int, height: Int) -> PTOIDNDenoiser? {
        let key = "\(width)x\(height)"
        if let existing = oidnDenoisers[key] {
            // 命中：把它挪到"最近使用"末尾
            if let index = oidnDenoiserKeys.firstIndex(of: key) { oidnDenoiserKeys.remove(at: index) }
            oidnDenoiserKeys.append(key)
            return existing
        }
        guard let denoiser = PTOIDNDenoiser(commandQueue: queue, width: UInt(width), height: UInt(height)) else {
            NSLog("PT OIDN 初始化失败（width=\(width) height=\(height)）")
            return nil
        }
        oidnDenoisers[key] = denoiser
        oidnDenoiserKeys.append(key)
        // 超出上限按最久未用淘汰（正常只会用到交互档 + 成片档两份）
        while oidnDenoiserKeys.count > oidnDenoiser上限, let 最旧 = oidnDenoiserKeys.first {
            oidnDenoiserKeys.removeFirst()
            oidnDenoisers.removeValue(forKey: 最旧)
            NSLog("PT OIDN 缓存淘汰 \(最旧)")
        }
        if !oidnLogged {
            oidnLogged = true
            NSLog("PT 降噪后端 = OIDN/\(denoiser.backendName) \(width)x\(height)")
        }
        return denoiser
    }


    /// 降噪不可用时的兜底呈现：不带降噪，直接把累积结果色调映射到 drawable。
    private func presentUndenoised(drawable: CAMetalDrawable, accumTexture: MTLTexture) -> Bool {
        guard let commandBuffer = queue.makeCommandBuffer() else {
            drawable.present()
            hasPresentedFrame = true
            return false
        }
        // 眩光（同一条链，源为累积缓冲）
        let 辉光图 = encodeGlow(commandBuffer: commandBuffer,
                                源: .累积(accumTexture),
                                width: accumTexture.width,
                                height: accumTexture.height)
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            drawable.present()
            hasPresentedFrame = true
            return false
        }
        encoder.label = "PT 色调映射（未降噪）"
        encoder.setComputePipelineState(resolvePipeline)
        encoder.setTexture(accumTexture, index: 0)
        encoder.setTexture(drawable.texture, index: 1)
        encoder.setTexture(accumCompTexture, index: 3)
        绑定辉光(encoder, 图: 辉光图, textureIndex: 2, strengthBufferIndex: 2, selfMaskBufferIndex: 3)
        var invSamples: Float = 1
        var exposureValue = Float(pow(2.0, Double(settings.exposure)))
        encoder.setBytes(&invSamples, length: MemoryLayout<Float>.stride, index: 0)
        encoder.setBytes(&exposureValue, length: MemoryLayout<Float>.stride, index: 1)
        dispatch(encoder: encoder, pipeline: resolvePipeline, width: drawable.texture.width, height: drawable.texture.height)
        encoder.endEncoding()
        最后帧走降噪 = false
        采样探针(texture: drawable.texture, commandBuffer: commandBuffer)
        commandBuffer.addCompletedHandler { [在飞] _ in
            在飞.signal()
            // 材质槽回收与上面 提交帧() 配对：帧到 GPU 完成后回主线程才轮询
            Task { @MainActor in _ = 材质接线.共享.帧完成() }
            PT并发仲裁.shared.视口归还()
        }
        PT并发仲裁.shared.视口提交了()
        commandBuffer.present(drawable)
        材质接线.共享.提交帧()
        commandBuffer.commit()
        本帧缓冲.append(commandBuffer)
        hasPresentedFrame = true
        return true
    }

    /// 灰雾探针：从 drawable 上抓 5 个点回读（1px×5，历史结论：整图大 blit 会假阴性，单点探针可信）
    private func 采样探针(texture: MTLTexture, commandBuffer: MTLCommandBuffer) {
        guard 探针待打印 > 0, texture.pixelFormat == .bgra8Unorm else { return }
        let w = texture.width
        let h = texture.height
        guard w > 8, h > 8 else { return }
        let 点位: [(Int, Int, String)] = [
            (w / 2, h / 2, "屏心"),
            (w / 2, h / 4, "上中"),
            (w / 2, h * 3 / 4, "下中"),
            (w / 4, h / 2, "左中"),
            (w * 3 / 4, h / 2, "右中")
        ]
        let bytes = 点位.count * 4
        if (探针Buffer?.length ?? 0) != bytes {
            探针Buffer = device.makeBuffer(length: bytes, options: .storageModeShared)
        }
        guard let buffer = 探针Buffer,
              let blit = commandBuffer.makeBlitCommandEncoder()
        else { return }
        blit.label = "PT 灰雾探针"
        for (i, p) in 点位.enumerated() {
            blit.copy(
                from: texture,
                sourceSlice: 0,
                sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: p.0, y: p.1, z: 0),
                sourceSize: MTLSize(width: 1, height: 1, depth: 1),
                to: buffer,
                destinationOffset: i * 4,
                destinationBytesPerRow: 4,
                destinationBytesPerImage: 4
            )
        }
        blit.endEncoding()

        探针待打印 -= 1
        探针序号 += 1
        let 序号 = 探针序号
        commandBuffer.addCompletedHandler { _ in
            let ptr = buffer.contents().bindMemory(to: UInt8.self, capacity: bytes)
            var 串 = ""
            for i in 0..<点位.count {
                let b = ptr[i * 4 + 0]
                let g = ptr[i * 4 + 1]
                let r = ptr[i * 4 + 2]
                串 += String(format: " %@=%d,%d,%d", 点位[i].2, r, g, b)
            }
            NSLog("PTDBG 探针#%d%@", 序号, 串)
        }
    }

    /// 统一派发：分块原点与帧内样本数都在这里一次性绑定，避免每个调用点各自记得传。
    /// spp 默认 1 = 改动前的"一次 dispatch 一个样本"；出图帧内 spp 循环传本帧实际样本数。
    private func dispatch(encoder: MTLComputeCommandEncoder, pipeline: MTLComputePipelineState, width: Int, height: Int, 原点: SIMD2<UInt32> = .zero, spp: UInt32 = 1) {
        let threadWidth = pipeline.threadExecutionWidth
        let threadHeight = max(pipeline.maxTotalThreadsPerThreadgroup / threadWidth, 1)
        let threadsPerGroup = MTLSize(width: threadWidth, height: threadHeight, depth: 1)
        let groups = MTLSize(
            width: (width + threadWidth - 1) / threadWidth,
            height: (height + threadHeight - 1) / threadHeight,
            depth: 1
        )
        // 分块原点：视口与整图渲染恒为 (0,0)，只有出图分块时才非零。
        // 放在这里统一 setBytes，所有调用点都不用各自记得传。
        var origin = 原点
        encoder.setBytes(&origin, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 24)
        // 帧内样本数：内核据此对同一像素连采 spp 次、只写回一次累积。
        // 必须每次都绑（不能只在出图路径绑），否则没绑的路径会让 buffer(25) 读到脏值。
        var 样本数 = max(spp, 1)
        encoder.setBytes(&样本数, length: MemoryLayout<UInt32>.stride, index: 25)
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threadsPerGroup)
    }

    private func ensureAccum(size: CGSize) -> Bool {
        if accumSize == size, accumTexture != nil, accumCompTexture != nil, gNormalDepthTexture != nil {
            // 尺寸没变就不用重建：这次没消费到标记，作废，避免留给下一次真正的档位切换
            出图刚结束 = false
            return true
        }
        let width = max(Int(size.width), 1)
        let height = max(Int(size.height), 1)

        func makeTexture(format: MTLPixelFormat, usage: MTLTextureUsage) -> MTLTexture? {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format,
                width: width,
                height: height,
                mipmapped: false
            )
            descriptor.usage = usage
            descriptor.storageMode = .private
            return device.makeTexture(descriptor: descriptor)
        }

        accumTexture = makeTexture(format: .rgba32Float, usage: [.shaderRead, .shaderWrite])
        accumCompTexture = makeTexture(format: .rgba32Float, usage: [.shaderRead, .shaderWrite])
        gNormalDepthTexture = makeTexture(format: .rgba16Float, usage: [.shaderRead, .shaderWrite])
        gAlbedoTexture = makeTexture(format: .rgba16Float, usage: [.shaderRead, .shaderWrite])
        NSLog("PTDBG ensureAccum recreate \(Int(size.width))x\(Int(size.height)) (old=\(Int(accumSize.width))x\(Int(accumSize.height)))")
        accumSize = size
        sampleIndex = 0
        // 队列容量跟内部渲染分辨率绑定，跟着一起换；建不出来就一直走全网格
        _ = ensureAdaptiveBuffers(width: width, height: height)
        // 纹理重建同样是"重开累积"：与上面 reset 分支同一条铁律 —— reset 必须配换代。
        // 交互档 0.6 ↔ 成片档 1.0 切换、拖窗口、拖分栏都会走到这里；只重建纹理不换代的话，
        // 追踪会接着用那颗可能已求交失效的 AS，结果就是整屏一个环境色，动一下视口才回来。
        // 换代本身是异步不阻塞的（build 里不 waitUntilCompleted），成本只有 GPU 上几毫秒。
        // 【唯一例外：出图刚结束】那一刻的尺寸差异来自"出图用全分辨率、视口用交互档"，
        // 几何一个字节都没动，AS 也刚被出图每批 refit 过，换代纯属白重建（表现为出图后
        // 视口第一帧 blas=rebuild）。只跳过这一次，之后所有尺寸变化照旧换代。
        if 出图刚结束 {
            出图刚结束 = false
            NSLog("PT 出图结束回视口：累积纹理按视口尺寸重建，加速结构沿用（不换代）")
        } else {
            acceleration.invalidate()
        }
        return accumTexture != nil
            && accumCompTexture != nil
            && gNormalDepthTexture != nil
            && gAlbedoTexture != nil
    }

    /// 自适应采样用的一维队列 + 派发参数缓冲。
    /// 容量按像素总数给足（最坏情况每个像素都入队一次），尺寸变了才重建。
    /// 分辨率是 0.5 档的交互尺寸，几百 KB 级，重建成本可忽略。
    private func ensureAdaptiveBuffers(width: Int, height: Int) -> Bool {
        let 像素数 = max(width * height, 1)
        if 自适应缓冲容量 == 像素数,
           像素队列缓冲 != nil, 自适应计数缓冲 != nil,
           自适应参数缓冲 != nil, 自适应上限缓冲 != nil {
            return true
        }
        自适应缓冲容量 = 0
        guard let 队列 = device.makeBuffer(
            length: 像素数 * MemoryLayout<SIMD2<UInt32>>.stride,
            options: .storageModePrivate
        ),
        let 计数 = device.makeBuffer(length: MemoryLayout<UInt32>.stride, options: .storageModePrivate),
        let 参数 = device.makeBuffer(length: MemoryLayout<UInt32>.stride * 4, options: .storageModePrivate),
        let 上限 = device.makeBuffer(length: MemoryLayout<UInt32>.stride, options: .storageModePrivate)
        else { return false }
        队列.label = "PT 自适应像素队列"
        计数.label = "PT 自适应计数"
        参数.label = "PT 自适应派发参数"
        上限.label = "PT 自适应队列长度"
        像素队列缓冲 = 队列
        自适应计数缓冲 = 计数
        自适应参数缓冲 = 参数
        自适应上限缓冲 = 上限
        自适应缓冲容量 = 像素数
        return true
    }

    private func reportSamples() {
        guard sampleIndex != lastReported else { return }
        // 每 8 个样本报一次，避免每帧刷 UI
        if sampleIndex % 8 == 0 || sampleIndex == 0 || sampleIndex >= UInt32(settings.maxSamples) {
            lastReported = sampleIndex
            onSampleUpdate?(sampleIndex)
        }
    }

    // MARK: - 离屏出图（渲染出图）
    //
    // 设计约束：出图必须复用视口那套完整画质链路（ptTrace → ptPackOIDN → OIDN → ptResolveOIDN），
    // 绝不另写一套追踪。所以这里不是"新的渲染器"，而是同一个 PTPathTracer 的一段离屏分支：
    //   · 目标纹理自建（bgra8Unorm），不碰 MTKView 的 drawable；
    //   · 分辨率固定 = 任务宽高，永不做交互期 0.5 降分辨率；
    //   · 每帧提交后不 present，也不阻塞主线程等 GPU（靠"上一帧没跑完就跳过本帧"的闸门）；
    //   · 累积到目标采样数后回调，交回离屏纹理由会话存 PNG。

    /// 离屏出图任务。设成非 nil 即进入出图模式；设回 nil 结束。
    var 离屏任务: PT离屏任务? {
        didSet {
            guard 离屏任务 != oldValue else { return }
            // 换任务 = 重开一轮累积：计数归零、离屏纹理按新尺寸重建、加速结构换代
            sampleIndex = 0
            lastReported = .max
            convergeStart = CFAbsoluteTimeGetCurrent()
            convergeLogged = false
            离屏目标纹理 = nil
            离屏在飞 = nil
            离屏自愈次数 = 0
            离屏待丢首帧 = (离屏任务 != nil)
            离屏命中峰值 = 0
            离屏连续作废 = 0
            离屏块列表 = []
            离屏块序号 = 0
            离屏轮样本 = 0
            离屏需清累积 = true
            离屏块日志已打 = false
            离屏本帧spp = 0
            // 【换任务不再全量清零】为将来序列帧渲染做准备：同一序列里分辨率恒定，
            // 逐帧把实测来的单样本耗时扔掉、再从 4 ms / 1 spp 重新探一遍，等于每帧都白烧一批。
            // 所以这里改成：
            //   · 任务结束（离屏任务 = nil）→ 先把本任务累计值回写成自校准系数 k，再清累计计数；
            //   · 分辨率不变 → 保留 离屏单样本耗时ms / 平滑值 / 已有实测标记，只清累计计数；
            //   · 分辨率变了 → 按像素比缩放估计值（单样本耗时基本与像素数成正比），不重置成 4.0。
            // 只影响"下一批跑几个样本"，不碰样本序号推进、随机种子、累积方式，像素结果完全不变。
            let 旧像素 = (oldValue?.宽 ?? 0) * (oldValue?.高 ?? 0)
            let 新像素 = (离屏任务?.宽 ?? 0) * (离屏任务?.高 ?? 0)
            if 离屏任务 == nil {
                // 会话结束（写出成功 / 取消 / 失败都会把任务置 nil）：先回写 k
                回写校准系数()
                离屏校准像素Mpx = 0
            } else if 旧像素 > 0, 新像素 > 0 {
                if 旧像素 == 新像素 {
                    // 分辨率相同（序列帧）：沿用上一帧实测，累计计数归零重新累计
                } else {
                    let 比 = Double(新像素) / Double(旧像素)
                    离屏单样本耗时ms = max(离屏单样本耗时ms * 比, 0.05)
                    离屏平滑单样本ms = max(离屏平滑单样本ms * 比, 0.05)
                }
                离屏校准像素Mpx = Double(新像素) / 1_000_000.0
            } else if 新像素 > 0 {
                // 渲染器第一次拿到任务：清一次基准像素，单样本耗时保持初始兜底值
                离屏校准像素Mpx = Double(新像素) / 1_000_000.0
            }
            离屏GPU累计ms = 0
            离屏GPU帧计 = 0
            离屏GPU累计样本 = 0
            上次离屏预览时间 = 0
            离屏回读池 = []
            离屏回读轮换 = 0
            // 换任务 = 新一次出图会话：上一轮冻结的绘画图集副本必须丢掉（由新会话重新冻结），
            // 否则会一直占着显存；让出计数也归零
            离屏绘画冻结 = nil
            离屏让出计 = 0
            离屏连让数 = 0
            // 【只在"进入出图"时换代，结束时不再换代】
            // 原来这里无条件 invalidate + lastCamera = nil，于是每次出图结束回视口，
            // 第一帧必然 cameraMoved → reset → acceleration.invalidate() → 提交行 blas=rebuild，
            // 也就是"出图一次，视口白重建一次"。出图每批都走 refit / 原地刷新，本身就一直在
            // "碰"这颗 AS（历史灰雾的成因是长期不碰，不是不换代），所以结束侧不必换代。
            // 回视口真正需要的只是：累积纹理按视口尺寸重建（ensureAccum 里做）+ 样本归零。
            if 离屏任务 != nil {
                acceleration.invalidate()
                lastCamera = nil
                出图刚结束 = false
            } else {
                // 结束侧只留一个标记：回视口那次累积纹理重建跳过换代（见 ensureAccum）
                出图刚结束 = true
            }
            NSLog("PT 出图：任务 %@ 采样上限 %d", 离屏任务.map { "\($0.宽)x\($0.高)" } ?? "结束", 离屏任务?.目标采样 ?? 0)
        }
    }
    /// 【绘画图集冻结副本】出图会话开始时深拷贝出来的私有图集，出图全程只读它。
    /// nil 表示没有冻结（没开并发开关 / 拷贝失败）——此时退回读全局快照，即老行为。
    private var 离屏绘画冻结: PaintGPUSnapshot.内容?
    /// 【空场景温和降耗】连续"场景为空"的帧数。只用于降频，**绝不**用于停止 draw 回调。
    private var 空场景帧数 = 0
    /// 降频阈值：连续 30 帧（60fps 下约 0.5s）仍为空才降到 10fps。
    /// 半秒以内的空档（切模式、重建场景、首次注入）完全不受影响，观感与满速一致。
    private let 空场景降频阈值 = 30
    /// 降频后的目标帧率：保留回调、能被任何输入叫醒，只是少跑几趟（空场景一帧的代价只有
    /// 一次转译缓存命中，本就没多少油水，降频只为在"工程本来就没有几何"时别一直空转）。
    private let 空场景帧率 = 10
    /// 降频前的目标帧率（恢复时按原值写回，不动用户/系统设置的刷新率）
    private var 空场景前帧率 = 0
    /// 空场景期间最后看到的相机。相机一变就说明"有人正在操作"，必须立刻回满速，
    /// 否则拖轨道/转视角在 10fps 下会明显发涩。只在空场景分支里更新，不影响正常帧。
    private var 空场景末次相机: PTCamera?

    /// 【出图刚结束】一次性标记：出图收尾后视口第一次重建累积纹理时跳过换代。
    /// 出图与视口共用 accumTexture，尺寸不同；回视口必然触发一次 ensureAccum 重建。
    /// 那颗加速结构只描述几何，与累积纹理尺寸无关，而且出图每批刚 refit 过（结构是"新鲜"的），
    /// 没有"长期不碰退化"的问题 —— 所以这一次重建累积不该连带换代。
    private var 出图刚结束 = false
    /// 本会话里因视口有帧在飞而被让出的拍数（只打日志，不影响像素）
    private var 离屏让出计 = 0
    /// 连续让出的拍数（上限 1）：防止视口长时间连续出帧把出图饿死
    private var 离屏连让数 = 0

    /// 把 PaintGPUSnapshot 的 atlas / 通道图集 / holeAtlas 深拷贝成私有冻结副本。
    ///
    /// 为什么必须拷贝而不能直接引用：全局图集是同一个 MTLTexture，视口落笔时会把图集就地
    /// 重合成（render 到原纹理）。出图批次正在采样时被改写，就会采到"半新半旧"的笔迹；
    /// slice 重排还会让同一个 slice 指向别的物体（串色 / 洞错位）。
    /// 拷贝成只读副本后两条路径各读各的，出图结果 = "开始出图那一刻的绘画状态"，
    /// 与串行跑的像素结果一致。
    ///
    /// 实现是一条 blit 命令缓冲把所有切片整段拷进新纹理，再 waitUntilCompleted 等它落定
    /// （一次性、几毫秒，发生在用户点「开始出图」的瞬间，不在渲染热路径上）。
    /// 同时借 PT并发仲裁 的冻结窗口挡住视口提交，避免拷到写了一半的图集。
    func 冻结离屏绘画图集() {
        let 源 = PaintGPUSnapshot.shared.读()
        离屏绘画冻结 = nil
        // 一张笔迹纹理都没有：没有被就地改写的对象，直接引用（CPU 侧的表本来就是值拷贝）
        guard 源.atlas != nil || 源.holeAtlas != nil || !源.通道图集.isEmpty else {
            离屏绘画冻结 = 源
            return
        }
        PT并发仲裁.shared.开始冻结()
        defer { PT并发仲裁.shared.结束冻结() }
        guard let 命令 = queue.makeCommandBuffer(), let 编码 = 命令.makeBlitCommandEncoder() else {
            NSLog("PT 出图：绘画图集冻结失败（拿不到命令缓冲），本会话沿用共享图集")
            离屏绘画冻结 = 源
            return
        }
        编码.label = "PT 出图 绘画图集冻结"
        var 冻结 = 源
        var 拷贝数 = 0
        冻结.atlas = 源.atlas.flatMap { 拷贝图集($0, 编码: 编码, 计数: &拷贝数) }
        var 通道副本: [PaintChannel: MTLTexture] = [:]
        for (通道, 纹理) in 源.通道图集 {
            if let 副本 = 拷贝图集(纹理, 编码: 编码, 计数: &拷贝数) { 通道副本[通道] = 副本 }
        }
        冻结.通道图集 = 通道副本
        冻结.holeAtlas = 源.holeAtlas.flatMap { 拷贝图集($0, 编码: 编码, 计数: &拷贝数) }
        编码.endEncoding()
        命令.commit()
        命令.waitUntilCompleted()
        guard 拷贝数 > 0 else {
            NSLog("PT 出图：绘画图集冻结失败（一张纹理都没拷成），本会话沿用共享图集")
            离屏绘画冻结 = 源
            return
        }
        离屏绘画冻结 = 冻结
        NSLog("PT 出图：绘画图集已冻结 %d 张副本（通道 %d，洞图 %@），revision %d",
              拷贝数, 通道副本.count, 冻结.holeAtlas == nil ? "无" : "有", 冻结.revision)
    }

    /// 按源纹理的尺寸/格式/层数新建一张 .private 纹理，逐切片整段 blit 过去。
    /// 返回 nil 表示建不出目标纹理（显存不足），调用方退回共享图集。
    private func 拷贝图集(_ 源: MTLTexture, 编码: MTLBlitCommandEncoder, 计数: inout Int) -> MTLTexture? {
        let 描述 = MTLTextureDescriptor()
        描述.textureType = 源.textureType
        描述.pixelFormat = 源.pixelFormat
        描述.width = 源.width
        描述.height = 源.height
        描述.depth = 源.depth
        描述.arrayLength = 源.arrayLength
        描述.mipmapLevelCount = 源.mipmapLevelCount
        描述.sampleCount = 源.sampleCount
        描述.storageMode = .private
        描述.usage = .shaderRead
        guard let 副本 = device.makeTexture(descriptor: 描述) else { return nil }
        let 原点 = MTLOrigin(x: 0, y: 0, z: 0)
        let 尺寸 = MTLSize(width: 源.width, height: 源.height, depth: 1)
        for 片 in 0..<max(源.arrayLength, 1) {
            编码.copy(from: 源, sourceSlice: 片, sourceLevel: 0, sourceOrigin: 原点, sourceSize: 尺寸,
                     to: 副本, destinationSlice: 片, destinationLevel: 0, destinationOrigin: 原点)
        }
        计数 += 1
        return 副本
    }

    /// 进度回调（主线程，参数为已累积采样数）
    var 离屏进度回调: ((UInt32) -> Void)?
    /// 完成回调（主线程，交出最终离屏纹理：bgra8Unorm，已 ACES + sRGB）
    var 离屏完成回调: ((MTLTexture) -> Void)?
    /// 失败回调（主线程）
    var 离屏失败回调: ((String) -> Void)?

    /// 渐进预览回调（主线程，CGImage 为当前累积画面的"未降噪"色调映射结果）。
    /// 挂上它才会做节流回读：窗口要实时看到图，挂不上就纯跑追踪，零额外开销。
    var 离屏预览回调: ((CGImage) -> Void)?

    private var 离屏目标纹理: MTLTexture?
    private var 离屏在飞: MTLCommandBuffer?
    private var 离屏自愈次数 = 0
    /// 任务重开后要丢弃的预热帧数（首帧不可信，绝不参与累积）
    private var 离屏待丢首帧 = false
    /// 本任务内的命中量峰值：用来识别"部分像素打偏"的隐性退化
    private var 离屏命中峰值: UInt32 = 0
    /// 连续作废帧数：仅做兜底，防止 AS 彻底废掉时无限重来
    private var 离屏连续作废 = 0

    /// 出图分块：把一帧的整图派发切成若干块，**在同一帧内把所有块都跑完**。
    /// 【为什么】4K 整图一帧是千万像素级的单次长 dispatch，单次执行时间长、更容易撞上
    /// GPU 单帧超时；切块的意义是缩短单个 dispatch 的时长，而不是把一帧的活拆成 N 帧 ——
    /// 每帧的固定开销（辉光、色调映射、命令缓冲、60Hz 节拍闸门）不会因切块而减少，
    /// 拆帧会把总时间放大到 N 倍。累积纹理仍是一整张，块只切派发范围。
    private var 离屏块列表: [SIMD2<UInt32>] = []
    /// 每块边长（像素）。按整图宽度自动选，1080p/2K 切 2×2、4K 切 4×3。
    private var 离屏块边长 = 1024
    /// 出图分块开关：关掉就退回单次整图 dispatch（块列表只含 (0,0) 一块）
    private let 离屏分块启用 = true
    /// 当前块下标：帧内已不再推进（一帧跑完全部块），仅保留给日志与重置使用
    private var 离屏块序号 = 0
    /// 每像素已完成的样本数：一帧内整图跑了几次样本就加几，进度与收敛上限都用它，
    /// 不能用 sampleIndex（分块后一帧内 sampleIndex 涨了 块数 × sppPerFrame 次）。
    private var 离屏轮样本: UInt32 = 0
    /// 本轮累积需要整图清零一次（任务重开/首帧丢弃后置真）
    private var 离屏需清累积 = false
    /// 分块结构日志只打一次
    private var 离屏块日志已打 = false
    /// 上一帧每块实际跑的样本数（帧内 spp 循环一次跑完），仅用于性能日志
    private var 离屏本帧spp: UInt32 = 0
    /// 出图每批（每帧）的 GPU 时间预算（毫秒），批样本数由它反推，见 离屏本批样本数(剩余样本:)。
    /// 并发关闭时的固定预算（老行为）；并发开启时改用 AIMD 闭环预算（见 离屏当前批预算ms()）。
    private let 离屏批预算ms: Double = 120.0

    /// 本批实际使用的 GPU 时间预算（毫秒）。
    /// - 并发关闭（老行为）：固定 120 ms。
    /// - 并发开启：取 PT并发仲裁 里 AIMD 闭环算出来的预算（区间恒在 [4, 250] ms，
    ///   低电量/过热时上限降到 64 ms）。原来"视口忙就恒定压到 16 ms"的一刀切降档已删除：
    ///   那条路径永远猜不准视口到底吃得下多少，反而把出图长期钉在 16 ms 的小批上。
    ///   现在只由"视口实测帧间隔 P95 是否超过目标帧间隔的 1.15 倍"来反馈调节。
    private func 离屏当前批预算ms() -> Double {
        guard 后台渲染并发视口 else { return 离屏批预算ms }
        return PT并发仲裁.shared.离屏批预算AIMD
    }
    /// 单样本 GPU 耗时估计（毫秒）。这是一个"结果值"，由累计法算出（见 更新离屏单样本耗时）。
    /// 4.0 只在累计样本数为 0 时作为除零兜底出现，不再作为首批估算的主依据。
    private var 离屏单样本耗时ms: Double = 4.0
    /// 小样本期的保守下限：指数平滑值，累计样本 < 64 时与累计值取 max（宁慢勿快，避免冲爆预算）
    private var 离屏平滑单样本ms: Double = 4.0
    /// 是否已开始用实测值（首批且没有跨任务校准系数 k 时仍保守跑 1 spp）
    private var 离屏已有实测耗时 = false
    /// 出图 GPU 耗时统计：累计毫秒、已统计帧数（纯追踪帧），每 10 帧打一条
    private var 离屏GPU累计ms: Double = 0
    private var 离屏GPU帧计 = 0
    /// 【累计法】本任务里已并入统计的样本总数，与 离屏GPU累计ms 同口径成对累加。
    /// 单样本耗时 = 离屏GPU累计ms / Double(离屏GPU累计样本)，不再靠逐帧指数平滑外推。
    private var 离屏GPU累计样本: UInt64 = 0
    /// 【跨设备自校准系数 k】毫秒 / (百万像素 · 样本)。
    /// nil 表示这台机器+这个系统版本上还没量过；有值就直接用来估首批样本数，
    /// 不必再用"首批 1 spp 探路"。key 里拼了 MTLDevice.name 与系统版本，换机/换系统自动失效。
    private var 离屏每Mpx样本ms: Double?
    /// 本任务累计值对应的像素规模（百万像素），回写 k 时用作分母
    private var 离屏校准像素Mpx: Double = 0
    /// 单批样本数上限：批预算是百毫秒量级，256 已远超任何真实设备能跑完的量，
    /// 只是防止"单样本耗时异常小"时把估算推到大得离谱、撞驱动单次 dispatch 上限。
    private let 离屏样本批上限 = 256

    /// 校准系数在 UserDefaults 里的 key：拼进 GPU 型号 + 系统版本，换硬件或换系统自动失效
    private static func 校准Key(设备: MTLDevice) -> String {
        "PT.离屏每Mpx样本ms.\(设备.name).\(ProcessInfo.processInfo.operatingSystemVersionString)"
    }

    /// 本批（本帧每块）要跑几个样本：按 GPU 时间预算反推，对标 Cycles 的批粒度自适应。
    ///
    /// 【为什么批预算取 120 ms】Cycles 在 CPU/CUDA 上按 2 s / 15 s 反推 num_samples，
    /// 那是它的"批"里还夹着 CPU 侧排队、tile 调度与重启逻辑；这里一批就是一条命令缓冲里的
    /// 一次（分块后是每块一次）compute dispatch，直接跑在 Metal 上，单次 dispatch 拖太长
    /// 会撞驱动的执行上限被中途掐断 —— 历史坑就是"命中计数只累了一部分甚至为 0"，
    /// 被误判成求交退化无限重开累积。120 ms 是两头都能兼顾的折中：既远离驱动看门狗，
    /// 又足够长到把每批的固定开销（命令缓冲、在飞闸门、完成回调、每 24 批一次全量 build）
    /// 摊薄近两个数量级（1080p 单样本约 4 ms，120 ms 约 20~30 个样本/批）。
    ///
    /// 【在视频后台渲染里的作用】视频导出是"每帧一个渲染任务、任务内几何不变"：
    /// 一帧的所有批共享同一份加速结构，批数越少 → 每帧的 refit / 全量 build / 命令缓冲
    /// 提交次数越少、GPU 空转的节拍等待越少，同样时长内能多渲几帧；同时批预算又死死限住
    /// 单次 dispatch 的时长，保证"每批 refit 保活 + 每 24 批回落全量 build"这条链路
    /// 不会因为批变长而撞上限。帧与帧之间拓扑不变时照旧走 refit，与批粒度无关。
    ///
    /// 【为什么不改像素结果】这里只决定"一批跑几个样本"：样本总数、样本序号推进
    /// （sampleIndex / 离屏轮样本 都按实际跑了多少推进）、随机种子（sampleIndex + s）、
    /// 累积与混合方式一律不变，最终累积出的图与逐样本跑完全等价。
    private func 离屏本批样本数(剩余样本: UInt32) -> UInt32 {
        guard 剩余样本 > 0 else { return 0 }
        // 上限：既不超过本帧剩余样本数（不越总采样上限），也不超过 离屏样本批上限(256)
        let 上限 = min(Int(剩余样本), 离屏样本批上限)
        let 本帧Mpx = max(离屏校准像素Mpx, 0.001)
        // 单样本耗时来源：①本任务已有实测（累计法）→ 直接用；
        // ②没实测但有跨设备校准系数 k → 用 k × 本帧百万像素数估；
        // ③两者都没有 → 首批保守 1 spp，把流水线跑热再说（不拿硬编码 4 ms 去赌）。
        let 单样本ms: Double
        if 离屏已有实测耗时 {
            单样本ms = 离屏单样本耗时ms
        } else if let k = 离屏每Mpx样本ms, k > 0 {
            单样本ms = k * 本帧Mpx
        } else {
            return 1
        }
        // 估算 = 批预算 / 单样本耗时 × 0.9（安全系数：留 10% 余量吸收估算误差）
        // 【为什么不再取 2 的幂】kernel 里的 spp 只是 `for (uint s = 0; s < 样本数; ++s)` 的循环
        // 次数（PT 着色器.metal:483），没有 threadgroup 尺寸依赖、没有位反转、没有低差异序列
        // （种子是哈希混合，相邻 s 天然不重复）—— 所以 spp 不需要是 2 的幂。
        // 旧的 `while 幂*2 <= 估算` 最坏会丢掉近一半预算，纯属白扔。
        let 估算 = Int(floor(离屏当前批预算ms() / max(单样本ms, 0.05) * 0.9))
        return UInt32(max(min(估算, 上限, Int(剩余样本)), 1))
    }

    /// 用本帧实测的 GPU 时间更新单样本耗时估计。
    ///
    /// 【累计法】先按同口径累加 GPU 毫秒与样本数，再算 累计ms / 累计样本。
    /// 累计样本 < 64 时取 max(累计值, 指数平滑值) 走保守一侧：小样本期累计值容易被
    /// 某一帧的短批带偏（首批固定开销摊不开），宁可估慢一点，也不要冲爆批预算。
    /// 累计样本 ≥ 64 后，累计值已是稳定实测，直接用，不再受逐帧抖动影响。
    private func 更新离屏单样本耗时(_ 完成: MTLCommandBuffer, 本帧样本数: UInt32) {
        guard 本帧样本数 > 0, 完成.gpuStartTime > 0, 完成.gpuEndTime > 完成.gpuStartTime else { return }
        let 毫秒 = (完成.gpuEndTime - 完成.gpuStartTime) * 1000.0
        // 只统计纯追踪帧：末帧含 OIDN、带渐进预览回读的帧含色调映射 + blit，
        // 混进来会把单样本耗时估高，批样本数被带小。
        离屏GPU累计ms += 毫秒
        离屏GPU累计样本 += UInt64(本帧样本数)
        离屏GPU帧计 += 1

        let 单样本 = 毫秒 / Double(本帧样本数)
        离屏平滑单样本ms = 离屏平滑单样本ms * 0.7 + 单样本 * 0.3

        let 累计值 = 离屏GPU累计ms / Double(max(离屏GPU累计样本, 1))
        离屏单样本耗时ms = 离屏GPU累计样本 < 64 ? max(累计值, 离屏平滑单样本ms) : 累计值
        离屏已有实测耗时 = true
    }

    /// 记录一帧出图的 GPU 耗时（取 commandBuffer 的 GPU 起止时间），每 10 帧打一条。
    /// 只读累计值不累加：累加统一在 更新离屏单样本耗时 里做，避免同一帧被记两次
    /// （那会让 累计ms 翻倍而 累计样本 只加一次，单样本耗时与 k 一起失真）。
    private func 记录离屏GPU耗时(_ 完成: MTLCommandBuffer) {
        let 起 = 完成.gpuStartTime
        let 止 = 完成.gpuEndTime
        guard 起 > 0, 止 > 起 else { return }
        let 毫秒 = (止 - 起) * 1000.0
        if 离屏GPU帧计 % 10 == 0 {
            NSLog(String(
                format: "PT 出图 性能：帧 %d 本帧 GPU %.1f ms，平均 %.1f ms，累计样本 %llu（%d spp/批基准），块数 %d，每块 spp %d，单样本 %.2f ms（下一批 %d spp，批预算 %.0f ms）",
                离屏GPU帧计, 毫秒, 离屏GPU累计ms / Double(max(离屏GPU帧计, 1)),
                离屏GPU累计样本,
                离屏轮样本, 离屏块列表.count, 离屏本帧spp,
                离屏单样本耗时ms,
                离屏本批样本数(剩余样本: UInt32(max(settings.maxSamples - Int(离屏轮样本), 0))),
                离屏当前批预算ms()
            ))
        }
    }

    /// 任务结束时回写自校准系数 k = 累计GPUms / (累计样本数 × 百万像素数)。
    /// 与旧值做 0.5 滑动平均后再落盘，避免单次任务被首帧预热/降噪尾帧带偏。
    private func 回写校准系数() {
        guard 离屏GPU累计样本 > 0, 离屏校准像素Mpx > 0, 离屏GPU累计ms > 0 else { return }
        let 新值 = 离屏GPU累计ms / (Double(离屏GPU累计样本) * 离屏校准像素Mpx)
        guard 新值.isFinite, 新值 > 0 else { return }
        let 平滑 = 离屏每Mpx样本ms.map { ($0 + 新值) * 0.5 } ?? 新值
        离屏每Mpx样本ms = 平滑
        UserDefaults.standard.set(平滑, forKey: Self.校准Key(设备: device))
        NSLog(String(
            format: "PT 出图 校准：本任务 %llu 样本 / %.1f ms / %.3f Mpx → k=%.4f ms/(Mpx·spp)，落盘 %.4f",
            离屏GPU累计样本, 离屏GPU累计ms, 离屏校准像素Mpx, 新值, 平滑
        ))
    }
    /// 出图命中计数的乒乓缓冲池。
    /// 【为什么不能复用视口那一块】：出图是"上一帧 GPU 一完成就立刻排下一帧"，帧 N 的完成回调
    /// 读计数与帧 N+1 的清零 blit 存在竞争窗口 —— 读到 0 或读到帧 N+1 的半截值，
    /// 就会被误判成"整屏 0 命中 / 命中暴跌"，进而无限作废归零（2K/4K 必现）。
    /// 每帧轮换一块独立缓冲，帧间互不覆盖，判定才可信。
    private var 离屏计数池: [MTLBuffer] = []
    private var 离屏计数轮换 = 0

    /// 按块边长把整图切成左上角坐标列表。
    /// 列数按整图宽度选：≤2K 切 2 列（1080p/2K 各 4 块），4K 切 4 列（3840×2160 → 12 块）。
    /// 块边长 = ceil(宽 / 列数)，高度方向按同一边长自然分行。
    private func 建立离屏块列表(宽: Int, 高: Int) -> [SIMD2<UInt32>] {
        // 开关关闭：退回分块前的行为，整图一次 dispatch
        guard 离屏分块启用 else {
            离屏块边长 = 宽
            return [SIMD2<UInt32>.zero]
        }
        let 列数 = 宽 >= 3000 ? 4 : 2
        离屏块边长 = max((宽 + 列数 - 1) / 列数, 16)
        let 边 = 离屏块边长
        var 块: [SIMD2<UInt32>] = []
        var y = 0
        while y < 高 {
            var x = 0
            while x < 宽 {
                块.append(SIMD2<UInt32>(UInt32(x), UInt32(y)))
                x += 边
            }
            y += 边
        }
        return 块
    }

    private func 取离屏计数缓冲() -> MTLBuffer? {
        if 离屏计数池.isEmpty {
            for i in 0..<4 {
                guard let 缓冲 = device.makeBuffer(
                    length: MemoryLayout<UInt32>.stride,
                    options: .storageModeShared
                ) else { return nil }
                缓冲.label = "PT 出图 命中计数 \(i)"
                离屏计数池.append(缓冲)
            }
        }
        guard !离屏计数池.isEmpty else { return nil }
        let 缓冲 = 离屏计数池[离屏计数轮换 % 离屏计数池.count]
        离屏计数轮换 += 1
        return 缓冲
    }
    /// 预览节流：两次回读的最小间隔（秒）。4K 下一次回读 ≈ 眨眼级，0.5s 足够顺滑又不抢 GPU。
    private var 上次离屏预览时间: CFAbsoluteTime = 0
    /// 回读缓冲双缓冲轮换：后台转 CGImage 时上一帧的缓冲不会被立刻覆写
    private var 离屏回读池: [MTLBuffer] = []
    private var 离屏回读轮换 = 0

    private func 离屏失败(_ 原因: String) {
        NSLog("PT 出图失败：%@", 原因)
        离屏失败回调?(原因)
    }

    private func 取离屏纹理(宽: Int, 高: Int) -> MTLTexture? {
        if let 现成 = 离屏目标纹理, 现成.width == 宽, 现成.height == 高 { return 现成 }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: 宽,
            height: 高,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        let 纹理 = device.makeTexture(descriptor: descriptor)
        纹理?.label = "PT 出图目标 \(宽)x\(高)"
        离屏目标纹理 = 纹理
        return 纹理
    }

    /// 把离屏纹理 blit 到一块复用的 shared 缓冲（只编码，不额外提交）。
    /// 返回缓冲与行字节数，交给命令缓冲的完成回调去做 CGImage。
    private func 编码离屏回读(
        命令: MTLCommandBuffer,
        源: MTLTexture,
        宽: Int,
        高: Int
    ) -> (缓冲: MTLBuffer, 每行字节: Int)? {
        // 纹理→缓冲 的 bytesPerRow 必须 256 字节对齐，自定义分辨率不一定命中，统一向上取整
        let 每行字节 = ((宽 * 4 + 255) / 256) * 256
        let 总字节 = 每行字节 * 高
        if 离屏回读池.count != 2 || 离屏回读池[0].length != 总字节 {
            var 新池: [MTLBuffer] = []
            for i in 0..<2 {
                guard let 缓冲 = device.makeBuffer(length: 总字节, options: .storageModeShared) else {
                    离屏回读池 = []
                    return nil
                }
                缓冲.label = "PT 出图 预览回读 \(i) \(宽)x\(高)"
                新池.append(缓冲)
            }
            离屏回读池 = 新池
            离屏回读轮换 = 0
        }
        let 缓冲 = 离屏回读池[离屏回读轮换]
        离屏回读轮换 = (离屏回读轮换 + 1) % 2

        guard let blit = 命令.makeBlitCommandEncoder() else { return nil }
        blit.label = "PT 出图 预览回读"
        blit.copy(
            from: 源,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: 宽, height: 高, depth: 1),
            to: 缓冲,
            destinationOffset: 0,
            destinationBytesPerRow: 每行字节,
            destinationBytesPerImage: 总字节
        )
        blit.endEncoding()
        return (缓冲, 每行字节)
    }

    /// 后台线程把回读缓冲转成 CGImage，再回主线程交出去。
    /// 4K 一张图拼 CGImage 要几十毫秒，绝不能压在主线程上做。
    private static func 转预览图(
        缓冲: MTLBuffer,
        每行字节: Int,
        宽: Int,
        高: Int,
        完成: @escaping (CGImage) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let 图 = PT缓冲转CGImage(缓冲: 缓冲, 每行字节: 每行字节, 宽: 宽, 高: 高) else { return }
            DispatchQueue.main.async { 完成(图) }
        }
    }

    /// 离屏渲染一帧。返回后不保证 GPU 已完成：上一帧还在飞就直接跳过本帧，
    /// 由出图会话的下一次驱动再来（主线程立刻归还，UI 不卡）。
    func 离屏渲染一帧() {
        guard 内核就绪 else { return }
        guard let 任务 = 离屏任务 else { return }
        // 闸门：上一帧没跑完就跳过，绝不阻塞主线程
        if let 上帧 = 离屏在飞, 上帧.status != .completed { return }

        // 【调度让步】并发模式下优先让视口上 GPU：视口有帧在飞时本拍直接让出，
        // 由 60 Hz 驱动拍的下一拍（≈16.7 ms 后）再来。只影响"什么时候跑"，
        // 不改变本批样本数、样本序号推进、累积方式与随机种子。
        // 连让上限 1 拍：视口如果长时间满负荷连续出帧（拖拽/动画），出图也至少隔一拍就跑一批，
        // 不会被饿死；这样两边大致是"你一拍我一拍"，视口不丢帧、出图也不会停住不动。
        if 后台渲染并发视口, 离屏连让数 < 1, PT并发仲裁.shared.视口在飞() {
            离屏连让数 += 1
            离屏让出计 += 1
            return
        }
        离屏连让数 = 0

        guard let scene = sceneProvider?(), !scene.isEmpty else {
            离屏失败("场景为空：没有可出图的几何体")
            return
        }
        let camera = cameraProvider.flatMap { $0() } ?? .fallback
        lastCamera = camera
        if scene.几何签名 != scene几何签名 {
            scene几何签名 = scene.几何签名
            scene材质版本 = scene.材质版本
            scene环境签名 = scene.环境签名
            scene变换版本 = scene.变换版本
        }
        // 【灯记账：只有版本号这一套口径】出图每批都会 refit（顺带重写灯缓冲），回视口后
        // 若不同步这两个数，视口会以为"灯自上次画以来变过" → 白清一次累积、多一次重建。
        // 判据与预览侧完全同源（scene.灯光版本 / scene.灯变换版本，由灯光接线单调推进），
        // 不再另记一份字符串哈希 —— 那种做法会被改名/哈希抖动误判。
        scene灯光版本 = scene.灯光版本
        scene灯变换版本 = scene.灯变换版本

        let 宽 = max(任务.宽, 16)
        let 高 = max(任务.高, 16)
        // 全分辨率：出图不做交互期降分辨率，scale 恒为 1
        guard ensureAccum(size: CGSize(width: 宽, height: 高)) else {
            离屏失败("无法创建 \(宽)×\(高) 的累积纹理")
            return
        }
        guard let accumTexture,
              let accumCompTexture,
              let gNormalDepthTexture,
              let gAlbedoTexture,
              let 目标 = 取离屏纹理(宽: 宽, 高: 高),
              let commandBuffer = queue.makeCommandBuffer()
        else {
            离屏失败("无法创建命令缓冲")
            return
        }
        let 加速起点 = CFAbsoluteTimeGetCurrent()
        // 【出图不再每帧全量换代】分块后台累积会把出图帧数放大到块数倍，每帧一次全量
        // 加速结构重建（build）的成本会跟着线性叠加，是分块不可行的直接原因。
        //
        // 语义上仍然要求每一帧拿到的结构是"新鲜"的（历史实测：同一颗结构连用第二帧起
        // 命中量开始掉），所以这里不是简单复用旧结构，而是改成两级重建：
        //   ① 拓扑不变 → 增量重建：BLAS 原地 refit（每帧重算 AABB）+ 实例层重建，
        //      求交结果与全量 build 等价，只是节点不重排，树质量略降；
        //   ② 拓扑变了 / 几何签名不符 / 增量次数用满 → 回落 invalidate() 全量重建，
        //      保证 BVH 质量不会随着出图帧数一路劣化。
        // 出图是离屏独占路径，本帧之前已有 离屏在飞.status != .completed 闸门，
        // CPU 侧改写顶点缓冲时不可能有在飞帧正在读同一份缓冲。
        // 【保活开关】false = 每批 refit 保活（推荐）；true = 每批直接全量换代（最保险）。
        // 千万别回到「签名没变就完全跳过 AS」：实测那样跑完 512 批会退化成整屏灰雾。
        let 出图每批强制换代 = false
        if 出图每批强制换代 || !acceleration.增量重建(scene) {
            acceleration.invalidate()
        }
        guard let payload = acceleration.payload(for: scene) else {
            离屏失败("加速结构构建失败")
            return
        }
        acceleration.更新切片(scene)
        let 加速耗时 = CFAbsoluteTimeGetCurrent() - 加速起点

        // 分块结构日志：每任务只打一次，方便实测核对 1080p=4 块、2K=4 块、4K=12 块
        if 离屏块列表.isEmpty { 离屏块列表 = 建立离屏块列表(宽: 宽, 高: 高) }
        if !离屏块日志已打, !离屏块列表.isEmpty {
            离屏块日志已打 = true
            // 帧内跑完全部块后不再存在"当前块"，日志只报块结构；
            // 每帧 dispatch 次数 = 块总数 × 每块样本数，而每块样本数已改为按批预算自适应
            NSLog("PT 出图 分块：%@ → %d 块，块边长 %d，每帧 dispatch %d 次（首批按校准 k 估或 1 spp，之后按 %.0f ms 批预算反推，上限 256）",
                  "\(宽)x\(高)", 离屏块列表.count, 离屏块边长, 离屏块列表.count, 离屏当前批预算ms())
        }

        // 命中计数清零：出图过程动辄几十帧，中途任何一次 AS 求交退化都会让整张图变成纯环境色，
        // 这里每帧清零、帧末读回，退化就换代重开（与预览同一套自愈机制）。
        let 计数缓冲 = 取离屏计数缓冲()
        if let 计数缓冲, let 清零 = commandBuffer.makeBlitCommandEncoder() {
            清零.label = "PT 出图 命中计数清零"
            清零.fill(buffer: 计数缓冲, range: 0..<MemoryLayout<UInt32>.stride, value: 0)
            清零.endEncoding()
        }

        // ---- 1. 追踪（与 draw 里预览那段逐行一致；改一处务必改两处）
        // 绘图集绑定：优先用会话开始时冻结的私有副本（并发模式下唯一的硬冲突隔离点），
        // 没有冻结（开关关闭 / 拷贝失败 / 无笔迹之外的极端情况）才退回读全局快照。
        let 绘画快照 = 离屏绘画冻结 ?? PaintGPUSnapshot.shared.读()
        // 出图不再读 settings.samplesPerFrame（它属于预览的"每帧样本档"）：
        // 每批跑几个样本改由 离屏本批样本数(剩余样本:) 按 GPU 时间预算反推。
        if let encoder = commandBuffer.makeComputeCommandEncoder() {
            encoder.label = "PT 出图 追踪"
            encoder.setComputePipelineState(tracePipeline)

            var gpuCamera = camera.gpu(aspect: Float(宽) / Float(高),
                                       介质时间: settings.volumeTime,
                                       介质湍流: settings.volumeTurbulence)
            var bounces = UInt32(max(settings.maxBounces, 1))

            encoder.setBytes(&gpuCamera, length: MemoryLayout<PTCameraGPU>.stride, index: 0)
            var environment = scene.environment
            encoder.setBytes(&environment, length: MemoryLayout<PTEnvironmentGPU>.stride, index: 1)
            encoder.setBuffer(payload.vertexBuffer, offset: 0, index: 2)
            encoder.setBuffer(payload.normalBuffer, offset: 0, index: 3)
            encoder.setBuffer(payload.indexBuffer, offset: 0, index: 4)
            encoder.setBuffer(payload.triangleMaterialBuffer, offset: 0, index: 5)
            encoder.setBuffer(payload.materialBuffer, offset: 0, index: 6)
            encoder.setAccelerationStructure(payload.instanceAcceleration, bufferIndex: 7)
            encoder.setTexture(accumTexture, index: 0)
            encoder.setTexture(gNormalDepthTexture, index: 1)
            encoder.setTexture(gAlbedoTexture, index: 2)
            encoder.setTexture(accumCompTexture, index: 12)
            encoder.setBytes(&bounces, length: MemoryLayout<UInt32>.stride, index: 9)
            encoder.setBuffer(payload.lightTriangleBuffer, offset: 0, index: 10)
            encoder.setBuffer(payload.lightCDFBuffer, offset: 0, index: 11)
            var lightCount = UInt32(payload.lightCount)
            encoder.setBytes(&lightCount, length: MemoryLayout<UInt32>.stride, index: 12)

            encoder.setBuffer(payload.uvBuffer, offset: 0, index: 13)
            encoder.setBuffer(payload.sliceBuffer, offset: 0, index: 14)
            var hasPaint = UInt32((绘画快照.有绘画 && 绘画快照.atlas != nil) ? 1 : 0)
            encoder.setBytes(&hasPaint, length: MemoryLayout<UInt32>.stride, index: 15)
            if let atlas = 绘画快照.atlas {
                encoder.setTexture(atlas, index: 3)
            } else if let 占位 = 取占位图集() {
                encoder.setTexture(占位, index: 3)
            }
            var 通道掩码: UInt32 = 0
            let 通道槽: [(PaintChannel, UInt32, Int)] = [
                (.roughness, 1, 5),
                (.metalness, 2, 6),
                (.coatWeight, 4, 7),
                (.coatRoughness, 8, 8),
                (.emission, 16, 9),
                (.normal, 32, 10)
            ]
            let 空图集 = 取占位图集()
            for (通道, 位, 槽) in 通道槽 {
                if let tex = 绘画快照.通道图集[通道] {
                    encoder.setTexture(tex, index: 槽)
                    通道掩码 |= 位
                } else if let 空图集 {
                    encoder.setTexture(空图集, index: 槽)
                }
            }
            encoder.setBytes(&通道掩码, length: MemoryLayout<UInt32>.stride, index: 18)
            // ---- 材质贴图（导入的基础色图）：一片一个材质 ----
            // 层序靠着色器保证：贴图只当"底"，笔迹再盖上去，这里的绑定不影响绘画可见性。
            if let 材质 = 取材质图集(scene.材质贴图, 档: settings.textureTier, 材质版本: scene.材质版本) {
                encoder.setTexture(材质, index: 11)
            } else if let 空图集 {
                encoder.setTexture(空图集, index: 11)
            }
            // ---- 显式灯光（不是几何，直接光采样用）----
            encoder.setBuffer(payload.lightsBuffer, offset: 0, index: 19)
            var 灯数 = UInt32(payload.lightsCount)
            encoder.setBytes(&灯数, length: MemoryLayout<UInt32>.stride, index: 20)
            // 显式灯亮度 CDF（重要性采样）：index 26 是当前唯一空位，别跟 0-14 / 21-25 撞
            encoder.setBuffer(payload.lightsCDFBuffer, offset: 0, index: 26)
            // 灯 AABB 树（保守剔除）：27 节点 / 28 叶内灯顺序 / 29 树头。
            // 树头灯数与当前灯数不一致时着色器会整体退回线性扫描，所以这里照实传，不做猜测。
            encoder.setBuffer(payload.lightNodeBuffer, offset: 0, index: 27)
            encoder.setBuffer(payload.lightOrderBuffer, offset: 0, index: 28)
            var 灯树头 = PTLightTreeHeaderGPU(节点数: UInt32(max(payload.lightNodeCount, 0)),
                                              灯数: UInt32(max(payload.lightTreeLightsCount, 0)))
            encoder.setBytes(&灯树头, length: MemoryLayout<PTLightTreeHeaderGPU>.stride, index: 29)
            // ---- 特效发射器（体积介质源）：只有数组，占 30 号槽 ----
            // Metal 的 buffer 索引上限就是 0…30，0…29 已用满，30 是最后一个空位，
            // 所以数量不单独占槽位：**有效项连续在前，其余全零**，着色器遇全零即停。
            // 固定上限缓冲每帧原地重写照帧快照（不看 payload 抄下来的旧值）。
            // 没有发射器时整段全零，着色器整段跳过 —— 逐像素与接入前完全一致。
            let 发射器数 = min(scene.特效发射器.count, PTVolumeEmitterGPU.上限)
            let 发射器缓冲长 = PTVolumeEmitterGPU.上限 * MemoryLayout<PTVolumeEmitterGPU>.stride
            memset(payload.emitterBuffer.contents(), 0, 发射器缓冲长)
            if 发射器数 > 0 {
                scene.特效发射器.withUnsafeBytes { 源 in
                    if let 首 = 源.baseAddress {
                        payload.emitterBuffer.contents().copyMemory(
                            from: 首,
                            byteCount: 发射器数 * MemoryLayout<PTVolumeEmitterGPU>.stride
                        )
                    }
                }
            }
            encoder.setBuffer(payload.emitterBuffer, offset: 0, index: 30)
            // ---- 模拟场体素：13…20 密、21…28 温 ----
            // 和视口绑的是同一批 MTLTexture（同一份体素内容），
            // 出图与预览因此不是"算得像"，而是读同一堆体素。
            // 每个槽都必须绑：Metal 不允许 texture 数组缺项，空槽用 1×1×1 占位顶上，
            // 着色器按 sim.z == 0 提前跳过，不会真去采。
            if let 占位模拟 = 取占位模拟图() {
                for 槽 in 0..<PTVolumeEmitterGPU.模拟上限 {
                    let 密 = 槽 < scene.特效模拟密.count ? scene.特效模拟密[槽] : nil
                    let 温 = 槽 < scene.特效模拟温.count ? scene.特效模拟温[槽] : nil
                    encoder.setTexture(密 ?? 占位模拟, index: 13 + 槽)
                    encoder.setTexture(温 ?? 占位模拟, index: 21 + 槽)
                }
            }
            encoder.setBuffer(payload.holeSlotBuffer, offset: 0, index: 17)
            if let 洞图 = 绘画快照.holeAtlas, 绘画快照.有洞 {
                encoder.setTexture(洞图, index: 4)
            } else if let 占位 = 取占位洞图() {
                encoder.setTexture(占位, index: 4)
            }
            if let 计数缓冲 {
                encoder.setBuffer(计数缓冲, offset: 0, index: 16)
            }

            var 队列长度: UInt32 = 0
            if let 队列 = 像素队列缓冲 { encoder.setBuffer(队列, offset: 0, index: 21) }
            // 出图档永远走全网格：每像素每个样本都采，绝不因为"看着够干净"少算一次
            encoder.setBytes(&队列长度, length: MemoryLayout<UInt32>.stride, index: 22)

            // ---- 分块：外层样本、内层块，一帧内把整图所有块都跑完 ----
            // 【为什么不能一帧一块】一帧的固定开销（辉光、色调映射、命令缓冲、60Hz 闸门）
            // 与块数无关，把一帧的活拆成 N 帧就把总时间放大 N 倍；分块只为缩短单次
            // dispatch 时长，帧数必须与分块前完全一致。
            if 离屏块列表.isEmpty { 离屏块列表 = 建立离屏块列表(宽: 宽, 高: 高) }
            if 离屏块序号 >= 离屏块列表.count { 离屏块序号 = 0 }

            // ---- 整图累积清零：靠内核的 resetAccum（buffer 23）逐像素完成 ----
            // accum / accumComp 是 storageMode.private 的纹理，blit 的 fill 只支持缓冲、
            // 纹理 replace() 又要求非 private，所以"整图清零"改由内核做，语义完全等价：
            // 每一轮的首个样本对本块像素置 resetAccum=1，内核把该像素的累加和与补偿项
            // 丢成 0（金属 L851-865）。因为每块只清自己的像素、且只在"轮样本==0 的首个样本"
            // 清一次，整圈块跑完之后整张图恰好被清过一遍，与原来整图 dispatch 时
            // sampleIndex==0 首样本一次性清全图等价；且每帧最多只清当前这一块，无额外开销。
            // 分块改到帧内后：本轮首个样本对**所有块**都置 1，每块清自己那片像素，
            // 整帧之内整张图刚好被清一次，语义与"首样本清全图"完全一致。
            // ---- 帧内 spp 循环：一帧里每个块只 dispatch 一次，样本循环搬进内核 ----
            // 【为什么】以前同一块要 dispatch sppPerFrame 次，每次内核都 accum.read +
            // accumComp.read 再写回；4K 下这两张纹理各 132MB，一个样本就是 264MB 纯搬运。
            // 现在内核内部连采 N 次、辐射留在寄存器里，一次 dispatch 只写回一次累积。
            var 本帧样本数: UInt32 = 0
            let 剩余样本 = settings.maxSamples > Int(离屏轮样本)
                ? UInt32(settings.maxSamples - Int(离屏轮样本)) : 0
            // 本帧每个块实际要跑的样本数：按批预算反推，且不越过总采样上限
            // （精确整数、不取 2 的幂，夹在 [1, min(剩余, 256)]；见 离屏本批样本数(剩余样本:)）
            let 本块spp = 离屏本批样本数(剩余样本: 剩余样本)
            if 本块spp > 0 {
                for 块原点 in 离屏块列表 {
                    let 块宽 = max(min(离屏块边长, 宽 - Int(块原点.x)), 1)
                    let 块高 = max(min(离屏块边长, 高 - Int(块原点.y)), 1)
                    var sample = sampleIndex
                    // 本轮首个样本才丢旧累加和；同一帧内所有块共用这一个样本值
                    var 清零标记: UInt32 = (离屏需清累积 && 离屏轮样本 == 0) ? 1 : 0
                    encoder.setBytes(&sample, length: MemoryLayout<UInt32>.stride, index: 8)
                    encoder.setBytes(&清零标记, length: MemoryLayout<UInt32>.stride, index: 23)
                    // 分块只切派发范围（宽高=块尺寸、原点=块左上角），累积纹理仍是整张，
                    // 内核里 gid += tileOrigin 把块内坐标挪回整图坐标再写 accum；
                    // 内核里第 s 个样本的种子是 (sampleIndex + s)，所以这里按块整段推进取样序号。
                    dispatch(encoder: encoder, pipeline: tracePipeline,
                             width: 块宽, height: 块高, 原点: 块原点, spp: 本块spp)
                    sampleIndex += 本块spp
                }
                本帧样本数 = 本块spp
            }
            离屏本帧spp = 本帧样本数
            // 一帧内整图实际跑了本帧样本数 次，就给"每像素样本数"加这么多次（不写死 sppPerFrame）
            离屏轮样本 &+= 本帧样本数
            // 首轮整图已清过，后续轮次继续累加，不再清零
            离屏需清累积 = false
            encoder.endEncoding()
        }

        // ---- 中途帧：只跑追踪，不降噪、不呈现 ----
        // OIDN 与色调映射是给"屏幕上看得见"准备的。出图过程中没人看屏幕，
        // 4K 下每帧跑一遍 OIDN 是几百毫秒级的白烧，所以只在最后一帧做。
        // 进度上报、求交退化自愈照样每帧通过完成回调回主线程。
        if 离屏轮样本 < UInt32(任务.目标采样) {
            let 帧样本 = 离屏轮样本
            // 本批每块实际跑的样本数（结束时回算单样本耗时用）
            let 本帧批spp = 离屏本帧spp
            // 渐进预览：每 0.5s 对当前累积做一次"不含 OIDN"的 resolve（和最终帧同一条色调映射链路），
            // 顺手 blit 回读，后台转 CGImage。渲染窗口据此"越渲越干净"，视口那头完全不参与。
            var 预览回读: (缓冲: MTLBuffer, 每行字节: Int)?
            let 现在 = CFAbsoluteTimeGetCurrent()
            if 离屏预览回调 != nil, 现在 - 上次离屏预览时间 >= 0.5,
               离屏编码未降噪(commandBuffer: commandBuffer, 目标: 目标, accum: accumTexture) {
                上次离屏预览时间 = 现在
                预览回读 = 编码离屏回读(命令: commandBuffer, 源: 目标, 宽: 宽, 高: 高)
            }
            离屏在飞 = commandBuffer
            // 出图（离屏）也是采样材质的一帧：提交前登记、GPU 完成后回主线程销账
            材质接线.共享.提交帧()
            commandBuffer.addCompletedHandler { [weak self] 完成 in
                Task { @MainActor in _ = 材质接线.共享.帧完成() }
                if let 错误 = 完成.error {
                    NSLog("PT 出图：中途帧命令缓冲失败 %@", String(describing: 错误))
                }
                let 命中 = 计数缓冲?.contents().load(as: UInt32.self) ?? 1
                // 量化本帧 GPU 耗时：块数 / 每块 spp 一起打出来，方便和改动前对比
                self?.记录离屏GPU耗时(完成)
                // 用本批实测 GPU 时间 ÷ 本批样本数 刷新单样本耗时，供下一批反推样本数
                // （只算纯追踪的中间帧：末帧含 OIDN、带渐进预览回读的帧含色调映射 + blit，
                // 都不并进这个估计，否则批样本数会被噪声带偏）
                if 预览回读?.缓冲 == nil {
                    self?.更新离屏单样本耗时(完成, 本帧样本数: 本帧批spp)
                }
                // 【AIMD 闭环】一批（一帧）真的跑完了才喂一次反馈：
                // 取视口最近 30 帧间隔的 P95 与目标帧间隔比，撑爆就乘 0.7、连续 3 批稳就乘 1.15。
                // 放在完成回调里（不在提交前），这样"这一批到底有没有把视口挤掉帧"才是实测的。
                PT并发仲裁.shared.出图批完成()
                if let 预览回读 {
                    Self.转预览图(
                        缓冲: 预览回读.缓冲,
                        每行字节: 预览回读.每行字节,
                        宽: 宽,
                        高: 高
                    ) { 图 in
                        Task { @MainActor [weak self] in
                            self?.离屏预览回调?(图)
                        }
                    }
                }
                Task { @MainActor [weak self] in
                    self?.离屏帧结束(样本: 帧样本, 命中: 命中)
                }
            }
            commandBuffer.commit()
            return
        }

        // ---- 2. 降噪 + 色调映射 → 离屏纹理（不 present）
        var 最终: MTLCommandBuffer?
        if settings.denoiseEnabled,
           let oidnBuffers = ensureOIDNBuffers(width: 宽, height: 高),
           let denoiser = ensureDenoiser(width: 宽, height: 高) {
            encodePackOIDN(
                commandBuffer: commandBuffer,
                width: 宽,
                height: 高,
                colorBuffer: oidnBuffers.color,
                albedoBuffer: oidnBuffers.albedo,
                normalBuffer: oidnBuffers.normal
            )
            // 追踪 + 打包先提交，OIDN 在本队列上排在其后，天然同序
            commandBuffer.commit()
            let 降噪起点 = CFAbsoluteTimeGetCurrent()
            let ok = denoiser.denoiseColor(
                oidnBuffers.color,
                albedo: oidnBuffers.albedo,
                normal: oidnBuffers.normal,
                output: oidnBuffers.output,
                quality: .high,
                // 出图是低频调用，这里同步等 OIDN 真正写完：只有 sync 之后
                // oidnGetDeviceError 才能反映出执行期的错误，读回像素也才有保证。
                // 预览侧仍保持 false（靠同队列顺序），不影响交互帧率。
                synchronize: true
            )
            NSLog("PT 出图 降噪 %.1f ms（spp=%d）", (CFAbsoluteTimeGetCurrent() - 降噪起点) * 1000, 离屏轮样本)
            if ok {
                最终 = 离屏呈现OIDN(目标: 目标, width: 宽, height: 高)
            }
            if 最终 == nil {
                // OIDN 出错时不做降噪，直接色调映射累积结果，画面不中断
                NSLog("PT 出图：OIDN 降噪失败，回落未降噪通路")
                if let 兜底 = queue.makeCommandBuffer(),
                   离屏编码未降噪(commandBuffer: 兜底, 目标: 目标, accum: accumTexture) {
                    最终 = 兜底
                }
            }
        } else {
            if 离屏编码未降噪(commandBuffer: commandBuffer, 目标: 目标, accum: accumTexture) {
                最终 = commandBuffer
            }
        }

        guard let 最终 else {
            离屏失败("无法编码色调映射")
            return
        }
        let 帧样本 = 离屏轮样本
        离屏在飞 = 最终
        // 末帧是最长的一条缓冲（追踪 + 降噪 + 色调映射），登记它等于守住整帧的 GPU 生命周期
        材质接线.共享.提交帧()
        最终.addCompletedHandler { [weak self] 完成 in
            Task { @MainActor in _ = 材质接线.共享.帧完成() }
            if let 错误 = 完成.error {
                NSLog("PT 出图：末帧命令缓冲失败 %@", String(describing: 错误))
            }
            let 命中 = 计数缓冲?.contents().load(as: UInt32.self) ?? 1
            // 末帧的 GPU 时间里还含 OIDN 降噪 + 色调映射，单独打一行、不并入中途帧平均，
            // 否则"纯追踪帧"的耗时就再也和改动前不可比了。
            if 完成.gpuStartTime > 0, 完成.gpuEndTime > 完成.gpuStartTime {
                NSLog(String(
                    format: "PT 出图 性能：末帧（含降噪）GPU %.1f ms，累计样本 %d，块数 %d，每块 spp %d",
                    (完成.gpuEndTime - 完成.gpuStartTime) * 1000.0,
                    self?.离屏轮样本 ?? 0, self?.离屏块列表.count ?? 0, self?.离屏本帧spp ?? 0
                ))
            }
            // 回主线程收尾：进度上报、自愈判定、完成交图都在主线程做
            Task { @MainActor [weak self] in
                self?.离屏帧结束(样本: 帧样本, 命中: 命中)
            }
        }
        最终.commit()
        // 刻意不调 记录()：出图的帧耗时不该混进视口 HUD 的性能统计里
    }

    /// 一帧离屏渲染的 GPU 收尾（主线程）
    private func 离屏帧结束(样本: UInt32, 命中: UInt32) {
        guard let 任务 = 离屏任务 else { return }

        // ── ① 首帧预热丢弃：任务重开累积时加速结构刚换代，第一帧本就不可信 ──
        // （旧逻辑里"曾命中过"守卫会把首帧整屏天空的样本放进去平均，这是灰雾的第一个漏点）
        if 离屏待丢首帧 {
            离屏待丢首帧 = false
            sampleIndex = 0
            // 分块：丢弃的这一帧只写了其中一块，必须把块进度与每像素样本数一起退回起点，
            // 并重新置清零标记，让下一轮的首个样本把整张累积按块清一遍（块列表尺寸没变，保留）。
            离屏块序号 = 0
            离屏轮样本 = 0
            离屏需清累积 = true
            lastReported = .max
            离屏进度回调?(0)
            NSLog("PT 出图：首帧预热丢弃（命中 %d，分块 %d 块）", 命中, 离屏块列表.count)
            return
        }

        // ── ② 命中数只做统计，绝不参与流程控制 ──
        // 这里是上一次"无限归零"的根源：判定一抖就把 sampleIndex 打回 0，
        // 进度永远重来。出图的进度现在只由"实际累积样本数"单向推进，
        // 命中数降级为诊断信息，写日志可以，改流程不可以。
        if 命中 > 离屏命中峰值 { 离屏命中峰值 = 命中 }

        离屏进度回调?(样本)
        if 样本 >= UInt32(任务.目标采样) {
            guard let 纹理 = 离屏目标纹理 else {
                离屏失败("离屏纹理已释放")
                return
            }
            离屏完成回调?(纹理)
        }
    }

    /// OIDN 输出 → ACES + sRGB → 离屏纹理。返回未提交的命令缓冲，由调用方挂完成回调后提交。
    private func 离屏呈现OIDN(目标: MTLTexture, width: Int, height: Int) -> MTLCommandBuffer? {
        guard let outputBuffer = oidnOutputBuffer,
              let commandBuffer = queue.makeCommandBuffer()
        else { return nil }
        let 辉光图 = encodeGlow(commandBuffer: commandBuffer,
                                源: .降噪缓冲(outputBuffer, width: width, height: height),
                                width: width,
                                height: height)
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }
        encoder.label = "PT 出图 OIDN 色调映射"
        encoder.setComputePipelineState(resolveOIDNPipeline)
        encoder.setBuffer(outputBuffer, offset: 0, index: 0)
        encoder.setTexture(目标, index: 1)
        绑定辉光(encoder, 图: 辉光图, textureIndex: 3, strengthBufferIndex: 3, selfMaskBufferIndex: 4)
        var exposure = Float(pow(2.0, Double(settings.exposure)))
        encoder.setBytes(&exposure, length: MemoryLayout<Float>.stride, index: 1)
        var srcSize = SIMD2<UInt32>(UInt32(width), UInt32(height))
        encoder.setBytes(&srcSize, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 2)
        dispatch(encoder: encoder, pipeline: resolveOIDNPipeline, width: 目标.width, height: 目标.height)
        encoder.endEncoding()
        最后帧走降噪 = true
        return commandBuffer
    }

    /// 未降噪通路：累积缓冲 → ACES + sRGB → 离屏纹理（编码进调用方给的命令缓冲）
    private func 离屏编码未降噪(commandBuffer: MTLCommandBuffer, 目标: MTLTexture, accum: MTLTexture) -> Bool {
        let 辉光图 = encodeGlow(commandBuffer: commandBuffer,
                                源: .累积(accum),
                                width: accum.width,
                                height: accum.height)
        // 同 encodePackOIDN：先校验可选值，再创建编码器，避免编码器被 guard 提前返回带走
        guard let accumComp = accumCompTexture else { return false }
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return false }
        encoder.label = "PT 出图 色调映射（未降噪）"
        encoder.setComputePipelineState(resolvePipeline)
        encoder.setTexture(accum, index: 0)
        encoder.setTexture(目标, index: 1)
        encoder.setTexture(accumComp, index: 3)
        绑定辉光(encoder, 图: 辉光图, textureIndex: 2, strengthBufferIndex: 2, selfMaskBufferIndex: 3)
        var invSamples: Float = 1
        var exposure = Float(pow(2.0, Double(settings.exposure)))
        encoder.setBytes(&invSamples, length: MemoryLayout<Float>.stride, index: 0)
        encoder.setBytes(&exposure, length: MemoryLayout<Float>.stride, index: 1)
        dispatch(encoder: encoder, pipeline: resolvePipeline, width: 目标.width, height: 目标.height)
        encoder.endEncoding()
        最后帧走降噪 = false
        return true
    }
}
