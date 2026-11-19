import Foundation
import CoreGraphics

// MARK: - MaterialX 节点图构造

/// `MTLX材质`（解析产物）→ App 的 `NodeGraph`。
///
/// 单独拆一个文件是为了这一层能脱离 `着色Store` 单独跑：
/// 它只依赖节点数据模型，纯函数、无主线程隔离，方便在命令行里对真实 `.mtlx` 样本做自检。
enum MTLX建图 {

    /// 输出节点的固定机位（和 `NodeGraph.empty` 一致，导入后一进节点面板就是熟悉的位置）
    static let 输出位置 = CGPoint(x: 620, y: 120)
    private static let 每列宽: CGFloat = 210
    private static let 每行高: CGFloat = 128
    private static let 列顶: CGFloat = 40

    /// 节点按「到 Output 的跳数」分列，同列往下排。
    /// 只搬 `.mtlx` 里真有的节点，不补中间层、不造网关节点。
    /// - Parameter 近似色: 图像贴图节点名 → 读图算出来的平均色（求值兜底）
    /// - Parameter 贴图: 图像贴图节点名 → 贴图库 UUID（真图；没给就只拿平均色）
    static func 建图(_ 材质: MTLX材质, 近似色: [String: PBRValue] = [:], 贴图: [String: UUID] = [:]) -> NodeGraph {
        let 输出 = ShaderNode(kind: .output, position: 输出位置)
        var 节点表: [String: ShaderNode] = [:]
        var 节点列表: [ShaderNode] = []
        var 列高: [Int: Int] = [:]

        // 深度越大离输出越远，列号从右往左数
        for 原 in 材质.节点 {
            let 列 = max(原.深度, 0)
            let 行 = 列高[列] ?? 0
            列高[列] = 行 + 1
            let 位置 = CGPoint(
                x: 输出位置.x - CGFloat(列 + 1) * 每列宽,
                y: 列顶 + CGFloat(行) * 每行高
            )
            var 参数 = 原.参数
            var 图: UUID? = nil
            if 原.kind == .imageTexture {
                // 图像贴图节点：tint = 整图平均色（求值/无贴图兜底），image = 贴图库真图
                if let 补 = 近似色[原.名字], case .color(let c) = 补 { 参数["tint"] = .color(c) }
                图 = 贴图[原.名字]
            } else if let 补 = 近似色[原.名字] {
                参数["color"] = 补      // rgbConstant 的输入口 id 就叫 color
            }
            let 节点 = ShaderNode(
                kind: 原.kind,
                title: 原.名字,
                position: 位置,
                params: 参数,
                image: 图
            )
            节点表[原.名字] = 节点
            节点列表.append(节点)
        }

        var 连线: [NodeLink] = []
        for 连 in 材质.连线 {
            // 上游节点必须真的建出来了（不支持的节点解析期已经跳过并记了诊断）
            guard let 上 = 节点表[连.从] else { continue }
            if 连.到 == MTLX连线.输出 {
                guard let 键 = PBRParamKey(rawValue: 连.到口) else { continue }
                let 出口 = 输出口(上.kind, 期望: MTLX解析.是颜色参数(键) ? .color : .scalar)
                连线.append(NodeLink(fromNode: 上.id, fromSocket: 出口, toNode: 输出.id, toSocket: 连.到口))
            } else if let 下 = 节点表[连.到] {
                // 目标口得是该节点真有的输入口，否则求值器取不到值还会画出一条悬空线
                guard let 入口 = 下.kind.inputs.first(where: { $0.id == 连.到口 }) else { continue }
                let 出口 = 输出口(上.kind, 期望: 入口.kind)
                连线.append(NodeLink(fromNode: 上.id, fromSocket: 出口, toNode: 下.id, toSocket: 连.到口))
            }
        }

        return NodeGraph(nodes: 节点列表 + [输出], links: 连线)
    }

    /// 上游取哪个输出口：按下游那个口的类型挑，挑不到才退回第一个。
    ///
    /// 项目里 `noise` 一个节点同时给「系数 out」和「颜色 outColor」两个口，
    /// 如果只按「这条线要不要颜色」粗判，噪声接到 roughness 时就会错拿颜色口，
    /// 求值结果被强行转成标量，图看着连上了但数值是错的。
    static func 输出口(_ kind: ShaderNodeKind, 期望 kind_: SocketKind) -> String {
        let 口 = kind.outputs
        if let 命中 = 口.first(where: { $0.kind == kind_ }) { return 命中.id }
        if let 首 = 口.first { return 首.id }
        return "out"
    }
}
