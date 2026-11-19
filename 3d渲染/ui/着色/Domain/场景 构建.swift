import AppKit
import Metal
import CoreGraphics
import RealityKit
import SwiftUI

// MARK: - 场景构建

enum SceneBuilder {

    // MARK: 物体标识

    private static let objectNamePrefix = "object:"

    static func objectNodeName(for id: UUID) -> String {
        "\(objectNamePrefix)\(id.uuidString)"
    }

    static func objectID(fromNodeName name: String?) -> UUID? {
        guard let name, name.hasPrefix(objectNamePrefix) else { return nil }
        return UUID(uuidString: String(name.dropFirst(objectNamePrefix.count)))
    }

    // MARK: 环境

    /// 程序化 equirect 环境板：垂直渐变 + 主光亮斑，用来给 PBR 提供正确的反射梯度
    static func environmentImage(_ environment: StudioEnvironment) -> CGImage? {
        let width = 1024
        let height = 512
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }

        let top = environment.skyTop.nsColor
        let bottom = environment.skyBottom.nsColor
        let colors = [top.cgColor, bottom.cgColor] as CFArray
        if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: height),
                end: CGPoint(x: 0, y: 0),
                options: []
            )
        }

        // 主光亮斑
        let light = environment.keyLight
        let cx = CGFloat(light.azimuth / 360.0) * CGFloat(width)
        let cy = CGFloat((90 - light.elevation) / 180.0) * CGFloat(height)
        let radius = environment == .overcast ? CGFloat(width) * 0.32 : CGFloat(width) * 0.11
        let hot = NSColor(srgbRed: 1, green: 0.98, blue: 0.94, alpha: 1)
        let edge = NSColor(srgbRed: 1, green: 0.98, blue: 0.94, alpha: 0)

        if let spot = CGGradient(
            colorsSpace: space,
            colors: [hot.cgColor, edge.cgColor] as CFArray,
            locations: [0, 1]
        ) {
            context.saveGState()
            context.setBlendMode(.plusLighter)
            context.drawRadialGradient(
                spot,
                startCenter: CGPoint(x: cx, y: cy), startRadius: 0,
                endCenter: CGPoint(x: cx, y: cy), endRadius: radius,
                options: []
            )
            context.restoreGState()
        }

        return context.makeImage()
    }

    // MARK: 材质球网格

    static func meshSymbol(_ mesh: MeshKind) -> String { mesh.symbol }
}

// MARK: - RealityKit 视口场景

/// 轨道相机机位存档：保存工程时写进快照，重新打开原样还原。
///
/// 只记「怎么看」——方位角 / 仰角 / 距离 / 轨道中心，不碰场景内容。
/// Finder 图标与空格预览用的聚焦机位是另一套离屏渲染，不回写这里。
struct 视口相机存档: Codable, Equatable {
    var 方位角: Double = 0
    var 仰角: Double = 0.17
    var 距离: Double = 6.49
    var 目标点X: Float = 0
    var 目标点Y: Float = 1.0
    var 目标点Z: Float = 0
}

/// RealityKit 常驻实体树：材质/变换走增量更新，相机由 rk.camera 实体 + 轨道参数驱动。
@MainActor
final class ViewportScene {

    private let root = Entity()
    private let objectsRoot = Entity()
    private let lightsRoot = Entity()
    private let cameraTarget = Entity()

    private var objectEntities: [UUID: Entity] = [:]
    /// 最近一次同步的物体数据：精确拾取只认参数化网格，需要位置/旋转/缩放/网格类型
    private var 物体快照: [SceneObject] = []
    private var objectSignature: [String] = []
    /// 每个物体上次套材质时用的「单材质版本」——直接问数据层材质域，视口不再自拼材质签名
    /// 键 = (对象绑定的材质 id, 该材质的单材质版本)。带 id 是因为两个材质版本号可能撞，
    /// 只看版本会在换绑到"版本号恰好相同"的另一个材质时漏掉一次重套。
    private var objectMaterialVersion: [UUID: (材质: UUID?, 版本: UInt64)] = [:]
    /// 上次的外观档位（着色模式 + 深色）：变了整树重套一次，与材质版本无关
    private var 上次外观键 = ""
    /// 姿态脏标记：谁摆了姿势谁就被点一下名，回到同步时只换这一身的部件实体。
    /// 不再靠比对指纹 —— 没动过就是零开销，动一次重建一次。
    private var 待重建姿态: Set<UUID> = []
    private var environmentKey = ""
    private var appliedLookDark: Bool?
    private var gridEntity: Entity?
    /// 轨道距离只有下限（防贴脸/穿透），上界仅是 Double→Float 的数值安全线，不构成业务上限
    static let 最小轨道距离: Double = 0.05
    static let 轨道距离安全上限: Double = 1e9
    private var cameraEntity: Entity?
    /// 轨道相机参数：绕 cameraTarget 环绕
    private var orbitAzimuth: Double = 0
    private var orbitElevation: Double = 0.17
    private var orbitDistance: Double = 6.49
    private var orbitTargetPoint: SIMD3<Float> = [0, 1.0, 0]
    private var groundEntity: Entity?
    private var shadowEntities: [UUID: Entity] = [:]
    private var selectionRingSignature: [UUID: String] = [:]
    private var shadowMesh: MeshResource?
    private var spinTask: Task<Void, Never>?
    private var 对齐任务: Task<Void, Never>?
    private var environmentIntensity: Double = 1
    private var environment: StudioEnvironment = .studio
    /// RealityViewCameraContent 是值类型，这里存一份用来做命中测试（底层场景仍是同一个）
    private var contentRef: RealityViewCameraContent?

    /// 系统相机托管、RealityKit 又不给接口的项：视口里如实标注，别装作支持
    static let 后端限制: [String] = [
        "视野角（系统相机托管）",
        "环境旋转 / 曝光（无公开接口）",
        "方向光阴影贴图（改走接触阴影）"
    ]

    init() {
        root.name = "rk.root"
        objectsRoot.name = "rk.objects"
        cameraTarget.name = "rk.target"
        cameraTarget.position = [0, 0.9, 0]

        root.addChild(objectsRoot)
        root.addChild(lightsRoot)
        root.addChild(cameraTarget)

        setupLights()
        setupCameraEntity()
        setupGround()
        setupGrid()
    }

    // MARK: 同步入口

    func attach(_ content: inout RealityViewCameraContent) {
        // 判重口径：看 root 本身在不在**当前这个** content 里，而不是「挂过一次就跳过」。
        // 这样即使 RealityView 被重建（拿到全新 content），root 也能重新挂进去。
        // 停算（detach）已删除，但这条判重仍是最稳的写法，别改回去。
        // 【历史 · 2026-11-09 之前】当时是为了配合「视图整块摘出视图树」的方案：切回时拿到的是
        // 全新 content，而 contentRef 早就不为 nil，按「挂过一次就跳过」会让 root 永远进不去
        // 新场景，表现为现实模式整屏空白。
        let 已挂载 = content.entities.contains { $0 === root }
        rk诊断("attach 进入 已挂载=\(已挂载) entities=\(content.entities.count) root.parent空=\(root.parent == nil) root子级=\(root.children.count)")
        if !已挂载 {
            // 从旧场景脱离时根节点可能还留着父级，先摘干净再接上，避免重复挂载
            root.removeFromParent()
            content.entities.append(root)
            // 环境资源挂在 content 上、不随实体走：新 content 是干净的默认环境，
            // 清掉键值让下一次 sync 无条件重设一遍 IBL，否则切回来的现实模式没有天空盒/反射。
            environmentKey = ""
            rk诊断("attach 已append entities=\(content.entities.count) root.parent空=\(root.parent == nil) root子级=\(root.children.count)")
            // 250ms 后回看：若这次挂载被 RealityKit 丢掉，root.parent 会重新变空
            let 根 = root
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                rk诊断("attach 0.25s 后 root.parent空=\(根.parent == nil) root子级=\(根.children.count)")
            }
        }
        content.cameraTarget = cameraTarget
        contentRef = content
        rk诊断("attach 完成 entities=\(content.entities.count) 含相机=\(root.children.contains { $0.components[PerspectiveCameraComponent.self] != nil })")
    }

    /// 【已删除 · 2026-11-09】停算 detach() 连同上方的停演开关一起移除。
    /// RealityView 恢复成引入停算之前的形态：常驻视图树、无条件 attach + sync、照常每帧渲染。
    ///
    /// 【留档：原实现】停算时把 root 从「当前这个」content 里 removeFromParent()，并把
    /// content.environment 回 .default、environmentKey 置空。摘的只是场景归属，数据本身
    /// （root / objectsRoot / 实体 / MeshResource / Material）全被 SceneBuilder 强引用着，
    /// GPU 资源随对象引用保留，所以切回时 objectSignature / objectMaterialVersion 能命中缓存，
    /// 只做一次 append + O(n) transform，不重建实体、不重算材质。
    /// 视口侧配套是 `private var 停演现实渲染 = settings.shading == .pathTraced || PT_FORCE == "1"`
    /// 加上 make / update 里的 `if 停演 { scene.detach(&content) } else { attach + sync }`。
    ///
    /// 【删除原因】它省下的是一笔 RK 开销，换回来的是三类偶发问题：
    ///   1) 收敛后不再 present，最后那一帧若是退化的灰雾就被永久冻结在屏上；
    ///   2) 停演期间 sync 整段被跳过，物体快照冻结 → 拾取 / 拖材质读到旧数据；
    ///   3) 切回模式时画面瞬黑。
    /// 回到无条件渲染后，这三类一并消失。
    ///
    /// 【要重新加回来】把 detach 本体贴回本类，视口恢复 if 停演 分支即可。
    /// 千万别用 Group + if + Color.clear 去摘视图：SwiftUI 会真的销毁重建 RealityView，
    /// 同一个 root 跨 scene 搬运时 RealityKit 不解除旧归属，第二次起 append 被静默丢弃 → 永久黑屏。

    func sync(
        objects: [SceneObject],
        materials: [UUID: MaterialAsset],
        settings: ViewportSettings,
        selectedObjectID: UUID? = nil,
        选中集合: Set<UUID> = [],
        content: inout RealityViewCameraContent
    ) {
        syncEnvironment(settings, content: &content)
        syncObjects(objects)
        syncSettings(settings)
        syncContactShadows(objects: objects, settings: settings)
        syncMaterials(objects: objects, materials: materials, settings: settings)
        syncSelection(objects: objects, selectedObjectID: selectedObjectID, 选中集合: 选中集合, settings: settings)
    }

    /// 给路径追踪用的相机快照：直接读轨道相机的真实位置与朝向，
    /// 这样 PT 与 RealityKit 两个模式的构图、视角完全重合，切换不跳。
    func pathTraceCamera() -> PTCamera? {
        guard let camera = cameraEntity else { return nil }
        let origin = camera.position(relativeTo: nil)
        let fov = camera.components[PerspectiveCameraComponent.self]?.fieldOfViewInDegrees ?? 38
        return PTCamera(
            position: origin,
            target: orbitTargetPoint,
            fieldOfViewDegrees: Float(fov)
        )
    }

    /// 命中测试：用自己维护的轨道相机做射线求交，不依赖 content.hitTest。
    /// RealityView 的 hitTest 在自定义相机（PerspectiveCameraComponent + look(at:)）下
    /// 基本拿不到命中，而且它要求坐标系与 SwiftUI 视图严格一致，实测不可靠。
    func pick(at point: CGPoint, viewSize: CGSize) -> UUID? {
        guard let camera = cameraEntity,
              viewSize.width > 1, viewSize.height > 1 else { return nil }

        let origin = camera.position(relativeTo: nil)
        let forward = normalize(orbitTargetPoint - origin)
        var right = cross(forward, SIMD3<Float>(0, 1, 0))
        if length(right) < 0.0001 { right = SIMD3<Float>(1, 0, 0) }
        right = normalize(right)
        let up = normalize(cross(right, forward))

        let fov = camera.components[PerspectiveCameraComponent.self]?.fieldOfViewInDegrees ?? 38
        let tanHalf = tanf(Float(fov) * .pi / 360)
        let aspect = Float(viewSize.width / viewSize.height)
        let ndcX = Float(point.x / viewSize.width) * 2 - 1
        let ndcY = 1 - Float(point.y / viewSize.height) * 2
        let direction = normalize(forward + right * (ndcX * tanHalf * aspect) + up * (ndcY * tanHalf))

        // 精确拾取：按各 MeshKind 的真实网格做射线-三角形求交。
        // 包围球会在相邻物体间互相覆盖（屏幕投影半径可达上百像素），导致点左边却选中右边
        var best: (id: UUID, distance: Float)?
        for object in 物体快照 where object.isVisible {
            guard let 距离 = 拾取几何.命中(object, origin: origin, direction: direction) else { continue }
            if best == nil || 距离 < best!.distance { best = (object.id, 距离) }
        }
        return best?.id
    }

    // MARK: 环境

    private func syncEnvironment(_ settings: ViewportSettings, content: inout RealityViewCameraContent) {
        environment = settings.environment
        if environmentKey != settings.environment.rawValue {
            environmentKey = settings.environment.rawValue
            let 图 = SceneBuilder.environmentImage(settings.environment)
            let 资源 = 图.flatMap { try? EnvironmentResource(equirectangular: $0) }
            if let 资源 { content.environment = .skybox(资源) }
            rk诊断("IBL 重设 env=\(settings.environment.rawValue) 有图=\(图 != nil) 资源成功=\(资源 != nil)")
        }

        var effects = content.renderingEffects
        effects.antialiasing = .multisample4X
        content.renderingEffects = effects

        environmentIntensity = max(settings.environmentIntensity, 0.05)
        updateLightIntensity()
    }

    private func updateLightIntensity() {
        let base = environment.keyLight.intensity
        for light in lightsRoot.children {
            switch light.name {
            case "rk.key":
                var component = light.components[DirectionalLightComponent.self] ?? DirectionalLightComponent()
                component.intensity = Float(base * environmentIntensity)
                light.components.set(component)
            case "rk.rim":
                var component = light.components[PointLightComponent.self] ?? PointLightComponent()
                component.intensity = Float(420 * environmentIntensity)
                light.components.set(component)
            case "rk.fill":
                var component = light.components[PointLightComponent.self] ?? PointLightComponent()
                component.intensity = Float(180 * environmentIntensity)
                light.components.set(component)
            default:
                break
            }
        }
    }

    // MARK: 物体

    private func syncObjects(_ objects: [SceneObject]) {
        // 几何先入域，再算签名：签名里的几何版本号必须是这一次同步之后的值。
        几何接线.共享.同步(几何源取值.从模型(objects))
        物体快照 = objects
        // 签名必须带上几何内容版本：打开工程时物体列表可能和上一份逐字相同
        // （id / mesh / 可见性都没变），只按物体快照判缓存会命中 -> 直接跳过重建，
        // 而网格库是后一步才恢复进池的，于是视口永远挂着上一轮那个 cube 占位实体。
        // 版本号由 导入网格库 在 存入 / 恢复 时递增，几何一变签名必变，重建必然发生。
        // 【几何内容版本接管】mesh / 导入网格 UUID / "同一 UUID 重新烘过" 三件事都由几何域记账：
        // 几何接线写入时推进逐记录版本，这里只把它拼进签名，不再自己读 mesh.rawValue 与网格库版本。
        let signature = objects.map { object -> String in
            // 锥角也要进签名：聚光符号的锥体张角跟着它走，不然改了角度视口不重建
            let 灯键 = object.灯光.map { "L\($0.种类.rawValue)|\($0.宽)|\($0.高)|\($0.半径)|\($0.锥角)|\($0.色温)" } ?? "-"
            return "\(object.id.uuidString)|\(object.isVisible)|\(几何接线.共享.记录版本(键: object.id.uuidString))|\(灯键)"
        }
        if signature != objectSignature {
            objectSignature = signature
            objectEntities.values.forEach { $0.removeFromParent() }
            objectEntities.removeAll()
            objectMaterialVersion.removeAll()
            for object in objects {
                // 灯：视口里只放一个"灯符号"占位（能看见、能点选、能拖），
                // 它不参与路径追踪，所以出图里灯本体不会出现，只有它照出来的光
                let entity = 建实体(object, objects: objects)
                objectsRoot.addChild(entity)
                objectEntities[object.id] = entity
            }
        }

        // 姿态脏了才换实体：谁摆了姿势由 标脏姿态 明确点名，
        // 不在这里每帧比对。没摆过姿势的角色一次都不会进这个循环。
        if !待重建姿态.isEmpty {
            let 脏 = 待重建姿态
            待重建姿态.removeAll()
            for object in objects {
                guard !object.是角色,
                      几何接线.共享.取值(键: object.id.uuidString)?.导入网格标识 ?? object.导入网格ID != nil else { continue }
                guard let 角色ID = object.父?.对象ID, 脏.contains(角色ID) else { continue }
                objectEntities[object.id]?.removeFromParent()
                objectEntities.removeValue(forKey: object.id)
                // 材质版本记录一起清掉：新实体是白板，得让它重新吃一遍材质
                objectMaterialVersion.removeValue(forKey: object.id)
                let entity = 建实体(object, objects: objects)
                objectsRoot.addChild(entity)
                objectEntities[object.id] = entity
            }
        }

        for object in objects {
            guard let entity = objectEntities[object.id] else { continue }
            entity.isEnabled = object.isVisible
            // 【变换唯一所有者】实体定位不再自己解析 position/rotation/scale：
            // 世界矩阵一律向变换域要（域内派生 + 域内缓存），视口 / 拾取 / PT 烘焙读的是同一份。
            // object.position / rotation / scale 是"编辑输入"，不是"世界矩阵的来源"。
            var 位姿 = Transform(matrix: 变换接线.共享.世界矩阵(of: object))
            // 退化缩放（任一轴为 0）：域内按 1 处理（PT 防退化口径），
            // 视口仍按 0 隐藏，否则"缩成 0 的物体"会突然重新出现。这是口径差异，不是容错重建。
            if object.scale.x == 0 || object.scale.y == 0 || object.scale.z == 0 {
                位姿.scale = [0, 0, 0]
            }
            entity.transform = 位姿
        }
    }

    // MARK: 角色姿态

    /// 给某个角色点脏：下一次同步只换这一身的部件实体（别的角色、别的物体一概不动）
    func 标脏姿态(_ 角色ID: UUID) {
        待重建姿态.insert(角色ID)
    }

    /// 单个物体的视口实体。角色部件按当前姿态摆好再生成网格，其余保持原样。
    private func 建实体(_ object: SceneObject, objects: [SceneObject]) -> Entity {
        // 【几何唯一所有者】来源只问几何域：程序网格形状 / 导入网格 UUID 都由几何记录给出。
        // 首次构建时若域里还没有这份几何，按模型回落一次（与 PT 转译同口径）。
        let 几何源 = 几何接线.共享.取值(键: object.id.uuidString)
        let 程序形状 = 几何接线.共享.程序形状(键: object.id.uuidString, 兜底: object.mesh)
        let entity: Entity
        if object.是角色 {
            // 角色是容器资产（骨架本身没有几何）：视口里不画那个占位立方体，
            // 身子由它的部件显示；操作入口是大纲里双击角色行
            entity = Entity()
        } else if let 设置 = object.灯光 {
            entity = SceneBuilder.makeLightEntity(for: 设置)
        } else if let 设置 = object.特效 {
            // 容器在视口里**只画符号**（细管骨架框），不画实体几何：
            // 里面的源是发射体，本身就不该被看见；框有多大，火就从多大一片冒，
            // 位置与形状一眼对得上，不用再去猜"火到底从哪来"。
            entity = SceneBuilder.makeContainerWireEntity(几何: 特效几何库.组合几何(设置))
        } else if let 网格ID = 几何源?.导入网格标识,
                  let 导入实体 = 几何接线.共享.生成实体(
                      网格ID,
                      名称: SceneBuilder.objectNodeName(for: object.id),
                      替身: 摆好姿势的片(object, objects: objects)
                  ) {
            entity = 导入实体
        } else {
            entity = SceneBuilder.makeEntity(for: 程序形状)
        }
        entity.name = SceneBuilder.objectNodeName(for: object.id)
        return entity
    }

    /// 角色部件摆好姿势后的几何。没有姿态（或不是角色部件）返回 nil，直接用池里的静止形状。
    private func 摆好姿势的片(_ object: SceneObject, objects: [SceneObject]) -> [导入网格]? {
        guard let 角色ID = object.父?.对象ID,
              let 主 = objects.first(where: { $0.id == 角色ID }),
              let 角色 = 主.角色,
              角色姿态.有姿态(角色约束求解.姿态(角色)),
              !角色.骨数据.isEmpty,
              let 网格ID = 几何接线.共享.取值(键: object.id.uuidString)?.导入网格标识 ?? object.导入网格ID,
              let 片们 = 几何接线.共享.取(网格ID) else { return nil }
        let 解 = 角色姿态.解算(骨: 角色.骨数据, 姿态: 角色约束求解.姿态(角色))
        return 角色姿态.变形(片们: 片们, 骨: 角色.骨数据, 解: 解)
    }

    /// 部件所属角色的姿态指纹。挂不上角色的部件返回空串，永远只用一次。
    private func 姿态键(_ object: SceneObject, objects: [SceneObject]) -> String {
        guard let 角色ID = object.父?.对象ID,
              let 主 = objects.first(where: { $0.id == 角色ID }),
              let 角色 = 主.角色 else { return "" }
        return 角色姿态.签名(角色.姿态) + "|" + 角色约束求解.签名(角色.约束)
    }

    // MARK: 材质

    private func syncMaterials(objects: [SceneObject], materials: [UUID: MaterialAsset], settings: ViewportSettings) {
        // 外观档位（着色模式 + 深色）变了要整树重套一次；这与材质版本无关
        let lookKey = "\(settings.shading.rawValue)|\(Theme.配色.深色)"
        if lookKey != 上次外观键 {
            上次外观键 = lookKey
            objectMaterialVersion.removeAll()
        }

        // 同一个材质被多个物体引用时，解析结果与签名完全一样：
        // 签名要拼贴图 UUID 串，物体一多就是纯重复的字符串活，这里按材质 id 复用一份。
        var 解析池: [UUID: ResolvedMaterial] = [:]
        // 同一材质被 M 个物体共享时，RK 材质实例也只该造 1 份：
        // 否则改一次滑杆就白造 M 份 anyMaterial（M:N 共享下最容易漏掉的多余重建）。
        var 视口材质池: [UUID: any RealityKit.Material] = [:]
        let 默认键 = UUID()

        for object in objects {
            // 灯只有符号，不吃材质库
            guard object.灯光 == nil else { continue }
            guard let entity = objectEntities[object.id] else { continue }

            // 材质变没变，只问材质域的单材质版本（没挂材质 = 0，固定不变）
            let 材质版本 = (材质: object.materialID,
                           版本: object.materialID.flatMap { 材质接线.共享.版本(资产: $0) } ?? 0)
            if let 上次 = objectMaterialVersion[object.id], 上次 == 材质版本 { continue }
            objectMaterialVersion[object.id] = 材质版本

            let 键 = object.materialID ?? 默认键
            let resolved: ResolvedMaterial
            if let 已解析 = 解析池[键] {
                resolved = 已解析
            } else {
                let value: ResolvedMaterial
                if let materialID = object.materialID, let asset = materials[materialID] {
                    value = MaterialCompiler.resolve(asset)
                } else {
                    var neutral = OpenPBRParams()
                    neutral[.baseColor] = .color(PBRColor(gray: 0.42))
                    neutral[.baseRoughness] = .scalar(0.55)
                    value = ResolvedMaterial(params: neutral, drivenKeys: [], diagnostics: [])
                }
                resolved = value
                解析池[键] = value
            }

            switch settings.shading {
            case .solid:
                SceneBuilder.applyUnlit(SceneBuilder.solidColor, to: entity)
            case .normal:
                // ModelDebugOptionsComponent 在 macOS RealityView 里不生效，
                // 用法线着色器补齐；真拿不到默认 Metal 库时退回调试可视化。
                if let material = SceneBuilder.normalVisualizationMaterial() {
                    SceneBuilder.apply(material, to: entity)
                } else {
                    SceneBuilder.applyDebugMode(.normal, to: entity)
                }
            case .material, .wireframe, .pathTraced:
                // 路径追踪模式由独立的 MTKView 覆盖渲染，这里仍按材质预览同步一份，
                // 保证切走时不出现空白或残留的纯色/法线材质
                let 桥: any RealityKit.Material
                if let 已有 = 视口材质池[键] {
                    桥 = 已有
                } else {
                    let 新造 = RKMaterialBridge.makeViewportMaterial(resolved, shading: settings.shading)
                    视口材质池[键] = 新造
                    桥 = 新造
                }
                SceneBuilder.apply(桥, to: entity)
            }
        }
    }

    // MARK: 视图设置

    private func syncSettings(_ settings: ViewportSettings) {
        gridEntity?.isEnabled = settings.showsGrid
        groundEntity?.isEnabled = settings.showsGround
        updateLook()

        if settings.autoRotate != (spinTask != nil) {
            if settings.autoRotate { startSpin() } else { stopSpin() }
        }
    }

    private func startSpin() {
        spinTask?.cancel()
        spinTask = Task { [weak self] in
            var angle: Float = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16))
                guard let self, !Task.isCancelled else { return }
                angle = (angle + 0.016 * Float.pi * 2 / 18)
                    .truncatingRemainder(dividingBy: .pi * 2)
                self.objectsRoot.orientation = simd_quatf(angle: angle, axis: [0, 1, 0])
            }
        }
    }

    private func stopSpin() {
        spinTask?.cancel()
        spinTask = nil
        objectsRoot.orientation = simd_quatf(angle: 0, axis: [0, 1, 0])
    }

    private func updateLook() {
        let isDark = Theme.配色.深色
        guard appliedLookDark != isDark else { return }
        appliedLookDark = isDark

        if let grid = gridEntity {
            SceneBuilder.apply(
                SceneBuilder.gridMaterial(isDark: isDark),
                to: grid,
                replacing: true
            )
        }
        if let ground = groundEntity {
            SceneBuilder.apply(
                SceneBuilder.groundMaterial(isDark: isDark),
                to: ground,
                replacing: true
            )
        }
    }

    // MARK: 选中

    private func syncSelection(objects: [SceneObject], selectedObjectID: UUID?, 选中集合: Set<UUID>, settings: ViewportSettings) {
        let accent = NSColor(Theme.主色)
        // 多选集合优先；集合为空时退回单个主选中，单选路径行为不变
        let 高亮集: Set<UUID> = 选中集合.isEmpty
            ? (selectedObjectID.map { [$0] } ?? [])
            : 选中集合
        for object in objects {
            guard let entity = objectEntities[object.id] else { continue }
            let wantsRing = 偏好设置Store.shared.视口选中高亮
                && 高亮集.contains(object.id)
                && object.isVisible

            let existing = entity.children.first { $0.name == SceneBuilder.selectionRingName }

            guard wantsRing else {
                existing?.isEnabled = false
                selectionRingSignature[object.id] = nil
                continue
            }

            // 包围盒随变换走：位置/旋转/缩放变了就重建描边，没变只点亮
            let signature = SceneBuilder.transformSignature(object)
            if let ring = existing, selectionRingSignature[object.id] == signature {
                ring.isEnabled = true
                continue
            }

            existing?.removeFromParent()
            guard let ring = SceneBuilder.makeSelectionRing(on: entity, color: accent) else { continue }
            entity.addChild(ring)
            selectionRingSignature[object.id] = signature
        }
    }

    // MARK: 搭建

    private func setupLights() {
        let key = Entity()
        key.name = "rk.key"
        key.components.set(
            DirectionalLightComponent(
                color: NSColor(calibratedWhite: 1, alpha: 1),
                intensity: Float(environment.keyLight.intensity),
                isRealWorldProxy: false
            )
        )
        key.look(at: [0, 0.9, 0], from: [3.2, 5.2, 3.6], relativeTo: nil)
        lightsRoot.addChild(key)

        let rim = Entity()
        rim.name = "rk.rim"
        rim.components.set(
            PointLightComponent(
                cgColor: NSColor(srgbRed: 0.72, green: 0.84, blue: 1.0, alpha: 1).cgColor,
                intensity: 420,
                attenuationRadius: 18
            )
        )
        rim.position = [-3.6, 2.6, -3.4]
        lightsRoot.addChild(rim)

        let fill = Entity()
        fill.name = "rk.fill"
        fill.components.set(
            PointLightComponent(
                cgColor: NSColor(srgbRed: 1.0, green: 0.93, blue: 0.85, alpha: 1).cgColor,
                intensity: 180,
                attenuationRadius: 16
            )
        )
        fill.position = [3.4, 1.8, 4.6]
        lightsRoot.addChild(fill)
    }

    /// 自建相机：轨道参数驱动位置与朝向（RealityView 的托管相机不给编程接口）
    private func setupCameraEntity() {
        var camera = PerspectiveCameraComponent()
        camera.fieldOfViewInDegrees = 38
        camera.near = 0.005
        // 只是首帧兜底，真正取值由 applyOrbitCamera → updateClipPlanes() 按轨道距离动态给
        camera.far = 100000
        let entity = Entity()
        entity.name = "rk.camera"
        entity.components.set(camera)
        root.addChild(entity)
        cameraEntity = entity
        applyOrbitCamera()
    }

    // MARK: 轨道相机

    /// 拖拽转相机：左拖环绕，仰角锁在 ±(90° - 余量)，保证顶/底视可以真的转到位
    func orbit(delta: CGSize) {
        对齐任务?.cancel()
        orbitAzimuth -= Double(delta.width) * 0.008
        let 上限 = 视口轴向.仰角上限
        orbitElevation = min(max(orbitElevation + Double(delta.height) * 0.008, -上限), 上限)
        applyOrbitCamera()
    }

    /// 缩放：factor > 1 拉远，< 1 推近
    func zoom(factor: Double) {
        guard factor.isFinite, factor > 0 else { return }
        orbitDistance = 夹取距离(orbitDistance * factor)
        applyOrbitCamera()
    }
    /// 统一的轨道距离夹取：只压下限防穿透，往上不封顶（1e9 只是数值安全线）
    private func 夹取距离(_ value: Double) -> Double {
        guard value.isFinite else { return Self.最小轨道距离 }
        return min(max(value, Self.最小轨道距离), Self.轨道距离安全上限)
    }

    /// 平移（中键 / 滚轮按住拖动）：目标点沿相机自身的右、上两个方向移动，
    /// 屏幕里的东西跟着指针走，视角方向不变。
    /// 位移按「目标点所在深度的可视高度」换算成世界单位，推近时不会一下飞出去、
    /// 拉远时也不会拖不动 —— 与缩放共用同一套距离参数，手感是连贯的。
    /// - Parameter delta: 视口坐标（原点左上、y 向下）下的像素位移
    func pan(delta: CGPoint, 视图尺寸 size: CGSize) {
        guard size.height > 1 else { return }
        对齐任务?.cancel()
        let 快照 = 相机快照()
        let 半高 = tan(快照.视场角 * .pi / 360) * orbitDistance
        let 每像素 = Float(2 * 半高 / Double(size.height))
        // 内容跟手：指针往右 → 相机（目标点）往左；指针往下 → 相机往上
        orbitTargetPoint -= 快照.右向 * (Float(delta.x) * 每像素)
        orbitTargetPoint += 快照.上向 * (Float(delta.y) * 每像素)
        applyOrbitCamera()
    }

    private func applyOrbitCamera() {
        guard let camera = cameraEntity else { return }
        let horizontal = orbitDistance * cos(orbitElevation)
        let position = SIMD3<Float>(
            orbitTargetPoint.x + Float(horizontal * sin(orbitAzimuth)),
            orbitTargetPoint.y + Float(orbitDistance * sin(orbitElevation)),
            orbitTargetPoint.z + Float(horizontal * cos(orbitAzimuth))
        )
        camera.position = position
        camera.look(at: orbitTargetPoint, from: position, relativeTo: nil)
        updateClipPlanes()
        updateGridFollow()
    }

    // MARK: - 无限视口支撑（动态裁剪面 + 无限网格）

    /// near/far 随轨道距离等比伸缩：near 贴住当前尺度、far 盖到网格边界之外，
    /// 拉多远都不会被裁掉，且 far/near 比例恒定 ⇒ 不会因深度精度爆炸出现 z-fighting
    private func updateClipPlanes() {
        guard let camera = cameraEntity,
              var component = camera.components[PerspectiveCameraComponent.self] else { return }
        // near 不设上限：它必须与 orbitDistance 等比，远/近比值恒定，深度精度才恒定；
        // 之前给 near 加了 50 的上限，拉远后 far/near 比例暴涨，几十万单位外深度精度只剩几百单位，
        // 网格会被地面按 z-fighting 吃掉。
        let near = Float(max(orbitDistance * 0.01, 0.001))
        let far = Float(max(orbitDistance * 120, 1000))
        let nearChanged = abs(component.near - near) > max(component.near, near) * 0.08
        let farChanged = abs(component.far - far) > max(component.far, far) * 0.08
        guard nearChanged || farChanged else { return }
        component.near = near
        component.far = far
        camera.components.set(component)
    }

    /// 网格 / 地面的无限跟随：网格本身由 shader 按世界坐标画（世界空间刻度），
    /// 这里只负责把承载平面铺满可见视锥，不重建 mesh、不改格子尺寸、也不需要吸附 ——
    /// 格线位置只取决于世界坐标，相机平移缩放时线条本身纹丝不动。
    private func updateGridFollow() {
        let D = max(orbitDistance, Self.最小轨道距离)
        let fov = Double(cameraEntity?.components[PerspectiveCameraComponent.self]?.fieldOfViewInDegrees ?? 38)
        let 半角 = max(fov, 1) * 0.5 * .pi / 180
        // 目标点处的可见半宽 ×6：斜视时远端更远也照得住，脚下到地平线都有网格
        let 覆盖 = max(D * tan(半角) * 6, 0.05)
        // 边长量化到 10 的幂：距离平滑变化时 scale 绝大多数帧不变，场景图不会被每帧写入
        let 边长 = Float(pow(10.0, ceil(log10(覆盖 * 2))))
        // 网格与地面的高度差按相机距离等比放大：深度精度随距离线性变差（精度 ≈ D/1.7e5），
        // 固定毫米级间距在远处会被吃掉导致网格被地面遮挡，因此层高取 3e-3·D（约 5 倍余量），
        // 近处则收在下限 0.002，保证小模型看起来仍贴着网格。
        let 层高 = Float(max(0.002, D * 0.003))
        if let grid = gridEntity {
            grid.position = [orbitTargetPoint.x, 层高, orbitTargetPoint.z]
            if grid.scale.x != 边长 { grid.scale = [边长, 1, 边长] }
        }
        if let ground = groundEntity {
            ground.position = [orbitTargetPoint.x, -层高, orbitTargetPoint.z]
            if ground.scale.x != 边长 { ground.scale = [边长, 1, 边长] }
        }
    }


    // MARK: 视口覆盖层支撑

    /// 相机参数快照：轴向控件与对象坐标轴靠它做 2D 投影，与 PT 共用同一套参数
    func 相机快照() -> 视口相机 {
        let fov = cameraEntity?.components[PerspectiveCameraComponent.self]?.fieldOfViewInDegrees ?? 38
        return 视口相机(
            方位角: orbitAzimuth,
            仰角: orbitElevation,
            距离: orbitDistance,
            目标点: orbitTargetPoint,
            视场角: Double(fov)
        )
    }

    /// 当前机位存档：保存工程时原样写进快照
    func 相机存档() -> 视口相机存档 {
        视口相机存档(
            方位角: orbitAzimuth,
            仰角: orbitElevation,
            距离: orbitDistance,
            目标点X: orbitTargetPoint.x,
            目标点Y: orbitTargetPoint.y,
            目标点Z: orbitTargetPoint.z
        )
    }

    /// 还原机位：打开文件时所见即所得——用户存的时候什么样，打开就是什么样。
    /// 这里只搬相机参数，不重新聚焦、不碰场景内容。
    func 应用相机存档(_ 存档: 视口相机存档) {
        对齐任务?.cancel()
        orbitAzimuth = 存档.方位角
        orbitElevation = min(max(存档.仰角, -视口轴向.仰角上限), 视口轴向.仰角上限)
        orbitDistance = 夹取距离(存档.距离)
        orbitTargetPoint = [存档.目标点X, 存档.目标点Y, 存档.目标点Z]
        applyOrbitCamera()
    }

    /// 物体的世界位置（自动转台转的是父节点，坐标轴手柄必须跟着一起转）
    func 世界位置(of id: UUID) -> SIMD3<Float>? {
        guard let entity = objectEntities[id], entity.isEnabled else { return nil }
        return entity.position(relativeTo: nil)
    }

    // MARK: 聚焦

    /// 物体的世界包围球。优先向 RealityKit 要真实包围盒；
    /// 实体还没同步出来（刚加、或被禁用）就按内置几何的标称尺寸乘缩放估算，
    /// 保证 F 键任何时刻都有结果，不会因为一帧没同步就失灵。
    func 包围球(of id: UUID) -> (中心: SIMD3<Float>, 半径: Float)? {
        if let entity = objectEntities[id], entity.isEnabled {
            // RealityKit 的 BoundingBox 不给包围球，自己用对角线算
            let 框 = entity.visualBounds(relativeTo: nil)
            let 中心 = (框.min + 框.max) * 0.5
            let 半径 = simd_length(框.max - 框.min) * 0.5
            if 半径.isFinite, 半径 > 0.0001 {
                return (中心, 半径)
            }
        }
        guard let object = 物体快照.first(where: { $0.id == id }) else { return nil }
        return 粗略包围球(of: object)
    }

    /// 物体的世界轴对齐包围盒：中心 + 各轴半边。
    /// 拼接是点对点贴面，必须用真实外壳角；拿包围球内接立方体的角当锚点，
    /// 非立方体（球、环、圆柱、导入模型）那个角会缩在壳里，吸完就留一道缝。
    func 包围盒(of object: SceneObject) -> (中心: SIMD3<Float>, 半边: SIMD3<Float>) {
        if let entity = objectEntities[object.id], entity.isEnabled {
            let 框 = entity.visualBounds(relativeTo: nil)
            let 中心 = (框.min + 框.max) * 0.5
            let 半边 = (框.max - 框.min) * 0.5
            if 半边.x.isFinite, 半边.y.isFinite, 半边.z.isFinite,
               max(半边.x, max(半边.y, 半边.z)) > 0.0001 {
                return (中心, 半边)
            }
        }
        // 实体还没同步出来：按标称半径折成立方半边，只差一帧，够用
        let (中心, 半径) = 粗略包围球(of: object)
        return (中心, SIMD3(repeating: 半径 / 1.7320508))
    }

    /// 轻量包围球：只按变换 + 标称半径估算，不碰 RealityKit 实体子树。
    /// 「聚焦全部」要一口气量几百上千个物体，逐个走 visualBounds 会把主线程拖住，用它替代。
    func 粗略包围球(of object: SceneObject) -> (中心: SIMD3<Float>, 半径: Float) {
        let 中心 = SIMD3<Float>(Float(object.position.x), Float(object.position.y), Float(object.position.z))
        let 最大缩放 = Float(max(abs(object.scale.x), abs(object.scale.y), abs(object.scale.z)))
        // 标称半径按几何域记的形状算；导入网格没有内置形状，回落模型占位形状（与接入前一致）
        let 程序形状 = 几何接线.共享.程序形状(键: object.id.uuidString, 兜底: object.mesh)
        return (中心, 标称半径(程序形状) * max(最大缩放, 0.01))
    }

    /// 内置几何的标称包围半径（与 PTGeometry 的尺寸表对齐）
    private func 标称半径(_ mesh: MeshKind) -> Float {
        switch mesh {
        case .sphere: 0.9
        case .cube: 1.3      // 1.5³ 的体对角半径
        case .torus: 1.15    // ring 0.85 + pipe 0.3
        case .cylinder: 1.08 // h 1.8 / r 0.6
        case .plane: 0.75
        case .shaderBall: 1.1
        }
    }

    /// F 聚焦：轨道目标点移到物体中心，并按包围球重算距离，让物体刚好铺满视场。
    /// 与「点轴向控件」的相机动画共用同一个任务槽位（互斥），避免叠加抽搐。
    func 聚焦(on 中心: SIMD3<Float>, 半径: Float, onStep: ((视口相机) -> Void)? = nil) {
        对齐任务?.cancel()

        let fov = Double(cameraEntity?.components[PerspectiveCameraComponent.self]?.fieldOfViewInDegrees ?? 38)
        let 半角 = max(fov, 1) * 0.5 * .pi / 180
        let 安全半径 = max(Double(半径), 0.02)
        // 包围球裹进视锥，再留 15% 呼吸边；夹在合理区间免得贴脸或飞出天际
        let 目标距离 = 夹取距离(安全半径 / sin(半角) * 1.15)

        let 起目标 = orbitTargetPoint
        let 起距离 = orbitDistance
        let 时长: Double = 0.22

        // 与「对齐」一样按真实时钟推进：主线程偶尔卡一帧只掉帧，不拖长总时长
        对齐任务 = Task { [weak self] in
            let 起点 = CFAbsoluteTimeGetCurrent()
            while true {
                try? await Task.sleep(for: .milliseconds(8))
                guard let self, !Task.isCancelled else { return }
                let 进度 = min(max((CFAbsoluteTimeGetCurrent() - 起点) / 时长, 0), 1)
                let e = 进度 * 进度 * (3 - 2 * 进度)
                self.orbitTargetPoint = 起目标 + (中心 - 起目标) * Float(e)
                self.orbitDistance = 起距离 + (目标距离 - 起距离) * e
                self.applyOrbitCamera()
                onStep?(self.相机快照())
                if 进度 >= 1 { return }
            }
        }
    }

    /// 点击轴向控件：轨道相机平滑对齐到该轴向，方位角走最短弧避免绕一大圈
    func 对齐(_ 轴向: 视口轴向, onStep: ((视口相机) -> Void)? = nil) {
        对齐任务?.cancel()

        let 起方位 = orbitAzimuth
        let 起仰角 = orbitElevation
        var 增量 = (轴向.方位角 - 起方位).truncatingRemainder(dividingBy: .pi * 2)
        if 增量 > .pi { 增量 -= .pi * 2 }
        if 增量 < -.pi { 增量 += .pi * 2 }
        let 目标方位 = 起方位 + 增量
        let 目标仰角 = 轴向.仰角

        // 【时间驱动】以前是「固定 16 步 × 每步 sleep 12ms」：总时长完全取决于
        // 每一步能不能准点醒。主线程上只要有一次 SwiftUI 全树重算 / 场景转译插进来，
        // sleep 就被拖长，16 步叠起来能从 190ms 涨到 300ms 以上 ——
        // 手感就是「点了轴向控件，画面慢半拍才转过去」。
        // 改成按真实时钟推进：慢帧只会让这一小段掉几帧，总时长始终是 0.2s。
        let 时长: Double = 0.2
        对齐任务 = Task { [weak self] in
            let 起点 = CFAbsoluteTimeGetCurrent()
            while true {
                try? await Task.sleep(for: .milliseconds(8))
                guard let self, !Task.isCancelled else { return }
                let 进度 = min(max((CFAbsoluteTimeGetCurrent() - 起点) / 时长, 0), 1)
                let e = 进度 * 进度 * (3 - 2 * 进度)
                self.orbitAzimuth = 起方位 + (目标方位 - 起方位) * e
                self.orbitElevation = 起仰角 + (目标仰角 - 起仰角) * e
                self.applyOrbitCamera()
                onStep?(self.相机快照())
                if 进度 >= 1 { return }
            }
        }
    }

    // MARK: 接触阴影

    /// RealityKit 在 macOS 上不提供方向光阴影贴图，这里补一张贴地的柔和接触阴影，
    /// 跟随物体的包围盒位置与尺度，保证「有投影」这件事在视口里成立。
    private func syncContactShadows(objects: [SceneObject], settings: ViewportSettings) {
        let alive = Set(objects.map(\.id))
        for (id, entity) in shadowEntities where !alive.contains(id) {
            entity.removeFromParent()
            shadowEntities[id] = nil
        }

        for object in objects {
            guard let entity = objectEntities[object.id] else { continue }
            let shadow: Entity
            if let existing = shadowEntities[object.id] {
                shadow = existing
            } else {
                guard let made = SceneBuilder.makeContactShadow() else { continue }
                made.name = "rk.shadow." + object.id.uuidString
                root.addChild(made)
                shadowEntities[object.id] = made
                shadow = made
            }

            let bounds = entity.visualBounds(relativeTo: root)
            let extent = max(max(bounds.extents.x, bounds.extents.z), 0.3)
            let size = Float(extent * 1.55)
            shadow.position = [bounds.center.x, 0.0015, bounds.center.z]
            shadow.scale = [size, 1, size]
            shadow.isEnabled = settings.showsGround && object.isVisible
        }
    }

    private func setupGround() {
        // 单位平面 + 由相机距离驱动的 scale：不再写死 12×12，拉多远地面都铺满
        guard let mesh = try? MeshResource.generatePlane(width: 1, depth: 1) else { return }
        let entity = ModelEntity(mesh: mesh, materials: [SceneBuilder.groundMaterial(isDark: Theme.配色.深色)])
        entity.name = "rk.ground"
        entity.position = [0, -0.001, 0]
        entity.scale = [12, 1, 12]
        root.addChild(entity)
        groundEntity = entity
    }

    private func setupGrid() {
        // 程序化无限网格：只放一个大平面（4 顶点、单次 draw call），格线由 rkShaders.metal 的
        // rkGridSurface 按片元世界坐标画出来，顶点数与相机远近、场景规模完全无关，且永不重建。
        // 这里只决定平面铺多大，格子的世界尺寸始终由 shader 里的 1 / 10 / 100 刻度决定。
        guard let mesh = try? MeshResource.generatePlane(width: 1, depth: 1) else { return }
        let entity = ModelEntity(mesh: mesh, materials: [SceneBuilder.gridMaterial(isDark: Theme.配色.深色)])
        entity.name = "rk.grid"
        entity.position = [0, 0.0015, 0]
        entity.scale = [12, 1, 12]
        root.addChild(entity)
        gridEntity = entity
        updateGridFollow()
    }
}

// MARK: - RealityKit 场景构建

extension SceneBuilder {

    static let selectionRingName = "rk.selection"
    static var solidColor: NSColor { NSColor(calibratedWhite: 0.62, alpha: 1) }

    static func deg2rad(_ deg: Double) -> Double { deg * .pi / 180 }

    /// 固定 XYZ 顺序的欧拉角 → 四元数（RealityKit 没有对应初始化器）
    static func eulerQuaternion(x: Double, y: Double, z: Double) -> simd_quatf {
        let qx = simd_quatf(angle: Float(deg2rad(x)), axis: [1, 0, 0])
        let qy = simd_quatf(angle: Float(deg2rad(y)), axis: [0, 1, 0])
        let qz = simd_quatf(angle: Float(deg2rad(z)), axis: [0, 0, 1])
        return qx * qy * qz
    }

    // MARK: 实体

    /// 视口里的灯符号：只是个能看见 / 能点选 / 能拖动的占位体，
    /// 与路径追踪无关（PT 里灯只有照明，没有几何）。
    ///
    /// 但符号必须回答一个 DCC 里最要紧的问题：**光朝哪一面发**。所以除了形体本身还要两样东西：
    /// 1. 发光面单独贴一片亮色、背面留暗灰 —— 一眼分得出正反面；
    /// 2. 从发光面沿本地 -Y 伸出一条箭头 —— 方向与 PT 转译里的发光朝向严格一致（灯默认往下打）。
    static func makeLightEntity(for 设置: 灯光设置) -> Entity {
        let 提示色 = 灯光提示色(设置.色温)
        let 发光色 = 灯光符号亮色(提示色)
        let 壳体色 = 灯光符号壳体色(提示色)
        let root = Entity()

        switch 设置.种类 {
        case .区域光:
            let 宽 = Float(max(设置.宽, 0.02))
            let 深 = Float(max(设置.高, 0.02))
            let 板 = ModelEntity(
                mesh: .generateBox(size: [宽, 0.04, 深], cornerRadius: min(0.02, min(宽, 深) * 0.1)),
                materials: [UnlitMaterial(color: 壳体色)]
            )
            板.name = 灯光符号前缀 + "外壳"
            root.addChild(板)
            // 朝 -Y 的一面贴一片更亮的薄片：这就是真正出光的那一面
            let 发光面 = ModelEntity(
                mesh: .generateBox(size: [宽 * 0.97, 0.012, 深 * 0.97]),
                materials: [UnlitMaterial(color: 发光色)]
            )
            发光面.name = 灯光符号发光面名
            发光面.position = [0, -0.025, 0]
            root.addChild(发光面)
            let 箭头 = 方向箭头(长: min(max(min(宽, 深) * 0.85, 0.5), 3.0))
            箭头.position = [0, -0.04, 0]
            root.addChild(箭头)

        case .点光:
            let 半径 = Float(max(设置.半径, 0.08))
            let 球 = ModelEntity(mesh: .generateSphere(radius: 半径), materials: [UnlitMaterial(color: 发光色)])
            球.name = 灯光符号发光面名
            root.addChild(球)
            // 点光向四面八方发：四个短箭头指明「没有单一朝向」
            let 短 = min(max(半径 * 1.6, 0.18), 0.45)
            // 箭头几何默认指向 -Y，按目标方向给显式旋转（不走 from/to 四元数，正反共线时会退化）
            let 四向: [(SIMD3<Float>, simd_quatf)] = [
                (SIMD3<Float>(0, -1, 0), simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))),
                (SIMD3<Float>(0, 1, 0), simd_quatf(angle: Float.pi, axis: SIMD3<Float>(1, 0, 0))),
                (SIMD3<Float>(1, 0, 0), simd_quatf(angle: Float.pi / 2, axis: SIMD3<Float>(0, 0, 1))),
                (SIMD3<Float>(-1, 0, 0), simd_quatf(angle: -Float.pi / 2, axis: SIMD3<Float>(0, 0, 1)))
            ]
            for (方向, 朝向) in 四向 {
                let 箭头 = 方向箭头(长: 短)
                箭头.orientation = 朝向
                箭头.position = 方向 * 半径
                root.addChild(箭头)
            }

        case .聚光:
            // 锥体：尖顶落在灯的位置，底面朝 -Y 张开，张角跟真实聚光角一致
            let 高 = Float(min(max(max(设置.宽, 0.6) * 0.5, 0.6), 2.4))
            let 半角 = Float(min(max(设置.锥角, 1), 89) * Double.pi / 180)
            let 底半径 = 高 * tan(半角)
            if let 锥网格 = makeConeMesh(高: 高, 底半径: 底半径) {
                let 锥 = ModelEntity(mesh: 锥网格, materials: [UnlitMaterial(color: 壳体色)])
                锥.name = 灯光符号前缀 + "光锥"
                root.addChild(锥)
            }
            // 灯口：一片亮圆盘标出发光端
            let 灯口 = ModelEntity(
                mesh: .generateCylinder(height: 0.03, radius: max(Float(设置.半径), 0.06)),
                materials: [UnlitMaterial(color: 发光色)]
            )
            灯口.name = 灯光符号发光面名
            root.addChild(灯口)
            let 箭头 = 方向箭头(长: 高 * 0.7)
            箭头.position = [0, -0.03, 0]
            root.addChild(箭头)

        case .平行光:
            let 球 = ModelEntity(mesh: .generateSphere(radius: 0.12), materials: [UnlitMaterial(color: 发光色)])
            球.name = 灯光符号发光面名
            root.addChild(球)
            // 平行光是整片方向一致的光：三根等长箭头发排射
            for 横向 in [Float(-0.26), 0, 0.26] {
                let 箭头 = 方向箭头(长: 0.9)
                箭头.position = [横向, -0.1, 横向 * 0.6]
                root.addChild(箭头)
            }
        }
        return root
    }

    /// 视口灯符号的所有子件都带这个前缀：材质刷新 / 统一上色时靠它把符号原样保留下来
    static let 灯光符号前缀 = "灯光符号·"
    /// 特效容器线框符号的节点名前缀：材质/调试着色的递归刷新要跳过它，
    /// 否则容器框会被刷成"跟场景里别的物体一样的实体色"，符号感就没了。
    static let 容器符号前缀 = "特效容器符号·"
    /// 灯符号的发光面节点名（亮色那一面）
    static let 灯光符号发光面名 = "灯光符号·发光面"
    /// 灯符号的出光箭头节点名
    static let 灯光符号箭头名 = "灯光符号·箭头"

    /// 灯符号箭头颜色：固定暖黄，跟任何色温的灯都能区分开
    private static func 灯光符号箭头色() -> NSColor {
        NSColor(srgbRed: 1.0, green: 0.78, blue: 0.18, alpha: 1)
    }

    /// 灯符号外壳（背面 / 锥体）：压暗的灯色，跟亮面形成反差
    private static func 灯光符号壳体色(_ 灯色: NSColor) -> NSColor {
        guard let rgb = 灯色.usingColorSpace(.sRGB) else { return 灯色 }
        return NSColor(
            srgbRed: rgb.redComponent * 0.42,
            green: rgb.greenComponent * 0.42,
            blue: rgb.blueComponent * 0.46,
            alpha: 1
        )
    }

    /// 灯符号发光面：把灯色往白里推，亮到一眼看出「这面在发」
    private static func 灯光符号亮色(_ 灯色: NSColor) -> NSColor {
        guard let rgb = 灯色.usingColorSpace(.sRGB) else { return 灯色 }
        let 比例: CGFloat = 0.55
        return NSColor(
            srgbRed: rgb.redComponent + (1 - rgb.redComponent) * 比例,
            green: rgb.greenComponent + (1 - rgb.greenComponent) * 比例,
            blue: rgb.blueComponent + (1 - rgb.blueComponent) * 比例,
            alpha: 1
        )
    }

    /// 出光方向箭头：几何自己算（从原点指向 -Y），不依赖 RealityKit 内置锥体的轴向约定
    private static func 方向箭头(长 L: Float) -> Entity {
        // 箭头是「哪一面出光」唯一的方向线索，宁可粗一点也不要做成细线
        let 杆半径 = max(L * 0.045, 0.016)
        let 头长 = max(L * 0.3, 0.06)
        let 材质 = UnlitMaterial(color: 灯光符号箭头色())
        let 箭头: ModelEntity
        if let 网格 = makeArrowMesh(长: L, 杆半径: 杆半径, 头半径: 杆半径 * 2.6, 头长: 头长) {
            箭头 = ModelEntity(mesh: 网格, materials: [材质])
        } else {
            箭头 = ModelEntity(mesh: .generateSphere(radius: 杆半径 * 2), materials: [材质])
        }
        箭头.name = 灯光符号箭头名
        return 箭头
    }

    /// 沿 -Y 的箭头：杆身从 0 到 -(L-头长)，锥头收在 -L，尖端就是光去的方向
    static func makeArrowMesh(长 L: Float, 杆半径 r: Float, 头半径 R: Float, 头长 hl: Float, 段数 n: Int = 20) -> MeshResource? {
        guard L > 1e-3, r > 0, R > 0, hl > 0, hl < L else { return nil }
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []

        func 圆点(_ 角度: Float, _ 半径: Float, _ y: Float) -> SIMD3<Float> {
            SIMD3<Float>(cos(角度) * 半径, y, sin(角度) * 半径)
        }

        let 杆末 = -(L - hl)
        // 杆身侧面
        for i in 0..<n {
            let a0 = Float(i) / Float(n) * 2 * .pi
            let a1 = Float(i + 1) / Float(n) * 2 * .pi
            let n0 = SIMD3<Float>(cos(a0), 0, sin(a0))
            let n1 = SIMD3<Float>(cos(a1), 0, sin(a1))
            let base = UInt32(positions.count)
            positions.append(contentsOf: [圆点(a0, r, 0), 圆点(a0, r, 杆末), 圆点(a1, r, 杆末), 圆点(a1, r, 0)])
            normals.append(contentsOf: [n0, n0, n1, n1])
            indices.append(contentsOf: [base, base + 1, base + 2, base, base + 2, base + 3])
        }
        // 锥头侧面
        let 尖 = SIMD3<Float>(0, -L, 0)
        let 锥法线抬升 = R / hl
        for i in 0..<n {
            let a0 = Float(i) / Float(n) * 2 * .pi
            let a1 = Float(i + 1) / Float(n) * 2 * .pi
            let n0 = simd_normalize(SIMD3<Float>(cos(a0), 锥法线抬升, sin(a0)))
            let n1 = simd_normalize(SIMD3<Float>(cos(a1), 锥法线抬升, sin(a1)))
            let base = UInt32(positions.count)
            positions.append(contentsOf: [圆点(a0, R, 杆末), 圆点(a1, R, 杆末), 尖])
            normals.append(contentsOf: [n0, n1, n0])
            indices.append(contentsOf: [base, base + 1, base + 2])
        }

        var descriptor = MeshDescriptor(name: "lightArrow")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.primitives = .triangles(indices)
        return try? MeshResource.generate(from: [descriptor])
    }

    /// 聚光锥：尖顶在原点，底面朝 -Y 张开
    static func makeConeMesh(高 h: Float, 底半径 R: Float, 段数 n: Int = 32) -> MeshResource? {
        guard h > 1e-3, R > 0 else { return nil }
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []

        let 尖 = SIMD3<Float>(0, 0, 0)
        let 法线抬升 = R / h
        for i in 0..<n {
            let a0 = Float(i) / Float(n) * 2 * .pi
            let a1 = Float(i + 1) / Float(n) * 2 * .pi
            let b0 = SIMD3<Float>(cos(a0) * R, -h, sin(a0) * R)
            let b1 = SIMD3<Float>(cos(a1) * R, -h, sin(a1) * R)
            let n0 = simd_normalize(SIMD3<Float>(cos(a0), 法线抬升, sin(a0)))
            let n1 = simd_normalize(SIMD3<Float>(cos(a1), 法线抬升, sin(a1)))
            let base = UInt32(positions.count)
            positions.append(contentsOf: [尖, b0, b1])
            normals.append(contentsOf: [n0, n0, n1])
            indices.append(contentsOf: [base, base + 1, base + 2])
        }

        var descriptor = MeshDescriptor(name: "lightCone")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.primitives = .triangles(indices)
        return try? MeshResource.generate(from: [descriptor])
    }

    /// 色温 → 视口提示色（符号颜色）。与 PT 侧共用同一套黑体拟合，
    /// 保证"符号是什么色、照出来的光就是什么色"，不再另拿一条 t 线性插值糊一个近似 ——
    /// 那条插值在 1800K 只到浅黄，2000K 往上就基本白了，暖色和冷色两头都看不出来。
    static func 灯光提示色(_ kelvin: Double) -> NSColor {
        let 线性 = PTTranslator.色温RGB(kelvin)
        func 编码(_ v: Float) -> CGFloat {
            let s = v <= 0.0031308 ? v * 12.92 : 1.055 * powf(v, 1.0 / 2.4) - 0.055
            return CGFloat(min(max(s, 0), 1))
        }
        // 符号是自发光色块，别用满饱和的原色，往白里掺一点更像"灯罩在亮"
        func 掺白(_ v: CGFloat) -> CGFloat { min(0.75 * v + 0.25, 1) }
        return NSColor(srgbRed: 掺白(编码(线性.x)),
                       green: 掺白(编码(线性.y)),
                       blue: 掺白(编码(线性.z)),
                       alpha: 1)
    }

    static func makeEntity(for mesh: MeshKind) -> Entity {
        switch mesh {
        case .shaderBall:
            return makeShaderBallEntity()
        case .sphere:
            return ModelEntity(mesh: .generateSphere(radius: 0.9))
        case .cube:
            return ModelEntity(mesh: .generateBox(size: [1.5, 1.5, 1.5], cornerRadius: 0.08))
        case .torus:
            return makeTorusEntity(ring: 0.85, pipe: 0.3) ?? ModelEntity(mesh: .generateSphere(radius: 0.9))
        case .cylinder:
            return ModelEntity(mesh: .generateCylinder(height: 1.8, radius: 0.6))
        case .plane:
            // Plane 默认水平，预旋 -90° 并抬到地面之上
            let entity = ModelEntity(mesh: .generatePlane(width: 1, depth: 1))
            entity.orientation = simd_quatf(angle: -.pi / 2, axis: [1, 0, 0])
            entity.position = [0, 0.002, 0]
            return entity
        }
    }

    /// 特效容器的视口符号：12 条细管拼一个线框盒。
    ///
    /// RealityKit 没有"线框填充模式"，`generateBox` 又是实心 —— 所以用细管拼骨架，
    /// 看上去就是线框，而且照样能被选中/框选。
    /// 盒子按容器**合并几何的包围盒**来：框有多大，火就从多大一片冒，
    /// "火到底从哪冒"这件事不用再靠猜。容器里还没有源时给一个默认小盒，
    /// 表示"这是一个空容器"。
    static func makeContainerWireEntity(几何: 对象几何数据?) -> Entity {
        var 中心 = SIMD3<Float>.zero
        var 尺寸 = SIMD3<Float>(repeating: 0.7)
        if let 几何, !几何.三角点.isEmpty {
            中心 = (几何.最小 + 几何.最大) * 0.5
            尺寸 = simd_max(几何.最大 - 几何.最小, SIMD3<Float>(repeating: 0.16))
        }
        let 半 = 尺寸 * 0.5
        let 粗 = max(0.005, simd_reduce_max(尺寸) * 0.009)
        // 青蓝常亮：符号要一眼能跟场景里的实体几何区分开
        let 材质 = UnlitMaterial(color: NSColor(srgbRed: 0.36, green: 0.84, blue: 0.98, alpha: 1))
        let 根 = Entity()
        根.name = 容器符号前缀 + "框"
        func 段(_ 长: SIMD3<Float>, _ 位: SIMD3<Float>) {
            let 条 = ModelEntity(mesh: .generateBox(size: 长, cornerRadius: 0),
                                 materials: [材质])
            条.name = 容器符号前缀 + "边"
            条.position = 位
            根.addChild(条)
        }
        for sy in [Float(-1), 1] {
            for sz in [Float(-1), 1] {
                段(SIMD3<Float>(尺寸.x + 粗, 粗, 粗),
                  中心 + SIMD3<Float>(0, 半.y * sy, 半.z * sz))
            }
        }
        for sx in [Float(-1), 1] {
            for sz in [Float(-1), 1] {
                段(SIMD3<Float>(粗, 尺寸.y + 粗, 粗),
                  中心 + SIMD3<Float>(半.x * sx, 0, 半.z * sz))
            }
        }
        for sx in [Float(-1), 1] {
            for sy in [Float(-1), 1] {
                段(SIMD3<Float>(粗, 粗, 尺寸.z + 粗),
                  中心 + SIMD3<Float>(半.x * sx, 半.y * sy, 0))
            }
        }
        return 根
    }

    /// 参考 DCC 常见 shader ball：主球 + 底座 + 凹槽环 + 斜台
    private static func makeShaderBallEntity() -> Entity {
        let root = Entity()
        let ball = ModelEntity(mesh: .generateSphere(radius: 0.86))
        ball.position = [0, 0.98, 0]
        root.addChild(ball)
        let plinth = ModelEntity(mesh: .generateCylinder(height: 0.16, radius: 0.62))
        plinth.position = [0, 0.08, 0]
        root.addChild(plinth)
        if let groove = makeTorusEntity(ring: 0.46, pipe: 0.055) {
            groove.position = [0, 0.17, 0]
            root.addChild(groove)
        }
        let slope = ModelEntity(mesh: .generateBox(size: [1.35, 0.16, 1.35], cornerRadius: 0.02))
        root.addChild(slope)
        return root
    }

    static func makeTorusEntity(ring: Float, pipe: Float) -> Entity? {
        guard let mesh = makeTorusMesh(ring: ring, pipe: pipe) else { return nil }
        return ModelEntity(mesh: mesh)
    }

    /// RealityKit 没有 generateTorus，手搓参数化环面
    static func makeTorusMesh(ring: Float, pipe: Float, ringSegments: Int = 96, pipeSegments: Int = 48) -> MeshResource? {
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []

        for i in 0...ringSegments {
            let u = Float(i) / Float(ringSegments) * 2 * .pi
            let cu = cos(u), su = sin(u)
            for j in 0...pipeSegments {
                let v = Float(j) / Float(pipeSegments) * 2 * .pi
                let cv = cos(v), sv = sin(v)
                positions.append(SIMD3<Float>(cu * (ring + pipe * cv), pipe * sv, su * (ring + pipe * cv)))
                normals.append(SIMD3<Float>(cu * cv, sv, su * cv))
            }
        }

        let stride = pipeSegments + 1
        for i in 0..<ringSegments {
            for j in 0..<pipeSegments {
                let a = UInt32(i * stride + j)
                let b = UInt32((i + 1) * stride + j)
                let c = UInt32((i + 1) * stride + j + 1)
                let d = UInt32(i * stride + j + 1)
                indices.append(contentsOf: [a, b, c, a, c, d])
            }
        }

        var descriptor = MeshDescriptor(name: "torus")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.primitives = .triangles(indices)
        return try? MeshResource.generate(from: [descriptor])
    }

    // MARK: 材质应用

    static func apply(_ material: any RealityKit.Material, to entity: Entity, replacing: Bool = false) {
        if var model = entity.components[ModelComponent.self] {
            model.materials = [material]
            entity.components.set(model)
            entity.components.remove(ModelDebugOptionsComponent.self)
        }
        for child in entity.children where child.name != selectionRingName && !child.name.hasPrefix(灯光符号前缀) && !child.name.hasPrefix(容器符号前缀) {
            apply(material, to: child, replacing: replacing)
        }
    }

    static func applyUnlit(_ color: NSColor, to entity: Entity) {
        let material = UnlitMaterial(color: color)
        if var model = entity.components[ModelComponent.self] {
            model.materials = [material]
            entity.components.set(model)
        }
        entity.components.remove(ModelDebugOptionsComponent.self)
        for child in entity.children where child.name != selectionRingName && !child.name.hasPrefix(灯光符号前缀) && !child.name.hasPrefix(容器符号前缀) {
            applyUnlit(color, to: child)
        }
    }

    private static var normalMaterialCache: (any RealityKit.Material)?

    /// 法线可视化材质：走 rkShaders.metal 里的 rkNormalSurface
    static func normalVisualizationMaterial() -> (any RealityKit.Material)? {
        if let cached = normalMaterialCache { return cached }
        guard let device = MTLCreateSystemDefaultDevice(),
              let library = device.makeDefaultLibrary(),
              let shader = try? CustomMaterial.SurfaceShader(named: "rkNormalSurface", in: library),
              let material = try? CustomMaterial(surfaceShader: shader, lightingModel: .unlit)
        else { return nil }
        normalMaterialCache = material
        return material
    }

    static func applyDebugMode(_ mode: ModelDebugOptionsComponent.VisualizationMode, to entity: Entity) {
        if entity.components[ModelComponent.self] != nil {
            entity.components.set(ModelDebugOptionsComponent(visualizationMode: mode))
        }
        for child in entity.children where child.name != selectionRingName && !child.name.hasPrefix(灯光符号前缀) && !child.name.hasPrefix(容器符号前缀) {
            applyDebugMode(mode, to: child)
        }
    }

    /// 网格材质：程序化无限网格走 rkGridSurface（世界空间恒定刻度）。
    /// 深浅主题各缓存一份，切主题只换材质、不重建几何。
    static func gridMaterial(isDark: Bool) -> any RealityKit.Material {
        if let cached = gridMaterialCache[isDark] { return cached }
        let made: any RealityKit.Material = makeGridSurfaceMaterial(isDark: isDark) ?? hiddenGridMaterial()
        gridMaterialCache[isDark] = made
        return made
    }

    private static var gridMaterialCache: [Bool: any RealityKit.Material] = [:]
    private static var gridSurfaceShaderCache: CustomMaterial.SurfaceShader?
    private static var gridSurfaceShaderMissing = false

    /// 程序化无限网格的 surface shader：世界空间恒定刻度 + fwidth 抗锯齿 + 分级淡出
    private static func gridSurfaceShader() -> CustomMaterial.SurfaceShader? {
        if let gridSurfaceShaderCache { return gridSurfaceShaderCache }
        if gridSurfaceShaderMissing { return nil }
        guard let device = MTLCreateSystemDefaultDevice(),
              let library = device.makeDefaultLibrary(),
              let shader = try? CustomMaterial.SurfaceShader(named: "rkGridSurface", in: library)
        else {
            gridSurfaceShaderMissing = true
            return nil
        }
        gridSurfaceShaderCache = shader
        return shader
    }

    private static func makeGridSurfaceMaterial(isDark: Bool) -> CustomMaterial? {
        guard let shader = gridSurfaceShader(),
              var material = try? CustomMaterial(surfaceShader: shader, lightingModel: .unlit)
        else { return nil }
        // x = 主题（1 深 / 0 浅）  y = 整体不透明度（≤0 视为 1）
        material.custom.value = SIMD4<Float>(isDark ? 1 : 0, 1, 0, 0)
        material.blending = .transparent(opacity: .init(floatLiteral: 1))
        // 透明网格不写深度：避免这块巨大平面把后面的地面 / 物体裁掉；
        // 仍读深度，被模型挡住的线条会被正确剔除，不会"穿透"模型浮在前面。
        material.writesDepth = false
        material.readsDepth = true
        return material
    }

    /// shader 不可用时的兜底：完全不显示，宁可没有网格也不给出一块错误色板。
    private static func hiddenGridMaterial() -> UnlitMaterial {
        var material = UnlitMaterial()
        material.color = .init(tint: NSColor(calibratedWhite: 0.5, alpha: 1))
        material.blending = .transparent(opacity: .init(floatLiteral: 0))
        return material
    }

    /// 接触阴影：径向渐变的黑色 alpha 贴图 + 无光照半透明材质
    static func makeContactShadow() -> Entity? {
        let mesh: MeshResource
        if let cached = contactShadowMesh {
            mesh = cached
        } else {
            guard let plane = try? MeshResource.generatePlane(width: 1, depth: 1) else { return nil }
            contactShadowMesh = plane
            mesh = plane
        }
        let entity = ModelEntity(mesh: mesh, materials: [contactShadowMaterial()])
        entity.position = [0, 0.0015, 0]
        return entity
    }

    private static var contactShadowMesh: MeshResource?

    static func contactShadowMaterial() -> UnlitMaterial {
        var material = UnlitMaterial()
        material.color = .init(tint: .white, texture: contactShadowTexture().map { .init($0) })
        material.blending = .transparent(opacity: .init(floatLiteral: 1))
        return material
    }

    static func contactShadowTexture() -> TextureResource? {
        if let cached = contactShadowTextureCache { return cached }
        let size = 256
        guard let ctx = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let center = CGPoint(x: Double(size) / 2, y: Double(size) / 2)
        let radius = Double(size) / 2
        let colors = [
            CGColor(red: 0, green: 0, blue: 0, alpha: 0.62),
            CGColor(red: 0, green: 0, blue: 0, alpha: 0.42),
            CGColor(red: 0, green: 0, blue: 0, alpha: 0.16),
            CGColor(red: 0, green: 0, blue: 0, alpha: 0)
        ] as CFArray
        let locations: [CGFloat] = [0, 0.28, 0.62, 1]
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors,
            locations: locations
        ) else { return nil }
        ctx.drawRadialGradient(
            gradient,
            startCenter: center,
            startRadius: 0,
            endCenter: center,
            endRadius: radius,
            options: []
        )
        guard let image = ctx.makeImage(),
              let texture = try? TextureResource(
                image: image,
                withName: "rk.contactShadow",
                options: .init(semantic: .color)
              ) else { return nil }
        contactShadowTextureCache = texture
        return texture
    }

    private static var contactShadowTextureCache: TextureResource?

    static func groundMaterial(isDark: Bool) -> PhysicallyBasedMaterial {
        var params = OpenPBRParams()
        params[.baseColor] = .color(PBRColor(gray: isDark ? 0.10 : 0.86))
        params[.baseRoughness] = .scalar(0.62)
        return RKMaterialBridge.makeMaterial(ResolvedMaterial(params: params, drivenKeys: [], diagnostics: []))
    }

    static func ringMaterial(_ color: NSColor) -> PhysicallyBasedMaterial {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: color)
        material.emissiveColor = .init(color: color)
        material.emissiveIntensity = 1.6
        material.metallic = .init(floatLiteral: 0)
        material.roughness = .init(floatLiteral: 1)
        material.triangleFillMode = .lines
        material.faceCulling = .none
        return material
    }

    /// 选中描边：拿物体包围盒做一个线框盒，挂在物体下面（并抵消物体的缩放）
    static func transformSignature(_ object: SceneObject) -> String {
        String(
            format: "%.4f,%.4f,%.4f|%.4f,%.4f,%.4f|%.4f,%.4f,%.4f",
            object.position.x, object.position.y, object.position.z,
            object.rotation.x, object.rotation.y, object.rotation.z,
            object.scale.x, object.scale.y, object.scale.z
        )
    }

    static func makeSelectionRing(on entity: Entity, color: NSColor) -> Entity? {
        // 注意：必须取相对自身的包围盒，描边是 entity 的子节点，用世界坐标会重复叠加变换
        let bounds = entity.visualBounds(recursive: true, relativeTo: entity)
        let extents = bounds.extents
        guard extents.x.isFinite, extents.y.isFinite, extents.z.isFinite else { return nil }
        let size: SIMD3<Float> = [
            max(extents.x, 0.02),
            max(extents.y, 0.02),
            max(extents.z, 0.02)
        ]
        let mesh = MeshResource.generateBox(size: size, cornerRadius: 0)
        let ring = ModelEntity(mesh: mesh, materials: [ringMaterial(color)])
        ring.name = selectionRingName
        ring.position = bounds.center
        let scale = entity.scale
        ring.scale = [
            scale.x == 0 ? 1 : 1 / scale.x,
            scale.y == 0 ? 1 : 1 / scale.y,
            scale.z == 0 ? 1 : 1 / scale.z
        ]
        return ring
    }
}

// MARK: - [临时诊断·RK 重挂]

/// 排查「路径追踪切回其他着色模式首次黑屏」用：把关键挂载状态同时打到控制台和
/// ~/Library/Logs/3dRender/rk_attach_debug.log（本 target 未开沙盒，可直接写）。
/// 定位完把本函数和所有 rk诊断 调用一并删掉。
func rk诊断(_ 文本: String) {
    let 时间 = String(format: "%.3f", Date().timeIntervalSince1970)
    let 行 = "[RK诊断 \(时间)] \(文本)\n"
    print(行, terminator: "")
    let 目录 = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/3dRender", isDirectory: true)
    try? FileManager.default.createDirectory(at: 目录, withIntermediateDirectories: true)
    let 路径 = 目录.appendingPathComponent("rk_attach_debug.log")
    if let 句柄 = FileHandle(forWritingAtPath: 路径.path) {
        句柄.seekToEndOfFile()
        句柄.write(行.data(using: .utf8) ?? Data())
        句柄.closeFile()
    } else {
        FileManager.default.createFile(atPath: 路径.path, contents: 行.data(using: .utf8))
    }
}
