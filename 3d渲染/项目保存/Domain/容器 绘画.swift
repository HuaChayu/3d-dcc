import Foundation

// MARK: - 绘画快照（纯值，跨线程安全）

struct 绘画图层快照: Codable, Sendable {
    var id: UUID
    var 名称: String
    var 可见: Bool
    var 不透明度: Float
    var 混合: String   // PaintBlend.rawValue（String 枚举）
}

/// 一个对象的绘画数据：图层元信息 + 每个通道的稀疏 tile 块。
struct 物体绘画快照: Sendable {
    var 物体ID: UUID
    var 图层: [绘画图层快照]
    var 当前图层: Int
    /// key = "baseColor" 或 PaintChannel.rawValue
    var 通道: [String: [UInt8]]
}

struct 绘画快照: Sendable {
    var revision: Int
    var 物体: [物体绘画快照]
}

// MARK: - 稀疏纹理块

/// `.cgp` 稀疏 tile 块。
///
/// 绘画图集是 1024×1024×8 切片的 rgba8，一层全量就是 32MB、八层 256MB。
/// 但实际画过的地方通常不到图集的百分之几，剩下全透明。
/// 所以这里按 128×128 切块，**只写 alpha 不全为 0 的块**，每块再做 zlib：
/// - 空白工程：一个通道几十字节；
/// - 画满的极端情况：和裸像素持平（压缩不膨胀，压不小就存原样）。
///
/// 布局：
/// ```
/// 0   魔数 "CGPT\0\0\0\0"  8B
/// 8   版本 u32
/// 12  图集边长 u32
/// 16  切片数 u32
/// 20  tile 边长 u32
/// 24  块数 u32
/// 28  保留 u32
/// 32  块索引 块数 × 24B：
///       切片 u16 · tileX u16 · tileY u16 · 压缩 u16(0=原样,1=zlib) · 偏移 u64 · 长度 u64
/// ..  数据区
/// ```
enum 容器绘画 {

    static let 魔数: [UInt8] = [0x43, 0x47, 0x50, 0x54, 0, 0, 0, 0] // "CGPT"
    static let 版本: UInt32 = 1
    static let 头长 = 32
    static let 索引长 = 24
    static let tile = 128

    struct 块 {
        var 切片: UInt16
        var x: UInt16
        var y: UInt16
        var 压缩: UInt16
        var 数据: [UInt8]
    }

    // MARK: 打包

    /// 从一整张切片（边长 × 边长 × 4B）里切出非空 tile。
    /// 调用方按 slice 逐个喂进来，避免一次性持有一整个 32MB 图集的拷贝。
    static func 切片入块(_ 像素: UnsafeRawBufferPointer,
                        边长: Int,
                        切片: Int,
                        收集: inout [块]) {
        let t = tile
        let 行字节 = 边长 * 4
        guard 像素.count >= 行字节 * 边长 else { return }

        var ty = 0
        while ty < 边长 {
            var tx = 0
            while tx < 边长 {
                let w = min(t, 边长 - tx)
                let h = min(t, 边长 - ty)
                var 有内容 = false
                var 缓冲 = [UInt8](repeating: 0, count: w * h * 4)

                for row in 0..<h {
                    let 源 = (ty + row) * 行字节 + tx * 4
                    for col in 0..<w {
                        let a = 像素[源 + col * 4 + 3]
                        if a != 0 { 有内容 = true }
                        缓冲[(row * w + col) * 4 + 0] = 像素[源 + col * 4 + 0]
                        缓冲[(row * w + col) * 4 + 1] = 像素[源 + col * 4 + 1]
                        缓冲[(row * w + col) * 4 + 2] = 像素[源 + col * 4 + 2]
                        缓冲[(row * w + col) * 4 + 3] = a
                    }
                }

                if 有内容 {
                    let 原 = Data(缓冲)
                    if let 压 = try? (原 as NSData).compressed(using: .zlib) as Data, 压.count < 原.count {
                        收集.append(块(切片: UInt16(切片), x: UInt16(tx / t), y: UInt16(ty / t),
                                      压缩: 1, 数据: [UInt8](压)))
                    } else {
                        收集.append(块(切片: UInt16(切片), x: UInt16(tx / t), y: UInt16(ty / t),
                                      压缩: 0, 数据: 缓冲))
                    }
                }
                tx += t
            }
            ty += t
        }
    }

    static func 打包(边长: Int, 切片数: Int, 块: [块]) -> Data {
        var 游标 = 头长 + 块.count * 索引长
        游标 = (游标 + 15) & ~15
        var 偏移表: [Int] = []
        偏移表.reserveCapacity(块.count)
        for b in 块 {
            游标 = (游标 + 7) & ~7
            偏移表.append(游标)
            游标 += b.数据.count
        }
        var data = Data(count: 游标)
        data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            for (i, v) in 魔数.enumerated() { base.storeBytes(of: v, toByteOffset: i, as: UInt8.self) }
            base.storeBytes(of: 版本, toByteOffset: 8, as: UInt32.self)
            base.storeBytes(of: UInt32(边长), toByteOffset: 12, as: UInt32.self)
            base.storeBytes(of: UInt32(切片数), toByteOffset: 16, as: UInt32.self)
            base.storeBytes(of: UInt32(tile), toByteOffset: 20, as: UInt32.self)
            base.storeBytes(of: UInt32(块.count), toByteOffset: 24, as: UInt32.self)
            base.storeBytes(of: UInt32(0), toByteOffset: 28, as: UInt32.self)
            for (i, b) in 块.enumerated() {
                let off = 头长 + i * 索引长
                base.storeBytes(of: b.切片, toByteOffset: off, as: UInt16.self)
                base.storeBytes(of: b.x, toByteOffset: off + 2, as: UInt16.self)
                base.storeBytes(of: b.y, toByteOffset: off + 4, as: UInt16.self)
                base.storeBytes(of: b.压缩, toByteOffset: off + 6, as: UInt16.self)
                base.storeBytes(of: UInt64(偏移表[i]), toByteOffset: off + 8, as: UInt64.self)
                base.storeBytes(of: UInt64(b.数据.count), toByteOffset: off + 16, as: UInt64.self)
            }
            for (i, b) in 块.enumerated() {
                guard !b.数据.isEmpty else { continue }
                b.数据.withUnsafeBytes { src in
                    guard let s = src.baseAddress else { return }
                    (base + 偏移表[i]).copyMemory(from: s, byteCount: src.count)
                }
            }
        }
        return data
    }

    // MARK: 解包

    struct 解包结果 {
        var 边长: Int
        var 切片数: Int
        var 块: [块]
    }

    static func 解包(_ data: Data) -> 解包结果? {
        guard data.count > 头长 else { return nil }
        return data.withUnsafeBytes { raw -> 解包结果? in
            guard raw[0] == 0x43, raw[1] == 0x47, raw[2] == 0x50, raw[3] == 0x54 else { return nil }
            let 边长 = Int(raw.load(fromByteOffset: 12, as: UInt32.self))
            let 切片数 = Int(raw.load(fromByteOffset: 16, as: UInt32.self))
            let 块数 = Int(raw.load(fromByteOffset: 24, as: UInt32.self))
            guard 边长 > 0, 块数 >= 0, 头长 + 块数 * 索引长 <= raw.count else { return nil }
            var 列表: [块] = []
            列表.reserveCapacity(块数)
            for i in 0..<块数 {
                let off = 头长 + i * 索引长
                let 切片 = raw.load(fromByteOffset: off, as: UInt16.self)
                let x = raw.load(fromByteOffset: off + 2, as: UInt16.self)
                let y = raw.load(fromByteOffset: off + 4, as: UInt16.self)
                let 压 = raw.load(fromByteOffset: off + 6, as: UInt16.self)
                let 偏移 = Int(raw.load(fromByteOffset: off + 8, as: UInt64.self))
                let 长度 = Int(raw.load(fromByteOffset: off + 16, as: UInt64.self))
                guard 偏移 >= 0, 长度 >= 0, 偏移 + 长度 <= raw.count else { continue }
                var 载荷 = [UInt8](UnsafeRawBufferPointer(rebasing: raw[偏移..<偏移 + 长度]))
                if 压 == 1,
                   let 解 = try? (Data(载荷) as NSData).decompressed(using: .zlib) as Data {
                    载荷 = [UInt8](解)
                }
                列表.append(块(切片: 切片, x: x, y: y, 压缩: 压, 数据: 载荷))
            }
            return 解包结果(边长: 边长, 切片数: 切片数, 块: 列表)
        }
    }

    // MARK: 落盘

    struct 写出结果 {
        var 条目: [容器清单.绘画条目]
    }

    static func 写出(_ 快照: 绘画快照, 到 st: 容器存储, 旧条目: [容器清单.绘画条目]) -> 写出结果 {
        var 条目: [容器清单.绘画条目] = []

        // 图层元信息：单文件存，几 KB
        if let 图层数据 = 编码图层(快照) {
            _ = st.写(项目容器.布局.绘画索引, 图层数据)
        }

        for 物 in 快照.物体 {
            for (通道, 字节) in 物.通道.sorted(by: { $0.key < $1.key }) {
                let 名 = "\(物.物体ID.uuidString.lowercased())-\(通道).cgp"
                let 路径 = 项目容器.布局.绘画 + "/" + 名

                // revision 相同且块在 → 这次这一块一个字节都没变，跳过
                if 快照.revision > 0,
                   let 旧 = 旧条目.first(where: { $0.物体ID == 物.物体ID && $0.通道 == 通道 }),
                   旧.revision == 快照.revision,
                   st.大小(路径) != nil {
                    条目.append(旧)
                    continue
                }

                let data = Data(字节)
                if st.写(路径, data) {
                    条目.append(.init(物体ID: 物.物体ID, 文件: 名, 通道: 通道,
                                     revision: 快照.revision, 字节: data.count))
                }
            }
        }
        return 写出结果(条目: 条目)
    }

    static func 读取(_ 条目: [容器清单.绘画条目], 从 st: 容器存储) -> 绘画快照? {
        guard !条目.isEmpty else { return nil }
        var 物: [UUID: 物体绘画快照] = [:]

        let 图层表 = 取图层(st)
        for e in 条目 {
            guard let data = st.读(项目容器.布局.绘画 + "/" + e.文件) else { continue }
            var 快 = 物[e.物体ID] ?? 物体绘画快照(物体ID: e.物体ID,
                                             图层: 图层表[e.物体ID] ?? [],
                                             当前图层: 0,
                                             通道: [:])
            快.通道[e.通道] = [UInt8](data)
            物[e.物体ID] = 快
        }
        guard !物.isEmpty else { return nil }
        return 绘画快照(revision: 条目.first?.revision ?? 0,
                     物体: 物.values.sorted { $0.物体ID.uuidString < $1.物体ID.uuidString })
    }

    // MARK: 图层元信息

    static let 图层记录名 = "paint-layers"

    private static func 编码图层(_ 快照: 绘画快照) -> Data? {
        let 表: [String: [绘画图层快照]] = Dictionary(
            uniqueKeysWithValues: 快照.物体.map { ($0.物体ID.uuidString, $0.图层) }
        )
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(表) else { return nil }
        return (try? (data as NSData).compressed(using: .zlib) as Data) ?? data
    }

    private static func 取图层(_ st: 容器存储) -> [UUID: [绘画图层快照]] {
        guard let raw = st.读(项目容器.布局.绘画索引) else { return [:] }
        let data = (try? (raw as NSData).decompressed(using: .zlib) as Data) ?? raw
        let decoder = JSONDecoder()
        guard let 表 = try? decoder.decode([String: [绘画图层快照]].self, from: data) else { return [:] }
        var 结果: [UUID: [绘画图层快照]] = [:]
        for (k, v) in 表 {
            if let id = UUID(uuidString: k) { 结果[id] = v }
        }
        return 结果
    }

    static func 清理孤儿(_ 条目: [容器清单.绘画条目], 到 st: 容器存储) -> [容器清单.绘画条目] {
        let 保留 = Set(条目.map(\.文件))
        guard st.是目录 else {
            // 同几何：单文件形态删不掉字节，但孤儿必须从索引摘掉，否则 compact 认为没有垃圾
            let 前缀 = 项目容器.布局.绘画 + "/"
            let 孤儿 = st.条目().filter { 名 in
                名.hasPrefix(前缀) && 名.hasSuffix(".cgp")
                    && !保留.contains(String(名.dropFirst(前缀.count)))
            }
            st.移除(孤儿)
            return 条目
        }
        let 目录 = st.根.appendingPathComponent(项目容器.布局.绘画, isDirectory: true)
        guard let 文件 = try? FileManager.default.contentsOfDirectory(atPath: 目录.path) else { return 条目 }
        for 名 in 文件 where 名.hasSuffix(".cgp") && !保留.contains(名) {
            try? FileManager.default.removeItem(at: 目录.appendingPathComponent(名))
        }
        return 条目
    }
}
