import Foundation
import simd

// MARK: - 变换接线

/// 变换接线：场景模型里的"位置/旋转/缩放"进入变换域的唯一入口。
///
/// 分工钉死：
/// - **模型**（SceneObject.position/rotation/scale）是用户编辑的真相，但**不是**矩阵的真相；
/// - **变换域**是本地矩阵、父子链、世界矩阵的唯一派生方与缓存方；
/// - 本类只做一件事：把模型的 TRS 交给域（值没变就一个字节都不写、版本号也不推），
///   再把域算出来的世界矩阵递回去。任何模块都不许自己再乘一次父子链。
///
/// 灯也走这里（`同步(键:名称:_:)`），所以"灯变换"与"对象变换"是同一套记录、同一套缓存、
/// 同一套版本 —— 不再有独立的"灯变换接线"计数器。
final class 变换接线 {

    static let 共享 = 变换接线()

    /// 一次 TRS 的三元组。用结构体而不是元组：要拿它做 Equatable 比对来"先比后写"。
    struct TRS: Equatable {
        var 位置: SIMD3<Double>
        var 欧拉角: SIMD3<Double>
        var 缩放: SIMD3<Double>

        init(位置: SIMD3<Double>, 欧拉角: SIMD3<Double>, 缩放: SIMD3<Double>) {
            self.位置 = 位置
            self.欧拉角 = 欧拉角
            self.缩放 = 缩放
        }

        init(_ 物体: SceneObject) {
            self.位置 = SIMD3<Double>(物体.position.x, 物体.position.y, 物体.position.z)
            self.欧拉角 = SIMD3<Double>(物体.rotation.x, 物体.rotation.y, 物体.rotation.z)
            self.缩放 = SIMD3<Double>(物体.scale.x, 物体.scale.y, 物体.scale.z)
        }
    }

    private let 层 = 场景数据层.共享

    /// 键表（键→记录 / 键→TRS）会被两条线程同时碰：
    /// 主线程（视口实体定位、拖拽、面板）与渲染线程（PT 转译取灯）。
    /// 域自己有锁，键表也必须锁，否则"拖灯"时就是随机崩溃而不是画面问题。
    /// 锁序固定：先本锁、后域锁；任何路径都不许反向（域内绝不回调本类）。
    private let 键锁 = NSRecursiveLock()

    /// 外部键 → 变换标识 / 上次写进域的 TRS：三张表统一在 `域模版` 里。
    /// 注入的正是上面那把递归锁 —— 写入路径会重入（自检、持锁状态下再调同步）。
    private let 簿: 域模版<变换域标签, TRS>

    /// 键 → 名称：只用于新增记录时给名字与诊断，不参与任何版本判定。
    private var 键到名称: [String: String] = [:]

    /// 灯键集合：由灯光接线登记（它就是灯矩阵的唯一写入方）。
    /// 有了它，变换接线才能把「非灯对象段」的版本单独记出来 —— 否则拖灯也会推进
    /// 「对象变换版本」，PT 侧每帧都误判成"物体被拖动了"，白白 refit 整棵加速结构。
    private var 灯键集: Set<String> = []
    /// 非灯对象段的变换版本（严格单调）：只有非灯记录发生**真实写入**才自增。
    /// 不用「逐记录版本求和」：对象隐藏/删除时和会变小，而版本号必须只增不减。
    private var 非灯变换版本: UInt64 = 0

    /// 诊断计数（不参与判定）
    private(set) var 同步次数: UInt64 = 0
    var 实际写入次数: UInt64 { 簿.实际写入次数 }

    private init() {
        簿 = 域模版(锁: 键锁)
        自检入口()
    }

    /// 自检专用入口：只为了让"版本拆分"断言能拿到一个键表独立的实例（不碰真实场景的键）。
    /// 数据层仍然是同一个 场景数据层.共享 —— 全进程不许有第二份所有者。
    fileprivate init(跑自检: Bool) {
        簿 = 域模版(锁: 键锁)
        if 跑自检 { 自检入口() }
    }

    private func 自检入口() {
        #if DEBUG
        // Debug 自检：一次性，只做矩阵数值断言，不碰画面、不重建任何东西。
        变换矩阵自检.跑一次()
        #endif
    }

    // MARK: 写（唯一写入口，令牌恒为 .变换）

    /// 把一份 TRS 同步进域。
    /// - Returns: 对应的变换记录 id（失败返回 nil，并已按"断言不重建"记录架构违规）
    @discardableResult
    func 同步(键: String, 名称: String, _ trs: TRS) -> 稳定标识<变换域标签>? {
        键锁.lock()
        defer { 键锁.unlock() }
        同步次数 &+= 1

        if let id = 簿.标识(键: 键) {
            if 簿.值(键: 键) == trs, 层.变换.取(id) != nil { return id }
            let 写入 = 层.变换.设本地矩阵(
                id,
                本地矩阵(trs: trs, 父: 层.变换.取(id)?.父),
                令牌: .变换
            )
            if 写入 { 簿.计一次写入() }
            if 写入, !灯键集.contains(键) { 非灯变换版本 &+= 1 }
            簿.记入(键: 键, 标识: id, 值: trs, 版本该推进: false)
            键到名称[键] = 名称
            return 层.变换.取(id) != nil ? id : nil
        }

        let 矩阵 = 变换域.本地矩阵(位置: trs.位置, 欧拉角: trs.欧拉角, 缩放: trs.缩放)
        guard let id = 层.变换.新增(变换记录(名称: 名称, 本地矩阵: 矩阵), 令牌: .变换) else {
            架构记录(.未知标识, "变换接线新增失败：键=\(键)")
            return nil
        }
        簿.记入(键: 键, 标识: id, 值: trs, 版本该推进: false)
        键到名称[键] = 名称
        簿.计一次写入()
        if !灯键集.contains(键) { 非灯变换版本 &+= 1 }
        return id
    }

    /// 灯键登记：由灯光接线在同步时把"当前这一批灯的外部键"报上来。
    /// 只做分类，不写任何变换；灯矩阵仍然只经 `同步(键:名称:_:)` 写入。
    func 登记灯键(_ 键们: Set<String>) {
        键锁.lock()
        defer { 键锁.unlock() }
        灯键集 = 键们
    }

    /// 非灯对象段的变换版本（只读，供 PT / 视口判定"物体变换变没变"）。
    func 取非灯变换版本() -> UInt64 {
        键锁.lock()
        defer { 键锁.unlock() }
        return 非灯变换版本
    }

    #if DEBUG
    /// 自检专用：验证「灯写入不推进非灯版本、物体写入才推进、静止帧谁都不推进」这条口径。
    /// 用键名带前缀的独立实例，只往共享域里留两条不会被引用的记录，不读不改真实场景的键。
    func 自检版本拆分() -> (Bool, String) {
        let 灯键 = "自检#灯", 物键 = "自检#箱"
        登记灯键([灯键])

        let 起 = 取非灯变换版本()
        let 灯段0 = 段版本(键们: [灯键])

        _ = 同步(键: 灯键, 名称: "自检灯", TRS(位置: [1, 2, 3], 欧拉角: [0, 0, 0], 缩放: [1, 1, 1]))
        let 建灯 = 取非灯变换版本()
        _ = 同步(键: 灯键, 名称: "自检灯", TRS(位置: [4, 5, 6], 欧拉角: [0, 0, 0], 缩放: [1, 1, 1]))
        let 拖灯 = 取非灯变换版本()
        let 灯段1 = 段版本(键们: [灯键])

        _ = 同步(键: 物键, 名称: "自检箱", TRS(位置: [0, 0, 0], 欧拉角: [0, 0, 0], 缩放: [1, 1, 1]))
        let 建物 = 取非灯变换版本()
        _ = 同步(键: 物键, 名称: "自检箱", TRS(位置: [7, 0, 0], 欧拉角: [0, 0, 0], 缩放: [1, 1, 1]))
        let 拖物 = 取非灯变换版本()
        let 灯段2 = 段版本(键们: [灯键])

        // 静止帧：同一 TRS 再同步一次，域内值没变 ⇒ 不许推进任何版本
        _ = 同步(键: 物键, 名称: "自检箱", TRS(位置: [7, 0, 0], 欧拉角: [0, 0, 0], 缩放: [1, 1, 1]))
        let 静止 = 取非灯变换版本()

        let 通过 = 建灯 == 起 && 拖灯 == 起
            && 建物 == 起 &+ 1 && 拖物 == 起 &+ 2 && 静止 == 拖物
            && 灯段1 > 灯段0 && 灯段2 == 灯段1
        let 说明 = "⑦ 版本拆分：拖灯后 非灯版本 \(起)→\(拖灯)（应不变）；建物体 \(建物)、拖物体 \(拖物)（应各 +1）；静止帧重复同步 \(静止)（应不变）；灯段版本 \(灯段0)→\(灯段1)（拖灯后应增大），拖物体后 \(灯段2)（应不变）"
        return (通过, 说明)
    }
    #endif

    /// 批量同步场景里的物体（跳过灯：灯由灯光接线按"可见 + 启用"筛选后自己同步，
    /// 两边都写会变成两个写者，正是要消灭的东西）。
    /// - Parameter 物体们: 场景模型里的全部物体
    func 同步对象(_ 物体们: [SceneObject]) {
        for 物体 in 物体们 {
            guard !物体.是灯 else { continue }
            guard 物体.isVisible else { continue }
            _ = 同步(键: 物体.id.uuidString, 名称: 物体.name, TRS(物体))
        }
        // 先把所有物体的本地矩阵都写好，再统一登记父子：
        // 父必须已有记录，否则子会挂到一条不存在的父上（母鸡先于蛋）
        登记父子(物体们)
    }

    // MARK: 读（只读域的派生值）

    /// 模型给的是**世界** TRS，域里存的是**相对父**的本地矩阵。
    /// 换算只换参照系：世界矩阵永远严格等于模型写的那个值，画面一个像素都不动；
    /// 而父一动，子的世界矩阵由域沿链重新派生 —— 「父动子跟随」靠层级，不靠逐帧抄写。
    private func 本地矩阵(trs: TRS, 父: 稳定标识<变换域标签>?) -> simd_double4x4 {
        let 世界 = 变换域.本地矩阵(位置: trs.位置, 欧拉角: trs.欧拉角, 缩放: trs.缩放)
        guard let 父, let 父世界 = 层.变换.世界矩阵(父) else { return 世界 }
        return simd_inverse(父世界) * 世界
    }

    /// 父子登记：把模型里的 `父` 报进域（父指针的唯一真相在域里，本类只做转发）。
    /// 设父的同时把「当前世界」重新烘成本地 —— 只是换参照系，位置不会跳。
    /// 角色部件走的就是这条路：容器是数据父，部件挂在它下面，容器一动整身跟着走。
    func 登记父子(_ 物体们: [SceneObject]) {
        键锁.lock()
        defer { 键锁.unlock() }
        for 物体 in 物体们 {
            guard !物体.是灯, 物体.isVisible else { continue }
            let 键 = 物体.id.uuidString
            guard let id = 簿.标识(键: 键) else { continue }
            // 父没同步过就当根：宁可这一帧不挂，也不建一条指向未知父的悬空指针
            let 目标父 = 物体.父?.对象ID.flatMap { 簿.标识(键: $0.uuidString) }
            guard 层.变换.取(id)?.父 != 目标父 else { continue }
            guard 层.变换.设父(id, 父: 目标父, 令牌: .变换) == nil else { continue }
            guard let trs = 簿.值(键: 键) else { continue }
            _ = 层.变换.设本地矩阵(id, 本地矩阵(trs: trs, 父: 目标父), 令牌: .变换)
        }
    }

    func 变换标识(键: String) -> 稳定标识<变换域标签>? { 簿.标识(键: 键) }

    /// 世界矩阵（Double 口径）：域内派生 + 域内缓存，命中直接返回。
    func 世界矩阵(键: String) -> simd_double4x4? {
        guard let id = 簿.标识(键: 键) else { return nil }
        return 层.变换.世界矩阵(id)
    }

    /// 世界矩阵（Float 口径，视口 / 拾取 / PT 通用）。只在拿到 Double 结果后做一次窄化，
    /// 不再重复做父子链连乘。
    func 世界矩阵F(键: String) -> simd_float4x4? {
        guard let m = 世界矩阵(键: 键) else { return nil }
        return simd_float4x4(
            SIMD4<Float>(Float(m.columns.0.x), Float(m.columns.0.y), Float(m.columns.0.z), Float(m.columns.0.w)),
            SIMD4<Float>(Float(m.columns.1.x), Float(m.columns.1.y), Float(m.columns.1.z), Float(m.columns.1.w)),
            SIMD4<Float>(Float(m.columns.2.x), Float(m.columns.2.y), Float(m.columns.2.z), Float(m.columns.2.w)),
            SIMD4<Float>(Float(m.columns.3.x), Float(m.columns.3.y), Float(m.columns.3.z), Float(m.columns.3.w))
        )
    }

    /// 写通读：先把这个物体的 TRS 交给域（值没变就是纯读），再向域要世界矩阵。
    /// 拾取 / 拖拽 / 导出这类"随时可能被调用"的入口用它，保证读到的永远是最新且唯一的派生值。
    func 世界矩阵(of 物体: SceneObject) -> simd_float4x4 {
        let 键 = 物体.id.uuidString
        _ = 同步(键: 键, 名称: 物体.name, TRS(物体))
        guard let 阵 = 世界矩阵F(键: 键) else {
            架构记录(.未知标识, "变换接线取世界矩阵失败：键=\(键)")
            return matrix_identity_float4x4
        }
        return 阵
    }

    /// 逐记录版本号：几何段缓存之类的"按变换失效"的键用它，不再自己哈希 TRS。
    func 记录版本(键: String) -> UInt64 {
        guard let id = 簿.标识(键: 键) else { return 0 }
        return 层.变换.记录版本(id)
    }

    /// 段版本：这批键对应记录的版本之和。单调不减 —— 任何一条变换真变了，和必变；
    /// 全都没变，和不变。它取代了原来的"灯变换接线独立计数器"。
    func 段版本(键们: [String]) -> UInt64 {
        var ids: [稳定标识<变换域标签>] = []
        ids.reserveCapacity(键们.count)
        for 键 in 键们 {
            if let id = 簿.标识(键: 键) { ids.append(id) }
        }
        return 层.变换.段版本(ids)
    }

    // MARK: 诊断

    var 缓存命中: UInt64 { 层.变换.缓存命中 }
    var 缓存未命中: UInt64 { 层.变换.缓存未命中 }
    var 记录数: Int { 层.变换.有效数量 }

    /// 供自检/日志用：域内世界矩阵与"按当前 TRS 重新换算一次本地矩阵"的一致性。
    /// 只读，不修正（发现不一致就记录，不重建）。
    func 自检一致() -> Bool {
        键锁.lock()
        defer { 键锁.unlock() }
        for (键, 旧) in 簿.全部值() {
            guard let id = 簿.标识(键: 键), let 世界 = 层.变换.世界矩阵(id) else { continue }
            let 本地 = 变换域.本地矩阵(位置: 旧.位置, 欧拉角: 旧.欧拉角, 缩放: 旧.缩放)
            let 期望 = 层.变换.取(id)?.父 == nil ? 本地 : 世界
            if 层.变换.取(id)?.父 == nil, 世界 != 期望 {
                架构记录(.快照版本不一致, "变换缓存与本地矩阵不一致：键=\(键)")
                return false
            }
        }
        return true
    }
}

// MARK: - Debug 自检：矩阵数值断言（一次性，不做画面测试）

#if DEBUG
/// 【口径】路径追踪是蒙特卡洛采样，画面本就不逐位稳定 —— 拿截图 / 像素比对来验证
/// 矩阵正确性是错的手段。正确做法是矩阵数值断言：同一输入下，域算出的矩阵与参考实现
/// 算出的矩阵逐元素比，差异量化成「最大绝对差」并说明来源。
/// 本自检只在首次构造 变换接线 时跑一次，不参与运行期判定，也不做任何「发现不一致就重建」。
enum 变换矩阵自检 {

    static var 已跑 = false

    // MARK: 工具

    static func 宽到双(_ m: simd_float4x4) -> simd_double4x4 {
        simd_double4x4(
            SIMD4<Double>(Double(m.columns.0.x), Double(m.columns.0.y), Double(m.columns.0.z), Double(m.columns.0.w)),
            SIMD4<Double>(Double(m.columns.1.x), Double(m.columns.1.y), Double(m.columns.1.z), Double(m.columns.1.w)),
            SIMD4<Double>(Double(m.columns.2.x), Double(m.columns.2.y), Double(m.columns.2.z), Double(m.columns.2.w)),
            SIMD4<Double>(Double(m.columns.3.x), Double(m.columns.3.y), Double(m.columns.3.z), Double(m.columns.3.w))
        )
    }

    static func 元素(_ m: simd_double4x4) -> [Double] {
        var 出: [Double] = []
        出.reserveCapacity(16)
        for 列 in 0..<4 {
            for 行 in 0..<4 { 出.append(m[列][行]) }
        }
        return 出
    }

    /// 最大绝对差（16 项里最大的一项）+ 相等的元素个数
    static func 比(_ a: simd_double4x4, _ b: simd_double4x4) -> (最大差: Double, 严格相等项: Int) {
        let x = 元素(a), y = 元素(b)
        var 差: Double = 0
        var 等 = 0
        for i in 0..<16 {
            if x[i] == y[i] { 等 += 1 }
            差 = max(差, abs(x[i] - y[i]))
        }
        return (差, 等)
    }

    // MARK: 参考实现甲：历史位级口径（同一套四元数表达、独立书写）

    static func 参考_四元数(位置: SIMD3<Double>, 欧拉角: SIMD3<Double>, 缩放: SIMD3<Double>) -> simd_float4x4 {
        let 度 = Float.pi / 180
        let rx = Float(欧拉角.x) * 度, ry = Float(欧拉角.y) * 度, rz = Float(欧拉角.z) * 度
        let q = simd_quatf(angle: rz, axis: SIMD3<Float>(0, 0, 1))
            * simd_quatf(angle: rx, axis: SIMD3<Float>(1, 0, 0))
            * simd_quatf(angle: ry, axis: SIMD3<Float>(0, 1, 0))
        let sx = Float(缩放.x == 0 ? 1 : 缩放.x)
        let sy = Float(缩放.y == 0 ? 1 : 缩放.y)
        let sz = Float(缩放.z == 0 ? 1 : 缩放.z)
        return simd_float4x4(columns: (
            SIMD4<Float>(q.act(SIMD3<Float>(1, 0, 0)) * sx, 0),
            SIMD4<Float>(q.act(SIMD3<Float>(0, 1, 0)) * sy, 0),
            SIMD4<Float>(q.act(SIMD3<Float>(0, 0, 1)) * sz, 0),
            SIMD4<Float>(Float(位置.x), Float(位置.y), Float(位置.z), 1)
        ))
    }

    // MARK: 参考实现乙：纯矩阵链（Double 三角函数，完全不同的实现路径）

    static func 旋X(_ 角: Double) -> simd_double4x4 {
        let c = cos(角), s = sin(角)
        return simd_double4x4(
            SIMD4<Double>(1, 0, 0, 0),
            SIMD4<Double>(0, c, s, 0),
            SIMD4<Double>(0, -s, c, 0),
            SIMD4<Double>(0, 0, 0, 1)
        )
    }

    static func 旋Y(_ 角: Double) -> simd_double4x4 {
        let c = cos(角), s = sin(角)
        return simd_double4x4(
            SIMD4<Double>(c, 0, -s, 0),
            SIMD4<Double>(0, 1, 0, 0),
            SIMD4<Double>(s, 0, c, 0),
            SIMD4<Double>(0, 0, 0, 1)
        )
    }

    static func 旋Z(_ 角: Double) -> simd_double4x4 {
        let c = cos(角), s = sin(角)
        return simd_double4x4(
            SIMD4<Double>(c, s, 0, 0),
            SIMD4<Double>(-s, c, 0, 0),
            SIMD4<Double>(0, 0, 1, 0),
            SIMD4<Double>(0, 0, 0, 1)
        )
    }

    static func 参考_矩阵链(位置: SIMD3<Double>, 欧拉角: SIMD3<Double>, 缩放: SIMD3<Double>) -> simd_double4x4 {
        let 度 = Double.pi / 180
        let sx = 缩放.x == 0 ? 1 : 缩放.x
        let sy = 缩放.y == 0 ? 1 : 缩放.y
        let sz = 缩放.z == 0 ? 1 : 缩放.z
        let 缩 = simd_double4x4(
            SIMD4<Double>(sx, 0, 0, 0),
            SIMD4<Double>(0, sy, 0, 0),
            SIMD4<Double>(0, 0, sz, 0),
            SIMD4<Double>(0, 0, 0, 1)
        )
        var 移 = matrix_identity_double4x4
        移.columns.3 = SIMD4<Double>(位置.x, 位置.y, 位置.z, 1)
        // 与域内约定同一顺序：先缩、再绕 Z → X → Y、最后平移
        return 移 * 旋Z(欧拉角.z * 度) * 旋X(欧拉角.x * 度) * 旋Y(欧拉角.y * 度) * 缩
    }

    // MARK: 输入样本

    static func 样本() -> [(String, SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)] {
        [
            ("单位", [0, 0, 0], [0, 0, 0], [1, 1, 1]),
            ("纯平移", [1.5, -2.25, 3.75], [0, 0, 0], [1, 1, 1]),
            ("纯旋转 X", [0, 0, 0], [30, 0, 0], [1, 1, 1]),
            ("纯旋转 Y", [0, 0, 0], [0, -45, 0], [1, 1, 1]),
            ("纯旋转 Z", [0, 0, 0], [0, 0, 90], [1, 1, 1]),
            ("三轴复合", [0.3, 1.7, -0.9], [12.5, -33, 78], [1, 1, 1]),
            ("三轴复合 + 非均匀缩放", [-4.2, 0.75, 9.1], [95, 170, -260], [2, 0.5, 1.25]),
            ("含负缩放（镜像）", [1, 2, 3], [10, 20, 30], [-1, 1, 1]),
            ("零缩放（退化按 1）", [0, 0, 0], [0, 0, 0], [0, 2, 0]),
            ("大角度（>360）", [0, 0, 0], [720, -540, 450], [1, 1, 1]),
            ("极小量级", [1e-6, -1e-6, 1e-6], [0.001, 0.002, 0.003], [1, 1, 1]),
            ("极大量级", [1e6, -2e6, 3e6], [180, 180, 180], [1e3, 1e3, 1e3])
        ]
    }

    // MARK: 主入口

    static func 跑一次() {
        guard !已跑 else { return }
        已跑 = true
        let 结 = 执行()
        NSLog("%@", 结.报告)
        if !结.通过 {
            assertionFailure(结.报告)
        }
    }

    static func 执行() -> (通过: Bool, 报告: String) {
        var 行: [String] = []
        var 通过 = true

        // ---- 断言 1：本地矩阵 vs 历史位级参考（期望 memcmp 全等）
        var 最大差1: Double = 0
        var 全等样本 = 0
        for (名, 位, 欧, 缩) in 样本() {
            let 域值 = 变换域.本地矩阵(位置: 位, 欧拉角: 欧, 缩放: 缩)
            let 参考 = 宽到双(参考_四元数(位置: 位, 欧拉角: 欧, 缩放: 缩))
            let r = 比(域值, 参考)
            最大差1 = max(最大差1, r.最大差)
            if r.严格相等项 == 16 { 全等样本 += 1 }
        }
        if 全等样本 != 样本().count { 通过 = false }
        行.append("① 本地矩阵 vs 历史位级参考：16/16 元素逐位相等的样本 \(全等样本)/\(样本().count)，最大绝对差 \(格(最大差1))")

        // ---- 断言 2：本地矩阵 vs 纯矩阵链参考（Double 三角函数，量化 Float 口径舍入）
        var 最大差2: Double = 0
        var 最大差2来源 = ""
        for (名, 位, 欧, 缩) in 样本() {
            let 域值 = 变换域.本地矩阵(位置: 位, 欧拉角: 欧, 缩放: 缩)
            let 参考 = 参考_矩阵链(位置: 位, 欧拉角: 欧, 缩放: 缩)
            let 差 = 比(域值, 参考).最大差
            // 用相对差消掉量级影响：平移 1e6 的样本绝对差天然更大
            let 量级 = max(1, abs(位.x), abs(位.y), abs(位.z), abs(缩.x), abs(缩.y), abs(缩.z))
            let 相对 = 差 / 量级
            if 相对 > 最大差2 { 最大差2 = 相对; 最大差2来源 = 名 }
        }
        行.append("② 本地矩阵 vs 矩阵链参考（数学等价、实现不同）：最大相对差 \(格(最大差2))（最差样本：\(最大差2来源)），来源 = 域内按 Float 计算再扩 Double 的舍入误差")
        if 最大差2 > 1e-6 { 通过 = false }

        // ---- 断言 3：世界矩阵 vs 手工父子链连乘（同一份本地矩阵，期望位级全等）
        let 域 = 变换域()
        guard let 根 = 域.新增(变换记录(名称: "根"), 令牌: .变换),
              let 中 = 域.新增(变换记录(名称: "中"), 令牌: .变换),
              let 叶 = 域.新增(变换记录(名称: "叶"), 令牌: .变换) else {
            return (false, "③ 前置失败：自检用变换域新增被拒")
        }
        _ = 域.设父(中, 父: 根, 令牌: .变换)
        _ = 域.设父(叶, 父: 中, 令牌: .变换)
        let 根本地 = 变换域.本地矩阵(位置: [1, 2, 3], 欧拉角: [15, 25, 35], 缩放: [1, 1, 1])
        let 中本地 = 变换域.本地矩阵(位置: [0.5, -1, 2], 欧拉角: [0, 45, 0], 缩放: [2, 2, 2])
        let 叶本地 = 变换域.本地矩阵(位置: [-3, 0.25, 1], 欧拉角: [60, 0, -20], 缩放: [1, 0.5, 3])
        _ = 域.设本地矩阵(根, 根本地, 令牌: .变换)
        _ = 域.设本地矩阵(中, 中本地, 令牌: .变换)
        _ = 域.设本地矩阵(叶, 叶本地, 令牌: .变换)
        let 域世界 = 域.世界矩阵(叶) ?? matrix_identity_double4x4
        let 手算世界 = 根本地 * 中本地 * 叶本地
        let r3 = 比(域世界, 手算世界)
        if r3.严格相等项 != 16 { 通过 = false }
        行.append("③ 叶节点世界矩阵 vs 手工父子链连乘：16/16 元素逐位相等的项 \(r3.严格相等项)/16，最大绝对差 \(格(r3.最大差))")

        // ---- 断言 4：缓存（命中与未命中位级一致；父动后代必动）
        let 命中前 = 域.缓存未命中
        let 再读 = 域.世界矩阵(叶) ?? matrix_identity_double4x4
        let 命中后 = 域.缓存未命中
        let r4 = 比(再读, 域世界)
        if r4.严格相等项 != 16 || 命中后 != 命中前 { 通过 = false }
        行.append("④ 世界矩阵缓存：二次读取 16/16 位级一致，缓存未命中计数 \(命中前)→\(命中后)（应不再增长）")

        let 新根本地 = 变换域.本地矩阵(位置: [10, 0, 0], 欧拉角: [0, 0, 0], 缩放: [1, 1, 1])
        _ = 域.设本地矩阵(根, 新根本地, 令牌: .变换)
        let 父动后 = 域.世界矩阵(叶) ?? matrix_identity_double4x4
        let 手算父动后 = 新根本地 * 中本地 * 叶本地
        let r5 = 比(父动后, 手算父动后)
        if r5.严格相等项 != 16 { 通过 = false }
        行.append("⑤ dirty 向下传播：改根后叶节点世界矩阵 vs 手工重算 16/16 逐位相等（严格相等项 \(r5.严格相等项)/16，最大绝对差 \(格(r5.最大差))）")

        // ---- 断言 6：灯出光方向（世界矩阵旋转列 vs 欧拉角四元数）
        var 方向最大差: Double = 0
        for (名, _, 欧, _) in 样本() {
            let q = 参考_四元数(位置: [0, 0, 0], 欧拉角: 欧, 缩放: [1, 1, 1])
            let 旧方向 = simd_normalize(q * SIMD4<Float>(0, -1, 0, 0))
            let 域阵 = 变换域.本地矩阵(位置: [0, 0, 0], 欧拉角: 欧, 缩放: [1, 1, 1])
            let 新方向d = 域阵 * SIMD4<Double>(0, -1, 0, 0)
            let 新方向 = simd_normalize(SIMD3<Float>(Float(新方向d.x), Float(新方向d.y), Float(新方向d.z)))
            方向最大差 = max(方向最大差,
                max(abs(Double(新方向.x - 旧方向.x)), max(abs(Double(新方向.y - 旧方向.y)), abs(Double(新方向.z - 旧方向.z)))))
            _ = 名
        }
        行.append("⑥ 灯出光方向（世界矩阵旋转列取 -Y）：与欧拉角四元数口径最大绝对差 \(格(方向最大差))，来源 = 旋转列先乘后归一化的 Float 末位舍入")
        if 方向最大差 > 1e-6 { 通过 = false }

        // ---- 断言 7：灯 / 物体各自的单调版本（拖灯不许推进对象变换版本）
        let 版结果 = 变换接线(跑自检: false).自检版本拆分()
        行.append(版结果.1)
        if !版结果.0 { 通过 = false }

        行.append(通过 ? "结论：全部矩阵数值断言通过（①③④⑤ 位级相等，②⑥ 差异已量化且 < 1e-6，⑦ 版本口径正确）"
                       : "结论：存在未通过的矩阵数值断言，见上")
        return (通过, "【变换矩阵自检】" + 行.joined(separator: " | "))
    }

    static func 格(_ v: Double) -> String { String(format: "%.3e", v) }
}
#endif
