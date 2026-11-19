import Foundation

// MARK: - 视口设置

enum ViewportShading: String, Codable, CaseIterable, Identifiable, Sendable {
    case material
    case solid
    case wireframe
    case normal
    /// 硬件光追路径追踪（自研 Metal 内核，见 ui/着色/路径追踪渲染器）
    case pathTraced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .material: "材质预览"
        case .solid: "纯色"
        case .wireframe: "线框"
        case .normal: "法线"
        case .pathTraced: "路径追踪"
        }
    }

    var symbol: String {
        switch self {
        case .material: "circle.lefthalf.filled"
        case .solid: "square.fill"
        case .wireframe: "grid"
        case .normal: "arrow.up.right"
        case .pathTraced: "sparkles"
        }
    }
}

enum StudioEnvironment: String, Codable, CaseIterable, Identifiable, Sendable {
    case studio
    case sunset
    case overcast
    case nightLab

    var id: String { rawValue }

    var title: String {
        switch self {
        case .studio: "摄影棚"
        case .sunset: "日落"
        case .overcast: "阴天"
        case .nightLab: "暗房"
        }
    }

    /// 环境板顶/底颜色，程序化生成 equirect（不依赖外部 HDRI 文件）
    var skyTop: PBRColor {
        switch self {
        case .studio: PBRColor(0.30, 0.31, 0.34)
        case .sunset: PBRColor(0.55, 0.32, 0.20)
        case .overcast: PBRColor(0.62, 0.65, 0.70)
        case .nightLab: PBRColor(0.05, 0.06, 0.09)
        }
    }

    var skyBottom: PBRColor {
        switch self {
        case .studio: PBRColor(0.06, 0.06, 0.07)
        case .sunset: PBRColor(0.10, 0.07, 0.09)
        case .overcast: PBRColor(0.35, 0.37, 0.40)
        case .nightLab: PBRColor(0.01, 0.01, 0.02)
        }
    }

    /// 主光方向（方位角/仰角，度）
    var keyLight: (azimuth: Double, elevation: Double, intensity: Double) {
        switch self {
        case .studio: (35, 42, 1100)
        case .sunset: (150, 8, 1500)
        case .overcast: (60, 65, 700)
        case .nightLab: (-40, 55, 500)
        }
    }
}

struct ViewportSettings: Codable, Equatable {
    var shading: ViewportShading = .pathTraced
    var environment: StudioEnvironment = .studio
    var environmentIntensity: Double = 1.0
    var environmentRotation: Double = 0
    var fieldOfView: Double = 38
    var showsGrid: Bool = true
    var showsGround: Bool = true
    var autoRotate: Bool = false
    var exposure: Double = 0

    // MARK: 路径追踪参数（仅 .pathTraced 生效）

    // 降噪（OIDN 神经网络）没有开关：进路径追踪就常开，原工具栏上的开关已移除，
    // 相关参数统一收拢到「路径追踪」旁的下拉菜单里。

    /// 每帧累积样本数（1...8，越大收敛越快、掉帧越明显）
    var ptSamplesPerFrame: Int = 8
    /// 累积上限，到顶后停止累积（画面定住）
    var ptMaxSamples: Int = 48
    /// 光线弹射次数
    var ptMaxBounces: Int = 4
    /// 介质湍流的「时间」（秒）：驱动体积羽流的噪声相位，只改形状不改任何光照量。
    /// 不是墙钟时间 —— PT 是累积渲染器，时间随墙钟走就永远收敛不了。
    var ptVolumeTime: Double = 0
    /// 介质动画：开着会让 PT 每收敛一轮就推进介质时间并重开累积 —— 等于永远停在低 spp，
    /// 画面持续跳噪点（观感就是"没烘焙没播时间轴，火自己在闪"）。默认关，要用再手动开。
    var ptVolumeAnimate: Bool = false
    /// 介质湍流强度倍率：0 = 关（退回纯锥形羽流），1 = 默认翻滚
    var ptVolumeTurbulence: Double = 1
    /// 内部渲染分辨率比例（1.0 = 原生，越低越流畅）
    var ptResolutionScale: Double = 1.0
    /// 渲染纹理尺寸（材质图集档位，像素）：路径追踪视口与离屏出图共用这一档。
    /// 只决定图集边长上限与派生材质烘焙档，与「内部分辨率」是两个独立维度。
    var ptTextureTier: Int = 1024
    /// 萤火虫压制：单像素亮度不得超过邻域参考亮度的倍数（0 = 关闭压制）
    var ptLuminosityCeiling: Double = 24
    /// 派生贴图缓存上限（MB，默认 256）。
    /// 派生图（烘焙图集、缩略图、程序贴图）按「引用计数 + 字节上限」淘汰：
    /// 有引用的一张不扔，零引用且不在飞帧的先扔，仍超上限才按最久未用继续扔。
    /// 调大命中率高、占内存多；调小省内存、频繁重烘。下限 64MB，见 `材质接线`/`视口纹理库` 的入参钳制。
    var ptDerivedCacheMB: Int = 256

    // MARK: 眩光辉光（Blender Glare 式屏幕空间后处理）
    // 只认 HDR 亮度：节点里把自发光拉起来、拿绘画的 emission 通道画一笔，都走同一条辉光链，
    // 不需要在材质里各写一套。表面发光，光晕则溢到模型轮廓之外。

    /// 辉光总开关
    var ptGlowEnabled: Bool = true
    /// 眩光叠加强度（0 = 看不见）
    var ptGlowStrength: Double = 0.35
    /// 起辉亮度阈值：曝光后的线性 HDR，1.0 ≈ 白点，越低越多东西发光
    var ptGlowThreshold: Double = 1.0
    /// 半径（1…6 级）：层数越多光晕铺得越远、越柔
    var ptGlowRadius: Double = 4
    /// 屏蔽自身（0…1）：0 = 普通叠加（模型表面自己也跟着被辉光提亮）；
    /// 1 = 只留「超出自身亮度」的那部分溢出，表面保持原来的自发光效果，光晕只在轮廓外出现
    var ptGlowSelfMask: Double = 0

    static var `default`: ViewportSettings { ViewportSettings() }

    // 宽松解码：老快照里没有降噪字段时绝不能整份丢弃（LocalStore 用 try? 解码，
    // 一旦抛错整个工程会当作"无快照"处理），所以每个字段都走 decodeIfPresent 兜底。
    init() {}

    enum CodingKeys: String, CodingKey {
        case shading, environment, environmentIntensity, environmentRotation
        case fieldOfView, showsGrid, showsGround, autoRotate, exposure
        case ptSamplesPerFrame, ptMaxSamples, ptMaxBounces, ptResolutionScale, ptTextureTier, ptLuminosityCeiling
        case ptVolumeTime, ptVolumeTurbulence, ptVolumeAnimate
        case ptDerivedCacheMB
        case ptGlowEnabled, ptGlowStrength, ptGlowThreshold, ptGlowRadius, ptGlowSelfMask
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = ViewportSettings()
        shading = (try? c.decodeIfPresent(ViewportShading.self, forKey: .shading)) ?? fallback.shading
        environment = (try? c.decodeIfPresent(StudioEnvironment.self, forKey: .environment)) ?? fallback.environment
        environmentIntensity = (try? c.decodeIfPresent(Double.self, forKey: .environmentIntensity)) ?? fallback.environmentIntensity
        environmentRotation = (try? c.decodeIfPresent(Double.self, forKey: .environmentRotation)) ?? fallback.environmentRotation
        fieldOfView = (try? c.decodeIfPresent(Double.self, forKey: .fieldOfView)) ?? fallback.fieldOfView
        showsGrid = (try? c.decodeIfPresent(Bool.self, forKey: .showsGrid)) ?? fallback.showsGrid
        showsGround = (try? c.decodeIfPresent(Bool.self, forKey: .showsGround)) ?? fallback.showsGround
        autoRotate = (try? c.decodeIfPresent(Bool.self, forKey: .autoRotate)) ?? fallback.autoRotate
        exposure = (try? c.decodeIfPresent(Double.self, forKey: .exposure)) ?? fallback.exposure
        ptSamplesPerFrame = (try? c.decodeIfPresent(Int.self, forKey: .ptSamplesPerFrame)) ?? fallback.ptSamplesPerFrame
        ptMaxSamples = (try? c.decodeIfPresent(Int.self, forKey: .ptMaxSamples)) ?? fallback.ptMaxSamples
        ptMaxBounces = (try? c.decodeIfPresent(Int.self, forKey: .ptMaxBounces)) ?? fallback.ptMaxBounces
        ptVolumeTime = (try? c.decodeIfPresent(Double.self, forKey: .ptVolumeTime)) ?? fallback.ptVolumeTime
        ptVolumeTurbulence = (try? c.decodeIfPresent(Double.self, forKey: .ptVolumeTurbulence)) ?? fallback.ptVolumeTurbulence
        ptVolumeAnimate = (try? c.decodeIfPresent(Bool.self, forKey: .ptVolumeAnimate)) ?? fallback.ptVolumeAnimate
        ptResolutionScale = (try? c.decodeIfPresent(Double.self, forKey: .ptResolutionScale)) ?? fallback.ptResolutionScale
        ptTextureTier = (try? c.decodeIfPresent(Int.self, forKey: .ptTextureTier)) ?? fallback.ptTextureTier
        ptLuminosityCeiling = (try? c.decodeIfPresent(Double.self, forKey: .ptLuminosityCeiling)) ?? fallback.ptLuminosityCeiling
        ptDerivedCacheMB = (try? c.decodeIfPresent(Int.self, forKey: .ptDerivedCacheMB)) ?? fallback.ptDerivedCacheMB
        ptGlowEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .ptGlowEnabled)) ?? fallback.ptGlowEnabled
        ptGlowStrength = (try? c.decodeIfPresent(Double.self, forKey: .ptGlowStrength)) ?? fallback.ptGlowStrength
        ptGlowThreshold = (try? c.decodeIfPresent(Double.self, forKey: .ptGlowThreshold)) ?? fallback.ptGlowThreshold
        ptGlowRadius = (try? c.decodeIfPresent(Double.self, forKey: .ptGlowRadius)) ?? fallback.ptGlowRadius
        ptGlowSelfMask = (try? c.decodeIfPresent(Double.self, forKey: .ptGlowSelfMask)) ?? fallback.ptGlowSelfMask
    }
}
