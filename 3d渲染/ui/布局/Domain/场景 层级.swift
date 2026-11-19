import Foundation
import simd

// MARK: - 层级：集合（文件夹）与父子关系
//
// 两条概念分开：
// 1. 集合 = 文件夹，只做组织，**没有变换**（与 Blender 的 Collection 一致）。
//    所以导入时的骨架 / 空物体这类"没有几何的容器"，落到本 App 就变成集合。
// 2. 父子 = 物体之间挂靠，动父物体时子物体跟着走（父动子跟随）。
//
// 本 App 的 SceneObject.position / rotation / scale 存的**始终是世界值**
// （渲染、路径追踪、拾取全都直接读它们，没有局部变换这一层），因此：
// - 改变父子关系时世界位置天然不变，不需要任何补偿；
// - 移动父物体时，必须显式把增量矩阵搬给后代，这个动作由 `联动后代` 负责。

extension 布局Store {

    // MARK: 查表

    func 集合(_ id: UUID?) -> 场景集合? {
        guard let id else { return nil }
        return 集合们.first { $0.id == id }
    }

    /// 某个容器（集合）下的直接子集合
    func 子集合们(_ 父: UUID?) -> [场景集合] {
        集合们.filter { $0.parentID == 父 }
    }

    /// 某个容器下的直接子对象：挂集合的、挂这个物体当子级的，都算它的直接子
    func 子对象们(_ 父: 父引用?) -> [SceneObject] {
        objects.filter { $0.父 == 父 }
    }

    /// 根级对象（没有父）
    var 根对象们: [SceneObject] {
        objects.filter { $0.父 == nil }
    }

    /// 对象是否有子（大纲要不要画展开箭头）
    func 有子对象(_ id: UUID) -> Bool {
        objects.contains { $0.父?.对象ID == id }
    }

    /// 某物体的所有后代物体 ID（父动子跟随的作用范围）
    func 后代对象ID(_ id: UUID) -> [UUID] {
        var 结果: [UUID] = []
        var 待办 = [id]
        while let 当前 = 待办.popLast() {
            for 物体 in objects where 物体.父?.对象ID == 当前 {
                guard !结果.contains(物体.id) else { continue }
                结果.append(物体.id)
                待办.append(物体.id)
            }
        }
        return 结果
    }

    /// 集合（含嵌套子集合）里的所有后代物体 ID
    func 集合内对象ID(_ 集合ID: UUID) -> [UUID] {
        var 结果: [UUID] = []
        var 待办 = [集合ID]
        var 走过: Set<UUID> = []
        while let 当前 = 待办.popLast() {
            guard 走过.insert(当前).inserted else { continue }
            for 子 in 集合们 where 子.parentID == 当前 {
                待办.append(子.id)
            }
            for 物体 in objects where 物体.父?.集合ID == 当前 {
                结果.append(物体.id)
            }
        }
        return 结果
    }

    /// 集合链上是否都可见（父集合藏了，子集合里的东西也算藏了）
    func 集合链可见(_ id: UUID) -> Bool {
        var 当前: UUID? = id
        var 防环 = 0
        while let 步 = 当前, 防环 < 64 {
            guard let c = 集合(步) else { return true }
            if !c.isVisible { return false }
            当前 = c.parentID
            防环 += 1
        }
        return true
    }

    /// 集合的所有后代集合 ID
    func 集合后代ID(_ id: UUID) -> [UUID] {
        var 结果: [UUID] = []
        var 待办 = [id]
        var 走过: Set<UUID> = []
        while let 当前 = 待办.popLast() {
            guard 走过.insert(当前).inserted else { continue }
            for 子 in 集合们 where 子.parentID == 当前 {
                结果.append(子.id)
                待办.append(子.id)
            }
        }
        return 结果
    }

    /// 这个节点能否挂到目标父下（防环：不能把父挂到自己的后代里）
    func 可以设父(_ 节点: 父引用, 到 父: 父引用?) -> Bool {
        guard let 父 else { return true }
        switch 父 {
        case .对象(let 父ID):
            switch 节点 {
            case .对象(let 自身):
                guard 自身 != 父ID else { return false }
                return !后代对象ID(自身).contains(父ID)
            case .集合:
                // 集合不做变换层级，只能挂集合，不能挂物体
                return false
            }
        case .集合(let 集合ID):
            guard 集合(集合ID) != nil else { return false }
            switch 节点 {
            case .对象:
                return true
            case .集合(let 自身):
                return 自身 != 集合ID && !集合后代ID(自身).contains(集合ID)
            }
        }
    }

    // MARK: 集合增删改

    /// 同一个父下不重名
    func 唯一集合名(_ 名: String, 父: UUID?) -> String {
        let 同级 = Set(子集合们(父).map(\.name))
        guard 同级.contains(名) else { return 名 }
        var i = 2
        while 同级.contains("\(名) \(i)") { i += 1 }
        return "\(名) \(i)"
    }

    @discardableResult
    func 新建集合(名: String = "集合", 父: UUID? = nil) -> 场景集合 {
        let c = 场景集合(name: 唯一集合名(名, 父: 父), parentID: 父)
        集合们.append(c)
        // 新建的集合默认展开，父链也一起展开，否则新集合藏在折叠的父里看不见
        var 上 = 父
        var 防环 = 0
        while let 步 = 上, 防环 < 64 {
            if let i = 集合们.firstIndex(where: { $0.id == 步 }) { 集合们[i].展开 = true }
            上 = 集合(步)?.parentID
            防环 += 1
        }
        onChange?()
        return c
    }

    func 重命名集合(_ id: UUID, 为 名: String) {
        let 清 = 名.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !清.isEmpty, let i = 集合们.firstIndex(where: { $0.id == id }) else { return }
        集合们[i].name = 清
        onChange?()
    }

    /// 解散集合：内容（子集合 / 直接子物体）提升到上一级，**不删任何物体**
    func 删除集合(_ id: UUID) {
        guard let 目标 = 集合(id) else { return }
        let 上级 = 目标.parentID
        for i in 集合们.indices where 集合们[i].parentID == id {
            集合们[i].parentID = 上级
        }
        for i in objects.indices where objects[i].父?.集合ID == id {
            objects[i].父 = 上级.map { 父引用.集合($0) }
        }
        集合们.removeAll { $0.id == id }
        onChange?()
    }

    func 切换集合展开(_ id: UUID) {
        guard let i = 集合们.firstIndex(where: { $0.id == id }) else { return }
        集合们[i].展开.toggle()
    }

    func 切换对象展开(_ id: UUID) {
        if 展开对象.contains(id) { 展开对象.remove(id) } else { 展开对象.insert(id) }
    }

    /// 集合显隐：覆盖式（连同里面所有物体一起），与 Blender 的集合显隐一致
    func 设集合可见(_ id: UUID, _ 可见: Bool) {
        guard let i = 集合们.firstIndex(where: { $0.id == id }) else { return }
        集合们[i].isVisible = 可见
        for 物体ID in 集合内对象ID(id) {
            if let j = objects.firstIndex(where: { $0.id == 物体ID }) {
                objects[j].isVisible = 可见
            }
        }
        onChange?()
    }

    // MARK: 设父

    /// 改挂靠关系。世界位置不变（见文件头注释），所以这里只动 `父` 字段。
    @discardableResult
    func 设父(_ id: UUID, 到 父: 父引用?) -> Bool {
        guard let i = objects.firstIndex(where: { $0.id == id }) else { return false }
        guard 可以设父(.对象(id), 到: 父) else {
            note(父 == nil ? "挂不上去" : "不能挂到自己的子级里")
            return false
        }
        objects[i].父 = 父
        // 挂上之后把父链展开，免得挂进折叠的容器里看不见
        if let 父 {
            switch 父 {
            case .对象(let 父ID):
                展开对象.insert(父ID)
            case .集合(let 集合ID):
                var 上: UUID? = 集合ID
                var 防环 = 0
                while let 步 = 上, 防环 < 64 {
                    if let j = 集合们.firstIndex(where: { $0.id == 步 }) { 集合们[j].展开 = true }
                    上 = 集合(步)?.parentID
                    防环 += 1
                }
            }
        }
        onChange?()
        return true
    }

    /// 集合改挂到别的集合下（拖集合用）
    @discardableResult
    func 移动集合(_ id: UUID, 到 父集合: UUID?) -> Bool {
        guard let i = 集合们.firstIndex(where: { $0.id == id }) else { return false }
        guard 可以设父(.集合(id), 到: 父集合.map { 父引用.集合($0) }) else {
            note("不能把集合移到它自己的子级里")
            return false
        }
        集合们[i].parentID = 父集合
        onChange?()
        return true
    }

    /// 拖进来的那些东西（物体 / 集合）挂到目标容器下
    /// - Parameter 目标: 目标容器；nil = 场景根级
    @discardableResult
    func 移入(_ 节点们: [父引用], 到 目标: 父引用?) -> Bool {
        var 成功 = false
        for 节点 in 节点们 {
            // 拖到自己身上 / 自己的子里：跳过，不要炸树
            guard 可以设父(节点, 到: 目标) else { continue }
            switch 节点 {
            case .对象(let id):
                if let i = objects.firstIndex(where: { $0.id == id }) {
                    objects[i].父 = 目标
                    成功 = true
                }
            case .集合(let id):
                if let i = 集合们.firstIndex(where: { $0.id == id }) {
                    集合们[i].parentID = 目标?.集合ID
                    成功 = true
                }
            }
        }
        if 成功 { onChange?() }
        return 成功
    }

    /// 把选中的物体包进一个新集合（大纲右键 / 菜单用）
    @discardableResult
    func 打包选中为集合(名: String = "集合") -> 场景集合? {
        let 目标 = 选中物体们
        guard !目标.isEmpty else { return nil }
        // 新集合挂在当前选中物体所在的容器下，视觉上就出现在原位置
        let 父 = 目标.first?.父?.集合ID
        let c = 新建集合(名: 名, 父: 父)
        for 物体 in 目标 {
            if let i = objects.firstIndex(where: { $0.id == 物体.id }) {
                objects[i].父 = .集合(c.id)
            }
        }
        onChange?()
        return c
    }

    // MARK: 父动子跟随

    /// 场景里有没有真正的父子变换（没有就完全跳过矩阵开销 —— 拖拽是每帧调的）
    var 有父子变换: Bool {
        objects.contains { $0.父?.对象ID != nil }
    }

    /// 改物体前的世界矩阵快照；没有父子关系时返回空表，调用方据此走零开销路径
    func 变换快照() -> [UUID: simd_float4x4] {
        guard 有父子变换 else { return [:] }
        var 表: [UUID: simd_float4x4] = [:]
        for object in objects { 表[object.id] = 拾取几何.世界矩阵(object) }
        return 表
    }

    /// 改完物体后调一次：把"直接改动的物体"的位移带给它的后代（父动子跟随）。
    ///
    /// 本 App 存的是世界变换，所以跟随必须显式搬一遍。规则：
    /// - 只给**没在本轮直接被改**的后代施加增量，被直接改过的节点由它自己继续往下传；
    /// - 每层只对直接子施加一次，同一增量不会叠加两遍（多选父子一起拖也不会双倍）。
    func 联动改动(旧表: [UUID: simd_float4x4]) {
        guard !旧表.isEmpty else { return }
        var 改动集: Set<UUID> = []
        for object in objects {
            guard let 旧 = 旧表[object.id] else { continue }
            if !同矩阵(拾取几何.世界矩阵(object), 旧) { 改动集.insert(object.id) }
        }
        guard !改动集.isEmpty else { return }
        for id in 改动集 {
            guard let 新 = objects.first(where: { $0.id == id }), let 旧 = 旧表[id] else { continue }
            let 增量 = 拾取几何.世界矩阵(新) * 旧.inverse
            下传增量(父: id, 增量: 增量, 改动集: 改动集)
        }
    }

    /// 改一个物体的变换并带走后代（属性检查器 / 视口手柄想省事时用这个入口）
    func 设变换(_ id: UUID, _ mutate: (inout SceneObject) -> Void) {
        updateObject(id, mutate)
    }

    private func 下传增量(父 id: UUID, 增量: simd_float4x4, 改动集: Set<UUID>) {
        for i in objects.indices where objects[i].父?.对象ID == id {
            // 这个后代本轮也被直接改过：它自己会往它的子级传，别再叠一次
            if 改动集.contains(objects[i].id) { continue }
            分解(增量 * 拾取几何.世界矩阵(objects[i]), into: &objects[i])
            下传增量(父: objects[i].id, 增量: 增量, 改动集: 改动集)
        }
    }

    private func 同矩阵(_ a: simd_float4x4, _ b: simd_float4x4) -> Bool {
        for 列 in 0..<4 {
            for 行 in 0..<4 where abs(a[列][行] - b[列][行]) > 1e-6 { return false }
        }
        return true
    }

    /// 世界矩阵 → position / euler / scale（T·R·S 口径，与 拾取几何.世界矩阵 互逆）。
    /// 只用于父动子跟随的数值回写；带切变的结果不保证原样还原（场景里也不会产生）。
    private func 分解(_ m: simd_float4x4, into object: inout SceneObject) {
        let 位移 = m.columns.3
        let c0 = SIMD3<Float>(m.columns.0.x, m.columns.0.y, m.columns.0.z)
        let c1 = SIMD3<Float>(m.columns.1.x, m.columns.1.y, m.columns.1.z)
        let c2 = SIMD3<Float>(m.columns.2.x, m.columns.2.y, m.columns.2.z)
        let s0 = simd_length(c0), s1 = simd_length(c1), s2 = simd_length(c2)
        guard s0 > 1e-6, s1 > 1e-6, s2 > 1e-6 else { return }
        let 基 = simd_float3x3(c0 / s0, c1 / s1, c2 / s2)
        let 镜像 = simd_determinant(基) < 0
        object.position = Vec3(Double(位移.x), Double(位移.y), Double(位移.z))
        object.rotation = 手柄旋转.欧拉角(from: simd_quatf(基))
        object.scale = Vec3(Double(镜像 ? -s0 : s0), Double(s1), Double(s2))
    }
}
