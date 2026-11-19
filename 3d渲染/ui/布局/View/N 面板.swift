import SwiftUI

// MARK: - N 面板（Blender 手感：视口右侧抽屉）

/// N 面板的分页。每页只读自己那一域的数据，互相不认识。
///
/// 口径：
/// - 变换 / 特效 读的是「选中的场景对象」，写入一律走 `布局Store.updateObject`；
/// - 物理 读的是全局单体 `着色Store.物理域`，不属于任何对象；
/// - 特效 页是发射器参数（真值在 SceneObject.特效），参数组按 种类 走：粒子/水 = 粒子池，火/烟 = 体积场。
enum N面板页: String, CaseIterable, Identifiable {
    case 变换
    case 特效
    case 物理

    var id: String { rawValue }
    var 标题: String { rawValue }

    var 符号: String {
        switch self {
        case .变换: "move.3d"
        case .特效: "sparkles"
        case .物理: "atom"
        }
    }
}

/// 视口右侧的 N 面板：**挤压式**，把视口挤窄，不覆盖画面、不吃视口高度。
///
/// 它不自己存任何状态：可见性与当前页都在 `着色Store`（两个工作区共用一套），
/// 按 N 只管切那个布尔值。
struct N面板: View {
    @Binding var 页: N面板页
    var 收起: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            页签条
            Rectangle().fill(Theme.divider).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch 页 {
                    case .变换: 变换参数页()
                    case .特效: 特效参数页()
                    case .物理: 物理参数页()
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 300)
        .background(Theme.inspectorBackground)
    }

    // MARK: 页签条

    private var 页签条: some View {
        HStack(spacing: 2) {
            ForEach(N面板页.allCases) { 项 in
                Button {
                    页 = 项
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: 项.符号)
                            .font(.system(size: 11))
                        Text(项.标题)
                            .font(.system(size: 9))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background(
                        页 == 项 ? Theme.主色.opacity(0.16) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                    .foregroundStyle(页 == 项 ? Theme.主色 : Theme.textSecondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(项.标题)
            }

            Button(action: 收起) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 20, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("收起（N）")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}

// MARK: - 共用小件

/// 一行「标题 + 数值框」。数值框复用变换那套（回车提交、失焦也提交）。
private struct 参数数值行: View {
    let 标题: String
    let 值: Double
    var 范围: ClosedRange<Double>? = nil
    let 提交: (Double) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(标题)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 76, alignment: .leading)

            变换数值输入(值: 值) { 新 in
                提交(范围.map { min(max(新, $0.lowerBound), $0.upperBound) } ?? 新)
            }
        }
    }
}

/// 一行颜色（线性 0…1 的 RGB 三格）
private struct 参数颜色行: View {
    let 标题: String
    let 颜色: Vec3
    let 提交: (Vec3) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionTitle(text: 标题)
            HStack(spacing: 6) {
                参数数值行(标题: "R", 值: 颜色.x, 范围: 0...1) { v in var c = 颜色; c.x = v; 提交(c) }
                参数数值行(标题: "G", 值: 颜色.y, 范围: 0...1) { v in var c = 颜色; c.y = v; 提交(c) }
                参数数值行(标题: "B", 值: 颜色.z, 范围: 0...1) { v in var c = 颜色; c.z = v; 提交(c) }
            }
        }
    }
}

/// 三轴一行（位置 / 旋转 / 缩放 / 力）
private struct 参数三轴行: View {
    let 标题: String
    let 值: Vec3
    let 提交: (Vec3) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionTitle(text: 标题)
            HStack(spacing: 6) {
                参数数值行(标题: "X", 值: 值.x) { v in var c = 值; c.x = v; 提交(c) }
                参数数值行(标题: "Y", 值: 值.y) { v in var c = 值; c.y = v; 提交(c) }
                参数数值行(标题: "Z", 值: 值.z) { v in var c = 值; c.z = v; 提交(c) }
            }
        }
    }
}

private struct 无选中提示: View {
    let 说明: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "cube.dashed")
                .font(.system(size: 22))
                .foregroundStyle(Theme.textTertiary)
            Text(说明)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 26)
    }
}

// MARK: - 变换页（从布局工作区整体搬过来）

private struct 变换参数页: View {
    @Environment(布局Store.self) private var store
    @Environment(着色Store.self) private var shading

    var body: some View {
        if let object = store.selectedObject {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Image(systemName: object.symbol)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Text(object.name)
                        .font(.system(size: 12.5, weight: .semibold))
                    Spacer()
                }

                vecEditor("位置", 字段: "pos", 物体: object.id, value: object.position) { next in
                    store.updateObject(object.id) { $0.position = next }
                }
                vecEditor("旋转", 字段: "rot", 物体: object.id, value: object.rotation) { next in
                    store.updateObject(object.id) { $0.rotation = next }
                }
                vecEditor("缩放", 字段: "scale", 物体: object.id, value: object.scale) { next in
                    store.updateObject(object.id) { $0.scale = next }
                }

                SectionTitle(text: "网格")
                HStack(spacing: 4) {
                    ForEach(MeshKind.allCases) { mesh in
                        Button {
                            // 换回程序形状时必须清掉导入网格引用，否则改完还是显示原来那块导入网格
                            store.updateObject(object.id) { $0.设置几何来源(程序形状: mesh, 导入网格: nil) }
                        } label: {
                            Image(systemName: mesh.symbol)
                                .font(.system(size: 10))
                                .frame(width: 24, height: 22)
                        }
                        .buttonStyle(.bordered)
                        .tint(object.mesh == mesh ? .accentColor : .gray)
                    }
                }

                SectionTitle(text: "绑定材质")
                Menu {
                    ForEach(shading.库材质列表) { material in
                        Button(material.name) {
                            // 从库里选 = 上新的一份原始样式实例
                            store.assign(shading.实例ID(for: material.id), to: object.id)
                        }
                    }
                    Divider()
                    Button("解除绑定") { store.assign(nil, to: object.id) }
                } label: {
                    HStack {
                        Text(shading.material(object.materialID)?.name ?? "未绑定")
                            .font(.system(size: 11))
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8))
                    }
                }
                .menuStyle(.borderlessButton)

                Button("删除物体", role: .destructive) {
                    store.deleteObject(object.id)
                }
                .controlSize(.small)
            }
        } else {
            无选中提示(说明: "未选中物体")
        }
    }

    private func vecEditor(_ title: String, 字段: String, 物体: UUID, value: Vec3, onChange: @escaping (Vec3) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionTitle(text: title)
            HStack(spacing: 6) {
                axisField("X", 键: 动画接线.键(物体: 物体, 字段: 字段, 轴: "x"), value.x) { next in
                    var copy = value; copy.x = next; onChange(copy)
                }
                axisField("Y", 键: 动画接线.键(物体: 物体, 字段: 字段, 轴: "y"), value.y) { next in
                    var copy = value; copy.y = next; onChange(copy)
                }
                axisField("Z", 键: 动画接线.键(物体: 物体, 字段: 字段, 轴: "z"), value.z) { next in
                    var copy = value; copy.z = next; onChange(copy)
                }
            }
        }
    }

    /// 一根轴 = 一个 K 参控件（关键帧点 + 数值框）。
    /// 控件只知道通道键，不知道自己在编辑位置还是缩放 —— 打帧逻辑全在控件与动画域里。
    private func axisField(_ axis: String, 键: String, _ value: Double, onChange: @escaping (Double) -> Void) -> some View {
        K参控件(键: 键, 值: value, 轴名: axis, 提交: onChange)
            .frame(maxWidth: .infinity)
    }
}

// MARK: - 特效页

private struct 特效参数页: View {
    @Environment(布局Store.self) private var store
    /// 只有"打开特效容器窗口"要用它（容器面板要材质库来塞材质）
    @Environment(着色Store.self) private var shading

    var body: some View {
        if let object = store.selectedObject {
            if let 设置 = object.特效 {
                编辑器(物体: object.id, 设置: 设置)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    无选中提示(说明: "「\(object.name)」还不是发射器")
                    Button("为它添加粒子发射器") {
                        store.updateObject(object.id) { $0.特效 = 特效设置(种类: .粒子) }
                    }
                    .controlSize(.small)
                }
            }
        } else {
            无选中提示(说明: "选中一个物体再来调特效")
        }
    }

    private func 编辑器(物体 id: UUID, 设置 s: 特效设置) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // 品类
            HStack(spacing: 6) {
                ForEach(特效种类.allCases) { 种 in
                    Button {
                        改(id) { $0.种类 = 种; $0.最大粒子数 = 种.默认最大粒子数 }
                    } label: {
                        VStack(spacing: 2) {
                            Image(systemName: 种.符号).font(.system(size: 10))
                            Text(种.名称).font(.system(size: 8.5))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.bordered)
                    .tint(s.种类 == 种 ? .accentColor : .gray)
                }
            }

            Toggle("发射（启用）", isOn: 绑定(id, \.启用))
                .toggleStyle(.switch)
                .controlSize(.mini)

            // 选什么类型，就只显示那个类型真正生效的参数。
            switch s.种类 {
            case .粒子, .水:
                粒子型参数(id: id, s: s)
            case .火, .烟:
                体积型参数(id: id, s: s)
            }
        }
    }

    /// 一行「发射体」：决定这团特效长在谁身上。
    ///
    /// 默认 = 自己（旧工程行为不变）；指到别的物体 = 直接吃那个物体的几何与世界矩阵。
    /// 火/烟沿它的几何表面烧，粒子/水跟着它的位置与朝向喷。
    /// 特效对象本身的变换照旧可打关键帧，改发射体不会动它。
    @ViewBuilder
    private func 发射体行(id: UUID, s: 特效设置) -> some View {
        // 只列实体几何：把火挂到另一个特效的占位 torus 上没有意义，只会让人眼更乱
        let 候选 = store.objects.filter { $0.isVisible && $0.id != id && $0.特效 == nil }
        let 当前 = 候选.first { $0.id == s.发射体对象ID }
        HStack(spacing: 8) {
            Text("发射体")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 76, alignment: .leading)
            Menu {
                Button("本对象（自身几何）") { 改(id) { $0.发射体对象ID = nil } }
                if !候选.isEmpty {
                    Divider()
                    ForEach(候选) { 物 in
                        Button(物.name) { 改(id) { $0.发射体对象ID = 物.id } }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(当前?.name ?? "本对象")
                        .font(.system(size: 11))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .menuStyle(.borderlessButton)
        }
        Text("火 / 烟贴着发射体的几何表面烧；粒子 / 水跟着它的位置与朝向喷。")
            .font(.system(size: 10))
            .foregroundStyle(Theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
        // 容器优先：里面有启用源时，上面这行"发射体"选谁都不再生效（让位给容器几何）
        if s.是特效容器 {
            Text("容器里有 \(s.源数) 个发射源在接管发射，上面选谁都不再算数。")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        Button(s.是特效容器 ? "调整容器里的发射源…" : "把发射源塞进容器…") {
            特效窗口控制器.shared.打开(特效ID: id, store: store, shading: shading)
        }
        .controlSize(.small)
    }

    /// 走 GPU 粒子池的两类（火花 / 浮尘 / 溅沫、水滴）：按池容量与逐粒子积分参数给。
    @ViewBuilder
    private func 粒子型参数(id: UUID, s: 特效设置) -> some View {
        SectionTitle(text: "发射")
        发射体行(id: id, s: s)
        参数数值行(标题: "发射率 /秒", 值: s.发射率, 范围: 0...200000) { v in 改(id) { $0.发射率 = v } }
        参数数值行(标题: "最大粒子数", 值: Double(s.最大粒子数), 范围: 100...200000) { v in 改(id) { $0.最大粒子数 = Int(v) } }

        SectionTitle(text: "运动")
        参数数值行(标题: "寿命 秒", 值: s.寿命, 范围: 0.05...60) { v in 改(id) { $0.寿命 = v } }
        参数数值行(标题: "初速 米/秒", 值: s.初速, 范围: 0...50) { v in 改(id) { $0.初速 = v } }
        参数数值行(标题: "速度随机", 值: s.速度随机, 范围: 0...1) { v in 改(id) { $0.速度随机 = v } }
        参数数值行(标题: "扩散角 度", 值: s.扩散角, 范围: 0...180) { v in 改(id) { $0.扩散角 = v } }
        参数数值行(标题: "重力倍率", 值: s.重力倍率, 范围: 0...5) { v in 改(id) { $0.重力倍率 = v } }
        参数数值行(标题: "风力倍率", 值: s.风力倍率, 范围: 0...5) { v in 改(id) { $0.风力倍率 = v } }
        参数数值行(标题: "湍流", 值: s.湍流, 范围: 0...1) { v in 改(id) { $0.湍流 = v } }

        SectionTitle(text: "尺寸")
        参数数值行(标题: "出生 米", 值: s.起始尺寸, 范围: 0.001...5) { v in 改(id) { $0.起始尺寸 = v } }
        参数数值行(标题: "死亡 米", 值: s.终止尺寸, 范围: 0.001...5) { v in 改(id) { $0.终止尺寸 = v } }

        SectionTitle(text: "外观")
        参数颜色行(标题: "出生颜色", 颜色: s.起始颜色) { v in 改(id) { $0.起始颜色 = v } }
        参数颜色行(标题: "死亡颜色", 颜色: s.终止颜色) { v in 改(id) { $0.终止颜色 = v } }
        参数数值行(标题: "不透明度", 值: s.不透明度, 范围: 0...1) { v in 改(id) { $0.不透明度 = v } }

        Toggle("与场景碰撞（SDF）", isOn: 绑定(id, \.碰撞))
            .toggleStyle(.switch)
            .controlSize(.mini)
    }

    /// 走体积 raymarch 的两类（火 / 烟）：只有下面这些字段进介质场，其余字段给了也不生效，就不摆出来。
    @ViewBuilder
    private func 体积型参数(id: UUID, s: 特效设置) -> some View {
        SectionTitle(text: "羽流")
        发射体行(id: id, s: s)
        参数数值行(标题: "寿命 秒", 值: s.寿命, 范围: 0.05...60) { v in 改(id) { $0.寿命 = v } }
        参数数值行(标题: "初速 米/秒", 值: s.初速, 范围: 0...50) { v in 改(id) { $0.初速 = v } }
        参数数值行(标题: "扩散角 度", 值: s.扩散角, 范围: 0...180) { v in 改(id) { $0.扩散角 = v } }
        Text("羽流长度 = 初速 × 寿命 ≈ \(String(format: "%.2f", s.初速 * s.寿命)) 米")
            .font(.system(size: 10))
            .foregroundStyle(Theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)

        SectionTitle(text: "密度")
        参数数值行(标题: "喷口半径 米", 值: s.起始尺寸, 范围: 0.001...5) { v in 改(id) { $0.起始尺寸 = v } }
        参数数值行(标题: "不透明度", 值: s.不透明度, 范围: 0...1) { v in 改(id) { $0.不透明度 = v } }
        参数数值行(标题: "湍流", 值: s.湍流, 范围: 0...1) { v in 改(id) { $0.湍流 = v } }
        参数数值行(标题: "重力倍率", 值: s.重力倍率, 范围: 0...4) { v in 改(id) { $0.重力倍率 = v } }

        SectionTitle(text: "颜色")
        参数颜色行(标题: "出生颜色", 颜色: s.起始颜色) { v in 改(id) { $0.起始颜色 = v } }
        参数颜色行(标题: "死亡颜色", 颜色: s.终止颜色) { v in 改(id) { $0.终止颜色 = v } }

        if s.种类 == .火 {
            SectionTitle(text: "火焰")
            // 火的颜色是**算出来的**：温度 → 黑体色温。这两行定的是温度区间的两头，
            // 上面两个颜色只作为轻微染色参与混合（35%），想整体偏色就调这里。
            参数数值行(标题: "芯色温 K", 值: s.火焰芯色温 ?? 3400, 范围: 800...6000) { v in 改(id) { $0.火焰芯色温 = v } }
            参数数值行(标题: "尾色温 K", 值: s.火焰尾色温 ?? 760, 范围: 400...2600) { v in 改(id) { $0.火焰尾色温 = v } }
            // "局部透局部不"就是这个：给密度场分薄厚，薄处透出后面的亮芯，厚处自己挡自己
            参数数值行(标题: "内部结构", 值: s.火焰结构 ?? 0.6, 范围: 0...1) { v in 改(id) { $0.火焰结构 = v } }
            参数数值行(标题: "亮度 ×", 值: s.火焰亮度 ?? 1, 范围: 0.1...4) { v in 改(id) { $0.火焰亮度 = v } }
            Text("芯色温越高越发白（3400K 亮黄白 / 2400K 橙黄 / 1400K 橙红）；内部结构 0 = 均匀一块糊着，0.5~0.9 才有厚度重叠、局部透局部不透。")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }

        SectionTitle(text: "流体（高级）")
        // 这些直接喂给 GPU 欧拉解算：浮力管窜多高、源温管火芯冲不冲、
        // 死区管尾雾切得干不干净、子步数与压力迭代管稳定性和开销。
        参数数值行(标题: "浮力 ×", 值: s.浮力倍率 ?? 1, 范围: 0.05...6) { v in 改(id) { $0.浮力倍率 = v } }
        参数数值行(标题: "源温 ×", 值: s.源温倍率 ?? 1, 范围: 0.05...4) { v in 改(id) { $0.源温倍率 = v } }
        参数数值行(标题: "密度死区 ×", 值: s.死区倍率 ?? 1, 范围: 0.05...6) { v in 改(id) { $0.死区倍率 = v } }
        参数数值行(标题: "子步数", 值: Double(s.子步数 ?? 1), 范围: 1...4) { v in 改(id) { $0.子步数 = Int(v.rounded()) } }
        参数数值行(标题: "压力迭代", 值: Double(s.压力迭代 ?? 40), 范围: 8...120) { v in 改(id) { $0.压力迭代 = Int(v.rounded()) } }
        Text("×1 = 出厂标定。子步数 / 压力迭代越大越稳越贵；压力迭代偏小会让浮力被散度吃掉、火压在喷口不起来。")
            .font(.system(size: 10))
            .foregroundStyle(Theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// 写回一律走布局Store 的公开入口，且只动 特效 一个字段 —— 不碰变换、不碰材质。
    private func 改(_ id: UUID, _ 动作: @escaping (inout 特效设置) -> Void) {
        store.updateObject(id) { 物体 in
            guard var s = 物体.特效 else { return }
            动作(&s)
            物体.特效 = s
        }
    }

    private func 绑定(_ id: UUID, _ 键路: WritableKeyPath<特效设置, Bool>) -> Binding<Bool> {
        Binding(
            get: { store.objects.first { $0.id == id }?.特效?[keyPath: 键路] ?? false },
            set: { 新 in 改(id) { $0[keyPath: 键路] = 新 } }
        )
    }
}

// MARK: - 物理页

private struct 物理参数页: View {
    @Environment(着色Store.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("启用物理", isOn: 布尔绑定(\.启用))
                .toggleStyle(.switch)
                .controlSize(.mini)

            Menu {
                ForEach(物理库.预设们) { 预设 in
                    Button {
                        var 新 = 预设.域
                        // 勾选状态是另一回事：套预设只换数值，不偷偷把总开关打开或关掉
                        新.启用 = store.物理域.启用
                        store.物理域 = 新
                    } label: {
                        Label(预设.名称, systemImage: 预设.符号)
                    }
                }
            } label: {
                HStack {
                    Text("套用预设")
                        .font(.system(size: 11))
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8))
                }
            }
            .menuStyle(.borderlessButton)

            参数三轴行(标题: "重力 米/秒²", 值: store.物理域.重力) { 新 in store.物理域.重力 = 新 }
            参数三轴行(标题: "风", 值: store.物理域.风) { 新 in store.物理域.风 = 新 }
            参数三轴行(标题: "流", 值: store.物理域.流) { 新 in store.物理域.流 = 新 }

            参数数值行(标题: "湍流", 值: store.物理域.湍流, 范围: 0...1) { v in store.物理域.湍流 = v }
            参数数值行(标题: "阻力", 值: store.物理域.阻力, 范围: 0...10) { v in store.物理域.阻力 = v }
            参数数值行(标题: "时间缩放", 值: store.物理域.时间缩放, 范围: 0...5) { v in store.物理域.时间缩放 = v }

            Text("重力 / 风 / 流 是全局单体，跟摄像机同口径：不进大纲、不属任何对象，随工程存盘。发射器按自己的倍率吃这些力。")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func 布尔绑定(_ 键路: WritableKeyPath<物理域, Bool>) -> Binding<Bool> {
        Binding(
            get: { store.物理域[keyPath: 键路] },
            set: { 新 in store.物理域[keyPath: 键路] = 新 }
        )
    }
}
