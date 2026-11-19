import SwiftUI
import simd

// MARK: - 模型拼接

/// 拼接模式里的一个可吸附点：物体中心，或者它世界包围盒的一个直角顶点。
struct 拼接点: Hashable {
    var 物体: UUID
    /// -1 = 中心；0…7 = 包围盒八个直角顶点
    var 角标: Int
    var 世界点: SIMD3<Float>

    var 是中心: Bool { 角标 < 0 }
    var 名称: String { 是中心 ? "中心" : "顶点\(角标 + 1)" }

    // 身份只看「哪个物体的哪个点」：世界点会随物体走，不参与判定
    static func == (甲: 拼接点, 乙: 拼接点) -> Bool {
        甲.物体 == 乙.物体 && 甲.角标 == 乙.角标
    }

    func hash(into 装: inout Hasher) {
        装.combine(物体)
        装.combine(角标)
    }
}

/// 候选表：进拼接时算一次（世界坐标 + 屏幕上大概多大），之后只跟着相机重投影。
/// 屏幕位置**不存** —— 这就是上一版环「一动机位就脱开模型」的根因：
/// 位置一旦冻结成屏幕坐标，模型在屏幕上被相机推走，环就必然留在原地。
struct 拼接锚点 {
    var 点: 拼接点
    var 物体像素: CGFloat
}

/// 拼接环绘制层。样式和三轴交汇处的中心球一致（盘面 → 外光晕 → 主环 → 左上高光弧），
/// 环心额外点一个实心小点 —— 吸附认的就是这个点，别让人以为环的边缘才是锚点。
/// 相机是 @State，只在机位真的变了（平移 / 缩放 / 转视角回调）时才重画，
/// 没有定时器、没有逐帧轮询，空闲时零开销。
struct 拼接环层: View {
    var 相机: 视口相机
    var 候选: [拼接锚点]
    var 源: 拼接点?

    /// 环半径：中心环大一点、顶点环小一点，一眼能分
    static let 中心半径: CGFloat = 8.5
    static let 顶点半径: CGFloat = 6.5
    /// 数量封顶：大场景里同时画/判的环有上限
    static let 上限 = 200

    var body: some View {
        Canvas { ctx, size in
            画全部(&ctx, 尺寸: size)
        }
        .allowsHitTesting(false)
    }

    private func 画全部(_ ctx: inout GraphicsContext, 尺寸 size: CGSize) {
        guard size.width > 1, size.height > 1, !候选.isEmpty else { return }
        let 框 = CGRect(origin: .zero, size: size)
        var 屏: [(点: 拼接点, 中心: CGPoint, 半径: CGFloat, 权重: CGFloat)] = []
        屏.reserveCapacity(min(候选.count, Self.上限 * 2))

        for 项 in 候选 {
            // 世界点 → 当前机位的屏幕点：环永远咬在模型上
            guard let 中心 = 相机.投影(项.点.世界点, 视图尺寸: size) else { continue }
            guard 框.insetBy(dx: -30, dy: -30).contains(中心) else { continue }
            屏.append((项.点, 中心, 项.点.是中心 ? Self.中心半径 : Self.顶点半径, 项.物体像素))
        }
        if 屏.count > Self.上限 {
            屏 = Array(屏.sorted { $0.权重 > $1.权重 }.prefix(Self.上限))
        }
        // 源环最后画，永远压在最上面
        for 环 in 屏.sorted(by: { 层级($0.点) < 层级($1.点) }) {
            画(&ctx, 环.中心, 环.半径, 选中: 环.点 == 源)
        }
    }

    private func 层级(_ 点: 拼接点) -> Int { 点 == 源 ? 1 : 0 }

    private func 画(_ ctx: inout GraphicsContext, _ 中心: CGPoint, _ r: CGFloat, 选中: Bool) {
        let rr = 选中 ? r + 1.5 : r
        let 框 = CGRect(x: 中心.x - rr, y: 中心.y - rr, width: rr * 2, height: rr * 2)
        let 圆 = Path(ellipseIn: 框)
        let 主色 = Theme.accent
        let 强: Double = 选中 ? 1.0 : 0.8
        let 环宽: CGFloat = 选中 ? 3.0 : 1.8

        // 1. 玻璃盘面：中心几乎通透，越靠边越带一点主色
        ctx.fill(
            圆,
            with: .radialGradient(
                Gradient(colors: [主色.opacity(0.05 * 强), 主色.opacity(0.20 * 强)]),
                center: 中心,
                startRadius: 0,
                endRadius: rr
            )
        )
        // 2. 外侧光晕
        ctx.stroke(圆, with: .color(主色.opacity(0.16 * 强)), lineWidth: 环宽 + 3)
        // 3. 主环
        ctx.stroke(
            圆,
            with: .color(主色.opacity(0.85 * 强)),
            style: StrokeStyle(lineWidth: 环宽, lineCap: .round)
        )
        // 4. 左上高光弧
        var 高光 = Path()
        高光.addArc(
            center: 中心,
            radius: rr,
            startAngle: .degrees(190),
            endAngle: .degrees(265),
            clockwise: false
        )
        ctx.stroke(
            高光,
            with: .color(.white.opacity(选中 ? 0.7 : 0.45)),
            style: StrokeStyle(lineWidth: 环宽 * 0.8, lineCap: .round)
        )
        // 5. 环心锚点：吸附就是「这个点对那个点」，不给个实心点总被当成贴边缘
        let 点半径: CGFloat = 选中 ? 2.2 : 1.6
        let 点框 = CGRect(
            x: 中心.x - 点半径,
            y: 中心.y - 点半径,
            width: 点半径 * 2,
            height: 点半径 * 2
        )
        ctx.fill(Path(ellipseIn: 点框), with: .color(.white.opacity(选中 ? 0.95 : 0.55)))
    }
}
