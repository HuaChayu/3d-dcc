import Foundation
import RealityKit

// MARK: - 物体几何统计

/// 视口底部信息卡要的"多少点、多少面"。
/// 导入网格从 导入网格库 直接数（池里就是顶点数组，零成本）；
/// 程序化形体没有现成数组，借用 SceneBuilder 生成一次实体再读 MeshResource 的顶点表，
/// 按 MeshKind 缓存 —— 六个形体各算一次，之后纯查表。
enum 对象统计 {
    struct 几何量: Equatable, Sendable {
        var 顶点: Int = 0
        var 三角面: Int = 0
    }

    @MainActor private static var 程序化缓存: [String: 几何量] = [:]

    @MainActor
    static func 几何(_ object: SceneObject) -> 几何量 {
        if let 导入ID = 几何接线.共享.取值(键: object.id.uuidString)?.导入网格标识,
           let 网格集 = 几何接线.共享.取(导入ID),
           !网格集.isEmpty {
            var 量 = 几何量()
            for 网格 in 网格集 {
                量.顶点 += 网格.顶点.count
                量.三角面 += 网格.索引.count / 3
            }
            return 量
        }
        return 程序化(几何接线.共享.程序形状(键: object.id.uuidString, 兜底: object.mesh))
    }

    @MainActor
    private static func 程序化(_ kind: MeshKind) -> 几何量 {
        let 键 = kind.rawValue
        if let 命中 = 程序化缓存[键] { return 命中 }

        var 量 = 几何量()
        if let 实体 = SceneBuilder.makeEntity(for: kind) as? ModelEntity,
           let 网格 = 实体.model?.mesh {
            for 模型 in 网格.contents.models {
                for 部件 in 模型.parts {
                    量.顶点 += 部件.positions.count
                    量.三角面 += (部件.triangleIndices?.count ?? 0) / 3
                }
            }
        }
        程序化缓存[键] = 量
        return 量
    }

    /// 物体身上的一个材质槽：只记"第几号槽、导入时子集写的材质名/下标"。
    /// 不复制材质本体：要显示外观就去材质库引用同一份材质，缺省回落物体当前材质。
    struct 材质槽: Identifiable, Hashable {
        var id: String { 键 }
        let 键: String
        let 序: Int
        let 材质名: String?
        let 下标: Int?

        /// 子集写了材质名就用它，否则按槽序叫「槽 N」
        var 显示名: String {
            if let 材质名, !材质名.isEmpty { return 材质名 }
            return "槽 \(序 + 1)"
        }
    }

    /// 这个物体身上的槽列表：导入网格按子集里的材质下标/材质名去重，顺序保持导入时的出现顺序；
    /// 程序化网格只有一个槽。
    @MainActor
    static func 材质槽列表(_ object: SceneObject) -> [材质槽] {
        if let 导入ID = 几何接线.共享.取值(键: object.id.uuidString)?.导入网格标识,
           let 网格集 = 几何接线.共享.取(导入ID),
           !网格集.isEmpty {
            var 列表: [材质槽] = []
            var 已见 = Set<String>()
            for 网格 in 网格集 {
                for 子集 in 网格.子集 {
                    let 名 = 子集.材质名.flatMap { $0.isEmpty ? nil : $0 }
                    let 键 = 名.map { "名:\($0)" } ?? "下标:\(子集.材质 ?? 0)"
                    guard 已见.insert(键).inserted else { continue }
                    列表.append(材质槽(键: 键, 序: 列表.count, 材质名: 名, 下标: 子集.材质))
                }
            }
            return 列表.isEmpty ? [材质槽(键: "主", 序: 0, 材质名: nil, 下标: nil)] : 列表
        }
        return [材质槽(键: "主", 序: 0, 材质名: nil, 下标: nil)]
    }

    /// 这个物体身上有几个材质槽。跟"用了几种材质图"是两回事，别混。
    @MainActor
    static func 材质槽数(_ object: SceneObject) -> Int {
        材质槽列表(object).count
    }

    /// 材质图里"效果器"的数量：除输出端与常量以外的处理节点
    /// （噪波 / 棋盘格 / 渐变 / 混合 / 色相 / 重映射 / 菲涅尔 / 凹凸）。
    static func 效果器数(_ material: MaterialAsset?) -> Int {
        guard let material else { return 0 }
        return material.graph.nodes.filter { 节点 in
            switch 节点.kind {
            case .output, .rgbConstant, .valueConstant: false
            default: true
            }
        }.count
    }
}
