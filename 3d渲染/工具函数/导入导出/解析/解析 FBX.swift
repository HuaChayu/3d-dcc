import Compression
import Foundation
import simd

// MARK: - FBX 属性值

/// FBX 容器的属性值。类型码按 Autodesk 公开的 FBX 二进制容器规范。
enum FBX值: Sendable {
    case 布尔(Bool)
    case 短整(Int16)
    case 整(Int32)
    case 长整(Int64)
    case 浮点(Float)
    case 双精度(Double)
    case 文本(String)
    case 二进制(Data)
    case 双精度列([Double])
    case 浮点列([Float])
    case 整型列([Int32])
    case 长整列([Int64])
    case 布尔列([Bool])

    var 数值: Double? {
        switch self {
        case .布尔(let v): return v ? 1 : 0
        case .短整(let v): return Double(v)
        case .整(let v): return Double(v)
        case .长整(let v): return Double(v)
        case .浮点(let v): return Double(v)
        case .双精度(let v): return v
        case .文本(let v): return Double(v)
        default: return nil
        }
    }

    var 文本: String? {
        if case .文本(let v) = self { return v }
        return nil
    }

    var 长整值: Int64? {
        switch self {
        case .短整(let v): return Int64(v)
        case .整(let v): return Int64(v)
        case .长整(let v): return v
        case .浮点(let v): return Int64(v)
        case .双精度(let v): return Int64(v)
        case .布尔(let v): return v ? 1 : 0
        default: return nil
        }
    }

    /// 数值列统一取双精度，调用方自己按需转 Int / Float
    var 双精度列: [Double]? {
        switch self {
        case .双精度列(let v): return v
        case .浮点列(let v): return v.map(Double.init)
        case .整型列(let v): return v.map(Double.init)
        case .长整列(let v): return v.map(Double.init)
        case .布尔列(let v): return v.map { $0 ? 1 : 0 }
        default: return nil
        }
    }
}

// MARK: - FBX 节点树

/// FBX 的容器就是一课节点树，二进制与 ASCII 都解析成这同一个结构。
struct FBX节: Sendable {
    let 名称: String
    var 值: [FBX值] = []
    var 子: [FBX节] = []

    init(_ 名称: String) { self.名称 = 名称 }

    subscript(名: String) -> FBX节? { 子.first { $0.名称 == 名 } }

    func 全部(_ 名: String) -> [FBX节] { 子.filter { $0.名称 == 名 } }

    func 值取(_ 名: String, _ 位: Int = 0) -> FBX值? {
        guard let n = self[名], n.值.count > 位 else { return nil }
        return n.值[位]
    }

    func 文本取(_ 名: String, _ 位: Int = 0) -> String? { 值取(名, 位)?.文本 }

    func 数取(_ 名: String, _ 位: Int = 0) -> Double? { 值取(名, 位)?.数值 }

    /// Properties70 里的 P 节点形如 ["名字","类型","标签","标记", 值...]
    func 属性值(_ 名: String) -> FBX值? {
        guard let p70 = self["Properties70"] else { return nil }
        for p in p70.全部("P") where p.值.first?.文本 == 名 {
            if p.值.count > 4 { return p.值[4] }
        }
        return nil
    }

    func 属性数(_ 名: String) -> Double? { 属性值(名)?.数值 }

    func 属性三元(_ 名: String) -> SIMD3<Double>? {
        guard let p70 = self["Properties70"] else { return nil }
        for p in p70.全部("P") where p.值.first?.文本 == 名 {
            if p.值.count >= 7 {
                return SIMD3(p.值[4].数值 ?? 0, p.值[5].数值 ?? 0, p.值[6].数值 ?? 0)
            }
        }
        return nil
    }

    /// 数组节点：二进制里属性直接挂在节点上（且是 `.双精度列/.整型列` 这类"列"值），
    /// ASCII 里是一串标量或挂在子节点 a 上。这里统一摊平成 [Double]。
    /// 注意：列值的 `数值` 是 nil，若只靠 compactMap{数值} 取，二进制文件会全部读成空数组。
    func 数列(_ 名: String) -> [Double]? {
        guard let n = self[名] else { return nil }
        if let a = n["a"], !a.值.isEmpty { return a.值.compactMap { $0.数值 } }
        var 出: [Double] = []
        出.reserveCapacity(n.值.count)
        for v in n.值 {
            if let 列 = v.双精度列 { 出.append(contentsOf: 列) }
            else if let d = v.数值 { 出.append(d) }
        }
        return 出.isEmpty ? nil : 出
    }
}

// MARK: - 二进制读取

private struct 位读 {
    let 字节: [UInt8]
    var 位 = 0

    init(_ 字节: [UInt8]) { self.字节 = 字节 }

    var 余量: Int { 字节.count - 位 }

    mutating func 取(_ n: Int) throws -> [UInt8] {
        guard n >= 0, 位 + n <= 字节.count else {
            throw 导入导出错误.解析失败(格式: "FBX", 原因: "FBX 二进制越界（位置 \(位)，长度 \(n)）")
        }
        let s = Array(字节[位..<(位 + n)])
        位 += n
        return s
    }

    mutating func u8() throws -> UInt8 { try 取(1)[0] }

    mutating func u16() throws -> UInt16 {
        let b = try 取(2)
        return UInt16(b[0]) | UInt16(b[1]) << 8
    }

    mutating func u32() throws -> UInt32 {
        let b = try 取(4)
        return UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
    }

    mutating func u64() throws -> UInt64 {
        let b = try 取(8)
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(b[i]) << (8 * UInt64(i)) }
        return v
    }

    mutating func i16() throws -> Int16 { Int16(bitPattern: try u16()) }

    mutating func i32() throws -> Int32 { Int32(bitPattern: try u32()) }

    mutating func i64() throws -> Int64 {
        let b = try 取(8)
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(b[i]) << (8 * UInt64(i)) }
        return Int64(bitPattern: v)
    }

    mutating func f32() throws -> Float { Float(bitPattern: try u32()) }

    mutating func f64() throws -> Double { Double(bitPattern: UInt64(bitPattern: try i64())) }
}

// MARK: - FBX 原生解析

/// FBX 的全原生读写。
///
/// 不做任何「借道第三方 DCC」的事：容器格式（Kaydara 头 + 节点树 + 属性编码）按公开规范自己走，
/// 语义层（Objects / Connections / Properties70）按 Blender io_scene_fbx、Assimp、ufbx 一致的读取顺序走。
///
/// 轴的处理只有一条：文件自己声明 UpAxis/UpAxisSign 就采信，没声明就按 FBX 生态主流值 Y 处理。
/// 这里不做 Z→Y 的「Blender 式假设」——那是 Blender 内部 Z-up 的历史包袱，App 自己的基准是 Y-up。
enum FBX解析 {

    // MARK: 入口

    static func 导入(url: URL, 设置: 单文件导入设置) throws -> 导入场景 {
        let 原始: Data
        do {
            原始 = try Data(contentsOf: url)
        } catch {
            throw 导入导出错误.文件不可读(url)
        }
        guard !原始.isEmpty else { throw 导入导出错误.文件不可读(url) }

        let 根 = try 是二进制(原始) ? 解析二进制(原始) : 解析ASCII(原始)
        return try 组装(根: 根, url: url, 设置: 设置)
    }

    private static func 是二进制(_ 数据: Data) -> Bool {
        guard 数据.count >= 18 else { return false }
        let 头 = [UInt8](数据.prefix(18))
        return String(decoding: 头, as: UTF8.self) == "Kaydara FBX Binary"
    }

    // MARK: 二进制容器

    private static func 解析二进制(_ 数据: Data) throws -> [FBX节] {
        var r = 位读([UInt8](数据))
        let 魔数 = try r.取(18)
        guard String(decoding: 魔数, as: UTF8.self) == "Kaydara FBX Binary" else {
            throw 导入导出错误.解析失败(格式: "FBX", 原因: "不是 FBX 二进制容器")
        }
        _ = try r.取(5)                       // "  " + 0x00 0x1A 0x00
        let 版本 = try r.u32()

        var 根: [FBX节] = []
        while r.位 + 12 < r.字节.count {
            guard let 节 = try 读节(&r, 版本: 版本) else { break }
            根.append(节)
        }
        guard !根.isEmpty else { throw 导入导出错误.解析失败(格式: "FBX", 原因: "FBX 容器为空") }
        return 根
    }

    /// 返回 nil 表示读到了结束哨兵
    private static func 读节(_ r: inout 位读, 版本: UInt32) throws -> FBX节? {
        let 起 = r.位
        // FBX 7.5（版本号 7500）起，节点头的 EndOffset / NumProperties / PropertyListLen
        // 全部从 4 字节扩成 8 字节，头总长 13 → 25。CLO、Maya 等导出的 7700 档就是这种宽头，
        // 一律按 4 字节去读会整段错位，落到属性类型上就报「未知属性类型 0x0」。
        var 末尾: UInt64 = 0
        var 属性数: UInt64 = 0
        var 属性长: UInt64 = 0
        if 版本 >= 7500 {
            末尾 = try r.u64()
            属性数 = try r.u64()
            属性长 = try r.u64()
        } else {
            末尾 = UInt64(try r.u32())
            属性数 = UInt64(try r.u32())
            属性长 = UInt64(try r.u32())
        }
        _ = 属性长                          // 属性字节长度，按属性数逐个读即可
        let 名长 = Int(try r.u8())

        if 末尾 == 0 && 属性数 == 0 && 名长 == 0 {
            // 7.5+ 的哨兵扩展成 25 字节，7.4 及以前是 13 字节
            r.位 = 起 + (版本 >= 7500 ? 25 : 13)
            return nil
        }

        let 名 = String(decoding: try r.取(名长), as: UTF8.self)
        var 节 = FBX节(名)
        节.值.reserveCapacity(Int(属性数))
        for _ in 0..<Int(属性数) { 节.值.append(try 读属性(&r)) }

        let 哨兵长 = 版本 >= 7500 ? 25 : 13
        let 子止 = Int(末尾) - 哨兵长
        while r.位 < 子止, r.位 + 12 < r.字节.count {
            guard let 子 = try 读节(&r, 版本: 版本) else { break }
            节.子.append(子)
        }
        let 末 = Int(末尾)
        r.位 = (末 > 起 && 末 <= r.字节.count) ? 末 : max(子止, r.位)
        return 节
    }

    private static func 读属性(_ r: inout 位读) throws -> FBX值 {
        let 码 = try r.u8()
        switch 码 {
        case 0x59: return .短整(try r.i16())                       // 'Y'
        case 0x43: return .布尔((try r.u8()) != 0)                 // 'C'
        case 0x49: return .整(try r.i32())                         // 'I'
        case 0x46: return .浮点(try r.f32())                       // 'F'
        case 0x44: return .双精度(try r.f64())                     // 'D'
        case 0x4C: return .长整(try r.i64())                       // 'L'
        case 0x53:                                                 // 'S'
            let n = Int(try r.u32())
            return .文本(String(decoding: try r.取(n), as: UTF8.self))
        case 0x52:                                                 // 'R'
            let n = Int(try r.u32())
            return .二进制(Data(try r.取(n)))
        case 0x66, 0x64, 0x6C, 0x69, 0x62:                         // f d l i b
            let 数 = Int(try r.u32())
            let 编码 = try r.u32()
            let 压长 = Int(try r.u32())
            let 压 = try r.取(压长)
            let 元素长 = 元素字节长(码)
            let 原 = 编码 == 1 ? try 解压(压, 期望: 数 * 元素长) : 压
            guard 原.count >= 数 * 元素长 else {
                throw 导入导出错误.解析失败(格式: "FBX", 原因: "FBX 数组长度不符")
            }
            return 装列(码, 原, 数)
        default:
            throw 导入导出错误.解析失败(格式: "FBX", 原因: "FBX 未知属性类型 0x\(String(码, radix: 16))")
        }
    }

    private static func 元素字节长(_ 码: UInt8) -> Int {
        switch 码 {
        case 0x66, 0x69: return 4      // f i
        case 0x64, 0x6C: return 8      // d l
        default: return 1              // b
        }
    }

    private static func 装列(_ 码: UInt8, _ b: [UInt8], _ n: Int) -> FBX值 {
        switch 码 {
        case 0x66:
            var 出 = [Float](repeating: 0, count: n)
            b.withUnsafeBytes { raw in
                for i in 0..<n {
                    let v = raw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)
                    出[i] = Float(bitPattern: UInt32(littleEndian: v))
                }
            }
            return .浮点列(出)
        case 0x64:
            var 出 = [Double](repeating: 0, count: n)
            b.withUnsafeBytes { raw in
                for i in 0..<n {
                    let v = raw.loadUnaligned(fromByteOffset: i * 8, as: UInt64.self)
                    出[i] = Double(bitPattern: UInt64(littleEndian: v))
                }
            }
            return .双精度列(出)
        case 0x69:
            var 出 = [Int32](repeating: 0, count: n)
            b.withUnsafeBytes { raw in
                for i in 0..<n {
                    let v = raw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)
                    出[i] = Int32(bitPattern: UInt32(littleEndian: v))
                }
            }
            return .整型列(出)
        case 0x6C:
            var 出 = [Int64](repeating: 0, count: n)
            b.withUnsafeBytes { raw in
                for i in 0..<n {
                    let v = raw.loadUnaligned(fromByteOffset: i * 8, as: UInt64.self)
                    出[i] = Int64(bitPattern: UInt64(littleEndian: v))
                }
            }
            return .长整列(出)
        default:
            return .布尔列(b.prefix(n).map { $0 != 0 })
        }
    }

    /// FBX 数组是 zlib 流（RFC1950：2 字节头 + deflate + adler32）。
    /// 系统 Compression 吃的是裸 deflate，所以要跳过 2 字节头。
    private static func 解压(_ 源: [UInt8], 期望: Int) throws -> [UInt8] {
        guard 期望 > 0 else { return [] }
        guard 源.count > 2 else { throw 导入导出错误.解析失败(格式: "FBX", 原因: "FBX 压缩数组过短") }
        var 出 = [UInt8](repeating: 0, count: 期望)
        let n = 出.withUnsafeMutableBufferPointer { 目 -> Int in
            源.withUnsafeBufferPointer { 指 -> Int in
                guard let 基 = 指.baseAddress else { return 0 }
                return compression_decode_buffer(
                    目.baseAddress!, 期望,
                    基 + 2, 源.count - 2,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard n == 期望 else {
            throw 导入导出错误.解析失败(格式: "FBX", 原因: "FBX 数组解压失败（\(n)/\(期望) 字节）")
        }
        return 出
    }

    // MARK: ASCII 容器

    private static func 解析ASCII(_ 数据: Data) throws -> [FBX节] {
        var 分析 = ASCII分析器(String(decoding: 数据, as: UTF8.self))
        let 根 = try 分析.读块()
        guard !根.isEmpty else { throw 导入导出错误.解析失败(格式: "FBX", 原因: "FBX ASCII 容器为空") }
        return 根
    }

    private struct ASCII分析器 {
        let 字: [Character]
        var i = 0

        init(_ s: String) { 字 = Array(s) }

        mutating func 跳空() {
            while i < 字.count {
                let c = 字[i]
                if c.isWhitespace { i += 1; continue }
                if c == ";" {
                    while i < 字.count && 字[i] != "\n" { i += 1 }
                    continue
                }
                break
            }
        }

        mutating func 读块() throws -> [FBX节] {
            var 出: [FBX节] = []
            while true {
                跳空()
                guard i < 字.count else { return 出 }
                if 字[i] == "}" { i += 1; return 出 }

                guard let 名 = 读名() else { i += 1; continue }
                var 节 = FBX节(名)
                跳空()
                if i < 字.count, 字[i] == ":" { i += 1 }

                var 有块 = false
                跳空()
                if i < 字.count, 字[i] == "{" {
                    i += 1
                    有块 = true
                } else {
                    // 读属性直到本行结束或块开始；"*N { a: ... }" 直接进块
                    while true {
                        跳空()
                        guard i < 字.count else { break }
                        let c = 字[i]
                        if c == "{" { i += 1; 有块 = true; break }
                        if c == "}" { break }
                        if c == "*" {
                            i += 1
                            _ = 读原子()
                            跳空()
                            if i < 字.count, 字[i] == "{" { i += 1; 有块 = true }
                            break
                        }
                        guard let v = 读原子() else { i += 1; break }
                        节.值.append(v)
                        跳空()
                        // 属性后面紧跟 "{" 是「带属性又有子节点」的常见写法
                        // （Geometry: 100, "Geometry::x", "Mesh" { … }），
                        // 这里不认就会把子节点整体吐到父级，几何直接解析成 0 个。
                        if i < 字.count, 字[i] == "{" { i += 1; 有块 = true; break }
                        if i < 字.count, 字[i] == "," { i += 1; continue }
                        break
                    }
                }

                if 有块 { 节.子 = try 读块() }
                出.append(节)
            }
        }

        mutating func 读名() -> String? {
            var s = ""
            while i < 字.count {
                let c = 字[i]
                if c == ":" || c == "{" || c == "}" || c == "," || c.isWhitespace { break }
                s.append(c)
                i += 1
            }
            return s.isEmpty ? nil : s
        }

        mutating func 读原子() -> FBX值? {
            while i < 字.count, 字[i].isWhitespace { i += 1 }
            guard i < 字.count else { return nil }
            if 字[i] == "\"" {
                i += 1
                var s = ""
                while i < 字.count, 字[i] != "\"" { s.append(字[i]); i += 1 }
                if i < 字.count { i += 1 }
                return .文本(s)
            }
            var s = ""
            while i < 字.count {
                let c = 字[i]
                if c == "," || c == "{" || c == "}" || c.isWhitespace { break }
                s.append(c)
                i += 1
            }
            if s.isEmpty { return nil }
            if let v = Int64(s) { return .长整(v) }
            if let v = Double(s) { return .双精度(v) }
            return .文本(s)
        }
    }

    // MARK: 语义组装

    private static func 组装(根: [FBX节], url: URL, 设置: 单文件导入设置) throws -> 导入场景 {
        var 场景 = 导入场景(源文件: url)

        // ---- 全局设置：版本 / 上轴 / 单位 ----
        let 全局 = 根.first { $0.名称 == "GlobalSettings" }
        var 版本号: Int = 0
        if let 头 = 根.first(where: { $0.名称 == "FBXHeaderExtension" }),
           let v = 头.数取("FBXVersion") {
            版本号 = Int(v)
        }

        var 上轴: 上轴? = nil
        if let 轴 = 全局?.属性数("UpAxis") {
            let 轴值 = Int(轴)
            上轴 = (轴值 == 2) ? .z : .y
            let 符号 = 全局?.属性数("UpAxisSign") ?? 1
            场景.报告.append("文件声明 UpAxis=\(轴值 == 2 ? "Z" : (轴值 == 0 ? "X" : "Y"))，符号 \(Int(符号))")
            if 轴值 == 0 {
                场景.报告.append("X 向上是极端少见配置，按 Y 向上处理")
                上轴 = .y
            }
        } else {
            场景.报告.append("文件未声明 UpAxis，按 FBX 生态默认 Y 向上")
        }
        场景.文件上轴 = 上轴

        // UnitScaleFactor：1 单位等于多少厘米。1.0 = 厘米，2.54 = 英寸，100 = 米。
        let 单位厘米 = 全局?.属性数("UnitScaleFactor") ?? 全局?.属性数("OriginalUnitScaleFactor") ?? 1.0
        var 单位缩放: Float = 1
        if 设置.采用米制换算, 单位厘米 > 0, abs(单位厘米 - 100) > 1e-6 {
            // 只有源文件不是米制时才需要换算
            单位缩放 = Float(单位厘米 / 100.0)
        }
        场景.报告.append("单位：1 文件单位 = \(格式小数(单位厘米)) 厘米")

        // ---- Objects ----
        guard let 对象 = 根.first(where: { $0.名称 == "Objects" }) else {
            throw 导入导出错误.解析失败(格式: "FBX", 原因: "FBX 缺少 Objects 段")
        }
        let 模型们 = 对象.全部("Model")
        let 几何们 = 对象.全部("Geometry")
        let 材质们 = 对象.全部("Material")
        guard !几何们.isEmpty else {
            throw 导入导出错误.无有效几何(url)
        }
        场景.报告.append("Objects：\(模型们.count) 个 Model，\(几何们.count) 个 Geometry，\(材质们.count) 个 Material")

        // ---- Connections：父子关系 ----
        let 连线 = 根.first(where: { $0.名称 == "Connections" })?.全部("C") ?? []
        var 父表: [Int64: Int64] = [:]
        var 子序: [Int64: [Int64]] = [:]
        var 连线序: [Int64] = []
        for c in 连线 where c.值.count >= 3 {
            guard c.值[0].文本 == "OO" else { continue }
            let 子 = c.值[1].长整值 ?? 0
            let 父 = c.值[2].长整值 ?? 0
            父表[子] = 父
            子序[父, default: []].append(子)
            连线序.append(子)
        }

        let 模型表 = 字典(模型们)
        let 几何表 = 字典(几何们)
        let 材质表 = 字典(材质们)

        // 全局材质池：按 Model 顺序去重收集，保证每个 Model 的槽位从 0 连续
        var 全局材质: [导入材质] = []
        var 材质键: [String: Int] = [:]
        var 模型材质槽: [Int64: [Int]] = [:]
        for m in 模型们 {
            let 模型ID = m.值.first?.长整值 ?? 0
            var 槽: [Int] = []
            for 子 in 子序[模型ID] ?? [] {
                guard let 材质节 = 材质表[子] else { continue }
                let 名 = 对象名(材质节)
                if let 已有 = 材质键[名] {
                    槽.append(已有)
                } else {
                    let 材 = 解析材质(材质节, 名: 名)
                    全局材质.append(材)
                    材质键[名] = 全局材质.count - 1
                    槽.append(全局材质.count - 1)
                }
            }
            模型材质槽[模型ID] = 槽
        }

        // ---- 逐个 Geometry 出网格 ----
        var 报告网格: [String] = []
        for 几何 in 几何们 {
            let 几何ID = 几何.值.first?.长整值 ?? 0
            let 类型 = 几何.值.count > 2 ? (几何.值[2].文本 ?? "") : ""
            guard 类型.isEmpty || 类型 == "Mesh" else { continue }

            // 找它的 Model 父
            var 模型ID: Int64? = nil
            var 游 = 父表[几何ID]
            while let p = 游 {
                if 模型表[p] != nil { 模型ID = p; break }
                游 = 父表[p]
                if 游 == p { break }
            }
            guard let 模型ID, let 模型 = 模型表[模型ID] else {
                报告网格.append("跳过孤立几何 \(对象名(几何))（没有 Model 挂载）")
                continue
            }

            let 世界 = 世界变换(模型ID: 模型ID, 模型表: 模型表, 父表: 父表, 单位缩放: 单位缩放)
            let 名 = 去前缀(对象名(模型))

            var 统计 = 网格统计()
            guard let 一片 = 造网格(几何: 几何, 名称: 名, 统计: &统计) else {
                报告网格.append("跳过 \(名)：没有可用顶点或全部面退化")
                continue
            }
            // 拓扑口径写进报告：面被丢了多少，是不是走了耳切，出问题好定位
            if 统计.退化面 > 0 || 统计.越界面 > 0 || 统计.退化三角形 > 0 {
                报告网格.append(
                    "\(名)：\(统计.面) 个面（最大边数 \(统计.最大边数)，凹面 \(统计.凹面)）"
                    + "，丢弃退化面 \(统计.退化面) / 越界面 \(统计.越界面) / 退化三角形 \(统计.退化三角形)"
                )
            } else if 统计.最大边数 > 3 || 统计.凹面 > 0 {
                报告网格.append("\(名)：\(统计.面) 个面，最大边数 \(统计.最大边数)，凹面 \(统计.凹面)，已三角化")
            }

            var 网格 = 一片
            网格.变换 = 世界
            网格.对齐属性()
            if 网格.子集.isEmpty { 网格.重建默认子集() }
            if 设置.重算法线 || 网格.法线.count != 网格.顶点.count {
                网格.重算法线()
            }
            场景.网格.append(网格)
        }

        guard !场景.网格.isEmpty else {
            throw 导入导出错误.无有效几何(url)
        }
        场景.材质 = 全局材质
        场景.报告.append(contentsOf: 报告网格)
        场景.报告.append("FBX 版本 \(版本号)，解析出 \(场景.网格.count) 个网格 / \(场景.总三角形) 三角形")
        return 场景
    }

    private static func 字典(_ 节表: [FBX节]) -> [Int64: FBX节] {
        var 出: [Int64: FBX节] = [:]
        for s in 节表 {
            if let id = s.值.first?.长整值 { 出[id] = s }
        }
        return 出
    }

    private static func 对象名(_ 节: FBX节) -> String {
        let 全 = 节.值.count > 1 ? (节.值[1].文本 ?? "") : ""
        return 去前缀(全)
    }

    /// "Model::Cube" → "Cube"
    private static func 去前缀(_ s: String) -> String {
        guard let r = s.range(of: "::", options: .backwards) else { return s }
        let 后 = String(s[r.upperBound...])
        return 后.isEmpty ? s : 后
    }

    private static func 格式小数(_ v: Double) -> String {
        if abs(v - v.rounded()) < 1e-9 { return String(Int(v)) }
        return String(format: "%.4g", v)
    }

    // MARK: 变换

    private static func 世界变换(模型ID: Int64, 模型表: [Int64: FBX节], 父表: [Int64: Int64], 单位缩放: Float) -> simd_float4x4 {
        var 链: [FBX节] = []
        var 游: Int64? = 模型ID
        var 防环 = 0
        while let id = 游, let m = 模型表[id], 防环 < 64 {
            链.append(m)
            游 = 父表[id]
            if 游 == id { break }
            防环 += 1
        }
        var 结果 = matrix_identity_float4x4
        // 自根向叶累乘
        for m in 链.reversed() {
            结果 = 结果 * 局部变换(m)
        }
        if 单位缩放 != 1 {
            结果 = 結果乘缩放(结果, 单位缩放)
        }
        return 结果
    }

    private static func 結果乘缩放(_ m: simd_float4x4, _ s: Float) -> simd_float4x4 {
        var 出 = m
        出.columns.0 *= s
        出.columns.1 *= s
        出.columns.2 *= s
        return 出
    }

    private static func 局部变换(_ 模型: FBX节) -> simd_float4x4 {
        let 平移 = 模型.属性三元("Lcl Translation") ?? SIMD3<Double>(0, 0, 0)
        let 旋转 = 模型.属性三元("Lcl Rotation") ?? SIMD3<Double>(0, 0, 0)
        let 缩放 = 模型.属性三元("Lcl Scaling") ?? SIMD3<Double>(1, 1, 1)
        let 预旋 = 模型.属性三元("PreRotation") ?? SIMD3<Double>(0, 0, 0)
        let 几何移 = 模型.属性三元("GeometricTranslation") ?? SIMD3<Double>(0, 0, 0)
        let 序 = Int(模型.属性数("RotationOrder") ?? 0)

        let 平 = simd_float4x4(columns: (
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(Float(平移.x + 几何移.x), Float(平移.y + 几何移.y), Float(平移.z + 几何移.z), 1)
        ))
        let 缩 = simd_float4x4(diagonal: SIMD4<Float>(Float(缩放.x), Float(缩放.y), Float(缩放.z), 1))
        let 转 = 欧拉(旋转, 顺序: 序)
        let 预 = 欧拉(预旋, 顺序: 0)
        return 平 * 预 * 转 * 缩
    }

    private static func 欧拉(_ 度: SIMD3<Double>, 顺序: Int) -> simd_float4x4 {
        let 弧 = 度 * .pi / 180
        let rx = 绕X(Float(弧.x)), ry = 绕Y(Float(弧.y)), rz = 绕Z(Float(弧.z))
        // eEulerXYZ 表示先 X 后 Y 后 Z，作用在列向量上是 Rz·Ry·Rx
        switch 顺序 {
        case 0: return rz * ry * rx   // XYZ
        case 1: return ry * rz * rx   // XZY
        case 2: return rx * rz * ry   // YZX
        case 3: return rz * rx * ry   // YXZ
        case 4: return ry * rx * rz   // ZXY
        case 5: return rx * ry * rz   // ZYX
        default: return rz * ry * rx
        }
    }

    private static func 绕X(_ a: Float) -> simd_float4x4 {
        let c = cos(a), s = sin(a)
        return simd_float4x4(columns: (
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, c, s, 0),
            SIMD4<Float>(0, -s, c, 0),
            SIMD4<Float>(0, 0, 0, 1)
        ))
    }

    private static func 绕Y(_ a: Float) -> simd_float4x4 {
        let c = cos(a), s = sin(a)
        return simd_float4x4(columns: (
            SIMD4<Float>(c, 0, -s, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(s, 0, c, 0),
            SIMD4<Float>(0, 0, 0, 1)
        ))
    }

    private static func 绕Z(_ a: Float) -> simd_float4x4 {
        let c = cos(a), s = sin(a)
        return simd_float4x4(columns: (
            SIMD4<Float>(c, s, 0, 0),
            SIMD4<Float>(-s, c, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(0, 0, 0, 1)
        ))
    }

    // MARK: 材质

    private static func 解析材质(_ 节: FBX节, 名: String) -> 导入材质 {
        var 材 = 导入材质()
        材.名称 = 名
        if let 色 = 节.属性三元("DiffuseColor") ?? 节.属性三元("Diffuse") {
            材.基础色 = 线性色色(Float(色.x), Float(色.y), Float(色.z))
        }
        if let 发 = 节.属性三元("EmissiveColor") {
            材.自发光 = 线性色色(Float(发.x), Float(发.y), Float(发.z))
        }
        if let 透 = 节.属性数("Opacity") ?? 节.属性数("TransparencyFactor") {
            材.不透明度 = Float(min(max(透, 0), 1))
        }
        if let 金 = 节.属性数("Metallic") ?? 节.属性数("Metalness") {
            材.金属度 = Float(min(max(金, 0), 1))
        }
        if let 粗 = 节.属性数("Roughness") {
            材.粗糙度 = Float(min(max(粗, 0), 1))
        }
        return 材
    }

    private static func 线性色色(_ r: Float, _ g: Float, _ b: Float) -> SIMD3<Float> {
        func 转(_ v: Float) -> Float {
            let x = min(max(v, 0), 1)
            return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
        }
        return SIMD3(转(r), 转(g), 转(b))
    }

    // MARK: 几何展开

    /// 单个 Geometry 的拓扑统计，用来在导入报告里交代这个模型有没有被降级
    private struct 网格统计 {
        var 面 = 0
        var 凹面 = 0
        var 退化面 = 0
        var 越界面 = 0
        var 退化三角形 = 0
        /// 有没有 n>3 的边数
        var 最大边数 = 0
    }

    private static func 造网格(几何: FBX节, 名称: String, 统计: inout 网格统计) -> 导入网格? {
        guard let 位置列 = 几何.数列("Vertices"), 位置列.count >= 3 else { return nil }
        let 位置数 = 位置列.count / 3
        var 位置 = [SIMD3<Float>](repeating: .zero, count: 位置数)
        for i in 0..<位置数 {
            位置[i] = SIMD3(Float(位置列[i * 3]), Float(位置列[i * 3 + 1]), Float(位置列[i * 3 + 2]))
        }

        // 多边形环：PolygonVertexIndex 用负数（按位取反）标记环结尾。
        //
        // 角序（ByPolygonVertex 的法线/UV 就靠它对齐）必须按「原始数组位置」累计：
        // 即使某个环因为退化被丢掉，后面所有环的角序也不能往前挪，否则 UV 会整体串位。
        let 原始索引 = (几何.数列("PolygonVertexIndex") ?? []).map { Int($0) }
        guard !原始索引.isEmpty else { return nil }
        let 总角 = 原始索引.count
        var 环表: [[Int]] = []
        var 角起: [Int] = []

        if 原始索引.contains(where: { $0 < 0 }) {
            var 当前环: [Int] = []
            var 当前起 = 0
            当前环.reserveCapacity(4)
            for (i, v) in 原始索引.enumerated() {
                if 当前环.isEmpty { 当前起 = i }
                if v < 0 {
                    当前环.append(~v)
                    环表.append(当前环)
                    角起.append(当前起)
                    当前环.removeAll(keepingCapacity: true)
                } else {
                    当前环.append(v)
                }
            }
            // 有些写入器漏写最后一个负值结尾，尾巴还留着也当环处理，别整面丢掉
            if !当前环.isEmpty {
                环表.append(当前环)
                角起.append(当前起)
            }
        } else {
            // 完全没有环标记的畸形文件：按三角面片汤处理（每 3 个一组）
            环表.reserveCapacity(总角 / 3)
            角起.reserveCapacity(总角 / 3)
            var i = 0
            while i + 3 <= 总角 {
                环表.append(Array(原始索引[i..<(i + 3)]))
                角起.append(i)
                i += 3
            }
        }

        // 法线通道
        let 法线节 = 几何["LayerElementNormal"]
        var 法线映射 = 法线节?.文本取("MappingInformationType") ?? "ByPolygonVertex"
        let 法线引用 = 法线节?.文本取("ReferenceInformationType") ?? "Direct"
        let 法线原文 = 法线节.flatMap { $0.数列("Normals") } ?? []
        let 法线索引 = (法线节.flatMap { $0.数列("NormalsIndex") } ?? []).map { Int($0) }
        let 法线数 = 法线原文.count / 3

        // UV 通道：多 UV 集时第一套优先（下标 只取第一个 LayerElementUV）
        let uv节 = 几何["LayerElementUV"]
        var uv映射 = uv节?.文本取("MappingInformationType") ?? "ByPolygonVertex"
        let uv引用 = uv节?.文本取("ReferenceInformationType") ?? "Direct"
        let uv原文 = uv节.flatMap { $0.数列("UV") } ?? []
        let uv索引 = (uv节.flatMap { $0.数列("UVIndex") } ?? []).map { Int($0) }
        let uv数 = uv原文.count / 2

        // 有些导出器把逐控制点的法线/UV 写成 ByPolygonVertex + Direct，但数组长度只有控制点数。
        // 这种按角序去取会一路串到末尾，退回逐控制点语义才对得上。
        if 法线映射 == "ByPolygonVertex", 法线引用 != "IndexToDirect", 法线数 > 0, 法线数 < 总角 {
            法线映射 = "ByVertice"
        }
        if uv映射 == "ByPolygonVertex", uv引用 != "IndexToDirect", uv数 > 0, uv数 < 总角 {
            uv映射 = "ByVertice"
        }

        // 角 → 法线下标，取不到返回 -1（后面按默认法线填）
        // 注意：FBX 官方对「逐控制点」的写法是 ByControlPoint，ByVertice 是旧版拼法，两者都要认；
        // 漏认会掉进 default 分支，被当成逐角序去取，UV/法线整片错位。
        func 是逐控制点(_ 映射: String) -> Bool {
            映射 == "ByVertice" || 映射 == "ByVertex" || 映射 == "ByControlPoint"
        }

        func 法号取(_ 位: Int, _ 角序: Int, _ p: Int) -> Int {
            guard 法线数 > 0 else { return -1 }
            switch 法线映射 {
            case _ where 是逐控制点(法线映射):
                return (位 >= 0 && 位 < 法线数) ? 位 : -1
            case "ByPolygon":
                return (p >= 0 && p < 法线数) ? p : -1
            case "AllSame":
                return 0
            default: // ByPolygonVertex
                let 引 = 法线引用 == "IndexToDirect" ? (角序 < 法线索引.count ? 法线索引[角序] : -1) : 角序
                return (引 >= 0 && 引 < 法线数) ? 引 : -1
            }
        }

        // 角 → UV 下标，取不到返回 -1（后面按零点填）
        func uv号取(_ 位: Int, _ 角序: Int, _ p: Int) -> Int {
            guard uv数 > 0 else { return -1 }
            switch uv映射 {
            case _ where 是逐控制点(uv映射):
                return (位 >= 0 && 位 < uv数) ? 位 : -1
            case "ByPolygon":
                return (p >= 0 && p < uv数) ? p : -1
            case "AllSame":
                return 0
            default: // ByPolygonVertex
                let 引 = uv引用 == "IndexToDirect" ? (角序 < uv索引.count ? uv索引[角序] : -1) : 角序
                return (引 >= 0 && 引 < uv数) ? 引 : -1
            }
        }

        // 材质槽
        let 材质节 = 几何["LayerElementMaterial"]
        let 材质映射 = 材质节?.文本取("MappingInformationType") ?? "AllSame"
        let 材质列 = (材质节.flatMap { $0.数列("Materials") } ?? []).map { Int($0) }

        // 角级展开 + 去重（位置/法线/UV 三元组一致才共享顶点）
        struct 角键: Hashable { let 位: Int; let 法: Int; let uv: Int }
        var 去重: [角键: UInt32] = [:]
        var 顶点: [SIMD3<Float>] = []
        var 法线: [SIMD3<Float>] = []
        var UV: [SIMD2<Float>] = []
        var 索引: [UInt32] = []
        var 三角形材质: [Int] = []

        for (p, 环) in 环表.enumerated() {
            统计.面 += 1
            guard 环.count >= 3 else {
                统计.退化面 += 1
                continue
            }
            // 控制点下标越界：整面丢弃。钳到边界只会产出一个错位的面，比丢面更难查
            guard !环.contains(where: { $0 < 0 || $0 >= 位置数 }) else {
                统计.越界面 += 1
                continue
            }
            统计.最大边数 = max(统计.最大边数, 环.count)

            let 面点 = 环.map { 位置[$0] }
            // 注意：三角化后只剩三角形，面边界与「面 → 三角」映射在这里丢失（详见 导入网格.三角化多边形 的说明）。
            let 切分 = 导入网格.三角化多边形(面点)
            guard !切分.索引.isEmpty else {
                统计.退化面 += 1
                continue
            }
            if 切分.凹 { 统计.凹面 += 1 }

            let 材质号 = 材质号取(材质映射, 材质列, p, 环表.count)
            let 角基 = 角起[p]

            // 面自身尺度：退化三角形的面积阈值按面的尺寸走，不用全局坐标量级
            var 面最小 = 面点[0], 面最大 = 面点[0]
            for q in 面点 {
                面最小 = simd_min(面最小, q)
                面最大 = simd_max(面最大, q)
            }
            let 面尺度 = max(simd_length(面最大 - 面最小), 1e-9)
            let 退化面积 = 面尺度 * 面尺度 * 1e-7

            // 顶点只在真的被三角形用到时才落池，纯退化面不会留下孤儿顶点
            var 环内局: [Int: UInt32] = [:]
            环内局.reserveCapacity(环.count)

            func 顶点号(_ c: Int) -> UInt32 {
                if let 有 = 环内局[c] { return 有 }
                let 位 = 环[c]
                let 角序 = 角基 + c
                let 法 = 法号取(位, 角序, p)
                let uv = uv号取(位, 角序, p)
                let 键 = 角键(位: 位, 法: 法, uv: uv)
                let 号: UInt32
                if let 已有 = 去重[键] {
                    号 = 已有
                } else {
                    号 = UInt32(顶点.count)
                    顶点.append(位置[位])
                    if 法 >= 0, 法 * 3 + 2 < 法线原文.count {
                        法线.append(SIMD3(Float(法线原文[法 * 3]), Float(法线原文[法 * 3 + 1]), Float(法线原文[法 * 3 + 2])))
                    } else {
                        法线.append(SIMD3(0, 1, 0))
                    }
                    if uv >= 0, uv * 2 + 1 < uv原文.count {
                        UV.append(SIMD2(Float(uv原文[uv * 2]), Float(uv原文[uv * 2 + 1])))
                    } else {
                        UV.append(.zero)
                    }
                    去重[键] = 号
                }
                环内局[c] = 号
                return 号
            }

            // 三角化：凸面走扇形、凹面走耳切，出来的三角形一定落在面内
            for t in stride(from: 0, to: 切分.索引.count - 2, by: 3) {
                let a = 切分.索引[t]
                let b = 切分.索引[t + 1]
                let c = 切分.索引[t + 2]
                guard a != b, b != c, a != c else {
                    统计.退化三角形 += 1
                    continue
                }
                // 共线三点面积≈0，进渲染管线也只是无效片元，直接丢
                let pa = 面点[a], pb = 面点[b], pc = 面点[c]
                guard simd_length(simd_cross(pb - pa, pc - pa)) > 退化面积 else {
                    统计.退化三角形 += 1
                    continue
                }
                索引.append(顶点号(a))
                索引.append(顶点号(b))
                索引.append(顶点号(c))
                三角形材质.append(材质号)
            }
        }

        guard !索引.isEmpty else { return nil }

        var 网格 = 导入网格(名称: 名称)
        网格.顶点 = 顶点
        网格.法线 = 法线
        网格.UV = UV
        网格.索引 = 索引
        网格.子集 = 造子集(三角形材质)

        // 法线缺失时由调度层重算
        if 法线数 == 0 { 网格.法线 = [] }
        return 网格
    }

    private static func 材质号取(_ 映射: String, _ 列: [Int], _ 多边形: Int, _ 总数: Int) -> Int {
        guard !列.isEmpty else { return 0 }
        switch 映射 {
        case "ByPolygon":
            return 多边形 < 列.count ? 列[多边形] : 列[列.count - 1]
        case "AllSame":
            return 列[0]
        default:
            return 列.count > 多边形 ? 列[多边形] : 列[0]
        }
    }

    /// 材质号相同的连续三角形合并成一段
    private static func 造子集(_ 三角形材质: [Int]) -> [导入子集] {
        guard !三角形材质.isEmpty else { return [] }
        var 出: [导入子集] = []
        var 起 = 0
        var 当前 = 三角形材质[0]
        for i in 1...三角形材质.count {
            let 值 = i < 三角形材质.count ? 三角形材质[i] : -999
            if 值 != 当前 {
                let 数量 = (i - 起) * 3
                出.append(导入子集(材质: 当前, 起始: 起 * 3, 数量: 数量))
                起 = i
                当前 = 值
            }
        }
        return 出
    }
}
