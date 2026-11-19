import Foundation
import simd

// MARK: - 角色（骨架）资产
//
// 设计口径：骨架不是文件夹，而是一个"角色"。
// 它在场景里就是一个普通 SceneObject（参与渲染、可选中、可移动），
// 额外的 角色资产 只负责记录「这一身由哪些部件组成」，
// 交给独立窗口（左侧内部树 + 右侧预览）去管理，大纲里只留角色这一行。

/// 部件分组：身体 / 衣服 / 道具 / 其他（左侧树的第一层）
enum 角色部件分类: String, Codable, CaseIterable, Hashable {
    case 身体
    case 衣服
    case 道具
    case 其他

    var 名: String { rawValue }

    var 符号: String {
        switch self {
        case .身体: return "figure.stand"
        case .衣服: return "tshirt"
        case .道具: return "wand.and.rays"
        case .其他: return "shippingbox"
        }
    }

    /// 靠对象名猜一次分组。Blender 里的对象名通常带 Body / Cloth / Sword 这类字眼，
    /// 猜不中就算「其他」，用户在窗口里可以改。
    static func 猜(_ 名: String) -> 角色部件分类 {
        let 小 = 名.lowercased()
        let 身体词 = ["body", "skin", "head", "face", "eye", "teeth", "tooth", "tongue",
                   "hair", "brow", "lash", "arm", "leg", "hand", "foot", "手指", "躯",
                   "身体", "眼", "牙", "发", "头", "脸", "舌"]
        let 衣服词 = ["cloth", "shirt", "dress", "coat", "pant", "skirt", "armor", "armour",
                   "cape", "hood", "shoe", "boot", "glove", "sock", "衣", "服", "裙",
                   "裤", "袜", "靴", "甲", "袍", "帽"]
        let 道具词 = ["sword", "gun", "weapon", "rifle", "pistol", "staff", "wand", "shield",
                   "bag", "prop", "helmet", "hat", "axe", "bow", "剑", "枪", "盾", "棒",
                   "包", "盔", "弓", "斧"]

        if 身体词.contains(where: { 小.contains($0) }) { return .身体 }
        if 衣服词.contains(where: { 小.contains($0) }) { return .衣服 }
        if 道具词.contains(where: { 小.contains($0) }) { return .道具 }
        return .其他
    }
}

/// 一根骨骼的静止姿态（rest pose）：头尾点已经乘过骨架物体的世界矩阵，
/// 和部件网格的坐标同一个空间，所以能直接跟部件一起画在预览里。
struct 角色骨骼: Codable, Hashable, Sendable {
    /// 骨名（不含层级）
    var 名称: String = ""
    /// 层级路径，例如「躯干/胸/手.L」
    var 路径: String = ""
    /// 父骨在 骨数据 数组里的下标；根骨为 nil
    var 父: Int? = nil
    /// (路径层级深度 - 1)，左侧树缩进直接用，省得每次数斜杠
    var 层: Int = 0
    var 头: SIMD3<Float> = .zero
    var 尾: SIMD3<Float> = .zero

    /// 骨长（世界单位），预览里画骨杆用
    var 长: Float { simd_length(尾 - 头) }

    /// 头尾都是正常数字才画（坏块读出来的可能是 NaN / 无穷）
    var 有效: Bool {
        头.x.isFinite && 头.y.isFinite && 头.z.isFinite
            && 尾.x.isFinite && 尾.y.isFinite && 尾.z.isFinite
    }
}

/// 约束型：Blender 里「约束（Constraint）」那种算法型求解器，不是限位。
/// 区别在于：限位只做边界裁剪（超了才夹回来），约束是每次都把姿态重算成满足目标，
/// 所以在链条上会带着上游/下游的骨一起动。
enum 角色约束型: String, Codable, Hashable, Sendable, CaseIterable {
    /// 对准目标（= Blender 的 Damped Track / Track To）：这节骨的 头→尾 始终指着目标骨，
    /// 只有这一节转，位置不动。链长固定 1。
    case 对准
    /// 反向动力学（= Blender 的 IK）：末端骨带着上游「链长」根骨一起去够目标骨，
    /// 够不到就把链弯起来 —— 提膝就是这条路。
    case 反向动力学

    var 标题: String {
        switch self {
        case .对准: "对准目标"
        case .反向动力学: "反向动力学（IK）"
        }
    }

    var 说明: String {
        switch self {
        case .对准: "这节骨的头→尾 一直指着目标骨，只有它自己转"
        case .反向动力学: "末端够向目标骨，上游几节跟着弯，够不到就弯起来"
        }
    }
}

/// 一条约束：挂在某根骨上，盯住某根「目标骨」。
/// 数据上只存骨路径，不存算好的结果 —— 每次解算现算，目标一动整条链就跟着动。
struct 角色约束: Codable, Hashable, Sendable, Identifiable {
    var 标识 = UUID()
    var 型: 角色约束型 = .反向动力学
    /// 被约束的骨（约束挂在这节上）
    var 骨路径: String = ""
    /// 目标骨（Blender 的 Target Bone）：它的骨尾就是目标点
    var 目标骨路径: String = ""
    /// 上游参与求解的骨数：1 = 只有被约束这节动；2 = 带上父骨一起弯
    var 链长: Int = 2
    var 启用: Bool = true

    var 生效链长: Int { max(1, min(2, 链长)) }

    /// Identifiable：面板里的 ForEach 用
    var id: UUID { 标识 }
}

/// 一个角色：骨架 + 挂在它身上的身体 / 衣服 / 道具
struct 角色资产: Codable, Hashable {
    /// 骨架对象名（窗口标题用）
    var 骨架名: String = ""
    /// 骨骼名（带层级路径，左侧树直接按它缩进显示）
    var 骨骼: [String] = []
    /// 骨骼几何（rest 姿态头尾点），预览里画骨架用
    var 骨数据: [角色骨骼] = []
    /// 部件的 SceneObject.id。部件本身仍在场景里、照常渲染，
    /// 只是大纲里被收进角色行，不再单独占位。
    var 部件: [UUID] = []
    /// 用户手动指定的分组（键没命中就按名字自动猜）
    var 分类: [UUID: 角色部件分类] = [:]
    /// 摆出来的姿势：骨路径 → 该骨在「父骨空间」里的局部旋转（相对 rest）。
    /// 键没出现的骨就是没动过。视口里的关节球拖出来的就是这个，
    /// 骨点的实际位置由 `角色姿态.解算` 沿父子链复合，不在这里存死。
    var 姿态: [String: SIMD4<Float>] = [:]
    /// 约束：Blender 那种算法约束（目标骨 + 链长）。和「姿态」是两个层次 ——
    /// 姿态是手摆出来的，约束是每次解算时在上面的二次求解，不写回姿态表。
    var 约束: [角色约束] = []

    var 部件数: Int { 部件.count }

    init(骨架名: String = "",
         骨骼: [String] = [],
         骨数据: [角色骨骼] = [],
         部件: [UUID] = [],
         分类: [UUID: 角色部件分类] = [:],
         姿态: [String: SIMD4<Float>] = [:],
         约束: [角色约束] = []) {
        self.骨架名 = 骨架名
        self.骨骼 = 骨骼
        self.骨数据 = 骨数据
        self.部件 = 部件
        self.分类 = 分类
        self.姿态 = 姿态
        self.约束 = 约束
    }

    // 手动解码：老工程的存档里没有「骨数据」这个键，缺了就当空，别让整个工程读不回来
    init(from decoder: Decoder) throws {
        let 容器 = try decoder.container(keyedBy: CodingKeys.self)
        骨架名 = try 容器.decodeIfPresent(String.self, forKey: .骨架名) ?? ""
        骨骼 = try 容器.decodeIfPresent([String].self, forKey: .骨骼) ?? []
        骨数据 = try 容器.decodeIfPresent([角色骨骼].self, forKey: .骨数据) ?? []
        部件 = try 容器.decodeIfPresent([UUID].self, forKey: .部件) ?? []
        分类 = try 容器.decodeIfPresent([UUID: 角色部件分类].self, forKey: .分类) ?? [:]
        姿态 = try 容器.decodeIfPresent([String: SIMD4<Float>].self, forKey: .姿态) ?? [:]
        约束 = try 容器.decodeIfPresent([角色约束].self, forKey: .约束) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var 容器 = encoder.container(keyedBy: CodingKeys.self)
        try 容器.encode(骨架名, forKey: .骨架名)
        try 容器.encode(骨骼, forKey: .骨骼)
        try 容器.encode(骨数据, forKey: .骨数据)
        try 容器.encode(部件, forKey: .部件)
        try 容器.encode(分类, forKey: .分类)
        try 容器.encode(姿态, forKey: .姿态)
        try 容器.encode(约束, forKey: .约束)
    }

    enum CodingKeys: String, CodingKey {
        case 骨架名, 骨骼, 骨数据, 部件, 分类, 姿态, 约束
    }
}
