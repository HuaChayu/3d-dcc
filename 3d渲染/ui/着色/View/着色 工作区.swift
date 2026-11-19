import SwiftUI

/// 竖向分栏拖动手势锚定的固定坐标系。
/// 手势挂在"会移动"的分隔条上，若用默认的 .local，translation 会跟着分隔条自身移动一起漂移，
/// 表现为快速拖动时分隔条明显滞后于鼠标、还会来回跳。
private let 着色分栏坐标系 = "着色工作区竖向分栏"

/// 模式一：上方 3D 视口 + 下方材质节点编辑器（+ 右侧 OpenPBR 检查器）
struct ShadingWorkspace: View {
    @Environment(着色Store.self) private var store
    /// 只用来记「鼠标现在在哪个区」，让 ⌫ 只删当前区里的东西
    @Environment(布局Store.self) private var scene

    /// 拖动中的底部高度（像素）。拖动全程只写这个本地状态，绝不写 store：
    /// 每帧写 store.nodeAreaRatio 会让 @Observable 广播、连带重算其它面板，
    /// 再加上视口每帧重排，手势事件就全堵在主线程后面。
    @State private var splitLiveBottom: CGFloat?

    var body: some View {
        // 底栏页存在 store 里（不在本地 @State）：全局搜索点材质时要能把这一页切到材质库
        @Bindable var store = store

        return GeometryReader { proxy in
            let total = proxy.size.height
            let dividerHeight: CGFloat = 9
            let minTop: CGFloat = 200
            let minBottom: CGFloat = 190
            // 先算像素上限，再钳制，避免"比例钳制"和"最小像素"互相打架导致跳变
            let maxBottom = max(minBottom, total - minTop - dividerHeight)
            let steadyBottom = min(max(minBottom, total * store.nodeAreaRatio), maxBottom)
            let bottom = min(max(splitLiveBottom ?? steadyBottom, minBottom), maxBottom)
            let top = max(minTop, total - bottom - dividerHeight)
            // 视口渲染画布按"视口能占到的最大高度"固定下来：
            // 分栏只改变裁剪出多少可见范围，渲染尺寸、画幅比例、相机全都不动。
            // 这样拖动时 RealityKit / MTKView 一次都不用重排，画面也不会被拉伸或忽远忽近。
            let 画布高 = max(minTop, total - minBottom - dividerHeight)

            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    ViewportPanel(画布高: 画布高, 可见高: top)
                        .frame(height: 画布高)
                        .frame(height: top)
                        .clipped()
                        .background(Theme.viewportBackground)

                    if store.n面板可见 {
                        Rectangle().fill(Theme.divider).frame(width: 1)

                        // 挤压式：只占宽度，不动视口高度，也不盖住画面
                        N面板(页: $store.n面板页) { store.n面板可见 = false }
                    }
                }
                .frame(height: top)

                SplitHandle(
                    startBottom: bottom,
                    range: minBottom...maxBottom,
                    onChange: { splitLiveBottom = $0 },
                    onEnd: { 新底高 in
                        store.nodeAreaRatio = Double(新底高 / max(total, 1))
                        store.persist()
                        // 同一轮里同时解除本地态：视口按最终高度重排一次，不会先闪一帧中间态
                        splitLiveBottom = nil
                    }
                )
                .frame(height: dividerHeight)

                HStack(spacing: 0) {
                    // 同一个底栏，三页：材质球库 / 本项目 / 材质节点
                    Group {
                        switch store.底栏页 {
                        case .库:
                            MaterialLibraryView(页: $store.底栏页)
                        case .本项目:
                            MaterialLibraryView(页: $store.底栏页, 范围: .本项目)
                        case .节点:
                            MaterialNodeEditor(页: $store.底栏页)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // 视图身份挂在项目上：新建/打开项目＝全新项目，整块自动重建，不需要任何手动清零
                    .id(项目容器.当前项目)

                    if store.inspectorVisible {
                        Rectangle()
                            .fill(Theme.divider)
                            .frame(width: 1)
                        MaterialInspector()
                            .frame(width: 340)
                    }
                }
                .frame(height: bottom)
                .background(Theme.panelBackground)
                // 鼠标一进下半区就算「在材质区干活」：⌫ 只删节点/连线，不会回头删视口物体。
                // 靠悬停而不是靠点击，是因为点节点未必能一次点中（预览区、按钮都在抢命中）。
                .onContinuousHover(coordinateSpace: .local) { phase in
                    if case .active = phase, scene.焦点 != .节点编辑器 {
                        scene.焦点 = .节点编辑器
                    }
                }
            }
            .coordinateSpace(name: 着色分栏坐标系)
        }
        .background(Theme.canvasBackground)
        .navigationTitle("着色")
    }
}

/// 视口 / 节点编辑器之间的竖向分隔条（上下拖动改变底部分栏高度）
private struct SplitHandle: View {
    /// 按下瞬间的底部高度（像素）：拖动全程以它为基准累积，
    /// 不用 store 里的值，避免"写 store → 重排 → 再读回"这条回路带来的反馈振荡
    let startBottom: CGFloat
    let range: ClosedRange<CGFloat>

    let onStart: () -> Void = {}
    let onChange: (CGFloat) -> Void
    let onEnd: (CGFloat) -> Void

    @State private var 起点: CGFloat?
    @State private var 上次应用: CGFloat?
    @State private var 悬停中 = false

    var body: some View {
        ZStack {
            Theme.panelBackground.opacity(0.9)
            Capsule()
                .fill(Theme.stroke)
                .frame(width: 38, height: 3)
        }
        .contentShape(Rectangle())
        .onHover { inside in
            if inside, !悬停中 {
                悬停中 = true
                NSCursor.resizeUpDown.push()
            } else if !inside, 悬停中 {
                悬停中 = false
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named(着色分栏坐标系))
                .onChanged { value in
                    if 起点 == nil {
                        起点 = startBottom
                        onStart()
                    }
                    guard let 起点 else { return }
                    // 向上拖 → 底部分栏变矮；向下拖 → 变高
                    let 目标 = 起点 - value.translation.height
                    let 钳制后 = min(max(目标, range.lowerBound), range.upperBound)
                    // 亚像素抖动不触发重排：视口每改一次高度都是实打实的代价
                    if let 上次 = 上次应用, abs(上次 - 钳制后) < 0.5 { return }
                    上次应用 = 钳制后
                    onChange(钳制后)
                }
                .onEnded { _ in
                    let 最终 = 上次应用 ?? startBottom
                    起点 = nil
                    上次应用 = nil
                    onEnd(最终)
                }
        )
    }
}
