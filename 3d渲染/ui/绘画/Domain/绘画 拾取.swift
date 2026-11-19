import Foundation
import simd

// MARK: - 命中结果

/// 笔刷落在物体表面的一个点。
/// 除了世界坐标和法线，还带局部坐标与三角形下标：
/// 后续采样要在物体局部空间里做（缩放不变形），而衰减权重必须按世界尺度算（笔刷半径是世界单位）。
struct PaintHit {
    var objectID: UUID
    var triangle: Int
    var localPoint: SIMD3<Float>
    var worldPoint: SIMD3<Float>
    var worldNormal: SIMD3<Float>
    var uv: SIMD2<Float>
    var localScale: SIMD3<Float>
}

/// 笔刷圆盘在表面上的落位。
///
/// 这里是最容易做错的一步：笔刷**不是**「屏幕上那个正圆」，而是**贴在切平面上的圆盘**。
/// 圈扫到朝左的面，圆盘跟着侧过去；扫到朝上的面，圆盘跟着仰起来 —— 所以屏幕上看到的圈
/// 永远是椭圆，图案也随面倾斜。屏幕上的旋转角（maskRot）只是「圆盘内的图案在切平面里
/// 转多少度」，不是「整个圆盘在屏幕上转」。
///
/// 基的取法（与 Blender `calc_brush_local_mat` 同构）：
/// - X = 屏幕角度方向投到切平面后归一化（角度方向 = cosθ·相机右向 − sinθ·相机上向，
///   屏幕 y 向下，所以 θ 增大就是视觉上的顺时针）
/// - Y = cross(X, normal)，落在切平面内，屏幕上大致朝下
/// - normal = 命中点表面法线（朝相机一侧）
struct PaintBrushFrame {
    var x: SIMD3<Float>
    var y: SIMD3<Float>
    var normal: SIMD3<Float>

    init(x: SIMD3<Float>, y: SIMD3<Float>, normal: SIMD3<Float>) {
        self.x = x
        self.y = y
        self.normal = normal
    }

    /// 表面法线 + 屏幕角度（度）→ 切平面基。
    init(normal n0: SIMD3<Float>, 屏幕角 angleDegrees: Float, 相机: 视口相机) {
        var n = simd_length(n0) > 1e-6 ? simd_normalize(n0) : -相机.前向
        // 法线背向相机时翻过来：不翻的话图案会镜像一次
        if simd_dot(n, 相机.前向) > 0 { n = -n }

        let 角 = angleDegrees * .pi / 180
        let m = 相机.右向 * cos(角) - 相机.上向 * sin(角)

        var 横 = m - n * simd_dot(m, n)
        if simd_length(横) < 1e-4 {
            // 视线几乎掠过切平面，角度方向在切平面上的投影塌成 0：退回相机右向
            横 = 相机.右向 - n * simd_dot(相机.右向, n)
        }
        if simd_length(横) < 1e-4 {
            横 = SIMD3<Float>(0, 1, 0) - n * n.y
        }
        if simd_length(横) < 1e-4 { 横 = SIMD3<Float>(1, 0, 0) }
        横 = simd_normalize(横)

        var 纵 = simd_cross(横, n)
        if simd_length(纵) < 1e-4 { 纵 = simd_cross(横, SIMD3<Float>(0, 1, 0)) }
        if simd_length(纵) < 1e-4 { 纵 = SIMD3<Float>(0, 1, 0) }
        纵 = simd_normalize(纵)

        self.x = 横
        self.y = 纵
        self.normal = n
    }
}

enum PaintPicker {

    // MARK: 拾取

    /// 从相机射线找最近的可绘画表面。
    /// 与选物拾取的区别：这里必须拿到三角形 + 重心坐标 + UV，才能把笔迹精确投到图集上。
    static func 拾取(origin: SIMD3<Float>,
                  direction: SIMD3<Float>,
                  objects: [SceneObject]) -> PaintHit? {
        var bestT = Float.greatestFiniteMagnitude
        var best: PaintHit?

        for object in objects where object.isVisible {
            let world = object.pathTraceMatrix
            let inv = world.inverse
            let lo4 = inv * SIMD4<Float>(origin, 1)
            let localOrigin = SIMD3<Float>(lo4.x, lo4.y, lo4.z)
            let ld4 = inv * SIMD4<Float>(direction, 0)
            let localDirRaw = SIMD3<Float>(ld4.x, ld4.y, ld4.z)
            let localDirLength = simd_length(localDirRaw)
            guard localDirLength > 1e-7 else { continue }
            let localDir = localDirRaw / localDirLength

            // 局部空间法线转世界要用逆转置矩阵，直接用世界矩阵会把非均匀缩放算歪
            let m3 = simd_float3x3(
                SIMD3<Float>(inv.columns.0.x, inv.columns.0.y, inv.columns.0.z),
                SIMD3<Float>(inv.columns.1.x, inv.columns.1.y, inv.columns.1.z),
                SIMD3<Float>(inv.columns.2.x, inv.columns.2.y, inv.columns.2.z)
            )
            let normalMatrix = m3.transpose

            let mesh = PaintUV.mesh(for: 几何接线.共享.程序形状(键: object.id.uuidString, 兜底: object.mesh))
            for t in 0..<mesh.triangleCount {
                let (a, b, c) = mesh.triangle(t)
                guard let bary = 求交(origin: localOrigin, direction: localDir, a: a, b: b, c: c) else { continue }
                // 世界射线参数：局部方向被归一化过，除回去才是世界 t
                let worldT = bary.t / localDirLength
                guard worldT < bestT else { continue }

                let lp = localOrigin + localDir * bary.t
                let wp = world * SIMD4<Float>(lp, 1)
                let ln = cross(b - a, c - a)
                let wn = normalMatrix * ln
                let (u0, u1, u2) = PaintUV.解缠(mesh.triangleUV(t).0, mesh.triangleUV(t).1, mesh.triangleUV(t).2)
                let uv = u0 * bary.b0 + u1 * bary.b1 + u2 * bary.b2

                bestT = worldT
                best = PaintHit(
                    objectID: object.id,
                    triangle: t,
                    localPoint: lp,
                    worldPoint: SIMD3<Float>(wp.x, wp.y, wp.z),
                    worldNormal: simd_length(wn) > 1e-9 ? simd_normalize(wn) : SIMD3<Float>(0, 1, 0),
                    uv: PaintUV.折回(uv),
                    localScale: SIMD3<Float>(Float(object.scale.x), Float(object.scale.y), Float(object.scale.z))
                )
            }
        }
        return best
    }

    // MARK: 主光线-三角形求交（Möller–Trumbore）

    private struct 重心命中 {
        var t: Float
        var b0: Float
        var b1: Float
        var b2: Float
    }

    private static func 求交(origin: SIMD3<Float>,
                          direction: SIMD3<Float>,
                          a: SIMD3<Float>,
                          b: SIMD3<Float>,
                          c: SIMD3<Float>) -> 重心命中? {
        let e1 = b - a
        let e2 = c - a
        let p = cross(direction, e2)
        let det = dot(e1, p)
        guard abs(det) > 1e-9 else { return nil }
        let invDet = 1 / det
        let tv = origin - a
        let u = dot(tv, p) * invDet
        guard u >= -0.0005, u <= 1.0005 else { return nil }
        let q = cross(tv, e1)
        let v = dot(direction, q) * invDet
        guard v >= -0.0005, u + v <= 1.0005 else { return nil }
        let t = dot(e2, q) * invDet
        guard t > 0.0001 else { return nil }
        return 重心命中(t: t, b0: 1 - u - v, b1: u, b2: v)
    }

    // MARK: 表面采样

    /// 在命中点周围沿物体表面撒点，每个点投影成 UV 空间的一个 splat。
    ///
    /// 为什么不直接在 UV 空间画个圆：UV 有接缝、有挤压（球两极、平面边缘），
    /// 在 UV 上画圆会在 3D 上变成一条被拉长的歪弧。反过来「3D 撒点 → 投 UV」，
    /// 每个 splat 的 UV 半径按该三角形的 UV/世界面积比单独算，接缝与挤压都能对齐。
    /// - Parameter 基: 笔刷圆盘的切平面基。整支笔刷只算一次（命中点法线 + 屏幕角），
    ///   每个三角形再用自己的 uv 雅可比把「切平面坐标」摊到 uv 上 —— 图案因此贴在表面上，
    ///   而不是躺在 uv 里被拉伸。
    static func 采样(object: SceneObject,
                    hit: PaintHit,
                    brush: PaintBrush,
                    基: PaintBrushFrame,
                    maxSplats: Int = 20000) -> [PaintSplat] {
        let mesh = PaintUV.mesh(for: 几何接线.共享.程序形状(键: object.id.uuidString, 兜底: object.mesh))
        let world = object.pathTraceMatrix
        let inv = world.inverse

        let radius = max(brush.radius, 1e-4)
        let spacing = max(radius * max(brush.spacing, 0.08), 1e-4)
        let hardness = min(max(brush.hardness, 0), 0.98)
        let centerLocal = hit.localPoint
        // 局部空间的笔刷半径：用世界→局部的平均缩放换算，非均匀缩放时取最保守（最大）的一档
        let scaleWorld = SIMD3<Float>(Float(object.scale.x), Float(object.scale.y), Float(object.scale.z))
        let maxScale = max(max(abs(scaleWorld.x), abs(scaleWorld.y)), max(abs(scaleWorld.z), 1e-4))
        let localRadius = radius / maxScale

        var splats: [PaintSplat] = []
        splats.reserveCapacity(512)

        for t in 0..<mesh.triangleCount {
            if splats.count >= maxSplats { break }
            let (a, b, c) = mesh.triangle(t)
            // 三角形在局部空间的外接半径：重心距离减它就够判断有没有交集
            let centroid = (a + b + c) / 3
            let triRadius = max(simd_length(a - centroid), max(simd_length(b - centroid), simd_length(c - centroid)))
            guard simd_length(centroid - centerLocal) - triRadius <= localRadius else { continue }

            let 格 = mesh.rect(ofTriangle: t)
            // 解缠周期用「一格宽」而不是 1：格子内缩过 padding，拿 1 去抬接缝会多抬一截，
            // 缝两侧的笔迹就跟着错开那一点（细笔看得出来）
            let (t0, t1, t2) = PaintUV.解缠(mesh.triangleUV(t).0, mesh.triangleUV(t).1, mesh.triangleUV(t).2,
                                        周期: 格.z - 格.x)
            // 退化三角形（球的极点扇、接缝、零面积片）没有可信的 UV/世界比。以前这里兜底 256，
            // 等于把单个 splat 放大到铺满整张图集 —— 于是"刷子扫到模型边缘，整个模型都被染色"。
            // 现在退化就给中性密度，再靠下面的格内矩形 + GPU 侧夹紧双重兜底。
            let uvPerWorld = 三角形UV密度(t, mesh: mesh, a: a, b: b, c: c) ?? 1

            // 切平面坐标 → uv 的雅可比：整支笔刷的基是「贴表面的圆盘」，但落笔要落在 uv 上，
            // 所以每个三角形各自把自己那段表面摊到 uv 上。j1/j2 就是「uv 走 1 格，圆盘里走多远」，
            // 已经除掉笔刷半径（单位 = 笔刷半径），GPU 侧 brush = j1·Δu + j2·Δv 直接就是圆盘坐标。
            // 不这么干的话（旧做法：Δuv / (半径 × uv密度)）图案会被 UV 的拉伸方向带着歪，
            // 斜纹、格纹、带方向的图案全都会走形，而且跟表面朝向一点关系都没有。
            let j1: SIMD2<Float>
            let j2: SIMD2<Float>
            let wa = world * SIMD4<Float>(a, 1)
            let wb = world * SIMD4<Float>(b, 1)
            let wc = world * SIMD4<Float>(c, 1)
            let du1 = t1 - t0
            let du2 = t2 - t0
            let det = du1.x * du2.y - du1.y * du2.x
            // 精确路径的常量：三角形 uv 顶点 / 世界顶点 / 整支笔刷的贴表面基（已除笔刷半径）/ 落笔点。
            // GPU 片元靠它们由像素 uv 反解重心坐标、插出世界位置再算圆盘坐标 ——
            // 世界位置跨接缝本来就连续，所以图案不会在缝上折弯、间隔也不会突变。
            // 只有几何不可信（退化三角形）时，才退回用本片三角形的 j 兜底。
            let 几何可信: Float = abs(det) > 1e-12 ? 1 : 0
            let 精确UV0 = SIMD4<Float>(t0.x, t0.y, t1.x, t1.y)
            let 精确UV1 = SIMD4<Float>(t2.x, t2.y, 0, 0)
            let 世界0 = SIMD4<Float>(wa.x, wa.y, wa.z, 几何可信)
            let 世界1 = SIMD4<Float>(wb.x, wb.y, wb.z, 0)
            let 世界2 = SIMD4<Float>(wc.x, wc.y, wc.z, 0)
            let 基0 = SIMD4<Float>(基.x.x, 基.x.y, 基.x.z, 0) / max(radius, 1e-9)
            let 基1 = SIMD4<Float>(基.y.x, 基.y.y, 基.y.z, 0) / max(radius, 1e-9)
            let 原点 = SIMD4<Float>(hit.worldPoint.x, hit.worldPoint.y, hit.worldPoint.z, 几何可信)
            if abs(det) > 1e-12 {
                let dP1 = SIMD3<Float>(wb.x - wa.x, wb.y - wa.y, wb.z - wa.z)
                let dP2 = SIMD3<Float>(wc.x - wa.x, wc.y - wa.y, wc.z - wa.z)
                let dPdu = (dP1 * du2.y - dP2 * du1.y) / det
                let dPdv = (dP2 * du1.x - dP1 * du2.x) / det
                j1 = SIMD2<Float>(simd_dot(dPdu, 基.x), simd_dot(dPdu, 基.y)) / radius
                j2 = SIMD2<Float>(simd_dot(dPdv, 基.x), simd_dot(dPdv, 基.y)) / radius
            } else {
                // 退化三角形（球的极点扇、零面积片）没有可信的 uv 方向：退回各向同性，
                // 至少不会把图案甩到别处去
                let k = 1 / max(radius * uvPerWorld, 1e-9)
                j1 = SIMD2<Float>(k, 0)
                j2 = SIMD2<Float>(0, k)
            }
            let 格宽 = max(格.z - 格.x, 1e-4)
            // 这个三角形自己的 uv 尺度：下面用它给 splat 的 uv 半径封顶。
            // j 只在这一个三角形里成立，splat 一旦跨出这片 uv，就是拿这片的 j 去换算隔壁 ——
            // 隔壁的 uv 密度可能差好几倍，换算出来的图案尺度整个错掉。
            let uvEdge = max(max(simd_length(t1 - t0), simd_length(t2 - t0)), simd_length(t2 - t1))

            // splat 的 uv 半径（三角形级，与具体采样点无关）。
            let edge1 = simd_length(b - a)
            let edge2 = simd_length(c - a)
            let edge3 = simd_length(c - b)
            let maxEdge = max(edge1, max(edge2, edge3)) / maxScale
            // 采样间距跟着局部三角形走，不再全局固定。
            // 原来一个 splat 的世界半径就是整支笔刷，比一片三角形大好几倍 ——
            // 它只能靠「用自己那片三角形的 j」去覆盖隔壁好几片，而隔壁 uv 密度可能差几倍，
            // 换算出的图案尺度整个错掉。现在把笔刷切成许多「一片三角形大小」的小块密铺，
            // 每块只在自己那片三角形里生效，j 就永远是准的。
            // 下限取笔刷半径的 1/8：高模三角形比这还小时不能再切，
            // 否则一笔要撒几十万个 splat —— 那种尺度下相邻小片的 uv 密度本来就几乎相同，跨片无害。
            let 最细间距 = max(radius * 0.125, 1e-6)
            let 有效间距 = min(spacing, max(maxEdge * 0.6, 最细间距))

            // 取「面积比估的半径」与「雅可比反算的圆盘投影半轴」里更大的那个：
            // 强拉伸的面上圆盘投到 uv 是个长椭圆，只按面积估会盖不住两头，图案被切掉。
            let detJ = j1.x * j2.y - j2.x * j1.y
            var uvR = SIMD2<Float>(repeating: radius * uvPerWorld)
            if abs(detJ) > 1e-12 {
                uvR.x = max(uvR.x, simd_length(SIMD2<Float>(j2.y, -j1.y) / detJ))
                uvR.y = max(uvR.y, simd_length(SIMD2<Float>(-j2.x, j1.x) / detJ))
            }
            let 采样间距uv = max(有效间距 * uvPerWorld, 1e-6)
            // 下界 = 相邻两个 splat 在 uv 上的间距（留 30% 重叠，密铺不留点状空隙）
            let 半径下界 = max(采样间距uv * 1.3, 1.0 / Float(PaintUV.图集边长) * 1.5)
            // 硬上界 = 这个三角形自己的 uv 尺度。雅可比只是这一小片的线性近似，
            // splat 一旦跨到隔壁三角形，隔壁的 uv 密度可能差几倍（椭球被拉长那一侧尤甚），
            // 用这片的 j 换算出来的图案尺度整个错掉 —— 几十个 splat 相位各错一遍，
            // 叠出来就是「比笔刷还大、一团乱、不成形状」。
            let 半径上界 = max(半径下界,
                            min(min(max(radius * uvPerWorld, 1e-6) * 4, 格宽 * 0.5), uvEdge * 1.2))
            let uvRadius = min(max(max(uvR.x, uvR.y), 半径下界), 半径上界)

            let steps = max(1, min(64, Int(ceil(maxEdge / 有效间距))))
            let nd = Float(steps)

            for i in 0...steps {
                let u = Float(i) / nd
                for j in 0...(steps - i) {
                    let v = Float(j) / nd
                    let w0 = 1 - u - v
                    guard w0 >= -1e-4 else { continue }
                    let localP = a * w0 + b * u + c * v
                    let worldP = world * SIMD4<Float>(localP, 1)
                    let 位移 = SIMD3<Float>(worldP.x - hit.worldPoint.x,
                                            worldP.y - hit.worldPoint.y,
                                            worldP.z - hit.worldPoint.z)
                    let d = simd_length(位移)
                    guard d < radius else { continue }
                    // 这个 splat 的圆心在「整支笔刷圆盘」里的精确位置（±1 = 笔刷边缘）。
                    // 表面上的世界位移直接投到命中点的贴表面基上、再除笔刷半径，全程不经过 uv —
                    // 所以图案与 uv 怎么拉伸、表面在哪被压扁都无关，一支笔刷画的永远是
                    // 同一个圆盘里那一份图案。GPU 侧只要再加上 splat 自己那一小片的线性换算，
                    // 误差就不会再随「离落笔点有多远」滚雪球 —— 那正是右半边糊成一团、
                    // 越往外越不清的来源（几十个 splat 各自拿命中的那一小片 j 从落笔点外推）。
                    let brush0 = SIMD2<Float>(simd_dot(位移, 基.x), simd_dot(位移, 基.y)) / radius
                    let falloff = 1 - smoothstepNormalized(Float(d / radius), edge: hardness)
                    guard falloff > 0.002 else { continue }

                    let uvRaw = t0 * w0 + t1 * u + t2 * v
                    // 接缝：折回本格，不能硬夹到格边。
                    // 解缠让跨缝的三角形在逻辑上连续（uv 会越到 1.01 / -0.01），
                    // 硬 clamp 把这些点全压到格边上 —— 笔迹就成贴着缝的一条竖线，
                    // 缝另一侧的表面一片空白。按格宽取模折回后，跨缝的两半各自落到格的两端，
                    // GPU 再用同样的格宽就近对齐，「缝左边、缝右边」就都能正常投影。
                    let uv = 环回格内(uvRaw, 格: 格)
                    let 缝半径 = SIMD2<Float>(repeating: uvRadius)
                    let 缝颜色 = SIMD4<Float>(brush.color.x, brush.color.y, brush.color.z,
                                             falloff * brush.opacity)
                    let 缝参数 = SIMD4<Float>(hardness, 0, 0, 0)
                    let 缝笔刷 = SIMD4<Float>(brush0.x, brush0.y, radius * uvPerWorld, 0)
                    let 缝雅可比 = SIMD4<Float>(j1.x, j1.y, j2.x, j2.y)
                    splats.append(PaintSplat(
                        center: uv,
                        radius: 缝半径,
                        color: 缝颜色,
                        params: 缝参数,
                        bounds: 格,
                        // 遮罩按「整支笔刷」采样：这里给出这个 splat 圆心在笔刷圆盘里的精确
                        // 坐标（brush0，±1 = 笔刷边缘）。GPU 主路径现在直接用下面三角形的 uv / 世界
                        // 顶点在片元里反解，brushRef / brushJac 只作退化兜底。
                        // 用未截断的 radius×uvPerWorld 兜底，图案才不会被格宽夹小
                        brushRef: 缝笔刷,
brushJac: 缝雅可比,
                        triUV0: 精确UV0,
                        triUV1: 精确UV1,
                        world0: 世界0,
                        world1: 世界1,
                        world2: 世界2,
                        basis0: 基0,
                        basis1: 基1,
                        originW: 原点
                    ))

                    // 接缝补写：这个 splat 的圆盘有半边越出了本格，那半边在 UV 上其实落在
                    // 格子的对面。quad 不再夹格（夹了会把图案压歪），越界像素由片元裁掉，
                    // 所以缝对面这半边得靠副本补上，否则会裂开一道「斜纹被切断」的直缝。
                    // 这里在对面补一份参数完全相同的副本，只把圆心平移一个格宽/格高；
                    // GPU 侧 dd 按同样的格宽就近折回，两份图案在缝上正好接得上。
                    let 格宽 = 格.z - 格.x
                    let 格高 = 格.w - 格.y
                    if 格宽 > 1e-5, 格高 > 1e-5 {
                        var 横移: [Float] = []
                        if uv.x - uvRadius < 格.x { 横移.append(格宽) }
                        if uv.x + uvRadius > 格.z { 横移.append(-格宽) }
                        var 纵移: [Float] = []
                        if uv.y - uvRadius < 格.y { 纵移.append(格高) }
                        if uv.y + uvRadius > 格.w { 纵移.append(-格高) }
                        if !横移.isEmpty || !纵移.isEmpty {
                            let 横列 = 横移.isEmpty ? [Float(0)] : 横移
                            let 纵列 = 纵移.isEmpty ? [Float(0)] : 纵移
                            for 移x in 横列 {
                                for 移y in 纵列 {
                                    guard 移x != 0 || 移y != 0 else { continue }
                                    splats.append(PaintSplat(
                                        center: uv + SIMD2<Float>(移x, 移y),
                                        radius: 缝半径,
                                        color: 缝颜色,
                                        params: 缝参数,
                                        bounds: 格,
                                        brushRef: 缝笔刷,
brushJac: 缝雅可比,
                                        triUV0: 精确UV0,
                                        triUV1: 精确UV1,
                                        world0: 世界0,
                                        world1: 世界1,
                                        world2: 世界2,
                                        basis0: 基0,
                                        basis1: 基1,
                                        originW: 原点
                                    ))
                                }
                            }
                        }
                    }
                }
            }
        }
        return splats
    }

    /// 把 uv 环绕折回本格内部（按格宽高取模，而不是夹到格边）。
    ///
    /// 接缝处解缠后插值出的 uv 会越到格外面（1.01 / -0.01），而那是逻辑上连续、
    /// 物理上也连续的点。硬 clamp 会把它们全压到格边上 —— 笔迹变成贴着缝的一条竖线，
    /// 缝另一侧的表面完全没有笔迹。取模折回则让越界的点落到格的另一头，
    /// 正好是缝对面那块表面该在的位置；GPU 侧再用同样的格宽做就近对齐，图案就续上了。
    private static func 环回格内(_ uv: SIMD2<Float>, 格: SIMD4<Float>) -> SIMD2<Float> {
        let 宽 = 格.z - 格.x
        let 高 = 格.w - 格.y
        // 格退化（老数据 / 空 piece）：没有可环绕的周期，只能夹
        guard 宽 > 1e-5, 高 > 1e-5 else {
            return SIMD2<Float>(min(max(uv.x, 格.x), 格.z),
                                min(max(uv.y, 格.y), 格.w))
        }
        func 环(_ v: Float, _ 起: Float, _ 长: Float) -> Float {
            let t = (v - 起).truncatingRemainder(dividingBy: 长)
            return 起 + (t < 0 ? t + 长 : t)
        }
        return SIMD2<Float>(环(uv.x, 格.x, 宽), 环(uv.y, 格.y, 高))
    }

    /// 三角形的 UV 面积 / 世界面积，开方 = 1 世界单位对应多少 uv
    private static func 三角形UV密度(_ t: Int,
                                mesh: PaintMesh,
                                a: SIMD3<Float>,
                                b: SIMD3<Float>,
                                c: SIMD3<Float>) -> Float? {
        let (t0, t1, t2) = PaintUV.解缠(mesh.triangleUV(t).0, mesh.triangleUV(t).1, mesh.triangleUV(t).2)
        let e1 = t1 - t0
        let e2 = t2 - t0
        let areaUV = abs(e1.x * e2.y - e1.y * e2.x) * 0.5
        let area3D = simd_length(cross(b - a, c - a)) * 0.5
        guard area3D > 1e-9, areaUV > 1e-14 else { return nil }
        return sqrt(areaUV / area3D)
    }

    /// 归一化距离 → 衰减权重。edge = 硬度：0 全软，1 硬边
    private static func smoothstepNormalized(_ x: Float, edge: Float) -> Float {
        let start = min(max(edge, 0), 0.95)
        let s = min(max((x - start) / max(1 - start, 1e-4), 0), 1)
        return s * s * (3 - 2 * s)
    }
}

