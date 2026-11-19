import Foundation
import CoreGraphics
import ImageIO

// MARK: - MaterialX 材质接入

/// `.mtlx` 解析结果 → 材质库。
///
/// 职责边界：
/// - 本文件只做「解析产物 → `MaterialAsset`」这一段转换与入库，**不碰绘画域任何东西**，
///   也不改既有材质、不改场景物体的材质引用（材质在下、绘画在上，各层自己管自己）；
/// - 解析（XML → `MTLX文档`）在 `MTLX 解析.swift` 里，后台线程可调；
/// - 入库必须回主线程（`着色Store` 是主actor隔离），所以这里分成两段：
///   `解析为场景(url:)` 可以丢后台，`入库(_:着色:)` 只在主线程跑。
enum MTLX接入 {

    // MARK: 后台：文件 → 导入场景

    /// 把一个 `.mtlx` 读成「只有材质、没有网格」的 `导入场景`。
    /// 走 `导入场景` 这层是为了复用通用导入窗口的整套流程（选文件 / 进度 / 失败提示），
    /// 接入层只要看 `场景.mtlx材质` 非空就走材质入库分支。
    nonisolated static func 解析为场景(url: URL) throws -> 导入场景 {
        let 文档 = try MTLX解析.解析(url: url)
        var 场景 = 导入场景(源文件: url)
        场景.mtlx材质 = 文档.材质
        if 文档.材质.isEmpty {
            场景.报告.append("MaterialX：文件里没有可用的表面材质")
        } else {
            let 节点数 = 文档.材质.reduce(0) { $0 + $1.节点.count }
            场景.报告.append("MaterialX：\(文档.材质.count) 个材质 / \(节点数) 个节点")
        }
        return 场景
    }

    // MARK: 主线程：导入场景 → 材质库

    /// 把一批 `导入场景` 里带的 MaterialX 材质落进材质库并持久化。
    /// 返回新入库的材质 ID（顺序与 `场景集` 内材质顺序一致）。
    @MainActor
    @discardableResult
    static func 入库(_ 场景集: [导入场景], 着色 store: 着色Store?) -> [UUID] {
        guard let store else { return [] }
        var 新ID: [UUID] = []
        for 场景数据 in 场景集 where !场景数据.mtlx材质.isEmpty {
            for 材质 in 场景数据.mtlx材质 {
                let asset = 建资产(材质, 源文件: 场景数据.源文件, 已有名: 取库名(store))
                store.导入材质(asset)
                新ID.append(asset.id)
            }
        }
        guard !新ID.isEmpty else { return [] }
        store.selectedMaterialID = 新ID.last
        // 让底栏切回材质节点页，用户点完导入就能看见刚进来的图，而不是停在原材质上
        store.底栏页 = .节点
        store.persist()
        let 名 = 新ID.last.flatMap { id in store.materials.first { $0.id == id }?.name } ?? "材质"
        store.note(新ID.count == 1 ? "已导入 MaterialX 材质「\(名)」" : "已导入 \(新ID.count) 个 MaterialX 材质")
        return 新ID
    }

    /// 库里已有名字集合：逐个入库时也要算上新加的那些，否则同名文件导入两次会撞名
    @MainActor
    private static func 取库名(_ store: 着色Store) -> Set<String> {
        Set(store.materials.map(\.name))
    }

    // MARK: 单个材质 → 资产

    @MainActor
    private static func 建资产(_ 材质: MTLX材质, 源文件: URL, 已有名: Set<String>) -> MaterialAsset {
        var 材质 = 材质
        let (近似色, 贴图, 缺图) = 近似色表(材质, 源文件: 源文件)
        if !贴图.isEmpty {
            材质.诊断.append("有 \(贴图.count) 张图像贴图已接入图像贴图节点（直连 OpenPBR 颜色口的走真图采样）")
        }
        if 贴图.count < 近似色.count {
            材质.诊断.append("有 \(近似色.count - 贴图.count) 张图像贴图只按整图平均色近似（夹在运算链中间或非颜色口）")
        }
        for 名 in 缺图 {
            材质.诊断.append("图像节点「\(名)」的贴图读不出来（文件缺失或格式不支持），已退回默认灰")
        }
        let 图 = MTLX建图.建图(材质, 近似色: 近似色, 贴图: 贴图)
        let 基线 = OpenPBRParams.default.merging(材质.参数)
        var asset = MaterialAsset(
            name: 唯一名(材质.名称, 已有: 已有名),
            baseline: 基线,
            graph: 图,
            内置: false
        )
        asset.note = 备注(材质, 源文件: 源文件, 图: 图)
        return asset
    }

    /// 名字去重：`着色Store.未占用材质名` 只认 store 里的现值，这里入库是批量的，
    /// 前一个刚 append 但还没落进 store 的也会漏判，所以自己带一份集合走。
    private static func 唯一名(_ 基名: String, 已有: Set<String>) -> String {
        let 干净 = 基名.trimmingCharacters(in: .whitespacesAndNewlines)
        let 基 = 干净.isEmpty ? "MaterialX 材质" : 干净
        guard 已有.contains(基) else { return 基 }
        var 序 = 2
        while 已有.contains("\(基) (\(序))") { 序 += 1 }
        return "\(基) (\(序))"
    }


    // MARK: 图像贴图 → 近似色

    /// 把材质里的图像贴图节点读成平均色。
    ///
    /// 项目现在没有图像贴图节点（视口与路径追踪都还没有 sampler 通路），所以不做真贴图，
    /// 只把整图平均色当成常量喂给解析期留下的占位颜色节点：导入后颜色是对得上的，
    /// 而不是一片默认灰。等贴图通路做完，这里换成就地绑纹理即可，解析层不用动。
    @MainActor
    private static func 近似色表(
        _ 材质: MTLX材质,
        源文件: URL
    ) -> (色: [String: PBRValue], 贴图: [String: UUID], 缺图: [String]) {
        var 表: [String: PBRValue] = [:]
        var 图: [String: UUID] = [:]
        var 缺图: [String] = []
        let 目录 = 源文件.deletingLastPathComponent()
        for 节点 in 材质.节点 {
            guard let 原路径 = 节点.图片 else { continue }
            guard let 完整 = MTLX解析.定位贴图(原路径, 目录: 目录),
                  let 位图 = MTLX解析.读图(完整),
                  let 色 = MTLX解析.平均色(完整) else {
                缺图.append(节点.名字)
                continue
            }
            // 灰度图喂三通道相等的值，下游标量口按亮度加权才不会整体变暗
            表[节点.名字] = .color(节点.图片是标量 ? PBRColor(gray: 色.luminance) : 色)
            // 彩色图才进贴图库（灰度图走亮度口，采样语义不一样，宁可走常量）
            if !节点.图片是标量 {
                图[节点.名字] = 材质接线.共享.源图登记(位图)
            }
        }
        return (表, 图, 缺图)
    }

    // MARK: 备注

    /// 材质备注里写清来源与降级情况：`.mtlx` 里有一半节点项目没有对应实现，
    /// 静默丢掉会让用户以为导入成功但图是空的，所以一律写进 note 让它在检查器里能看见。
    private static func 备注(_ 材质: MTLX材质, 源文件: URL, 图: NodeGraph) -> String {
        var 行: [String] = ["来自 \(源文件.lastPathComponent)（MaterialX）"]
        let 驱动 = 图.drivenKeys
        if !驱动.isEmpty {
            行.append("驱动参数：" + 驱动.map(\.title).sorted().joined(separator: "、"))
        }
        let 贴图数 = 材质.节点.filter { $0.图片 != nil }.count
        if 贴图数 > 0 {
            let 真图 = 图.nodes.filter { $0.kind == .imageTexture && $0.image != nil }.count
            行.append("贴图 \(贴图数) 张：其中 \(真图) 张接进图像贴图节点（颜色口走真图，其余通道按平均色）")
        }
        let 没连上的 = 材质.连线.count - 图.links.count
        if 没连上的 > 0 { 行.append("有 \(没连上的) 条连线因端口不支持被跳过") }
        if !材质.诊断.isEmpty { 行.append(contentsOf: 材质.诊断) }
        return 行.joined(separator: "\n")
    }

    // MARK: 主线程：网格文件自带材质 → 材质库

    /// 网格文件（glTF / OBJ / FBX…）自带的材质落进材质库，基础色贴图直连 OpenPBR 颜色口。
    /// 返回「场景下标 → 场景内材质下标 → 材质库 ID」，物体按子集材质绑定用。
    /// 单个无贴图的默认材质不进库（直接退回场景原有默认材质），免得导一个模型就多一个灰球。
    @MainActor
    @discardableResult
    static func 网格材质入库(
        _ 场景集: [导入场景], 着色 store: 着色Store?
    ) -> [Int: [Int: UUID]] {
        guard let store else { return [:] }
        var 表: [Int: [Int: UUID]] = [:]
        var 新ID: [UUID] = []
        for (场景下标, 场景数据) in 场景集.enumerated() {
            let 需要 = 场景数据.材质.count > 1 || 场景数据.材质.contains { $0.基础色贴图 != nil }
            guard 需要 else { continue }
            var 行: [Int: UUID] = [:]
            for (材质下标, 材质) in 场景数据.材质.enumerated() {
                let asset = 网格资产(材质, 源文件: 场景数据.源文件, 已有名: 取库名(store))
                store.导入材质(asset)
                行[材质下标] = asset.id
                新ID.append(asset.id)
            }
            表[场景下标] = 行
        }
        guard !新ID.isEmpty else { return [:] }
        if store.selectedMaterialID == nil { store.selectedMaterialID = 新ID.first }
        store.persist()
        let 名 = 新ID.first.flatMap { id in store.materials.first { $0.id == id }?.name } ?? "材质"
        store.note(新ID.count == 1 ? "已导入模型材质「\(名)」" : "已导入 \(新ID.count) 个模型材质")
        return 表
    }

    /// 单个网格材质 → MaterialAsset：一张结果图（图像贴图节点）直连 OpenPBR 颜色口；
    /// 没贴图就用颜色常量，节点图上同样一眼能看懂，不还原外部原始节点树。
    @MainActor
    private static func 网格资产(_ 材质: 导入材质, 源文件: URL, 已有名: Set<String>) -> MaterialAsset {
        let 线性色 = PBRColor(Double(材质.基础色.x), Double(材质.基础色.y), Double(材质.基础色.z))
        var 基线 = OpenPBRParams.default
        基线[.baseColor] = .color(线性色)
        基线[.baseMetallic] = .scalar(Double(材质.金属度))
        基线[.baseRoughness] = .scalar(Double(材质.粗糙度))
        基线[.baseAlpha] = .scalar(Double(材质.不透明度))
        基线[.baseIOR] = .scalar(Double(材质.IOR))
        if 材质.自发光 != .zero {
            基线[.emissionColor] = .color(PBRColor(
                Double(材质.自发光.x), Double(材质.自发光.y), Double(材质.自发光.z)
            ))
            基线[.emissionLuminance] = .scalar(1)
        }

        let 输出 = ShaderNode(kind: .output, position: CGPoint(x: 620, y: 120))
        var 节点: [ShaderNode] = []
        var 连线: [NodeLink] = []
        var 有真图 = false
        if let 字节 = 材质.基础色贴图, let 位图 = 解码贴图(字节) {
            // 原始字节一起交给纹理库：项目保存时原样落盘，重启后不用再去找源文件
            let 贴图ID = 材质接线.共享.源图登记(位图, 字节: 字节)
            let 图节点 = ShaderNode(
                kind: .imageTexture,
                title: 材质.基础色贴图名 ?? "基础色贴图",
                position: CGPoint(x: 300, y: 120),
                params: ["tint": .color(PBRColor(1, 1, 1))],
                image: 贴图ID
            )
            节点.append(图节点)
            连线.append(NodeLink(
                fromNode: 图节点.id, fromSocket: "out",
                toNode: 输出.id, toSocket: PBRParamKey.baseColor.rawValue
            ))
            有真图 = true
        } else {
            let 色节点 = ShaderNode(
                kind: .rgbConstant,
                title: "基础色",
                position: CGPoint(x: 300, y: 120),
                params: ["color": .color(线性色)]
            )
            节点.append(色节点)
            连线.append(NodeLink(
                fromNode: 色节点.id, fromSocket: "out",
                toNode: 输出.id, toSocket: PBRParamKey.baseColor.rawValue
            ))
        }

        // 通道图：源材质的哪个口接了图，就把这张图原样接到 OpenPBR 的同名入口。
        // 不复刻对方的节点树（混合/映射/程序化节点一概不带过来），只搬图本身。
        var 接了通道 = 0
        var 竖排 = 0
        for 图 in 材质.通道图 {
            guard let 口 = 口键(用途: 图.用途), let 位图 = 解码贴图(图.字节) else { continue }
            let 贴图ID = 材质接线.共享.源图登记(位图, 字节: 图.字节)
            let 通道节点 = ShaderNode(
                kind: .imageTexture,
                title: 图.名,
                position: CGPoint(x: 300, y: 260 + CGFloat(竖排) * 130),
                params: ["tint": .color(PBRColor(1, 1, 1))],
                image: 贴图ID
            )
            节点.append(通道节点)
            连线.append(NodeLink(
                fromNode: 通道节点.id, fromSocket: "out",
                toNode: 输出.id, toSocket: 口.rawValue
            ))
            竖排 += 1
            接了通道 += 1
        }

        // 游离图：源材质里没接进 Principled 任何口的图像节点（法线/遮罩/多套颜色等）。
        // 一律摆进节点图但不连线——OpenPBR 没有对应入口就不硬塞，让用户自己连。
        var 游离数 = 0
        for 图 in 材质.游离图 {
            guard let 位图 = 解码贴图(图.字节) else { continue }
            let 贴图ID = 材质接线.共享.源图登记(位图, 字节: 图.字节)
            let 散节点 = ShaderNode(
                kind: .imageTexture,
                title: 图.名,
                position: CGPoint(x: 60, y: 120 + CGFloat(游离数) * 130),
                params: ["tint": .color(PBRColor(1, 1, 1))],
                image: 贴图ID
            )
            节点.append(散节点)
            游离数 += 1
        }

        var asset = MaterialAsset(
            name: 唯一名(材质.名称, 已有: 已有名),
            baseline: 基线,
            graph: NodeGraph(nodes: 节点 + [输出], links: 连线),
            内置: false
        )
        var 行 = ["来自 \(源文件.lastPathComponent)（模型自带材质）"]
        if 有真图 {
            行.append("基础色图接 OpenPBR base_color（源材质里连在 Base Color 口上的就是这张）")
        } else if 材质.基础色贴图 != nil {
            行.append("贴图「\(材质.基础色贴图名 ?? "未命名")」解码失败，已退回基础色常量")
        } else if !材质.通道图.isEmpty || !材质.游离图.isEmpty {
            行.append("源材质 Base Color 口没接图，颜色取 Principled 上的常量值")
        } else {
            行.append("纯参数材质：没有贴图，按基础色常量建图")
        }
        if 接了通道 > 0 {
            行.append("另有 \(接了通道) 张图按原口直连 OpenPBR 对应入口")
        }
        if 游离数 > 0 {
            行.append("还有 \(游离数) 张图没接进任何 OpenPBR 口（如法线/遮罩），已摆成孤立图像节点，可自己连线")
        }
        asset.note = 行.joined(separator: "\n")
        return asset
    }

    /// 用途字符串 → OpenPBR 参数键。
    /// blend 导入侧直接写 PBRParamKey 的 rawValue（base_roughness 等），
    /// glTF/OBJ 侧写的是粗糙度/金属度这类关键词，两套都要认。
    private static func 口键(用途: String) -> PBRParamKey? {
        if let 直 = PBRParamKey(rawValue: 用途) { return 直 }
        let 旧表: [String: PBRParamKey] = [
            "roughness": .baseRoughness,
            "metallic": .baseMetallic,
            "emission": .emissionColor,
            "alpha": .baseAlpha,
            "specular": .specularRoughness
        ]
        return 旧表[用途]
    }

    /// 贴图字节 → CGImage（主线程；sRGB 语义，RealityKit 侧自己转线性）
    @MainActor
    private static func 解码贴图(_ 字节: Data) -> CGImage? {
        guard let 源 = CGImageSourceCreateWithData(字节 as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(源, 0, nil)
    }
}
