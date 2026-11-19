import Foundation
import Observation

/// 鼠标/键盘此刻作用在哪个区。⌫ 只删这个区里的东西，
/// 否则在材质面板按 Del 会把视口里选中的物体删掉。
enum 交互区域 {
    case 视口
    case 节点编辑器
}

/// 布局工作区状态：场景物体列表、选中物体、物体变换。
/// 材质只读依赖着色域（`shading`），物体增删时默认取材质库第一个作为初值。
@Observable
final class 布局Store {

    var objects: [SceneObject] = [] {
        didSet {
            同步材质选择()
            // 几何域是唯一所有者：模型一变就立刻把几何来源推给域，不等到下一帧视口刷新。
            // 这样任何消费端（拾取、统计、搜索、导出）读域都拿到最新值，不存在"域落后模型"的窗口。
            几何接线.共享.同步(几何源取值.从模型(objects))
        }
    }

    /// 集合（文件夹）列表。只做组织，不带变换：移动集合里的物体靠"父动子跟随"那条链。
    var 集合们: [场景集合] = []

    /// 大纲里对象的展开状态（只有带子对象的行才有意义；集合的展开态存在集合自身上）
    var 展开对象: Set<UUID> = []

    /// 主选中：手柄、检查器、材质联动都读这一个
    var selectedObjectID: UUID? {
        didSet {
            // 任何直接赋值都按单选处理：集合重置成这一个。
            // 多选由 选中(_:加选:) 在赋值之后把集合补回去
            选中集合 = selectedObjectID.map { [$0] } ?? []
            同步材质选择()
        }
    }

    /// 选中集合（多选）：普通点击只有主选中一个，Shift 点击往里加 / 减
    private(set) var 选中集合: Set<UUID> = []

    /// 大纲请求滚动并聚焦到某个物体（全局搜索跳转用）；大纲滚完立刻清空。
    /// 只影响大纲这一条列表的可见范围，不动选中态 —— 选中由 `选中(_:)` 负责。
    var 大纲聚焦目标: UUID?

    /// 材质来源（着色域）弱引用，仅读取
    weak var shading: 着色Store?

    /// 当前交互区域。默认视口；鼠标一进材质区就会被切走。
    var 焦点: 交互区域 = .视口

    /// 数据变更 → 根 Store 落盘
    var onChange: (() -> Void)?
    var onNote: ((String) -> Void)?

    // MARK: 派生

    var selectedObject: SceneObject? {
        guard let selectedObjectID else { return nil }
        return objects.first { $0.id == selectedObjectID }
    }

    func note(_ message: String) { onNote?(message) }

    // MARK: 选中

    /// 选中的物体（按场景顺序），多选时用于批量显隐 / 聚焦
    var 选中物体们: [SceneObject] {
        guard !选中集合.isEmpty else { return [] }
        return objects.filter { 选中集合.contains($0.id) }
    }

    /// 选中的且可见的物体
    var 可见选中物体们: [SceneObject] {
        选中物体们.filter(\.isVisible)
    }

    func 是否选中(_ id: UUID?) -> Bool {
        guard let id else { return false }
        return 选中集合.contains(id)
    }

    /// 视口 / 物体列表统一的选中入口。
    /// - 普通点击：单选，整个集合替换成这一个
    /// - 加选（Shift）：已在集合里就移出（DCC 通用的切换语义），否则追加
    func 选中(_ id: UUID?, 加选: Bool = false) {
        // 点选物体本身就是"我在视口干活"的证明：⌫ 从此归视口
        焦点 = .视口
        guard 加选 else {
            selectedObjectID = id
            return
        }
        // Shift 点空白：保持当前选择不动（清空是普通点击的事）
        guard let id else { return }

        var 集合 = 选中集合
        if 集合.contains(id) {
            集合.remove(id)
            // 主选中被减掉时，顺延到集合里还剩的第一个物体
            selectedObjectID = objects.first { 集合.contains($0.id) }?.id
            选中集合 = 集合
        } else {
            集合.insert(id)
            selectedObjectID = id      // 主选中跟到刚点中的这个
            选中集合 = 集合            // didSet 刚重置成 [id]，这里补回完整集合
        }
    }

    /// 选中物体 → 材质节点编辑器自动切到该物体的材质，
    /// 否则改的是别的材质，模型当然"不跟着变"
    private func 同步材质选择() {
        guard let shading,
              let object = objects.first(where: { $0.id == selectedObjectID }),
              let materialID = object.materialID
        else { return }
        guard shading.selectedMaterialID != materialID else { return }
        shading.selectedMaterialID = materialID
        shading.selectedNodeID = nil
    }

    // MARK: 可见性 / 独立显示

    /// 独立显示（isolate）之前的隐藏集合。
    /// 非 nil 表示正处于独立显示状态，退出时按这份快照原样还原，
    /// 这样"独立显示前本来就藏着的物体"退出后仍然是藏着的。
    private var 独立显示前隐藏: Set<UUID>?

    var 是否独立显示: Bool { 独立显示前隐藏 != nil }

    /// H：隐藏所有选中物体，返回实际藏掉的物体（多选时是多个）
    @discardableResult
    func 隐藏选中() -> [SceneObject] {
        let 目标 = 可见选中物体们
        guard !目标.isEmpty else { return [] }
        for index in objects.indices where 选中集合.contains(objects[index].id) {
            objects[index].isVisible = false
        }
        // 选中保持不变（Blender 行为）：撤销隐藏后原物体仍在选中状态，
        // 手柄会因为实体被禁用而自动消失，不会飘在看不见的位置
        onChange?()
        return 目标
    }

    /// Alt+H：取消所有隐藏（连同独立显示状态一起退出）
    @discardableResult
    func 全部取消隐藏() -> Bool {
        独立显示前隐藏 = nil
        var changed = false
        for index in objects.indices where !objects[index].isVisible {
            objects[index].isVisible = true
            changed = true
        }
        if changed { onChange?() }
        return changed
    }

    /// 长按 F：独立显示——只留选中的这些物体，其余全部藏起来
    @discardableResult
    func 独立显示选中() -> Bool {
        guard !选中集合.isEmpty,
              objects.contains(where: { 选中集合.contains($0.id) })
        else { return false }
        if 独立显示前隐藏 == nil {
            独立显示前隐藏 = Set(objects.filter { !$0.isVisible }.map(\.id))
        }
        var changed = false
        for index in objects.indices {
            // 选中物体本身就是唯一该显示的，选中不变、无需转移
            let 该显示 = 选中集合.contains(objects[index].id)
            if objects[index].isVisible != 该显示 {
                objects[index].isVisible = 该显示
                changed = true
            }
        }
        if changed { onChange?() }
        return true
    }

    /// Alt+F：取消独立显示，回到进入前的可见性
    @discardableResult
    func 取消独立显示() -> Bool {
        guard let 快照 = 独立显示前隐藏 else { return false }
        独立显示前隐藏 = nil
        var changed = false
        for index in objects.indices {
            let 该显示 = !快照.contains(objects[index].id)
            if objects[index].isVisible != 该显示 {
                objects[index].isVisible = 该显示
                changed = true
            }
        }
        // 选中不动：Alt+F 只还原可见性，跟 Blender 一致
        if changed { onChange?() }
        return true
    }

    // MARK: 场景编辑

    func assign(_ materialID: UUID?, to objectID: UUID) {
        guard let index = objects.firstIndex(where: { $0.id == objectID }) else { return }
        // 材质↔对象是 M:N，引用计数与引用者的唯一口径在数据层材质接线里（按对象全部槽位派生）：
        // 换主槽只改 0 号槽，副槽原样带过去。若在这里按"单材质"重置整表，
        // 只被副槽引用的材质就会从计数里漏掉，接着被当成 0 引用误删。
        var 槽位 = objects[index].材质槽位表
        if 槽位.isEmpty { 槽位 = [materialID] } else { 槽位[0] = materialID }
        switch 材质接线.共享.绑定(对象: objectID, 槽位表: 槽位) {
        case .变更, .无需变更:
            objects[index].materialID = materialID
        case .未知材质(let id):
            note("该材质不在材质域里（id=\(id)），已拒绝绑定")
            return
        case .引用计数错乱(let 原因):
            note("材质引用计数错乱：\(原因)，已拒绝绑定")
            return
        }
        // 换材质后把节点编辑器也切过去，方便立刻改参数
        if let materialID, selectedObjectID == objectID {
            shading?.selectedMaterialID = materialID
            shading?.selectedNodeID = nil
        }
        onChange?()
    }

    func updateObject(_ id: UUID, _ mutate: (inout SceneObject) -> Void) {
        guard let index = objects.firstIndex(where: { $0.id == id }) else { return }
        let 旧表 = 变换快照()
        mutate(&objects[index])
        联动改动(旧表: 旧表)
        onChange?()
    }

    /// 批量变换：多选拖手柄时一次改完、只落盘一次，
    /// 否则 N 个物体就是 N 次 onChange（N 次存盘 + N 次视图刷新）
    func updateObjects(_ mutate: (inout [SceneObject]) -> Void) {
        let 旧表 = 变换快照()
        mutate(&objects)
        联动改动(旧表: 旧表)
        onChange?()
    }

    /// 加入一个已经造好的物体（初始内容预设走这条：几何已经在 导入网格库 里）
    func addObject(_ object: SceneObject) {
        objects.append(object)
        selectedObjectID = object.id
        onChange?()
    }

    func addObject(mesh: MeshKind) {
        let object = SceneObject(
            name: "\(mesh.title) \(objects.count + 1)",
            mesh: mesh,
            position: Vec3(0, mesh == .plane ? 0 : 1, 0),
            materialID: shading?.库材质列表.first?.id
        )
        objects.append(object)
        selectedObjectID = object.id
        onChange?()
    }

    func deleteObject(_ id: UUID) {
        // 子物体不连坐：先提升到被删物体的上一级，免得父子链突然悬空
        let 上级 = objects.first { $0.id == id }?.父
        for i in objects.indices where objects[i].父?.对象ID == id {
            objects[i].父 = 上级
        }
        objects.removeAll { $0.id == id }
        // 轨道不能跟着变成孤儿：动画域自己收拾自己的账，布局不替它保管
        时间轴域.共享.删除主体轨道(id)
        // 多选里删掉一个：其余选中保持，主选中被删就顺延到剩下第一个
        let 剩下 = 选中集合.subtracting([id])
        if selectedObjectID == id {
            selectedObjectID = objects.first { 剩下.contains($0.id) }?.id
            选中集合 = 剩下
        } else {
            选中集合 = 剩下
        }
        onChange?()
    }

    /// ⌫ / X：一次删掉所有选中的物体（多选时整批删），返回删掉几个
    @discardableResult
    func 删除选中物体() -> Int {
        let 目标 = 选中集合
        guard !目标.isEmpty else { return 0 }
        // 整批删也守同一条规矩：被删物体的子级提升到它原来的上级
        var 上级表: [UUID: 父引用?] = [:]
        for object in objects where 目标.contains(object.id) { 上级表[object.id] = object.父 }
        for i in objects.indices {
            guard let 父 = objects[i].父?.对象ID, 目标.contains(父) else { continue }
            objects[i].父 = 上级表[父] ?? nil
        }
        objects.removeAll { 目标.contains($0.id) }
        for 编号 in 目标 { 时间轴域.共享.删除主体轨道(编号) }
        selectedObjectID = nil
        选中集合 = []
        onChange?()
        return 目标.count
    }

    /// A：全选。跟 Blender 一致 —— 隐藏的物件也在名单里，
    /// 只是看不见也点不到，手柄不会因为它们飘在屏幕外
    func 全选() {
        guard !objects.isEmpty else { return }
        selectedObjectID = objects[0].id
        // selectedObjectID 的 didSet 会把集合重置成单元素，这里补回完整集合
        选中集合 = Set(objects.map(\.id))
    }

    /// Alt+A：取消选择
    func 取消选择() {
        selectedObjectID = nil
    }

    /// ⌘D：原位复制选中物体（沿 X/Z 各让一点，免得和原件完全重叠看不出效果），
    /// 复制完主选与集合都落到新副本上，接着就能直接拖
    @discardableResult
    func 复制选中() -> Int {
        let 源 = objects.filter { 选中集合.contains($0.id) }
        guard !源.isEmpty else { return 0 }
        var 副本: [SceneObject] = []
        for object in 源 {
            副本.append(
                SceneObject(
                    name: "\(object.name) 副本",
                    mesh: object.mesh,
                    导入网格ID: object.导入网格ID,
                    导入符号: object.导入符号,
                    position: Vec3(object.position.x + 0.25, object.position.y, object.position.z + 0.25),
                    rotation: object.rotation,
                    scale: object.scale,
                    materialID: object.materialID,
                    isVisible: object.isVisible,
                    灯光: object.灯光
                )
            )
        }
        // 副本跟着原件留在同一个容器里；只是"选中的父也一起被复制"时，把副本自成一棵新树
        var 原到新: [UUID: UUID] = [:]
        for (i, object) in 源.enumerated() { 原到新[object.id] = 副本[i].id }
        for i in 副本.indices {
            let 原父 = 源[i].父
            副本[i].父 = 原父.map { 引用 -> 父引用 in
                switch 引用 {
                case .对象(let 父ID): return .对象(原到新[父ID] ?? 父ID)
                case .集合: return 引用
                }
            }
        }
        objects.append(contentsOf: 副本)
        selectedObjectID = 副本.first?.id
        选中集合 = Set(副本.map(\.id))     // didSet 刚重置成 [第一个]，补回整批
        onChange?()
        return 副本.count
    }

    /// 材质被删除后，解除场景里所有物体的绑定
    /// 【判据不能只问反向索引】删除路径通常先把槽位表清干净，走到这里时反向索引已经是空集，
    /// 只按引用者扫会一个对象都扫不到，objects 里的 materialID 就留在原地指向一条已经不在域里的材质：
    /// 视口不重套材质、PT 转译查不到材质，表现就是"删完画面纹丝不动，切一次模式才看到材质没了"。
    func unbindMaterial(_ materialID: UUID) {
        // 引用者集合问反向索引；object.materialID 再兜一层，谁先清过槽都不影响这条判据
        let 引用者 = 材质接线.共享.引用者(资产: materialID)
        var changed = false
        for index in objects.indices {
            guard objects[index].materialID == materialID || 引用者.contains(objects[index].id) else { continue }
            _ = 材质接线.共享.解绑(对象: objects[index].id)
            objects[index].materialID = nil
            changed = true
        }
        if changed { onChange?() }
    }

    // MARK: 载入 / 重置

    func load(from snapshot: ProjectSnapshot) {
        // 旧版出厂场景里的 Floor 是 14×14 竖直平面立在原点，正好糊在相机前；
        // 地面由视口自己提供，这条无材质 Floor 直接丢弃
        objects = snapshot.objects.filter { !($0.name == "Floor" && $0.materialID == nil) }
        // 载入后按存档重建 (对象 → 全部材质槽位) 绑定：引用计数与引用者跟着当前工程走（幂等，先清后建）。
        // 这里必须传整张槽位表：旧档里存在"只被副槽引用"的物体，只按 materialID 重建会让那些材质变成 0 引用。
        let 绑定结果 = 材质接线.共享.重建绑定(
            Dictionary(objects.map { 物 in (物.id, 物.材质槽位表) }, uniquingKeysWith: { 甲, _ in 甲 })
        )
        if !绑定结果.未知.isEmpty {
            note("存档里 \(绑定结果.未知.count) 个材质已不在材质域中，相关物体按无材质载入")
        }
        集合们 = snapshot.集合们 ?? []
        // 父引用指向已不存在的节点（存档被外部改过 / 那半边被删）时断链回根，免得树里凭空少东西
        objects = objects.map { 物体 in
            guard let 父 = 物体.父 else { return 物体 }
            switch 父 {
            case .对象(let id):
                guard objects.contains(where: { $0.id == id }) else { var 改 = 物体; 改.父 = nil; return 改 }
            case .集合(let id):
                guard 集合们.contains(where: { $0.id == id }) else { var 改 = 物体; 改.父 = nil; return 改 }
            }
            return 物体
        }
        // 老存档 / 旧版面板生成的物体只有 mesh 枚举、几何没进池：打开时当场把内置几何
        // 补进 导入网格库 并回填 ID —— 不留「App 看得见、空格预览看不见」的物体
        objects = objects.map { 物体 in
            guard 物体.导入网格ID == nil else { return 物体 }
            var 补齐 = 物体
            补齐.设置几何来源(导入网格: 几何接线.共享.存入([导出接入.内置网格(物体.mesh)]))
            return 补齐
        }
        selectedObjectID = snapshot.selectedObjectID ?? objects.first?.id
    }

    /// 构造「出厂基础场景」的布局域：三个内建图元（着色球 / 金属圆环 / 玻璃球）。
    ///
    /// 整体替换 `objects`，不做增量清理 —— 历史文档里导入的物体压根不会出现在新数组里。
    func 载入基础场景() {
        let ids = (shading?.库材质列表 ?? []).map(\.id)
        objects = 初始项目.objects(materialIDs: ids)
        selectedObjectID = objects.first?.id
        // 独立显示（solo）是瞬态的视图过滤，新文档不该带着上一个文档的隔离状态
        独立显示前隐藏 = nil
        集合们 = []
        展开对象 = []
    }
}
