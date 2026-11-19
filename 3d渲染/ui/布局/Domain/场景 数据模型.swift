import Foundation

// MARK: - 向量

struct Vec3: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var z: Double

    init(_ x: Double, _ y: Double, _ z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    static let zero = Vec3(0, 0, 0)
    static let one = Vec3(1, 1, 1)

    static func uniform(_ v: Double) -> Vec3 { Vec3(v, v, v) }
}

// MARK: - 网格

enum MeshKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case shaderBall
    case sphere
    case cube
    case torus
    case cylinder
    case plane

    var id: String { rawValue }

    var title: String {
        switch self {
        case .shaderBall: "Shader Ball"
        case .sphere: "球体"
        case .cube: "立方体"
        case .torus: "环面"
        case .cylinder: "圆柱"
        case .plane: "平面"
        }
    }

    var symbol: String {
        switch self {
        case .shaderBall: "circle.hexagongrid.fill"
        case .sphere: "circle.fill"
        case .cube: "cube.fill"
        case .torus: "circle.dashed"
        case .cylinder: "cylinder.fill"
        case .plane: "square.fill"
        }
    }
}

// MARK: - 灯光

/// DCC 语义的灯：独立对象、有物理参数，不是"发光的网格"
enum 灯光种类: String, Codable, CaseIterable, Identifiable, Sendable {
    case 区域光
    case 点光
    case 聚光
    case 平行光

    var id: String { rawValue }

    var title: String {
        switch self {
        case .区域光: return "区域光"
        case .点光:   return "点光"
        case .聚光:   return "聚光"
        case .平行光: return "平行光"
        }
    }

    var symbol: String {
        switch self {
        case .区域光: return "rectangle.fill"
        case .点光:   return "lightbulb.fill"
        case .聚光:   return "flashlight.on.fill"
        case .平行光: return "sun.max.fill"
        }
    }
}

/// 灯的参数：功率按瓦、色温按开尔文，跟 Blender / Cycles 的口径对齐
struct 灯光设置: Codable, Equatable, Sendable {
    var 种类: 灯光种类 = .区域光
    var 启用: Bool = true
    /// 瓦数。区域光按辐亮度、点/聚光按立体角强度换算，平行光按辐照度换算
    var 功率: Double = 200
    /// 色温（K），6500 附近为白，越低越暖
    var 色温: Double = 5600
    /// 区域光的高宽（米）
    var 宽: Double = 2.0
    var 高: Double = 2.0
    /// 点光 / 聚光的发光球半径，0 = 理想点
    var 半径: Double = 0.1
    /// 聚光锥半角（度）
    var 锥角: Double = 35
    /// 聚光边缘柔和度 0~1
    var 柔和: Double = 0.3

    var 符号: String { 种类.symbol }
}

// MARK: - 层级

/// 一个节点挂在谁下面：可能是另一个物体（父子变换层级），
/// 也可能是一个集合（文件夹）。两者在大纲里是同一棵树。
enum 父引用: Codable, Hashable, Sendable {
    case 对象(UUID)
    case 集合(UUID)

    var 对象ID: UUID? {
        if case .对象(let id) = self { return id }
        return nil
    }

    var 集合ID: UUID? {
        if case .集合(let id) = self { return id }
        return nil
    }
}

/// 集合（文件夹）：只做组织，本身不带变换 —— 与 Blender 的 Collection 同语义。
/// 需要"有变换的容器"时用物体做父级，不要给集合加变换。
struct 场景集合: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    /// 上级集合；nil 表示根级
    var parentID: UUID?
    var isVisible: Bool
    /// 大纲里是否展开
    var 展开: Bool

    init(
        id: UUID = UUID(),
        name: String,
        parentID: UUID? = nil,
        isVisible: Bool = true,
        展开: Bool = true
    ) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.isVisible = isVisible
        self.展开 = 展开
    }
}

// MARK: - 场景物体

struct SceneObject: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    private(set) var mesh: MeshKind
    /// 非 nil 表示这个物体用外部导入的网格（几何存在 导入网格库 里）。
    /// mesh 只留作占位符号与旧存档兼容，真实几何一律以这里为准。
    private(set) var 导入网格ID: UUID? = nil
    /// 导入来源的格式图标（sf symbol）；nil 走 mesh.symbol
    private(set) var 导入符号: String? = nil
    var position: Vec3
    /// 欧拉角（度）
    var rotation: Vec3
    var scale: Vec3
    var materialID: UUID?
    /// 每个材质槽引用的材质 ID（按槽序，只存引用不复制材质）。
    /// 没写过的槽一律回落到 materialID；导入网格带材质名时还可回落到库里同名材质，
    /// 所以这里存 nil / 缺项都表示"按回落规则来"，不是丢材质。
    var 材质槽引用: [UUID]? = nil

    /// 这个对象实际引用的**全部材质槽位**（0 号槽 + 各副槽），是材质引用计数的唯一真值来源。
    ///
    /// 0 号槽强制等于 `materialID`（主槽真值只有一份，不允许两处各说一套）；
    /// 其后按 `材质槽引用` 的槽序取值，尾部空槽裁掉（尾部空槽不构成引用）。
    /// 材质接线按这张表派生引用计数与反向索引 —— 只看主槽的口径会把"只被副槽引用"
    /// 的材质算成 0 引用，从而误删仍在使用的材质。
    var 材质槽位表: [UUID?] {
        var 表: [UUID?]
        if let 引用 = 材质槽引用, !引用.isEmpty {
            表 = 引用.map { Optional($0) }
            表[0] = materialID
        } else {
            表 = [materialID]
        }
        while let 尾 = 表.last, 尾 == nil { 表.removeLast() }
        return 表
    }
    var isVisible: Bool
    /// 非 nil 表示这个物体是「灯」：不生成网格几何，只作为光源参与照明
    var 灯光: 灯光设置? = nil
    /// 非 nil 表示这个物体是一个「角色」（来自骨架）：它不是文件夹，
    /// 而是一身可以穿挂的身体/衣服/道具，双击打开独立窗口管理。
    var 角色: 角色资产? = nil
    /// 非 nil 表示这个物体是一个「特效发射器」：参数在这里，模拟在视口层现算。
    /// 发射器是普通场景对象（可多、可移动、可打关键帧、随工程存盘），
    /// 但它不参与路径追踪出图 —— 出图口径暂不管特效，见 特效 数据.swift 的注释。
    var 特效: 特效设置? = nil
    /// 层级：挂在哪个父下（另一个物体 = 父子变换，集合 = 文件夹）。
    /// nil 表示场景根级。本 App 的 position/rotation/scale 存的始终是世界值，
    /// 所以父子只影响"父动子跟随"的组织语义，不改渲染口径。
    var 父: 父引用? = nil

    init(
        id: UUID = UUID(),
        name: String,
        mesh: MeshKind,
        导入网格ID: UUID? = nil,
        导入符号: String? = nil,
        position: Vec3 = .zero,
        rotation: Vec3 = .zero,
        scale: Vec3 = .one,
        materialID: UUID? = nil,
        材质槽引用: [UUID]? = nil,
        isVisible: Bool = true,
        灯光: 灯光设置? = nil,
        角色: 角色资产? = nil,
        特效: 特效设置? = nil,
        父: 父引用? = nil
    ) {
        self.id = id
        self.name = name
        self.mesh = mesh
        self.导入网格ID = 导入网格ID
        self.导入符号 = 导入符号
        self.position = position
        self.rotation = rotation
        self.scale = scale
        self.materialID = materialID
        self.材质槽引用 = 材质槽引用
        self.isVisible = isVisible
        self.灯光 = 灯光
        self.角色 = 角色
        self.特效 = 特效
        self.父 = 父
    }

    var symbol: String {
        if 角色 != nil { return "figure.arms.open" }
        return 灯光?.种类.symbol ?? 导入符号 ?? mesh.symbol
    }
    /// 是不是灯（灯不渲染网格，只照明）
    /// 存档前按几何域里的最新来源重写几何字段：落盘内容以域为准，字段本身只是运行期缓存。
    /// 域退化成「程序网格」多半是网格池那一刻取不到，这种时候不能拿它覆盖已有的导入网格引用。
    mutating func 按域回填几何(_ 源: 几何源取值) {
        switch 源.来源 {
        case .导入网格(let 标识):
            if 几何接线.共享.存在(标识) { self.导入网格ID = 标识 }
        case .程序网格(let 形状):
            if self.导入网格ID == nil { self.mesh = 形状 }
        }
    }

    // MARK: 几何来源（唯一写入口）

    /// 编辑层只记「这块物体的几何指向谁」，不存几何本体（顶点在 导入网格库 / PTGeometry）。
    /// 三个字段必须成组改，所以对外不开放单独 setter：
    /// 改程序形状走 `程序形状:`，换成导入网格走 `导入网格:`（传 nil 表示退回程序形状）。
    mutating func 设置几何来源(程序形状: MeshKind? = nil, 导入网格: UUID?, 导入符号: String? = nil) {
        if let 程序形状 { self.mesh = 程序形状 }
        self.导入网格ID = 导入网格
        self.导入符号 = 导入网格 == nil ? nil : (导入符号 ?? self.导入符号)
    }

    var 是灯: Bool { 灯光 != nil }
    /// 是不是角色（骨架容器）
    var 是角色: Bool { 角色 != nil }
    /// 是不是特效发射器（视口层据此走粒子链路，出图链路忽略它）
    var 是特效: Bool { 特效 != nil }
}
