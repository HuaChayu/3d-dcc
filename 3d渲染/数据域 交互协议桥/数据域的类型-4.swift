import Foundation
import simd

// MARK: - 几何域
//
// 唯一所有者：几何。
// 这里只记录「几何的归属与生命周期」，形状本身不在这里另立第二套：
// 程序网格直接复用 MeshKind，导入网格只存 导入网格库 里的 id（几何数据归导入网格库）。
// 禁止在任何其它地方再写一份形状枚举 / 默认值 / 校验。

/// 几何来源：引用既有定义，不复制形状。
enum 几何来源: Equatable {
    /// 程序化网格（球、立方体……），唯一来源是 MeshKind
    case 程序网格(MeshKind)
    /// 外部导入网格，唯一来源是 导入网格库，这里只存 id
    case 导入网格(UUID)
}

struct 几何记录: Equatable {
    var 名称: String
    var 来源: 几何来源

    init(名称: String, 来源: 几何来源) {
        self.名称 = 名称
        self.来源 = 来源
    }
}

typealias 几何域 = 记录域<几何域标签, 几何记录>
typealias 几何视图 = 域只读视图<几何域标签, 几何记录>

// MARK: - 材质域
//
// 唯一所有者：材质。
// 材质参数块（OpenPBR 全套字段）、节点图、出厂基线/出厂图、出处/内置/副本关系，
// 以及节点图引用到的图像资产，全部住在域里。
// 域外不许保存材质副本、不许自己拼材质签名：视口与 PT 一律经快照只读视图取，
// 写一律经 材质接线（唯一写入方，要 .材质 令牌）。

struct 材质记录: Equatable {
    /// 材质本体：参数块 + 节点图 + 出厂快照 + 出处 + 内置 + 副本于 + note。
    /// 资产 id（MaterialAsset.id）即全工程长期引用键，不用域内下标。
    var 资产: MaterialAsset
    /// 单材质版本：参数、节点图、图像引用任一处被写就 +1。
    /// 全局域版本回答"有没有材质动过"，这个回答"动的是哪一个"，两粒度都要。
    var 参数版本: UInt64
    /// 节点图沿连线反向收集到的图像资产引用（参数键 → 图像资产 id）。
    /// 只在写入时由接线重算一次，消费端直接读，不许自己再跑图。
    var 图像引用: [PBRParamKey: UUID]

    var 资产ID: UUID { 资产.id }
    var 名称: String { 资产.name }

    init(资产: MaterialAsset, 参数版本: UInt64 = 0, 图像引用: [PBRParamKey: UUID] = [:]) {
        self.资产 = 资产
        self.参数版本 = 参数版本
        self.图像引用 = 图像引用
    }

    /// 占位构造：只给名字。真源仍是 MaterialAsset，域里不另写一份默认值。
    init(名称: String) {
        self.init(资产: MaterialAsset(name: 名称))
    }
}

typealias 材质域 = 记录域<材质域标签, 材质记录>
typealias 材质视图 = 域只读视图<材质域标签, 材质记录>

extension 材质域 {
    /// 按长期引用键定位；材质数量是几十级，线性扫描比再维护一份平行索引更稳。
    /// 每帧每对象都要反查的调用方走 材质接线 的索引，不用这个。
    func 标识(资产 id: UUID) -> 稳定标识<材质域标签>? {
        for 标 in 全部标识() where 取(标)?.资产ID == id { return 标 }
        return nil
    }

    func 记录(资产 id: UUID) -> 材质记录? {
        guard let 标 = 标识(资产: id) else { return nil }
        return 取(标)
    }
}

// MARK: - 灯光域
//
// 唯一所有者：灯光。
// 灯是 DCC 意义上的独立对象，不产几何、不进几何域。
// 灯参数唯一来源是 灯光设置（场景 数据模型.swift），这里不重新定义瓦数/色温/半径的默认值。

struct 灯光记录: Equatable {
    var 名称: String
    var 设置: 灯光设置
    /// 朝向（欧拉角，度）：矩阵只表达"灯在哪"，"灯朝哪照"是灯的属性，归灯光所有。
    var 朝向: SIMD3<Double>
    /// 模型对象标识：灯光接线是唯一写入方，靠它把模型对象映射到稳定标识。
    var 外部键: String

    init(
        名称: String,
        设置: 灯光设置 = 灯光设置(),
        朝向: SIMD3<Double> = SIMD3<Double>(repeating: 0),
        外部键: String = ""
    ) {
        self.名称 = 名称
        self.设置 = 设置
        self.朝向 = 朝向
        self.外部键 = 外部键
    }
}

typealias 灯光域 = 记录域<灯光域标签, 灯光记录>
typealias 灯光视图 = 域只读视图<灯光域标签, 灯光记录>

// MARK: - 变换域
//
// 唯一所有者：变换。作用域是对象树，父指针 + 本地矩阵。
// 父子只表达"父动子跟随"，世界矩阵是派生值，缓存也必须由本域算，别处不许再算一份。
//
// 【阶段2-第二步：域升级为 派生 / 缓存 / 版本 三合一】
// 1) 派生：TRS → 本地矩阵的换算搬进本域（`本地矩阵(位置:欧拉角:缩放:)`）。外部
//    （PT 顶点烘焙 / 视口实体定位 / 灯位置 / 出图 / 拾取 / 面板数值）一律只向域要世界矩阵，
//    不许自己再乘一次父子链，也不许自己解析 position/rotation/scale。
// 2) 缓存：世界矩阵按 id 缓存，写入时沿父子链向下作废（dirty 传播），命中直接返回。
// 3) 版本：域版本号（全局，任何写入 +1）与逐记录版本号（`记录版本(_:)`）并存。
//    逐记录版本用来做「段版本」聚合：`段版本(ids)` 是这些记录版本之和 —— 每项只增不减，
//    因此和严格单调，任何一项变、和必变；没变就不变。灯的"变换段版本"由此得出，
//    不再需要一份独立的"灯变换接线计数器"，也就不会把"物体动了"误判成"灯动了"。

struct 变换记录: Equatable {
    var 名称: String
    var 本地矩阵: simd_double4x4
    var 父: 稳定标识<变换域标签>?

    init(名称: String = "变换", 本地矩阵: simd_double4x4 = matrix_identity_double4x4, 父: 稳定标识<变换域标签>? = nil) {
        self.名称 = 名称
        self.本地矩阵 = 本地矩阵
        self.父 = 父
    }
}

/// 变换域：在通用记录域外面套一层"成环不许挂"的约束（规矩 6）。
final class 变换域 {

    let 存储: 记录域<变换域标签, 变换记录>

    /// 世界矩阵缓存：域内派生值的唯一存放处。写一次只作废"该节点 + 其全部后代"。
    private var 世界缓存: [稳定标识<变换域标签>: simd_double4x4] = [:]
    /// 逐记录修改计数：段版本聚合的唯一原料，只增不减。
    private var 记录版本表: [稳定标识<变换域标签>: UInt64] = [:]
    /// 父 → 子 索引：只服务 dirty 向下传播，不承担任何真相语义（真相仍是记录里的 父）。
    private var 子索引: [稳定标识<变换域标签>: [稳定标识<变换域标签>]] = [:]

    /// 变换域是唯一会被"主线程拾取"和"渲染线程转译"同时碰的数据：
    /// 读（世界矩阵）与写（TRS）都在锁内，缓存与版本号不会读到半写状态。
    /// 递归锁：设TRS → 设本地矩阵、记账 → 作废(向下传播) 都是同线程重入。
    private let 锁 = NSRecursiveLock()

    /// 缓存命中/未命中（只做诊断，绝不参与判定）
    private(set) var 缓存命中: UInt64 = 0
    private(set) var 缓存未命中: UInt64 = 0

    init() {
        存储 = 记录域(所有者: .变换)
    }

    var 版本号: UInt64 { 存储.版本号 }
    var 有效数量: Int { 存储.有效数量 }

    func 取(_ id: 稳定标识<变换域标签>) -> 变换记录? { 存储.取(id) }

    func 遍历(_ 体: (稳定标识<变换域标签>, 变换记录) -> Void) { 存储.遍历(体) }

    func 全部标识() -> [稳定标识<变换域标签>] { 存储.全部标识() }

    // MARK: TRS → 本地矩阵（全工程唯一换算入口）

    /// 位置 + 欧拉角（度）+ 缩放 → 本地矩阵。
    /// 顺序与视口一致：先缩、再转（绕 Z → 绕 X → 绕 Y）、最后平移。
    /// 【口径钉死】内部用 Float 计算再扩到 Double：与历史 PT 顶点烘焙 / 视口实现的位级结果
    /// 完全一致。改成"用 Double 重算"看着更精确，末位却不同 —— 那正是"肉眼看一样、比像素不一样"。
    static func 本地矩阵(
        位置: SIMD3<Double>,
        欧拉角: SIMD3<Double>,
        缩放: SIMD3<Double>
    ) -> simd_double4x4 {
        let 弧度 = SIMD3<Float>(Float(欧拉角.x), Float(欧拉角.y), Float(欧拉角.z)) * (Float.pi / 180)
        let 四元数 = simd_quatf(angle: 弧度.z, axis: [0, 0, 1])
            * simd_quatf(angle: 弧度.x, axis: [1, 0, 0])
            * simd_quatf(angle: 弧度.y, axis: [0, 1, 0])

        func 轴(_ v: SIMD3<Float>) -> SIMD4<Float> { SIMD4<Float>(四元数.act(v), 0) }

        let 缩X = Float(缩放.x == 0 ? 1 : 缩放.x)
        let 缩Y = Float(缩放.y == 0 ? 1 : 缩放.y)
        let 缩Z = Float(缩放.z == 0 ? 1 : 缩放.z)

        let 阵 = simd_float4x4(columns: (
            轴([1, 0, 0]) * 缩X,
            轴([0, 1, 0]) * 缩Y,
            轴([0, 0, 1]) * 缩Z,
            SIMD4<Float>(Float(位置.x), Float(位置.y), Float(位置.z), 1)
        ))
        return simd_double4x4(
            SIMD4<Double>(Double(阵.columns.0.x), Double(阵.columns.0.y), Double(阵.columns.0.z), Double(阵.columns.0.w)),
            SIMD4<Double>(Double(阵.columns.1.x), Double(阵.columns.1.y), Double(阵.columns.1.z), Double(阵.columns.1.w)),
            SIMD4<Double>(Double(阵.columns.2.x), Double(阵.columns.2.y), Double(阵.columns.2.z), Double(阵.columns.2.w)),
            SIMD4<Double>(Double(阵.columns.3.x), Double(阵.columns.3.y), Double(阵.columns.3.z), Double(阵.columns.3.w))
        )
    }

    // MARK: 写（一律带令牌，一律先比后写）

    @discardableResult
    func 新增(
        _ 记录: 变换记录,
        令牌 写令牌: 所有者令牌
    ) -> 稳定标识<变换域标签>? {
        锁.lock()
        defer { 锁.unlock() }
        if let 违规 = 存储.预检写入(写令牌) {
            架构记录(.非所有者写入, "变换域 拒绝 \(写令牌.名称) 的新增：\(违规.描述)")
            return nil
        }
        if let 父 = 记录.父, 存储.检测标识(父) != nil {
            架构记录(.关节点悬空, "新增变换时父 \(父) 不存在")
            return nil
        }
        guard let id = 存储.新增(记录, 令牌: 写令牌) else { return nil }
        记录版本表[id] = 1
        if let 父 = 记录.父 {
            var 子们 = 子索引[父, default: []]
            if !子们.contains(id) { 子们.append(id) }
            子索引[父] = 子们
        }
        作废(id)
        return id
    }

    /// 只检测不成环，不做任何写入 —— 供自检与断言共用。
    func 检测成环(_ id: 稳定标识<变换域标签>, 新父: 稳定标识<变换域标签>) -> 域违规? {
        if 新父 == id {
            return .成环(细节: "\(id) 把自己设成自己的父")
        }
        var 游标: 稳定标识<变换域标签>? = 新父
        var 步数 = 0
        let 上限 = 存储.有效数量 + 1
        while let 当前 = 游标 {
            if 当前 == id {
                return .成环(细节: "\(id) 挂到 \(新父) 后父链会绕回自己")
            }
            步数 += 1
            if 步数 > 上限 {
                return .成环(细节: "父链步数超过记录数（\(上限)），链本身已坏")
            }
            游标 = 存储.取(当前)?.父
        }
        return nil
    }

    /// 设父：Debug 断言 + Release 返回错误，不做"检测到就重建"的容错（规矩 3、6）。
    @discardableResult
    func 设父(
        _ id: 稳定标识<变换域标签>,
        父 新父: 稳定标识<变换域标签>?,
        令牌 写令牌: 所有者令牌
    ) -> 域违规? {
        锁.lock()
        defer { 锁.unlock() }
        if let 违规 = 存储.预检写入(写令牌) {
            架构记录(.非所有者写入, "变换域 拒绝 \(写令牌.名称) 的设父：\(违规.描述)")
            return 违规
        }
        if let 新父 {
            if let 违规 = 检测成环(id, 新父: 新父) {
                架构记录(.成环, 违规.描述)
                return 违规
            }
        }
        guard let 目标 = 存储.取(id) else { return .未知标识(细节: "\(id) 不存在") }
        let 旧父 = 目标.父
        if 旧父 == 新父 { return nil }
        let 成功 = 存储.改(id, 令牌: 写令牌) { $0.父 = 新父 }
        guard 成功 else { return .未知标识(细节: "\(id) 不存在") }
        if let 旧父, var 子们 = 子索引[旧父] {
            子们.removeAll { $0 == id }
            子索引[旧父] = 子们
        }
        if let 新父 {
            var 子们 = 子索引[新父, default: []]
            if !子们.contains(id) { 子们.append(id) }
            子索引[新父] = 子们
        }
        记账(id)
        return nil
    }

    /// 设本地矩阵：值没变就一个字节都不写、版本号也不推（拖拽静止帧不该空转）。
    /// - Returns: true = 真的写入了（版本号已推进）
    @discardableResult
    func 设本地矩阵(
        _ id: 稳定标识<变换域标签>,
        _ 矩阵: simd_double4x4,
        令牌 写令牌: 所有者令牌
    ) -> Bool {
        锁.lock()
        defer { 锁.unlock() }
        guard let 旧 = 存储.取(id) else {
            架构记录(.未知标识, "变换域 设本地矩阵：\(id) 不存在")
            return false
        }
        if 旧.本地矩阵 == 矩阵 { return false }
        guard 存储.改(id, 令牌: 写令牌, { $0.本地矩阵 = 矩阵 }) else { return false }
        记账(id)
        return true
    }

    /// 设 TRS：外部只给 position / 欧拉角 / 缩放，换算在本域内做（唯一换算入口）。
    /// - Returns: true = 真的写入了
    @discardableResult
    func 设TRS(
        _ id: 稳定标识<变换域标签>,
        位置: SIMD3<Double>,
        欧拉角: SIMD3<Double>,
        缩放: SIMD3<Double>,
        令牌 写令牌: 所有者令牌
    ) -> Bool {
        设本地矩阵(id, Self.本地矩阵(位置: 位置, 欧拉角: 欧拉角, 缩放: 缩放), 令牌: 写令牌)
    }

    // MARK: 派生（世界矩阵 + 缓存）

    /// 世界矩阵：只在域内派生。命中缓存直接返回；未命中就走一遍父链，
    /// 顺手把链上每一层都缓存下来（下一次读中间节点也是 O(1)）。
    func 世界矩阵(_ id: 稳定标识<变换域标签>) -> simd_double4x4? {
        锁.lock()
        defer { 锁.unlock() }
        if let 命中 = 世界缓存[id] {
            缓存命中 &+= 1
            return 命中
        }
        缓存未命中 &+= 1

        // 收集 "自己 → 根" 的链（父链不可能成环：设父与新增都挡过），再从根往下连乘。
        // 链上每一层都写进缓存：之后读中间任何一层都是 O(1)。
        var 链: [稳定标识<变换域标签>] = []
        var 游标: 稳定标识<变换域标签>? = id
        var 步数 = 0
        let 上限 = 存储.有效数量 + 1
        while let 当前 = 游标 {
            guard let 记录 = 存储.取(当前) else { return nil }
            链.append(当前)
            游标 = 记录.父
            步数 += 1
            if 步数 > 上限 {
                架构记录(.成环, "世界矩阵求解超过 \(上限) 步，父链成环")
                return nil
            }
        }

        var 矩阵: simd_double4x4?
        for 节点 in 链.reversed() {   // 从根往下：世界 = 父世界 × 本地
            guard let 记录 = 存储.取(节点) else { return nil }
            // 根节点（无父）直接就是本地矩阵：不做 "本地 × 单位阵" 的乘法。
            // 省一次乘法，也避开 -0.0/+0.0 这种末位差异 —— 逐像素等价要求能不动的位就不动。
            if let 父世界 = 矩阵 {
                矩阵 = 父世界 * 记录.本地矩阵
            } else {
                矩阵 = 记录.本地矩阵
            }
            世界缓存[节点] = 矩阵
        }
        return 矩阵
    }

    /// 逐记录版本号（没有记录过就是 0）：给"段版本"聚合与诊断用。
    func 记录版本(_ id: 稳定标识<变换域标签>) -> UInt64 {
        锁.lock()
        defer { 锁.unlock() }
        return 记录版本表[id] ?? 0
    }

    /// 段版本：这些记录版本之和。所有分量只增不减 ⇒ 和严格单调，任一项变必变，全都不变则不变。
    /// 灯段的"变换版本"就是这么来的：灯变换记录动了就涨，拖箱子不会让它涨。
    func 段版本(_ ids: [稳定标识<变换域标签>]) -> UInt64 {
        锁.lock()
        defer { 锁.unlock() }
        var 和: UInt64 = 0
        for id in ids { 和 &+= (记录版本表[id] ?? 0) }
        return 和
    }

    /// 整域作废（只给"引用回收真删了记录"这类罕见路径用，正常写入走 记账 的定向作废）
    func 全部作废() {
        锁.lock()
        defer { 锁.unlock() }
        世界缓存.removeAll(keepingCapacity: true)
        子索引.removeAll(keepingCapacity: true)
        记录版本表.removeAll(keepingCapacity: true)
    }

    // MARK: 内部记账

    /// 一次成功写入后的统一记账：推逐记录版本 + 定向作废该节点与其全部后代。
    private func 记账(_ id: 稳定标识<变换域标签>) {
        记录版本表[id, default: 0] &+= 1
        作废(id)
    }

    /// dirty 向下传播：自己坏了，所有后代的世界矩阵都坏了（父动子跟随）。
    private func 作废(_ id: 稳定标识<变换域标签>) {
        世界缓存.removeValue(forKey: id)
        guard let 子们 = 子索引[id], !子们.isEmpty else { return }
        for 子 in 子们 { 作废(子) }
    }

    func 只读视图() -> 变换视图 { 变换视图(self) }
}

/// 变换域只读视图：同样零拷贝，只转发读。
struct 变换视图 {

    private let 源: 变换域
    let 版本号: UInt64

    init(_ 源: 变换域) {
        self.源 = 源
        self.版本号 = 源.版本号
    }

    var 数量: Int { 源.有效数量 }

    func 取(_ id: 稳定标识<变换域标签>) -> 变换记录? { 源.取(id) }

    func 遍历(_ 体: (稳定标识<变换域标签>, 变换记录) -> Void) { 源.遍历(体) }

    func 全部标识() -> [稳定标识<变换域标签>] { 源.全部标识() }

    func 世界矩阵(_ id: 稳定标识<变换域标签>) -> simd_double4x4? { 源.世界矩阵(id) }

    /// 本地矩阵：只有"我自己"这一层，不含父链（角色部件这类需要局部量的场景用）。
    func 本地矩阵(_ id: 稳定标识<变换域标签>) -> simd_double4x4? { 源.取(id)?.本地矩阵 }

    func 记录版本(_ id: 稳定标识<变换域标签>) -> UInt64 { 源.记录版本(id) }

    func 段版本(_ ids: [稳定标识<变换域标签>]) -> UInt64 { 源.段版本(ids) }

    func 是否仍是最新(_ 层: 变换域) -> Bool { 层.版本号 == 版本号 }
}

// MARK: - 对象域：关节表 / 材质分配 / 对象视图（原「对象 关节.swift」）

// MARK: - 材质分配

/// 对象怎么吃材质：只有这三种，别处不许再发明第四种映射方式。
enum 材质分配: Equatable {

    /// 整个对象一个材质；nil 表示"还没指定"（不是默认材质，别在这里编默认值）
    case 单材质(稳定标识<材质域标签>?)

    /// 逐三角形材质索引：第 i 项对应第 i 个三角形，nil 项表示该三角形未指定
    case 逐三角形([稳定标识<材质域标签>?])

    /// 图集切片：一张材质图集，按 (列, 行, 索引) 取切片
    case 图集(材质: 稳定标识<材质域标签>, 切片: 图集切片)

    struct 图集切片: Equatable {
        var 列: Int
        var 行: Int
        var 索引: Int

        init(列: Int, 行: Int, 索引: Int) {
            self.列 = 列
            self.行 = 行
            self.索引 = 索引
        }
    }

    /// 这个分配里出现的所有材质 id（用于引用计数与悬空校验）
    var 涉及材质: [稳定标识<材质域标签>] {
        switch self {
        case let .单材质(材质):
            return 材质.map { [$0] } ?? []
        case let .逐三角形(表):
            return 表.compactMap { $0 }
        case let .图集(材质, _):
            return [材质]
        }
    }
}

// MARK: - 对象关节 独立

/// 对象是唯一的 M:N 连接者：
/// 几何 ↔ 对象 = 1:N（一份几何被多个实例引用）
/// 材质 ↔ 对象 = M:N
/// 对象 ↔ 变换 = 1:1
/// 对象 ↔ 灯光 = 1:1（灯不产几何、不进几何域）
struct 对象关节记录: Equatable {
    var 名称: String
    /// 几何 id；灯对象为 nil
    var 几何: 稳定标识<几何域标签>?
    var 材质分配: 材质分配
    /// 变换 id；一对一，必需
    var 变换: 稳定标识<变换域标签>
    /// 灯光 id；几何对象为 nil
    var 灯光: 稳定标识<灯光域标签>?

    init(
        名称: String,
        几何: 稳定标识<几何域标签>? = nil,
        材质分配: 材质分配 = .单材质(nil),
        变换: 稳定标识<变换域标签>,
        灯光: 稳定标识<灯光域标签>? = nil
    ) {
        self.名称 = 名称
        self.几何 = 几何
        self.材质分配 = 材质分配
        self.变换 = 变换
        self.灯光 = 灯光
    }

    /// 是不是灯（灯不渲染几何，只照明）
    var 是灯: Bool { 灯光 != nil }
}

/// 对象关节表：唯一允许同时读多个域的地方（只读，不写别人家的域）。
final class 对象关节表 {

    let 存储: 记录域<对象域标签, 对象关节记录>

    /// 反向占用表：保证 对象↔变换、对象↔灯光 是 1:1 而不是 1:N
    private var 变换占用: [稳定标识<变换域标签>: 稳定标识<对象域标签>] = [:]
    private var 灯光占用: [稳定标识<灯光域标签>: 稳定标识<对象域标签>] = [:]

    init() {
        存储 = 记录域(所有者: .对象)
    }

    var 版本号: UInt64 { 存储.版本号 }
    var 有效数量: Int { 存储.有效数量 }

    func 取(_ id: 稳定标识<对象域标签>) -> 对象关节记录? { 存储.取(id) }

    func 遍历(_ 体: (稳定标识<对象域标签>, 对象关节记录) -> Void) { 存储.遍历(体) }

    func 全部标识() -> [稳定标识<对象域标签>] { 存储.全部标识() }

    /// 检测关系约束（只判断不修复）：灯不产几何、必须有一个身份、1:1 不许重号。
    func 检测关系(_ 记录: 对象关节记录, 排除: 稳定标识<对象域标签>? = nil) -> 域违规? {
        if 记录.几何 != nil && 记录.灯光 != nil {
            return .悬空引用(细节: "同一对象既是几何体又是灯（灯不产几何，不许进几何域）")
        }
        if 记录.几何 == nil && 记录.灯光 == nil {
            return .悬空引用(细节: "对象既没有几何也没有灯光，无法确定身份")
        }
        if let 已占用 = 变换占用[记录.变换], 已占用 != 排除 {
            return .一对多(细节: "变换 \(记录.变换) 已被对象 \(已占用) 占用（对象↔变换 必须 1:1）")
        }
        if let 灯 = 记录.灯光, let 已占用 = 灯光占用[灯], 已占用 != 排除 {
            return .一对多(细节: "灯光 \(灯) 已被对象 \(已占用) 占用（对象↔灯光 必须 1:1）")
        }
        return nil
    }

    @discardableResult
    func 新增(_ 记录: 对象关节记录, 令牌 写令牌: 所有者令牌) -> 稳定标识<对象域标签>? {
        if let 违规 = 存储.预检写入(写令牌) {
            架构记录(.非所有者写入, "对象关节表 拒绝 \(写令牌.名称) 的新增：\(违规.描述)")
            return nil
        }
        if let 违规 = 检测关系(记录) {
            架构记录(关系违规转架构(违规), "对象「\(记录.名称)」关系不合法：\(违规.描述)")
            return nil
        }
        guard let id = 存储.新增(记录, 令牌: 写令牌) else { return nil }
        变换占用[记录.变换] = id
        if let 灯 = 记录.灯光 { 灯光占用[灯] = id }
        return id
    }

    @discardableResult
    func 改(
        _ id: 稳定标识<对象域标签>,
        令牌 写令牌: 所有者令牌,
        _ 体: (inout 对象关节记录) -> Void
    ) -> Bool {
        if let 违规 = 存储.预检写入(写令牌) {
            架构记录(.非所有者写入, "对象关节表 拒绝 \(写令牌.名称) 的改写：\(违规.描述)")
            return false
        }
        guard var 旧 = 存储.取(id) else {
            架构记录(.下标作引用, "对象关节表 改写 \(id) 失败：标识无效")
            return false
        }
        var 新 = 旧
        体(&新)
        if let 违规 = 检测关系(新, 排除: id) {
            架构记录(关系违规转架构(违规), "对象 \(id) 改写后关系不合法：\(违规.描述)")
            return false
        }
        if 旧.变换 != 新.变换 {
            变换占用.removeValue(forKey: 旧.变换)
            变换占用[新.变换] = id
        }
        if 旧.灯光 != 新.灯光 {
            if let 旧灯 = 旧.灯光 { 灯光占用.removeValue(forKey: 旧灯) }
            if let 新灯 = 新.灯光 { 灯光占用[新灯] = id }
        }
        旧 = 新
        return 存储.改(id, 令牌: 写令牌) { $0 = 旧 }
    }

    @discardableResult
    func 请求删除(_ id: 稳定标识<对象域标签>, 令牌 写令牌: 所有者令牌) -> Bool {
        guard let 记录 = 存储.取(id) else {
            架构记录(.下标作引用, "对象关节表 删除 \(id) 失败：标识无效")
            return false
        }
        guard 存储.请求删除(id, 令牌: 写令牌) else { return false }
        变换占用.removeValue(forKey: 记录.变换)
        if let 灯 = 记录.灯光 { 灯光占用.removeValue(forKey: 灯) }
        return true
    }

    /// 跨域只读校验：关节点引用的记录必须真的存在于对应域里。
    /// 这是数据层里唯一允许"一次看多个域"的地方，而它只读不写。
    func 校验引用(
        几何域: 几何域,
        材质域: 材质域,
        灯光域: 灯光域,
        变换域: 变换域
    ) -> [域违规] {
        var 问题: [域违规] = []
        存储.遍历 { id, 记录 in
            if let 几何 = 记录.几何, 几何域.检测标识(几何) != nil {
                问题.append(.悬空引用(细节: "对象 \(id) 指向的几何 \(几何) 不存在"))
            }
            if let 灯 = 记录.灯光 {
                if 灯光域.检测标识(灯) != nil {
                    问题.append(.悬空引用(细节: "对象 \(id) 指向的灯光 \(灯) 不存在"))
                }
            }
            if 变换域.存储.检测标识(记录.变换) != nil {
                问题.append(.悬空引用(细节: "对象 \(id) 指向的变换 \(记录.变换) 不存在"))
            }
            for 材质 in 记录.材质分配.涉及材质 where 材质域.检测标识(材质) != nil {
                问题.append(.悬空引用(细节: "对象 \(id) 指向的材质 \(材质) 不存在"))
            }
        }
        return 问题
    }

    func 只读视图() -> 对象视图 { 对象视图(self) }
}

/// 对象关节表只读视图：零拷贝，只有读。
struct 对象视图 {

    private let 源: 对象关节表
    let 版本号: UInt64

    init(_ 源: 对象关节表) {
        self.源 = 源
        self.版本号 = 源.版本号
    }

    var 数量: Int { 源.有效数量 }

    func 取(_ id: 稳定标识<对象域标签>) -> 对象关节记录? { 源.取(id) }

    func 遍历(_ 体: (稳定标识<对象域标签>, 对象关节记录) -> Void) { 源.遍历(体) }

    func 全部标识() -> [稳定标识<对象域标签>] { 源.全部标识() }

    func 是否仍是最新(_ 层: 对象关节表) -> Bool { 层.版本号 == 版本号 }
}
