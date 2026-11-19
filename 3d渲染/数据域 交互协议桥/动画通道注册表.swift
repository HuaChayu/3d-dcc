import Foundation

// MARK: - 动画通道

/// 一条可被动画驱动的**标量通道**：键 → 读/写闭包 + 展示信息。
///
/// 它只是「通道注册表」的一条登记，**不是第二份真相**：
/// - `读` 读的是模型此刻的值（SceneObject.position.x 这种）；
/// - `写` 写回模型，再由模型所在域自己的接线（变换接线 / 材质接线 …）推进域。
/// 任何模块都不许绕过模型直接写域令牌，否则模型与域会分叉。
@MainActor
struct 动画通道 {
    /// 全局唯一键，形态跟用户的架构约定一致：`obj/<uuid>/transform/pos.x`
    let 键: String
    /// 面板/菜单里给人看的名字：位置 X
    let 标题: String
    /// 通道所属主体（物体 / 材质 / 灯…的 UUID）
    let 主体: UUID
    /// 批量写分组（如 "transform"）。同一帧里同组同主体的通道合并成**一次**写入，
    /// 播放时才不会 N 个通道 = N 次 onChange（N 次存盘 + N 次视图刷新）。
    /// nil = 独立通道，逐条写。
    let 分组: String?
    /// 组内短名（如 "pos.x"），批量写器按它分辨字段
    let 组内名: String
    let 读: () -> Double?
    let 写: (Double) -> Void
}

// MARK: - 注册表

/// 通道注册表：动画域与"谁可以被动画"之间唯一的接头处。
///
/// 为什么要有它：控件层要打帧、播放要写值、序列化要知道轨道对应谁，
/// 如果每处都手写「打帧/回写/显示」三套接线，就是 N 控件 × 3 的漏接。
/// 现在参数只在**定义处**注册一次闭包，之后打帧 / 播放 / 回填全走同一条路。
///
/// 它不持有轨道，也不做求值 —— 那是 `时间轴域` 的事。这里只有"键 → 怎么读怎么写"。
@MainActor
final class 动画通道注册表 {

    static let 共享 = 动画通道注册表()

    private init() {}

    /// 已登记的通道（首次解析后缓存，避免每帧重建闭包）
    private var 表: [String: 动画通道] = [:]

    /// 批量写器：分组 → (主体, 组内名→值)
    private var 批量写器表: [String: (UUID, [String: Double]) -> Void] = [:]

    /// 未登记的键现场造通道。
    /// 有了它，物体增删不必逐处登记/注销 —— 键里本来就带着 uuid，
    /// 物体不在场景里就读到 nil，自然不参与求值。
    var 动态解析: ((String) -> 动画通道?)?

    // MARK: 登记

    func 注册(_ 通道: 动画通道) {
        表[通道.键] = 通道
    }

    func 注册(_ 通道们: [动画通道]) {
        for 通道 in 通道们 { 表[通道.键] = 通道 }
    }

    func 注销(键: String) {
        表.removeValue(forKey: 键)
    }

    /// 注销某个主体的全部通道（物体被删时可用；不调用也不会错，只是表里多几条读 nil 的登记）
    func 注销(主体: UUID) {
        表 = 表.filter { $0.value.主体 != 主体 }
    }

    /// 注册批量写器。同组同主体的一帧值会被合并成一次调用。
    func 注册批量写器(组: String, _ 写: @escaping (UUID, [String: Double]) -> Void) {
        批量写器表[组] = 写
    }

    // MARK: 查询

    func 通道(_ 键: String) -> 动画通道? {
        if let 已 = 表[键] { return 已 }
        guard let 造 = 动态解析, let 新 = 造(键) else { return nil }
        表[键] = 新
        return 新
    }

    func 读(_ 键: String) -> Double? {
        通道(键)?.读()
    }

    /// 某主体当前有登记的全部通道（右键菜单 / 批量打帧用）
    func 某主体的通道(_ 主体: UUID) -> [动画通道] {
        表.values.filter { $0.主体 == 主体 }
    }

    // MARK: 写入

    /// 把一帧的求值结果写回模型。
    ///
    /// - 只写"值确实变了"的通道（调用方已用 `读` 比对过，这里再守一道）；
    /// - 同组同主体合并成一次批量写；
    /// - 返回实际写入的通道数。
    @discardableResult
    func 应用(_ 值表: [String: Double]) -> Int {
        guard !值表.isEmpty else { return 0 }

        var 分组批: [String: [UUID: [String: Double]]] = [:]
        var 单独: [(动画通道, Double)] = []

        for (键, 值) in 值表 {
            guard let 通道 = 通道(键) else { continue }
            if let 组 = 通道.分组, 批量写器表[组] != nil {
                分组批[组, default: [:]][通道.主体, default: [:]][通道.组内名] = 值
            } else {
                单独.append((通道, 值))
            }
        }

        var 写入数 = 0
        for (组, 主体表) in 分组批 {
            guard let 写 = 批量写器表[组] else { continue }
            for (主体, 子表) in 主体表 {
                guard !子表.isEmpty else { continue }
                写(主体, 子表)
                写入数 += 子表.count
            }
        }
        for (通道, 值) in 单独 {
            通道.写(值)
            写入数 += 1
        }
        return 写入数
    }
}
