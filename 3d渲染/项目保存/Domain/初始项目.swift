import Foundation

// MARK: - 基础场景

/// 出厂基础场景：三份 OpenPBR 材质 + 一个摆好的 shader 场景 + 默认渲染队列。
///
/// 新建项目与冷启动都从这里构造。它只描述「从零」的样子 ——
/// 不携带任何用户历史（导入几何、绘画、上次机位、上次路径），
/// 也不该被当成「重置」的素材：构造路径是新文档的唯一来源。
enum 初始项目 {

    // MARK: 场景

    /// 初始材质库：新建项目时这些材质**全部**落进 App，成为 App 内的实际数据。
    /// 它们不是「点了才生成」的模板 —— 材质面板里能直接选中、编辑、指派。
    /// 全部标成内置预设：库里排在自定义材质前面，只能复制、不能删。
    static func materials() -> [MaterialAsset] {
        ([ceramicMaterial(), brushedMetalMaterial(), thinFilmGlassMaterial()] + 其余初始材质())
            .map { 材质 in
                var 预设 = 材质
                预设.内置 = true
                预设.副本于 = nil
                return 预设
            }
    }

    /// 预置材质的出厂参数表（按名字索引）。
    /// 给旧存档补出厂快照用：老工程里的材质可能已经被调过，靠名字回到预置的原始参数。
    static func 预置快照表() -> [String: (baseline: OpenPBRParams, graph: NodeGraph)] {
        var 表: [String: (baseline: OpenPBRParams, graph: NodeGraph)] = [:]
        for m in materials() where 表[m.name] == nil {
            表[m.name] = (m.baseline, m.graph)
        }
        return 表
    }

    static func objects(materialIDs: [UUID]) -> [SceneObject] {
        let ceramic = materialIDs[safe: 0]
        let metal = materialIDs[safe: 1]
        let glass = materialIDs[safe: 2]

        return [
            SceneObject(name: "着色球", mesh: .shaderBall, 导入网格ID: 存入(着色球几何()),
                        position: Vec3(0, 1.05, 0), scale: Vec3.uniform(1.0),
                        materialID: ceramic),
            SceneObject(name: "金属圆环", mesh: .torus,
                        导入网格ID: 存入([("金属圆环", PTGeometry.torus(ring: 0.85, pipe: 0.3))]),
                        position: Vec3(-2.1, 1.0, 0.3), rotation: Vec3(68, 0, 18),
                        scale: Vec3.uniform(0.62), materialID: metal),
            SceneObject(name: "玻璃球", mesh: .sphere,
                        导入网格ID: 存入([("玻璃球", PTGeometry.sphere(radius: 0.9))]),
                        position: Vec3(2.15, 1.0, 0.25), scale: Vec3.uniform(0.72),
                        materialID: glass),
        ]
    }

    // MARK: 出厂几何

    /// 出厂场景的模型几何。
    ///
    /// 这里只是**新建瞬间的初始数据**：写进 导入网格库（App 内存里的几何池）之后，
    /// 视口、路径追踪、保存、空格预览读的都是池里那份真实几何。
    /// 之后在 App 里怎么编辑都在内存里改，任何一端都不会再回读本文件里的尺寸。
    private static func 存入(_ 部件们: [(名称: String, 片: PTGeometry.Piece)]) -> UUID {
        let 网格们 = 部件们.map { 部件 -> 导入网格 in
            var 网格 = 导入网格(名称: 部件.名称)
            网格.顶点 = 部件.片.positions
            网格.法线 = 部件.片.normals
            网格.UV = 部件.片.uvs
            网格.索引 = 部件.片.indices
            return 网格
        }
        return 几何接线.共享.存入(网格们)
    }

    /// 着色球：主球 + 底座 + 凹槽环 + 方台
    private static func 着色球几何() -> [(名称: String, 片: PTGeometry.Piece)] {
        var 球 = PTGeometry.sphere(radius: 0.86)
        PTGeometry.translate(&球, y: 0.98)
        var 底座 = PTGeometry.cylinder(height: 0.16, radius: 0.62)
        PTGeometry.translate(&底座, y: 0.08)
        var 凹槽 = PTGeometry.torus(ring: 0.46, pipe: 0.055)
        PTGeometry.translate(&凹槽, y: 0.17)
        let 方台 = PTGeometry.box(size: SIMD3<Float>(1.35, 0.16, 1.35))
        return [("主球", 球), ("底座", 底座), ("凹槽", 凹槽), ("方台", 方台)]
    }

    // MARK: 1. 陶瓷：Noise → Base Color，Fresnel → Coat Weight

    static func ceramicMaterial() -> MaterialAsset {
        let outputID = UUID()
        let noiseID = UUID()
        let gradientID = UUID()
        let fresnelID = UUID()
        let remapID = UUID()

        let output = ShaderNode(id: outputID, kind: .output, position: CGPoint(x: 700, y: 120))
        let noise = ShaderNode(
            id: noiseID, kind: .noiseTexture, title: "噪波 · 陶土",
            position: CGPoint(x: 60, y: 60),
            params: [
                "scale": .scalar(5.5), "detail": .scalar(3.5),
                "colorA": .color(PBRColor(0.72, 0.42, 0.30)),
                "colorB": .color(PBRColor(0.88, 0.72, 0.58))
            ]
        )
        let gradient = ShaderNode(
            id: gradientID, kind: .gradientMap, title: "渐变 · 色调",
            position: CGPoint(x: 300, y: 40),
            params: [
                "fac": .scalar(0.55),
                "colorA": .color(PBRColor(0.86, 0.71, 0.58)),
                "colorB": .color(PBRColor(0.72, 0.40, 0.28))
            ]
        )
        let fresnel = ShaderNode(
            id: fresnelID, kind: .fresnel, title: "菲涅尔",
            position: CGPoint(x: 300, y: 250),
            params: ["ior": .scalar(1.5), "bias": .scalar(0.1)]
        )
        let remap = ShaderNode(
            id: remapID, kind: .remap, title: "重映射 · 清漆",
            position: CGPoint(x: 500, y: 250),
            params: [
                "fromMin": .scalar(0), "fromMax": .scalar(1),
                "toMin": .scalar(0.15), "toMax": .scalar(0.75)
            ]
        )

        var graph = NodeGraph(
            nodes: [noise, gradient, fresnel, remap, output],
            links: [
                NodeLink(fromNode: noiseID, fromSocket: "outColor", toNode: gradientID, toSocket: "fac"),
                NodeLink(fromNode: gradientID, fromSocket: "out", toNode: outputID, toSocket: PBRParamKey.baseColor.rawValue),
                NodeLink(fromNode: fresnelID, fromSocket: "out", toNode: remapID, toSocket: "value"),
                NodeLink(fromNode: remapID, fromSocket: "out", toNode: outputID, toSocket: PBRParamKey.coatWeight.rawValue)
            ]
        )
        graph.setNode(output)

        var baseline = OpenPBRParams()
        baseline[.baseRoughness] = .scalar(0.38)
        baseline[.baseMetallic] = .scalar(0)
        baseline[.specularRoughness] = .scalar(0.32)
        baseline[.coatRoughness] = .scalar(0.12)
        baseline[.coatIOR] = .scalar(1.55)

        return MaterialAsset(
            name: "陶土",
            baseline: baseline,
            graph: graph,
            note: "噪波调色 → 基础色；菲涅尔经重映射 → 清漆权重（边缘清漆加厚）。"
        )
    }

    // MARK: 2. 拉丝金属：Checker → Roughness，Anisotropy 走基线

    static func brushedMetalMaterial() -> MaterialAsset {
        let outputID = UUID()
        let checkerID = UUID()
        let remapID = UUID()
        let rgbID = UUID()

        let output = ShaderNode(id: outputID, kind: .output, position: CGPoint(x: 700, y: 120))
        let checker = ShaderNode(
            id: checkerID, kind: .checkerTexture, title: "棋盘格 · 拉丝",
            position: CGPoint(x: 60, y: 80),
            params: [
                "scale": .scalar(48),
                "colorA": .color(PBRColor(0, 0, 0)),
                "colorB": .color(PBRColor(1, 1, 1))
            ]
        )
        let remap = ShaderNode(
            id: remapID, kind: .remap, title: "重映射 · 粗糙度",
            position: CGPoint(x: 320, y: 60),
            params: [
                "fromMin": .scalar(0), "fromMax": .scalar(1),
                "toMin": .scalar(0.16), "toMax": .scalar(0.34)
            ]
        )
        let rgb = ShaderNode(
            id: rgbID, kind: .rgbConstant, title: "铝",
            position: CGPoint(x: 60, y: 300),
            params: ["color": .color(PBRColor(0.91, 0.92, 0.94))]
        )

        var graph = NodeGraph(
            nodes: [checker, remap, rgb, output],
            links: [
                NodeLink(fromNode: checkerID, fromSocket: "out", toNode: remapID, toSocket: "value"),
                NodeLink(fromNode: remapID, fromSocket: "out", toNode: outputID, toSocket: PBRParamKey.baseRoughness.rawValue),
                NodeLink(fromNode: rgbID, fromSocket: "out", toNode: outputID, toSocket: PBRParamKey.baseColor.rawValue)
            ]
        )
        graph.setNode(output)

        var baseline = OpenPBRParams()
        baseline[.baseMetallic] = .scalar(1.0)
        baseline[.specularRoughness] = .scalar(0.22)
        baseline[.specularAnisotropy] = .scalar(0.6)
        baseline[.specularIORLevel] = .scalar(0.85)

        return MaterialAsset(
            name: "拉丝铝",
            baseline: baseline,
            graph: graph,
            note: "棋盘格高频 → 粗糙度做拉丝起伏；各向异性由基线给定，视口不表达。"
        )
    }

    // MARK: 3. 薄膜玻璃

    static func thinFilmGlassMaterial() -> MaterialAsset {
        let outputID = UUID()
        let gradientID = UUID()
        let hueID = UUID()

        let output = ShaderNode(id: outputID, kind: .output, position: CGPoint(x: 700, y: 120))
        let gradient = ShaderNode(
            id: gradientID, kind: .gradientMap, title: "渐变 · 着色",
            position: CGPoint(x: 60, y: 120),
            params: [
                "fac": .scalar(0.35),
                "colorA": .color(PBRColor(0.86, 0.94, 0.98)),
                "colorB": .color(PBRColor(0.55, 0.78, 0.86))
            ]
        )
        let hue = ShaderNode(
            id: hueID, kind: .hueSaturation, title: "色相偏移",
            position: CGPoint(x: 330, y: 120),
            params: ["hue": .scalar(8), "sat": .scalar(1.1)]
        )

        var graph = NodeGraph(
            nodes: [gradient, hue, output],
            links: [
                NodeLink(fromNode: gradientID, fromSocket: "out", toNode: hueID, toSocket: "color"),
                NodeLink(fromNode: hueID, fromSocket: "out", toNode: outputID, toSocket: PBRParamKey.baseColor.rawValue),
                NodeLink(fromNode: hueID, fromSocket: "out", toNode: outputID, toSocket: PBRParamKey.emissionColor.rawValue)
            ]
        )
        graph.setNode(output)

        var baseline = OpenPBRParams()
        baseline[.baseRoughness] = .scalar(0.02)
        baseline[.transmissionWeight] = .scalar(0.92)
        baseline[.transmissionDepth] = .scalar(0.6)
        baseline[.transmissionColor] = .color(PBRColor(0.92, 0.98, 1.0))
        baseline[.thinFilmWeight] = .scalar(0.85)
        baseline[.thinFilmThickness] = .scalar(420)
        baseline[.thinFilmIOR] = .scalar(1.42)
        baseline[.coatWeight] = .scalar(0.2)
        baseline[.coatRoughness] = .scalar(0.05)
        baseline[.emissionLuminance] = .scalar(0.25)

        return MaterialAsset(
            name: "薄膜玻璃",
            baseline: baseline,
            graph: graph,
            note: "薄膜厚度 420nm 走基线；视口不计算薄膜干涉，仅近似为透明 + 自发光。"
        )
    }

    // MARK: 渲染历史

    static func renderJobs() -> [RenderJob] {
        [
            RenderJob(label: "陶土 · 主视角",
                      createdAt: .now.addingTimeInterval(-3600 * 5),
                      state: .done, progress: 1, width: 1920, height: 1080, seconds: 74),
            RenderJob(label: "拉丝铝 · 环视",
                      createdAt: .now.addingTimeInterval(-3600 * 2),
                      state: .done, progress: 1, width: 2560, height: 1440, seconds: 168),
            RenderJob(label: "薄膜玻璃 · 主光",
                      createdAt: .now.addingTimeInterval(-600),
                      state: .idle, progress: 0, width: 1920, height: 1080)
        ]
    }
}

// MARK: - 初始内容预设

/// 一个可加进场景的初始对象。
///
/// `部件` 只描述**生成方式**：点下的那一刻用 PTGeometry 造出顶点/法线/UV/索引，
/// 全部写进 导入网格库（App 内存里的几何池），场景里只留一个带 `导入网格ID` 的 SceneObject。
/// 之后视口、路径追踪、保存、空格预览读的都是池里那份真实几何 —— 没有第二份尺寸常量。
struct 内容预设: Identifiable {
    let id: String
    let 名称: String
    /// 面板里没用上（面板画的是线稿缩略图），留着给需要图标的别处
    let 符号: String
    /// 默认挂的初始材质名（初始材质库里都有）
    let 材质名: String
    let 部件: () -> [(名称: String, 片: PTGeometry.Piece)]
    /// 添加面板里的分组标题；同组的排在同一栏下面
    var 分类: String = "基础网格"
    /// 生成时额外抬高的米数：灯光要挂在半空，网格贴地
    var 悬空: Double = 0
    /// 非 nil 表示这个预设造出来的是「灯」：不生成几何，只作为光源
    var 灯光: 灯光设置? = nil
}

extension 初始项目 {

    /// 视口「添加初始对象」下拉菜单的全部条目。
    ///
    /// 只有前三件套会随出厂场景直接摆进场景（它们已经是实际几何）；
    /// 其余条目都只在这里躺着，**点一次才**当场程序生成成真实物体。
    static var 内容预设们: [内容预设] {
        [
            // MARK: 基础网格（程序生成的模板，点一次造一个实例）
            内容预设(id: "立方体", 名称: "立方体", 符号: "cube", 材质名: "磨砂塑料",
                  部件: { [("立方体", PTGeometry.box(size: SIMD3<Float>(1.4, 1.4, 1.4)))] }),
            内容预设(id: "方台", 名称: "方台", 符号: "square.stack.3d.down.right", 材质名: "磨砂塑料",
                  部件: { [("方台", PTGeometry.box(size: SIMD3<Float>(2.4, 0.16, 2.4)))] }),
            内容预设(id: "圆球", 名称: "圆球", 符号: "circle.fill", 材质名: "黑色橡胶",
                  部件: { [("圆球", PTGeometry.sphere(radius: 0.75))] }),
            内容预设(id: "圆柱", 名称: "圆柱", 符号: "cylinder", 材质名: "抛光黄铜",
                  部件: { [("圆柱", PTGeometry.cylinder(height: 1.6, radius: 0.5))] }),
            内容预设(id: "圆锥", 名称: "圆锥", 符号: "triangle", 材质名: "磨砂塑料",
                  部件: { [("圆锥", PTGeometry.cone(radius: 0.7, height: 1.6))] }),
            内容预设(id: "胶囊", 名称: "胶囊", 符号: "capsule", 材质名: "哑光黑塑料",
                  部件: { [("胶囊", PTGeometry.capsule(radius: 0.42, height: 1.8))] }),
            内容预设(id: "半球", 名称: "半球", 符号: "circle.bottomhalf.filled", 材质名: "亚光白塑料",
                  部件: { [("半球", PTGeometry.hemisphere(radius: 0.85))] }),
            内容预设(id: "棱柱", 名称: "棱柱", 符号: "hexagon", 材质名: "抛光黄铜",
                  部件: { [("棱柱", PTGeometry.cylinder(height: 1.5, radius: 0.62, segments: 8))] }),
            内容预设(id: "圆盘", 名称: "圆盘", 符号: "circle.dotted", 材质名: "黑板漆",
                  部件: { [("圆盘", PTGeometry.cylinder(height: 0.09, radius: 0.92))] }),
            内容预设(id: "圆环", 名称: "圆环", 符号: "circle.hexagonpath", 材质名: "磨砂玻璃",
                  部件: { [("圆环", PTGeometry.torus(ring: 0.8, pipe: 0.18))] }),
            内容预设(id: "平面", 名称: "平面", 符号: "square", 材质名: "磨砂塑料",
                  部件: { [("平面", PTGeometry.plane(width: 3, depth: 3))] }),
            内容预设(id: "台阶", 名称: "台阶", 符号: "stairs", 材质名: "亚光白塑料",
                  部件: {
                       var 一 = PTGeometry.box(size: SIMD3<Float>(0.6, 0.24, 1.4))
                       PTGeometry.translate(&一, x: -0.6, y: 0.12)
                       var 二 = PTGeometry.box(size: SIMD3<Float>(0.6, 0.48, 1.4))
                       PTGeometry.translate(&二, y: 0.24)
                       var 三 = PTGeometry.box(size: SIMD3<Float>(0.6, 0.72, 1.4))
                       PTGeometry.translate(&三, x: 0.6, y: 0.36)
                       return [("第一级", 一), ("第二级", 二), ("第三级", 三)]
                   }),
             // 材质测试球原班人马，现在同属基础网格
            内容预设(id: "着色球", 名称: "着色球", 符号: "circle.hexagongrid", 材质名: "陶土",
                  部件: { 着色球几何() }),
            内容预设(id: "金属圆环", 名称: "金属圆环", 符号: "circle.dashed", 材质名: "拉丝铝",
                  部件: { [("金属圆环", PTGeometry.torus(ring: 0.85, pipe: 0.3))] }),
            内容预设(id: "玻璃球", 名称: "玻璃球", 符号: "circle.circle", 材质名: "薄膜玻璃",
                  部件: { [("玻璃球", PTGeometry.sphere(radius: 0.9))] }),
            内容预设(id: "霓虹球", 名称: "霓虹球", 符号: "lightbulb", 材质名: "霓虹发光",
                  部件: { [("霓虹球", PTGeometry.sphere(radius: 0.62))] }),

            // MARK: 灯光（DCC 语义的灯：不生成几何，直接作为光源参与照明）
            内容预设(id: "面光板", 名称: "面光", 符号: "rectangle.fill", 材质名: "柔光板",
                  部件: { [] },
                  分类: "灯光", 悬空: 3.2,
                  灯光: 灯光设置(种类: .区域光, 功率: 320, 色温: 5600, 宽: 2.4, 高: 2.4)),
            内容预设(id: "条形灯", 名称: "条形灯", 符号: "rectangle.expand.vertical", 材质名: "冷白灯管",
                  部件: { [] },
                  分类: "灯光", 悬空: 3.0,
                  灯光: 灯光设置(种类: .区域光, 功率: 240, 色温: 6500, 宽: 3.2, 高: 0.24)),
            内容预设(id: "环形灯", 名称: "环形灯", 符号: "circle.hexagonpath.fill", 材质名: "柔光板",
                  部件: { [] },
                  分类: "灯光", 悬空: 3.0,
                  灯光: 灯光设置(种类: .区域光, 功率: 180, 色温: 5000, 宽: 1.7, 高: 1.7)),
            内容预设(id: "球灯", 名称: "球灯", 符号: "lightbulb.fill", 材质名: "暖钨丝",
                  部件: { [] },
                  分类: "灯光", 悬空: 2.8,
                  灯光: 灯光设置(种类: .点光, 功率: 80, 色温: 3000, 半径: 0.25)),
            内容预设(id: "筒灯", 名称: "筒灯", 符号: "light.recessed", 材质名: "暖钨丝",
                  部件: { [] },
                  分类: "灯光", 悬空: 3.2,
                  灯光: 灯光设置(种类: .聚光, 功率: 120, 色温: 2900, 半径: 0.18, 锥角: 32, 柔和: 0.35)),
            内容预设(id: "霓虹灯柱", 名称: "霓虹灯柱", 符号: "light.max", 材质名: "霓虹粉",
                  部件: { [] },
                  分类: "灯光", 悬空: 2.0,
                  灯光: 灯光设置(种类: .区域光, 功率: 90, 色温: 4200, 宽: 0.16, 高: 2.2)),
        ]
    }

    /// 添加面板里各栏的顺序：网格在前、灯光在后，面板按这个顺序分栏
    static var 分类们: [String] {
        let 固定 = ["基础网格", "灯光"]
        var 其余: [String] = []
        for 预设 in 内容预设们 where !固定.contains(预设.分类) && !其余.contains(预设.分类) {
            其余.append(预设.分类)
        }
        return 固定 + 其余
    }

    /// 网格库面板点某个基础形状时，用它对应的预设 —— 生成方式与下拉菜单、出厂三件套完全一致
    static func 预设(for mesh: MeshKind) -> 内容预设? {
        let 名: String
        switch mesh {
        case .shaderBall: 名 = "着色球"
        case .sphere: 名 = "圆球"
        case .cube: 名 = "立方体"
        case .torus: 名 = "圆环"
        case .cylinder: 名 = "圆柱"
        case .plane: 名 = "平面"
        }
        return 内容预设们.first { $0.id == 名 }
    }

    /// 把一个预设**当场**生成成真实物体：程序造几何 → 存进 导入网格库 → 返回带 导入网格ID 的 SceneObject。
    /// 摆放：底面对齐地面、沿 X 摆在已有物体右侧（用池里的包围球量，不猜尺寸），名字自动去重。
    @MainActor
    static func 造物体(_ 预设: 内容预设, 材质们: [MaterialAsset], 已有: [SceneObject]) -> SceneObject {
        // 灯：不造几何，直接是一个带灯光参数的场景对象
        if let 灯光 = 预设.灯光 {
            let 右缘 = 已有.map { Float($0.position.x) }.max() ?? 0
            let x = 已有.isEmpty ? 0 : 右缘 + 0.9
            return SceneObject(
                name: 唯一名(预设.名称, 已有: 已有),
                mesh: .cube,                 // 占位：灯不渲染网格
                导入符号: 预设.符号,
                position: Vec3(Double(x), 预设.悬空, 0),
                灯光: 灯光
            )
        }

        let 网格ID = 存入(预设.部件())
        let 球 = 几何接线.共享.局部包围球(网格ID)
        let 中心 = 球?.中心 ?? SIMD3<Float>(repeating: 0)
        let 半径 = 球?.半径 ?? 1

        let 右缘 = 已有.compactMap { o -> Float? in
            if let id = o.导入网格ID, let s = 几何接线.共享.局部包围球(id) {
                return Float(o.position.x) + s.半径 * abs(Float(o.scale.x))
            }
            return Float(o.position.x)
        }.max() ?? 0
        let x = 已有.isEmpty ? 0 : 右缘 + 半径 * 1.4

        return SceneObject(
            name: 唯一名(预设.名称, 已有: 已有),
            mesh: .cube,                 // 占位：真实几何在网格库里
            导入网格ID: 网格ID,
            导入符号: 预设.符号,
            position: Vec3(Double(x), Double(-中心.y) + 预设.悬空, 0),
            materialID: 材质们.first { $0.name == 预设.材质名 }?.id ?? 材质们.first?.id
        )
    }

    private static func 唯一名(_ 基: String, 已有 objects: [SceneObject]) -> String {
        let 已有名 = Set(objects.map(\.name))
        guard 已有名.contains(基) else { return 基 }
        var i = 2
        while 已有名.contains("\(基) \(i)") { i += 1 }
        return "\(基) \(i)"
    }

    // MARK: 其余初始材质（全部进 App，进来就是实际数据）

    /// 除三件套之外的初始材质：同样是完整 OpenPBR 基线 + 节点图，
    /// 材质面板里能直接改、能指派给任意物体，不是写死的观感常量。
    static func 其余初始材质() -> [MaterialAsset] {
        [
            // MARK: 通用塑料 / 涂层
            单色材质(名称: "磨砂塑料", 色: PBRColor(0.84, 0.85, 0.88),
                 粗糙度: 0.55, 金属度: 0,
                 备注: "颜色常量 → 基础色；基线给中高粗糙度，视口里就是哑光塑料。"),
            单色材质(名称: "哑光黑塑料", 色: PBRColor(0.03, 0.03, 0.035),
                 粗糙度: 0.90, 金属度: 0,
                 备注: "深色 + 极高粗糙度，完全不反光的哑光工程塑料。"),
            单色材质(名称: "亚光白塑料", 色: PBRColor(0.90, 0.90, 0.89),
                 粗糙度: 0.85, 金属度: 0,
                 备注: "高粗糙度把高光散开，白而不刺眼。"),
            单色材质(名称: "黑色橡胶", 色: PBRColor(0.07, 0.07, 0.08),
                 粗糙度: 0.78, 金属度: 0,
                 备注: "深色常量 → 基础色；高粗糙度近似橡胶。"),
            单色材质(名称: "白色硅胶", 色: PBRColor(0.86, 0.86, 0.84),
                 粗糙度: 0.68, 金属度: 0,
                 次表面权重: 0.25,
                 备注: "中高粗糙 + 少量次表面，软胶的轻微透光感。"),
            单色材质(名称: "红色车漆", 色: PBRColor(0.58, 0.03, 0.05),
                 粗糙度: 0.22, 金属度: 0.35,
                 涂层权重: 1.0, 涂层粗糙度: 0.02,
                 备注: "带金属片的基色 + 一层光滑清漆，车漆标准双层。"),
            单色材质(名称: "透明清漆黑", 色: PBRColor(0.02, 0.02, 0.025),
                 粗糙度: 0.30, 金属度: 0,
                 涂层权重: 1.0, 涂层粗糙度: 0.01,
                 备注: "哑光黑底 + 镜面清漆层，钢琴烤漆。"),
            单色材质(名称: "亚克力白", 色: PBRColor(0.93, 0.95, 0.96),
                 粗糙度: 0.02, 金属度: 0,
                 透射权重: 0.92, 折射率: 1.49,
                 备注: "近零粗糙的透射体，折射率 1.49 对应 PMMA。"),
            单色材质(名称: "黑板漆", 色: PBRColor(0.06, 0.07, 0.07),
                 粗糙度: 0.55, 金属度: 0,
                 备注: "低亮度 + 中等粗糙，粉笔黑板面。"),

            // MARK: 金属
            单色材质(名称: "抛光黄铜", 色: PBRColor(0.95, 0.76, 0.42),
                 粗糙度: 0.12, 金属度: 1,
                 备注: "颜色常量 → 基础色；全金属 + 低粗糙度，反射靠环境撑。"),
            单色材质(名称: "抛光黄金", 色: PBRColor(0.99, 0.84, 0.34),
                 粗糙度: 0.07, 金属度: 1,
                 备注: "全金属极低粗糙，暖金色反射。"),
            单色材质(名称: "镜面银", 色: PBRColor(0.97, 0.97, 0.96),
                 粗糙度: 0.02, 金属度: 1,
                 备注: "近镜面的全金属，几乎只反映环境。"),
            单色材质(名称: "铬", 色: PBRColor(0.90, 0.91, 0.93),
                 粗糙度: 0.04, 金属度: 1,
                 备注: "冷调全金属，比银更偏蓝灰。"),
            单色材质(名称: "钛金属", 色: PBRColor(0.62, 0.64, 0.68),
                 粗糙度: 0.18, 金属度: 1,
                 各向异性: 0.40,
                 备注: "各向异性拉出方向性高光，接近拉丝钛板。"),
            单色材质(名称: "玫瑰金", 色: PBRColor(0.97, 0.72, 0.66),
                 粗糙度: 0.13, 金属度: 1,
                 备注: "金里掺铜的粉调金属，低粗糙度镜面。"),
            单色材质(名称: "红铜", 色: PBRColor(0.94, 0.55, 0.40),
                 粗糙度: 0.16, 金属度: 1,
                 备注: "纯铜本色，暖橙反射。"),
            单色材质(名称: "紫铜旧化", 色: PBRColor(0.66, 0.34, 0.24),
                 粗糙度: 0.42, 金属度: 0.85,
                 备注: "金属度略降 + 粗糙度提升，模拟氧化发暗的旧铜。"),
            单色材质(名称: "青铜", 色: PBRColor(0.80, 0.58, 0.30),
                 粗糙度: 0.35, 金属度: 0.90,
                 备注: "偏黄的合金金属，粗糙度中等带一点哑光。"),
            单色材质(名称: "铜绿（氧化青铜）", 色: PBRColor(0.26, 0.52, 0.44),
                 粗糙度: 0.62, 金属度: 0.20,
                 备注: "金属度压到 0.2，蓝绿锈层盖住金属反射。"),
            单色材质(名称: "铸铁", 色: PBRColor(0.15, 0.15, 0.16),
                 粗糙度: 0.66, 金属度: 0.85,
                 备注: "高粗糙金属，粗糙表面把高光散成大光斑。"),
            单色材质(名称: "黑化钢", 色: PBRColor(0.05, 0.05, 0.06),
                 粗糙度: 0.30, 金属度: 1,
                 备注: "全金属但基色极暗，只剩反射轮廓。"),
            单色材质(名称: "枪铁色", 色: PBRColor(0.20, 0.21, 0.23),
                 粗糙度: 0.28, 金属度: 1,
                 备注: "偏蓝灰的暗金属，枪械表面。"),
            单色材质(名称: "生锈铁", 色: PBRColor(0.45, 0.23, 0.10),
                 粗糙度: 0.85, 金属度: 0.25,
                 备注: "锈层是粗糙非金属，金属度大幅下调。"),
            单色材质(名称: "铝箔", 色: PBRColor(0.92, 0.93, 0.94),
                 粗糙度: 0.09, 金属度: 1,
                 备注: "薄金属箔的强反射，粗糙度略高于镜面银。"),
            单色材质(名称: "拉丝紫金", 色: PBRColor(0.72, 0.52, 0.62),
                 粗糙度: 0.22, 金属度: 1,
                 各向异性: 0.65,
                 备注: "强各向异性把高光拉成一条线，装饰金属板。"),

            // MARK: 玉石 / 宝石
            单色材质(名称: "羊脂白玉", 色: PBRColor(0.93, 0.91, 0.85),
                 粗糙度: 0.16, 金属度: 0,
                 透射权重: 0.45, 透射色: PBRColor(0.95, 0.93, 0.87),
                 折射率: 1.62, 次表面权重: 0.70,
                 次表面色: PBRColor(0.96, 0.94, 0.88),
                 备注: "透射 + 次表面双管齐下，蜡质半透的温润玉感。"),
            单色材质(名称: "翡翠", 色: PBRColor(0.10, 0.56, 0.30),
                 粗糙度: 0.12, 金属度: 0,
                 透射权重: 0.50, 透射色: PBRColor(0.14, 0.62, 0.34),
                 折射率: 1.66, 次表面权重: 0.75,
                 备注: "高次表面权重让绿色从内部透出来，不靠表面反射。"),
            单色材质(名称: "和田青玉", 色: PBRColor(0.38, 0.52, 0.42),
                 粗糙度: 0.22, 金属度: 0,
                 透射权重: 0.35, 折射率: 1.62, 次表面权重: 0.60,
                 备注: "偏灰青的软玉，透射比白玉低一档。"),
            单色材质(名称: "墨玉", 色: PBRColor(0.06, 0.07, 0.07),
                 粗糙度: 0.20, 金属度: 0,
                 透射权重: 0.25, 折射率: 1.62, 次表面权重: 0.40,
                 备注: "极暗基色但保留透射与次表面，黑而不死。"),
            单色材质(名称: "粉晶", 色: PBRColor(0.94, 0.62, 0.66),
                 粗糙度: 0.10, 金属度: 0,
                 透射权重: 0.60, 折射率: 1.55, 次表面权重: 0.50,
                 备注: "粉调低粗糙晶体，透射带雾感。"),
            单色材质(名称: "玛瑙红", 色: PBRColor(0.62, 0.16, 0.10),
                 粗糙度: 0.10, 金属度: 0,
                 透射权重: 0.35, 折射率: 1.54, 次表面权重: 0.30,
                 备注: "半透的红棕，条带感留给贴图，这里只定材质基调。"),
            单色材质(名称: "青金石", 色: PBRColor(0.10, 0.17, 0.46),
                 粗糙度: 0.28, 金属度: 0.10,
                 备注: "深蓝不透，极低金属度给一点颗粒光泽。"),
            单色材质(名称: "绿松石", 色: PBRColor(0.20, 0.62, 0.60),
                 粗糙度: 0.32, 金属度: 0,
                 备注: "不透明的青绿，中等粗糙接近抛光石面。"),
            单色材质(名称: "孔雀石", 色: PBRColor(0.10, 0.45, 0.30),
                 粗糙度: 0.30, 金属度: 0,
                 备注: "饱和绿松石系石头，纹路靠贴图叠加。"),
            单色材质(名称: "虎眼石", 色: PBRColor(0.62, 0.40, 0.14),
                 粗糙度: 0.22, 金属度: 0.15,
                 各向异性: 0.60,
                 备注: "各向异性模拟纤维状猫眼效应。"),
            单色材质(名称: "紫水晶", 色: PBRColor(0.44, 0.24, 0.72),
                 粗糙度: 0.04, 金属度: 0,
                 透射权重: 0.88, 折射率: 1.54,
                 备注: "高透射 + 极低粗糙，石英族紫色宝石。"),
            单色材质(名称: "红宝石", 色: PBRColor(0.66, 0.05, 0.10),
                 粗糙度: 0.03, 金属度: 0,
                 透射权重: 0.90, 折射率: 1.77,
                 备注: "刚玉折射率 1.77，彩色宝石的强折射。"),
            单色材质(名称: "蓝宝石", 色: PBRColor(0.04, 0.17, 0.62),
                 粗糙度: 0.03, 金属度: 0,
                 透射权重: 0.90, 折射率: 1.77,
                 备注: "与红宝石同折射率，仅基色不同。"),
            单色材质(名称: "祖母绿", 色: PBRColor(0.03, 0.55, 0.30),
                 粗糙度: 0.04, 金属度: 0,
                 透射权重: 0.85, 折射率: 1.58,
                 备注: "绿柱石折射率约 1.58，冷绿高透。"),
            单色材质(名称: "钻石", 色: PBRColor(0.96, 0.97, 0.98),
                 粗糙度: 0.00, 金属度: 0,
                 透射权重: 1.00, 折射率: 2.42,
                 备注: "折射率 2.42 是钻石的灵魂，粗糙度归零。"),
            单色材质(名称: "黄水晶", 色: PBRColor(0.95, 0.70, 0.18),
                 粗糙度: 0.04, 金属度: 0,
                 透射权重: 0.85, 折射率: 1.55,
                 备注: "暖黄透明石英，折射率同紫水晶。"),
            单色材质(名称: "托帕石", 色: PBRColor(0.95, 0.78, 0.35),
                 粗糙度: 0.05, 金属度: 0,
                 透射权重: 0.85, 折射率: 1.62,
                 备注: "比黄水晶折射略高，蜜糖色调。"),
            单色材质(名称: "萤石", 色: PBRColor(0.55, 0.42, 0.88),
                 粗糙度: 0.06, 金属度: 0, 自发光亮度: 0.45,
                 透射权重: 0.80, 折射率: 1.43,
                 备注: "极低折射率 + 微弱自发光，紫蓝荧光石。"),
            单色材质(名称: "琥珀", 色: PBRColor(0.90, 0.50, 0.10),
                 粗糙度: 0.10, 金属度: 0,
                 透射权重: 0.72, 折射率: 1.55, 次表面权重: 0.30,
                 备注: "树脂类透射体，暖橙且内部有散射。"),
            单色材质(名称: "黑曜石", 色: PBRColor(0.03, 0.03, 0.04),
                 粗糙度: 0.06, 金属度: 0,
                 折射率: 1.48,
                 备注: "火山玻璃：不设透射，靠极低粗糙度做镜面黑。"),
            单色材质(名称: "欧泊", 色: PBRColor(0.90, 0.88, 0.86),
                 粗糙度: 0.08, 金属度: 0,
                 透射权重: 0.40, 薄膜权重: 1.0, 膜厚: 450,
                 备注: "薄膜干涉给变彩，厚度决定彩虹色相。"),
            单色材质(名称: "月光石", 色: PBRColor(0.85, 0.88, 0.92),
                 粗糙度: 0.06, 金属度: 0,
                 透射权重: 0.50, 薄膜权重: 0.80, 膜厚: 380,
                 备注: "冷白半透 + 淡蓝乳光。"),
            单色材质(名称: "珍珠母贝", 色: PBRColor(0.92, 0.90, 0.88),
                 粗糙度: 0.06, 金属度: 0.15,
                 薄膜权重: 1.0, 膜厚: 500,
                 备注: "薄膜干涉 + 少量金属度，贝壳珠光层。"),
            单色材质(名称: "天河石", 色: PBRColor(0.30, 0.68, 0.62),
                 粗糙度: 0.20, 金属度: 0,
                 次表面权重: 0.30,
                 备注: "蓝绿不透明石，微弱次表面让边缘泛白。"),
            单色材质(名称: "碧玺粉", 色: PBRColor(0.86, 0.30, 0.48),
                 粗糙度: 0.06, 金属度: 0,
                 透射权重: 0.82, 折射率: 1.62,
                 备注: "电气石高透粉红，折射率 1.62。"),

            // MARK: 石材 / 建筑
            单色材质(名称: "大理石白", 色: PBRColor(0.92, 0.91, 0.88),
                 粗糙度: 0.26, 金属度: 0,
                 次表面权重: 0.25,
                 备注: "抛光石面 + 少量次表面，白石的温润感。"),
            单色材质(名称: "黑金大理石", 色: PBRColor(0.10, 0.10, 0.11),
                 粗糙度: 0.22, 金属度: 0,
                 备注: "深色抛光石，金线交给贴图。"),
            单色材质(名称: "花岗岩", 色: PBRColor(0.52, 0.50, 0.48),
                 粗糙度: 0.68, 金属度: 0,
                 备注: "中灰高粗糙，颗粒感靠噪波贴图。"),
            单色材质(名称: "石灰岩", 色: PBRColor(0.82, 0.79, 0.72),
                 粗糙度: 0.78, 金属度: 0,
                 备注: "偏暖的浅色石材，粗糙度高。"),
            单色材质(名称: "砂岩", 色: PBRColor(0.76, 0.62, 0.44),
                 粗糙度: 0.82, 金属度: 0,
                 备注: "沙黄粗颗粒，几乎无镜面高光。"),
            单色材质(名称: "玄武岩", 色: PBRColor(0.14, 0.14, 0.15),
                 粗糙度: 0.86, 金属度: 0,
                 备注: "深灰火山岩，全漫反射。"),
            单色材质(名称: "混凝土", 色: PBRColor(0.55, 0.55, 0.54),
                 粗糙度: 0.85, 金属度: 0,
                 备注: "中性灰清水混凝土。"),
            单色材质(名称: "沥青", 色: PBRColor(0.06, 0.06, 0.07),
                 粗糙度: 0.88, 金属度: 0,
                 备注: "深黑粗糙路面。"),
            单色材质(名称: "石膏", 色: PBRColor(0.95, 0.94, 0.92),
                 粗糙度: 0.90, 金属度: 0,
                 备注: "高反照率 + 极高粗糙度，纯白漫反射。"),
            单色材质(名称: "粉笔", 色: PBRColor(0.97, 0.96, 0.94),
                 粗糙度: 0.92, 金属度: 0,
                 备注: "比石膏更干更粉的质感。"),
            单色材质(名称: "陶土砖", 色: PBRColor(0.70, 0.36, 0.24),
                 粗糙度: 0.75, 金属度: 0,
                 备注: "红陶砖面，粗糙无光。"),
            单色材质(名称: "青石板", 色: PBRColor(0.34, 0.37, 0.36),
                 粗糙度: 0.80, 金属度: 0,
                 备注: "冷灰石板，户外铺装。"),

            // MARK: 有机物 / 晶体冰蜡
            单色材质(名称: "象牙", 色: PBRColor(0.94, 0.90, 0.76),
                 粗糙度: 0.32, 金属度: 0,
                 次表面权重: 0.45,
                 备注: "暖白半透，次表面做出象牙的层次。"),
            单色材质(名称: "骨瓷", 色: PBRColor(0.97, 0.96, 0.93),
                 粗糙度: 0.05, 金属度: 0,
                 透射权重: 0.18, 涂层权重: 1.0, 涂层粗糙度: 0.04,
                 备注: "釉面清漆 + 少量透射，薄胎瓷的透光。"),
            单色材质(名称: "石蜡", 色: PBRColor(0.96, 0.93, 0.82),
                 粗糙度: 0.22, 金属度: 0,
                 透射权重: 0.55, 折射率: 1.44, 次表面权重: 0.70,
                 备注: "蜡的透射 + 高次表面，软糯的半透。"),
            单色材质(名称: "冰", 色: PBRColor(0.90, 0.95, 1.00),
                 粗糙度: 0.04, 金属度: 0,
                 透射权重: 0.95, 折射率: 1.31,
                 备注: "冰的折射率只有 1.31，比玻璃弱一截。"),
            单色材质(名称: "积雪", 色: PBRColor(0.97, 0.97, 0.98),
                 粗糙度: 0.62, 金属度: 0,
                 次表面权重: 0.55,
                 备注: "高反照率 + 次表面，雪堆的柔和过渡。"),
            单色材质(名称: "肥皂泡", 色: PBRColor(0.95, 0.95, 0.95),
                 粗糙度: 0.02, 金属度: 0,
                 透射权重: 0.90, 折射率: 1.33, 薄膜权重: 1.0, 膜厚: 320,
                 备注: "超薄膜干涉，彩虹色完全由膜厚驱动。"),
            单色材质(名称: "蜂蜜", 色: PBRColor(0.78, 0.44, 0.06),
                 粗糙度: 0.06, 金属度: 0,
                 透射权重: 0.80, 折射率: 1.50,
                 备注: "高透暖棕，浓度靠透射深度控制。"),

            // MARK: 织物 / 毛绒
            单色材质(名称: "天鹅绒酒红", 色: PBRColor(0.30, 0.04, 0.16),
                 粗糙度: 0.55, 金属度: 0,
                 绒毛权重: 1.00, 绒毛色: PBRColor(0.55, 0.08, 0.22), 绒毛粗糙度: 0.60,
                 备注: "高绒毛权重做边缘绒光，天鹅绒的关键。"),
            单色材质(名称: "麂皮驼色", 色: PBRColor(0.55, 0.42, 0.30),
                 粗糙度: 0.72, 金属度: 0,
                 绒毛权重: 0.80, 绒毛色: PBRColor(0.68, 0.55, 0.42),
                 备注: "中高绒毛 + 高粗糙，翻毛皮的哑光绒面。"),
            单色材质(名称: "毛毡灰", 色: PBRColor(0.70, 0.70, 0.68),
                 粗糙度: 0.85, 金属度: 0,
                 绒毛权重: 0.90, 绒毛色: PBRColor(0.80, 0.80, 0.78),
                 备注: "极高粗糙 + 强绒毛，压实羊毛。"),
            单色材质(名称: "丝绸绛红", 色: PBRColor(0.72, 0.12, 0.28),
                 粗糙度: 0.16, 金属度: 0,
                 绒毛权重: 0.25, 绒毛色: PBRColor(0.90, 0.40, 0.50),
                 各向异性: 0.60,
                 备注: "低粗糙 + 各向异性，丝面的那条纵向高光。"),
            单色材质(名称: "皮革深棕", 色: PBRColor(0.26, 0.15, 0.09),
                 粗糙度: 0.62, 金属度: 0,
                 绒毛权重: 0.20,
                 备注: "中等粗糙 + 少量绒毛，磨砂皮革。"),
            单色材质(名称: "帆布", 色: PBRColor(0.78, 0.74, 0.62),
                 粗糙度: 0.88, 金属度: 0,
                 绒毛权重: 0.40,
                 备注: "粗织布，粗糙度接近上限。"),
            单色材质(名称: "尼龙黑", 色: PBRColor(0.10, 0.10, 0.11),
                 粗糙度: 0.45, 金属度: 0,
                 绒毛权重: 0.30,
                 备注: "合成纤维，比棉布略光滑。"),

            // MARK: 木材 / 天然纹理材
            单色材质(名称: "胡桃木", 色: PBRColor(0.30, 0.19, 0.11),
                 粗糙度: 0.52, 金属度: 0,
                 各向异性: 0.30,
                 备注: "各向异性轻微拉出木纹方向的高光。"),
            单色材质(名称: "橡木", 色: PBRColor(0.60, 0.44, 0.26),
                 粗糙度: 0.55, 金属度: 0,
                 备注: "浅暖木色，中等粗糙。"),
            单色材质(名称: "松木", 色: PBRColor(0.80, 0.64, 0.42),
                 粗糙度: 0.60, 金属度: 0,
                 备注: "偏黄的软木，反照率高。"),
            单色材质(名称: "乌木", 色: PBRColor(0.07, 0.05, 0.05),
                 粗糙度: 0.35, 金属度: 0,
                 备注: "极暗硬木，抛光后带一点润泽。"),
            单色材质(名称: "竹青", 色: PBRColor(0.62, 0.66, 0.36),
                 粗糙度: 0.45, 金属度: 0,
                 涂层权重: 0.60, 涂层粗糙度: 0.10,
                 备注: "竹表层的蜡质清漆，偏黄绿。"),
            单色材质(名称: "软木", 色: PBRColor(0.64, 0.46, 0.28),
                 粗糙度: 0.82, 金属度: 0,
                 绒毛权重: 0.25,
                 备注: "多孔疏松，极高粗糙 + 轻微绒毛。"),
            单色材质(名称: "焦炭", 色: PBRColor(0.04, 0.04, 0.04),
                 粗糙度: 0.92, 金属度: 0,
                 备注: "几乎纯黑的强漫反射体。"),

            // MARK: 次表面散射（皮肤 / 蜡 / 有机物）
            单色材质(名称: "皮肤（白皙）", 色: PBRColor(0.87, 0.70, 0.60),
                 粗糙度: 0.46, 金属度: 0,
                 次表面权重: 0.85, 次表面色: PBRColor(0.95, 0.42, 0.34),
                 次表面半径: 3.2, 次表面散射各向异性: 0.30,
                 涂层权重: 0.18, 涂层粗糙度: 0.30,
                 备注: "次表面权重 + 偏红的次表面色 + 3.2 半径：光从皮下散出来，耳廓鼻翼才透红；薄涂层当皮肤油光。"),
            单色材质(名称: "皮肤（小麦）", 色: PBRColor(0.70, 0.50, 0.36),
                 粗糙度: 0.48, 金属度: 0,
                 次表面权重: 0.80, 次表面色: PBRColor(0.88, 0.34, 0.24),
                 次表面半径: 2.8, 次表面散射各向异性: 0.30,
                 涂层权重: 0.15, 涂层粗糙度: 0.32,
                 备注: "基底偏黄，次表面色仍留红，交界处才不显脏。"),
            单色材质(名称: "皮肤（深棕）", 色: PBRColor(0.33, 0.22, 0.17),
                 粗糙度: 0.52, 金属度: 0,
                 次表面权重: 0.70, 次表面色: PBRColor(0.62, 0.20, 0.14),
                 次表面半径: 2.2, 次表面散射各向异性: 0.25,
                 涂层权重: 0.12, 涂层粗糙度: 0.34,
                 备注: "深肤色次表面权重收一点、半径收小，避免整体发灰发光。"),
            单色材质(名称: "白蜡烛", 色: PBRColor(0.94, 0.91, 0.84),
                 粗糙度: 0.42, 金属度: 0,
                 透射权重: 0.16, 透射色: PBRColor(1.00, 0.82, 0.52), 透射深度: 0.70,
                 次表面权重: 0.90, 次表面色: PBRColor(0.99, 0.76, 0.46),
                 次表面半径: 2.4, 次表面散射各向异性: 0.35,
                 备注: "蜡是强次表面 + 弱透射：光在壁里走一段才出，靠透射色吃出暖黄芯。"),
            单色材质(名称: "红蜡烛", 色: PBRColor(0.74, 0.12, 0.10),
                 粗糙度: 0.40, 金属度: 0,
                 透射权重: 0.18, 透射色: PBRColor(0.95, 0.20, 0.14), 透射深度: 0.55,
                 次表面权重: 0.85, 次表面色: PBRColor(0.98, 0.30, 0.18),
                 次表面半径: 2.0, 次表面散射各向异性: 0.35,
                 备注: "深度比白蜡更小 → 吸收更重，薄壁透红、厚处仍饱和。"),
            单色材质(名称: "蜂蜡", 色: PBRColor(0.88, 0.68, 0.26),
                 粗糙度: 0.38, 金属度: 0,
                 透射权重: 0.14, 透射色: PBRColor(1.00, 0.74, 0.30), 透射深度: 0.80,
                 次表面权重: 0.82, 次表面色: PBRColor(1.00, 0.66, 0.20),
                 次表面半径: 2.6, 次表面散射各向异性: 0.30,
                 备注: "天然蜡的黄+半透，适合蜡烛块与蜂巢。"),
            单色材质(名称: "牛奶", 色: PBRColor(0.95, 0.94, 0.90),
                 粗糙度: 0.34, 金属度: 0,
                 透射权重: 0.10, 透射色: PBRColor(0.98, 0.95, 0.90), 透射深度: 1.50,
                 次表面权重: 0.95, 次表面色: PBRColor(0.99, 0.96, 0.90),
                 次表面半径: 4.0, 次表面散射各向异性: 0.40,
                 透射散射色: PBRColor(0.85, 0.82, 0.78),
                 备注: "强次表面 + 大半径 = 乳浊液：亮处发白、暗部带一点暖，散射色把透射搅浑。"),
            单色材质(名称: "果冻（草莓）", 色: PBRColor(0.93, 0.32, 0.40),
                 粗糙度: 0.16, 金属度: 0,
                 透射权重: 0.38, 透射色: PBRColor(1.00, 0.48, 0.52), 透射深度: 1.40,
                 次表面权重: 0.65, 次表面色: PBRColor(1.00, 0.35, 0.42),
                 次表面半径: 2.6,
                 透射散射色: PBRColor(0.45, 0.10, 0.12),
                 备注: "低粗糙 + 中透射 + 淡散射：像胶体，边缘透亮但整体不透明。"),
            单色材质(名称: "肥皂", 色: PBRColor(0.93, 0.88, 0.72),
                 粗糙度: 0.28, 金属度: 0,
                 透射权重: 0.30, 透射色: PBRColor(0.95, 0.90, 0.76), 透射深度: 1.80,
                 次表面权重: 0.60, 次表面色: PBRColor(0.97, 0.92, 0.78),
                 次表面半径: 2.2,
                 备注: "和石蜡的区别在粗糙度更低、透射深度更大：光走得更远，看着更润。"),
            单色材质(名称: "乳白玻璃", 色: PBRColor(0.92, 0.94, 0.93),
                 粗糙度: 0.22, 金属度: 0,
                 透射权重: 0.55, 透射色: PBRColor(0.94, 0.96, 0.95), 透射深度: 2.50,
                 次表面权重: 0.55, 次表面色: PBRColor(0.95, 0.96, 0.95),
                 次表面半径: 2.0,
                 透射散射色: PBRColor(0.80, 0.84, 0.84), 透射散射各向异性: 0.20,
                 备注: "高透射被散射一搅就成了乳浊：亮而不透字，典型灯罩质感。"),
            单色材质(名称: "西柚果肉", 色: PBRColor(0.94, 0.48, 0.34),
                 粗糙度: 0.30, 金属度: 0,
                 透射权重: 0.28, 透射色: PBRColor(1.00, 0.55, 0.36), 透射深度: 1.20,
                 次表面权重: 0.88, 次表面色: PBRColor(1.00, 0.42, 0.26),
                 次表面半径: 3.0, 次表面散射各向异性: 0.30,
                 透射散射色: PBRColor(0.90, 0.35, 0.20),
                 备注: "果肉纤维感靠强次表面 + 中等半径，反弹光里带橙红。"),
            单色材质(名称: "棉花糖", 色: PBRColor(0.96, 0.94, 0.97),
                 粗糙度: 0.55, 金属度: 0,
                 次表面权重: 0.75, 次表面色: PBRColor(0.99, 0.90, 0.95),
                 次表面半径: 5.0, 次表面散射各向异性: 0.50,
                 绒毛权重: 0.35, 绒毛色: PBRColor(0.99, 0.93, 0.97), 绒毛粗糙度: 0.60,
                 备注: "超大半径的次表面 + 绒毛，光在绒毛层里反复散，边缘发糊。"),

            // MARK: 自发光
            单色材质(名称: "霓虹发光", 色: PBRColor(0.16, 0.95, 0.95),
                 粗糙度: 0.3, 金属度: 0, 自发光亮度: 4,
                 备注: "同一个颜色常量同时连基础色与自发光色；发光亮度走基线。"),
            单色材质(名称: "霓虹粉", 色: PBRColor(0.98, 0.25, 0.72),
                 粗糙度: 0.30, 金属度: 0, 自发光亮度: 3.0,
                 备注: "品红霓虹管，亮度略低于青色款。"),
            单色材质(名称: "荧光绿", 色: PBRColor(0.35, 0.98, 0.42),
                 粗糙度: 0.30, 金属度: 0, 自发光亮度: 2.5,
                 备注: "高饱和绿自发光，适合做指示灯。"),
            单色材质(名称: "暖钨丝", 色: PBRColor(1.00, 0.72, 0.35),
                 粗糙度: 0.35, 金属度: 0, 自发光亮度: 6.0,
                 备注: "亮度拉到 6，暖橙白炽灯色温。"),
            单色材质(名称: "柔光板", 色: PBRColor(1.00, 0.97, 0.92),
                 粗糙度: 0.60, 金属度: 0, 自发光亮度: 8.0,
                 备注: "中性暖白面光，亮度 8；发光面越大，落在物体上的照度越均匀。"),
            单色材质(名称: "冷白灯管", 色: PBRColor(0.86, 0.93, 1.00),
                 粗糙度: 0.50, 金属度: 0, 自发光亮度: 7.0,
                 备注: "偏蓝白的灯管色，长条发光体打侧光更容易看清轮廓。"),
            单色材质(名称: "夜光涂料", 色: PBRColor(0.55, 0.95, 0.62),
                 粗糙度: 0.60, 金属度: 0, 自发光亮度: 0.9,
                 备注: "弱自发光 + 高粗糙，蓄光涂层的低压发光。"),
            磨砂玻璃材质(),
        ]
    }

    /// 单色材质：一个颜色常量同时喂基础色（自发光时也喂自发光色），
    /// 其余数值全部走基线；靠可选参数拼出金属、宝石玉石、石材、织物、清漆等各类预设。
    /// 参数顺序：名称 / 色 / 粗糙度 / 金属度 / 自发光亮度 / 透射权重 / 透射色 / 透射深度 /
    /// 折射率 / 次表面权重 / 次表面色 / 涂层权重 / 涂层粗糙度 / 绒毛权重 / 绒毛色 /
    /// 绒毛粗糙度 / 各向异性 / 薄膜权重 / 膜厚 / 备注
    private static func 单色材质(
        名称: String,
        色: PBRColor,
        粗糙度: Double,
        金属度: Double,
        自发光亮度: Double = 0,
        透射权重: Double = 0,
        透射色: PBRColor? = nil,
        透射深度: Double = 0.4,
        折射率: Double? = nil,
        次表面权重: Double = 0,
        次表面色: PBRColor? = nil,
        次表面半径: Double? = nil,
        次表面散射各向异性: Double? = nil,
        透射散射色: PBRColor? = nil,
        透射散射各向异性: Double? = nil,
        高光级别: Double? = nil,
        高光色: PBRColor? = nil,
        涂层权重: Double? = nil,
        涂层粗糙度: Double? = nil,
        绒毛权重: Double = 0,
        绒毛色: PBRColor? = nil,
        绒毛粗糙度: Double = 0.5,
        各向异性: Double? = nil,
        薄膜权重: Double? = nil,
        膜厚: Double? = nil,
        备注: String
    ) -> MaterialAsset {
        let outputID = UUID()
        let rgbID = UUID()

        let output = ShaderNode(id: outputID, kind: .output, position: CGPoint(x: 540, y: 120))
        let rgb = ShaderNode(
            id: rgbID, kind: .rgbConstant, title: "颜色 · \(名称)",
            position: CGPoint(x: 160, y: 90),
            params: ["color": .color(色)]
        )

        var links = [
            NodeLink(fromNode: rgbID, fromSocket: "out", toNode: outputID,
                     toSocket: PBRParamKey.baseColor.rawValue)
        ]
        if 自发光亮度 > 0 {
            links.append(NodeLink(fromNode: rgbID, fromSocket: "out", toNode: outputID,
                                  toSocket: PBRParamKey.emissionColor.rawValue))
        }

        var graph = NodeGraph(nodes: [rgb, output], links: links)
        graph.setNode(output)

        var baseline = OpenPBRParams()
        baseline[.baseRoughness] = .scalar(粗糙度)
        baseline[.baseMetallic] = .scalar(金属度)
        baseline[.specularRoughness] = .scalar(粗糙度)
        if 自发光亮度 > 0 {
            baseline[.emissionLuminance] = .scalar(自发光亮度)
        }
        if let 折射率 {
            baseline[.baseIOR] = .scalar(折射率)
            baseline[.specularIOR] = .scalar(折射率)
        }
        if 透射权重 > 0 {
            baseline[.transmissionWeight] = .scalar(透射权重)
            baseline[.transmissionColor] = .color(透射色 ?? 色)
            baseline[.transmissionDepth] = .scalar(透射深度)
            if let 透射散射色 { baseline[.transmissionScatter] = .color(透射散射色) }
            if let 透射散射各向异性 { baseline[.transmissionScatterAnisotropy] = .scalar(透射散射各向异性) }
        }
        if 次表面权重 > 0 {
            baseline[.subsurfaceWeight] = .scalar(次表面权重)
            baseline[.subsurfaceColor] = .color(次表面色 ?? 色)
            if let 次表面半径 { baseline[.subsurfaceRadius] = .scalar(次表面半径) }
            if let 次表面散射各向异性 { baseline[.subsurfaceScatterAnisotropy] = .scalar(次表面散射各向异性) }
        }
        if let 高光级别 { baseline[.specularIORLevel] = .scalar(高光级别) }
        if let 高光色 { baseline[.specularColor] = .color(高光色) }
        if let 涂层权重 {
            baseline[.coatWeight] = .scalar(涂层权重)
            baseline[.coatRoughness] = .scalar(涂层粗糙度 ?? 0.05)
        }
        if 绒毛权重 > 0 {
            baseline[.fuzzWeight] = .scalar(绒毛权重)
            baseline[.fuzzColor] = .color(绒毛色 ?? 色)
            baseline[.fuzzRoughness] = .scalar(绒毛粗糙度)
        }
        if let 各向异性 {
            baseline[.specularAnisotropy] = .scalar(各向异性)
        }
        if let 膜厚 {
            baseline[.thinFilmWeight] = .scalar(薄膜权重 ?? 1)
            baseline[.thinFilmThickness] = .scalar(膜厚)
        }

        return MaterialAsset(name: 名称, baseline: baseline, graph: graph, note: 备注)
    }

    /// 磨砂玻璃：噪波 → 粗糙度起伏，透射走基线
    private static func 磨砂玻璃材质() -> MaterialAsset {
        let outputID = UUID()
        let noiseID = UUID()
        let remapID = UUID()

        let output = ShaderNode(id: outputID, kind: .output, position: CGPoint(x: 700, y: 120))
        let noise = ShaderNode(
            id: noiseID, kind: .noiseTexture, title: "噪波 · 磨砂",
            position: CGPoint(x: 60, y: 60),
            params: [
                "scale": .scalar(14), "detail": .scalar(2),
                "colorA": .color(PBRColor(0.35, 0.38, 0.40)),
                "colorB": .color(PBRColor(0.62, 0.66, 0.70))
            ]
        )
        let remap = ShaderNode(
            id: remapID, kind: .remap, title: "重映射 · 粗糙度",
            position: CGPoint(x: 360, y: 60),
            params: [
                "fromMin": .scalar(0), "fromMax": .scalar(1),
                "toMin": .scalar(0.26), "toMax": .scalar(0.50)
            ]
        )

        var graph = NodeGraph(
            nodes: [noise, remap, output],
            links: [
                NodeLink(fromNode: noiseID, fromSocket: "outColor", toNode: remapID, toSocket: "fac"),
                NodeLink(fromNode: remapID, fromSocket: "out", toNode: outputID,
                         toSocket: PBRParamKey.baseRoughness.rawValue)
            ]
        )
        graph.setNode(output)

        var baseline = OpenPBRParams()
        baseline[.baseRoughness] = .scalar(0.36)
        baseline[.baseColor] = .color(PBRColor(0.86, 0.92, 0.94))
        baseline[.transmissionWeight] = .scalar(0.90)
        baseline[.transmissionColor] = .color(PBRColor(0.88, 0.95, 0.97))
        baseline[.transmissionDepth] = .scalar(0.4)
        baseline[.coatRoughness] = .scalar(0.2)

        return MaterialAsset(
            name: "磨砂玻璃",
            baseline: baseline,
            graph: graph,
            note: "噪波经重映射 → 粗糙度；透射权重走基线，视口按透明近似。"
        )
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
