import AppKit
import CryptoKit
import Foundation
import UniformTypeIdentifiers

// MARK: - 容器清单

/// manifest.json 的内存形态。
///
/// 设计原则：**清单只放索引与元信息，任何一个字段都不允许随项目规模线性膨胀**。
/// 顶点、像素、笔迹这些大块数据一律落在独立文件里，清单只记「哪个对象、哪个文件、多大」，
/// 这样每次保存只写几 KB 清单 + 变化的块，改一个滑杆不会重写几百 MB。
struct 容器清单: Codable {

    struct 几何条目: Codable {
        var 网格ID: UUID
        var 文件: String        // 相对 geometry/
        var 子网格数: Int
        var 顶点数: Int
        var 索引数: Int
        var 字节: Int
        /// 上次写出时整块内容的校验（几何 + 名称/变换/子集）。
        /// 文件名只带几何指纹，块里还藏了子集这类元数据，光看文件名判断不了
        /// 「同名块是否同内容」，靠这个字段决定跳过还是原地重写。
        /// 老清单没有这个字段（= nil），首次保存会重写一次同名块，之后稳定。
        var 校验: String?
    }

    struct 绘画条目: Codable {
        var 物体ID: UUID
        var 文件: String        // 相对 paint/
        var 通道: String        // "baseColor" 或 PaintChannel.rawValue
        var revision: Int       // 写入时的全局笔迹版本，用来跳过没动过的对象
        var 字节: Int           // 稀疏化之后的实际占用
    }

    var 格式: String
    var 版本: UInt32
    var 创建: Date
    var 修改: Date
    var 应用: String
    /// 材质贴图块（导入的基础色图，原始 PNG/JPEG 字节）。
    /// 文件名带内容指纹 → 同名必同内容，写出时只看存在性就能跳过。
    struct 贴图条目: Codable {
        var 贴图ID: UUID
        var 文件: String        // 相对 texture/
        var 字节: Int
    }

    var 几何: [几何条目]
    var 绘画: [绘画条目]
    /// 材质贴图。老档案没有这个键 → nil，照常打开；首次保存时补齐。
    var 贴图: [贴图条目]? = nil
    /// 扩展记录键。未来加时间线、渲染历史、资产引用，都往 records/ 里丢一个键，
    /// 不用动版本号、不用改老档案的解析路径。
    var 记录: [String]
    /// 预留：任意字符串键值，留给格式演进时的兼容标记
    var 扩展: [String: String]

    static func 新建() -> 容器清单 {
        let now = Date()
        return 容器清单(
            格式: 项目容器.格式标识,
            版本: 项目容器.当前版本,
            创建: now,
            修改: now,
            应用: 项目容器.应用版本,
            几何: [],
            绘画: [],
            记录: [],
            扩展: [:]
        )
    }
}

/// 一次载入的全部内容。
struct 容器内容 {
    var 位置: URL
    var 清单: 容器清单
    var 快照: ProjectSnapshot
    var 几何: [UUID: [导入网格]]
    var 绘画: 绘画快照?
}

// MARK: - 容器本体

/// `.cg` 项目容器。
///
/// 物理形态是**单文件**（不是目录包）。这一点很关键：只要 UTI 还 conforms `com.apple.package`，
/// Finder 空格预览就会走系统「包」通道，第三方 QuickLook 扩展根本不会被拉起；
/// 改成单文件之后 .cg 和其它文档一样交给 appex 处理，预览 / 缩略图才真正可用。
///
/// 单文件内部仍是一套「虚拟目录」，条目和以前的文件一一对应：
/// ```
/// 未命名.cg   （单文件）
/// ├── manifest.json          清单：索引 + 元信息（几 KB）
/// ├── scene/project.json      项目参数（材质 / 物体 / 视口 / 渲染 / 队列，zlib）
/// ├── geometry/<网格ID>-<顶点数>-<索引数>-<内容指纹>.cgm   单网格块，16B 对齐，mmap 直读
/// │                            老文件的 <网格ID>-<顶点数>-<索引数>.cgm 仍按清单名照常读
/// ├── paint/index.json        绘画图层元数据
/// ├── paint/<物体ID>-<通道>.cgp                稀疏 tile 块，只存非空块
/// ├── records/<名>.json       扩展区：任意记录名 → Codable（zlib）
/// ├── thumbnail.png           QuickLook 缩略图（512×512）
/// └── QuickLook/Thumbnail.png 同上（兼容老版本 qlgenerator）
/// ```
///
/// 文件体内是「数据区 + 尾部索引 + 双 meta」，写入只追加、索引整份重写（几 KB），
/// meta 最后落，所以原子性、增量、mmap 三样都不丢。老的目录形态仍然可读，
/// 见 `容器存储`。
///
/// 三条硬约束，全部为了让「保存快、载入快、体积小」同时成立：
/// 1. **增量**：几何按「网格ID + 顶点数 + 索引数」命名，文件已存在就跳过；
///    绘画按 revision 跳过没动过的对象。保存成本只和「这次改了多少」有关。
/// 2. **原子**：单个文件先写 .tmp 再 replace，绝不半截；清单最后写，
///    清单里指不到的孤儿文件在下次保存时清掉。
/// 3. **零解释**：所有大块数据都是定长二进制，载入 = mmap + memcpy，
///    不存在 JSON 解析，不存在 string → float 的逐字符转换。
enum 项目容器 {

    // MARK: 常量

    static let 扩展名 = "cg"
    static let 格式标识 = "cg"
    static let 当前版本: UInt32 = 1
    /// 与 Info.plist 的 UTExportedTypeDeclarations 保持一致
    static let 类型标识符 = "com.3drender.project.cg"

    enum 布局 {
        static let 清单 = "manifest.json"
        static let 场景 = "scene"
        static let 场景文件 = "scene/project.json"
        static let 几何 = "geometry"
        static let 绘画 = "paint"
        static let 绘画索引 = "paint/index.json"
        /// 材质贴图字节（一块一张图，内容寻址）
        static let 贴图 = "texture"
        static let 记录 = "records"
        static let 缩略图 = "thumbnail.png"
        static let 预览 = "QuickLook/Thumbnail.png"
    }

    static var 应用版本: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0"
    }

    /// 运行期类型：Finder / 拖放 / 打开面板都用它。
    /// 注意 conforms `.data` 而不是 `.package`：包类型会让 QuickLook 走系统的包预览通道，
    /// 把我们的 appex 完全绕过去（这就是之前空格预览一直不出图的原因）。
    static var 文件类型: UTType {
        UTType(exportedAs: 类型标识符, conformingTo: .data)
    }

    static var 项目目录: URL { LocalStore.存档目录 }

    /// 出厂项目容器。首次启动建在这里；用户打开过别的 .cg 之后就不再指向它。
    static var 默认项目: URL {
        项目目录.appendingPathComponent("未命名.\(扩展名)", isDirectory: false)
    }

    /// 当前活动项目容器。所有不带显式 root 的读写都落到这里，
    /// 打开 / 另存为 / 拖放 / 双击文件只改这一个指针，写盘线程每次取最新值，
    /// 所以切换项目之后不会有残留的写入跑到旧目录去。
    private static let 当前锁 = NSLock()
    private static var _当前项目: URL = 默认项目

    static var 当前项目: URL {
        get {
            当前锁.lock()
            defer { 当前锁.unlock() }
            return _当前项目
        }
        set {
            当前锁.lock()
            _当前项目 = newValue
            当前锁.unlock()
        }
    }

    /// 拿到这个容器对应的存储后端。**只认单文件形态**。
    ///
    /// 旧的目录包（目录形态的 .cg）从这一版起不再兼容：命中目录直接返回 nil，
    /// 上层按「无法打开」处理（`是容器` 也会先把它挡掉），不会再走目录读写路径。
    /// 文件不存在时不返回 nil —— `单文件存储` 打开时会自己建头，新建项目靠的就是这条。
    static func 后端(_ root: URL) -> 容器存储? {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue {
            return nil
        }
        return 单文件存储(root)
    }

    static func 是容器(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
            return false
        }
        // 单文件形态：认头 8 字节魔数
        guard let fh = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? fh.close() }
        let 头 = (try? fh.read(upToCount: 8)) ?? Data()
        return 头.count == 8 && Array(头) == 单文件存储.魔数
    }

    /// 老目录包 → 新单文件。先把所有条目搬进临时容器，落盘成功后才替换原路径，
    /// 中途失败原目录原样留着，最坏结果是这次没搬成。
    /// 顺带把 `com.apple.package` 的包标记去掉，否则 Finder 仍走 Package 通道。
    @discardableResult
    static func 读清单(_ root: URL, 存储 外: 容器存储? = nil) -> 容器清单? {
        guard let st = 外 ?? 后端(root) else { return nil }
        guard let data = st.读(布局.清单) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(容器清单.self, from: data)
    }

    /// 传了 `存储` 表示调用方会统一提交（一次保存只落一次索引），没传就自己提交。
    @discardableResult
    static func 写清单(_ 清单: 容器清单, 到 root: URL, 存储 外: 容器存储? = nil) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(清单) else { return false }
        guard let st = 外 ?? 后端(root) else { return false }
        guard st.写(布局.清单, data) else { return false }
        return 外 == nil ? st.提交() : true
    }

    /// 先写临时文件再 replace，保证任何时刻磁盘上都是「完整的旧版」或「完整的新版」。
    @discardableResult
    static func 原子写(_ data: Data, 到 url: URL) -> Bool {
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent + ".tmp-\(UUID().uuidString.prefix(8))")
        do {
            try data.write(to: tmp, options: .atomic)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            return true
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            // replaceItemAt 在目标不存在时会抛错，这里退化成直接搬过去
            do {
                try data.write(to: url, options: .atomic)
                return true
            } catch {
                return false
            }
        }
    }

    // MARK: 场景参数

    static func 存场景(_ 快照: ProjectSnapshot, 到 root: URL, 存储 外: 容器存储? = nil) -> Bool {
        guard let json = LocalStore.编码(快照) else { return false }
        let 压 = (try? (json as NSData).compressed(using: .zlib) as Data) ?? json
        guard let st = 外 ?? 后端(root) else { return false }
        guard st.写(布局.场景文件, 压) else { return false }
        return 外 == nil ? st.提交() : true
    }

    static func 取场景(_ root: URL, 存储 外: 容器存储? = nil) -> ProjectSnapshot? {
        guard let st = 外 ?? 后端(root) else { return nil }
        guard let raw = st.读(布局.场景文件) else { return nil }
        // 先按 zlib 解，解不开当明文（兼容手工改过的档案）
        let json = (try? (raw as NSData).decompressed(using: .zlib) as Data) ?? raw
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ProjectSnapshot.self, from: json)
    }

    // MARK: 扩展记录区

    /// 写一条记录。任意 Codable 都能塞，未来加功能不必改容器格式。
    @discardableResult
    static func 写记录<T: Encodable>(_ 值: T, 名: String, 到 root: URL, 存储 外: 容器存储? = nil) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(值) else { return false }
        let 压 = (try? (data as NSData).compressed(using: .zlib) as Data) ?? data
        guard let st = 外 ?? 后端(root) else { return false }
        guard st.写(布局.记录 + "/\(名).json", 压) else { return false }
        var 清单 = 读清单(root, 存储: st) ?? .新建()
        if !清单.记录.contains(名) { 清单.记录.append(名) }
        清单.修改 = .now
        guard 写清单(清单, 到: root, 存储: st) else { return false }
        return 外 == nil ? st.提交() : true
    }

    static func 读记录<T: Decodable>(_ 类型: T.Type, 名: String, 从 root: URL, 存储 外: 容器存储? = nil) -> T? {
        guard let st = 外 ?? 后端(root) else { return nil }
        guard let raw = st.读(布局.记录 + "/\(名).json") else { return nil }
        let data = (try? (raw as NSData).decompressed(using: .zlib) as Data) ?? raw
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(类型, from: data)
    }

    // MARK: 保存

    /// 全量保存（内部逐块做增量判断）。
    ///
    /// - Parameters:
    ///   - 快照: 项目参数（不含几何池）
    ///   - 几何池: 导入网格池，按网格 ID 分块落盘
    ///   - 绘画: 稀疏化后的绘画数据，nil 表示本次不动绘画
    @discardableResult
    static func 保存(_ 快照: ProjectSnapshot,
                     几何池: [UUID: [导入网格]],
                     绘画: 绘画快照?,
                     到 root: URL,
                     刷新聚焦图: Bool = true,
                     整理容器: Bool = true,
                     版本表: [UUID: UInt64] = [:]) -> Bool {
        // 老目录包第一次保存就顺手升级，之后所有写入都落在单文件里
        guard let st = 后端(root) else { return false }
        var 清单 = 读清单(root, 存储: st) ?? .新建()
        清单.修改 = .now

        // 1) 几何：内容寻址，已存在就跳过
        let 几何结果 = 容器几何.写出(几何池, 到: st, 旧条目: 清单.几何, 版本表: 版本表)
        清单.几何 = 几何结果.条目

        // 2) 场景参数：几十 KB，每次都写
        guard 存场景(快照, 到: root, 存储: st) else { return false }

        // 3) 绘画：稀疏 tile，revision 没变就跳过
        if let 绘画 {
            let 结果 = 容器绘画.写出(绘画, 到: st, 旧条目: 清单.绘画)
            清单.绘画 = 结果.条目
        }

        // 3.5) 材质贴图：内容寻址，同名同内容就跳过。
        //      只写「纹理库里还在的」贴图 —— 换项目/清空之后留下的死引用不会污染新档。
        let 贴图结果 = 容器贴图.写出(材质接线.共享.全部源图字节(), 到: st)
        清单.贴图 = 贴图结果.条目

        // 4) 缩略图占位：先塞一张示意图，保证任何情况下容器里都有一张位图。
        //    真正给 Finder 看的是提交之后用「聚焦取景」渲出来的那张（见第 7 步），
        //    这里只是兜底，防止渲染失败时图标变成系统默认空白。
        if let png = 容器缩略图.生成(快照: 快照) {
            _ = st.写(布局.缩略图, png)
            _ = st.写(布局.预览, png)
        }

        // 5) 清单最后写：清单没落地 = 新块视为孤儿，下次被清掉，不会污染旧档
        清单.几何 = 容器几何.清理孤儿(清单.几何, 到: st)
        清单.绘画 = 容器绘画.清理孤儿(清单.绘画, 到: st)
        清单.贴图 = 容器贴图.清理孤儿(清单.贴图 ?? [], 到: st)
        guard 写清单(清单, 到: root, 存储: st) else { return false }
        guard st.提交() else { return false }

        // 6) 追加写会留下被替换掉的旧块，攒多了要压一遍 —— 但**不在保存栈里做**。
        //    compact = 全量读活块 + 写临时文件 + replaceItemAt，O(文件大小)，
        //    217MB 的工程压一次就是一秒级的主线程卡顿（⌘S 转圈的主因之一）。
        //    这里只往写队列上挂一个「延后 3 秒、期间再保存就重新计时」的任务：
        //    仍是同一条串行队列 → 和 append / 索引提交不会并发；
        //    不在主线程 → 用户继续编辑不卡；连续编辑只压最后一版。
        //    阈值语义（垃圾 >30% 且总量 >4MB）原样留在 单文件存储.整理() 里。
        //    自动保护文件不需要压：它每次都是全量重写，压了纯属多一次 IO。
        if 整理容器, st is 单文件存储 {
            存档写入器.shared.排后台整理(到: root)
        }

        // 7) 聚焦图 + Finder 图标：容器已经完整落盘，这时才用「和空格预览完全相同的
        //    场景构建 + 机位」离屏渲一张，覆盖掉第 4 步的示意图，并设成 .cg 的文件图标。
        //    放在提交之后是必须的：场景加载只认已经登记进清单的几何块。
        //    注意这里是「排队」不是当场渲：渲染要完整反序列化 + 建全量顶点 + 离屏出图，
        //    放在保存里会把这批保存全部堵住；连续保存（拖滑杆）时还会重复渲同一张图。
        //    改成「最后一次保存之后 0.5s 在写队列上渲一次」：一批保存只渲最后一张，
        //    且排在这里的渲不会和 append / compact 并发（避免撕裂读）。
        //    自动保存写独立保护文件时不刷聚焦图：那不是用户工程，没必要为它渲图。
        if 刷新聚焦图 {
            存档写入器.shared.排刷新聚焦(到: root)
        }
        return true
    }

    /// 渲染聚焦图 → 写回容器里的两块 PNG → 设为 .cg 的文件图标。
    ///
    /// 全程只读容器、只替换位图块，任何一步失败都静默跳过：
    /// 图标是锦上添花，绝不能因为它把工程本身弄坏。
    static func 刷新聚焦图标(到 root: URL) {
        guard 是容器(root), let png = 容器缩略图.渲染聚焦(容器: root) else { return }
        回写聚焦图(png, 到: root)
    }

    /// 清单 扩展 里记「这张缩略图是按哪份几何 + 哪个对象列表渲的」的键名。
    static let 缩略图键名 = "缩略图键"

    /// 缩略图对应的指纹：几何块文件名（本身就带几何指纹）+ 物体的网格引用。
    ///
    /// 位置 / 旋转 / 材质故意不进指纹 —— 挪一下物体不值得把 512 图重渲一遍。
    /// 但几何块换了、导入物换了就必须重渲，否则打开的永远是上一版（比如变形）的图。
    static func 缩略图键(清单: 容器清单, 快照: ProjectSnapshot? = nil) -> String {
        let 几何 = 清单.几何.map { $0.文件 }.sorted().joined(separator: ",")
        let 物体 = (快照?.objects ?? []).map {
            "\($0.id.uuidString):\($0.mesh.rawValue):\($0.导入网格ID?.uuidString ?? "-")"
        }.joined(separator: ",")
        return 几何 + "|" + 物体
    }

    /// 只做回写：替换容器里的两块 PNG → 提交 → 设为 .cg 的文件图标。
    ///
    /// 必须跑在 `存档写入器` 的写队列上（保存 / 只写几何 / 只写绘画也在那条队列），
    /// 否则会和保存的「追加 + 提交清单」并发写同一个容器。
    static func 回写聚焦图(_ png: Data, 到 root: URL) {
        guard let st = 后端(root) else { return }
        // 先把「这张图是按哪份几何/场景渲的」记进清单扩展，再落图：
        // 顺序反了万一中途失败，图是新的、键是旧的，下次打开又会白渲一遍。
        // 只动 扩展 这一个字段，不改 修改 时间 —— 图标元数据不该让工程变脏。
        if var 清单 = 读清单(root, 存储: st) {
            清单.扩展[缩略图键名] = 缩略图键(清单: 清单, 快照: 取场景(root, 存储: st))
            _ = 写清单(清单, 到: root, 存储: st)
        }
        _ = st.写(布局.缩略图, png)
        _ = st.写(布局.预览, png)
        guard st.提交() else { return }
        // 两侧都从保存主路径上拿掉了：
        // 1) compact 不再在这里同步做 —— 换个新 PNG 只多几十 KB 垃圾，不值得为它
        //    全量重读 217MB 再重写一遍；交给写队列上延后触发的后台整理。
        if st is 单文件存储 { 存档写入器.shared.排后台整理(到: root) }
        // 2) 设 Finder 图标要走 NSWorkspace，属于 UI 侧调用，回主线程做更稳妥；
        //    渲染和落盘都已经在后台完成，这里只是把成品图标贴上去。
        guard let 图 = NSImage(data: png) else { return }
        let 路径 = root.path
        DispatchQueue.main.async {
            NSWorkspace.shared.setIcon(图, forFile: 路径, options: [])
        }
    }

    // MARK: 局部写入（只动一块，不碰其他）

    /// 只写绘画。绘画的导出是 GPU 异步读回，跟场景参数不在同一个节奏上，
    /// 所以给它一条独立的写盘路径，避免为了存一张图把整份清单重算一遍。
    static func 只写绘画(_ 画: 绘画快照, 到 root: URL, 整理: Bool = false) {
        guard let st = 后端(root) else { return }
        var 清单 = 读清单(root, 存储: st) ?? .新建()
        let 结果 = 容器绘画.写出(画, 到: st, 旧条目: 清单.绘画)
        清单.绘画 = 容器绘画.清理孤儿(结果.条目, 到: st)
        清单.修改 = .now
        写清单(清单, 到: root, 存储: st)
        st.提交()
        if 整理, let 单 = st as? 单文件存储 { 单.整理() }
    }

    /// 只写几何池。导入模型后单独走这条，不重写场景参数。
    static func 只写几何(_ 池: [UUID: [导入网格]], 到 root: URL, 整理: Bool = false,
                       版本表: [UUID: UInt64] = [:]) {
        guard let st = 后端(root) else { return }
        var 清单 = 读清单(root, 存储: st) ?? .新建()
        let 结果 = 容器几何.写出(池, 到: st, 旧条目: 清单.几何, 版本表: 版本表)
        清单.几何 = 容器几何.清理孤儿(结果.条目, 到: st)
        清单.修改 = .now
        写清单(清单, 到: root, 存储: st)
        st.提交()
        if 整理, let 单 = st as? 单文件存储 { 单.整理() }
    }

    // MARK: 载入

    static func 载入(_ root: URL = 项目容器.当前项目) -> 容器内容? {
        guard 是容器(root) else { return nil }
        // 老的目录包就地升级成单文件，否则 Finder 里还是包，空格预览照旧被 Package 通道截走
        guard let st = 后端(root) else { return nil }
        guard var 清单 = 读清单(root, 存储: st), let 快照 = 取场景(root, 存储: st) else { return nil }
        if 清单.版本 < 当前版本 { 清单.版本 = 当前版本 }
        // 几何 mmap 直读；池里没被任何物体引用的网格也照样留着，删物体不自动删素材
        let 几何 = 容器几何.读取(清单.几何, 从: st)
        let 绘画 = 容器绘画.读取(清单.绘画, 从: st)
        // 材质贴图：读回字节登记进纹理库，再按清单裁一遍库 ——
        // 贴图 UUID 用的就是清单里那个，材质 imageTexture 节点跨重启依然指得中同一张图；
        // 裁剪是为了让「库里的贴图」恒等于「本工程的贴图」，别的工程的图不会被顺手保存进来。
        let 贴图条目 = 清单.贴图 ?? []
        if !贴图条目.isEmpty { 容器贴图.读取(贴图条目, 从: st) }
        材质接线.共享.源图只保留(Set(贴图条目.map(\.贴图ID)))
        // 缩略图对不上当前几何/场景就排一次后台重渲：
        // 老工程里存的可能是旧编码时期渲坏的图，光靠保存时才刷新永远补不上。
        // 渲在写队列上跑，不占打开主路径；键一致就一次都不渲。
        if 清单.扩展[缩略图键名] != 缩略图键(清单: 清单, 快照: 快照) {
            存档写入器.shared.排刷新聚焦(到: root)
        }
        return 容器内容(位置: root, 清单: 清单, 快照: 快照, 几何: 几何, 绘画: 绘画)
    }

    // MARK: 删除

    static func 删除(_ root: URL = 项目容器.当前项目) {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: 写时复制（clonefile）

    /// 用 APFS 的 `clonefile(2)` 把 `源` 复制成 `目标`。
    ///
    /// 特点：毫秒级完成，且两个文件共享同一批物理块，之后谁改写谁分裂差异页。
    /// 自动保护文件（autosave）正是靠这个，从「每份 217MB 真占」变成
    /// 「三份加起来≈一份」——逻辑大小各自完整，物理占用只在差异页上翻倍。
    ///
    /// 返回 false 表示这条路走不通（非 APFS 卷、跨卷、源不存在、目标已存在等），
    /// **调用方必须自己退回普通 copy，不许硬依赖 clone**。
    @discardableResult
    static func 写时复制(_ 源: URL, 到 目标: URL) -> Bool {
        // clonefile 要求目标不存在。已存在时不做「先删再克隆」——
        // 那等于把上一份保护文件提前毁掉，失败就没退路了；直接交给调用方 copy 覆盖。
        if FileManager.default.fileExists(atPath: 目标.path) { return false }
        guard FileManager.default.fileExists(atPath: 源.path) else { return false }
        let 结果 = 源.path.withCString { 源路径 in
            目标.path.withCString { 目标路径 in
                clonefile(源路径, 目标路径, 0)
            }
        }
        return 结果 == 0
    }
}

// MARK: - 材质贴图块

/// 材质贴图块的写/读（内容寻址）。
///
/// 形状刻意和 容器几何 / 容器绘画 保持一致：写出返回条目、读取登记进纹理库、
/// 清理孤儿删块。差别只在判据——贴图的名字里就带了「UUID + 字节数 + 内容摘要」，
/// 同名必同内容，所以跳过判断只看存在性，不用像几何那样再存一份校验。
enum 容器贴图 {

    struct 写出结果 {
        var 条目: [容器清单.贴图条目]
        var 跳过 = 0
        var 写入 = 0
    }

    /// 摘要缓存：同一张图（UUID 相同、字节数不变）只算一次 SHA256。
    /// 保存是高频动作，几百毫秒的哈希不该每次重来。
    private static let 缓存锁 = NSLock()
    private static var 摘要缓存: [UUID: (字节数: Int, 摘要: String)] = [:]

    private static func 摘要(_ id: UUID, _ data: Data) -> String {
        缓存锁.lock()
        if let 命中 = 摘要缓存[id], 命中.字节数 == data.count {
            缓存锁.unlock()
            return 命中.摘要
        }
        缓存锁.unlock()

        var h = SHA256()
        h.update(data: data)
        // 前 8 字节足够区分（16 个 hex 字符），名字也不至于长到看不清
        let 值 = h.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()

        缓存锁.lock()
        摘要缓存[id] = (data.count, 值)
        缓存锁.unlock()
        return 值
    }

    private static func 文件名(_ id: UUID, 字节数: Int, 摘要: String) -> String {
        "\(id.uuidString.lowercased())-\(字节数)-\(摘要).png"
    }

    /// 写出全部贴图字节。表是 [UUID: 原始字节]，UUID 就是材质节点里存的那个。
    static func 写出(_ 表: [UUID: Data], 到 st: 容器存储) -> 写出结果 {
        var 结果 = 写出结果(条目: [])
        for id in 表.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let data = 表[id], !data.isEmpty else { continue }
            let 名 = 文件名(id, 字节数: data.count, 摘要: 摘要(id, data))
            let 路径 = 项目容器.布局.贴图 + "/" + 名
            if let 已有 = st.大小(路径), 已有 == data.count {
                结果.跳过 += 1
                结果.条目.append(.init(贴图ID: id, 文件: 名, 字节: 已有))
                continue
            }
            if st.写(路径, data) {
                结果.写入 += 1
                结果.条目.append(.init(贴图ID: id, 文件: 名, 字节: data.count))
            }
        }
        return 结果
    }

    /// 读回本档贴图：解码 + 登记进纹理库。
    /// UUID 用清单里的那个 —— 材质 imageTexture 节点存的就是它，跨重启必须对得上。
    @discardableResult
    static func 读取(_ 条目: [容器清单.贴图条目], 从 st: 容器存储) -> Int {
        var 张数 = 0
        for e in 条目 {
            guard let data = st.读(项目容器.布局.贴图 + "/" + e.文件) else { continue }
            if 材质接线.共享.源图载入(data, id: e.贴图ID) { 张数 += 1 }
        }
        return 张数
    }

    /// 清单里没登记的贴图块视为垃圾（换图 / 删材质留下的旧块）。
    /// 单文件形态删不掉单个字节，但必须把孤儿从索引摘掉，否则 compact 的垃圾比例永远算成 0。
    static func 清理孤儿(_ 条目: [容器清单.贴图条目], 到 st: 容器存储) -> [容器清单.贴图条目] {
        let 保留 = Set(条目.map(\.文件))
        guard st.是目录 else {
            let 前缀 = 项目容器.布局.贴图 + "/"
            let 孤儿 = st.条目().filter { 名 in
                名.hasPrefix(前缀) && !保留.contains(String(名.dropFirst(前缀.count)))
            }
            st.移除(孤儿)
            return 条目
        }
        let 目录 = st.根.appendingPathComponent(项目容器.布局.贴图, isDirectory: true)
        guard let 文件 = try? FileManager.default.contentsOfDirectory(atPath: 目录.path) else { return 条目 }
        for 名 in 文件 where !保留.contains(名) {
            try? FileManager.default.removeItem(at: 目录.appendingPathComponent(名))
        }
        return 条目
    }
}
