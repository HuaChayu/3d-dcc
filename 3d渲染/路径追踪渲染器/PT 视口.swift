import Foundation
import MetalKit
import SwiftUI
import simd

// MARK: - SwiftUI 封装

/// 路径追踪视口的 SwiftUI 外壳。
/// 关键约束：这一层不参与命中测试（外层加 allowsHitTesting(false)），
/// 鼠标事件继续落到下面的 RealityView，轨道/缩放/点选手感完全不用重写。
struct PathTraceViewport: View {
    var objects: [SceneObject]
    var materials: [UUID: MaterialAsset]
    var settings: ViewportSettings
    var cameraProvider: () -> PTCamera?

    @State private var samples: UInt32 = 0

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            PathTraceMetalView(
                objects: objects,
                materials: materials,
                settings: settings,
                cameraProvider: cameraProvider,
                onSamples: { samples = $0 }
            )

            HStack(spacing: 6) {
                Circle()
                    .fill(samples >= UInt32(max(settings.ptMaxSamples, 1)) ? Color.green : Color.orange)
                    .frame(width: 6, height: 6)
                Text(samplesText)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.black.opacity(0.45), in: Capsule())
            .padding(10)
        }
        .background(Color.black)
    }

    private var samplesText: String {
        // 降噪恒开（OIDN），角标只报累积进度
        let mode = "降噪·OIDN"
        if samples == 0 { return "路径追踪 · 预热中" }
        if samples >= UInt32(max(settings.ptMaxSamples, 1)) { return "路径追踪 · \(samples) spp · 已收敛 · \(mode)" }
        return "路径追踪 · \(samples) spp · \(mode)"
    }
}

// MARK: - MTKView 桥接

private struct PathTraceMetalView: NSViewRepresentable {

    var objects: [SceneObject]
    var materials: [UUID: MaterialAsset]
    var settings: ViewportSettings
    var cameraProvider: () -> PTCamera?
    var onSamples: (UInt32) -> Void

    final class Coordinator {
        var renderer: PTPathTracer?
        var objects: [SceneObject] = []
        var materials: [UUID: MaterialAsset] = [:]
        var sceneSettings = ViewportSettings.default
        var cameraProvider: (() -> PTCamera?)?
        var onSamples: ((UInt32) -> Void)?

        // MARK: 场景转译缓存

        /// 这一层以前每帧都跑一遍 PTTranslator.build：材质节点图求值 + 逐顶点矩阵变换
        /// + 地面重造 + 灯光 CDF + 签名哈希，全在渲染回调里做。相机一动就是每帧白烧。
        /// 现在按"输入内容是否真的变了"判断，没变就复用上一份编译好的场景。
        /// 锁是必须的：渲染回调在 MetalKit 的 display link 线程，SwiftUI 的 updateNSView 在主线程。
        private let 锁 = NSLock()
        private var 缓存场景 = PTScene()
        private var 缓存对象: [SceneObject] = []
        /// 材质只记版本，不再存一份材质字典副本：要不要重建问材质域，不自己逐字段比对
        private var 缓存材质版本: UInt64 = 0
        private var 当前材质版本: UInt64 = 0
        private var 缓存设置: ViewportSettings?
        private var 已构建 = false
        /// 上一次编译场景时用的绘画快照版本。
        /// 【必须进缓存 key】objects/materials/settings 三样在落笔时一点都没变，
        /// 所以「只比这三样」的缓存会永远命中，返回那份 slice 表全是 0xFFFFFFFF 的旧场景：
        ///   · PT 渲染器发现快照 revision 比场景新，会再要一份场景重译 —— 而 取场景 又把同一份旧场景还回去；
        ///   · 每帧的 更新切片 再把这份旧表 memcpy 回 GPU 的 sliceBuffer，把刚画出来的笔迹编号抹掉。
        /// 结果就是「怎么画都看不到，切一次模式（重建 Coordinator 强制重译）才出现」。
        private var 缓存绘画rev = -1
        /// 上次编译场景时的「体积模拟场登记版本」。
        ///
        /// 【必须进缓存 key】模拟场出不出现由视口粒子渲染器决定，跟 objects / 材质 / 设置 / 绘画
        /// 四样完全无关：PT 先画出第一帧（此时登记表还是空的，发射器 模拟.z == 0 → 走解析场），
        /// 之后就永远命中缓存，那份"解析球"场景再也换不掉 —— 用户看到的就是"PT 出图一直是球"。
        private var 缓存体积版本: UInt64 = .max
        /// 上次编译时的拖动状态（拖动结束要重译一次换全档贴图）
        private var 上次拖动 = false

        /// 这一次要不要因为"拖动状态变化"而重译。
        ///
        /// 只有「上次建场景时左键正按着、现在松开」才需要 —— 那一份可能吃到了拖动期的降档贴图，
        /// 松手补一次全档即可。反方向（刚按下进入拖动）**不重译**：
        /// 拖节点位置、拖材质球都不改材质外观，重译就是白建一次加速结构 + 累积清零，
        /// 表现正是「拖着节点，视口却从 1spp 重新开始算」。
        private var 补档需要重译: Bool { !(上次拖动 && !视口纹理库.拖动中) }

        /// 主线程：灌入 SwiftUI 侧的最新输入
        func 更新输入(objects: [SceneObject],
                   materials: [UUID: MaterialAsset],
                   settings: ViewportSettings,
                   cameraProvider: (() -> PTCamera?)?,
                   onSamples: ((UInt32) -> Void)?) {
            锁.lock()
            defer { 锁.unlock() }
            self.objects = objects
            self.materials = materials
            self.sceneSettings = settings
            self.cameraProvider = cameraProvider
            self.onSamples = onSamples
        }

        /// 渲染线程：取当前相机（闭包出锁再调，闭包内部会读 ViewportScene）
        func 取相机() -> PTCamera? {
            锁.lock()
            let provider = cameraProvider
            锁.unlock()
            return provider?()
        }

        /// 渲染线程：上报累积进度（出锁再调，避免把 SwiftUI 重绘拖进临界区）
        func 发样本(_ count: UInt32) {
            锁.lock()
            let 回调 = onSamples
            锁.unlock()
            回调?(count)
        }

        /// 把三个环境字段抹成固定值，用来判断"除了环境以外还有没有别的设置变了"。
        /// 这样不用逐个字段列白名单，将来 ViewportSettings 加字段也不会漏判。
        private func 归一化环境(_ 设置: ViewportSettings) -> ViewportSettings {
            var 副本 = 设置
            副本.environment = .studio
            副本.environmentIntensity = 1
            副本.environmentRotation = 0
            return 副本
        }

        /// 渲染线程：命中缓存就复用，输入变了才重新编译场景
        func 取场景() -> PTScene {
            锁.lock()
            defer { 锁.unlock() }
            // 绘画快照也是场景的一部分（slice 表 + hasPaint），必须一起参与缓存判定
            let 绘画rev = PaintGPUSnapshot.shared.读().revision
            // 材质变了没有 = 材质域版本说了算（被引用材质的聚合版本），这层不再自己拼签名/比字段
            当前材质版本 = 材质接线.共享.场景材质版本(Array(materials.keys))
            // 【只改环境：原地替换，不重译整场景】拖摄影棚亮度 / 环境旋转时，几何、材质、
            // 灯、绘画表一个字节都没变，重译整个场景是纯浪费（大场景每帧几十毫秒，
            // 拖滑杆会一顿一顿）。判据：把三个环境字段归一化成固定值后，其余设置必须完全相等
            // —— 这样将来 ViewportSettings 加字段也自动覆盖，不会漏判；
            // 另外要求环境预设本身未变：预设会牵动地面材质反照率，那条路必须走整场景重译。
            if 已构建,
               缓存对象 == objects,
               缓存材质版本 == 当前材质版本,
               缓存绘画rev == 绘画rev,
               缓存体积版本 == 体积场登记.版本,
               补档需要重译,
               let 旧设置 = 缓存设置,
               旧设置 != sceneSettings,
               旧设置.environment == sceneSettings.environment,
               归一化环境(旧设置) == 归一化环境(sceneSettings) {
                缓存场景 = PTTranslator.替换环境(缓存场景, settings: sceneSettings)
                缓存设置 = sceneSettings
                return 缓存场景
            }
            if 已构建,
               缓存设置 == sceneSettings,
               缓存对象 == objects,
               缓存材质版本 == 当前材质版本,
               缓存绘画rev == 绘画rev,
               缓存体积版本 == 体积场登记.版本,
               补档需要重译 {
                return 缓存场景
            }
            if 已构建 { 诊断场景差异() }
            let 新场景 = PTTranslator.build(objects: objects, materials: materials, settings: sceneSettings)
            缓存场景 = 新场景
            缓存对象 = objects
            缓存材质版本 = 当前材质版本
            缓存设置 = sceneSettings
            缓存绘画rev = 绘画rev
            缓存体积版本 = 体积场登记.版本
            // 拖动期派生图只有半档分辨率，松手那一帧要重取一次把全档换上来
            上次拖动 = 视口纹理库.拖动中
            已构建 = true
            return 新场景
        }

        /// 临时诊断：缓存没命中时，把到底哪个对象、哪个字段变了打到日志里。
        /// 场景签名每帧抖动会让 PT 每帧重建加速结构 + 清零累积，画面永远停在 1spp 灰雾，
        /// 所以必须先查清差异来源。限流 6 次，查完就删。
        private var 诊断次数 = 0

        private func 诊断场景差异() {
            guard 诊断次数 < 6 else { return }
            诊断次数 += 1
            if 缓存设置 != sceneSettings { NSLog("PTDBG 差异 设置变了 \(String(describing: 缓存设置)) → \(String(describing: sceneSettings))") }
            if 缓存材质版本 != 当前材质版本 { NSLog("PTDBG 差异 材质版本 \(缓存材质版本) → \(当前材质版本)（材质数 \(materials.count)）") }
            if 缓存对象.count != objects.count {
                NSLog("PTDBG 差异 对象数 \(缓存对象.count) → \(objects.count)")
                return
            }
            for index in 缓存对象.indices {
                let a = 缓存对象[index]
                let b = objects[index]
                if a == b { continue }
                var 字段: [String] = []
                if a.id != b.id { 字段.append("id(\(a.id.uuidString.prefix(8)))→\(b.id.uuidString.prefix(8))") }
                if a.name != b.name { 字段.append("name(\(a.name)→\(b.name))") }
                if a.mesh != b.mesh { 字段.append("mesh") }
                if a.position != b.position {
                    字段.append(String(format: "pos(%.9f,%.9f,%.9f)→(%.9f,%.9f,%.9f)",
                                       a.position.x, a.position.y, a.position.z,
                                       b.position.x, b.position.y, b.position.z))
                }
                if a.rotation != b.rotation {
                    字段.append(String(format: "rot(%.9f,%.9f,%.9f)→(%.9f,%.9f,%.9f)",
                                       a.rotation.x, a.rotation.y, a.rotation.z,
                                       b.rotation.x, b.rotation.y, b.rotation.z))
                }
                if a.scale != b.scale {
                    字段.append(String(format: "scale(%.9f,%.9f,%.9f)→(%.9f,%.9f,%.9f)",
                                       a.scale.x, a.scale.y, a.scale.z,
                                       b.scale.x, b.scale.y, b.scale.z))
                }
                if a.materialID != b.materialID { 字段.append("materialID") }
                if a.isVisible != b.isVisible { 字段.append("isVisible(\(a.isVisible)→\(b.isVisible))") }
                NSLog("PTDBG 差异 #\(index) \(a.name) 字段=\(字段.isEmpty ? "无(仅顺序/未列出项)" : 字段.joined(separator: " "))")
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MTKView {
        let view = PassThroughMetalView()
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false          // 色彩映射要往 drawable 上写
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        view.preferredFramesPerSecond = 60
        // 【AIMD 目标帧间隔】把视口刷新率登记给仲裁器，作为"视口帧节奏有没有被出图挤掉"的基准
        // （目标帧间隔 = 1/fps，出图按实测帧间隔 P95 > 目标×1.15 判断是否该退让）。
        // 以后若把这里改成按显示器刷新率自适应（ProMotion 120 Hz 等），AIMD 会自动跟着走。
        PT并发仲裁.shared.设置目标帧率(view.preferredFramesPerSecond)
        view.enableSetNeedsDisplay = false
        // 【不再暂停首帧】以前这里靠 isPaused = true 憋到 updateNSView 灌进 objects 才开跑，
        // 代价是"没有几何的工程/场景暂时变空"时视图永久定住：唤醒只认 objects 数组变化，
        // 转相机、改参数一律叫不醒（同类缺陷，见 PT 渲染器 draw 里空场景那段注释）。
        // 现在空场景由渲染器自己跳过帧并按 30 帧阈值降到 10fps（保留回调），
        // 所以挂上去直接开跑是安全的：空场景最多停留到下一次 updateNSView，通常同一次布局内。
        view.autoResizeDrawable = true

        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let renderer = PTPathTracer(device: device, queue: queue)
        else {
            return view
        }

        view.device = device
        view.delegate = renderer

        let coordinator = context.coordinator
        coordinator.renderer = renderer
        coordinator.更新输入(objects: [],
                       materials: [:],
                       settings: settings,
                       cameraProvider: cameraProvider,
                       onSamples: onSamples)
        // 先把曝光/降噪档位灌进去，再 attach：attach 之后 draw 就会按 ~60fps 跑，
        // 所以 settings 必须在挂代理之前就是有效值（否则前几帧会拿默认档位出图）。
        // 注意：视图现在不靠"暂停"来避免首帧空跑，空场景由渲染器跳过帧并按阈值降频。
        renderer.settings = PathTraceSettings.from(viewport: settings)
        renderer.attach(view)

        renderer.cameraProvider = { [weak coordinator] in coordinator?.取相机() }
        renderer.sceneProvider = { [weak coordinator] in
            guard let coordinator else { return PTScene() }
            return coordinator.取场景()
        }
        renderer.onSampleUpdate = { [weak coordinator] count in
            coordinator?.发样本(count)
        }
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        let coordinator = context.coordinator
        // 走带锁的入口：渲染线程每帧都在读这批输入，直接赋值会和它撞数据竞争
        coordinator.更新输入(objects: objects,
                       materials: materials,
                       settings: settings,
                       cameraProvider: cameraProvider,
                       onSamples: onSamples)

        guard let renderer = coordinator.renderer else { return }

        // 曝光 + 降噪档位必须整体同步：这里以前只抄 exposure，
        // 降噪开关/档位永远停在默认值，等于降噪链路一次都没真正打开过。
        // renderer.settings 的 didSet 会自己 restart，不用在外面再补一次。
        let next = PathTraceSettings.from(viewport: settings)
        if renderer.settings != next {
            renderer.settings = next
        }

        // 【兜底唤醒】现在唯一的暂停来源是"出图期间把 GPU 让给离屏渲染"（PT视口登记 暂停/恢复），
        // 它的恢复由出图会话结束信号确定性触发。这里再兜一层：SwiftUI 一更新而视图仍是暂停态、
        // 且不是出图在占用，就无条件叫醒。不再要求 objects 非空 —— 没有几何的工程也该能看到
        // 环境背景，"空场景"绝不能变成"视图定死"的借口（本轮修的就是这类"暂停等外部事件"缺陷）。
        if view.isPaused, !PT视口登记.shared.出图中 {
            renderer.restart()
        }
    }
}

// MARK: - 事件穿透

/// MTKView 会在 AppKit 层把自己算进 hitTest 命中链，
/// 即使 SwiftUI 外面套了 allowsHitTesting(false)，拖动/滚轮照样被它吞掉。
/// 这层是纯展示的，直接把命中测试返回 nil，让事件落到下面的 RealityView。
final class PassThroughMetalView: MTKView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { false }
}
