import Foundation
import simd

/// glTF 2.0 / GLB 原生解析（不依赖 Blender）。
/// 之所以自己写：glTF 是 JSON + 紧凑二进制，规范稳定，原生读写比拉 Blender 起进程快一个量级，
/// 而且导出侧也能复用同一份结构定义。
enum GLTF解析: 网格格式解析器 {

    // MARK: 文档结构

    private struct 文档: Decodable {
        var asset: 资产?
        var scene: Int?
        var scenes: [场景]?
        var nodes: [节点]?
        var meshes: [网格定义]?
        var accessors: [访问器]?
        var bufferViews: [缓冲视图]?
        var buffers: [缓冲]?
        var materials: [材质定义]?
        var images: [图像定义]?
        var textures: [纹理定义]?
    }

    private struct 资产: Decodable {
        var version: String?
        var generator: String?
    }

    private struct 场景: Decodable {
        var name: String?
        var nodes: [Int]?
    }

    private struct 节点: Decodable {
        var name: String?
        var mesh: Int?
        var children: [Int]?
        var matrix: [Float]?
        var translation: [Float]?
        var rotation: [Float]?
        var scale: [Float]?
    }

    private struct 网格定义: Decodable {
        var name: String?
        var primitives: [图元]
    }

    private struct 图元: Decodable {
        var attributes: [String: Int]
        var indices: Int?
        var material: Int?
        var mode: Int?
    }

    private struct 访问器: Decodable {
        var bufferView: Int?
        var byteOffset: Int?
        var componentType: Int
        var normalized: Bool?
        var count: Int
        var type: String
    }

    private struct 缓冲视图: Decodable {
        var buffer: Int
        var byteOffset: Int?
        var byteLength: Int
        var byteStride: Int?
    }

    private struct 缓冲: Decodable {
        var uri: String?
        var byteLength: Int
    }

    private struct 图像定义: Decodable {
        var uri: String?
        var mimeType: String?
        var bufferView: Int?
    }

    private struct 纹理定义: Decodable {
        var source: Int?
    }

    private struct 材质定义: Decodable {
        struct PBR: Decodable {
            struct 纹理引用: Decodable {
                var index: Int?
            }
            var baseColorFactor: [Float]?
            var metallicFactor: Float?
            var roughnessFactor: Float?
            var baseColorTexture: 纹理引用?
        }
        var name: String?
        var pbrMetallicRoughness: PBR?
        var doubleSided: Bool?
        var emissiveFactor: [Float]?
    }

    // MARK: 入口

    static func 解析(url: URL, 设置: 单文件导入设置) throws -> 导入场景 {
        guard let 原始 = try? Data(contentsOf: url) else {
            throw 导入导出错误.文件不可读(url)
        }

        var json数据 = Data()
        var 内嵌BIN: Data?

        if 原始.starts(with: Data("glTF".utf8)) {
            guard 原始.count > 20 else {
                throw 导入导出错误.解析失败(格式: "glTF", 原因: "GLB 文件过短")
            }
            var 偏移 = 12
            var 已取JSON = false
            while 偏移 + 8 <= 原始.count {
                let 长 = Int(UInt32(littleEndian: 原始[偏移..<偏移 + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }))
                let 类型 = UInt32(littleEndian: 原始[偏移 + 4..<偏移 + 8].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
                let 起 = 偏移 + 8
                let 止 = 起 + 长
                guard 止 <= 原始.count else { break }
                if 类型 == 0x4E4F534A {          // "JSON"
                    json数据 = 原始[起..<止]
                    已取JSON = true
                } else if 类型 == 0x004E4942 {   // "BIN\0"
                    内嵌BIN = 原始[起..<止]
                }
                偏移 = 止
            }
            guard 已取JSON else {
                throw 导入导出错误.解析失败(格式: "glTF", 原因: "GLB 内没有 JSON 块")
            }
        } else {
            json数据 = 原始
        }

        let 文件: 文档
        do {
            文件 = try JSONDecoder().decode(文档.self, from: json数据)
        } catch {
            throw 导入导出错误.解析失败(格式: "glTF", 原因: "JSON 解码失败：\(error.localizedDescription)")
        }

        var 场景 = 导入场景(源文件: url)

        var 缓冲数据: [Data] = []
        let 目录 = url.deletingLastPathComponent()
        for (i, 缓) in (文件.buffers ?? []).enumerated() {
            if let uri = 缓.uri {
                if uri.hasPrefix("data:") {
                    if let 逗号 = uri.firstIndex(of: ","),
                       let d = Data(base64Encoded: String(uri[uri.index(after: 逗号)...])) {
                        缓冲数据.append(d)
                        continue
                    }
                    场景.报告.append("buffer[\(i)] 内嵌数据解码失败")
                    缓冲数据.append(Data())
                } else {
                    let 路径 = 目录.appendingPathComponent(uri.removingPercentEncoding ?? uri)
                    缓冲数据.append((try? Data(contentsOf: 路径)) ?? Data())
                }
            } else if i == 0, let 内嵌BIN {
                缓冲数据.append(内嵌BIN)
            } else {
                缓冲数据.append(Data())
            }
        }

        for (i, 材) in (文件.materials ?? []).enumerated() {
            var 结果 = 导入材质(名称: 材.name ?? "材质\(i + 1)")
            if let pbr = 材.pbrMetallicRoughness {
                if let c = pbr.baseColorFactor, c.count >= 4 {
                    结果.基础色 = sRGB转线性(SIMD3(c[0], c[1], c[2]))
                    结果.不透明度 = min(max(c[3], 0), 1)
                }
                结果.金属度 = min(max(pbr.metallicFactor ?? 1, 0), 1)
                结果.粗糙度 = min(max(pbr.roughnessFactor ?? 1, 0), 1)
                if let 贴图 = 贴图数据(
                    文件.images, 文件.textures, 纹理下标: pbr.baseColorTexture?.index,
                    视图表: 文件.bufferViews, 缓冲: 缓冲数据, 目录: 目录
                ) {
                    结果.基础色贴图 = 贴图.数据
                    结果.基础色贴图名 = 贴图.名
                }
            }
            if let e = 材.emissiveFactor, e.count >= 3 {
                结果.自发光 = SIMD3(e[0], e[1], e[2])
            }
            结果.双面 = 材.doubleSided ?? true
            场景.材质.append(结果)
        }
        if 场景.材质.isEmpty { 场景.材质.append(导入材质()) }

        // 访问器读取
        func 读访问器(_ 下标: Int) throws -> (值: [Float], 每项分量: Int, 数量: Int) {
            guard let 表 = 文件.accessors, 下标 >= 0, 下标 < 表.count else {
                throw 导入导出错误.解析失败(格式: "glTF", 原因: "accessor \(下标) 越界")
            }
            let acc = 表[下标]
            let 分量: Int
            switch acc.type {
            case "SCALAR": 分量 = 1
            case "VEC2": 分量 = 2
            case "VEC3": 分量 = 3
            case "VEC4": 分量 = 4
            case "MAT4": 分量 = 16
            default: 分量 = 1
            }
            guard let bv下标 = acc.bufferView,
                  let 视图表 = 文件.bufferViews, bv下标 >= 0, bv下标 < 视图表.count else {
                return (Array(repeating: 0, count: acc.count * 分量), 分量, acc.count)
            }
            let 视图 = 视图表[bv下标]
            guard 视图.buffer >= 0, 视图.buffer < 缓冲数据.count else {
                throw 导入导出错误.解析失败(格式: "glTF", 原因: "bufferView 指向的 buffer 不存在")
            }
            let 数据 = 缓冲数据[视图.buffer]
            let 每项字节 = 分量 * 分量字节数(acc.componentType)
            let 步长 = 视图.byteStride ?? 每项字节
            let 基 = (视图.byteOffset ?? 0) + (acc.byteOffset ?? 0)
            guard 基 >= 0, 每项字节 > 0 else { return ([], 分量, 0) }

            var 输出 = [Float](repeating: 0, count: acc.count * 分量)
            数据.withUnsafeBytes { 原始 in
                for i in 0..<acc.count {
                    let 起 = 基 + i * 步长
                    if 起 + 每项字节 > 原始.count { break }
                    for c in 0..<分量 {
                        let 偏移 = 起 + c * 分量字节数(acc.componentType)
                        输出[i * 分量 + c] = 读分量(原始, 偏移, acc.componentType, acc.normalized ?? false)
                    }
                }
            }
            return (输出, 分量, acc.count)
        }

        func 读索引(_ 下标: Int) throws -> [UInt32] {
            guard let acc = 文件.accessors?[下标], let bv下标 = acc.bufferView,
                  let 视图 = 文件.bufferViews?[bv下标], 视图.buffer < 缓冲数据.count else { return [] }
            let 数据 = 缓冲数据[视图.buffer]
            let 每项 = 分量字节数(acc.componentType)
            let 步长 = 视图.byteStride ?? 每项
            let 基 = (视图.byteOffset ?? 0) + (acc.byteOffset ?? 0)
            var 输出: [UInt32] = []
            输出.reserveCapacity(acc.count)
            数据.withUnsafeBytes { 原始 in
                for i in 0..<acc.count {
                    let 起 = 基 + i * 步长
                    if 起 + 每项 > 原始.count { break }
                    输出.append(UInt32(max(读分量(原始, 起, acc.componentType, false), 0)))
                }
            }
            return 输出
        }

        let 节点表 = 文件.nodes ?? []
        var 已访问 = Set<Int>()
        var 网格节点数 = 0

        func 遍历(_ 下标: Int, 父变换: simd_float4x4) {
            guard 下标 >= 0, 下标 < 节点表.count, !已访问.contains(下标) else { return }
            已访问.insert(下标)
            let 节 = 节点表[下标]
            let 世界 = 父变换 * 局部变换(节)

            if let 网格下标 = 节.mesh, let 网格表 = 文件.meshes,
               网格下标 >= 0, 网格下标 < 网格表.count {
                let 定义 = 网格表[网格下标]
                网格节点数 += 1
                for (pi, 图) in 定义.primitives.enumerated() {
                    let 模式 = 图.mode ?? 4
                    guard 模式 == 4 || 模式 == 5 || 模式 == 6 else {
                        场景.报告.append("跳过非三角图元（mode=\(模式)）")
                        continue
                    }
                    do {
                        var 网格 = try 组装图元(
                            图,
                            名称: 定义.name ?? 节.name ?? "网格\(网格下标)-\(pi)",
                            读访问器: 读访问器,
                            读索引: 读索引
                        )
                        网格.变换 = 世界 * 网格.变换
                        场景.网格.append(网格)
                    } catch {
                        场景.报告.append("图元 \(pi) 组装失败：\(error.localizedDescription)")
                    }
                }
            }

            for 子 in 节.children ?? [] { 遍历(子, 父变换: 世界) }
        }

        if let 场景表 = 文件.scenes, !场景表.isEmpty {
            let 采用 = 场景表.indices.contains(文件.scene ?? 0) ? (文件.scene ?? 0) : 0
            for 根 in 场景表[采用].nodes ?? [] { 遍历(根, 父变换: matrix_identity_float4x4) }
        }
        if 场景.网格.isEmpty {
            已访问.removeAll()
            for i in 节点表.indices where 节点表[i].mesh != nil {
                遍历(i, 父变换: matrix_identity_float4x4)
            }
        }

        guard !场景.网格.isEmpty else { throw 导入导出错误.无有效几何(url) }
        场景.报告.insert("glTF \(文件.asset?.version ?? "2.0")：\(场景.网格.count) 个子网格 / \(网格节点数) 个网格节点", at: 0)
        return 场景
    }

    // MARK: 图元组装

    private static func 组装图元(
        _ 图: 图元,
        名称: String,
        读访问器: (Int) throws -> (值: [Float], 每项分量: Int, 数量: Int),
        读索引: (Int) throws -> [UInt32]
    ) throws -> 导入网格 {
        guard let 位置下标 = 图.attributes["POSITION"] else {
            throw 导入导出错误.解析失败(格式: "glTF", 原因: "图元缺少 POSITION 属性")
        }
        var 网格 = 导入网格(名称: 名称)
        let 位置 = try 读访问器(位置下标)
        guard 位置.每项分量 >= 3 else {
            throw 导入导出错误.解析失败(格式: "glTF", 原因: "POSITION 不是 VEC3")
        }
        网格.顶点 = (0..<位置.数量).map { i in
            let b = i * 位置.每项分量
            return SIMD3(位置.值[b], 位置.值[b + 1], 位置.值[b + 2])
        }

        if let 法线下标 = 图.attributes["NORMAL"] {
            let 法线 = try 读访问器(法线下标)
            if 法线.每项分量 >= 3, 法线.数量 == 位置.数量 {
                网格.法线 = (0..<法线.数量).map { i in
                    let b = i * 法线.每项分量
                    return SIMD3(法线.值[b], 法线.值[b + 1], 法线.值[b + 2])
                }
            }
        }
        if let uv下标 = 图.attributes["TEXCOORD_0"] {
            let uv = try 读访问器(uv下标)
            if uv.每项分量 >= 2, uv.数量 == 位置.数量 {
                网格.UV = (0..<uv.数量).map { i in
                    let b = i * uv.每项分量
                    return SIMD2(uv.值[b], uv.值[b + 1])
                }
            }
        }
        网格.对齐属性()

        if let 索引下标 = 图.indices {
            网格.索引 = try 读索引(索引下标)
        } else {
            网格.索引 = (0..<位置.数量).map { UInt32($0) }
        }

        var 净: [UInt32] = []
        净.reserveCapacity(网格.索引.count)
        let 上界 = UInt32(网格.顶点.count)
        var i = 0
        while i + 2 < 网格.索引.count {
            let a = 网格.索引[i], b = 网格.索引[i + 1], c = 网格.索引[i + 2]
            i += 3
            if a < 上界, b < 上界, c < 上界 {
                净.append(a); 净.append(b); 净.append(c)
            }
        }
        网格.索引 = 净
        网格.子集 = [导入子集(材质: 图.material, 起始: 0, 数量: 网格.索引.count)]
        return 网格
    }

    // MARK: 节点变换

    private static func 局部变换(_ 节: 节点) -> simd_float4x4 {
        if let m = 节.matrix, m.count >= 16 {
            return simd_float4x4(columns: (
                SIMD4(m[0], m[1], m[2], m[3]),
                SIMD4(m[4], m[5], m[6], m[7]),
                SIMD4(m[8], m[9], m[10], m[11]),
                SIMD4(m[12], m[13], m[14], m[15])
            ))
        }
        var 平移 = SIMD3<Float>.zero
        var 旋转 = matrix_identity_float3x3
        var 缩放 = SIMD3<Float>(1, 1, 1)
        if let t = 节.translation, t.count >= 3 { 平移 = SIMD3(t[0], t[1], t[2]) }
        if let r = 节.rotation, r.count >= 4 {
            旋转 = simd_float3x3(simd_quatf(ix: r[0], iy: r[1], iz: r[2], r: r[3]))
        }
        if let s = 节.scale, s.count >= 3 { 缩放 = SIMD3(s[0], s[1], s[2]) }

        // M = T · R · S（glTF 规范的 TRS 合成顺序）
        let 线性 = 旋转 * simd_float3x3(SIMD3(缩放.x, 0, 0), SIMD3(0, 缩放.y, 0), SIMD3(0, 0, 缩放.z))
        return simd_float4x4(columns: (
            SIMD4(线性.columns.0, 0),
            SIMD4(线性.columns.1, 0),
            SIMD4(线性.columns.2, 0),
            SIMD4(平移, 1)
        ))
    }

    // MARK: 二进制分量

    private static func 分量字节数(_ 类型: Int) -> Int {
        switch 类型 {
        case 5120, 5121: return 1
        case 5122, 5123: return 2
        case 5125, 5126: return 4
        default: return 4
        }
    }

    private static func 读分量(_ 原始: UnsafeRawBufferPointer, _ 偏移: Int, _ 类型: Int, _ 归一化: Bool) -> Float {
        switch 类型 {
        case 5126:
            return 原始.loadUnaligned(fromByteOffset: 偏移, as: Float.self)
        case 5125:
            return Float(原始.loadUnaligned(fromByteOffset: 偏移, as: UInt32.self))
        case 5123:
            let v = 原始.loadUnaligned(fromByteOffset: 偏移, as: UInt16.self)
            return 归一化 ? Float(v) / 65535 : Float(v)
        case 5122:
            let v = 原始.loadUnaligned(fromByteOffset: 偏移, as: Int16.self)
            return 归一化 ? max(Float(v) / 32767, -1) : Float(v)
        case 5121:
            let v = 原始.loadUnaligned(fromByteOffset: 偏移, as: UInt8.self)
            return 归一化 ? Float(v) / 255 : Float(v)
        case 5120:
            let v = 原始.loadUnaligned(fromByteOffset: 偏移, as: Int8.self)
            return 归一化 ? max(Float(v) / 127, -1) : Float(v)
        default:
            return 0
        }
    }


    // MARK: baseColor 贴图 → 原始字节

    /// 把 glTF 的 baseColorTexture 搬成原始字节（不解码）：
    /// 优先 GLB 内嵌 bufferView，其次 data: URI，最后外部文件。
    /// 主线程入库时再交给贴图库解码登记。
    private static func 贴图数据(
        _ 图像表: [图像定义]?, _ 纹理表: [纹理定义]?, 纹理下标: Int?,
        视图表: [缓冲视图]?, 缓冲: [Data], 目录: URL
    ) -> (数据: Data, 名: String)? {
        guard let 纹 = 纹理下标, 纹 >= 0, 纹 < (纹理表?.count ?? 0),
              let 源 = 纹理表?[纹].source, 源 >= 0, 源 < (图像表?.count ?? 0) else { return nil }
        let 图 = 图像表![源]
        if let uri = 图.uri {
            let 干净 = uri.removingPercentEncoding ?? uri
            if uri.hasPrefix("data:") {
                if let 逗号 = uri.firstIndex(of: ","),
                   let d = Data(base64Encoded: String(uri[uri.index(after: 逗号)...])) {
                    return (d, uri.hasPrefix("data:image/png") ? "内嵌贴图.png" : "内嵌贴图")
                }
                return nil
            }
            let 路径 = 目录.appendingPathComponent(干净)
            guard let d = try? Data(contentsOf: 路径) else { return nil }
            return (d, 路径.lastPathComponent)
        }
        guard let bv = 图.bufferView, bv >= 0, bv < (视图表?.count ?? 0),
              let 视图 = 视图表?[bv], 视图.buffer < 缓冲.count else { return nil }
        let 起 = 视图.byteOffset ?? 0
        let 止 = min(起 + 视图.byteLength, 缓冲[视图.buffer].count)
        guard 止 > 起 else { return nil }
        return (缓冲[视图.buffer][起..<止], "内嵌贴图")
    }
}
