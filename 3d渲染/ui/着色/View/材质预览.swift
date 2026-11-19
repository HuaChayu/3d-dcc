import AppKit
import SwiftUI

// MARK: - 材质球缩略预览

/// 材质名左边那颗小球 —— 它本身就是效果预览。
/// 不套任何容器：出图带透明背景，只有球，直接浮在检查器底色上。
/// 走的是和材质球库同一套离屏渲染与缓存，两边外观一致；
/// 画不出来时（设备不可用）退化成基色圆点，不留空白。
struct 材质球缩略图: View {
    let resolved: ResolvedMaterial
    let 签名: String
    var 尺寸: CGFloat = 26
    /// 离屏渲染用的尺寸，只影响"渲几像素"，不影响显示大小。
    /// 槽条这类小图标传材质库那档（96）就能直接命中库里已经渲好的那张图，不为小图标再渲一遍。
    var 渲染尺寸: CGFloat? = nil

    @State private var 图像: NSImage?

    var body: some View {
        content
            .frame(width: 尺寸, height: 尺寸)
            .help("材质效果预览 · 当前节点求值后的近似外观")
            .task(id: 缓存标识) {
                图像 = 材质球预览器.shared.图像(resolved, 签名: 签名, 尺寸: 缓存标识尺寸)
            }
    }

    /// 签名 + 渲染尺寸才是缓存键，两者任一变化都要重取图
    private var 缓存标识: String { "\(签名)|\(缓存标识尺寸)" }
    private var 缓存标识尺寸: CGFloat { 渲染尺寸 ?? 尺寸 }

    @ViewBuilder
    private var content: some View {
        if let 图像 {
            Image(nsImage: 图像)
                .resizable()
                .interpolation(.high)
                .aspectRatio(1, contentMode: .fit)
                // 球在画面里留了余量，剪成圆只是兜底：
                // 万一渲染器没给透明背景，看到的还是一个圆，不会冒出方形
                .clipShape(Circle())
        } else {
            Circle()
                .fill(Theme.color(from: resolved.params.previewColor))
                .frame(width: 尺寸 * 0.62, height: 尺寸 * 0.62)
        }
    }
}
