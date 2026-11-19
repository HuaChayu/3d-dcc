import Foundation
import simd

// MARK: - 相机

/// 路径追踪相机的参数快照：从视口轨道相机抄过来，保证两种显示模式构图一致。
struct PTCamera: Equatable {
    var position: SIMD3<Float>
    var target: SIMD3<Float>
    var fieldOfViewDegrees: Float
    var near: Float = 0.05
    var far: Float = 500

    static let fallback = PTCamera(
        position: [0, 2.4, 6.5],
        target: [0, 0.9, 0],
        fieldOfViewDegrees: 38
    )

    /// 相机到世界的 4x4 矩阵（列主序，右 +X / 上 +Y / 前 -Z 的右手系）
    var cameraToWorld: simd_float4x4 {
        let forward = simd_normalize(target - position)
        let worldUp = SIMD3<Float>(0, 1, 0)
        var right = simd_cross(forward, worldUp)
        // 正对天顶时 forward 与 up 平行，换一个参考轴兜底
        if simd_length(right) < 0.0001 {
            right = simd_cross(forward, SIMD3<Float>(0, 0, 1))
        }
        right = simd_normalize(right)
        let up = simd_cross(right, forward)

        return simd_float4x4(columns: (
            SIMD4<Float>(right, 0),
            SIMD4<Float>(up, 0),
            SIMD4<Float>(-forward, 0),
            SIMD4<Float>(position, 1)
        ))
    }

    /// 传给 GPU 的打包形式：矩阵 + (tanHalfFov, aspect, near, far)
    func gpu(aspect: Float, 介质时间: Float = 0, 介质湍流: Float = 1) -> PTCameraGPU {
        let tanHalf = tan(fieldOfViewDegrees * .pi / 360)
        return PTCameraGPU(
            cameraToWorld: cameraToWorld,
            params: SIMD4<Float>(tanHalf, max(aspect, 0.0001), near, far),
            volume: SIMD4<Float>(介质时间, 介质湍流, 0, 0)
        )
    }
}

// MARK: - GPU 结构（必须与 PT 着色器.metal 里的 struct 逐字段对齐）

struct PTCameraGPU {
    var cameraToWorld: simd_float4x4
    var params: SIMD4<Float>
    /// x = 介质时间（秒，驱动体积湍流相位）, y = 湍流强度倍率（0 = 关）, z/w 预留。
    /// 走相机这份常量缓冲而不是新开槽位：Metal 的 buffer 索引 0…30 已经用满，
    /// 而这两个量本来就"每次追踪的进场参数"，语义上也归这里。
    var volume: SIMD4<Float>
}

struct PTEnvironmentGPU {
    /// xyz = 天顶色（线性），w = 环境强度
    var skyTop: SIMD4<Float>
    /// xyz = 地平色（线性），w = 未用
    var skyBottom: SIMD4<Float>
    /// xyz = 指向太阳的方向（单位向量），w = 太阳辐照强度
    var sun: SIMD4<Float>
}

// MARK: - 灯光（DCC 语义的显式光源）

/// 灯的种类在着色器里的编号：跟 Swift 枚举顺序保持一致
enum PTLightKind: UInt32 {
    case 区域光 = 0
    case 点光 = 1
    case 聚光 = 2
    case 平行光 = 3
}

/// 一盏灯在 PT 里的全部信息。
/// 灯不是几何：没有三角形、不会被相机拍到，只参与直接光采样（NEE），
/// 所以视口里不会再出现"发光的网格"这种伪光源。
struct PTLightGPU: Equatable {
    /// xyz = 世界位置，w = 发光半径（点光/聚光用，0 = 理想点）
    var positionRadius: SIMD4<Float>
    /// xyz = 朝向（单位向量，区域光/聚光/平行光用），w = 聚光锥半角的余弦
    var axisCosCone: SIMD4<Float>
    /// xyz = 颜色（已含色温），w = 强度（区域光=辐亮度、点/聚光=辐射强度、平行光=辐照度）
    var colorIntensity: SIMD4<Float>
    /// x = 宽, y = 高, z = 种类, w = 边缘柔和度
    var shape: SIMD4<Float>
}

/// 灯 AABB 树节点（与着色器 PTLightNode 逐字节对齐，共 48 字节）。
/// 只有 traceLightSurface 的保守剔除用它，不参与 NEE 抽样，也不影响任何亮度计算。
struct PTLightNodeGPU {
    /// xyz = AABB 最小角
    var 最小: SIMD4<Float> = SIMD4<Float>(0, 0, 0, 0)
    /// xyz = AABB 最大角
    var 最大: SIMD4<Float> = SIMD4<Float>(0, 0, 0, 0)
    /// 叶 = lightOrder 里的起始下标；内部节点 = 左子下标（右子 = 首项 + 1）
    var 首项: UInt32 = 0
    /// 0 = 内部节点；> 0 = 叶节点里的灯数
    var 数量: UInt32 = 0
    var 预留0: UInt32 = 0
    var 预留1: UInt32 = 0
}

/// 灯树头（与着色器 PTLightTreeHeader 对齐，16 字节）。
/// 灯数与当前灯总数不一致时，着色器整体退回线性扫描 —— 这是树下标越界的唯一防线。
struct PTLightTreeHeaderGPU {
    var 节点数: UInt32 = 0
    var 灯数: UInt32 = 0
    var 预留0: UInt32 = 0
    var 预留1: UInt32 = 0
}

/// OpenPBR 参数在 PT 里的完整表达：这里不做降级折色，
/// 每个通道都能对应到一条真实的 BSDF 项。
struct PTMaterialGPU: Equatable {
    /// xyz = 基底色（线性），w = 基底权重
    var baseColor: SIMD4<Float>
    /// xyz = 自发光色（线性），w = 自发光强度
    var emissive: SIMD4<Float>
    /// x = 粗糙度, y = 金属度, z = IOR, w = 透射权重
    var p0: SIMD4<Float>
    /// x = 薄膜权重, y = 薄膜厚度(nm), z = 薄膜 IOR, w = 清漆权重
    var p1: SIMD4<Float>
    /// x = 清漆粗糙度, y = 清漆变暗, z = 高光权重, w = 不透明度
    var p2: SIMD4<Float>
    /// x = 材质贴图在「材质图集」里的层号（< 0 = 没有贴图，走 baseColor 常量）
    /// y = 1 表示按 sRGB 解码。材质图集见 PTScene.材质贴图 / PT 渲染器.取材质图集。
    var p3: SIMD4<Float> = SIMD4<Float>(-1, 0, 0, 0)

    static let `default` = PTMaterialGPU(
        baseColor: SIMD4<Float>(0.8, 0.8, 0.8, 1),
        emissive: SIMD4<Float>(0, 0, 0, 0),
        p0: SIMD4<Float>(0.4, 0, 1.5, 0),
        p1: SIMD4<Float>(0, 300, 1.4, 0),
        p2: SIMD4<Float>(0.05, 0, 1, 1)
    )
}

// MARK: - 特效发射器（体积介质源）

/// 一个发射器在 PT 里的**稳态描述**（不是模拟状态）。
///
/// 口径（照 数据层 架构规矩.md §2 钉死）：
/// - 真值只有一个：`SceneObject.特效`（发射器参数）+ 变换域（世界矩阵）+ `物理域`（全局力）。
///   本结构只是"把真值翻译成 GPU 认的排布"，不存第二份参数、不做第二套默认值。
/// - **粒子位置/速度、体素 brick 一律不在这里**：那是渲染器工作状态，归渲染器私有。
/// - 与 `粒子 GPU 类型.swift` 的 `粒子发射参数` 分工不同：那份带 dt / 帧序号 / 发射数，喂模拟 kernel；
///   这份不随帧变，喂路径追踪的介质积分（密度/温度/albedo 由它在场里现算）。
struct PTVolumeEmitterGPU: Equatable {
    /// 世界矩阵（局部 +Y = 喷射轴）
    var 世界: simd_float4x4 = matrix_identity_float4x4
    /// xyz = 世界位置，w = 出生尺寸（米）
    var 位置尺寸: SIMD4<Float> = .zero
    /// xyz = 喷射轴（单位向量，世界空间），w = 扩散锥半角的余弦
    var 轴扩散: SIMD4<Float> = .zero
    /// x = 每秒发射数, y = 寿命(秒), z = 初速(米/秒), w = 种类码(0 粒子/1 火/2 烟/3 水)
    var 发射: SIMD4<Float> = .zero
    /// xyz = 出生颜色（线性），w = 不透明度
    var 出生: SIMD4<Float> = .zero
    /// xyz = 死亡颜色（线性），w = 受全局重力比例
    var 死亡: SIMD4<Float> = .zero
    /// x = 域盒半宽(米), y = 域盒高(米), z = 模拟纹理槽 + 1（0 = 本帧没有模拟场，回落到解析场）, w 保留。
    /// 视口跑的是 GPU 欧拉网格模拟，出图若还吃解析场，两边就不是同一种火；
    /// 这一格让 PT 直接采同一批体素（纹理由 `体积场登记` 每帧送过来）。
    var 模拟: SIMD4<Float> = .zero
    /// x = 消光系数, y = 发光强度（与视口 `体积模拟参数.配色` 同源，保证两边同一套色阶）。
    var 模拟色: SIMD4<Float> = .zero
    /// 火焰外观，与视口 `体积发射参数.包围` 同源：
    /// x 芯色温 K, y 尾色温 K, z 内部结构 0…1, w 亮度倍率。
    /// 出图不读这一格就会"视口调好了、渲染出来还是出厂色"。
    var 火焰: SIMD4<Float> = SIMD4<Float>(3400, 760, 0.6, 1)

    /// 单场景发射器上限：介质缓冲按它固定分配，每帧原地重写，不进加速结构签名。
    /// 着色器侧同名常量 `PT_VOLUME_EMITTER_LIMIT` 必须与它同值。
    static let 上限 = 64

    /// 模拟纹理槽数：必须与视口 `VOL_MERGE_MAX` 及着色器 `PT_SIM_SLOTS` 同值。
    /// 同一个 MTLDevice 每帧最多有这么多台网格模拟能进 PT 纹理槽（13…20 密 / 21…28 温）。
    static let 模拟上限 = 8

    /// 布局自检：改了字段就必须两边一起改（着色器 struct 在 PT 着色器.metal 顶部）
    static func 布局自检() {
        assert(MemoryLayout<PTVolumeEmitterGPU>.stride == 192,
               "PTVolumeEmitterGPU 必须是 192 字节，实为 \(MemoryLayout<PTVolumeEmitterGPU>.stride)")
    }
}

// MARK: - CPU 场景

/// 一份已经烘焙到世界空间的三角形汤：加速结构只建一次，变换改了靠签名触发重建。
struct PTScene {
    /// 每个顶点 xyz + 1 个填充位（float4 便于对齐与加速结构使用 16 字节 stride）
    var positions: [SIMD4<Float>] = []
    var normals: [SIMD4<Float>] = []
    var indices: [UInt32] = []
    /// 每个三角形一份材质下标
    var triangleMaterial: [UInt32] = []
    /// 每顶点图集 UV（与 positions 一一对应）
    var uvs: [SIMD2<Float>] = []
    /// 每顶点所属的绘画 slice 下标（UInt32.max = 该物体没有笔迹，着色器直接跳过采样）
    var vertexSlice: [UInt32] = []
    /// 每顶点所属的「镂空洞图」格位（UInt32.max = 该物体没有洞，着色器直接跳过洞采样）。
    /// 洞和颜色是两套独立数据：洞不写图层，所以它有自己的格位表。
    var vertexHoleSlot: [UInt32] = []
    /// 整个场景有没有洞：没有就整个洞分支都省掉
    var hasHole: Bool = false
    /// 转译时读到的绘画快照版本号。
    /// slice 表不进 signature（它不影响几何），所以一份「用旧快照转译出来的」scene
    /// 会把错表带进缓存的加速结构里，之后再也不会自己纠正 —— draw 靠这个号判断要不要重新转译。
    var paintRevision: Int = -1
    /// 整个场景有没有笔迹：没有就整个绘画分支都省掉
    var hasPaint: Bool = false
    /// 自发光三角形池（Cycles 光源列表的极简版）：着色器按 CDF 从中抽一支做直接光采样。
    /// 顺序是「按面积×亮度降序」排过的，元素仍是真实三角形下标（渲染器别处一律按真实下标访问几何）。
    var lightTriangles: [UInt32] = []
    /// 面光 CDF 打包缓冲，单段三块，长度 2n + B（n = lightTriangles.count，B = lightBlockCount）：
    ///   [0, n)          旧单级全局 CDF（1e-6 相对下限版；着色器宏 PT_AREA_LIGHT_BLOCK_CDF_ENABLED=0 时只读这段）
    ///   [n, n+B)        块级 CDF（块内权重之和的全局占比，Double 建、float32 上传，末项 1）
    ///   [n+B, n+B+n)    块内局部 CDF（按块内总量归一的条件概率，块内末项 1）
    /// 采样概率 = 块格宽 × 块内格宽。
    var lightCDF: [Float] = []
    /// 面光块数 = ceil(lightTriangles.count / 64)。着色器据此算块级二分范围
    var lightBlockCount: Int = 0
    var lightCount: Int { lightTriangles.count }
    /// 显式灯光（场景里的灯对象）：不占几何，只在直接光采样里被抽到
    var lights: [PTLightGPU] = []
    /// 显式灯的「亮度权重归一化 CDF」（升序，末位恒为 1），长度与 lights 一致。
    /// 仅用于选灯概率，不参与任何亮度/颜色计算，因此不改变渲染结果的数学期望。
    var lightsCDF: [Float] = []
    var lightsCount: Int { lights.count }
    var materials: [PTMaterialGPU] = []
    /// 材质贴图（导入的基础色图）的层表：下标 = PTMaterialGPU.p3.x。
    /// 只存 UUID，像素在渲染器上传时按 视口纹理库 现取，场景里不放几百 MB 位图。
    var 材质贴图: [UUID] = []
    var environment = PTEnvironmentGPU(
        skyTop: SIMD4<Float>(0.3, 0.31, 0.34, 1),
        skyBottom: SIMD4<Float>(0.06, 0.06, 0.07, 0),
        sun: SIMD4<Float>(0.4, 0.66, 0.63, 1.6)
    )
    /// 整体指纹（分段拼接，兼容老口径）。任何一段变都意味着画面得重算。
    /// 整体签名已删除：没有任何消费者，判等只看分段版本/签名。
    /// 几何指纹：三角形 + 地面开关。只有它变才需要重建加速结构。
    /// 材质色、环境亮度这些高频滑杆参数一律不进这一段 —— 大场景里重建 BLAS 是
    /// O(三角形数) 的 GPU 开销，把「改个色」也拖进重建是最贵的浪费。
    var 几何签名: String = ""
    /// 变换段（对象位置/旋转/缩放）：只驱动顶点重烘 + BLAS refit，不驱动 BLAS 重建。
    /// 【变换域接管后：唯一判据】来源是变换域的 `版本号`（任何对象的变换写入都会推进）。
    /// 旧的字符串哈希（场景指纹 xform 段）已整段删除：哈希要枚举 TRS 三个字段，
    /// 漏一个就漏整片顶点；版本号由写入方自己推进，漏不掉。
    var 变换版本: UInt64 = 0
    /// 灯位置段：只驱动灯缓冲与灯树原地刷新，不触达 BLAS/IAS。
    /// 【变换域接管后】唯一判据是下面的 `灯变换版本`（由变换域"灯段版本"派生）。
    /// 旧的灯位置哈希已整段删除：灯与物体共用变换域后，它无法区分"灯动了"和"物体动了"，
    /// 正是当年把拖物体误判成灯变的来源。
    /// 材质指纹：materials 数组内容。变了只需重写材质缓冲 + 清累积。
    /// 材质段版本：直接来自数据层材质域（被引用材质的聚合版本），不再自拼材质签名
    var 材质版本: UInt64 = 0
    /// 环境指纹：环境贴图/强度/旋转。只影响着色器常量，连缓冲都不用换。
    var 环境签名: String = ""
    /// 灯光指纹：灯对象参数（功率/色温/尺寸/锥角/半径/柔和/位置/朝向/启用/种类）。
    /// 灯不产几何、不进加速结构，变了只需原地重写 lightsBuffer + lightsCDF；
    /// 只有"盏数变了"（灯被增删/启停）才需要重新分配灯缓冲并全量重建。
    /// 【仅记账，禁止用于变更判定】唯一判据是 灯光版本。
    var 灯光签名: String = ""
    /// 灯段版本号（数据层灯光接线记账，取代灯光指纹做变更判定）：
    /// 拖灯只会让它两个之一自增，渲染器据此分派"只刷灯位置"/"只刷灯参数"，两条都不碰 BLAS/IAS。
    var 灯光版本: UInt64 = 0
    /// 灯变换版本号：只有灯的矩阵真的变了才自增（拖物体不会让它动）。
    var 灯变换版本: UInt64 = 0

    /// 特效发射器（体积介质源）：不占几何、不进加速结构，介质在场里自己求交。
    /// 数据来源唯一：转译时从 `SceneObject.特效` 现收（与收灯同一条路）。
    var 特效发射器: [PTVolumeEmitterGPU] = []
    /// 模拟密 / 温 3D 纹理（与 特效发射器 同下标，nil = 该项本帧没有模拟场）。
    /// 只是「借来的引用」，不参与签名、不参与缓存判定：纹理内部每帧被 compute 覆写，
    /// 内容变了不代表场景结构变了（累积清不清看 特效版本，不看这里）。
    var 特效模拟密: [MTLTexture?] = []
    var 特效模拟温: [MTLTexture?] = []
    /// 发射器段版本号：由转译侧按「发射器参数是否真变」记账（与 灯光记账 同构）。
    /// 介质一变，旧样点就不可复用 —— 消费端据此清累积，而不是自己猜。
    var 特效版本: UInt64 = 0
    var 特效发射器数: Int { 特效发射器.count }

    var triangleCount: Int { indices.count / 3 }
    var isEmpty: Bool { indices.isEmpty }
}

// MARK: - 采样设置

/// 降噪入口的统一参数（OIDN 通路共用）：
/// 萤火虫样点压制用固定的 24x 邻域亮度上限，不再按样本数分档。
struct PTDenoisePlan: Equatable {
    /// 萤火虫样点压制：单像素亮度不得超过邻域参考亮度的这个倍数
    var luminosityCeiling: Float

    var isEnabled: Bool { luminosityCeiling > 0 }

    static let off = PTDenoisePlan(luminosityCeiling: 0)
}

/// 路径追踪的采样参数（先给固定档位，够用再暴露到设置页）
/// 与着色器里的 PTGlowParams 逐字段对齐（4 个 float，16 字节）
struct PTGlowParams {
    var threshold: Float
    var smoothness: Float
    var maxBrightness: Float
    var strength: Float
}

struct PathTraceSettings: Equatable {
    /// 每帧累积的样本数：静止时靠它把收敛速度顶上去（M4 上仍有大量余量）
    var samplesPerFrame: Int = 8
    var maxBounces: Int = 4
    /// 介质时间演化：单位秒，只驱动体积介质的湍流相位，不参与任何光照量。
    /// 放在这里而不是读墙钟，是因为 PT 是累积渲染器 —— 时间随墙钟走会让每帧都是新画面，
    /// 永远收敛不了、OIDN 也永远在擦一颗永远擦不干净的噪点。
    var volumeTime: Float = 0
    /// 介质湍流强度倍率：0 = 关闭（退回纯锥形羽流），1 = 默认翻滚
    var volumeTurbulence: Float = 1
    /// 介质动画：一轮累积收敛后由渲染器自己把时间往前推（出图路径不吃这份时钟）
    var volumeAnimate: Bool = false
    /// 累积上限。OIDN 吃 48 spp 才能把焦散/间接光的残余颗粒彻底抹平
    ///（实测 24 spp 仍可见细微颗粒），配合每帧 8 spp，2800x849 全分辨率约 0.8 秒收敛。
    var maxSamples: Int = 48
    var exposure: Float = 1.0
    /// 内部渲染分辨率比例（1.0 = 原生，0.75 更流畅）
    var resolutionScale: Double = 1.0
    /// 渲染纹理尺寸（材质图集档位，像素）。视口与离屏出图共用同一档，
    /// 只影响「材质图集边长上限 + 派生材质烘焙档」，与 resolutionScale 互不相干。
    var textureTier: Int = 1024

    // MARK: M4 降噪（OIDN 神经网络，常开）

    /// 降噪恒开（OIDN 单一后端，无 À-Trous 回退）；工具栏不再提供关闭入口
    var denoiseEnabled: Bool = true
    /// 萤火虫压制的亮度上限倍数（0 = 不压制）。由「路径追踪 ▼」菜单调节
    var luminosityCeiling: Float = 24

    // MARK: 眩光辉光（Blender Glare 式屏幕空间后处理）

    /// 辉光开关：只认 HDR 亮度，节点自发光与绘画自发光走同一条路
    var glowEnabled: Bool = true
    /// 起辉亮度阈值（曝光后的线性 HDR，1.0 ≈ 白点）
    var glowThreshold: Float = 1.0
    /// 阈值平滑宽度（越大越柔，0 会闪）
    var glowSmoothness: Float = 0.3
    /// 单像素亮度上限，压制萤火虫把整屏烧白
    var glowMaxBrightness: Float = 32
    /// 眩光叠加强度
    var glowStrength: Float = 0.35
    /// 半径：参与上下采样的层数（1…6），越大光晕铺得越远
    var glowRadius: Int = 4
    /// 屏蔽自身（0…1）：叠加时先减掉「自身亮度」再取正，
    /// 拉满等于只保留轮廓外的光晕，模型表面维持原有自发光效果不被辉光洗亮
    var glowSelfMask: Float = 0

    /// 除了辉光那几个参数以外是否完全一致。
    /// 辉光只在「呈现阶段」把光晕叠到已追踪好的 HDR 上，不进累积缓冲、
    /// 不影响加速结构与场景 —— 所以只是拖辉光滑杆时不该重开累积。
    func 除辉光外相同(_ other: PathTraceSettings) -> Bool {
        var a = self
        a.glowEnabled = other.glowEnabled
        a.glowThreshold = other.glowThreshold
        a.glowSmoothness = other.glowSmoothness
        a.glowMaxBrightness = other.glowMaxBrightness
        a.glowStrength = other.glowStrength
        a.glowRadius = other.glowRadius
        a.glowSelfMask = other.glowSelfMask
        return a == other
    }

    static let standard = PathTraceSettings()

    /// 渲染纹理尺寸的合法档位（面板下拉的四个选项）。
    /// 读盘/旧工程里出现任何别的值时吸附到最近的合法档：
    /// 图集边长走的是 2 的幂，档位必须落在白名单里，否则「取图 → 烘焙 → 补烘」三处会对不上档。
    static let 纹理档白名单: [Int] = [512, 1024, 2048, 4096]

    static func 吸附档(_ 值: Int) -> Int {
        if 纹理档白名单.contains(值) { return 值 }
        if 值 <= 纹理档白名单[0] { return 纹理档白名单[0] }
        if 值 >= 纹理档白名单[纹理档白名单.count - 1] { return 纹理档白名单[纹理档白名单.count - 1] }
        // 中间值取最近的合法档
        return 纹理档白名单.min(by: { abs($0 - 值) < abs($1 - 值) }) ?? 1024
    }

    /// 降噪参数：OIDN 入口的萤火虫压制按菜单档位取亮度上限
    func denoisePlan(samples: UInt32) -> PTDenoisePlan {
        guard denoiseEnabled, luminosityCeiling > 1 else { return .off }
        return PTDenoisePlan(luminosityCeiling: luminosityCeiling)
    }

    /// 从视口设置派生 PT 参数（曝光/采样/降噪全部走这条线，避免只同步一半）
    static func from(viewport: ViewportSettings) -> PathTraceSettings {
        var s = PathTraceSettings.standard
        s.exposure = Float(viewport.exposure)
        s.samplesPerFrame = min(max(viewport.ptSamplesPerFrame, 1), 8)
        s.maxSamples = max(viewport.ptMaxSamples, 1)
        s.maxBounces = max(viewport.ptMaxBounces, 1)
        s.volumeTime = max(Float(viewport.ptVolumeTime), 0)
        s.volumeTurbulence = min(max(Float(viewport.ptVolumeTurbulence), 0), 2)
        s.volumeAnimate = viewport.ptVolumeAnimate
        s.resolutionScale = min(max(viewport.ptResolutionScale, 0.25), 1.0)
        s.textureTier = PathTraceSettings.吸附档(viewport.ptTextureTier)
        s.luminosityCeiling = max(Float(viewport.ptLuminosityCeiling), 0)
        s.denoiseEnabled = true
        s.glowEnabled = viewport.ptGlowEnabled
        s.glowStrength = max(Float(viewport.ptGlowStrength), 0)
        s.glowThreshold = max(Float(viewport.ptGlowThreshold), 0)
        s.glowRadius = min(max(Int(viewport.ptGlowRadius.rounded()), 1), 6)
        s.glowSelfMask = min(max(Float(viewport.ptGlowSelfMask), 0), 1)
        return s
    }
}
