import SwiftUI
import MetalKit
import simd

// MARK: - 粒子视口层
//
// 位置：盖在 RealityView（和 PT overlay）之上，只做展示、不吃事件。
//
// 为什么不用 RealityKit 粒子系统：
// - 10 万级粒子要的是"一次 draw、GPU 内积分"，RK 的粒子组件按实体粒度管理，撑不住这个量；
// - 球 impostor 的深度要跟视口一致、要能跟物体碰撞，链路必须自己掌握。
//
// 为什么用独立 MTKView 而不是往 RK 场景里塞：
// - 跟 PT 视口同一套做法（见 PT 视口.swift）：独立画布、独立节奏、互不影响；
// - 代价是它拿不到 RealityKit 的深度/法线，所以粒子对场景物体是「按球近似遮挡」
//   （见 粒子 着色器.metal 的碰撞球分支）。真正逐像素被遮挡要等 RK 深度回读，留作下一步。

struct 粒子视口层: NSViewRepresentable {

    var objects: [SceneObject]
    var 物理域: 物理域
    var cameraProvider: () -> PTCamera?

    /// 烘焙好的这一帧（主线程取好传进来）。nil = 没烘过，照旧实时积分。
    /// 传值而不是传闭包：渲染线程不许碰域，数据必须在主线程就摘干净。
    var 回放: [UUID: 烘焙发射器帧]? = nil

    /// 碰撞球上限：与着色器里的 48 对齐（改这里就要改 metal）
    static let 碰撞球上限 = 48

    @inline(__always)
    private static func 取xyz(_ v: SIMD4<Float>) -> SIMD3<Float> { SIMD3<Float>(v.x, v.y, v.z) }

    func makeCoordinator() -> 协调器 { 协调器() }

    func makeNSView(context: Context) -> MTKView {
        // 【为什么 device 必须在建 view 时就传】MTKView 的 drawable 来自它自己的 CAMetalLayer，
        // device 为 nil 时 currentDrawable / currentRenderPassDescriptor 恒为 nil，
        // draw 每帧都在第一个 guard 处早退 —— 表现就是"视口有底图，
        // 但粒子与体积火一帧都没画过"（底层 RealityView 照常显示，所以看不出异常）。
        guard let device = MTLCreateSystemDefaultDevice() else {
            let view = PassThroughMetalView()
            view.isPaused = true
            return view
        }
        let view = PassThroughMetalView(frame: .zero, device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false
        // 透明清屏：这一层只画粒子，底下的 RealityView / PT 必须透上来
        view.clearColor = MTLClearColorMake(0, 0, 0, 0)
        view.depthStencilPixelFormat = .depth32Float
        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay = false
        view.autoResizeDrawable = true
        view.layer?.isOpaque = false
        view.layer?.backgroundColor = .clear

        guard let queue = device.makeCommandQueue(),
              let 渲染器 = 粒子渲染器(device: device,
                                   queue: queue,
                                   像素格式: view.colorPixelFormat,
                                   深度格式: view.depthStencilPixelFormat)
        else {
            // 拿不到设备就把这一层停掉，让上层画面照旧能用（粒子只是叠加层，不该拖垮视口）
            view.isPaused = true
            return view
        }

        渲染器.相机取 = cameraProvider
        context.coordinator.渲染器 = 渲染器
        view.delegate = 渲染器
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        guard let 渲染器 = context.coordinator.渲染器 else { return }
        渲染器.相机取 = cameraProvider

        // 主线程收集：世界矩阵要写通读数据层（变换接线），渲染线程不许碰域，这里算好再交出去
        let 快照 = Self.收集快照(objects)
        渲染器.更新输入(.init(发射器: 快照.发射器,
                              碰撞球: 快照.球,
                              物理域: 物理域,
                              相机: nil,
                              帧: 时间轴域.共享.当前帧,
                              帧率: 时间轴域.共享.帧率,
                              回放: 回放))
    }

    /// 对象在自身局部空间里的尺度：(包围球顶高度, 包围球半径)。
    /// 体积火/烟要"从对象上冒"，就必须知道这东西多大、顶在哪；
    /// 以前只拿对象矩阵（原点=几何中心），所以火是从中心往外长的。
    /// 导入网格读真包围球；程序网格（立方体/球/平面等）没有包围球，按单位网格近似。
    static func 对象局部尺度(_ 物: SceneObject) -> (顶部: Float, 半径: Float) {
        if let 网格 = 物.导入网格ID, let 包 = 几何接线.共享.局部包围球(网格) {
            let 半径 = max(0.02, 包.半径)
            return (包.中心.y + 半径, 半径)
        }
        let 半径: Float = 0.8
        return (半径, 半径)
    }

    /// 场景 → GPU 输入的翻译层。
    ///
    /// **烘焙域也调这一个**：离线烘焙与实时渲染必须从同一份翻译里取世界矩阵，
    /// 否则同一个发射器两边算出不同结果，「烘出来的和看到的不一样」就成了玄学。
    static func 收集快照(_ objects: [SceneObject]) -> (发射器: [粒子发射器快照], 球: [SIMD4<Float>]) {
        var 发射器: [粒子发射器快照] = []
        var 球: [SIMD4<Float>] = []

        for 物 in objects where 物.isVisible {
            if let 设置 = 物.特效 {
                // 关掉的发射器不进快照：池会被回收，参数照样留在对象上
                guard 设置.启用 else { continue }
                // 发射体：设置里指了别的物体就吃那个物体的几何与世界矩阵；
                // 没指（旧工程 / 默认）就是自己。特效挂在空发射器上时，
                // 靠这一行把它"贴"到用户真正想烧的那坨几何上。
                let 宿主 = 设置.发射体对象ID.flatMap { id in
                    objects.first { $0.id == id && $0.isVisible }
                } ?? 物
                // 容器：里面有启用源就吃「容器自身矩阵 + 合并几何」——
                // 源只是发射体，不进场景、不进视口，所以这是"看不见的发射体"。
                // 没有源时 容器几何 为 nil，完整回到老口径，旧工程外观不变。
                let 容器几何 = 特效几何库.组合几何(设置)
                let 世界 = 容器几何 != nil ? 拾取几何.世界矩阵(物) : 拾取几何.世界矩阵(宿主)
                let 尺度 = 容器几何.map { 特效几何库.尺度($0) } ?? 对象局部尺度(宿主)
                // 体积类要"从这坨几何上冒"，就得把它的三角形一起带过去。
                // 取用有缓存（程序网格按形状、导入网格按内容版本），每帧只是查表。
                let 几何 = 容器几何 ?? (设置.走体积 ? 对象几何库.取(宿主) : nil)
                发射器.append(粒子发射器快照(id: 物.id, 设置: 设置, 世界: 世界,
                                       对象顶部: 尺度.顶部, 对象半径: 尺度.半径, 几何: 几何))
                continue
            }
            // 灯不构成障碍（本来也没有体积），角色整体太复杂，都不进碰撞球
            if 物.灯光 != nil || 物.角色 != nil { continue }
            guard 球.count < 碰撞球上限 else { continue }

            let 世界 = 拾取几何.世界矩阵(物)
            let 缩放 = max(simd_length(取xyz(世界.columns.0)),
                          simd_length(取xyz(世界.columns.1)),
                          simd_length(取xyz(世界.columns.2)))
            // 导入网格用真包围球；程序网格没有包围球，取单位网格的近似半径 0.8
            var 局部中心 = SIMD3<Float>(0, 0, 0)
            var 局部半径: Float = 0.8
            if let 网格 = 物.导入网格ID,
               let 包 = 几何接线.共享.局部包围球(网格) {
                局部中心 = 包.中心
                局部半径 = max(0.02, 包.半径)
            }
            let 中心 = 取xyz(世界 * SIMD4<Float>(局部中心, 1))
            球.append(SIMD4<Float>(中心, max(0.01, 局部半径 * 缩放)))
        }

        return (发射器, 球)
    }

    // MARK: 协调器

    final class 协调器 {
        var 渲染器: 粒子渲染器?
    }
}
