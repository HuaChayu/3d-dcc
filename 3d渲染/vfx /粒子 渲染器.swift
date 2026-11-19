import Foundation
import Metal
import MetalKit
import QuartzCore
import simd

// MARK: - 粒子渲染器
//
// 职责边界（见 数据层 架构规矩.md）：
// - 只读输入：发射器快照（设置 + 世界矩阵，主线程算好）、全局物理域、相机；
// - 本文件里的全部状态（粒子池、写指针、累计时间）都是**渲染器工作状态**，
//   不进任何域、不存盘、不改参数真值；
// - 时间由视口帧驱动，自己不起 Timer（与 PT 视口同一节奏，见 PT并发仲裁）。

final class 粒子渲染器: NSObject, MTKViewDelegate {

    // MARK: 输入

    struct 输入 {
        var 发射器: [粒子发射器快照] = []
        /// xyz = 球心，w = 半径（已含缩放）。上限 48，数量多到这个量级就没必要再叠了
        var 碰撞球: [SIMD4<Float>] = []
        var 物理域: 物理域 = .标准
        var 相机: PTCamera?
        /// 时间轴播放头当前帧。**模拟只认它**：帧号不变就一步都不推，
        /// 停止播放后画面必须冻在那一帧（此前按真实帧间隔推进，一停就成了"自己还在播"）。
        var 帧: Int = 0
        /// 时间轴帧率。一帧固定推进 1/帧率 秒 —— 播放快慢不再由显示器刷新率决定。
        var 帧率: Double = 24
        /// 烘焙回放：这一帧的现成模拟状态（id → 池快照）。
        /// 有值时**整段 compute 跳过**，直接把这批粒子铺进池再画 —— 这就是「路径播放用现成结果」。
        /// 为 nil 就回落到实时积分，两条路切换对用户是透明的。
        var 回放: [UUID: 烘焙发射器帧]?
    }

    struct 统计 {
        var 发射器数: Int = 0
        var 在场粒子数: Int = 0
        var 帧耗时毫秒: Double = 0
    }

    // MARK: 粒子池

    /// 一个发射器一个池：池容量 = 这个发射器的「最大粒子数」。
    /// 用环形写指针，发射 O(1)；池满覆盖最老的粒子，不做压缩、不做排序。
    private final class 粒子池 {
        let 粒子: MTLBuffer
        let 写指针: MTLBuffer
        let 容量: Int
        var 待发射: Double = 0
        var 时刻: Float = 0
        var 帧序号: UInt32 = 0

        init?(device: MTLDevice, 容量: Int) {
            let 上限 = max(256, min(200_000, 容量))
            let 字节 = 上限 * MemoryLayout<粒子GPU>.stride
            guard let 粒子 = device.makeBuffer(length: 字节, options: .storageModeShared),
                  let 写指针 = device.makeBuffer(length: MemoryLayout<UInt32>.stride, options: .storageModeShared)
            else { return nil }
            // 清零一次：未初始化显存里的垃圾寿命会让池一上来就满屏乱粒子
            memset(粒子.contents(), 0, 字节)
            memset(写指针.contents(), 0, MemoryLayout<UInt32>.stride)
            粒子.label = "粒子池 \(上限)"
            self.粒子 = 粒子
            self.写指针 = 写指针
            self.容量 = 上限
        }
    }

    // MARK: 状态

    private let device: MTLDevice
    private let queue: MTLCommandQueue

    private var 发射管线: MTLComputePipelineState?
    private var 步进管线: MTLComputePipelineState?
    private var 渲染管线: MTLRenderPipelineState?
    private var 深度状态: MTLDepthStencilState?
    /// 体积特效（火 / 烟）：不走粒子池，直接 raymarch，与 PT 出图同形
    private var 体积管线: MTLRenderPipelineState?
    /// 合并体积管线：整屏只画一次，fragment 内按深度排序累积所有实例
    private var 体积合并管线: MTLRenderPipelineState?
    private var 体积深度状态: MTLDepthStencilState?
    /// 体积场的时间演化（秒）：视口自己累计，烘焙回放不参与
    private var 体积时刻: Float = 0
    /// 模拟已经推进到时间轴的哪一帧。帧号不变 = 不再推进（停止播放即冻结）。
    private var 已算帧: Int = .min

    /// 相机取：渲染线程每帧现取（与 PT 视口同一做法，都是只读 scene 的相机参数）
    var 相机取: (() -> PTCamera?)?

    private let 输入锁 = NSLock()
    private var 当前输入 = 输入()

    private var 池们: [UUID: 粒子池] = [:]
    private var 上次时刻: CFTimeInterval = 0
    private var 全局帧序号: UInt32 = 0
    private(set) var 上次统计 = 统计()

    /// 单帧最大时间步：掉帧时不让粒子一步跨半秒（会穿模、会闪）
    private static let 最大步长: Float = 1.0 / 20.0


    // MARK: 诊断（临时，用于定位「火还是粒子、体积到底跑没跑」）
    private var 诊断计数: Int = 0
    private var 诊断路径: URL? = {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/3d渲染", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("诊断-粒子.log")
    }()

    private func 诊断(_ 文本: String) {
        guard let url = 诊断路径 else { return }
        let 行 = 文本 + "\n"
        guard let 数据 = 行.data(using: .utf8) else { return }
        if let 属性 = try? FileManager.default.attributesOfItem(atPath: url.path),
           let 大小 = 属性[.size] as? Int, 大小 > 256 * 1024 {
            try? FileManager.default.removeItem(at: url)
        }
        if let 句柄 = try? FileHandle(forWritingTo: url) {
            句柄.seekToEndOfFile()
            句柄.write(数据)
            try? 句柄.close()
        } else {
            try? 数据.write(to: url)
        }
    }

    // MARK: 初始化

    init?(device: MTLDevice, queue: MTLCommandQueue, 像素格式: MTLPixelFormat, 深度格式: MTLPixelFormat) {
        粒子布局自检.运行()
        self.device = device
        self.queue = queue
        super.init()
        建管线(像素格式: 像素格式, 深度格式: 深度格式)
        体积模拟 = 体积模拟器(device: device)
        if 发射管线 == nil || 步进管线 == nil || 渲染管线 == nil { return nil }
    }

    private func 建管线(像素格式: MTLPixelFormat, 深度格式: MTLPixelFormat) {
        guard let library = device.makeDefaultLibrary() else {
            NSLog("粒子：默认着色器库拿不到，粒子层不启动")
            return
        }

        if let f = library.makeFunction(name: "particleEmit") {
            发射管线 = try? device.makeComputePipelineState(function: f)
        }
        if let f = library.makeFunction(name: "particleStep") {
            步进管线 = try? device.makeComputePipelineState(function: f)
        }

        if let v = library.makeFunction(name: "particleVertex"),
           let f = library.makeFunction(name: "particleFragment") {
            let d = MTLRenderPipelineDescriptor()
            d.label = "粒子 球 impostor"
            d.vertexFunction = v
            d.fragmentFunction = f
            let a = d.colorAttachments[0]!
            a.pixelFormat = 像素格式
            // 预乘 alpha：片元输出 rgb 已乘过 a
            a.isBlendingEnabled = true
            a.rgbBlendOperation = .add
            a.alphaBlendOperation = .add
            a.sourceRGBBlendFactor = .one
            a.destinationRGBBlendFactor = .oneMinusSourceAlpha
            a.sourceAlphaBlendFactor = .one
            a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            d.depthAttachmentPixelFormat = 深度格式
            渲染管线 = try? device.makeRenderPipelineState(descriptor: d)
        }

        let ds = MTLDepthStencilDescriptor()
        ds.depthCompareFunction = .lessEqual
        ds.isDepthWriteEnabled = false      // 半透明不写深度：粒子之间靠混合叠，不互相剔除
        深度状态 = device.makeDepthStencilState(descriptor: ds)

        // 体积特效管线：同样走预乘 alpha、不写深度（复用上面的 深度状态）
        if let v = library.makeFunction(name: "volumeFXVertex"),
           let f = library.makeFunction(name: "volumeFXFragment") {
            let d = MTLRenderPipelineDescriptor()
            d.label = "体积特效 raymarch"
            d.vertexFunction = v
            d.fragmentFunction = f
            let a = d.colorAttachments[0]!
            a.pixelFormat = 像素格式
            a.isBlendingEnabled = true
            a.rgbBlendOperation = .add
            a.alphaBlendOperation = .add
            a.sourceRGBBlendFactor = .one
            a.destinationRGBBlendFactor = .oneMinusSourceAlpha
            a.sourceAlphaBlendFactor = .one
            a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            d.depthAttachmentPixelFormat = 深度格式
            体积管线 = try? device.makeRenderPipelineState(descriptor: d)
        }

        // 合并体积管线：同一套混合状态，顶点换成全屏三角、片元换成多实例排序累积
        if let v = library.makeFunction(name: "volumeFXFullscreenVertex"),
           let f = library.makeFunction(name: "volumeFXMergedFragment") {
            let d = MTLRenderPipelineDescriptor()
            d.label = "体积特效 合并 raymarch"
            d.vertexFunction = v
            d.fragmentFunction = f
            let a = d.colorAttachments[0]!
            a.pixelFormat = 像素格式
            a.isBlendingEnabled = true
            a.rgbBlendOperation = .add
            a.alphaBlendOperation = .add
            a.sourceRGBBlendFactor = .one
            a.destinationRGBBlendFactor = .oneMinusSourceAlpha
            a.sourceAlphaBlendFactor = .one
            a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            d.depthAttachmentPixelFormat = 深度格式
            体积合并管线 = try? device.makeRenderPipelineState(descriptor: d)
        }

        if 渲染管线 == nil {
            NSLog("粒子：渲染管线建立失败（着色器名或像素格式对不上）")
        }
        if 体积管线 == nil {
            NSLog("粒子：体积特效管线建立失败（volumeFXVertex / volumeFXFragment 没编进默认库？）")
        }
    }

    // MARK: 输入更新（主线程）

    /// 主线程每帧把最新快照塞进来。这里只做替换，不碰 GPU。
    func 更新输入(_ 新: 输入) {
        输入锁.lock()
        当前输入 = 新
        输入锁.unlock()
    }

    private func 取输入() -> 输入 {
        输入锁.lock()
        let v = 当前输入
        输入锁.unlock()
        return v
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let 开始 = CACurrentMediaTime()

        // 进入标记：视口不画火时，先确认 draw 到底有没有被调起来
        if 诊断计数 % 120 == 0 {
            PT体积诊断.落盘("VFX进入draw 帧=\(全局帧序号) 有drawable=\(view.currentDrawable != nil) 有pass=\(view.currentRenderPassDescriptor != nil)")
        }

        guard let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor,
              let cmd = queue.makeCommandBuffer()
        else { return }

        let 本帧 = 取输入()

        // MARK: 时间步 —— 只由时间轴帧号驱动
        // 以前这里是「真实帧间隔 × 时间缩放」：于是停止播放后 draw 还在跑，
        // 火/烟/粒子就各自继续积分，表现成"我按了停止它自己还在播"。
        // 现在改成帧驱动：播放头换了帧才推进一步，一帧固定 1/帧率 秒；
        // 停在哪一帧，画面就冻在哪一帧。播放时一帧算一帧，本身就是"边播边烘"。
        let 缩放 = Float(max(0.0, min(4.0, Double(本帧.物理域.时间缩放))))
        // 往回拖播放头：粒子已飞出去、密度场已经烧过，状态有记忆。
        // 只"停住"不倒带的话，画第 10 帧用的还是第 80 帧的火 —— 所以这里整批丢掉重来，
        // 严格保持"第 N 帧 = 从起点逐帧积分到 N"这个语义（和烘焙出来的结果同一口径）。
        if 已算帧 != .min, 本帧.帧 < 已算帧 {
            池们.removeAll()
            体积场们.removeAll()
            体积时刻 = 0
        }
        var 追帧 = 0
        if 已算帧 == .min {
            // 首帧：先把场建起来（否则第一帧是空的，用户会以为没生效）
            追帧 = 1
        } else if 本帧.帧 != 已算帧 {
            // 拖播放头/跳帧时允许追几步，但不无限追（追太多会卡成 PPT）
            追帧 = min(max(1, abs(本帧.帧 - 已算帧)), 4)
        }
        已算帧 = 本帧.帧
        let 一帧秒 = Float(1.0 / max(1.0, 本帧.帧率))
        var 步长: Float = 追帧 > 0 ? 一帧秒 * 缩放 * Float(追帧) : 0
        步长 = min(步长, Self.最大步长 * Float(max(1, 追帧)))
        上次时刻 = 开始
        全局帧序号 &+= 1

        // 全局力：物理域关掉就是「不施力」，发射器自己的湍流/初速照旧
        var 域 = 本帧.物理域
        if !域.启用 {
            域.重力 = .zero
            域.风 = .zero
            域.流 = .zero
            域.湍流 = 0
        }

        let 发射器 = 本帧.发射器
        var 在场 = 0

        // 池：按 id 复用，容量变了就重建（换品类/拖参数时才会重建）
        var 活跃池: [(快照: 粒子发射器快照, 池: 粒子池, 参数: 粒子发射参数, 实例数: Int)] = []
        活跃池.reserveCapacity(发射器.count)

        // 火 / 烟不进粒子池：它们由 GPU 流体网格模拟，这里只收集"这一帧要步进+要画"的场
        var 体积列表: [体积绘制项] = []
        var 高精度可再用 = 体积网格.高精度上限
        // 体积介质的噪声相位按「固定帧步长」推进，不吃真实帧间隔：
        // 用真实间隔时一旦掉帧/卡顿，噪声相位每帧跨度忽大忽小，火焰整体亮度跟着跳，
        // 观感就是"没播时间轴火却在闪"。固定 1/60 让湍流速度恒定、画面稳定。
        // 体积介质的噪声相位同样只跟帧走：不推进就不动，
        // 否则停止播放后湍流相位还在变，火看起来"还在烧"（这正是之前的假象之一）。
        if 追帧 > 0 {
            体积时刻 += 一帧秒 * 缩放 * Float(追帧)
        }

        // 体积分流漏斗：视口没火时，一眼看清是"没勾走体积""模拟器没起来"还是"场建失败"
        var 走体积数 = 0, 模拟缺席数 = 0, 场建失败数 = 0

        for 快照 in 发射器 {
            // 【为什么在这里分流】火的形态是密度场，粒子池对它毫无意义：
            // 喷出来的球无论怎么调 alpha 都只是"打光的珠子"。烟同理。
            // 所以这两类在这里直接掉头，一个粒子都不发。
            if 快照.设置.走体积 {
                走体积数 += 1
                if 快照.设置.启用, let 模拟 = 体积模拟, 模拟.可用 {
                    _ = 模拟
                    // 预算调度：前几个用高精度（主角火焰要火舌细节），后面的自动降到低精度。
                    // 这条规则就是"未来无数个火"能撑住的原因 —— 数量上来时是分辨率降级，
                    // 而不是帧率崩掉或者直接不画。
                    let 边长 = 高精度可再用 > 0 ? 体积网格.高 : 体积网格.低
                    let 场: 体积场
                    if let 旧 = 体积场们[快照.id], 旧.边长 == 边长 {
                        场 = 旧
                        _ = 旧
                    } else if let 新 = 体积场(device: device, id: 快照.id, 边长: 边长) {
                        体积场们[快照.id] = 新
                        场 = 新
                    } else {
                        场建失败数 += 1
                        continue
                    }
                    if 边长 == 体积网格.高 { 高精度可再用 -= 1 }
                    // 表面场：把对象本体体素成距离场，火/烟沿几何表面长，而不是从中心圆盘冒。
                    // 网格还没进池（几何为空）时返回 nil，参数退回老喷口行为，不至于整块不发光。
                    let 表面场 = 对象表面场库存.取(几何: 快照.几何, 设置: 快照.设置, 网格边长: 边长)
                    场.更新表面(表面场)
                    // 模拟参数与渲染参数同源：盒、配色、消光、世界矩阵都出自 特效设置
                    let 模拟参 = 快照.设置.制造模拟参数(物理域: 域, 世界: 快照.世界,
                                                    时间: 场.时刻, dt: 1.0 / 60.0, 网格边长: 边长,
                                                    对象顶部: 快照.对象顶部,
                                                    对象半径: 快照.对象半径,
                                                    表面: 表面场)
                    var 参数 = 快照.设置.体积参数(世界: 模拟参.世界, 时间: 体积时刻, 网格边长: 边长)
                    // 喷口已沿对象本地 +Y 抬到包围球顶，渲染必须吃同一个矩阵，否则火会画在对象中心
                    参数.世界 = 模拟参.世界
                    参数.域盒 = 模拟参.域
                    参数.配色 = 模拟参.配色
                    体积列表.append(体积绘制项(id: 快照.id, 场: 场, 参数: 参数, 模拟参: 模拟参))
                } else {
                    模拟缺席数 += 1
                }
                continue
            }

            let 容量 = 快照.设置.池容量上限
            let 池: 粒子池
            if let 旧 = 池们[快照.id], 旧.容量 == 容量 {
                池 = 旧
            } else if let 新 = 粒子池(device: device, 容量: 容量) {
                池们[快照.id] = 新
                池 = 新
            } else {
                continue
            }

            // 这一帧有没有现成缓存。有就整段模拟让位（见下方回放铺池）
            let 回放帧 = 本帧.回放?[快照.id]

            var 待发: UInt32 = 0
            if 回放帧 == nil {
                池.时刻 += 步长
                if 步长 > 0 { 池.帧序号 &+= 1 }

                if 快照.设置.启用 {
                    池.待发射 += 快照.设置.发射率 * Double(步长)
                    // 上限就是池容量：一帧不可能发射超过池能装下的量
                    let 可发 = min(池.待发射, Double(容量))
                    if 可发 >= 1 {
                        待发 = UInt32(可发)
                        池.待发射 -= Double(待发)
                    } else {
                        // 小发射率（每秒几个）时保留小数累积，不然永远发不出来
                        待发 = 0
                    }
                } else {
                    池.待发射 = 0
                }
            }

            var 参数 = 快照.设置.参数(物理域: 域,
                                  世界: 快照.世界,
                                  dt: 步长,
                                  池容量: UInt32(池.容量),
                                  发射数: 待发,
                                  帧序号: 池.帧序号,
                                  球数: UInt32(本帧.碰撞球.count))
            参数.流.w = 池.时刻

            活跃池.append((快照, 池, 参数, 回放帧.map { min($0.粒子.count, 池.容量) } ?? 池.容量))
            在场 += 池.容量
        }

        // 回收：发射器被删/被关掉后池要及时还显存。
        // 体积类（火 / 烟）从来不用池，这里也要把它们排除，否则它们新建池后永远收不回来。
        let 活ID = Set(发射器.filter { !$0.设置.走体积 }.map(\.id))
        if 池们.count > 活ID.count {
            for id in 池们.keys where !活ID.contains(id) {
                池们.removeValue(forKey: id)
            }
        }

        // MARK: 回放：把烘焙缓存铺进池（整段 compute 让位）
        //
        // 为什么走 blit 而不是 CPU memcpy：上一帧的命令可能还在读同一块池 buffer，
        // 只有排进命令队列才能保证「先铺、后画」，不会画到写了一半的数据。
        if let 回放 = 本帧.回放, !回放.isEmpty,
           let enc = cmd.makeBlitCommandEncoder() {
            enc.label = "粒子 烘焙回放"
            for 项 in 活跃池 {
                guard let 帧数据 = 回放[项.快照.id] else { continue }
                let 池字节 = 项.池.容量 * MemoryLayout<粒子GPU>.stride
                // 先整池清零：缓存只存活粒子，不清的话剩余槽会飘出上一帧的残影
                enc.fill(buffer: 项.池.粒子, range: 0..<池字节, value: 0)

                let 字节 = min(池字节, 帧数据.粒子.count * MemoryLayout<粒子GPU>.stride)
                if 字节 > 0 {
                    帧数据.粒子.withUnsafeBytes { 原 in
                        guard let 起 = 原.baseAddress,
                              let 上传 = device.makeBuffer(bytes: 起,
                                                           length: 字节,
                                                           options: .storageModeShared)
                        else { return }
                        上传.label = "烘焙帧 上传"
                        enc.copy(from: 上传, sourceOffset: 0,
                                 to: 项.池.粒子, destinationOffset: 0,
                                 size: 字节)
                    }
                }
            }
            enc.endEncoding()
        }

        // MARK: compute：发射 + 步进

        if 本帧.回放 == nil, !活跃池.isEmpty && 步长 > 0 {
            写碰撞球(本帧.碰撞球)
            if let enc = cmd.makeComputeCommandEncoder() {
                enc.label = "粒子 模拟"
                let 宽 = MTLSize(width: 64, height: 1, depth: 1)

                for 项 in 活跃池 {
                    var 参数 = 项.参数

                    if 参数.发射数 > 0, let 管线 = 发射管线 {
                        enc.setComputePipelineState(管线)
                        enc.setBuffer(项.池.粒子, offset: 0, index: 0)
                        enc.setBytes(&参数, length: MemoryLayout<粒子发射参数>.stride, index: 1)
                        enc.setBuffer(项.池.写指针, offset: 0, index: 2)
                        enc.dispatchThreads(MTLSize(width: Int(参数.发射数), height: 1, depth: 1),
                                            threadsPerThreadgroup: 宽)
                    }

                    if let 管线 = 步进管线 {
                        enc.setComputePipelineState(管线)
                        enc.setBuffer(项.池.粒子, offset: 0, index: 0)
                        enc.setBytes(&参数, length: MemoryLayout<粒子发射参数>.stride, index: 1)
                        enc.setBuffer(碰撞球缓冲(本帧.碰撞球), offset: 0, index: 2)
                        enc.dispatchThreads(MTLSize(width: 项.池.容量, height: 1, depth: 1),
                                            threadsPerThreadgroup: 宽)
                    }
                }
                enc.endEncoding()
            }
        }

        // MARK: render：球 impostor

        var 相机基: [SIMD4<Float>] = [SIMD4<Float>(1, 0, 0, 0), SIMD4<Float>(0, 1, 0, 0)]
        var 视图投影 = matrix_identity_float4x4
        var 有相机 = false
        var 相机值: PTCamera?
        if let 相机 = 相机取?() ?? 本帧.相机 {
            相机值 = 相机
            let 宽高比 = Float(max(1, view.drawableSize.width) / max(1, view.drawableSize.height))
            let 结果 = Self.视图投影矩阵(相机, 宽高比: 宽高比)
            视图投影 = 结果.投影
            相机基 = [结果.右, 结果.上]
            有相机 = true
        }

        // 诊断：每 60 帧记一次，看清「谁在画、谁没画」
        诊断计数 += 1
        if 诊断计数 % 60 == 1 {
            let 种类表 = 发射器.map { "\($0.设置.种类.rawValue)@\($0.设置.启用 ? "on" : "off")" }.joined(separator: ",")
            let 文本 = "帧=\(全局帧序号) 发射器=\(发射器.count)[\(种类表)] 体积命中=\(体积列表.count) 活跃池=\(活跃池.count) 体积管线=\(体积管线 != nil) 体积时刻=\(体积时刻) 步长=\(步长) 回放=\(本帧.回放 != nil) 有相机=\(有相机)"
            诊断(文本)
            // 落盘：视口不显示火时，这一行直接指出断在漏斗的哪一级
            PT体积诊断.落盘("VFX \(文本) 走体积 \(走体积数) 模拟缺席 \(模拟缺席数) 建场失败 \(场建失败数) 模拟器 \(体积模拟 != nil) 可用 \(体积模拟?.可用 ?? false) 高精度余 \(高精度可再用)")
        }

        // MARK: 体积模拟步进
        // 必须塞在同一个 cmd 里、而且排在 render encoder 之前：
        // compute 写完纹理，render 才能采到这一帧的密度。换 cmd 会让视口永远慢一帧。
        if 追帧 > 0, let 模拟 = 体积模拟, 模拟.可用, !体积列表.isEmpty, let cenc = cmd.makeComputeCommandEncoder() {
            cenc.label = "体积 模拟"
            // 碰撞球：粒子那份是 (xyz 球心, w 半径)，这里直接用，形状完全相同
            let 原始球 = 本帧.碰撞球
            let 用球 = 原始球.prefix(24)
            var 球们: [体积碰撞球] = 用球.map { 体积碰撞球(球心半径: $0) }
            if 球们.isEmpty { 球们 = [体积碰撞球()] }
            for 项 in 体积列表 {
                var 参 = 项.模拟参
                参.碰撞 = SIMD4<Float>(Float(用球.count),
                                     参.碰撞.y,
                                     参.碰撞.z,
                                     参.碰撞.w)
                模拟.步进(场: 项.场, 参数: 参, 球: 球们, encoder: cenc)
            }
            cenc.endEncoding()
        }

        // 出图登记：把本帧的场（含最新密度/温度纹理）交给路径追踪。
        // **不能放进"要不要步进"的分支里**：停止播放时不步进，但 PT 出图还得吃到同一份场，
        // 否则"视口有火、出图没火"会再次出现。
        if !体积列表.isEmpty {
            var 登记: [UUID: 体积场登记.项] = [:]
            for 项 in 体积列表 {
                登记[项.id] = 体积场登记.项(场: 项.场,
                                          半宽: 项.模拟参.域.x,
                                          高: 项.模拟参.域.y,
                                          边长: max(项.模拟参.域.z, 1))
            }
            体积场登记.提交(登记)
        }

        if let enc = cmd.makeRenderCommandEncoder(descriptor: pass) {
            enc.label = "粒子 绘制"

            // MARK: 体积火 / 烟：raymarch 一次成像，先于粒子绘制
            if 有相机, let 管线 = 体积合并管线, let 相机 = 相机值, !体积列表.isEmpty {
                var 相机参数 = 体积相机参数()
                let 右 = 相机基[0], 上 = 相机基[1]
                相机参数.眼 = SIMD4<Float>(相机.position, 1)
                相机参数.右 = SIMD4<Float>(右.x, 右.y, 右.z, 0)
                相机参数.上 = SIMD4<Float>(上.x, 上.y, 上.z, 0)
                let 前向 = simd_normalize(相机.target - 相机.position)
                相机参数.前 = SIMD4<Float>(前向, 0)
                let 体积宽高比 = Float(max(1, view.drawableSize.width) / max(1, view.drawableSize.height))
                let tanHalf = tan(max(1, min(179, 相机.fieldOfViewDegrees)) * Float.pi / 360)
                // z 步数：交互期固定 64 步，够看出翻滚又不掉帧；w 曝光把 PT 的 HDR 发光压回 SDR 视口
                相机参数.平面 = SIMD4<Float>(tanHalf, 体积宽高比, 64, 0.55)
                相机参数.视图投影 = 视图投影

                enc.setRenderPipelineState(管线)
                if let ds = 深度状态 { enc.setDepthStencilState(ds) }

                // 实例上限 8：纹理槽位是固定数组（速 0…7 / 密 8…15），
                // 超出部分下帧按距离裁剪；排序在片元里按 t0 做，重叠处的吸收才是对的
                let 取数 = min(体积列表.count, 8)
                var 参数们 = 体积列表.prefix(取数).map { $0.参数 }
                var 头部 = SIMD4<Int32>(Int32(取数), 0, 0, 0)
                var 速表: [MTLTexture] = []
                var 密表: [MTLTexture] = []
                for i in 0..<8 {
                    let 项 = 体积列表[min(i, 取数 - 1)]
                    速表.append(项.场.当前速)
                    密表.append(项.场.当前密)
                }

                enc.setFragmentBytes(&头部, length: MemoryLayout<SIMD4<Int32>>.stride, index: 0)
                enc.setFragmentBytes(&相机参数, length: MemoryLayout<体积相机参数>.stride, index: 1)
                参数们.withUnsafeBytes { 原 in
                    if let 底 = 原.baseAddress {
                        enc.setFragmentBytes(底, length: 原.count, index: 2)
                    }
                }
                // 密度与温度来自这一帧刚跑完的模拟纹理：视口看到的形状 = 出图得到的形状
                enc.setFragmentTextures(速表 + 密表, range: 0..<16)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }

            if 有相机, let 管线 = 渲染管线 {
                enc.setRenderPipelineState(管线)
                if let ds = 深度状态 { enc.setDepthStencilState(ds) }

                for 项 in 活跃池 {
                    var 参数 = 项.参数
                    enc.setVertexBuffer(项.池.粒子, offset: 0, index: 0)
                    enc.setVertexBytes(&参数, length: MemoryLayout<粒子发射参数>.stride, index: 1)
                    enc.setVertexBytes(&视图投影, length: MemoryLayout<simd_float4x4>.stride, index: 2)
                    相机基.withUnsafeBytes { 原 in
                        enc.setVertexBytes(原.baseAddress!, length: 原.count, index: 3)
                    }
                    enc.drawPrimitives(type: .triangleStrip,
                                       vertexStart: 0,
                                       vertexCount: 4,
                                       instanceCount: 项.实例数)
                }
            }
            enc.endEncoding()
        }

        cmd.present(drawable)
        cmd.commit()

        上次统计 = 统计(发射器数: 活跃池.count,
                      在场粒子数: 在场,
                      帧耗时毫秒: (CACurrentMediaTime() - 开始) * 1000)
    }

    // MARK: 体积模拟（GPU 欧拉网格）

    /// 所有火 / 烟共用一套流体 compute 管线
    private var 体积模拟: 体积模拟器?
    /// 每发射器一套 3D 网格纹理，按 id 复用；发射器删掉后这里留着也只是一个纹理，
    /// 下次同 id 重建不会白跑一遍预热
    private var 体积场们: [UUID: 体积场] = [:]

    /// 一帧里要画的体积
    private struct 体积绘制项 {
        let id: UUID
        let 场: 体积场
        var 参数: 体积发射参数
        var 模拟参: 体积模拟参数
    }

    // MARK: 碰撞球缓冲

    /// 小球数组直接 setBytes 更省一次分配（48 个球 = 768 字节，远低于 setBytes 上限）
    private var 缓存球缓冲: MTLBuffer?
    private var 缓存球数: Int = -1

    private func 碰撞球缓冲(_ 球: [SIMD4<Float>]) -> MTLBuffer {
        if let b = 缓存球缓冲, 缓存球数 == 球.count { return b }
        let 数 = max(1, 球.count)
        let b = device.makeBuffer(length: 数 * MemoryLayout<SIMD4<Float>>.stride,
                                  options: .storageModeShared) ?? device.makeBuffer(length: 16, options: .storageModeShared)!
        b.label = "粒子 碰撞球"
        缓存球缓冲 = b
        缓存球数 = 球.count
        return b
    }

    private func 写碰撞球(_ 球: [SIMD4<Float>]) {
        let b = 碰撞球缓冲(球)
        guard !球.isEmpty else { return }
        球.withUnsafeBytes { 原 in
            memcpy(b.contents(), 原.baseAddress!, 原.count)
        }
    }

    // MARK: 相机矩阵

    /// 右手系 / Metal 的 0…1 深度：与 PT 视口同一口径（朝 -Z），粒子才能跟 PT 出图对齐
    private static func 视图投影矩阵(_ 相机: PTCamera, 宽高比: Float) -> (投影: simd_float4x4, 右: SIMD4<Float>, 上: SIMD4<Float>) {
        let 眼 = SIMD3<Float>(Float(相机.position.x), Float(相机.position.y), Float(相机.position.z))
        let 靶 = SIMD3<Float>(Float(相机.target.x), Float(相机.target.y), Float(相机.target.z))
        var 前 = 靶 - 眼
        if simd_length(前) < 0.0001 { 前 = SIMD3<Float>(0, 0, -1) }
        前 = simd_normalize(前)

        var 参考上 = SIMD3<Float>(0, 1, 0)
        if abs(simd_dot(前, 参考上)) > 0.999 { 参考上 = SIMD3<Float>(0, 0, 1) }
        let 右 = simd_normalize(simd_cross(前, 参考上))
        let 上 = simd_cross(右, 前)

        // view：世界 → 相机（相机朝 -Z）
        var 视图 = matrix_identity_float4x4
        视图.columns.0 = SIMD4<Float>(右.x, 上.x, -前.x, 0)
        视图.columns.1 = SIMD4<Float>(右.y, 上.y, -前.y, 0)
        视图.columns.2 = SIMD4<Float>(右.z, 上.z, -前.z, 0)
        视图.columns.3 = SIMD4<Float>(-simd_dot(右, 眼), -simd_dot(上, 眼), simd_dot(前, 眼), 1)

        // projection：垂直 fov，深度 0…1（reverse 不做，跟 RealityKit 的常规区间一致）
        let 近 = Float(max(0.01, 相机.near))
        let 远 = Float(max(近 + 0.1, 相机.far))
        let fovY = Float(max(1, min(179, 相机.fieldOfViewDegrees))) * .pi / 180
        let f = 1 / tan(fovY * 0.5)
        var 投影 = matrix_identity_float4x4
        投影.columns.0 = SIMD4<Float>(f / 宽高比, 0, 0, 0)
        投影.columns.1 = SIMD4<Float>(0, f, 0, 0)
        投影.columns.2 = SIMD4<Float>(0, 0, 远 / (近 - 远), -1)
        投影.columns.3 = SIMD4<Float>(0, 0, 近 * 远 / (近 - 远), 0)

        return (投影 * 视图,
                SIMD4<Float>(右.x, 右.y, 右.z, 0),
                SIMD4<Float>(上.x, 上.y, 上.z, 0))
    }
}
