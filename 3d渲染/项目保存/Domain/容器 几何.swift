import CryptoKit
import Foundation
import simd

// MARK: - 几何块（mmap 直读）

/// 单网格几何块 `.cgm`。
///
/// 为什么不是一个 meshpool 大文件：
/// - 大文件改一个模型要整份重写；分块之后「改 A 模型」只重写 A 那一块，
///   其余文件原地不动，保存成本从 O(全场) 降到 O(改动)。
/// - 载入时只 mmap 被物体引用的块，模型库里没被引用的素材一个字节都不驻留。
///
/// 文件布局（全部小端、定长、16B 对齐，载入路径上没有解析只有 memcpy）：
/// ```
/// 0   魔数 "CGGEO\0\0\0"  8B
/// 8   版本 u32
/// 12  段数 u32
/// 16  段表 段数 × 16B：类型 u32（低16位=类型，高16位=子网格序号）+ 数量 u32 + 偏移 u64
/// ..  数据区（16B 对齐）
/// ```
enum 容器几何 {

    static let 魔数 = Data([0x43, 0x47, 0x47, 0x45, 0x4F, 0x00, 0x00, 0x00]) // "CGGEO"
    static let 版本: UInt32 = 1
    static let 头长 = 16
    static let 段长 = 16

    /// 段类型字：`子网格序号 u16 << 16 | 元素编码 u8 << 8 | 段类型 u8`
    ///
    /// 布局完全由段表自描述：**元素编码就在类型字里**，读取端按「类型 + 编码」决定
    /// 每元素多少字节、怎么解包，不依赖任何版本号分派。老块的类型字高字节是 0
    /// （= `.原始`），所以老文件走的还是原来那条 16B/8B/4B 的路径，一个字节都不用改。
    enum 段: UInt32 {
        case 名称 = 1
        case 变换 = 2
        case 顶点 = 3
        case 法线 = 4
        case UV = 5
        case 索引 = 6
        case 子集 = 7
        /// 蒙皮权重：数量 = 顶点数，每顶点定长 32B = 4 槽 ×（骨名序号 u32 + 重量 f32）。
        /// 空槽填 序号 0xFFFF_FFFF、重量 0。
        case 权重 = 8
        /// 权重段引用到的骨名表：数量 = 载荷总字节数，载荷 = 重复（u32 字节长 + UTF-8）。
        /// 必须落盘：顶点组名（= 骨名）是蒙皮能和骨架对上号的唯一依据，
        /// 丢了它，读回来的权重就是一串没人认领的下标。
        case 骨名 = 9
    }

    /// 段内元素的落盘编码。全部无损：只去对齐填充、折叠同值、收窄位宽，
    /// 解回来和写进去的数值逐位相同。
    enum 编码: UInt32 {
        /// 老布局：SIMD3<Float> 按 16B stride（含 4B 对齐填充）、UV 8B、索引 UInt32
        case 原始 = 0
        /// SIMD3 去填充：每元素 12B（x/y/z 各 4B），丢掉的那个 lane 本来就是填充
        case 紧凑 = 1
        /// 常量段：整段元素值完全相同，载荷只有 1 个元素，数量仍记元素个数
        case 常量 = 2
        /// 索引半宽：最大索引 ≤ 0xFFFF 时按 UInt16 落盘（不用 24 位，非对齐读会拖慢）
        case 半宽 = 3
        /// 索引恰为 0..n-1 的顺序序列：一个字节都不写，读时按数量生成
        case 顺序 = 4
    }

    /// 新编码标记位：**只写给旧版读取端看**，让它干净地判成不兼容，
    /// 而不是按 16B stride 去读 12B 数据、读出一堆垃圾几何。
    /// 本文件的新读取端从不按它分派布局（那由段表里的编码字段决定），版本号仍是 1。
    static let 紧凑标志: UInt32 = 0x4000_0000

    // MARK: 命名

    /// 内容寻址：`<网格ID>-<顶点数>-<索引数>-<几何指纹>.cgm`
    ///
    /// 只按「顶点数/索引数」命名是不够的：顶点数不变、只改了数据的场景（拖点、
    /// 形变、导入后数量恰好相同的重拓扑）文件名不会变，保存会命中「已存在就跳过」，
    /// 改动永远落不了盘，下次打开读到旧几何（脏读）。补一段对真实几何数据做的指纹后，
    /// 内容一变必然换名，既不脏读也不会覆盖掉正在被旧清单引用的块。
    ///
    /// 指纹口径只覆盖**真实几何载荷**（顶点 / 法线 / UV / 索引）。
    /// 子集（材质分配）这类结构化元数据不进文件名：材质一改就换名，等于把几十 MB
    /// 的几何整块重写一份，而几何本身一个字节都没动。这类变化改由清单的 `校验`
    /// 字段记录（见 校验指纹），命中同名块时按它决定「跳过」还是「同名原地重写」。
    ///
    /// 兼容旧工程：读取只认清单里登记的文件名，不会反推命名规则，
    /// 所以 `ID-顶点数-索引数.cgm` 这类老块照常打开；首次保存会按新规则重写一份，
    /// 老块随后作为孤儿被清理（数据已迁移完成，不会丢）。
    private static func 文件名(_ 网格ID: UUID, 几何指纹: String, 顶点: Int, 索引: Int) -> String {
        "\(网格ID.uuidString.lowercased())-\(顶点)-\(索引)-\(几何指纹).cgm"
    }

    /// 几何指纹：只对真实几何载荷（顶点 / 法线 / UV / 索引）取 SHA256，取前 6 字节。
    /// 子集、材质名这类元数据一律不进这个哈希。
    private static func 几何指纹(_ 网格: [导入网格]) -> String {
        摘要(网格, 含元数据: false)
    }

    /// 全量校验：几何载荷 + 真正会落盘的元数据段（名称 / 变换 / 子集）。
    /// 只用于判断「同名块的内容是否与本次要写的一模一样」，不进文件名：
    /// 它变了不必换名，原地重写同名块即可，旧版本由 compact 回收。
    private static func 校验指纹(_ 网格: [导入网格]) -> String {
        摘要(网格, 含元数据: true)
    }

    // MARK: 哈希缓存（SHA256 仍是最終依据，只是不再每轮全量重算）

    /// 缓存键：描述「这一版几何载荷的输入特征」。
    ///
    /// 只靠数组 count 判断是不安全的：顶点被换成等长的另一组数据时 count 不变，
    /// 会命中旧哈希 → 块名不变 → 保存误判「同名块已存在」→ 改动落不了盘（脏读）。
    /// 历史踩过这个坑，所以这里三道判据一起用，全部一致才复用：
    /// 1. `版本`：几何池登记的内容版本号，内容一变必然换号（最权威、成本 O(1)）；
    /// 2. 结构计数：子网格数 / 顶点数 / 索引数，兜住「版本号被漏 bump 的旧代码路径」；
    /// 3. `内容指纹`：全量顶点 / 法线 / UV / 索引 / 元数据的 FNV-1a 折叠值（微秒级），
    ///    兜住「版本没换、计数没变、但数据被原地改写」这种最坏情况。
    ///
    /// 判据缺失（调用方没给版本号）时一律重算：正确性优先于性能。
    private struct 缓存键: Equatable {
        var 版本: UInt64
        var 子网格: Int
        var 顶点: Int
        var 索引: Int
        var 内容指纹: UInt64
    }

    private struct 缓存值 {
        var 键: 缓存键
        var 几何: String
        var 校验: String
    }

    /// 缓存只在写队列上读写，但加锁成本可忽略，顺手保证以后挪位置也不会坏。
    private final class 哈希缓存盒: @unchecked Sendable {
        private let 锁 = NSLock()
        private var 表: [UUID: 缓存值] = [:]
        func 取(_ id: UUID) -> 缓存值? { 锁.lock(); defer { 锁.unlock() }; return 表[id] }
        func 存(_ id: UUID, _ 值: 缓存值) { 锁.lock(); 表[id] = 值; 锁.unlock() }
        func 忘(_ id: UUID) { 锁.lock(); 表[id] = nil; 锁.unlock() }
    }

    private static let 哈希缓存 = 哈希缓存盒()

    /// 内容指纹：**全量**遍历顶点 / 法线 / UV / 索引 / 元数据，用 FNV-1a 折叠成一个 UInt64。
    ///
    /// 为什么不是「首中尾采样」：采样会漏掉中间任何一段被原地改写的情况，
    /// 那正是「顶点数据变了但哈希没变 → 块名不变 → 保存误判已存在 → 改动落不了盘」
    /// 这个历史坑的成因。判据必须覆盖每一个会影响块内容的字节，宁可多扫一遍。
    ///
    /// 为什么比 SHA256 便宜一个量级：全量只有约 15 万次 xor-multiply（微秒级），
    /// 而 SHA256 要扫同样的字节并做分块压缩（毫秒级，且每次保存算两次）。
    /// Float 取 bitPattern、SIMD3 只取 x/y/z（绕开第 4 个填充 lane，否则结果不稳定）。
    private static func 内容指纹(_ 网格: [导入网格]) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        @inline(__always) func 混(_ v: UInt64) {
            h = (h ^ v) &* 0x0000_0100_0000_01b3
        }
        // 全量遍历：一个元素都不跳。热点用 withUnsafeBufferPointer 省掉边界检查。
        @inline(__always) func 混三维(_ 数组: [SIMD3<Float>]) {
            混(UInt64(数组.count))
            guard !数组.isEmpty else { return }
            数组.withUnsafeBufferPointer { p in
                for v in p {
                    混(UInt64(v.x.bitPattern)); 混(UInt64(v.y.bitPattern)); 混(UInt64(v.z.bitPattern))
                }
            }
        }
        @inline(__always) func 混UV(_ 数组: [SIMD2<Float>]) {
            混(UInt64(数组.count))
            guard !数组.isEmpty else { return }
            数组.withUnsafeBufferPointer { p in
                for v in p { 混(UInt64(v.x.bitPattern)); 混(UInt64(v.y.bitPattern)) }
            }
        }
        @inline(__always) func 混索引(_ 数组: [UInt32]) {
            混(UInt64(数组.count))
            guard !数组.isEmpty else { return }
            数组.withUnsafeBufferPointer { p in
                for i in p { 混(UInt64(i)) }
            }
        }

        混(UInt64(网格.count))
        for m in 网格 {
            混三维(m.顶点); 混三维(m.法线); 混UV(m.UV); 混索引(m.索引)
            // 名称 / 子集 / 变换也会落盘，一并混进来。
            // 名称用自己算的 FNV 而不是 hashValue：后者带进程随机种子，不可复现。
            for b in m.名称.utf8 { 混(UInt64(b)) }
            混(UInt64(m.子集.count))
            for v in [m.变换.columns.0, m.变换.columns.1, m.变换.columns.2, m.变换.columns.3] {
                混(UInt64(v.x.bitPattern)); 混(UInt64(v.y.bitPattern)); 混(UInt64(v.z.bitPattern))
            }
            // 权重也要进指纹：顶点一个字节没动、只重新绑了一遍骨，块内容却是新的，
            // 漏了这一项就会「哈希缓存命中旧值 → 校验相同 → 跳过写入」，新权重永远落不了盘。
            混(UInt64(m.权重.count))
            for 一顶点 in m.权重 {
                for 一骨 in 一顶点 {
                    for b in 一骨.骨名.utf8 { 混(UInt64(b)) }
                    混(UInt64(一骨.重量.bitPattern))
                }
            }
        }
        return h
    }

    /// 两个坑必须绕开，否则「同内容」会算出不同哈希，每次保存都写新块白占磁盘：
    /// 1. `SIMD3<Float>` 的 stride 是 16（末尾 4 字节是填充，值不确定），不能整块哈希，
    ///    按 3 个 float 打成 12 字节连续块再喂给哈希；
    /// 2. 带可选值的子集结构同样有填充字节，一律先转成定长整数再哈希。
    private static func 摘要(_ 网格: [导入网格], 含元数据: Bool) -> String {
        var h = SHA256()

        /// 落盘布局标记：只进「校验指纹」，不进文件名。
        /// 作用是把「同样数值、但按老布局落的块」判成「内容需重写」，
        /// 于是升级后第一次保存会把老块原地换成本版布局（文件名不变，不会多留一份）。
        /// 放在这里而不是版本号里：文件名与几何指纹的口径完全不变。
        if 含元数据 { h.update(data: Data("几何布局:原始十六Bv2".utf8)) }

        /// 定长整数：整型没有填充歧义，直接当 8 字节喂进去。
        func 记数(_ 值: Int) {
            var v = Int64(值)
            withUnsafeBytes(of: &v) { h.update(bufferPointer: $0) }
        }

        func 记字节(_ 数组: String?) {
            let 串 = 数组 ?? ""
            h.update(data: Data(串.utf8))
        }

        /// 无内边距的标量数组（UInt32 / SIMD2<Float>）：原始缓冲区就是确定字节序列。
        func 记裸数组<T>(_ 数组: [T]) {
            记数(数组.count)
            if !数组.isEmpty { 数组.withUnsafeBytes { h.update(bufferPointer: $0) } }
        }

        /// SIMD3<Float>：每元素只取 xyz 三通道，避开第 4 个填充 lane。
        func 记三维(_ 数组: [SIMD3<Float>]) {
            记数(数组.count)
            guard !数组.isEmpty else { return }
            let 批 = 4096
            var 块 = [Float]()
            块.reserveCapacity(批 * 3)
            var i = 0
            while i < 数组.count {
                let 末 = Swift.min(i + 批, 数组.count)
                块.removeAll(keepingCapacity: true)
                for k in i..<末 {
                    let v = 数组[k]
                    块.append(v.x); 块.append(v.y); 块.append(v.z)
                }
                块.withUnsafeBytes { h.update(bufferPointer: $0) }
                i = 末
            }
        }

        /// simd_float4x4 是 16 个 float 紧凑排布，无填充。
        func 记矩阵(_ m: simd_float4x4) {
            var m = m
            withUnsafeBytes(of: &m) { h.update(bufferPointer: $0) }
        }

        记数(网格.count)
        for m in 网格 {
            // 名称 / 变换会写进块，但不算「几何载荷」：只参与 校验指纹
            if 含元数据 {
                记字节(m.名称)
                记矩阵(m.变换)
            }
            记三维(m.顶点)
            记三维(m.法线)
            记裸数组(m.UV)
            记裸数组(m.索引)
            if 含元数据 {
                记数(m.子集.count)
                for s in m.子集 {
                    // 与打包严格对齐：材质名不落盘所以不计；起始/数量按截断后的值计
                    记数(s.材质 ?? -1)
                    记数(max(0, s.起始))
                    记数(max(0, s.数量))
                }
            }
            // 权重段只在真有权重时才进校验：老块本来就没有权重，
            // 无条件混入会让「刚打开的旧工程」在首次保存时把所有几何整块重写一遍。
            if 含元数据, !m.权重.isEmpty {
                h.update(data: Data("蒙皮权重v1".utf8))
                let 字节 = 蒙皮字节(m.权重)
                h.update(data: 字节.槽)
                h.update(data: 字节.名表)
            }
        }

        return h.finalize().prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: 写出

    struct 写出结果 {
        var 条目: [容器清单.几何条目]
        var 跳过: Int
        var 写入: Int
    }

    /// - Parameter 版本表: 几何池给出的每块内容版本号。不传就等于「没有可靠判据」，
    ///   所有哈希一律重算——慢一点，但绝不会拿旧哈希当新内容。
    static func 写出(_ 池: [UUID: [导入网格]], 到 st: 容器存储,
                     旧条目: [容器清单.几何条目] = [],
                     版本表: [UUID: UInt64] = [:]) -> 写出结果 {
        var 条目: [容器清单.几何条目] = []
        条目.reserveCapacity(池.count)
        var 跳过 = 0
        var 写入 = 0

        /// 上次保存留下的「块名 → 全量校验」，用来判断同名块是不是真的同内容。
        let 旧校验: [String: String] = Dictionary(
            旧条目.compactMap { e in e.校验.map { (e.文件, $0) } },
            uniquingKeysWith: { 首, _ in 首 })

        for 网格ID in 池.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let 网格 = 池[网格ID], !网格.isEmpty else { continue }
            let 顶点 = 网格.reduce(0) { $0 + $1.顶点.count }
            let 索引 = 网格.reduce(0) { $0 + $1.索引.count }

            // 哈希走缓存：判据齐了才复用，缺一项就老老实实重算。
            // 两个指纹（文件名用的几何指纹 + 跳过判断用的全量校验）一起缓存，
            // 命中时省掉两次全量 SHA256 遍历。
            let 版本号 = 版本表[网格ID]
            let 键 = 缓存键(版本: 版本号 ?? 0, 子网格: 网格.count,
                          顶点: 顶点, 索引: 索引, 内容指纹: 内容指纹(网格))
            var 几何指纹值 = ""
            var 校验 = ""
            if 版本号 != nil, let 缓 = 哈希缓存.取(网格ID), 缓.键 == 键 {
                几何指纹值 = 缓.几何
                校验 = 缓.校验
            } else {
                几何指纹值 = 几何指纹(网格)
                校验 = 校验指纹(网格)
                if 版本号 != nil {
                    哈希缓存.存(网格ID, 缓存值(键: 键, 几何: 几何指纹值, 校验: 校验))
                }
            }

            let 名 = 文件名(网格ID, 几何指纹: 几何指纹值, 顶点: 顶点, 索引: 索引)
            let 路径 = 项目容器.布局.几何 + "/" + 名

            if let 已有 = st.大小(路径), 已有 > 头长 {
                // 同名块必须「内容完全一致」才跳过：只有子集 / 变换 / 名称变了，
                // 或者老清单里根本没有 校验 字段，都要原地重写同名块，
                // 否则材质分配之类的元数据会读回旧值（就是脏读）。
                if 旧校验[名] == 校验 {
                    跳过 += 1
                    条目.append(.init(网格ID: 网格ID, 文件: 名, 子网格数: 网格.count,
                                     顶点数: 顶点, 索引数: 索引, 字节: 已有, 校验: 校验))
                    continue
                }
            }

            guard let data = 打包(网格) else { continue }
            if st.写(路径, data) {
                写入 += 1
                条目.append(.init(网格ID: 网格ID, 文件: 名, 子网格数: 网格.count,
                                 顶点数: 顶点, 索引数: 索引, 字节: data.count, 校验: 校验))
            }
        }
        return 写出结果(条目: 条目, 跳过: 跳过, 写入: 写入)
    }

    /// 权重 → 落盘字节。两个段一起产出，指纹与落盘共用同一份字节，避免「算的和写的不是一回事」。
    /// - 权重段：每顶点 4 槽 ×（骨名序号 u32 + 重量 f32）；空槽 = 0xFFFF_FFFF / 0
    /// - 骨名段：重复（u32 字节长 + UTF-8），名字出现顺序即权重段里的序号
    private static func 蒙皮字节(_ 权重表: [[导入骨权重]]) -> (槽: Data, 名表: Data) {
        var 序号: [String: UInt32] = [:]
        var 名表 = Data()
        var 槽 = Data(capacity: 权重表.count * 32)
        槽.reserveCapacity(权重表.count * 32)

        @inline(__always) func 追加<T>(_ 值: T, 到 目标: inout Data) {
            var v = 值
            withUnsafeBytes(of: &v) { 目标.append(contentsOf: $0) }
        }

        for 一顶点 in 权重表 {
            var 已写 = 0
            for 一骨 in 一顶点 where 已写 < 4 {
                let 号: UInt32
                if let 现成 = 序号[一骨.骨名] {
                    号 = 现成
                } else {
                    号 = UInt32(序号.count)
                    序号[一骨.骨名] = 号
                    let 字节 = Data(一骨.骨名.utf8)
                    追加(UInt32(clamping: 字节.count), 到: &名表)
                    名表.append(字节)
                }
                追加(号, 到: &槽)
                追加(一骨.重量, 到: &槽)
                已写 += 1
            }
            while 已写 < 4 {
                追加(UInt32.max, 到: &槽)
                追加(Float(0), 到: &槽)
                已写 += 1
            }
        }
        return (槽, 名表)
    }

    /// 把 [导入网格] 打成一块。段表先行，数据区统一 16B 对齐。
    ///
    /// 每段的「编码」按数据本身挑，任何一条前提不满足就退回 `.原始` 老写法：
    /// 顶点/法线 → 全同则常量，否则原样 16B（保留 memcpy 快路径）；UV → 全同则常量，否则原样 8B；
    /// 索引 → 恰好 0..n-1 则隐式，最大索引 ≤ 0xFFFF 则半宽，否则原样 32 位。
    private static func 打包(_ 网格: [导入网格]) -> Data? {
        struct 待写段 {
            var 类型字: UInt32
            var 数量: Int
            var 字节数: Int
            var 偏移: Int
            var 载荷: Data
        }

        var 段表: [待写段] = []

        func 加段(_ 子: Int, _ 类型: 段, _ 编码: 编码, _ 数量: Int, _ 载荷: Data) {
            段表.append(待写段(类型字: (UInt32(子) << 16) | (编码.rawValue << 8) | 类型.rawValue,
                             数量: 数量, 字节数: 载荷.count, 偏移: 0, 载荷: 载荷))
        }

        /// SIMD3 段：整段同值走常量，否则原样 16B stride。
        ///
        /// 这里刻意不写 12B 紧凑布局：载荷与 `SIMD3<Float>` 的内存布局完全一致，
        /// 读端 `.原始` 分支能直接 `Array(UnsafeBufferPointer)` 整块 memcpy 成数组，
        /// 省掉的 4B 填充只值零点几 MB，却让解包退化成逐元素 load（实测慢 2.8 倍）。
        /// 12B 的读取兼容仍保留，用于打开老版本已落的紧凑块。
        func 加三维段(_ 子: Int, _ 类型: 段, _ 数组: [SIMD3<Float>]) {
            guard !数组.isEmpty else { return }
            if 全同(数组) {
                加段(子, 类型, .常量, 数组.count, 紧凑三维([数组[0]]))
                return
            }
            加段(子, 类型, .原始, 数组.count, 原始(数组))
        }

        for (i, m) in 网格.enumerated() {
            let 名称 = Data(m.名称.utf8)
            加段(i, .名称, .原始, 名称.count, 名称)
            加段(i, .变换, .原始, 1, 矩阵字节(m.变换))
            if !m.顶点.isEmpty { 加三维段(i, .顶点, m.顶点) }
            if !m.法线.isEmpty { 加三维段(i, .法线, m.法线) }
            if !m.UV.isEmpty {
                // UV 是 SIMD2<Float>，本身没有填充，能省的只有「全段同值」这一种
                if 全同(m.UV) {
                    加段(i, .UV, .常量, m.UV.count, 原始([m.UV[0]]))
                } else {
                    加段(i, .UV, .原始, m.UV.count, 原始(m.UV))
                }
            }
            if !m.索引.isEmpty {
                // 编码阶梯：顺序（0 字节）→ 半宽（2B）→ 32 位（4B）。
                // 关键是「顺序一旦被拓扑编辑破坏，必须先落到半宽」这条短路：
                // 只看最大索引，最大索引 ≤ 0xFFFF 就一定用 2B，绝不定跳 32 位——
                // 否则删/增一个顶点就会把整档索引从 0 字节抬到 4B/索引。
                let 决策 = 索引编码(m.索引)
                加段(i, .索引, 决策.0, m.索引.count, 决策.1)
            }
            if !m.子集.isEmpty {
                var buf = Data(capacity: m.子集.count * 12)
                for s in m.子集 {
                    // 材质必须落成 4B 定宽。读取端按 Int32 + UInt32 + UInt32 = 12B 步长解，
                    // 这里写成 Int（arm64 上 8B）会让每条子集多出 4B，
                    // 于是「材质 -1 的高 4 字节」被读成起始 = 4294967295、真正的起始被读成数量，
                    // 整段子集从此错位：网格的绘制范围变成 0 个三角形，材质也丢了。
                    var 材质 = Int32(s.材质 ?? -1)
                    var 起始 = UInt32(clamping: max(0, s.起始))
                    var 数量 = UInt32(clamping: max(0, s.数量))
                    withUnsafeBytes(of: &材质) { buf.append(contentsOf: $0) }
                    withUnsafeBytes(of: &起始) { buf.append(contentsOf: $0) }
                    withUnsafeBytes(of: &数量) { buf.append(contentsOf: $0) }
                }
                加段(i, .子集, .原始, m.子集.count, buf)
            }
            // 蒙皮权重必须跟几何同块：它是几何的绑定信息，单独一份迟早和顶点对不上。
            // 顶点数对不上的权重一律不落盘（读回来也会被硬校验丢掉，白占体积）。
            if !m.权重.isEmpty, m.权重.count == m.顶点.count {
                let 字节 = 蒙皮字节(m.权重)
                加段(i, .骨名, .原始, 字节.名表.count, 字节.名表)
                加段(i, .权重, .原始, m.权重.count, 字节.槽)
            }
        }

        guard !段表.isEmpty else { return nil }


        // 计算偏移：头 + 段表，之后逐段 16B 对齐
        var 游标 = 头长 + 段表.count * 段长
        for i in 段表.indices {
            游标 = (游标 + 15) & ~15
            段表[i].偏移 = 游标
            游标 += 段表[i].字节数
        }
        let 总长 = (游标 + 15) & ~15

        // 只要有一段用上了新编码，就给旧读取端打上不好惹的标记；
        // 全是老编码的块保持原样，回滚旧版也能照常打开（零收益的块不牺牲兼容）。
        let 用新编码 = 段表.contains { (($0.类型字 >> 8) & 0xFF) != 编码.原始.rawValue }
        let 版本字 = 版本 | (用新编码 ? 紧凑标志 : 0)

        var data = Data(count: 总长)
        data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            // 头
            base.storeBytes(of: 版本字, toByteOffset: 8, as: UInt32.self)
            base.storeBytes(of: UInt32(段表.count), toByteOffset: 12, as: UInt32.self)
            let 魔 = 魔数
            魔.withUnsafeBytes { m in
                base.copyMemory(from: m.baseAddress!, byteCount: 8)
            }
            // 段表
            for (i, s) in 段表.enumerated() {
                let off = 头长 + i * 段长
                base.storeBytes(of: s.类型字, toByteOffset: off, as: UInt32.self)
                base.storeBytes(of: UInt32(s.数量), toByteOffset: off + 4, as: UInt32.self)
                base.storeBytes(of: UInt64(s.偏移), toByteOffset: off + 8, as: UInt64.self)
            }
        }

        // 段载荷按各自偏移落位（指针是 base 偏移，不能直接用 Data 的相对地址）
        data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            for s in 段表 {
                s.载荷.withUnsafeBytes { p in
                    guard let src = p.baseAddress, p.count > 0 else { return }
                    (base + s.偏移).copyMemory(from: src, byteCount: p.count)
                }
            }
        }
        // 数据区够大才压。小文件留着 mmap 零拷贝，压了反而更慢。
        let 数据区起点 = 头长 + 段表.count * 段长
        guard data.count - 数据区起点 >= 块压缩.阈值 else { return data }
        let 压缩块: Data? = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Data? in
            guard let 首址 = raw.baseAddress else { return nil }
            return 块压缩.压(首址 + 数据区起点, 长度: data.count - 数据区起点)
        }
        guard let 块 = 压缩块, 块.count + 数据区起点 < data.count else { return data }
        var 输出 = Data(data[0..<数据区起点])
        输出.append(块)
        输出.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            raw.storeBytes(of: 版本字 | 块压缩.标志, toByteOffset: 8, as: UInt32.self)
        }
        return 输出
    }

    // MARK: 读取（mmap）

    /// mmap + memcpy。整个过程零 JSON、零字符串解析。
    static func 读取(_ 条目: [容器清单.几何条目], 从 st: 容器存储) -> [UUID: [导入网格]] {
        var 池: [UUID: [导入网格]] = [:]
        池.reserveCapacity(条目.count)

        for e in 条目 {
            // 后端给的是整包 mmap 的切片（Data 不复制），缺页时才从磁盘拉
            guard let data = st.读(项目容器.布局.几何 + "/" + e.文件) else { continue }
            data.withUnsafeBytes { raw in
                guard var 网格 = 解析(raw) else { return }
                修补法线(&网格)
                池[e.网格ID] = 网格
            }
        }
        return 池
    }

    /// 老文件兜底：早期版本把「不带 vn 的模型」整段写成常量法线，
    /// 读回来是一模一样的 (0,0,-1)，渲染出来只有一片死色，看着像模型碎了。
    /// 这里一旦发现法线数量不符或整段全同，就按拓扑重算，让旧工程打开即正确。
    private static func 修补法线(_ 网格: inout [导入网格]) {
        for i in 网格.indices {
            guard 网格[i].顶点.count > 1 else { continue }
            let 现有 = 网格[i].法线
            guard 现有.count != 网格[i].顶点.count || 全同(现有) else { continue }
            if let 算出 = 网格[i].计算顶点法线() { 网格[i].法线 = 算出 }
        }
    }

    private static func 解析(_ raw: UnsafeRawBufferPointer) -> [导入网格]? {
        guard raw.count > 头长 else { return nil }
        guard raw[0] == 0x43, raw[1] == 0x47, raw[2] == 0x47, raw[3] == 0x45 else { return nil }
        let 版本字 = raw.load(fromByteOffset: 8, as: UInt32.self)
        // 只校验「版本号本身」，压缩位和兼容标记位都不是布局判据：
        // 新旧布局完全由段表里的编码字段自描述。老文件不打标记，照样走这里。
        guard 版本字 & ~(块压缩.标志 | 紧凑标志) <= 版本 else { return nil }
        let 段数 = Int(raw.load(fromByteOffset: 12, as: UInt32.self))
        let 数据区 = 头长 + 段数 * 段长
        guard 段数 > 0, 数据区 <= raw.count else { return nil }

        // 数据区被压过：解到一块自带「头 + 段表」的缓冲里，
        // 段表里的偏移仍是文件绝对偏移，解析逻辑一行都不用改。
        guard 版本字 & 块压缩.标志 != 0 else {
            return 解析体(raw)
        }
        guard let 首址 = raw.baseAddress, raw.count > 数据区 else { return nil }
        let 压缩块 = 首址 + 数据区
        guard let 原长 = 块压缩.原始长度(压缩块) else { return nil }
        let 总量 = 数据区 + 原长
        let 缓冲 = UnsafeMutableRawPointer.allocate(byteCount: 总量, alignment: 16)
        defer { 缓冲.deallocate() }
        缓冲.copyMemory(from: 首址, byteCount: 数据区)
        let 解出 = 块压缩.解压到(压缩块, raw.count - 数据区, 目标: 缓冲 + 数据区, 容量: 原长)
        guard 解出 == 原长 else { return nil }
        return 解析体(UnsafeRawBufferPointer(start: 缓冲, count: 总量))
    }

    /// 真正的解析：入参是「头 + 段表 + 未压缩数据区」的连续内存。
    private static func 解析体(_ raw: UnsafeRawBufferPointer) -> [导入网格]? {
        let 段数 = Int(raw.load(fromByteOffset: 12, as: UInt32.self))
        guard 段数 > 0, 头长 + 段数 * 段长 <= raw.count else { return nil }

        // 先按子网格序号归位
        var 名称: [Int: String] = [:]
        var 变换: [Int: simd_float4x4] = [:]
        var 顶点: [Int: [SIMD3<Float>]] = [:]
        var 法线: [Int: [SIMD3<Float>]] = [:]
        var UV: [Int: [SIMD2<Float>]] = [:]
        var 索引: [Int: [UInt32]] = [:]
        var 子集: [Int: [导入子集]] = [:]
        var 权重槽: [Int: (偏移: Int, 数量: Int)] = [:]
        var 骨名: [Int: [String]] = [:]
        var 最大子 = 0

        for i in 0..<段数 {
            let off = 头长 + i * 段长
            let 类型字 = raw.load(fromByteOffset: off, as: UInt32.self)
            let 数量 = Int(raw.load(fromByteOffset: off + 4, as: UInt32.self))
            let 偏移 = Int(raw.load(fromByteOffset: off + 8, as: UInt64.self))
            let 子 = Int(类型字 >> 16)
            // 编码就藏在类型字里：老块这一字节恒为 0（.原始），
            // 新块按实际编码解包，读取端不需要任何版本分派。
            let 编码值 = (类型字 >> 8) & 0xFF
            let 类型 = 类型字 & 0xFF
            最大子 = max(最大子, 子)
            guard 数量 >= 0, 偏移 >= 0, 偏移 <= raw.count else { continue }

            switch 类型 {
            case 段.名称.rawValue:
                guard 编码值 == 编码.原始.rawValue else { continue }
                名称[子] = String(decoding: UnsafeRawBufferPointer(rebasing: raw[偏移..<min(raw.count, 偏移 + 数量)]), as: UTF8.self)
            case 段.变换.rawValue:
                guard 编码值 == 编码.原始.rawValue, 偏移 + 64 <= raw.count else { continue }
                var m = matrix_identity_float4x4
                withUnsafeMutableBytes(of: &m) { dst in
                    dst.copyMemory(from: UnsafeRawBufferPointer(rebasing: raw[偏移..<偏移 + 64]))
                }
                变换[子] = m
            case 段.顶点.rawValue:
                guard let a = 解三维(raw, 偏移, 数量, 编码值) else { continue }
                顶点[子] = a
            case 段.法线.rawValue:
                guard let a = 解三维(raw, 偏移, 数量, 编码值) else { continue }
                法线[子] = a
            case 段.UV.rawValue:
                guard let a = 解UV(raw, 偏移, 数量, 编码值) else { continue }
                UV[子] = a
            case 段.索引.rawValue:
                guard let a = 解索引(raw, 偏移, 数量, 编码值) else { continue }
                索引[子] = a
            case 段.子集.rawValue:
                guard 编码值 == 编码.原始.rawValue else { continue }
                // 步长自适应：现行写法 4B 材质 = 12B/条；历史写成 Int 的块 = 16B/条。
                // 老块按 12B 硬解会把「材质 -1 的高 4 字节」读成起始、真正的起始读成数量，
                // 网格就此丢掉绘制范围和材质，所以这里必须先认出布局再解。
                let 步长 = 子集步长(raw, 偏移, 数量)
                var list: [导入子集] = []
                list.reserveCapacity(数量)
                for k in 0..<数量 {
                    let base = 偏移 + k * 步长
                    guard base + 步长 <= raw.count else { break }
                    let 材质 = raw.load(fromByteOffset: base, as: Int32.self)
                    let 起始 = Int(raw.load(fromByteOffset: base + 步长 - 8, as: UInt32.self))
                    let 数目 = Int(raw.load(fromByteOffset: base + 步长 - 4, as: UInt32.self))
                    list.append(导入子集(材质: 材质 >= 0 ? Int(材质) : nil, 起始: 起始, 数量: 数目))
                }
                子集[子] = list
            case 段.骨名.rawValue:
                guard 编码值 == 编码.原始.rawValue else { continue }
                骨名[子] = 解骨名(raw, 偏移, 数量)
            case 段.权重.rawValue:
                // 载荷是定长 32B/顶点，这里只记位置：骨名表可能排在本段后面，
                // 组装时两个都齐了才能把序号翻成骨名。
                guard 编码值 == 编码.原始.rawValue else { continue }
                权重槽[子] = (偏移, 数量)
            default:
                continue
            }
        }

        var 网格: [导入网格] = []
        网格.reserveCapacity(最大子 + 1)
        for i in 0...max(0, 最大子) {
            var m = 导入网格(名称: 名称[i] ?? "网格 \(i + 1)")
            m.顶点 = 顶点[i] ?? []
            m.法线 = 法线[i] ?? []
            m.UV = UV[i] ?? []
            m.索引 = 索引[i] ?? []
            m.子集 = 子集[i] ?? []
            m.变换 = 变换[i] ?? matrix_identity_float4x4
            // 蒙皮权重：条数必须与顶点数严格相等，否则摆姿势那段会整段跳过（静默不蒙皮）。
            // 宁可当成「没有权重」让上层给出明确提示，也不要留半截数据去制造错位变形。
            if let 槽 = 权重槽[i], let 名 = 骨名[i], 槽.数量 == m.顶点.count {
                m.权重 = 解权重(raw, 槽.偏移, 槽.数量, 名)
                if m.权重.count != m.顶点.count { m.权重 = [] }
            }
            if !m.顶点.isEmpty { 网格.append(m) }
        }
        return 网格.isEmpty ? nil : 网格
    }

    // MARK: 孤儿清理

    /// 清单里没登记的 .cgm 视为半截写入的孤儿，删掉。避免「改了模型但文件残留」把磁盘撑大。
    /// 单文件形态删不了单个字节，但**必须把孤儿从索引里摘掉**：只要它还挂在索引上，
    /// 就会被 整理() 当成活块算进分母，垃圾比例永远算成 0，compact 永远不触发。
    /// 摘索引后物理字节由 compact 真正回收。
    static func 清理孤儿(_ 条目: [容器清单.几何条目], 到 st: 容器存储) -> [容器清单.几何条目] {
        let 保留 = Set(条目.map(\.文件))
        guard st.是目录 else {
            let 前缀 = 项目容器.布局.几何 + "/"
            let 孤儿 = st.条目().filter { 名 in
                名.hasPrefix(前缀) && 名.hasSuffix(".cgm")
                    && !保留.contains(String(名.dropFirst(前缀.count)))
            }
            st.移除(孤儿)
            return 条目
        }
        let 目录 = st.根.appendingPathComponent(项目容器.布局.几何, isDirectory: true)
        guard let 文件 = try? FileManager.default.contentsOfDirectory(atPath: 目录.path) else { return 条目 }
        for 名 in 文件 where 名.hasSuffix(".cgm") && !保留.contains(名) {
            try? FileManager.default.removeItem(at: 目录.appendingPathComponent(名))
        }
        return 条目
    }

    // MARK: 字节转换

    /// 未对齐安全的小端读取。
    /// 不能用 `raw.load(fromByteOffset:as:)`：骨名段是变长的（u32 长度 + 字符串），
    /// 只要前面有个名字长度不是 4 的倍数，后面的 u32 就落在奇数地址上，
    /// Swift 会直接 `Fatal error: load from misaligned raw pointer` 崩掉 —— 这不是容错问题，是硬崩。
    @inline(__always) private static func 读U32(_ raw: UnsafeRawBufferPointer, _ 偏移: Int) -> UInt32 {
        UInt32(raw[偏移])
            | (UInt32(raw[偏移 + 1]) << 8)
            | (UInt32(raw[偏移 + 2]) << 16)
            | (UInt32(raw[偏移 + 3]) << 24)
    }

    @inline(__always) private static func 读F32(_ raw: UnsafeRawBufferPointer, _ 偏移: Int) -> Float {
        Float(bitPattern: 读U32(raw, 偏移))
    }

    /// 骨名段：重复（u32 字节长 + UTF-8）。`字节数` 是载荷总长，越界即停，不猜。
    private static func 解骨名(_ raw: UnsafeRawBufferPointer, _ 偏移: Int, _ 字节数: Int) -> [String] {
        guard 偏移 >= 0, 字节数 > 0, 偏移 + 4 <= raw.count else { return [] }
        let 末 = Swift.min(raw.count, 偏移 + 字节数)
        var 结果: [String] = []
        var 游 = 偏移
        while 游 + 4 <= 末 {
            let 长 = Int(读U32(raw, 游))
            游 += 4
            guard 长 > 0, 游 + 长 <= 末 else { break }
            结果.append(String(decoding: UnsafeRawBufferPointer(rebasing: raw[游..<游 + 长]), as: UTF8.self))
            游 += 长
        }
        return 结果
    }

    /// 权重段：每顶点 4 槽 ×（序号 u32 + 重量 f32）。序号越界或重量不正值视为空槽。
    private static func 解权重(_ raw: UnsafeRawBufferPointer, _ 偏移: Int, _ 顶点数: Int,
                          _ 骨名: [String]) -> [[导入骨权重]] {
        var 结果: [[导入骨权重]] = []
        结果.reserveCapacity(顶点数)
        for i in 0..<顶点数 {
            let 基 = 偏移 + i * 32
            guard 基 + 32 <= raw.count else { break }
            var 一顶点: [导入骨权重] = []
            一顶点.reserveCapacity(4)
            for k in 0..<4 {
                let 序 = 读U32(raw, 基 + k * 8)
                let 重 = 读F32(raw, 基 + k * 8 + 4)
                guard 序 != UInt32.max, 重 > 0, Int(序) < 骨名.count else { continue }
                一顶点.append(导入骨权重(组: Int(序), 骨名: 骨名[Int(序)], 重量: 重))
            }
            结果.append(一顶点)
        }
        return 结果
    }

    /// 整段元素是否完全相同。常量段的前提，不满足就退回普通段。
    private static func 全同<T: Equatable>(_ a: [T]) -> Bool {
        guard let 首 = a.first else { return false }
        for v in a.dropFirst() where v != 首 { return false }
        return true
    }

    /// 索引是否恰好是 0,1,2,…（隐式顺序段的前提）。
    private static func 是顺序索引(_ a: [UInt32]) -> Bool {
        for (i, v) in a.enumerated() where v != UInt32(i) { return false }
        return true
    }

    /// 12B/元素的紧凑 SIMD3：x/y/z 各 4B，丢掉的第 4 个 lane 本来就是对齐填充。
    private static func 紧凑三维(_ a: [SIMD3<Float>]) -> Data {
        var d = Data(count: a.count * 12)
        d.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            for (i, v) in a.enumerated() {
                let o = i * 12
                base.storeBytes(of: v.x, toByteOffset: o, as: Float.self)
                base.storeBytes(of: v.y, toByteOffset: o + 4, as: Float.self)
                base.storeBytes(of: v.z, toByteOffset: o + 8, as: Float.self)
            }
        }
        return d
    }

    private static func 半宽索引(_ a: [UInt32]) -> Data {
        var d = Data(count: a.count * 2)
        d.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            for (i, v) in a.enumerated() {
                base.storeBytes(of: UInt16(truncatingIfNeeded: v), toByteOffset: i * 2, as: UInt16.self)
            }
        }
        return d
    }

    /// 索引段的编码决策：顺序（0 字节）→ 半宽（2B）→ 32 位（4B）。
    ///
    /// 一趟扫描同时拿到「是否恰为 0..n-1」与「最大索引」，避免原来扫两遍。
    /// 顺序被破坏时**优先半宽**：只要最大索引 ≤ 0xFFFF 就落 2B，
    /// 只有当顶点数超 65536、索引真的装不下 16 位时才退回 4B。
    private static func 索引编码(_ a: [UInt32]) -> (编码, Data) {
        guard !a.isEmpty else { return (.顺序, Data()) }
        var 顺序 = true
        var 最大: UInt32 = 0
        for (i, v) in a.enumerated() {
            if v != UInt32(i) { 顺序 = false }
            if v > 最大 { 最大 = v }
        }
        if 顺序 { return (.顺序, Data()) }
        if 最大 <= UInt32(UInt16.max) { return (.半宽, 半宽索引(a)) }
        return (.原始, 原始(a))
    }

    /// 按段里的编码把 SIMD3 段解回来。编码不认识、边界不够一律返回 nil（该段跳过）。
    private static func 解三维(_ raw: UnsafeRawBufferPointer, _ 偏移: Int, _ 数量: Int,
                             _ 编码值: UInt32) -> [SIMD3<Float>]? {
        switch 编码值 {
        case 编码.原始.rawValue:
            guard 偏移 + 数量 * 16 <= raw.count else { return nil }
            let p = raw.baseAddress!.advanced(by: 偏移).assumingMemoryBound(to: SIMD3<Float>.self)
            return Array(UnsafeBufferPointer(start: p, count: 数量))
        case 编码.紧凑.rawValue:
            guard 偏移 + 数量 * 12 <= raw.count else { return nil }
            var a = [SIMD3<Float>](repeating: .zero, count: 数量)
            for i in 0..<数量 {
                let o = 偏移 + i * 12
                a[i] = SIMD3<Float>(raw.load(fromByteOffset: o, as: Float.self),
                                    raw.load(fromByteOffset: o + 4, as: Float.self),
                                    raw.load(fromByteOffset: o + 8, as: Float.self))
            }
            return a
        case 编码.常量.rawValue:
            guard 偏移 + 12 <= raw.count else { return nil }
            let v = SIMD3<Float>(raw.load(fromByteOffset: 偏移, as: Float.self),
                                 raw.load(fromByteOffset: 偏移 + 4, as: Float.self),
                                 raw.load(fromByteOffset: 偏移 + 8, as: Float.self))
            return [SIMD3<Float>](repeating: v, count: 数量)
        default:
            return nil
        }
    }

    private static func 解UV(_ raw: UnsafeRawBufferPointer, _ 偏移: Int, _ 数量: Int,
                            _ 编码值: UInt32) -> [SIMD2<Float>]? {
        switch 编码值 {
        case 编码.原始.rawValue:
            guard 偏移 + 数量 * 8 <= raw.count else { return nil }
            let p = raw.baseAddress!.advanced(by: 偏移).assumingMemoryBound(to: SIMD2<Float>.self)
            return Array(UnsafeBufferPointer(start: p, count: 数量))
        case 编码.常量.rawValue:
            guard 偏移 + 8 <= raw.count else { return nil }
            let v = SIMD2<Float>(raw.load(fromByteOffset: 偏移, as: Float.self),
                                 raw.load(fromByteOffset: 偏移 + 4, as: Float.self))
            return [SIMD2<Float>](repeating: v, count: 数量)
        default:
            return nil
        }
    }

    /// 子集段每条的字节步长：12（材质 Int32 定宽）或 16（历史 Int 宽度写法）。
    ///
    /// 12B 布局下 `偏移+4` 是起始，它不可能同时满足「取满 32 位」且「数量为 0」；
    /// 一旦出现这种不可能值，说明读到的是历史 16B 块里材质 -1 的高 4 字节，
    /// 且剩余字节数够放 16B/条，就按老布局重解，避免旧文件掉绘制范围和材质。
    private static func 子集步长(_ raw: UnsafeRawBufferPointer, _ 偏移: Int, _ 数量: Int) -> Int {
        guard 数量 > 0, 偏移 + 12 <= raw.count else { return 12 }
        let 起始 = raw.load(fromByteOffset: 偏移 + 4, as: UInt32.self)
        let 数目 = raw.load(fromByteOffset: 偏移 + 8, as: UInt32.self)
        if 起始 == UInt32.max, 数目 == 0, 偏移 + 数量 * 16 <= raw.count { return 16 }
        return 12
    }

    private static func 解索引(_ raw: UnsafeRawBufferPointer, _ 偏移: Int, _ 数量: Int,
                             _ 编码值: UInt32) -> [UInt32]? {
        switch 编码值 {
        case 编码.原始.rawValue:
            guard 偏移 + 数量 * 4 <= raw.count else { return nil }
            let p = raw.baseAddress!.advanced(by: 偏移).assumingMemoryBound(to: UInt32.self)
            return Array(UnsafeBufferPointer(start: p, count: 数量))
        case 编码.半宽.rawValue:
            guard 偏移 + 数量 * 2 <= raw.count else { return nil }
            var a = [UInt32](repeating: 0, count: 数量)
            for i in 0..<数量 {
                a[i] = UInt32(raw.load(fromByteOffset: 偏移 + i * 2, as: UInt16.self))
            }
            return a
        case 编码.顺序.rawValue:
            // 一个字节都不在盘上：数量就是长度。防一手畸形数量把内存打爆。
            guard 数量 <= 1 << 27 else { return nil }
            return (0..<数量).map { UInt32($0) }
        default:
            return nil
        }
    }

    private static func 原始(_ a: [SIMD3<Float>]) -> Data {
        a.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private static func 原始(_ a: [SIMD2<Float>]) -> Data {
        a.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private static func 原始(_ a: [UInt32]) -> Data {
        a.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private static func 矩阵字节(_ m: simd_float4x4) -> Data {
        var m = m
        return withUnsafeBytes(of: &m) { Data($0) }
    }
}
