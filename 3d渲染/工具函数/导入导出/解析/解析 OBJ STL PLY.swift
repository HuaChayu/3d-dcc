import Foundation
import simd

/// 各原生解析器统一入口签名
protocol 网格格式解析器 {
    static func 解析(url: URL, 设置: 单文件导入设置) throws -> 导入场景
}

/// sRGB → 线性（各格式给的颜色几乎都是 sRGB，App 全线用线性）
@inline(__always) func sRGB转线性(_ c: SIMD3<Float>) -> SIMD3<Float> {
    SIMD3(转线性一条(c.x), 转线性一条(c.y), 转线性一条(c.z))
}

@inline(__always) private func 转线性一条(_ v: Float) -> Float {
    let c = min(max(v, 0), 1)
    return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
}

// MARK: - OBJ

enum OBJ解析: 网格格式解析器 {
    private struct 组合键: Hashable {
        var v: Int
        var t: Int
        var n: Int
    }

    /// 行内记号游标（区间为半开区间 [起, 终)）
    private struct 记号流 {
        let p: UnsafePointer<UInt8>
        let 长度: Int
        var 位置: Int

        @inline(__always) static func 空白(_ b: UInt8) -> Bool {
            b == 0x20 || b == 0x09 || b == 0x0B || b == 0x0C || b == 0x0D
        }

        @inline(__always) mutating func 下一记号() -> (Int, Int)? {
            while 位置 < 长度 && Self.空白(p[位置]) { 位置 += 1 }
            guard 位置 < 长度 else { return nil }
            let 起 = 位置
            while 位置 < 长度 && !Self.空白(p[位置]) { 位置 += 1 }
            return (起, 位置)
        }
    }

    /// 老工具（3ds Max 等）常把组名/材质名写成 GBK，这里三级回退，至少要能对上 MTL 里的名字
    @inline(__always) private static func 字符串(_ p: UnsafePointer<UInt8>, _ 起: Int, _ 终: Int) -> String {
        let 字节 = UnsafeBufferPointer(start: p + 起, count: max(0, 终 - 起))
        if let s = String(bytes: 字节, encoding: .utf8) { return s }
        let gb = CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        if let s = String(bytes: 字节, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(gb))) {
            return s
        }
        return String(decoding: 字节, as: UTF8.self)
    }

    @inline(__always) private static func 整数(_ p: UnsafePointer<UInt8>, _ 起: Int, _ 终: Int) -> Int? {
        var i = 起
        var 负 = false
        if i < 终, p[i] == 0x2B || p[i] == 0x2D {
            负 = p[i] == 0x2D
            i += 1
        }
        guard i < 终 else { return nil }
        var v = 0
        while i < 终 {
            let d = Int(p[i]) - 48
            guard d >= 0, d <= 9 else { return nil }
            v = v * 10 + d
            i += 1
        }
        return 负 ? -v : v
    }

    /// 手写浮点解析：不碰 Locale、不建临时字符串，95MB 级别才跑得动
    @inline(__always) private static func 浮点(_ p: UnsafePointer<UInt8>, _ 起: Int, _ 终: Int) -> Float? {
        var i = 起
        var 负 = false
        if i < 终, p[i] == 0x2B || p[i] == 0x2D {
            负 = p[i] == 0x2D
            i += 1
        }
        var 值 = 0.0
        var 有数字 = false
        while i < 终 {
            let d = Int(p[i]) - 48
            guard d >= 0, d <= 9 else { break }
            值 = 值 * 10 + Double(d)
            有数字 = true
            i += 1
        }
        if i < 终, p[i] == 0x2E {
            i += 1
            var 位 = 0.1
            while i < 终 {
                let d = Int(p[i]) - 48
                guard d >= 0, d <= 9 else { break }
                值 += Double(d) * 位
                位 *= 0.1
                有数字 = true
                i += 1
            }
        }
        guard 有数字 else { return nil }
        if i < 终, p[i] == 0x65 || p[i] == 0x45 {
            i += 1
            var 指负 = false
            if i < 终, p[i] == 0x2B || p[i] == 0x2D {
                指负 = p[i] == 0x2D
                i += 1
            }
            var 指 = 0
            var 有指 = false
            while i < 终 {
                let d = Int(p[i]) - 48
                guard d >= 0, d <= 9 else { break }
                指 = 指 * 10 + d
                有指 = true
                i += 1
            }
            guard 有指 else { return nil }
            值 *= pow(10.0, 指负 ? -Double(指) : Double(指))
        }
        return Float(负 ? -值 : 值)
    }

    static func 解析(url: URL, 设置: 单文件导入设置) throws -> 导入场景 {
        // 大文件必须按字节扫：Foundation 的 String 以「字 Grapheme 簇」为单位，
        // 用 String 切行 + 切记号时整份文件要跑几百万次 Unicode 分段，
        // 95MB / 150 万顶点 / 50 万面这种真实模型几分钟到几十分钟都跑不完。
        guard let 数据 = try? Data(contentsOf: url, options: .mappedIfSafe), !数据.isEmpty else {
            throw 导入导出错误.文件不可读(url)
        }
        return try 数据.withUnsafeBytes { (raw: UnsafeRawBufferPointer) throws -> 导入场景 in
            guard let 基址 = raw.bindMemory(to: UInt8.self).baseAddress else {
                throw 导入导出错误.文件不可读(url)
            }
            return try 扫描(基址: 基址, 长度: raw.count, url: url, 设置: 设置)
        }
    }

    private static func 扫描(
        基址 p: UnsafePointer<UInt8>,
        长度 n: Int,
        url: URL,
        设置: 单文件导入设置
    ) throws -> 导入场景 {
        var 场景 = 导入场景(源文件: url)
        var 位置表: [SIMD3<Float>] = []
        var UV表: [SIMD2<Float>] = []
        var 法线表: [SIMD3<Float>] = []

        var MTL字典: [String: 导入材质] = [:]
        var 材质下标表: [String: Int] = [:]

        /// 一个 (组, 材质) 组合一份网格，落地时再按参数决定是否合并
        var 网格表: [String: 导入网格] = [:]
        var 网格顺序: [String] = []
        var 组合缓存: [String: [组合键: UInt32]] = [:]
        var 组材质名: [String: String] = [:]

        var 当前组名 = url.deletingPathExtension().lastPathComponent
        var 当前材质名: String?

        func 键(_ 组: String, _ 材质: String?) -> String { "\(组)\u{1}\(材质 ?? "")" }

        /// 索引归一：OBJ 同时允许「从 1 开始的正索引」和「负数表示从末尾倒数」，
        /// 统一收敛成 0-based 顶点池下标；0、越界一律判为非法。
        func 归一索引(_ raw: Int, 总数: Int) -> Int? {
            guard 总数 > 0 else { return nil }
            let idx = raw < 0 ? 总数 + raw : raw - 1
            return (idx >= 0 && idx < 总数) ? idx : nil
        }

        var 面行数 = 0
        var 面数 = 0
        var 最大边数 = 0
        var 凹面数 = 0
        var 退化面数 = 0
        var 丢弃面数 = 0
        var 坏顶点行 = 0

        // 整份文件的 f 行几乎都是连续同组，把当前网格和去重表保持为「活引用」：
        // 若每个面都从字典取出再写回，写回会触发一次数组写时复制，
        // 150 万顶点的规模下等于把整份顶点数组复制 50 万次。
        var 活键: String?
        var 活网格 = 导入网格(名称: "")
        var 活表: [组合键: UInt32] = [:]

        func 落盘() {
            guard let k = 活键 else { return }
            网格表[k] = 活网格
            组合缓存[k] = 活表
        }

        var i = 0
        // BOM 会粘在第一行第一个记号上（"\u{FEFF}v"），整行指令会识别失败
        if n >= 3, p[0] == 0xEF, p[1] == 0xBB, p[2] == 0xBF { i = 3 }

        while i < n {
            // 换行统一按 \n 或 \r 处理：CRLF 文件的 \r 不会被当成行内容，
            // 也就不会出现「1.5\r 解析成 nil」把整批顶点丢光的老问题
            var 行首 = i
            while 行首 < n, p[行首] == 0x0A || p[行首] == 0x0D { 行首 += 1 }
            guard 行首 < n else { break }
            var 行尾 = 行首
            while 行尾 < n, p[行尾] != 0x0A, p[行尾] != 0x0D { 行尾 += 1 }
            i = 行尾

            var 读 = 记号流(p: p, 长度: 行尾, 位置: 行首)
            guard let 头 = 读.下一记号() else { continue }
            let 头长 = 头.1 - 头.0

            switch p[头.0] {
            case 0x76 where 头长 == 1:            // v
                if let 记 = 读.下一记号(), let 记2 = 读.下一记号(), let 记3 = 读.下一记号(),
                   let x = 浮点(p, 记.0, 记.1), let y = 浮点(p, 记2.0, 记2.1), let z = 浮点(p, 记3.0, 记3.1) {
                    位置表.append(SIMD3(x, y, z))
                } else {
                    // 坏行也必须占位，否则后面所有面索引整体错位，模型会被悄悄拧形
                    位置表.append(.zero)
                    坏顶点行 += 1
                }
            case 0x76 where 头长 == 2 && p[头.0 + 1] == 0x74:   // vt
                let u = 读.下一记号().flatMap { 浮点(p, $0.0, $0.1) } ?? 0
                let v = 读.下一记号().flatMap { 浮点(p, $0.0, $0.1) } ?? 0
                UV表.append(SIMD2(u, v))
            case 0x76 where 头长 == 2 && p[头.0 + 1] == 0x6E:   // vn
                if let 记 = 读.下一记号(), let 记2 = 读.下一记号(), let 记3 = 读.下一记号(),
                   let x = 浮点(p, 记.0, 记.1), let y = 浮点(p, 记2.0, 记2.1), let z = 浮点(p, 记3.0, 记3.1) {
                    法线表.append(SIMD3(x, y, z))
                } else {
                    法线表.append(SIMD3(0, 1, 0))
                }
            case 0x6F, 0x67:                       // o / g：多段合并，只换名字不换网格
                if let 记 = 读.下一记号() { 当前组名 = 字符串(p, 记.0, 记.1) }
            case 0x75 where 头长 == 5:             // usemtl
                if let 记 = 读.下一记号() { 当前材质名 = 字符串(p, 记.0, 记.1) } else { 当前材质名 = nil }
            case 0x6D where 头长 == 6:             // mtllib
                if 设置.读取MTL {
                    let 目录 = url.deletingLastPathComponent()
                    while let 记 = 读.下一记号() {
                        MTL字典.merge(读MTL(目录.appendingPathComponent(字符串(p, 记.0, 记.1))), uniquingKeysWith: { $1 })
                    }
                }
            case 0x66 where 头长 == 1:             // f
                面行数 += 1
                let k = 键(当前组名, 当前材质名)
                if 活键 != k {
                    落盘()
                    if var 已有 = 网格表.removeValue(forKey: k) {
                        if 已有.名称.isEmpty { 已有.名称 = 当前组名 }
                        活网格 = 已有
                        活表 = 组合缓存.removeValue(forKey: k) ?? [:]
                    } else {
                        活网格 = 导入网格(名称: 当前组名)
                        活表 = [:]
                        网格顺序.append(k)
                        if let 名 = 当前材质名 { 组材质名[k] = 名 }
                    }
                    活键 = k
                }

                var 环: [UInt32] = []
                环.reserveCapacity(4)
                var 面合法 = true

                // 整个面要么全部角都合法、要么整面丢弃：只丢个别角会悄悄改变面的形状
                while let 记 = 读.下一记号() {
                    var 场号 = 0
                    var vi: Int?
                    var ti: Int?
                    var ni: Int?
                    var 段非法 = false
                    var 段起 = 记.0
                    var j = 记.0
                    // 四种写法全覆盖：v / v/vt / v//vn / v/vt/vn，空字段即缺省
                    while j <= 记.1 {
                        if j == 记.1 || p[j] == 0x2F {
                            if j > 段起 {
                                let 值 = 整数(p, 段起, j)
                                if 值 == nil { 段非法 = true }
                                switch 场号 {
                                case 0: vi = 值
                                case 1: ti = 值
                                default: ni = 值
                                }
                            }
                            场号 += 1
                            段起 = j + 1
                            if 场号 > 2 { break }
                        }
                        j += 1
                    }

                    guard !段非法, let 原始v = vi, let vIdx = 归一索引(原始v, 总数: 位置表.count) else {
                        面合法 = false
                        break
                    }
                    let tIdx = ti.flatMap { 归一索引($0, 总数: UV表.count) }
                    let nIdx = ni.flatMap { 归一索引($0, 总数: 法线表.count) }
                    if (ti != nil && tIdx == nil) || (ni != nil && nIdx == nil) {
                        面合法 = false
                        break
                    }

                    let 组合 = 组合键(v: vIdx, t: tIdx ?? -1, n: nIdx ?? -1)
                    if let 已存在 = 活表[组合] {
                        环.append(已存在)
                    } else {
                        let 新下标 = UInt32(活网格.顶点.count)
                        活网格.顶点.append(位置表[vIdx])
                        活网格.UV.append(tIdx.map { UV表[$0] } ?? .zero)
                        活网格.法线.append(nIdx.map { 法线表[$0] } ?? SIMD3(0, 1, 0))
                        活表[组合] = 新下标
                        环.append(新下标)
                    }
                }

                if !面合法 || 环.count < 3 {
                    丢弃面数 += 1
                } else if 环.count == 3 {
                    // 三角面占真实模型的绝大多数，走直通路径：只判一次面积是否退化，
                    // 不必为每个面分配耳切那套临时数组
                    let a = 活网格.顶点[Int(环[0])]
                    let b = 活网格.顶点[Int(环[1])]
                    let c = 活网格.顶点[Int(环[2])]
                    let 最小 = simd_min(simd_min(a, b), c)
                    let 最大 = simd_max(simd_max(a, b), c)
                    let 尺度 = max(simd_length(最大 - 最小), 1e-9)
                    if simd_length(simd_cross(b - a, c - a)) <= 尺度 * 尺度 * 1e-9 {
                        退化面数 += 1
                    } else {
                        面数 += 1
                        最大边数 = max(最大边数, 3)
                        活网格.索引.append(环[0])
                        活网格.索引.append(环[1])
                        活网格.索引.append(环[2])
                    }
                } else {
                    // 多边形统一走「凸→扇形、凹→耳切」三角化，n 边面不再被整面丢弃。
                    // 三角化返回的是「环内局部下标」，要映射回顶点池下标。
                    // 注意：过了这一步就只剩三角形，面边界与「面 → 三角」映射在这里丢失（详见 导入网格.三角化多边形 的说明）。
                    var 环点: [SIMD3<Float>] = []
                    环点.reserveCapacity(环.count)
                    for 角 in 环 { 环点.append(活网格.顶点[Int(角)]) }
                    let 结果 = 导入网格.三角化多边形(环点)
                    if 结果.退化 {
                        退化面数 += 1
                    } else {
                        面数 += 1
                        最大边数 = max(最大边数, 环.count)
                        if 结果.凹 { 凹面数 += 1 }
                        var t = 0
                        while t + 2 < 结果.索引.count {
                            活网格.索引.append(环[结果.索引[t]])
                            活网格.索引.append(环[结果.索引[t + 1]])
                            活网格.索引.append(环[结果.索引[t + 2]])
                            t += 3
                        }
                    }
                }
            default:
                break
            }
        }

        // 收尾：把最后一个「活」网格写回字典
        落盘()

        for k in 网格顺序 {
            guard var 网格 = 网格表[k], !网格.索引.isEmpty else { continue }
            var 材质下标: Int?
            if let 材质名 = 组材质名[k] {
                if let 已有 = 材质下标表[材质名] {
                    材质下标 = 已有
                } else {
                    var 材质 = MTL字典[材质名] ?? 导入材质(名称: 材质名)
                    材质.名称 = 材质名
                    材质下标 = 场景.材质.count
                    材质下标表[材质名] = 场景.材质.count
                    场景.材质.append(材质)
                }
            }
            网格.子集 = [导入子集(材质: 材质下标, 起始: 0, 数量: 网格.索引.count)]
            网格.对齐属性()
            if 设置.重算法线 || 网格.法线.allSatisfy({ $0 == SIMD3(0, 1, 0) }) {
                网格.重算法线()
            }
            场景.网格.append(网格)
        }

        guard !场景.网格.isEmpty else {
            // 只有 v 没有可用 f 的模型（点云 / 扫描件）要给准确原因，不能笼统报"没有三角网格"
            if 位置表.isEmpty {
                throw 导入导出错误.解析失败(
                    格式: "OBJ",
                    原因: "没有解析出任何顶点（v），文件可能不是 OBJ 文本或编码异常"
                )
            }
            if 面行数 == 0 {
                throw 导入导出错误.解析失败(
                    格式: "OBJ",
                    原因: "该文件只有 \(位置表.count) 个顶点，不含任何面数据（f）——属点云，暂不支持渲染"
                )
            }
            throw 导入导出错误.解析失败(
                格式: "OBJ",
                原因: "共 \(面行数) 行面数据，但三角化后没有可用三角面（索引非法丢弃 \(丢弃面数) 面 / 退化面 \(退化面数) 面）"
            )
        }
        if 坏顶点行 > 0 {
            场景.报告.append("警告：\(坏顶点行) 行顶点数据无法解析，已置零占位以免后续索引错位")
        }
        if 面行数 > 0 {
            场景.报告.append(
                "面 \(面行数) 行：三角化成功 \(面数)（其中凹多边形 \(凹面数) 面，最大边数 \(最大边数)），"
                + "退化跳过 \(退化面数)，索引非法丢弃 \(丢弃面数)"
            )
        }
        if 场景.材质.isEmpty { 场景.材质.append(导入材质()) }
        if !MTL字典.isEmpty { 场景.报告.append("读取到 \(MTL字典.count) 个 MTL 材质") }
        return 场景
    }

    /// MTL 只取能映射到 OpenPBR 的几项，其余留给用户手动调
    static func 读MTL(_ url: URL) -> [String: 导入材质] {
        // 编码与换行都要和 OBJ 主体保持一致：CRLF 的 MTL 若留着行尾 "\r"，
        // 材质名会变成 "材质名\r"，与 f 段里的名字对不上，材质全部落到默认
        guard let 原始 = (try? String(contentsOf: url, encoding: .utf8))
                ?? (try? String(contentsOf: url, encoding: .isoLatin1)) else { return [:] }
        let 文本 = 原始.first == "\u{FEFF}" ? String(原始.dropFirst()) : 原始
        var 结果: [String: 导入材质] = [:]
        var 当前 = "默认材质"
        for 行 in 文本.split(omittingEmptySubsequences: true, whereSeparator: { $0.isNewline }) {
            let 片段 = 行.split(omittingEmptySubsequences: true, whereSeparator: { $0.isWhitespace })
            guard let 头 = 片段.first else { continue }
            if 结果[当前] == nil && 头 != "newmtl" { continue }
            switch 头 {
            case "newmtl":
                当前 = 片段.count > 1 ? String(片段[1]) : 当前
                if 结果[当前] == nil { 结果[当前] = 导入材质(名称: 当前) }
            case "Kd" where 片段.count >= 4:
                let c = SIMD3(Float(片段[1]) ?? 0.7, Float(片段[2]) ?? 0.7, Float(片段[3]) ?? 0.7)
                结果[当前, default: 导入材质(名称: 当前)].基础色 = sRGB转线性(c)
            case "Ke" where 片段.count >= 4:
                let c = SIMD3(Float(片段[1]) ?? 0, Float(片段[2]) ?? 0, Float(片段[3]) ?? 0)
                结果[当前, default: 导入材质(名称: 当前)].自发光 = sRGB转线性(c)
            case "Ns" where 片段.count >= 2:
                // MTL 的 Ns 是 0~1000 的镜面指数，粗糙度按经验反比映射
                let ns = max(Float(片段[1]) ?? 50, 1)
                结果[当前, default: 导入材质(名称: 当前)].粗糙度 = min(max(1 - sqrt(ns / 1000), 0.03), 1)
            case "d" where 片段.count >= 2:
                let d = Float(片段[1]) ?? 1
                结果[当前, default: 导入材质(名称: 当前)].不透明度 = min(max(d, 0), 1)
            case "Tr" where 片段.count >= 2:
                let d = Float(片段[1]) ?? 0
                结果[当前, default: 导入材质(名称: 当前)].不透明度 = min(max(1 - d, 0), 1)
            case "map_Kd" where 片段.count >= 2:
                // 贴图路径可能带空格，把整行剩下的都拼回去
                let 原 = 片段.dropFirst().map(String.init).joined(separator: " ")
                let 路径 = url.deletingLastPathComponent()
                    .appendingPathComponent(原.replacingOccurrences(of: "\\", with: "/"))
                if let d = try? Data(contentsOf: 路径) {
                    结果[当前, default: 导入材质(名称: 当前)].基础色贴图 = d
                    结果[当前, default: 导入材质(名称: 当前)].基础色贴图名 = 路径.lastPathComponent
                }
            default:
                break
            }
        }
        return 结果
    }
}

// MARK: - STL

enum STL解析: 网格格式解析器 {
    static func 解析(url: URL, 设置: 单文件导入设置) throws -> 导入场景 {
        guard let 数据 = try? Data(contentsOf: url) else {
            throw 导入导出错误.文件不可读(url)
        }
        var 场景 = 导入场景(源文件: url)
        var 网格 = 导入网格(名称: url.deletingPathExtension().lastPathComponent)

        let 面数 = 数据.count >= 84
            ? Int(UInt32(littleEndian: 数据[80..<84].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }))
            : -1

        if 面数 > 0, 84 + 面数 * 50 == 数据.count {
            网格.顶点.reserveCapacity(面数 * 3)
            网格.索引.reserveCapacity(面数 * 3)
            数据.withUnsafeBytes { 原始 in
                for f in 0..<面数 {
                    let 基 = 84 + f * 50 + 12   // 跳过每面自带的法线，统一重算
                    for k in 0..<3 {
                        let 偏移 = 基 + k * 12
                        let x = 原始.loadUnaligned(fromByteOffset: 偏移, as: Float.self)
                        let y = 原始.loadUnaligned(fromByteOffset: 偏移 + 4, as: Float.self)
                        let z = 原始.loadUnaligned(fromByteOffset: 偏移 + 8, as: Float.self)
                        网格.顶点.append(SIMD3(x, y, z))
                        网格.索引.append(UInt32(网格.顶点.count - 1))
                    }
                }
            }
            网格.对齐属性()
            网格.重算法线()
            场景.报告.append("二进制 STL：\(面数) 个三角形")
        } else if let 文本 = try? String(contentsOf: url, encoding: .utf8) {
            var 当前法线 = SIMD3<Float>(0, 1, 0)
            // CRLF 文件必须按任意换行符切：只切 "\n" 会让行尾 "\r" 粘在最后一个数值上
            for 行 in 文本.split(omittingEmptySubsequences: true, whereSeparator: { $0.isNewline }) {
                let 片段 = 行.split(separator: " ", omittingEmptySubsequences: true)
                guard let 头 = 片段.first else { continue }
                if 头 == "facet", 片段.count >= 5, 片段[1] == "normal" {
                    当前法线 = SIMD3(Float(片段[2]) ?? 0, Float(片段[3]) ?? 0, Float(片段[4]) ?? 1)
                } else if 头 == "vertex", 片段.count >= 4 {
                    网格.顶点.append(SIMD3(Float(片段[1]) ?? 0, Float(片段[2]) ?? 0, Float(片段[3]) ?? 0))
                    网格.法线.append(当前法线)
                    网格.索引.append(UInt32(网格.顶点.count - 1))
                }
            }
            网格.对齐属性()
            场景.报告.append("ASCII STL：\(网格.三角形数) 个三角形")
        } else {
            throw 导入导出错误.解析失败(格式: "STL", 原因: "既不是合法二进制也不是 UTF-8 文本")
        }

        guard !网格.索引.isEmpty else { throw 导入导出错误.无有效几何(url) }
        网格.子集 = [导入子集(材质: nil, 起始: 0, 数量: 网格.索引.count)]
        场景.网格 = [网格]
        场景.材质 = [导入材质(名称: "STL 默认")]
        return 场景
    }
}

// MARK: - PLY

enum PLY类型: String {
    case char, uchar, short, ushort, int, uint, float, double
    case int8, uint8, int16, uint16, int32, uint32, float32, float64
    case 未知

    var 字节数: Int {
        switch self {
        case .char, .uchar, .int8, .uint8: return 1
        case .short, .ushort, .int16, .uint16: return 2
        case .int, .uint, .float, .int32, .uint32, .float32: return 4
        case .double, .float64: return 8
        case .未知: return 4
        }
    }

    static func 从(_ s: String) -> PLY类型 { PLY类型(rawValue: s) ?? .未知 }
}

enum PLY解析: 网格格式解析器 {
    private struct 属性 {
        var 名称: String
        var 类型: PLY类型
        /// 列表属性的元素类型（非列表为 nil）
        var 元素类型: PLY类型?
    }

    private struct 元素 {
        var 名称: String
        var 数量: Int
        var 属性: [属性]
    }

    static func 解析(url: URL, 设置: 单文件导入设置) throws -> 导入场景 {
        guard let 数据 = try? Data(contentsOf: url) else {
            throw 导入导出错误.文件不可读(url)
        }
        guard let 终止范围 = 数据.range(of: Data("end_header".utf8)) else {
            throw 导入导出错误.解析失败(格式: "PLY", 原因: "缺少 end_header")
        }
        var 数据起点 = 终止范围.upperBound
        while 数据起点 < 数据.count, 数据[数据起点] == 0x0A || 数据[数据起点] == 0x0D {
            数据起点 += 1
        }
        guard let 头文本 = String(data: 数据[0..<数据起点], encoding: .ascii) else {
            throw 导入导出错误.解析失败(格式: "PLY", 原因: "头部不是 ASCII")
        }

        var 格式 = "ascii"
        var 元素表: [元素] = []
        for 行 in 头文本.split(omittingEmptySubsequences: true, whereSeparator: { $0.isNewline }) {
            let 片段 = 行.split(omittingEmptySubsequences: true, whereSeparator: { $0.isWhitespace })
            guard let 头 = 片段.first else { continue }
            if 头 == "format", 片段.count >= 2 {
                格式 = String(片段[1])
            } else if 头 == "element", 片段.count >= 3 {
                元素表.append(元素(名称: String(片段[1]), 数量: Int(片段[2]) ?? 0, 属性: []))
            } else if 头 == "property", !元素表.isEmpty {
                if 片段.count >= 5, 片段[1] == "list" {
                    元素表[元素表.count - 1].属性.append(属性(
                        名称: String(片段[4]),
                        类型: PLY类型.从(String(片段[3])),
                        元素类型: PLY类型.从(String(片段[2]))
                    ))
                } else if 片段.count >= 3 {
                    元素表[元素表.count - 1].属性.append(属性(
                        名称: String(片段[2]),
                        类型: PLY类型.从(String(片段[1])),
                        元素类型: nil
                    ))
                }
            }
        }

        var 场景 = 导入场景(源文件: url)
        var 网格 = 导入网格(名称: url.deletingPathExtension().lastPathComponent)

        if 格式 == "ascii" {
            guard let 文本 = String(data: 数据[数据起点...], encoding: .ascii)
                    ?? String(data: 数据[数据起点...], encoding: .utf8) else {
                throw 导入导出错误.解析失败(格式: "PLY", 原因: "ASCII 实体段解码失败")
            }
            var 行迭代 = 文本.split(omittingEmptySubsequences: true, whereSeparator: { $0.isNewline }).makeIterator()
            for 元 in 元素表 {
                for _ in 0..<元.数量 {
                    guard let 行 = 行迭代.next() else { break }
                    let 值 = 行.split(omittingEmptySubsequences: true, whereSeparator: { $0.isWhitespace })
                    if 元.名称 == "vertex" {
                        读顶点行(值, 属性: 元.属性, 到: &网格)
                    } else if 元.名称 == "face" {
                        读面行(值, 到: &网格)
                    }
                }
            }
        } else {
            let 大端 = 格式.contains("big")
            数据.withUnsafeBytes { 原始 in
                var 偏移 = 数据起点
                for 元 in 元素表 {
                    for _ in 0..<元.数量 {
                        switch 元.名称 {
                        case "vertex":
                            var 位置 = SIMD3<Float>.zero
                            var 法线 = SIMD3<Float>(0, 1, 0)
                            var uv = SIMD2<Float>.zero
                            for 属 in 元.属性 {
                                if let 元素类型 = 属.元素类型 {
                                    let n = max(读整数(原始, 偏移, 元素类型, 大端), 0)
                                    偏移 += 元素类型.字节数 + n * 属.类型.字节数
                                    continue
                                }
                                let v = 读数(原始, 偏移, 属.类型, 大端)
                                偏移 += 属.类型.字节数
                                switch 属.名称 {
                                case "x": 位置.x = v
                                case "y": 位置.y = v
                                case "z": 位置.z = v
                                case "nx": 法线.x = v
                                case "ny": 法线.y = v
                                case "nz": 法线.z = v
                                case "s", "u", "texture_u": uv.x = v
                                case "t", "v", "texture_v": uv.y = v
                                default: break
                                }
                            }
                            网格.顶点.append(位置)
                            网格.法线.append(法线)
                            网格.UV.append(uv)
                        case "face":
                            var 环: [UInt32] = []
                            for 属 in 元.属性 {
                                guard let 元素类型 = 属.元素类型 else {
                                    偏移 += 属.类型.字节数
                                    continue
                                }
                                let n = max(读整数(原始, 偏移, 元素类型, 大端), 0)
                                偏移 += 元素类型.字节数
                                for _ in 0..<n {
                                    let 值 = 读整数(原始, 偏移, 属.类型, 大端)
                                    偏移 += 属.类型.字节数
                                    if 属.名称.contains("vertex") || 属.名称.contains("index") {
                                        if 值 >= 0, 值 < 网格.顶点.count { 环.append(UInt32(值)) }
                                    }
                                }
                            }
                            导入网格.扇形三角化(环, 写入: &网格.索引)
                        default:
                            for 属 in 元.属性 {
                                if let 元素类型 = 属.元素类型 {
                                    let n = max(读整数(原始, 偏移, 元素类型, 大端), 0)
                                    偏移 += 元素类型.字节数 + n * 属.类型.字节数
                                } else {
                                    偏移 += 属.类型.字节数
                                }
                            }
                        }
                    }
                }
            }
        }

        guard !网格.索引.isEmpty else {
            throw 导入导出错误.解析失败(格式: "PLY", 原因: "只有顶点没有面（点云暂不支持渲染）")
        }
        if 设置.重算法线 || 网格.法线.allSatisfy({ $0 == SIMD3(0, 1, 0) }) {
            网格.重算法线()
        }
        网格.对齐属性()
        网格.子集 = [导入子集(材质: nil, 起始: 0, 数量: 网格.索引.count)]
        场景.网格 = [网格]
        场景.材质 = [导入材质(名称: "PLY 默认")]
        return 场景
    }

    // MARK: ASCII 分支

    private static func 读顶点行(_ 值: [Substring], 属性: [属性], 到 网格: inout 导入网格) {
        var 位置 = SIMD3<Float>.zero
        var 法线 = SIMD3<Float>(0, 1, 0)
        var uv = SIMD2<Float>.zero
        for (下标, 文本) in 值.enumerated() {
            guard 下标 < 属性.count, let v = Float(文本) else { continue }
            switch 属性[下标].名称 {
            case "x": 位置.x = v
            case "y": 位置.y = v
            case "z": 位置.z = v
            case "nx": 法线.x = v
            case "ny": 法线.y = v
            case "nz": 法线.z = v
            case "s", "u", "texture_u": uv.x = v
            case "t", "v", "texture_v": uv.y = v
            default: break
            }
        }
        网格.顶点.append(位置)
        网格.法线.append(法线)
        网格.UV.append(uv)
    }

    private static func 读面行(_ 值: [Substring], 到 网格: inout 导入网格) {
        guard let 数 = Int(值[0]), 数 > 2, 值.count > 数 else { return }
        var 环: [UInt32] = []
        环.reserveCapacity(数)
        for k in 1...数 {
            if let idx = Int(值[k]), idx >= 0, idx < 网格.顶点.count {
                环.append(UInt32(idx))
            }
        }
        导入网格.扇形三角化(环, 写入: &网格.索引)
    }

    // MARK: 二进制分支

    private static func 读数(_ 原始: UnsafeRawBufferPointer, _ 偏移: Int, _ 类型: PLY类型, _ 大端: Bool) -> Float {
        switch 类型 {
        case .float, .float32:
            let v = 原始.loadUnaligned(fromByteOffset: 偏移, as: UInt32.self)
            return Float(bitPattern: 大端 ? v.bigEndian : v.littleEndian)
        case .double, .float64:
            let v = 原始.loadUnaligned(fromByteOffset: 偏移, as: UInt64.self)
            return Float(Double(bitPattern: 大端 ? v.bigEndian : v.littleEndian))
        default:
            return Float(读整数(原始, 偏移, 类型, 大端))
        }
    }

    private static func 读整数(_ 原始: UnsafeRawBufferPointer, _ 偏移: Int, _ 类型: PLY类型, _ 大端: Bool) -> Int {
        switch 类型 {
        case .char, .int8:
            return Int(Int8(bitPattern: 原始.loadUnaligned(fromByteOffset: 偏移, as: UInt8.self)))
        case .uchar, .uint8:
            return Int(原始.loadUnaligned(fromByteOffset: 偏移, as: UInt8.self))
        case .short, .int16:
            let v = 原始.loadUnaligned(fromByteOffset: 偏移, as: UInt16.self)
            return Int(Int16(bitPattern: 大端 ? v.bigEndian : v.littleEndian))
        case .ushort, .uint16:
            let v = 原始.loadUnaligned(fromByteOffset: 偏移, as: UInt16.self)
            return Int(大端 ? v.bigEndian : v.littleEndian)
        case .int, .int32:
            let v = 原始.loadUnaligned(fromByteOffset: 偏移, as: UInt32.self)
            return Int(Int32(bitPattern: 大端 ? v.bigEndian : v.littleEndian))
        case .uint, .uint32:
            let v = 原始.loadUnaligned(fromByteOffset: 偏移, as: UInt32.self)
            return Int(大端 ? v.bigEndian : v.littleEndian)
        default:
            return 0
        }
    }
}
