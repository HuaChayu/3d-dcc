import AppKit
import SwiftUI
import simd

// MARK: - 容器右栏：预览 + 材质槽 + 模块栈
//
// 口径（跟角色窗口对齐）：右上方是**预览窗口**，一眼看到"这个材质发出来是什么效果"；
// 下方是参数区，按 UE 新版 Niagara 那种**模块**分堆：发射器 / 生命周期 / 力 / 火焰外观 / 模拟。
// 模块里的每个数都写回同一份 `特效设置`，所以容器面板和 N 面板调的是同一批参数，
// 不存在"两边各有一份、改了不同步"。

// MARK: - 预览区

/// 容器右上角的预览窗口：材质球 + 这团火的色温辉光 + 关键数值。
///
/// 不新开渲染管线：材质球走材质库同一套离屏球（同一个缓存，库里看到什么这里就是什么），
/// 辉光用色温算出来的两团径向渐变，开销基本为零，拖着滑杆不会卡。
struct 特效预览区: View {
    let 设置: 特效设置?
    let 源: 特效发射源?
    let 材质: MaterialAsset?

    // MARK: 预览播放（一次 / 循环）

    @State private var 播放中 = false
    @State private var 循环播放 = true
    @State private var 进度: Double = 0
    /// 预览一拍的长度（秒）。只决定"看一遍有多快"，跟真实寿命无关。
    private let 一拍时长: Double = 1.5

    private var 芯色: Color { Self.色(设置?.火焰芯色温 ?? 3400) }
    private var 尾色: Color { Self.色(设置?.火焰尾色温 ?? 760) }

    /// 一次拍子里"一团火往上顶"的强弱：先鼓后收。没在播时按满值算静态色。
    private var 鼓: Double {
        (播放中 || 进度 > 0) ? sin(Double.pi * min(max(进度, 0), 1)) : 1
    }
    private var 亮: Double { 0.45 + 0.55 * 鼓 }

    private func 起播(循环: Bool) {
        循环播放 = 循环
        进度 = 0
        播放中 = true
    }

    private func 步进() {
        let 步 = 0.033 / 一拍时长
        进度 += 步
        if 进度 >= 1 {
            if 循环播放 {
                进度 -= 1
            } else {
                进度 = 1
                播放中 = false
            }
        }
    }

    /// 色温 → 颜色。线性值开个平方，屏幕上才不会糊成一片死白。
    private static func 色(_ 开尔文: Double) -> Color {
        let rgb = PTTranslator.色温RGB(开尔文)
        return Color(red: Double(sqrt(max(rgb.x, 0))),
                     green: Double(sqrt(max(rgb.y, 0))),
                     blue: Double(sqrt(max(rgb.z, 0))))
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.09), Color(white: 0.04)],
                           startPoint: .top, endPoint: .bottom)

            // 辉光：外圈尾色、内圈芯色 —— "芯亮尾暗"就是这个体积感
            RadialGradient(colors: [尾色.opacity(0.5 * 亮), .clear],
                           center: UnitPoint(x: 0.5, y: 0.5 + 0.14 * 进度),
                           startRadius: 4, endRadius: 128 + 72 * 鼓)
                .blendMode(.plusLighter)
            RadialGradient(colors: [芯色.opacity(0.7 * 亮), .clear],
                           center: UnitPoint(x: 0.5, y: 0.6 - 0.12 * 进度),
                           startRadius: 2, endRadius: 58 + 46 * 鼓)
                .blendMode(.plusLighter)

            if let 材质 {
                let 解析 = MaterialCompiler.resolve(材质)
                材质球缩略图(resolved: 解析, 签名: 材质缩略图键.key(解析),
                          尺寸: 92, 渲染尺寸: 192)
                    .shadow(color: 芯色.opacity(0.45), radius: 16)
            } else {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.white.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .frame(width: 82, height: 82)
                    .overlay(
                        Text("未选材质")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.white.opacity(0.45))
                    )
            }

            VStack {
                HStack(spacing: 5) {
                    Image(systemName: 源?.图标 ?? "cube.transparent")
                        .font(.system(size: 9))
                    Text(源?.形状名 ?? "空容器")
                        .font(.system(size: 10, weight: .medium))
                    if let 材质 {
                        Text("· \(材质.name)")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                    }
                    Spacer()
                }
                .foregroundStyle(.white.opacity(0.85))

                Spacer()

                HStack(spacing: 10) {
                    if let s = 设置 {
                        数值签("发射率", String(format: "%.0f", s.发射率))
                        数值签("寿命", String(format: "%.2f s", s.寿命))
                        数值签("芯", String(format: "%.0f K", s.火焰芯色温 ?? 3400))
                    }
                    Spacer(minLength: 8)
                    HStack(spacing: 4) {
                        预览播放键(图标: "play.fill",
                                 亮起: 播放中 && !循环播放,
                                 提示: "播放一次") { 起播(循环: false) }
                        预览播放键(图标: "repeat",
                                 亮起: 播放中 && 循环播放,
                                 提示: "循环播放（再点一下停）") {
                            if 播放中 && 循环播放 {
                                播放中 = false
                                进度 = 0
                            } else {
                                起播(循环: true)
                            }
                        }
                    }
                    Text(播放中 ? String(format: "%.0f%%", 进度 * 100) : "静态色")
                        .font(.system(size: 9, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.32))
                }
            }
            .padding(10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .task(id: 播放中) {
            // 只在播放时跑 30Hz，不播就一点开销都没有
            guard 播放中 else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 33_000_000)
                if Task.isCancelled { return }
                步进()
            }
        }
    }

    /// 预览窗格上的小圆键：亮起表示当前就是它在播。
    private func 预览播放键(图标: String, 亮起: Bool, 提示: String, 动作: @escaping () -> Void) -> some View {
        Button(action: 动作) {
            Image(systemName: 图标)
                .font(.system(size: 9, weight: .semibold))
                .frame(width: 20, height: 18)
                .background(Color.white.opacity(亮起 ? 0.22 : 0.08),
                            in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .foregroundStyle(Color.white.opacity(亮起 ? 0.95 : 0.55))
        }
        .buttonStyle(.plain)
        .help(提示)
    }

    private func 数值签(_ 名: String, _ 值: String) -> some View {
        HStack(spacing: 3) {
            Text(名)
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.45))
            Text(值)
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.85))
        }
    }
}

// MARK: - 材质槽

/// 材质选择就是一个**槽**：显示当前材质球，点一下弹预览面板挑一个。
/// 面板里列的是材质库「本项目」tab 那一批（同一份 `本项目材质列表`），
/// 所以"容器里能选的材质"和"材质库里有的材质"永远是同一套东西。
struct 特效材质槽: View {
    let 材质: MaterialAsset?
    let 材质们: [MaterialAsset]
    var 尺寸: CGFloat = 54
    let 选: (UUID?) -> Void

    @State private var 弹出 = false

    var body: some View {
        Button {
            弹出 = true
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black.opacity(0.22))
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Theme.stroke, lineWidth: 1)
                if let 材质 {
                    let 解析 = MaterialCompiler.resolve(材质)
                    材质球缩略图(resolved: 解析, 签名: 材质缩略图键.key(解析),
                              尺寸: 尺寸 - 10, 渲染尺寸: 96)
                } else {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .frame(width: 尺寸, height: 尺寸)
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help("点这里选材质（本项目已有材质）")
        .popover(isPresented: $弹出, arrowEdge: .trailing) {
            材质选择浮层(材质们: 材质们, 当前: 材质?.id,
                        选: { id in
                选(id)
                弹出 = false
            })
        }
    }
}

/// 材质选择浮层：搜索 + 材质球网格（样式照搬材质库「本项目」tab）。
struct 材质选择浮层: View {
    let 材质们: [MaterialAsset]
    let 当前: UUID?
    let 选: (UUID?) -> Void

    @State private var 搜索 = ""

    private var 过滤: [MaterialAsset] {
        let 词 = 搜索.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !词.isEmpty else { return 材质们 }
        return 材质们.filter { $0.name.localizedCaseInsensitiveContains(词) }
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
                TextField("搜索本项目材质", text: $搜索)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                if !搜索.isEmpty {
                    Button {
                        搜索 = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.16)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.stroke, lineWidth: 1))

            if 过滤.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "circle.dashed")
                        .font(.system(size: 18))
                        .foregroundStyle(Theme.textTertiary)
                    Text(材质们.isEmpty ? "本项目还没有材质" : "没有匹配的材质")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 220)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 76, maximum: 96), spacing: 8)],
                              spacing: 8) {
                        ForEach(过滤) { 素材 in
                            单元(素材)
                        }
                    }
                    .padding(2)
                }
                .frame(height: 250)
            }

            HStack(spacing: 8) {
                Button("不指定") { 选(nil) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Text("\(过滤.count) / \(材质们.count) 份 · 与材质库「本项目」同源")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(10)
        .frame(width: 380)
        .background(Theme.panelBackground)
    }

    private func 单元(_ 素材: MaterialAsset) -> some View {
        let 选中 = 素材.id == 当前
        let 解析 = MaterialCompiler.resolve(素材)
        return Button {
            选(素材.id)
        } label: {
            VStack(spacing: 4) {
                材质球缩略图(resolved: 解析, 签名: 材质缩略图键.key(解析),
                          尺寸: 58, 渲染尺寸: 96)
                Text(素材.name)
                    .font(.system(size: 9.5))
                    .foregroundStyle(选中 ? Theme.accent : Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(width: 76)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(选中 ? Theme.accent.opacity(0.14) : Color.white.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(选中 ? Theme.accent.opacity(0.8) : Theme.stroke.opacity(0.6),
                                  lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .help(素材.name)
    }
}

// MARK: - 模块栈

/// UE 新版 Niagara 那种模块堆：一组一组可折叠，标题带图标，展开就是参数行。
/// 参数直接写回 `特效设置`（容器面板和 N 面板共用同一份），这里不留任何本地副本。
struct 特效模块栈: View {
    let 设置: 特效设置
    /// 回写：给一份**改好的整份设置**，由容器窗口负责落到场景对象上。
    /// （不直接持有 `(inout) -> Void` 那种引用式回调：闭包里的 inout 参数不能当值传，
    /// 写成"收一份整份"反而最省事，也不会出现两边各存一份的副本。）
    let 提交: (特效设置) -> Void

    @State private var 展开: Set<String> = ["发射器", "生命周期"]

    /// 模块内统一用它改数：复制一份、改动、整份交回去。
    private func 写(_ 变: (inout 特效设置) -> Void) {
        var 草稿 = 设置
        变(&草稿)
        提交(草稿)
    }

    var body: some View {
        VStack(spacing: 6) {
            模块("发射器", "dot.radiowaves.left.and.right") {
                数行("发射率", 设置.发射率, 0...20000, "%.0f") { v in 写 { $0.发射率 = v } }
                数行("初速", 设置.初速, 0...12, "%.2f") { v in 写 { $0.初速 = v } }
                数行("速度随机", 设置.速度随机, 0...1, "%.2f") { v in 写 { $0.速度随机 = v } }
                数行("扩散角", 设置.扩散角, 0...90, "%.0f°") { v in 写 { $0.扩散角 = v } }
            }
            模块("生命周期", "clock.arrow.circlepath") {
                数行("寿命", 设置.寿命, 0.1...10, "%.2f s") { v in 写 { $0.寿命 = v } }
                数行("起始尺寸", 设置.起始尺寸, 0.005...1, "%.3f") { v in 写 { $0.起始尺寸 = v } }
                数行("终止尺寸", 设置.终止尺寸, 0.005...1, "%.3f") { v in 写 { $0.终止尺寸 = v } }
                数行("不透明度", 设置.不透明度, 0...1, "%.2f") { v in 写 { $0.不透明度 = v } }
                色行("起始颜色", 设置.起始颜色) { v in 写 { $0.起始颜色 = v } }
                色行("终止颜色", 设置.终止颜色) { v in 写 { $0.终止颜色 = v } }
            }
            模块("力", "wind") {
                数行("重力 ×", 设置.重力倍率, -3...3, "%.2f") { v in 写 { $0.重力倍率 = v } }
                数行("风力 ×", 设置.风力倍率, 0...5, "%.2f") { v in 写 { $0.风力倍率 = v } }
                数行("湍流", 设置.湍流, 0...2, "%.2f") { v in 写 { $0.湍流 = v } }
                开关行("参与碰撞", 设置.碰撞) { v in 写 { $0.碰撞 = v } }
            }
            模块("火焰外观", "flame") {
                数行("芯色温", 设置.火焰芯色温 ?? 3400, 800...6000, "%.0f K") { v in 写 { $0.火焰芯色温 = v } }
                数行("尾色温", 设置.火焰尾色温 ?? 760, 400...2600, "%.0f K") { v in 写 { $0.火焰尾色温 = v } }
                数行("内部结构", 设置.火焰结构 ?? 0.6, 0...1, "%.2f") { v in 写 { $0.火焰结构 = v } }
                数行("亮度 ×", 设置.火焰亮度 ?? 1, 0.1...4, "%.2f") { v in 写 { $0.火焰亮度 = v } }
            }
            if 设置.走体积 {
                模块("模拟", "square.grid.3x3.fill") {
                    数行("浮力 ×", 设置.浮力倍率 ?? 1, 0.05...6, "%.2f") { v in 写 { $0.浮力倍率 = v } }
                    数行("源温 ×", 设置.源温倍率 ?? 1, 0.05...4, "%.2f") { v in 写 { $0.源温倍率 = v } }
                    数行("密度死区 ×", 设置.死区倍率 ?? 1, 0.05...6, "%.2f") { v in 写 { $0.死区倍率 = v } }
                    数行("子步数", Double(设置.子步数 ?? 1), 1...4, "%.0f") { v in 写 { $0.子步数 = Int(v.rounded()) } }
                    数行("压力迭代", Double(设置.压力迭代 ?? 40), 8...120, "%.0f") { v in 写 { $0.压力迭代 = Int(v.rounded()) } }
                }
            }
        }
    }

    // MARK: 模块卡片

    private func 模块<内容: View>(_ 名: String, _ 图标: String,
                                  @ViewBuilder 内容: () -> 内容) -> some View {
        let 开 = 展开.contains(名)
        return VStack(spacing: 0) {
            Button {
                if 开 {
                    展开.remove(名)
                } else {
                    展开.insert(名)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: 图标)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 14)
                    Text(名)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Image(systemName: 开 ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if 开 {
                VStack(alignment: .leading, spacing: 5) {
                    内容()
                }
                .padding(.horizontal, 9)
                .padding(.bottom, 8)
            }
        }
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.stroke.opacity(0.55), lineWidth: 1))
    }

    // MARK: 行

    private func 数行(_ 标题: String, _ 值: Double, _ 范围: ClosedRange<Double>,
                     _ 格式: String, _ 提交: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 6) {
            Text(标题)
                .font(.system(size: 10))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 62, alignment: .leading)
            Slider(value: Binding(
                get: { min(max(值, 范围.lowerBound), 范围.upperBound) },
                set: { 提交($0) }
            ), in: 范围)
            .controlSize(.mini)
            Text(String(format: 格式, 值))
                .font(.system(size: 9.5).monospacedDigit())
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 52, alignment: .trailing)
        }
    }

    private func 开关行(_ 标题: String, _ 值: Bool, _ 提交: @escaping (Bool) -> Void) -> some View {
        HStack(spacing: 6) {
            Text(标题)
                .font(.system(size: 10))
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Toggle("", isOn: Binding(get: { 值 }, set: { 提交($0) }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
    }

    private func 色行(_ 标题: String, _ 值: Vec3, _ 提交: @escaping (Vec3) -> Void) -> some View {
        HStack(spacing: 6) {
            Text(标题)
                .font(.system(size: 10))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 62, alignment: .leading)
            ColorPicker("", selection: Binding(
                get: { Color(red: 值.x, green: 值.y, blue: 值.z) },
                set: { 新 in
                    let ns = NSColor(新).usingColorSpace(.sRGB) ?? .white
                    提交(Vec3(Double(ns.redComponent),
                             Double(ns.greenComponent),
                             Double(ns.blueComponent)))
                }
            ), supportsOpacity: false)
            .labelsHidden()
            .frame(width: 44)
            Spacer()
        }
    }
}
