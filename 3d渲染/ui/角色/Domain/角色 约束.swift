import Foundation
import simd

/// 约束求解：Blender 那套「算法约束」的最小实现。
///
/// 和姿态的关系：姿态是手摆出来的局部旋转，约束是在它之上再做一次求解，
/// 解出来的结果**不写回** `角色.姿态`（否则约束一动，手摆的姿势就丢了）。
/// 需要实际生效姿态的地方（解算 / 蒙皮 / 关节球）统一走 `角色约束求解.姿态(角色)`。
///
/// 求解顺序照 Blender：一条一条顺下去，后一条看到的是前一条算完的结果。
enum 角色约束求解 {

    /// 单位旋转（绕 Y 零角度，等价于不转）
    private static let 单位 = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))

    /// 生效姿态 = 手摆姿态 过一遍约束
    static func 姿态(_ 角色: 角色资产) -> [String: SIMD4<Float>] {
        guard !角色.约束.isEmpty, !角色.骨数据.isEmpty else { return 角色.姿态 }
        return 求解(骨: 角色.骨数据, 姿态: 角色.姿态, 约束们: 角色.约束)
    }

    /// 约束指纹：改目标骨 / 换链长 / 开关都要让蒙皮那边认成「变了」，跟着重建。
    /// 和 `角色姿态.签名` 拼在一起当整个角色的姿态键。
    static func 签名(_ 约束们: [角色约束]) -> String {
        guard !约束们.isEmpty else { return "" }
        return 约束们
            .map { "\($0.型.rawValue):\($0.骨路径)>\($0.目标骨路径):\($0.生效链长):\($0.启用 ? 1 : 0)" }
            .joined(separator: ";")
    }

    /// 核心求解。骨用下标寻址，路径用来对约束里的人话名字。
    static func 求解(骨: [角色骨骼],
                     姿态: [String: SIMD4<Float>],
                     约束们: [角色约束]) -> [String: SIMD4<Float>] {
        guard !约束们.isEmpty, !骨.isEmpty else { return 姿态 }
        var 出 = 姿态

        // 路径 → 下标（骨路径是唯一的，含层级，直接当键）
        var 序号: [String: Int] = [:]
        序号.reserveCapacity(骨.count)
        for (i, 一) in 骨.enumerated() { 序号[一.路径] = i }

        for 约 in 约束们 where 约.启用 {
            guard let 被 = 序号[约.骨路径],
                  let 目 = 序号[约.目标骨路径],
                  被 != 目, 约.链长 > 0 else { continue }

            switch 约.型 {
            case .对准:
                // 单骨对准：只有这一节转，够不着就是够不着（骨长不变）
                _ = 对准(被: 被, 到骨: 目, 骨: 骨, 姿态: &出)

            case .反向动力学:
                if 约.生效链长 >= 2, let 根 = 父(骨[被]) {
                    // 两骨 IK：先按余弦定理把上游那节摆到正确角度，再让末端指向目标
                    _ = 两骨(末端: 被, 根: 根, 到骨: 目, 骨: 骨, 姿态: &出)
                } else {
                    _ = 对准(被: 被, 到骨: 目, 骨: 骨, 姿态: &出)
                }
            }
        }
        return 出
    }

    // MARK: - 两种求解

    /// 让「被」的 头→尾 指向目标骨的骨尾。
    /// 等价 Blender 的 Damped Track：转最小角度把当前朝向掰过去，骨长不变。
    @discardableResult
    private static func 对准(被: Int,
                             到骨: Int,
                             骨: [角色骨骼],
                             姿态: inout [String: SIMD4<Float>]) -> Bool {
        var 解 = 角色姿态.解算(骨: 骨, 姿态: 姿态)
        guard 到骨 < 解.骨尾.count, 被 < 解.骨头.count else { return false }
        return 对准(被: 被, 到点: 解.骨尾[到骨], 解: &解, 骨: 骨, 姿态: &姿态)
    }

    /// 对准到具体一个点（局部空间）。IK 的第二步也复用它。
    @discardableResult
    private static func 对准(被: Int,
                             到点 目标: SIMD3<Float>,
                             解: inout 角色姿态解算,
                             骨: [角色骨骼],
                             姿态: inout [String: SIMD4<Float>]) -> Bool {
        guard 被 >= 0, 被 < 解.骨头.count, 被 < 解.世界旋转.count else { return false }
        let 头 = 解.骨头[被]
        let 现在 = 解.骨尾[被] - 头
        let 想要 = 目标 - 头
        guard simd_length(现在) > 0.0001, simd_length(想要) > 0.0001 else { return false }

        // 从当前朝向转到目标朝向的最小旋转，左乘到世界旋转上
        let 差 = simd_quatf(from: simd_normalize(现在), to: simd_normalize(想要))
        let 新世界 = 差 * 解.世界旋转[被]
        写回(被: 被, 世界旋转: 新世界, 解: &解, 骨: 骨, 姿态: &姿态)
        return true
    }

    /// 两骨 IK：末端要够到目标，够不到就把 根→末端 这段弯起来。
    /// 用的是余弦定理的解析解（腿这种两节链够用了，不需要迭代 FABRIK）。
    @discardableResult
    private static func 两骨(末端: Int,
                             根: Int,
                             到骨: Int,
                             骨: [角色骨骼],
                             姿态: inout [String: SIMD4<Float>]) -> Bool {
        var 解 = 角色姿态.解算(骨: 骨, 姿态: 姿态)
        guard 末端 < 解.骨头.count, 根 < 解.骨头.count,
              末端 < 解.骨尾.count, 根 < 解.骨尾.count,
              到骨 < 解.骨尾.count else { return false }

        let 目标 = 解.骨尾[到骨]
        let 起点 = 解.骨头[根]
        let 甲 = 解.骨尾[根] - 起点           // 上游那节
        let 乙 = 解.骨尾[末端] - 解.骨头[末端] // 末端那节
        let 长甲 = simd_length(甲)
        let 长乙 = simd_length(乙)
        guard 长甲 > 0.0001, 长乙 > 0.0001 else { return false }

        let 指向 = 目标 - 起点
        let 距离原 = simd_length(指向)
        guard 距离原 > 0.0001 else { return false }
        // 够不到就伸直、离太近就收到最短，两端各留一点余量免得 acos 出 NaN
        let 下限 = abs(长甲 - 长乙) + 0.0005
        let 上限 = 长甲 + 长乙 - 0.0005
        let 距离 = min(max(距离原, 下限), 上限)
        let 单位指向 = 指向 / 距离原

        // 余弦定理：上游那节与「起点→目标」的夹角
        let 余弦 = (长甲 * 长甲 + 距离 * 距离 - 长乙 * 长乙) / (2 * 长甲 * 距离)
        let 角 = acos(min(max(余弦, -1), 1))

        // 弯曲平面：沿用上游当前的朝向在垂直方向上的分量（膝盖朝哪儿由当前姿势决定，不会被掰歪）
        var 侧 = 甲 - 单位指向 * simd_dot(甲, 单位指向)
        if simd_length(侧) < 0.0001 {
            侧 = 垂直(单位指向)
        }
        let 侧单 = simd_normalize(侧)

        let 新方向 = 单位指向 * cos(角) + 侧单 * sin(角)
        let 差 = simd_quatf(from: simd_normalize(甲), to: 新方向)
        写回(被: 根, 世界旋转: 差 * 解.世界旋转[根], 解: &解, 骨: 骨, 姿态: &姿态)

        // 上游摆好之后重新解算，末端再对准目标点（骨长限制在球面上，方向对就够了）
        解 = 角色姿态.解算(骨: 骨, 姿态: 姿态)
        guard 末端 < 解.骨头.count, 末端 < 解.骨尾.count else { return false }
        return 对准(被: 末端, 到点: 目标, 解: &解, 骨: 骨, 姿态: &姿态)
    }

    // MARK: - 工具

    /// 把「这根骨的世界旋转」换回它父骨空间的局部旋转写进姿态（视口里拖关节球也是这么写的）
    private static func 写回(被: Int,
                             世界旋转: simd_quatf,
                             解: inout 角色姿态解算,
                             骨: [角色骨骼],
                             姿态: inout [String: SIMD4<Float>]) {
        let 父世界: simd_quatf
        if let 父下标 = 骨[被].父, 父下标 >= 0, 父下标 < 解.世界旋转.count {
            父世界 = 解.世界旋转[父下标]
        } else {
            父世界 = 单位
        }
        let 局部 = 父世界.inverse * 世界旋转
        姿态[骨[被].路径] = 角色姿态.值(局部)
    }

    private static func 父(_ 骨: 角色骨骼) -> Int? {
        guard let 下标 = 骨.父, 下标 >= 0 else { return nil }
        return 下标
    }

    /// 随便取一个和 v 垂直的单位向量
    private static func 垂直(_ v: SIMD3<Float>) -> SIMD3<Float> {
        let 候选 = abs(v.y) < 0.9 ? SIMD3<Float>(0, 1, 0) : SIMD3<Float>(0, 0, 1)
        let 叉 = simd_cross(v, 候选)
        return simd_length(叉) > 0.0001 ? simd_normalize(叉) : SIMD3<Float>(1, 0, 0)
    }
}
