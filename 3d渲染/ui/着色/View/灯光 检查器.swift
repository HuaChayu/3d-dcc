import SwiftUI
import simd

// MARK: - 灯光检查器

/// 灯的物理参数面板：功率 / 色温 / 尺寸 / 锥角。
/// 这些值只进路径追踪的直接光采样，视口里看到的那个小符号只是占位体。
struct LightInspector: View {
    @Environment(布局Store.self) private var scene

    let objectID: UUID
    let 设置: 灯光设置

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            ScrollView {
                VStack(spacing: 12) {
                    kindPicker
                    朝向区
                    if 设置.种类 == .区域光 {
                        尺寸区
                    } else if 设置.种类 == .点光 || 设置.种类 == .聚光 {
                        半径区
                    }
                    if 设置.种类 == .聚光 {
                        锥角区
                    }
                    功率区
                    色温区
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
        }
        .background(Theme.inspectorBackground)
    }

    // MARK: 头

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: 设置.种类.symbol)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text("灯光")
                .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 4)
            Toggle("", isOn: Binding(
                get: { 设置.启用 },
                set: { value in 改 { $0.启用 = value } }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var kindPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(text: "种类")
            Picker("", selection: Binding(
                get: { 设置.种类 },
                set: { value in
                    改 { 灯 in
                        灯.种类 = value
                        // 平行光的"功率"按 lux 看待，和室内灯的瓦数不是一个量级：
                        // 从瓦数灯切过来时给个能看见的默认，免得一改种类就全黑
                        if value == .平行光, 灯.功率 < 200 { 灯.功率 = 1100 }
                    }
                }
            )) {
                ForEach(灯光种类.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    // MARK: 出光朝向

    /// 把本地 -Y 转到世界空间，直说「朝下 / 朝上」这种话：
    /// 视口里那排箭头与这条规则严格一致，这里只是用文字把同一件事讲明白。
    private var 朝向区: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(text: "出光朝向")
            HStack(spacing: 6) {
                Text(朝向文字)
                    .font(.system(size: 10.5, weight: .medium))
                Spacer(minLength: 4)
                if 设置.种类 != .点光 {
                    Button("翻个面") { 翻转出光面() }
                        .controlSize(.mini)
                }
            }
            Text("视口里箭头指向的就是发光方向")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
        }
    }

    private var 朝向文字: String {
        // 点光没有单一朝向，写「全向」比编一个方向更诚实
        if 设置.种类 == .点光 { return "全向（四周都发）" }
        guard let 物体 = scene.objects.first(where: { $0.id == objectID }) else { return "—" }
        // 面板数值也向变换域要：世界矩阵第二列取负（灯的本地 -Y），不再自己解析欧拉角
        let 世界 = 变换接线.共享.世界矩阵(of: 物体)
        let 方向 = simd_normalize(-SIMD3<Float>(世界.columns.1.x, 世界.columns.1.y, 世界.columns.1.z))
        let 候选: [(SIMD3<Float>, String)] = [
            ([0, -1, 0], "朝下"), ([0, 1, 0], "朝上"),
            ([1, 0, 0], "朝 +X"), ([-1, 0, 0], "朝 -X"),
            ([0, 0, 1], "朝 +Z"), ([0, 0, -1], "朝 -Z")
        ]
        if let 命中 = 候选.first(where: { simd_dot($0.0, 方向) > 0.94 }) {
            return 命中.1
        }
        return String(format: "斜向 (%.2f, %.2f, %.2f)", 方向.x, 方向.y, 方向.z)
    }

    /// 绕本地 X 翻 180°：灯板 / 筒灯这类默认朝下的灯，一下就能翻过来朝上
    private func 翻转出光面() {
        scene.updateObject(objectID) { object in
            object.rotation.x = (object.rotation.x + 180).truncatingRemainder(dividingBy: 360)
        }
    }

    private var 尺寸区: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(text: "尺寸")
            滑杆("宽", 值: 设置.宽, 范围: 0.1...10, 单位: "m") { v in 改 { $0.宽 = v } }
            滑杆("高", 值: 设置.高, 范围: 0.1...10, 单位: "m") { v in 改 { $0.高 = v } }
        }
    }

    private var 半径区: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(text: "发光半径")
            滑杆("半径", 值: 设置.半径, 范围: 0...1, 单位: "m") { v in 改 { $0.半径 = v } }
            Text("0 为理想点光源，调大即软阴影面积光")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
        }
    }

    private var 锥角区: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(text: "光锥")
            滑杆("半角", 值: 设置.锥角, 范围: 5...85, 单位: "°") { v in 改 { $0.锥角 = v } }
            滑杆("柔和", 值: 设置.柔和, 范围: 0...1, 单位: "") { v in 改 { $0.柔和 = v } }
        }
    }

    private var 功率区: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(text: "功率")
            滑杆("功率", 值: 设置.功率, 范围: 0...2000, 单位: "W") { v in 改 { $0.功率 = v } }
        }
    }

    private var 色温区: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(text: "色温")
            滑杆("色温", 值: 设置.色温, 范围: 1800...10000, 单位: "K") { v in 改 { $0.色温 = v } }
        }
    }

    // MARK: 控件

    private func 滑杆(
        _ 标题: String,
        值: Double,
        范围: ClosedRange<Double>,
        单位: String,
        onChange: @escaping (Double) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(标题)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(格式化(值) + 单位)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            Slider(
                value: Binding(get: { min(max(值, 范围.lowerBound), 范围.upperBound) }, set: onChange),
                in: 范围
            )
            .controlSize(.mini)
        }
    }

    private func 格式化(_ value: Double) -> String {
        value >= 100 ? String(Int(value.rounded())) : String(format: "%.2f", value)
    }

    private func 改(_ mutate: (inout 灯光设置) -> Void) {
        scene.updateObject(objectID) { object in
            guard var 灯 = object.灯光 else { return }
            mutate(&灯)
            object.灯光 = 灯
        }
    }
}
