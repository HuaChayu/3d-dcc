import SwiftUI
import simd

// MARK: - 右上角轴向控件

/// 视口右上角的小控件：画出三个世界轴的当前朝向，点击任一轴即把视图对齐到该轴向。
/// 只负责显示与点击，轨道相机仍归 ViewportScene 管。
struct 轴向指示控件: View {
    var 相机: 视口相机
    var onPick: (视口轴向) -> Void

    private let 边长: CGFloat = 92
    private let 半径: CGFloat = 30

    var body: some View {
        Canvas { ctx, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let 视角方向 = normalize(相机.位置 - 相机.目标点)
            let 端点 = 视口轴向.allCases.map { axis -> (轴向: 视口轴向, 点: CGPoint, 深度: Float, 高亮: Bool) in
                let d = axis.方向
                let p = CGPoint(
                    x: center.x + CGFloat(dot(d, 相机.右向)) * 半径,
                    y: center.y - CGFloat(dot(d, 相机.上向)) * 半径
                )
                return (axis, p, dot(d, 相机.前向), dot(d, 视角方向) > 0.995)
            }

            // 深度大的先画（背向相机的轴在底下）
            for item in 端点.sorted(by: { $0.深度 > $1.深度 }) {
                let 正轴 = item.轴向.正轴标签 != nil
                let 色 = item.高亮 ? Theme.accent : 轴色(item.轴向)
                let 远 = item.深度 > 0

                var 线 = Path()
                线.move(to: center)
                线.addLine(to: item.点)
                ctx.stroke(
                    线,
                    with: .color(色.opacity(远 ? 0.45 : 1)),
                    style: StrokeStyle(lineWidth: 远 ? 1.2 : 1.8, lineCap: .round)
                )

                let r: CGFloat = 正轴 ? (远 ? 6.2 : 7.6) : (远 ? 3.4 : 4.4)
                let rect = CGRect(x: item.点.x - r, y: item.点.y - r, width: r * 2, height: r * 2)
                ctx.fill(Path(ellipseIn: rect), with: .color(色.opacity(远 ? 0.75 : 1)))

                if let 标签 = item.轴向.正轴标签, !远 {
                    ctx.draw(
                        Text(标签)
                            .font(.system(size: 8.5, weight: .heavy))
                            .foregroundStyle(.white),
                        at: item.点
                    )
                }
            }

            // 中心小球：当前投影中心
            let c = CGRect(x: center.x - 2.4, y: center.y - 2.4, width: 4.8, height: 4.8)
            ctx.fill(Path(ellipseIn: c), with: .color(Theme.textSecondary.opacity(0.9)))
        }
        .frame(width: 边长, height: 边长)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Theme.stroke, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .help("点击轴：视图对齐到该轴向")
        .gesture(
            SpatialTapGesture(coordinateSpace: .local).onEnded { value in
                if let 轴向 = 命中(value.location) { onPick(轴向) }
            }
        )
    }

    /// 点击判定：够近就取最近的那个轴端点
    private func 命中(_ p: CGPoint) -> 视口轴向? {
        let center = CGPoint(x: 边长 / 2, y: 边长 / 2)
        var best: (视口轴向, CGFloat)?
        for axis in 视口轴向.allCases {
            let d = axis.方向
            let point = CGPoint(
                x: center.x + CGFloat(dot(d, 相机.右向)) * 半径,
                y: center.y - CGFloat(dot(d, 相机.上向)) * 半径
            )
            let distance = hypot(p.x - point.x, p.y - point.y)
            guard distance <= 13 else { continue }
            if best == nil || distance < best!.1 { best = (axis, distance) }
        }
        return best?.0
    }

    /// 轴端点配色与对象手柄保持同一套
    private func 轴色(_ 轴向: 视口轴向) -> Color {
        switch 轴向 {
        case .右视, .左视: Color(red: 0.94, green: 0.34, blue: 0.36)
        case .顶视, .底视: Color(red: 0.44, green: 0.82, blue: 0.40)
        default: Color(red: 0.34, green: 0.58, blue: 0.98)
        }
    }
}

// MARK: - 对象坐标轴手柄

/// 选中物体上的三轴手柄，纯绘制层（不接收事件）：
/// 拖动由 AppKit 事件监视器统一处理，避免和视口轨道手势抢事件。
struct 坐标轴手柄层: View {
    var 相机: 视口相机
    var 世界位置: SIMD3<Float>
    var 模式: 变换模式
    /// 全局轴传单位四元数，局部轴传物体自身旋转
    var 轴旋转: simd_quatf = simd_quatf(angle: 0, axis: [0, 1, 0])
    var 激活轴: 手柄轴?
    /// 中心球是否被按住
    var 球激活: Bool = false

    var body: some View {
        GeometryReader { proxy in
            let 几何 = 相机.手柄(
                中心: 世界位置,
                视图尺寸: proxy.size,
                半径像素: 78,
                旋转: 轴旋转
            )
            // 中心球只在移动 / 缩放出现：旋转的三轴交汇处保持空着
            let 球 = 模式 == .旋转 ? nil : 相机.中心球(中心: 世界位置, 视图尺寸: proxy.size)
            Canvas { ctx, _ in
                let 球半径 = 球?.像素半径 ?? 0
                for g in 几何.sorted(by: { $0.朝向相机 > $1.朝向相机 }) {
                    画(&ctx, g, 球半径: 球半径)
                }
                if let 球 { 画球(&ctx, 球) }
            }
        }
        .allowsHitTesting(false)
    }

    /// 三轴交汇处的中心球：一层薄玻璃圆环，颜色全部取自全局主色 Theme.accent。
    /// 环内是空的但绝对干净 —— 轴线在 半径 + 3 处才起笔，跨不过盘面，所以怎么透明都不会露出轴线。
    /// 质感由四层叠出来：淡渐变盘面 → 外层光晕 → 主环 → 左上高光弧。
    /// 按住时整圈变亮加粗，不做内外双层、不点白芯
    private func 画球(_ ctx: inout GraphicsContext, _ 球: 手柄中心球) {
        let r = 球.像素半径
        let 中心 = 球.中心
        let 框 = CGRect(x: 中心.x - r, y: 中心.y - r, width: r * 2, height: r * 2)
        let 圆 = Path(ellipseIn: 框)
        let 主色 = Theme.accent
        let 强: Double = 球激活 ? 1.0 : 0.8
        let 环宽: CGFloat = 球激活 ? 3.2 : 2.2

        // 1. 玻璃盘面：中心几乎通透，越靠边越带一点主色，像一块薄玻璃片
        ctx.fill(
            圆,
            with: .radialGradient(
                Gradient(colors: [主色.opacity(0.04 * 强), 主色.opacity(0.18 * 强)]),
                center: 中心,
                startRadius: 0,
                endRadius: r
            )
        )
        // 2. 外侧一圈很淡的光晕：玻璃边缘的厚度感
        ctx.stroke(圆, with: .color(主色.opacity(0.16 * 强)), lineWidth: 环宽 + 3)
        // 3. 主环
        ctx.stroke(
            圆,
            with: .color(主色.opacity(0.85 * 强)),
            style: StrokeStyle(lineWidth: 环宽, lineCap: .round)
        )
        // 4. 左上高光弧：玻璃表面那道反光
        var 高光 = Path()
        高光.addArc(
            center: 中心,
            radius: r,
            startAngle: .degrees(190),
            endAngle: .degrees(265),
            clockwise: false
        )
        ctx.stroke(
            高光,
            with: .color(.white.opacity(球激活 ? 0.7 : 0.45)),
            style: StrokeStyle(lineWidth: 环宽 * 0.8, lineCap: .round)
        )
    }

    private func 画(_ ctx: inout GraphicsContext, _ g: 手柄轴几何, 球半径: CGFloat) {
        let 亮 = 激活轴 == g.轴
        let 色 = Color(red: g.轴.色.r, green: g.轴.色.g, blue: g.轴.色.b)
        let 线宽: CGFloat = 亮 ? 3.4 : 2.0

        switch 模式 {
        case .移动:
            轴线(&ctx, g, 色, 线宽, 球半径: 球半径)
            guard g.可用 else { break }
            ctx.fill(箭头(g, 头长: 亮 ? 15 : 12), with: .color(色))

        case .缩放:
            轴线(&ctx, g, 色, 线宽, 球半径: 球半径)
            guard g.可用 else { break }
            let 侧: CGFloat = 亮 ? 7 : 5.5
            let 盒 = CGRect(x: g.正端点.x - 侧, y: g.正端点.y - 侧, width: 侧 * 2, height: 侧 * 2)
            let 方块 = Path(roundedRect: 盒, cornerRadius: 1.5)
            ctx.fill(方块, with: .color(色))
            ctx.stroke(方块, with: .color(.black.opacity(0.35)), lineWidth: 1)

        case .旋转:
            guard g.环绕路径.count > 2 else { break }
            var 环 = Path()
            环.move(to: g.环绕路径[0])
            for p in g.环绕路径.dropFirst() { 环.addLine(to: p) }
            ctx.stroke(
                环,
                with: .color(色.opacity(亮 ? 1 : 0.82)),
                style: StrokeStyle(lineWidth: 线宽, lineCap: .round)
            )
        }
    }

    /// 轴线从「球的表面」起笔：球存在的模式下把起点从球心沿屏幕方向外推到球半径之外，
    /// 球内不再有线头，视觉上就是三根轴从球上长出来。旋转模式没有球，起笔仍在中心。
    private func 轴线(
        _ ctx: inout GraphicsContext,
        _ g: 手柄轴几何,
        _ 色: Color,
        _ 线宽: CGFloat,
        球半径: CGFloat
    ) {
        var 起点 = g.中心
        if 球半径 > 0 {
            let d = g.屏幕方向
            let 长度 = max(0, sqrt(d.dx * d.dx + d.dy * d.dy))
            if 长度 > 0.0001 {
                // 球改成圆环后，环带外缘在 半径 + 环宽/2（约 1.7px），再留 1px 缝
                // 外推要跨过整圈环才起笔，这样环内永远是干净的，看不到轴线
                let 外推 = 球半径 + 3
                起点 = CGPoint(
                    x: g.中心.x + d.dx / 长度 * 外推,
                    y: g.中心.y + d.dy / 长度 * 外推
                )
            }
        }
        var 线 = Path()
        线.move(to: 起点)
        线.addLine(to: g.正端点)
        ctx.stroke(线, with: .color(色), style: StrokeStyle(lineWidth: 线宽, lineCap: .round))
    }

    /// 箭头三角：沿轴的屏幕方向摆，长度固定像素
    private func 箭头(_ g: 手柄轴几何, 头长 size: CGFloat) -> Path {
        let d = g.屏幕方向
        let n = CGVector(dx: -d.dy, dy: d.dx)
        let tip = g.正端点
        let base = CGPoint(x: tip.x - d.dx * size, y: tip.y - d.dy * size)
        var path = Path()
        path.move(to: tip)
        path.addLine(to: CGPoint(x: base.x + n.dx * size * 0.42, y: base.y + n.dy * size * 0.42))
        path.addLine(to: CGPoint(x: base.x - n.dx * size * 0.42, y: base.y - n.dy * size * 0.42))
        path.closeSubpath()
        return path
    }
}

// MARK: - 拖动状态

/// 参与本次变换的物体在「按下瞬间」的基准值
struct 手柄成员 {
    var id: UUID
    var 位置: Vec3
    var 旋转: Vec3
    var 缩放: Vec3
}

/// 一次手柄拖动的上下文：全部基于「按下瞬间」的基准值累计，避免逐帧误差累积。
/// 多选时 成员们 有多个，枢轴 是它们整体包围盒中心——移动保持相对关系、
/// 旋转/缩放都绕这个枢轴进行；单选时 成员们 只有一个，枢轴即物体中心，行为与以前一致。
struct 手柄拖动 {
    var 物体ID: UUID
    var 模式: 变换模式
    /// 单轴手柄：按住某根轴时才填
    var 轴: 手柄轴?
    var 几何: 手柄轴几何?
    /// 中心球：非空表示这一拖是平面移动 / 等比缩放，轴那套完全不参与
    var 球: 手柄中心球?
    var 起点: CGPoint
    var 起始位置: Vec3
    var 起始旋转: Vec3
    var 起始缩放: Vec3
    /// 变换枢轴（世界坐标）：单选=物体中心，多选=整体中心
    var 枢轴: Vec3 = .zero
    /// 一起变换的物体快照
    var 成员们: [手柄成员] = []

    var 多选: Bool { 成员们.count > 1 }
}


// MARK: - 只读小轴向（角色窗口预览用）

/// 只读版轴向控件：比视口那只小一圈，**不接收任何点击**，纯粹告诉人「现在从哪个方向看」。
/// 角色窗口的预览相机是 SceneKit 的 allowsCameraControl 管的，翻不了轴向，
/// 所以这里只挂显示、不挂手势，也不挡预览的鼠标事件。
///
/// 直接吃相机的三个基向量，而不是 视口相机：预览那边的相机朝向是从 SceneKit 的
/// 相机世界矩阵里量出来的，绕一圈换算成方位角/仰角只会白添误差。
struct 只读轴向指示: View {
    var 右向: SIMD3<Float>
    var 上向: SIMD3<Float>
    var 前向: SIMD3<Float>
    var 边长: CGFloat = 58

    private var 半径: CGFloat { 边长 * 0.33 }
    private var 球半径: CGFloat { 边长 * 0.045 }

    var body: some View {
        Canvas { ctx, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let 背面 = -前向
            let 端点 = 视口轴向.allCases.map { axis -> (轴向: 视口轴向, 点: CGPoint, 深度: Float, 亮: Bool) in
                let d = axis.方向
                let p = CGPoint(
                    x: center.x + CGFloat(dot(d, 右向)) * 半径,
                    y: center.y - CGFloat(dot(d, 上向)) * 半径
                )
                return (axis, p, dot(d, 前向), dot(d, 背面) > 0.995)
            }

            // 背向相机的轴先画，会被前面的压住
            for item in 端点.sorted(by: { $0.深度 > $1.深度 }) {
                let 正轴 = item.轴向.正轴标签 != nil
                let 色 = item.亮 ? Theme.accent : 轴颜色(item.轴向)
                let 远 = item.深度 > 0

                var 线 = Path()
                线.move(to: center)
                线.addLine(to: item.点)
                ctx.stroke(
                    线,
                    with: .color(色.opacity(远 ? 0.42 : 1)),
                    style: StrokeStyle(lineWidth: 远 ? 0.9 : 1.3, lineCap: .round)
                )

                let r: CGFloat = 正轴 ? (远 ? 3.8 : 4.6) : (远 ? 2.0 : 2.6)
                let 框 = CGRect(x: item.点.x - r, y: item.点.y - r, width: r * 2, height: r * 2)
                ctx.fill(Path(ellipseIn: 框), with: .color(色.opacity(远 ? 0.7 : 1)))

                if let 标签 = item.轴向.正轴标签, !远 {
                    ctx.draw(
                        Text(标签)
                            .font(.system(size: 6.5, weight: .heavy))
                            .foregroundStyle(.white),
                        at: item.点
                    )
                }
            }

            let 心 = CGRect(x: center.x - 球半径, y: center.y - 球半径, width: 球半径 * 2, height: 球半径 * 2)
            ctx.fill(Path(ellipseIn: 心), with: .color(Theme.textSecondary.opacity(0.85)))
        }
        .frame(width: 边长, height: 边长)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Theme.stroke, lineWidth: 1)
        )
        // 纯展示：鼠标穿透给下面的预览，不参与任何拾取
        .allowsHitTesting(false)
        .help("当前视角朝向（只读）")
    }

    private func 轴颜色(_ 轴向: 视口轴向) -> Color {
        switch 轴向 {
        case .右视, .左视: Color(red: 0.94, green: 0.34, blue: 0.36)
        case .顶视, .底视: Color(red: 0.44, green: 0.82, blue: 0.40)
        default: Color(red: 0.34, green: 0.58, blue: 0.98)
        }
    }
}
