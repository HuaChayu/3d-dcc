import Foundation
import simd

// MARK: - GPU 粒子结构（与 粒子 着色器.metal 逐字节一致）
//
// 口径：
// - 这里是**渲染器工作状态**，不是场景数据（见 数据层 架构规矩.md §2「不属于任何域的东西」）。
//   真值只有一个：SceneObject.特效（发型参数）+ 着色Store.物理域（全局力）。
//   本文件只是"把真值翻译成 GPU 认的排布"，不存第二份参数、不做第二套默认值。
// - 全部用 SIMD4 排布：SIMD4<Float> 16 字节对齐，48 字节/粒子，10 万粒子 = 4.8 MB 常驻，
//   单 buffer 原地更新（每粒子只读写自己那一份，无邻居交互，不需要 ping-pong）。

/// 一个粒子（48 字节）
struct 粒子GPU {
    /// xyz = 世界位置，w = 已活秒数
    var 位置_已活: SIMD4<Float> = .zero
    /// xyz = 速度，w = 总寿命（0 表示空闲槽）
    var 速度_总活: SIMD4<Float> = .zero
    /// x = 相位，y = 尺寸抖动，z = 湍流种子，w = 保留
    var 随机: SIMD4<Float> = .zero
}

/// 一个发射器一帧要交给 GPU 的全部参数（224 字节）
///
/// 顺序必须与 粒子 着色器.metal 里的 `struct 发射参数` 完全一致，改字段就两边一起改。
struct 粒子发射参数 {
    var 世界: simd_float4x4 = matrix_identity_float4x4

    var 初速: Float = 0
    var 速度随机: Float = 0
    var 扩散余弦: Float = 0
    var 寿命: Float = 1

    var 寿命随机: Float = 0
    var 起始尺寸: Float = 0.05
    var 终止尺寸: Float = 0.05
    var 不透明度: Float = 1

    var 起始颜色: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 1)
    var 终止颜色: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 1)

    var 重力倍率: Float = 1
    var 风力倍率: Float = 1
    var 湍流: Float = 0
    /// 0 = 粒子 / 1 = 火 / 2 = 烟 / 3 = 水（片元里决定透明度曲线与高光）
    var 种类: Float = 0

    /// xyz = 重力加速度，w = 空气阻力（0…1，每秒衰减比例）
    var 重力: SIMD4<Float> = .zero
    /// xyz = 恒定风，w = 全局湍流（打碎成小尺度扰动）
    var 风: SIMD4<Float> = .zero
    /// xyz = 流场，w = 时间（秒）
    var 流: SIMD4<Float> = .zero

    var 碰撞开关: Float = 0
    /// 碰撞用的粒子半径（取起始尺寸的一半，避免扎进地面）
    var 粒子半径: Float = 0.02
    /// 场景碰撞球数量（见 粒子碰撞球）
    var 球数: UInt32 = 0
    /// 池容量（= 这个发射器的最大粒子数）
    var 池容量: UInt32 = 0

    /// 本帧要发射几个（只发射 kernel 用）
    var 发射数: UInt32 = 0
    /// 帧序号（喂随机数，保证不同帧的随机流不重复）
    var 帧序号: UInt32 = 0
    var dt: Float = 0
    /// 保留位（16 字节对齐用）
    var 保留: Float = 0
}

// MARK: - 布局自检（Debug 里改了字段忘了同步就当场炸，不留隐患）

enum 粒子布局自检 {
    static func 运行() {
        assert(MemoryLayout<粒子GPU>.stride == 48, "粒子GPU 必须是 48 字节，实为 \(MemoryLayout<粒子GPU>.stride)")
        assert(MemoryLayout<粒子发射参数>.stride == 224, "粒子发射参数 必须是 224 字节，实为 \(MemoryLayout<粒子发射参数>.stride)")
    }
}

// MARK: - 主线程 → 渲染线程的只读快照

/// 一个发射器这一帧的样子：设置 + 世界矩阵
///
/// 世界矩阵只在主线程算（`变换接线.世界矩阵(of:)` 会写域，渲染线程不许碰数据层，
/// 见 数据层 架构规矩.md §4），渲染线程只拿这份算好的结果。
struct 粒子发射器快照: Equatable {
    var id: UUID
    /// 特效设置（值语义，渲染线程读它不需要锁域）
    var 设置: 特效设置
    /// 发射器世界矩阵（局部 +Y = 喷射方向）
    var 世界: simd_float4x4
    /// 对象局部包围球的顶部高度（沿本地 +Y）。体积火/烟的喷口抬到这儿 —— 从对象上冒，不是从中心冒
    var 对象顶部: Float = 0
    /// 对象局部包围球半径。体积域盒拿它兜下限，免得火比对象本体还小
    var 对象半径: Float = 0
    /// 宿主几何（对象本体的三角汤）。有它 = 火/烟/水沿这坨几何的表面长；
    /// 没有（网格还没进池）则退回老的"顶部圆盘喷口"
    var 几何: 对象几何数据?

    static func == (甲: 粒子发射器快照, 乙: 粒子发射器快照) -> Bool {
        甲.id == 乙.id && 甲.设置 == 乙.设置 && 甲.世界 == 乙.世界
            && 甲.对象顶部 == 乙.对象顶部 && 甲.对象半径 == 乙.对象半径
            && 甲.几何?.键 == 乙.几何?.键
    }
}

// MARK: - 特效设置 → GPU 参数

extension 特效设置 {
    /// 把一门特效翻译成一帧的 GPU 参数。
    /// 只做机械换算，不在这里补默认值、不做第二套口径 —— 缺省值一律来自 特效设置 本身。
    func 参数(物理域: 物理域,
            世界: simd_float4x4,
            dt: Float,
            池容量: UInt32,
            发射数: UInt32,
            帧序号: UInt32,
            球数: UInt32) -> 粒子发射参数 {
        var p = 粒子发射参数()
        p.世界 = 世界
        p.初速 = Float(初速)
        p.速度随机 = Float(max(0, min(1, 速度随机)))
        // 扩散角是半锥角（度），180 度 = 全向
        let 半角 = Float(max(0, min(180, 扩散角))) * .pi / 180
        p.扩散余弦 = cos(半角)
        p.寿命 = Float(max(0.02, 寿命))
        p.寿命随机 = 0
        p.起始尺寸 = Float(max(0.0005, 起始尺寸))
        p.终止尺寸 = Float(max(0.0005, 终止尺寸))
        p.不透明度 = Float(max(0, min(1, 不透明度)))
        p.起始颜色 = SIMD4<Float>(Float(起始颜色.x), Float(起始颜色.y), Float(起始颜色.z), 1)
        p.终止颜色 = SIMD4<Float>(Float(终止颜色.x), Float(终止颜色.y), Float(终止颜色.z), 1)
        p.重力倍率 = Float(重力倍率)
        p.风力倍率 = Float(风力倍率)
        p.湍流 = Float(max(0, 湍流))
        p.种类 = Float(Self.种类码(种类))
        p.重力 = SIMD4<Float>(Float(物理域.重力.x), Float(物理域.重力.y), Float(物理域.重力.z),
                            Float(max(0, min(1, 物理域.阻力))))
        p.风 = SIMD4<Float>(Float(物理域.风.x), Float(物理域.风.y), Float(物理域.风.z),
                          Float(max(0, 物理域.湍流)))
        // 火 / 烟 自带一点上升气流，否则不拖「流」的时候只会往下掉，不像火
        var 流 = SIMD3<Float>(Float(物理域.流.x), Float(物理域.流.y), Float(物理域.流.z))
        if 种类 == .火 { 流.y += 1.2 }
        if 种类 == .烟 { 流.y += 0.5 }
        p.流 = SIMD4<Float>(流.x, 流.y, 流.z, 0)
        p.碰撞开关 = 碰撞 ? 1 : 0
        p.粒子半径 = Float(max(0.001, min(起始尺寸, 终止尺寸) * 0.5))
        p.球数 = 球数
        p.池容量 = 池容量
        p.发射数 = min(发射数, 池容量)
        p.帧序号 = 帧序号
        p.dt = dt
        return p
    }

    /// 片元着色器用的种类码（与 metal 里 0/1/2/3 对齐）
    static func 种类码(_ 种类: 特效种类) -> Int {
        switch 种类 {
        case .粒子: return 0
        case .火: return 1
        case .烟: return 2
        case .水: return 3
        }
    }

    /// 池容量上限：参数面板可以填很大的数，这里夹一道，防手滑填 1000 万把显存吃掉
    var 池容量上限: Int { max(256, min(200_000, 最大粒子数)) }
}


// MARK: - 体积特效（火 / 烟）
//
// 【为什么单独一套参数】火和烟不走粒子池：没有"粒子"这层实体，只有连续密度场。
// 视口拿到发射器后，直接按 PT 出图的那套介质公式 raymarch 一次成像。
// 下面两个结构必须与 metal 里的 VolumeFXParams / VolumeFXCam 逐字节一致（都是 144 字节）。

struct 体积发射参数 {
    var 世界: simd_float4x4 = matrix_identity_float4x4
    var 出生: SIMD4<Float> = SIMD4<Float>(1, 0.6, 0.2, 1)      // rgb 出生色, w 不透明度
    var 终止: SIMD4<Float> = SIMD4<Float>(0.4, 0.05, 0, 1)     // rgb 终止色, w 重力倍率
    var 轴锥: SIMD4<Float> = SIMD4<Float>(2, 1, 0.1, 0.97)     // x 初速, y 寿命, z 起始半径, w cosCone
    var 发射: SIMD4<Float> = SIMD4<Float>(1, 0.5, 0, 0)        // x 种类, y 湍流, z 时间, w 保留
    /// 火焰外观（见 metal 侧 volFireCoreK / TailK / Gain / Structure）：
    /// x 芯色温 K, y 尾色温 K, z 内部结构 0…1, w 亮度倍率。
    /// 位置一直是保留字段，征用它不会挪动任何字段偏移（结构必须与 metal 逐字节一致）。
    var 包围: SIMD4<Float> = SIMD4<Float>(3400, 760, 0.6, 1)
    /// x 半宽(米) y 高(米) z 网格边长 w 体素边长 —— 与 体积 场.swift 的域盒同源，
    /// 渲染必须和模拟用同一个盒子，否则采样位置全错（这是旧解析场时代最隐蔽的坑）
    var 域盒: SIMD4<Float> = SIMD4<Float>(0.5, 1, 64, 0.02)
    /// x 消光 y 发光 z 自阴影 w 保留
    var 配色: SIMD4<Float> = SIMD4<Float>(6, 1, 1, 0)
}

struct 体积相机参数 {
    var 眼: SIMD4<Float> = SIMD4<Float>(0, 0, 0, 0)
    var 右: SIMD4<Float> = SIMD4<Float>(1, 0, 0, 0)
    var 上: SIMD4<Float> = SIMD4<Float>(0, 1, 0, 0)
    var 前: SIMD4<Float> = SIMD4<Float>(0, 0, -1, 0)
    /// x tanHalfFov, y aspect, z 步数, w 曝光
    var 平面: SIMD4<Float> = SIMD4<Float>(0.35, 1.5, 64, 0.55)
    var 视图投影: simd_float4x4 = matrix_identity_float4x4
}

extension 特效设置 {
    /// 火 / 烟走体积管线；粒子 / 水仍走粒子池（水的液体表面是独立管线，后面再做）
    var 走体积: Bool { 种类 == .火 || 种类 == .烟 }

    func 体积参数(世界: simd_float4x4, 时间: Float, 网格边长: Int = 体积网格.高,
              对象半径: Float = 0) -> 体积发射参数 {
        var p = 体积发射参数()
        p.世界 = 世界
        let 盒 = 体积域盒(对象半径: 对象半径)
        p.域盒 = SIMD4<Float>(盒.半宽, 盒.高, Float(网格边长), 盒.高 / Float(max(网格边长, 1)))
        // 消光：不透明度小 = 更透。火要厚才压得住背景，烟必须薄才有层次。
        let 消光 = Float(1.2 + 7.0 * min(max(不透明度, 0), 1)) * (种类 == .火 ? 1.0 : 0.7)
        p.配色 = SIMD4<Float>(消光, 种类 == .火 ? 1.0 : 0.35, 1.0, 0)
        p.出生 = SIMD4<Float>(Float(起始颜色.x), Float(起始颜色.y), Float(起始颜色.z),
                             Float(min(max(不透明度, 0), 1)))
        p.终止 = SIMD4<Float>(Float(终止颜色.x), Float(终止颜色.y), Float(终止颜色.z),
                             Float(min(max(重力倍率, 0), 4)))
        let 半角 = Float(min(max(扩散角, 0), 179)) * .pi / 180
        p.轴锥 = SIMD4<Float>(Float(max(初速, 0.02)),
                             Float(max(寿命, 0.02)),
                             Float(max(起始尺寸, 0.0005)),
                             cos(半角))
        p.发射 = SIMD4<Float>(Float(Self.种类码(种类)),
                             Float(min(max(湍流, 0), 1)),
                             时间, 0)
        // 火焰外观：只对火有意义，烟也照传（着色器只在 是火 时读）
        p.包围 = SIMD4<Float>(Float(max(火焰芯色温 ?? 3400, 600)),
                             Float(max(火焰尾色温 ?? 760, 400)),
                             Float(min(max(火焰结构 ?? 0.6, 0), 1)),
                             Float(max(火焰亮度 ?? 1, 0.02)))
        return p
    }
}
