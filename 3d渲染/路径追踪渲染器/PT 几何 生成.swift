import Foundation
import simd

// MARK: - 程序化几何

/// PT 不吃 RealityKit 的网格，自己生成三角形：
/// 一是能保证法线质量（PT 里法线错了就是一片噪点），
/// 二是避免从 MeshResource 里抠 buffer 的那堆版本差异。
/// 尺寸全部对齐 SceneBuilder 里的同名几何，两个模式看起来是同一个物体。
enum PTGeometry {

    struct Piece {
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        /// 参数化 UV（每个 piece 自己占满 0...1）。
        /// 绘画功能要往里写笔迹，就必须有一条从「表面点」到「贴图坐标」的稳定映射；
        /// 这些形体本来就是按 (u,v) 参数生成的，顺手把参数留下来最省事。
        /// 组合体（shader ball / 圆柱盖）的多个 piece 会互相重叠，由 PaintUV 统一分配到图集格子里。
        var uvs: [SIMD2<Float>] = []
        var indices: [UInt32] = []
    }

    // MARK: 基础形体

    static func sphere(radius: Float, segments: Int = 72, rings: Int = 36) -> Piece {
        var piece = Piece()
        for ring in 0...rings {
            let v = Float(ring) / Float(rings)
            let phi = v * Float.pi
            let y = cos(phi)
            let r = sin(phi)
            for segment in 0...segments {
                let u = Float(segment) / Float(segments)
                let theta = u * 2 * Float.pi
                let n = SIMD3<Float>(r * cos(theta), y, r * sin(theta))
                piece.positions.append(n * radius)
                piece.normals.append(simd_normalize(n))
                // 经度 → u，纬度 → v；v 取反让 v=0 落在北极，贴图上下不会倒
                piece.uvs.append(SIMD2<Float>(u, 1 - v))
            }
        }
        let stride = segments + 1
        for ring in 0..<rings {
            for segment in 0..<segments {
                let a = UInt32(ring * stride + segment)
                let b = UInt32((ring + 1) * stride + segment)
                piece.indices.append(contentsOf: [a, b, a + 1, a + 1, b, b + 1])
            }
        }
        return piece
    }

    static func box(size: SIMD3<Float>) -> Piece {
        var piece = Piece()
        let h = size * 0.5
        // 六个面各自独立顶点，才能拿到硬边法线
        let faces: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = [
            ([1, 0, 0], [0, 0, -1], [0, 1, 0]),
            ([-1, 0, 0], [0, 0, 1], [0, 1, 0]),
            ([0, 1, 0], [1, 0, 0], [0, 0, 1]),
            ([0, -1, 0], [1, 0, 0], [0, 0, -1]),
            ([0, 0, 1], [1, 0, 0], [0, 1, 0]),
            ([0, 0, -1], [-1, 0, 0], [0, 1, 0])
        ]
        for (faceIndex, face) in faces.enumerated() {
            let (normal, tangent, bitangent) = face
            let base = UInt32(piece.positions.count)
            let center = normal * h
            let u = tangent * h
            let v = bitangent * h
            let corners = [center - u - v, center + u - v, center + u + v, center - u + v]
            // 六个面共用一张图，按 3 列 × 2 行切成各自的格子（face 顺序即 faces 数组顺序）
            let cell = SIMD2<Float>(0.34, 0.5)
            let origin = SIMD2<Float>(Float(faceIndex % 3) * cell.x, Float(faceIndex / 3) * cell.y)
            // 内缩一点，避免面与面之间采样串色
            let inset = SIMD2<Float>(0.008, 0.008)
            let cornersUV: [SIMD2<Float>] = [
                SIMD2<Float>(0, 0), SIMD2<Float>(1, 0), SIMD2<Float>(1, 1), SIMD2<Float>(0, 1)
            ]
            for (slot, corner) in corners.enumerated() {
                piece.positions.append(corner)
                piece.normals.append(normal)
                let local = cornersUV[slot]
                piece.uvs.append(origin + inset + local * (cell - inset * 2))
            }
            piece.indices.append(contentsOf: [base, base + 1, base + 2, base, base + 2, base + 3])
        }
        return piece
    }

    static func cylinder(height: Float, radius: Float, segments: Int = 64) -> Piece {
        var piece = Piece()
        let half = height * 0.5

        // 侧面
        for segment in 0...segments {
            let u = Float(segment) / Float(segments)
            let theta = u * 2 * Float.pi
            let n = SIMD3<Float>(cos(theta), 0, sin(theta))
            piece.positions.append(SIMD3<Float>(n.x * radius, -half, n.z * radius))
            piece.normals.append(n)
            piece.uvs.append(SIMD2<Float>(u, 0))
            piece.positions.append(SIMD3<Float>(n.x * radius, half, n.z * radius))
            piece.normals.append(n)
            piece.uvs.append(SIMD2<Float>(u, 1))
        }
        for segment in 0..<segments {
            let a = UInt32(segment * 2)
            piece.indices.append(contentsOf: [a, a + 1, a + 2, a + 2, a + 1, a + 3])
        }

        // 上下盖
        for (y, normal) in [(half, SIMD3<Float>(0, 1, 0)), (-half, SIMD3<Float>(0, -1, 0))] {
            let center = UInt32(piece.positions.count)
            piece.positions.append(SIMD3<Float>(0, y, 0))
            piece.normals.append(normal)
            // 盖子按极坐标铺成圆盘：圆心 (0.5,0.5)，外圈是半径 0.5 的圆
            piece.uvs.append(SIMD2<Float>(0.5, 0.5))
            for segment in 0...segments {
                let theta = Float(segment) / Float(segments) * 2 * Float.pi
                piece.positions.append(SIMD3<Float>(cos(theta) * radius, y, sin(theta) * radius))
                piece.normals.append(normal)
                piece.uvs.append(SIMD2<Float>(0.5 + 0.5 * cos(theta), 0.5 + 0.5 * sin(theta)))
            }
            for segment in 0..<segments {
                let a = center + 1 + UInt32(segment)
                if normal.y > 0 {
                    piece.indices.append(contentsOf: [center, a, a + 1])
                } else {
                    piece.indices.append(contentsOf: [center, a + 1, a])
                }
            }
        }
        return piece
    }

    static func torus(ring: Float, pipe: Float, ringSegments: Int = 96, pipeSegments: Int = 48) -> Piece {
        var piece = Piece()
        for ringIndex in 0...ringSegments {
            let u = Float(ringIndex) / Float(ringSegments) * 2 * Float.pi
            let center = SIMD3<Float>(cos(u) * ring, 0, sin(u) * ring)
            for pipeIndex in 0...pipeSegments {
                let v = Float(pipeIndex) / Float(pipeSegments) * 2 * Float.pi
                let normal = SIMD3<Float>(cos(u) * cos(v), sin(v), sin(u) * cos(v))
                piece.positions.append(center + normal * pipe)
                piece.normals.append(normal)
                // 环面天然是可展参数面：大环角 → u，小管角 → v
                piece.uvs.append(SIMD2<Float>(Float(ringIndex) / Float(ringSegments),
                                             Float(pipeIndex) / Float(pipeSegments)))
            }
        }
        let stride = pipeSegments + 1
        for ringIndex in 0..<ringSegments {
            for pipeIndex in 0..<pipeSegments {
                let a = UInt32(ringIndex * stride + pipeIndex)
                let b = UInt32((ringIndex + 1) * stride + pipeIndex)
                piece.indices.append(contentsOf: [a, b, a + 1, a + 1, b, b + 1])
            }
        }
        return piece
    }

    static func plane(width: Float, depth: Float) -> Piece {
        var piece = Piece()
        let hw = width * 0.5
        let hd = depth * 0.5
        let normal = SIMD3<Float>(0, 1, 0)
        piece.positions = [
            SIMD3<Float>(-hw, 0, -hd), SIMD3<Float>(hw, 0, -hd),
            SIMD3<Float>(hw, 0, hd), SIMD3<Float>(-hw, 0, hd)
        ]
        piece.normals = [normal, normal, normal, normal]
        piece.uvs = [
            SIMD2<Float>(0, 0), SIMD2<Float>(1, 0), SIMD2<Float>(1, 1), SIMD2<Float>(0, 1)
        ]
        piece.indices = [0, 1, 2, 0, 2, 3]
        return piece
    }

    /// 圆锥：底面在 -h/2、顶点在 +h/2，与圆柱同一套朝向
    static func cone(radius: Float, height: Float, segments: Int = 64) -> Piece {
        var piece = Piece()
        let half = height * 0.5
        // 侧面：顶点扇 + 底圈；法线按母线求（竖直分量 radius、径向分量 height）
        let apex = UInt32(piece.positions.count)
        piece.positions.append(SIMD3<Float>(0, half, 0))
        piece.normals.append(SIMD3<Float>(0, 1, 0))
        piece.uvs.append(SIMD2<Float>(0.5, 1))
        for segment in 0...segments {
            let u = Float(segment) / Float(segments)
            let theta = u * 2 * Float.pi
            let c = cos(theta), s = sin(theta)
            piece.positions.append(SIMD3<Float>(c * radius, -half, s * radius))
            piece.normals.append(simd_normalize(SIMD3<Float>(c * height, radius, s * height)))
            piece.uvs.append(SIMD2<Float>(u, 0))
        }
        for segment in 0..<segments {
            let a = apex + 1 + UInt32(segment)
            piece.indices.append(contentsOf: [apex, a, a + 1])
        }
        // 底面
        let center = UInt32(piece.positions.count)
        piece.positions.append(SIMD3<Float>(0, -half, 0))
        piece.normals.append(SIMD3<Float>(0, -1, 0))
        piece.uvs.append(SIMD2<Float>(0.5, 0.5))
        for segment in 0...segments {
            let theta = Float(segment) / Float(segments) * 2 * Float.pi
            piece.positions.append(SIMD3<Float>(cos(theta) * radius, -half, sin(theta) * radius))
            piece.normals.append(SIMD3<Float>(0, -1, 0))
            piece.uvs.append(SIMD2<Float>(0.5 + 0.5 * cos(theta), 0.5 + 0.5 * sin(theta)))
        }
        for segment in 0..<segments {
            let a = center + 1 + UInt32(segment)
            piece.indices.append(contentsOf: [center, a + 1, a])
        }
        return piece
    }

    /// 胶囊：总高 height（含两端半球），中间柱段自动扣掉两个半径。
    /// 走"竖剖轮廓 → 绕 Y 旋转"，与球体同一套环序，绕向/UV 方向也对得上。
    static func capsule(radius: Float, height: Float, segments: Int = 64, capRings: Int = 16) -> Piece {
        var piece = Piece()
        let 柱半 = max(0, height * 0.5 - radius)
        var 轮廓: [(y: Float, r: Float, ny: Float)] = []
        // 下半球：底极点 → 赤道
        for index in 0...capRings {
            let t = Float(index) / Float(capRings) * Float.pi / 2
            轮廓.append((y: -柱半 - radius * cos(t), r: radius * sin(t), ny: -cos(t)))
        }
        if 柱半 > 0 {
            轮廓.append((y: 柱半, r: radius, ny: 0))
        }
        // 上半球：赤道 → 顶点（柱段为 0 时跳过重复的赤道环）
        for index in (柱半 > 0 ? 0 : 1)...capRings {
            let t = Float(index) / Float(capRings) * Float.pi / 2
            轮廓.append((y: 柱半 + radius * sin(t), r: radius * cos(t), ny: sin(t)))
        }
        // 反过来排：环序与球体一致（从上往下），v=0 落在顶部
        轮廓.reverse()

        for (环, p) in 轮廓.enumerated() {
            let v = Float(环) / Float(max(1, 轮廓.count - 1))
            let 径向 = sqrt(max(0, 1 - p.ny * p.ny))
            for segment in 0...segments {
                let u = Float(segment) / Float(segments)
                let theta = u * 2 * Float.pi
                let c = cos(theta), s = sin(theta)
                piece.positions.append(SIMD3<Float>(c * p.r, p.y, s * p.r))
                piece.normals.append(SIMD3<Float>(c * 径向, p.ny, s * 径向))
                piece.uvs.append(SIMD2<Float>(u, v))
            }
        }
        let stride = segments + 1
        for 环 in 0..<(轮廓.count - 1) {
            for segment in 0..<segments {
                let a = UInt32(环 * stride + segment)
                let b = UInt32((环 + 1) * stride + segment)
                piece.indices.append(contentsOf: [a, b, a + 1, a + 1, b, b + 1])
            }
        }
        return piece
    }

    /// 半球：赤道面在 y=0，凸面朝 +Y，底部补一张朝下的圆盘封口
    static func hemisphere(radius: Float, segments: Int = 72, rings: Int = 18) -> Piece {
        var piece = Piece()
        for ring in 0...rings {
            let v = Float(ring) / Float(rings)
            let phi = v * Float.pi / 2
            let y = cos(phi)
            let r = sin(phi)
            for segment in 0...segments {
                let u = Float(segment) / Float(segments)
                let theta = u * 2 * Float.pi
                let n = SIMD3<Float>(r * cos(theta), y, r * sin(theta))
                piece.positions.append(n * radius)
                piece.normals.append(simd_normalize(n))
                piece.uvs.append(SIMD2<Float>(u, 1 - v))
            }
        }
        let stride = segments + 1
        for ring in 0..<rings {
            for segment in 0..<segments {
                let a = UInt32(ring * stride + segment)
                let b = UInt32((ring + 1) * stride + segment)
                piece.indices.append(contentsOf: [a, b, a + 1, a + 1, b, b + 1])
            }
        }
        // 封口
        let center = UInt32(piece.positions.count)
        piece.positions.append(.zero)
        piece.normals.append(SIMD3<Float>(0, -1, 0))
        piece.uvs.append(SIMD2<Float>(0.5, 0.5))
        for segment in 0...segments {
            let theta = Float(segment) / Float(segments) * 2 * Float.pi
            piece.positions.append(SIMD3<Float>(cos(theta) * radius, 0, sin(theta) * radius))
            piece.normals.append(SIMD3<Float>(0, -1, 0))
            piece.uvs.append(SIMD2<Float>(0.5 + 0.5 * cos(theta), 0.5 + 0.5 * sin(theta)))
        }
        for segment in 0..<segments {
            let a = center + 1 + UInt32(segment)
            piece.indices.append(contentsOf: [center, a + 1, a])
        }
        return piece
    }

    // MARK: 组合体

    /// 单个 MeshKind 的几何（世界变换由调用方施加）
    static func piece(for kind: MeshKind) -> [Piece] {
        switch kind {
        case .sphere:
            return [sphere(radius: 0.9)]
        case .cube:
            return [box(size: [1.5, 1.5, 1.5])]
        case .torus:
            return [torus(ring: 0.85, pipe: 0.3)]
        case .cylinder:
            return [cylinder(height: 1.8, radius: 0.6)]
        case .plane:
            return [plane(width: 1, depth: 1)]
        case .shaderBall:
            return shaderBall()
        }
    }

    /// 对齐 SceneBuilder.makeShaderBallEntity：主球 + 底座 + 凹槽环 + 斜台
    static func shaderBall() -> [Piece] {
        var ball = sphere(radius: 0.86)
        translate(&ball, y: 0.98)
        var plinth = cylinder(height: 0.16, radius: 0.62)
        translate(&plinth, y: 0.08)
        var groove = torus(ring: 0.46, pipe: 0.055)
        translate(&groove, y: 0.17)
        let slope = box(size: SIMD3<Float>(1.35, 0.16, 1.35))
        return [ball, plinth, groove, slope]
    }

    // MARK: 工具

    static func translate(_ piece: inout Piece, x: Float = 0, y: Float = 0, z: Float = 0) {
        let offset = SIMD3<Float>(x, y, z)
        for index in piece.positions.indices {
            piece.positions[index] += offset
        }
    }
}

// MARK: - 变换

extension Vec3 {
    var simd: SIMD3<Float> { SIMD3<Float>(Float(x), Float(y), Float(z)) }
}

extension SceneObject {
    /// 世界矩阵：**向变换域要**（阶段2-第二步起）。
    ///
    /// 以前这里自己乘 TRS、自己拼矩阵，全工程因此有三个矩阵口径：
    /// 这里的 pathTraceMatrix、拾取几何的世界矩阵(object)、视口直赋的 SCNNode transform。
    /// 现在唯一派生方是变换域：`变换域.本地矩阵(位置:欧拉角:缩放:)` + 父子链缓存，
    /// 本属性退化为"写通读"的薄壳（先把这个物体的 TRS 交给变换接线，再读回世界矩阵），
    /// 只是为了让几十个既有调用点不用一起改签名。**不要再往这里加任何乘法。**
    var pathTraceMatrix: simd_float4x4 {
        变换接线.共享.世界矩阵(of: self)
    }
}
