import Foundation

// MARK: - 材质数据模型（PBR / OpenPBR 参数，原「材质 数据模型.swift」）

// MARK: - 线性颜色

/// OpenPBR 全线使用线性 RGB（不做 sRGB 编码），显示时才转。
struct PBRColor: Codable, Equatable, Hashable, Sendable {
    var r: Double
    var g: Double
    var b: Double

    init(_ r: Double, _ g: Double, _ b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    init(gray v: Double) {
        self.init(v, v, v)
    }

    static let black = PBRColor(0, 0, 0)
    static let white = PBRColor(1, 1, 1)

    var luminance: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }

    var clamped: PBRColor {
        PBRColor(min(max(r, 0), 1), min(max(g, 0), 1), min(max(b, 0), 1))
    }

    func scaled(_ k: Double) -> PBRColor { PBRColor(r * k, g * k, b * k) }

    func mixed(_ other: PBRColor, _ t: Double) -> PBRColor {
        let f = min(max(t, 0), 1)
        return PBRColor(r + (other.r - r) * f, g + (other.g - g) * f, b + (other.b - b) * f)
    }

    /// 色相旋转（角度制），HSL 往返一次
    func hueRotated(_ degrees: Double) -> PBRColor {
        guard degrees != 0 else { return self }
        let h = HSL.from(self)
        // 转完要归一化回 [0,1)：负角度或超一圈不取模会算出错的通道
        var 目标 = (h.h + degrees / 360).truncatingRemainder(dividingBy: 1)
        if 目标 < 0 { 目标 += 1 }
        return HSL(h: 目标, s: h.s, l: h.l).toColor()
    }

    /// 薄膜干涉近似：两束光在薄膜上下表面反射后干涉，按 R/G/B 三个采样波长算相位差。
    /// RealityKit 没有 iridescence 通道，只能把干涉色折进基底色来"看得见"薄膜厚度变化。
    static func thinFilmTint(thickness nm: Double, ior: Double) -> PBRColor {
        let d = max(nm, 1) * 1e-9
        let n = max(ior, 1.0)
        func channel(_ wavelengthNM: Double) -> Double {
            let phase = 4 * Double.pi * n * d / (wavelengthNM * 1e-9)
            return 0.5 + 0.5 * cos(phase)
        }
        return PBRColor(channel(610), channel(545), channel(465))
    }

    func saturated(_ amount: Double) -> PBRColor {
        let h = HSL.from(self)
        return HSL(h: h.h, s: min(max(h.s * amount, 0), 1), l: h.l).toColor()
    }

    /// 明度平移（-1…1，0 = 不变）：同样是 HSL 里动 l，和色相/饱和度同一套往返
    func lightened(_ delta: Double) -> PBRColor {
        guard delta != 0 else { return self }
        let h = HSL.from(self)
        return HSL(h: h.h, s: h.s, l: min(max(h.l + delta, 0), 1)).toColor()
    }
}

/// 仅用于色相/饱和度节点的往返空间，不进入渲染
struct HSL {
    var h: Double
    var s: Double
    var l: Double

    static func from(_ c: PBRColor) -> HSL {
        let maxV = max(c.r, c.g, c.b)
        let minV = min(c.r, c.g, c.b)
        let l = (maxV + minV) / 2
        guard maxV != minV else { return HSL(h: 0, s: 0, l: l) }
        let d = maxV - minV
        let s = l > 0.5 ? d / (2 - maxV - minV) : d / (maxV + minV)
        var h: Double
        switch maxV {
        case c.r: h = (c.g - c.b) / d + (c.g < c.b ? 6 : 0)
        case c.g: h = (c.b - c.r) / d + 2
        default: h = (c.r - c.g) / d + 4
        }
        h /= 6
        return HSL(h: h, s: s, l: l)
    }

    func toColor() -> PBRColor {
        guard s > 0 else { return PBRColor(gray: l) }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        func channel(_ t0: Double) -> Double {
            var t = t0
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 0.5 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }
        return PBRColor(channel(h + 1.0 / 3), channel(h), channel(h - 1.0 / 3))
    }
}

// MARK: - 参数值

/// 节点图的求值结果：标量或颜色，不做隐式强转（避免图里出现"看起来对"的错值）
enum PBRValue: Codable, Equatable, Hashable, Sendable {
    case scalar(Double)
    case color(PBRColor)

    var scalarValue: Double {
        switch self {
        case .scalar(let v): v
        case .color(let c): c.luminance
        }
    }

    var colorValue: PBRColor {
        switch self {
        case .scalar(let v): PBRColor(gray: v)
        case .color(let c): c
        }
    }
}

// MARK: - OpenPBR 层

enum PBRParamLayer: String, Codable, CaseIterable, Identifiable, Sendable {
    case base
    case specular
    case transmission
    case subsurface
    case fuzz
    case coat
    case thinFilm
    case emission
    case geometry

    var id: String { rawValue }

    var title: String {
        switch self {
        case .base: "基底"
        case .specular: "高光"
        case .transmission: "透射"
        case .subsurface: "次表面"
        case .fuzz: "绒毛"
        case .coat: "清漆"
        case .thinFilm: "薄膜"
        case .emission: "自发光"
        case .geometry: "几何"
        }
    }
}

// MARK: - 参数键

/// 直接照 OpenPBR Surface 1.0 的输入名建模：
/// 一个键 = 一个 shader input = 节点图上的一个可连插槽。
enum PBRParamKey: String, Codable, CaseIterable, Identifiable, Sendable {
    // Base
    case baseWeight = "base_weight"
    case baseColor = "base_color"
    case baseMetallic = "base_metallic"
    case baseRoughness = "base_roughness"
    case baseIOR = "base_ior"
    case baseAlpha = "base_alpha"

    // Specular
    case specularWeight = "specular_weight"
    case specularColor = "specular_color"
    case specularRoughness = "specular_roughness"
    case specularIOR = "specular_ior"
    case specularIORLevel = "specular_ior_level"
    case specularAnisotropy = "specular_anisotropy"
    case specularRotation = "specular_rotation"

    // Transmission
    case transmissionWeight = "transmission_weight"
    case transmissionColor = "transmission_color"
    case transmissionDepth = "transmission_depth"
    case transmissionScatter = "transmission_scatter"
    case transmissionScatterAnisotropy = "transmission_scatter_anisotropy"

    // Subsurface
    case subsurfaceWeight = "subsurface_weight"
    case subsurfaceColor = "subsurface_color"
    case subsurfaceRadius = "subsurface_radius"
    case subsurfaceScatterAnisotropy = "subsurface_scatter_anisotropy"

    // Fuzz
    case fuzzWeight = "fuzz_weight"
    case fuzzColor = "fuzz_color"
    case fuzzRoughness = "fuzz_roughness"

    // Coat
    case coatWeight = "coat_weight"
    case coatColor = "coat_color"
    case coatRoughness = "coat_roughness"
    case coatIOR = "coat_ior"
    case coatDarkening = "coat_darkening"

    // Thin film
    case thinFilmWeight = "thin_film_weight"
    case thinFilmThickness = "thin_film_thickness"
    case thinFilmIOR = "thin_film_ior"

    // Emission
    case emissionLuminance = "emission_luminance"
    case emissionColor = "emission_color"

    // Geometry
    case geometryOpacity = "geometry_opacity"
    /// 规范里没有这一口，是自研补的：法线图（切线空间 RGB）和高度图（灰度）都往这儿接，
    /// 用户不用先搞清楚自己手里是哪一种。口是颜色类型，图像贴图节点的颜色输出可直接进。
    case geometryNormal = "geometry_normal"

    var id: String { rawValue }

    /// 官方参数名，直接展示在检查器里，方便对照规范
    var opName: String { rawValue }

    var layer: PBRParamLayer {
        switch self {
        case .baseWeight, .baseColor, .baseMetallic, .baseRoughness, .baseIOR, .baseAlpha:
            .base
        case .specularWeight, .specularColor, .specularRoughness, .specularIOR,
             .specularIORLevel, .specularAnisotropy, .specularRotation:
            .specular
        case .transmissionWeight, .transmissionColor, .transmissionDepth,
             .transmissionScatter, .transmissionScatterAnisotropy:
            .transmission
        case .subsurfaceWeight, .subsurfaceColor, .subsurfaceRadius, .subsurfaceScatterAnisotropy:
            .subsurface
        case .fuzzWeight, .fuzzColor, .fuzzRoughness:
            .fuzz
        case .coatWeight, .coatColor, .coatRoughness, .coatIOR, .coatDarkening:
            .coat
        case .thinFilmWeight, .thinFilmThickness, .thinFilmIOR:
            .thinFilm
        case .emissionLuminance, .emissionColor:
            .emission
        case .geometryOpacity, .geometryNormal:
            .geometry
        }
    }

    var title: String {
        switch self {
        case .baseWeight: "权重"
        case .baseColor: "基础色"
        case .baseMetallic: "金属度"
        case .baseRoughness: "粗糙度"
        case .baseIOR: "折射率"
        case .baseAlpha: "透明度"
        case .specularWeight: "高光权重"
        case .specularColor: "高光色"
        case .specularRoughness: "高光粗糙度"
        case .specularIOR: "高光折射率"
        case .specularIORLevel: "折射率级别"
        case .specularAnisotropy: "高光各向异性"
        case .specularRotation: "各向异性旋转"
        case .transmissionWeight: "透射权重"
        case .transmissionColor: "透射色"
        case .transmissionDepth: "透射深度"
        case .transmissionScatter: "散射色"
        case .transmissionScatterAnisotropy: "透射散射各向异性"
        case .subsurfaceWeight: "次表面权重"
        case .subsurfaceColor: "次表面色"
        case .subsurfaceRadius: "半径缩放"
        case .subsurfaceScatterAnisotropy: "次表面散射各向异性"
        case .fuzzWeight: "绒毛权重"
        case .fuzzColor: "绒毛色"
        case .fuzzRoughness: "绒毛粗糙度"
        case .coatWeight: "清漆权重"
        case .coatColor: "清漆色"
        case .coatRoughness: "清漆粗糙度"
        case .coatIOR: "清漆折射率"
        case .coatDarkening: "暗化"
        case .thinFilmWeight: "薄膜权重"
        case .thinFilmThickness: "薄膜厚度 (nm)"
        case .thinFilmIOR: "薄膜折射率"
        case .emissionLuminance: "发光亮度"
        case .emissionColor: "自发光色"
        case .geometryOpacity: "不透明度"
        case .geometryNormal: "法线 / 高度"
        }
    }

    var isColor: Bool {
        switch self {
        case .baseColor, .specularColor, .transmissionColor, .transmissionScatter,
             .subsurfaceColor, .fuzzColor, .coatColor, .emissionColor, .geometryNormal:
            // 法线 / 高度口按颜色收：图像贴图节点吐的是颜色，灰度高度图也是颜色三通道，
            // 两种图都能直接连进来，不用再分「标量口 + 颜色口」让人猜
            true
        default:
            false
        }
    }

    var range: ClosedRange<Double> {
        switch self {
        case .thinFilmThickness: 0...2000
        case .thinFilmIOR, .coatIOR, .specularIOR: 1...3
        case .baseIOR: 1...3
        case .baseMetallic, .baseAlpha, .geometryOpacity, .specularWeight, .baseWeight,
             .transmissionWeight, .subsurfaceWeight, .fuzzWeight, .coatWeight,
             .thinFilmWeight, .specularAnisotropy, .specularIORLevel, .coatDarkening:
            0...1
        case .coatRoughness: 0...1
        case .transmissionDepth: 0...10
        case .subsurfaceRadius: 0...10
        case .emissionLuminance: 0...50
        default: 0...1
        }
    }

    var defaultValue: PBRValue {
        switch self {
        case .baseColor, .subsurfaceColor: .color(PBRColor(gray: 0.8))
        case .specularColor, .transmissionColor, .fuzzColor, .coatColor, .emissionColor:
            .color(.white)
        case .transmissionScatter: .color(.black)
        // 切线空间法线的中性值：(0.5, 0.5, 1) 就是"没扰动"；
        // 高度图没连时这个颜色也不参与计算，纯占位
        case .geometryNormal: .color(PBRColor(0.5, 0.5, 1))
        case .baseWeight, .baseAlpha, .specularWeight, .geometryOpacity, .coatDarkening:
            .scalar(1)
        case .baseRoughness, .specularRoughness: .scalar(0.3)
        case .fuzzRoughness: .scalar(0.5)
        case .baseIOR, .specularIOR: .scalar(1.5)
        case .coatIOR: .scalar(1.6)
        case .thinFilmIOR: .scalar(1.4)
        default: .scalar(0)
        }
    }
}

enum ViewportSupport: String, Codable, Sendable {
    case full
    case approx
    case none

    var title: String {
        switch self {
        case .full: "精确"
        case .approx: "近似"
        case .none: "视口未支持"
        }
    }
}

// MARK: - 参数集合

/// OpenPBR 参数块。用 key→value 字典，新增参数不需要改动求值/序列化链路。
struct OpenPBRParams: Codable, Equatable {
    var values: [PBRParamKey: PBRValue]

    init(values: [PBRParamKey: PBRValue] = PBRParamKey.defaultValues) {
        self.values = values
    }

    static var `default`: OpenPBRParams { OpenPBRParams() }

    subscript(key: PBRParamKey) -> PBRValue {
        get { values[key] ?? key.defaultValue }
        set { values[key] = newValue }
    }

    func double(_ key: PBRParamKey) -> Double { self[key].scalarValue }
    func color(_ key: PBRParamKey) -> PBRColor { self[key].colorValue }

    func merging(_ overrides: [PBRParamKey: PBRValue]) -> OpenPBRParams {
        var copy = self
        for (k, v) in overrides { copy[k] = v }
        return copy
    }

    /// 归一化后的"视觉摘要"，用于材质球缩略图与列表色块
    var previewColor: PBRColor {
        let base = color(.baseColor)
        let emission = color(.emissionColor).scaled(double(.emissionLuminance) * 0.05)
        return PBRColor(
            base.clamped.r + emission.r,
            base.clamped.g + emission.g,
            base.clamped.b + emission.b
        ).clamped
    }
}

extension PBRParamKey {
    static var defaultValues: [PBRParamKey: PBRValue] {
        var map: [PBRParamKey: PBRValue] = [:]
        for key in allCases { map[key] = key.defaultValue }
        return map
    }
}

// MARK: - 材质

/// 一份材质 = 基线参数块 + 驱动它的节点图。
/// 图里连到 Output 的参数覆盖基线，没连的用基线（OpenPBR 的"未连接即用默认值"语义）。
struct MaterialAsset: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var baseline: OpenPBRParams
    var graph: NodeGraph
    var note: String

    /// 出厂快照：这份材质刚被创建 / 预置生成那一刻的基线参数与节点图。
    ///
    /// 材质球库只按它出球 —— 把某个材质挂到物体上再调参，改的只是这份材质当前的样子，
    /// 库里展示的永远是原始样式，不会跟着参数一起变；想拿回原样右键「恢复原始样式」。
    /// 旧存档里没有这两个字段，读出来是 nil，由 着色Store 载入时补齐。
    var 出厂基线: OpenPBRParams?
    var 出厂图: NodeGraph?

    /// 出处：nil = 这就是材质库里的条目（模板本身），材质球库只列这些；
    /// 非 nil = 某条库材质被用到场景后派生出来的实例，编辑实例只改变用它的物体，
    /// 库里那一条永远是原始样式。旧存档里没有这个字段，读出来是 nil，正好全是库条目。
    var 出处: UUID?

    /// 是不是出厂自带的预设材质（内置）。
    /// 内置的删不掉、也谈不上「恢复原始样式」——它就是原样；想改就复制一份出来。
    /// 复制 / 另存出来的条目一律不算内置。旧存档没有这个字段，读出来 nil，
    /// 由 着色Store 载入时按预置名字补齐。
    var 内置: Bool?

    /// 复制自哪条库材质：副本靠它跟原件归成一组，排在原件右边。
    var 副本于: UUID?

    /// 只属于当前工程、不进材质库：导入模型（OBJ / STL / PLY / glTF / FBX / blend / MTLX）带进来的
    /// 材质归这一档 —— 它们只为这个工程服务，不该污染用户材质库。想留成模板走「另存为新材质」。
    var 仅工程: Bool?

    /// 是不是材质库里的条目（模板）
    var 是否库条目: Bool { 出处 == nil && !(仅工程 ?? false) }


    /// 是不是内置预设
    var 是内置预设: Bool { 内置 ?? false }

    init(
        id: UUID = UUID(),
        name: String,
        baseline: OpenPBRParams = .default,
        graph: NodeGraph = .empty,
        note: String = "",
        出处: UUID? = nil,
        内置: Bool = false,
        副本于: UUID? = nil,
        仅工程: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.baseline = baseline
        self.graph = graph
        self.note = note
        self.出处 = 出处
        self.内置 = 内置
        self.副本于 = 副本于
        self.仅工程 = 仅工程
        // 新建即出厂：预置材质、复制出来的材质、导入生成的材质，快照就是构造这一刻的样子
        self.出厂基线 = baseline
        self.出厂图 = graph
    }

    var previewColor: PBRColor { baseline.previewColor }

    /// 库卡片展示用的版本：套上出厂快照（没有快照的老材质退回当前值）
    var 原始样式: MaterialAsset {
        var m = self
        if let 出厂基线 { m.baseline = 出厂基线 }
        if let 出厂图 { m.graph = 出厂图 }
        return m
    }

    /// 当前参数是否已经偏离出厂样式（库卡片据此打小圆点）
    var 改动过: Bool {
        guard let 出厂基线, let 出厂图 else { return false }
        return baseline != 出厂基线 || graph != 出厂图
    }

    /// 补齐出厂快照：已经有快照的不动；缺的按传入的预置参数记账，没传就用当前值。
    mutating func 冻结出厂样式(baseline 基线: OpenPBRParams? = nil, graph 图: NodeGraph? = nil) {
        if 出厂基线 == nil { 出厂基线 = 基线 ?? baseline }
        if 出厂图 == nil { 出厂图 = 图 ?? graph }
    }

    /// 把当前参数拉回出厂样式（正在用这份材质的物体一起回到原样）
    mutating func 恢复出厂样式() {
        guard let 出厂基线 else { return }
        baseline = 出厂基线
        if let 出厂图 { graph = 出厂图 }
    }

    /// 成像外观是否一致：只比「改了就影响渲染」的内容。
    ///
    /// 特意不看的东西：节点在画布上的 position、节点/材质标题、note、出处/内置/副本关系、
    /// 出厂快照。这些纯属编辑期信息，挪个节点位置不会让画面多一个像素 ——
    /// 早先"任何写入都推进材质参数版本"，于是拖一下节点，路径追踪就判定材质变了，
    /// 场景重译 + 累积清零，画面从 1spp 重来。这里把这个口径收紧到成像字段。
    func 外观相同(_ 另: MaterialAsset) -> Bool {
        guard baseline == 另.baseline else { return false }
        guard graph.links == 另.graph.links else { return false }
        guard graph.nodes.count == 另.graph.nodes.count else { return false }
        for (甲, 乙) in zip(graph.nodes, 另.graph.nodes) {
            if 甲.id != 乙.id { return false }
            if 甲.kind != 乙.kind { return false }
            if 甲.isMuted != 乙.isMuted { return false }
            if 甲.image != 乙.image { return false }
            if 甲.params != 乙.params { return false }
        }
        return true
    }

    /// 哪些参数被节点图驱动（检查器据此打"图驱动"标记）
    var drivenKeys: Set<PBRParamKey> { graph.drivenKeys }

    func isDriven(_ key: PBRParamKey) -> Bool { drivenKeys.contains(key) }
}


// MARK: - 图像引用（材质数据的组成部分，归材质域持有）

extension NodeGraph {
    /// 节点图引用到的图像资产：从 Output 的每个颜色参数出发，沿连线反向找第一个图像贴图节点。
    ///
    /// 口径说明：这里只回答"这个参数最终喂的是哪张**图像资产**"，不跑求值、不生成纹理。
    /// 纹理 id 是派生结果（由视口纹理库按材质版本派生），材质数据里不出现它。
    var 图像引用表: [PBRParamKey: UUID] {
        guard let output = outputNode else { return [:] }
        let 上游 = Dictionary(grouping: links, by: \.toNode)
        var 表: [PBRParamKey: UUID] = [:]
        for link in links where link.toNode == output.id {
            guard let key = output.kind.inputs.first(where: { $0.id == link.toSocket })?.paramKey,
                  key.isColor,
                  let 图 = 图像(起自: link.fromNode, 上游: 上游, 走过: [])
            else { continue }
            表[key] = 图
        }
        return 表
    }

    private func 图像(起自 节点: UUID, 上游: [UUID: [NodeLink]], 走过: Set<UUID>) -> UUID? {
        guard !走过.contains(节点) else { return nil }   // 图里有环也不许递归到栈溢出
        guard let n = nodes.first(where: { $0.id == 节点 }) else { return nil }
        if n.kind == .imageTexture, let 图 = n.image { return 图 }
        let 新走过 = 走过.union([节点])
        for link in 上游[节点] ?? [] {
            if let 图 = 图像(起自: link.fromNode, 上游: 上游, 走过: 新走过) { return 图 }
        }
        return nil
    }
}

extension MaterialAsset {
    /// 这份材质引用的图像资产（归域持有的那部分"纹理/贴图引用"）。
    var 图像引用表: [PBRParamKey: UUID] { graph.图像引用表 }
}

// MARK: - 节点数据模型（节点图 / 插槽，原「节点 数据模型.swift」）

// MARK: - 插槽

enum SocketKind: String, Codable, Sendable {
    case scalar
    case color

    var title: String {
        switch self {
        case .scalar: "标量"
        case .color: "颜色"
        }
    }

    var symbol: String {
        switch self {
        case .scalar: "number"
        case .color: "paintpalette"
        }
    }

    /// 颜色插槽可以被标量驱动（灰度），反过来不行
    func accepts(_ other: SocketKind) -> Bool {
        self == other || self == .color
    }
}

struct NodeSocket: Identifiable, Hashable, Sendable {
    let id: String
    var title: String
    var kind: SocketKind
    /// 只有 Input 节点（OpenPBR Output）的输入端口带参数键，其余节点用节点自身参数
    var paramKey: PBRParamKey?

    init(_ id: String, _ title: String, _ kind: SocketKind, paramKey: PBRParamKey? = nil) {
        self.id = id
        self.title = title
        self.kind = kind
        self.paramKey = paramKey
    }
}

// MARK: - 节点类型

enum ShaderNodeKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case output
    case rgbConstant
    case valueConstant
    case checkerTexture
    case noiseTexture
    case gradientMap
    case mix
    case hueSaturation
    case remap
    case fresnel
    case bump
    case imageTexture

    var id: String { rawValue }

    var title: String {
        switch self {
        case .output: "OpenPBR 输出"
        case .rgbConstant: "颜色常量"
        case .valueConstant: "数值常量"
        case .checkerTexture: "棋盘格"
        case .noiseTexture: "噪波"
        case .gradientMap: "渐变"
        case .mix: "混合"
        case .hueSaturation: "色相/饱和度"
        case .remap: "重映射"
        case .fresnel: "菲涅尔"
        case .bump: "凹凸"
        case .imageTexture: "图像贴图"
        }
    }

    var symbol: String {
        switch self {
        case .output: "circle.hexagongrid"
        case .rgbConstant: "paintpalette"
        case .valueConstant: "number"
        case .checkerTexture: "square.grid.3x3"
        case .noiseTexture: "aqi.medium"
        case .gradientMap: "square.lefthalf.filled"
        case .mix: "circle.lefthalf.filled"
        case .hueSaturation: "eyedropper.halffull"
        case .remap: "arrow.left.and.right"
        case .fresnel: "camera.aperture"
        case .bump: "mountain.2"
        case .imageTexture: "photo"
        }
    }

    /// 节点分类，决定侧栏分组与配色
    var category: NodeCategory {
        switch self {
        case .output: .sink
        case .rgbConstant, .valueConstant: .input
        case .checkerTexture, .noiseTexture, .gradientMap, .imageTexture: .texture
        case .mix, .hueSaturation, .remap, .fresnel, .bump: .math
        }
    }

    var outputs: [NodeSocket] {
        switch self {
        case .output: []
        case .rgbConstant: [NodeSocket("out", "颜色", .color)]
        case .checkerTexture, .gradientMap, .imageTexture: [NodeSocket("out", "颜色", .color)]
        case .noiseTexture, .fresnel, .bump:
            [NodeSocket("out", "系数", .scalar), NodeSocket("outColor", "颜色", .color)]
        case .valueConstant, .remap:
            [NodeSocket("out", "数值", .scalar)]
        case .mix:
            [NodeSocket("out", "结果", .color), NodeSocket("outFac", "系数", .scalar)]
        case .hueSaturation:
            [NodeSocket("out", "颜色", .color)]
        }
    }

    var inputs: [NodeSocket] {
        switch self {
        case .output:
            // OpenPBR Output 的输入端口 = 参数键，视图直接按这个列表铺行
            NodeGraph.outputKeys.map {
                NodeSocket($0.rawValue, $0.title, $0.isColor ? .color : .scalar, paramKey: $0)
            }
        case .valueConstant:
            []
        case .rgbConstant:
            []
        case .checkerTexture:
            [NodeSocket("scale", "缩放", .scalar), NodeSocket("colorA", "颜色 A", .color),
             NodeSocket("colorB", "颜色 B", .color)]
        case .imageTexture:
            // 贴图本身已经是一组复合颜色，再往里插一个颜色口没有意义，
            // 所以图像节点没有任何输入端口：卡片里显示的是预览 + 动效下拉。
            []
        case .noiseTexture:
            [NodeSocket("scale", "缩放", .scalar), NodeSocket("detail", "细节", .scalar),
             NodeSocket("colorA", "颜色 A", .color), NodeSocket("colorB", "颜色 B", .color)]
        case .gradientMap:
            [NodeSocket("fac", "系数", .scalar), NodeSocket("colorA", "颜色 A", .color),
             NodeSocket("colorB", "颜色 B", .color)]
        case .mix:
            [NodeSocket("fac", "系数", .scalar), NodeSocket("a", "A", .color),
             NodeSocket("b", "B", .color)]
        case .hueSaturation:
            [NodeSocket("color", "颜色", .color), NodeSocket("hue", "色相", .scalar),
             NodeSocket("sat", "饱和度", .scalar), NodeSocket("light", "明度", .scalar)]
        case .remap:
            [NodeSocket("value", "数值", .scalar), NodeSocket("fromMin", "源最小", .scalar),
             NodeSocket("fromMax", "源最大", .scalar), NodeSocket("toMin", "目标最小", .scalar),
             NodeSocket("toMax", "目标最大", .scalar)]
        case .fresnel:
            [NodeSocket("ior", "折射率", .scalar), NodeSocket("bias", "偏移", .scalar)]
        case .bump:
            [NodeSocket("height", "高度", .scalar), NodeSocket("strength", "强度", .scalar)]
        }
    }

    /// 节点自身参数（端口没连线时用这里的值）
    var localDefaults: [String: PBRValue] {
        switch self {
        case .rgbConstant: ["color": .color(PBRColor(0.8, 0.8, 0.8))]
        case .valueConstant: ["value": .scalar(0.5)]
        case .checkerTexture:
            ["scale": .scalar(8), "colorA": .color(PBRColor(0.05, 0.05, 0.05)),
             "colorB": .color(PBRColor(0.85, 0.85, 0.85))]
        case .noiseTexture:
            ["scale": .scalar(6), "detail": .scalar(4),
             "colorA": .color(PBRColor(0.1, 0.1, 0.1)), "colorB": .color(.white)]
        case .gradientMap:
            ["fac": .scalar(0.5), "colorA": .color(PBRColor(0.1, 0.08, 0.06)),
             "colorB": .color(PBRColor(0.95, 0.9, 0.8))]
        case .mix: ["fac": .scalar(0.5)]
        case .hueSaturation: ["hue": .scalar(0), "sat": .scalar(1), "light": .scalar(0)]
        case .remap:
            ["fromMin": .scalar(0), "fromMax": .scalar(1), "toMin": .scalar(0), "toMax": .scalar(1)]
        case .fresnel: ["ior": .scalar(1.5), "bias": .scalar(0)]
        case .bump: ["strength": .scalar(0.4)]
        // 贴图节点的输出兜底色永远是「原色」，真正采样由视口/离线渲染器做；
        // anim 是预览动效，缺键时按 0（不动）处理
        case .imageTexture: ["tint": .color(PBRColor(1, 1, 1)), 图像动效.paramKey: .scalar(0)]
        case .output: [:]
        }
    }

    /// 节点面板宽度
    var width: CGFloat {
        switch self {
        case .output: 236
        case .fresnel, .remap: 168
        default: 150
        }
    }
}

enum NodeCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case input
    case texture
    case math
    case sink

    var id: String { rawValue }

    var title: String {
        switch self {
        case .input: "常量"
        case .texture: "程序纹理"
        case .math: "转换"
        case .sink: "输出"
        }
    }
}

// MARK: - 节点

struct ShaderNode: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var kind: ShaderNodeKind
    var title: String
    var position: CGPoint
    /// 节点自身参数，键与 `inputs` 里的 socket id 对齐
    var params: [String: PBRValue]
    var isMuted: Bool
    /// 图像贴图节点引用的贴图（纹理库 UUID）；nil 表示还没解码成功，求值时退回基色
    var image: UUID?

    init(
        id: UUID = UUID(),
        kind: ShaderNodeKind,
        title: String? = nil,
        position: CGPoint,
        params: [String: PBRValue]? = nil,
        isMuted: Bool = false,
        image: UUID? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title ?? kind.title
        self.position = position
        self.params = params ?? kind.localDefaults
        self.isMuted = isMuted
        self.image = image
    }

    var displayTitle: String { title.isEmpty ? kind.title : title }

    /// 面板高度：按端口数量推，避免视图层到处算
    func height(rowHeight: CGFloat = 22, header: CGFloat = 30, padding: CGFloat = 10) -> CGFloat {
        let rows = max(kind.inputs.count, 1)
        return header + padding * 2 + CGFloat(rows) * rowHeight
    }

    func value(for socket: String) -> PBRValue {
        params[socket] ?? kind.localDefaults[socket] ?? .scalar(0)
    }
}

// MARK: - 连线

struct NodeLink: Identifiable, Codable, Equatable, Hashable, Sendable {
    var id: UUID
    var fromNode: UUID
    var fromSocket: String
    var toNode: UUID
    var toSocket: String

    init(id: UUID = UUID(), fromNode: UUID, fromSocket: String, toNode: UUID, toSocket: String) {
        self.id = id
        self.fromNode = fromNode
        self.fromSocket = fromSocket
        self.toNode = toNode
        self.toSocket = toSocket
    }
}

// MARK: - 节点图

struct NodeGraph: Codable, Equatable {
    var nodes: [ShaderNode]
    var links: [NodeLink]

    init(nodes: [ShaderNode] = [], links: [NodeLink] = []) {
        self.nodes = nodes
        self.links = links
    }

    static var empty: NodeGraph {
        NodeGraph(nodes: [
            ShaderNode(kind: .output, position: CGPoint(x: 620, y: 120))
        ])
    }

    /// OpenPBR Output 上暴露的插槽：常用子集，按"改了能立刻在视口看出差别"排序
    static let outputKeys: [PBRParamKey] = [
        .baseColor, .baseMetallic, .baseRoughness, .baseIOR,
        .specularRoughness, .specularAnisotropy,
        .transmissionWeight, .coatWeight, .coatRoughness,
        .emissionColor, .emissionLuminance, .geometryOpacity,
        // 法线 / 高度共用一口：法线图、高度图都往这儿接，视口暂时不吃，端口先摆出来
        .geometryNormal
    ]

    var outputNode: ShaderNode? {
        nodes.first { $0.kind == .output }
    }

    /// 被图驱动的参数（Output 上有连线）
    var drivenKeys: Set<PBRParamKey> {
        var keys: Set<PBRParamKey> = []
        guard let output = outputNode else { return keys }
        for link in links where link.toNode == output.id {
            if let key = PBRParamKey(rawValue: link.toSocket) { keys.insert(key) }
        }
        return keys
    }

    func node(_ id: UUID) -> ShaderNode? { nodes.first { $0.id == id } }

    /// 某输入端口是否已有连线（一个输入只能吃一条）
    func link(into node: UUID, socket: String) -> NodeLink? {
        links.first { $0.toNode == node && $0.toSocket == socket }
    }

    mutating func setNode(_ node: ShaderNode) {
        if let index = nodes.firstIndex(where: { $0.id == node.id }) {
            nodes[index] = node
        } else {
            nodes.append(node)
        }
    }

    mutating func removeNode(_ id: UUID) {
        nodes.removeAll { $0.id == id }
        links.removeAll { $0.fromNode == id || $0.toNode == id }
    }

    /// 连线替换语义：输入端口最多一条，新连接顶掉旧的
    mutating func connect(fromNode: UUID, fromSocket: String, toNode: UUID, toSocket: String) {
        links.removeAll { $0.toNode == toNode && $0.toSocket == toSocket }
        links.append(NodeLink(fromNode: fromNode, fromSocket: fromSocket, toNode: toNode, toSocket: toSocket))
    }

    mutating func disconnect(_ linkID: UUID) {
        links.removeAll { $0.id == linkID }
    }

    /// 该参数此刻是否真被节点图驱动（输出节点上有边接进来）。
    /// 判据只能看连线本身：库条目和实例都可能有驱动边，跟「是不是模板」无关。
    func isDriven(_ key: PBRParamKey) -> Bool {
        guard let output = outputNode else { return false }
        return links.contains { $0.toNode == output.id && $0.toSocket == key.rawValue }
    }

    /// 断开输出节点上某个参数的驱动边：手调这个参数时用。
    /// 派生图是「图覆盖基线」的，不摘掉这条边，刚写进去的手调值会被盖回去，滑条看着就像拉不动。
    mutating func disconnect(to key: PBRParamKey) {
        guard let output = outputNode else { return }
        links.removeAll { $0.toNode == output.id && $0.toSocket == key.rawValue }
    }

    /// 插入新节点时自动放到一个不重叠的位置（视图中心由调用方给）
    func freePosition(near point: CGPoint, spacing: CGFloat = 24) -> CGPoint {
        var candidate = point
        var attempts = 0
        while nodes.contains(where: {
            abs($0.position.x - candidate.x) < 120 && abs($0.position.y - candidate.y) < 90
        }) && attempts < 40 {
            candidate.x += spacing
            candidate.y += spacing
            attempts += 1
        }
        return candidate
    }
}

// MARK: - 图像动效

/// 图像贴图节点预览下方那一栏下拉：给贴图本身加时间驱动的形变，
/// 让静帧在预览里真的"动起来"。值存在 `params["anim"]`（PBRValue.scalar 存 rawValue），
/// 老存档没有这个键时按「无」处理，不影响解码。
enum 图像动效: Int, CaseIterable, Identifiable, Sendable {
    case 无 = 0
    case 火焰扰动
    case 水面波动
    case 旋转
    case 漂移
    case 呼吸
    case 涟漪

    var id: Int { rawValue }

    static let paramKey = "anim"

    var title: String {
        switch self {
        case .无: "不动"
        case .火焰扰动: "火焰扰动"
        case .水面波动: "水面波动"
        case .旋转: "旋转"
        case .漂移: "漂移"
        case .呼吸: "呼吸"
        case .涟漪: "涟漪"
        }
    }

    var symbol: String {
        switch self {
        case .无: "pause"
        case .火焰扰动: "flame"
        case .水面波动: "water.waves"
        case .旋转: "arrow.triangle.2.circlepath"
        case .漂移: "wind"
        case .呼吸: "waveform.path"
        case .涟漪: "circle.dotted"
        }
    }

    /// 是否为时间驱动（决定预览要不要跑 TimelineView）
    var 有动画: Bool { self != .无 }
}

extension ShaderNode {
    /// 当前动效（读 params，缺失时按「无」）
    var 图像动效值: 图像动效 {
        let raw = Int((params[图像动效.paramKey] ?? .scalar(0)).scalarValue.rounded())
        return 图像动效(rawValue: raw) ?? .无
    }
}

// MARK: - 节点参数范围

extension ShaderNodeKind {
    /// 节点自身参数的滑杆范围。色相是「度」不是 0…1 的比例，
    /// 照 0…1 给滑杆的话整条只能转 1 度，看起来就是「拖了没反应」。
    func 参数范围(_ socket: String) -> ClosedRange<Double>? {
        switch (self, socket) {
        case (.hueSaturation, "hue"): return -180...180      // 度
        case (.hueSaturation, "sat"): return 0...2           // 倍率，1 = 原样
        case (.hueSaturation, "light"): return -1...1        // 明度平移，0 = 原样
        default: return nil
        }
    }
}
