import Foundation

// MARK: - 一条命中

/// 全局搜索的一条命中。
///
/// 这里只描述"搜到了什么、点下去要跳去哪"，不含任何视图。
/// 以后要加类别（相机、节点、关键帧…）只要在 `类别` 里补 case、
/// 再在 `AppStore.搜索结果(for:)` 里补一段匹配，面板 UI 不用动。
struct 搜索命中: Identifiable {
    enum 类别: String, CaseIterable, Identifiable, Sendable {
        case 对象
        case 材质

        var id: String { rawValue }

        /// 分组标题
        var 标题: String {
            switch self {
            case .对象: "场景对象"
            case .材质: "材质"
            }
        }

        var 图标: String {
            switch self {
            case .对象: "cube.transparent"
            case .材质: "circle.hexagongrid.fill"
            }
        }
    }

    let 类别: 搜索命中.类别
    /// 目标实体 id（物体 id / 材质 id）
    let 主键: UUID
    let 名称: String
    let 副标题: String
    /// 右侧预览色：材质给颜色，物体给 nil（走类型图标）
    let 色: PBRColor?

    var id: String { "\(self.类别.rawValue)-\(主键.uuidString)" }
}

// MARK: - 搜索与跳转

/// 全局搜索的全部逻辑都挂在根 Store 上：
/// 它天然同时看见着色域与布局域，不用让两个子 Store 互相认识。
extension AppStore {

    /// 跨域搜索：材质库条目 + 场景物体，按名称匹配。
    /// 排序：完全相同 → 前缀命中 → 命中位置靠前，同分按名字。
    func 搜索结果(for 词: String) -> [搜索命中] {
        let 键 = 词.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !键.isEmpty else { return [] }

        let 物体命中 = layout.objects.compactMap { object -> (分: Int, 命中: 搜索命中)? in
            guard let 分 = 匹配分(object.name, 键) else { return nil }
            let 材质名 = object.materialID.flatMap { shading.material($0)?.name }
            let 副标题 = ([(几何接线.共享.程序形状(键: object.id.uuidString, 兜底: object.mesh)).title] + (材质名.map { [$0] } ?? [])).joined(separator: " · ")
            return (分, 搜索命中(
                类别: .对象,
                主键: object.id,
                名称: object.name,
                副标题: object.isVisible ? 副标题 : 副标题 + " · 已隐藏",
                色: nil
            ))
        }
        .sorted(by: 排序)
        .map(\.命中)

        let 材质命中 = shading.库材质列表.compactMap { material -> (分: Int, 命中: 搜索命中)? in
            guard let 分 = 匹配分(material.name, 键) else { return nil }
            let 用量 = shading.库使用数(for: material.id)
            let 副标题 = (material.是内置预设 ? "内置预设" : "自定义") + " · 被 \(用量) 个物体使用"
            return (分, 搜索命中(
                类别: .材质,
                主键: material.id,
                名称: material.name,
                副标题: 副标题,
                色: material.原始样式.previewColor
            ))
        }
        .sorted(by: 排序)
        .map(\.命中)

        // 类别顺序固定：场景对象在前（更常搜），材质在后
        return 物体命中 + 材质命中
    }

    /// 跳转 + 聚焦。
    ///
    /// 选中语义一律复用「手动点击」那套现成的：这里只负责把面板/光标搬到位置上，
    /// 绝不自己重写一份选中逻辑。
    /// - 物体：不切 tab（对象是全局选择态，着色视口一样认），只让布局大纲把该行滚进视野；
    /// - 材质：材质面板只活在着色工作区 —— 不在着色就切过去，已经在就只把底栏换到材质库页。
    func 跳转到(_ 命中: 搜索命中) {
        全局搜索打开 = false

        switch 命中.类别 {
        case .对象:
            layout.选中(命中.主键)
            layout.大纲聚焦目标 = 命中.主键
            // 选中还不够：让视口把镜头也对准它（等同按一次 F）
            shading.请求视口聚焦(命中.主键)

        case .材质:
            if tab != .shading { tab = .shading }
            shading.底栏页 = .库
            // 选中态一次只属于一个东西：选中材质时把节点/连线的选中让出来，
            // 免得检查器显示的和材质库里高亮的不是同一个
            shading.selectedNodeID = nil
            shading.selectedLinkID = nil
            shading.selectedMaterialID = 命中.主键
            shading.库聚焦目标 = 命中.主键
            shading.note("已定位材质「\(命中.名称)」")
        }
    }

    // MARK: 内部

    private func 排序(
        _ 左: (分: Int, 命中: 搜索命中),
        _ 右: (分: Int, 命中: 搜索命中)
    ) -> Bool {
        左.分 == 右.分 ? 左.命中.名称 < 右.命中.名称 : 左.分 < 右.分
    }

    /// 命中分数：越小越靠前；nil = 不匹配。
    /// 0 完全相同 / 1 前缀 / 10+ 出现在中间（带上位置，越靠前越优先）
    private func 匹配分(_ 文本: String, _ 键: String) -> Int? {
        let 名 = 文本.lowercased()
        if 名 == 键 { return 0 }
        if 名.hasPrefix(键) { return 1 }
        guard let 范围 = 名.range(of: 键) else { return nil }
        return 10 + 名.distance(from: 名.startIndex, to: 范围.lowerBound)
    }
}
