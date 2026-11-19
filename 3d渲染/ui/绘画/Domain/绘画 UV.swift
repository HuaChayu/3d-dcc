import Foundation
import simd

// MARK: - 可绘画网格

/// 一个 MeshKind 的「可绘画网格」。
///
/// 关键约束：顶点顺序与三角形顺序必须与 PTGeometry.piece(for:) 完全一致，
/// 因为拾取命中的三角形下标要能直接拿去查 UV、也要能对上 PT 那边同一个三角形。
/// 所以这里不自己造几何，而是把 PTGeometry 的 piece 拼起来、顺手把每个 piece 的参数化 UV
/// 映射进一张图集的格子里。
struct PaintMesh {
    var positions: [SIMD3<Float>] = []
    var normals: [SIMD3<Float>] = []
    /// 图集 UV（已映射到 0...1 的全局图集坐标，不是单个 piece 的局部参数）
    var uvs: [SIMD2<Float>] = []
    var indices: [UInt32] = []
    /// 每个 piece 在图集里的可用矩形（minX, minY, maxX, maxY，已内缩）。
    /// 笔刷/PT 采样都必须被夹在这个框里 —— 越框就会采到别的部件、甚至别的物体的笔迹。
    var pieceRect: [SIMD4<Float>] = []
    /// 每个顶点属于哪个 piece（= pieceRect 的下标）
    var vertexPiece: [UInt32] = []
    /// 每个三角形属于哪个 piece（= 三个顶点共用同一个 piece，取 i0 那个）
    var trianglePiece: [UInt32] = []

    var triangleCount: Int { indices.count / 3 }

    func triangle(_ t: Int) -> (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>) {
        let i0 = Int(indices[t * 3])
        let i1 = Int(indices[t * 3 + 1])
        let i2 = Int(indices[t * 3 + 2])
        return (positions[i0], positions[i1], positions[i2])
    }

    func triangleUV(_ t: Int) -> (SIMD2<Float>, SIMD2<Float>, SIMD2<Float>) {
        let i0 = Int(indices[t * 3])
        let i1 = Int(indices[t * 3 + 1])
        let i2 = Int(indices[t * 3 + 2])
        return (uvs[i0], uvs[i1], uvs[i2])
    }

    /// 这个三角形的 splat 允许出现的矩形（它的 piece 那一格）
    func rect(ofTriangle t: Int) -> SIMD4<Float> {
        guard t < trianglePiece.count else { return SIMD4<Float>(0, 0, 1, 1) }
        let piece = Int(trianglePiece[t])
        guard piece < pieceRect.count else { return SIMD4<Float>(0, 0, 1, 1) }
        return pieceRect[piece]
    }

    /// 顶点允许出现的矩形（PT 侧夹接缝用）
    func rect(ofVertex i: Int) -> SIMD4<Float> {
        guard i < vertexPiece.count else { return SIMD4<Float>(0, 0, 1, 1) }
        let piece = Int(vertexPiece[i])
        guard piece < pieceRect.count else { return SIMD4<Float>(0, 0, 1, 1) }
        return pieceRect[piece]
    }

    /// 图集里这个三角形占的 UV 面积 / 世界面积，开方后就是「1 世界单位 ≈ 多少 uv」。
    /// 球两极的三角形在 UV 上被压扁，笔刷半径必须按这个比例补偿，否则一刷就是一片。
    /// 退化三角形（面积≈0：球的极点扇、接缝、圆柱盖外圈）返回 nil —— 这种三角形没有
    /// 可信的 UV/世界比，硬塞一个「很大」的值就会让单个 splat 的 quad 铺满整张图集，
    /// 于是「刷子刷到模型边缘，整个模型都被染色」。
    func uvPerWorld(_ t: Int) -> Float? {
        let (p0, p1, p2) = triangle(t)
        let (t0, t1, t2) = triangleUV(t)
        let area3D = 0.5 * simd_length(simd_cross(p1 - p0, p2 - p0))
        let e1 = t1 - t0
        let e2 = t2 - t0
        let areaUV = 0.5 * abs(e1.x * e2.y - e1.y * e2.x)
        guard area3D > 1e-9, areaUV > 1e-12 else { return nil }
        return sqrt(areaUV / area3D)
    }
}

// MARK: - UV 图集

/// 程序化几何的 UV 布局。
///
/// 单个 piece 的形（球 / 环面 / 平面 / 立方体）自带满幅 0...1 参数，直接铺满整张图；
/// 组合体（shader ball 的 4 个部件、圆柱的侧壁 + 两个盖子）必须切开格子，否则会互相覆盖。
enum PaintUV {

    /// 图集边长（像素）。1024 在 4K 视口下笔迹依然细腻，显存也压得住（每图层 4MB）。
    static let 图集边长 = 1024

    /// 格子内缩，避免双线性采样在格子边界串到隔壁的笔迹
    private static let 内缩UV: Float = 0.004

    private static let 锁 = NSLock()
    private nonisolated(unsafe) static var 缓存: [MeshKind: PaintMesh] = [:]

    static func mesh(for kind: MeshKind) -> PaintMesh {
        锁.lock()
        if let hit = 缓存[kind] {
            锁.unlock()
            return hit
        }
        锁.unlock()

        let built = build(kind)

        锁.lock()
        缓存[kind] = built
        锁.unlock()
        return built
    }

    private static func build(_ kind: MeshKind) -> PaintMesh {
        let pieces = PTGeometry.piece(for: kind)
        let 列数 = 列数(for: pieces.count)
        let 行数 = 行数(for: pieces.count)

        var out = PaintMesh()
        for (index, piece) in pieces.enumerated() {
            let col = index % 列数
            let row = index / 列数
            let origin = SIMD2<Float>(Float(col) / Float(列数), Float(row) / Float(行数))
            let scale = SIMD2<Float>(1 / Float(列数), 1 / Float(行数))
            let 可用 = scale - SIMD2<Float>(repeating: 内缩UV * 2)

            let base = UInt32(out.positions.count)
            // 这一格的可用矩形：splat 的 quad 与 PT 的采样都会被夹进这个框，
            // 保证任何一边的笔迹都不会跨到隔壁格子（隔壁可能是别的部件，甚至别的物体）。
            let 框左下 = origin + SIMD2<Float>(repeating: 内缩UV)
            let 框右上 = 框左下 + 可用
            out.pieceRect.append(SIMD4<Float>(框左下.x, 框左下.y, 框右上.x, 框右上.y))
            for i in piece.positions.indices {
                out.positions.append(piece.positions[i])
                out.normals.append(piece.normals[i])
                let local = i < piece.uvs.count ? piece.uvs[i] : SIMD2<Float>(0.5, 0.5)
                out.uvs.append(框左下 + local * 可用)
                out.vertexPiece.append(UInt32(index))
            }
            for i in piece.indices {
                out.indices.append(i + base)
            }
            for _ in 0..<(piece.indices.count / 3) {
                out.trianglePiece.append(UInt32(index))
            }
        }
        return out
    }

    /// 单块铺满；两块对半；三块以上排成 2×2（圆柱正好三格，第四格留空）
    private static func 列数(for pieceCount: Int) -> Int {
        switch pieceCount {
        case 0, 1: 1
        case 2: 2
        default: 2
        }
    }

    private static func 行数(for pieceCount: Int) -> Int {
        switch pieceCount {
        case 0, 1: 1
        case 2: 1
        default: (pieceCount + 1) / 2
        }
    }

    /// 绕 u 方向接缝的三角形：顶点 u 分别落在 0 附近和 1 附近，直接插值会横跨整张图。
    /// 把偏小的那侧 +1 抬到连续域里，插值结果再取小数部分，笔迹就不会在接缝上拉一条长条。
    ///
    /// 周期默认 1（整图环绕）。但一格内缩过 padding 时（单格图集里格宽≈0.992），
    /// 真实的环绕周期是「一格宽」而不是 1 —— 抬错量会让缝两侧的笔迹错开那一小截，
    /// 所以落笔采样时要按格宽传进来。
    static func 解缠(_ t0: SIMD2<Float>,
                    _ t1: SIMD2<Float>,
                    _ t2: SIMD2<Float>,
                    周期: Float = 1) -> (SIMD2<Float>, SIMD2<Float>, SIMD2<Float>) {
        let 参考 = t0.x
        let 半 = max(周期, 1e-6) * 0.5
        func 抬起(_ uv: SIMD2<Float>) -> SIMD2<Float> {
            var v = uv
            if v.x - 参考 > 半 { v.x -= 周期 }
            if 参考 - v.x > 半 { v.x += 周期 }
            return v
        }
        return (t0, 抬起(t1), 抬起(t2))
    }

    /// 把 u 折回 0...1（图集是环绕的）
    static func 折回(_ uv: SIMD2<Float>) -> SIMD2<Float> {
        var v = uv
        v.x -= floor(v.x)
        v.y = min(max(v.y, 0), 1)
        return v
    }
}
