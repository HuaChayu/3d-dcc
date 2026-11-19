import Foundation
import simd

// MARK: - 特效容器
//
// 口径（跟角色容器一个套路，但语义不同）：
// - 特效对象在大纲里就是**一行容器**，双击打开它自己的面板；
// - 容器里可以塞「发射源」：程序网格 / 导入网格 + 材质 + 自己的 TRS；
// - 这些几何**只是发射体** —— 不进场景对象列表、不进大纲、视口里也看不见，
//   所以"想让圈圈上冒火"不必真在场景里摆一个看得见的圈，塞一个环面就行；
// - 容器**不是范围锁**：没有"只影响内部"的语义，外面照样能烧、能被粒子撞。
//   它就是 UE 里那种方便选择和组织的节点，纯组织用途。

/// 容器里的一个发射源。几何在**容器局部空间**里算，容器一动源跟着动。
struct 特效发射源: Identifiable, Equatable, Sendable, Codable {
    var id: UUID
    var 名称: String
    var 启用: Bool
    var 形状: MeshKind
    var 导入网格ID: UUID?
    var 材质ID: UUID?
    var 位置: Vec3
    var 旋转: Vec3
    var 缩放: Vec3

    init(id: UUID = UUID(),
         名称: String = "发射源",
         启用: Bool = true,
         形状: MeshKind = .torus,
         导入网格ID: UUID? = nil,
         材质ID: UUID? = nil,
         位置: Vec3 = .zero,
         旋转: Vec3 = .zero,
         缩放: Vec3 = .one) {
        self.id = id
        self.名称 = 名称
        self.启用 = 启用
        self.形状 = 形状
        self.导入网格ID = 导入网格ID
        self.材质ID = 材质ID
        self.位置 = 位置
        self.旋转 = 旋转
        self.缩放 = 缩放
    }

    var 是导入网格: Bool { 导入网格ID != nil }

    var 图标: String { 是导入网格 ? "shippingbox.fill" : 形状.symbol }

    var 形状名: String { 是导入网格 ? "导入网格" : 形状.title }

    /// 容器局部空间的 TRS 矩阵。换算走变换域那唯一一份口径（欧拉顺序与视口/PT 一致）。
    var 局部矩阵: simd_float4x4 {
        let 双 = 变换域.本地矩阵(位置: SIMD3<Double>(位置.x, 位置.y, 位置.z),
                              欧拉角: SIMD3<Double>(旋转.x, 旋转.y, 旋转.z),
                              缩放: SIMD3<Double>(缩放.x, 缩放.y, 缩放.z))
        return simd_float4x4(columns: (SIMD4<Float>(双.columns.0),
                                       SIMD4<Float>(双.columns.1),
                                       SIMD4<Float>(双.columns.2),
                                       SIMD4<Float>(双.columns.3)))
    }

    // MARK: Codable（逐字段兜底）
    //
    // 手写而不是让编译器合成：容器是新东西，将来加字段时旧工程里的源必须还能解出来，
    // 缺一个键就整份工程打不开是最难查的那种崩。

    private enum 键: String, CodingKey {
        case id, 名称, 启用, 形状, 导入网格ID, 材质ID, 位置, 旋转, 缩放
    }

    init(from 解: Decoder) throws {
        let 盒 = try 解.container(keyedBy: 键.self)
        id = (try? 盒.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        名称 = (try? 盒.decodeIfPresent(String.self, forKey: .名称)) ?? "发射源"
        启用 = (try? 盒.decodeIfPresent(Bool.self, forKey: .启用)) ?? true
        形状 = (try? 盒.decodeIfPresent(MeshKind.self, forKey: .形状)) ?? .torus
        导入网格ID = try? 盒.decodeIfPresent(UUID.self, forKey: .导入网格ID)
        材质ID = try? 盒.decodeIfPresent(UUID.self, forKey: .材质ID)
        位置 = (try? 盒.decodeIfPresent(Vec3.self, forKey: .位置)) ?? .zero
        旋转 = (try? 盒.decodeIfPresent(Vec3.self, forKey: .旋转)) ?? .zero
        缩放 = (try? 盒.decodeIfPresent(Vec3.self, forKey: .缩放)) ?? .one
    }

    func encode(to 编: Encoder) throws {
        var 盒 = 编.container(keyedBy: 键.self)
        try 盒.encode(id, forKey: .id)
        try 盒.encode(名称, forKey: .名称)
        try 盒.encode(启用, forKey: .启用)
        try 盒.encode(形状, forKey: .形状)
        try 盒.encodeIfPresent(导入网格ID, forKey: .导入网格ID)
        try 盒.encodeIfPresent(材质ID, forKey: .材质ID)
        try 盒.encode(位置, forKey: .位置)
        try 盒.encode(旋转, forKey: .旋转)
        try 盒.encode(缩放, forKey: .缩放)
    }
}

// MARK: - 容器 → 几何

/// 把容器里的若干个源**合并成一份对象几何**（容器局部空间）。
///
/// 为什么合并而不是让下游吃多份：
/// 表面场、域盒、喷口、PT 转译全是"一个几何 + 一个世界矩阵"的签名，
/// 合并之后这些链路一行都不用改，容器就等于"一个形状很复杂的对象"。
enum 特效几何库 {

    private static let 锁 = NSLock()
    /// 基础三角汤缓存（按形状 / 按导入网格内容版本）：拖动源时不必重跑网格生成器
    private static var 点缓存: [String: [SIMD3<Float>]] = [:]
    /// 合并结果缓存（键里带每个源的 TRS，所以只在真正变了才重建）
    private static var 几何缓存: [String: 对象几何数据] = [:]

    /// 容器里有没有"在干活的源"。没有就退回老口径（发射体对象ID / 自己）。
    static func 有启用源(_ 设置: 特效设置) -> Bool {
        (设置.发射源们 ?? []).contains { $0.启用 }
    }

    /// 合并后的三角汤。容器里没有任何可用几何时返回 nil（下游自动退回老逻辑）。
    static func 组合几何(_ 设置: 特效设置) -> 对象几何数据? {
        let 源们 = (设置.发射源们 ?? []).filter { $0.启用 }
        guard !源们.isEmpty else { return nil }

        var 指纹 = "特效容器:"
        for (序, 源) in 源们.enumerated() {
            let 基 = 基础点(形状: 源.形状, 导入网格ID: 源.导入网格ID)
            指纹 += "\(序)|\(基.键)|\(源.位置.x),\(源.位置.y),\(源.位置.z)"
            指纹 += "|\(源.旋转.x),\(源.旋转.y),\(源.旋转.z)"
            指纹 += "|\(源.缩放.x),\(源.缩放.y),\(源.缩放.z);"
        }

        锁.lock()
        let 命中 = 几何缓存[指纹]
        锁.unlock()
        if let 命中 { return 命中 }

        var 点: [SIMD3<Float>] = []
        for 源 in 源们 {
            let 基 = 基础点(形状: 源.形状, 导入网格ID: 源.导入网格ID)
            guard !基.点.isEmpty else { continue }
            let 阵 = 源.局部矩阵
            for p in 基.点 {
                let 世 = 阵 * SIMD4<Float>(p, 1)
                点.append(SIMD3<Float>(世.x, 世.y, 世.z))
            }
        }
        guard !点.isEmpty else { return nil }

        let 数据 = 对象几何数据(键: 指纹, 三角点: 点)
        锁.lock()
        if 几何缓存.count > 24 { 几何缓存.removeAll() }
        几何缓存[指纹] = 数据
        锁.unlock()
        return 数据
    }

    /// 容器几何的尺度：顶部 = 合并后几何的顶面 y，半径 = 横向与半高的较大者。
    /// 域盒、粒子出生半径都吃这两个数，容器比单个对象大多少这里说了算。
    static func 尺度(_ 几何: 对象几何数据) -> (顶部: Float, 半径: Float) {
        let 半径 = max(0.02, max(几何.半宽, 几何.高 * 0.5))
        return (几何.最大.y, 半径)
    }

    // MARK: 基础三角汤

    /// 一个源自己的三角汤（源局部空间）。跟 对象几何库 用同一条口径：
    /// 程序网格走画面同一份生成器，导入网格按内容版本取池里的三角点。
    private static func 基础点(形状: MeshKind, 导入网格ID: UUID?) -> (键: String, 点: [SIMD3<Float>]) {
        if let 网格 = 导入网格ID {
            let 键 = "导入:\(网格.uuidString):\(几何接线.共享.版本号(网格))"
            锁.lock()
            let 命中 = 点缓存[键]
            锁.unlock()
            if let 命中 { return (键, 命中) }
            let 点 = 几何接线.共享.三角点列(网格)
            if !点.isEmpty {
                锁.lock()
                if 点缓存.count > 32 { 点缓存.removeAll() }
                点缓存[键] = 点
                锁.unlock()
            }
            return (键, 点)
        }

        let 键 = "程序:\(形状.rawValue)"
        锁.lock()
        let 命中 = 点缓存[键]
        锁.unlock()
        if let 命中 { return (键, 命中) }

        var 点: [SIMD3<Float>] = []
        for 片 in PTGeometry.piece(for: 形状) {
            let n = 片.indices.count - 片.indices.count % 3
            var i = 0
            while i < n {
                点.append(片.positions[Int(片.indices[i])])
                点.append(片.positions[Int(片.indices[i + 1])])
                点.append(片.positions[Int(片.indices[i + 2])])
                i += 3
            }
        }
        if !点.isEmpty {
            锁.lock()
            if 点缓存.count > 32 { 点缓存.removeAll() }
            点缓存[键] = 点
            锁.unlock()
        }
        return (键, 点)
    }
}
