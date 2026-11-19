import Foundation

// MARK: - 容器存储后端
//
// 容器有两种物理形态，上层（清单 / 场景 / 几何 / 绘画）不需要知道自己落在哪种上：
//   · 目录形态：老的 .cg 包，一个条目一个文件（保留只读兼容，老工程照样能打开）
//   · 单文件形态：新的 .cg，全部条目打进一个文件，尾部索引 + 双 meta 原子提交
//
// 单文件不是 zip：几何块原样存放、16B 对齐，读取路径仍然是 mmap 切片零拷贝。
// 增量靠「条目按内容寻址命名 + 已存在同长度就跳过」，只有变化块才会被追加，
// 旧块变成垃圾，攒够比例再 compact。

protocol 容器存储: AnyObject {
    var 根: URL { get }
    var 是目录: Bool { get }
    /// 条目已存在时返回字节数，否则 nil
    func 大小(_ 名: String) -> Int?
    func 读(_ 名: String) -> Data?
    @discardableResult func 写(_ 名: String, _ data: Data) -> Bool
    /// 目录形态什么都不做；单文件形态在这里落索引
    @discardableResult func 提交() -> Bool
    func 条目() -> [String]
    /// 把条目从索引里摘掉，物理字节留给 compact 回收。
    /// 目录形态一个条目就是一个文件，孤儿清理直接删文件，这里不需要做任何事。
    @discardableResult func 移除(_ 名们: [String]) -> Int
}

extension 容器存储 {
    @discardableResult func 移除(_ 名们: [String]) -> Int { 0 }
}
// MARK: - CRC32

enum 块校验 {
    static let 表: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1) }
        return c
    }

    static func 算(_ p: UnsafeRawPointer, _ n: Int) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        let b = p.assumingMemoryBound(to: UInt8.self)
        var i = 0
        while i < n {
            c = 表[Int((c ^ UInt32(b[i])) & 0xFF)] ^ (c >> 8)
            i += 1
        }
        return c ^ 0xFFFF_FFFF
    }

    static func 算(_ d: Data) -> UInt32 {
        let n = d.count
        if n == 0 { return 0 }
        return d.withUnsafeBytes { 算($0.baseAddress!, n) }
    }
}

// MARK: - 单文件形态

/// 文件布局（小端）：
/// ```
/// 0    魔数 "CGPKG\0\0\0"          8B
/// 8    版本 u32
/// 12   保留 u32
/// 16   meta A                      32B
/// 48   meta B                      32B
/// 80   数据区（每个条目 16B 对齐）
/// ..   索引（每次提交追加一份新索引）
/// ```
/// meta 结构 32B：序号 u32 | 索引偏移 u64 | 索引长度 u32 | 索引CRC u32 | 标志 u32 | 保留 8B
///
/// 提交顺序：先追加数据 → 再追加索引 → 最后写一份 meta（A/B 交替，序号自增）。
/// 任何时刻断电，读侧取「CRC 正确且序号最大」的那份 meta，最多丢掉最后一次写。
final class 单文件存储: 容器存储 {
    static let 魔数: [UInt8] = [0x43, 0x47, 0x50, 0x4B, 0x47, 0x00, 0x00, 0x00] // "CGPKG"
    static let 版本: UInt32 = 1
    static let 头长 = 80
    static let metaA = 16
    static let metaB = 48
    static let meta长 = 32
    static let meta标志: UInt32 = 0x4347_504B
    static let 数据起 = 80

    let 根: URL
    var 是目录: Bool { false }

    private var fd: Int32 = -1
    private var 条目表: [String: (偏移: Int, 长度: Int)] = [:]
    private var 序号: UInt32 = 0
    private var 下次序号: UInt32 = 0
    private var 写尾: Int = 单文件存储.数据起
    private var 映射: UnsafeMutableRawPointer?
    private var 映射长: Int = 0
    private var 待提交 = false
    private var 新条目数 = 0

    init?(_ root: URL) {
        self.根 = root
        guard 打开() else { return nil }
    }

    deinit { 关闭() }

    // MARK: 打开 / 关闭

    private func 打开() -> Bool {
        let 路径 = 根.path
        if !FileManager.default.fileExists(atPath: 路径) {
            try? FileManager.default.createDirectory(at: 根.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
        }
        fd = open(路径, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else { return false }
        let 长 = Int(lseek(fd, 0, SEEK_END))
        if 长 < 单文件存储.头长 {
            return 初始化空文件()
        }
        return 读元信息(文件长: 长)
    }

    func 关闭() {
        解除映射()
        if fd >= 0 { close(fd); fd = -1 }
    }

    /// 把活条目搬到新文件再整体替换，垃圾块（被同一条目的新版本顶掉的旧块）清零。
    /// 阈值卡在「总量 > 4MB 且垃圾 > 30%」，小文件的复制开销不值得。
    ///
    /// 「活」的判据只看**索引里还登记着的条目**：不再被清单引用的块必须先由
    /// 清理孤儿 → 移除(_:) 从索引里摘掉，否则它们会被当成活块算进分母，
    /// 垃圾比例永远算成 0，compact 就永远不会触发（旧实现就是这样静默不干活的）。
    @discardableResult
    func 整理() -> Bool {
        guard fd >= 0 else { return 记整理失败("文件句柄无效") }
        let 总 = Int(lseek(fd, 0, SEEK_END))
        guard 总 > 4 << 20 else { return 记整理失败("总量 \(总)B 未超过 4MB") }
        let 活 = 条目表.values.reduce(0) { $0 + $1.长度 }
        let 垃圾比 = Double(总 - 活) / Double(总)
        guard 垃圾比 > 0.3 else {
            return 记整理失败("垃圾 \(总 - 活)B 占比 \(String(format: "%.1f%%", 垃圾比 * 100)) 未超过 30%")
        }

        let tmp = 根.deletingLastPathComponent()
            .appendingPathComponent(".\(根.lastPathComponent).compact-\(UUID().uuidString.prefix(6))")
        try? FileManager.default.removeItem(at: tmp)
        guard let 新 = 单文件存储(tmp) else { return 记整理失败("临时容器创建失败 \(tmp.lastPathComponent)") }
        for (名, _) in 条目表 {
            if let d = 读(名) { _ = 新.写(名, d) }
        }
        guard 新.提交() else {
            新.关闭()
            try? FileManager.default.removeItem(at: tmp)
            return 记整理失败("临时容器提交失败")
        }
        新.关闭()

        // 先断开自己的映射与句柄，再整体替换；POSIX 下别处已经拿到的旧映射仍然有效
        解除映射()
        条目表 = [:]
        待提交 = false
        if fd >= 0 { close(fd) }
        fd = -1
        do {
            _ = try FileManager.default.replaceItemAt(根, withItemAt: tmp)
        } catch {
            // 替换失败：原文件还在原地、内容完好，只是白算一遍。别把失败吞掉，
            // 否则下次还是「阈值够了却不整理」，又变成查不出的静默 bug。
            fd = open(根.path, O_RDWR)
            try? FileManager.default.removeItem(at: tmp)
            if fd >= 0 { _ = 读元信息(文件长: Int(lseek(fd, 0, SEEK_END))) }
            return 记整理失败("整体替换失败 \(error.localizedDescription)")
        }
        try? FileManager.default.removeItem(at: tmp)

        fd = open(根.path, O_RDWR)
        guard fd >= 0 else { return 记整理失败("整理后重新打开失败") }
        return 读元信息(文件长: Int(lseek(fd, 0, SEEK_END)))
    }

    /// 设置 `CG_COMPACT_DEBUG=1` 时把不整理的原因打到 stderr，平时零开销。
    private func 记整理失败(_ 原因: @autoclosure () -> String) -> Bool {
        if ProcessInfo.processInfo.environment["CG_COMPACT_DEBUG"] == "1" {
            FileHandle.standardError.write(Data("[compact] \(根.lastPathComponent): \(原因())\n".utf8))
        }
        return false
    }

    /// 只摘索引、不动物理字节：孤儿块从此不再算「活」，下一次 整理() 会把它们真正回收掉。
    @discardableResult
    func 移除(_ 名们: [String]) -> Int {
        var 删 = 0
        for 名 in 名们 where 条目表.removeValue(forKey: 名) != nil { 删 += 1 }
        if 删 > 0 { 待提交 = true }
        return 删
    }

    private func 初始化空文件() -> Bool {
        var 头 = [UInt8](repeating: 0, count: 单文件存储.头长)
        for (i, b) in 单文件存储.魔数.enumerated() { 头[i] = b }
        头.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: 单文件存储.版本, toByteOffset: 8, as: UInt32.self)
        }
        guard pwrite(fd, 头, 单文件存储.头长, 0) == 单文件存储.头长 else { return false }
        条目表 = [:]
        写尾 = 单文件存储.头长
        序号 = 0
        下次序号 = 1
        待提交 = true
        return 提交()
    }

    private func 读元信息(文件长: Int) -> Bool {
        var 头 = [UInt8](repeating: 0, count: 单文件存储.头长)
        guard pread(fd, &头, 单文件存储.头长, 0) == 单文件存储.头长 else { return false }
        for i in 0..<8 where 头[i] != 单文件存储.魔数[i] { return false }

        var 最佳: (序号: UInt32, 偏移: Int, 长度: Int, crc: UInt32)?
        for 位置 in [单文件存储.metaA, 单文件存储.metaB] {
            guard let m = 解析meta(头, 位置), m.偏移 + m.长度 <= 文件长, m.长度 > 0 else { continue }
            if 最佳 == nil || m.序号 > 最佳!.序号 { 最佳 = m }
        }
        guard let 选中 = 最佳 else { return false }

        var 索引 = [UInt8](repeating: 0, count: 选中.长度)
        guard pread(fd, &索引, 选中.长度, off_t(选中.偏移)) == 选中.长度 else { return false }
        guard 索引.withUnsafeBytes({ 块校验.算($0.baseAddress!, 选中.长度) }) == 选中.crc else { return false }
        guard 解析索引(索引) else { return false }

        序号 = 选中.序号
        下次序号 = 选中.序号 &+ 1
        // 写尾取所有条目与索引末尾的最大值，保证追加不会覆盖已有数据
        var 尾 = 单文件存储.头长
        for (_, v) in 条目表 { 尾 = max(尾, v.偏移 + v.长度) }
        尾 = max(尾, 选中.偏移 + 选中.长度)
        写尾 = (尾 + 15) & ~15
        return true
    }

    private func 解析meta(_ 头: [UInt8], _ 位置: Int) -> (序号: UInt32, 偏移: Int, 长度: Int, crc: UInt32)? {
        let 片 = 头[位置..<(位置 + 单文件存储.meta长)]
        let b = Array(片)
        return b.withUnsafeBytes { raw -> (UInt32, Int, Int, UInt32)? in
            let 标志 = raw.loadUnaligned(fromByteOffset: 20, as: UInt32.self)
            guard 标志 == 单文件存储.meta标志 else { return nil }
            let 序号 = raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
            let 偏移 = raw.loadUnaligned(fromByteOffset: 4, as: UInt64.self)
            let 长度 = raw.loadUnaligned(fromByteOffset: 12, as: UInt32.self)
            let crc = raw.loadUnaligned(fromByteOffset: 16, as: UInt32.self)
            guard 偏移 > 0, 长度 > 0, 偏移 < UInt64(Int.max) else { return nil }
            return (序号, Int(偏移), Int(长度), crc)
        }
    }

    private func 写meta(_ 序号: UInt32, 索引偏移: Int, 索引长度: Int, crc: UInt32) -> Bool {
        var 缓冲 = [UInt8](repeating: 0, count: 单文件存储.meta长)
        缓冲.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: 序号, toByteOffset: 0, as: UInt32.self)
            raw.storeBytes(of: UInt64(索引偏移), toByteOffset: 4, as: UInt64.self)
            raw.storeBytes(of: UInt32(索引长度), toByteOffset: 12, as: UInt32.self)
            raw.storeBytes(of: crc, toByteOffset: 16, as: UInt32.self)
            raw.storeBytes(of: 单文件存储.meta标志, toByteOffset: 20, as: UInt32.self)
        }
        // A/B 交替写，始终有一份是完整的旧版本
        let 位置 = (序号 % 2 == 0) ? 单文件存储.metaB : 单文件存储.metaA
        return pwrite(fd, 缓冲, 单文件存储.meta长, off_t(位置)) == 单文件存储.meta长
    }

    // MARK: 索引

    private func 序列化索引() -> Data {
        var d = Data(capacity: 1024)
        var 数 = UInt32(条目表.count)
        withUnsafeBytes(of: &数) { d.append(contentsOf: $0) }
        for (名, v) in 条目表.sorted(by: { $0.key < $1.key }) {
            let 名字节 = Array(名.utf8)
            var 名长 = UInt16(名字节.count)
            var 偏移 = UInt64(v.偏移)
            var 长度 = UInt32(v.长度)
            withUnsafeBytes(of: &名长) { d.append(contentsOf: $0) }
            d.append(contentsOf: 名字节)
            withUnsafeBytes(of: &偏移) { d.append(contentsOf: $0) }
            withUnsafeBytes(of: &长度) { d.append(contentsOf: $0) }
        }
        return d
    }

    private func 解析索引(_ d: [UInt8]) -> Bool {
        guard d.count >= 4 else { return false }
        var 表: [String: (偏移: Int, 长度: Int)] = [:]
        var p = 0
        let 数 = Int(d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) })
        p = 4
        for _ in 0..<数 {
            guard p + 2 <= d.count else { return false }
            let 名长 = Int(d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: p, as: UInt16.self) })
            p += 2
            guard 名长 > 0, p + 名长 + 12 <= d.count else { return false }
            let 名 = String(decoding: d[p..<(p + 名长)], as: UTF8.self)
            p += 名长
            let 偏移 = d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: p, as: UInt64.self) }
            p += 8
            let 长度 = d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: p, as: UInt32.self) }
            p += 4
            表[名] = (Int(偏移), Int(长度))
        }
        条目表 = 表
        return true
    }

    // MARK: 读写

    func 大小(_ 名: String) -> Int? {
        条目表[名]?.长度
    }

    func 条目() -> [String] { Array(条目表.keys) }

    /// 同名再写 = 追加一块新版本并改索引，旧块降级成垃圾。
    /// 这里不做「同长度就跳过」的优化：长度相同不代表内容相同（拓扑没变但顶点挪了就是这样），
    /// 要不要跳过由上层按内容寻址命名 + 大小判断，存储层只保证写进去的一定读得回来。
    @discardableResult
    func 写(_ 名: String, _ data: Data) -> Bool {
        guard fd >= 0, !data.isEmpty else { return false }
        let 起 = (写尾 + 15) & ~15
        if 起 > 写尾 { _ = ftruncate(fd, off_t(起)) }
        let n = data.withUnsafeBytes { p -> Int in
            guard let base = p.baseAddress else { return 0 }
            return Int(pwrite(fd, base, data.count, off_t(起)))
        }
        guard n == data.count else { return false }
        条目表[名] = (起, data.count)
        写尾 = 起 + data.count
        待提交 = true
        新条目数 += 1
        return true
    }

    func 读(_ 名: String) -> Data? {
        guard let e = 条目表[名], e.长度 > 0 else { return nil }
        guard 建立映射() else { return nil }
        guard let base = 映射, e.偏移 + e.长度 <= 映射长 else { return nil }
        return Data(bytesNoCopy: base + e.偏移, count: e.长度, deallocator: .none)
    }

    private func 建立映射() -> Bool {
        if 映射 != nil { return true }
        guard fd >= 0 else { return false }
        let 长 = Int(lseek(fd, 0, SEEK_END))
        guard 长 > 0 else { return false }
        guard let p = mmap(nil, 长, PROT_READ, MAP_PRIVATE, fd, 0), p != MAP_FAILED else { return false }
        映射 = p
        映射长 = 长
        return true
    }

    private func 解除映射() {
        if let p = 映射 { munmap(p, 映射长) }
        映射 = nil
        映射长 = 0
    }

    @discardableResult
    func 提交() -> Bool {
        guard fd >= 0 else { return false }
        if !待提交 { return true }
        let 索引 = 序列化索引()
        let crc = 块校验.算(索引)
        let 起 = (写尾 + 15) & ~15
        if 起 > 写尾 { _ = ftruncate(fd, off_t(起)) }
        let n = 索引.withUnsafeBytes { p -> Int in
            guard let base = p.baseAddress else { return 0 }
            return Int(pwrite(fd, base, 索引.count, off_t(起)))
        }
        guard n == 索引.count else { return false }
        下次序号 = 下次序号 &+ 1
        guard 写meta(下次序号, 索引偏移: 起, 索引长度: 索引.count, crc: crc) else { return false }
        _ = fsync(fd)
        序号 = 下次序号
        写尾 = 起 + 索引.count
        待提交 = false
        新条目数 = 0
        解除映射() // 文件变长，旧映射作废，下次读重建
        return true
    }

    /// 垃圾块占比（旧块被新块替换后留在文件里），超过阈值由上层择机 compact
    var 垃圾比例: Double {
        guard 映射长 > 0 || fd >= 0 else { return 0 }
        let 总 = Int(lseek(fd, 0, SEEK_END))
        let 活 = 条目表.values.reduce(0) { $0 + $1.长度 }
        guard 总 > 单文件存储.头长 else { return 0 }
        return max(0, Double(总 - 单文件存储.头长 - 活) / Double(总))
    }
}
