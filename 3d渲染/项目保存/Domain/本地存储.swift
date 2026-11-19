import AppKit
import Foundation

// MARK: - 本地快照

struct ProjectSnapshot: Codable {
    var materials: [MaterialAsset]
    var objects: [SceneObject]
    var selectedMaterialID: UUID?
    var selectedObjectID: UUID?
    var viewport: ViewportSettings
    var render: RenderSettings
    var renderJobs: [RenderJob]
    /// 导入几何池（外部模型 fbx/blend/usd/obj…）。可空是为了兼容旧存档：
    /// 早期快照里没有这个键，解码出 nil 只是「没有导入模型」，不该让整份存档报废。
    var 导入网格池: [UUID: [导入网格]]? = nil
    var savedAt: Date
    /// 轨道相机机位（保存时的观察角度 / 距离 / 轨道中心）。
    ///
    /// 只决定「打开文件先看到什么」，不参与场景内容；老工程没有这一项时留空，
    /// 打开后仍是默认机位，不会因为解码失败整份快照被丢。
    var 视口相机: 视口相机存档? = nil
    /// 集合（文件夹）。可选：旧存档没有这一项，读出来就是 nil → 空集合
    var 集合们: [场景集合]? = nil
    /// 时间轴 + 轨道表。可选：旧存档没有这一项 → 没有动画，不报错。
    /// 动画跟工程走，不跟 App 走：一份工程自带它自己的关键帧。
    var 动画: 动画快照? = nil
    /// 全局物理（重力 / 风 / 流 / 湍流 / 阻力）。可选：旧存档没有 → 标准地球重力。
    /// 是全局单体而非场景对象，所以不放进 objects；发射器每个粒子按自己的倍率吃这套力。
    var 物理域: 物理域? = nil
}

enum LocalStore {
    // MARK: 存档位置
    //
    // 老版本把整份快照（含导入网格池的顶点/索引）塞进 UserDefaults，
    // 项目一大就是几百 MB。UserDefaults 的 set 会同步走 CFPreferences：
    // 序列化 + 落盘 + 通知 cfprefsd 全在主线程上做，于是每改一个参数就卡一下、
    // 鼠标转风车。现在改为「文件 + 后台串行队列 + 合并写」：
    //   - 主线程只做一次值拷贝（COW，微秒级），立刻返回；
    //   - 编码、压缩、写盘全在 utility 队列上完成；
    //   - 写盘期间多次 persist 只保留最后一态，不会排队堆积。
    private static let 旧键 = "3drender.project.v1"
    private static let 魔数 = Data("3DPJ".utf8)
    /// 负载第 5 字节：1 = zlib 压缩，0 = 明文 JSON
    private static let 标志偏移 = 4

    static var 存档目录: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        let dir = base.appendingPathComponent("3d渲染", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var 存档文件: URL {
        存档目录.appendingPathComponent("project.3dpj")
    }

    /// 自动保护文件目录：App 支持目录下的 autosave/。
    ///
    /// 自动保存只往这里写独立 .cg 文件，主工程文件永远不会被自动保存碰到。
    static var 自动保存目录: URL {
        let dir = 存档目录.appendingPathComponent("autosave", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 根 Store 的弱引用：底层写盘模块（几何池脏标记等）需要把「工程变脏」上报给它。
    static weak var 主App: AppStore?

    /// 旧存档（UserDefaults）是否还在，用于清理提示/迁移判断。
    static var 尚有旧存档: Bool {
        UserDefaults.standard.data(forKey: 旧键) != nil
    }

    /// 载入项目：优先新容器，其次旧档，最次 UserDefaults。
    ///
    /// 迁移是「读旧、写新、不删旧」：旧档照常能起来，下一次 persist 就把内容写进
    /// `.cg` 容器；旧文件保留到用户主动清理，迁移出问题还能回滚。
    static func 载入容器() -> 容器内容? {
        if let 内容 = 项目容器.载入() { return 内容 }
        guard let 快照 = load() else { return nil }
        let 池 = 网格池文件.载入() ?? 快照.导入网格池 ?? [:]
        // 仅首次从旧档迁移时发生（目标位置尚无有效容器），等价于「建项目」，
        // 之后的日常改动一律不再写主文件，只走 ⌘S 或 autosave。
        _ = 项目容器.保存(快照, 几何池: 池, 绘画: nil, 到: 项目容器.当前项目)
        return 项目容器.载入()
    }

    static func load() -> ProjectSnapshot? {
        if let data = 读盘() {
            return 解码(data)
        }
        // 迁移：老版本存在 UserDefaults 里
        guard let legacy = UserDefaults.standard.data(forKey: 旧键),
              let snapshot = 解码(legacy) else { return nil }
        // 编码+写盘放后台，启动不被几百 MB 的编码拖住；写成功后再删旧键
        DispatchQueue.global(qos: .utility).async {
            if let json = 编码(snapshot), 写盘(json) {
                UserDefaults.standard.removeObject(forKey: 旧键)
            }
        }
        return snapshot
    }

    private static func 解码(_ data: Data) -> ProjectSnapshot? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var snapshot = try? decoder.decode(ProjectSnapshot.self, from: data) else { return nil }
        migrateLegacyNames(&snapshot)
        return snapshot
    }

    // MARK: 旧快照文案迁移

    /// 早期版本用英文命名（Material 1 / Shader Ball / Noise · Clay …），
    /// 载入时统一换成中文，避免界面里残留英文。
    private static func migrateLegacyNames(_ snapshot: inout ProjectSnapshot) {
        let names: [String: String] = [
            "Shader Ball": "着色球",
            "Metal Torus": "金属圆环",
            "Glass Sphere": "玻璃球",
            "Ceramic Clay": "陶土",
            "Brushed Aluminium": "拉丝铝",
            "Thin Film Glass": "薄膜玻璃",
        ]
        let nodeTitles: [String: String] = [
            "Noise · Clay": "噪波 · 陶土",
            "Gradient · Tone": "渐变 · 色调",
            "Gradient · Tint": "渐变 · 着色",
            "Fresnel": "菲涅尔",
            "Remap · Coat": "重映射 · 清漆",
            "Hue Shift": "色相偏移",
            "Aluminium": "铝",
        ]
        let jobLabels: [String: String] = [
            "Ceramic Clay · Hero": "陶土 · 主视角",
            "Brushed Aluminium · Turnaround": "拉丝铝 · 环视",
            "Thin Film Glass · Key": "薄膜玻璃 · 主光",
        ]

        for i in snapshot.materials.indices {
            var name = snapshot.materials[i].name
            if let zh = names[name] {
                name = zh
            }
            // "Material 3 Copy" → "材质 3 副本"
            if name.hasSuffix(" Copy") {
                name = String(name.dropLast(" Copy".count)) + " 副本"
            }
            if name.hasPrefix("Material "), let index = Int(name.dropFirst("Material ".count)) {
                name = "材质 \(index)"
            }
            snapshot.materials[i].name = name
            var graph = snapshot.materials[i].graph
            for j in graph.nodes.indices {
                if let zh = nodeTitles[graph.nodes[j].title] {
                    graph.nodes[j].title = zh
                }
            }
            snapshot.materials[i].graph = graph
        }

        for i in snapshot.objects.indices {
            if let zh = names[snapshot.objects[i].name] {
                snapshot.objects[i].name = zh
            }
        }

        for i in snapshot.renderJobs.indices {
            if let zh = jobLabels[snapshot.renderJobs[i].label] {
                snapshot.renderJobs[i].label = zh
            }
        }
    }

    /// 主线程只拷贝一次快照就返回，真正的编码/写盘在后台串行队列里合并执行。
    /// 全量落盘到指定容器。
    ///
    /// 目标容器必须由调用方显式给出：主工程文件只有 ⌘S / 另存为这类手动路径才允许写，
    /// 自动保存一律写 autosave 目录下的独立文件，绝不允许顺着全局指针摸到主文件。
    static func save(_ snapshot: ProjectSnapshot, 到 root: URL, 刷新聚焦图: Bool = true) {
        // 网格走容器里的 .cgm 块，这里再剥一次做双保险：
        // 万一哪天有人又把池塞回快照，也不会把几百 MB 拖进 JSON。
        var 轻量 = snapshot
        轻量.导入网格池 = nil
        存档写入器.shared.提交(轻量, 到: root, 刷新聚焦图: 刷新聚焦图)
        // 绘画在显存里，导出得先读回，所以单独节流：0.5 秒内的连续改动只导出一次
        MainActor.assumeIsolated { 绘画导出节流.shared.请求(到: root) }
    }

    static func clear() {
        项目容器.删除()
        try? FileManager.default.removeItem(at: 存档文件)
        try? FileManager.default.removeItem(at: 网格池文件.文件)
        UserDefaults.standard.removeObject(forKey: 旧键)
        存档写入器.shared.丢弃待写()
    }

    /// 手动保存 / 退出前，把还没落盘的最后一态补写到指定容器。
    ///
    /// 这只是「把已排队的那一版提前写完」，不产生新的写盘请求，因此不会顺手写主文件。
    static func flush(到 root: URL) {
        // 退出路径必须同步导出绘画，否则最后一笔留在显存里就丢了
        绘画导出节流.shared.取消()
        let 画 = MainActor.assumeIsolated { PaintEngine.shared.导出绘画快照同步() }
        存档写入器.shared.同步写绘画(画, 到: root)
        存档写入器.shared.立即写盘()
    }

    /// ⌘S 用：主线程只「拍快照 + 导出绘画 + 登记」，写盘（几何块 + 索引提交 + fsync）
    /// 全丢给后台串行写队列。
    ///
    /// 这样 ⌘S 立刻返回，不会出现转圈；连续按只写最后一版，但每一次的 `完成`
    /// 都会在写完后回调（成功 / 失败），失败由调用方翻成用户可见的状态。
    /// 绘画必须在主线程先导出（数据在引擎里，后台取不到），导出后先排绘画写入、
    /// 再排主容器写入，两者同在一条串行队列上，顺序即提交顺序。
    static func 异步落盘(_ snapshot: ProjectSnapshot, 绘画: 绘画快照?, 到 root: URL,
                      刷新聚焦图: Bool, 完成: @escaping (Bool) -> Void) {
        let 写 = 存档写入器.shared
        if let 绘画 { 写.提交绘画(绘画, 到: root) }
        写.提交(snapshot, 到: root, 刷新聚焦图: 刷新聚焦图, 完成: 完成)
    }

    /// 等写队列里已经排上的活儿（含在途那笔）全部做完。只在退出 / 切项目这类
    /// 「必须拿到确定状态」的路径上调用，允许阻塞。
    static func 等待写队列空闲() {
        存档写入器.shared.等待空闲()
    }

    /// 切换项目前丢掉还没到点的聚焦图渲染 / 后台整理（见 存档写入器.丢弃延后任务）。
    static func 丢弃延后任务() {
        存档写入器.shared.丢弃延后任务()
    }

    /// 让指定的容器在后台补一张聚焦图（Finder 图标）。保存路径只排队，不等渲染。
    static func 排刷新聚焦图标(到 root: URL) {
        存档写入器.shared.排刷新聚焦(到: root)
    }

    /// 后台队列调用：把快照写进 `.cg` 容器（场景 + 几何块）。
    /// 返回是否落盘成功——失败必须一路传出去给用户看，不许静默吞掉。
    @discardableResult
    static func 写入容器(_ snapshot: ProjectSnapshot, 到 root: URL, 刷新聚焦图: Bool) -> Bool {
        let 快 = 几何接线.共享.快照与版本()
        return 项目容器.保存(snapshot,
                          几何池: 快.池,
                          绘画: nil,
                          到: root,
                          刷新聚焦图: 刷新聚焦图,
                          版本表: 快.版本)
    }

    /// 绘画导出完成（任意线程）后调用，丢给后台队列落盘。
    static func 写绘画(_ 画: 绘画快照, 到 root: URL) {
        存档写入器.shared.提交绘画(画, 到: root)
    }

    // MARK: 编码 / 读盘 / 写盘

    static func 编码(_ snapshot: ProjectSnapshot) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(snapshot)
    }

    /// 写盘成功返回 true。格式：魔数(4B) + 压缩标志(1B) + 负载。
    @discardableResult
    fileprivate static func 写盘(_ json: Data) -> Bool {
        var payload = 魔数
        if let 压缩 = try? (json as NSData).compressed(using: .zlib) as Data {
            payload.append(1)
            payload.append(压缩)
        } else {
            payload.append(0)
            payload.append(json)
        }
        do {
            try payload.write(to: 存档文件, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private static func 读盘() -> Data? {
        guard let raw = try? Data(contentsOf: 存档文件),
              raw.count > 魔数.count + 1,
              raw.prefix(魔数.count) == 魔数 else { return nil }
        let 标志 = raw[raw.startIndex + 标志偏移]
        let 负载 = raw.subdata(in: (魔数.count + 1)..<raw.count)
        if 标志 == 1 {
            return try? (负载 as NSData).decompressed(using: .zlib) as Data
        }
        return 负载
    }

    /// 图 → JSON 文本，用于导出/调试
    static func exportJSON(_ graph: NodeGraph) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(graph),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}

// MARK: - 后台合并写

/// 串行队列 + 单槽 pending：
/// 正在写盘时再来多少次 save 都只保留最后一态，写完顺手把最新态补写一次。
/// 这样拖滑杆、改参数这类高频 onChange 不会把主线程和磁盘排队堵死。
final class 存档写入器 {
    static let shared = 存档写入器()

    private let 队列 = DispatchQueue(label: "com.3drender.localstore.write", qos: .utility)
    private let 锁 = NSLock()

    /// 待写批次：同一条目标容器只保留最新一版。
    /// key = 容器的标准化路径，所以「主文件」和「自动保护文件」各自排队、互不覆盖。
    private var 待写: [String: 待写项] = [:]
    private var 待写顺序: [String] = []
    private var 忙 = false

    private var 聚焦待刷: URL?          // 待刷新聚焦图的目标容器
    private var 聚焦延后: DispatchWorkItem?

    /// 后台整理（compact）待办：每个容器一个待执行的活。
    /// 和写盘共用这条串行队列 —— compact 要「读活块 → 写临时文件 → replaceItemAt」，
    /// 和 append / 提交索引并发就会拿旧索引覆盖新索引。
    private var 整理待办: [String: DispatchWorkItem] = [:]

    private struct 待写项 {
        let root: URL
        let 快照: ProjectSnapshot
        let 刷新聚焦图: Bool
        /// 这一版写完后要通知的人。连续多次 ⌘S 合并成一版时，几个回调都挂在这里。
        var 等待者: [(Bool) -> Void]
    }

    /// 刻意不监听 willTerminate 自动补写：退出时该不该写主文件由用户决定（见 应用委托），
    /// 偷偷在这里补一刀就等于「静默覆盖用户工程」。
    private init() {}

    func 提交(_ snapshot: ProjectSnapshot, 到 root: URL, 刷新聚焦图: Bool,
             完成: ((Bool) -> Void)? = nil) {
        let 键 = root.standardizedFileURL.path
        锁.lock()
        let 旧 = 待写[键]
        if 旧 == nil { 待写顺序.append(键) }
        var 等待者 = 旧?.等待者 ?? []
        if let 完成 { 等待者.append(完成) }
        待写[键] = 待写项(root: root,
                        快照: snapshot,
                        刷新聚焦图: (旧?.刷新聚焦图 ?? false) || 刷新聚焦图,
                        等待者: 等待者)
        let 需要启动 = !忙
        if 需要启动 { 忙 = true }
        锁.unlock()
        if 需要启动 { 泵() }
    }

    /// 等队列上已经排好的活儿（含在途那笔）全部做完。调用方不能在写队列上调用。
    func 等待空闲() {
        队列.sync {}
    }

    /// 切换项目 / 另存为 / 重置前调用：丢掉还在「等时间」的装饰性后台活
    /// （聚焦图渲染、compact）。它们都是延后 0.5s / 3s 才提交到队列的，
    /// 若留着，切完项目后还会去渲染 / 整理上一个项目的旧容，纯属浪费 IO。
    func 丢弃延后任务() {
        锁.lock()
        聚焦延后?.cancel()
        聚焦延后 = nil
        聚焦待刷 = nil
        for (_, 活) in 整理待办 { 活.cancel() }
        整理待办.removeAll()
        锁.unlock()
    }

    /// 整理（compact）从保存主路径移出来的落点：保存完成后延后 3 秒执行，
    /// 期间又保存就重新计时 —— 连续编辑时根本不压，只压最后一版。
    ///
    /// 执行仍然排在这条写队列上（不是另开线程），所以和 append / 索引提交天然串行；
    /// 又因为不在主线程、也不在保存调用栈里，用户继续编辑不会卡。
    func 排后台整理(到 root: URL) {
        let 键 = root.standardizedFileURL.path
        锁.lock()
        整理待办[键]?.cancel()
        let 工作 = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.锁.lock()
            self.整理待办[键] = nil
            self.锁.unlock()
            // 每次重新开后端：拿到的是刚提交过的索引，不会读到别人的过期状态
            guard let 单 = 项目容器.后端(root) as? 单文件存储 else { return }
            单.整理()
        }
        整理待办[键] = 工作
        锁.unlock()
        队列.asyncAfter(deadline: .now() + 3, execute: 工作)
    }

    /// 绘画导出是异步的，回到这里时已经在后台线程，直接排进写队列。
    func 提交绘画(_ 画: 绘画快照, 到 root: URL) {
        队列.async {
            项目容器.只写绘画(画, 到: root)
        }
    }

    /// 退出路径用：绘画必须当场落盘，不能等合并写。
    func 同步写绘画(_ 画: 绘画快照, 到 root: URL) {
        队列.sync {
            项目容器.只写绘画(画, 到: root)
        }
    }

    func 丢弃待写() {
        锁.lock()
        待写.removeAll()
        待写顺序.removeAll()
        锁.unlock()
    }

    /// 聚焦图延后刷新（保存路径调用）。
    ///
    /// 渲染一帧聚焦图 = 整包反序列化 + 建全量顶点 + 离屏出图，在保存里当场做会把
    /// 这一批保存全堵住。这里改成「最后一次保存之后 0.5s 才渲」，连续保存只渲最后一张。
    ///
    /// 渲染仍放在写队列上执行（不自开队列）：只有和 append / compact 串行，
    /// 才不会出现「渲染正 mmap 读文件，另一路 compact 把文件重写」的撕裂读。
    func 排刷新聚焦(到 root: URL) {
        锁.lock()
        聚焦待刷 = root
        聚焦延后?.cancel()
        let 工作 = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.锁.lock()
            let 目标 = self.聚焦待刷
            self.聚焦待刷 = nil
            self.聚焦延后 = nil
            self.锁.unlock()
            guard let 目标 else { return }
            项目容器.刷新聚焦图标(到: 目标)   // 渲 + 回写，同步跑在写队列上
        }
        聚焦延后 = 工作
        锁.unlock()
        队列.asyncAfter(deadline: .now() + 0.5, execute: 工作)
    }

    /// 把已经排队的那几版当场写完（退出 / 切项目 / 另存为前调用，允许短暂阻塞）。
    ///
    /// 这里**不再顺手渲聚焦图**：渲染是装饰性动作，串在退出或另存为路径上只会白等
    /// 几百毫秒。需要图标的场景改成排后台任务（`排刷新聚焦图标`），保存完自己补。
    func 立即写盘() {
        锁.lock()
        let 批次 = 待写顺序.compactMap { 待写[$0] }
        待写.removeAll()
        待写顺序.removeAll()
        锁.unlock()

        if 批次.isEmpty {
            队列.sync {}
            return
        }
        队列.sync {
            for 项 in 批次 {
                let 成功 = LocalStore.写入容器(项.快照, 到: 项.root, 刷新聚焦图: 项.刷新聚焦图)
                let 等待者 = 项.等待者
                if !等待者.isEmpty {
                    DispatchQueue.main.async {
                        for 完 in 等待者 { 完(成功) }
                    }
                }
            }
        }
    }

    private func 泵() {
        队列.async { [weak self] in
            guard let self else { return }
            while true {
                self.锁.lock()
                guard let 键 = self.待写顺序.first, let 项 = self.待写[键] else {
                    self.待写.removeAll()
                    self.待写顺序.removeAll()
                    self.忙 = false
                    self.锁.unlock()
                    return
                }
                self.待写顺序.removeFirst()
                self.待写[键] = nil
                self.锁.unlock()

                let 成功 = LocalStore.写入容器(项.快照, 到: 项.root, 刷新聚焦图: 项.刷新聚焦图)

                // 结果回主线程：合并进来的每一次保存都收到同一份结果，
                // 失败要靠它变成状态栏上的错误态，不许静默。
                let 等待者 = 项.等待者
                if !等待者.isEmpty {
                    DispatchQueue.main.async {
                        for 完 in 等待者 { 完(成功) }
                    }
                }
            }
        }
    }
}
