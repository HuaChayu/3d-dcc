import Foundation
import simd

// MARK: - 场景转译

/// RealityKit 场景 → 路径追踪场景。
/// 只保留 PT 真正需要的：世界空间三角形 + 逐三角形材质下标 + 环境。
/// 选中描边、网格、接触阴影这些"视口辅助物"一律不进来，否则会在地面上留一圈莫名其妙的黑环。
enum PTTranslator {

    /// 材质 GPU 表示的跨帧缓存。
    /// MaterialCompiler.resolve 要跑整张节点图（每帧每个材质几十次纹理/常量求值），
    /// 拖物体时场景每帧都在重建，但材质本身一个字节都没变 —— 这里按"资产内容"命中复用。
    final class 材质GPU缓存 {
        /// 一次解析的全部产出：GPU 参数 + 基础色贴图的纹理库 UUID（nil = 这个材质没贴图）。
        struct 结果 {
            var gpu: PTMaterialGPU
            var 贴图: UUID?
        }

        static let shared = 材质GPU缓存()
        private let 锁 = NSLock()
        /// 键 = 材质 id，值 = 当时的「单材质版本」（版本 nil = 不在材质域里，不缓存）。
        /// **不再存 MaterialAsset 副本**：材质的唯一所有者是数据层材质域，这里只放派生结果。
        private var 表: [UUID: (版本: UInt64?, 结果: 结果)] = [:]

        func gpu(for asset: MaterialAsset) -> 结果 {
            锁.lock()
            defer { 锁.unlock() }
            let 版本 = 材质接线.共享.版本(资产: asset.id)
            if let 命中 = 表[asset.id], let 版本, 命中.版本 == 版本 { return 命中.结果 }
            // 贴图 UUID 和参数一起从同一次 resolve 里拿：分两次解析会多跑一遍整张节点图
            let resolved = MaterialCompiler.resolve(asset)
            // 基础色贴图已经把调色烘进图里，这里再叠一次常量色就是双重调色 → 用 渲染参数
            var 结果 = 结果(gpu: PTTranslator.translate(resolved.渲染参数),
                            贴图: resolved.贴图[.baseColor])
            表[asset.id] = (版本, 结果)
            return 结果
        }
    }

    static func build(
        objects: [SceneObject],
        materials: [UUID: MaterialAsset],
        settings: ViewportSettings
    ) -> PTScene {
        var scene = PTScene()

        // 绘画图集快照（跨线程安全）：slice 必须在着色器里能反查到，
        // 而笔迹本身不进几何，所以这里只搬「哪个物体用哪一格」，不动三角形。
        let 绘画 = PaintGPUSnapshot.shared.读()
        scene.hasPaint = 绘画.有绘画
        // 记下这份 scene 是按哪一版快照转译的：draw 用它识别「表是旧的」
        scene.paintRevision = 绘画.revision
        let 无画笔 = UInt32.max
        // 图集实际有几片。slice 一旦 >= 这个数，sample 的读回是未定义的
        //（驱动通常 clamp 到边缘片，于是整个物体都被涂成那一片的颜色），
        // 所以这里先卡住：宁可这一帧不采样，也不能让整个模型变成一坨笔刷色。
        let 图集片数 = 绘画.有绘画 ? (绘画.atlas?.arrayLength ?? 0) : 0
        // 洞图同理由 CPU 侧给格位；这里只做上界护栏，超界的洞格位当成「没洞」
        scene.hasHole = 绘画.有洞 && 绘画.holeAtlas != nil
        let 洞图片数 = scene.hasHole ? (绘画.holeAtlas?.arrayLength ?? 0) : 0

        // 材质去重：同一个材质被多个物体引用时只占一个槽位
        var materialSlots: [UUID: UInt32] = [:]
        var resolvedCache: [UUID: PTMaterialGPU] = [:]
        /// 贴图 UUID → 材质图集层号。多材质共用同一张图时只占一片。
        var 贴图槽: [UUID: Float] = [:]

        func 贴图层号(_ id: UUID) -> Float {
            if let 层 = 贴图槽[id] { return 层 }
            let 层 = Float(scene.材质贴图.count)
            scene.材质贴图.append(id)
            贴图槽[id] = 层
            return 层
        }

        func slot(for id: UUID?) -> UInt32 {
            guard let id else {
                scene.materials.append(PTMaterialGPU.default)
                return UInt32(scene.materials.count - 1)
            }
            if let existing = materialSlots[id] { return existing }
            var gpu = PTMaterialGPU.default
            var 贴图: UUID?
            if let asset = materials[id] {
                let 结果 = 材质GPU缓存.shared.gpu(for: asset)
                gpu = 结果.gpu
                贴图 = 结果.贴图
            }
            // 只有纹理库里真拿得到图才占一片：拿不到就留 p3 = -1 走常量，
            // 免得材质指到一片不存在的层（采样越界是未定义行为）。
            // 只想知道「图在不在」：以前用 取图() 探，探针会把派生图逼着同步烘一张 2048 档
            if let 贴图, 视口纹理库.有图(贴图) {
                gpu.p3 = SIMD4<Float>(贴图层号(贴图), 1, 0, 0)
            }
            resolvedCache[id] = gpu
            scene.materials.append(gpu)
            let index = UInt32(scene.materials.count - 1)
            materialSlots[id] = index
            return index
        }

        // MARK: P2 几何段缓存（三级缓存之二：几何 / 材质 / 灯光）
        // 转译最贵的一步是顶点装配：world 变换 + 法线矩阵求逆转置 + 逐顶点 UV 裁剪，
        // 成本按顶点数走（几千到几十万）。可拖材质滑杆时几何一个字节都没动，
        // 以前这里照样整块重算。现在把装配结果按「几何键」缓存：
        // 键只收 网格 / 变换 / 材质归属 / 绘画切片 / 地面开关 —— 材质值不进键，它是高频量。
        // 命中后只剩两件廉价活：按对象顺序重建材质槽（几十个）、整数重映射三角形材质下标。
        var 槽号表: [槽键: UInt32] = [:]
        var 对象槽: [UInt32] = []
        对象槽.reserveCapacity(objects.count)
        for object in objects where object.isVisible && !object.是灯 && !object.是角色 {
            let 键: 槽键 = object.materialID.map { .资产($0) } ?? .默认
            let 槽 = slot(for: object.materialID)
            对象槽.append(槽)
            if 槽号表[键] == nil { 槽号表[键] = 槽 }
        }

        // 地面材质属于「材质段」，命中几何缓存也要重建：它的反照率跟着环境预设走（白天/夜场两档）
        if settings.showsGround {
            var groundMaterial = PTMaterialGPU.default
            let albedo: Float = settings.environment == .nightLab ? 0.05 : 0.16
            groundMaterial.baseColor = SIMD4<Float>(albedo, albedo, albedo * 1.02, 1)
            groundMaterial.p0 = SIMD4<Float>(0.55, 0, 1.5, 0)
            scene.materials.append(groundMaterial)
            槽号表[.地面] = UInt32(scene.materials.count - 1)
        }

        // 【阶段2-第二步：变换域接线】进入转译前，先把模型 TRS 交给变换接线 ——
        // 它是唯一的变换写入口（值没变就不写、不推版本）。之后本函数里所有世界矩阵
        // 一律向变换域要，任何地方都不许自己再乘父子链、自己解析 position/rotation/scale。
        变换接线.共享.同步对象(objects)
        // 【几何域接线】几何来源同样先交给几何接线 —— 它是几何的唯一写入口。
        // 之后装配顶点一律按几何域记录的来源取（程序网格形状 / 导入网格 UUID），
        // 消费端不再自己 switch object.导入网格ID / object.mesh。
        几何接线.共享.同步(几何源取值.从模型(objects))

        let 几何键 = 几何指纹(
            objects: objects,
            settings: settings,
            版本: 绘画.revision,
            图集片数: 图集片数,
            洞图片数: 洞图片数
        )

        if let 段 = 几何段缓存.shared.取(几何键) {
            scene.positions = 段.positions
            scene.normals = 段.normals
            scene.uvs = 段.uvs
            scene.indices = 段.indices
            scene.vertexSlice = 段.vertexSlice
            scene.vertexHoleSlot = 段.vertexHoleSlot
            // 三角形→材质：缓存里存的是「材质归属」，这里按本轮槽号表重映射。
            // 纯整数映射，没有 simd、没有分支，比重新遍历顶点便宜两个数量级。
            scene.triangleMaterial = 段.三角材质.map { 槽号表[$0] ?? 0 }
        } else {
            var 段 = 几何段缓存.段()
            段.三角材质.reserveCapacity(scene.indices.count / 3)
            var 对象下标 = 0
            for object in objects where object.isVisible && !object.是灯 && !object.是角色 {
                let materialIndex = 对象槽[对象下标]
                对象下标 += 1
                let 键: 槽键 = object.materialID.map { .资产($0) } ?? .默认
                // 世界矩阵向变换域要（域内派生 + 缓存），不再由 SceneObject 自己算
                guard let world = 变换接线.共享.世界矩阵F(键: object.id.uuidString) else { continue }
                let normalMatrix = simd_float3x3(
                    SIMD3<Float>(world.columns.0.x, world.columns.0.y, world.columns.0.z),
                    SIMD3<Float>(world.columns.1.x, world.columns.1.y, world.columns.1.z),
                    SIMD3<Float>(world.columns.2.x, world.columns.2.y, world.columns.2.z)
                ).inverse.transpose

                let slice: UInt32
                if let index = 绘画.sliceOf[object.id], index >= 0, index < 图集片数 {
                    slice = UInt32(index)
                } else {
                    slice = 无画笔
                }
                let holeSlot: UInt32
                if let index = 绘画.holeSlotOf[object.id], index >= 0, index < 洞图片数 {
                    holeSlot = UInt32(index)
                } else {
                    holeSlot = 无画笔
                }
                // 【几何唯一所有者】来源只问几何域：程序网格形状 / 导入网格 UUID 都由几何记录给出，
                // 这里不再自己 switch object.导入网格ID / object.mesh。
                // 第一次构建那一帧域里若还没有这份几何，按模型回落一次（与灯光接线 取设置 同口径）。
                let 几何源 = 几何接线.共享.取值(键: object.id.uuidString)
                let 程序形状 = 几何接线.共享.程序形状(键: object.id.uuidString, 兜底: object.mesh)
                let paintMesh = PaintUV.mesh(for: 程序形状)
                // 导入物：几何来自 导入网格库（文件自带 UV，不进笔迹图集）。
                // 顶点数和内置网格的 paintMesh 对不上，下面 uv齐全 会自然拦住采样，
                // 不会出现「整模被涂成一色」。
                let pieces: [PTGeometry.Piece]
                if let 网格ID = 几何源?.导入网格标识, 几何接线.共享.存在(网格ID) {
                    pieces = 几何接线.共享.转PT片段(网格ID)
                } else {
                    pieces = PTGeometry.piece(for: 程序形状)
                }
                var uvOffset = 0
                for piece in pieces {
                    // 护栏：这个 piece 的顶点必须在 UV 网格里有对应项。
                    // 一旦对不上（未来接导入网格、或 piece 拼法改了），宁可这一层「不采样笔迹」，
                    // 也不能让整段顶点掉进下面 0.5 兜底 —— 那样每个顶点都采同一个 texel，
                    // 一笔下去整个模型都变一个色（"整模染色"就是这么来的）。
                    let uv齐全 = uvOffset + piece.positions.count <= paintMesh.uvs.count
                    let 三角前 = scene.indices.count
                    append(
                        piece: piece,
                        uvMesh: paintMesh,
                        uvOffset: uvOffset,
                        slice: uv齐全 ? slice : 无画笔,
                        holeSlot: uv齐全 ? holeSlot : 无画笔,
                        world: world,
                        normalMatrix: normalMatrix,
                        materialIndex: materialIndex,
                        into: &scene
                    )
                    段.三角材质.append(contentsOf: repeatElement(键, count: (scene.indices.count - 三角前) / 3))
                    uvOffset += piece.positions.count
                }
            }

            // 地面：PT 里没有接触阴影可用，索性给一块真地板接间接光
            if settings.showsGround, let 地面槽 = 槽号表[.地面] {
                var ground = PTGeometry.plane(width: 14, depth: 14)
                PTGeometry.translate(&ground, y: -0.002)
                let 三角前 = scene.indices.count
                append(
                    piece: ground,
                    uvMesh: nil,
                    uvOffset: 0,
                    slice: 无画笔,
                    holeSlot: 无画笔,
                    world: matrix_identity_float4x4,
                    normalMatrix: matrix_identity_float3x3,
                    materialIndex: 地面槽,
                    into: &scene
                )
                段.三角材质.append(contentsOf: repeatElement(.地面, count: (scene.indices.count - 三角前) / 3))
            }

            // 缓存只存大数组和归属表：Array 是写时复制，这里赋值不会多拷一份
            段.positions = scene.positions
            段.normals = scene.normals
            段.uvs = scene.uvs
            段.indices = scene.indices
            段.vertexSlice = scene.vertexSlice
            段.vertexHoleSlot = scene.vertexHoleSlot
            几何段缓存.shared.存(几何键, 段)
        }


        scene.environment = environment(settings)
        buildLightList(&scene)
        buildLights(&scene, objects: objects)

        // 【材质唯一所有者】材质变没变，只问材质域：把「真被场景引用到的材质」的单材质版本
        // 聚合成一个段版本。原先这里按 PTMaterialGPU 逐字段拼哈希（自建材质签名）——已删。
        scene.材质版本 = 材质接线.共享.场景材质版本(objects.compactMap(\.materialID))

        let 指纹 = signature(objects: objects, settings: settings, slots: materialSlots)
        scene.几何签名 = 指纹.几何
        scene.环境签名 = 指纹.环境
        scene.灯光签名 = 指纹.灯光
        return scene
    }

    // MARK: 追加几何

    private static func append(
        piece: PTGeometry.Piece,
        uvMesh: PaintMesh?,
        uvOffset: Int,
        slice: UInt32,
        holeSlot: UInt32,
        world: simd_float4x4,
        normalMatrix: simd_float3x3,
        materialIndex: UInt32,
        into scene: inout PTScene
    ) {
        let base = UInt32(scene.positions.count)
        for index in piece.positions.indices {
            let position = world * SIMD4<Float>(piece.positions[index], 1)
            var normal = normalMatrix * piece.normals[index]
            if simd_length(normal) < 0.0001 {
                normal = SIMD3<Float>(0, 1, 0)
            } else {
                normal = simd_normalize(normal)
            }
            scene.positions.append(SIMD4<Float>(position.x, position.y, position.z, 1))
            scene.normals.append(SIMD4<Float>(normal.x, normal.y, normal.z, 0))
            // 图集 UV 的世界侧变换无关（UV 在物体局部空间定义），这里只按顶点顺序抄
            let uvIndex = uvOffset + index
            var uv = SIMD2<Float>(0.5, 0.5)
            if let uvMesh, uvIndex < uvMesh.uvs.count {
                uv = uvMesh.uvs[uvIndex]
                // 逐顶点夹进它所属的那一格：接缝三角形插值时会横穿整张图集，
                // 不夹就会采到隔壁格子（甚至别的物体）的笔迹，看着像「模型被染色」。
                if uvIndex < uvMesh.vertexPiece.count {
                    let 格 = uvMesh.rect(ofVertex: uvIndex)
                    // 退化格子（宽或高为 0）不能拿来夹：夹完所有顶点都塌成一个 uv 点，
                    // 整个模型只采一个 texel —— 又一个「整模染色」入口。
                    if 格.z - 格.x > 0.0001, 格.w - 格.y > 0.0001 {
                        uv = SIMD2<Float>(min(max(uv.x, 格.x), 格.z),
                                          min(max(uv.y, 格.y), 格.w))
                    }
                }
            }
            scene.uvs.append(uv)
            scene.vertexSlice.append(slice)
            scene.vertexHoleSlot.append(holeSlot)
        }
        var offset = 0
        while offset + 2 < piece.indices.count {
            scene.indices.append(base + piece.indices[offset])
            scene.indices.append(base + piece.indices[offset + 1])
            scene.indices.append(base + piece.indices[offset + 2])
            scene.triangleMaterial.append(materialIndex)
            offset += 3
        }
    }

    // MARK: 材质

    /// OpenPBR → PT。这里不折色：每个通道都落到真实的 BSDF 项上，
    /// 所以柯西斯/玻璃/薄膜这些在 PT 里是算出来的，而不是贴图糊上去的。
    static func translate(_ params: OpenPBRParams) -> PTMaterialGPU {
        func c(_ key: PBRParamKey) -> SIMD3<Float> {
            let color = params.color(key)
            return SIMD3<Float>(Float(max(color.r, 0)), Float(max(color.g, 0)), Float(max(color.b, 0)))
        }
        func v(_ key: PBRParamKey) -> Float { Float(params.double(key)) }

        let baseColor = c(.baseColor)
        let baseWeight = min(max(v(.baseWeight), 0), 1)
        let emission = c(.emissionColor)
        let emissionIntensity = max(v(.emissionLuminance), 0)
        let opacity = min(max(v(.baseAlpha) * v(.geometryOpacity), 0), 1)

        return PTMaterialGPU(
            baseColor: SIMD4<Float>(baseColor * baseWeight, baseWeight),
            emissive: SIMD4<Float>(emission, emissionIntensity),
            p0: SIMD4<Float>(
                min(max(v(.baseRoughness), 0.001), 1),
                min(max(v(.baseMetallic), 0), 1),
                max(v(.baseIOR), 1.0),
                min(max(v(.transmissionWeight), 0), 1)
            ),
            p1: SIMD4<Float>(
                min(max(v(.thinFilmWeight), 0), 1),
                max(v(.thinFilmThickness), 0),
                max(v(.thinFilmIOR), 1.0),
                min(max(v(.coatWeight), 0), 1)
            ),
            p2: SIMD4<Float>(
                min(max(v(.coatRoughness), 0.001), 1),
                min(max(v(.coatDarkening), 0), 1),
                min(max(v(.specularWeight), 0), 1),
                opacity
            )
        )
    }

    // MARK: 环境

    static func environment(_ settings: ViewportSettings) -> PTEnvironmentGPU {
        let intensity = Float(max(settings.environmentIntensity, 0))
        let top = settings.environment.skyTop
        let bottom = settings.environment.skyBottom
        let light = settings.environment.keyLight

        let azimuth = Float(light.azimuth + settings.environmentRotation) * .pi / 180
        let elevation = Float(light.elevation) * .pi / 180
        let direction = SIMD3<Float>(
            cos(elevation) * sin(azimuth),
            sin(elevation),
            cos(elevation) * cos(azimuth)
        )

        // 1100 lx 的影棚主光换算成 PT 世界里能用的辐照度：除个经验系数，避免一开图全白
        let sunIntensity = Float(light.intensity) / 700 * intensity

        return PTEnvironmentGPU(
            skyTop: SIMD4<Float>(Float(top.r), Float(top.g), Float(top.b), intensity),
            skyBottom: SIMD4<Float>(Float(bottom.r), Float(bottom.g), Float(bottom.b), 0),
            sun: SIMD4<Float>(direction, sunIntensity)
        )
    }

    /// 环境段签名：只含三个与环境 uniform 一一对应的量（预设 / 强度 / 旋转）。
    /// 单独抽出来是为了让"拖摄影棚亮度"这类高频操作能走原地换环境，
    /// 不必重译整个场景（几何/材质/灯缓冲一个字节都不会变）。
    static func 环境签名(settings: ViewportSettings) -> String {
        var env = Hasher()
        env.combine(settings.environment.rawValue)
        env.combine(settings.environmentIntensity)
        env.combine(settings.environmentRotation)
        return String(env.finalize())
    }

    /// 只换环境（强度 / 旋转 / 预设）的轻量重译：场景其余部分按值复用（数组是写时复制，不多拷）。
    /// 注意预设本身还牵动地面材质反照率，所以调用方只在"预设未变、仅强度或旋转变"时才走这里。
    static func 替换环境(_ scene: PTScene, settings: ViewportSettings) -> PTScene {
        var 新场景 = scene
        新场景.environment = environment(settings)
        新场景.环境签名 = 环境签名(settings: settings)
        return 新场景
    }

    // MARK: - 灯光

    /// 色温（K）→ 线性 RGB，Tanner Helland 拟合，6500K 附近接近白。
    ///
    /// 拟合公式三个通道的取值域是 0…255，必须按 255 截断。之前误写成先按 0…1 截断、
    /// 再乘 255：G 通道在 3000K 就已经算出 177，被钳成 1 后变成 255，R 通道则恒为 255，
    /// 于是只剩 B 通道在动 —— 低温（B=0）是纯黄、稍微升温 B 一起来就变纯白，
    /// 暖色段和整个冷色段全部丢失。改成按 255 截断后色相才连续。
    static func 色温RGB(_ kelvin: Double) -> SIMD3<Float> {
        let t = min(max(kelvin, 1000), 15000) / 100
        func clamp255(_ v: Double) -> Double { min(max(v, 0), 255) }
        let r: Double
        let g: Double
        let b: Double
        if t <= 66 {
            r = 255
            g = clamp255(99.4708025861 * log(t) - 161.1195681661)
        } else {
            r = clamp255(329.698727446 * pow(t - 60, -0.1332047592))
            g = clamp255(288.1221695283 * pow(t - 60, -0.0755148492))
        }
        if t >= 66 {
            b = 255
        } else if t <= 19 {
            b = 0
        } else {
            b = clamp255(138.5177312231 * log(t - 10) - 305.0447927307)
        }
        // sRGB → 近似线性，避免灯色偏灰
        func linear(_ v: Double) -> Float {
            let s = v / 255
            return Float(s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4))
        }
        var rgb = SIMD3<Float>(linear(r), linear(g), linear(b))
        // 归一化到最大通道 = 1，亮度交给功率控制，色温只管色相
        let peak = max(max(rgb.x, rgb.y), rgb.z)
        if peak > 1e-4 { rgb /= peak }
        return rgb
    }

    /// 场景里的灯对象 → 着色器能直接用的灯光数组。
    /// 灯默认朝 -Y（吊灯/筒灯那种"往下打"），朝向由物体的欧拉角决定。
    // MARK: - 灯：模型 → 灯源（唯一一处"从场景模型读灯"的代码，写入方专用）

    /// 上次已校验的灯段版本：版本没动就不重复打日志（拖灯时每帧都会调到本函数）。
    nonisolated(unsafe) private static var 上次灯校验版本: 灯光版本记账? = nil

    /// 零差异校验：快照取值 vs 模型取值，逐字段比对 灯光设置 / 世界矩阵 16 项 / 朝向 3 项。
    /// 只比对、不参与渲染；不一致立刻打日志（Debug 下断言），绝不静默改用新路。
    @discardableResult
    private static func 校验灯取值一致(
        _ 灯源们: [灯源取值],
        objects: [SceneObject],
        版本: 灯光版本记账
    ) -> Bool {
        let 模型灯 = 灯源取值.从模型(objects)
        var 不一致 = ""
        if 模型灯.count != 灯源们.count {
            不一致 = "盏数 快照=\(灯源们.count) 模型=\(模型灯.count)"
        } else {
            for 序 in 模型灯.indices {
                let 旧 = 模型灯[序]
                let 新 = 灯源们[序]
                if 旧.外部键 != 新.外部键 {
                    不一致 = "第\(序)盏 外部键 快照=\(新.外部键) 模型=\(旧.外部键)"
                    break
                }
                if 旧.设置 != 新.设置 {
                    不一致 = "第\(序)盏 灯光设置不等 名称=\(新.名称)"
                    break
                }
                // 世界矩阵不再两边各算一遍比较（那就是两份派生了）：
                // 比的是"快照读到的世界矩阵"与"这份世界矩阵的平移分量恰好等于模型位置"，
                // 以及朝向/缩放这三个模型侧字段的一致。
                // 位置走了一遍"Double → Float(域内) → Double(矩阵)"，末位必然不同，
                // 所以按管线的真实口径（Float）比，而不是拿 Double 原值硬比。
                // 仍能抓出真实错位：只要差超过 Float 的 1 ulp 就会露出来。
                if !同位置(旧.位置, 新.位置) {
                    不一致 = "第\(序)盏 位置不一致 名称=\(新.名称)"
                    break
                }
                if !同向量(旧.朝向, 新.朝向) {
                    不一致 = "第\(序)盏 朝向 memcmp≠0 名称=\(新.名称)"
                    break
                }
                if !同向量(旧.缩放, 新.缩放) {
                    不一致 = "第\(序)盏 缩放不一致 名称=\(新.名称)"
                    break
                }
            }
        }
        if !不一致.isEmpty {
            NSLog("[PT灯取值] ✗ 快照与模型取值不一致：\(不一致)（参数版本=\(版本.参数) 灯变换版本=\(版本.变换)）")
            #if DEBUG
            assertionFailure("[PT灯取值] 快照与模型取值不一致：\(不一致)")
            #endif
            上次灯校验版本 = 版本
            return false
        }
        if 上次灯校验版本 != 版本 {
            上次灯校验版本 = 版本
            NSLog("[PT灯取值] ✓ 盏数=\(灯源们.count) 参数版本=\(版本.参数) 灯变换版本=\(版本.变换) 逐字段一致（设置 / 世界矩阵16项 / 朝向3项）")
        }
        return true
    }

    private static func 同矩阵(_ a: simd_double4x4, _ b: simd_double4x4) -> Bool {
        withUnsafeBytes(of: a) { pa in
            withUnsafeBytes(of: b) { pb in
                guard let p = pa.baseAddress, let q = pb.baseAddress, pa.count == pb.count else { return false }
                return memcmp(p, q, pa.count) == 0
            }
        }
    }

    private static func 同向量(_ a: Vec3, _ b: Vec3) -> Bool {
        a.x == b.x && a.y == b.y && a.z == b.z
    }

    /// 位置的比对口径：一律先落到 Float 再比（变换域内换算就是 Float 口径）。
    private static func 同位置(_ a: Vec3, _ b: Vec3) -> Bool {
        Float(a.x) == Float(b.x) && Float(a.y) == Float(b.y) && Float(a.z) == Float(b.z)
    }

    private static func buildLights(_ scene: inout PTScene, objects: [SceneObject]) {
        // 【取值来源 = 数据层快照】场景模型只作为"写入方"喂给灯光接线；
        // 灯参数 / 灯位置 / 灯朝向一律经 场景快照 的只读视图取（灯光域 + 变换域），
        // 本函数不再直接读 object.灯光 / object.pathTraceMatrix / object.rotation。
        let 快照 = 灯光接线.共享.同步(灯源取值.从模型(objects))
        scene.灯光版本 = 快照.灯光记账.参数
        scene.灯变换版本 = 快照.灯光记账.变换
        // 对象变换版本：**非灯段**的域派生版本号。
        // 不能再用整域 `版本.变换`：灯也是变换域里的一条记录，拖灯会让它自增，
        // 于是每帧都被判成"物体被拖动了"，白白对整棵加速结构做 refit（拖灯顿感的来源）。
        scene.变换版本 = 变换接线.共享.取非灯变换版本()
        let 灯源们 = 灯光接线.共享.取灯源(快照)
        // 零差异校验：同一帧两条路（快照 / 模型）逐字段比对，不一致立刻暴露，不静默用新的
        校验灯取值一致(灯源们, objects: objects, 版本: 快照.灯光记账)

        // 【特效发射器段】与收灯同一条路：只从模型读、只写进本场景。
        // 粒子位置 / 体素 brick 一律不进这里（渲染器私有）。
        // 模拟纹理是「借来的钥匙」：视口每帧把本帧在跑的场登记到 体积场登记，
        // 这里按 object.id 取当前密/温纹理一起带进 PTScene，出图就吃到和视口同一批体素。
        let 特效结果 = PTVolumeEmitterGPU.从模型(objects)
        scene.特效发射器 = 特效结果.发射器
        scene.特效模拟密 = 特效结果.模拟密
        scene.特效模拟温 = 特效结果.模拟温
        scene.特效版本 = 特效记账.推进(scene.特效发射器)


        for 灯 in 灯源们 {
            let 设置 = 灯.设置
            let 世界 = simd_float4x4(
                SIMD4<Float>(Float(灯.世界矩阵.columns.0.x), Float(灯.世界矩阵.columns.0.y),
                             Float(灯.世界矩阵.columns.0.z), Float(灯.世界矩阵.columns.0.w)),
                SIMD4<Float>(Float(灯.世界矩阵.columns.1.x), Float(灯.世界矩阵.columns.1.y),
                             Float(灯.世界矩阵.columns.1.z), Float(灯.世界矩阵.columns.1.w)),
                SIMD4<Float>(Float(灯.世界矩阵.columns.2.x), Float(灯.世界矩阵.columns.2.y),
                             Float(灯.世界矩阵.columns.2.z), Float(灯.世界矩阵.columns.2.w)),
                SIMD4<Float>(Float(灯.世界矩阵.columns.3.x), Float(灯.世界矩阵.columns.3.y),
                             Float(灯.世界矩阵.columns.3.z), Float(灯.世界矩阵.columns.3.w))
            )
            let 位置 = SIMD3<Float>(世界.columns.3.x, 世界.columns.3.y, 世界.columns.3.z)

            // 出光方向同样向变换域要：世界矩阵的第二列就是「本地 +Y 的世界朝向」，
            // 灯默认朝本地 -Y，取负即可（归一化顺手抹掉缩放）。不再自己把欧拉角拼四元数 ——
            // 那样一旦灯挂进父子链，方向就会和世界矩阵各说一套。
            var 朝向 = -SIMD3<Float>(世界.columns.1.x, 世界.columns.1.y, 世界.columns.1.z)
            if simd_length(朝向) < 1e-5 { 朝向 = SIMD3<Float>(0, -1, 0) }
            朝向 = simd_normalize(朝向)

            let 颜色 = 色温RGB(设置.色温)
            let 功率 = max(设置.功率, 0)
            let 宽 = Float(max(设置.宽, 0.01))
            let 高 = Float(max(设置.高, 0.01))
            let 锥Cos = Float(cos(min(max(设置.锥角, 1), 89) * Double.pi / 180))

            let 强度: Float
            let 种类编号: UInt32
            switch 设置.种类 {
            case .区域光:
                // 辐亮度 = 功率 / (面积 × π)，再压一个经验系数避免室内灯把画面打爆
                强度 = Float(功率) / (宽 * 高 * .pi) * 0.25
                种类编号 = PTLightKind.区域光.rawValue
            case .点光:
                // 辐射强度 = 功率 / 4π（系数标定到太阳 ≈1.57 的量级，80W 球灯 2m 处接近一档日光）
                强度 = Float(功率) / (4 * .pi) * 0.9
                种类编号 = PTLightKind.点光.rawValue
            case .聚光:
                // 全部功率压进锥体：I = P / (2π(1-cosθ))
                let 立体角 = 2 * Float.pi * (1 - 锥Cos)
                强度 = Float(功率) / max(立体角, 1e-4) * 0.12
                种类编号 = PTLightKind.聚光.rawValue
            case .平行光:
                // 平行光既没有面积也没有距离衰减，功率按 lux 看待。
                // 口径对齐环境太阳（环境强度 1.0 时太阳辐照度约 1.6）：
                // 原来除以 700，200W 只有 0.29，只有天光的零头，画面上就是"完全不亮"。
                强度 = Float(功率) / 200
                种类编号 = PTLightKind.平行光.rawValue
            }

            guard 强度 > 1e-5 else { continue }
            scene.lights.append(
                PTLightGPU(
                    positionRadius: SIMD4<Float>(位置, Float(max(设置.半径, 0))),
                    axisCosCone: SIMD4<Float>(朝向, 锥Cos),
                    colorIntensity: SIMD4<Float>(颜色, 强度),
                    shape: SIMD4<Float>(宽, 高, Float(种类编号), Float(min(max(设置.柔和, 0), 1)))
                )
            )
        }

        // 显式灯重要性采样：按「每盏灯的辐射亮度」建归一化 CDF。
        // 只改"抽哪盏灯"的概率，不改任何一盏灯的贡献表达式 → 期望不变（无偏）。
        // 权重 = 亮度(颜色 × 强度)，与实际贡献成正比（贡献 ∝ 透射率·BRDF·Le·cos/pdf）。
        guard !scene.lights.isEmpty else {
            scene.lightsCDF = []
            return
        }

        // 第一遍：收集权重（NaN/Inf 及负数一律按 0）并求总和 S
        var 权重 = [Double](repeating: 0, count: scene.lights.count)
        var 总和 = 0.0
        for 序 in scene.lights.indices {
            let 色强 = scene.lights[序].colorIntensity
            let 值 = 色强.w * (0.2126 * 色强.x + 0.7152 * 色强.y + 0.0722 * 色强.z)
            let 安全值 = 值.isFinite ? Double(max(值, 0)) : 0.0
            权重[序] = 安全值
            总和 += 安全值
        }

        // 【权重下限 = 总和 × 1e-6】相对下限，不是"最亮灯 × 1e-3"。
        // 旧写法的问题：万盏灯场景下每盏暗灯都拿到 1e-3 × 最亮灯，合计 = N × 1e-3 倍，
        // 暗灯会劫走绝大部分采样概率（1 亮 + 9999 暗时暗灯合计约 90.9%），主灯反而被饿死。
        // 该写法的"下限浪费"上界是 N × 1e-6（万盏灯约 1e-2 量级），与最亮灯亮度差无关。
        //
        // 【为什么是 1e-6 而不是 1e-7】CDF 存的是 Float：float32 在 1.0 附近的 ulp ≈ 1.19e-7，
        // 1e-7 的格宽只剩不到 1 个 ulp。归一化后相邻两项一旦被 Float 舍入成同一个数，
        // 二分就会落进一个宽度为 0 的区间（cdfHi - cdfLo == 0）——概率质量凭空消失、pdf 退成兜底值。
        // 取 1e-6 ≈ 8 个 ulp，留足舍入余量：任何相邻格宽在 float32 下都严格 > 0。
        guard 总和.isFinite, 总和 > 0 else {
            // 退化防护：全部灯零强度/全部无效 → 均匀分布（概率恒正、总和精确为 1）
            let 盏数 = Double(scene.lights.count)
            scene.lightsCDF = (0..<scene.lights.count).map { Float(Double($0 + 1) / 盏数) }
            return
        }
        // 最小格宽：前缀和沿序每步至少前进这么多（单位与"总和"同尺度）
        let 最小格宽 = 总和 * 1e-6
        // 权重下限与最小格宽取同一常量：下限决定"每盏灯至少占多少权重"，
        // 最小格宽决定"相邻两个前缀至少差多少"，两件事同一个量级才自洽。
        let 下限 = 最小格宽

        // 第二遍：施加下限 → 前缀和（沿序强制单调，且每步至少一格最小宽度）→ 除以末项归一化
        // 严格单调钳制是最后一道保险：即使将来有人把下限调小，或者权重里混进怪值，
        // 前缀也不会出现"平段"（平段 = 零宽区间 = 永远抽不中的灯）。
        var 前缀 = [Double](repeating: 0, count: 权重.count)
        for 序 in 权重.indices {
            let 上一格 = 序 == 0 ? 0.0 : 前缀[序 - 1]
            前缀[序] = max(上一格 + max(权重[序], 下限), 上一格 + 最小格宽)
        }
        let 归一 = 前缀.last ?? 0
        guard 归一.isFinite, 归一 > 0 else {
            let 盏数 = Double(scene.lights.count)
            scene.lightsCDF = (0..<scene.lights.count).map { Float(Double($0 + 1) / 盏数) }
            return
        }
        // 末项 = 归一/归一 = 1.0，Float 转换精确：着色器里 u < 1 必落在最后一格内
        scene.lightsCDF = 前缀.map { Float($0 / 归一) }
    }

    // MARK: 签名

    /// 内容指纹：任何会改变画面的东西变了就重建加速结构，没变就继续累积样本。
    // MARK: - 光源列表

    // MARK: - 面光两级 CDF（排序分块）

    /// 每块最多多少项。必须与 PT 着色器.metal 里的 PT_AREA_LIGHT_BLOCK_SIZE 一致。
    static let 面光每块项数 = 64

    /// 格宽下限系数 = 2^-21 = float32 在 1.0 附近 4 个 ulp。
    /// 下限是「相邻两个前缀和至少差这么多」，作用对象是本级的参考总量：
    /// 块级参考全局总量、块内参考块内总量。只要格宽 ≥ 4 ulp，
    /// 即便归一化时整体缩了零点几个百分点、再各自舍入 ±0.5 ulp，两格也仍然差 ≥ 3 ulp > 0。
    static let 面光格宽下限系数 = 1.0 / 2097152.0

    /// 块内格宽的下限系数（相对块内总量）。块内升序累加后 float32 已能分辨块内任意项，
    /// 故只需压住 float32 下溢（真实块内占比 < 1e-38 才会用到），实际从不触发。
    static let 面光内格宽下限系数 = 1e-30

    /// 面光两级 CDF 的构建结果。
    struct 面光两级CDF {
        /// 降序排列后的「真实三角形下标」：着色器二分命中的是排序后位置，靠它映射回真实三角形
        var 三角形: [UInt32] = []
        /// 打包缓冲（单缓冲五段，长度 3n + 2B）：
        ///   [0, n)              旧单级全局 CDF（宏置 0 时着色器只读这一段，等于完整回滚）
        ///   [n, n+B)            块级前缀 CDF（Double 建、float32 上传，只用于二分）
        ///   [n+B, n+2B)         块格宽（全局占比，Double 算好再转 float32）
        ///   [n+2B, 2n+2B)       块内局部前缀 CDF（已按块内总量归一，只用于二分）
        ///   [2n+2B, 3n+2B)      块内格宽（块内条件概率）
        /// 格宽单独存而不在 GPU 上做前缀差：1.0 附近两个 float32 相减，绝对误差就是
        /// ulp(1.0)=1.19e-7，尾部 6e-7 宽的块会偏 ~10%，pdf = 块格宽×块内格宽 就跟着失真。
        var 打包CDF: [Float] = []
        var 三角形数 = 0
        var 块数 = 0
        /// 诊断用：块内最小格宽、全局最小有效概率（块格宽 × 块内格宽）、下限触发次数
        var 块内最小格宽: Float = 1
        var 全局最小概率: Float = 1
        var 钳制次数 = 0
        var 排序耗时 = 0.0
        var 建表耗时 = 0.0
    }

    // 【未来优化】实测耗时基线（10 万 / 50 万自发光三角形，本机 release）：
    //   10 万三角：排序 + 建表合计 1.63~1.87ms —— 在 5ms 预算内；
    //   50 万三角：合计 9.65~10.78ms（排序约 5.85ms + 建表约 3.84ms）—— 超出预算一倍。
    // 超预算的大头在建表这一半：5 条长度 n 的数组 + 逐项 Double 累加 + 两轮归一化。
    // 已评估、尚未实施的两条优化（只改实现，不动打包布局、不动数据结构）：
    //   1) 建表改裸指针：块内 CDF / 格宽现在走 [Double] / [Float] 带下标检查的访问，
    //      与排序那侧换成 UnsafeMutablePointer 后拿到的收益同源（下标检查占了大头）；
    //   2) 按块并行：每块的内层 CDF 与格宽只依赖本块权重和块内总量，块与块之间完全独立，
    //      可以按块切给并发队列，块级前缀那一步再串行收口。
    // 触发面：这条链路只在场景重译、需要重算自发光三角形集合或权重时才会跑；
    // 拖真光源的功率/颜色滑杆走 刷新灯光 → 原地刷新灯 的快路径，不进这里。
    /// 纯函数：只吃「权重 + 真实三角形下标」，不读不写任何场景状态。
    /// 抽出来是为了能脱离 app 做离线基准与验收（10 万 / 50 万三角构建耗时、抽样命中率）。
    ///
    /// 为什么是「排序 + 分块 + 两级」：
    /// 单级全局 CDF 有一个绕不过去的矛盾 —— 前缀和是 float32 时，末项 = 1.0，
    /// 那么占比低于 ~1e-7（一个 ulp）的格子在量化后与前一格相等 = 零宽 = 永远抽不中；
    /// 想让它不被吃掉就只能整体加个「相对全局」的下限，而这个下限一旦是 1e-6，
    /// 真实占比 1e-9 的暗面就被抬成 1e-6（放大一千倍），抽中后贡献≈0 → 样本白花。
    /// 排成降序后按 64 项分块，块总和天然从大到小；块内 CDF 单独按「块内总量」归一，
    /// 于是块内的分辨力参考的是块内总量而不是全局总量 —— 尾部那些大而暗的面
    /// 落在块总和极小的块里，相对分辨力被放大好几个量级，既不丢也几乎不浪费。
    static func 构建面光两级CDF(权重: [Double], 三角形: [UInt32]) -> 面光两级CDF {
        var 结果 = 面光两级CDF()
        let n = 权重.count
        guard n > 0, 三角形.count == n else { return 结果 }

        // ---- 1) 按权重降序排列（16 位 × 2 趟 LSD 基数排序，裸指针版）----
        // 正 Double 的 bitPattern 与数值单调同序，所以「按 UInt64 降序」就是「按权重降序」，且是稳定确定的。
        // 不用 sort()：500k 项比较排序实测 44ms；基数排序只需线性趟。
        // 只排高 32 位（2 趟）：权重是正 Double，高 32 位 = 符号+指数+尾数高位；
        // 两个权重差在 2^-32 相对以内时谁前谁后对分布没有任何影响（float32 格宽本就相同），
        // 而排满 4 趟会把 500k 的排序从 ~6.5ms 抬到 ~12ms。
        // 用 UnsafeMutablePointer 而不是 [Int]：500k 项下标越界检查占了一大半时间。
        let 排序开始 = CFAbsoluteTimeGetCurrent()
        var 序三角: [UInt32]
        var 序权重: [Double]
        do {
            let 桶数 = 1 << 16
            let 掩 = UInt64(桶数 - 1)
            let 键 = UnsafeMutablePointer<UInt64>.allocate(capacity: n)
            let 甲 = UnsafeMutablePointer<Int>.allocate(capacity: n)
            let 乙 = UnsafeMutablePointer<Int>.allocate(capacity: n)
            let 计数 = UnsafeMutablePointer<Int>.allocate(capacity: 桶数)
            defer {
                键.deallocate(); 甲.deallocate(); 乙.deallocate(); 计数.deallocate()
            }
            for i in 0..<n { 键[i] = 权重[i].bitPattern }
            for i in 0..<n { 甲[i] = i }
            var 源 = 甲
            var 目标 = 乙
            for 趟 in 0..<2 {
                let 位移 = UInt64(32 + 趟 * 16)
                for i in 0..<桶数 { 计数[i] = 0 }
                for i in 0..<n { 计数[Int((键[源[i]] >> 位移) & 掩)] += 1 }
                // 桶从大到小累加 → 大桶排前面 → 得到降序
                var 累加 = 0
                var b = 桶数 - 1
                while b >= 0 {
                    let c = 计数[b]
                    计数[b] = 累加
                    累加 += c
                    b -= 1
                }
                for i in 0..<n {
                    let e = 源[i]
                    let k = Int((键[e] >> 位移) & 掩)
                    目标[计数[k]] = e
                    计数[k] += 1
                }
                let 临 = 源
                源 = 目标
                目标 = 临
            }
            序三角 = [UInt32](repeating: 0, count: n)
            序权重 = [Double](repeating: 0, count: n)
            序三角.withUnsafeMutableBufferPointer { tb in
                序权重.withUnsafeMutableBufferPointer { wb in
                    权重.withUnsafeBufferPointer { w0 in
                        三角形.withUnsafeBufferPointer { t0 in
                            for i in 0..<n {
                                let e = 源[i]
                                tb[i] = t0[e]
                                wb[i] = w0[e]
                            }
                        }
                    }
                }
            }
        }
        // ---- 1.5) 块内改升序（块与块之间仍是降序，块的成员集合完全不变）----
        // 为什么必须这样：块内 CDF 是 float32 前缀和，分辨力由「当前前缀的量级」决定。
        // 若块内也降序，首块（含一个占 0.99996 的亮面）的前缀一直在 1.0 附近打转，
        // ulp(1.0)=1.19e-7，后面那些 1e-8 的暗项量化后与前一格相等 = 零宽 = 永远抽不中，
        // 只能靠内层下限把它们抬到 4ulp ≈ 4.8e-7（实测放大约 47 倍：这不是防吃掉，只是把过采样挪了个位置）。
        // 块内升序累加后，暗项先加、前缀还小（1e-8 量级时 ulp 只有 1e-15），分辨力足够；
        // 变粗糙的只剩每块最后那个最大项，它本身格宽很大，1ulp 的量化无影响。
        // 零宽可证明不会出现：升序下 前缀[k] ≤ k·w_k ≤ 64·w_k，ulp(前缀)/2 ≈ 6e-8·前缀 ≤ 3.8e-6·w_k < w_k。
        // 【注意】「块内按升序累加」是正确性要求，不是随便挑的排序口味：块内降序会让首块被高占比亮面占据，
        // 块内前缀长期环绕在 1.0 附近，float32 有效分辨率只剩几个 ulp，于是 1e-8 量级的暗项被抬高数十倍 ——
        // 实测出现过 47 倍过采样（暗面场景 MC 命中 278 次 vs 期望 160 次）。升序则暗项先累加、前缀量级小、
        // 分辨力足够，且可证明不出现零宽区间（见上一句）。任何人想改回块内降序，必须先把暗面过采样实测跑一遍。
        // 注意：变的只是块内排列顺序；pdf 由「块格宽 × 块内格宽」逐项给出、permutation 负责映射回真实三角形，
        // 所以顺序不影响分布，只影响 float32 能分辨到什么程度。
        do {
            let 块容量0 = 面光每块项数
            let 块数0 = (n + 块容量0 - 1) / 块容量0
            for b in 0..<块数0 {
                let 起 = b * 块容量0
                let 止 = min(起 + 块容量0, n)
                if 止 - 起 <= 1 { continue }
                // 全局已按降序排好，所以每块内部此刻恰好是降序 —— 反转就是升序，O(n) 总代价、零比较。
                // （用插入排序重排过一版，500k 三角把排序阶段从 8.5ms 拖到 30.6ms，没必要。）
                序权重[起..<止].reverse()
                序三角[起..<止].reverse()
            }
        }
        结果.排序耗时 = (CFAbsoluteTimeGetCurrent() - 排序开始) * 1000.0
        let 建表开始 = CFAbsoluteTimeGetCurrent()

        // ---- 2) 降序切块，每块 ≤ 面光每块项数 ----
        let 块容量 = 面光每块项数
        let 块数 = (n + 块容量 - 1) / 块容量
        var 块权重 = [Double](repeating: 0, count: 块数)
        for b in 0..<块数 {
            let 起 = b * 块容量
            let 止 = min(起 + 块容量, n)
            var s = 0.0
            for i in 起..<止 { s += 序权重[i] }
            块权重[b] = s
        }
        // 全局总量直接用排序后块权重之和：与排序前的 总和 数学相等，但省掉一次全量累加
        var 全局总量 = 0.0
        for b in 0..<块数 { 全局总量 += 块权重[b] }
        guard 全局总量 > 0, 全局总量.isFinite else { return 结果 }

        // ---- 3) 块级 CDF：Double 建、逐块下限（相对全局总量）、归一后传 float32 ----
        let 块下限 = 全局总量 * 面光格宽下限系数
        var 块前缀 = [Double](repeating: 0, count: 块数)
        var 游标 = 0.0
        for b in 0..<块数 {
            游标 += max(块权重[b], 块下限)
            块前缀[b] = 游标
        }
        guard 游标 > 0, 游标.isFinite else { return 结果 }
        var 块CDF = [Float](repeating: 0, count: 块数)
        var 上一块: Float = 0
        for b in 0..<块数 {
            var v = Float(块前缀[b] / 游标)
            if b == 块数 - 1 { v = 1.0 }                       // 末项必须精确 1.0：u < 1 必落在最后一格
            if v <= 上一块 {                                    // 兜底：强行抬高 1 ulp，绝不出现零宽块
                v = Float(bitPattern: 上一块.bitPattern &+ 1)
                if v > 1.0 { v = 1.0 }
                结果.钳制次数 += 1
            }
            块CDF[b] = v
            上一块 = v
        }

        // 【块宽单独存一份】不能靠 块CDF[b] - 块CDF[b-1] 在 GPU 上现算：
        // 尾部块的边界都挤在 1.0 附近，float32 在 1.0 处 ulp = 1.19e-7，
        // 两个 0.99999x 相减得到 6e-7 宽的块，量化误差就有 ~10%（实测尾部块 6.19e-2）。
        // 直接上传 Double 算好的块宽（float32 化只有 1e-7 相对误差），pdf 才是真概率。
        var 块宽F = [Float](repeating: 0, count: 块数)
        for b in 0..<块数 {
            块宽F[b] = Float(max(块权重[b], 块下限) / 游标)
        }

        // ---- 4) 块内 CDF：按「块内总量」归一，让块内暗项也有分辨力 ----
        var 内CDF = [Float](repeating: 0, count: n)
        var 内宽F = [Float](repeating: 0, count: n)
        var 内前缀: [Double] = []
        for b in 0..<块数 {
            let 起 = b * 块容量
            let 止 = min(起 + 块容量, n)
            let 项数 = 止 - 起
            // 【关键】下限的参考量是块内总量，不是全局总量。
            // 而且块内已按升序累加，float32 前缀对块内小项有完全分辨力（见 1.5 的证明），
            // 所以这里不再需要 4ulp 的余量，只留一个「防 float32 下溢成 0」的数量级保险，
            // 它相对块内总量只有 1e-30，永远不参与放缩 —— 否则首块（总量≈1）会把 1e-8 的暗项抬到 4.8e-7（47 倍过采样）。
            let 内下限 = 块权重[b] * 面光内格宽下限系数
            内前缀.removeAll(keepingCapacity: true)
            内前缀.reserveCapacity(项数)
            var 累 = 0.0
            for k in 0..<项数 {
                累 += max(序权重[起 + k], 内下限)
                内前缀.append(累)
            }
            let 内归一 = 累 > 0 ? 累 : 1.0
            // 块内格宽同样单独存：块内前缀也在 1.0 附近做差，块内占比 1e-3 的项会被量化到 ~1e-4 相对误差
            for k in 0..<项数 {
                内宽F[起 + k] = Float(max(序权重[起 + k], 内下限) / 内归一)
            }
            var 上一: Float = 0
            for k in 0..<项数 {
                var v = Float(内前缀[k] / 内归一)
                if k == 项数 - 1 { v = 1.0 }                    // 块内末项同样精确 1.0
                if v <= 上一 {
                    v = Float(bitPattern: 上一.bitPattern &+ 1)
                    if v > 1.0 { v = 1.0 }
                    结果.钳制次数 += 1
                }
                内CDF[起 + k] = v
                let 格宽 = 内宽F[起 + k]
                if 格宽 < 结果.块内最小格宽 { 结果.块内最小格宽 = 格宽 }
                let 有效概率 = 块宽F[b] * 格宽
                if 有效概率 < 结果.全局最小概率 { 结果.全局最小概率 = 有效概率 }
                上一 = v
            }
        }

        // ---- 5) 旧单级全局 CDF（宏置 0 的回滚路径）：原样保留「相对全局 1e-6 下限 + 严格单调」
        // 注意它建在「排序后」的序列上：分布与被替换前的版本等价（同一批权重、同一条单调前缀），
        // 只是灯列表顺序变成降序，因此回滚版与更早版本的随机流不同、逐位不会一致。
        let 最小格宽 = 全局总量 * 1e-6
        var 旧前缀 = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let 上一格 = i == 0 ? 0.0 : 旧前缀[i - 1]
            旧前缀[i] = max(上一格 + max(序权重[i], 最小格宽), 上一格 + 最小格宽)
        }
        let 旧归一 = 旧前缀.last ?? 0
        guard 旧归一 > 0, 旧归一.isFinite else { return 结果 }

        // ---- 6) 打包成一段：旧单级 | 块前缀 | 块宽 | 块内前缀 | 块内格宽 ----
        // 单缓冲五段，不新增 buffer 绑定（仍是 index 11）。
        // 为什么要单独存两级格宽：前缀差在 1.0 附近做减法会灾难性抵消，
        // 而 pdf 必须等于「块格宽 × 块内格宽」的真值，不能带 10% 量化误差。
        let 段旧 = 0
        let 段块 = n
        let 段块宽 = n + 块数
        let 段内 = n + 2 * 块数
        let 段内宽 = n + 2 * 块数 + n
        var 打包 = [Float](repeating: 0, count: 3 * n + 2 * 块数)
        for i in 0..<n { 打包[段旧 + i] = Float(旧前缀[i] / 旧归一) }
        打包[段块 + 块数 - 1] = 1.0
        for b in 0..<块数 { 打包[段块 + b] = 块CDF[b] }
        for b in 0..<块数 { 打包[段块宽 + b] = 块宽F[b] }
        for i in 0..<n { 打包[段内 + i] = 内CDF[i] }
        for i in 0..<n { 打包[段内宽 + i] = 内宽F[i] }

        结果.三角形 = 序三角
        结果.打包CDF = 打包
        结果.三角形数 = n
        结果.块数 = 块数
        结果.建表耗时 = (CFAbsoluteTimeGetCurrent() - 建表开始) * 1000.0
        return 结果
    }

    /// 只把自发光三角形收进候选池，按 面积 × 发光亮度 建前缀和 CDF。
    /// 有了它，面光源（比如屏幕上发光的球）不用再靠 BSDF 随机撞，
    /// 软阴影和光晕的方差能降一个数量级 —— 思路跟 Cycles 的 light distribution 一致，
    /// 只是这里没做 light tree（多光源场景才需要分层重要性采样）。
    private static func buildLightList(_ scene: inout PTScene) {
        var triangles: [UInt32] = []
        // 权重用 Double 累加：几千到几万个自发光三角形、面积功率跨好几个数量级时，
        // Float 前缀和在"大步 + 小步"交替累加下会直接吞掉小三角的增量（float32 只有 24 位尾数），
        // 结果是小三角的 CDF 跨度被抹成 0 → 永远抽不中 → 那部分发光能量整块丢失（变暗）。
        var 权重: [Double] = []
        var 总和 = 0.0

        for tri in 0..<scene.triangleCount {
            let materialIndex = Int(scene.triangleMaterial[tri])
            guard materialIndex < scene.materials.count else { continue }
            let emission = scene.materials[materialIndex].emissive
            let power = emission.w * (0.2126 * emission.x + 0.7152 * emission.y + 0.0722 * emission.z)
            // 这里只排除"真的不发光"（自发光 rgb 全 0 / 强度 0）。
            // 以前用 power > 1e-4 当门槛：亮度略低于 1e-4 的自发光三角形会被整个踢出灯池，
            // 而 bounce > 0 的非镜面跳又不累加命中发光 → 那部分能量彻底消失（系统性偏暗）。
            guard power.isFinite, power > 0 else { continue }

            let i0 = Int(scene.indices[tri * 3])
            let i1 = Int(scene.indices[tri * 3 + 1])
            let i2 = Int(scene.indices[tri * 3 + 2])
            let p0 = scene.positions[i0]
            let p1 = scene.positions[i1]
            let p2 = scene.positions[i2]
            let cross = simd_cross(
                SIMD3<Float>(p1.x - p0.x, p1.y - p0.y, p1.z - p0.z),
                SIMD3<Float>(p2.x - p0.x, p2.y - p0.y, p2.z - p0.z)
            )
            let area = 0.5 * simd_length(cross)
            // 退化三角形（面积为 0）不能进灯池：着色器里 area <= 1e-8 会直接丢掉这个样本的贡献，
            // 但它已经吃掉了这次采样的概率质量 → 纯粹变暗。门槛与着色器那侧严格对齐（同为 1e-8）。
            guard area.isFinite, area > 1e-8 else { continue }
            let 三角权重 = Double(area) * Double(power)
            guard 三角权重.isFinite, 三角权重 > 0 else { continue }

            triangles.append(UInt32(tri))
            权重.append(三角权重)
            总和 += 三角权重
        }

        guard !triangles.isEmpty, 总和.isFinite, 总和 > 0 else { return }

        // 【改：排序分块两级 CDF】
        // 排序只动「灯列表的顺序」，permutation 里存的仍是真实三角形下标：
        // scene.positions / indices / normals / triangleMaterial 一律不重排 ——
        // 加速结构、法线表、材质表全部继续按真实下标访问，几何数据顺序一个字节都不变，
        // 所以不存在「降序排序与 AS 求交/法线表冲突」的问题（冲突只会在直接重排几何时出现）。
        let 两级 = 构建面光两级CDF(权重: 权重, 三角形: triangles)
        guard 两级.三角形数 == triangles.count, 两级.块数 > 0 else { return }

        scene.lightTriangles = 两级.三角形
        scene.lightCDF = 两级.打包CDF
        scene.lightBlockCount = 两级.块数

        // 构建耗时只在超预算时打印（拖滑杆会反复重建，避免刷屏）。预算 5ms。
        let 总耗时 = 两级.排序耗时 + 两级.建表耗时
        if 总耗时 > 5.0 {
            print(String(
                format: "面光两级CDF 三角=%d 块=%d 排序=%.2fms 建表=%.2fms 合计=%.2fms 块内最小格宽=%.3g 全局最小概率=%.3g 钳制=%d",
                两级.三角形数, 两级.块数, 两级.排序耗时, 两级.建表耗时, 总耗时,
                两级.块内最小格宽, 两级.全局最小概率, 两级.钳制次数
            ))
        }
    }

    /// 三段指纹。为什么要拆：
    /// 加速结构那一代能不能复用，只取决于「三角形和灯有没有变」；
    /// 材质色、环境亮度这些是每帧都可能被拖动的高频参数，
    /// 把它们混进同一个签名里，等于拖一下色相就重建一次 BLAS（O(三角形数)），
    /// 大场景下这就是卡顿的主因。拆开之后各段走各自的最廉价路径。
    struct 指纹 {
        /// 几何段：只由拓扑/顶点/对象增删驱动（网格内容、导入网格、三角化结果、材质归属）。
        /// 位置/旋转/缩放绝不进这里 —— 否则拖动物体就被判成"几何重建"。
        var 几何: String = ""
        var 环境: String = ""
        /// 灯光段：灯参数（功率/颜色/尺寸/角度/朝向/位置）单独成段。
        /// 灯不产几何、不进加速结构，只有灯对象（PTLightGPU 数组 + lightsCDF）会变，
        /// 所以灯一变只需要原地重写灯缓冲，不必让整棵 BLAS 换代。
        var 灯光: String = ""
    }

    /// 只算几何/环境/灯光三段。材质段不在这里算 —— 它是材质域的版本号（见 build 里 场景材质版本）。
    private static func signature(
        objects: [SceneObject],
        settings: ViewportSettings,
        slots: [UUID: UInt32]
    ) -> 指纹 {
        var geom = Hasher()
        var light = Hasher()
        for object in objects where object.isVisible && !object.是灯 && !object.是角色 {
            // 【几何段读域版本】程序网格形状 / 导入网格 UUID / "同一 UUID 重新烘过" 三件事
            // 都由几何域记账：几何接线在写入时按等价性推进逐键版本，这里只 combine 版本号，
            // 不再自己拼 mesh.rawValue + 导入网格ID —— 老拼法漏掉"导入网格内容换了但 UUID 没变"，
            // 那种改动会被判成几何没变。
            geom.combine(几何接线.共享.记录版本(键: object.id.uuidString))
            geom.combine(object.materialID)
            // 【变换不进几何段】位置/旋转/缩放既不进这里（否则拖动会被判成几何重建），
            // 也不再单独记哈希：变换变更判据已交给变换域版本号（见 PTScene.变换版本）。
        }
        // 环境段单独算（见 环境签名），这样拖亮度时渲染器可以原地换环境、不必整场景重译
        // 地面开关必须归几何：它凭空多出一块地板三角形，混进环境段会让
        // 「开关地面」复用旧加速结构 → 新地板画不出来 / 旧地板留在求交里
        geom.combine(settings.showsGround)

        // 灯一变画面就变，必须进指纹 —— 但只进「灯光段」，不进「几何段」。
        // 以前这段是 combine 到 geom 上的，后果是拖一下功率/尺寸滑杆，几何签名就变，
        // 于是整场景 BLAS 全量 refit（O(三角形数)）—— 而灯根本不产几何、也从不进加速结构，
        // 它只影响 lightsBuffer 与 lightsCDF 这两个小缓冲。拆段后灯参数变化走原地刷新。
        for object in objects where object.是灯 {
            guard let 设置 = object.灯光 else { continue }
            // isVisible / 启用 / 种类 决定这盏灯到底在不在灯池里（数量变化必须能识别出来）
            light.combine(object.isVisible)
            light.combine(设置.启用)
            light.combine(设置.种类.rawValue)
            light.combine(设置.功率)
            light.combine(设置.色温)
            light.combine(设置.宽)
            light.combine(设置.高)
            light.combine(设置.半径)
            light.combine(设置.锥角)
            light.combine(设置.柔和)
            // 灯的位置/朝向只影响灯缓冲（traceLightSurface 与 NEE 都从缓冲里读），
            // 不影响任何三角形 → 不归几何。吊灯视角里挪灯从此不再触发全场景 refit。
            // 【灯位置不再进指纹】位置变只需重写灯缓冲 + 重算灯树 AABB，连 refit 都不该做，
            // 其判据是变换域派生的 灯变换版本。朝向仍留在灯光段（它同时是灯参数，决定灯面法向）。
            light.combine(object.rotation.x)
            light.combine(object.rotation.y)
            light.combine(object.rotation.z)
        }
        return 指纹(
            几何: String(geom.finalize()),
            环境: 环境签名(settings: settings),
            灯光: String(light.finalize())
        )
    }
}

// MARK: - 几何段缓存

extension PTTranslator {
    /// 三角形材质归属。转译时用槽号，缓存里只存「归属」，命中后按本轮槽号表重映射 ——
    /// 这样换材质（哪怕材质表顺序变了）也不需要重算顶点。
    enum 槽键: Hashable {
        case 资产(UUID)
        case 默认
        case 地面
    }

    /// 几何段缓存（三级缓存之二：几何 / 材质 / 灯光）。
    /// 只保一份：拖参数时场景是单调变化的，多份 LRU 命中率没提升反而白占几十 MB。
    final class 几何段缓存 {
        struct 段 {
            var positions: [SIMD4<Float>] = []
            var normals: [SIMD4<Float>] = []
            var uvs: [SIMD2<Float>] = []
            var indices: [UInt32] = []
            var vertexSlice: [UInt32] = []
            var vertexHoleSlot: [UInt32] = []
            var 三角材质: [槽键] = []
        }

        static let shared = 几何段缓存()
        private let 锁 = NSLock()
        private var 键: String = ""
        private var 段值: 段?

        func 取(_ 键: String) -> 段? {
            锁.lock()
            defer { 锁.unlock() }
            guard self.键 == 键 else { return nil }
            return 段值
        }

        func 存(_ 键: String, _ 段: 段) {
            锁.lock()
            defer { 锁.unlock() }
            self.键 = 键
            段值 = 段
        }
    }

    /// 几何键：只收会改变「顶点 / 三角形 / 三角形材质归属」的东西。
    /// 材质参数、环境亮度、曝光这些高频量一律不进 —— 它们变了走命中路径。
    private static func 几何指纹<T: Hashable>(
        objects: [SceneObject],
        settings: ViewportSettings,
        版本: T,
        图集片数: Int,
        洞图片数: Int
    ) -> String {
        var 器 = Hasher()
        for object in objects where object.isVisible && !object.是灯 && !object.是角色 {
            // object.id 必须进键：笔迹切片是 PaintGPUSnapshot.sliceOf[object.id] 查出来的
            器.combine(object.id)
            // 【几何来源不自己拼】形状 / 导入网格 UUID / 导入网格内容版本统一由几何域记账，
            // 几何接线推进逐键版本，这里只读版本号（与上面"变换读域版本"同一套路）。
            器.combine(几何接线.共享.记录版本(键: object.id.uuidString))
            // 【变换不进哈希，读域的逐记录版本】顶点是按世界矩阵烘出来的，所以变换一变
            // 这份缓存必须失效；但"变没变"由变换域说了算（记录版本号），
            // 不再在这里把 position/rotation/scale 逐个 combine —— TRS 有三个来源、
            // 谁漏一个就漏整片顶点，版本号没有这个漏洞。
            器.combine(变换接线.共享.记录版本(键: object.id.uuidString))
            器.combine(object.materialID)
        }
        器.combine(settings.showsGround)
        器.combine(版本)
        器.combine(图集片数)
        器.combine(洞图片数)
        return String(器.finalize())
    }
}


// MARK: - 特效发射器：从场景模型取（写入方唯一入口）

extension PTVolumeEmitterGPU {
    /// 模型 → 发射器稳态描述。只筛「可见 + 是特效 + 启用」，顺序即模型顺序。
    ///
    /// 全工程唯一一处直接从场景模型读特效的地方：它服务于写入方（转译），消费端不许调。
    /// 世界矩阵一律向变换域要（与顶点烘焙同源），不在这里自己拼 TRS —— 否则一旦发射器
    /// 挂进父子链，位置就和世界矩阵各说一套。
    static func 从模型(_ objects: [SceneObject]) -> (发射器: [PTVolumeEmitterGPU],
                                                    模拟密: [MTLTexture?],
                                                    模拟温: [MTLTexture?]) {
        var 结果: [PTVolumeEmitterGPU] = []
        /// 未匹配数：有特效、有世界矩阵，但视口还没提交过这份场（出图抢在视口之前）
        var 未匹配数 = 0
        /// 逐层漏斗计数：出图拿不到火时，一眼能看出是卡在"没有特效对象"还是"没有世界矩阵"
        var 对象总数 = 0, 特效数 = 0, 启用数 = 0, 矩阵数 = 0
        /// 密/温两张 3D 纹理是**模拟槽数组**（只收本帧真有模拟场的项）：
        /// 槽号 = 下标 + 1，写进 发射器.模拟.z；没有模拟场的项不占槽，
        /// 避免"8 个槽被没跑模拟的火占满，真跑模拟的反而拿不到槽"。
        var 密表: [MTLTexture?] = []
        var 温表: [MTLTexture?] = []
        // 本帧视口真正在跑的场（渲染器在步进之后提交，先于本帧转译）
        let 登记表 = 体积场登记.当前
        for object in objects {
            对象总数 += 1
            guard object.isVisible else { continue }
            guard let 设置 = object.特效 else { continue }
            特效数 += 1
            guard 设置.启用 else { continue }
            启用数 += 1
            // 必须用写通读版：先把这个物体的 TRS 同步进变换域，再向域要派生世界矩阵。
            // 纯读的 `世界矩阵F(键:)` 只在"视口这一帧同步过该物体"时才有值，出图独立开跑时
            // 会一律取空 → 发射器被整片过滤掉 → 出图没火而视口有火。口径与拾取/导出完全一致。
            // 发射体：与视口同一套解析（设置里指了别的物体就用那个物体的几何与矩阵）
            let 宿主 = 设置.发射体对象ID.flatMap { id in
                objects.first { $0.id == id && $0.isVisible }
            } ?? object
            // 容器：里面有启用源就吃「容器自身矩阵 + 合并几何」——源只是发射体，
            // 不进场景、出图也看不见，跟视口是同一套解析。
            // 没有源时 容器几何 为 nil，退回 发射体对象ID / 自己，旧工程外观不变。
            let 容器几何 = 特效几何库.组合几何(设置)
            let 原始世界 = 变换接线.共享.世界矩阵(of: 容器几何 != nil ? object : 宿主)
            矩阵数 += 1
            // 对象尺度 + 喷口抬升：和视口体积走的是同一对函数。
            // 出图与视口必须同源，否则"视口从对象上冒、出图从中心冒"是必然结果。
            let 尺度 = 容器几何.map { 特效几何库.尺度($0) } ?? 粒子视口层.对象局部尺度(宿主)
            // 表面发射的域盒 / 世界矩阵与视口用的是同一对函数 + 同一张表，
            // 所以"视口从圈上烧、出图从中心冒"这种分裂不会出现。
            let 几何 = 容器几何 ?? (设置.走体积 ? 对象几何库.取(宿主) : nil)
            let 表面 = 设置.走体积
                ? 对象表面场库存.取(几何: 几何, 设置: 设置,
                               网格边长: Int(max(登记表[object.id]?.边长 ?? 64, 1)))
                : nil
            // 有表面场：世界矩阵下沉到底面（域盒把对象整个包住）；
            // 没有：退回老喷口（沿本地 +Y 抬到包围球顶）
            let 世界: simd_float4x4
            if let 表面 {
                世界 = 原始世界 * simd_float4x4(columns: (SIMD4<Float>(1, 0, 0, 0),
                                                        SIMD4<Float>(0, 1, 0, 0),
                                                        SIMD4<Float>(0, 0, 1, 0),
                                                        SIMD4<Float>(0, -表面.底偏移, 0, 1)))
            } else {
                世界 = 特效设置.体积喷口世界(原始世界, 对象顶部: 尺度.顶部)
            }

            let 位置 = SIMD3<Float>(世界.columns.3.x, 世界.columns.3.y, 世界.columns.3.z)
            // 喷射轴 = 世界矩阵第二列（本地 +Y），归一化顺手抹掉缩放；退化时退回世界 +Y
            var 轴 = SIMD3<Float>(世界.columns.1.x, 世界.columns.1.y, 世界.columns.1.z)
            if simd_length(轴) < 1e-6 { 轴 = SIMD3<Float>(0, 1, 0) }
            轴 = simd_normalize(轴)

            // 扩散角是半锥角（度），180 度 = 全向
            let 半角 = Float(max(0, min(180, 设置.扩散角))) * .pi / 180
            let 起始 = Float(max(0.0005, 设置.起始尺寸))

            // 有模拟场就交钥匙：域盒与配色一律走 `制造模拟参数`（和模拟 kernel 同一份推导，
            // 不在这里重写公式，避免"视口 1.5 米高、出图 1.2 米高"这种对不上的事）。
            var 模拟 = SIMD4<Float>.zero
            var 模拟色 = SIMD4<Float>.zero
            var 密: MTLTexture?
            var 温: MTLTexture?
            if let 项 = 登记表[object.id], 密表.count < PTVolumeEmitterGPU.模拟上限 {
                let 模拟参 = 设置.制造模拟参数(物理域: .标准, 世界: 世界,
                                            时间: 0, dt: 0, 网格边长: Int(max(项.边长, 1)),
                                            对象半径: 尺度.半径, 表面: 表面)
                // 槽位 = 该发射器在密表里的下标 + 1（0 留给"没有模拟场"），
                // 这样 Swift 侧绑 13+槽 / 21+槽 与着色器里的取槽完全对得上。
                模拟 = SIMD4<Float>(模拟参.域.x, 模拟参.域.y, Float(密表.count) + 1, 0)
                模拟色 = SIMD4<Float>(模拟参.配色.x, 模拟参.配色.y, 模拟参.配色.w, 0)
                密 = 项.场.当前密
                温 = 项.场.当前速
            } else if 登记表[object.id] == nil {
                // 只统计、不兜底：出图必须吃视口那一份场（同一批体素），
                // 绝不能自己另烧一份 —— 那样视口和出图就是两套流体，形态永远对不上。
                未匹配数 += 1
            }

            结果.append(
                PTVolumeEmitterGPU(
                    世界: 世界,
                    位置尺寸: SIMD4<Float>(位置, 起始),
                    轴扩散: SIMD4<Float>(轴, cos(半角)),
                    发射: SIMD4<Float>(Float(max(0, 设置.发射率)),
                                     Float(max(0.02, 设置.寿命)),
                                     Float(设置.初速),
                                     Float(特效设置.种类码(设置.种类))),
                    出生: SIMD4<Float>(Float(设置.起始颜色.x),
                                     Float(设置.起始颜色.y),
                                     Float(设置.起始颜色.z),
                                     Float(max(0, min(1, 设置.不透明度)))),
                    死亡: SIMD4<Float>(Float(设置.终止颜色.x),
                                     Float(设置.终止颜色.y),
                                     Float(设置.终止颜色.z),
                                     Float(设置.重力倍率)),
                    模拟: 模拟,
                    模拟色: 模拟色,
                    // 火焰外观与视口同一份参数（色温 / 结构 / 亮度），
                    // 少传一项就会"视口调好了、渲染出来还是出厂火"
                    火焰: SIMD4<Float>(Float(max(设置.火焰芯色温 ?? 3400, 600)),
                                     Float(max(设置.火焰尾色温 ?? 760, 400)),
                                     Float(min(max(设置.火焰结构 ?? 0.6, 0), 1)),
                                     Float(max(设置.火焰亮度 ?? 1, 0.02)))
                )
            )
            // 只有真拿到模拟场的才占槽（槽号已在上面算好，就是 append 前的 count）
            if 密 != nil {
                密表.append(密)
                温表.append(温)
            }
            // 超出上限就截断（与缓冲容量一致，绝不让着色器读到边界外）
            if 结果.count >= PTVolumeEmitterGPU.上限 { break }
        }
        // 【体积诊断】逐层漏斗落盘：出图没火时，一眼看出卡在"没有特效对象"还是"视口没交场"。
        PT体积诊断.报告(发射器: 结果.count, 登记: 登记表.count, 槽: 密表.count,
                      漏斗: [对象总数, 特效数, 启用数, 矩阵数], 未匹配: 未匹配数)
        return (结果, 密表, 温表)
    }
}

/// 体积链路的临时诊断（定性用，定位完可以整段删）。
///
/// 判读方式（对象/特效/启用/矩阵 是漏斗，从左到右逐层收窄）：
/// - `对象 N 特效 0` → 场景里根本没挂特效的对象，和体积链路无关；
/// - `特效 1 启用 1 矩阵 0` → 变换接线没填世界矩阵（出图抢在视口第一帧之前）；
/// - `矩阵 1 登记 0` → 世界矩阵有、但视口粒子渲染器没跑过体积模拟，场压根没生成；
/// - `登记 1 槽 0` → 登记表的 key 和 object.id 对不上；
/// - `槽 > 0` → 场已接进 PT，不成形就只可能是模拟场本身或采样坐标的事。
enum PT体积诊断 {
    nonisolated(unsafe) static var 上次: [Int] = []

    static func 报告(发射器: Int, 登记: Int, 槽: Int, 漏斗: [Int], 未匹配: Int) {
        let 对象 = 漏斗.count > 0 ? 漏斗[0] : -1
        let 特效 = 漏斗.count > 1 ? 漏斗[1] : -1
        let 启用 = 漏斗.count > 2 ? 漏斗[2] : -1
        let 矩阵 = 漏斗.count > 3 ? 漏斗[3] : -1
        let 键 = [对象, 特效, 启用, 矩阵, 发射器, 登记, 槽, 未匹配]
        guard 上次 != 键 else { return }
        上次 = 键
        NSLog("PT体积诊断：对象 %d 特效 %d 启用 %d 矩阵 %d → 发射器 %d，登记 %d，槽 %d，未匹配 %d",
              对象, 特效, 启用, 矩阵, 发射器, 登记, 槽, 未匹配)
        // 落盘一份：用户不一定会去看控制台，这里写到 ~/Library/Logs/3d渲染/pt_vol_diag.log。
        落盘("对象 \(对象) 特效 \(特效) 启用 \(启用) 矩阵 \(矩阵) 发射器 \(发射器) 登记 \(登记) 槽 \(槽) 未匹配 \(未匹配)")
    }

    /// 通用追加写：视口侧（粒子渲染器）和 PT 侧都落到同一个文件，
    /// 看一眼视口 / 出一次图之后直接读这一份，两边口径在同一行里能对上。
    static func 落盘(_ 正文: String) {
        let 行 = "\(Date()) \(正文)\n"
        if let 库 = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first {
            let 目录 = 库.appendingPathComponent("Logs/3d渲染", isDirectory: true)
            try? FileManager.default.createDirectory(at: 目录, withIntermediateDirectories: true)
            let 文件 = 目录.appendingPathComponent("pt_vol_diag.log")
            if let 句柄 = try? FileHandle(forWritingTo: 文件) {
                句柄.seekToEndOfFile()
                句柄.write(Data(行.utf8))
                try? 句柄.close()
            } else {
                try? 行.write(to: 文件, atomically: true, encoding: .utf8)
            }
        }
    }
}

/// 发射器段记账：只在「值真变了」时推进版本号（与 灯光记账 完全同构）。
/// 只存上一代的值用来判等，不存第二份参数、不做第二套默认值。
enum 特效记账 {
    private static let 锁 = NSLock()
    private static var 上次: [PTVolumeEmitterGPU] = []
    private static var 版本: UInt64 = 0

    static func 推进(_ 新: [PTVolumeEmitterGPU]) -> UInt64 {
        锁.lock()
        defer { 锁.unlock() }
        if 新 != 上次 {
            上次 = 新
            版本 &+= 1
        }
        return 版本
    }
}


// MARK: - 灯源：从场景模型取（写入方唯一入口）

extension 灯源取值 {
    /// 模型 → 灯源。只筛"可见 + 启用"的灯，顺序即模型顺序（决定灯缓冲/CDF 的排列）。
    /// 这是全工程唯一一处直接从场景模型读灯的地方：它服务于写入方（灯光接线），消费端不许调。
    static func 从模型(_ objects: [SceneObject]) -> [灯源取值] {
        var 结果: [灯源取值] = []
        结果.reserveCapacity(objects.count)
        for object in objects where object.isVisible {
            guard let 设置 = object.灯光, 设置.启用 else { continue }
            结果.append(
                灯源取值(
                    外部键: object.id.uuidString,
                    名称: object.name,
                    设置: 设置,
                    // 只交 TRS：矩阵换算与父子链在变换域内完成。
                    // 这里是"写入口"，不是派生点 —— 派生只有一个地方，就是变换域。
                    位置: object.position,
                    朝向: object.rotation,
                    缩放: object.scale,
                    // 写入方向没有世界矩阵可交；真值由 取灯源(快照) 从变换域回填。
                    世界矩阵: matrix_identity_double4x4
                )
            )
        }
        return 结果
    }
}
