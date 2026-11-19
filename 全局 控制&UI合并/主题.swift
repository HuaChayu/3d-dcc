import SwiftUI

// MARK: - 设计令牌

/// 所有颜色的唯一来源：令牌值来自「偏好设置」，禁止在 View 里写死颜色。
/// 改主题后根视图按 `偏好.变更版本` 重建，因此这里可以安全地用静态读取。
enum Theme {
    static let cardRadius: CGFloat = 12
    static let panelRadius: CGFloat = 16
    static let padding: CGFloat = 14
    static let tightPadding: CGFloat = 10
    static let nodeRadius: CGFloat = 10
    static let hairline: CGFloat = 1

    static var 偏好: 偏好设置Store { .shared }
    static var 配色: 界面配色 { 偏好.当前配色 }

    // MARK: 四级背景

    /// 编辑器背景
    static var canvasBackground: Color { 配色.画布 }
    static var canvasGrid: Color { 配色.网格 }
    static var panelBackground: Color { 配色.面板 }
    static var inspectorBackground: Color { 配色.检查器 }
    static var viewportBackground: Color { 配色.视口 }

    /// 节点卡片
    static var nodeBackground: Color { 配色.节点底 }
    static var nodeHeader: Color { 配色.节点头 }
    static var fieldBackground: Color { 配色.控件底 }

    // MARK: 线

    static var stroke: Color { 配色.描边 }
    static var divider: Color { 配色.分隔 }

    // MARK: 文字

    static var textPrimary: Color { 配色.文字主 }
    static var textSecondary: Color { 配色.文字次 }
    static var textTertiary: Color { 配色.文字弱 }

    // MARK: 主色

    static var accent: Color { 配色.主色 }

    // MARK: 中文别名（偏好设置面板等按配色令牌原名读取）

    static var 画布: Color { 配色.画布 }
    static var 网格: Color { 配色.网格 }
    static var 面板: Color { 配色.面板 }
    static var 检查器: Color { 配色.检查器 }
    static var 视口: Color { 配色.视口 }
    static var 节点底: Color { 配色.节点底 }
    static var 节点头: Color { 配色.节点头 }
    static var 控件底: Color { 配色.控件底 }
    static var 描边: Color { 配色.描边 }
    static var 分隔: Color { 配色.分隔 }
    static var 文字主: Color { 配色.文字主 }
    static var 文字次: Color { 配色.文字次 }
    static var 文字弱: Color { 配色.文字弱 }
    static var 主色: Color { 配色.主色 }

    static func layerTint(_ layer: PBRParamLayer) -> Color {
        switch layer {
        case .base: Color(red: 0.44, green: 0.66, blue: 0.98)
        case .specular: Color(red: 0.55, green: 0.80, blue: 0.96)
        case .transmission: Color(red: 0.42, green: 0.88, blue: 0.82)
        case .subsurface: Color(red: 0.98, green: 0.66, blue: 0.62)
        case .fuzz: Color(red: 0.86, green: 0.78, blue: 0.98)
        case .coat: Color(red: 0.98, green: 0.82, blue: 0.48)
        case .thinFilm: Color(red: 0.72, green: 0.92, blue: 0.55)
        case .emission: Color(red: 0.98, green: 0.72, blue: 0.42)
        case .geometry: Color(red: 0.70, green: 0.72, blue: 0.78)
        }
    }

    static func categoryTint(_ category: NodeCategory) -> Color {
        switch category {
        case .input: Color(red: 0.58, green: 0.78, blue: 0.98)
        case .texture: Color(red: 0.96, green: 0.72, blue: 0.52)
        case .math: Color(red: 0.72, green: 0.66, blue: 0.96)
        case .sink: Color(red: 0.56, green: 0.92, blue: 0.74)
        }
    }

    static func supportTint(_ support: ViewportSupport) -> Color {
        switch support {
        case .full: Color(red: 0.42, green: 0.82, blue: 0.55)
        case .approx: Color(red: 0.95, green: 0.76, blue: 0.38)
        case .none: Color(red: 0.62, green: 0.64, blue: 0.70)
        }
    }

    /// 线性 → 显示：沿 PBRColor.nsColor 的 sRGB 编码，否则取色器里会显得发白
    static func color(from pbr: PBRColor) -> Color {
        Color(nsColor: pbr.clamped.nsColor)
    }

    static func nsColor(from pbr: PBRColor) -> NSColor {
        pbr.nsColor
    }

    static func pbr(from color: Color) -> PBRColor {
        pbr(from: NSColor(color))
    }

    static func pbr(from ns: NSColor) -> PBRColor {
        let converted = ns.usingColorSpace(.sRGB) ?? .white
        return PBRColor(
            srgbToLinear(Double(converted.redComponent)),
            srgbToLinear(Double(converted.greenComponent)),
            srgbToLinear(Double(converted.blueComponent))
        )
    }

    private static func srgbToLinear(_ v: Double) -> Double {
        let c = min(max(v, 0), 1)
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
}

// MARK: - 通用小组件

struct SectionTitle: View {
    var text: String
    var trailing: String?

    var body: some View {
        HStack(spacing: 6) {
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 4)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }
}

struct SupportBadge: View {
    var support: ViewportSupport

    var body: some View {
        Text(support.title)
            .font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Theme.supportTint(support).opacity(0.18), in: Capsule())
            .foregroundStyle(Theme.supportTint(support))
    }
}

/// 参数行：标题 + 官方参数名 + 视口支持度
struct ParamHeader: View {
    var key: PBRParamKey
    var driven: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(key.title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
            if driven {
                Text("图驱动")
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Theme.layerTint(key.layer).opacity(0.22), in: Capsule())
                    .foregroundStyle(Theme.layerTint(key.layer))
            }
            Spacer(minLength: 4)
            SupportBadge(support: key.realityKitSupport)
        }
    }
}

// MARK: - 细滑块

struct ParamSlider: View {
    var label: String
    var value: Double
    var range: ClosedRange<Double>
    var onChange: (Double) -> Void

    /// 拖动过程中的本地值，thumb 只认它。
    /// 写参数会推进材质版本、让检查器整块重算，Binding 的 get 拿到的其实是上一轮才求出来的值，
    /// 拖动时每帧都被这个慢半拍的值校正一下，手感就是「拉不动、回弹」。
    /// 拖动期用本地值、松手再交回外部真值，手势就和主线程重算解耦了。
    @State private var 拖动值: Double?

    private var 显示值: Double { 拖动值 ?? value }

    var body: some View {
        HStack(spacing: 8) {
            Slider(
                value: Binding(
                    get: { 拖动值 ?? value },
                    set: { 拖动值 = $0; onChange($0) }
                ),
                in: range,
                onEditingChanged: { 开始 in 拖动值 = 开始 ? value : nil }
            )
            .controlSize(.mini)
            .tint(Theme.accent)
            Text(String(format: "%.3f", 显示值))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 46, alignment: .trailing)
        }
    }
}
