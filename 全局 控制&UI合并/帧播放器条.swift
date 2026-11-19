import SwiftUI

/// 全局帧播放器条：传输按钮 + 时间线 + 读数 + 自动 K 帧开关。
///
/// 它挂在窗口底部（状态条上面一层），**不属于任何 Tab** ——
/// 布局里在播，切到着色 / 渲染 / 资源照样在播，将来路径渲染出图窗口读的也是同一个播放头。
/// 状态唯一来源是 `时间轴域.共享`，这个视图自己不存任何帧号。
///
/// 视口底部那条「网格 / 地面 / 转台 / 全局 / 局部 / 移动 / 旋转 / 缩放」是
/// ViewportPanel 自带的通用条，这里一个字都不碰。
struct 帧播放器条: View {

    private var 域: 时间轴域 { .共享 }

    var body: some View {
        HStack(spacing: 10) {
            传输按钮组

            时间线轨道(
                当前帧: 域.当前帧,
                总帧数: 域.结束帧 + 1,
                帧率: 域.帧率,
                关键帧帧们: 关键帧帧们,
                已烘焙帧: 烘焙帧列表,
                设帧: { 域.跳($0) },
                拖动开始: { 域.暂停() }
            )
            .frame(maxWidth: .infinity)
            .frame(height: 23)
            // 烘焙期间锁住播放头：世界矩阵是要按帧烤进缓存的，中途被拖走会烤出花
            .disabled(烘焙域.烘焙中)

            读数区

            烘焙区
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Theme.panelBackground)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.divider).frame(height: 1)
        }
    }

    /// 所有轨道的关键帧落在哪些帧上（时间线上的小标记，去重升序）
    private var 关键帧帧们: [Int] {
        Set(域.轨道表.flatMap { $0.控制点.map(\.帧) }).sorted()
    }

    private var 烘焙域: 特效烘焙域 { .共享 }

    /// 烘过且有完整缓存的帧（升序）。时间线顶部那条细带画的就是它。
    private var 烘焙帧列表: [Int] { 烘焙域.已烘焙帧.sorted() }

    // MARK: 传输按钮

    private var 传输按钮组: some View {
        HStack(spacing: 2) {
            传输按钮("backward.end.fill", "回到第一帧") { 域.步进(域.起始帧 - 域.当前帧) }
            传输按钮("backward.frame.fill", "上一帧") { 域.步进(-1) }

            Button {
                域.切换播放()
            } label: {
                Image(systemName: 域.播放中 ? "pause.fill" : "play.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 24, height: 18)
                    .background(Theme.主色.opacity(0.2), in: RoundedRectangle(cornerRadius: 5))
                    .foregroundStyle(Theme.主色)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(域.播放中 ? "暂停（空格）" : "播放（空格）")

            传输按钮("forward.frame.fill", "下一帧") { 域.步进(1) }
            传输按钮("forward.end.fill", "到最后一帧") { 域.跳(域.结束帧) }
        }
        .padding(3)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private func 传输按钮(_ 符号: String, _ 提示: String, _ 动作: @escaping () -> Void) -> some View {
        Button(action: 动作) {
            Image(systemName: 符号)
                .font(.system(size: 9.5, weight: .semibold))
                .frame(width: 21, height: 18)
                .foregroundStyle(Color.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(提示)
    }

    // MARK: 读数：帧号 / 秒 / 帧率 / 循环 / 自动 K 帧

    private var 读数区: some View {
        HStack(spacing: 8) {
            Text(String(format: "%04d", 域.当前帧) + " / " + String(format: "%04d", 域.结束帧))
                .font(.system(size: 10, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(Theme.textSecondary)

            Text(String(format: "%.2fs", Double(域.当前帧 - 域.起始帧) / max(域.帧率, 1)))
                .font(.system(size: 9.5, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 44, alignment: .leading)

            帧率菜单

            开关按钮(
                符号: 域.循环 ? "repeat.circle.fill" : "repeat",
                开启: 域.循环,
                提示: 域.循环 ? "循环播放：开" : "循环播放：关"
            ) { 域.循环.toggle() }

            开关按钮(
                符号: 域.自动K帧 ? "record.circle.fill" : "record.circle",
                开启: 域.自动K帧,
                提示: 域.自动K帧 ? "自动 K 帧：开（改值即落帧）" : "自动 K 帧：关（改值不落帧）"
            ) { 域.自动K帧.toggle() }

            // 轨道数：一眼看出这个工程到底有没有动画
            Text("轨 \(域.轨道表.count)")
                .font(.system(size: 9, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(域.轨道表.isEmpty ? Theme.textTertiary : Theme.主色.opacity(0.85))
        }
    }

    private var 帧率菜单: some View {
        Menu {
            ForEach([12.0, 24.0, 25.0, 30.0, 50.0, 60.0], id: \.self) { 值 in
                Button {
                    域.设帧率(值)
                } label: {
                    if abs(域.帧率 - 值) < 0.01 {
                        Label(String(format: "%g fps", 值), systemImage: "checkmark")
                    } else {
                        Text(String(format: "%g fps", 值))
                    }
                }
            }
            Divider()
            Button("设为当前帧率 \(String(format: "%g", 域.帧率)) fps") {}
                .disabled(true)
        } label: {
            Text(String(format: "%g fps", 域.帧率))
                .font(.system(size: 9.5, design: .monospaced))
                .monospacedDigit()
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("帧率（影响播放速度与秒数读数）")
    }

    private func 开关按钮(
        符号: String,
        开启: Bool,
        提示: String,
        动作: @escaping () -> Void
    ) -> some View {
        Button(action: 动作) {
            Image(systemName: 符号)
                .font(.system(size: 10))
                .foregroundStyle(开启 ? Theme.主色 : Color.secondary.opacity(0.7))
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(提示)
    }

    // MARK: 烘焙

    private var 烘焙区: some View {
        VStack(spacing: 2) {
            Button {
                if 烘焙域.烘焙中 {
                    烘焙域.停止()
                } else {
                    烘焙域.烘焙全部()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: 烘焙域.烘焙中 ? "stop.fill" : "flame.fill")
                        .font(.system(size: 8.5, weight: .semibold))
                    Text(烘焙域.烘焙中
                         ? String(format: "停 %.0f%%", 烘焙域.进度 * 100)
                         : "烘焙全部特效")
                        .font(.system(size: 9.5, weight: .semibold))
                        .monospacedDigit()
                }
                .padding(.horizontal, 7)
                .frame(height: 15)
                .background(Theme.主色.opacity(烘焙域.烘焙中 ? 0.3 : 0.16),
                            in: RoundedRectangle(cornerRadius: 4))
                .foregroundStyle(Theme.主色)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!烘焙域.烘焙中 && !烘焙域.可以烘焙)
            .help(烘焙提示)

            // 帧范围：一次烘整段，起止都可以手填（填反了域里会自动夹正）
            HStack(spacing: 2) {
                帧输入框(值: Binding(get: { 烘焙域.起始帧 },
                                    set: { 烘焙域.起始帧 = $0 }),
                        提示: "烘焙起始帧")
                Text("–")
                    .font(.system(size: 8))
                    .foregroundStyle(Theme.textTertiary)
                帧输入框(值: Binding(get: { 烘焙域.结束帧 },
                                    set: { 烘焙域.结束帧 = $0 }),
                        提示: "烘焙结束帧")
            }
        }
        .disabled(烘焙域.烘焙中)
    }

    private var 烘焙提示: String {
        if 烘焙域.烘焙中 { return 烘焙域.状态文字 }
        if !烘焙域.可以烘焙 { return "场景里没有启用的特效" }
        return 烘焙域.状态文字 + "\n把帧范围内所有特效的模拟算成现成结果，播放时直接读缓存"
    }

    private func 帧输入框(值: Binding<Int>, 提示: String) -> some View {
        TextField("", value: 值, format: .number)
            .textFieldStyle(.plain)
            .font(.system(size: 9, design: .monospaced))
            .monospacedDigit()
            .multilineTextAlignment(.center)
            .frame(width: 38, height: 13)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 3))
            .help(提示)
    }
}

// MARK: - 时间线轨道

private struct 时间线轨道: View {
    var 当前帧: Int
    var 总帧数: Int
    var 帧率: Double
    var 关键帧帧们: [Int]
    /// 已烘焙的帧（顶部那条细带）
    var 已烘焙帧: [Int] = []
    var 设帧: (Int) -> Void
    var 拖动开始: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let 宽 = max(proxy.size.width, 1)
            let 末帧 = max(总帧数 - 1, 1)
            let 头x = 宽 * CGFloat(min(max(当前帧, 0), 末帧)) / CGFloat(末帧)

            ZStack(alignment: .topLeading) {
                // 轨道底
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.primary.opacity(0.07))
                    .frame(height: 12)
                    .offset(y: 4)

                // 已播到播放头的那一段
                RoundedRectangle(cornerRadius: 3)
                    .fill(Theme.主色.opacity(0.22))
                    .frame(width: max(头x, 0), height: 12)
                    .offset(y: 4)

                // 刻度 + 关键帧标记
                Canvas { 画布, 尺寸 in
                    let 步 = 刻度步(宽: 尺寸.width, 末帧: 末帧)
                    let 每秒 = max(Int(帧率.rounded()), 1)
                    var 帧 = 0
                    while 帧 <= 末帧 {
                        let x = 尺寸.width * CGFloat(帧) / CGFloat(末帧)
                        let 整秒 = 帧 % 每秒 == 0
                        let 线高: CGFloat = 整秒 ? 5 : 3
                        var 线 = Path()
                        线.move(to: CGPoint(x: x, y: 18))
                        线.addLine(to: CGPoint(x: x, y: 18 + 线高))
                        画布.stroke(
                            线,
                            with: .color(整秒 ? Theme.textTertiary.opacity(0.55) : Theme.textTertiary.opacity(0.28)),
                            lineWidth: 1
                        )
                        // 整秒处标秒数（第一帧不标，贴着左边会被裁）
                        if 整秒 && 帧 > 0 {
                            let 文本 = Text("\(帧 / 每秒)s")
                                .font(.system(size: 7.5, design: .monospaced))
                                .foregroundStyle(Theme.textTertiary)
                            画布.draw(文本, at: CGPoint(x: x, y: 15), anchor: .bottom)
                        }
                        帧 += 步
                    }

                    // 关键帧标记：所有轨道的控制点汇总画成小菱形
                    for 帧 in 关键帧帧们 where 帧 >= 0 && 帧 <= 末帧 {
                        let x = 尺寸.width * CGFloat(帧) / CGFloat(末帧)
                        var 菱形 = Path()
                        菱形.move(to: CGPoint(x: x, y: 6))
                        菱形.addLine(to: CGPoint(x: x + 3, y: 10))
                        菱形.addLine(to: CGPoint(x: x, y: 14))
                        菱形.addLine(to: CGPoint(x: x - 3, y: 10))
                        菱形.closeSubpath()
                        画布.fill(菱形, with: .color(Theme.主色.opacity(0.75)))
                    }

                    // 已烘焙帧：顶部一条细带。连续帧合并成一段画，几百帧也只有几个矩形。
                    // 放在最关键帧之后画，宽度至少 1.2pt，单帧缓存也看得见。
                    var 段起: Int?
                    var 段末 = 0
                    func 收段() {
                        guard let 起 = 段起 else { return }
                        let x0 = 尺寸.width * CGFloat(起) / CGFloat(末帧)
                        let x1 = 尺寸.width * CGFloat(min(段末 + 1, 末帧)) / CGFloat(末帧)
                        let 矩形 = Path(roundedRect: CGRect(x: x0,
                                                           y: 0,
                                                           width: max(x1 - x0, 1.2),
                                                           height: 2.6),
                                       cornerRadius: 1)
                        画布.fill(矩形, with: .color(Theme.主色.opacity(0.85)))
                    }
                    for 帧 in 已烘焙帧 where 帧 >= 0 && 帧 <= 末帧 {
                        if let 起 = 段起, 帧 == 段末 + 1 {
                            段末 = 帧
                            continue
                        }
                        收段()
                        段起 = 帧
                        段末 = 帧
                    }
                    收段()
                }

                // 播放头
                Path { 路径 in
                    路径.move(to: CGPoint(x: 头x, y: 3))
                    路径.addLine(to: CGPoint(x: 头x, y: 17))
                }
                .stroke(Theme.主色, lineWidth: 1.5)

                Circle()
                    .fill(Theme.主色)
                    .frame(width: 7, height: 7)
                    .offset(x: 头x - 3.5, y: 3.5)
            }
            .frame(width: 宽, height: proxy.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { 手势 in
                        if 手势.translation == .zero { 拖动开始() }
                        let x = min(max(手势.location.x, 0), 宽)
                        设帧(Int((x / 宽 * CGFloat(末帧)).rounded()))
                    }
            )
        }
    }

    /// 刻度间隔：先保证最小像素间距，再取整秒的整除值，末帧再多也不糊成一片。
    private func 刻度步(宽: CGFloat, 末帧: Int) -> Int {
        let 每秒 = max(Int(帧率.rounded()), 1)
        let 最小间距: CGFloat = 24
        let 候选 = [1, 2, 5, 10, 每秒, 每秒 * 2, 每秒 * 5, 每秒 * 10, 每秒 * 30]
        for 步 in 候选 where 步 > 0 {
            if 宽 * CGFloat(步) / CGFloat(末帧) >= 最小间距 { return 步 }
        }
        return max(末帧, 1)
    }
}
