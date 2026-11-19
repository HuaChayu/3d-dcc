import Foundation

// MARK: - 单文件 .cg 容器的只读实现
//
// 预览扩展跑在自己的进程里，不能引用主 App 的存储层，所以这里只保留「读」的最小实现：
//   0   魔数 "CGPKG\0\0\0"
//   8   版本 u32 / 保留 u32
//   16  meta A（32B）   序号 u32 | 索引偏移 u64 | 索引长度 u32 | 索引CRC u32 | 标志 u32 | 保留
//   48  meta B（32B）
//   80  数据区（块 16B 对齐）
//   ..  索引（每次提交追加一份新的，A/B 两份 meta 指向最新那份）
//
// 整个文件一次 mmap，块直接切片交给下游，不复制、不解压、不解析中间格式。
final class CGContainer {
    struct 条目 {
        let 偏移: Int
        let 长度: Int
    }

    static let 魔数: [UInt8] = [0x43, 0x47, 0x50, 0x4B, 0x47, 0x00, 0x00, 0x00] // "CGPKG\0\0\0"
    static let 头长 = 80
    static let metaA = 16
    static let metaB = 48
    static let meta长 = 32
    static let meta标志: UInt32 = 0x4347_504B

    private let 基址: UnsafeMutableRawPointer
    private let 总长: Int
    private var 表: [String: 条目] = [:]

    /// 目录形态或者读不出来就返回 nil，交给调用方回退到老逻辑
    init?(路径: URL) {
        let fd = open(路径.path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        let 长 = Int(lseek(fd, 0, SEEK_END))
        guard 长 > CGContainer.头长 else { return nil }
        guard let p = mmap(nil, 长, PROT_READ, MAP_PRIVATE, fd, 0), p != MAP_FAILED else { return nil }
        基址 = p
        总长 = 长

        let b = p.assumingMemoryBound(to: UInt8.self)
        for i in 0..<8 where b[i] != CGContainer.魔数[i] {
            munmap(p, 长)
            return nil
        }
        guard 载入索引(配: b) else {
            munmap(p, 长)
            return nil
        }
    }

    deinit { munmap(基址, 总长) }

    // MARK: 对外

    func 有(_ 名: String) -> Bool { 表[名] != nil }

    func 读(_ 名: String) -> Data? {
        guard let e = 表[名], e.长度 > 0, e.偏移 + e.长度 <= 总长 else { return nil }
        // bytesNoCopy：返回的是映射里的切片，SCNGeometry 用完即弃，不做多余拷贝
        return Data(bytesNoCopy: 基址 + e.偏移, count: e.长度, deallocator: .none)
    }

    func 条目名() -> [String] { Array(表.keys) }

    // MARK: 索引

    private func 载入索引(配 b: UnsafePointer<UInt8>) -> Bool {
        var 最佳: (序: UInt32, 偏移: Int, 长度: Int, crc: UInt32)?
        for 位置 in [CGContainer.metaA, CGContainer.metaB] {
            guard let m = 读meta(b, 位置), m.偏移 + m.长度 <= 总长, m.长度 > 0 else { continue }
            if 最佳 == nil || m.序 > 最佳!.序 { 最佳 = m }
        }
        guard let 选中 = 最佳 else { return false }

        let 索引 = UnsafeRawPointer(b + 选中.偏移)
        guard CGContainer.crc32(索引, 选中.长度) == 选中.crc else { return false }

        var p = 0
        func u32(_ off: Int) -> UInt32 {
            UnsafeRawPointer(b + 选中.偏移 + off).loadUnaligned(as: UInt32.self)
        }
        func u16(_ off: Int) -> UInt16 {
            UnsafeRawPointer(b + 选中.偏移 + off).loadUnaligned(as: UInt16.self)
        }
        func u64(_ off: Int) -> UInt64 {
            UnsafeRawPointer(b + 选中.偏移 + off).loadUnaligned(as: UInt64.self)
        }
        guard 选中.长度 >= 4 else { return false }
        let 数 = Int(u32(0))
        p = 4
        var 出: [String: 条目] = [:]
        出.reserveCapacity(数)
        for _ in 0..<数 {
            guard p + 2 <= 选中.长度 else { return false }
            let 名长 = Int(u16(p))
            p += 2
            guard 名长 > 0, p + 名长 + 12 <= 选中.长度 else { return false }
            let 名 = String(decoding: UnsafeRawBufferPointer(start: b + 选中.偏移 + p, count: 名长), as: UTF8.self)
            p += 名长
            let 偏移 = u64(p)
            p += 8
            let 长度 = u32(p)
            p += 4
            guard 偏移 < UInt64(总长) else { continue }
            出[名] = 条目(偏移: Int(偏移), 长度: Int(长度))
        }
        表 = 出
        return !表.isEmpty
    }

    private func 读meta(_ b: UnsafePointer<UInt8>, _ 位置: Int) -> (序: UInt32, 偏移: Int, 长度: Int, crc: UInt32)? {
        let 标志 = UnsafeRawPointer(b + 位置 + 20).loadUnaligned(as: UInt32.self)
        guard 标志 == CGContainer.meta标志 else { return nil }
        let 序 = UnsafeRawPointer(b + 位置).loadUnaligned(as: UInt32.self)
        let 偏移 = UnsafeRawPointer(b + 位置 + 4).loadUnaligned(as: UInt64.self)
        let 长度 = UnsafeRawPointer(b + 位置 + 12).loadUnaligned(as: UInt32.self)
        let crc = UnsafeRawPointer(b + 位置 + 16).loadUnaligned(as: UInt32.self)
        guard 偏移 > 0, 长度 > 0, 偏移 < UInt64(Int.max) else { return nil }
        return (序, Int(偏移), Int(长度), crc)
    }

    private static let crc表: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1) }
        return c
    }

    private static func crc32(_ p: UnsafeRawPointer, _ n: Int) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        let b = p.assumingMemoryBound(to: UInt8.self)
        var i = 0
        while i < n {
            c = crc表[Int((c ^ UInt32(b[i])) & 0xFF)] ^ (c >> 8)
            i += 1
        }
        return c ^ 0xFFFF_FFFF
    }
}
