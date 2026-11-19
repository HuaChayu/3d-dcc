import CoreGraphics
import Foundation
import ImageIO
import Metal
import MetalKit
import Observation
import UniformTypeIdentifiers

// MARK: - 出图任务

/// 一次离屏出图的任务描述。只描述"画多大、画到多少采样"，
/// 画质参数（曝光/弹射/降噪/辉光/萤火虫压制）一律从视口设置派生，保证出图与预览同一条链路。
struct PT离屏任务: Equatable {
    var 宽: Int
    var 高: Int
    var 目标采样: Int

    var 尺寸标题: String { "\(宽) × \(高)" }
}

enum PT出图错误: LocalizedError {
    case 无法读回像素
    case 无法创建文件
    case 写盘失败(String)

    var errorDescription: String? {
        switch self {
        case .无法读回像素: "无法把离屏纹理读回内存（显存不足或像素格式不支持）"
        case .无法创建文件: "无法创建 PNG 文件（目录不存在或没有写权限）"
        case .写盘失败(let 原因): 原因
        }
    }
}

// MARK: - 视口登记表

/// 视口 MTKView 的弱引用登记表。
/// 目的只有一个：出图期间把预览的 MTKView 暂停，把 GPU 全让给离屏渲染；出图一结束立刻恢复。
/// 这里只碰 `isPaused`，不介入任何渲染逻辑。
///
/// 标记成 @Observable 是为了让主视口能跟着「出图中」翻脸：出图时现实渲染整块摘掉，结束再挂回来。
@MainActor
@Observable
final class PT视口登记 {
    static let shared = PT视口登记()

    private let 表 = NSHashTable<MTKView>.weakObjects()
    /// 出图是否正在占用 GPU。视口据此判断"暂停是出图要的"还是"该兜底叫醒的"。
    private(set) var 出图中 = false

    func 登记(_ 视图: MTKView) {
        表.add(视图)
    }

    func 暂停() {
        出图中 = true
        for 视图 in 表.allObjects { 视图.isPaused = true }
    }

    func 恢复() {
        出图中 = false
        for 视图 in 表.allObjects {
            视图.isPaused = false
            视图.setNeedsDisplay(视图.bounds)
        }
    }
}

// MARK: - 后台渲染并发开关

/// 【后台渲染与视口并发开关】
///
/// `true`：出图（以及将来的视频后台渲染）不再暂停视口，渲染与视口编辑同时进行。
///   **前置依赖**：绘画图集冻结必须生效 —— 出图会话开始时调用
///   `PTPathTracer.冻结离屏绘画图集()`，把 PaintGPUSnapshot 的 atlas / 通道图集 / holeAtlas
///   深拷贝成私有冻结副本（新建 MTLTexture + blit 拷贝），出图全程只读副本、结束即释放。
///   这样视口落笔就地重合成原图集时，后台不会采到半新半旧的笔迹，也不会因 slice 重排采错物体。
///   **若出现笔迹串色 / 花屏 / 洞错位：先把这里改回 `false`**，即回到"出图期间暂停视口"的老行为。
///
/// `false`：恢复原有行为 —— 出图开始 `PT视口登记.shared.暂停()`、结束 `恢复()`。
///   `PT视口登记` 类本身保留未动，就是为了这条回滚路径随时可用。
let 后台渲染并发视口 = true

// MARK: - 并发仲裁

/// 【出图与视口的调度让步仲裁】
///
/// 记两件事：视口最近一次 `commit()` 的时间戳 / 在飞状态（提交了但 GPU 还没跑完），
/// 以及一个 **AIMD 闭环**算出来的出图批预算（见 出图批完成()）：
/// - 视口有帧在飞 → 本帧直接让出（不提交），下一拍再来，让视口的帧优先上 GPU；
/// - 批预算不再由"视口忙就压到 16 ms"的一刀切决定，改由视口实测帧间隔 P95 反馈调节：
///   撑爆（> 目标帧间隔 × 1.15）就乘 0.7 快速退让，连续 3 批稳定就乘 1.15 缓慢增。
///   区间恒在 [4, 250] ms，低电量/过热时上限 64 ms，下限永不为 0（后台视频渲染不能停）。
///
/// 这是纯"让时间片"的机制：不改变任何像素语义、样本总数、累积方式与随机种子，
/// 只决定"出图这一批跑多久、什么时候跑"。渲染主循环与视口 draw 不在同一线程
/// （display link 线程），所以这里用 NSCondition 而不是 @MainActor。
final class PT并发仲裁: @unchecked Sendable {
    static let shared = PT并发仲裁()

    /// 视口"刚忙过"的判定窗口（秒）：100 ms ≈ 6 个 60 Hz 帧，够覆盖一次落笔引发的连续重绘
    static let 忙窗口: TimeInterval = 0.1
    /// 在飞状态的最长信任时间（秒）：超过它说明完成回调没回来（已销毁的视图等），一律当空闲
    private static let 在飞过期: TimeInterval = 0.5

    private let 条件 = NSCondition()
    private var 最近提交: CFAbsoluteTime = 0
    private var 在飞 = false
    /// 正在做一次性图集冻结：此窗口内视口先别提交新帧，避免冻结拷到"写了一半"的图集
    private var 冻结中 = false

    // MARK: - AIMD 闭环批预算
    //
    // 一把独立的锁：AIMD 的读写发生在 GPU 完成回调线程（出图批完成 / 视口帧完成）
    // 与主线程（离屏本批样本数 读预算），跟上面那把"冻结时会让提交方 wait"的条件锁无关，
    // 混用会让完成回调有可能被迫等冻结窗口，没必要。

    /// 离屏批预算下限（毫秒）：恒为 4。任何情况下不得为 0 —— 后台渲染（尤其视频导出）不能停。
    static let 批预算下限: Double = 4.0
    /// 视口帧间隔样本容量：30 帧 ≈ 0.5 s，够算一个稳定的 P95，又不至于记太久远的历史
    private static let 帧间隔容量 = 30

    private let 反馈锁 = NSLock()
    /// 出图每批的 GPU 时间预算（毫秒），AIMD 调节。初值 120 ms（老默认值）。
    private(set) var 离屏批预算AIMD: Double = 120.0
    /// 连续"视口没被挤掉帧"的批数，满 3 才加性增一次（避免抖动时一路膨胀）
    private var 连续稳定批数 = 0
    /// 视口帧间隔环形缓冲（秒）：用 GPU 结束时间戳的差值，与出图侧同一口径
    private var 帧间隔: [Double] = []
    /// 上一帧视口画面的 GPU 结束时间（算间隔用）
    private var 上帧GPU结束: CFTimeInterval = 0
    /// 目标帧间隔（秒）：视口 preferredFramesPerSecond 的倒数，拿不到就用 1/60
    private var 目标帧间隔秒: Double = 1.0 / 60.0

    /// 视口 draw 即将 commit 时调用
    func 视口提交了() {
        条件.lock()
        // 图集冻结是几毫秒的一次性动作，等它做完再提交，保证冻结出来的副本是干净的一代
        let 截止 = Date(timeIntervalSinceNow: 0.5)
        while 冻结中, Date() < 截止 { 条件.wait(until: 截止) }
        最近提交 = CFAbsoluteTimeGetCurrent()
        在飞 = true
        条件.unlock()
    }

    /// 视口帧的完成回调里调用（任意线程）
    func 视口归还() {
        条件.lock()
        在飞 = false
        条件.signal()
        条件.unlock()
    }

    /// 视口是否真有帧在 GPU 上跑
    func 视口在飞() -> Bool {
        条件.lock()
        defer { 条件.unlock() }
        guard 在飞 else { return false }
        return CFAbsoluteTimeGetCurrent() - 最近提交 <= Self.在飞过期
    }

    /// 视口是否"忙"：在飞，或最近 100 ms 内提交过。
    ///
    /// 【注意】这个方法**已不再参与出图批预算决策**（原来"视口忙就恒定压到 16 ms"的一刀切降档已删除，
    /// 改由 AIMD 闭环按视口实测帧间隔反馈调节，见 出图批完成()）。
    /// 保留它是因为它是判断"视口这会儿是不是正在出帧"的独立诊断口径，日志与调试还要用；
    /// 目前仅定义在此、无生产调用点，删除也不影响编译。
    func 视口忙(窗口: TimeInterval = PT并发仲裁.忙窗口) -> Bool {
        条件.lock()
        defer { 条件.unlock() }
        let 现在 = CFAbsoluteTimeGetCurrent()
        if 在飞, 现在 - 最近提交 <= Self.在飞过期 { return true }
        return 现在 - 最近提交 < 窗口
    }

    /// 冻结窗口开始：先等视口在飞帧收尾，再独占（有超时，绝不挂死主线程）
    func 开始冻结(超时: TimeInterval = 0.5) {
        条件.lock()
        let 截止 = Date(timeIntervalSinceNow: 超时)
        while 在飞, Date() < 截止 { 条件.wait(until: 截止) }
        冻结中 = true
        条件.unlock()
    }

    /// 冻结窗口结束：放行视口提交
    func 结束冻结() {
        条件.lock()
        冻结中 = false
        条件.broadcast()
        条件.unlock()
    }

    // MARK: - AIMD 反馈

    /// 视口帧 present 的完成回调里调用（GPU 完成线程）：记一次帧间隔样本。
    /// 用 commandBuffer 的 gpuEndTime 差值，量的是"GPU 上两帧之间隔了多久"，
    /// 已剔除 CPU 侧排队与垂直同步的噪声，跟出图侧的单样本耗时是同一时间口径。
    func 视口帧完成(gpuEndTime: CFTimeInterval) {
        guard gpuEndTime > 0 else { return }
        反馈锁.lock()
        defer { 反馈锁.unlock() }
        let 上一帧 = 上帧GPU结束
        上帧GPU结束 = gpuEndTime
        guard 上一帧 > 0 else { return }
        let 间隔 = gpuEndTime - 上一帧
        // 只收半秒以内的合法间隔：窗口被切走/暂停/断点会把时间戳拉开好几秒，
        // 那种样本不是"视口被挤掉帧"，混进来会让 P95 无限期偏高、预算被白白压到底。
        guard 间隔 > 0, 间隔 < 0.5 else { return }
        帧间隔.append(间隔)
        if 帧间隔.count > Self.帧间隔容量 { 帧间隔.removeFirst(帧间隔.count - Self.帧间隔容量) }
    }

    /// 视口刷新率变化时登记目标帧间隔（拿不到 fps 就保持 1/60）
    func 设置目标帧率(_ fps: Int) {
        guard fps > 0 else { return }
        反馈锁.lock()
        目标帧间隔秒 = 1.0 / Double(fps)
        反馈锁.unlock()
    }

    /// 出图一批（一帧）完成时调用（GPU 完成线程）：AIMD 的核心反馈。
    ///
    /// 判据 = 视口最近 30 帧帧间隔的 P95 vs 目标帧间隔 × 1.15。
    /// - 超过 → 视口已经被这批挤掉帧了：预算 × 0.7（快速退让），稳定计数归零；
    /// - 没超过 → 稳定计数 +1，满 3 批才 × 1.15（缓慢试探，避免每批都动造成振荡）。
    /// 最后再夹一次 [批预算下限, 批预算上限]：下限 4 ms 永不为 0，后台渲染永不停。
    func 出图批完成() {
        反馈锁.lock()
        defer { 反馈锁.unlock() }

        let 上限 = Self.批预算上限()
        // 样本太少（刚开视口 / 刚开图）时先按初值跑，别拿两三个样本去猜
        if 帧间隔.count >= 3 {
            let 排序 = 帧间隔.sorted()
            let 位 = min(Int(floor(Double(排序.count - 1) * 0.95)), 排序.count - 1)
            let p95 = 排序[位]
            if p95 > 目标帧间隔秒 * 1.15 {
                离屏批预算AIMD = max(离屏批预算AIMD * 0.7, Self.批预算下限)
                连续稳定批数 = 0
            } else {
                连续稳定批数 += 1
                if 连续稳定批数 >= 3 {
                    连续稳定批数 = 0
                    离屏批预算AIMD = min(离屏批预算AIMD * 1.15, 上限)
                }
            }
        }
        // 上限可能因为切到低电量 / 机器过热而变小，这里每批都夹一次，保证立刻生效
        离屏批预算AIMD = min(max(离屏批预算AIMD, Self.批预算下限), 上限)
    }

    /// 批预算上限：正常 250 ms；低电量模式或热状态 serious/critical 时降到 64 ms
    /// （这两种情况下系统随时可能降频，长批更容易吃满功耗预算、把视口挤成幻灯片）。
    static func 批预算上限() -> Double {
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return 64 }
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical: return 64
        default: return 250
        }
    }
}

// MARK: - 出图会话

/// 出图会话：持有离屏渲染器、分帧驱动、收进度、存 PNG、管取消。
///
/// 为什么要有这一层：`PTPathTracer.draw(in:)` 是 MTKView 驱动的，出图不能依赖任何视图的
/// display link。所以这里用一条 60Hz 的主线程定时器当"驱动拍"，每拍让渲染器渲染一帧；
/// 渲染器内部有"上一帧没在 GPU 上跑完就跳过本拍"的闸门，主线程永远不会被阻塞。
@Observable
@MainActor
final class PT出图会话 {
    static let shared = PT出图会话()

    enum 出图阶段: Equatable {
        case 空闲
        case 渲染中
        case 已完成
        case 已取消
        case 失败

        var 标题: String {
            switch self {
            case .空闲: "待出图"
            case .渲染中: "渲染中"
            case .已完成: "已完成"
            case .已取消: "已取消"
            case .失败: "失败"
            }
        }
    }

    private(set) var 阶段: 出图阶段 = .空闲
    private(set) var 已采样: UInt32 = 0
    private(set) var 目标采样: Int = 512
    private(set) var 输出路径 = ""
    private(set) var 说明 = ""
    private(set) var 失败原因 = ""
    private(set) var 耗时: Double = 0
    private(set) var 分辨率标题 = ""
    /// 渐进预览图：渲染途中按节流回读刷新，渲染窗口的图像区直接显示它。
    /// 只在主线程写（渲染器的预览回调与收图都在主线程）。
    private(set) var 预览图: CGImage?

    var 进行中: Bool { 阶段 == .渲染中 }

    var 进度: Double {
        guard 目标采样 > 0 else { return 0 }
        return min(Double(已采样) / Double(目标采样), 1)
    }

    private var 渲染器: PTPathTracer?
    private var 驱动: Timer?
    private var 开始时间: Date?
    private var 输出URL: URL?
    /// 【防 App Nap 节流】渲染 session 期间持有的活动令牌，与 beginActivity 一一对应
    private var 活动令牌: NSObjectProtocol?

    // MARK: 开始

    /// 开一轮出图。场景与相机在这一刻固定下来（快照），渲染过程不再受视口操作影响。
    func 开始(
        宽: Int,
        高: Int,
        目标采样数: Int,
        最大弹射: Int,
        降噪: Bool,
        曝光: Double,
        视口设置: ViewportSettings,
        场景: PTScene,
        相机: PTCamera?,
        输出: URL
    ) {
        guard 阶段 != .渲染中 else { return }
        已采样 = 0
        失败原因 = ""
        耗时 = 0
        预览图 = nil

        guard !场景.isEmpty else {
            落到失败("场景为空：视口里先放个模型再出图")
            return
        }
        guard let 渲染器 = 取渲染器() else {
            落到失败("无法创建 Metal 路径追踪渲染器（设备或内核缺失）")
            return
        }
        let 目录 = 输出.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: 目录, withIntermediateDirectories: true)
        } catch {
            落到失败("无法创建输出目录：\(error.localizedDescription)")
            return
        }

        let 宽 = max(宽, 16)
        let 高 = max(高, 16)
        let 采样 = max(目标采样数, 1)

        // 画质参数：从视口派生（曝光/辉光/萤火虫压制全跟视口一致），再覆盖出图专属项
        var 参数 = PathTraceSettings.from(viewport: 视口设置)
        参数.exposure = Float(曝光)
        参数.maxBounces = max(最大弹射, 1)
        参数.maxSamples = 采样
        参数.resolutionScale = 1.0
        参数.denoiseEnabled = 降噪
        // 出图链路的"每批样本数"已不在这里决定：渲染器按 GPU 时间预算（AIMD 在 [4,250] ms 内
        // 自动收敛，见 PT并发仲裁.离屏批预算AIMD）反推每批样本数（见 PTPathTracer.离屏本批样本数），
        // 首批用跨设备校准系数 k 估、无 k 时保守 1 spp，之后用累计法实测的单样本耗时估算，
        // 夹在 [1, min(该帧剩余样本, 256)]。这里保留 1 只是让 settings 走"最短一步"的保守值，
        // 离屏路径已不读它（预览路径仍按它分档）。
        // 老坑备注：一帧塞太多样本会让单次 dispatch 撞驱动执行上限被中途掐断，
        // 表现为"命中计数只累了一部分甚至为 0"，被误当成求交退化无限重开累积 ——
        // 所以批预算必须限死在百毫秒量级，不能照搬 Cycles 的 CPU/CUDA 2s/15s。
        参数.samplesPerFrame = 1

        // 顺序要紧：先落 settings（其 didSet 只会给预览路径打重绘标记，离屏不用），
        // 再落 离屏任务（它的 didSet 才是重置累积、换代加速结构、重建离屏纹理的时点）
        渲染器.settings = 参数
        渲染器.sceneProvider = { 场景 }
        渲染器.cameraProvider = { 相机 }
        渲染器.离屏任务 = PT离屏任务(宽: 宽, 高: 高, 目标采样: 采样)
        // 【绘画图集冻结】并发模式下，视口在出图期间随时可能落笔重合成图集纹理。
        // 这里一次性深拷贝出私有的冻结副本，出图全程只读副本（见 后台渲染并发视口 的注释）。
        // 顺序要紧：必须在 离屏任务 赋值之后（它的 didSet 会清空旧的冻结副本）。
        if 后台渲染并发视口 {
            渲染器.冻结离屏绘画图集()
        }
        渲染器.离屏进度回调 = { [weak self] 样本 in
            guard let self, self.阶段 == .渲染中 else { return }
            self.已采样 = 样本
            self.说明 = "累积中 \(样本)/\(self.目标采样) spp"
            // 【完成即排下一帧】此前整条出图链只由 60Hz 定时器驱动：每帧 GPU 只有一两毫秒，
            // 却必须干等到下一个 16.7 ms 节拍，实测 512 帧光空等就约 8.5 s，GPU 利用率不到 10%。
            // 这里在"上一帧 GPU 已完成"的时点立刻排下一帧；离屏渲染一帧 开头的在飞闸门会挡住
            // 重入（此时 status 必为 .completed），主线程立刻归还，UI 不卡。
            // 每批样本数由渲染器按 AIMD 批预算自适应反推（首批 k 估或 1 spp，上限 256），
            // 会话层只负责排拍子，不参与批粒度决策。
            if 样本 < UInt32(self.目标采样) { self.驱一拍() }
        }
        渲染器.离屏完成回调 = { [weak self] 纹理 in
            self?.收图(纹理)
        }
        渲染器.离屏失败回调 = { [weak self] 原因 in
            self?.落到失败(原因)
        }
        // 渐进预览：渲染器按节流回读，后台转成 CGImage 后回主线程刷新
        渲染器.离屏预览回调 = { [weak self] 图 in
            guard let self, self.阶段 == .渲染中 else { return }
            self.预览图 = 图
        }

        输出URL = 输出
        输出路径 = 输出.path
        目标采样 = 采样
        分辨率标题 = "\(宽) × \(高)"
        开始时间 = .now
        阶段 = .渲染中
        说明 = "准备渲染 \(宽)×\(高)，目标 \(采样) 采样"
        // 【防 App Nap】session 真正开跑，立刻声明"用户在等这件事"
        开启活动令牌()

        // 出图期间是否暂停视口由 后台渲染并发视口 决定：
        // true  → 不暂停，视口照常渲染（依赖上面那次图集冻结把唯一硬冲突隔离开）；
        // false → 恢复原有行为，把 GPU 全让给这张图（结束/取消时恢复）。
        if !后台渲染并发视口 {
            PT视口登记.shared.暂停()
        }
        启动驱动()
    }

    // MARK: 取消

    func 取消() {
        guard 阶段 == .渲染中 else { return }
        停驱动()
        收尾()
        阶段 = .已取消
        说明 = "已取消，未写出文件"
    }

    /// 面板关闭后把已完成/已取消/失败的横幅收掉，下次打开是干净的"待出图"
    func 复位横幅() {
        guard 阶段 != .渲染中 else { return }
        阶段 = .空闲
        说明 = ""
        失败原因 = ""
        已采样 = 0
        耗时 = 0
    }

    // MARK: 驱动

    private func 启动驱动() {
        停驱动()
        // 用 .common 模式挂：渲染窗口开着时用户可能拖窗口/拉菜单，.default 模式的定时器会被饿死
        let 定时器 = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.驱一拍()
            }
        }
        定时器.tolerance = 0.004
        RunLoop.main.add(定时器, forMode: .common)
        驱动 = 定时器
    }

    private func 驱一拍() {
        guard 阶段 == .渲染中, let 渲染器, 渲染器.离屏任务 != nil else { return }
        渲染器.离屏渲染一帧()
    }

    private func 停驱动() {
        驱动?.invalidate()
        驱动 = nil
    }

    private func 取渲染器() -> PTPathTracer? {
        if let 渲染器 { return 渲染器 }
        guard let 设备 = MTLCreateSystemDefaultDevice(),
              let 队列 = 设备.makeCommandQueue(),
              let 新建 = PTPathTracer(device: 设备, queue: 队列)
        else { return nil }
        渲染器 = 新建
        return 新建
    }

    // MARK: 收尾

    private func 收图(_ 纹理: MTLTexture) {
        guard 阶段 == .渲染中, let 输出 = 输出URL else { return }
        停驱动()
        do {
            try 存PNG(纹理: 纹理, 到: 输出)
        } catch {
            落到失败(error.localizedDescription)
            return
        }
        耗时 = 开始时间.map { Date.now.timeIntervalSince($0) } ?? 0
        已采样 = UInt32(max(目标采样, Int(已采样)))
        阶段 = .已完成
        说明 = "已完成：\(纹理.width)×\(纹理.height)，\(目标采样) 采样，用时 \(String(format: "%.1f", 耗时)) 秒"
        收尾()
    }

    private func 落到失败(_ 原因: String) {
        停驱动()
        收尾()
        失败原因 = 原因
        阶段 = .失败
        说明 = "失败：\(原因)"
    }

    /// 断开回调、退出离屏模式、恢复视口刷新。可重入调用无副作用。
    private func 收尾() {
        渲染器?.离屏进度回调 = nil
        渲染器?.离屏完成回调 = nil
        渲染器?.离屏失败回调 = nil
        渲染器?.离屏预览回调 = nil
        渲染器?.离屏任务 = nil
        if !后台渲染并发视口 {
            PT视口登记.shared.恢复()
        }
        // 【防 App Nap】收尾必须释放活动令牌：成功写出、取消、失败三条路径都汇到这里，
        // 令牌用 nil 判空保护，重复调用不会再 endActivity 一次。
        关闭活动令牌()
    }

    // MARK: - 防 App Nap

    /// 后台长时间渲染时，App Nap 会把进程降级：定时器合并/降频、CPU 优先级让出，
    /// 表现为 60 Hz 驱动被拉成几 Hz、每批之间空等十几毫秒，GPU 利用率掉一截。
    ///
    /// - `.userInitiatedAllowingIdleSystemSleep`：声明"用户正在等这件事"，但不阻止闲时睡眠
    ///   （不选 `.idleSystemSleepDisabled`，免得笔记本合盖/待机被一直顶住耗电）；
    /// - `.suddenTerminationDisabled`：渲染途中别被系统直接杀掉，否则半张图白跑。
    private func 开启活动令牌() {
        guard 活动令牌 == nil else { return }
        活动令牌 = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .suddenTerminationDisabled],
            reason: "离屏渲染进行中"
        )
    }

    private func 关闭活动令牌() {
        if let 令牌 = 活动令牌 {
            ProcessInfo.processInfo.endActivity(令牌)
            活动令牌 = nil
        }
    }

    // MARK: 存盘

    /// 离屏纹理 → CGImage（按 sRGB 标记）→ PNG。
    /// 只在出图完全结束后等一次 GPU（几毫秒），不影响渲染过程的主线程手感。
    private func 存PNG(纹理: MTLTexture, 到 url: URL) throws {
        let 图 = try PT读回CGImage(纹理: 纹理)
        // 最终图也落到预览图上：窗口里看到的就是这张要存盘的结果
        预览图 = 图
        try PT写PNG(图: 图, 到: url)
    }

    /// 「保存副本…」：把当前渲染图（最终帧或最新预览帧）另存到用户挑的位置。
    func 保存副本(到 url: URL) throws {
        guard let 图 = 预览图 else { throw PT出图错误.无法读回像素 }
        try PT写PNG(图: 图, 到: url)
    }
}

// MARK: - 像素读回与存盘（渲染器渐进预览与出图会话共用）

/// 离屏纹理 → shared 缓冲 → CGImage（bgra8Unorm → sRGB）。
/// 内部会等一次 GPU 完成，只适合低频调用（出图收尾）。
func PT读回CGImage(纹理: MTLTexture) throws -> CGImage {
    let 宽 = 纹理.width
    let 高 = 纹理.height
    guard 宽 > 0, 高 > 0 else { throw PT出图错误.无法读回像素 }
    // macOS 上 纹理→缓冲 的 bytesPerRow 必须 256 字节对齐（1920/2560/3840 恰好都是，
    // 但自定义尺寸不一定），所以按 256 向上取整；CGImage 允许行尾带填充。
    let 每行字节 = ((宽 * 4 + 255) / 256) * 256
    let 总字节 = 每行字节 * 高

    let 设备 = 纹理.device
    guard let 缓冲 = 设备.makeBuffer(length: 总字节, options: .storageModeShared),
          let 队列 = 设备.makeCommandQueue(),
          let 命令 = 队列.makeCommandBuffer(),
          let blit = 命令.makeBlitCommandEncoder()
    else { throw PT出图错误.无法读回像素 }

    blit.label = "PT 出图 读回像素"
    blit.copy(
        from: 纹理,
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
    命令.commit()
    命令.waitUntilCompleted()

    guard let 图 = PT缓冲转CGImage(缓冲: 缓冲, 每行字节: 每行字节, 宽: 宽, 高: 高) else {
        throw PT出图错误.无法读回像素
    }
    return 图
}

/// shared 缓冲里的 bgra8Unorm 像素 → CGImage。
/// 会拷一份数据（与缓冲生命周期解耦），因此可以在后台线程安全调用。
func PT缓冲转CGImage(缓冲: MTLBuffer, 每行字节: Int, 宽: Int, 高: Int) -> CGImage? {
    guard 宽 > 0, 高 > 0, 每行字节 >= 宽 * 4 else { return nil }
    let 总字节 = 每行字节 * 高
    let 数据 = Data(bytes: 缓冲.contents(), count: 总字节)
    guard let 提供者 = CGDataProvider(data: 数据 as CFData) else { return nil }
    // bgra8Unorm：小端 32 位 + 跳过首通道（alpha 恒为 1，色调映射内核写死的）
    let 位图信息 = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)
        .union(.byteOrder32Little)
    guard let 色彩空间 = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
    return CGImage(
        width: 宽,
        height: 高,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: 每行字节,
        space: 色彩空间,
        bitmapInfo: 位图信息,
        provider: 提供者,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    )
}

func PT写PNG(图: CGImage, 到 url: URL) throws {
    guard let 目的地 = CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else { throw PT出图错误.无法创建文件 }
    CGImageDestinationAddImage(目的地, 图, nil)
    guard CGImageDestinationFinalize(目的地) else {
        throw PT出图错误.写盘失败("PNG 编码失败：\(url.path)")
    }
}
