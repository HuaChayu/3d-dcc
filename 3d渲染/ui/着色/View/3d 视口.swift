import AppKit
import RealityKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - RealityKit 视口

/// [临时诊断·RK 重挂] update 次数计数：只记前几次，别每帧刷日志
enum RK诊断计数 {
    nonisolated(unsafe) static var update次数 = 0
}

/// 场景逻辑在 ViewportScene（service 层），相机由场景里的 rk.camera 实体自己管（轨道参数驱动），
/// 这里只负责托管 RealityView、把拖拽/捏合/滚轮转成轨道操作，并转发点选
struct Viewport3DSurface: View {
    var objects: [SceneObject]
    var materials: [UUID: MaterialAsset]
    var settings: ViewportSettings
    /// 全局物理（重力/风/流/阻力）：粒子的力从这里来，本身是 store 的全局单体，不是场景对象
    var 物理域: 物理域 = .标准
    var selectedObjectID: UUID?
    /// 选中集合（多选）：描边按集合点亮，Shift 点击往里加
    var 选中集合: Set<UUID> = []
    /// 场景托管对象由上层持有：轴向控件与对象坐标轴都要读同一套相机参数
    var scene: ViewportScene
    /// 命中结果 + 点击的视口坐标（坐标用来避开右上角轴向控件）+ 是否按住 Shift 加选
    var onPick: (UUID?, CGPoint, Bool) -> Void
    /// 轨道相机变化后回传快照，2D 覆盖层据此重绘
    var onCameraChange: (视口相机) -> Void = { _ in }
    /// W / E / R 快捷键
    var onShortcut: (String) -> Void = { _ in }
    /// 键盘数值变换是否在进行（长按 W / E / R 触发）：进行时键盘整段交给它
    var 数值输入中: Bool = false
    /// 数值会话里的键（x / y / z / 数字 / "." / "-" / "backspace" / "return" / "esc"）
    var on数值键: (String) -> Bool = { _ in false }
    /// 点在浮动控件上：这次点击归控件，不做视口拾取（否则点底部按钮会顺手清掉选中）
    var shouldIgnoreTap: (CGPoint) -> Bool = { _ in false }
    /// 命中坐标轴手柄时返回 true：事件被吞掉，避免同时启动轨道旋转
    var onGizmoPress: (CGPoint, CGSize) -> Bool = { _, _ in false }
    /// 右键命中关节球：弹约束面板（Blender 里右键骨头加约束的手感）
    var onGizmoRightPress: (CGPoint, CGSize) -> Bool = { _, _ in false }
    var onGizmoDrag: (CGPoint) -> Void = { _ in }
    var onGizmoRelease: () -> Void = {}
    /// 中键（滚轮按住）拖动平移视口：给的增量是视口坐标下的像素位移
    var onPan: (CGPoint, CGSize) -> Void = { _, _ in }
    /// 绘画事件（画笔模式开启时才有意义）：按下回 true 表示这次被画笔吃掉
    var onPaintPress: (CGPoint, CGSize) -> Bool = { _, _ in false }
    var onPaintDrag: (CGPoint, CGSize) -> Void = { _, _ in }
    var onPaintRelease: () -> Void = {}
    var onHover: (CGPoint, CGSize) -> Void = { _, _ in }
    var onExit: () -> Void = {}
    /// 渲染画布比可见窗口多出来的上下留白（像素）：
    /// 分栏拖动时画布尺寸保持不变、只在上下裁切，事件也只该在可见窗口里生效
    var 可见留白: CGFloat = 0

    @State private var lastDrag: CGSize = .zero
    @State private var lastMagnification: CGFloat = 1
    /// 【已删除 · 2026-11-09】停演开关随 detach 一起移除（原 `停演现实渲染` 与它观察的 `出图登记`）。
    /// 原实现：`设了路径追踪覆盖 || 出图登记.出图中` 为真时，make/update 走 scene.detach 清场，
    /// 让 RK 那条独立渲染循环没有内容可提交。省钱有限，却换来冻结成灰 / 域数据不刷新 / 切回瞬黑，
    /// 已按用户要求整体回滚到「无条件常驻渲染」。

    /// 视口是否被 PT 的 MTKView 盖住（PT 模式或调试强制）
    private var 设了路径追踪覆盖: Bool {
        settings.shading == .pathTraced || ProcessInfo.processInfo.environment["PT_FORCE"] == "1"
    }

    var body: some View {
        // 【已回滚 · 2026-11-09】RealityView 常驻且无条件渲染，与引入停算之前一致。
        // 这里不需要任何条件分支：make 挂一次 root 并同步，update 判重 + 同步。
        //
        // 走过的两条弯路，都别再走：
        //   1) Group + if + Color.clear 把视图摘出视图树 —— SwiftUI 会真的销毁重建 RealityView，
        //      同一个 root 跨 scene 搬运时 RealityKit 不解除旧归属，append 被静默丢弃，
        //      路径切回其它模式后永久黑屏。
        //   2) 保留视图但用 scene.detach 清场 —— 不黑屏了，却换来收敛后画面冻结成灰、
        //      停演期间 sync 被整段跳过导致域数据过期（拾取 / 拖材质拿旧快照）、切回瞬黑。
        // 代价是路径追踪期间 RK 照常每帧提交（PBR / 阴影 / IBL / MSAA 都在跑），这笔账认了。
        RealityView { content in
            // [临时诊断·RK 重挂] 每次新挂载打一行，和 attach 的日志对时间线
            rk诊断("RealityView make 着色=\(settings.shading)")
            scene.attach(&content)
            scene.sync(
                objects: objects,
                materials: materials,
                settings: settings,
                selectedObjectID: selectedObjectID,
                选中集合: 选中集合,
                content: &content
            )
        } update: { content in
            // [临时诊断·RK 重挂] 只打前三次，够看出新视图有没有真的在跑同步
            if RK诊断计数.update次数 < 3 {
                RK诊断计数.update次数 += 1
                rk诊断("RealityView update#\(RK诊断计数.update次数) entities=\(content.entities.count) 着色=\(settings.shading)")
            }
            // attach 保留：内部按 root 是否已在 content 里判重，命中时是纯 O(1) 检查，
            // 但能兜住「视图被重建 → make 没跑到挂载」的意外。判重之后只做 sync。
            scene.attach(&content)
            scene.sync(
                objects: objects,
                materials: materials,
                settings: settings,
                selectedObjectID: selectedObjectID,
                选中集合: 选中集合,
                content: &content
            )
        }
        .overlay {
            // 滚轮、点选、坐标轴拖拽都不走 SwiftUI 手势：RealityView 会吃掉 tap，
            // 改成 AppKit 本地事件监视器，只在视口范围内截获，并在自己的坐标里换算
            ViewportEventCatcher(
                onScroll: { delta in
                    // 绘画开着且指针在视口里：滚轮改成调笔刷大小 —— 画的时候手最常想改的就是它，
                    // 这时候再缩放视图只会让笔到处乱跑
                    if PaintSession.shared.启用, PaintSession.shared.光标 != nil {
                        PaintSession.shared.调整笔刷(滚动: delta)
                        return
                    }
                    // 系数 0.09：鼠标滚轮一格 ≈ 8~9% 距离变化，接近 DCC 常规手感；
                    // 距离不设上限，滚到底可以一直往外拉
                    scene.zoom(factor: exp(-Double(delta) * 0.09))
                    onCameraChange(scene.相机快照())
                },
                onTap: { point, size, shift in
                    guard !shouldIgnoreTap(point) else { return }
                    onPick(scene.pick(at: point, viewSize: size), point, shift)
                },
                onShortcut: onShortcut,
                数值输入中: 数值输入中,
                on数值键: on数值键,
                onGizmoPress: onGizmoPress,
                onGizmoRightPress: onGizmoRightPress,
                onGizmoDrag: onGizmoDrag,
                onGizmoRelease: onGizmoRelease,
                onPan: onPan,
                onPaintPress: onPaintPress,
                onPaintDrag: onPaintDrag,
                onPaintRelease: onPaintRelease,
                onHover: onHover,
                onExit: onExit,
                hitUI: shouldIgnoreTap,
                可见留白: 可见留白
            )
            .allowsHitTesting(false)
        }
        .overlay {
            ZStack {
                // 路径追踪：独立的 MTKView 盖在 RealityView 之上，
                // 但不接管命中测试，轨道旋转/缩放/点选照旧走下面那一层
                if 设了路径追踪覆盖 {
                    PathTraceViewport(
                        objects: objects,
                        materials: materials,
                        settings: settings,
                        cameraProvider: { scene.pathTraceCamera() }
                    )
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
                // 粒子：常驻最上层（着色模式与路径追踪模式都显示）。
                // 只画粒子、清屏透明，底下的 RealityView / PT 照旧透上来。
                // 出图（PT 落盘）暂不含特效，这一点与 特效 数据.swift 的口径一致。
                粒子视口层(
                    objects: objects,
                    物理域: 物理域,
                    cameraProvider: { scene.pathTraceCamera() },
                    // 烘过的帧直接用现成结果播放（没烘过就是 nil，回落实时积分）。
                    // 这一行同时让本视图订阅「当前帧 / 已烘焙帧」，播放头一动就重取。
                    回放: 特效烘焙域.共享.回放取帧(时间轴域.共享.当前帧)
                )
                .allowsHitTesting(false)
            }
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    let delta = CGSize(
                        width: value.translation.width - lastDrag.width,
                        height: value.translation.height - lastDrag.height
                    )
                    lastDrag = value.translation
                    scene.orbit(delta: delta)
                    onCameraChange(scene.相机快照())
                }
                .onEnded { _ in lastDrag = .zero }
        )
        .simultaneousGesture(
            MagnificationGesture()
                .onChanged { value in
                    // 手势给的是累计倍率，这里取增量，避免反复叠加把相机推爆
                    let delta = value / lastMagnification
                    lastMagnification = value
                    scene.zoom(factor: 1 / Double(delta))
                    onCameraChange(scene.相机快照())
                }
                .onEnded { _ in lastMagnification = 1 }
        )
    }
}

// MARK: - 滚轮

/// 透明 NSView：装本地事件监视器，落在自己 bounds 内的滚轮交给视口缩放、
/// 位移很小的左键按下-抬起算一次点选（RealityView 自己会吞掉 SwiftUI tap）。
private struct ViewportEventCatcher: NSViewRepresentable {
    var onScroll: (CGFloat) -> Void
    var onTap: (CGPoint, CGSize, Bool) -> Void
    var onShortcut: (String) -> Void
    /// 键盘数值变换进行中：键盘整段交给它
    var 数值输入中: Bool = false
    var on数值键: ((String) -> Bool)?
    var onGizmoPress: (CGPoint, CGSize) -> Bool
    var onGizmoRightPress: (CGPoint, CGSize) -> Bool = { _, _ in false }
    var onGizmoDrag: (CGPoint) -> Void
    var onGizmoRelease: () -> Void
    /// 中键（滚轮按住）拖动平移：增量是视口坐标（左上原点）下的像素位移
    var onPan: (CGPoint, CGSize) -> Void = { _, _ in }
    /// 绘画：按下返回 true 表示这一下被画笔吃掉（不再启动轨道旋转/点选）
    var onPaintPress: (CGPoint, CGSize) -> Bool = { _, _ in false }
    var onPaintDrag: (CGPoint, CGSize) -> Void = { _, _ in }
    var onPaintRelease: () -> Void = {}
    /// 指针在视口里移动（不按键），用于画刷子光标
    var onHover: (CGPoint, CGSize) -> Void = { _, _ in }
    var onExit: () -> Void = {}
    /// 命中浮动控件（顶栏 / 底栏 / 图层面板）时返回 true：
    /// 这些区域里的滚轮和悬停都不该当成视口操作 —— 面板上滚一格就改笔刷大小太容易误伤
    var hitUI: (CGPoint) -> Bool = { _ in false }
    var 可见留白: CGFloat = 0

    func makeNSView(context: Context) -> NSView {
        let view = CatcherView()
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let catcher = nsView as? CatcherView else { return }
        apply(to: catcher)
    }

    private func apply(to catcher: CatcherView) {
        catcher.onScroll = onScroll
        catcher.onTap = onTap
        catcher.数值输入中 = 数值输入中
        catcher.on数值键 = on数值键
        catcher.onShortcut = onShortcut
        catcher.onGizmoPress = onGizmoPress
        catcher.onGizmoRightPress = onGizmoRightPress
        catcher.onGizmoDrag = onGizmoDrag
        catcher.onGizmoRelease = onGizmoRelease
        catcher.onPan = onPan
        catcher.onPaintPress = onPaintPress
        catcher.onPaintDrag = onPaintDrag
        catcher.onPaintRelease = onPaintRelease
        catcher.onHover = onHover
        catcher.onExit = onExit
        catcher.hitUI = hitUI
        catcher.可见留白 = 可见留白
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        (nsView as? CatcherView)?.stop()
    }

    final class CatcherView: NSView {
        var onScroll: ((CGFloat) -> Void)?
        var onTap: ((CGPoint, CGSize, Bool) -> Void)?
        var onShortcut: ((String) -> Void)?
        /// 数值变换进行中：键盘只给它，x 不再删物体、z 不再切着色
        var 数值输入中 = false
        var on数值键: ((String) -> Bool)?
        var onGizmoPress: ((CGPoint, CGSize) -> Bool)?
        var onGizmoRightPress: ((CGPoint, CGSize) -> Bool)?
        var onGizmoDrag: ((CGPoint) -> Void)?
        var onGizmoRelease: (() -> Void)?
        var onPan: ((CGPoint, CGSize) -> Void)?
        var onPaintPress: ((CGPoint, CGSize) -> Bool)?
        var onPaintDrag: ((CGPoint, CGSize) -> Void)?
        var onPaintRelease: (() -> Void)?
        var onHover: ((CGPoint, CGSize) -> Void)?
        var onExit: (() -> Void)?
        var hitUI: ((CGPoint) -> Bool)?
        var 可见留白: CGFloat = 0
        private var monitors: [Any] = []
        /// 这一笔正在画：之后的 dragged / up 全部转给画笔，不再当点选
        private var draggingPaint = false
        private var pressPoint: CGPoint?
        private var lastTapTime: TimeInterval = 0
        /// 这次左键按下是不是被我们（绘画 / 手柄）接走了。
        /// 鼠标事件必须「整套」交给一方：RealityKit 只要收到半套 —— 有 down 没 up、
        /// 或者按下期间收到 mouseMoved —— 就会在它自己的拖拽手势状态上强解包 trap（闪退根因）。
        /// 所以一旦接管，就一路吞到 up 收尾为止，中间一个都不放行。
        ///
        /// 必须是 static：SwiftUI 重建这条链路会换一个 catch 视图实例，实例上的布尔量
        /// 当场归零，可 RealityKit 那边被吞掉的 down 还欠着一个 up —— 一分家就又崩。
        ///
        /// 存的是**计数**而不是布尔：语义是「我们吞掉了几个 down 还没还 up」。
        /// 布尔量会串轮 —— 上一笔的 up 丢在窗口外（松手时鼠标已离开），标记没清掉，
        /// 下一次按下走的是放行分支（RealityKit 收到 down），紧接着那个 up 却因为标记
        /// 还是 true 被我们吞了 —— RealityKit 便挂着一个永远不会来的 up，
        /// 下一次 mouseMoved 时它自己去补发 mouseUp，内部拖拽状态已失效，正是这条
        /// ARView.mouseUp ← ARView.mouseMoved 的 trap。计数保证「吞了多少 down 就吞多少 up」，
        /// 既不会多吞一个 up，也不会让放行的 down 变成孤儿。
        private nonisolated(unsafe) static var 待配平Up = 0
        /// 反过来的一本账：我们**放行**给 RealityKit 的 down 有几个还没等到自己的 up。
        /// 抬起的 up 只有在「这本账上还有一个」时才继续放行；账是空的就吞掉。
        ///
        /// 为什么必须这样卡：down 不一定能进到这个监视器里 —— 点击未激活窗口时，
        /// 那一下会被 AppKit 拿去激活窗口，down 不派发到视图，up 却照样发下来；
        /// 鼠标从别的 App 按着拖进本窗口、上一笔 up 落在窗口外，也都是「只有 up 没有 down」。
        /// RealityKit 收到这种孤儿 up，会去读它自己那个空着的拖拽手势状态，
        /// ARView.mouseUp 强解包当场 EXC_BREAKPOINT —— 崩溃栈正是它。
        /// 这也正好解释「切到别的 App 再切回来、过一会儿才闪退」：先失焦，回来后第一下点击
        /// 就是那个没有 down 的 up。
        private nonisolated(unsafe) static var 放行的Down = 0

        /// 抬起要不要继续送给 RealityKit：有账（我们自己放行过 down）才放，否则吞。
        private static func 放行这次抬起() -> Bool {
            guard 放行的Down > 0 else { return false }
            放行的Down -= 1
            return true
        }
        private var draggingGizmo = false
        /// 中键（滚轮按住）平移：按下后一路吞到自己抬起，不给 RealityKit 留半套事件
        private var draggingPan = false
        /// 上一次的中键位置（视口坐标，左上原点），用来算增量
        private var 平移上一点: CGPoint?
        /// 裸 F 的长按判定：按满时长还没松手算长按（独立显示），先松手算短按（聚焦）
        private var f长按任务: DispatchWorkItem?
        private var f长按已触发 = false
        private let f长按时长: TimeInterval = 0.35

        /// W / E / R 的长按判定：长按 = 对象直接进入该变换、等键盘给数值；
        /// 短按 = 老行为，只切变换模式。判定方式和 F 一致，抬起才定案。
        private var 模式长按任务: DispatchWorkItem?
        private var 模式长按键: String?
        private var 模式长按已触发 = false
        private let 模式长按时长: TimeInterval = 0.35

        /// 裸 Alt 的长按：按满时长进「模型拼接」，松开就退出。
        /// 和 W/E/R 那一套不是一回事 —— Alt 不锁轴、也不跟鼠标，只是把可吸附的环铺出来。
        private var alt长按任务: DispatchWorkItem?
        private var alt长按已触发 = false
        private var alt按着 = false
        private let alt长按时长: TimeInterval = 0.35

        private func 更新Alt(_ 按下: Bool) {
            guard 按下 != alt按着 else { return }
            alt按着 = 按下
            guard 按下 else {
                alt长按任务?.cancel()
                alt长按任务 = nil
                // 真进过拼接才发退出；只是单独摸了一下 Alt 不当回事
                if alt长按已触发 {
                    alt长按已触发 = false
                    onShortcut?("alt.up")
                }
                return
            }
            alt长按任务?.cancel()
            alt长按已触发 = false
            let 任务 = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.alt长按已触发 = true
                self.onShortcut?("alt.hold")
            }
            alt长按任务 = 任务
            DispatchQueue.main.asyncAfter(deadline: .now() + alt长按时长, execute: 任务)
        }

        /// Alt 跟别的键凑成组合键时（Alt+H / Alt+F）把长按判据撤掉，别顺带冒出拼接
        private func 取消Alt长按() {
            alt长按任务?.cancel()
            alt长按任务 = nil
            if alt长按已触发 {
                alt长按已触发 = false
                onShortcut?("alt.up")
            }
        }

        private func 开始F长按() {
            f长按任务?.cancel()
            f长按已触发 = false
            let 任务 = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.f长按已触发 = true
                self.onShortcut?("f.hold")
            }
            f长按任务 = 任务
            DispatchQueue.main.asyncAfter(deadline: .now() + f长按时长, execute: 任务)
        }

        /// F 抬起：长按已经触发过就只做收尾，否则补发一次短按
        private func 结束F长按() {
            guard let 任务 = f长按任务 else { return }
            任务.cancel()
            f长按任务 = nil
            if f长按已触发 {
                f长按已触发 = false
                return
            }
            onShortcut?("f")
        }

        private func 开始模式长按(_ key: String) {
            模式长按任务?.cancel()
            模式长按键 = key
            模式长按已触发 = false
            let 任务 = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.模式长按已触发 = true
                // 加上 .hold 后缀，面板据此区分「切模式」和「进入数值变换」
                self.onShortcut?("\(key).hold")
            }
            模式长按任务 = 任务
            DispatchQueue.main.asyncAfter(deadline: .now() + 模式长按时长, execute: 任务)
        }

        /// W / E / R 抬起：长按已经触发过就到此为止，否则补发一次短按切模式
        private func 结束模式长按(_ key: String) {
            guard 模式长按键 == key, let 任务 = 模式长按任务 else { return }
            任务.cancel()
            模式长按任务 = nil
            模式长按键 = nil
            if 模式长按已触发 {
                模式长按已触发 = false
                return
            }
            onShortcut?(key)
        }

        /// 数值会话认的键：数字、小数点（中英文句号都行）、负号、选轴字母、几个控制键
        private static func 数值键标记(_ event: NSEvent) -> String? {
            switch event.keyCode {
            case 51, 117: return "backspace"     // ⌫ / Fn+⌫
            case 36, 76: return "return"         // ⏎ / 小键盘 Enter
            case 53: return "esc"
            case 49: return "space"
            default: break
            }
            guard let 字符 = event.charactersIgnoringModifiers?.first else { return nil }
            switch 字符 {
            case "0"..."9": return String(字符)
            // 中文输入法下敲出来的是全角句号，一样当小数点用
            case ".", "。", "．": return "."
            case "-", "−", "–": return "-"
            case "x", "X": return "x"
            case "y", "Y": return "y"
            case "z", "Z": return "z"
            default: return nil
            }
        }

        /// AppKit 视图坐标原点在左下，视口覆盖层用左上原点，统一在这里翻 y
        private func 翻转(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x, y: bounds.height - point.y)
        }

        /// 判断点是否落在"可见窗口"内。
        /// 分栏拖动时渲染画布尺寸固定、只在上下裁掉一部分，
        /// 被裁掉那段仍属于视图 bounds，不该再接收滚轮和点选。
        private func 在可见区(_ point: CGPoint) -> Bool {
            guard bounds.contains(point) else { return false }
            guard 可见留白 > 0 else { return true }
            let 可见顶 = bounds.height - 可见留白
            return point.y <= 可见顶 && point.y >= 可见留白
        }

        // [临时诊断·坐标系标定] 每次点选把 catcher/window 的真实几何写盘，供脚本核对后即删
        private func 诊断(_ 文本: String) {
            let 行 = 文本 + "\n"
            if let h = FileHandle(forWritingAtPath: "/tmp/catcher_debug.log") {
                h.seekToEndOfFile(); h.write(行.data(using: .utf8)!); h.closeFile()
            } else {
                FileManager.default.createFile(atPath: "/tmp/catcher_debug.log", contents: 行.data(using: .utf8))
            }
        }

        override func layout() {
            super.layout()
            let 窗口框 = window?.frame ?? .zero
            let 我方 = window.map { _ in self.convert(self.bounds, to: nil) } ?? .zero
            let 内容 = window?.contentLayoutRect ?? .zero
            诊断("LAYOUT bounds=\(bounds.size) inWindow=\(我方) winFrame=\(窗口框) contentRect=\(内容) scale=\(window?.backingScaleFactor ?? 0)")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }

            // 刷子光标：窗口默认不派发 mouseMoved，得先打开
            self.window?.acceptsMouseMovedEvents = true
            monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                // 绘画 / 手柄接管期间，move 必须一起吞掉。
                // RealityKit 的 mouseMoved 会去读「当前拖拽手势」，而它的 mouseDown 早被我们
                // 吞在外面了，那份状态是空的 —— 放行就是一次强解包 trap，正是这条崩溃栈。
                // 「左键按着但我们没记起点」也一并当作接管：视图重建会把布尔量清零，
                // 这时候靠系统按键态兜底，绝不让半套事件漏过去。
                // 「左键按着但我们没记起点」不再当作接管：那种情况说明这次 down 已经
                // 放行给 RealityKit 了（鼠标落在面板/顶栏上），move 也得一起放行，
                // 否则它收到 down 却收不到 move，拖拽会话同样会半残。
                // 左键按着，但账上没有任何一个「被我们放行的 down」：
                // 说明这次按下 RealityKit 根本没收到 —— 点未激活窗口时 down 被 AppKit
                // 拿去激活窗口、直接没派发到视图。这种按下期间到达的 move 放过去，
                // RealityKit 会自己去补一个假 mouseUp，还是那处 trap，所以照样吞。
                if NSEvent.pressedMouseButtons & 1 != 0, Self.放行的Down == 0,
                   !self.draggingPaint, !self.draggingGizmo {
                    return nil
                }
                if Self.待配平Up > 0 || self.draggingPaint || self.draggingGizmo {
                    if NSEvent.pressedMouseButtons & 1 == 0 {
                        // 抬起事件丢在窗口外了（松手时鼠标已离开）：在这儿把账配平掉，
                        // 否则欠账会一直留到下次按下，把一个本该放行的 up 也吞了
                        if self.draggingPaint { self.onPaintRelease?() }
                        if self.draggingGizmo { self.onGizmoRelease?() }
                        self.draggingPaint = false
                        self.draggingGizmo = false
                        Self.待配平Up = 0
                    } else {
                        return nil
                    }
                }
                let point = self.convert(event.locationInWindow, from: nil)
                // 控件框是按 SwiftUI 视口坐标（原点左上、y 向下）上报的，
                // 这里必须翻过再问，否则上半屏和下半屏的判断会整个对调
                let 界面点 = self.翻转(point)
                // 指针进了面板/顶栏就把刷子光标收掉：否则那个圈会贴着控件边缘被切一半，
                // 看着像画到了 UI 上
                if self.在可见区(point), !(self.hitUI?(界面点) ?? false) {
                    self.onHover?(self.翻转(point), self.bounds.size)
                } else {
                    self.onExit?()
                }
                return event
            } as Any)

            monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                guard self.在可见区(point) else { return event }
                // 落在面板上的滚轮交给面板（遮罩缩放就吃在这一层），视口一点都不动。
                // 同样要先翻成 SwiftUI 视口坐标，不然「鼠标明明在 UI 上」也会漏进来缩放视图
                guard !(self.hitUI?(self.翻转(point)) ?? false) else { return event }
                // 触控板的 precise 增量远小于传统鼠标滚轮，先归一化再交给场景，两者手感一致
                let 滚动量 = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.06 : event.scrollingDeltaY
                self.onScroll?(滚动量)
                return nil
            } as Any)

            // 中键（滚轮按住）平移视口。RealityKit 不管中键，但事件必须「整套」吞：
            // 按下、拖动、抬起都收在自己手里，一个都不漏出去，就不会留半套给下层。
            monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown]) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                // 鼠标侧键：前键（button 4）＝聚焦选中，等同按一次 F；后键（button 3）＝显示并聚焦全部。
                // 侧键一次性触发，不参与拖动；和别的鼠标键一样整套吞掉，不把半套事件漏给系统。
                if event.buttonNumber == 3 || event.buttonNumber == 4 {
                    let point = self.convert(event.locationInWindow, from: nil)
                    if self.在可见区(point), !(self.hitUI?(self.翻转(point)) ?? false) {
                        // 个别鼠标把前后键接反，手感不对就把这里的 4 和 3 对调
                        self.onShortcut?(event.buttonNumber == 4 ? "f" : "focus.all")
                    }
                    return nil
                }
                guard event.buttonNumber == 2 else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                // 落在面板/顶栏上的中键归控件，视口不动
                guard self.在可见区(point), !(self.hitUI?(self.翻转(point)) ?? false) else { return event }
                self.draggingPan = true
                self.平移上一点 = self.翻转(point)
                return nil
            } as Any)

            monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDragged]) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                guard self.draggingPan, event.buttonNumber == 2 else { return event }
                let 现在 = self.翻转(self.convert(event.locationInWindow, from: nil))
                let 上一点 = self.平移上一点 ?? 现在
                self.平移上一点 = 现在
                let delta = CGPoint(x: 现在.x - 上一点.x, y: 现在.y - 上一点.y)
                if delta.x != 0 || delta.y != 0 {
                    self.onPan?(delta, self.bounds.size)
                }
                return nil
            } as Any)

            monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.otherMouseUp]) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                if event.buttonNumber == 3 || event.buttonNumber == 4 { return nil }
                guard event.buttonNumber == 2 else { return event }
                let 接管过 = self.draggingPan
                self.draggingPan = false
                self.平移上一点 = nil
                return 接管过 ? nil : event
            } as Any)

            // W / E / R 切换移动、旋转、缩放；H 隐藏、F 聚焦（长按 F 独立显示）；
            // Alt+H 取消所有隐藏、Alt+F 取消独立显示；有文本输入焦点时不抢键
            // 裸 Alt：按住满时长进拼接模式，松开退出。修饰键不会发 keyDown，只有 flagsChanged，
            // 所以单独挂一条；文本框里一律让路（Alt 在那儿是特殊字符）。
            monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                if let responder = window.firstResponder,
                   responder is NSText || responder is NSTextView {
                    return event
                }
                self.更新Alt(event.modifierFlags.contains(.option))
                return event
            } as Any)

            monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                if let responder = window.firstResponder,
                   responder is NSText || responder is NSTextView {
                    return event
                }
                // Alt + 别的键是组合键（Alt+H / Alt+F），不是拼接：先把长按判据撤掉
                if event.type == .keyDown, event.modifierFlags.contains(.option) {
                    self.取消Alt长按()
                }
                // 数值变换会话进行中：键盘整段先交给它。
                // 这时候 x 是「选 X 轴」不是删物体、z 也不是切着色，一个键都不能漏下去。
                // ⌘ / ⌃ 组合照旧留给系统（保存、撤销不能失灵）
                if self.数值输入中,
                   event.modifierFlags.intersection([.command, .control]).isEmpty {
                    if event.type == .keyDown, !event.modifierFlags.contains(.option),
                       let 标记 = Self.数值键标记(event) {
                        _ = self.on数值键?(标记)
                    }
                    return nil
                }
                // Fn+⌫（forward delete）：直接算一次「删除选中」。
                // 普通 ⌫ 不在这里接 —— 那是菜单里的 keyEquivalent，先于本监视器分发，
                // 由菜单那条统一的「删除选中」去分辨删节点还是删物体
                if event.type == .keyDown, event.keyCode == 117 {
                    guard !event.isARepeat else { return nil }
                    self.onShortcut?("delete")
                    return nil
                }
                // command / control 留给系统菜单，option 是我们要用的（Alt+H / Alt+F）
                guard event.modifierFlags.intersection([.command, .control]).isEmpty,
                      let key = event.charactersIgnoringModifiers?.lowercased(),
                      ["w", "e", "r", "h", "f", "b",
                       "a", "g", "z", "x", "n",
                       "1", "2", "3", "4", "6", "7", "8", "9"].contains(key) else { return event }
                let option = event.modifierFlags.contains(.option)
                // ⇧A：在鼠标处弹「添加物体」面板（Blender 的手感），按下就开，连发不算
                if event.type == .keyDown, key == "a", event.modifierFlags.contains(.shift) {
                    guard !event.isARepeat else { return nil }
                    self.onShortcut?("shift+a")
                    return nil
                }

                if event.type == .keyUp {
                    // 只有裸 F / W / E / R 的抬起才有意义：
                    // F = 聚焦还是独立显示，W / E / R = 切模式还是进入键盘数值变换
                    guard !option else { return event }
                    if key == "f" {
                        self.结束F长按()
                        return nil
                    }
                    if ["w", "e", "r"].contains(key) {
                        self.结束模式长按(key)
                        return nil
                    }
                    return event
                }

                // keyDown：系统自动重复的 F 不算第二次按下，否则长按会被反复重排
                guard !event.isARepeat else { return nil }

                switch (key, option) {
                case ("h", true), ("f", true), ("a", true):
                    self.onShortcut?("alt+\(key)")
                    return nil
                case ("h", false):
                    self.onShortcut?("h")
                    return nil
                case ("f", false):
                    // 先不动手，等 keyUp 才知道是短按（聚焦）还是长按（独立显示）
                    self.开始F长按()
                    return nil
                case ("w", false), ("e", false), ("r", false):
                    // 同理：抬起才知道是短按（切变换模式）还是长按（进入键盘数值变换）
                    self.开始模式长按(key)
                    return nil
                default:
                    guard !option else { return event }
                    self.onShortcut?(key)
                    return nil
                }
            } as Any)

            // 绘画撤销：Cmd+Z（带不带 Shift 都当撤销，重做暂时没有）
            monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                guard event.modifierFlags.contains(.command),
                      !event.modifierFlags.contains(.control),
                      event.charactersIgnoringModifiers?.lowercased() == "z" else { return event }
                guard PaintSession.shared.启用 else { return event }
                PaintSession.shared.撤销()
                return nil
            } as Any)

            monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                let inside = self.在可见区(point)

                // 新的一次按下：上一轮如果还挂着欠账，说明那个 up 彻底丢了（鼠标在别的窗口/
                // 窗口外松的手，系统不会再补发）。这里必须清掉，否则这次按下即便放行给
                // RealityKit，它的 up 也会被我们当欠账吞掉 —— 变成「有 down 没 up」的 trap。
                Self.待配平Up = 0
                // 放行的账同样作废：上一轮那个 down 的 up 已经不可能再来了
                Self.放行的Down = 0

                // 绘画优先：画笔模式下一律当画布，手柄与选中都不抢这次按下
                if inside, self.onPaintPress?(self.翻转(point), self.bounds.size) == true {
                    self.draggingPaint = true
                    Self.待配平Up = 1
                    self.pressPoint = nil
                    return nil
                }

                // 再让对象坐标轴判定：命中手柄就吞掉这次按下，
                // 否则 RealityView 会同时启动轨道旋转
                if inside, self.onGizmoPress?(self.翻转(point), self.bounds.size) == true {
                    self.draggingGizmo = true
                    Self.待配平Up = 1
                    self.pressPoint = nil
                    return nil
                }

                self.pressPoint = inside ? point : nil
                // 这一下放给了 RealityKit（轨道旋转 / 选中），记一笔账：
                // 只有它的 up 到来时才允许再放行，否则孤儿 up 会触发 trap
                Self.放行的Down += 1
                return event
            } as Any)

            // 右键：命中关节球就弹约束面板，别的一概不动（不弹原生菜单，免得跟面板抢事件）
            monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown]) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                guard self.在可见区(point) else { return event }
                return self.onGizmoRightPress?(self.翻转(point), self.bounds.size) == true ? nil : event
            } as Any)

            monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged]) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                if self.draggingPaint {
                    let point = self.convert(event.locationInWindow, from: nil)
                    self.onPaintDrag?(self.翻转(point), self.bounds.size)
                    return nil
                }
                if self.draggingGizmo {
                    let point = self.convert(event.locationInWindow, from: nil)
                    self.onGizmoDrag?(self.翻转(point))
                    return nil
                }
                // 接管态还在、但上面两个分支都没命中（视图重建把实例标记清了）：
                // 这种拖拽照样得吞，漏给 RealityKit 就是同一处 trap。
                // 账上也没有「正在被 RealityKit 跟踪的 down」时更得吞 ——
                // 它压根没收到这次按下，此时收到 mouseMoved 一样会去补发一个假的 mouseUp。
                return (Self.待配平Up > 0 || Self.放行的Down == 0) ? nil : event
            } as Any)

            monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }

                // 这次按下被我们（绘画 / 手柄）接走过，抬起必须一起吞：
                // 给 RealityKit 一个「没有 down 的 up」，它照样会去读空的手势状态 ——
                // 崩溃栈里的 ARView.mouseUp 就是它。判据用跨实例的 Self.待配平Up（吞过几个 down），
                // 视图重建丢了 draggingPaint 也照样成对。
                if Self.待配平Up > 0 || self.draggingPaint || self.draggingGizmo {
                    if self.draggingPaint {
                        self.draggingPaint = false
                        self.onPaintRelease?()
                    }
                    if self.draggingGizmo {
                        self.draggingGizmo = false
                        self.onGizmoRelease?()
                    }
                    // 只还我们欠的那一个：吞了几个 down 就吞几个 up，绝不多吞 ——
                    // 多吞一个就是让 RealityKit 挂着永远等不到的 up，下次 move 时 trap
                    if Self.待配平Up > 0 { Self.待配平Up -= 1 }
                    self.pressPoint = nil
                    return nil
                }

                // 到这里说明我们没接管过这一笔。那也不能想当然放给 RealityKit：
                // 只有「账上确实有一个被放行的 down 在等这个 up」才放，否则一律吞。
                // 点击未激活窗口、从别的 App 按着拖进来、上一笔 up 丢在窗口外 ——
                // 这三种都只有 up 没有 down，放过去就是 ARView.mouseUp 的 trap。
                // 判定只做一次，后面每个出口都按同一个结果走，账和事件不会错位。
                let 应放行 = Self.放行这次抬起()
                guard let start = self.pressPoint else { return 应放行 ? event : nil }
                self.pressPoint = nil
                let point = self.convert(event.locationInWindow, from: nil)
                // 位移超过阈值就当拖拽（轨道旋转已由 SwiftUI 处理），不算点选
                guard abs(point.x - start.x) < 4, abs(point.y - start.y) < 4 else { return 应放行 ? event : nil }
                // 同一事件可能被多个监视器收到（视图重建残留），60ms 内去重
                let now = ProcessInfo.processInfo.systemUptime
                guard now - self.lastTapTime > 0.06 else { return 应放行 ? event : nil }
                self.lastTapTime = now
                // Shift 加选：修饰键状态直接从这次鼠标事件读，
                // 不额外维护按键态，避免焦点切换后残留
                let shift = event.modifierFlags.contains(.shift)
                self.诊断("TAP windowPoint=\(event.locationInWindow) viewPoint=\(point) flipped=\(self.翻转(point)) size=\(self.bounds.size) shift=\(shift)")
                self.onTap?(self.翻转(point), self.bounds.size, shift)
                return 应放行 ? event : nil
            } as Any)
        }

        func stop() {
            f长按任务?.cancel()
            f长按任务 = nil
            f长按已触发 = false
            draggingPan = false
            平移上一点 = nil
            for monitor in monitors { NSEvent.removeMonitor(monitor) }
            monitors.removeAll()
        }

        override var isOpaque: Bool { false }
    }
}

// MARK: - 视口面板（视口 + 浮动工具条 + 角标）

struct ViewportPanel: View {
    @Environment(着色Store.self) private var store
    @Environment(布局Store.self) private var scene
    @State private var 偏好 = 偏好设置Store.shared
    /// 绘画会话（单例）：刷子参数、开关、光标状态都在这儿
    @State private var 绘画 = PaintSession.shared

    /// 视口场景由面板持有：轴向控件和对象坐标轴都要读同一台轨道相机的参数
    @State private var 视口场景 = ViewportScene()
    @State private var 相机 = 视口相机()
    @State private var 手柄模式: 变换模式 = .移动
    /// 手柄按全局轴还是物体自身轴摆放（W / E / R 左边那个控件）
    @State private var 手柄空间: 坐标空间 = .全局
    @State private var 激活轴: 手柄轴?
    /// 中心球是否被按住：移动=平面拖、缩放=等比
    @State private var 球激活 = false
    @State private var 拖拽: 手柄拖动?
    /// 约束面板：右键关节球弹出来，管理这一节的「算法约束」（目标骨 + 链长）
    @State private var 约束骨路径: String?
    @State private var 约束骨名: String = ""
    @State private var 显示约束面板 = false
    /// 新建约束时面板里选的参数
    @State private var 新约束型: 角色约束型 = .反向动力学
    @State private var 新约束目标: String = ""
    @State private var 新约束链长 = 2
    /// 点中的关节球（只表示"选中了哪一节骨"）。点球就只是选它，别的什么都不做。
    @State private var 关节选中: 关节选中项?
    /// 正在拖的关节（拖三轴手柄改这一节骨的局部旋转）
    @State private var 关节拖拽: 关节拖动?
    /// 木偶会话：拖关节球时抓着哪个关节 + 这一身的拓扑表（按下建一次，拖动时复用）
    @State private var 木偶会话: 木偶抓取会话?
    /// 长按 W / E / R 进入的键盘数值变换（nil = 没在进行）
    @State private var 数值会话: 数值变换会话?
    /// 拼接模式（长按 Alt）：视口里可见对象的中心 / 包围盒直角顶点出环，点两个环做点对点吸附。
    /// 候选点的世界坐标只在进入、吸附之后算一次；屏幕位置由环层每帧按实时机位重新投影，
    /// 所以中键平移、滚轮缩放、转视角时环都咬在模型上，不会留在原地飘。
    @State private var 拼接中 = false
    @State private var 拼接候选: [拼接锚点] = []
    @State private var 拼接源: 拼接点?
    /// 会话开始那一刻的成员快照：esc 要能整段退回去，所以每次都从这份重算
    @State private var 数值基准: [手柄成员] = []
    /// 长按 W 之后物体跟着鼠标走：起点是长按那一刻的鼠标位置（视口像素）
    @State private var 抓取起点: CGPoint?
    /// 枢轴所在深度处「一个像素等于多少世界长度」，以及该深度的相机平面基
    @State private var 抓取每像素: Float = 0
    @State private var 抓取右向 = SIMD3<Float>(1, 0, 0)
    @State private var 抓取上向 = SIMD3<Float>(0, 1, 0)
    /// 鼠标带出来的世界位移（跟数字输入互斥：一敲数字就以数字为准）
    @State private var 抓取位移 = SIMD3<Double>.zero
    /// 鼠标带出来的旋转角度（度）与缩放倍率：长按 E / R 之后鼠标一动就跟着转 / 缩
    @State private var 抓取角度: Double = 0
    @State private var 抓取倍率: Double = 1
    /// 状态栏文案去重 + 节流：鼠标每帧都在动，不能每帧都改状态栏
    @State private var 抓取读数 = ""
    @State private var 抓取刷新时刻: TimeInterval = 0
    @State private var 手柄中心: SIMD3<Float>?
    /// 右上角轴向控件的实际占位：AppKit 事件监视器先于 SwiftUI 命中，
    /// 点在这个框里就不该再当成视口点选或手柄拖动
    @State private var 轴向控件框: CGRect = .zero
    /// 顶栏 / 底栏的占位：落在这些框里的鼠标事件是给控件的，不能当成视口点选
    @State private var 控件框: [CGRect] = []
    /// 摄像机取景：全局就这一台，不做场景对象、不进大纲、没有可拖的实体。
    /// 打开只是在视口里画一个画幅框，框外压暗，纯视口状态。
    @State private var 摄像机取景 = false
    @State private var 取景画幅: 取景比例 = .宽16比9
    /// 辉光设置泡泡（三根滑杆放不下菜单，改挂 popover，拖动时菜单不会被打断）
    @State private var 显示辉光设置 = false
    /// 画布实际尺寸：材质球库拖进来的落点要换算成拾取用的视口坐标
    @State private var 视口尺寸: CGSize = .zero
    /// 添加物体面板：按钮点在哪儿就贴哪儿，⇧A 则贴鼠标
    @State private var 显示添加面板 = false
    /// 面板左上角（视口坐标）
    @State private var 添加面板原点: CGPoint = .zero
    /// 顶栏那个 + 按钮的占位，按钮入口要用它算面板位置
    @State private var 添加按钮框: CGRect = .zero
    /// 最近一次鼠标在视口里的位置（⇧A 就在这儿弹面板）
    ///
    /// 故意放一个引用型缓存里、不当 @State：鼠标一动就要记一次位置，而 @State 写一下整个视口
    /// body 就得重算（RealityView update / 场景 sync / PT 视口全部跟着走）。材质球从库里拖过来时
    /// 指针一直在视口上划过，两千次 mouseMoved 就是两千次全量重算，主线程顾不上刷系统的拖影，
    /// 那个方块就会滞后、甚至停在半路上等人。这里只在按 ⇧A 的那一刻读一次，不值得为它整体重绘。
    private final class 鼠标位置缓存 {
        var 点: CGPoint = .zero
    }
    @State private var 鼠标位置 = 鼠标位置缓存()
    /// 渲染画布高度：分栏拖动时保持恒定，相机与画幅都不变
    var 画布高: CGFloat?
    /// 当前可见窗口高度：画布上下各裁掉 (画布高 - 可见高) / 2
    var 可见高: CGFloat?

    /// 画布在可见窗口上下多出来的留白（像素）。
    /// 视口内部坐标一律以画布左上角为原点，浮动控件据此往可见窗口边界内缩。
    private var 画布留白: CGFloat {
        guard let 画布高, let 可见高 else { return 0 }
        return max(0, (画布高 - 可见高) / 2)
    }

    var body: some View {
        ZStack {
            Theme.viewportBackground
            // 约束面板的锚点：右键关节球时弹在这儿（1pt 透明，不挡点击）
            Color.clear
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
                .popover(isPresented: $显示约束面板, arrowEdge: .top) { 约束面板 }
            Viewport3DSurface(
                objects: scene.objects,
                materials: store.materialsByID,
                settings: store.viewport,
                物理域: store.物理域,
                selectedObjectID: scene.selectedObjectID,
                选中集合: scene.选中集合,
                scene: 视口场景,
                onPick: { id, point, shift in
                    scene.选中(id, 加选: shift)
                    刷新手柄中心()
                    // Shift 点空白处保持原选择，不回显；真加进来了才报数量
                    guard id != nil, shift else { return }
                    if scene.选中集合.count > 1 {
                        store.note("加选：\(scene.选中集合.count) 个物体（Shift 再点可减选）")
                    }
                },
                onCameraChange: { snapshot in
                    相机 = snapshot
                    // 机位随操作实时记进 store：不主动写盘，等下一次 persist（⌘S 或其它编辑）带上
                    let 新存档 = 视口场景.相机存档()
                    if store.视口相机存档 != 新存档 { store.视口相机存档 = 新存档 }
                    // 拼接环的位置在长按 Alt 那一刻就定死了，机位怎么变都不重算，也不新增环
                    刷新手柄中心()
                },
                onShortcut: { key in
                    // 显隐 / 聚焦系走这里，其余交给变换模式
                    switch key {
                    case "h":
                        隐藏选中()
                    case "n":
                        // N 是这个视口自己的抽屉开关：展开时把视口挤窄，不盖画面
                        store.n面板可见.toggle()
                        store.note(store.n面板可见 ? "N 面板：展开（\(store.n面板页.标题)）" : "N 面板：收起")
                    case "alt+h":
                        显示全部()
                    case "f":
                        聚焦选中()
                    case "focus.all":
                        显示并聚焦全部()
                    case "shift+a":
                        在鼠标处打开添加面板()
                    case "f.hold":
                        独立显示选中()
                    case "b":
                        绘画.启用.toggle()
                        store.note(绘画.启用
                                   ? "绘画：开 — 左键上色，空白处拖动仍可转视角（B 关闭）"
                                   : "绘画：关")
                    case "alt+f":
                        取消独立显示()
                    case "a":
                        scene.全选()
                        store.note("全选 \(scene.选中集合.count) 个物体")
                    case "alt+a":
                        scene.取消选择()
                        store.note("取消选择")
                    case "alt.hold":
                        进入拼接()
                    case "alt.up":
                        退出拼接()
                    case "w.hold", "e.hold", "r.hold":
                        进入数值变换(String(key.prefix(1)))
                    case "g":
                        手柄空间 = (手柄空间 == .全局 ? .局部 : .全局)
                        store.note("坐标空间：\(手柄空间.title)")
                    case "z":
                        循环着色()
                    case "x", "delete":
                        // 这条键盘监视器是窗口级的，跟鼠标停在哪无关 —— 先问焦点：
                        // 鼠标在材质区时，这里绝不能删视口物体
                        if scene.焦点 == .节点编辑器 {
                            if store.selectedNodeID != nil || store.selectedLinkID != nil {
                                store.deleteSelection()
                            } else {
                                store.note("节点编辑器里没有选中节点或连线")
                            }
                        } else {
                            删除选中物体()
                        }
                    // 数字键照小键盘的方位来：2 底、4 左、6 右、8 顶，
                    // 1/3/7/9 分别对前、右、顶、后 —— 熟悉的不用记，盲按也对
                    case "1":
                        对齐(.前视)
                    case "2":
                        对齐(.底视)
                    case "3":
                        对齐(.右视)
                    case "4":
                        对齐(.左视)
                    case "6":
                        对齐(.右视)
                    case "7":
                        对齐(.顶视)
                    case "8":
                        对齐(.顶视)
                    case "9":
                        对齐(.后视)
                    default:
                        guard let mode = 变换模式.from(shortcut: key) else { return }
                        手柄模式 = mode
                        store.note("变换模式：\(mode.title)（\(mode.shortcut)）")
                    }
                },
                数值输入中: 数值会话 != nil,
                on数值键: { 键 in 数值键盘输入(键) },
                shouldIgnoreTap: 点中控件,
                onGizmoPress: 手柄按下,
                onGizmoDrag: 手柄拖动中,
                onGizmoRelease: 手柄抬起,
                onPan: 平移视口,
                onPaintPress: { point, size in
                    // 顶栏/底栏/图层面板都是普通控件，画笔不能把它们当画布
                    guard !点中控件(point) else { return false }
                    return 绘画.按下(point: point, size: size, objects: scene.objects, 相机: 相机)
                },
                onPaintDrag: { point, size in
                    绘画.拖动(point: point, size: size, objects: scene.objects, 相机: 相机)
                },
                onPaintRelease: {
                    绘画.抬起()
                },
                onHover: { point, size in
                    // ⇧A 要在鼠标处弹面板，位置一直跟着最后一次移动走（走缓存，不触发重绘）
                    鼠标位置.点 = point
                    // 鼠标真的落在视口可见区（且不在任何面板上）才算回视口干活
                    if scene.焦点 != .视口 { scene.焦点 = .视口 }
                    // 长按 W 的抓取期间：鼠标就是位移本身，画笔与悬停都让路
                    if 数值会话 != nil {
                        抓取跟随(point)
                        return
                    }
                    guard 绘画.启用, !点中控件(point) else { return }
                    绘画.移动(point: point, size: size, objects: scene.objects, 相机: 相机)
                },
                onExit: {
                    绘画.移出视口()
                },
                可见留白: 画布留白
            )
            .allowsHitTesting(true)

            // 对象坐标轴：只画不接收事件，拖动统一由上面的事件监视器处理
            GeometryReader { proxy in
                // 选中角色时不摆三轴手柄：这一身要摆姿势，关节球才是主角，
                // 三轴手柄的中心球刚好压在人身上，两个控件叠着谁都点不准
                // 选中关节时同样要手柄：没有三轴就看不出到底选中了哪一节
                // 选中「角色本体」也出手柄 —— 那时候枢轴已经挪到脚下圆盘上，不压人，
                // 摆姿势的关节球和整身变换各占一块屏，互不抢点击
                let 选中容器 = scene.选中物体们.contains { $0.角色 != nil }
                if !拼接中, scene.selectedObjectID != nil,
                   可编辑角色() == nil || 关节选中 != nil || 选中容器, let 中心 = 手柄中心 {
                    坐标轴手柄层(
                        相机: 相机,
                        世界位置: 中心,
                        模式: 手柄模式,
                        轴旋转: 手柄空间旋转,
                        激活轴: 激活轴,
                        球激活: 球激活
                    )
                    .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
            .allowsHitTesting(false)

            // 容器圆盘：选中角色时脚下那只圈。跟随根骨、只画不接收事件，
            // 点击由事件监视器的「圆盘按下」接管 —— 点它等于选中这一身
            GeometryReader { proxy in
                let 盘们 = 角色圆盘们(proxy.size)
                if !拼接中, let 盘 = 盘们.first {
                    角色圆盘层(盘: 盘, 高亮: 关节选中 == nil)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
            .allowsHitTesting(false)

            // 关节球：选中角色（或它的部件）时，骨架上每根骨的终点各给一颗实心球。
            // 膝盖 / 脚踝 / 指尖这些关节就是子骨的头点、父骨的尾点 —— 一骨一球，全都调得到。
            // 同样是纯绘制层，命中交给事件监视器 —— 点中球就是摆这一节骨。
            GeometryReader { proxy in
                let 球们 = 关节球们(proxy.size)
                if !拼接中, !球们.isEmpty {
                    关节球层(球们: 球们, 激活: 关节选中?.键)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
            .allowsHitTesting(false)

            // 拼接环：同样是纯绘制层，命中交给事件监视器转过来的「手柄按下」
            GeometryReader { proxy in
                if 拼接中, !拼接候选.isEmpty {
                    拼接环层(相机: 相机, 候选: 拼接候选, 源: 拼接源)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
            .allowsHitTesting(false)

            // 刷子光标：半径按命中点深度换算，离得远圈就小，圈住的范围就是真画到的范围
            GeometryReader { proxy in
                if 绘画.启用, let 光标 = 绘画.光标 {
                    let r = max(绘画.光标像素半径(size: proxy.size, 相机: 相机), 4)
                    // 笔刷圆盘 → 屏幕的仿射矩阵（由命中点法线 + 相机算出）。
                    // 没命中表面时退回单位阵：此时画正圆虚线，表示「这里画不上」。
                    let 圆盘 = 绘画.圆盘到屏幕(size: proxy.size, 相机: 相机)
                        ?? CGAffineTransform(translationX: 光标.x, y: 光标.y)
                            .scaledBy(x: r, y: r)

                    // 圈里的遮罩预览：整张遮罩图铺满笔刷圆盘（直径 = 2r），再整体贴到
                    // 命中点的切平面上 —— 所以圈按表面朝向压成椭圆，图案跟着面一起歪。
                    //
                    // 这里必须用「切平面基」的仿射变换，不能只做 rotationEffect：
                    // 正对屏幕的面，圆盘就是正圆；俯视/侧视的面，圆盘在屏幕上是个椭圆。
                    // 只转不压的话，不管鼠标挪到哪个面，圈永远是个正圆 —— 那就是
                    // 用户看到的「笔刷永远贴视口」。
                    ZStack(alignment: .topLeading) {
                        if 绘画.光标在表面, 绘画.brush.mask != .无,
                           let 遮罩图 = 绘画.brush.mask.缩略图(256) {
                            Image(nsImage: 遮罩图)
                                .resizable()
                                .interpolation(.high)
                                .frame(width: r * 2, height: r * 2)
                                .scaleEffect(CGFloat(max(绘画.brush.maskScale, 0.05)))
                                .rotationEffect(.degrees(Double(绘画.brush.maskRot)))
                                // 平移量按「一整个笔刷直径」换算，和 shader 里
                                // uv - 0.5 - maskOffset 是同一套单位，所以面板上拖到哪、
                                // 圈里就偏到哪，1:1 一致
                                .offset(x: CGFloat(绘画.brush.maskOffset.x) * r * 2,
                                        y: CGFloat(绘画.brush.maskOffset.y) * r * 2)
                                .遮罩反转(绘画.brush.maskInvert)
                                .opacity(0.5)
                                .frame(width: r * 2, height: r * 2)
                                .clipShape(Circle())
                                .position(x: r, y: r)
                                .transformEffect(贴平面变换(圆盘, 圆半径: r))
                        }

                        Circle()
                            .strokeBorder(
                                绘画.光标在表面 ? Color.white : Color.white.opacity(0.55),
                                style: StrokeStyle(
                                    lineWidth: 1.5,
                                    dash: 绘画.光标在表面 ? [] : [3, 3]
                                )
                            )
                            .background(
                                Circle().strokeBorder(Color.black.opacity(0.45), lineWidth: 2.5)
                            )
                            .frame(width: r * 2, height: r * 2)
                            .position(x: r, y: r)
                            .transformEffect(贴平面变换(圆盘, 圆半径: r))
                    }
                }
            }
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                // 顶栏和它下面的性能指标绑在一个左对齐的竖列里：
                // 顶栏宽度不变，指标贴在顶栏左下角，底栏仍占满整行
                VStack(alignment: .leading, spacing: 8) {
                    topBar
                        .背景框上报()
                    if 显示性能指标 {
                        视口性能面板()
                    }
                }
                Spacer(minLength: 0)
                // 底栏不再整条上报：整条 HStack 的高度取最高的「对象信息卡」，
                // 中间/右侧那些矮按钮上方会多出一条约 18pt 的透明空白，
                // 整条上报会把这条空白也算成控件，那片区域就点不到模型了。
                // 改成每个可见控件各自上报自己的框（见 bottomBar 内部）。
                bottomBar
            }
            .padding(.horizontal, 10)
            .padding(.top, 10 + 画布留白)
            .padding(.bottom, 10 + 画布留白)

            // 摄像机取景框：压在画面之上、控件之下 —— 框外压暗，但顶底栏和侧边条照常能点。
            // 只画框，不改渲染：将来「渲染出图」按这个画幅裁。
            if 摄像机取景 {
                摄像机取景层(比例: 取景画幅)
            }

            // 左右竖向工具条：垂直居中摆，避开顶栏、底栏、右上角轴向控件和右下角标
            HStack(alignment: .center, spacing: 0) {
                左侧工具条(
                    取消选择: {
                        scene.取消选择()
                        store.note("取消选择")
                    },
                    聚焦选中: { 聚焦选中() },
                    隐藏选中: { 隐藏选中() },
                    显示全部: { 显示全部() }
                )
                .背景框上报()

                Spacer(minLength: 0)

                右侧工具条(
                    摄像机: $摄像机取景,
                    比例: $取景画幅,
                    注: { store.note($0) }
                )
                .背景框上报()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 66 + 画布留白)

            // 右上角轴向控件：挂在顶栏下方，避免压住顶栏控件
            VStack {
                HStack {
                    Spacer(minLength: 0)
                    轴向指示控件(相机: 相机) { 轴向 in
                        对齐(轴向)
                    }
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: 轴向控件框Key.self,
                                value: proxy.frame(in: .named("视口"))
                            )
                        }
                    )
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 54 + 画布留白)
            .padding(.trailing, 12)

            // 左下角图层面板：浮在底栏上方，只在绘画开着的时候出现。
            // 用量到的视口尺寸喂给面板，让它自己决定宽高 —— 窗口拉多小都不会溢出边界。
            if 绘画.启用 {
                GeometryReader { gen in
                    VStack {
                        Spacer(minLength: 0)
                        HStack {
                            PaintPanelView(
                                objects: scene.objects.filter { $0.isVisible },
                                可用: CGSize(
                                    width: max(0, gen.size.width - 24),
                                    height: max(0, gen.size.height - 130)
                                )
                            )
                            .背景框上报()
                            Spacer(minLength: 0)
                        }
                    }
                    .padding(.leading, 10)
                    .padding(.bottom, 10 + 画布留白 + 44)
                }
                .allowsHitTesting(true)
            }

            // 单位角标：右下角小字提示，只做展示层，不参与任何命中测试
            VStack {
                Spacer(minLength: 0)
                HStack {
                    Spacer(minLength: 0)
                    视口单位角标()
                }
            }
            .padding(.trailing, 12)
            .padding(.bottom, 10 + 画布留白 + 44)
            .allowsHitTesting(false)
        }
        .coordinateSpace(name: "视口")
        // 材质球库 → 视口：落在哪个物体上就给谁上材质；落在空处就用当前选中
        .modifier(材质投放修饰(
            视口尺寸: $视口尺寸,
            落点接收: { info, 落点 in 接收材质球(info, 落点: 落点) }
        ))
        .onPreferenceChange(轴向控件框Key.self) { 轴向控件框 = $0 }
        .onPreferenceChange(视口控件框Key.self) { 控件框 = $0 }
        .onPreferenceChange(添加按钮框Key.self) { 添加按钮框 = $0 }
        .overlay(alignment: .topLeading) {
            if 显示添加面板 { 添加面板遮罩 }
        }
        .clipShape(RoundedRectangle(cornerRadius: 0))
        .onAppear {
            // 打开工程先还原保存时的机位：所见即所得，不强制聚焦
            if let 存档 = store.视口相机存档 {
                视口场景.应用相机存档(存档)
            }
            相机 = 视口场景.相机快照()
            刷新手柄中心()
            绘画.同步场景(scene.objects)
            // 上次的搜索对焦请求可能还没消费（比如当时视口没显示）
            消费视口聚焦请求()
        }
        // 载入 / 打开另一个工程时再套一次机位（面板不一定会重建）
        .onChange(of: store.相机还原信号) { _, _ in
            guard let 存档 = store.视口相机存档 else { return }
            视口场景.应用相机存档(存档)
            相机 = 视口场景.相机快照()
            刷新手柄中心()
        }
        .onChange(of: scene.selectedObjectID) { _, _ in
            // 换了选中物体，关节选中跟着作废：骨属于某个角色，不能跨角色留着
            if let 选中 = 关节选中, scene.selectedObjectID != 选中.角色ID {
                关节选中 = nil
            }
            刷新手柄中心()
            激活轴 = nil
            球激活 = false
            拖拽 = nil
            // 换对象了，旧会话的基准就没意义了，别再往新对象上套
            if 数值会话 != nil { 结束数值变换(回滚: false) }
        }
        // 多选增减时主选中可能没变（比如减掉的是别人），枢轴仍要跟着挪
        .onChange(of: scene.选中集合) { _, _ in
            刷新手柄中心()
            激活轴 = nil
            球激活 = false
            拖拽 = nil
        }
        .onChange(of: scene.objects) { _, 新 in
            刷新手柄中心()
            // 可见集合变了要重排图集 slice，否则 PT 那边会拿旧映射采样到别人的笔迹
            绘画.同步场景(新)
        }
        .onChange(of: store.viewport.shading) { _, 新 in
            // 离开路径追踪就把面板数据清掉，免得下次切回来先闪一眼上一轮的旧读数
            if 新 != .pathTraced { PT性能统计.shared.清空() }
        }
        .onChange(of: 手柄模式) { _, _ in
            激活轴 = nil
            球激活 = false
            拖拽 = nil
        }
        .onChange(of: 手柄空间) { _, 新 in
            激活轴 = nil
            球激活 = false
            拖拽 = nil
            // 多选没有共同的自轴，切到局部也没用，直接说清楚免得以为失灵
            if 新 == .局部, scene.选中集合.count > 1 {
                store.note("多选按全局轴变换")
            }
        }
        // 全局搜索跳过来的对焦请求：选中已经在布局域做完，这里只管把镜头挪过去
        .onChange(of: store.视口聚焦请求) { _, _ in 消费视口聚焦请求() }
    }

    // MARK: 快捷键动作

    /// 中键平移：相机在 Domain 里挪，覆盖层要立刻拿同一份快照，
    /// 否则手柄按旧视角画，拖起来就对不上手指
    private func 平移视口(_ delta: CGPoint, 尺寸 size: CGSize) {
        视口场景.pan(delta: delta, 视图尺寸: size)
        相机 = 视口场景.相机快照()
    }

    /// Z：按 路径追踪 → 材质 → 纯色 → 线框 → 法线 循环。
    /// 顺序照着「从好看往调试方向走」排，反方向就用 Shift+Z 的直觉也没有 —— 来回按就行
    private func 循环着色() {
        let 序: [ViewportShading] = [.pathTraced, .material, .solid, .wireframe, .normal]
        let 当前 = 序.firstIndex(of: store.viewport.shading) ?? 0
        let 下一个 = 序[(当前 + 1) % 序.count]
        store.viewport.shading = 下一个
        store.note("着色：\(下一个.title)（Z 循环切换）")
    }

    /// X / ⌫ / Fn+⌫：删掉所有选中物体，顺手把手柄收掉
    private func 删除选中物体() {
        let 数量 = scene.删除选中物体()
        guard 数量 > 0 else {
            store.note("没有选中物体，先点一个再删")
            return
        }
        手柄中心 = nil
        激活轴 = nil
        球激活 = false
        拖拽 = nil
        store.note("已删除 \(数量) 个物体")
    }

    // MARK: 轴向对齐

    private func 对齐(_ 轴向: 视口轴向) {
        store.note("视图对齐：\(轴向.title)")
        视口场景.对齐(轴向) { snapshot in
            相机 = snapshot
            刷新手柄中心()
        }
    }

    // MARK: 键盘数值变换（长按 W / E / R）

    /// 长按 W / E / R：选中的对象直接进入该变换，接下来敲的就是量。
    /// 和拖手柄互斥 —— 先把拖动状态收干净，再按一份快照起算。
    private func 进入数值变换(_ 键: String) {
        guard let 模式 = 变换模式.from(shortcut: 键) else { return }
        let 目标 = scene.选中物体们.filter(\.isVisible)
        guard !目标.isEmpty else {
            store.note("先选中物体，再长按 \(键.uppercased()) 敲数值")
            return
        }
        // 换了键等于换了一次活：上一段先按原样退回去，别把两段混着算
        if 数值会话 != nil { 结束数值变换(回滚: true) }

        拖拽 = nil
        激活轴 = nil
        球激活 = false
        手柄模式 = 模式

        // 枢轴跟手柄同一个：单选是物体中心，多选是整体中心，旋转 / 缩放要绕它
        let 中心 = 手柄中心 ?? 视口场景.世界位置(of: 目标[0].id)
        let 枢轴 = 中心.map { SIMD3<Double>(Double($0.x), Double($0.y), Double($0.z)) }
            ?? SIMD3<Double>(0, 0, 0)
        数值基准 = 目标.map {
            手柄成员(id: $0.id, 位置: $0.position, 旋转: $0.rotation, 缩放: $0.scale)
        }
        数值会话 = 数值变换会话(模式: 模式, 枢轴: 枢轴)
        抓取起点 = nil
        抓取位移 = .zero
        抓取角度 = 0
        抓取倍率 = 1
        抓取读数 = ""
        抓取刷新时刻 = 0
        // 位移换算全用枢轴所在深度的相机平面：鼠标往右推，物体就沿屏幕右向走
        if 视口尺寸.width > 1, 视口尺寸.height > 1,
           let 球 = 相机.中心球(中心: 中心 ?? .zero, 视图尺寸: 视口尺寸) {
            抓取每像素 = 球.每像素世界长度
            抓取右向 = 球.右向
            抓取上向 = 球.上向
        } else {
            抓取每像素 = 0.005
            抓取右向 = 相机.右向
            抓取上向 = 相机.上向
        }
        switch 模式 {
        case .移动:
            store.note("移动中：鼠标往哪推物体就跟到哪 · 点击确认，esc 取消 · X / Y / Z 锁轴 · 长按 Alt 拼接")
        case .旋转, .缩放:
            store.note("\(模式.title)中：鼠标拖动跟着变，也可以敲\(单位词(模式))（X / Y / Z 锁轴）· 点击确认，esc 取消 · 长按 Alt 拼接")
        }
    }

    /// 抓取期间鼠标动了：把像素位移换成世界位移，立刻刷一次预览
    private func 抓取跟随(_ point: CGPoint) {
        guard let 会话 = 数值会话 else { return }
        // 起点定在「长按之后鼠标第一次动」的那一刻：
        // 光标本来停在哪都行，不会因为按下位置和真实光标不一致而跳一大截
        guard let 起点 = 抓取起点 else {
            抓取起点 = point
            return
        }
        let dx = Float(point.x - 起点.x)
        // 视口 y 朝下，世界「上」要取反
        let dy = -Float(point.y - 起点.y)
        switch 会话.模式 {
        case .移动:
            let 平面 = (抓取右向 * dx + 抓取上向 * dy) * 抓取每像素
            抓取位移 = SIMD3<Double>(Double(平面.x), Double(平面.y), Double(平面.z))
        case .旋转:
            // 横向 240px ≈ 180°：锁了轴就绕那根轴，没锁就绕视线（Blender 里 R 的手感）
            抓取角度 = Double(dx) * 0.75
        case .缩放:
            // 向右放大、向左缩小；留个下限免得倍率跑到 0 以下把物体压没
            抓取倍率 = max(0.01, 1 + Double(dx) * 0.005)
        }

        应用数值预览(会话)
        刷新手柄中心()

        // 状态栏只在读数真的变了才写，而且 0.08s 一次，免得每帧都惊动 UI
        let 读数 = 会话读数(会话)
        let 现在 = Date().timeIntervalSince1970
        guard 读数 != 抓取读数, 现在 - 抓取刷新时刻 > 0.08 else { return }
        抓取读数 = 读数
        抓取刷新时刻 = 现在
        store.note("\(会话.模式.title)：\(读数) · 点击确认，esc 取消" + 未锁轴提示(会话))
    }

    /// 鼠标带出来的世界位移：锁了轴就把它投到轴上（按 X 之后只有沿 X 会动）
    private func 抓取移动向量(_ 会话: 数值变换会话) -> SIMD3<Float> {
        let 原始 = SIMD3<Float>(Float(抓取位移.x), Float(抓取位移.y), Float(抓取位移.z))
        guard let 轴 = 会话.轴 else { return 原始 }
        let 方向 = 该轴世界方向(轴, 旋转: 手柄空间旋转)
        return 方向 * simd_dot(原始, 方向)
    }

    /// 当前会话的读数：键盘敲了东西就报键盘的，没敲就报鼠标带出来的量
    private func 会话读数(_ 会话: 数值变换会话) -> String {
        if 会话.文本.isEmpty, 会话.累计.isEmpty {
            switch 会话.模式 {
            case .移动 where 抓取位移 != .zero:
                return 位移读数(抓取移动向量(会话))
            case .旋转 where 抓取角度 != 0:
                return 旋转读数(会话)
            case .缩放 where 抓取倍率 != 1:
                return 缩放读数(会话)
            default:
                break
            }
        }
        return 数值显示文案(会话)
    }

    /// 旋转读数：锁了轴就报那根轴的角度，没锁就是绕视线转
    private func 旋转读数(_ 会话: 数值变换会话) -> String {
        "\(会话.轴?.标题 ?? "视图")轴 \(短数值(抓取角度))°"
    }

    /// 缩放读数：锁了轴只报那根轴的倍率，没锁就是等比
    private func 缩放读数(_ 会话: 数值变换会话) -> String {
        let 前缀 = 会话.轴.map { "\($0.标题)轴 " } ?? "等比 "
        return 前缀 + "×" + 短数值(抓取倍率)
    }

    /// 键盘或鼠标任意一路出了实打实的量：没有就别去动场景
    private func 会话有动静(_ 会话: 数值变换会话) -> Bool {
        会话.有数值
            || (会话.模式 == .移动 && 抓取位移 != .zero)
            || (会话.模式 == .旋转 && 抓取角度 != 0)
            || (会话.模式 == .缩放 && 抓取倍率 != 1)
    }

    private func 位移读数(_ 位移: SIMD3<Float>) -> String {
        "X轴 \(短数值(Double(位移.x)))  Y轴 \(短数值(Double(位移.y)))  Z轴 \(短数值(Double(位移.z)))"
    }

    private func 单位词(_ 模式: 变换模式) -> String {
        switch 模式 {
        case .移动: return "位移"
        case .旋转: return "角度"
        case .缩放: return "倍率"
        }
    }

    /// 数值会话的键：状态全在会话里演进，改完立刻刷一次预览
    private func 数值键盘输入(_ 键: String) -> Bool {
        guard var 会话 = 数值会话 else { return false }
        let 结果 = 会话.按键(键)
        数值会话 = 会话
        switch 结果 {
        case .继续:
            应用数值预览(会话)
            刷新手柄中心()
            // 键盘一改立刻重写底栏：只靠鼠标移动刷新会让人以为「按了没反应」
            store.note("\(会话.模式.title)：\(会话读数(会话)) · 点击确认，esc 取消" + 未锁轴提示(会话))
        case .确认:
            应用数值预览(会话)
            let 读数 = 会话读数(会话)
            let 有动静 = 会话有动静(会话)
            结束数值变换(回滚: false)
            store.note(有动静
                       ? "\(会话.模式.title)：\(读数)"
                       : "没输数值，\(会话.模式.title)没有执行")
        case .取消:
            结束数值变换(回滚: true)
            store.note("已取消\(会话.模式.title)")
        case .忽略:
            break
        }
        return true
    }

    // MARK: - 模型拼接（长按 Alt）

    /// 底栏尾巴：还没锁轴的时候顺手把「锁轴」和「长按 Alt 拼接」两件事摆出来
    private func 未锁轴提示(_ 会话: 数值变换会话) -> String {
        会话.轴 == nil ? " · X / Y / Z 锁轴 · 长按 Alt 拼接" : ""
    }

    /// 长按 Alt 进拼接：和锁轴不是一套，数值会话就地收掉，物体停住不再跟鼠标。
    /// 然后给视口里每个可见对象铺「中心环 + 八个直角顶点环」，点两个环做点对点吸附。
    private func 进入拼接() {
        guard !拼接中 else { return }
        if 数值会话 != nil { 结束数值变换(回滚: false) }
        拖拽 = nil
        激活轴 = nil
        球激活 = false
        拼接中 = true
        拼接源 = nil
        刷新拼接候选()
        store.note(拼接候选.isEmpty
                   ? "拼接：视口里没有可吸附的对象"
                   : "拼接：\(拼接候选.count) 个吸附点 · 点一个环，再点另一个环吸附 · 松开 Alt 退出")
    }

    private func 退出拼接() {
        guard 拼接中 else { return }
        拼接中 = false
        拼接候选 = []
        拼接源 = nil
        store.note("拼接：退出")
    }

    private func 刷新拼接候选() {
        guard 拼接中 else { 拼接候选 = []; return }
        拼接候选 = 计算拼接候选(尺寸: 视口尺寸)
    }

    /// 候选点只算一次：存世界坐标 + 屏幕上大概多大，不做任何屏幕投影。
    /// 屏幕位置由环层按当前机位投影 —— 所以平移 / 缩放 / 转视角时环都咬在模型上。
    private func 计算拼接候选(尺寸 size: CGSize) -> [拼接锚点] {
        guard size.width > 1, size.height > 1 else { return [] }
        let 机位 = 视口场景.相机快照()
        var 结果: [拼接锚点] = []
        结果.reserveCapacity(min(scene.objects.count * 3, 900))

        for 物体 in scene.objects where 物体.isVisible {
            // 真实包围盒：角必须长在模型外壳上，吸完才严丝合缝
            let 盒 = 视口场景.包围盒(of: 物体)
            let 每像素 = 机位.每像素世界长度(at: 盒.中心, 视图尺寸: size)
            guard 每像素 > 0.000001 else { continue }
            let 最大半边 = max(盒.半边.x, max(盒.半边.y, 盒.半边.z))
            let 物体像素 = CGFloat(最大半边 / 每像素)
            // 拉远到只剩几个像素：看不见就别出环
            guard 物体像素 >= 2.5 else { continue }

            结果.append(拼接锚点(
                点: 拼接点(物体: 物体.id, 角标: -1, 世界点: 盒.中心),
                物体像素: 物体像素
            ))

            // 直角顶点：物体在屏幕上太小就只留中心环，不然满屏碎环
            guard 物体像素 >= 16 else { continue }
            for 序号 in 0..<8 {
                let 符号 = SIMD3<Float>(
                    序号 & 1 == 0 ? -1 : 1,
                    序号 & 2 == 0 ? -1 : 1,
                    序号 & 4 == 0 ? -1 : 1
                )
                let 世界 = 盒.中心 + 符号 * 盒.半边
                结果.append(拼接锚点(
                    点: 拼接点(物体: 物体.id, 角标: 序号, 世界点: 世界),
                    物体像素: 物体像素
                ))
            }
        }

        // 点太多就只留屏幕上最大的那些物体的点：数量封顶，绘制和命中都还是常数级
        let 上限 = 900
        if 结果.count > 上限 {
            let 像素表 = Dictionary<UUID, CGFloat>(
                结果.map { ($0.点.物体, $0.物体像素) },
                uniquingKeysWith: { 甲, _ in 甲 }
            )
            let 大物体 = 像素表
                .sorted { $0.value > $1.value }
                .prefix(上限 / 9)
                .map(\.key)
            let 保留 = Set(大物体)
            结果 = 结果.filter { 保留.contains($0.点.物体) }
        }
        return 结果
    }

    /// 点到哪个环（放 6px 容差，小环也点得中）。
    /// 用和环层同一个 相机 快照投影 —— 环画在哪儿就能点到哪儿。
    private func 命中环(_ point: CGPoint) -> 拼接点? {
        let size = 视口尺寸
        guard size.width > 1, size.height > 1, !拼接候选.isEmpty else { return nil }
        var 最佳: 拼接点?
        var 最近 = CGFloat.greatestFiniteMagnitude
        for 项 in 拼接候选 {
            guard let 中心 = 相机.投影(项.点.世界点, 视图尺寸: size) else { continue }
            let 半径: CGFloat = 项.点.是中心 ? 拼接环层.中心半径 : 拼接环层.顶点半径
            let 距离 = hypot(point.x - 中心.x, point.y - 中心.y)
            guard 距离 <= 半径 + 6 else { continue }
            if 距离 < 最近 {
                最近 = 距离
                最佳 = 项.点
            }
        }
        return 最佳
    }

    /// 拼接模式下的左键：点中环就是选点，点空放行给视口（还能照常转视角）
    private func 拼接点选(_ point: CGPoint, _ size: CGSize) -> Bool {
        guard !点中控件(point) else { return false }
        guard let 点 = 命中环(point) else { return false }
        if let 源 = 拼接源 {
            if 源 == 点 {
                拼接源 = nil
                store.note("拼接：起点放下了")
                return true
            }
            吸附(从: 源, 到: 点)
            return true
        }
        拼接源 = 点
        store.note("拼接：起点 = \(物体名(点.物体)) · \(点.名称) · 再点一个环，把这个点吸过去")
        return true
    }

    /// 点对点吸附：起点那个对象整体平移，让起点落在目标点上
    private func 吸附(从 源: 拼接点, 到 目标: 拼接点) {
        guard 源.物体 != 目标.物体 else {
            拼接源 = nil
            store.note("拼接：同一个物体上的两个点不能互相吸附")
            return
        }
        let 位移 = 目标.世界点 - 源.世界点
        guard simd_length(位移) > 0.00001 else {
            拼接源 = nil
            store.note("拼接：两点已经重合，没有动")
            return
        }
        // 起点那个物体在选中集合里就整组一起挪（和数值变换的多选平移一致），否则只挪它自己
        var 一起动: Set<UUID> = [源.物体]
        if scene.选中集合.contains(源.物体), scene.选中集合.count > 1 {
            一起动 = scene.选中集合
        }
        scene.updateObjects { list in
            for index in list.indices where 一起动.contains(list[index].id) {
                list[index].position = Vec3(
                    list[index].position.x + Double(位移.x),
                    list[index].position.y + Double(位移.y),
                    list[index].position.z + Double(位移.z)
                )
            }
        }
        刷新手柄中心()
        拼接源 = nil
        // 环跟着点走：只把「被挪动物体」的候选点整体平移同一个位移，
        // 不重扫场景、不查 visualBounds（同一帧里 entity 还没同步，查了反而是旧值）
        平移候选(一起动, 位移: 位移)
        store.note("拼接：\(物体名(源.物体)) 的\(源.名称) 吸附到 \(物体名(目标.物体)) 的\(目标.名称)")
    }

    /// 候选点整体平移：只动这几个物体的点，条数、身份、筛选结果全不变。
    /// 环跟着模型走的同时保持「不新增、不重扫」。
    private func 平移候选(_ 物体: Set<UUID>, 位移: SIMD3<Float>) {
        guard !物体.isEmpty, !拼接候选.isEmpty else { return }
        for 序 in 拼接候选.indices where 物体.contains(拼接候选[序].点.物体) {
            拼接候选[序].点.世界点 += 位移
        }
    }

    private func 物体名(_ id: UUID) -> String {
        scene.objects.first(where: { $0.id == id })?.name ?? "物体"
    }

    /// 收掉数值会话。回滚 = 按会话开始时的快照把对象摆回去（esc 用）
    private func 结束数值变换(回滚: Bool) {
        defer {
            数值会话 = nil
            数值基准 = []
            抓取起点 = nil
            抓取位移 = .zero
            抓取角度 = 0
            抓取倍率 = 1
            抓取读数 = ""
            刷新手柄中心()
        }
        guard 回滚, !数值基准.isEmpty else { return }
        let 基准 = Dictionary(数值基准.map { ($0.id, $0) }, uniquingKeysWith: { 先, _ in 先 })
        scene.updateObjects { list in
            for index in list.indices {
                guard let 起 = 基准[list[index].id] else { continue }
                list[index].position = 起.位置
                list[index].rotation = 起.旋转
                list[index].scale = 起.缩放
            }
        }
    }

    /// 把会话里的合计值写进场景。
    /// 每一帧都从快照重算 —— 改数字、退格、换轴都是「改主意」，而不是在原值上叠加
    private func 应用数值预览(_ 会话: 数值变换会话) {
        let 合计 = 会话.各轴合计
        guard !数值基准.isEmpty else { return }
        // 鼠标已经接管过就每次都按快照重算：往回拖到起点要把对象摆回原位，不能只进不退
        guard 会话有动静(会话) || 抓取起点 != nil else { return }
        let 基准 = Dictionary(数值基准.map { ($0.id, $0) }, uniquingKeysWith: { 先, _ in 先 })
        let 旋转 = 手柄空间旋转
        let 多选 = 数值基准.count > 1

        switch 会话.模式 {
        case .移动:
            // 各轴的量先合成一个世界向量：局部轴已经把物体自己的朝向算进去了
            var 位移 = SIMD3<Float>.zero
            if 合计.isEmpty {
                // 没敲数字就一直跟着鼠标（长按 W = Blender 的 G）
                位移 = 抓取移动向量(会话)
            } else {
                for (轴, 值) in 合计 { 位移 += 该轴世界方向(轴, 旋转: 旋转) * Float(值) }
            }
            scene.updateObjects { list in
                for index in list.indices {
                    guard let 起 = 基准[list[index].id] else { continue }
                    list[index].position = Vec3(
                        起.位置.x + Double(位移.x),
                        起.位置.y + Double(位移.y),
                        起.位置.z + Double(位移.z)
                    )
                }
            }

        case .旋转:
            // 键盘的角度按轴拆；鼠标给的只有一个整体角度：锁了轴就绕那根轴，没锁就绕视线
            var 轴角度 = 合计
            if 轴角度.isEmpty, 抓取角度 != 0, let 轴 = 会话.轴 { 轴角度[轴] = 抓取角度 }
            var 转法: [(轴: SIMD3<Float>, 角度: Double)] = []
            // 多轴就按 X → Y → Z 顺序叠，跟逐轴拖手柄转出来的一样
            for 轴 in 手柄轴.allCases {
                guard let 角度 = 轴角度[轴], 角度 != 0 else { continue }
                转法.append((该轴世界方向(轴, 旋转: 旋转), 角度))
            }
            if 轴角度.isEmpty, 抓取角度 != 0 { 转法.append((相机.前向, 抓取角度)) }
            scene.updateObjects { list in
                for index in list.indices {
                    guard let 起 = 基准[list[index].id] else { continue }
                    var 朝向 = 起.旋转
                    var 位置 = 起.位置
                    for 步骤 in 转法 {
                        if 多选 {
                            // 多选绕枢轴刚性转：位置和朝向一起动
                            let 相对 = SIMD3<Float>(
                                Float(位置.x - 会话.枢轴.x),
                                Float(位置.y - 会话.枢轴.y),
                                Float(位置.z - 会话.枢轴.z)
                            )
                            let 转后 = simd_quatf(angle: Float(步骤.角度 * .pi / 180), axis: 步骤.轴).act(相对)
                            位置 = Vec3(
                                会话.枢轴.x + Double(转后.x),
                                会话.枢轴.y + Double(转后.y),
                                会话.枢轴.z + Double(转后.z)
                            )
                        }
                        朝向 = 手柄旋转.绕轴(起始: 朝向, 世界轴: 步骤.轴, 角度: 步骤.角度)
                    }
                    list[index].position = 位置
                    list[index].rotation = 朝向
                }
            }

        case .缩放:
            var 倍率 = SIMD3<Double>(1, 1, 1)
            if 合计.isEmpty, 抓取倍率 != 1 {
                // 鼠标拖出来的倍率：锁了轴只缩那根，没锁就是等比
                if let 轴 = 会话.轴 {
                    倍率[轴.分量下标] = 抓取倍率
                } else {
                    倍率 = SIMD3<Double>(repeating: 抓取倍率)
                }
            } else {
                for (轴, 值) in 合计 { 倍率[轴.分量下标] *= 值 }
            }
            scene.updateObjects { list in
                for index in list.indices {
                    guard let 起 = 基准[list[index].id] else { continue }
                    var 位置 = 起.位置
                    if 多选 {
                        // 沿被缩放的轴绕枢轴推开，和拖手柄那套算法保持一致
                        for 轴 in 手柄轴.allCases {
                            let 下标 = 轴.分量下标
                            let 比例 = 倍率[下标]
                            guard 比例 != 1 else { continue }
                            位置[下标] = 会话.枢轴[下标] + (位置[下标] - 会话.枢轴[下标]) * 比例
                        }
                    }
                    list[index].position = 位置
                    list[index].scale = Vec3(
                        max(起.缩放.x * 倍率[0], 0.01),
                        max(起.缩放.y * 倍率[1], 0.01),
                        max(起.缩放.z * 倍率[2], 0.01)
                    )
                }
            }
        }
    }

    /// 数值变换用的世界方向：全局轴就是单位轴；局部轴要跟着物体自身旋转扭一下
    private func 该轴世界方向(_ 轴: 手柄轴, 旋转 q: simd_quatf) -> SIMD3<Float> {
        let 单位 = 轴.世界方向
        let 方向 = 手柄空间 == .全局 ? 单位 : q.act(单位)
        let 长 = simd_length(方向)
        return 长 > 0.0001 ? 方向 / 长 : 单位
    }

    // MARK: 对象坐标轴拖动

    /// 手柄当前使用的空间：全局 = 单位四元数（世界轴），局部 = 选中物体自身旋转
    private var 手柄空间旋转: simd_quatf {
        // 多选时各物体自身轴各不相同，没有共同的「局部轴」，
        // 一律按全局轴摆放与旋转，否则整体转动会拧成一团
        guard 手柄空间 == .局部,
              scene.选中集合.count <= 1,
              let id = scene.selectedObjectID,
              let object = scene.objects.first(where: { $0.id == id })
        else { return 单位旋转 }
        return 手柄旋转.四元数(object.rotation)
    }

    private var 单位旋转: simd_quatf { simd_quatf(angle: 0, axis: [0, 1, 0]) }

    /// 手柄枢轴：单选 = 物体自身世界位置（与原行为一致），
    /// 多选 = 所有选中物体包围球并成 AABB 后的中心，也就是「它们中间」
    private func 刷新手柄中心() {
        // 选中关节：手柄摆在那一节骨上 —— 和选中物体同一个三轴手柄，只是枢轴换成骨点
        if let 选中 = 关节选中,
           let 角色物 = scene.objects.first(where: { $0.id == 选中.角色ID }),
           let 角色 = 角色物.角色,
           选中.骨下标 >= 0, 选中.骨下标 < 角色.骨数据.count {
            let 解 = 角色姿态.解算(骨: 角色.骨数据, 姿态: 角色约束求解.姿态(角色))
            if 选中.骨下标 < 解.骨尾.count {
                let 局部 = 解.骨尾[选中.骨下标]
                let 四 = 角色世界矩阵(角色物) * SIMD4<Float>(局部.x, 局部.y, 局部.z, 1)
                手柄中心 = SIMD3<Float>(四.x, 四.y, 四.z)
                return
            }
        }
        let 目标 = scene.选中物体们
        guard !目标.isEmpty else {
            手柄中心 = nil
            return
        }
        if 目标.count == 1 {
            // 角色本体：手柄摆到脚下圆盘同心处。移动/旋转/缩放改的是容器，
            // 视觉锚点也落在容器上 —— 中心球不会压在人物身上挡关节球
            if 目标[0].角色 != nil, let 落脚 = 容器落脚(目标[0]) {
                手柄中心 = 落脚.中心
                return
            }
            手柄中心 = 视口场景.世界位置(of: 目标[0].id)
            return
        }
        手柄中心 = 整体中心(目标)
    }

    /// 多选枢轴：各物体世界包围球并成 AABB 取中心。
    /// 不直接平均位置——大小悬殊时会被小物体把枢轴拖偏
    private func 整体中心(_ 目标: [SceneObject]) -> SIMD3<Float>? {
        var 下界 = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var 上界 = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var 有结果 = false
        // 只统计可见物体：全被藏起来时枢轴失效，手柄跟着消失（与单选一致）
        for object in 目标 where object.isVisible {
            guard let 球 = 视口场景.包围球(of: object.id) else { continue }
            let 半径 = SIMD3<Float>(repeating: 球.半径)
            下界 = simd_min(下界, 球.中心 - 半径)
            上界 = simd_max(上界, 球.中心 + 半径)
            有结果 = true
        }
        guard 有结果 else { return nil }
        return (下界 + 上界) * 0.5
    }

    // MARK: 显隐 / 聚焦快捷键

    /// H：隐藏选中（多选时整批隐藏）
    private func 隐藏选中() {
        let 目标 = scene.选中物体们
        guard !目标.isEmpty else {
            store.note("先选中一个物体再按 H")
            return
        }
        let 藏掉 = scene.隐藏选中()
        guard !藏掉.isEmpty else {
            store.note(目标.count > 1
                       ? "选中的 \(目标.count) 个物体都已经隐藏"
                       : "\(目标[0].name) 已经是隐藏状态")
            return
        }
        刷新手柄中心()
        store.note(藏掉.count > 1 ? "隐藏 \(藏掉.count) 个物体" : "隐藏：\(藏掉[0].name)")
    }

    /// Alt+H：取消所有隐藏
    private func 显示全部() {
        let 有还原 = scene.全部取消隐藏()
        刷新手柄中心()
        store.note(有还原 ? "取消所有隐藏" : "没有被隐藏的物体")
    }

    /// 长按 F：独立显示——只留选中物体（多选则是这几个）
    private func 独立显示选中() {
        guard !scene.选中集合.isEmpty else {
            store.note("先选中一个物体再长按 F")
            return
        }
        guard scene.独立显示选中() else { return }
        刷新手柄中心()
        let 数量 = scene.选中集合.count
        store.note(数量 > 1
                   ? "独立显示 \(数量) 个物体"
                   : "独立显示：\(scene.selectedObject?.name ?? "选中物体")")
    }

    /// Alt+F：取消独立显示，回到进入前的显隐状态
    private func 取消独立显示() {
        guard scene.取消独立显示() else {
            store.note("当前没有处于独立显示")
            return
        }
        刷新手柄中心()
        store.note("取消独立显示")
    }

    /// F：聚焦选中——轨道目标点移到物体中心，并按包围球重新算距离。
    /// 多选时把各物体的包围球合成一个（中心取均值，半径取最远点），一次框住全部。
    private func 聚焦选中() {
        let 目标 = scene.选中物体们
        guard !目标.isEmpty else {
            store.note("先选中一个物体再按 F")
            return
        }
        let 球们 = 目标.compactMap { 视口场景.包围球(of: $0.id) }
        guard let 合并 = 合并包围球(球们) else {
            store.note("取不到 \(目标[0].name) 的包围盒，无法聚焦")
            return
        }
        应用聚焦(合并)
        store.note(目标.count > 1 ? "聚焦 \(目标.count) 个物体" : "聚焦：\(目标[0].name)")
    }

    /// 鼠标后侧键：先显示全部（退出独立显示、把藏起来的都放出来），再把镜头框住整个场景。
    /// 大场景量包围球走 粗略包围球，一次 O(n) 纯算术，不逐个遍历实体子树。
    // MARK: - 添加物体面板（按钮贴按钮，⇧A 贴鼠标）

    /// 面板宽高：定位要用来收边，所以是常量而不是量出来的
    private static let 添加面板宽: CGFloat = 232
    private static let 添加面板列数 = 5
    private static let 添加格子宽: CGFloat = 38
    private static let 添加格子高: CGFloat = 46
    private static let 添加格间距: CGFloat = 4

    private static var 添加面板列们: [GridItem] {
        Array(repeating: GridItem(.fixed(添加格子宽), spacing: 添加格间距), count: 添加面板列数)
    }

    /// 面板高度跟着"分类数 × 行数"算出来：网格条目一多就不能再写死一个常量
    private static func 添加面板高() -> CGFloat {
        var 高: CGFloat = 20        // 上下内边距
        var 组数 = 0
        for 分类 in 初始项目.分类们 {
            let 数 = 初始项目.内容预设们.filter { $0.分类 == 分类 }.count
            guard 数 > 0 else { continue }
            let 行数 = (数 + 添加面板列数 - 1) / 添加面板列数
            高 += 12 + 5 + CGFloat(行数) * 添加格子高 + CGFloat(行数 - 1) * 添加格间距
            组数 += 1
        }
        if 组数 > 1 { 高 += CGFloat(组数 - 1) * 10 }
        return 高
    }

    /// 出现位置：点按钮就跟按钮走，⇧A 就跟鼠标走；两种情况都不许出视口
    private func 计算添加面板原点(锚在按钮: Bool) -> CGPoint {
        let 基准: CGPoint
        if 锚在按钮, 添加按钮框 != .zero {
            基准 = CGPoint(x: 添加按钮框.minX, y: 添加按钮框.maxY + 6)
        } else {
            基准 = 鼠标位置.点
        }
        let 面板高 = Self.添加面板高()
        let 视口宽 = 视口尺寸.width > 0 ? 视口尺寸.width : (添加按钮框.maxX + Self.添加面板宽)
        let 视口高 = 视口尺寸.height > 0 ? 视口尺寸.height : (添加按钮框.maxY + 面板高)
        let 右界 = max(8, 视口宽 - Self.添加面板宽 - 8)
        let 下界 = max(8, 视口高 - min(面板高, 视口高 - 16) - 8)
        return CGPoint(x: min(max(基准.x, 8), 右界), y: min(max(基准.y, 8), 下界))
    }

    /// ⇧A：同一张面板，出现在鼠标所在处；再按一次收起
    private func 在鼠标处打开添加面板() {
        if 显示添加面板 {
            显示添加面板 = false
            return
        }
        添加面板原点 = 计算添加面板原点(锚在按钮: false)
        显示添加面板 = true
    }

    /// 点一项才当场程序生成几何（与出厂三件套同一套生成器）并入几何池
    private func 添加预设(_ 预设: 内容预设) {
        let 物体 = 初始项目.造物体(预设, 材质们: store.materials, 已有: scene.objects)
        scene.addObject(物体)
        scene.note("已添加 \(物体.name)")
        显示添加面板 = false
    }

    /// 点一项特效预设：造一个发射器对象进场景（跟添加物体同一套：可多开、可选中、可打关键帧）。
    /// 视口里的真表示由 MTK 层按 `物体.特效` 现算；这颗 torus 只是还没做粒子渲染前的占位。
    private func 添加特效(_ 预设: 特效预设) {
        var 物体 = 特效库.造物体(预设, 已有: scene.objects)
        // 选中了实体（几何对象）就把它的**形状收成容器里的第一个发射源**。
        // 注意不能走 `发射体对象ID`：那条路是"火从我身上冒"，容器留在原地当摆设，
        // 看到的就是「火不在容器所在的地方」。收成源 = 火从容器处、按这个形状冒。
        var 收纳名: String?
        if let 宿主 = scene.selectedObject, 宿主.特效 == nil, 宿主.角色 == nil,
           var 特效 = 物体.特效 {
            let 源 = 特效发射源(
                名称: 宿主.name,
                形状: 宿主.导入网格ID == nil ? 宿主.mesh : .cube,
                导入网格ID: 宿主.导入网格ID
            )
            特效.发射源们 = [源] + (特效.发射源们 ?? [])
            特效.发射体对象ID = nil
            物体.特效 = 特效
            收纳名 = 宿主.name
        }
        scene.addObject(物体)
        if let 名 = 收纳名 {
            scene.note("已添加特效 \(物体.name)（容器里已收纳 \(名) 的形状）")
        } else {
            scene.note("已添加特效 \(物体.name)")
        }
    }

    /// 全局物理档位：菜单里以勾选呈现，只有"勾上"才有动作（再点一次不取消，避免误清空整套力）
    private func 物理档勾选(_ 预设: 物理预设) -> Binding<Bool> {
        Binding(
            get: { store.物理域 == 预设.域 },
            set: { 新 in
                guard 新 else { return }
                store.物理域 = 预设.域
                scene.note("物理已切到 \(预设.名称)")
            }
        )
    }

    private var 物理启用勾选: Binding<Bool> {
        Binding(
            get: { store.物理域.启用 },
            set: { 新 in
                store.物理域.启用 = 新
                scene.note(新 ? "物理已启用" : "物理已关闭（只留初速）")
            }
        )
    }

    private var 添加面板遮罩: some View {
        ZStack(alignment: .topLeading) {
            // 点面板以外的地方就收起，顺手也不让这一次点击落到视口里去选物体
            Color.black.opacity(0.001)
                .contentShape(Rectangle())
                .onTapGesture { 显示添加面板 = false }
            添加物体面板
                .offset(x: 添加面板原点.x, y: 添加面板原点.y)
        }
    }

    private var 添加物体面板: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(初始项目.分类们, id: \.self) { 分类 in
                    let 条目 = 初始项目.内容预设们.filter { $0.分类 == 分类 }
                    if !条目.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(分类)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                            LazyVGrid(columns: Self.添加面板列们, alignment: .leading,
                                      spacing: Self.添加格间距) {
                                ForEach(条目) { 预设 in
                                    添加格子(预设)
                                }
                            }
                        }
                    }
                }
            }
            .padding(10)
            .frame(width: Self.添加面板宽, alignment: .leading)
        }
        .frame(width: Self.添加面板宽,
               height: min(Self.添加面板高(), max(140, 视口尺寸.height - 16)),
               alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.97))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(Theme.配色.描边, lineWidth: 0.8)
        )
        .shadow(color: .black.opacity(0.28), radius: 12, y: 5)
    }

    /// 一个模型格子：上面是形状线稿（立方体就是立方体），下面才是名字
    private func 添加格子(_ 预设: 内容预设) -> some View {
        Button {
            添加预设(预设)
        } label: {
            VStack(spacing: 3) {
                模型缩略图(id: 预设.id)
                    .frame(width: 26, height: 26)
                Text(预设.名称)
                    .font(.system(size: 8.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(width: 38, height: 46)
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help("添加 \(预设.名称)")
    }

    private func 显示并聚焦全部() {
        let 藏着的 = scene.objects.contains { !$0.isVisible }
        if 藏着的 {
            _ = scene.全部取消隐藏()
            刷新手柄中心()
        }
        let 目标 = scene.objects.filter(\.isVisible)
        guard !目标.isEmpty else {
            store.note("场景里没有可见物体，没法聚焦")
            return
        }
        // 刚被放出来的物体要等 RealityView 接回场景，读到的位置才是新的
        Task { @MainActor in
            if 藏着的 { try? await Task.sleep(nanoseconds: 60_000_000) }
            let 球们 = 目标.map { 视口场景.粗略包围球(of: $0) }
            guard let 合并 = 合并包围球(球们) else { return }
            应用聚焦(合并)
            store.note(
                藏着的
                ? "显示并聚焦全部：\(目标.count) 个物体"
                : "聚焦全部：\(目标.count) 个物体"
            )
        }
    }

    /// 多个包围球合成一个：中心取均值，半径取「离均值最远那个球的外缘」。
    /// 多选聚焦与全场景聚焦共用这一份，两处口径不打架。
    private func 合并包围球(
        _ 球们: [(中心: SIMD3<Float>, 半径: Float)]
    ) -> (中心: SIMD3<Float>, 半径: Float)? {
        guard let 首 = 球们.first else { return nil }
        guard 球们.count > 1 else { return 首 }
        let 均 = 球们.reduce(SIMD3<Float>.zero) { $0 + $1.中心 } / Float(球们.count)
        let 最远 = 球们.reduce(Float(0)) { max($0, simd_length($1.中心 - 均) + $1.半径) }
        // 退化情况（物体点全重合）退回第一个球，别把镜头推到无穷远
        guard 最远.isFinite, 最远 > 0.0001 else { return 首 }
        return (均, 最远)
    }

    private func 应用聚焦(_ 合并: (中心: SIMD3<Float>, 半径: Float)) {
        视口场景.聚焦(on: 合并.中心, 半径: 合并.半径) { snapshot in
            相机 = snapshot
            刷新手柄中心()
        }
    }

    /// 消费一条跨域对焦请求（全局搜索选中物体后自动对焦，等同用户按一次 F）。
    /// 选中态是刚写进布局域的，等一拍让 RealityView sync 完，包围球才是最新那份。
    private func 消费视口聚焦请求() {
        guard let 目标 = store.取视口聚焦物体() else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 60_000_000)
            guard scene.选中集合.contains(目标) || scene.selectedObjectID == 目标 else { return }
            聚焦选中()
        }
    }

    /// 点是否落在浮动控件上（右上角轴向控件、顶栏、底栏）
    private func 点中控件(_ point: CGPoint) -> Bool {
        if 轴向控件框.contains(point) { return true }
        return 控件框.contains { $0.contains(point) }
    }

    // MARK: 关节球（摆姿势）

    /// 当前能摆姿势的角色：选中的是角色本身，或者选中的是它的某个部件（往上认一层）。
    private func 可编辑角色() -> SceneObject? {
        for 物 in scene.选中物体们 {
            if 物.角色 != nil { return 物 }
            if let 父ID = 物.父?.对象ID,
               let 主 = scene.objects.first(where: { $0.id == 父ID }),
               主.角色 != nil {
                return 主
            }
        }
        return nil
    }

    /// 物体的 TRS 矩阵，和视口实体那条 position / orientation / scale 同一顺序。
    private func 物体矩阵(_ 物: SceneObject) -> simd_float4x4 {
        // 【唯一所有者】不再自己拼 T·R·S：向变换域要世界矩阵（域内派生 + 域内缓存）。
        // 口径见 数据层/四个 域.swift 变换域.本地矩阵 —— Float 内部计算再扩 Double，
        // 与历史实现位级一致（离线校验 20 万样本 0 反例）。
        变换接线.共享.世界矩阵(of: 物)
    }

    /// 角色物体在世界里的矩阵：旋转 / 缩放沿用数据，平移取实体的真实世界位置。
    /// 关节球、手柄枢轴、骨骼解算统一走它，和渲染同源，不会各算一套。
    private func 角色世界矩阵(_ 物: SceneObject) -> simd_float4x4 {
        var 阵 = 物体矩阵(物)
        let 锚 = 视口场景.世界位置(of: 物.id) ?? SIMD3<Float>(
            Float(物.position.x), Float(物.position.y), Float(物.position.z)
        )
        阵.columns.3 = SIMD4<Float>(锚.x, 锚.y, 锚.z, 1)
        return 阵
    }

    // MARK: 角色容器（脚下圆盘）

    /// 每个角色「根骨头 → 静止姿态全身最低点」的落差（局部空间，世界单位）。
    ///
    /// 这一项就是「圆盘到根下方多少」的答案：**每个角色自己算自己的**，不写死常数，也不用填参数。
    /// 关键是只按**静止姿态**算一次并缓存 —— 若跟着当前姿势的最低点走，抬腿/蹲下/劈叉时圆心会上下乱跳。
    /// 圆盘是落脚点，不是"这一帧身体的最低点"。
    private static var 坐落缓存: [UUID: (骨数: Int, 落差: Float)] = [:]

    private func 坐落落差(_ 物: SceneObject, _ 角色: 角色资产) -> Float {
        if let 命中 = Self.坐落缓存[物.id], 命中.骨数 == 角色.骨数据.count { return 命中.落差 }
        // 空姿态 = rest pose：没摆过姿势的那一身，和当前姿势无关
        let 解 = 角色姿态.解算(骨: 角色.骨数据, 姿态: [:])
        guard !解.骨头.isEmpty else { return 0 }
        var 根y们: [Float] = []
        var 最低 = Float.greatestFiniteMagnitude
        for i in 角色.骨数据.indices where 角色.骨数据[i].有效 {
            guard i < 解.骨头.count, i < 解.骨尾.count else { continue }
            最低 = min(最低, min(解.骨头[i].y, 解.骨尾[i].y))
            if 角色.骨数据[i].父 == nil { 根y们.append(解.骨头[i].y) }
        }
        guard 最低.isFinite else { return 0 }
        // 根骨也认不到（父链全断）就退成第一根骨头，不硬编码名字
        let 根y = 根y们.isEmpty
            ? (解.骨头.first?.y ?? 最低)
            : 根y们.reduce(0, +) / Float(根y们.count)
        let 落差 = max(根y - 最低, 0)
        Self.坐落缓存[物.id] = (角色.骨数据.count, 落差)
        return 落差
    }

    /// 容器的落脚点：水平跟着「拓扑根骨」走，高度 = 根骨当前 y − 这身静止时的落差。
    /// 父为空的那几根就是根骨 —— 纯拓扑，不看名字也不看形状，
    /// 导入什么骨架（哪怕只有一根）都成立；角色跑动、跳跃时圆盘跟着根骨一起走。
    private func 容器落脚(_ 物: SceneObject) -> (中心: SIMD3<Float>, 半径: Float)? {
        guard let 角色 = 物.角色, !角色.骨数据.isEmpty else { return nil }
        let 解 = 角色姿态.解算(骨: 角色.骨数据, 姿态: 角色约束求解.姿态(角色))
        guard !解.骨头.isEmpty else { return nil }
        let 阵 = 角色世界矩阵(物)

        var 根点: [SIMD3<Float>] = []
        var 全部点: [SIMD3<Float>] = []
        全部点.reserveCapacity(角色.骨数据.count * 2)
        for i in 角色.骨数据.indices where 角色.骨数据[i].有效 {
            guard i < 解.骨头.count, i < 解.骨尾.count else { continue }
            全部点.append(解.骨头[i])
            全部点.append(解.骨尾[i])
            if 角色.骨数据[i].父 == nil { 根点.append(解.骨头[i]) }
        }
        guard !全部点.isEmpty else { return nil }

        // 有根用根；万一数据里的父链全断（都认不到根），退成全部骨点的中心，不留空
        let 基准 = 根点.isEmpty ? 全部点 : 根点
        var 根心 = SIMD3<Float>.zero
        for 点 in 基准 { 根心 += 点 }
        根心 /= Float(基准.count)

        var 最远: Float = 0
        for 点 in 全部点 {
            最远 = max(最远, hypot(点.x - 根心.x, 点.z - 根心.z))
        }
        guard 最远.isFinite else { return nil }

        // 高度：不是"当前最低点"，是"根骨下方固定的那一段"，所以姿势怎么变圆心都不跳
        let 落差 = 坐落落差(物, 角色)
        let 四 = 阵 * SIMD4<Float>(根心.x, 根心.y - 落差, 根心.z, 1)
        let 中心 = SIMD3<Float>(四.x, 四.y, 四.z)
        // 阵里带缩放：半径跟着整身放大缩小，否则小角色圆盘比人大
        let 缩放 = simd_length(SIMD3<Float>(阵.columns.0.x, 阵.columns.0.y, 阵.columns.0.z))
        let 半径 = max(最远 * 0.6, 0.15) * max(缩放, 0.001)
        guard 中心.x.isFinite, 中心.y.isFinite, 中心.z.isFinite, 半径.isFinite else { return nil }
        return (中心, 半径)
    }

    /// 圆盘投影到屏幕：水平面采样一圈，连成多边形 —— 俯视是正圆，侧视压成椭圆
    private func 圆盘屏幕(_ 中心: SIMD3<Float>, _ 半径: Float, _ size: CGSize) -> 角色圆盘柄? {
        guard let 屏 = 相机.投影(中心, 视图尺寸: size) else { return nil }
        var 圈: [CGPoint] = []
        圈.reserveCapacity(24)
        for i in 0..<24 {
            let a = Float(i) / 24 * 2 * Float.pi
            let 点 = 中心 + SIMD3<Float>(cos(a) * 半径, 0, sin(a) * 半径)
            guard let 投影 = 相机.投影(点, 视图尺寸: size) else { continue }
            圈.append(投影)
        }
        guard 圈.count >= 8 else { return nil }
        var 最远: CGFloat = 0
        for 点 in 圈 { 最远 = max(最远, hypot(点.x - 屏.x, 点.y - 屏.y)) }
        guard 最远.isFinite, 最远 > 1 else { return nil }
        return 角色圆盘柄(屏幕: 屏, 圈: 圈, 半径: 最远)
    }

    /// 视口里当前该画的那只圆盘：只给选中的角色画（或选中它身上某件时画整身的那只）
    private func 角色圆盘们(_ size: CGSize) -> [角色圆盘柄] {
        guard size.width > 1, size.height > 1, let 角色物 = 可编辑角色() else { return [] }
        guard let 落脚 = 容器落脚(角色物),
              var 盘 = 圆盘屏幕(落脚.中心, 落脚.半径, size) else { return [] }
        盘.角色ID = 角色物.id
        return [盘]
    }

    /// 点圆盘 = 选中这一身（点的是容器，不是里面某根骨）
    private func 圆盘按下(_ point: CGPoint, _ size: CGSize) -> Bool {
        // 不能因为「正抓着某根骨」就把圆盘锁死：两只手本来就会来回换，
        // 点了骨球再想抓整身是很自然的操作，所以这里不看关节选中
        for 角色物 in scene.objects where 角色物.角色 != nil && 角色物.isVisible {
            guard let 落脚 = 容器落脚(角色物),
                  let 盘 = 圆盘屏幕(落脚.中心, 落脚.半径, size) else { continue }
            // 圆盘压扁后屏幕上是个椭圆，用最大半径判就够了，不必做精确椭圆内含
            guard hypot(盘.屏幕.x - point.x, 盘.屏幕.y - point.y) <= max(盘.半径, 10) else { continue }
            if scene.选中集合.contains(角色物.id) {
                // 已经选中这一身、且正卡在某个关节手柄里：点脚下圆盘 = 从摆姿势退回整身变换，
                // 手柄搬回脚底。没有关节选中时这块让给三轴手柄，不抢。
                guard 关节选中 != nil else { return false }
                关节选中 = nil
                store.note("回到整身：拖脚下圆盘移动/旋转/缩放这个角色")
                return true
            }
            scene.选中(角色物.id)
            return true
        }
        return false
    }

    /// 关节球清单：每根骨的终点（= 子关节的位置）投影到屏幕。
    /// 骨点是物体局部坐标，世界位置得先过一遍角色物体的 TRS。
    private func 关节球们(_ size: CGSize) -> [关节球项] {
        guard size.width > 1, size.height > 1,
              let 角色物 = 可编辑角色(),
              let 角色 = 角色物.角色,
              !角色.骨数据.isEmpty else { return [] }

        let 解 = 角色姿态.解算(骨: 角色.骨数据, 姿态: 角色约束求解.姿态(角色))
        let 阵 = 角色世界矩阵(角色物)
        var 输出: [关节球项] = []
        输出.reserveCapacity(角色.骨数据.count)

        for i in 角色.骨数据.indices where 角色.骨数据[i].有效 {
            let 局部 = 解.骨尾[i]
            let 世界4 = 阵 * SIMD4<Float>(局部.x, 局部.y, 局部.z, 1)
            let 世界 = SIMD3<Float>(世界4.x, 世界4.y, 世界4.z)
            guard let 屏 = 相机.投影(世界, 视图尺寸: size) else { continue }
            // 出了视口就不画了（手指几百根，屏幕外的投影全算也是白费）
            guard 屏.x > -24, 屏.y > -24, 屏.x < size.width + 24, 屏.y < size.height + 24 else { continue }
            输出.append(关节球项(
                角色ID: 角色物.id,
                骨下标: i,
                骨名: 角色.骨数据[i].名称,
                世界: 世界,
                屏幕: 屏
            ))
        }
        return 输出
    }

    /// 按下：点在关节球上就选中这一节骨，返回 true。
    /// 只管选，别的一概不做 —— 球就是骨的选择器。
    private func 关节按下(_ point: CGPoint, _ size: CGSize) -> Bool {
        let 候选 = 关节球们(size).compactMap { 球 -> (关节球项, CGFloat)? in
            let 距 = hypot(球.屏幕.x - point.x, 球.屏幕.y - point.y)
            return 距 <= 10 ? (球, 距) : nil
        }
        guard let (球, _) = 候选.min(by: { $0.1 < $1.1 }),
              let 角色物 = scene.objects.first(where: { $0.id == 球.角色ID }),
              let 角色 = 角色物.角色,
              球.骨下标 >= 0, 球.骨下标 < 角色.骨数据.count else { return false }

        let 选中 = 关节选中项(
            角色ID: 球.角色ID,
            骨下标: 球.骨下标,
            骨路径: 角色.骨数据[球.骨下标].路径,
            骨名: 球.骨名
        )
        关节选中 = 选中
        // 抓关节就是抓木偶：整身交给静力学一次算完，提踝自动屈膝，不用给每根骨配 IK
        准备木偶(角色ID: 球.角色ID, 骨们: 角色.骨数据, 骨下标: 球.骨下标)
        // 按住球就等于抓住这个关节：鼠标一动，这节骨就朝鼠标指的方向摆（手抖 6pt 内不算）
        关节拖拽 = 关节对齐拖动(选中: 选中, 起点: point)
        // 换了关节就把手柄挪到新的骨点上（选中物体那套是 onChange 干的，这里手动同步一次）
        刷新手柄中心()
        激活轴 = nil
        球激活 = false
        return true
    }

    // MARK: 约束（Blender 那种算法约束）

    /// 屏幕点到哪颗关节球（10pt 内算命中）
    private func 关节命中(_ point: CGPoint, _ size: CGSize) -> (球: 关节球项, 骨路径: String)? {
        let 候选 = 关节球们(size).compactMap { 球 -> (关节球项, CGFloat)? in
            let 距 = hypot(球.屏幕.x - point.x, 球.屏幕.y - point.y)
            return 距 <= 10 ? (球, 距) : nil
        }
        guard let (球, _) = 候选.min(by: { $0.1 < $1.1 }),
              let 角色物 = scene.objects.first(where: { $0.id == 球.角色ID }),
              let 角色 = 角色物.角色,
              球.骨下标 >= 0, 球.骨下标 < 角色.骨数据.count else { return nil }
        return (球, 角色.骨数据[球.骨下标].路径)
    }

    /// 右键关节球：选中它并弹约束面板
    private func 关节右键(_ point: CGPoint, _ size: CGSize) -> Bool {
        guard let 命中 = 关节命中(point, size),
              let 角色物 = scene.objects.first(where: { $0.id == 命中.球.角色ID }),
              let 角色 = 角色物.角色 else { return false }
        关节选中 = 关节选中项(
            角色ID: 命中.球.角色ID,
            骨下标: 命中.球.骨下标,
            骨路径: 命中.骨路径,
            骨名: 命中.球.骨名
        )
        刷新手柄中心()
        约束骨路径 = 命中.骨路径
        约束骨名 = 命中.球.骨名
        // 默认目标：同链上离它最近的一节（往往就是父骨/子骨），省得每次都去列表里翻
        let 父路径 = 角色.骨数据[命中.球.骨下标].父
            .flatMap { $0 >= 0 && $0 < 角色.骨数据.count ? 角色.骨数据[$0].路径 : nil }
        新约束目标 = 父路径 ?? ""
        新约束型 = .反向动力学
        新约束链长 = 2
        显示约束面板 = true
        return true
    }

    /// 骨路径去掉层级前缀，面板里只显示末段
    private func 骨简称(_ 路径: String) -> String {
        路径.split(separator: "/").last.map(String.init) ?? 路径
    }

    /// 约束表整体写回。约束不写进姿态表，所以改完只要让这一身重建
    private func 写入约束(角色ID: UUID, 约束们: [角色约束]) {
        scene.updateObjects { list in
            for i in list.indices where list[i].id == 角色ID {
                list[i].角色?.约束 = 约束们
            }
        }
        视口场景.标脏姿态(角色ID)
        刷新手柄中心()
    }

    /// 改一条约束（启用开关 / 换目标 / 换链长都走这儿）
    private func 改约束(_ 标识: UUID, _ 改: (inout 角色约束) -> Void) {
        guard let 角色物 = 可编辑角色(), let 角色 = 角色物.角色 else { return }
        var 约束们 = 角色.约束
        guard let i = 约束们.firstIndex(where: { $0.标识 == 标识 }) else { return }
        改(&约束们[i])
        写入约束(角色ID: 角色物.id, 约束们: 约束们)
    }

    private func 启用绑定(_ 约: 角色约束) -> Binding<Bool> {
        Binding(get: { 约.启用 }, set: { 值 in 改约束(约.标识) { $0.启用 = 值 } })
    }

    /// 加一条：挂在这一节骨上，盯住选定的目标骨
    private func 加约束() {
        guard let 角色物 = 可编辑角色(), let 角色 = 角色物.角色,
              let 骨路径 = 约束骨路径, !新约束目标.isEmpty else { return }
        约束骨名 = 角色.骨数据.first(where: { $0.路径 == 骨路径 })?.名称 ?? 骨简称(骨路径)
        var 约束们 = 角色.约束
        约束们.append(角色约束(
            型: 新约束型,
            骨路径: 骨路径,
            目标骨路径: 新约束目标,
            链长: 新约束型 == .对准 ? 1 : 新约束链长
        ))
        写入约束(角色ID: 角色物.id, 约束们: 约束们)
        store.note("约束：\(约束骨名) → \(骨简称(新约束目标))（\(新约束型.标题)，链长 \(新约束型 == .对准 ? 1 : 新约束链长)）")
    }

    private func 删约束(_ 约: 角色约束) {
        guard let 角色物 = 可编辑角色(), let 角色 = 角色物.角色 else { return }
        写入约束(角色ID: 角色物.id, 约束们: 角色.约束.filter { $0.标识 != 约.标识 })
    }

    /// 约束面板：选个目标骨 + 链长，这一节就自动跟着目标走（提膝就是让踝的 IK 去够膝/脚）
    @ViewBuilder
    private var 约束面板: some View {
        let 角色 = 可编辑角色()?.角色
        let 骨们 = 角色?.骨数据 ?? []
        let 已有 = (角色?.约束 ?? []).filter { $0.骨路径 == 约束骨路径 }

        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Text("约束").font(.system(size: 11, weight: .semibold))
                Text(约束骨名).font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
            }

            if 已有.isEmpty {
                Text("这一节还没有约束").font(.system(size: 10)).foregroundStyle(.secondary)
            } else {
                ForEach(已有) { 约 in
                    HStack(spacing: 6) {
                        Toggle("", isOn: 启用绑定(约))
                            .labelsHidden()
                            .controlSize(.mini)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(约.型.标题).font(.system(size: 10))
                            Text("→ \(骨简称(约.目标骨路径))　链长 \(约.生效链长)")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        Button {
                            删约束(约)
                        } label: {
                            Image(systemName: "trash").font(.system(size: 10))
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }

            Divider()

            Picker("", selection: $新约束型) {
                ForEach(角色约束型.allCases, id: \.self) { 型 in
                    Text(型.标题).tag(型)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)

            Text(新约束型.说明).font(.system(size: 9)).foregroundStyle(.secondary)

            Picker("目标骨", selection: $新约束目标) {
                Text("选一根目标骨").tag("")
                ForEach(骨们.filter { $0.有效 && $0.路径 != 约束骨路径 }, id: \.路径) { 骨 in
                    Text(骨简称(骨.路径)).tag(骨.路径)
                }
            }
            .controlSize(.small)

            if 新约束型 == .反向动力学 {
                Picker("链长", selection: $新约束链长) {
                    Text("1 节").tag(1)
                    Text("2 节（带父骨）").tag(2)
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
            }

            HStack {
                Spacer()
                Button("加约束") { 加约束() }
                    .controlSize(.small)
                    .disabled(新约束目标.isEmpty)
            }
        }
        .padding(12)
        .frame(width: 248)
    }

    /// 拖关节球的起点：平面过当前骨尾、正对相机；骨头的 头 与静止方向 取静止数据。
    /// 骨长不变，所以关节会被约束在「以父关节为球心、骨长为半径」的球面上。
    private func 关节对齐拖动(选中: 关节选中项, 起点: CGPoint) -> 关节拖动? {
        guard let 角色物 = scene.objects.first(where: { $0.id == 选中.角色ID }),
              let 角色 = 角色物.角色,
              选中.骨下标 >= 0, 选中.骨下标 < 角色.骨数据.count else { return nil }
        let 骨们 = 角色.骨数据
        let 骨 = 骨们[选中.骨下标]
        let 解 = 角色姿态.解算(骨: 骨们, 姿态: 角色约束求解.姿态(角色))
        guard 选中.骨下标 < 解.骨尾.count, 选中.骨下标 < 解.世界旋转.count else { return nil }

        let 方向 = 骨.尾 - 骨.头
        let 长 = simd_length(方向)
        guard 长 > 0.0001 else { return nil }

        let 阵 = 角色世界矩阵(角色物)
        let 尾 = 解.骨尾[选中.骨下标]
        let 四 = 阵 * SIMD4<Float>(尾.x, 尾.y, 尾.z, 1)
        let 世界尾 = SIMD3<Float>(四.x, 四.y, 四.z)
        let 父世界: simd_quatf
        if let 父 = 骨.父, 父 >= 0, 父 < 解.世界旋转.count {
            父世界 = 解.世界旋转[父]
        } else {
            父世界 = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
        }

        return 关节拖动(
            角色ID: 选中.角色ID,
            骨下标: 选中.骨下标,
            骨路径: 选中.骨路径,
            枢轴: 世界尾,
            起点: 起点,
            几何: nil,
            对齐: 关节对齐(
                平面点: 世界尾,
                平面法线: 相机.前向,
                头: 骨.头,
                静止方向: 方向 / 长
            ),
            骨世界旋转: 解.世界旋转[选中.骨下标],
            父世界旋转: 父世界
        )
    }

    /// 这一节骨按下瞬间的世界旋转与父骨世界旋转（父链已复合），
    /// 拖出来的角度全部相对它累计。
    private func 关节基准(_ 选中: 关节选中项) -> (骨: simd_quatf, 父: simd_quatf)? {
        guard let 角色物 = scene.objects.first(where: { $0.id == 选中.角色ID }),
              角色物.角色 != nil,
              选中.骨下标 >= 0, 选中.骨下标 < 角色物.角色!.骨数据.count else { return nil }
        let 骨们 = 角色物.角色!.骨数据
        let 解 = 角色姿态.解算(骨: 骨们, 姿态: 角色约束求解.姿态(角色物.角色!))
        guard 选中.骨下标 < 解.世界旋转.count else { return nil }
        let 父下标 = 骨们[选中.骨下标].父
        let 父旋 = 父下标.map { $0 >= 0 && $0 < 解.世界旋转.count ? 解.世界旋转[$0] : 单位旋转 } ?? 单位旋转
        return (解.世界旋转[选中.骨下标], 父旋)
    }

    /// 按下：命中手柄就吞掉事件并开始拖动，返回 true
    private func 手柄按下(_ point: CGPoint, _ size: CGSize) -> Bool {
        // 拼接模式：环只画不接收事件，命中在这里判 —— 点中环就吃掉这一下，点空照常转视角
        if 拼接中 { return 拼接点选(point, size) }
        guard !点中控件(point) else { return false }
        // 抓取期间的一次点击就是「就这样了」：落在哪儿都算确认，
        // 顺带把这个按下吞掉，免得又去点选别的物体或者转相机
        if let 会话 = 数值会话 {
            let 读数 = 会话读数(会话)
            let 有动静 = 会话有动静(会话)
            结束数值变换(回滚: false)
            store.note(有动静
                       ? "\(会话.模式.title)：\(读数)"
                       : "没输数值，\(会话.模式.title)没有执行")
            return true
        }
        // 手柄画在枢轴上：单选=物体中心，多选=整体中心，命中几何必须用同一个点
        let 目标 = scene.选中物体们
        // 关节球最高优先级：球就是「抓木偶」。手柄轴/中心球一概不许抢，
        // 否则点落在旋转圈上就退回「绕父骨转这一节」，看着还是整条腿被抬起来
        if 关节球们(size).contains(where: {
            hypot($0.屏幕.x - point.x, $0.屏幕.y - point.y) <= 10
        }) {
            return 关节按下(point, size)
        }
        guard let 中心 = 手柄中心, !目标.isEmpty,
              目标.contains(where: \.isVisible) else { return 圆盘按下(point, size) || 关节按下(point, size) }
        let 主 = 目标.first(where: \.isVisible) ?? 目标[0]

        let 几何 = 相机.手柄(中心: 中心, 视图尺寸: size, 半径像素: 78, 旋转: 手柄空间旋转)

        // 中心球先判：它正压在三轴交汇处，和轴起点重叠，先给球才点得中
        // 选中关节时不给中心球：它正好压在关节球上，点了就变成拖整个角色
        let 球 = (手柄模式 == .旋转 || 关节选中 != nil) ? nil : 相机.中心球(中心: 中心, 视图尺寸: size)
        let 按球 = 球.map { $0.命中(point) } ?? false
        let 按轴 = 按球 ? nil : 视口相机.命中(几何, 模式: 手柄模式, 点: point)
        // 手柄没点中，再看是不是点在关节球或脚下圆盘上：手柄优先，免得旁边的球把点击吃掉
        guard 按球 || 按轴 != nil else { return 圆盘按下(point, size) || 关节按下(point, size) }

        激活轴 = 按轴?.轴
        球激活 = 按球

        // 选中关节时这套手柄就是这一节骨的手柄：拖它转骨，不碰物体 TRS。
        // 角度、四元数合成、姿态存储全走公共那套，这里只记按下瞬间的基准。
        if let 选中 = 关节选中, let 轴 = 按轴, let 基准 = 关节基准(选中) {
            拖拽 = nil
            关节拖拽 = 关节拖动(
                角色ID: 选中.角色ID,
                骨下标: 选中.骨下标,
                骨路径: 选中.骨路径,
                枢轴: 中心,
                起点: point,
                几何: 轴,
                对齐: nil,
                骨世界旋转: 基准.骨,
                父世界旋转: 基准.父
            )
            return true
        }
        // 成员快照：整批一起变换时全部基于按下瞬间的值累计，互不牵连
        拖拽 = 手柄拖动(
            物体ID: 主.id,
            模式: 手柄模式,
            轴: 按轴?.轴,
            几何: 按轴,
            球: 按球 ? 球 : nil,
            起点: point,
            起始位置: 主.position,
            起始旋转: 主.rotation,
            起始缩放: 主.scale,
            枢轴: Vec3(Double(中心.x), Double(中心.y), Double(中心.z)),
            成员们: 目标.map {
                手柄成员(id: $0.id, 位置: $0.position, 旋转: $0.rotation, 缩放: $0.scale)
            }
        )
        return true
    }

    /// 三轴手柄的旋转角度（度）：屏幕绕枢轴扫过的角度，按轴朝向观察者与否取符号。
    /// 物体旋转和关节旋转共用这一份，不各写一套。
    private func 手柄角度(起点: CGPoint, 当前: CGPoint, 几何: 手柄轴几何) -> Double {
        let 中心 = 几何.中心
        let a0 = atan2(起点.y - 中心.y, 起点.x - 中心.x)
        let a1 = atan2(当前.y - 中心.y, 当前.x - 中心.x)
        var 增量 = a1 - a0
        if 增量 > .pi { 增量 -= .pi * 2 }
        if 增量 < -.pi { 增量 += .pi * 2 }
        // 屏幕 y 向下：atan2 增量 > 0 即视觉顺时针。
        // 几何.朝向相机 存的是 dot(轴, 前向)，而「前向」是相机指向场景的视线方向，
        // 所以 > 0 实际表示该轴背离观察者（看到的是轴的负端）：
        //  - 背离观察者：从负端看正向旋转是顺时针 → 与屏幕增量同号
        //  - 朝向观察者：从正端看正向旋转是逆时针 → 取反
        let 符号: Double = 几何.朝向相机 >= 0 ? 1 : -1
        return Double(增量) * 180 / .pi * 符号
    }

    /// 关节拖动：把扫过的角度写成「这一节骨在父骨空间的局部旋转」，
    /// 骨点位置由 角色姿态.解算 统一复合 —— 球和皮永远同一份坐标。
    private func 关节拖动中(_ point: CGPoint) {
        guard let drag = 关节拖拽 else { return }

        // 拖关节球：把这一节骨的 头→尾 对准鼠标，骨长不变
        if let 对齐 = drag.对齐 {
            关节对齐中(point, drag: drag, 对齐: 对齐)
            return
        }

        // 拖三轴：绕那根轴转这一节骨
        guard let 几何 = drag.几何,
              let 角色物 = scene.objects.first(where: { $0.id == drag.角色ID }),
              角色物.角色 != nil else { return }

        let 角度 = 手柄角度(起点: drag.起点, 当前: point, 几何: 几何)
        guard abs(角度 - drag.角度) > 0.001 else { return }
        var 新 = drag
        新.角度 = 角度
        关节拖拽 = 新

        let 轴长 = simd_length(几何.世界方向)
        let 世界单位轴 = 轴长 > 0.0001 ? 几何.世界方向 / 轴长 : SIMD3<Float>(0, 1, 0)
        // 手柄轴是世界方向，骨的姿势记在角色物体局部空间 → 先转进来
        let 角色旋 = SceneBuilder.eulerQuaternion(
            x: 角色物.rotation.x, y: 角色物.rotation.y, z: 角色物.rotation.z
        )
        let 局部轴 = 角色旋.inverse.act(世界单位轴)
        // 和物体旋转同一套：绕该轴左乘合成，子骨跟着父链自动走
        let 世界旋转 = simd_quatf(angle: Float(角度 * .pi / 180), axis: 局部轴) * drag.骨世界旋转
        写入骨旋转(角色ID: drag.角色ID, 骨路径: drag.骨路径, 局部旋转: drag.父世界旋转.inverse * 世界旋转)
    }

    /// 拖关节球 = 拖木偶：鼠标投到「过骨尾、正对相机」的平面拿到目标点，
    /// 整身做一次静力学求解 —— 抓踝必然屈膝、抓手必然屈肘，全程没有任何骨名参与。
    private func 关节对齐中(_ point: CGPoint, drag: 关节拖动, 对齐: 关节对齐) {
        guard hypot(point.x - drag.起点.x, point.y - drag.起点.y) > 6 else { return }
        guard let 角色物 = scene.objects.first(where: { $0.id == drag.角色ID }),
              let 角色 = 角色物.角色,
              let 射线 = 相机.射线(屏幕点: point, 视图尺寸: 视口尺寸) else { return }

        let 分母 = simd_dot(射线.direction, 对齐.平面法线)
        guard abs(分母) > 0.0001 else { return }
        let 缩放 = simd_dot(对齐.平面点 - 射线.origin, 对齐.平面法线) / 分母
        guard 缩放 > 0 else { return }
        let 命中 = 射线.origin + 射线.direction * 缩放

        // 目标搬进角色局部空间：骨点都在这个空间里
        let 逆 = simd_inverse(角色世界矩阵(角色物))
        let 四 = 逆 * SIMD4<Float>(命中.x, 命中.y, 命中.z, 1)
        let 局部目标 = SIMD3<Float>(四.x, 四.y, 四.z)

        // 会话没准备好（比如从别处进来的拖动）就现场补一个，别急着退回老办法
        if 木偶会话 == nil || 木偶会话?.角色ID != drag.角色ID {
            准备木偶(角色ID: drag.角色ID, 骨们: 角色.骨数据, 骨下标: drag.骨下标)
        }
        // 木偶没准备好（这根骨没长度之类）才退回「只转这一节」的老办法
        guard let 会话 = 木偶会话, 会话.角色ID == drag.角色ID, 会话.节点 >= 0 else {
            单骨对准(目标: 局部目标, drag: drag, 对齐: 对齐)
            return
        }
        let 新姿态 = 角色木偶.求解(
            骨: 角色.骨数据,
            拓扑: 会话.拓扑,
            姿态: 角色.姿态,
            抓取节点: 会话.节点,
            抓取目标: 局部目标
        )
        写入木偶姿态(角色ID: drag.角色ID, 姿态: 新姿态)
    }

    /// 老办法：只把这节骨转到鼠标方向，父链不动。骨架太怪、木偶用不了时兜底。
    private func 单骨对准(目标: SIMD3<Float>, drag: 关节拖动, 对齐: 关节对齐) {
        var 方向 = 目标 - 对齐.头
        let 长 = simd_length(方向)
        guard 长 > 0.0001 else { return }
        方向 /= 长

        // 目标正好落在静止方向的反向时 from-to 会退化，绕一根垂直轴转 180°
        let 旋转: simd_quatf
        if simd_dot(方向, 对齐.静止方向) < -0.9999 {
            let 备用轴: SIMD3<Float> = abs(对齐.静止方向.x) < 0.9
                ? simd_cross(对齐.静止方向, SIMD3<Float>(1, 0, 0))
                : simd_cross(对齐.静止方向, SIMD3<Float>(0, 1, 0))
            旋转 = simd_quatf(angle: .pi, axis: simd_normalize(备用轴))
        } else {
            旋转 = simd_quatf(from: 对齐.静止方向, to: 方向)
        }
        写入骨旋转(角色ID: drag.角色ID, 骨路径: drag.骨路径, 局部旋转: drag.父世界旋转.inverse * 旋转)
    }

    /// 按下关节球时准备木偶：拓扑能复用就复用，骨数据换了才重建
    private func 准备木偶(角色ID: UUID, 骨们: [角色骨骼], 骨下标: Int) {
        if let 旧 = 木偶会话, 旧.角色ID == 角色ID, 旧.骨数 == 骨们.count,
           let 节点 = 角色木偶.节点(of: 骨下标, 拓扑: 旧.拓扑) {
            var 新 = 旧
            新.骨下标 = 骨下标
            新.节点 = 节点
            木偶会话 = 新
            return
        }
        let 拓扑 = 角色木偶.构建(骨: 骨们)
        guard let 节点 = 角色木偶.节点(of: 骨下标, 拓扑: 拓扑) else {
            木偶会话 = nil
            return
        }
        木偶会话 = 木偶抓取会话(
            角色ID: 角色ID,
            骨下标: 骨下标,
            节点: 节点,
            拓扑: 拓扑,
            骨数: 骨们.count
        )
    }

    /// 木偶算出来的是整身姿态，一次写回，仍然只重建这一身
    private func 写入木偶姿态(角色ID: UUID, 姿态: [String: SIMD4<Float>]) {
        scene.updateObjects { list in
            for i in list.indices where list[i].id == 角色ID {
                list[i].角色?.姿态 = 姿态
            }
        }
        视口场景.标脏姿态(角色ID)
        自检蒙皮(角色ID)
        刷新手柄中心()
    }

    /// 摆姿势前先看这一身到底能不能被蒙皮带动。
    /// 蒙皮失效是**静默**的：骨头照转、网格不动，肉眼只能看出「没反应」，看不出是哪一段断的。
    /// 这里把断点直接翻译成人话提示一次，别让人对着一动不动的模型猜。
    /// 视口是 struct（视图），去重状态放引用盒里，免得每帧重建结构体把上一次的提示丢掉。
    private final class 蒙皮提示盒 { var 上次 = "" }
    private static let 蒙皮提示 = 蒙皮提示盒()

    private func 自检蒙皮(_ 角色ID: UUID) {
        let 结论 = 蒙皮结论(角色ID)
        let 盒 = Self.蒙皮提示
        guard 结论 != 盒.上次 else { return }
        盒.上次 = 结论
        if !结论.isEmpty { store.note(结论) }
    }

    /// 空串 = 链路正常。只读计数与前 64 个顶点，摆姿势期间每帧调用也扛得住。
    private func 蒙皮结论(_ 角色ID: UUID) -> String {
        guard let 主 = scene.objects.first(where: { $0.id == 角色ID }), let 角色 = 主.角色 else { return "" }
        guard !角色.骨数据.isEmpty else { return "这身角色没有骨架数据，蒙不了皮" }
        let 部件们 = scene.objects.filter { $0.父?.对象ID == 角色ID }
        guard !部件们.isEmpty else { return "这身角色没有部件网格，动骨不会带动任何东西" }

        let 骨名集 = Set(角色姿态.骨名表(角色.骨数据).keys)
        var 网格数 = 0
        var 带权网格 = 0
        var 名匹配 = false
        for 部件 in 部件们 {
            guard let 网格ID = 几何接线.共享.取值(键: 部件.id.uuidString)?.导入网格标识 ?? 部件.导入网格ID,
                  let 片们 = 几何接线.共享.取(网格ID) else { continue }
            for 片 in 片们 where !片.顶点.isEmpty {
                网格数 += 1
                guard !片.权重.isEmpty, 片.权重.count == 片.顶点.count else { continue }
                带权网格 += 1
                if !名匹配 {
                    for 一顶点 in 片.权重.prefix(64) where 一顶点.contains(where: { 骨名集.contains($0.骨名) }) {
                        名匹配 = true
                        break
                    }
                }
            }
        }
        if 网格数 == 0 { return "这身角色的网格不在几何库里，视口里没东西可摆" }
        if 带权网格 == 0 { return "这身网格没有蒙皮权重（导入时没读到顶点组），骨头转网格不会动：重新导入一次这个模型" }
        if !名匹配 { return "蒙皮权重的骨名跟骨架一个都对不上（\(带权网格)/\(网格数) 个网格有权重），检查是不是换了骨架没重绑" }
        return ""
    }

    /// 把一节骨的局部旋转写进角色资产，并只让这一身重建
    private func 写入骨旋转(角色ID: UUID, 骨路径: String, 局部旋转: simd_quatf) {
        let 编码 = 角色姿态.值(局部旋转)
        scene.updateObjects { list in
            for i in list.indices where list[i].id == 角色ID {
                list[i].角色?.姿态[骨路径] = 编码
            }
        }
        // 只有这一身需要重摆，别的角色、别的物体一概不动
        视口场景.标脏姿态(角色ID)
        自检蒙皮(角色ID)
        刷新手柄中心()
    }

    private func 手柄拖动中(_ point: CGPoint) {
        if 关节拖拽 != nil {
            关节拖动中(point)
            return
        }
        guard let drag = 拖拽 else { return }
        // 成员表：按 id 取按下瞬间的基准值（多选时一次改一整批）
        let 基准 = Dictionary(drag.成员们.map { ($0.id, $0) }, uniquingKeysWith: { 先, _ in 先 })

        // 中心球：移动走相机平面，缩放走三轴等比，和单轴手柄是两套算法
        if let 球 = drag.球 {
            中心球拖动中(point, drag: drag, 球: 球, 基准: 基准)
            return
        }

        guard let 几何 = drag.几何, let 轴 = drag.轴 else { return }
        let 下标 = 轴.分量下标

        switch drag.模式 {
        case .移动, .缩放:
            let dx = point.x - drag.起点.x
            let dy = point.y - drag.起点.y
            let 屏幕位移 = dx * 几何.屏幕方向.dx + dy * 几何.屏幕方向.dy
            // 轴几乎垂直屏幕时像素长度趋近 0，取保底值避免灵敏度爆表
            let 像素 = max(几何.像素半径, 42)

            if drag.模式 == .移动 {
                // 像素位移 ×（世界半径 / 像素半径）即为该轴上的世界位移
                let 比例 = Double(几何.世界半径) / Double(max(几何.像素半径, 1))
                let 差值 = Double(屏幕位移) * 比例
                // 位移必须沿「该手柄在世界空间里的真实方向」走。
                // 局部轴下手柄方向已被物体旋转扭过，若只改 position 的单个分量，
                // 就变成沿世界 X/Y/Z 直上直下；全局轴恰好与分量同向，才看不出问题
                let 轴长 = simd_length(几何.世界方向)
                let 方向 = 轴长 > 0.0001
                    ? 几何.世界方向 / 轴长
                    : SIMD3<Float>(0, 1, 0)
                let 位移 = 方向 * Float(差值)
                // 同一轴上的平移对所有选中物体完全一致 → 相对位置保持不变
                scene.updateObjects { list in
                    for index in list.indices {
                        guard let 起点 = 基准[list[index].id] else { continue }
                        list[index].position = Vec3(
                            起点.位置.x + Double(位移.x),
                            起点.位置.y + Double(位移.y),
                            起点.位置.z + Double(位移.z)
                        )
                    }
                }
            } else {
                let 倍率 = Double((像素 + 屏幕位移) / 像素)
                let 收口 = min(max(倍率, 0.05), 20)
                let 枢轴 = drag.枢轴[下标]
                scene.updateObjects { list in
                    for index in list.indices {
                        guard let 起点 = 基准[list[index].id] else { continue }
                        // 多选：沿该轴绕枢轴推开，离得越远位移越大，整体像被拉伸；
                        // 单选时枢轴就是物体自己的中心，位移恒为 0，等同原来的纯缩放
                        if drag.多选 {
                            list[index].position[下标] = 枢轴 + (起点.位置[下标] - 枢轴) * 收口
                        }
                        list[index].scale[下标] = max(起点.缩放[下标] * 收口, 0.01)
                    }
                }
            }

        case .旋转:
            let 角度 = 手柄角度(起点: drag.起点, 当前: point, 几何: 几何)
            // 绕哪根世界轴转都已经由几何决定；用四元数左乘合成后转回欧拉角，
            // 这样物体已有其它轴旋转时也不会「转错轴」
            let 世界轴 = 几何.世界方向
            let 轴长 = simd_length(世界轴)
            let 单位轴 = 轴长 > 0.0001 ? 世界轴 / 轴长 : SIMD3<Float>(0, 1, 0)
            let 弧度 = Float(角度 * .pi / 180)
            let q = simd_quatf(angle: 弧度, axis: 单位轴)
            let 枢轴 = drag.枢轴
            scene.updateObjects { list in
                for index in list.indices {
                    guard let 起点 = 基准[list[index].id] else { continue }
                    // 多选：位置绕枢轴一起转 + 自身朝向叠加同一个旋转 → 整体刚性转动
                    if drag.多选 {
                        let 相对 = SIMD3<Float>(
                            Float(起点.位置.x - 枢轴.x),
                            Float(起点.位置.y - 枢轴.y),
                            Float(起点.位置.z - 枢轴.z)
                        )
                        let 转后 = q.act(相对)
                        list[index].position = Vec3(
                            枢轴.x + Double(转后.x),
                            枢轴.y + Double(转后.y),
                            枢轴.z + Double(转后.z)
                        )
                    }
                    list[index].rotation = 手柄旋转.绕轴(起始: 起点.旋转, 世界轴: 世界轴, 角度: 角度)
                }
            }
        }
    }

    /// 中心球拖动：移动 = 相机平面内平移（不贴任何一根轴），缩放 = 三轴等比。
    /// 屏幕位移直接落到相机的右 / 上向，所以视角怎么转都「跟着手走」。
    private func 中心球拖动中(
        _ point: CGPoint,
        drag: 手柄拖动,
        球: 手柄中心球,
        基准: [UUID: 手柄成员]
    ) {
        let dx = Float(point.x - drag.起点.x)
        // 屏幕 y 向下，相机上向要取反
        let dy = Float(point.y - drag.起点.y)
        let 每像素 = 球.每像素世界长度

        switch drag.模式 {
        case .移动:
            let 位移 = (球.右向 * dx + 球.上向 * (-dy)) * 每像素
            scene.updateObjects { list in
                for index in list.indices {
                    guard let 起点 = 基准[list[index].id] else { continue }
                    // 整批同一个位移 → 相对位置不变，就是「整块搬走」
                    list[index].position = Vec3(
                        起点.位置.x + Double(位移.x),
                        起点.位置.y + Double(位移.y),
                        起点.位置.z + Double(位移.z)
                    )
                }
            }

        case .缩放:
            // 竖向拖动控制倍率：往上放大、往下缩小
            let 倍率 = 1 - Double(dy) / 160
            let 收口 = min(max(倍率, 0.05), 20)
            let 枢轴 = drag.枢轴
            scene.updateObjects { list in
                for index in list.indices {
                    guard let 起点 = 基准[list[index].id] else { continue }
                    // 多选：绕枢轴整体推开，三轴同倍率 → 等比不变形
                    if drag.多选 {
                        let 相对 = SIMD3<Float>(
                            Float(起点.位置.x - 枢轴.x),
                            Float(起点.位置.y - 枢轴.y),
                            Float(起点.位置.z - 枢轴.z)
                        ) * Float(收口)
                        list[index].position = Vec3(
                            枢轴.x + Double(相对.x),
                            枢轴.y + Double(相对.y),
                            枢轴.z + Double(相对.z)
                        )
                    }
                    list[index].scale = Vec3(
                        max(起点.缩放.x * 收口, 0.01),
                        max(起点.缩放.y * 收口, 0.01),
                        max(起点.缩放.z * 收口, 0.01)
                    )
                }
            }

        case .旋转:
            // 旋转模式不给中心球，进不到这里
            break
        }
    }

    private func 手柄抬起() {
        拖拽 = nil
        关节拖拽 = nil
        激活轴 = nil
        球激活 = false
        刷新手柄中心()
    }

    /// 状态栏里的数值读法：已结算的按轴列出来，正在敲的用省略号占位
    private func 数值显示文案(_ 会话: 数值变换会话) -> String {
        // 缩放不锁轴就是等比：三个轴的量永远一样，报一行就够
        if 会话.模式 == .缩放, 会话.轴 == nil {
            return "等比 \(会话.输入片段.isEmpty ? "…" : 会话.输入片段)"
        }
        var 片段: [String] = []
        for 轴 in 手柄轴.allCases {
            guard let 值 = 会话.累计[轴] else { continue }
            片段.append("\(轴.标题)轴 \(短数值(值))")
        }
        if let 轴 = 会话.轴 {
            let 输入 = 会话.输入片段.isEmpty ? "…" : 会话.输入片段
            片段.append("\(轴.标题)轴 \(输入)")
        }
        return 片段.isEmpty ? "还没选轴" : 片段.joined(separator: "  ")
    }

    /// 数值尾巴上的零去掉：0.0100 → 0.01，-0.0000 → -0
    private func 短数值(_ 值: Double) -> String {
        var 文本 = String(format: "%.4f", 值)
        while 文本.contains("."), 文本.hasSuffix("0") { 文本.removeLast() }
        if 文本.hasSuffix(".") { 文本.removeLast() }
        return 文本 == "-0" ? "0" : 文本
    }

    // MARK: 顶部浮动条

    /// 降噪只对上路径追踪着色，其它着色模式下控件置灰
    private var ptActive: Bool {
        store.viewport.shading == .pathTraced
            || ProcessInfo.processInfo.environment["PT_FORCE"] == "1"
    }

    /// 辉光面板：三根滑杆（强度 / 范围 / 屏蔽自身）+ 起辉阈值。
    /// 滑杆必须落在 popover 里 —— 菜单的模态跟踪会把拖拽手势吃掉。
    private var 辉光设置面板: some View {
        @Bindable var store = store
        return VStack(alignment: .leading, spacing: 10) {
            Toggle("眩光辉光（Blender Glare）", isOn: $store.viewport.ptGlowEnabled)
                .toggleStyle(.checkbox)
                .font(.system(size: 12, weight: .semibold))

            // 1 强度：光晕整体亮度（只管加进来的光晕，不改自发光本身）
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("强度").font(.system(size: 11))
                    Spacer()
                    Text(String(format: "×%.2f", store.viewport.ptGlowStrength))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $store.viewport.ptGlowStrength, in: 0...2)
                    .controlSize(.small)
                Text("光晕有多亮。拖到 0 = 不出光晕，自发光本身不变")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }

            // 2 范围：光晕铺多远
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("范围").font(.system(size: 11))
                    Spacer()
                    Text(String(format: "%.0f 级", store.viewport.ptGlowRadius))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $store.viewport.ptGlowRadius, in: 1...6, step: 1)
                    .controlSize(.small)
                Text("光晕铺多远。1 = 贴着轮廓，6 = 大片散开")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }

            // 3 屏蔽自身：拉满 = 只有模型外圈发光
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("屏蔽自身").font(.system(size: 11))
                    Spacer()
                    Text(String(format: "%d%%", Int((store.viewport.ptGlowSelfMask * 100).rounded())))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $store.viewport.ptGlowSelfMask, in: 0...1)
                    .controlSize(.small)
                Text("0% = 表面自己也跟着被辉光提亮；100% = 表面维持原来的自发光效果，只有模型外圈发光")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            // 起辉阈值：哪些亮度算「发光」，档位够用，留作高级项
            Picker("起辉阈值", selection: $store.viewport.ptGlowThreshold) {
                Text("0.5（很敏感）").tag(0.5)
                Text("1.0（默认）").tag(1.0)
                Text("2.0").tag(2.0)
                Text("4.0（只认强自发光）").tag(4.0)
            }
            .font(.system(size: 11))
        }
        .padding(12)
        .frame(width: 268)
    }

    /// 「路径追踪 ▼」：降噪（OIDN 常开）状态 + 采样/降噪参数的收拢入口。
    /// 原来散在工具栏上的「降噪开关 + 降噪 · OIDN 文字」全部并进这个菜单，
    /// 工具栏宽度随之收回来，不再顶出窗口。
    private var ptOptionsMenu: some View {
        @Bindable var store = store
        return Menu {
            Text("降噪 · OIDN 常开")

            Picker("萤火虫压制", selection: $store.viewport.ptLuminosityCeiling) {
                Text("关闭").tag(0.0)
                Text("12×").tag(12.0)
                Text("24×（默认）").tag(24.0)
                Text("48×").tag(48.0)
            }

            Divider()

            Picker("每帧样本", selection: $store.viewport.ptSamplesPerFrame) {
                Text("1 spp").tag(1)
                Text("4 spp").tag(4)
                Text("8 spp（默认）").tag(8)
            }
            Picker("累积上限", selection: $store.viewport.ptMaxSamples) {
                Text("24 spp").tag(24)
                Text("48 spp（默认）").tag(48)
                Text("96 spp").tag(96)
                Text("192 spp").tag(192)
            }
            Picker("光线弹射", selection: $store.viewport.ptMaxBounces) {
                Text("2").tag(2)
                Text("4（默认）").tag(4)
                Text("6").tag(6)
                Text("8").tag(8)
            }
            // ---- 体积介质：湍流形态 + 时间相位 ----
            // 菜单里拖不动滑杆（NSMenu 的模态跟踪会吃掉拖拽），所以做成离散档位；
            // 想连续微调就在「恢复默认参数」旁边来回换档，改一档重开累积一轮即可看出差别。
            Picker("介质湍流", selection: $store.viewport.ptVolumeTurbulence) {
                Text("关闭（纯锥形）").tag(0.0)
                Text("0.5 轻柔").tag(0.5)
                Text("1.0（默认）").tag(1.0)
                Text("1.5 猛烈").tag(1.5)
                Text("2.0 沸腾").tag(2.0)
            }
            Picker("介质起始时间", selection: $store.viewport.ptVolumeTime) {
                Text("0 s").tag(0.0)
                Text("0.5 s").tag(0.5)
                Text("1 s").tag(1.0)
                Text("2 s").tag(2.0)
                Text("4 s").tag(4.0)
                Text("8 s").tag(8.0)
            }
            Toggle("介质动画（火/烟会动）", isOn: $store.viewport.ptVolumeAnimate)
            Picker("内部分辨率", selection: $store.viewport.ptResolutionScale) {
                Text("100%（默认）").tag(1.0)
                Text("85%").tag(0.85)
                Text("75%").tag(0.75)
                Text("50%").tag(0.5)
            }
            // 渲染纹理尺寸：材质图集的边长档位。视口与出图共用这一档，
            // 跟上面「内部分辨率」（画布像素比例）是两个独立维度，别混。
            // 调大更清晰但图集重建/补烘更慢，调小省显存。
            Picker("渲染纹理尺寸", selection: $store.viewport.ptTextureTier) {
                Text("512").tag(512)
                Text("1024（默认）").tag(1024)
                Text("2048").tag(2048)
                Text("4096").tag(4096)
            }

            // 派生贴图缓存上限：烘焙图集 / 缩略图 / 程序贴图这些「现算出来的」图占多少内存。
            // 只影响缓存留多少，不影响画质；改完立刻生效（下一次回收按新上限算）。
            Picker("贴图缓存上限", selection: $store.viewport.ptDerivedCacheMB) {
                Text("128 MB").tag(128)
                Text("256 MB（默认）").tag(256)
                Text("512 MB").tag(512)
                Text("1024 MB").tag(1024)
            }
            .onChange(of: store.viewport.ptDerivedCacheMB) { _, _ in
                store.应用缓存策略()
            }

            Divider()

            Picker("曝光", selection: $store.viewport.exposure) {
                ForEach(Array(stride(from: -1.5, through: 1.5, by: 0.5)), id: \.self) { ev in
                    Text(String(format: "%+.1f EV", ev)).tag(ev)
                }
            }

            Divider()

            Toggle("眩光辉光（Blender Glare）", isOn: $store.viewport.ptGlowEnabled)
            if store.viewport.ptGlowEnabled {
                // 强度 / 范围 / 屏蔽自身是三根连续滑杆，菜单里拖不动：
                // NSMenu 的模态跟踪会吃掉拖拽手势，滑杆会「一拖就关」。
                // 所以参数整体挪进顶栏的辉光面板（泡泡），菜单只负责开关 + 指路。
                Text("强度 · 范围 · 屏蔽自身 → 顶栏 ✨ 面板")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Divider()

            Button("恢复默认参数") {
                store.viewport.ptSamplesPerFrame = 8
                store.viewport.ptMaxSamples = 48
                store.viewport.ptMaxBounces = 4
                store.viewport.ptVolumeTime = 0
                store.viewport.ptVolumeTurbulence = 1
                store.viewport.ptResolutionScale = 1.0
                store.viewport.ptTextureTier = 1024
                store.viewport.ptLuminosityCeiling = 24
                store.viewport.ptDerivedCacheMB = 256
                store.应用缓存策略()
                store.viewport.ptGlowEnabled = true
                store.viewport.ptGlowStrength = 0.35
                store.viewport.ptGlowThreshold = 1.0
                store.viewport.ptGlowRadius = 4
                store.viewport.ptGlowSelfMask = 0
                store.viewport.exposure = 0
                store.note("路径追踪参数已恢复默认")
            }
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .frame(width: 18, height: 16)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
                .accessibilityLabel("路径追踪参数")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("路径追踪参数（含降噪）")
        .accessibilityLabel("路径追踪参数")
        .disabled(!ptActive)
        .opacity(ptActive ? 1 : 0.35)
    }

    /// 只有路径追踪模式才有帧率/GPU 数据可报，其它着色模式不显示指标
    private var 显示性能指标: Bool {
        store.viewport.shading == .pathTraced
            || ProcessInfo.processInfo.environment["PT_FORCE"] == "1"
    }

    /// 顶部浮动条：优先完整版（含环境强度滑块）；宽度不够时自动退到紧凑版
    /// （滑块换成环境菜单里的强度档位）。此前宽度写死、控件堆满，窄窗口下整条
    /// 会被顶到窗口外面，现在由 ViewThatFits 保证任何宽度都收在条内。
    private var topBar: some View {
        ViewThatFits(in: .horizontal) {
            topBarRow(compact: false)
            topBarRow(compact: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(Theme.stroke, lineWidth: 1)
        )
    }

    private func topBarRow(compact: Bool) -> some View {
        @Bindable var store = store
        return HStack(spacing: 6) {
            // 着色模式：不写死宽度，按中文标签自然撑开，避免被压扁/截断
            Picker("", selection: $store.viewport.shading) {
                ForEach(ViewportShading.allCases) { shading in
                    Text(shading.title).tag(shading)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()

            // 路径追踪参数收拢菜单（降噪常开，参数都在这）。排在绘画开关前面
            ptOptionsMenu

            // 绘画开关：不是模式切换，着色/渲染状态一律不动，只是让左键变成画笔
            Button {
                绘画.启用.toggle()
                store.note(绘画.启用
                           ? "绘画：开 — 左键上色，空白处拖动仍可转视角（B 关闭）"
                           : "绘画：关")
            } label: {
                Image(systemName: 绘画.启用 ? "paintbrush.fill" : "paintbrush")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(绘画.启用 ? Color.accentColor : Color.secondary)
                    .frame(width: 20, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("绘画（B）")

            // 辉光面板入口：强度 / 范围 / 屏蔽自身三根滑杆放泡泡里，
            // 菜单（NSMenu）里拖滑杆会被菜单的模态跟踪吃掉，所以独立成面板。
            Button {
                显示辉光设置.toggle()
            } label: {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(store.viewport.ptGlowEnabled ? Color.accentColor : Color.secondary)
                    .frame(width: 20, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("辉光面板（强度 / 范围 / 屏蔽自身）")
            .popover(isPresented: $显示辉光设置, arrowEdge: .bottom) {
                辉光设置面板
            }

            Divider().frame(height: 16)

            // 环境（紧凑版没有滑块，强度改从这里选档）
            Menu {
                ForEach(StudioEnvironment.allCases) { env in
                    Button {
                        store.viewport.environment = env
                        store.note("环境：\(env.title)")
                    } label: {
                        Label(env.title, systemImage: store.viewport.environment == env ? "checkmark" : "")
                    }
                }
                Divider()
                Picker("环境强度", selection: $store.viewport.environmentIntensity) {
                    Text("0.25×").tag(0.25)
                    Text("0.5×").tag(0.5)
                    Text("0.75×").tag(0.75)
                    Text("1.0×").tag(1.0)
                    Text("1.5×").tag(1.5)
                    Text("2.0×").tag(2.0)
                }
            } label: {
                Label(store.viewport.environment.title, systemImage: "sun.max")
                    .font(.system(size: 11))
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .frame(width: compact ? 74 : 92)

            if !compact {
                Slider(value: $store.viewport.environmentIntensity, in: 0.2...2.0)
                    .controlSize(.mini)
                    .frame(width: 76)
                Text(String(format: "×%.2f", store.viewport.environmentIntensity))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }

            Divider().frame(height: 16)

            // 添加物体：面板贴在按钮下方；⇧A 弹同一张面板，只是改贴在鼠标处
            Button {
                if 显示添加面板 {
                    显示添加面板 = false
                } else {
                    添加面板原点 = 计算添加面板原点(锚在按钮: true)
                    显示添加面板 = true
                }
            } label: {
                Image(systemName: "plus.square.on.square")
                    .font(.system(size: 11))
                    .foregroundStyle(显示添加面板 ? Color.accentColor : Color.primary)
                    .frame(width: 20, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: 添加按钮框Key.self,
                        value: proxy.frame(in: .named("视口"))
                    )
                }
            )
            .help("添加物体：立方体 / 圆柱 / 圆环 / 圆球 / 平面 / 方台 / 着色球 …（⇧A 在鼠标处打开）")

            // 特效与全局物理：合成一个下拉，免得顶栏再摊开两个按钮。
            // 上半是「加发射器」——点一项就往场景里真加一个对象，可以加任意多个；
            // 下半是「换全局那套力」——重力/风/流是全局单体，不上大纲，也不进场景。
            Menu {
                Section("添加特效") {
                    ForEach(特效库.预设们) { 预设 in
                        Button {
                            添加特效(预设)
                        } label: {
                            Label(预设.名称, systemImage: 预设.符号)
                        }
                    }
                }
                Section("全局物理") {
                    ForEach(物理库.预设们) { 预设 in
                        Toggle(isOn: 物理档勾选(预设)) {
                            Label(预设.名称, systemImage: 预设.符号)
                        }
                    }
                    Divider()
                    Toggle(isOn: 物理启用勾选) {
                        Label("启用物理", systemImage: "power")
                    }
                }
            } label: {
                Image(systemName: "sparkles")
                    .font(.system(size: 11))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 20)
            .help("特效：粒子 / 火 / 烟 / 水（加发射器对象）· 全局物理：重力 / 风 / 流 / 湍流")

            Divider().frame(height: 16)

            // 通用导入：一个入口吃所有格式，格式差异全在新窗口里按 Tab 分
            Button {
                通用导入窗口控制器.shared.显示 { 场景集 in
                    导入接入.放入(场景集, 场景: scene)
                }
            } label: {
                Image(systemName: "square.and.arrow.down.on.square")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help("通用导入：fbx / blend / usd(usda·usdc·usdz) / gltf / obj / stl / ply")

            // 导出：格式差异收进菜单，选中才弹保存面板
            Menu {
                ForEach(导出接入.格式表) { 项 in
                    Button(项.标题) {
                        导出接入.运行(
                            项,
                            objects: scene.objects,
                            materials: store.materialsByID,
                            场景: scene
                        )
                    }
                }
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 11))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 20)
            .help("导出场景：glTF / OBJ / USDA / STL / PLY / FBX / BLEND")

            // 出图：开一个独立的渲染窗口（视口只负责预览，要成片走窗口里那条离屏链路）
            Button {
                出图窗口控制器.shared.显示(
                    objects: scene.objects,
                    materials: store.materialsByID,
                    视口: store.viewport,
                    相机: { 视口场景.pathTraceCamera() }
                )
            } label: {
                Image(systemName: "camera")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help("出图：打开独立渲染窗口")

            Spacer(minLength: 0)
        }
    }

    // MARK: 底部角标

    private var bottomBar: some View {
        @Bindable var store = store
        return HStack(alignment: .bottom, spacing: 10) {
            对象信息卡
                .背景框上报()
            Spacer(minLength: 0)

            // 视图开关：网格 / 地面 / 自动转台。从顶栏挪到这儿，排在坐标空间与变换模式之前
            // 视觉必须和右边两组（坐标空间、变换模式）完全同源：同圆角、同内边距、同字号、同胶囊外框，
            // 否则系统 Toggle 会自带一套尺寸，排在一起明显一大一小
            HStack(spacing: 3) {
                视图开关按钮(开: $store.viewport.showsGrid, 符号: "grid", 标题: "网格", 提示: "显示网格")
                视图开关按钮(开: $store.viewport.showsGround, 符号: "square.on.square.dashed", 标题: "地面", 提示: "显示地面")
                视图开关按钮(开: $store.viewport.autoRotate, 符号: "arrow.clockwise", 标题: "转台", 提示: "自动转台")
            }
            .padding(3)
            .background(.ultraThinMaterial, in: Capsule())
            .背景框上报()

            // 坐标空间：手柄跟世界轴（全局）还是跟物体自身轴（局部）
            坐标空间控件(空间: $手柄空间)
                .背景框上报()
                .padding(.trailing, 5)

            // 变换模式：点这里或按 W / E / R 切换
            HStack(spacing: 3) {
                ForEach(变换模式.allCases) { mode in
                    Button {
                        手柄模式 = mode
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: mode.symbol)
                                .font(.system(size: 9))
                            Text(mode.title)
                                .font(.system(size: 9.5))
                            Text(mode.shortcut)
                                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                                .opacity(0.65)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            手柄模式 == mode ? Theme.主色.opacity(0.2) : Color.primary.opacity(0.05),
                            in: RoundedRectangle(cornerRadius: 5)
                        )
                        .foregroundStyle(手柄模式 == mode ? Theme.主色 : Color.secondary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("\(mode.title)模式（\(mode.shortcut)）")
                }
            }
            .padding(3)
            .background(.ultraThinMaterial, in: Capsule())
            .背景框上报()

            Text("拖拽旋转 · 捏合/滚轮缩放 · 拖手柄调整")
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.ultraThinMaterial, in: Capsule())
                .背景框上报()
        }
    }

    // MARK: 底部左侧：选中物体信息

    /// 原来这块显示的是「当前材质 + 视口近似」，选了物体也看不出物体本身，信息重复且没处看点数。
    /// 改成物体信息：名字、顶点 / 三角面、材质名与数量、材质图里的效果器数量。
    @ViewBuilder
    private var 对象信息卡: some View {
        if let object = scene.selectedObject {
            let 几何 = 对象统计.几何(object)
            let 材质 = store.material(object.materialID)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: object.symbol)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.主色)
                    Text(object.name)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if scene.选中集合.count > 1 {
                        Text("+\(scene.选中集合.count - 1)")
                            .font(.system(size: 8.5, design: .monospaced))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Theme.主色.opacity(0.18), in: Capsule())
                            .foregroundStyle(Theme.主色)
                            .help("另外还选中了 \(scene.选中集合.count - 1) 个物体")
                    }
                    Text(object.灯光 != nil ? "光源" : (几何接线.共享.取值(键: object.id.uuidString)?.导入网格标识 ?? object.导入网格ID == nil ? "程序化" : "导入"))
                        .font(.system(size: 8.5, design: .monospaced))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.primary.opacity(0.07), in: Capsule())
                        .foregroundStyle(.secondary)
                    if !object.isVisible {
                        Text("隐藏")
                            .font(.system(size: 8.5, design: .monospaced))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.18), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                }

                if let 灯 = object.灯光 {
                    // 灯是光类型，不产几何、也不挂材质：点数与材质那一套对它没意义
                    HStack(spacing: 10) {
                        信息项(标题: "光类型", 值: 灯.种类.title)
                        信息项(标题: "功率", 值: "\(Int(灯.功率))W")
                        信息项(标题: "色温", 值: "\(Int(灯.色温))K")
                    }
                } else {
                    HStack(spacing: 10) {
                        信息项(标题: "顶点", 值: 千分位(几何.顶点))
                        信息项(标题: "三角面", 值: 千分位(几何.三角面))
                    }

                    HStack(spacing: 10) {
                        信息项(标题: "材质", 值: 材质?.name ?? "无")
                        信息项(标题: "材质槽", 值: "\(对象统计.材质槽数(object))")
                        信息项(标题: "效果器", 值: "\(对象统计.效果器数(材质))")
                    }
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
            .help(object.灯光 == nil
                  ? "物体信息：顶点 / 三角面来自网格本身，效果器＝该材质图里除输出和常量外的节点数"
                  : "灯是光类型：不生成几何、不参与材质，只按功率 / 色温 / 朝向照明")
        } else {
            Text("未选中物体 · 点视口里的物体看点数 / 材质 / 效果器")
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func 信息项(标题: String, 值: String) -> some View {
        HStack(spacing: 3) {
            Text(标题)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Text(值)
                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    /// 顶点动辄几十万，不加千分位读不出量级
    private func 千分位(_ 值: Int) -> String {
        guard 值 >= 1000 else { return "\(值)" }
        var 剩余 = "\(值)"
        var 结果 = ""
        while 剩余.count > 3 {
            结果 = "," + 剩余.suffix(3) + 结果
            剩余 = String(剩余.dropLast(3))
        }
        return 剩余 + 结果
    }

    // MARK: 材质球投放

    /// 拖进来的东西只有一串材质 UUID（库那边用 id 作为拖拽载荷）。
    /// 先按落点拾取物体；落点没打到东西，就退化成"给当前选中的物体上材质"，
    /// 这样手抖一点也不会白拖一次。
    private func 接收材质球(_ info: DropInfo, 落点: CGPoint) -> Bool {
        guard let provider = info.itemProviders(for: [.text]).first else { return false }

        let 命中的物体ID = 视口场景.pick(at: 落点, viewSize: 视口尺寸)
        guard let 目标 = 命中的物体ID ?? scene.selectedObjectID else {
            store.note("拖到视口里的物体上；或先选中物体再拖过来")
            return false
        }
        let 目标名 = scene.objects.first { $0.id == 目标 }?.name ?? "物体"

        provider.loadObject(ofClass: NSString.self) { 对象, _ in
            guard let 原始 = 对象 as? String else { return }
            guard let 材质ID = UUID(uuidString: 原始) else { return }
            DispatchQueue.main.async {
                // 库条目（含内置）→ 派生成实例；工程自有材质 → 直接用本身。判定在 store 里，这里只问一句。
                let 上手 = store.实例ID(for: 材质ID)
                scene.assign(上手, to: 目标)
                scene.选中(目标)
                store.selectedMaterialID = 上手
                store.note("已给 \(目标名) 上 \(store.material(上手)?.name ?? "材质")")
            }
        }
        return true
    }
}

/// 视口的材质投放层：量出画布尺寸（落点要换算成拾取坐标）、接住拖放、拖到上方时描一圈虚线框。
/// 单独抽出来是为了别把主 body 那条 modifier 链继续撑长 —— 链太长编译器会直接超时。
private struct 材质投放修饰: ViewModifier {
    @Binding var 视口尺寸: CGSize
    let 落点接收: (DropInfo, CGPoint) -> Bool

    /// 虚线框状态留在这个修饰自己身上：以前挂在视口主视图的 @State 上，
    /// 拖入 / 拖出一次就让整个视口 body 重算（RealityView update、场景 sync 全跑一遍），
    /// 拖拽时反复进出边界等于反复全量重绘，系统的拖影就是被这么卡在半路的。
    @State private var 材质拖入中 = false

    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { 视口尺寸 = proxy.size }
                        .onChange(of: proxy.size) { _, 新 in 视口尺寸 = 新 }
                }
            )
            .onDrop(of: [.text], delegate: 材质投放代理(
                高亮: { 材质拖入中 = $0 },
                接收: 落点接收
            ))
            .overlay {
                if 材质拖入中 {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(
                            Theme.主色.opacity(0.85),
                            style: StrokeStyle(lineWidth: 2, dash: [7, 5])
                        )
                        .padding(4)
                        .allowsHitTesting(false)
                }
            }
    }
}

/// 视口的拖放代理：只认文本型载荷（材质 UUID），顺手把"松手就能上材质"的虚线框亮起来。
private struct 材质投放代理: DropDelegate {
    let 高亮: (Bool) -> Void
    let 接收: (DropInfo, CGPoint) -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.text])
    }

    func dropEntered(info: DropInfo) {
        高亮(true)
    }

    func dropExited(info: DropInfo) {
        高亮(false)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .copy)
    }

    func performDrop(info: DropInfo) -> Bool {
        高亮(false)
        return 接收(info, info.location)
    }
}

// MARK: - 视图开关按钮

/// 底栏的图标开关（网格 / 地面 / 转台）。
/// 完全照抄「坐标空间控件」那套形式：图标 9 + 文字 9.5、间距 3、内边距 7×3、圆角 5，
/// 选中主色 0.2 / 未选 primary 0.05，这样三组并排时是同一套尺寸与排版。
private struct 视图开关按钮: View {
    @Binding var 开: Bool
    let 符号: String
    let 标题: String
    let 提示: String

    var body: some View {
        Button {
            开.toggle()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: 符号)
                    .font(.system(size: 9))
                Text(标题)
                    .font(.system(size: 9.5))
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                开 ? Theme.主色.opacity(0.2) : Color.primary.opacity(0.05),
                in: RoundedRectangle(cornerRadius: 5)
            )
            .foregroundStyle(开 ? Theme.主色 : Color.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(提示)
    }
}

// MARK: - 坐标空间控件

/// 底栏的坐标空间切换：全局轴 / 局部轴。放在 W / E / R 左边，和变换模式一起决定手柄姿态。
private struct 坐标空间控件: View {
    @Binding var 空间: 坐标空间

    var body: some View {
        HStack(spacing: 3) {
            ForEach(坐标空间.allCases) { item in
                Button {
                    空间 = item
                } label: {
                    标签(item)
                }
                .buttonStyle(.plain)
                .help(item.help)
            }
        }
        .padding(3)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private func 标签(_ item: 坐标空间) -> some View {
        let 选中 = 空间 == item
        return HStack(spacing: 3) {
            Image(systemName: item.symbol)
                .font(.system(size: 9))
            Text(item.title)
                .font(.system(size: 9.5))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            选中 ? Theme.主色.opacity(0.2) : Color.primary.opacity(0.05),
            in: RoundedRectangle(cornerRadius: 5)
        )
        .foregroundStyle(选中 ? Theme.主色 : Color.secondary)
        .contentShape(Rectangle())
    }
}

// MARK: - 左上角性能面板

/// 视口左上角的悬空性能指标：一行一个指标、无背景、不接管鼠标。
/// 数据来自 PT性能统计（渲染器每 30 帧结算一次窗口均值）。
private struct 视口性能面板: View {
    @State private var 统计 = PT性能统计.shared

    var body: some View {
        if 统计.有效 {
            VStack(alignment: .leading, spacing: 1) {
                指标行("FPS", String(format: "%.0f", 统计.帧率))
                指标行("CPU", String(format: "%.1f ms", 统计.CPU毫秒))
                指标行("GPU", String(format: "%.1f ms", 统计.GPU毫秒))
                指标行("降噪", String(format: "%.1f ms", 统计.降噪毫秒))
                指标行("分辨率", 统计.宽度 > 0 ? "\(统计.宽度)×\(统计.高度)" : "—")
                指标行("采样", 统计.样本上限 > 0
                       ? "\(统计.样本)/\(统计.样本上限) spp"
                       : "\(统计.样本) spp")
            }
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            // 视口背景可能是深也可能是浅，给字一层极淡描影保证两种主题都读得清
            .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
            .allowsHitTesting(false)
        }
    }

    private func 指标行(_ 名称: String, _ 值: String) -> some View {
        HStack(spacing: 6) {
            Text(名称)
                .frame(width: 30, alignment: .leading)
                .opacity(0.7)
            Text(值)
        }
    }
}

// MARK: - 视口单位角标

/// 视口右下角的单位提示：1 世界单位 = 1 网格格 = 1 m。
/// 纯展示层，自身不接收鼠标事件，拾取 / 旋转 / 平移 / 框选照旧走下面那层。
private struct 视口单位角标: View {
    var body: some View {
        Text("1 格 = 1 m")
            .font(.system(size: 10.5, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(Theme.配色.文字次.opacity(0.9))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(Theme.配色.面板.opacity(Theme.配色.深色 ? 0.55 : 0.75)))
            .overlay(Capsule().strokeBorder(Theme.配色.描边, lineWidth: 0.5))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// MARK: - 右上角控件占位

/// 把轴向控件的 frame 回传给面板，用来屏蔽它上面的穿透点击
private struct 轴向控件框Key: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

/// 视口浮动控件的占位框（顶栏、底栏）。
/// AppKit 事件监视器比 SwiftUI 先拿到鼠标事件，落在这些框里的点击必须先排除掉，
/// 否则点底部「旋转 / 移动 / 缩放」按钮时，视口把同一次点击当成空白处点选，
/// 顺手把当前选中的对象清空 —— 表现就是「点旋转轴就消失，得重新选对象」。
private struct 视口控件框Key: PreferenceKey {
    static let defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
        value.append(contentsOf: nextValue())
    }
}

/// 顶栏「添加物体」按钮的占位：面板贴在它下面弹
private struct 添加按钮框Key: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let 新 = nextValue()
        if 新 != .zero { value = 新 }
    }
}

/// 把浮动控件的占位框以 preference 上报给面板（坐标系用视口自身的 named 空间）
private struct 控件框上报: ViewModifier {
    func body(content: Content) -> some View {
        content.background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: 视口控件框Key.self,
                    value: [proxy.frame(in: .named("视口"))]
                )
            }
        )
    }
}

private extension View {
    func 背景框上报() -> some View { modifier(控件框上报()) }
}

/// 「圆盘坐标 → 屏幕」的仿射矩阵换成「视图局部像素坐标 → 屏幕」的矩阵。
///
/// 笔刷预览视图是边长 2r 的正方形，局部 (0,0) 对应圆盘坐标 (-1,-1)，
/// 所以要先把局部像素除以 r 换成圆盘单位，再补上「原点不在圆心」的偏移。
/// 变换之后圆的 clip 自然变成贴合表面的椭圆 —— 圆的边界永远落在切平面上。
private func 贴平面变换(_ 盘: CGAffineTransform, 圆半径 r: CGFloat) -> CGAffineTransform {
    guard r > 0.01 else { return .identity }
    let a = 盘.a / r
    let b = 盘.b / r
    let c = 盘.c / r
    let d = 盘.d / r
    return CGAffineTransform(
        a: a, b: b, c: c, d: d,
        tx: 盘.tx - (a * r + c * r),
        ty: 盘.ty - (b * r + d * r)
    )
}

// MARK: - 添加面板里的模型线稿缩略图

/// 面板格子里的形状缩略图：不画实物渲染（26pt 也看不出材质），
/// 只画能一眼认出来的轮廓线稿 —— 立方体就是立方体的样子，圆环就是两个同心圈。
private struct 模型缩略图: View {
    let id: String

    var body: some View {
        Canvas { 上下文, 尺寸 in
            var 路径 = Path()
            let 宽 = 尺寸.width, 高 = 尺寸.height
            let 中心 = CGPoint(x: 宽 / 2, y: 高 / 2)
            // 灯不产几何：只画线框，不填充、不画实心块，唯一加粗的是「光朝哪」那一笔
            if let 灯图 = 灯光缩略图(id: id, 中心: 中心, 宽: 宽, 高: 高) {
                上下文.stroke(
                    灯图.壳体,
                    with: .color(Color.secondary.opacity(0.9)),
                    style: StrokeStyle(lineWidth: 1.0, lineCap: .round, lineJoin: .round)
                )
                上下文.stroke(
                    灯图.发光,
                    with: .color(Color.orange.opacity(0.95)),
                    style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round)
                )
                return
            }
            switch id {
            case "立方体": 立方体线(&路径, 中心: 中心, 宽: 宽, 高: 高, 扁: false)
            case "方台":   立方体线(&路径, 中心: 中心, 宽: 宽, 高: 高, 扁: true)
            case "圆柱":   圆柱线(&路径, 中心: 中心, 宽: 宽, 高: 高)
            case "圆环", "金属圆环": 圆环线(&路径, 中心: 中心, 宽: 宽, 高: 高)
            case "平面":   平面线(&路径, 中心: 中心, 宽: 宽, 高: 高)
            case "着色球":
                球线(&路径, 中心: CGPoint(x: 中心.x, y: 中心.y - 高 * 0.10), 半径: 宽 * 0.24)
                底座线(&路径, 中心: 中心, 宽: 宽, 高: 高)
            case "霓虹球":
                球线(&路径, 中心: 中心, 半径: 宽 * 0.28)
                光线线(&路径, 中心: 中心, 半径: 宽 * 0.28)
            case "圆锥":   锥线(&路径, 中心: 中心, 宽: 宽, 高: 高)
            case "胶囊":   胶囊线(&路径, 中心: 中心, 宽: 宽, 高: 高)
            case "半球":   半球线(&路径, 中心: 中心, 宽: 宽, 高: 高)
            case "棱柱":   棱柱线(&路径, 中心: 中心, 宽: 宽, 高: 高)
            case "圆盘":   圆盘线(&路径, 中心: 中心, 宽: 宽, 高: 高)
            case "台阶":   台阶线(&路径, 中心: 中心, 宽: 宽, 高: 高)
            default:       球线(&路径, 中心: 中心, 半径: 宽 * 0.30)
            }
            上下文.stroke(
                路径,
                with: .color(Color.secondary.opacity(0.9)),
                style: StrokeStyle(lineWidth: 1.1, lineCap: .round, lineJoin: .round)
            )
        }
    }

    /// 等轴测立方体；扁一点就是方台
    private func 立方体线(_ p: inout Path, 中心: CGPoint, 宽: CGFloat, 高: CGFloat, 扁: Bool) {
        let 半宽 = 宽 * (扁 ? 0.42 : 0.31)
        let 半高 = 高 * (扁 ? 0.10 : 0.17)
        let 顶y = 高 * (扁 ? 0.36 : 0.20)
        let 棱 = 高 * (扁 ? 0.07 : 0.17)
        let cx = 中心.x
        // 顶面菱形
        p.move(to: CGPoint(x: cx, y: 顶y))
        p.addLine(to: CGPoint(x: cx + 半宽, y: 顶y + 半高))
        p.addLine(to: CGPoint(x: cx, y: 顶y + 半高 * 2))
        p.addLine(to: CGPoint(x: cx - 半宽, y: 顶y + 半高))
        p.closeSubpath()
        // 三条竖棱
        let 侧顶 = 顶y + 半高
        for x in [cx - 半宽, cx, cx + 半宽] {
            p.move(to: CGPoint(x: x, y: x == cx ? 侧顶 + 半高 : 侧顶))
            p.addLine(to: CGPoint(x: x, y: (x == cx ? 侧顶 + 半高 : 侧顶) + 棱))
        }
        // 底面两条
        p.move(to: CGPoint(x: cx - 半宽, y: 侧顶 + 棱))
        p.addLine(to: CGPoint(x: cx, y: 侧顶 + 半高 + 棱))
        p.addLine(to: CGPoint(x: cx + 半宽, y: 侧顶 + 棱))
    }

    private func 圆柱线(_ p: inout Path, 中心: CGPoint, 宽: CGFloat, 高: CGFloat) {
        let r = 宽 * 0.26
        let 上y = 高 * 0.28, 下y = 高 * 0.70
        let 椭 = 高 * 0.085
        p.addEllipse(in: CGRect(x: 中心.x - r, y: 上y - 椭, width: r * 2, height: 椭 * 2))
        p.move(to: CGPoint(x: 中心.x - r, y: 上y))
        p.addLine(to: CGPoint(x: 中心.x - r, y: 下y))
        p.move(to: CGPoint(x: 中心.x + r, y: 上y))
        p.addLine(to: CGPoint(x: 中心.x + r, y: 下y))
        p.move(to: CGPoint(x: 中心.x - r, y: 下y))
        p.addQuadCurve(
            to: CGPoint(x: 中心.x + r, y: 下y),
            control: CGPoint(x: 中心.x, y: 下y + 椭 * 2)
        )
    }

    private func 圆环线(_ p: inout Path, 中心: CGPoint, 宽: CGFloat, 高: CGFloat) {
        let rx = 宽 * 0.34, ry = 高 * 0.21
        p.addEllipse(in: CGRect(x: 中心.x - rx, y: 中心.y - ry, width: rx * 2, height: ry * 2))
        p.addEllipse(in: CGRect(
            x: 中心.x - rx * 0.52, y: 中心.y - ry * 0.52,
            width: rx * 1.04, height: ry * 1.04
        ))
    }

    private func 平面线(_ p: inout Path, 中心: CGPoint, 宽: CGFloat, 高: CGFloat) {
        let cx = 中心.x
        p.move(to: CGPoint(x: cx - 宽 * 0.36, y: 高 * 0.62))
        p.addLine(to: CGPoint(x: cx + 宽 * 0.02, y: 高 * 0.36))
        p.addLine(to: CGPoint(x: cx + 宽 * 0.36, y: 高 * 0.42))
        p.addLine(to: CGPoint(x: cx - 宽 * 0.02, y: 高 * 0.68))
        p.closeSubpath()
    }

    private func 球线(_ p: inout Path, 中心: CGPoint, 半径 r: CGFloat) {
        p.addEllipse(in: CGRect(x: 中心.x - r, y: 中心.y - r, width: r * 2, height: r * 2))
        // 一道高光弧，跟纯圆区分开
        p.addArc(
            center: 中心, radius: r * 0.62,
            startAngle: .degrees(196), endAngle: .degrees(252),
            clockwise: false
        )
    }

    /// 着色球的底座：一圈托盘口 + 两侧斜边
    private func 底座线(_ p: inout Path, 中心: CGPoint, 宽: CGFloat, 高: CGFloat) {
        let r = 宽 * 0.32
        let 口y = 高 * 0.90
        p.move(to: CGPoint(x: 中心.x - r, y: 口y))
        p.addLine(to: CGPoint(x: 中心.x - r * 0.58, y: 高 * 0.70))
        p.move(to: CGPoint(x: 中心.x + r, y: 口y))
        p.addLine(to: CGPoint(x: 中心.x + r * 0.58, y: 高 * 0.70))
        p.addEllipse(in: CGRect(x: 中心.x - r * 0.58, y: 高 * 0.63, width: r * 1.16, height: 高 * 0.14))
        p.move(to: CGPoint(x: 中心.x - r, y: 口y))
        p.addQuadCurve(to: CGPoint(x: 中心.x + r, y: 口y), control: CGPoint(x: 中心.x, y: 口y + 高 * 0.10))
    }

    /// 霓虹球外面点几道光线
    private func 光线线(_ p: inout Path, 中心: CGPoint, 半径 r: CGFloat) {
        let 内向 = r * 1.12, 外向 = r * 1.45
        for 角度 in stride(from: 0.0, to: 360.0, by: 45.0) {
            let 弧度 = 角度 * .pi / 180
            p.move(to: CGPoint(x: 中心.x + cos(弧度) * 内向, y: 中心.y + sin(弧度) * 内向))
            p.addLine(to: CGPoint(x: 中心.x + cos(弧度) * 外向, y: 中心.y + sin(弧度) * 外向))
        }
    }

    private func 锥线(_ p: inout Path, 中心: CGPoint, 宽: CGFloat, 高: CGFloat) {
        let r = 宽 * 0.28
        let 尖y = 高 * 0.20, 底y = 高 * 0.70
        let 椭 = 高 * 0.075
        p.move(to: CGPoint(x: 中心.x, y: 尖y))
        p.addLine(to: CGPoint(x: 中心.x - r, y: 底y))
        p.move(to: CGPoint(x: 中心.x, y: 尖y))
        p.addLine(to: CGPoint(x: 中心.x + r, y: 底y))
        p.move(to: CGPoint(x: 中心.x - r, y: 底y))
        p.addQuadCurve(to: CGPoint(x: 中心.x + r, y: 底y), control: CGPoint(x: 中心.x, y: 底y + 椭 * 2))
    }

    private func 胶囊线(_ p: inout Path, 中心: CGPoint, 宽: CGFloat, 高: CGFloat) {
        let r = 宽 * 0.19
        let cx = 中心.x
        let 上y = 高 * 0.36, 下y = 高 * 0.64
        p.move(to: CGPoint(x: cx - r, y: 上y))
        p.addLine(to: CGPoint(x: cx - r, y: 下y))
        p.move(to: CGPoint(x: cx + r, y: 上y))
        p.addLine(to: CGPoint(x: cx + r, y: 下y))
        // 上下两端各半个圆，用二次曲线近似（缩略图尺寸看不出差别）
        p.move(to: CGPoint(x: cx - r, y: 上y))
        p.addQuadCurve(to: CGPoint(x: cx + r, y: 上y), control: CGPoint(x: cx, y: 上y - r * 1.45))
        p.move(to: CGPoint(x: cx - r, y: 下y))
        p.addQuadCurve(to: CGPoint(x: cx + r, y: 下y), control: CGPoint(x: cx, y: 下y + r * 1.45))
    }

    private func 半球线(_ p: inout Path, 中心: CGPoint, 宽: CGFloat, 高: CGFloat) {
        let r = 宽 * 0.30
        let 底y = 高 * 0.66
        let 椭 = 高 * 0.075
        p.move(to: CGPoint(x: 中心.x - r, y: 底y))
        p.addQuadCurve(to: CGPoint(x: 中心.x + r, y: 底y), control: CGPoint(x: 中心.x, y: 底y - r * 1.9))
        p.move(to: CGPoint(x: 中心.x - r, y: 底y))
        p.addQuadCurve(to: CGPoint(x: 中心.x + r, y: 底y), control: CGPoint(x: 中心.x, y: 底y + 椭 * 2))
    }

    /// 八角棱柱：顶面八边形 + 三条竖棱 + 底面弧
    private func 棱柱线(_ p: inout Path, 中心: CGPoint, 宽: CGFloat, 高: CGFloat) {
        let r = 宽 * 0.26
        let 顶y = 高 * 0.26, 底y = 高 * 0.68
        let 扁 = 高 * 0.055
        var 顶面 = Path()
        for index in 0..<8 {
            let 角度 = Double(index) / 8 * 2 * .pi + .pi / 8
            let 点 = CGPoint(x: 中心.x + cos(角度) * r, y: 顶y + sin(角度) * 扁)
            if index == 0 { 顶面.move(to: 点) } else { 顶面.addLine(to: 点) }
        }
        顶面.closeSubpath()
        p.addPath(顶面)
        // 左右两条竖棱 + 中间一条
        for x in [中心.x - r, 中心.x, 中心.x + r] {
            p.move(to: CGPoint(x: x, y: x == 中心.x ? 顶y + 扁 : 顶y))
            p.addLine(to: CGPoint(x: x, y: (x == 中心.x ? 顶y + 扁 : 顶y) + (底y - 顶y)))
        }
        p.move(to: CGPoint(x: 中心.x - r, y: 底y))
        p.addQuadCurve(to: CGPoint(x: 中心.x + r, y: 底y), control: CGPoint(x: 中心.x, y: 底y + 扁 * 2))
    }

    private func 圆盘线(_ p: inout Path, 中心: CGPoint, 宽: CGFloat, 高: CGFloat) {
        let rx = 宽 * 0.32, ry = 高 * 0.09
        let 上y = 高 * 0.44, 下y = 高 * 0.58
        p.addEllipse(in: CGRect(x: 中心.x - rx, y: 上y - ry, width: rx * 2, height: ry * 2))
        p.move(to: CGPoint(x: 中心.x - rx, y: 上y))
        p.addLine(to: CGPoint(x: 中心.x - rx, y: 下y))
        p.move(to: CGPoint(x: 中心.x + rx, y: 上y))
        p.addLine(to: CGPoint(x: 中心.x + rx, y: 下y))
        p.move(to: CGPoint(x: 中心.x - rx, y: 下y))
        p.addQuadCurve(to: CGPoint(x: 中心.x + rx, y: 下y), control: CGPoint(x: 中心.x, y: 下y + ry * 2))
    }

    /// 台阶：三级阶梯的侧剖线 + 顶面斜线
    private func 台阶线(_ p: inout Path, 中心: CGPoint, 宽: CGFloat, 高: CGFloat) {
        let 左 = 宽 * 0.20, 右 = 宽 * 0.80
        let 低y = 高 * 0.74, 高y = 高 * 0.34
        let 级宽 = (右 - 左) / 3
        var y = 低y
        p.move(to: CGPoint(x: 左, y: y))
        for 级 in 0..<3 {
            let x = 左 + 级宽 * CGFloat(级 + 1)
            if 级 > 0 {
                y -= (低y - 高y) / 3
                p.addLine(to: CGPoint(x: 左 + 级宽 * CGFloat(级), y: y))
            }
            p.addLine(to: CGPoint(x: x, y: y))
        }
        p.addLine(to: CGPoint(x: 右, y: 低y))
    }


    // MARK: 灯光缩略图

    /// 灯不产几何，缩略图就只画线框：一层壳体线（灯长什么样），一层橙色出光线（光朝哪）。
    /// 橙色那几笔是「出光面」的唯一标记 —— 面光板是朝下那条棱加箭头，筒灯是底口弧加箭头。
    private struct 灯光缩略图件 {
        var 壳体 = Path()
        var 发光 = Path()
    }

    private func 灯光缩略图(id: String, 中心: CGPoint, 宽 w: CGFloat, 高 h: CGFloat) -> 灯光缩略图件? {
        var 图 = 灯光缩略图件()
        let cx = 中心.x
        switch id {
        case "面光板", "条形灯":
            let 长条 = (id == "条形灯")
            let 半宽 = w * (长条 ? 0.40 : 0.29)
            let 厚 = h * (长条 ? 0.08 : 0.14)
            let 板y = h * 0.30
            // 一块斜放的薄板：四根棱画出来就够了，别填充
            图.壳体.move(to: CGPoint(x: cx - 半宽, y: 板y))
            图.壳体.addLine(to: CGPoint(x: cx, y: 板y - 厚))
            图.壳体.addLine(to: CGPoint(x: cx + 半宽, y: 板y))
            图.壳体.addLine(to: CGPoint(x: cx, y: 板y + 厚))
            图.壳体.closeSubpath()
            // 朝下这条棱才是发光面
            图.发光.move(to: CGPoint(x: cx - 半宽, y: 板y))
            图.发光.addLine(to: CGPoint(x: cx, y: 板y + 厚))
            图.发光.addLine(to: CGPoint(x: cx + 半宽, y: 板y))
            灯箭头(&图.壳体, x: cx, 从: 板y + 厚, 到: h * 0.90, 头宽: w * 0.09)

        case "环形灯":
            let rx = w * 0.32, ry = h * 0.19
            let 环心y = h * 0.36
            图.壳体.addEllipse(in: CGRect(x: cx - rx, y: 环心y - ry, width: rx * 2, height: ry * 2))
            图.壳体.addEllipse(in: CGRect(
                x: cx - rx * 0.55, y: 环心y - ry * 0.55, width: rx * 1.1, height: ry * 1.1
            ))
            // 下半个环亮起来
            图.发光.addArc(
                center: CGPoint(x: cx, y: 环心y), radius: rx * 0.78,
                startAngle: .degrees(20), endAngle: .degrees(160), clockwise: false
            )
            灯箭头(&图.壳体, x: cx, 从: 环心y + ry, 到: h * 0.92, 头宽: w * 0.08)

        case "球灯":
            // 空心圆加四向短线：不画实心圆，否则又像个材质球
            let r = w * 0.21
            let 球心 = CGPoint(x: cx, y: h * 0.42)
            图.壳体.addEllipse(in: CGRect(x: 球心.x - r, y: 球心.y - r, width: r * 2, height: r * 2))
            for 角度 in [40.0, 140.0, 220.0, 320.0] {
                let 弧度 = 角度 * .pi / 180
                let 内 = r + w * 0.05, 外 = r + w * 0.14
                图.发光.move(to: CGPoint(x: 球心.x + cos(弧度) * 内, y: 球心.y + sin(弧度) * 内))
                图.发光.addLine(to: CGPoint(x: 球心.x + cos(弧度) * 外, y: 球心.y + sin(弧度) * 外))
            }

        case "筒灯":
            let 半径 = w * 0.19
            let 顶y = h * 0.20, 底y = h * 0.58
            let 椭 = h * 0.06
            图.壳体.addEllipse(in: CGRect(x: cx - 半径, y: 顶y - 椭, width: 半径 * 2, height: 椭 * 2))
            图.壳体.move(to: CGPoint(x: cx - 半径, y: 顶y))
            图.壳体.addLine(to: CGPoint(x: cx - 半径, y: 底y))
            图.壳体.move(to: CGPoint(x: cx + 半径, y: 顶y))
            图.壳体.addLine(to: CGPoint(x: cx + 半径, y: 底y))
            // 底口是出光面
            图.发光.addArc(
                center: CGPoint(x: cx, y: 底y), radius: 半径,
                startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false
            )
            灯箭头(&图.壳体, x: cx, 从: 底y + 椭, 到: h * 0.92, 头宽: w * 0.09)

        case "霓虹灯柱":
            let 半宽 = w * 0.075
            let 上y = h * 0.16, 下y = h * 0.70
            图.壳体.move(to: CGPoint(x: cx - 半宽, y: 上y))
            图.壳体.addLine(to: CGPoint(x: cx - 半宽, y: 下y))
            图.壳体.move(to: CGPoint(x: cx + 半宽, y: 上y))
            图.壳体.addLine(to: CGPoint(x: cx + 半宽, y: 下y))
            图.壳体.move(to: CGPoint(x: cx - 半宽, y: 上y))
            图.壳体.addLine(to: CGPoint(x: cx + 半宽, y: 上y))
            图.壳体.move(to: CGPoint(x: cx - 半宽, y: 下y))
            图.壳体.addLine(to: CGPoint(x: cx + 半宽, y: 下y))
            // 柱心那条亮线 = 灯管本体
            图.发光.move(to: CGPoint(x: cx, y: 上y))
            图.发光.addLine(to: CGPoint(x: cx, y: 下y))
            灯箭头(&图.壳体, x: cx + 半宽 * 3.2, 从: 上y, 到: h * 0.92, 头宽: w * 0.08)

        default:
            return nil
        }
        return 图
    }


    /// 出光箭头：一条竖线加一个 V 形箭头，指向光去的方向
    private func 灯箭头(_ p: inout Path, x: CGFloat, 从 y0: CGFloat, 到 y1: CGFloat, 头宽: CGFloat) {
        guard y1 > y0 else { return }
        p.move(to: CGPoint(x: x, y: y0))
        p.addLine(to: CGPoint(x: x, y: y1))
        p.move(to: CGPoint(x: x - 头宽, y: y1 - 头宽 * 1.1))
        p.addLine(to: CGPoint(x: x, y: y1))
        p.addLine(to: CGPoint(x: x + 头宽, y: y1 - 头宽 * 1.1))
    }
}


// MARK: - 摄像机取景（视口级唯一，不做场景对象）

/// 摄像机画幅比例。
///
/// 摄像机只有一台、只作为视口的一个状态存在：不进场景、不上大纲、没有可拖的实体，
/// 所以这里只是「视口怎么画框」的参数，不是物体属性。
enum 取景比例: String, CaseIterable, Identifiable {
    case 宽16比9
    case 宽4比3
    case 方1比1
    case 竖9比16
    case 宽2点35比1
    case 宽3比2

    var id: String { rawValue }

    /// 宽 / 高
    var 值: CGFloat {
        switch self {
        case .宽16比9: return 16.0 / 9.0
        case .宽4比3: return 4.0 / 3.0
        case .方1比1: return 1.0
        case .竖9比16: return 9.0 / 16.0
        case .宽2点35比1: return 2.35
        case .宽3比2: return 3.0 / 2.0
        }
    }

    /// 按钮下标 / 角标用的小字
    var 短标: String {
        switch self {
        case .宽16比9: return "16:9"
        case .宽4比3: return "4:3"
        case .方1比1: return "1:1"
        case .竖9比16: return "9:16"
        case .宽2点35比1: return "2.35:1"
        case .宽3比2: return "3:2"
        }
    }

    var 说明: String {
        switch self {
        case .宽16比9: return "横屏"
        case .宽4比3: return "经典"
        case .方1比1: return "方图"
        case .竖9比16: return "竖屏"
        case .宽2点35比1: return "宽银幕"
        case .宽3比2: return "相机"
        }
    }
}

/// 取景框层：框外压暗 + 三分线 + 四角直角标记，纯绘制，不接任何事件。
///
/// 只影响视口观感，不改渲染与相机；将来「渲染出图」需要按同一画幅裁剪时，
/// 直接读这里的 `比例` 就行，不用去场景里找摄像机对象。
struct 摄像机取景层: View {
    let 比例: 取景比例
    /// 框离视口内沿的留白：留一点，框线不贴着窗口边
    var 内缩: CGFloat = 16

    var body: some View {
        GeometryReader { proxy in
            let 框 = 取景框(在: proxy.size)

            Canvas { 上下文, 尺寸 in
                // 框外压暗：四块矩形拼，比挖洞省事也不会漏边
                var 遮罩 = Path()
                遮罩.addRect(CGRect(x: 0, y: 0, width: 尺寸.width, height: max(0, 框.minY)))
                遮罩.addRect(CGRect(x: 0, y: 框.maxY, width: 尺寸.width, height: max(0, 尺寸.height - 框.maxY)))
                遮罩.addRect(CGRect(x: 0, y: 框.minY, width: max(0, 框.minX), height: 框.height))
                遮罩.addRect(CGRect(x: 框.maxX, y: 框.minY, width: max(0, 尺寸.width - 框.maxX), height: 框.height))
                上下文.fill(遮罩, with: .color(.black.opacity(0.55)))

                // 三分线：构图参考，压得很淡，不抢画面
                var 三分 = Path()
                for i in 1...2 {
                    let x = 框.minX + 框.width * CGFloat(i) / 3.0
                    let y = 框.minY + 框.height * CGFloat(i) / 3.0
                    三分.move(to: CGPoint(x: x, y: 框.minY))
                    三分.addLine(to: CGPoint(x: x, y: 框.maxY))
                    三分.move(to: CGPoint(x: 框.minX, y: y))
                    三分.addLine(to: CGPoint(x: 框.maxX, y: y))
                }
                上下文.stroke(三分, with: .color(.white.opacity(0.16)), lineWidth: 0.75)

                // 框线
                上下文.stroke(Path(框), with: .color(.white.opacity(0.85)), lineWidth: 1)

                // 四角直角标记：取景器的手感全在这四笔
                let 角长: CGFloat = 14
                var 角线 = Path()
                角线.move(to: CGPoint(x: 框.minX, y: 框.minY + 角长))
                角线.addLine(to: CGPoint(x: 框.minX, y: 框.minY))
                角线.addLine(to: CGPoint(x: 框.minX + 角长, y: 框.minY))

                角线.move(to: CGPoint(x: 框.maxX - 角长, y: 框.minY))
                角线.addLine(to: CGPoint(x: 框.maxX, y: 框.minY))
                角线.addLine(to: CGPoint(x: 框.maxX, y: 框.minY + 角长))

                角线.move(to: CGPoint(x: 框.maxX, y: 框.maxY - 角长))
                角线.addLine(to: CGPoint(x: 框.maxX, y: 框.maxY))
                角线.addLine(to: CGPoint(x: 框.maxX - 角长, y: 框.maxY))

                角线.move(to: CGPoint(x: 框.minX + 角长, y: 框.maxY))
                角线.addLine(to: CGPoint(x: 框.minX, y: 框.maxY))
                角线.addLine(to: CGPoint(x: 框.minX, y: 框.maxY - 角长))

                上下文.stroke(角线, with: .color(.white.opacity(0.95)), lineWidth: 2)
            }
            .overlay(alignment: .topLeading) {
                Text("摄像机 · \(比例.短标)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.35), in: Capsule())
                    .offset(x: 框.minX + 10, y: 框.minY + 10)
            }
        }
        .allowsHitTesting(false)
    }

    /// 按画幅适配到视口里：先按宽度铺满，太高就改成按高度铺满，永远不越界
    private func 取景框(在 尺寸: CGSize) -> CGRect {
        let 可用宽 = max(1, 尺寸.width - 内缩 * 2)
        let 可用高 = max(1, 尺寸.height - 内缩 * 2)
        var 宽 = 可用宽
        var 高 = 可用宽 / 比例.值
        if 高 > 可用高 {
            高 = 可用高
            宽 = 可用高 * 比例.值
        }
        return CGRect(x: (尺寸.width - 宽) / 2, y: (尺寸.height - 高) / 2, width: 宽, height: 高)
    }
}

// MARK: - 视口左右竖向工具条

/// 竖排图标按钮：宽高压死，图标不会把条挤粗
private struct 侧栏图标按钮: View {
    let 图标: String
    let 提示: String
    var 高亮 = false
    let 动作: () -> Void

    var body: some View {
        Button(action: 动作) {
            Image(systemName: 图标)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(高亮 ? Color.accentColor : Color.primary.opacity(0.85))
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(提示)
    }
}

/// 左侧工具条：先把图标摆出来（现阶段接的是已有动作：取消选择 / 聚焦 / 显隐）
struct 左侧工具条: View {
    var 取消选择: () -> Void
    var 聚焦选中: () -> Void
    var 隐藏选中: () -> Void
    var 显示全部: () -> Void

    var body: some View {
        VStack(spacing: 1) {
            侧栏图标按钮(图标: "cursorarrow", 提示: "取消选择（Esc）", 动作: 取消选择)

            Rectangle()
                .fill(Theme.stroke)
                .frame(width: 16, height: 1)
                .padding(.vertical, 2)

            侧栏图标按钮(图标: "scope", 提示: "聚焦选中（F）", 动作: 聚焦选中)
            侧栏图标按钮(图标: "eye.slash", 提示: "隐藏选中（H）", 动作: 隐藏选中)
            侧栏图标按钮(图标: "eye", 提示: "显示全部（⌥H）", 动作: 显示全部)
        }
        .padding(3)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(Theme.stroke, lineWidth: 1)
        )
    }
}

/// 右侧工具条：第一个是摄像机。
///
/// 摄像机不是场景对象 —— 全局就这一台，按下只是让视口进入取景状态；
/// 按钮底下那行小字（16:9 之类）是画幅下标，点它换比例。
struct 右侧工具条: View {
    @Binding var 摄像机: Bool
    @Binding var 比例: 取景比例
    var 注: (String) -> Void = { _ in }

    @State private var 显示比例菜单 = false

    var body: some View {
        VStack(spacing: 1) {
            Button {
                摄像机.toggle()
                注(摄像机 ? "摄像机：取景框已开（\(比例.短标)）" : "摄像机：关闭")
            } label: {
                Image(systemName: 摄像机 ? "camera.viewfinder" : "camera")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(摄像机 ? Color.accentColor : Color.primary.opacity(0.85))
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("摄像机取景（点下方小字换画幅）")

            Button {
                显示比例菜单 = true
            } label: {
                HStack(spacing: 1) {
                    Text(比例.短标)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 6, weight: .bold))
                }
                .font(.system(size: 7, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("摄像机画幅比例")
            .popover(isPresented: $显示比例菜单, arrowEdge: .leading) {
                比例菜单
            }
        }
        .padding(3)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(Theme.stroke, lineWidth: 1)
        )
    }

    private var 比例菜单: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("摄像机画幅")
                .font(.system(size: 11, weight: .semibold))

            ForEach(取景比例.allCases) { 项 in
                Button {
                    比例 = 项
                    摄像机 = true
                    显示比例菜单 = false
                    注("摄像机画幅：\(项.短标)")
                } label: {
                    HStack(spacing: 6) {
                        Text(项.短标)
                            .font(.system(size: 11, design: .monospaced))
                        Text(项.说明)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 10)
                        if 项 == 比例 {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                        }
                    }
                    .frame(width: 118, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
    }
}
