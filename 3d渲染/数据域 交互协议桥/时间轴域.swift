import Foundation
import Observation

// MARK: - 关键帧

struct 关键帧: Codable, Equatable, Identifiable {
    /// 整数帧号（本 App 的时间单位是帧，不是时间，避免帧率换算漂移）
    var 帧: Int
    var 值: Double

    var id: Int { 帧 }
}

/// 段间插值。先只做 `线性` 与 `常量`（保持）；
/// 贝塞尔要带动手/切线数据，等有人真需要再加，不提前造字段。
enum 关键帧插值: String, Codable, CaseIterable, Identifiable {
    case 线性
    case 常量

    var id: String { rawValue }

    var 标题: String {
        switch self {
        case .线性: "线性"
        case .常量: "保持"
        }
    }
}

// MARK: - 轨道

/// 一条轨道 = 一个通道上的关键帧序列。
///
/// 轨道**不存值**，只存控制点 —— 真实数值始终在模型里（SceneObject.position.x 等）。
/// 求值时才把「这一段应该是多少」算出来交给注册表写回模型。
struct 动画轨道: Codable, Equatable, Identifiable {
    /// 通道键，形态 `obj/<uuid>/transform/pos.x`
    var 键: String
    /// 按帧升序，同一帧只有一个控制点
    var 控制点: [关键帧] = []
    var 插值: 关键帧插值 = .线性

    var id: String { 键 }

    var 非空: Bool { !控制点.isEmpty }

    // MARK: 求值

    /// 某帧的值。首帧之前 / 末帧之后一律取端点值（DCC 的 hold 外插），
    /// 这样播放头拖到范围外不会把物体甩回原点。
    func 取(帧: Int) -> Double? {
        guard let 首 = 控制点.first, let 末 = 控制点.last else { return nil }
        if 帧 <= 首.帧 { return 首.值 }
        if 帧 >= 末.帧 { return 末.值 }
        // 线性扫描：一条轨道的控制点通常只有个位数到几十个，二分不值得多写代码
        for i in 1..<控制点.count {
            let 右 = 控制点[i]
            if 帧 == 右.帧 { return 右.值 }
            if 帧 < 右.帧 {
                let 左 = 控制点[i - 1]
                switch 插值 {
                case .常量:
                    return 左.值
                case .线性:
                    let 跨度 = Double(右.帧 - 左.帧)
                    guard 跨度 > 0 else { return 右.值 }
                    let t = Double(帧 - 左.帧) / 跨度
                    return 左.值 + (右.值 - 左.值) * t
                }
            }
        }
        return 末.值
    }

    /// 当前帧的值（= 控制点上那一刻的值，不插值），没有就是 nil
    func 帧值(_ 帧: Int) -> Double? {
        控制点.first { $0.帧 == 帧 }?.值
    }

    var 有关键帧: Bool { !控制点.isEmpty }

    var 帧范围: ClosedRange<Int>? {
        guard let 小 = 控制点.first?.帧, let 大 = 控制点.last?.帧 else { return nil }
        return 小...大
    }

    // MARK: 编辑

    /// 打帧：同帧覆盖，异帧插入并保持升序
    mutating func 打帧(_ 帧: Int, _ 值: Double) {
        if let i = 控制点.firstIndex(where: { $0.帧 == 帧 }) {
            控制点[i].值 = 值
            return
        }
        let 新 = 关键帧(帧: 帧, 值: 值)
        if let i = 控制点.firstIndex(where: { $0.帧 > 帧 }) {
            控制点.insert(新, at: i)
        } else {
            控制点.append(新)
        }
    }

    @discardableResult
    mutating func 删帧(_ 帧: Int) -> Bool {
        let 旧数 = 控制点.count
        控制点.removeAll { $0.帧 == 帧 }
        return 控制点.count != 旧数
    }
}

// MARK: - 快照

/// 随工程一起存取的时间轴状态。轨道跟着工程走，不跟着 App 走。
struct 动画快照: Codable {
    var 帧率: Double = 24
    var 起始帧: Int = 0
    var 结束帧: Int = 119
    var 当前帧: Int = 0
    var 循环: Bool = true
    var 轨道表: [动画轨道] = []
}

// MARK: - 时间轴域

/// 时间轴域：**唯一**持有「时间轴 + 轨道表 + 求值器」的地方。
///
/// 三条硬规矩：
/// 1. 它是全局单例，不属于任何 Tab —— 时间轴条压在窗口底部，布局 / 着色 / 渲染 /
///    资源全都能播，将来路径渲染窗口也读同一份播放头。
/// 2. 求值结果一律经 `动画通道注册表` 写回**模型**，再由各域自己的接线推进域；
///    它不碰任何 UI Store 的内部字段（更不许直写变换令牌）。
/// 3. 播放写值期间置 `正在回放`，AppStore 的标脏据此让路：播放不是编辑，
///    推帧不该把工程标脏、更不该每帧触发一次自动保存。
@MainActor
@Observable
final class 时间轴域 {

    static let 共享 = 时间轴域()

    // MARK: 时间轴

    var 帧率: Double = 24 {
        didSet { if 帧率 < 1 { 帧率 = 1 } }
    }
    var 起始帧: Int = 0 {
        didSet { if 结束帧 < 起始帧 { 结束帧 = 起始帧 }; 当前帧 = Self.夹住(当前帧, 起始帧, 结束帧) }
    }
    var 结束帧: Int = 119 {
        didSet {
            if 结束帧 < 起始帧 { 结束帧 = 起始帧 }
            当前帧 = Self.夹住(当前帧, 起始帧, 结束帧)
        }
    }
    private(set) var 当前帧: Int = 0
    var 循环 = true

    /// 自动 K 帧：**默认关**。开着时改任何已注册通道的值都会在当前帧落一个关键帧。
    var 自动K帧 = false

    // MARK: 轨道

    private(set) var 轨道表: [动画轨道] = []

    // MARK: 运行态

    private(set) var 播放中 = false

    /// 正在把动画值写回模型（播放 / 拖播放头 / 跳帧）。AppStore 标脏时据此让路。
    private(set) var 正在回放 = false

    /// 轨道被编辑（打帧 / 删帧 / 载入）后回调 —— 只有这些才是「文档真的变了」
    var onChange: (() -> Void)?

    private var 驱动: Task<Void, Never>?

    private init() {}

    // MARK: - 轨道查询

    var 有轨道: Bool { !轨道表.isEmpty }

    func 轨道(_ 键: String) -> 动画轨道? {
        轨道表.first { $0.键 == 键 }
    }

    /// 当前帧上这个通道有没有关键帧（K 点实心）
    func 当前帧有关键帧(_ 键: String) -> Bool {
        轨道(键)?.帧值(当前帧) != nil
    }

    /// 这个通道有没有任何关键帧（K 点是否上色）
    func 有关键帧(_ 键: String) -> Bool {
        轨道(键)?.有关键帧 ?? false
    }

    /// 当前帧值 ≠ 模型现值（有空心 K 点提示：值被手动改过，还没落帧）
    func 偏离关键帧(_ 键: String) -> Bool {
        guard let 帧值 = 轨道(键)?.帧值(当前帧),
              let 现值 = 动画通道注册表.共享.读(键) else { return false }
        return abs(帧值 - 现值) > 1e-9
    }

    /// 某主体的全部轨道键（删物体时清理用）
    func 轨道键(主体: UUID) -> [String] {
        轨道表.map(\.键).filter { $0.hasPrefix("obj/\(主体.uuidString)/") }
    }

    // MARK: - 打帧 / 删帧

    /// 在当前帧给某通道打帧。值不传就读模型现值。
    func 打帧(键: String, 值: Double? = nil) {
        guard let 值 = 值 ?? 动画通道注册表.共享.读(键) else { return }
        if let i = 轨道表.firstIndex(where: { $0.键 == 键 }) {
            轨道表[i].打帧(当前帧, 值)
        } else {
            var 轨道 = 动画轨道(键: 键)
            轨道.打帧(当前帧, 值)
            轨道表.append(轨道)
        }
        onChange?()
    }

    /// 删当前帧的关键帧；这条轨道的帧删空了就整条移除
    func 删当前帧(键: String) {
        guard let i = 轨道表.firstIndex(where: { $0.键 == 键 }) else { return }
        guard 轨道表[i].删帧(当前帧) else { return }
        if !轨道表[i].非空 { 轨道表.remove(at: i) }
        onChange?()
    }

    /// 删整条通道轨道
    func 删除轨道(键: String) {
        let 旧数 = 轨道表.count
        轨道表.removeAll { $0.键 == 键 }
        if 轨道表.count != 旧数 { onChange?() }
    }

    /// 删一个主体下的所有轨道（物体被删了，轨道不该留成孤儿）
    func 删除主体轨道(_ 主体: UUID) {
        let 键们 = Set(轨道键(主体: 主体))
        guard !键们.isEmpty else { return }
        轨道表.removeAll { 键们.contains($0.键) }
        onChange?()
    }

    /// 控件提交值之后调这里：自动 K 帧开着才落帧。
    /// 关着就什么都不做 —— 手动改值只是改模型，不动轨道（用户拍板：默认关）。
    func 值被改(键: String, 新值: Double) {
        guard 自动K帧 else { return }
        打帧(键: 键, 值: 新值)
    }

    // MARK: - 求值

    /// 把当前帧的求值结果写回模型。
    /// **变了才写**：先读模型现值，差在 1e-9 内就跳过 —— 否则每帧都是全场景 onChange，
    /// 一动不动的东西也在刷新视图、标脏、写盘。
    @discardableResult
    func 求值应用() -> Int {
        guard !轨道表.isEmpty else { return 0 }
        var 值表: [String: Double] = [:]
        for 轨道 in 轨道表 {
            guard let 目标 = 轨道.取(帧: 当前帧) else { continue }
            if let 现值 = 动画通道注册表.共享.读(轨道.键), abs(现值 - 目标) <= 1e-9 { continue }
            值表[轨道.键] = 目标
        }
        guard !值表.isEmpty else { return 0 }
        正在回放 = true
        let 数 = 动画通道注册表.共享.应用(值表)
        正在回放 = false
        return 数
    }

    // MARK: - 播放头

    /// 跳到某帧并求值。拖时间线、步进、播放推进都走这里。
    func 跳(_ 帧: Int) {
        当前帧 = Self.夹住(帧, 起始帧, 结束帧)
        求值应用()
    }

    func 步进(_ 步: Int) {
        暂停()
        跳(当前帧 + 步)
    }

    func 设帧率(_ 值: Double) {
        帧率 = max(值, 1)
    }

    func 设帧范围(起始: Int, 结束: Int) {
        let 起 = max(起始, 0)
        let 束 = max(结束, 起)
        起始帧 = 起
        结束帧 = 束
    }

    // MARK: - 播放

    func 切换播放() {
        if 播放中 { 暂停() } else { 播放() }
    }

    func 播放() {
        guard !播放中 else { return }
        if 当前帧 >= 结束帧 { 跳(起始帧) }
        播放中 = true
        let 间隔 = max(1.0 / 帧率, 0.004)
        驱动 = Task { @MainActor [weak self] in
            var 下一个 = ContinuousClock.now + .seconds(间隔)
            while !Task.isCancelled {
                guard let 自身 = self, 自身.播放中 else { break }
                try? await Task.sleep(until: 下一个, clock: .continuous)
                下一个 += .seconds(间隔)
                if Task.isCancelled { break }
                自身.推进一帧()
            }
        }
    }

    func 暂停() {
        guard 播放中 || 驱动 != nil else { return }
        播放中 = false
        驱动?.cancel()
        驱动 = nil
    }

    private func 推进一帧() {
        guard 播放中 else { return }
        if 当前帧 + 1 > 结束帧 {
            if 循环 {
                跳(起始帧)
            } else {
                跳(结束帧)
                暂停()
            }
        } else {
            跳(当前帧 + 1)
        }
    }

    // MARK: - 快照（跟工程走）

    func 快照() -> 动画快照 {
        动画快照(
            帧率: 帧率,
            起始帧: 起始帧,
            结束帧: 结束帧,
            当前帧: 当前帧,
            循环: 循环,
            轨道表: 轨道表
        )
    }

    /// 打开工程 / 新建工程都走这里：有快照就还原，没有就回到出厂态（空轨道）。
    func 载入(_ 快照: 动画快照?) {
        暂停()
        guard let 快照 else { 清空(); return }
        帧率 = max(快照.帧率, 1)
        起始帧 = max(快照.起始帧, 0)
        结束帧 = max(快照.结束帧, 起始帧)
        循环 = 快照.循环
        轨道表 = 快照.轨道表.filter { $0.非空 }
        当前帧 = Self.夹住(快照.当前帧, 起始帧, 结束帧)
        求值应用()
    }

    func 清空() {
        暂停()
        轨道表.removeAll()
        帧率 = 24
        起始帧 = 0
        结束帧 = 119
        当前帧 = 0
        循环 = true
    }

    // MARK: - 工具

    /// 帧号夹到范围里。用闭包式 static 而不是实例方法：`didSet` 里要能直接用。
    private nonisolated static func 夹住(_ 帧: Int, _ 低: Int, _ 高: Int) -> Int {
        min(max(帧, 低), max(高, 低))
    }
}
