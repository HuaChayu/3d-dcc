import CoreGraphics
import Foundation
import simd

// MARK: - 变换模式（快捷键 W / E / R）

/// 视口坐标轴手柄的三种工作模式，全部中文标签，快捷键沿用 DCC 惯例 W / E / R。
enum 变换模式: String, CaseIterable, Identifiable, Sendable {
    case 移动
    case 旋转
    case 缩放

    var id: String { rawValue }
    var title: String { rawValue }

    var shortcut: String {
        switch self {
        case .移动: "W"
        case .旋转: "E"
        case .缩放: "R"
        }
    }

    var symbol: String {
        switch self {
        case .移动: "move.3d"
        case .旋转: "rotate.3d"
        case .缩放: "scale.3d"
        }
    }

    /// 键盘字符 → 模式（只认 W / E / R，大小写不敏感）
    static func from(shortcut key: String) -> 变换模式? {
        switch key.lowercased() {
        case "w": .移动
        case "e": .旋转
        case "r": .缩放
        default: nil
        }
    }
}

// MARK: - 坐标空间（全局 / 局部）

/// 手柄按哪套轴摆放：全局用世界轴（永远是 Y 向上），局部用物体自身旋转后的轴。
/// 物体被胡乱旋转过之后，只有局部轴才能直接对应它「自己的」上、前、右。
enum 坐标空间: String, CaseIterable, Identifiable, Sendable {
    case 全局
    case 局部

    var id: String { rawValue }
    var title: String { rawValue }

    var symbol: String {
        switch self {
        case .全局: "globe"
        case .局部: "cube"
        }
    }

    var help: String {
        switch self {
        case .全局: "全局轴：手柄永远对齐世界 X / Y / Z"
        case .局部: "局部轴：手柄跟随物体自身旋转"
        }
    }
}

// MARK: - 标准轴向视图

/// 右上角轴向控件可点到的六个方向。名称按 DCC 惯例：前/后/左/右/顶/底。
enum 视口轴向: String, CaseIterable, Identifiable, Sendable {
    case 前视
    case 后视
    case 左视
    case 右视
    case 顶视
    case 底视

    var id: String { rawValue }
    var title: String { rawValue }

    /// 顶/底视留一点点余量：视线与世界上方向完全平行时相机朝向求解会退化
    static let 顶底余量: Double = 0.012

    /// 仰角上限（orbit 与轴向对齐共用同一套边界）
    static var 仰角上限: Double { .pi / 2 - 顶底余量 }

    var 方位角: Double {
        switch self {
        case .后视: .pi
        case .右视: .pi / 2
        case .左视: -.pi / 2
        default: 0
        }
    }

    var 仰角: Double {
        switch self {
        case .顶视: 视口轴向.仰角上限
        case .底视: -视口轴向.仰角上限
        default: 0
        }
    }

    /// 相机相对目标点的位置方向（单位向量）
    var 方向: SIMD3<Float> {
        switch self {
        case .前视: [0, 0, 1]
        case .后视: [0, 0, -1]
        case .右视: [1, 0, 0]
        case .左视: [-1, 0, 0]
        case .顶视: [0, 1, 0]
        case .底视: [0, -1, 0]
        }
    }

    /// 正轴端点标字母，负轴端点只画小圆点，避免控件里一堆 "-X / -Y / -Z"
    var 正轴标签: String? {
        switch self {
        case .前视: "Z"
        case .右视: "X"
        case .顶视: "Y"
        default: nil
        }
    }
}

// MARK: - 手柄轴

enum 手柄轴: String, CaseIterable, Identifiable, Sendable {
    case x
    case y
    case z

    var id: String { rawValue }
    var 标题: String { rawValue.uppercased() }

    var 世界方向: SIMD3<Float> {
        switch self {
        case .x: [1, 0, 0]
        case .y: [0, 1, 0]
        case .z: [0, 0, 1]
        }
    }

    var 分量下标: Int {
        switch self {
        case .x: 0
        case .y: 1
        case .z: 2
        }
    }

    /// 沿用 DCC 惯例：X 红、Y 绿、Z 蓝
    var 色: (r: Double, g: Double, b: Double) {
        switch self {
        case .x: (0.94, 0.34, 0.36)
        case .y: (0.44, 0.82, 0.40)
        case .z: (0.34, 0.58, 0.98)
        }
    }
}

/// 手柄按轴取值：位置 / 旋转 / 缩放共用一套下标读写
extension Vec3 {
    subscript(axis: Int) -> Double {
        get {
            switch axis {
            case 0: x
            case 1: y
            default: z
            }
        }
        set {
            switch axis {
            case 0: x = newValue
            case 1: y = newValue
            default: z = newValue
            }
        }
    }
}

// MARK: - 相机快照

/// 与 ViewportScene 里那台轨道相机同一套参数。
/// 2D 覆盖层（轴向控件、对象坐标轴）全靠它做投影，屏幕落点才能和模型严丝合缝。
struct 视口相机: Equatable {
    var 方位角: Double
    var 仰角: Double
    var 距离: Double
    var 目标点: SIMD3<Float>
    var 视场角: Double

    init(
        方位角: Double = 0,
        仰角: Double = 0.17,
        距离: Double = 6.49,
        目标点: SIMD3<Float> = [0, 1.0, 0],
        视场角: Double = 38
    ) {
        self.方位角 = 方位角
        self.仰角 = 仰角
        self.距离 = 距离
        self.目标点 = 目标点
        self.视场角 = 视场角
    }

    /// 相机世界位置（与 ViewportScene.applyOrbitCamera 完全同式）
    var 位置: SIMD3<Float> {
        let el = Float(仰角), az = Float(方位角), d = Float(距离)
        let horizontal = d * cos(el)
        return 目标点 + SIMD3<Float>(
            horizontal * sin(az),
            d * sin(el),
            horizontal * cos(az)
        )
    }

    var 前向: SIMD3<Float> {
        let el = Float(仰角), az = Float(方位角)
        return normalize(-SIMD3<Float>(cos(el) * sin(az), sin(el), cos(el) * cos(az)))
    }

    var 右向: SIMD3<Float> {
        var r = cross(前向, SIMD3<Float>(0, 1, 0))
        if length(r) < 0.0001 { r = SIMD3<Float>(1, 0, 0) }
        return normalize(r)
    }

    var 上向: SIMD3<Float> { normalize(cross(右向, 前向)) }

    /// 世界点 → 屏幕点（左上原点）；落在相机背后返回 nil
    func 投影(_ world: SIMD3<Float>, 视图尺寸 size: CGSize) -> CGPoint? {
        guard size.width > 1, size.height > 1 else { return nil }
        let v = world - 位置
        let depth = dot(v, 前向)
        guard depth > 0.02 else { return nil }
        let tanHalf = tan(Float(视场角) * .pi / 360)
        let aspect = Float(size.width / size.height)
        let ndcX = dot(v, 右向) / (depth * tanHalf * aspect)
        let ndcY = dot(v, 上向) / (depth * tanHalf)
        return CGPoint(
            x: CGFloat((ndcX + 1) * 0.5) * size.width,
            y: CGFloat((1 - ndcY) * 0.5) * size.height
        )
    }

    /// 屏幕点（左上原点）→ 世界射线。与 投影 严格互逆，绘画拾取靠它把鼠标换成射线。
    func 射线(屏幕点 point: CGPoint, 视图尺寸 size: CGSize) -> (origin: SIMD3<Float>, direction: SIMD3<Float>)? {
        guard size.width > 1, size.height > 1 else { return nil }
        let tanHalf = tan(Float(视场角) * .pi / 360)
        let aspect = Float(size.width / size.height)
        let ndcX = Float(point.x / size.width) * 2 - 1
        let ndcY = 1 - Float(point.y / size.height) * 2
        let dir = 前向 + 右向 * (ndcX * tanHalf * aspect) + 上向 * (ndcY * tanHalf)
        return (位置, normalize(dir))
    }

    /// 该深度处「一个世界单位 == 多少像素」，用来把 gizmo 的屏幕尺寸换成世界半径
    func 每像素世界长度(at world: SIMD3<Float>, 视图尺寸 size: CGSize) -> Float {
        let depth = max(dot(world - 位置, 前向), 0.05)
        let tanHalf = tan(Float(视场角) * .pi / 360)
        return 2 * depth * tanHalf / Float(max(size.height, 1))
    }

    /// 生成物体坐标轴手柄几何：屏幕半径固定，世界半径反算，所以远近都能看清
    /// - Parameter 旋转: 坐标空间。传单位四元数即全局轴，传物体自身旋转即局部轴。
    func 手柄(
        中心 worldCenter: SIMD3<Float>,
        视图尺寸 size: CGSize,
        半径像素 radiusPx: CGFloat,
        旋转 空间旋转: simd_quatf = simd_quatf(angle: 0, axis: [0, 1, 0])
    ) -> [手柄轴几何] {
        guard let center = 投影(worldCenter, 视图尺寸: size) else { return [] }
        let worldPerPixel = 每像素世界长度(at: worldCenter, 视图尺寸: size)
        let r = Float(radiusPx) * worldPerPixel

        return 手柄轴.allCases.compactMap { axis -> 手柄轴几何? in
            let dir = 空间旋转.act(axis.世界方向)
            guard let 正 = 投影(worldCenter + dir * r, 视图尺寸: size),
                  let 负 = 投影(worldCenter - dir * r, 视图尺寸: size)
            else { return nil }

            let dx = 正.x - center.x
            let dy = 正.y - center.y
            let px = hypot(dx, dy)
            let unit = px > 0.001
                ? CGVector(dx: dx / px, dy: dy / px)
                : CGVector(dx: 0, dy: -1)

            // 旋转模式的圆环：绕该轴、半径 r 的圆周采样后逐个投影
            let (u, v) = 视口相机.正交基(dir)
            var ring: [CGPoint] = []
            ring.reserveCapacity(49)
            for i in 0...48 {
                let a = Float(i) / 48 * 2 * .pi
                let p = worldCenter + (u * cos(a) + v * sin(a)) * r
                if let s = 投影(p, 视图尺寸: size) { ring.append(s) }
            }

            return 手柄轴几何(
                轴: axis,
                中心: center,
                正端点: 正,
                负端点: 负,
                屏幕方向: unit,
                世界方向: dir,
                像素半径: px,
                世界半径: r,
                朝向相机: dot(dir, 前向),
                环绕路径: ring
            )
        }
    }

    /// 三轴交汇处的中心球：移动模式按住它沿相机平面（屏幕平面）拖，
    /// 缩放模式按住它整体等比缩放。旋转模式不提供——旋转空间里中心是空的。
    func 中心球(
        中心 worldCenter: SIMD3<Float>,
        视图尺寸 size: CGSize,
        半径像素 radiusPx: CGFloat = 10
    ) -> 手柄中心球? {
        guard let center = 投影(worldCenter, 视图尺寸: size) else { return nil }
        return 手柄中心球(
            中心: center,
            像素半径: radiusPx,
            // 屏幕像素 → 世界单位：球所在深度处每像素多少世界长度
            每像素世界长度: 每像素世界长度(at: worldCenter, 视图尺寸: size),
            右向: 右向,
            上向: 上向
        )
    }

    static func 正交基(_ d: SIMD3<Float>) -> (SIMD3<Float>, SIMD3<Float>) {
        let helper: SIMD3<Float> = abs(d.y) < 0.9 ? [0, 1, 0] : [1, 0, 0]
        let u = normalize(cross(helper, d))
        let v = normalize(cross(d, u))
        return (u, v)
    }

    // MARK: 命中

    static func 命中(
        _ 几何: [手柄轴几何],
        模式: 变换模式,
        点 p: CGPoint,
        容差: CGFloat = 9
    ) -> 手柄轴几何? {
        var best: (手柄轴几何, CGFloat)?
        for g in 几何 {
            let d: CGFloat
            switch 模式 {
            case .移动, .缩放:
                // 轴几乎正对相机时屏幕长度塌成一点，这种轴不参与命中
                guard g.可用 else { continue }
                d = 点到线段距离(p, g.中心, g.正端点)
            case .旋转:
                guard g.环绕路径.count > 2 else { continue }
                d = 点到折线距离(p, g.环绕路径)
            }
            guard d <= 容差 else { continue }
            if best == nil || d < best!.1 { best = (g, d) }
        }
        return best?.0
    }

    static func 点到线段距离(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let abx = b.x - a.x
        let aby = b.y - a.y
        let len2 = abx * abx + aby * aby
        guard len2 > 0.0001 else { return hypot(p.x - a.x, p.y - a.y) }
        var t = ((p.x - a.x) * abx + (p.y - a.y) * aby) / len2
        t = min(max(t, 0), 1)
        return hypot(p.x - (a.x + abx * t), p.y - (a.y + aby * t))
    }

    static func 点到折线距离(_ p: CGPoint, _ points: [CGPoint]) -> CGFloat {
        guard points.count > 1 else { return .greatestFiniteMagnitude }
        var best = CGFloat.greatestFiniteMagnitude
        for i in 0..<(points.count - 1) {
            best = min(best, 点到线段距离(p, points[i], points[i + 1]))
        }
        return best
    }
}

// MARK: - 手柄几何

/// 一根轴在屏幕上的落点。移动/缩放用它当线段，旋转用它的环绕路径当圆环。
struct 手柄轴几何: Identifiable {
    var 轴: 手柄轴
    var 中心: CGPoint
    var 正端点: CGPoint
    var 负端点: CGPoint
    var 屏幕方向: CGVector
    /// 轴在世界空间的单位方向（全局轴就是 x/y/z；局部轴已按物体旋转摆好）
    var 世界方向: SIMD3<Float>
    /// 屏幕上的像素长度（透视缩短后的真实长度）
    var 像素半径: CGFloat
    /// 与像素长度对应的世界半径，拖动时用它把像素换算成世界单位
    var 世界半径: Float
    /// > 0 表示这根轴指向相机（用于旋转方向的视觉翻转）
    var 朝向相机: Float
    var 环绕路径: [CGPoint]

    var id: String { 轴.rawValue }

    var 可用: Bool { 像素半径 > 16 }
}

/// 三轴交汇处的中心球。移动模式 = 相机平面内平移（不沿任何一根轴），
/// 缩放模式 = 三轴等比。
struct 手柄中心球 {
    /// 球心的屏幕坐标
    var 中心: CGPoint
    /// 屏幕上的像素半径（与轴手柄同一套「屏幕尺寸固定」逻辑）
    var 像素半径: CGFloat
    /// 该深度处一个世界单位对应多少像素
    var 每像素世界长度: Float
    /// 相机右向 / 上向（世界空间）：像素位移沿它们落到世界
    var 右向: SIMD3<Float>
    var 上向: SIMD3<Float>

    /// 命中容差：球本身半径 + 一点点余量，保证比轴起点好点中
    func 命中(_ p: CGPoint, 放大: CGFloat = 4) -> Bool {
        hypot(p.x - 中心.x, p.y - 中心.y) <= 像素半径 + 放大
    }
}

// MARK: - 手柄旋转换算

/// 欧拉角（度，固定 XYZ 顺序 qx·qy·qz）与四元数的互转。
/// 拖动旋转统一走四元数合成：直接写欧拉分量只在「其它轴还是 0」时才正确，
/// 物体一旦被转过别的轴，同一个分量就不再是同一根世界轴。
enum 手柄旋转 {
    /// 物体当前欧拉角 → 四元数（与 SceneBuilder.eulerQuaternion 同一约定）
    static func 四元数(_ euler: Vec3) -> simd_quatf {
        SceneBuilder.eulerQuaternion(x: euler.x, y: euler.y, z: euler.z)
    }

    /// 从 起始欧拉角 出发，绕给定世界轴转过 角度（度）后的新欧拉角。
    /// q' = Δq · q，等价于「绕物体当前朝向下那根轴转」：局部轴只需把轴先旋到世界。
    static func 绕轴(起始: Vec3, 世界轴: SIMD3<Float>, 角度: Double) -> Vec3 {
        let 长度 = length(世界轴)
        guard 长度 > 0.0001 else { return 起始 }
        let q0 = 四元数(起始)
        let dq = simd_quatf(angle: Float(角度 * .pi / 180), axis: 世界轴 / 长度)
        return 欧拉角(from: dq * q0)
    }

    /// 四元数 → 欧拉角（度）。R = Rx(a)·Ry(b)·Rz(c)，与 四元数(_:) 互逆。
    static func 欧拉角(from q: simd_quatf) -> Vec3 {
        let m = simd_float3x3(q)
        // simd 矩阵列主序：m[列][行]
        let r00 = Double(m[0][0]), r01 = Double(m[1][0]), r02 = Double(m[2][0])
        let r12 = Double(m[2][1]), r22 = Double(m[2][2])
        let b = asin(min(max(r02, -1), 1))
        let a: Double
        let c: Double
        if abs(r02) < 0.99999 {
            a = atan2(-r12, r22)
            c = atan2(-r01, r00)
        } else {
            // 万向锁：b = ±90°，a 与 c 退化成同一个自由度，全部交给 c
            a = 0
            c = atan2(Double(m[1][0]), Double(m[1][1]))
        }
        let 度 = 180 / Double.pi
        return Vec3(a * 度, b * 度, c * 度)
    }
}
