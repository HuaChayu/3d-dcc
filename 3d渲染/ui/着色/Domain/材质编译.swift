import AppKit
import Metal
import RealityKit
import SceneKit

// MARK: - 解析结果

/// 一份材质编译后的最终参数 + 视口损失清单
struct ResolvedMaterial {
    var params: OpenPBRParams
    var drivenKeys: Set<PBRParamKey>
    var diagnostics: [GraphDiagnostic]
    /// 图像贴图节点直连输出 → 该参数走真贴图采样（值为纹理库 UUID）
    var 贴图: [PBRParamKey: UUID] = [:]
    /// 同一趟编译出来的逐像素程序：这张图是怎么由源图/棋盘格/噪波算出来的。
    /// 视口烘焙、路径追踪、卡片预览都跑同一份指令，没有「哪些节点能进贴图通路」的分支。
    var 贴图程序: [PBRParamKey: 着色程序] = [:]

    /// 视口/出图真正用的参数。基础色贴图已经把调色烘进图里，
    /// 再叠一次节点求值出来的常量色就是双重调色，所以这一项归白。
    var 渲染参数: OpenPBRParams {
        guard 贴图[.baseColor] != nil else { return params }
        var 出 = params
        出[.baseColor] = .color(.white)
        return 出
    }

    /// 视口无法精确表达的参数（检查器/渲染页直接展示，不糊弄）
    var viewportGaps: [PBRParamKey] {
        PBRParamKey.allCases.filter { key in
            key.realityKitSupport == .none && !isNeutral(key)
        }
    }

    private func isNeutral(_ key: PBRParamKey) -> Bool {
        let value = params[key].scalarValue
        if key.isColor { return params[key].colorValue == .white || params[key].colorValue == .black }
        return value == 0
    }
}

// MARK: - 编译

enum MaterialCompiler {

    // MARK: 按资产内容缓存

    /// 一次 resolve 要跑整张节点图：常量求值 + 每个输出口各编一遍栈机 + 派生图查表。
    /// 视口 syncMaterials、OpenPBR 检查器、材质球库、渲染工作区都是"每个物体 / 每次 body 求值"调一次，
    /// 而材质绝大多数帧一个字节都没变。这里按「资产内容」命中复用：
    /// 命中只花一次 Equatable 比较，比重新编译便宜一个数量级。
    /// 缓存里的贴图 UUID 是派生图 id，派生 id 由程序键唯一决定、内容原地更新，可以跨帧持有；
    /// 纹理库清空时由 视口纹理库.清空() 调 清除缓存() 一并作废。
    private static let 解析锁 = NSLock()
    private static let 解析上限 = 16
    private static var 解析表: [(资产: MaterialAsset, 结果: ResolvedMaterial)] = []

    /// 图 + 基线 → 最终参数
    static func resolve(_ material: MaterialAsset) -> ResolvedMaterial {
        解析锁.lock()
        if let i = 解析表.firstIndex(where: { $0.资产.id == material.id }) {
            if 解析表[i].资产 == material {
                let 命中 = 解析表[i].结果
                if i != 0 { 解析表.insert(解析表.remove(at: i), at: 0) }
                解析锁.unlock()
                return 命中
            }
        }
        解析锁.unlock()

        let 结果 = 编译(material)
        解析锁.lock()
        // 换掉旧结果之前先把手里的引用放掉，否则「同一材质反复改参数」会一路虚增引用计数，
        // 那些早该回收的派生图就永远卡在缓存里。
        if let 旧 = 解析表.first(where: { $0.资产.id == material.id }) {
            视口纹理库.解除引用派生(Array(旧.结果.贴图.values))
        }
        解析表.removeAll { $0.资产.id == material.id }
        解析表.insert((material, 结果), at: 0)
        var 挤出: [[UUID]] = []
        if 解析表.count > 解析上限 {
            挤出 = 解析表[解析上限...].map { Array($0.结果.贴图.values) }
            解析表.removeLast(解析表.count - 解析上限)
        }
        // 缓存里被持有的派生图：只要这份结果还在表里，就不许被回收淘汰
        视口纹理库.引用派生(Array(结果.贴图.values))
        解析锁.unlock()
        for ids in 挤出 { 视口纹理库.解除引用派生(ids) }
        return 结果
    }

    /// 纹理库清空后派生图 id 全成死号，缓存必须一起作废。
    static func 清除缓存() {
        解析锁.lock()
        let 全部贴图 = 解析表.flatMap { Array($0.结果.贴图.values) }
        解析表.removeAll()
        解析锁.unlock()
        // 引用在锁外一次性放掉：解析表已空，没人再持有这些派生图，
        // 去留交给「引用计数 + 字节上限」自己判断（还在别处被用着的照样留着）。
        视口纹理库.解除引用派生(全部贴图)
    }

    private static func 编译(_ material: MaterialAsset) -> ResolvedMaterial {
        let evaluation = NodeGraphEvaluator.evaluate(material.graph)
        let params = material.baseline.merging(evaluation.overrides)
        // 程序只编一遍：贴图表直接复用，早先两张表各自把每个输出口编一次，白跑一半
        let 程序表 = 解析程序(material.graph)
        return ResolvedMaterial(
            params: params,
            drivenKeys: Set(evaluation.overrides.keys),
            diagnostics: evaluation.diagnostics,
            贴图: 解析贴图(material.graph, 程序表: 程序表),
            贴图程序: 程序表
        )
    }

    /// 输出节点每个颜色参数上的完整求值程序。视口烘焙、路径追踪、卡片预览共用这一份，
    /// 里面没有「哪个节点能进贴图通路」的分支——任何连线都编成指令。
    static func 解析程序(_ graph: NodeGraph) -> [PBRParamKey: 着色程序] {
        guard let output = graph.outputNode else { return [:] }
        var table: [PBRParamKey: 着色程序] = [:]
        for link in graph.links where link.toNode == output.id {
            guard let key = output.kind.inputs.first(where: { $0.id == link.toSocket })?.paramKey,
                  key.isColor,
                  let 程序 = 节点图编译器.编译(graph, 参数: key)
            else { continue }
            table[key] = 程序
        }
        return table
    }

    /// 参数要用的逐像素图：程序能折成「就是采样一张图」就直用源图，
    /// 否则按程序烘焙派生图——棋盘格、噪波这类没有源图的也一样在这里生成。
    static func 解析贴图(
        _ graph: NodeGraph,
        程序表: [PBRParamKey: 着色程序]? = nil
    ) -> [PBRParamKey: UUID] {
        guard let output = graph.outputNode else { return [:] }
        var table: [PBRParamKey: UUID] = [:]
        for link in graph.links where link.toNode == output.id {
            guard let key = output.kind.inputs.first(where: { $0.id == link.toSocket })?.paramKey,
                  key.isColor,
                  let 程序 = 程序表?[key] ?? 节点图编译器.编译(graph, 参数: key),
                  let 图 = 视口纹理库.派生(程序)
            else { continue }
            table[key] = 图
        }
        return table
    }

    /// 某个节点最终被采样成哪张图：优先取「喂给输出的那条程序」，
    /// 没接到输出上就按它自己的输出口编一份，卡片预览总能看到自己的结果。
    static func 预览编号(_ graph: NodeGraph, 节点 nodeID: UUID) -> UUID? {
        guard let 程序 = 预览程序(graph, 节点: nodeID) else { return nil }
        return 视口纹理库.派生(程序, 最长边: 预览最长边)
    }

    /// 预览签名：程序里任何一位变了卡片就得重画。
    static func 预览签名(_ graph: NodeGraph, 节点 nodeID: UUID) -> String {
        预览签名(graph, 指纹: 图指纹(graph), 节点: nodeID)
    }

    /// 带缓存的预览签名。
    ///
    /// 签名 = 把该节点的上游子图完整编译一遍取程序键。而节点卡片每帧都要拿它做 Equatable 短路，
    /// 拖节点、拖数值、选中的每一帧都要对图里每个节点重编一次 —— 主线程就这么被吃掉了，
    /// 表现出来就是「拖起来一卡一卡」。缓存键 = 图指纹 + 节点 id，图内容没变直接命中。
    static func 预览签名(_ graph: NodeGraph, 指纹: String, 节点 nodeID: UUID) -> String {
        let 键 = "\(指纹)|\(nodeID.uuidString)"
        if let 命中 = 签名缓存[键] { return 命中 }
        let 值 = 预览程序(graph, 节点: nodeID)?.键 ?? ""
        // 图内容变一次就长一批条目，随手清一清，别让它无限涨
        if 签名缓存.count > 2048 { 签名缓存.removeAll(keepingCapacity: true) }
        签名缓存[键] = 值
        return 值
    }

    /// 图指纹：只装会影响编译结果的东西（节点类型 / 参数 / 旁路 / 贴图 + 连线）。
    /// 故意不含 position —— 拖动节点位置不该重编预览，也不该让签名缓存失效。
    static func 图指纹(_ graph: NodeGraph) -> String {
        var 片段: [String] = []
        片段.reserveCapacity(graph.nodes.count + graph.links.count)
        for node in graph.nodes {
            let 参数 = node.params
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: ",")
            片段.append("\(node.id.uuidString)/\(node.kind.rawValue)/\(node.isMuted ? 1 : 0)/\(node.image?.uuidString ?? "-")/\(参数)")
        }
        for link in graph.links {
            片段.append("\(link.fromNode.uuidString):\(link.fromSocket)>\(link.toNode.uuidString):\(link.toSocket)")
        }
        return 片段.joined(separator: "|")
    }

    /// 预览签名缓存。只在主线程（卡片布局期）读写，所以不做加锁。
    nonisolated(unsafe) private static var 签名缓存: [String: String] = [:]

    /// 卡片预览的烘焙档位。卡片只有一两百点宽，512 档纯属浪费 ——
    /// 一条链上每个节点各一张，512 档会把烘焙开销和内存一起放大四倍。
    /// 与视口 512 / 出图 2048 按编号后缀隔离，互不顶替。
    private static let 预览最长边 = 256

    /// 卡片预览用哪份程序：以「节点自己的输出口」为出口编译，只含它和它的上游。
    ///
    /// 旧口径是「输出通道那条程序里有没经过这个节点」。这招在单链、单个图时很讨巧，
    /// 但只要图不止一个、中途还分了叉（图A + 图B → 混合 → 调色 → 输出），
    /// 同一条程序会同时覆盖图A、图B、混合、调色四个节点 —— 四张卡片全显示同一张末端成品，
    /// 素材与中间步骤被抹平，预览就失去意义了。
    /// 现在一律按「自身输出」：图A 是原图、混合是混合结果、调色是调色结果，各看各的。
    /// 想要「这一路最终长啥样」，看输出节点那张卡片即可。
    private static func 预览程序(_ graph: NodeGraph, 节点 nodeID: UUID) -> 着色程序? {
        guard let node = graph.nodes.first(where: { $0.id == nodeID }) else { return nil }
        // 输出节点是通道终点，它没有自己的输出口，给它这一路的最终结果才有意义（基础色优先）
        if node.kind == .output {
            guard let output = graph.outputNode else { return nil }
            var 最佳: (优先: Int, 程序: 着色程序)?
            for 口 in output.kind.inputs {
                guard let key = 口.paramKey, key.isColor,
                      let 程序 = 节点图编译器.编译(graph, 参数: key) else { continue }
                let 优先 = (key == .baseColor) ? 0 : 1
                if 最佳 == nil || 优先 < 最佳!.优先 { 最佳 = (优先, 程序) }
            }
            return 最佳?.程序
        }
        guard let 口 = node.kind.outputs.first(where: { $0.kind == .color })?.id
        else { return nil }
        return 节点图编译器.编译节点(graph, 节点: nodeID, 口: 口)
    }

    static func resolve(_ material: MaterialAsset?) -> ResolvedMaterial {
        guard let material else {
            return ResolvedMaterial(params: .default, drivenKeys: [], diagnostics: [])
        }
        return resolve(material)
    }

}

// MARK: - 颜色桥接

extension PBRColor {
    /// 线性值 → sRGB 编码的 NSColor（AppKit 的 colorSpace: .sRGB）
    var nsColor: NSColor {
        NSColor(
            srgbRed: CGFloat(linearToSRGB(r)),
            green: CGFloat(linearToSRGB(g)),
            blue: CGFloat(linearToSRGB(b)),
            alpha: 1
        )
    }

    private func linearToSRGB(_ v: Double) -> Double {
        let c = min(max(v, 0), 1)
        return c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
    }

    var cgColor: CGColor { nsColor.cgColor }
}

// MARK: - RealityKit 通道口径

extension PBRParamKey {
    /// 视口能否用 RealityKit 的 PhysicallyBasedMaterial 表达这个参数。
    /// 口径按 macOS 27 SDK 的实际属性算，不按文档里的宣传语算。
    var realityKitSupport: ViewportSupport {
        switch self {
        case .baseColor, .baseMetallic, .baseRoughness, .baseAlpha, .geometryOpacity,
             .emissionColor, .emissionLuminance, .coatWeight, .coatRoughness,
             .specularWeight, .specularAnisotropy, .specularRotation,
             .subsurfaceWeight, .subsurfaceColor, .subsurfaceRadius,
             .subsurfaceScatterAnisotropy:
            .full
        case .baseWeight, .fuzzWeight, .fuzzColor, .fuzzRoughness,
             .transmissionWeight, .transmissionColor, .specularRoughness,
             .baseIOR, .thinFilmWeight, .thinFilmThickness, .thinFilmIOR,
             .coatColor, .coatIOR, .coatDarkening,
             .specularColor, .specularIOR, .specularIORLevel,
             .transmissionDepth, .transmissionScatter, .transmissionScatterAnisotropy:
            .approx
        default:
            .none
        }
    }

}

// MARK: - 材质缩略图键（只服务缩略图缓存，不再是材质判据）

/// **仅用于材质球缩略图的渲染缓存键**：缩略图画的是「出厂原始样式」，它变了才需要重画。
///
/// 注意它**不**参与"材质有没有变"的判定 —— 那个一律读数据层材质域的版本号
/// （视口见 `场景 构建.syncMaterials`，PT 见 `PT 渲染器` 的 `scene材质版本`）。
/// 之所以还要一个内容键：出厂快照属于材质本体的一部分，但同一版本内也可能被"冻结出厂样式"改写，
/// 而缩略图缓存不跟随域版本粒度，用内容键最省重绘。
enum 材质缩略图键 {

    static func key(_ resolved: ResolvedMaterial) -> String {
        var base = key(resolved.params, driven: resolved.drivenKeys)
        // 贴图 UUID 进签名：换图必须重建，否则视口留着上一张
        if !resolved.贴图.isEmpty {
            let table = resolved.贴图
                .map { "\($0.key.rawValue)=\($0.value.uuidString)" }
                .sorted()
                .joined(separator: ",")
            base += ";t=" + table
        }
        return base
    }

    static func key(_ params: OpenPBRParams, driven: Set<PBRParamKey>) -> String {
        var parts: [String] = []
        for key in PBRParamKey.allCases {
            parts.append("\(key.rawValue)=\(stable(params[key]))")
        }
        parts.append("d=" + driven.map(\.rawValue).sorted().joined(separator: ","))
        return parts.joined(separator: ";")
    }

    static func stable(_ value: PBRValue) -> String {
        switch value {
        case .scalar(let v):
            String(format: "%.6f", v)
        case .color(let c):
            String(format: "%.6f,%.6f,%.6f", c.r, c.g, c.b)
        }
    }
}

// MARK: - OpenPBR → RealityKit

/// OpenPBR 的 lobe 权重模型在 RealityKit 里没有对应物，
/// 这里按"能在视口看见趋势"的原则压平，缺口由 realityKitGaps 如实上报。
enum RKMaterialBridge {

    static func makeMaterial(_ resolved: ResolvedMaterial, shading: ViewportShading = .material) -> PhysicallyBasedMaterial {
        var material = PhysicallyBasedMaterial()
        apply(resolved, to: &material, shading: shading)
        return material
    }

    // MARK: - B 路线：透射 / 薄膜自定义着色

    private static var glassShaderCache: CustomMaterial.SurfaceShader?
    private static var glassShaderMissing = false

    private static func glassShader() -> CustomMaterial.SurfaceShader? {
        if let glassShaderCache { return glassShaderCache }
        if glassShaderMissing { return nil }
        guard let device = MTLCreateSystemDefaultDevice(),
              let library = device.makeDefaultLibrary(),
              let shader = try? CustomMaterial.SurfaceShader(named: "rkGlassSurface", in: library)
        else {
            glassShaderMissing = true
            return nil
        }
        glassShaderCache = shader
        return shader
    }

    /// 视口材质入口：能走 B 路线就走着色器，拿不到就原样退回 PBR。
    static func makeViewportMaterial(_ resolved: ResolvedMaterial, shading: ViewportShading = .material) -> any RealityKit.Material {
        if let glass = makeGlassMaterial(resolved, shading: shading) { return glass }
        return makeMaterial(resolved, shading: shading)
    }

    /// 玻璃 / 强薄膜：拿 CustomMaterial 在片元级算角度相关干涉项和 Fresnel，
    /// PBR 通道里没有 transmission / IOR / iridescence，只能这样补。
    static func makeGlassMaterial(_ resolved: ResolvedMaterial, shading: ViewportShading = .material) -> CustomMaterial? {
        guard shading == .material else { return nil }
        let p = resolved.params
        let transmission = c01(p.double(.transmissionWeight) * p.double(.geometryOpacity))
        let filmWeight = c01(p.double(.thinFilmWeight))
        guard transmission > 0.01 || filmWeight > 0.05 else { return nil }
        guard let shader = glassShader(),
              var material = try? CustomMaterial(surfaceShader: shader, lightingModel: .lit)
        else { return nil }

        var base = p.color(.baseColor).clamped
        let baseWeight = c01(p.double(.baseWeight))
        if baseWeight < 0.999 { base = base.scaled(baseWeight) }
        if transmission > 0.01 { base = base.mixed(透射外观(p).color, transmission * 0.5) }

        material.baseColor = .init(tint: base.nsColor)
        // x 厚度(nm) / y 薄膜 IOR / z 薄膜权重 / w 透射权重
        material.custom.value = SIMD4<Float>(
            Float(max(p.double(.thinFilmThickness), 0)),
            Float(max(p.double(.thinFilmIOR), 1.01)),
            Float(filmWeight),
            Float(transmission)
        )
        material.blending = .transparent(opacity: .init(floatLiteral: 1))
        material.faceCulling = .none
        return material
    }

    static func apply(_ resolved: ResolvedMaterial, to material: inout PhysicallyBasedMaterial, shading: ViewportShading = .material) {
        let p = resolved.params

        // MARK: 基底
        var baseColor = p.color(.baseColor).clamped
        let baseWeight = c01(p.double(.baseWeight))
        // RealityKit 没有 base_weight 通道，权重只能折进颜色
        if baseWeight < 0.999 { baseColor = baseColor.scaled(baseWeight) }

        material.baseColor = .init(tint: baseColor.nsColor)
        material.metallic = .init(floatLiteral: Float(c01(p.double(.baseMetallic))))
        material.roughness = .init(floatLiteral: Float(c01(p.double(.baseRoughness))))
        // RealityKit 没有 IOR 通道，用 F0 = ((n-1)/(n+1))² 折成镜面强度（1.5 → 0.04 为基准 1.0）
        // MARK: 高光 F0（specular_ior / specular_ior_level / specular_color）
        // specular_ior 是"表面 F0 的折射率"，与体折射率 base_ior 分开；
        // 它保持默认 1.5 时继续沿用 base_ior，老材质外观不变。
        let bodyIOR = max(p.double(.baseIOR), 1.0001)
        let surfaceIOR = p.double(.specularIOR)
        let iorForF0 = abs(surfaceIOR - 1.5) > 0.001 ? max(surfaceIOR, 1.0001) : bodyIOR
        let f0 = pow((iorForF0 - 1) / (iorForF0 + 1), 2)
        // specular_ior_level 是 F0 的缩放；本工程基线默认 0 表示"未设置"，按 1 处理
        let rawLevel = p.double(.specularIORLevel)
        let iorLevel = rawLevel > 0.001 ? c01(rawLevel) : 1
        // specular_color 没有独立通道：亮度折进高光强度，色偏轻微混进基底当"有色高光"
        let specularTint = p.color(.specularColor).clamped
        let specularLuma = min(max(0.2126 * specularTint.r + 0.7152 * specularTint.g + 0.0722 * specularTint.b, 0), 1)
        let specularStrength = c01(
            c01(p.double(.specularWeight)) * c01(f0 / 0.04) * iorLevel * specularLuma
        )
        material.specular = .init(floatLiteral: Float(specularStrength))
        if specularLuma < 0.999 {
            baseColor = baseColor.mixed(specularTint, 0.06 * (1 - specularLuma))
            material.baseColor = .init(tint: baseColor.nsColor)
        }
        material.faceCulling = .none

        // MARK: 薄膜 → 干涉色近似（无 iridescence 通道，折进基底色）
        let filmWeight = c01(p.double(.thinFilmWeight))
        if filmWeight > 0.001 {
            let tint = PBRColor.thinFilmTint(
                thickness: p.double(.thinFilmThickness),
                ior: p.double(.thinFilmIOR)
            )
            baseColor = baseColor.mixed(tint, filmWeight * 0.6)
            material.baseColor = .init(tint: baseColor.nsColor)
            material.specular = .init(floatLiteral: Float(c01(specularStrength + filmWeight * 0.4)))
        }

        // MARK: 清漆（coat_color / coat_ior / coat_darkening 无通道，按趋势压平）
        let coatWeight = c01(p.double(.coatWeight))
        material.clearcoat = .init(floatLiteral: Float(coatWeight))
        material.clearcoatRoughness = .init(floatLiteral: Float(c01(p.double(.coatRoughness))))
        if coatWeight > 0.001 {
            // 涂层颜色混进基底、涂层变暗压一层亮度，视觉上才有"罩了一层清漆"的差别
            let coatTint = p.color(.coatColor).clamped
            let darkening = c01(p.double(.coatDarkening))
            baseColor = baseColor.mixed(coatTint, coatWeight * 0.25).scaled(1 - darkening * coatWeight * 0.3)
            material.baseColor = .init(tint: baseColor.nsColor)
        }

        // MARK: 各向异性（RealityKit 原生通道）
        material.anisotropyLevel = .init(floatLiteral: Float(c01(p.double(.specularAnisotropy))))
        material.anisotropyAngle = .init(floatLiteral: Float(p.double(.specularRotation) * .pi / 180))

        // MARK: 次表面（macOS 27 新增）
        let subsurface = c01(p.double(.subsurfaceWeight))
        material.subsurfaceWeight = .init(floatLiteral: Float(subsurface))
        if subsurface > 0.001 {
            material.subsurfaceColor = .init(color: p.color(.subsurfaceColor).clamped.cgColor)
            // 半径是"平均自由程"：基线里没写（=0）时给 1.2 的兜底，
            // 否则 RealityKit 收到 0 就等于没有次表面，玉石/皮肤都会变成纯漫反射。
            let rawRadius = p.double(.subsurfaceRadius)
            let radius = rawRadius > 0.001 ? rawRadius : 1.2
            material.subsurfaceRadius = .init(floatLiteral: Float(radius))
            material.subsurfaceScatterAnisotropy = .init(
                floatLiteral: Float(min(max(p.double(.subsurfaceScatterAnisotropy), -0.99), 0.99))
            )
        }

        // MARK: 绒毛 → sheen（sheen 无独立 roughness，fuzz_roughness 折进基底粗糙度）
        let fuzz = c01(p.double(.fuzzWeight))
        if fuzz > 0.001 {
            let merged = c01(p.double(.baseRoughness)) * (1 - fuzz * 0.5)
                + c01(p.double(.fuzzRoughness)) * (fuzz * 0.5)
            material.roughness = .init(floatLiteral: Float(merged))
        }
        if fuzz > 0.001 {
            var sheen = PhysicallyBasedMaterial.SheenColor()
            sheen.__tint = p.color(.fuzzColor).clamped.mixed(.white, 1 - fuzz).cgColor
            material.sheen = sheen
        } else {
            material.sheen = nil
        }

        // MARK: 自发光
        let emission = p.color(.emissionColor).clamped
        let luminance = max(p.double(.emissionLuminance), 0)
        material.emissiveColor = .init(color: luminance > 0 ? emission.nsColor : PBRColor.black.nsColor)
        material.emissiveIntensity = Float(min(luminance, 50))

        // MARK: 透明 / 透射
        // 口径：alpha 是"不透明度"，透射只做玻璃近似。
        // RealityKit 没有 transmission_weight、也没有 IOR，透射只能走 opacity + 去金属。
        let alpha = c01(p.double(.baseAlpha) * p.double(.geometryOpacity))
        let transmission = c01(p.double(.transmissionWeight))
        var opacity = alpha
        if transmission > 0.01 {
            let 透射 = 透射外观(p)
            // 散射越重越浑浊：透射的"透明"打折、表面更粗糙
            let scatter = 透射.scatter
            opacity = c01(alpha * (1 - transmission * 0.85 * (1 - scatter * 0.6)))
            material.metallic = .init(floatLiteral: 0)
            material.roughness = .init(floatLiteral: Float(c01(p.double(.specularRoughness) + scatter * 0.4)))
            baseColor = baseColor.mixed(透射.color, transmission * 0.6)
            material.baseColor = .init(tint: baseColor.nsColor)
        }

        if opacity >= 0.999 {
            material.blending = .opaque
        } else {
            material.blending = .transparent(opacity: .init(floatLiteral: Float(opacity)))
        }

        // MARK: 着色模式
        switch shading {
        case .wireframe:
            material.triangleFillMode = .lines
        default:
            material.triangleFillMode = .fill
        }

        // MARK: 贴图收口
        // 图直连 OpenPBR 的参数在这里盖真图；tint 仍保留，RealityKit 是 tint × texture，
        // 所以上面那套权重/薄膜混合算出来的色调会自然乘到贴图上，不会丢
        if let id = resolved.贴图[.baseColor], let resource = 视口纹理库.取(id) {
            // 贴图已经把调色烘进去了，这里的常量色只保留「与调色无关」的叠加：有贴图就归白
            material.baseColor = .init(tint: PBRColor.white.nsColor, texture: .init(resource))
        }
    }

    /// 透射外观：把 transmission_color / transmission_depth / transmission_scatter /
    /// transmission_scatter_anisotropy 折成"透过来的颜色 + 浑浊度"。
    /// - depth 走 Beer–Lambert 吸收：深度越小、吸收系数越大，颜色越浓。
    /// - scatter 是散射色，越亮越浑浊；各向异性只把散射强度按前/后向加权。
    private static func 透射外观(_ p: OpenPBRParams) -> (color: PBRColor, scatter: Double) {
        let raw = p.color(.transmissionColor).clamped
        var tint = raw
        let depth = max(p.double(.transmissionDepth), 0)
        if depth > 0.001 {
            let sigma = 0.9 / max(depth, 0.05)
            tint = PBRColor(
                exp(-(1 - raw.r) * sigma),
                exp(-(1 - raw.g) * sigma),
                exp(-(1 - raw.b) * sigma)
            )
        }
        let scatterColor = p.color(.transmissionScatter).clamped
        let aniso = min(max(p.double(.transmissionScatterAnisotropy), -0.99), 0.99)
        let scatter = c01(max(scatterColor.r, max(scatterColor.g, scatterColor.b)) * (1 + aniso * 0.5))
        if scatter > 0.001 {
            tint = tint.mixed(scatterColor, scatter * 0.6)
        }
        return (tint, scatter)
    }

    private static func c01(_ v: Double) -> Double { min(max(v, 0), 1) }
}

// MARK: - 贴图库（视口）

/// 导入贴图先存 CGImage，等视口真要用的时候再做成 TextureResource。
/// 这么做两头都省：解码时不必碰 GPU；同一 UUID 只建一次纹理，
/// 材质重建（改参数、换着色模式）不会反复上传。
enum 视口纹理库 {

    private static let 锁 = NSLock()
    private static var 图: [UUID: CGImage] = [:]
    private static var 资源: [UUID: TextureResource] = [:]
    private static var 失败: Set<UUID> = []
    /// 贴图原始字节（导入文件的 PNG/JPEG 原样）。项目保存时直接落盘，不重新编码。
    private static var 字节: [UUID: Data] = [:]
    /// 登记先后顺序。字典无序，节点上的「换贴图」列表要按导入顺序稳定排列，
    /// 否则每次刷新缩略图都会跳位。
    private static var 顺序: [UUID] = []
    /// 节点卡片预览用的缩小版（键 = id + 最长边）
    private static var 缩略缓存: [String: CGImage] = [:]
    /// 派生图登记表：派生 id → 算出它的那份程序（出图档重烘要用）。
    /// 派生图与导入图彻底隔离：不进 顺序、不写 字节，存档和「换贴图」清单里都看不到它们。
    private static var 派生表: [UUID: 着色程序] = [:]
    /// 出图档（2048）缓存。视口只吃 768 档，高清档等路径追踪第一次来取时再烘。
    private static var 大图: [UUID: CGImage] = [:]
    /// 大图是按多大档烘的：视口要 1024、出图要 2048，先来的小档不该占住 2048 的位置。
    private static var 大图档: [UUID: Int] = [:]
    /// 派生图的新旧顺序：拖参数会一串串生新图，得有个上限，否则显存和内存一路涨
    private static var 派生顺序: [UUID] = []
    /// 每张派生图实际烘到的边长：命中时要靠它判断「已烘够」还是「要升档重烘」
    private static var 实际档: [UUID: Int] = [:]

    // MARK: 派生缓存记账（引用计数 + 字节上限 + 在飞保护）

    /// 早先这里是「只留最近 32 张」的 FIFO 上限：不看每张多大，也不看谁在用。
    /// 后果是两头都不对 —— 拖一次滑杆生成的废图会把正在渲染的那张挤掉（重烘一次就是几十毫秒卡顿），
    /// 而 2048 档一张就 16MB，32 张能撑到 500MB；反过来小图常见时 32 张又早早就把有用的图删了。
    /// 现在一律按「引用计数 + 字节上限（默认 256MB，设置里可调）+ 在飞帧保护」回收：
    /// 只有「没有任何解析结果引用、也没有帧/补烘在读」的图才会被淘汰，直到占用落回上限以内。
    private static var 派生引用: [UUID: Int] = [:]
    /// 每张派生图当前占的字节（小图 + 大图一起算），以及总量
    private static var 派生字节: [UUID: Int] = [:]
    private static var 派生总字节 = 0
    /// 正在被帧 / 后台补烘读的图：烘焙和上传都是异步的，回收必须等它落笔
    private static var 在飞图: [UUID: Int] = [:]
    private static var 在飞帧 = 0
    private static var _派生字节上限 = 256 * 1024 * 1024

    /// 源图代际：库里的「导入图集合」变了才 +1 —— 新增一张 id、释放、裁剪、清空。
    /// **原地覆盖同一个 id 的像素不算集合变动**（那种由 像素代际 精确到 id 记账），
    /// 否则重画一张图就会被图集当成「整张层表换了一代」而全层重传。
    /// 路径追踪的贴图图集靠它判定层表还对不对得上。
    private static var _源图代际: UInt64 = 0
    private static var _像素代际: [UUID: UInt64] = [:]
    private static var _代际计数: UInt64 = 0

    // MARK: 记账接口

    /// 派生缓存上限（字节）。默认 256MB，设置页「派生缓存上限」改的是它。
    static var 派生字节上限: Int {
        锁.lock(); defer { 锁.unlock() }
        return _派生字节上限
    }

    /// 改上限并立即按新上限回收一次（调小要马上生效，不能等下一次烘焙）
    static func 设派生字节上限(_ 字节: Int) {
        let 值 = max(16 * 1024 * 1024, 字节)
        锁.lock()
        _派生字节上限 = 值
        回收派生()
        锁.unlock()
    }

    /// 当前派生缓存占用（张数 / 字节）：设置页显示与排查用。
    static var 派生占用: (张数: Int, 字节: Int) {
        锁.lock(); defer { 锁.unlock() }
        return (派生表.count, 派生总字节)
    }

    /// 一份解析结果持有这些派生图：持有期间不许回收。
    /// 引用不按「用了多少次」而按「几个持有者」算，同一张图被同一份结果的两个通道共用也只算一次。
    static func 引用派生(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        锁.lock(); defer { 锁.unlock() }
        for id in Set(ids) { 派生引用[id, default: 0] += 1 }
    }

    static func 解除引用派生(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        锁.lock(); defer { 锁.unlock() }
        for id in Set(ids) {
            let 余 = (派生引用[id] ?? 0) - 1
            if 余 > 0 { 派生引用[id] = 余 } else { 派生引用[id] = nil }
        }
        回收派生()
    }

    /// 标记「这一帧还要读这些图」：帧没结束前不许回收。
    /// 少了这一步会有一类很难查的偶发花图：帧提交后、上传还没落，缓存被别的线程回收掉了。
    static func 帧内使用(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        锁.lock(); defer { 锁.unlock() }
        guard 在飞帧 > 0 else { return }
        for id in Set(ids) { 在飞图[id, default: 0] += 1 }
    }

    /// 帧开始 / 帧结束由材质接线的 提交帧 / 帧完成 驱动，两边帧号必须一一配对。
    static func 帧开始() {
        锁.lock(); defer { 锁.unlock() }
        在飞帧 += 1
    }

    static func 帧结束() {
        锁.lock(); defer { 锁.unlock() }
        if 在飞帧 > 0 { 在飞帧 -= 1 }
        guard 在飞帧 == 0 else { return }
        在飞图.removeAll()
        回收派生()
    }

    /// 源图代际（供路径追踪图集判定层表新鲜度）。
    static var 源图代际: UInt64 {
        锁.lock(); defer { 锁.unlock() }
        return _源图代际
    }

    /// 某张图当前像素是第几代：每次写像素（登记 / 派生烘好 / 高清档补完）都会变。
    /// 图集按它判断「这一层要不要重画」，不必整层重传。
    static func 像素代际(_ id: UUID) -> UInt64 {
        锁.lock(); defer { 锁.unlock() }
        return _像素代际[id] ?? 0
    }

    /// 任意一张图被重写过多少次（全库单调计数）。
    /// 消费端（如 PT 材质图集）拿它做一次廉价判据：计数没变就等于「一整库像素都没动过」，
    /// 不必逐张查代际；计数变了再逐层比对，缩小到真正变掉的那几层。
    static var 像素写计数: UInt64 {
        锁.lock(); defer { 锁.unlock() }
        return _代际计数
    }

    /// 调用方持锁
    private static func bump像素代际(_ id: UUID) {
        _代际计数 += 1
        _像素代际[id] = _代际计数
    }

    // MARK: 拖动期 / 后台烘焙（P4）

    /// 是否正在拖动：左键按住期间（拖滑杆、拖物体、拖画布都算）。
    /// 不采用「每个参数控件各自打点」的办法 —— 滑杆几十个，漏一个就漏一整片；
    /// 左键按住这个信号粒度粗一些，但对「拖动频率」的近似完全够用。
    static var 拖动中: Bool {
        (NSEvent.pressedMouseButtons & 1) != 0
    }

    /// 拖动期整档降到一半：卡片 256→128、视口 512→256。
    /// 逐像素本来就是并行跑的，一档之差是 4 倍像素量，
    /// 观感上只是「拖动时糊一点、松手变清楚」，换来的是滑杆不掉帧。
    private static func 执行档(_ 最长边: Int) -> Int {
        拖动中 ? max(64, 最长边 / 2) : 最长边
    }

    /// 只做存在性判断，不触发 2048 档烘焙。
    /// 以前 PT 转译用 `取图(...) != nil` 探一下图在不在，结果每张派生图都被逼着同步烘一张 2048 档——
    /// 探针顺手把最贵的那一步做了，这是 PT 首帧最隐蔽的一笔开销。
    static func 有图(_ id: UUID) -> Bool {
        锁.lock()
        defer { 锁.unlock() }
        return 图[id] != nil || 大图[id] != nil
    }

    /// 只取现成的图，绝不触发烘焙 —— 给「一刻都不能等」的渲染线程用（如 PT 首帧）。
    /// 返回拿到的图 + 是否已达目标档；未达档时调用方应先用这张低档图顶上，
    /// 再用 `后台补烘` 补高清，补完再换图（首帧因此不必等几十秒的逐像素烘焙）。
    static func 取图即时(_ id: UUID, 最长边: Int) -> (图: CGImage, 已达档: Bool)? {
        锁.lock()
        defer { 锁.unlock() }
        guard let 底图 = 图[id] else { return nil }
        // 导入贴图本身没有「档」的概念，直接就是成品
        guard 派生表[id] != nil else { return (大图[id] ?? 底图, true) }
        if let 已备 = 大图[id], (大图档[id] ?? 0) >= 最长边 { return (已备, true) }
        return (大图[id] ?? 底图, false)
    }

    /// 后台补烘队列：逐像素烘焙是纯 CPU 计算，放主线程就是白屏
    private static let 补烘队列 = DispatchQueue(label: "材质贴图后台补烘", qos: .utility)
    /// 正在烘的「图 + 档」：同一张同一档只烘一次，重复请求直接合并
    private static var 补烘中: Set<String> = []

    /// 后台补烘一张派生图的指定档，绝不阻塞调用线程；烘完在主队列回调（回调里可换图）。
    /// 无论是否真烘了东西都会回调一次，调用方的计数/状态因此不会漏归零。
    static func 后台补烘(_ id: UUID, 最长边: Int, 完成: @escaping () -> Void) {
        let 键 = "\(id.uuidString)|\(最长边)"
        锁.lock()
        let 可烘 = 派生表[id] != nil && (大图档[id] ?? 0) < 最长边
        let 已在跑 = 补烘中.contains(键)
        if 可烘 && !已在跑 { 补烘中.insert(键) }
        锁.unlock()
        guard 可烘, !已在跑 else {
            DispatchQueue.main.async(execute: 完成)
            return
        }
        补烘队列.async {
            // 派生大图 自己加锁取程序、烘完写缓存；拖动中它会直接退回原图不烘，
            // 那种情况留到下一帧由渲染侧重新下单即可。
            _ = 派生大图(id, 最长边: 最长边)
            锁.lock()
            补烘中.remove(键)
            锁.unlock()
            DispatchQueue.main.async(execute: 完成)
        }
    }

    /// 写一张派生图（调用方持锁）
    private static func 写派生(_ id: UUID, _ 程序: 着色程序, _ 档: Int, _ 已烘: CGImage) {
        图[id] = 已烘
        实际档[id] = 档
        资源[id] = nil
        失败.remove(id)
        派生表[id] = 程序
        派生顺序.removeAll { $0 == id }
        派生顺序.append(id)
        bump像素代际(id)
        记派生字节(id)
        回收派生()
    }

    /// 登记一张图，返回可写进节点的 UUID。
    /// 顺手给出原始字节就留着落盘用；不给（程序生成的位图、内联小图）也没关系，
    /// 保存时会补一次 PNG 编码。
    @discardableResult
    static func 登记(_ cgImage: CGImage, id: UUID = UUID(), 字节 data: Data? = nil) -> UUID {
        锁.lock()
        defer { 锁.unlock() }
        图[id] = cgImage
        资源[id] = nil
        失败.remove(id)
        let 新增 = !顺序.contains(id)
        if 新增 { 顺序.append(id) }
        if let data { 字节[id] = data }
        // 源图代际只回答「集合变了没有」（新增 / 删除 / 换工程），**不**回答「像素变了没有」。
        // 同一个 id 原地换像素属于后者，由下面的 像素代际 记账 —— 两者混在一起的话，
        // 盖一张图的像素也会被图集当成「整个集合换了一代」而全层重传。
        if 新增 { _源图代际 += 1 }
        bump像素代际(id)
        return id
    }

    /// 丢掉一批源图（材质域判定零引用后调用）。派生图、缩略缓存一并作废。
    static func 移除(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        锁.lock()
        for id in ids {
            图[id] = nil
            资源[id] = nil
            字节[id] = nil
            失败.remove(id)
            顺序.removeAll { $0 == id }
            缩略缓存 = 缩略缓存.filter { !$0.key.hasPrefix(id.uuidString) }
            _像素代际[id] = nil
        }
        // 只引用这些源图烘出来的派生图也一并作废：源图没了，它的程序永远算不出对的像素
        for id in Array(派生表.keys) where 派生表[id]?.贴图.contains(where: ids.contains) == true {
            丢弃派生(id)
        }
        派生顺序.removeAll { 派生表[$0] == nil }
        _源图代际 += 1
        锁.unlock()
        MaterialCompiler.清除缓存()
    }

    /// 从文件字节登记（项目载入用）：解码成图 + 保留原字节。
    /// UUID 由容器清单给出，材质节点里存的引用因此跨重启依然指得中。
    @discardableResult
    static func 登记字节(_ data: Data, id: UUID) -> Bool {
        guard let rep = NSBitmapImageRep(data: data), let image = rep.cgImage else { return false }
        _ = 登记(image, id: id, 字节: data)
        return true
    }

    /// 拿 CGImage 本体（路径追踪上传贴图图集用，走的是 CPU 侧像素，不走 RealityKit）。
    /// 派生图在这里给 2048 档：视口走的是 取() 的 768 档，出图要原分辨率。
    static func 取图(_ id: UUID, 最长边: Int = 2048) -> CGImage? {
        锁.lock()
        let 直接 = 图[id]
        let 已备 = 大图[id]
        let 已备档 = 大图档[id] ?? 0
        // 已经烘到更大档的，小档请求直接用现成的，不回头重烘
        let 需高清 = 派生表[id] != nil && (已备 == nil || 已备档 < 最长边)
        锁.unlock()
        // 档位要按调用方要的档烘：以前这里不传档，默认 2048 ——
        // 视口只要 1024 却被迫烘了 400 万像素（4 倍开销），这是 PT 首帧十几秒的另一半原因。
        if 需高清 { return 派生大图(id, 最长边: 最长边) ?? 直接 }
        return 已备 ?? 直接
    }

    // MARK: 派生贴图（图像 + 调色烘焙成一张新图）

    /// 程序 → 派生图编号。
    /// 纯采样一张图（就是原图本身）直接给源图，零烘焙；
    /// 不随 uv 变的程序返回 nil，让调用方走常量参数更省钱。
    static func 派生(_ 程序: 着色程序, 最长边: Int = 512) -> UUID? {
        if 程序.指令.count == 1, case .采样(0) = 程序.指令[0], let 源 = 程序.贴图.first {
            return 源
        }
        guard 程序.逐像素 else { return nil }
        // 档位要进编号：同一份程序在「卡片 256 / 视口 512 / 出图 2048」是三种不同精度的位图。
        // 共用编号会让先烘的那一档顶掉别人（卡片先建就把视口那张糊成 256），所以按档隔离。
        let 档 = 执行档(最长边)
        let id = 稳定编号(程序.键 + "@\(档)")
        锁.lock()
        let 已烘档 = 图[id] != nil ? (实际档[id] ?? 档) : 0
        锁.unlock()
        if 已烘档 >= 档 { return id }

        guard let 小图 = 烘焙(程序, 最长边: 档) else { return 程序.贴图.first }
        锁.lock()
        写派生(id, 程序, 档, 小图)
        锁.unlock()
        return id
    }

    /// 出图档：路径追踪要 2048 档，第一次来取时烘一次，之后缓存。
    static func 派生大图(_ id: UUID, 最长边: Int = 2048) -> CGImage? {
        锁.lock()
        if let 已备 = 大图[id], (大图档[id] ?? 0) >= 最长边 { 锁.unlock(); return 已备 }
        let 程序 = 派生表[id]
        锁.unlock()
        guard let 程序 else { return nil }
        // 2048 档是 400 万像素：相机一动、材质一改就可能来取，
        // 拖动期同步烘一次就是几十毫秒的白屏，先拿低档图顶着，松手后下一次 取图 自动补齐。
        if 拖动中 { return 取图本原(id) }
        guard let 烘好 = 烘焙(程序, 最长边: 最长边) else { return nil }
        锁.lock()
        大图[id] = 烘好
        大图档[id] = 最长边
        // 同一张图换了更高档的像素：路径追踪图集靠 像素代际 认出「这一层要重画」
        bump像素代际(id)
        记派生字节(id)
        回收派生()
        锁.unlock()
        return 烘好
    }

    /// 重算某张派生图占的字节（小图 + 大图一起算）并维护总量（调用方持锁）
    private static func 记派生字节(_ id: UUID) {
        派生总字节 -= 派生字节[id] ?? 0
        var 共 = 0
        if let 小 = 图[id] { 共 += 小.width * 小.height * 4 }
        if let 大 = 大图[id] { 共 += 大.width * 大.height * 4 }
        派生字节[id] = 共 > 0 ? 共 : nil
        派生总字节 += 共
        if 派生总字节 < 0 { 派生总字节 = 0 }
    }

    /// 真正丢掉一张派生图（调用方持锁）
    private static func 丢弃派生(_ id: UUID) {
        派生总字节 -= 派生字节[id] ?? 0
        if 派生总字节 < 0 { 派生总字节 = 0 }
        派生字节[id] = nil
        图[id] = nil
        资源[id] = nil
        大图[id] = nil
        大图档[id] = nil
        实际档[id] = nil
        派生表[id] = nil
        失败.remove(id)
        缩略缓存 = 缩略缓存.filter { !$0.key.hasPrefix(id.uuidString) }
        _像素代际[id] = nil
    }

    #if DEBUG
    /// 造一张给定颜色的 4×4 假图（自检专用，不进任何用户数据）
    static func 自检假图(_ r: Double, _ g: Double, _ b: Double) -> CGImage? {
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

    /// 【派生淘汰自检】账面断言：不烘真图，用受控的字节记账验证三条规则——
    /// ①被引用不能扔 ②在飞不能扔 ③保护优先于上限（宁可超限也不扔还在用的）。
    /// 只在库为空时跑（材质域初始化期），库非空直接跳过，绝不搅动真实贴图。
    /// 注意：`派生()` 内部自己加锁，所以这里不能整段持锁，只能在改账面时逐段 short lock。
    static func 自检派生淘汰() {
        func 持锁<T>(_ 体: () -> T) -> T {
            锁.lock(); defer { 锁.unlock() }
            return 体()
        }
        let 空库 = 持锁 { 派生表.isEmpty && 派生总字节 == 0 && 派生引用.isEmpty && 在飞图.isEmpty && 在飞帧 == 0 }
        guard 空库 else {
            NSLog("【派生淘汰自检】跳过：库内已有 %d 张派生图 / %d 字节（不搅动真实贴图）",
                  持锁 { 派生表.count }, 持锁 { 派生总字节 })
            return
        }
        let 每张 = 6 * 1024 * 1024
        let 上限 = 12 * 1024 * 1024
        var 断言: [(String, Bool, String)] = []
        func 记(_ 名: String, _ 过: Bool, _ 实测: @autoclosure () -> String) {
            断言.append((名, 过, 实测()))
        }
        // 造 4 张派生图。必须是「逐像素」程序（采样 + 相乘），派生() 才会真烘一张出来；
        // 常量程序会被折成常量直接返回 nil，那是编译期的省事路径，跟淘汰无关。
        // 4×4 假源图 + 64 档烘焙，单张几毫秒；真实字节很小，随后把账面字节改成受控值。
        var 源: UUID?
        if let 假 = Self.自检假图(0.8, 0.4, 0.2) { 源 = 登记(假) }
        guard let 源 else {
            NSLog("【派生淘汰自检】✗ 造不出假源图，断言无法进行")
            return
        }
        defer { 移除([源]) }
        var ids: [UUID] = []
        for k in 0..<4 {
            var 程序 = 着色程序()
            程序.颜色 = [PBRColor(0.1 * Double(k), 0.2, 0.3)]
            程序.贴图 = [源]
            // 推色 → 采样 → 相乘：结果随 uv 变，派生() 才会真烘一张 64 档的图
            程序.指令 = [.推色(0), .采样(0), .相乘]
            guard let id = 派生(程序, 最长边: 64), id != 源 else { continue }
            ids.append(id)
        }
        guard ids.count == 4 else {
            持锁 { for id in ids { 丢弃派生(id) }; 派生顺序.removeAll(); 派生总字节 = 0 }
            NSLog("【派生淘汰自检】✗ 只造出 %d/4 张派生图，断言无法进行", ids.count)
            return
        }
        let (甲, 乙, 丙, 丁) = (ids[0], ids[1], ids[2], ids[3])
        let 原上限 = 持锁 { _派生字节上限 }

        // 阶段一：账面每张 6MB、合计 24MB、上限 12MB；甲被引用、丁在飞 → 只能扔乙/丙
        持锁 {
            for id in ids { 派生字节[id] = 每张 }
            派生总字节 = 每张 * ids.count
            _派生字节上限 = 上限
            派生引用[甲] = 1
            在飞帧 = 1
            在飞图[丁] = 1
            回收派生()
        }
        let 阶段一 = 持锁 { (甲在: 派生表[甲] != nil, 丁在: 派生表[丁] != nil,
                            总字节: 派生总字节, 乙在: 派生表[乙] != nil, 丙在: 派生表[丙] != nil) }
        记("①被引用的甲不被淘汰", 阶段一.甲在, "甲存活=\(阶段一.甲在 ? "是" : "否")")
        记("②在飞的丁不被淘汰", 阶段一.丁在, "丁存活=\(阶段一.丁在 ? "是" : "否")")
        记("③总量被压到上限内", 阶段一.总字节 <= 上限,
          "总字节=\(阶段一.总字节 / 1024 / 1024)MB 上限=\(上限 / 1024 / 1024)MB")
        记("④非受保护者确实被扔（乙或丙至少少一张）", !阶段一.乙在 || !阶段一.丙在,
          "乙=\(阶段一.乙在 ? "在" : "扔") 丙=\(阶段一.丙在 ? "在" : "扔")")

        // 阶段二：存活者账面摊满，上限设成「只差 1 字节」——保护全生效就一张都扔不掉
        let 阶段二 = 持锁 { () -> (存活前: Int, 总前: Int, 存活后: Int, 总后: Int) in
            let 存活 = ids.filter { 派生表[$0] != nil }
            for id in 存活 { 派生字节[id] = 每张 }
            派生总字节 = 每张 * 存活.count
            _派生字节上限 = max(0, 派生总字节 - 1)
            let 存活前 = 存活.count, 总前 = 派生总字节
            回收派生()
            return (存活前, 总前, 存活.filter { 派生表[$0] != nil }.count, 派生总字节)
        }
        记("⑤引用/在飞全受保护时宁可超上限也不扔", 阶段二.存活后 == 阶段二.存活前 && 阶段二.总后 == 阶段二.总前,
          "存活 \(阶段二.存活前)→\(阶段二.存活后) 总字节 \(阶段二.总前 / 1024 / 1024)MB→\(阶段二.总后 / 1024 / 1024)MB")

        // 阶段三：解除全部引用、结束在飞帧、上限压到 0 → 应全部可回收。
        // 上限必须压到「低于当前占用」，否则 回收派生 会判定「还在额度内」直接不动手，
        // 那就测不到解放后的回收，而不是回收坏了。
        持锁 {
            派生引用.removeAll()
            在飞帧 = 0
            在飞图.removeAll()
            _派生字节上限 = 0
            回收派生()
        }
        let 阶段三 = 持锁 { (总: 派生总字节, 活: ids.filter { 派生表[$0] != nil }.count) }
        记("⑥无人引用且不在飞后可全部回收", 阶段三.总 == 0 && 阶段三.活 == 0,
          "总字节=\(阶段三.总) 存活=\(阶段三.活)")

        // 上限入口的下限钳制：设置里给 1MB 这种离谱值，必须被抬到 16MB，
        // 否则一设就只剩几张小图，视口每帧都在重烘。
        // 注意：设派生字节上限() 自己加锁，这里不能包在 持锁 里，否则自锁
        持锁 { _派生字节上限 = 原上限 }
        设派生字节上限(1024 * 1024)
        let 钳制 = 持锁 { _派生字节上限 }
        记("⑦上限入口把过小的值抬到 16MB 下限", 钳制 == 16 * 1024 * 1024,
          "设 1MB → 实取 \(钳制 / 1024 / 1024)MB")

        // 收尾：清残留、恢复上限
        持锁 {
            for id in ids { 丢弃派生(id) }
            派生顺序.removeAll()
            派生引用.removeAll()
            在飞图.removeAll()
            在飞帧 = 0
            派生总字节 = 0
            _派生字节上限 = 原上限
        }
        let 收尾 = 持锁 { (表: 派生表.count, 总: 派生总字节, 引: 派生引用.count) }
        记("⑧收尾：库回到空且上限已还原", 收尾.表 == 0 && 收尾.总 == 0 && 收尾.引 == 0,
          "派生表=\(收尾.表) 字节=\(收尾.总) 引用表=\(收尾.引)")

        for (名, 过, 实测) in 断言 {
            NSLog("【派生淘汰自检】%@ %@ —— %@", 过 ? "PASS" : "FAIL", 名, 实测)
        }
        let 过数 = 断言.filter { $0.1 }.count
        NSLog("【派生淘汰自检】结论：%d/%d 项通过%@", 过数, 断言.count, 过数 == 断言.count ? "" : "（有失败项，见上）")
    }
    #endif

    /// 派生图淘汰（调用方持锁）：引用计数 + 字节上限 + 在飞帧保护。
    /// 从最旧的开始看，但只要还在被引用 / 还在飞就跳过 —— 淘汰顺序只决定「都可用时先扔谁」，
    /// 绝不决定「能不能扔」。
    private static func 回收派生(保护 保护集: Set<UUID> = []) {
        guard 派生总字节 > _派生字节上限 else { return }
        for id in 派生顺序 {
            if 派生总字节 <= _派生字节上限 { break }
            if 派生表[id] == nil { continue }
            if (派生引用[id] ?? 0) > 0 { continue }
            if (在飞图[id] ?? 0) > 0 { continue }
            if 保护集.contains(id) { continue }
            丢弃派生(id)
        }
        派生顺序.removeAll { 派生表[$0] == nil }
    }

    private static func 取图本原(_ id: UUID) -> CGImage? {
        锁.lock()
        defer { 锁.unlock() }
        return 图[id]
    }

    /// 派生编号必须可复现：同一份程序落同一个 UUID。
    /// 每次 resolve 都换新 id 的话材质签名会跟着抖，视口会不停重建。
    private static func 稳定编号(_ 键: String) -> UUID {
        var 甲: UInt64 = 0xcbf2_9ce4_8422_2325
        var 乙: UInt64 = 0x8422_2325_cbf2_9ce4
        for 字节 in 键.utf8 {
            甲 = (甲 ^ UInt64(字节)) &* 0x0000_0100_0000_01b3
            乙 = (乙 &+ UInt64(字节)) &* 0x0000_0100_0000_01b3
        }
        let 十六 = String(format: "%016llx%016llx", 甲, 乙)
        let 字 = Array(十六)
        let 组 = [字[0..<8], 字[8..<12], 字[12..<16], 字[16..<20], 字[20..<32]]
        return UUID(uuidString: 组.map { String($0) }.joined(separator: "-")) ?? UUID()
    }

    /// 逐像素烘焙：程序算出线性色 → 编码回 sRGB。
    /// 贴图语义是 sRGB（.color），节点求值是线性，
    /// 这两次换算必须补上，否则视口和卡片会给出两种颜色。
    private static func 烘焙(_ 程序: 着色程序, 最长边: Int) -> CGImage? {
        // 底板尺寸：有源图按第一张源图的宽高比，纯程序图（棋盘格/噪波）按正方形
        let 比例: Double = {
            guard let 图 = 程序.贴图.lazy.compactMap({ 取图本原($0) }).first, 图.height > 0
            else { return 1 }
            return Double(图.width) / Double(图.height)
        }()
        var 宽 = 最长边
        var 高 = 最长边
        if 比例 >= 1 {
            高 = max(1, Int((Double(最长边) / 比例).rounded()))
        } else {
            宽 = max(1, Int((Double(最长边) * 比例).rounded()))
        }
        宽 = min(max(宽, 1), 4096)
        高 = min(max(高, 1), 4096)

        // 每张槽图各自缩到同一尺寸，程序按 uv 取谁都不会错位
        var 槽: [[UInt8]] = []
        槽.reserveCapacity(程序.贴图.count)
        for id in 程序.贴图 {
            guard let 图 = 取图本原(id), let 像素 = 取重采样(id, 图, 宽: 宽, 高: 高) else {
                槽.append([])
                continue
            }
            槽.append(像素)
        }

        let 字节数 = 宽 * 高 * 4
        let 缓冲 = UnsafeMutableRawPointer.allocate(byteCount: 字节数, alignment: 4)
        defer { 缓冲.deallocate() }
        guard let 色域 = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: 缓冲, width: 宽, height: 高, bitsPerComponent: 8,
                  bytesPerRow: 宽 * 4, space: 色域,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        let 像素 = 缓冲.bindMemory(to: UInt8.self, capacity: 字节数)
        // 逐像素是纯函数（局部栈 + 只读常量池），按行并行起步：
        // 512 档 26 万像素，单核算一次几十毫秒，M4 Max 上摊到多核就是几毫秒。
        DispatchQueue.concurrentPerform(iterations: 高) { y in
            for x in 0..<宽 {
                let i = (y * 宽 + x) * 4
                let 色 = 程序.求值(
                    u: (Double(x) + 0.5) / Double(宽),
                    v: (Double(y) + 0.5) / Double(高)
                ) { s in
                    guard s < 槽.count, 槽[s].count > i else { return PBRColor(gray: 0.5) }
                    let 源 = 槽[s]
                    let 甲字节 = 源[i + 3]
                    // 不透明图（绝大多数贴图）直接查表，省掉三次 pow
                    if 甲字节 == 255 {
                        return PBRColor(
                            线性表[Int(源[i])],
                            线性表[Int(源[i + 1])],
                            线性表[Int(源[i + 2])]
                        )
                    }
                    let 甲 = Double(甲字节) / 255
                    let 反 = 甲 > 0.002 ? 1 / 甲 : 0
                    return PBRColor(
                        线性(Double(源[i]) / 255 * 反),
                        线性(Double(源[i + 1]) / 255 * 反),
                        线性(Double(源[i + 2]) / 255 * 反)
                    )
                }
                // alpha 跟第一张源图走（贴图常带透明），纯程序图给不透明
                let 甲 = 槽.first.flatMap { $0.count > i ? Double($0[i + 3]) / 255 : nil } ?? 1
                if 甲 >= 0.999 {
                    像素[i] = 转字节(色.r)
                    像素[i + 1] = 转字节(色.g)
                    像素[i + 2] = 转字节(色.b)
                } else {
                    像素[i] = 量化(编码(色.r) * 甲)
                    像素[i + 1] = 量化(编码(色.g) * 甲)
                    像素[i + 2] = 量化(编码(色.b) * 甲)
                }
                像素[i + 3] = 量化(甲)
            }
        }
        return ctx.makeImage()
    }

    /// 把一张图重采样成 宽×高 的预乘 RGBA8 像素。
    // MARK: 重采样缓存
    /// 拖滑杆时源图不变、只有程序参数在变，但每一帧都要把源图重缩一遍。
    /// CG 高质量插值一张 1000×1000 要几毫秒，比栈机本身还贵，所以按「图 id + 尺寸」留一份。
    /// 2048 档一张就 16MB，不进缓存，只服务卡片/视口这几档。
    private static var 重采样缓存: [String: [UInt8]] = [:]
    private static var 重采样顺序: [String] = []

    private static func 取重采样(_ id: UUID, _ 图: CGImage, 宽: Int, 高: Int) -> [UInt8]? {
        guard 宽 <= 1024, 高 <= 1024 else { return 重采样(图, 宽: 宽, 高: 高) }
        let 键 = "\(id)-\(宽)x\(高)"
        锁.lock()
        if let 命中 = 重采样缓存[键] {
            锁.unlock()
            return 命中
        }
        锁.unlock()
        guard let 值 = 重采样(图, 宽: 宽, 高: 高) else { return nil }
        锁.lock()
        重采样缓存[键] = 值
        重采样顺序.append(键)
        while 重采样顺序.count > 8 {
            重采样缓存[重采样顺序.removeFirst()] = nil
        }
        锁.unlock()
        return 值
    }

    private static func 重采样(_ image: CGImage, 宽: Int, 高: Int) -> [UInt8]? {
        var 像素 = [UInt8](repeating: 0, count: 宽 * 高 * 4)
        guard let 色域 = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let 成 = 像素.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: 宽, height: 高, bitsPerComponent: 8,
                bytesPerRow: 宽 * 4, space: 色域,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: 宽, height: 高))
            return true
        }
        return 成 ? 像素 : nil
    }

    // MARK: 颜色空间查表
    ///
    /// 源像素是 8bit，进线性空间只可能是 k/255 这 256 个值；
    /// 出图那一侧同理，最终只落到 0…255 这 256 个字节。
    /// 两头各摆一张表，逐像素那六次 pow 就没了 —— 栈机开销不变，转换开销归零。
    private static let 线性表: [Double] = (0...255).map { 线性(Double($0) / 255) }

    /// 线性 → 字节。4096 级取样：步长 1/4096，量化误差到不了 1 个字节。
    private static let 字节表: [UInt8] = (0...4096).map { 量化(编码(Double($0) / 4096)) }

    private static func 转字节(_ v: Double) -> UInt8 {
        let x = v <= 0 ? 0 : (v >= 1 ? 1 : v)
        return 字节表[Int((x * 4096).rounded())]
    }

    private static func 线性(_ v: Double) -> Double {
        let c = min(max(v, 0), 1)
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    private static func 编码(_ v: Double) -> Double {
        let c = min(max(v, 0), 1)
        return c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
    }

    private static func 量化(_ v: Double) -> UInt8 {
        UInt8((min(max(v, 0), 1) * 255).rounded())
    }


    /// 视口里所有贴图的落盘字节。没有原始字节的在这里补一次 PNG 编码并写回缓存，
    /// 同一张图只编一次，之后每次保存都是白拿。
    static func 全部字节() -> [UUID: Data] {
        锁.lock()
        let 待编 = 图.filter { 字节[$0.key] == nil && 派生表[$0.key] == nil }
        锁.unlock()

        if !待编.isEmpty {
            var 补: [UUID: Data] = [:]
            for (id, image) in 待编 {
                if let data = PNG(image) { 补[id] = data }
            }
            锁.lock()
            for (id, data) in 补 where 字节[id] == nil { 字节[id] = data }
            锁.unlock()
        }

        锁.lock()
        defer { 锁.unlock() }
        // 只交还在库里的（清空/换项目之后缓存里的死图不落盘）
        return 字节.filter { 图[$0.key] != nil && 派生表[$0.key] == nil }
    }

    /// 当前项目里的全部贴图（按登记顺序）。节点卡片上的「换贴图」直接吃这份清单。
    static var 全部编号: [UUID] {
        锁.lock()
        defer { 锁.unlock() }
        return 顺序.filter { 图[$0] != nil }
    }

    /// 卡片预览用的小图（最长边 ≤ 边）。原图动辄 2K/4K，直接扔进 SwiftUI 每帧重采样，
    /// 拖动节点时手感会发飘；这里压一次就缓存住。
    static func 缩略图(_ id: UUID, 最长边: Int = 320) -> CGImage? {
        let 键 = "\(id.uuidString)-\(最长边)"
        锁.lock()
        if let 命中 = 缩略缓存[键] { 锁.unlock(); return 命中 }
        let 原图 = 图[id]
        锁.unlock()

        guard let 原图, 原图.width > 0, 原图.height > 0 else { return nil }
        let 比 = min(1.0, Double(最长边) / Double(max(原图.width, 原图.height)))
        var 小图 = 原图
        if 比 < 1 {
            let 宽 = max(1, Int(Double(原图.width) * 比))
            let 高 = max(1, Int(Double(原图.height) * 比))
            let 空间 = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            if let 画布 = CGContext(
                data: nil, width: 宽, height: 高,
                bitsPerComponent: 8, bytesPerRow: 0, space: 空间,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) {
                画布.interpolationQuality = .medium
                画布.draw(原图, in: CGRect(x: 0, y: 0, width: 宽, height: 高))
                小图 = 画布.makeImage() ?? 原图
            }
        }

        锁.lock()
        缩略缓存[键] = 小图
        锁.unlock()
        return 小图
    }

    private static func PNG(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    static func 取(_ id: UUID) -> TextureResource? {
        锁.lock()
        if let hit = 资源[id] { 锁.unlock(); return hit }
        if 失败.contains(id) { 锁.unlock(); return nil }
        let image = 图[id]
        锁.unlock()

        guard let image else { return nil }
        // 颜色类贴图按 sRGB 语义走，RealityKit 会自己转到线性
        guard let texture = try? TextureResource(
            image: image,
            withName: "导入贴图-\(id.uuidString)",
            options: .init(semantic: .color)
        ) else {
            锁.lock(); 失败.insert(id); 锁.unlock()
            return nil
        }

        锁.lock()
        资源[id] = texture
        锁.unlock()
        return texture
    }

    static func 清空() {
        锁.lock()
        图.removeAll()
        资源.removeAll()
        失败.removeAll()
        字节.removeAll()
        顺序.removeAll()
        缩略缓存.removeAll()
        派生表.removeAll()
        派生顺序.removeAll()
        大图.removeAll()
        大图档.removeAll()
        派生引用.removeAll()
        派生字节.removeAll()
        派生总字节 = 0
        _像素代际.removeAll()
        // 集合整体换掉，图集不能只看单张代际，必须整体重来
        _源图代际 += 1
        锁.unlock()
        MaterialCompiler.清除缓存()
    }

    /// 只留下给定的这些贴图。切项目时按新清单裁一遍，
    /// 让「库里的贴图」恒等于「当前工程的贴图」——
    /// 否则上一个工程的图会跟着下一次保存被一起写进新档，越滚越大。
    static func 只保留(_ ids: Set<UUID>) {
        锁.lock()
        图 = 图.filter { ids.contains($0.key) }
        资源 = 资源.filter { ids.contains($0.key) }
        字节 = 字节.filter { ids.contains($0.key) }
        失败 = 失败.filter { ids.contains($0) }
        顺序 = 顺序.filter { ids.contains($0) }
        缩略缓存 = 缩略缓存.filter { 键, _ in ids.contains { 键.hasPrefix($0.uuidString) } }
        _像素代际 = _像素代际.filter { ids.contains($0.key) }
        // 派生表按「程序用到的贴图都还在」筛：只要有一张源图被裁掉，这套程序就算不出对的像素
        派生表 = 派生表.filter { 程序 in 程序.value.贴图.allSatisfy(ids.contains) }
        大图 = 大图.filter { 派生表[$0.key] != nil }
        大图档 = 大图档.filter { 派生表[$0.key] != nil }
        实际档 = 实际档.filter { 派生表[$0.key] != nil }
        派生顺序 = 派生顺序.filter { 派生表[$0] != nil }
        var 新总字节 = 0
        for id in 派生表.keys { 新总字节 += 派生字节[id] ?? 0 }
        派生字节 = 派生字节.filter { 派生表[$0.key] != nil }
        派生总字节 = 新总字节
        派生引用 = 派生引用.filter { 派生表[$0.key] != nil }
        _源图代际 += 1
        锁.unlock()
        // 派生表裁掉之后，缓存里记着的派生 id 可能是死号，一并作废
        MaterialCompiler.清除缓存()
    }
}


// MARK: - OpenPBR → SceneKit（临时预览用）

/// 给「临时 SceneKit 预览」用的材质桥（角色窗口那种自己搭 SCNScene 的场合）。
/// 折算口径与材质球库的 `映射材质` 同一套：只求看得出是什么材质，不追求和 RealityKit 视口逐像素一致。
/// 这里额外补两件那边不需要的东西：基底色贴图、不透明度。
///
/// 性能口径：
/// - 键 = 材质内容签名 + 双面 + 贴图开关，命中直接返同一份 SCNMaterial，多件同材质共用一份；
/// - 贴图只取小档（预览窗口不到一千逻辑像素，取 2048 是白烧内存与解码时间）。
enum SCN材质桥 {

    /// 预览贴图档
    static let 预览贴图档 = 512
    /// 缓存上限：角色窗口反复开关不该无限囤材质
    private static let 上限 = 192

    private static var 缓存: [String: SCNMaterial] = [:]

    static func 做(_ resolved: ResolvedMaterial, 双面: Bool = true, 贴图: Bool = true) -> SCNMaterial {
        let 键 = 材质缩略图键.key(resolved) + "|d\(双面 ? 1 : 0)|t\(贴图 ? 1 : 0)"
        if let 命中 = 缓存[键] { return 命中 }
        let 材质 = 建(resolved, 双面: 双面, 贴图: 贴图)
        if 缓存.count >= 上限 { 缓存.removeAll(keepingCapacity: true) }
        缓存[键] = 材质
        return 材质
    }

    private static func 建(_ resolved: ResolvedMaterial, 双面: Bool, 贴图: Bool) -> SCNMaterial {
        let p = resolved.params
        let 材质 = SCNMaterial()
        材质.lightingModel = .physicallyBased
        材质.isDoubleSided = 双面

        var 基色 = p.color(.baseColor).clamped
        let 基重 = min(max(p.double(.baseWeight), 0), 1)
        if 基重 < 0.999 { 基色 = 基色.scaled(基重) }
        材质.diffuse.contents = 基色.nsColor

        let 粗糙 = min(max(p.double(.baseRoughness), 0.03), 1)
        材质.roughness.contents = NSNumber(value: 粗糙)
        材质.metalness.contents = NSNumber(value: min(max(p.double(.baseMetallic), 0), 1))

        // 发光口径与材质球库一致：亮到一定程度就把漫反射压暗，发射色按本色给满
        let 发光色 = p.color(.emissionColor).clamped
        let 发光量 = min(max(p.double(.emissionLuminance), 0), 8) / 8
        if 发光量 > 0.02 {
            let 漫反射 = 1 - min(发光量 * 1.8, 1)
            if 漫反射 < 0.999 {
                基色 = 基色.scaled(漫反射)
                材质.diffuse.contents = 基色.nsColor
            }
            let 增益 = min(0.4 + 1.2 * 发光量, 1)
            材质.emission.contents = NSColor(
                srgbRed: CGFloat(发光色.r * 增益),
                green: CGFloat(发光色.g * 增益),
                blue: CGFloat(发光色.b * 增益),
                alpha: 1
            )
        }

        // 清漆
        let 清漆 = min(max(p.double(.coatWeight), 0), 1)
        if 清漆 > 0.01 {
            材质.clearCoat.contents = NSNumber(value: 清漆)
            材质.clearCoatRoughness.contents = NSNumber(value: min(max(p.double(.coatRoughness), 0.02), 1))
        }

        // 透明：SceneKit 没有 transmission 通道，按透明度近似
        let 透射 = min(max(p.double(.transmissionWeight), 0), 1)
        let 不透明 = min(max(p.double(.geometryOpacity) * p.double(.baseAlpha), 0), 1)
        let 透明 = 不透明 * (1 - 透射 * 0.72)
        if 透明 < 0.999 {
            材质.transparency = CGFloat(透明)
            材质.blendMode = .alpha
        }

        // 基底色贴图：图里已经烘过调色，直接盖掉常量色
        if 贴图, let id = resolved.贴图[.baseColor], let 图 = 视口纹理库.取图(id, 最长边: 预览贴图档) {
            材质.diffuse.contents = 图
            材质.diffuse.wrapS = .repeat
            材质.diffuse.wrapT = .repeat
        }

        return 材质
    }
}
