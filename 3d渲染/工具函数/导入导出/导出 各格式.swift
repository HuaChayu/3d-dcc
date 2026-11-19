import Foundation
import simd

// MARK: - glTF / GLB 写出

/// glTF 2.0 写出。GLB 是内部中转格式（粘贴板、节点复制），.gltf+.bin 给人看/给别的工具吃。
enum GLTF导出 {

    // MARK: 内部缓冲拼装

    private struct 缓冲拼装 {
        var 数据 = Data()
        var 视图: [[String: Any]] = []
        var 访问器: [[String: Any]] = []

        /// 追加一段顶点数据，返回 accessor 下标
        mutating func 加属性(_ 分量: [Float], 每项分量: Int, 类型名: String, 目标: Int = 34962, 带包围盒: Bool = false) -> Int {
            // 4 字节对齐：glTF 的 bufferView 偏移必须满足分量大小对齐
            while 数据.count % 4 != 0 { 数据.append(0) }
            let 偏移 = 数据.count
            for v in 分量 {
                var f = v.bitPattern.littleEndian
                withUnsafeBytes(of: &f) { 数据.append(contentsOf: $0) }
            }
            let 长 = 数据.count - 偏移
            视图.append([
                "buffer": 0,
                "byteOffset": 偏移,
                "byteLength": 长,
                "target": 目标
            ])
            let 数量 = 每项分量 > 0 ? 分量.count / 每项分量 : 0
            var acc: [String: Any] = [
                "bufferView": 视图.count - 1,
                "componentType": 5126,
                "count": 数量,
                "type": 类型名
            ]
            if 带包围盒, 每项分量 == 3, 数量 > 0 {
                var 累加 = 包围盒累加()
                for i in 0..<数量 {
                    累加.加(SIMD3(分量[i * 3], 分量[i * 3 + 1], 分量[i * 3 + 2]))
                }
                if let 盒 = 累加.盒 {
                    acc["min"] = [Double(盒.最小.x), Double(盒.最小.y), Double(盒.最小.z)]
                    acc["max"] = [Double(盒.最大.x), Double(盒.最大.y), Double(盒.最大.z)]
                }
            }
            访问器.append(acc)
            return 访问器.count - 1
        }

        mutating func 加索引(_ 索引: [UInt32]) -> Int {
            while 数据.count % 4 != 0 { 数据.append(0) }
            let 偏移 = 数据.count
            for v in 索引 {
                var x = v.littleEndian
                withUnsafeBytes(of: &x) { 数据.append(contentsOf: $0) }
            }
            视图.append([
                "buffer": 0,
                "byteOffset": 偏移,
                "byteLength": 数据.count - 偏移,
                "target": 34963
            ])
            访问器.append([
                "bufferView": 视图.count - 1,
                "componentType": 5125,
                "count": 索引.count,
                "type": "SCALAR"
            ])
            return 访问器.count - 1
        }
    }

    // MARK: 组装文档

    private static func 组装文档(片段: [导入网格], 材质: [导入材质]) -> (JSON: [String: Any], BIN: Data) {
        var 缓冲 = 缓冲拼装()
        var 网格项: [[String: Any]] = []
        var 节点项: [[String: Any]] = []

        for 片 in 片段 {
            var 局部 = 片
            局部.对齐属性()
            guard !局部.索引.isEmpty, !局部.顶点.isEmpty else { continue }

            let 位置 = 缓冲.加属性(局部.顶点.flatMap { [ $0.x, $0.y, $0.z ] }, 每项分量: 3, 类型名: "VEC3", 带包围盒: true)
            let 法线 = 缓冲.加属性(局部.法线.flatMap { [ $0.x, $0.y, $0.z ] }, 每项分量: 3, 类型名: "VEC3")
            let uv = 缓冲.加属性(局部.UV.flatMap { [ $0.x, $0.y ] }, 每项分量: 2, 类型名: "VEC2")
            let 索引 = 缓冲.加索引(局部.索引)

            let 属性: [String: Any] = [
                "POSITION": 位置,
                "NORMAL": 法线,
                "TEXCOORD_0": uv
            ]
            var 图元: [String: Any] = [
                "attributes": 属性,
                "indices": 索引,
                "mode": 4
            ]
            if let 材质下标 = 局部.子集.first?.材质, 材质下标 >= 0, 材质下标 < 材质.count {
                图元["material"] = 材质下标
            }

            网格项.append([
                "name": 局部.名称,
                "primitives": [图元]
            ])

            let m = 局部.变换
            节点项.append([
                "name": 局部.名称,
                "mesh": 网格项.count - 1,
                "matrix": [
                    Double(m.columns.0.x), Double(m.columns.0.y), Double(m.columns.0.z), Double(m.columns.0.w),
                    Double(m.columns.1.x), Double(m.columns.1.y), Double(m.columns.1.z), Double(m.columns.1.w),
                    Double(m.columns.2.x), Double(m.columns.2.y), Double(m.columns.2.z), Double(m.columns.2.w),
                    Double(m.columns.3.x), Double(m.columns.3.y), Double(m.columns.3.z), Double(m.columns.3.w)
                ]
            ])
        }

        // 材质：glTF 的 baseColorFactor 是线性值，正好我们内部也是线性，不用转
        let 材质项: [[String: Any]] = 材质.map { 材 in
            [
                "name": 材.名称,
                "pbrMetallicRoughness": [
                    "baseColorFactor": [
                        Double(材.基础色.x), Double(材.基础色.y), Double(材.基础色.z), Double(材.不透明度)
                    ],
                    "metallicFactor": Double(材.金属度),
                    "roughnessFactor": Double(材.粗糙度)
                ],
                "emissiveFactor": [Double(材.自发光.x), Double(材.自发光.y), Double(材.自发光.z)],
                "doubleSided": 材.双面
            ]
        }

        var 文档: [String: Any] = [
            "asset": ["version": "2.0", "generator": "3d渲染 通用导出"],
            "scene": 0,
            "scenes": [["name": "Scene", "nodes": Array(0..<节点项.count)]],
            "nodes": 节点项,
            "meshes": 网格项,
            "bufferViews": 缓冲.视图,
            "accessors": 缓冲.访问器,
            "buffers": [["byteLength": (缓冲.数据.count + 3) / 4 * 4]]
        ]
        if !材质项.isEmpty { 文档["materials"] = 材质项 }
        return (文档, 缓冲.数据)
    }

    // MARK: GLB

    static func 写出GLB(片段: [导入网格], 材质: [导入材质], 到 目标: URL) throws {
        let (文档, 二进制) = 组装文档(片段: 片段, 材质: 材质)
        guard !二进制.isEmpty else { throw 导入导出错误.导出失败("没有可导出的三角网格") }

        var json = try JSONSerialization.data(withJSONObject: 文档, options: [.sortedKeys])
        // JSON chunk 用空格补齐，BIN chunk 用 0 补齐（规范要求）
        while json.count % 4 != 0 { json.append(0x20) }
        var bin = 二进制
        while bin.count % 4 != 0 { bin.append(0) }

        var 文件 = Data()
        字节.追加(&文件, UInt32(0x46546C67))                       // "glTF"
        字节.追加(&文件, UInt32(2))
        字节.追加(&文件, UInt32(12 + 8 + json.count + 8 + bin.count))
        字节.追加(&文件, UInt32(json.count))
        字节.追加(&文件, UInt32(0x4E4F534A))                       // "JSON"
        文件.append(json)
        字节.追加(&文件, UInt32(bin.count))
        字节.追加(&文件, UInt32(0x004E4942))                       // "BIN\0"
        文件.append(bin)

        do {
            try 文件.write(to: 目标)
        } catch {
            throw 导入导出错误.导出失败("写入 GLB 失败：\(error.localizedDescription)")
        }
    }

    // MARK: .gltf + .bin

    static func 写出GLTF(片段: [导入网格], 材质: [导入材质], 到 目标: URL) throws {
        var (文档, 二进制) = 组装文档(片段: 片段, 材质: 材质)
        guard !二进制.isEmpty else { throw 导入导出错误.导出失败("没有可导出的三角网格") }

        let bin名 = 目标.deletingPathExtension().lastPathComponent + ".bin"
        let bin路径 = 目标.deletingLastPathComponent().appendingPathComponent(bin名)
        文档["buffers"] = [["byteLength": 二进制.count, "uri": bin名]]

        while 二进制.count % 4 != 0 { 二进制.append(0) }
        do {
            try 二进制.write(to: bin路径)
            let json = try JSONSerialization.data(withJSONObject: 文档, options: [.prettyPrinted, .sortedKeys])
            try json.write(to: 目标)
        } catch {
            throw 导入导出错误.导出失败("写入 glTF 失败：\(error.localizedDescription)")
        }
    }
}

// MARK: - 文本格式导出

enum 纯文本导出 {

    /// OBJ 只表达「位置 + 法线 + UV + 三角面」，材质要另配 mtl
    static func 写出OBJ(片段: [导入网格], 材质: [导入材质], 到 目标: URL) throws {
        var 行: [String] = ["# 由 3d渲染 导出"]
        var 顶点偏移 = 1
        var 法线偏移 = 1
        var uv偏移 = 1
        var mtl名 = 目标.deletingPathExtension().lastPathComponent + ".mtl"
        var 使用材质 = false

        行.append("mtllib \(mtl名)")

        for 片 in 片段 {
            var 局部 = 片
            局部.对齐属性()
            guard !局部.索引.isEmpty else { continue }
            行.append("o \(清理名(局部.名称))")
            for v in 局部.顶点 {
                行.append(String(format: "v %.6f %.6f %.6f", v.x, v.y, v.z))
            }
            for n in 局部.法线 {
                行.append(String(format: "vn %.6f %.6f %.6f", n.x, n.y, n.z))
            }
            for t in 局部.UV {
                行.append(String(format: "vt %.6f %.6f", t.x, t.y))
            }
            var 用名 = 局部.子集.first?.材质名
            if 用名 == nil, let 下标 = 局部.子集.first?.材质, 材质.indices.contains(下标) {
                用名 = 材质[下标].名称
            }
            if let 用名 {
                行.append("usemtl \(清理名(用名))")
                使用材质 = true
            }
            var i = 0
            while i + 2 < 局部.索引.count {
                let a = Int(局部.索引[i]) + 顶点偏移
                let b = Int(局部.索引[i + 1]) + 顶点偏移
                let c = Int(局部.索引[i + 2]) + 顶点偏移
                let na = Int(局部.索引[i]) + 法线偏移
                let nb = Int(局部.索引[i + 1]) + 法线偏移
                let nc = Int(局部.索引[i + 2]) + 法线偏移
                let ta = Int(局部.索引[i]) + uv偏移
                let tb = Int(局部.索引[i + 1]) + uv偏移
                let tc = Int(局部.索引[i + 2]) + uv偏移
                行.append("f \(a)/\(ta)/\(na) \(b)/\(tb)/\(nb) \(c)/\(tc)/\(nc)")
                i += 3
            }
            顶点偏移 += 局部.顶点.count
            法线偏移 += 局部.法线.count
            uv偏移 += 局部.UV.count
        }

        do {
            try 行.joined(separator: "\n").appending("\n").write(to: 目标, atomically: true, encoding: .utf8)
            if 使用材质 {
                let mtl = 材质.map { 材 -> String in
                    let kd = 线性转sRGB(材.基础色)
                    return """
                    newmtl \(清理名(材.名称))
                    Kd \(String(format: "%.6f", kd.x)) \(String(format: "%.6f", kd.y)) \(String(format: "%.6f", kd.z))
                    Ks 0 0 0
                    Ns \(String(format: "%.2f", max(2, 1000 * (1 - 材.粗糙度))))
                    d \(String(format: "%.4f", 材.不透明度))

                    """
                }.joined()
                let mtl路径 = 目标.deletingLastPathComponent().appendingPathComponent(目标.deletingPathExtension().lastPathComponent + ".mtl")
                try mtl.write(to: mtl路径, atomically: true, encoding: .utf8)
            }
        } catch {
            throw 导入导出错误.导出失败("写入 OBJ 失败：\(error.localizedDescription)")
        }
    }

    /// STL 无材质无 UV，只有三角面 + 法线。默认写二进制（体积小、被 CAD 工具认）
    static func 写出STL(片段: [导入网格], 到 目标: URL, 二进制: Bool = true) throws {
        var 三角形: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = []
        for 片 in 片段 {
            var 局部 = 片
            局部.对齐属性()
            var i = 0
            while i + 2 < 局部.索引.count {
                let a = Int(局部.索引[i]), b = Int(局部.索引[i + 1]), c = Int(局部.索引[i + 2])
                i += 3
                guard a < 局部.顶点.count, b < 局部.顶点.count, c < 局部.顶点.count else { continue }
                let p0 = 局部.顶点[a], p1 = 局部.顶点[b], p2 = 局部.顶点[c]
                let n = 三角几何.法线(p0, p1, p2)
                三角形.append((n, p0, p1, p2))
            }
        }
        guard !三角形.isEmpty else { throw 导入导出错误.导出失败("没有可导出的三角面") }

        if 二进制 {
            var 数据 = Data(repeating: 0, count: 80)
            字节.追加(&数据, UInt32(三角形.count))
            for t in 三角形 {
                for v in [t.0, t.1, t.2, t.3] as [SIMD3<Float>] {
                    for f in [v.x, v.y, v.z] as [Float] {
                        字节.追加(&数据, f)
                    }
                }
                数据.append(0); 数据.append(0)
            }
            try? 数据.write(to: 目标)
        } else {
            var 行 = ["solid 3d渲染"]
            for t in 三角形 {
                行.append(String(format: "facet normal %.6f %.6f %.6f", t.0.x, t.0.y, t.0.z))
                行.append("  outer loop")
                for v in [t.1, t.2, t.3] {
                    行.append(String(format: "    vertex %.6f %.6f %.6f", v.x, v.y, v.z))
                }
                行.append("  endloop")
                行.append("endfacet")
            }
            行.append("endsolid 3d渲染")
            try 行.joined(separator: "\n").write(to: 目标, atomically: true, encoding: .utf8)
        }
    }

    /// PLY 二进制小端，带法线
    static func 写出PLY(片段: [导入网格], 到 目标: URL) throws {
        var 顶点: [SIMD3<Float>] = []
        var 法线: [SIMD3<Float>] = []
        var 面: [[Int]] = []
        for 片 in 片段 {
            var 局部 = 片
            局部.对齐属性()
            let 偏移 = 顶点.count
            顶点.append(contentsOf: 局部.顶点)
            法线.append(contentsOf: 局部.法线)
            var i = 0
            while i + 2 < 局部.索引.count {
                面.append([
                    Int(局部.索引[i]) + 偏移,
                    Int(局部.索引[i + 1]) + 偏移,
                    Int(局部.索引[i + 2]) + 偏移
                ])
                i += 3
            }
        }
        guard !顶点.isEmpty else { throw 导入导出错误.导出失败("没有可导出的顶点") }

        let 头 = """
        ply
        format binary_little_endian 1.0
        comment exported by 3d render
        element vertex \(顶点.count)
        property float x
        property float y
        property float z
        property float nx
        property float ny
        property float nz
        element face \(面.count)
        property list uchar int vertex_indices
        end_header
        """
        var 数据 = Data()
        数据.append(头.data(using: .utf8) ?? Data())
        for i in 顶点.indices {
            for f in [顶点[i].x, 顶点[i].y, 顶点[i].z, 法线[i].x, 法线[i].y, 法线[i].z] as [Float] {
                字节.追加(&数据, f)
            }
        }
        for f in 面 {
            数据.append(3)
            for idx in f {
                字节.追加(&数据, Int32(idx))
            }
        }
        do {
            try 数据.write(to: 目标)
        } catch {
            throw 导入导出错误.导出失败("写入 PLY 失败：\(error.localizedDescription)")
        }
    }

    /// usda 文本导出。不写 usdc（那要 USD 的二进制 crate 编码器，暂不支持）
    static func 写出USDA(片段: [导入网格], 材质: [导入材质], 到 目标: URL, 上轴: 上轴 = .y) throws {
        var 行: [String] = [
            "#usda 1.0",
            "(",
            "    defaultPrim = \"\(清理名(目标.deletingPathExtension().lastPathComponent))\"",
            "    metersPerUnit = 1",
            "    upAxis = \"\(上轴 == .y ? "Y" : "Z")\"",
            ")",
            "",
            "def Xform \"\(清理名(目标.deletingPathExtension().lastPathComponent))\"",
            "{"
        ]

        for (i, 片) in 片段.enumerated() {
            var 局部 = 片
            局部.对齐属性()
            // Z 向上由本函数自己转，调用方（导出调度）对 usda 不再预翻转
            if 上轴 == .z {
                局部.施加变换(网格变换.y转z)
                局部.烘焙变换()
            }
            guard !局部.索引.isEmpty else { continue }
            let 名 = 清理名(局部.名称.isEmpty ? "Mesh\(i)" : 局部.名称)

            // 面索引：usda 用 faceVertexCounts / faceVertexIndices
            var 计数: [Int] = []
            var 索引: [Int] = []
            var j = 0
            while j + 2 < 局部.索引.count {
                计数.append(3)
                索引.append(Int(局部.索引[j]))
                索引.append(Int(局部.索引[j + 1]))
                索引.append(Int(局部.索引[j + 2]))
                j += 3
            }

            let m = 局部.变换
            行.append("    def Mesh \"\(名)\"")
            行.append("    {")
            if m != matrix_identity_float4x4 {
                行.append("        matrix4d xformOp:transform = ("
                    + String(format: "(%.6f, %.6f, %.6f, 0)", m.columns.0.x, m.columns.0.y, m.columns.0.z)
                    + String(format: ", (%.6f, %.6f, %.6f, 0)", m.columns.1.x, m.columns.1.y, m.columns.1.z)
                    + String(format: ", (%.6f, %.6f, %.6f, 0)", m.columns.2.x, m.columns.2.y, m.columns.2.z)
                    + String(format: ", (%.6f, %.6f, %.6f, 1)", m.columns.3.x, m.columns.3.y, m.columns.3.z)
                    + ")")
                行.append("        uniform token[] xformOpOrder = [\"xformOp:transform\"]")
            }
            行.append("        int[] faceVertexCounts = [\(计数.map(String.init).joined(separator: ", "))]")
            行.append("        int[] faceVertexIndices = [\(索引.map(String.init).joined(separator: ", "))]")
            let 点串 = 局部.顶点.map { String(format: "(%.6f, %.6f, %.6f)", $0.x, $0.y, $0.z) }.joined(separator: ", ")
            行.append("        point3f[] points = [\(点串)]")
            if 局部.法线.count == 局部.顶点.count {
                let 法串 = 局部.法线.map { String(format: "(%.6f, %.6f, %.6f)", $0.x, $0.y, $0.z) }.joined(separator: ", ")
                行.append("        normal3f[] primvars:normals = [\(法串)] (")
                行.append("            interpolation = \"vertex\"")
                行.append("        )")
            }
            if 局部.UV.count == 局部.顶点.count, 局部.UV.contains(where: { $0 != .zero }) {
                let uv串 = 局部.UV.map { String(format: "(%.6f, %.6f)", $0.x, $0.y) }.joined(separator: ", ")
                行.append("        texCoord2f[] primvars:st = [\(uv串)] (")
                行.append("            interpolation = \"vertex\"")
                行.append("        )")
            }
            行.append("    }")
        }

        行.append("}")
        do {
            try 行.joined(separator: "\n").appending("\n").write(to: 目标, atomically: true, encoding: .utf8)
        } catch {
            throw 导入导出错误.导出失败("写入 usda 失败：\(error.localizedDescription)")
        }
    }

    // MARK: 小工具

    /// OBJ / usda 的名字里不能有空格与斜杠
    private static func 清理名(_ 原: String) -> String {
        文件名清理.替换非法字符(原, 禁: CharacterSet(charactersIn: " /\\\t\n\"'<>:|*?"), 兜底: "mesh")
    }

    private static func 线性转sRGB(_ c: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(
            c.x <= 0.0031308 ? c.x * 12.92 : 1.055 * pow(max(c.x, 0), 1 / 2.4) - 0.055,
            c.y <= 0.0031308 ? c.y * 12.92 : 1.055 * pow(max(c.y, 0), 1 / 2.4) - 0.055,
            c.z <= 0.0031308 ? c.z * 12.92 : 1.055 * pow(max(c.z, 0), 1 / 2.4) - 0.055
        )
    }
}
