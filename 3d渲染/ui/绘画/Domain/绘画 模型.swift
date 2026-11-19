import Foundation
import Metal
import Observation
import simd

// MARK: - 图层

enum PaintBlend: String, CaseIterable, Codable, Sendable {
    case normal
    case multiply
    case add

    var title: String {
        switch self {
        case .normal: "正常"
        case .multiply: "正片叠底"
        case .add: "叠加"
        }
    }
}

/// 图层元数据。像素本身住在 layerArray 的对应 slice 里，这里只存「怎么混」。
/// 绘画通道：**键名严格取自 OpenPBR Surface 1.0 参数表**，不自造通道。
///
/// 核对结论（openpbr.io 参数表 Table 1）：
///  - 几何相关只有 geometry_opacity / geometry_normal / geometry_coat_normal /
///    geometry_tangent / geometry_thin_walled，**没有 height、没有 displacement**。
///  - 位移/高度不在 OpenPBR 规范范围内（属于渲染器的几何层），材质侧只接收
///    已经算好的 geometry_normal。
/// 所以这里不放"高度"通道；凹凸笔刷在 GPU 上由笔刷覆盖度当场算出法线写进
/// normal 通道，磁盘/图集里永远是合法的 geometry_normal。
enum PaintChannel: String, CaseIterable, Sendable {
    case baseColor
    case roughness
    case metalness
    case normal
    case coatWeight
    case coatRoughness
    case emission

    /// OpenPBR 规范里的参数名（注释与 UI 提示用，务改名时同步核对规范）
    var openPBR: String {
        switch self {
        case .baseColor:     return "base_color"
        case .roughness:     return "specular_roughness"
        case .metalness:     return "base_metalness"
        case .normal:        return "geometry_normal"
        case .coatWeight:    return "coat_weight"
        case .coatRoughness: return "coat_roughness"
        case .emission:      return "emission_color × emission_luminance"
        }
    }

    var 名称: String {
        switch self {
        case .baseColor:     return "颜色"
        case .roughness:     return "粗糙度"
        case .metalness:     return "金属度"
        case .normal:        return "法线"
        case .coatWeight:    return "清漆"
        case .coatRoughness: return "清漆粗糙度"
        case .emission:      return "自发光"
        }
    }

    /// 是否 P0（第一屏就给）
    var 是基础: Bool {
        switch self {
        case .baseColor, .roughness, .metalness, .normal: return true
        default: return false
        }
    }

    /// 常量类通道的落笔值（法线通道不用它；自发光用笔刷颜色，值 = 强度）
    var 默认值: Float {
        switch self {
        case .roughness:     return 0.25
        case .metalness:     return 1.0
        case .coatWeight:    return 1.0
        case .coatRoughness: return 0.12
        // 自发光：打开就是满强度，颜色来自笔刷色
        case .emission:      return 1.0
        default:             return 0
        }
    }

    /// 有「值滑杆」可调的通道。颜色吃笔刷色、法线是逐像素算出来的凹凸，没有单值可调。
    var 有值滑杆: Bool {
        switch self {
        case .baseColor, .normal: return false
        default: return true
        }
    }

    /// 这个通道归哪个开关管。
    ///
    /// 清漆权重和清漆粗糙度在 OpenPBR 里是同一个清漆层的两个参数，拆两个开关只会让人
    /// 多按一次，还容易一个开一个关（权重开着、粗糙度没开，画出来是没有清漆高光的哑面）。
    /// 所以两者共用「清漆」这一个开关，滑杆各管各的值。
    var 开关通道: PaintChannel {
        switch self {
        case .coatRoughness: return .coatWeight
        default:             return self
        }
    }

    /// 常量类通道：整片像素只存同一个标量。
    /// 所以它的「值」可以直接当颜色 uniform 传进合成 kernel —— 拖滑杆立刻生效，
    /// 不用回头重刷已经画过的像素。颜色/法线/自发光是逐像素的，不能这么干。
    var 是常量: Bool {
        switch self {
        case .roughness, .metalness, .coatWeight, .coatRoughness: return true
        default: return false
        }
    }
}

struct PaintLayer: Identifiable, Sendable {
    var id = UUID()
    var name: String
    var isVisible: Bool = true
    var opacity: Float = 1
    var blend: PaintBlend = .normal
    // 通道开关/通道值不放这儿了：它是「笔刷落笔落进哪些 OpenPBR 通道」，
    // 跟具体哪一层、哪个对象没关系。全局一份，见 PaintBrush.通道开关 / 通道值。
}

// MARK: - 每个物体的绘画栈

/// 一个场景物体对应一套图层。图层纹理做成 texture2d_array 而不是一堆独立纹理：
/// 绘画时只要把 render pass 的 attachment.slice 指到当前图层，
/// 合成时一个 kernel 就能把所有图层一次读完，省掉 N 个绑定槽位。
@Observable
final class PaintStack {
    /// GPU 侧图层上限。够用（DCC 一般 3~5 层），也让合成 kernel 的参数表可以固定下来。
    static let 最大图层数 = 8

    let objectID: UUID
    var layers: [PaintLayer]
    var activeIndex: Int = 0
    /// 合成结果是否过期（笔迹、图层顺序、显隐、不透明度任一变化都会置脏）
    var 脏 = true
    /// 这套栈有没有被真正画过（全新工程不浪费显存）
    var 已启用 = false
    /// 图层像素（texture2d_array，slice = 图层下标）。首次真正落笔时才分配。
    var layerArray: MTLTexture?
    /// 非颜色通道的图层像素：同样 8 个 slice、与颜色通道逐层对齐，
    /// 只是每张图存的是该通道的值（rgb）+ 覆盖度（a）
    var 通道数组: [PaintChannel: MTLTexture] = [:]
    /// 哪些通道真的落过笔（没落过的通道不分配显存、也不参与合成）
    var 用过的通道: Set<PaintChannel> = []
    /// 落笔历史（撤销用）。只保留最近若干笔，画到上限就丢最早的，
    /// 避免长时间绘画把内存啃光；丢掉的代价只是撤不到更早的那几步。
    var strokes: [PaintStroke] = []
    static let 最多记录笔画 = 240

    init(objectID: UUID) {
        self.objectID = objectID
        self.layers = [PaintLayer(name: "图层 1")]
    }

    var activeLayer: PaintLayer? {
        guard layers.indices.contains(activeIndex) else { return layers.first }
        return layers[activeIndex]
    }

    /// 图层任一属性变了都要重合成，统一走这里置脏
    func 标记脏() { 脏 = true }
}

// MARK: - 绘制参数

struct PaintBrush: Equatable, Sendable {
    /// 笔刷半径（世界单位）。视口里按物体尺度自动给默认值，用户可滚轮调。
    var radius: Float = 0.12
    /// 0 = 极软，1 = 硬边（只影响边缘过渡宽度）
    var hardness: Float = 0.55
    /// 单次落笔不透明度（会沿轨迹累积）
    var opacity: Float = 1.0
    /// 沿轨迹的采样间距 = radius × spacing，越小笔迹越连续、splat 越多
    var spacing: Float = 0.3
    var color: SIMD3<Float> = [0.92, 0.24, 0.18]
    /// 笔刷行为：上色 / 擦除（削当前层 alpha）/ 镂空（把这块表面真的挖掉）
    var mode: PaintMode = .绘画
    /// 形状遮罩。绘画和镂空都吃它：选了哪个图案就用哪个图案
    var mask: PaintMaskKind = .无
    /// 遮罩反转：图案照旧，只是采样后 1 和 0 对调（实心变留白）。
    /// 无遮罩时无意义，落笔时会自动忽略
    var maskInvert: Bool = false
    /// 遮罩在笔刷内的缩放。1 = 原大小，越大会让图案在同一个笔刷里"撑开"
    var maskScale: Float = 1.0
    /// 遮罩旋转，单位度（0..360）。顺时针为正
    var maskRot: Float = 0
    /// 遮罩在笔刷内的平移，单位是「一个笔刷边长」的比例（0.5 = 挪半个笔刷）。
    /// 面板上拖遮罩图拖出来的就是它，视口笔刷圈里 1:1 照搬
    var maskOffset: SIMD2<Float> = .zero

    // MARK: 通道（全局，与层/对象无关）

    /// 通道「参不参与」的开关：只决定接下来的笔写不写这个通道。默认只有颜色。
    /// 这是全局的一份 —— 开了就所有层、所有对象都吃这套，换层换对象不会变。
    /// 注意：关掉不动已有笔迹，只是不再往里写（层只负责记录像素）。
    /// 存的是「开关通道」（清漆粗糙度归清漆那个开关），不是逐个通道一个勾。
    var 通道开关: Set<PaintChannel> = [.baseColor]
    /// 每个通道落笔要写的「值」——就是 OpenPBR 那个参数值本身（粗糙度 0.25 就是 0.25）。
    /// 同样全局一份：改一下，所有已画区域跟着变。
    var 通道值: [PaintChannel: Float] = [:]

    /// 兼容旧写法：开着的通道集合（已按开关分组展开）
    var 通道: Set<PaintChannel> { 开着的通道 }

    /// 单通道的值，没设过就是该通道默认值
    func 值(_ ch: PaintChannel) -> Float { 通道值[ch] ?? ch.默认值 }

    /// 这个通道参不参与（看清漆粗糙度：它跟着清漆那个开关）
    func 开着(_ ch: PaintChannel) -> Bool { 通道开关.contains(ch.开关通道) }

    /// 真正要落笔的通道列表：开关里存的是组长（清漆），这里展开成它带的全部通道。
    var 开着的通道: Set<PaintChannel> {
        Set(PaintChannel.allCases.filter { 通道开关.contains($0.开关通道) })
    }

    /// 改开关：统一改到组长上，避免一个开一个关
    mutating func 设置开关(_ ch: PaintChannel, 开: Bool) {
        if 开 { 通道开关.insert(ch.开关通道) } else { 通道开关.remove(ch.开关通道) }
    }

    /// 是否需要按「削 alpha」的管线走。只有擦除是 —— 镂空不碰图层像素，它写的是洞图
    var 减alpha: Bool { mode == .擦除 }
}

/// 笔刷的三种行为。和着色器里的 PaintUniforms.mode 一一对应，rawValue 不能乱改。
enum PaintMode: Int, CaseIterable, Identifiable, Sendable {
    case 绘画 = 0
    case 擦除 = 1
    case 镂空 = 2

    var id: Int { rawValue }

    var 名称: String {
        switch self {
        case .绘画: return "绘画"
        case .擦除: return "擦除"
        case .镂空: return "镂空"
        }
    }

    var 图标: String {
        switch self {
        case .绘画: return "paintbrush.pointed"
        case .擦除: return "eraser"
        case .镂空: return "circle.dashed"
        }
    }

    var 说明: String {
        switch self {
        case .绘画: return "用当前颜色上色，遮罩决定笔迹形状"
        case .擦除: return "把当前图层的颜色削薄，同时把这块的洞填回去"
        case .镂空: return "把这部分表面真的挖掉（破布、战损、残缺），光线直接穿过去"
        }
    }
}

/// 与 绘画 笔刷.metal 里的 PaintSplat 严格一一对应（224 字节，16 字节对齐）
struct PaintSplat {
    var center: SIMD2<Float> = .zero
    /// uv 空间半径（x = u 方向，y = v 方向）。各向异性是为了补偿球两极的 UV 挤压。
    var radius: SIMD2<Float> = .zero
    /// rgb = 颜色，a = 强度（未乘衰减前）
    var color: SIMD4<Float> = .zero
    /// x = 硬度，y 保留
    var params: SIMD4<Float> = .zero
    /// 允许落在图集上的矩形（minX, minY, maxX, maxY），即这个 splat 所属 piece 的那一格。
    /// 片元按这个框裁：quad 本身不再夹格（夹了会把跨缝 splat 的图案压歪），越界像素在片元里丢掉
    /// （隔壁可能是同一物体的别的部件，也可能是别的物体 —— 那就是「整个模型被染色」）。
    var bounds: SIMD4<Float> = SIMD4<Float>(0, 0, 1, 1)
    /// xy = 这个 splat 圆心在「整支笔刷圆盘」里的坐标（±1 = 笔刷边缘），z = 笔刷自身在 uv 空间的半径（0 = 未知，兜底用）。
    /// 遮罩靠它按「整支笔刷」采样：逐 splat 各画一份图案的话，重叠起来只会糊成一团。
    var brushRef: SIMD4<Float> = .zero
    /// 切平面 → uv 的雅可比（单位 = 1/笔刷半径）：xy = 列 u（uv.x 走 1 格），zw = 列 v。
    /// 有了它，GPU 才能把「像素在 uv 上的偏移」换成「像素在贴表面笔刷圆盘里的位置」：
    /// brush = j1·Δu + j2·Δv。少了它就只能按 uv 轴摆图案，图案会被 UV 拉伸方向带歪。
    var brushJac: SIMD4<Float> = .zero
    /// 这个三角形的 uv 顶点（解缠后、未环回）：xy = t0，zw = t1
    var triUV0: SIMD4<Float> = .zero
    /// xy = t2，zw 保留
    var triUV1: SIMD4<Float> = .zero
    /// 三角形三个顶点的世界坐标；w = 0 表示几何不可信，GPU 退回 j 兜底
    var world0: SIMD4<Float> = .zero
    var world1: SIMD4<Float> = .zero
    var world2: SIMD4<Float> = .zero
    /// 整支笔刷的贴表面基（世界空间，已除笔刷半径）：brush.x = dot(P - 落笔点, basis0.xyz)
    var basis0: SIMD4<Float> = .zero
    var basis1: SIMD4<Float> = .zero
    /// 落笔点世界坐标；w = 1 表示有效
    var originW: SIMD4<Float> = .zero
}

/// 每次落笔传给片元的参数。字段顺序必须和 绘画 笔刷.metal 里的 PaintUniforms 完全一致。
struct PaintUniforms {
    var mode: Int32 = 0
    var useMask: Int32 = 0
    /// 1 = 遮罩反转（shader 里统一在 sampleMask 里取反）
    var maskInvert: Int32 = 0
    /// 遮罩缩放，1 = 原大小
    var maskScale: Float = 1
    /// 遮罩旋转，弧度（UI 上用的是度，进 uniform 前换算）
    var maskRot: Float = 0
    /// 遮罩平移，比例（1 = 一整个笔刷）。SIMD2 有 8 字节对齐，metal 侧同布局
    var maskOffset: SIMD2<Float> = .zero
}

/// 覆盖场合进图层时用的颜色。与 metal 里的 PaintApply 对应（16 字节）。
/// 一次落笔只有一个颜色，所以走 uniform，不必逐 splat 带
struct PaintApply {
    var color: SIMD4<Float> = .zero
}

/// 一笔的完整记录：撤销靠「清掉这层 + 把剩下的笔画按顺序回放」实现，
/// 不存整张纹理快照（1024²×4 一张就 4MB，画几十笔显存就爆了），
/// 一笔的 splat 数组通常几百个点，几十 KB 而已。
struct PaintStroke: Sendable {
    /// 落笔时作用的目标层；-1 表示镂空（不写图层，写的是洞图）
    var layer: Int
    var mode: PaintMode
    var mask: PaintMaskKind
    /// 落笔当时的反转状态。跟着笔画一起存是必须的：回放若读面板当前值，
    /// 一按反转，历史上所有笔迹都会被重放成反的
    var maskInvert: Bool = false
    /// 缩放/旋转同理：回放必须用落笔当时的值，否则拖一下滑杆，旧笔迹全被重排
    var maskScale: Float = 1
    var maskRot: Float = 0
    /// 平移也必须跟着笔画走：否则拖一下遮罩图，历史笔迹全被重新排列
    var maskOffset: SIMD2<Float> = .zero
    var splats: [PaintSplat]
}

/// 与 metal 里的 PaintLayerGPU 对应（16 字节）
struct PaintLayerGPU {
    var opacity: Float
    var blend: Int32
    var visible: Int32
    var reserved: Int32 = 0
}

// MARK: - GPU 快照（跨线程）

/// PT 渲染回调跑在 MetalKit 的 display link 线程上，而 PaintEngine 是 @MainActor。
/// 这条快照就是两者之间唯一的桥：只存纹理引用 + 版本号 + objectID→slice 映射，
/// 全是值语义或引用类型，加锁读写即可，不需要跨 actor 跳线程。
final class PaintGPUSnapshot: @unchecked Sendable {

    static let shared = PaintGPUSnapshot()

    struct 内容 {
        var atlas: MTLTexture?
        var revision: Int
        var sliceOf: [UUID: Int]
        var 有绘画: Bool
        /// 镂空洞图（r8Unorm 数组，一物体一格）与它的格位表
        var holeAtlas: MTLTexture?
        var holeSlotOf: [UUID: Int]
        var 有洞: Bool
        /// 各通道合成结果（粗糙度 / 金属度 / 法线…）。没落过笔的通道这里没有键
        var 通道图集: [PaintChannel: MTLTexture] = [:]
    }

    private let 锁 = NSLock()
    private var 图集: MTLTexture?
    private var 版本 = 0
    private var 映射: [UUID: Int] = [:]
    private var 有内容 = false
    private var 洞图: MTLTexture?
    private var 洞映射: [UUID: Int] = [:]
    private var 洞有内容 = false
    private var 通道: [PaintChannel: MTLTexture] = [:]

    func 写(atlas: MTLTexture?, revision: Int, sliceOf: [UUID: Int], 有绘画: Bool,
            holeAtlas: MTLTexture?, holeSlotOf: [UUID: Int], 有洞: Bool,
            通道图集: [PaintChannel: MTLTexture] = [:]) {
        锁.lock()
        defer { 锁.unlock() }
        图集 = atlas
        版本 = revision
        映射 = sliceOf
        有内容 = 有绘画
        洞图 = holeAtlas
        洞映射 = holeSlotOf
        洞有内容 = 有洞
        通道 = 通道图集
    }

    func 读() -> 内容 {
        锁.lock()
        defer { 锁.unlock() }
        return 内容(atlas: 图集, revision: 版本, sliceOf: 映射, 有绘画: 有内容,
                   holeAtlas: 洞图, holeSlotOf: 洞映射, 有洞: 洞有内容,
                   通道图集: 通道)
    }
}

// MARK: - 绘画引擎

/// 笔刷投影与图层合成的 GPU 侧全部职责。
///
/// 设计要点（也是这个方案能成立的根本）：加速结构一个字节都不改。
/// 笔迹只写进每个物体自己的图层纹理，PT 着色器在命中时多查一次图集纹理，
/// 所以画一百笔和画一笔，BLAS 完全一样，不会出现「每帧全量转译 + 重建」的开销。
@MainActor
@Observable
final class PaintEngine {

    static let shared = PaintEngine()

    /// 全局版本号：任何笔迹/图层变化都 +1。PT 渲染器拿它进签名，变了才重开累积。
    private(set) var revision: Int = 0
    /// 图集 slice 的稳定分配顺序（只增不改既有顺序），见 执行刷新图集
    private var 顺序: [UUID] = []
    /// 上一次建图集时占着片的成员，用来识别「片数没变但换人了」
    private var 已分配: [UUID] = []

    private let device: MTLDevice?
    private let queue: MTLCommandQueue?
    private(set) var stacks: [UUID: PaintStack] = [:]

    /// 图集纹理（texture2d_array，一物体一 slice）
    private(set) var atlas: MTLTexture?
    /// 各通道的合成结果（与 atlas 同尺寸同片数）。PT 侧按需采样，没落过笔的通道为 nil
    private(set) var 通道图集: [PaintChannel: MTLTexture] = [:]
    private(set) var sliceOf: [UUID: Int] = [:]

    /// 场景里当前可见（会进 PT）的对象顺序。图集 slice 按这个顺序分配，
    /// PT 转译端必须拿同一份顺序去查映射，两边才咬得上。
    var 场景对象ID: [UUID] = []

    private var splatPipeline: MTLRenderPipelineState?
    private var 合成Pipeline: MTLComputePipelineState?
    private var 管线已就绪 = false
    private var layerParamBuffer: MTLBuffer?

    private init() {
        device = MTLCreateSystemDefaultDevice()
        queue = device?.makeCommandQueue()
    }

    // MARK: 栈与图集

    func stack(for objectID: UUID) -> PaintStack {
        if let s = stacks[objectID] { return s }
        let s = PaintStack(objectID: objectID)
        stacks[objectID] = s
        return s
    }

    func stackIfExists(_ objectID: UUID) -> PaintStack? { stacks[objectID] }

    /// 有没有任何对象的笔迹需要 PT 去采样
    var 有绘画内容: Bool { stacks.values.contains { $0.已启用 } }

    /// 保证 layerArray 存在（首次真正落笔时才分配，空工程不吃显存）
    private func ensureLayerArray(_ stack: PaintStack) -> MTLTexture? { ensureArray(stack, .baseColor) }

    /// 保证某个通道的图层数组存在。通道数组和颜色数组布局完全一致（8 slice、rgba8），
    /// 这样切层、删层、擦除这些操作只需要把「目标纹理」换一下，逻辑一套走完。
    private func ensureArray(_ stack: PaintStack, _ ch: PaintChannel) -> MTLTexture? {
        if ch == .baseColor, let t = stack.layerArray { return t }
        if ch != .baseColor, let t = stack.通道数组[ch] { return t }
        guard let device else { return nil }
        let desc = MTLTextureDescriptor()
        desc.textureType = .type2DArray
        desc.pixelFormat = .rgba8Unorm
        desc.width = PaintUV.图集边长
        desc.height = PaintUV.图集边长
        desc.arrayLength = PaintStack.最大图层数
        desc.mipmapLevelCount = 1
        // 删除图层要在图集内部跨 slice 前移像素（blit copy），Metal 的 usage 不含 blit 标志，
        // 只要纹理存在就能 copy，所以这里照旧只声明读和渲染目标。
        desc.usage = [.shaderRead, .renderTarget]
        desc.storageMode = .private
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        if ch == .baseColor {
            stack.layerArray = tex
        } else {
            stack.通道数组[ch] = tex
        }
        stack.已启用 = true
        // 新纹理的内容是未定义内存，必须整个清成完全透明。
        // 漏这一下的话，第一次落笔会 load 到一片随机像素，合成进图集就是满屏垃圾色。
        if let queue {
            for slice in 0..<PaintStack.最大图层数 {
                let pass = MTLRenderPassDescriptor()
                let attach = pass.colorAttachments[0]!
                attach.texture = tex
                attach.slice = slice
                attach.loadAction = .clear
                attach.storeAction = .store
                attach.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
                if let cb = queue.makeCommandBuffer(),
                   let enc = cb.makeRenderCommandEncoder(descriptor: pass) {
                    enc.endEncoding()
                    cb.commit()
                }
            }
        }
        return tex
    }

    func layerArray(of stack: PaintStack) -> MTLTexture? { stack.layerArray }

    /// 覆盖度场：全图集一张、一次落笔用一次（用完就清，不保留内容）
    private func 确保覆盖场() -> MTLTexture? {
        if let t = 覆盖场纹理 { return t }
        guard let device else { return nil }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: PaintUV.图集边长, height: PaintUV.图集边长,
            mipmapped: false
        )
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private
        guard let t = device.makeTexture(descriptor: desc) else { return nil }
        覆盖场纹理 = t
        return t
    }

    /// 把一批 splat 先 max 累积成覆盖度场，再整张 over 合到目标纹理上。
    /// - Parameter target: 图层（rgba8，上色）或洞图（r8，镂空）
    /// - Parameter 用洞管线: true = 目标只吃覆盖度本身
    /// 返回 false 表示管线/纹理没准备好，调用方该回退到旧路径
    /// 第一步：本笔所有 splat 取 max 累积成一张覆盖度场。
    /// 一张场可以被多个通道复用（颜色 / 粗糙度 / 金属度…共用同一次光栅化）。
    private func 覆盖度场(_ cb: MTLCommandBuffer,
                       buffer: MTLBuffer,
                      count: Int,
                        u: inout PaintUniforms,
                     遮罩: MTLTexture) -> MTLTexture? {
        guard let 场 = 确保覆盖场(), let coverPSO = 覆盖Pipeline else { return nil }
        let 场pass = MTLRenderPassDescriptor()
        let 场attach = 场pass.colorAttachments[0]!
        场attach.texture = 场
        场attach.loadAction = .clear
        场attach.storeAction = .store
        场attach.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        if let enc = cb.makeRenderCommandEncoder(descriptor: 场pass) {
            enc.setRenderPipelineState(coverPSO)
            enc.setVertexBuffer(buffer, offset: 0, index: 0)
            enc.setFragmentBytes(&u, length: MemoryLayout<PaintUniforms>.stride, index: 0)
            enc.setFragmentTexture(遮罩, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: count)
            enc.endEncoding()
        }
        return 场
    }

    /// 第二步：整张场一次性 over 合进目标 slice —— 只叠一次，图案的明暗差别才留得住。
    /// 值类通道（粗糙度/金属度/清漆）靠的就是「over 在 rgb 上等于 lerp」这一点，
    /// 所以不需要另写一套混合管线，同一套 blend 因子对颜色和标量都成立。
    private func 应用覆盖场(_ cb: MTLCommandBuffer,
                         场: MTLTexture,
                      颜色: SIMD4<Float>,
                    target: MTLTexture,
                     slice: Int,
                   洞管线: Bool) -> Bool {
        guard let applyPSO = 洞管线 ? 覆盖合成洞Pipeline : 覆盖合成Pipeline else { return false }
        var ap = PaintApply(color: 颜色)
        let pass = MTLRenderPassDescriptor()
        let attach = pass.colorAttachments[0]!
        attach.texture = target
        attach.slice = slice
        attach.loadAction = .load
        attach.storeAction = .store
        if let enc = cb.makeRenderCommandEncoder(descriptor: pass) {
            enc.setRenderPipelineState(applyPSO)
            enc.setFragmentBytes(&ap, length: MemoryLayout<PaintApply>.stride, index: 0)
            enc.setFragmentTexture(场, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: 1)
            enc.endEncoding()
        }
        return true
    }

    private func 覆盖合入(_ cb: MTLCommandBuffer,
                         buffer: MTLBuffer,
                        count: Int,
                          u: inout PaintUniforms,
                       遮罩: MTLTexture,
                       颜色: SIMD4<Float>,
                     target: MTLTexture,
                      slice: Int,
                    洞管线: Bool) -> Bool {
        guard let 场 = 覆盖度场(cb, buffer: buffer, count: count, u: &u, 遮罩: 遮罩) else { return false }
        return 应用覆盖场(cb, 场: 场, 颜色: 颜色, target: target, slice: slice, 洞管线: 洞管线)
    }

    // MARK: 管线

    private func 准备管线() {
        guard !管线已就绪, let device else { return }
        管线已就绪 = true
        guard let library = device.makeDefaultLibrary() else { return }

        if let vfn = library.makeFunction(name: "paintSplatVertex"),
           let ffn = library.makeFunction(name: "paintSplatFragment") {
            for 减alpha in [false, true] {
                let d = MTLRenderPipelineDescriptor()
                d.vertexFunction = vfn
                d.fragmentFunction = ffn
                let a = d.colorAttachments[0]!
                a.pixelFormat = .rgba8Unorm
                a.isBlendingEnabled = true
                if 减alpha {
                    // 擦除 / 镂空：只按覆盖度削减目标 alpha，源色不参与
                    a.sourceRGBBlendFactor = .zero
                    a.destinationRGBBlendFactor = .oneMinusSourceAlpha
                    a.sourceAlphaBlendFactor = .zero
                    a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                } else {
                    // 正常叠加：源色按覆盖度覆盖目标
                    a.sourceRGBBlendFactor = .sourceAlpha
                    a.destinationRGBBlendFactor = .oneMinusSourceAlpha
                    a.sourceAlphaBlendFactor = .one
                    a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                }
                let state = try? device.makeRenderPipelineState(descriptor: d)
                if 减alpha {
                    擦除Pipeline = state
                } else {
                    落笔Pipeline = state
                }
            }
        }

        // 法线通道管线：同一套 splat 顶点，片元按笔刷圆盘位置当场算出世界空间法线，
        // 混合仍按覆盖度 over 到法线图集（rgb 存编码法线，a 存覆盖度）
        if let vfn = library.makeFunction(name: "paintSplatVertex"),
           let nfn = library.makeFunction(name: "paintNormalStampFragment") {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = vfn
            d.fragmentFunction = nfn
            let a = d.colorAttachments[0]!
            a.pixelFormat = .rgba8Unorm
            a.isBlendingEnabled = true
            a.sourceRGBBlendFactor = .sourceAlpha
            a.destinationRGBBlendFactor = .oneMinusSourceAlpha
            a.sourceAlphaBlendFactor = .one
            a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            法线Pipeline = try? device.makeRenderPipelineState(descriptor: d)
        }

        // 镂空管线：同一套 splat 顶点，片元写洞图（r8），混合语义是「覆盖度覆盖」——
        // 反复涂会渐近饱和到 1（洞越涂越实），单笔边缘仍是渐变（洞边不平到锯齿）
        // 注意：vfn/ffn 上面那对是 if-let 的局部常量，出了块就没了。
        // 这里必须重新取一次函数名，否则「Cannot find 'ffn' in scope」。
        if let vfn = library.makeFunction(name: "paintSplatVertex"),
           let sfn = library.makeFunction(name: "paintSplatFragment"),
           let hfn = library.makeFunction(name: "paintHoleFragment") {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = vfn
            d.fragmentFunction = hfn
            let a = d.colorAttachments[0]!
            a.pixelFormat = .r8Unorm
            a.isBlendingEnabled = true
            a.sourceRGBBlendFactor = .sourceAlpha
            a.destinationRGBBlendFactor = .oneMinusSourceAlpha
            a.sourceAlphaBlendFactor = .sourceAlpha
            a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            洞Pipeline = try? device.makeRenderPipelineState(descriptor: d)

            // 洞的「擦除」管线：复用同一条 splat 顶点 + 普通片元，
            // 只把混合换成 dst × (1 - 覆盖度) —— 也就是把洞按覆盖度「填回去」。
            let e = MTLRenderPipelineDescriptor()
            e.vertexFunction = vfn
            e.fragmentFunction = sfn
            let ea = e.colorAttachments[0]!
            ea.pixelFormat = .r8Unorm
            ea.isBlendingEnabled = true
            ea.sourceRGBBlendFactor = .zero
            ea.destinationRGBBlendFactor = .oneMinusSourceAlpha
            ea.sourceAlphaBlendFactor = .zero
            ea.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            洞擦除Pipeline = try? device.makeRenderPipelineState(descriptor: e)
        }

        // 覆盖度场：max 混合。重叠多少次都只取最大值，图案不会被累积抹平
        if let vfn = library.makeFunction(name: "paintSplatVertex"),
           let cfn = library.makeFunction(name: "paintCoverageFragment") {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = vfn
            d.fragmentFunction = cfn
            let a = d.colorAttachments[0]!
            a.pixelFormat = .r8Unorm
            a.isBlendingEnabled = true
            a.rgbBlendOperation = .max
            a.alphaBlendOperation = .max
            a.sourceRGBBlendFactor = .one
            a.destinationRGBBlendFactor = .one
            a.sourceAlphaBlendFactor = .one
            a.destinationAlphaBlendFactor = .one
            覆盖Pipeline = try? device.makeRenderPipelineState(descriptor: d)
        }

        // 覆盖场 → 目标（一次 over，不再饱和）
        if let fv = library.makeFunction(name: "paintFullscreenVertex") {
            if let af = library.makeFunction(name: "paintCoverageApplyFragment") {
                let d = MTLRenderPipelineDescriptor()
                d.vertexFunction = fv
                d.fragmentFunction = af
                let a = d.colorAttachments[0]!
                a.pixelFormat = .rgba8Unorm
                a.isBlendingEnabled = true
                a.sourceRGBBlendFactor = .sourceAlpha
                a.destinationRGBBlendFactor = .oneMinusSourceAlpha
                a.sourceAlphaBlendFactor = .one
                a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                覆盖合成Pipeline = try? device.makeRenderPipelineState(descriptor: d)
            }
            if let hf = library.makeFunction(name: "paintCoverageApplyHoleFragment") {
                let d = MTLRenderPipelineDescriptor()
                d.vertexFunction = fv
                d.fragmentFunction = hf
                let a = d.colorAttachments[0]!
                a.pixelFormat = .r8Unorm
                a.isBlendingEnabled = true
                a.sourceRGBBlendFactor = .sourceAlpha
                a.destinationRGBBlendFactor = .oneMinusSourceAlpha
                a.sourceAlphaBlendFactor = .one
                a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                覆盖合成洞Pipeline = try? device.makeRenderPipelineState(descriptor: d)
            }
        }

        if let fn = library.makeFunction(name: "paintComposite") {
            合成Pipeline = try? device.makeComputePipelineState(function: fn)
        }

        layerParamBuffer = device.makeBuffer(
            length: MemoryLayout<PaintLayerGPU>.stride * PaintStack.最大图层数,
            options: .storageModeShared
        )
    }

    private var 落笔Pipeline: MTLRenderPipelineState?
    /// 法线通道专用：splat 几何 + 当场算法线
    private var 法线Pipeline: MTLRenderPipelineState?
    private var 擦除Pipeline: MTLRenderPipelineState?
    private var 洞Pipeline: MTLRenderPipelineState?
    private var 洞擦除Pipeline: MTLRenderPipelineState?

    // MARK: 覆盖度场
    //
    // 一笔要撒几千个互相重叠的 splat，若逐个 over 叠到图层上，同一像素被覆盖几十次，
    // alpha 立刻饱和成 1 —— 遮罩图案的明暗差别被彻底抹平，笔迹变成一团纯色。
    // 所以先按 max 累积出「这一笔的覆盖度场」，再整张 over 合进图层。
    /// 覆盖度场（r8，全图集一张，每次落笔前清空）
    private var 覆盖场纹理: MTLTexture?
    private var 覆盖Pipeline: MTLRenderPipelineState?
    private var 覆盖合成Pipeline: MTLRenderPipelineState?
    private var 覆盖合成洞Pipeline: MTLRenderPipelineState?

    // MARK: 镂空洞图
    //
    // 镂空 = 这部分表面不存在，像素层面不能写进图层 alpha（那会变成"颜色脏了"而不是"表面没了"），
    // 所以洞单独住一张 r8Unorm texture2d_array，一物体一格。
    // 但"住在图层之外"不等于"跟图层无关"：镂空笔画的归属层记录在 strokes 里，
    // 删层 / 清层 / 撤销都会据剩下的镂空笔画重建洞图，
    // 擦除落笔时也会顺手把洞按覆盖度填回去 —— 语义上洞属于那一层。
    // 格位只增不复用（对象删了也留着空位），否则新建对象会继承上一位主人留下的洞。
    static let 洞槽上限 = 16
    private var 洞图: MTLTexture?
    private var 洞槽表: [UUID: Int] = [:]
    /// 当前真正有洞的对象。撤销清空后会从这里移除，PT 侧据此决定要不要写洞槽。
    private var 洞脏: Set<UUID> = []

    /// 这个对象有没有洞（UI 与 PT 侧共用）
    func 有洞(_ objectID: UUID) -> Bool { 洞脏.contains(objectID) }

    private func 确保洞图() -> MTLTexture? {
        if let 洞图 { return 洞图 }
        guard let device else { return nil }
        let desc = MTLTextureDescriptor()
        desc.textureType = .type2DArray
        desc.pixelFormat = .r8Unorm
        desc.width = PaintUV.图集边长
        desc.height = PaintUV.图集边长
        desc.arrayLength = PaintEngine.洞槽上限
        desc.mipmapLevelCount = 1
        desc.usage = [.shaderRead, .renderTarget]
        desc.storageMode = .private
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        洞图 = tex
        // 新纹理是未定义内存，全部清成 0（0 = 实心，不是洞）。
        // 漏这一步会让某些格子天生带洞，模型开局就缺一块。
        if let queue, let cb = queue.makeCommandBuffer() {
            for slot in 0..<PaintEngine.洞槽上限 {
                let pass = MTLRenderPassDescriptor()
                let attach = pass.colorAttachments[0]!
                attach.texture = tex
                attach.slice = slot
                attach.loadAction = .clear
                attach.storeAction = .store
                attach.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
                if let enc = cb.makeRenderCommandEncoder(descriptor: pass) { enc.endEncoding() }
            }
            cb.commit()
        }
        return tex
    }

    private func 洞槽(for objectID: UUID) -> Int? {
        if let 有 = 洞槽表[objectID] { return 有 }
        guard 洞槽表.count < PaintEngine.洞槽上限 else { return nil }
        let slot = 洞槽表.count
        洞槽表[objectID] = slot
        return slot
    }

    /// 按「还剩哪些镂空笔画」把洞图整格重画一遍（删层 / 清层 / 撤销共用）。
    /// 洞是派生数据：笔画才是真相，所以删掉带洞的那一层之后重建一次，洞就自然补回来了。
    private func 重建洞(objectID: UUID) {
        清空洞(objectID: objectID)
        guard let stack = stacks[objectID] else { return }
        for 笔 in stack.strokes where 笔.mode == .镂空 {
            落笔(objectID: objectID, splats: 笔.splats, mode: .镂空, mask: 笔.mask,
                 反转: 笔.maskInvert, 缩放: 笔.maskScale, 旋转: 笔.maskRot, 平移: 笔.maskOffset,
                 层: 笔.layer, 记录: false, 刷新: false)
        }
    }

    /// 把这个物体的洞整格抹掉（撤销回放前调用）
    private func 清空洞(objectID: UUID) {
        洞脏.remove(objectID)
        guard let slot = 洞槽表[objectID], let 洞图, let queue,
              let cb = queue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        let attach = pass.colorAttachments[0]!
        attach.texture = 洞图
        attach.slice = slot
        attach.loadAction = .clear
        attach.storeAction = .store
        attach.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        if let enc = cb.makeRenderCommandEncoder(descriptor: pass) { enc.endEncoding() }
        cb.commit()
    }

    // MARK: 遮罩纹理

    /// 每种图案的遮罩纹理（256² r8，首次用到才生成）
    private var 遮罩纹理表: [PaintMaskKind: MTLTexture] = [:]
    /// 没选遮罩时绑的 1×1 白图。Metal 要求 shader 采样的纹理必须绑上，
    /// 有它兜底，fragment 里就能无条件 sample，不必再拆一条无遮罩管线。
    private var 白遮罩: MTLTexture?

    private func 遮罩纹理(_ kind: PaintMaskKind) -> MTLTexture? {
        if kind != .无, let 有 = 遮罩纹理表[kind] { return 有 }
        if kind == .无, let 有 = 白遮罩 { return 有 }
        guard let device else { return nil }
        let n = (kind == .无) ? 1 : PaintMaskKind.边长
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: n, height: n, mipmapped: false
        )
        desc.usage = .shaderRead
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        if kind == .无 {
            var 白: UInt8 = 255
            tex.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &白, bytesPerRow: 1)
            白遮罩 = tex
        } else {
            let 像素 = kind.生成像素()
            tex.replace(region: MTLRegionMake2D(0, 0, n, n), mipmapLevel: 0, withBytes: 像素, bytesPerRow: n)
            遮罩纹理表[kind] = tex
        }
        return tex
    }

    // MARK: 落笔

    /// 把一批 splat 画进指定对象。mode 决定是上色、擦当前层，还是把这块表面挖掉。
    /// - Parameter splats: uv 空间切平面采样得到的 splat（世界侧已算好衰减）
    /// - Parameter 层: 指定落到哪一层。撤销/重建回放必须用它 ——
    ///   回放时 activeIndex 早就不是当初那一层了，不指定就会把旧笔迹全糊到当前层。
    func 落笔(objectID: UUID, splats: [PaintSplat], mode: PaintMode, mask: PaintMaskKind,
             反转: Bool = false, 缩放: Float = 1, 旋转: Float = 0, 平移: SIMD2<Float> = .zero,
             层: Int? = nil, 记录: Bool = true, 刷新: Bool = true) {
        准备管线()
        guard !splats.isEmpty, let queue else { return }
        let stack = stack(for: objectID)
        let 当前 = min(max(层 ?? stack.activeIndex, 0), PaintStack.最大图层数 - 1)

        var data = splats
        let bytes = MemoryLayout<PaintSplat>.stride * data.count
        guard let buffer = device?.makeBuffer(bytes: &data, length: bytes, options: .storageModeShared) else { return }
        // 没选遮罩也要绑一张（1×1 白图），这样 fragment 里可以无条件采样
        guard let 遮罩 = 遮罩纹理(mask) else { return }
        let 真的用遮罩 = mask != .无
        var u = PaintUniforms(mode: Int32(mode.rawValue), useMask: 真的用遮罩 ? 1 : 0,
                              maskInvert: (反转 && 真的用遮罩) ? 1 : 0,
                              maskScale: 真的用遮罩 ? max(缩放, 0.05) : 1,
                              maskRot: 真的用遮罩 ? 旋转 * .pi / 180 : 0,
                              maskOffset: 真的用遮罩 ? 平移 : .zero)

        func 收尾() {
            revision &+= 1
            if 记录 {
                // 镂空也记在「当前图层」名下：洞本身住在洞图里，
                // 但语义上它属于这一层 —— 删掉这层，用在这一层上挖的洞就该跟着消失。
                stack.strokes.append(PaintStroke(layer: 当前, mode: mode, mask: mask,
                                                maskInvert: 反转 && 真的用遮罩,
                                                maskScale: 真的用遮罩 ? max(缩放, 0.05) : 1,
                                                maskRot: 真的用遮罩 ? 旋转 : 0,
                                                maskOffset: 真的用遮罩 ? 平移 : .zero, splats: data))
                if stack.strokes.count > PaintStack.最多记录笔画 {
                    stack.strokes.removeFirst(stack.strokes.count - PaintStack.最多记录笔画)
                }
            }
            // 立刻合进图集：PT 下一帧就能采样到新笔迹，不用等别的事件顺手触发。
            // 回放时由调用方统一刷一次，避免一次撤销合成 N 遍。
            if 刷新 { 刷新图集(objectIDs: 场景对象ID) }
        }

        // ---- 镂空：写洞图，一个像素都不碰图层 ----
        // 洞的语义是「这块表面不存在」，和颜色无关。以前它去削所有图层的 alpha，
        // 结果最多只能把颜色染回底材 —— 破洞不透光，看着像脏了，不是破了。
        if mode == .镂空 {
            guard let 洞图 = 确保洞图(), let slot = 洞槽(for: objectID),
                  let cb = queue.makeCommandBuffer() else { return }
            // 先攒覆盖度场再整张合入：几千个重叠 splat 直接 over 会把图案叠成实心，
            // 破布、裂纹这类遮罩就完全看不出形状了
            if 覆盖合入(cb, buffer: buffer, count: data.count, u: &u, 遮罩: 遮罩,
                     颜色: SIMD4<Float>(1, 1, 1, 1),
                     target: 洞图, slice: slot, 洞管线: true) {
                cb.commit()
                洞脏.insert(objectID)
                收尾()
                return
            }
            let pass = MTLRenderPassDescriptor()
            let attach = pass.colorAttachments[0]!
            attach.texture = 洞图
            attach.slice = slot
            attach.loadAction = .load
            attach.storeAction = .store
            // 先校验管线，再创建渲染编码器：编码器不能夹在多绑定 guard 里被提前返回带走
            guard let pso = 洞Pipeline else { return }
            guard let encoder = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
            encoder.setRenderPipelineState(pso)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.setFragmentBytes(&u, length: MemoryLayout<PaintUniforms>.stride, index: 0)
            encoder.setFragmentTexture(遮罩, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: data.count)
            encoder.endEncoding()
            cb.commit()
            洞脏.insert(objectID)
            收尾()
            return
        }

        guard let layers = ensureLayerArray(stack) else { return }
        guard let cb = queue.makeCommandBuffer() else { return }

        // 这一笔落哪些通道：开关和值都是全局的（笔刷），跟当前是哪层、哪个对象无关
        let 全局通道 = PaintSession.shared.brush
        let 开通道: Set<PaintChannel> = 全局通道.开着的通道
        let 取值: (PaintChannel) -> Float = { ch in 全局通道.值(ch) }

        // 绘画走覆盖度场：先 max 累积本笔覆盖度，再整张 over 合进图层。
        // 这是遮罩图案能留在模型上的前提 —— 逐 splat 直接 over 会立刻饱和成纯色，
        // 表现为「一团比笔刷还大的深红，一点纹理都没有」。
        // 多通道共用这一次覆盖度光栅化，只是把「合进哪张图」换一换。
        if mode == .绘画, let 首 = data.first,
           let 场 = 覆盖度场(cb, buffer: buffer, count: data.count, u: &u, 遮罩: 遮罩) {
            var 写了 = false
            for ch in 开通道 {
                let 值: SIMD4<Float>
                switch ch {
                case .baseColor:
                    // 颜色吃笔刷当前色；法线另有算法，见下面
                    值 = SIMD4<Float>(首.color.x, 首.color.y, 首.color.z, 1)
                case .emission:
                    // 【强度在这一笔落下的瞬间烘焙进颜色，之后拖强度滑杆这支笔不跟着变】
                    // 和通道开关解耦同一个道理：滑杆只决定「下一笔画多亮」，
                    // 已画上去的像素是既成事实。以前强度在合成期实时乘，一拖滑杆
                    // 整层历史笔迹全变，等于把滑杆变成了图层属性 —— 那不是要的语义。
                    // 只有 rgb 乘强度、a 保持 1：a 是覆盖度，乘进去会把笔迹变成半透明。
                    let 亮度 = max(取值(ch), 0)
                    值 = SIMD4<Float>(首.color.x * 亮度,
                                     首.color.y * 亮度,
                                     首.color.z * 亮度,
                                     1)
                default:
                    let v = 取值(ch)
                    值 = SIMD4<Float>(v, v, v, 1)
                }
                guard ch != .normal, let target = ensureArray(stack, ch) else { continue }
                // 【通道值一律在这一笔落下的瞬间写死进像素】
                // 之后拖「强度」滑杆只影响下一笔，已经画上去的粗糙度/金属度/自发光
                // 一个都不动 —— 和通道开关解耦是同一个语义：滑杆描述的是「笔」，
                // 不是「层」。以前值在合成期现取全局值，于是调一下滑杆整层历史笔迹全变，
                // 等于把笔的属性偷偷塞给了图层。
                // 覆盖度仍是满的（a=1），强度不折进覆盖度：折进去会出现
                // 「20% 强度画一笔 → 实际 4%」这种平方衰减。
                if 应用覆盖场(cb, 场: 场, 颜色: 值, target: target, slice: 当前, 洞管线: false) {
                    写了 = true
                    stack.用过的通道.insert(ch)
                }
            }
            // 法线通道不能用常量色：它要按每个 splat 的圆盘位置当场算出世界空间法线，
            // 这样笔迹才是「一鼓一鼓的凹凸」，而不是一整块斜的平面。
            if 开通道.contains(.normal),
               let 法线数组 = ensureArray(stack, .normal), let pso = 法线Pipeline {
                let np = MTLRenderPassDescriptor()
                let na = np.colorAttachments[0]!
                na.texture = 法线数组
                na.slice = 当前
                na.loadAction = .load
                na.storeAction = .store
                if let enc = cb.makeRenderCommandEncoder(descriptor: np) {
                    // 法线通道的强度同样只在合成阶段调（拔掉滑杆就是整通道关），
                    // 这里固定出满幅度的一鼓一鼓，保证不同强度下笔迹形状一致
                    var 强度: Float = 1.6
                    enc.setRenderPipelineState(pso)
                    enc.setVertexBuffer(buffer, offset: 0, index: 0)
                    enc.setFragmentBytes(&u, length: MemoryLayout<PaintUniforms>.stride, index: 0)
                    enc.setFragmentTexture(遮罩, index: 0)
                    enc.setFragmentBytes(&强度, length: MemoryLayout<Float>.stride, index: 1)
                    enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: data.count)
                    enc.endEncoding()
                    写了 = true
                    stack.用过的通道.insert(.normal)
                }
            }
            if 写了 {
                cb.commit()
                stack.已启用 = true
                stack.标记脏()
                收尾()
                return
            }
        }

        let pipeline = (mode == .绘画) ? 落笔Pipeline : 擦除Pipeline
        guard let pipeline else { cb.commit(); return }

        // 擦除要削掉这一层「画过的」所有通道，不能只看当前开着的：
        // 开关关掉只是不再写，旧笔迹还在，要是擦除也只削开着的通道，
        // 就会出现「颜色擦掉了，粗糙度/金属度那片还赖在模型上擦不掉」。
        var 擦除目标: [MTLTexture] = [layers]
        if mode == .擦除 {
            for ch in stack.用过的通道 where ch != .baseColor {
                if let t = ensureArray(stack, ch) { 擦除目标.append(t) }
            }
        }
        for target in 擦除目标 {
            let pass = MTLRenderPassDescriptor()
            let attach = pass.colorAttachments[0]!
            attach.texture = target
            attach.slice = 当前
            attach.loadAction = .load
            attach.storeAction = .store
            if let encoder = cb.makeRenderCommandEncoder(descriptor: pass) {
                encoder.setRenderPipelineState(pipeline)
                encoder.setVertexBuffer(buffer, offset: 0, index: 0)
                encoder.setFragmentBytes(&u, length: MemoryLayout<PaintUniforms>.stride, index: 0)
                encoder.setFragmentTexture(遮罩, index: 0)
                // 一个 quad 4 顶点，splat 走实例化，几万个点也只有一次 draw call
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: data.count)
                encoder.endEncoding()
            }
        }

        // 擦除是逆笔刷：除了削当前层颜色，还得把这块的洞按覆盖度填回去。
        // 洞以前住在图层之外，擦除根本碰不到它 —— 于是"挖错了擦不掉、也撤不好"，这次一并修掉。
        if mode == .擦除, let 洞图, let slot = 洞槽表[objectID], let 洞擦除Pipeline {
            let 洞pass = MTLRenderPassDescriptor()
            let 洞attach = 洞pass.colorAttachments[0]!
            洞attach.texture = 洞图
            洞attach.slice = slot
            洞attach.loadAction = .load
            洞attach.storeAction = .store
            if let enc = cb.makeRenderCommandEncoder(descriptor: 洞pass) {
                enc.setRenderPipelineState(洞擦除Pipeline)
                enc.setVertexBuffer(buffer, offset: 0, index: 0)
                enc.setFragmentBytes(&u, length: MemoryLayout<PaintUniforms>.stride, index: 0)
                enc.setFragmentTexture(遮罩, index: 0)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: data.count)
                enc.endEncoding()
            }
        }
        cb.commit()

        stack.已启用 = true
        stack.标记脏()
        收尾()
    }

    /// 撤销一笔：把该笔所在图层清空，再把这一层剩下的笔画按顺序重放。
    /// 只重放同一图层 —— 别的图层内容没被动过，动它们反而会引入误差。
    @discardableResult
    func 撤销(objectID: UUID) -> Bool {
        guard let stack = stacks[objectID], stack.strokes.popLast() != nil else { return false }
        // 镂空会挖穿所有图层，旧的「只重放同一层」增量撤销已经不成立了：
        // 一次镂空之后，任何层的重建都得把全部笔画按原顺序重走一遍。
        // 代价是撤销从「重放一层」变成「全栈重放」；笔画上限 240，每笔一个 draw call，
        // 实测仍在毫秒级，换来的是跨层语义绝对正确。
        // 洞也要一起回放：镂空笔的产物全在洞图上，不清掉的话撤销只撤颜色、洞还留在那
        清空洞(objectID: objectID)
        if stack.layerArray != nil {
            for i in 0..<max(stack.layers.count, 1) {
                清空图层(objectID: objectID, index: i, 刷新: false, 清历史: false)
            }
        }
        for 笔 in stack.strokes {
            落笔(objectID: objectID, splats: 笔.splats, mode: 笔.mode, mask: 笔.mask,
                 反转: 笔.maskInvert, 缩放: 笔.maskScale, 旋转: 笔.maskRot, 平移: 笔.maskOffset,
                 层: 笔.layer, 记录: false, 刷新: false)
        }
        刷新图集(objectIDs: 场景对象ID)
        return true
    }

    /// 清空某图层（图层面板上的「清空」）
    /// - Parameter 清历史: 面板上手点「清空」时传 true —— 撤销是按 strokes 逐层重放的，
    ///   只抹像素不清历史的话，下一笔撤销就会把刚清掉的内容整层复活。
    ///   撤销流程内部调用时必须为 false，否则会把自己正在重放的记录删掉。
    func 清空图层(objectID: UUID, index: Int, 刷新: Bool = true, 清历史: Bool = false) {
        guard let queue,
              let stack = stacks[objectID],
              let layers = ensureArray(stack, .baseColor) else { return }
        let 格 = min(max(index, 0), PaintStack.最大图层数 - 1)
        // 这一层的所有通道一起清：只清颜色的话，删层/清空之后粗糙度笔迹还会现形
        var 清空目标: [MTLTexture] = [layers]
        清空目标.append(contentsOf: stack.通道数组.values)
        guard let cb = queue.makeCommandBuffer() else { return }
        for tex in 清空目标 {
            let pass = MTLRenderPassDescriptor()
            let attach = pass.colorAttachments[0]!
            attach.texture = tex
            attach.slice = 格
            attach.loadAction = .clear
            attach.storeAction = .store
            attach.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            if let enc = cb.makeRenderCommandEncoder(descriptor: pass) { enc.endEncoding() }
        }
        cb.commit()
        if 清历史 {
            // 这一层上挖的洞随这一层一起清掉：先记下来，剔除笔画后再照剩下的镂空笔重建。
            let 带镂空 = stack.strokes.contains { $0.layer == index && $0.mode == .镂空 }
            stack.strokes.removeAll { $0.layer == index }
            if 带镂空, 洞槽表[objectID] != nil { 重建洞(objectID: objectID) }
        }
        stack.标记脏()
        revision &+= 1
        if 刷新 { 刷新图集(objectIDs: 场景对象ID) }
    }

    /// 删除某图层：连图层条目一起移除（区别于 清空图层 只抹像素）。
    ///
    /// 关键约定：slice 下标必须永远等于图层数组下标（落笔、清空、合成都依赖这点），
    /// 所以删掉中间一层后，后面所有图层的像素都得整体前移一格；
    /// 少了这一步就会出现「删掉图层 2，原来的图层 3 顶着图层 2 的位置」的错位。
    func 删除图层(objectID: UUID, index: Int, 刷新: Bool = true) {
        guard let stack = stacks[objectID], stack.layers.indices.contains(index) else { return }

        // 最后一层也允许真删：删空之后立刻补一个全新的「图层 1」并切成当前层。
        // 这样「删除」的语义始终一致（永远是删掉一层），而栈又不会真的空掉；
        // 名字从 1 重新起算，不会出现「只剩图层 2 却新建出图层 2」这种怪名字。
        guard stack.layers.count > 1 else {
            // 先把这一格像素抹掉，新图层复用的是同一个 slice
            清空图层(objectID: objectID, index: index, 刷新: false)
            stack.layers = [PaintLayer(name: "图层 1")]
            stack.activeIndex = 0
            stack.strokes.removeAll()
            清空洞(objectID: objectID)
            stack.标记脏()
            revision &+= 1
            if 刷新 { 刷新图集(objectIDs: 场景对象ID) }
            return
        }

        let 末 = stack.layers.count - 1

        var 数组们: [MTLTexture] = []
        if let layers = stack.layerArray { 数组们.append(layers) }
        数组们.append(contentsOf: stack.通道数组.values)
        if let queue, !数组们.isEmpty {
            let 原点 = MTLOrigin(x: 0, y: 0, z: 0)
            if let cb = queue.makeCommandBuffer() {
                for tex in 数组们 {
                    let 尺寸 = MTLSize(width: tex.width, height: tex.height, depth: 1)
                    // 从被删位置往后逐格前移。同一 blit encoder 内命令按编码顺序执行，
                    // 低往高搬不会自己踩自己（i+1 的内容先落到 i，之后才被 i+2 覆盖）。
                    if index < 末, let blit = cb.makeBlitCommandEncoder() {
                        for i in index..<末 {
                            blit.copy(
                                from: tex, sourceSlice: i + 1, sourceLevel: 0,
                                sourceOrigin: 原点, sourceSize: 尺寸,
                                to: tex, destinationSlice: i, destinationLevel: 0,
                                destinationOrigin: 原点
                            )
                        }
                        blit.endEncoding()
                    }
                    // 尾部空出来的那一格清透明，否则下次新建图层 load 到这块残留像素
                    let pass = MTLRenderPassDescriptor()
                    let attach = pass.colorAttachments[0]!
                    attach.texture = tex
                    attach.slice = 末
                    attach.loadAction = .clear
                    attach.storeAction = .store
                    attach.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
                    if let enc = cb.makeRenderCommandEncoder(descriptor: pass) { enc.endEncoding() }
                }
                cb.commit()
            }
        }

        stack.layers.remove(at: index)

        // 笔画历史里的图层下标跟着重映射：被删层的笔画直接丢，它后面的往前挪一格
        stack.strokes = stack.strokes.compactMap { 笔 in
            if 笔.layer == index { return nil }
            guard 笔.layer > index else { return 笔 }
            var 新笔 = 笔
            新笔.layer -= 1
            return 新笔
        }

        // 当前层修正：删的是自己就落到原位置（删的是末尾则往前收一格）
        if stack.activeIndex > index {
            stack.activeIndex -= 1
        } else if stack.activeIndex == index {
            stack.activeIndex = min(index, stack.layers.count - 1)
        }
        stack.activeIndex = min(max(stack.activeIndex, 0), stack.layers.count - 1)

        // 被删层上的镂空笔已经从 strokes 里剔掉了，洞据此重建一次 ——
        // 删掉图层，在这一层上挖的洞就该跟着消失（此前洞独立存放，删层也留着）。
        if 洞槽表[objectID] != nil { 重建洞(objectID: objectID) }

        stack.标记脏()
        revision &+= 1
        if 刷新 { 刷新图集(objectIDs: 场景对象ID) }
    }

    /// 图层元数据变了（显隐 / 不透明度 / 混合 / 名字）：置脏重合成一次。
    /// 像素没动，所以不需要清纹理，只是把「怎么混」重新算进图集。
    func 图层已变更(objectID: UUID) {
        guard let stack = stacks[objectID] else { return }
        stack.标记脏()
        revision &+= 1
        刷新图集(objectIDs: 场景对象ID)
    }

    /// 通道开关 / 通道值改了。这两样是全局的（笔刷上），
    /// 一改就影响所有对象、所有层，所以要把每个栈都置脏重合成一遍。
    /// 不然只有当前对象跟着变，切到别的物体还是老样子。
    func 通道已变更() {
        for stack in stacks.values where stack.已启用 { stack.标记脏() }
        revision &+= 1
        刷新图集(objectIDs: 场景对象ID)
    }

    /// 新建一图层并切到它。新图层对应的 slice 可能是上一轮用过的残留像素，
    /// 必须先清成透明，否则一加图层底下就冒出别人的旧笔迹。
    func 新建图层(objectID: UUID) {
        let stack = stack(for: objectID)
        guard stack.layers.count < PaintStack.最大图层数 else { return }
        stack.layers.append(PaintLayer(name: 下一个图层名(stack.layers)))
        stack.activeIndex = stack.layers.count - 1
        if stack.layerArray != nil {
            清空图层(objectID: objectID, index: stack.activeIndex)
        } else {
            图层已变更(objectID: objectID)
        }
    }

    /// 新图层的名字：取现有「图层 N」里最大的 N 再加一。
    /// 不能用 count + 1：删掉中间层后 count 会回落，名字就会撞上已有图层
    /// （2 层删掉图层 1，剩图层 2，count+1 = 2，又新建出一个「图层 2」）。
    /// 自己改过名的图层不参与编号，不会干扰。
    private func 下一个图层名(_ layers: [PaintLayer]) -> String {
        let 前缀 = "图层 "
        var 最大 = 0
        for layer in layers where layer.name.hasPrefix(前缀) {
            if let n = Int(layer.name.dropFirst(前缀.count)), n > 最大 { 最大 = n }
        }
        return "图层 \(最大 + 1)"
    }

    /// 改图层名（面板上双击图层名进入编辑）。
    /// 名字只影响面板显示，不参与合成，所以这里不碰纹理、不置脏、也不动 revision，
    /// 靠 @Observable 自己刷新面板即可，省掉一次多余的重合成。
    func 重命名图层(objectID: UUID, index: Int, 名字: String) {
        guard let stack = stacks[objectID], stack.layers.indices.contains(index) else { return }
        let 干净 = 名字.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !干净.isEmpty, 干净 != stack.layers[index].name else { return }
        stack.layers[index].name = 干净
    }

    /// 切换当前绘制图层
    func 切到图层(objectID: UUID, index: Int) {
        guard let stack = stacks[objectID] else { return }
        stack.activeIndex = min(max(index, 0), stack.layers.count - 1)
        revision &+= 1
    }

    // MARK: - 新建项目

    /// 新建项目：把绘画侧整体回到「刚启动、一笔都没画」的状态。
    ///
    /// 这里清的是引擎自己的全部表，而不只是笔迹 —— 图集 slice 分配、洞槽、
    /// 可见对象顺序都跟上一份文档的物体 ID 绑定，留着它们新文档的物体会
    /// 继续沿用旧切片，历史笔迹也就跟着进了新文件。
    func 清空全部() {
        stacks.removeAll()
        顺序.removeAll()
        已分配.removeAll()
        洞槽表.removeAll()
        洞脏.removeAll()
        场景对象ID.removeAll()
        atlas = nil
        通道图集.removeAll()
        sliceOf.removeAll()
        洞图 = nil
        // 版本 +1：PT 侧靠它判断要不要重开累积，图集换空必须让它失效
        revision &+= 1
    }

    // MARK: 合成 + 图集

    /// 把当前场景里所有带笔迹的对象合成进图集，返回可直接绑给 PT 的纹理。
    /// 顺序决定 slice 下标：调用方（PT 转译）必须用同一顺序去查 sliceOf。
    func 刷新图集(objectIDs: [UUID]) {
        执行刷新图集(objectIDs: objectIDs)
        同步GPU快照()
    }

    /// 把当前结果镜像进跨线程快照，PT 渲染线程每帧读它
    private func 同步GPU快照() {
        let 纹理 = (atlas != nil && 有绘画内容) ? atlas : 图集或占位()?.texture
        PaintGPUSnapshot.shared.写(
            atlas: 纹理,
            revision: revision,
            sliceOf: atlas != nil ? sliceOf : [:],
            有绘画: atlas != nil && 有绘画内容,
            holeAtlas: 洞脏.isEmpty ? nil : 洞图,
            holeSlotOf: 洞脏.isEmpty ? [:] : 洞槽表,
            有洞: !洞脏.isEmpty,
            通道图集: 通道图集
        )
    }

    private func 执行刷新图集(objectIDs: [UUID]) {
        准备管线()
        guard let device, let queue else { return }
        // 【slice 分配必须稳定】
        // 以前直接按 objectIDs 的顺序分片：对象在场景里换个顺序（拖动排序、删一个再加回来）
        // 图集片数往往没变因而不重建，但 slice 编号整体错位 —— A 采样到 B 的格子，
        // 两个模型互相显示对方的笔迹，看起来就是「莫名其妙整个模型被染色」。
        // 现在保留既有分配顺序，只有新对象才追加到末尾。
        let 可用 = Set(objectIDs.filter { stacks[$0]?.已启用 == true })
        顺序.removeAll { !可用.contains($0) }
        for id in objectIDs where 可用.contains(id) && !顺序.contains(id) {
            顺序.append(id)
        }
        let 有内容 = 顺序
        guard !有内容.isEmpty else {
            atlas = nil
            sliceOf = [:]
            return
        }

        // 光比片数不够：A 隐藏、C 显示时片数可能不变，但 C 会继承 A 留下的旧笔迹。
        // 成员一变就重建，重建会把所有栈重新合成一遍。
        let 成员变了 = 有内容 != 已分配
        if atlas == nil || atlas!.arrayLength != 有内容.count || 成员变了 {
            let desc = MTLTextureDescriptor()
            desc.textureType = .type2DArray
            desc.pixelFormat = .rgba8Unorm
            desc.width = PaintUV.图集边长
            desc.height = PaintUV.图集边长
            desc.arrayLength = 有内容.count
            desc.mipmapLevelCount = 1
            desc.usage = [.shaderRead, .renderTarget, .shaderWrite]
            desc.storageMode = .private
            atlas = device.makeTexture(descriptor: desc)
            // 通道图集跟颜色图集同生共死：片数、边长、格式全都一样，
            // 这样合成、清空、切片下标只需要换纹理，不用再分叉一套逻辑
            通道图集 = [:]
            for ch in PaintChannel.allCases where ch != .baseColor {
                通道图集[ch] = device.makeTexture(descriptor: desc)
            }
            // 新建的图集是未定义内存：没被合成覆盖到的 slice 会留下随机像素，
            // 表现为「画了一笔，整个球面糊上一层脏色」。先整张清成透明。
            if let atlas, let cb = queue.makeCommandBuffer() {
                // 颜色图集和所有通道图集一起清，漏一张就会在模型上糊一层脏色
                var 待清: [MTLTexture] = [atlas]
                待清.append(contentsOf: 通道图集.values)
                for tex in 待清 {
                    for slice in 0..<有内容.count {
                        let pass = MTLRenderPassDescriptor()
                        let attach = pass.colorAttachments[0]!
                        attach.texture = tex
                        attach.slice = slice
                        attach.loadAction = .clear
                        attach.storeAction = .store
                        attach.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
                        if let enc = cb.makeRenderCommandEncoder(descriptor: pass) {
                            enc.endEncoding()
                        }
                    }
                }
                cb.commit()
            }
            // 新建的图集全是空像素，所有栈都得重新合成
            for id in 有内容 { stacks[id]?.标记脏() }
            已分配 = 有内容
        }

        guard let atlas else { return }

        sliceOf = [:]
        for (index, id) in 有内容.enumerated() { sliceOf[id] = index }

        var 待合成: [(Int, PaintStack)] = []
        for (index, id) in 有内容.enumerated() {
            guard let stack = stacks[id] else { continue }
            if stack.脏 { 待合成.append((index, stack)) }
        }
        guard !待合成.isEmpty, let cb = queue.makeCommandBuffer() else { return }

        // 合成不读任何全局通道状态：通道值已经在落笔时写进像素了，
        // 这里只看图层自己的不透明度/混合/显隐。
        for (index, stack) in 待合成 {
            guard let pso = 合成Pipeline,
                  let params = layerParamBuffer else { break }
            var gpu = stack.layers.prefix(PaintStack.最大图层数).map {
                PaintLayerGPU(
                    // 颜色通道的开关只管「颜色参不参与」，不透明度还是图层自己那根
                    opacity: $0.opacity,
                    blend: Int32(PaintBlend.allCases.firstIndex(of: $0.blend) ?? 0),
                    visible: $0.isVisible ? 1 : 0
                )
            }
            while gpu.count < PaintStack.最大图层数 {
                gpu.append(PaintLayerGPU(opacity: 0, blend: 0, visible: 0))
            }
            var count = UInt32(min(stack.layers.count, PaintStack.最大图层数))
            var slice = UInt32(index)

            // 颜色一张图集 + 这一层用过的每个通道各一张，全都走同一个合成 kernel：
            // 混合规则、图层顺序、不透明度对颜色和标量通道是同一套语义，没必要分叉。
            var 目标们: [(layers: MTLTexture, 图集: MTLTexture, 通道: PaintChannel?)] = []
            if let l = stack.layerArray { 目标们.append((l, atlas, nil)) }
            for ch in stack.用过的通道.sorted(by: { $0.rawValue < $1.rawValue }) {
                if let l = stack.通道数组[ch], let a = 通道图集[ch] { 目标们.append((l, a, ch)) }
            }
            guard !目标们.isEmpty, let enc = cb.makeComputeCommandEncoder() else { continue }
            enc.setComputePipelineState(pso)
            enc.setBuffer(params, offset: 0, index: 0)
            enc.setBytes(&count, length: MemoryLayout<UInt32>.stride, index: 1)
            enc.setBytes(&slice, length: MemoryLayout<UInt32>.stride, index: 2)
            let w = pso.threadExecutionWidth
            let h = max(1, pso.maxTotalThreadsPerThreadgroup / w)
            let grid = MTLSize(width: PaintUV.图集边长, height: PaintUV.图集边长, depth: 1)
            // 线程组总线程数绝不能超过 maxTotalThreadsPerThreadgroup：
            // 超了 dispatch 会被驱动丢弃，图集一片都不写，表现就是「画了但看不到」。
            let group = MTLSize(width: w, height: h, depth: 1)
            for 目标 in 目标们 {
                // 参数缓冲是共享对象，每次 dispatch 前重灌一遍，避免上一轮残留。
                //
                // 【通道开关只管落笔，不管已有内容】
                // 开关关掉 = 接下来的笔画不往这个通道写；已经画上去的金属度、粗糙度
                // 照样参与合成。不然「关一下开关把上个模型辛苦画的金属度也擦了」——
                // 开关本来就不是图层的显隐，层只负责记录像素。
                // visible 只由图层自己的眼睛图标（isVisible）决定；
                // 通道与颜色走同一套图层参数，所以这里不再按通道分叉。
                gpu.withUnsafeBytes { raw in
                    params.contents().copyMemory(from: raw.baseAddress!, byteCount: raw.count)
                }
                // 【合成期不再注入任何「当前滑杆值」，只忠实读图集】
                // 通道值（含自发光强度）在落笔那一刻就写进了像素，合成只负责按
                // 图层顺序/混合模式叠起来。所以拖滑杆不会让历史笔迹跟着变，
                // 和「通道开关只管落笔、不管已有内容」是同一条原则。
                // 以前这里把全局值整片灌给 kernel（常量通道换标量、自发光乘强度），
                // 结果滑杆实际上变成了图层属性 —— 一拖就把整层笔迹重画成新值。
                enc.setTexture(目标.layers, index: 0)
                enc.setTexture(目标.图集, index: 1)
                enc.dispatchThreads(grid, threadsPerThreadgroup: group)
            }
            enc.endEncoding()
            stack.脏 = false
        }
        cb.commit()
        // 【必须等这几毫秒】PT 在另一条 command queue 上采样图集，跟这里的合成没有任何顺序保证。
        // 不等的话：主线程提交合成 → 立刻把 revision 写进快照 → PT 看到"新版本"开一帧新累积，
        // 但 GPU 上这一帧采到的还是合成前的空图集 → 笔迹这一帧等于没画，
        // 而 paintChanged 已经被消费掉了，之后不会再有 reset —— 累积里永远没有这一笔。
        // 表现就是「第一次画看不到，切个模式（重建累积）才出现」。合成只有几个 quad，很便宜。
        cb.waitUntilCompleted()
    }

    /// 给 PT 用的空图集：着色器里靠 sliceCount == 0 跳过采样，不需要分支判断纹理存不存在
    private var dummyAtlas: MTLTexture?

    // MARK: 自检（PAINT_SELFTEST=1 时启动即跑一遍）

    /// 自检只跑一次
    static var 自检已跑 = false

    /// 走真实的「中心射线拾取 → 表面采样 → 落笔 → 合成」全链路，
    /// 并统计图层/图集的非零像素，用来区分「拾取没命中」「采样没撒点」「合成没进图集」。
    func 自检(objects: [SceneObject], 相机: 视口相机) {
        let size = CGSize(width: 1200, height: 700)
        let 中心 = CGPoint(x: size.width / 2, y: size.height / 2)
        guard let (origin, direction) = 相机.射线(屏幕点: 中心, 视图尺寸: size) else {
            NSLog("PAINT自检 射线失败"); return
        }
        guard let hit = PaintPicker.拾取(origin: origin, direction: direction, objects: objects),
              let 目标 = objects.first(where: { $0.id == hit.objectID }) else {
            NSLog("PAINT自检 拾取未命中 objects=\(objects.count)"); return
        }
        let 自检笔刷 = PaintBrush(radius: 0.04, hardness: 0.9)
        let 自检基 = PaintBrushFrame(normal: hit.worldNormal, 屏幕角: 自检笔刷.maskRot, 相机: 相机)
        let splats = PaintPicker.采样(object: 目标, hit: hit, brush: 自检笔刷, 基: 自检基)
        if let r0 = splats.first?.radius, let r1 = splats.map({ $0.radius.x }).max(),
           let c0 = splats.first?.center, let cx1 = splats.map({ $0.center.x }).max() {
            let j0 = splats.first?.brushJac ?? .zero
            NSLog("PAINT自检 命中 object=\(hit.objectID) splats=\(splats.count) r首次=\(r0.x) r最大=\(r1) uv首=\(c0) uvMaxX=\(cx1) 基=\(自检基.x)/\(自检基.y) 法线=\(hit.worldNormal) jac=\(j0)")
        }
        guard !splats.isEmpty else { return }
        场景对象ID = objects.map(\.id)
        落笔(objectID: hit.objectID, splats: splats, mode: .绘画, mask: .无, 刷新: false)
        刷新图集(objectIDs: 场景对象ID)
        let 快照 = PaintGPUSnapshot.shared.读()
        NSLog("PAINT自检 atlas=\(atlas != nil ? 1 : 0) slice=\(sliceOf[hit.objectID].map(String.init) ?? "nil") 快照有绘画=\(快照.有绘画 ? 1 : 0) 快照slice=\(快照.sliceOf[hit.objectID].map(String.init) ?? "nil") rev=\(快照.revision)")
        guard let atlas, let device else { return }
        统计图集(atlas, device: device, id: hit.objectID)
    }

    private func 统计图集(_ atlas: MTLTexture, device: MTLDevice, id: UUID) {
        guard let slice = sliceOf[id], let queue, let layers = stacks[id]?.layerArray else {
            NSLog("PAINT自检 无 slice 或图层"); return
        }
        let bpr = atlas.width * 4
        guard let 池 = device.makeBuffer(length: bpr * atlas.height, options: .storageModeShared),
              let cb = queue.makeCommandBuffer(),
              let blit = cb.makeBlitCommandEncoder() else { return }
        blit.copy(from: atlas, sourceSlice: slice, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: atlas.width, height: atlas.height, depth: 1),
                  to: 池, destinationOffset: 0, destinationBytesPerRow: bpr,
                  destinationBytesPerImage: bpr * atlas.height)
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()

        let ptr = 池.contents().bindMemory(to: UInt8.self, capacity: bpr * atlas.height)
        var 非零 = 0
        var 最大A: UInt8 = 0
        for i in stride(from: 3, to: bpr * atlas.height, by: 4) {
            if ptr[i] > 0 { 非零 += 1; 最大A = max(最大A, ptr[i]) }
        }
        // 图层侧也统计一份：区分「没写进图层」和「没合进图集」
        let 图层行 = layers.width * 4
        guard let 池2 = device.makeBuffer(length: 图层行 * layers.height, options: .storageModeShared),
              let cb2 = queue.makeCommandBuffer(),
              let blit2 = cb2.makeBlitCommandEncoder() else { return }
        blit2.copy(from: layers, sourceSlice: 0, sourceLevel: 0,
                   sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                   sourceSize: MTLSize(width: layers.width, height: layers.height, depth: 1),
                   to: 池2, destinationOffset: 0, destinationBytesPerRow: 图层行,
                   destinationBytesPerImage: 图层行 * layers.height)
        blit2.endEncoding()
        cb2.commit()
        cb2.waitUntilCompleted()
        let ptr2 = 池2.contents().bindMemory(to: UInt8.self, capacity: 图层行 * layers.height)
        var 图层非零 = 0
        for i in stride(from: 3, to: 图层行 * layers.height, by: 4) where ptr2[i] > 0 { 图层非零 += 1 }
        NSLog("PAINT自检 图层非零α=\(图层非零) 图集slice\(slice)非零α=\(非零) 最大α=\(最大A)")
    }

    func 图集或占位() -> (texture: MTLTexture, 有内容: Bool)? {
        if let atlas, 有绘画内容 { return (atlas, true) }
        if let dummyAtlas { return (dummyAtlas, false) }
        guard let device else { return nil }
        let desc = MTLTextureDescriptor()
        desc.textureType = .type2DArray
        desc.pixelFormat = .rgba8Unorm
        desc.width = 1
        desc.height = 1
        desc.arrayLength = 1
        desc.usage = [.shaderRead]
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        dummyAtlas = tex
        return (tex, false)
    }
}


// MARK: - 项目容器：绘画导出 / 恢复

/// 一次导出任务：GPU 读回缓冲 + 要一起带回的图层元信息。
/// 标 @unchecked Sendable 是因为 MTLBuffer / MTLTexture 本身线程安全，只是没打协议标记。
private final class 绘画导出任务: @unchecked Sendable {
    let 物体: UUID
    let 通道: String
    let 纹理: MTLTexture
    let 缓冲: MTLBuffer
    let 图层: [绘画图层快照]
    let 当前: Int
    init(物体: UUID, 通道: String, 纹理: MTLTexture, 缓冲: MTLBuffer,
         图层: [绘画图层快照], 当前: Int) {
        self.物体 = 物体
        self.通道 = 通道
        self.纹理 = 纹理
        self.缓冲 = 缓冲
        self.图层 = 图层
        self.当前 = 当前
    }
}

extension PaintEngine {

    /// 导出一份可落盘的稀疏绘画快照。
    ///
    /// 主线程只做命令编码（微秒级），像素读回、tile 稀疏化、zlib 压缩全在
    /// GPU 完成回调里跑。几十个对象都画满的项目保存起来也不会卡住界面。
    func 导出绘画快照(完成: @escaping @Sendable (绘画快照) -> Void) {
        guard let device, let queue else {
            完成(绘画快照(revision: revision, 物体: []))
            return
        }
        let 边长 = PaintUV.图集边长
        let 切片数 = PaintStack.最大图层数
        let 每片字节 = 边长 * 边长 * 4

        var 任务表: [绘画导出任务] = []
        for (id, stack) in stacks where stack.已启用 {
            let 图层 = stack.layers.map {
                绘画图层快照(id: $0.id, 名称: $0.name, 可见: $0.isVisible,
                          不透明度: $0.opacity, 混合: $0.blend.rawValue)
            }
            var 纹理对: [(String, MTLTexture)] = []
            if let t = stack.layerArray { 纹理对.append((PaintChannel.baseColor.rawValue, t)) }
            for (ch, t) in stack.通道数组 { 纹理对.append((ch.rawValue, t)) }
            for (名, tex) in 纹理对 where tex.width == 边长 {
                guard let buf = device.makeBuffer(length: 每片字节 * 切片数,
                                                  options: .storageModeShared) else { continue }
                任务表.append(绘画导出任务(物体: id, 通道: 名, 纹理: tex, 缓冲: buf,
                                     图层: 图层, 当前: stack.activeIndex))
            }
        }

        guard !任务表.isEmpty,
              let cb = queue.makeCommandBuffer(),
              let blit = cb.makeBlitCommandEncoder() else {
            完成(绘画快照(revision: revision, 物体: []))
            return
        }
        for t in 任务表 {
            for s in 0..<切片数 {
                blit.copy(from: t.纹理, sourceSlice: s, sourceLevel: 0,
                          sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                          sourceSize: MTLSize(width: 边长, height: 边长, depth: 1),
                          to: t.缓冲, destinationOffset: s * 每片字节,
                          destinationBytesPerRow: 边长 * 4,
                          destinationBytesPerImage: 每片字节)
            }
        }
        blit.endEncoding()

        let 版本 = revision
        cb.addCompletedHandler { _ in
            var 表: [UUID: 物体绘画快照] = [:]
            for t in 任务表 {
                var 块表: [容器绘画.块] = []
                let base = t.缓冲.contents()
                for s in 0..<切片数 {
                    let p = UnsafeRawBufferPointer(start: base.advanced(by: s * 每片字节),
                                                   count: 每片字节)
                    容器绘画.切片入块(p, 边长: 边长, 切片: s, 收集: &块表)
                }
                let data = 容器绘画.打包(边长: 边长, 切片数: 切片数, 块: 块表)
                var 物 = 表[t.物体] ?? 物体绘画快照(物体ID: t.物体, 图层: t.图层,
                                              当前图层: t.当前, 通道: [:])
                物.通道[t.通道] = [UInt8](data)
                表[t.物体] = 物
            }
            完成(绘画快照(revision: 版本,
                       物体: 表.values.sorted { $0.物体ID.uuidString < $1.物体ID.uuidString }))
        }
        cb.commit()
    }

    /// 从容器恢复绘画。
    ///
    /// 这里**不重放笔迹**：strokes 只保留最近 240 笔（撤销用的窗口），
    /// 拿它重画会丢掉窗口之前的全部内容。直接上传像素块才是无损的。
    func 恢复绘画快照(_ 快照: 绘画快照) {
        guard let device, let queue else { return }
        let 边长 = PaintUV.图集边长
        var 脏对象: [UUID] = []

        for 物 in 快照.物体 {
            let stack = stack(for: 物.物体ID)
            if !物.图层.isEmpty {
                stack.layers = 物.图层.map {
                    PaintLayer(id: $0.id, name: $0.名称, isVisible: $0.可见,
                               opacity: $0.不透明度, blend: PaintBlend(rawValue: $0.混合) ?? .normal)
                }
                stack.activeIndex = min(max(0, 物.当前图层), max(0, stack.layers.count - 1))
            }

            for (通道名, 字节) in 物.通道 {
                guard let ch = PaintChannel(rawValue: 通道名),
                      let 解 = 容器绘画.解包(Data(字节)),
                      解.边长 == 边长,
                      let tex = ensureArray(stack, ch) else { continue }

                // 先把所有块拼成一段连续内存，再建一个 staging buffer。
                // 逐块建 MTLBuffer 会产生几十上百个对象，开销比拷贝本身还大。
                var 暂存: [UInt8] = []
                var 落位: [(偏移: Int, 字节数: Int, 宽: Int, 高: Int, 切片: Int, x: Int, y: Int)] = []
                for b in 解.块 {
                    let tx = Int(b.x) * 容器绘画.tile
                    let ty = Int(b.y) * 容器绘画.tile
                    let w = min(容器绘画.tile, 边长 - tx)
                    let h = min(容器绘画.tile, 边长 - ty)
                    let 字节数 = w * h * 4
                    guard w > 0, h > 0, b.数据.count >= 字节数, Int(b.切片) < tex.arrayLength else { continue }
                    落位.append((暂存.count, 字节数, w, h, Int(b.切片), tx, ty))
                    暂存.append(contentsOf: b.数据[0..<字节数])
                }
                guard !暂存.isEmpty,
                      let buf = device.makeBuffer(length: 暂存.count, options: .storageModeShared),
                      let cb = queue.makeCommandBuffer(),
                      let blit = cb.makeBlitCommandEncoder() else { continue }
                暂存.withUnsafeBytes { 源 in
                    if let 地址 = 源.baseAddress {
                        buf.contents().copyMemory(from: 地址, byteCount: 源.count)
                    }
                }
                for i in 落位 {
                    blit.copy(from: buf,
                              sourceOffset: i.偏移,
                              sourceBytesPerRow: i.宽 * 4,
                              sourceBytesPerImage: i.字节数,
                              sourceSize: MTLSize(width: i.宽, height: i.高, depth: 1),
                              to: tex,
                              destinationSlice: i.切片,
                              destinationLevel: 0,
                              destinationOrigin: MTLOrigin(x: i.x, y: i.y, z: 0))
                }
                blit.endEncoding()
                cb.commit()
                cb.waitUntilCompleted()
                stack.用过的通道.insert(ch)
            }

            stack.已启用 = true
            stack.标记脏()
            脏对象.append(物.物体ID)
        }

        if !脏对象.isEmpty { 刷新图集(objectIDs: 脏对象) }
    }

}


extension PaintEngine {

    /// 同步导出：退出路径专用，会阻塞到 GPU 读回结束（上限 5 秒）。
    func 导出绘画快照同步() -> 绘画快照 {
        final class 盒子: @unchecked Sendable { var 值: 绘画快照? }
        let 盒 = 盒子()
        let 信号 = DispatchSemaphore(value: 0)
        导出绘画快照 { 快照 in
            盒.值 = 快照
            信号.signal()
        }
        _ = 信号.wait(timeout: .now() + 5)
        return 盒.值 ?? 绘画快照(revision: revision, 物体: [])
    }
}

/// 绘画导出节流。
///
/// 一次保存会顺带导出一次绘画，但每次导出都读回一次显存太浪费。
/// 这里攒 0.5 秒：这段时间里的连续改动只导出一次，退出时再同步补一刀。
/// 目标容器由调用方显式给出，绘画只会跟着那次保存写到同一个容器里。
@MainActor
final class 绘画导出节流 {
    static let shared = 绘画导出节流()

    private var 待执行: DispatchWorkItem?
    private init() {}

    func 请求(到 root: URL) {
        待执行?.cancel()
        let item = DispatchWorkItem {
            PaintEngine.shared.导出绘画快照 { 快照 in
                LocalStore.写绘画(快照, 到: root)
            }
        }
        待执行 = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    func 取消() {
        待执行?.cancel()
        待执行 = nil
    }
}
