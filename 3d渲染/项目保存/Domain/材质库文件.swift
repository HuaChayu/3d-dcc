import Foundation

/// 用户材质库落盘：`~/Documents/cg app/自定义材质库/<材质名>.cgmat`
///
/// 一条材质一个文件，JSON 直接编码 `MaterialAsset` 本体 —— 节点 kind、位置、参数、
/// 连线（`NodeGraph.nodes` / `links`）原样带走，读回来就是同一张图，不需要另建映射表。
/// 贴图不内嵌字节：把节点用到的源图拷进库目录的 `贴图/`，文件里只记**相对库目录**的路径，
/// 读回时按该路径重新登记进源图库；路径断了就照现有求值口径退回基色。
enum 材质库文件 {

    static let 扩展名 = "cgmat"
    static let 版本 = 1
    static let 贴图目录名 = "贴图"

    // MARK: - 文件外形

    /// 外层封装：材质本体 + 贴图相对路径表（节点 UUID → 相对库目录的路径）
    struct 包: Codable {
        var 版本: Int
        var 材质: MaterialAsset
        var 贴图: [String: String]
    }

    // MARK: - 写

    /// 把一条材质写进用户材质库。成功返回落盘位置，失败返回 nil。
    ///
    /// 落盘的是「库条目形态」：丢掉工程语义（出处 / 内置 / 副本于），
    /// 出厂样式对齐当前样式 —— 这样从库里再拖出来仍是保存时的样子。
    @discardableResult
    static func 保存(_ 资产: MaterialAsset) -> URL? {
        let 库 = 用户目录.材质库
        try? FileManager.default.createDirectory(at: 库, withIntermediateDirectories: true)

        var 条目 = 资产
        条目.出处 = nil
        条目.内置 = false
        条目.副本于 = nil
        条目.出厂基线 = 资产.baseline
        条目.出厂图 = 资产.graph

        let 封装 = 包(版本: 版本, 材质: 条目, 贴图: 写出贴图(条目.graph, 库: 库))
        guard let 数据 = try? 编码器.encode(封装) else { return nil }

        let 目标 = 落点(名: 条目.name, id: 条目.id, 库: 库)
        do {
            try 数据.write(to: 目标, options: .atomic)
            return 目标
        } catch {
            return nil
        }
    }

    /// 图里用到的贴图，字节原样拷进 `贴图/`，返回「节点 UUID → 相对路径」。
    /// 拿不到原始字节的图（只存在于运行期位图里）不登记，读回时该节点退回基色。
    private static func 写出贴图(_ 图: NodeGraph, 库: URL) -> [String: String] {
        let 用到的 = Set(图.nodes.compactMap(\.image))
        guard !用到的.isEmpty else { return [:] }

        let 字节表 = 材质接线.共享.全部源图字节()
        var 表: [String: String] = [:]

        for id in 用到的 {
            guard let 字节 = 字节表[id], !字节.isEmpty else { continue }
            let 子 = 库.appendingPathComponent(贴图目录名, isDirectory: true)
            try? FileManager.default.createDirectory(at: 子, withIntermediateDirectories: true)

            let 文件 = "\(id.uuidString).\(图片后缀(字节))"
            let 目标 = 子.appendingPathComponent(文件)
            if !FileManager.default.fileExists(atPath: 目标.path) {
                try? 字节.write(to: 目标, options: .atomic)
            }
            guard FileManager.default.fileExists(atPath: 目标.path) else { continue }
            表[id.uuidString] = "\(贴图目录名)/\(文件)"
        }
        return 表
    }

    /// 按字节头给贴图配后缀，别把 JPEG 存成 .png
    private static func 图片后缀(_ 数据: Data) -> String {
        if 数据.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if 数据.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        return "bin"
    }

    /// 落点：同名文件若是**同一条材质**就覆盖，不是就加序号另存一份，绝不悄悄覆盖别人的库条目。
    private static func 落点(名: String, id: UUID, 库: URL) -> URL {
        let 基名 = 洗名(名)
        let 首选 = 库.appendingPathComponent("\(基名).\(扩展名)")
        if !FileManager.default.fileExists(atPath: 首选.path) || 读id(首选) == id { return 首选 }

        var 序 = 2
        while 序 <= 999 {
            let 试 = 库.appendingPathComponent("\(基名) \(序).\(扩展名)")
            if !FileManager.default.fileExists(atPath: 试.path) || 读id(试) == id { return 试 }
            序 += 1
        }
        return 库.appendingPathComponent("\(基名)-\(id.uuidString).\(扩展名)")
    }

    private static func 读id(_ url: URL) -> UUID? {
        guard let 数据 = try? Data(contentsOf: url),
              let 封装 = try? 解码器.decode(包.self, from: 数据) else { return nil }
        return 封装.材质.id
    }

    /// 文件名去掉路径分隔符这类非法字符，其余原样（中文、空格都留着）
    private static func 洗名(_ 名: String) -> String {
        let 非法 = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        let 清 = 名.components(separatedBy: 非法).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return 清.isEmpty ? "未命名材质" : 清
    }

    // MARK: - 读

    /// 扫一遍库目录，把能读的条目全部解出来；坏文件跳过，不牵连其它条目。
    static func 全部() -> [MaterialAsset] {
        let 库 = 用户目录.材质库
        guard let 文件们 = try? FileManager.default.contentsOfDirectory(
            at: 库, includingPropertiesForKeys: nil
        ) else { return [] }

        return 文件们
            .filter { $0.pathExtension.lowercased() == 扩展名 }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .compactMap { 载入($0, 库: 库) }
    }

    /// 解一个 `.cgmat`。贴图按相对路径重新登记进源图库，节点 UUID 保持原样。
    static func 载入(_ url: URL, 库: URL? = nil) -> MaterialAsset? {
        let 根 = 库 ?? 用户目录.材质库
        guard let 数据 = try? Data(contentsOf: url),
              let 封装 = try? 解码器.decode(包.self, from: 数据) else { return nil }

        var 条目 = 封装.材质
        条目.出处 = nil
        条目.内置 = false
        条目.副本于 = nil
        条目.出厂基线 = 条目.出厂基线 ?? 条目.baseline
        条目.出厂图 = 条目.出厂图 ?? 条目.graph

        for 节点 in 条目.graph.nodes {
            guard let id = 节点.image, let 相对 = 封装.贴图[id.uuidString] else { continue }
            let 图URL = 根.appendingPathComponent(相对)
            guard let 字节 = try? Data(contentsOf: 图URL) else { continue }
            _ = 材质接线.共享.源图载入(字节, id: id)
        }
        return 条目
    }

    // MARK: - 删

    /// 按资产 id 找到它落在库里的那个 `.cgmat`。
    /// 文件名是「材质名」而不是 id，改名之后 id 只存在文件里，所以只能逐个读 id 对，不能拼路径。
    /// 返回 nil 说明这条材质只有内存里的份（内置预设，或只在工程里），磁盘上没有对应文件。
    static func 定位(id: UUID) -> URL? {
        guard let 文件们 = try? FileManager.default.contentsOfDirectory(
            at: 用户目录.材质库, includingPropertiesForKeys: nil
        ) else { return nil }
        for 文件 in 文件们 where 文件.pathExtension == 扩展名 {
            if 读id(文件) == id { return 文件 }
        }
        return nil
    }

    /// 按资产 id 把库里对应的 `.cgmat` 删掉（进废纸篓，可恢复）。
    /// 返回是否真删到了文件（没找到 / 删失败都算 false，上层据此区分提示）。
    @discardableResult
    static func 删除(id: UUID) -> Bool {
        guard let 文件们 = try? FileManager.default.contentsOfDirectory(
            at: 用户目录.材质库, includingPropertiesForKeys: nil
        ) else { return false }
        for 文件 in 文件们 where 文件.pathExtension == 扩展名 {
            guard 读id(文件) == id else { continue }
            do {
                try FileManager.default.trashItem(at: 文件, resultingItemURL: nil)
                return true
            } catch {
                return false
            }
        }
        return false
    }

    // MARK: - 展示

    /// 界面上把家目录缩成 `~`，一眼能对上设置里那行路径
    static func 显示路径(_ url: URL) -> String {
        let 家 = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.hasPrefix(家) ? "~" + url.path.dropFirst(家.count) : url.path
    }

    // MARK: - 编解码

    private static var 编码器: JSONEncoder {
        let 器 = JSONEncoder()
        器.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        器.dateEncodingStrategy = .iso8601
        return 器
    }

    private static var 解码器: JSONDecoder {
        let 器 = JSONDecoder()
        器.dateDecodingStrategy = .iso8601
        return 器
    }
}
