import Foundation

/// 动画接线：把「场景物体的变换」接进动画通道注册表。
///
/// 分工钉死，跟几何/材质/灯光/变换接线一个路数：
/// - **动画域**只负责"这一帧该是多少"，它不认识 SceneObject；
/// - **注册表**只负责"这个键怎么读怎么写"；
/// - 本类负责把两者对上的那一段，并且写回一律走 `布局Store` 的公开写入口
///   （`updateObject` / `updateObjects`）—— 不碰它的内部字段，也不直写变换令牌。
///   写进模型之后，上游 `变换接线` 自然会把它推进变换域，链路不断。
///
/// 只登记变换的 9 条通道（位置/旋转/缩放 × XYZ）。毛发、粒子物理将来各有自己的
/// 通道组（`hair/<uuid>/…`、`particle/<uuid>/…`），只要在自己的接线里
/// `注册批量写器(组:)` + 让 `动态解析` 认得出键，动画域一个字节都不用改。
@MainActor
final class 动画接线 {

    static let 共享 = 动画接线()

    private init() {}

    private weak var app: AppStore?

    // MARK: - 字段表

    /// 变换的三个三分量字段。加字段只改这张表（求值、读写、标题全跟着走）。
    private static let 字段表: [(名: String, 标题: String, 键路: WritableKeyPath<SceneObject, Vec3>)] = [
        ("pos", "位置", \.position),
        ("rot", "旋转", \.rotation),
        ("scale", "缩放", \.scale)
    ]

    private static let 轴名 = ["x", "y", "z"]
    private static let 轴显示 = ["X", "Y", "Z"]

    // MARK: - 接线

    func 接上(_ app: AppStore) {
        self.app = app
        let 注册表 = 动画通道注册表.共享

        // 批量写：同一个物体在一帧里改动的位置/旋转/缩放分量，
        // 合成**一次** `updateObjects` —— 一次 onChange、一次变换快照、一次联动。
        // 不这么做就是 9 次 onChange，播放时直接卡成幻灯片。
        注册表.注册批量写器(组: "transform") { [weak app] 主体, 子表 in
            guard let app else { return }
            guard app.layout.objects.contains(where: { $0.id == 主体 }) else { return }
            app.layout.updateObjects { 物体表 in
                guard let i = 物体表.firstIndex(where: { $0.id == 主体 }) else { return }
                for (组内名, 值) in 子表 {
                    Self.写(&物体表[i], 组内名: 组内名, 值: 值)
                }
            }
        }

        // 物体增删不必逐处登记：键里带着 uuid，现场解析即可。
        注册表.动态解析 = { 键 in 动画接线.共享.造通道(键: 键) }
    }

    // MARK: - 键

    /// 变换通道键：`obj/<uuid>/transform/pos.x`
    static func 键(物体 id: UUID, 字段 名: String, 轴: String) -> String {
        "obj/\(id.uuidString)/transform/\(名).\(轴)"
    }

    /// 某物体的全部 9 条变换通道键（i 键批量打帧 / 面板列轨道用）
    static func 变换键们(物体 id: UUID) -> [String] {
        字段表.flatMap { 字段 in
            轴名.map { 键(物体: id, 字段: 字段.名, 轴: $0) }
        }
    }

    // MARK: - 造通道

    private func 造通道(键: String) -> 动画通道? {
        guard let app,
              let 分解 = Self.分解(键: 键),
              app.layout.objects.contains(where: { $0.id == 分解.主体 })
        else { return nil }

        let 主体 = 分解.主体
        let 字段 = 分解.字段
        let 轴 = 分解.轴
        let 组内名 = 分解.组内名
        let 标题 = 分解.标题

        return 动画通道(
            键: 键,
            标题: 标题,
            主体: 主体,
            分组: "transform",
            组内名: 组内名,
            读: { [weak app] in
                guard let app,
                      let 物体 = app.layout.objects.first(where: { $0.id == 主体 })
                else { return nil }
                let v = 物体[keyPath: 字段.键路]
                return 轴 == 0 ? v.x : (轴 == 1 ? v.y : v.z)
            },
            // 单写路径：批量写器缺席时的兜底（注册表在有组写器时不会走到这里）
            写: { [weak app] 值 in
                guard let app else { return }
                app.layout.updateObject(主体) { 物体 in
                    Self.写(&物体, 组内名: 组内名, 值: 值)
                }
            }
        )
    }

    private struct 分解结果 {
        let 主体: UUID
        let 字段: (名: String, 标题: String, 键路: WritableKeyPath<SceneObject, Vec3>)
        let 轴: Int
        let 组内名: String
        let 标题: String
    }

    private static func 分解(键: String) -> 分解结果? {
        let 段 = 键.split(separator: "/")
        guard 段.count == 4, 段[0] == "obj", 段[2] == "transform",
              let 主体 = UUID(uuidString: String(段[1]))
        else { return nil }

        let 尾 = 段[3].split(separator: ".")
        guard 尾.count == 2,
              let 字段 = 字段表.first(where: { $0.名 == String(尾[0]) }),
              let 轴 = 轴名.firstIndex(of: String(尾[1])).map({ $0 })
        else { return nil }

        return 分解结果(
            主体: 主体,
            字段: 字段,
            轴: 轴,
            组内名: String(段[3]),
            标题: "\(字段.标题) \(轴显示[轴])"
        )
    }

    /// 组内名 → 写到物体上。`pos.x` / `rot.z` / `scale.y`
    private static func 写(_ 物体: inout SceneObject, 组内名: String, 值: Double) {
        let 尾 = 组内名.split(separator: ".")
        guard 尾.count == 2,
              let 字段 = 字段表.first(where: { $0.名 == String(尾[0]) }),
              let 轴 = 轴名.firstIndex(of: String(尾[1]))
        else { return }
        var v = 物体[keyPath: 字段.键路]
        switch 轴 {
        case 0: v.x = 值
        case 1: v.y = 值
        default: v.z = 值
        }
        物体[keyPath: 字段.键路] = v
    }

    // MARK: - i 键：打帧

    /// `i`：给鼠标停留的那条通道打帧；没有停留就扫选中物体的 9 条变换通道。
    /// 返回一句给状态栏的提示（用户得知道刚才发生的是"打了一帧"还是"什么都没有"）。
    @discardableResult
    func 打帧快捷键() -> String {
        guard let app else { return "动画接线还没接上" }
        let 域 = 时间轴域.共享

        if let 键 = 动画悬停.共享.键, 动画通道注册表.共享.通道(键) != nil {
            let 已有 = 域.当前帧有关键帧(键)
            域.打帧(键: 键)
            return 已有 ? "第 \(域.当前帧) 帧已更新关键帧" : "第 \(域.当前帧) 帧已打关键帧"
        }

        guard let 物体 = app.layout.selectedObject else {
            return "先把鼠标停在某个输入框上，或选中一个物体再按 i"
        }
        var 数 = 0
        for 键 in Self.变换键们(物体: 物体.id) where 动画通道注册表.共享.通道(键) != nil {
            域.打帧(键: 键)
            数 += 1
        }
        return 数 > 0 ? "第 \(域.当前帧) 帧：\(物体.name) 打了 \(数) 条变换通道" : "没有可打帧的通道"
    }
}
