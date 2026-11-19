import Foundation
import RealityKit
import simd

/// 视口点选的精确拾取几何。
///
/// 原来用 `visualBounds` 的包围球做射线求交，球体/环面/立方体挨得近时包围球会互相覆盖
/// （屏幕上一个球的投影半径可以盖住旁边一整个物体），于是出现「鼠标在左边的环上、
/// 选中的却是右边的球」。这里按每个 MeshKind 的真实建模参数把网格在物体局部空间重建一遍，
/// 用射线-三角形求交取最近命中面，命中结果与画面所见一致。
enum 拾取几何 {

    // MARK: 对外入口

    /// 射线是否命中该对象；命中返回沿射线的世界距离，未命中返回 nil
    static func 命中(_ object: SceneObject, origin: SIMD3<Float>, direction: SIMD3<Float>) -> Float? {
        guard object.isVisible else { return nil }
        let 世界 = 世界矩阵(object)
        let 逆 = 世界.inverse
        guard 逆.columns.3.x.isFinite, 逆.columns.3.y.isFinite, 逆.columns.3.z.isFinite else { return nil }

        // 把射线搬到对象局部空间：局部空间里几何是单位参数体，求交不用管缩放/旋转
        let 起点 = (逆 * SIMD4<Float>(origin, 1)).xyz
        let 方向 = (逆 * SIMD4<Float>(direction, 0)).xyz
        guard simd_length_squared(方向) > 1e-12 else { return nil }

        // 导入物走网格库里的真实三角形；内置形体走参数化重建
        var 三角形: [SIMD3<Float>] = []
        if let 网格ID = 几何接线.共享.取值(键: object.id.uuidString)?.导入网格标识, 几何接线.共享.存在(网格ID) {
            // 导入网格动辄百万三角，展开成点列要几十毫秒；
            // 每点一下就重建一次，手感就是"点一下卡一下"。按网格 ID 缓存一份。
            三角形 = 导入三角形(网格ID)
        } else {
            三角形 = 三角网格(for: 几何接线.共享.程序形状(键: object.id.uuidString, 兜底: object.mesh))
        }
        guard !三角形.isEmpty else { return nil }
        var 最近: Float?
        var i = 0
        while i + 2 < 三角形.count {
            if let t = 求交(起点, 方向, 三角形[i], 三角形[i + 1], 三角形[i + 2]), t > 0 {
                let 世界命中点 = (世界 * SIMD4<Float>(起点 + 方向 * t, 1)).xyz
                let 距离 = simd_length(世界命中点 - origin)
                if 最近 == nil || 距离 < 最近! { 最近 = 距离 }
            }
            i += 3
        }
        return 最近
    }

    /// 对象的世界矩阵：**向变换域要**，不再自己 T·R·S 拼一遍（阶段2-第二步）。
    ///
    /// 以前这里自己拼 T·R·S，和 PT 的 pathTraceMatrix、视口直赋的 SCNNode transform 是
    /// 三份口径 —— 只要有一份公式走偏（欧拉顺序、零缩放处理），
    /// "点到的"和"看到的"就会分叉。现在唯一派生方是变换域，这里只剩一次薄转发。
    static func 世界矩阵(_ object: SceneObject) -> simd_float4x4 {
        变换接线.共享.世界矩阵(of: object)
    }

    // MARK: 导入网格三角缓存

    private static let 导入缓存锁 = NSLock()
    private static var 导入三角缓存: [UUID: [SIMD3<Float>]] = [:]

    private static func 导入三角形(_ 网格ID: UUID) -> [SIMD3<Float>] {
        导入缓存锁.lock()
        if let 命中 = 导入三角缓存[网格ID] {
            导入缓存锁.unlock()
            return 命中
        }
        导入缓存锁.unlock()

        let 三角形 = 几何接线.共享.三角点列(网格ID)

        导入缓存锁.lock()
        导入三角缓存[网格ID] = 三角形
        导入缓存锁.unlock()
        return 三角形
    }

    // MARK: 网格缓存

    private static let 锁 = NSLock()
    nonisolated(unsafe) private static var 缓存: [MeshKind: [SIMD3<Float>]] = [:]

    private static func 三角网格(for mesh: MeshKind) -> [SIMD3<Float>] {
        锁.lock()
        if let 已有 = 缓存[mesh] { 锁.unlock(); return 已有 }
        锁.unlock()

        let 生成结果 = 生成(mesh)
        锁.lock()
        缓存[mesh] = 生成结果
        锁.unlock()
        return 生成结果
    }

    // MARK: 各 MeshKind 的局部网格（参数与 SceneBuilder.makeEntity 一一对应）

    private static func 生成(_ mesh: MeshKind) -> [SIMD3<Float>] {
        switch mesh {
        case .sphere:
            return 球(0.9)
        case .cube:
            // generateBox(size: 1.5, cornerRadius: 0.08)：圆角只有几厘米，按直角盒拾取足够
            return 盒(SIMD3<Float>(1.5, 1.5, 1.5))
        case .torus:
            return 环面(ring: 0.85, pipe: 0.3)
        case .cylinder:
            return 圆柱(高度: 1.8, 半径: 0.6)
        case .plane:
            return 平面(宽: 1, 深: 1)
        case .shaderBall:
            return 球(0.86, 中心: SIMD3<Float>(0, 0.98, 0))
                + 圆柱(高度: 0.16, 半径: 0.62, 中心: SIMD3<Float>(0, 0.08, 0))
                + 环面(ring: 0.46, pipe: 0.055, 段U: 48, 段V: 16, 中心: SIMD3<Float>(0, 0.17, 0))
                + 盒(SIMD3<Float>(1.35, 0.16, 1.35))
        }
    }

    private static func 球(_ 半径: Float, 中心: SIMD3<Float> = .zero, 纬: Int = 20, 经: Int = 28) -> [SIMD3<Float>] {
        var 三角形: [SIMD3<Float>] = []
        三角形.reserveCapacity(纬 * 经 * 6)
        for i in 0..<纬 {
            let v0 = Float(i) / Float(纬) * .pi
            let v1 = Float(i + 1) / Float(纬) * .pi
            for j in 0..<经 {
                let u0 = Float(j) / Float(经) * 2 * .pi
                let u1 = Float(j + 1) / Float(经) * 2 * .pi
                let a = 中心 + 半径 * SIMD3<Float>(sin(v0) * cos(u0), cos(v0), sin(v0) * sin(u0))
                let b = 中心 + 半径 * SIMD3<Float>(sin(v1) * cos(u0), cos(v1), sin(v1) * sin(u0))
                let c = 中心 + 半径 * SIMD3<Float>(sin(v1) * cos(u1), cos(v1), sin(v1) * sin(u1))
                let d = 中心 + 半径 * SIMD3<Float>(sin(v0) * cos(u1), cos(v0), sin(v0) * sin(u1))
                三角形.append(contentsOf: [a, b, c, a, c, d])
            }
        }
        return 三角形
    }

    /// 环面：环在 XZ 平面，与 SceneBuilder.makeTorusMesh 的参数化逐项一致
    private static func 环面(
        ring: Float, pipe: Float,
        段U: Int = 56, 段V: Int = 20,
        中心: SIMD3<Float> = .zero
    ) -> [SIMD3<Float>] {
        func 点(_ i: Int, _ j: Int) -> SIMD3<Float> {
            let u = Float(i) / Float(段U) * 2 * .pi
            let v = Float(j) / Float(段V) * 2 * .pi
            let cu = cos(u), su = sin(u), cv = cos(v), sv = sin(v)
            return 中心 + SIMD3<Float>(cu * (ring + pipe * cv), pipe * sv, su * (ring + pipe * cv))
        }
        var 三角形: [SIMD3<Float>] = []
        三角形.reserveCapacity(段U * 段V * 6)
        for i in 0..<段U {
            for j in 0..<段V {
                let a = 点(i, j), b = 点(i + 1, j), c = 点(i + 1, j + 1), d = 点(i, j + 1)
                三角形.append(contentsOf: [a, b, c, a, c, d])
            }
        }
        return 三角形
    }

    private static func 圆柱(
        高度: Float, 半径: Float,
        边: Int = 36,
        中心: SIMD3<Float> = .zero
    ) -> [SIMD3<Float>] {
        let 上 = 中心 + SIMD3<Float>(0, 高度 / 2, 0)
        let 下 = 中心 - SIMD3<Float>(0, 高度 / 2, 0)
        func 圈(_ y: Float, _ i: Int) -> SIMD3<Float> {
            let a = Float(i) / Float(边) * 2 * .pi
            return SIMD3<Float>(cos(a) * 半径, y, sin(a) * 半径)
        }
        var 三角形: [SIMD3<Float>] = []
        三角形.reserveCapacity(边 * 12)
        for i in 0..<边 {
            let a0 = 圈(高度 / 2, i) + 中心, a1 = 圈(高度 / 2, i + 1) + 中心
            let b0 = 圈(-高度 / 2, i) + 中心, b1 = 圈(-高度 / 2, i + 1) + 中心
            // 侧面
            三角形.append(contentsOf: [a0, b0, b1, a0, b1, a1])
            // 上下盖（扇形三角）
            三角形.append(contentsOf: [上, a0, a1])
            三角形.append(contentsOf: [下, b1, b0])
        }
        return 三角形
    }

    private static func 盒(_ 尺寸: SIMD3<Float>, 中心: SIMD3<Float> = .zero) -> [SIMD3<Float>] {
        let h = 尺寸 / 2
        let 顶点: [SIMD3<Float>] = [
            SIMD3(-h.x, -h.y, -h.z), SIMD3(h.x, -h.y, -h.z),
            SIMD3(h.x, h.y, -h.z), SIMD3(-h.x, h.y, -h.z),
            SIMD3(-h.x, -h.y, h.z), SIMD3(h.x, -h.y, h.z),
            SIMD3(h.x, h.y, h.z), SIMD3(-h.x, h.y, h.z),
        ].map { $0 + 中心 }
        let 面: [[Int]] = [
            [0, 1, 2, 0, 2, 3],  // -Z
            [4, 6, 5, 4, 7, 6],  // +Z
            [0, 4, 5, 0, 5, 1],  // -Y
            [3, 2, 6, 3, 6, 7],  // +Y
            [0, 3, 7, 0, 7, 4],  // -X
            [1, 5, 6, 1, 6, 2],  // +X
        ]
        var 三角形: [SIMD3<Float>] = []
        三角形.reserveCapacity(36)
        for 六点 in 面 {
            for 下标 in 六点 { 三角形.append(顶点[下标]) }
        }
        return 三角形
    }

    private static func 平面(宽: Float, 深: Float) -> [SIMD3<Float>] {
        let x = 宽 / 2, z = 深 / 2
        let a = SIMD3<Float>(-x, 0, -z), b = SIMD3<Float>(x, 0, -z)
        let c = SIMD3<Float>(x, 0, z), d = SIMD3<Float>(-x, 0, z)
        return [a, b, c, a, c, d]
    }

    // MARK: 射线-三角形求交（Möller–Trumbore）

    private static func 求交(
        _ origin: SIMD3<Float>, _ direction: SIMD3<Float>,
        _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>
    ) -> Float? {
        let e1 = b - a
        let e2 = c - a
        let p = simd_cross(direction, e2)
        let 行列式 = simd_dot(e1, p)
        guard abs(行列式) > 1e-9 else { return nil }
        let 逆 = 1 / 行列式
        let s = origin - a
        let u = simd_dot(s, p) * 逆
        guard u >= -1e-5, u <= 1 + 1e-5 else { return nil }
        let q = simd_cross(s, e1)
        let v = simd_dot(direction, q) * 逆
        guard v >= -1e-5, u + v <= 1 + 1e-5 else { return nil }
        return simd_dot(e2, q) * 逆
    }
}

private extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> { SIMD3<Float>(x, y, z) }
}
