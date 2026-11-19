import Foundation

// MARK: - 角色（骨架）相关的场景操作
//
// 角色在场景里就是一个普通物体（参与渲染、选中、跟随父级），
// 这里只放"这个角色身上有哪些件"的查询与整理。

extension 布局Store {

    var 角色物体们: [SceneObject] {
        objects.filter(\.是角色)
    }

    /// 所有角色身上的部件 id：大纲里要把它们藏起来（都收进角色行了）
    var 角色部件ID集: Set<UUID> {
        var 集 = Set<UUID>()
        for 物体 in objects {
            if let 资产 = 物体.角色 { 集.formUnion(资产.部件) }
        }
        return 集
    }

    /// 角色身上挂的部件（按导入时的顺序）
    func 角色部件物体(_ 角色ID: UUID) -> [SceneObject] {
        guard let 角色 = objects.first(where: { $0.id == 角色ID && $0.是角色 }),
              let 资产 = 角色.角色 else { return [] }
        return 资产.部件.compactMap { 部件ID in
            objects.first(where: { $0.id == 部件ID })
        }
    }

    func 所属角色(_ 物体ID: UUID) -> UUID? {
        objects.first { 物体 in
            物体.是角色 && (物体.角色?.部件.contains(物体ID) ?? false)
        }?.id
    }

    /// 这件属于哪个分组：用户改过就用改的，没改过按名字猜
    func 部件分类(物体ID: UUID) -> 角色部件分类 {
        if let 角色ID = 所属角色(物体ID),
           let 角色 = objects.first(where: { $0.id == 角色ID }),
           let 指定 = 角色.角色?.分类[物体ID] {
            return 指定
        }
        let 名 = objects.first(where: { $0.id == 物体ID })?.name ?? ""
        return 角色部件分类.猜(名)
    }

    func 设部件分类(物体ID: UUID, 分类: 角色部件分类) {
        guard let 角色ID = 所属角色(物体ID),
              let i = objects.firstIndex(where: { $0.id == 角色ID }) else { return }
        var 资产 = objects[i].角色 ?? 角色资产()
        资产.分类[物体ID] = 分类
        objects[i].角色 = 资产
    }

    /// 从角色里移出：不再算这一身的一部分，还原成根级普通物体
    func 移出角色部件(_ 物体ID: UUID) {
        guard let 角色ID = 所属角色(物体ID),
              let i = objects.firstIndex(where: { $0.id == 角色ID }) else { return }
        var 资产 = objects[i].角色 ?? 角色资产()
        资产.部件.removeAll { $0 == 物体ID }
        资产.分类[物体ID] = nil
        objects[i].角色 = 资产

        if let j = objects.firstIndex(where: { $0.id == 物体ID }),
           case .对象(let 父) = objects[j].父, 父 == 角色ID {
            objects[j].父 = nil
        }
    }

    /// 把一件普通物体挂进角色（选中后右键用）
    func 加入角色部件(物体ID: UUID, 角色ID: UUID) {
        guard 物体ID != 角色ID,
              let i = objects.firstIndex(where: { $0.id == 角色ID && $0.是角色 }) else { return }
        var 资产 = objects[i].角色 ?? 角色资产()
        guard !资产.部件.contains(物体ID) else { return }
        资产.部件.append(物体ID)
        objects[i].角色 = 资产
        if let j = objects.firstIndex(where: { $0.id == 物体ID }) {
            objects[j].父 = .对象(角色ID)
        }
    }

    func 设物体可见(_ 物体ID: UUID, _ 可见: Bool) {
        guard let i = objects.firstIndex(where: { $0.id == 物体ID }) else { return }
        objects[i].isVisible = 可见
    }
}
