import Foundation

/// 自动保护（autosave）协调器。
///
/// 传统 DCC 语义：主工程文件只由 ⌘S / 另存为写入；自动保存写的是 App 支持目录下
/// `autosave/` 里的独立 `.cg` 文件，**永远不会碰用户的主工程文件**。
///
/// - 间隔按分钟计，由用户在偏好设置里决定（1…60 分钟，也可以直接关掉）。
/// - 只有工程处于「脏」状态才写盘，不脏不写。
/// - 只保留最近 3 份，按修改时间淘汰最旧的。
///
/// 全程不修改 `项目容器.当前项目` 指针：目标容器一律显式传参，
/// 从源头上避免「自动保存顺手把主文件覆盖了」。
@MainActor
final class 自动保存协调器 {

    static let 共享 = 自动保存协调器()

    /// 保留的自动保护文件份数
    private static let 保留份数 = 3
    /// 检查节拍：15 秒看一次，避免「改成 1 分钟还要等满 60 秒才生效」
    private static let 检查节拍: TimeInterval = 15

    private weak var 应用: AppStore?
    private var 定时: Timer?

    /// 上次真正写盘的时间（用于按间隔比较）
    private var 上次写盘: Date?
    /// 脏版本号：每次「脏状态变化」自增
    private var 脏版本: Int = 0
    /// 已经写进保护文件的脏版本号，同一版本不重复写
    private var 已保护版本: Int = -1
    private var 正在写 = false

    private init() {}

    // MARK: - 接线

    func 绑定(_ app: AppStore) {
        应用 = app
        上次写盘 = nil
        脏版本 = 0
        已保护版本 = app.有未保存改动 ? -1 : 0
        重启定时器()
    }

    /// 任何域状态变化都会走到这里：只记录版本，不立刻写盘。
    func 脏状态变化() {
        脏版本 &+= 1
        if 定时 == nil { 重启定时器() }
    }

    /// 手动保存 / 另存为成功后调用：把当前版本视为已落盘，避免紧接着又写一份保护文件。
    func 手动保存完成() {
        已保护版本 = 脏版本
        上次写盘 = Date()
    }

    // MARK: - 定时检查

    private func 重启定时器() {
        定时?.invalidate()
        let 定时器 = Timer(timeInterval: Self.检查节拍, repeats: true) { _ in
            Task { @MainActor in 自动保存协调器.共享.触发检查() }
        }
        RunLoop.main.add(定时器, forMode: .common)
        定时 = 定时器
    }

    private func 触发检查() {
        guard let 应用 else { return }
        let 设置 = 偏好设置Store.shared
        guard 设置.自动保存开启 else { return }
        guard 应用.有未保存改动 else { return }
        // 这个脏版本已经保护过了，不重复写
        guard 已保护版本 != 脏版本 else { return }
        guard !正在写 else { return }

        let 间隔 = TimeInterval(min(60, max(1, 设置.自动保存间隔分钟))) * 60
        if let 上次 = 上次写盘, Date().timeIntervalSince(上次) < 间隔 { return }

        写保护文件()
    }

    // MARK: - 写保护文件

    private func 写保护文件() {
        guard let 应用, !正在写 else { return }
        正在写 = true
        let 本次版本 = 脏版本

        // 绘画在显存里，导出必须在这里（主线程）同步读回一次
        let 画 = PaintEngine.shared.导出绘画快照同步()
        let 快照 = 应用.生成快照()
        // 池与版本一次取齐：版本是保存时哈希缓存的判据，必须是同一瞬间的值
        let 池与版本 = 几何接线.共享.快照与版本()
        let 目标 = 下一个保护文件URL()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.准备保护文件基底(目标)
            let 成功 = 项目容器.保存(
                快照,
                几何池: 池与版本.池,
                绘画: 画,
                到: 目标,
                刷新聚焦图: false,   // 不是用户工程，不渲聚焦图
                整理容器: false,     // 全量重写，不需要再压一遍
                版本表: 池与版本.版本
            )
            DispatchQueue.main.async {
                guard let self else { return }
                self.正在写 = false
                guard 成功 else { return }
                self.已保护版本 = 本次版本
                self.上次写盘 = Date()
                self.应用?.记录自动保护(Date())
                self.清理旧保护文件(保留: 目标)
            }
        }
    }

    /// 退出路径：把当前脏状态同步写成一份保护文件。允许短暂阻塞。
    @discardableResult
    func 退出前兜底写保护() -> Bool {
        guard let 应用, 应用.有未保存改动 else { return true }
        let 画 = PaintEngine.shared.导出绘画快照同步()
        let 快照 = 应用.生成快照()
        let 池与版本 = 几何接线.共享.快照与版本()
        let 目标 = 下一个保护文件URL()
        var 成功 = false
        DispatchQueue.global(qos: .userInitiated).sync {
            准备保护文件基底(目标)
            成功 = 项目容器.保存(
                快照,
                几何池: 池与版本.池,
                绘画: 画,
                到: 目标,
                刷新聚焦图: false,
                整理容器: false,
                版本表: 池与版本.版本
            )
        }
        if 成功 {
            已保护版本 = 脏版本
            上次写盘 = Date()
            应用.记录自动保护(Date())
            清理旧保护文件(保留: 目标)
        }
        return 成功
    }

    /// 最近一份自动保护文件的路径（退出提示用）。
    var 最新保护文件: URL? {
        保护文件列表().first
    }

    /// 基底复制用的源容器路径。主线程在 打开 / 另存为 / 新建项目 之后同步维护。
    /// nil = 未命名文档（还没落过盘），此时没有基底可铺，保护文件退化成
    /// 「本次内容的完整文件」—— 内容依然正确，只是多占一份体积。
    nonisolated(unsafe) static var 基底源: URL?

    /// 新保护文件先整份复制主容器当基底，再在上面覆盖写这次的内容。
    ///
    /// 内容寻址的块是按需写的，不铺底的话一旦某块这次没重写，保护文件里就会缺图元。
    /// 复制失败也继续写（退化成「只有本次内容的全量文件」，聊胜于无）。
    ///
    /// 复制方式优先走 **写时复制**（APFS `clonefile`）：毫秒级完成、且基底与主文件
    /// 共享物理块，之后谁改谁分裂差异页。这样三份 autosave 的**逻辑大小**各自完整
    /// （都还是 200MB+，可独立打开），**物理占用**却接近一份，不再×3。
    /// clonefile 在非 APFS 卷、跨卷、源缺失等情况下会失败，此时必须退回普通 copy，
    /// 不许硬依赖——退回的后果只是多占磁盘，绝不能变成「基底没铺上导致保护文件缺图元」。
    nonisolated private func 准备保护文件基底(_ 目标: URL) {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: 目标.path) else { return }
        let 源 = 自动保存协调器.基底源
        guard let 源, 项目容器.是容器(源), fm.fileExists(atPath: 源.path) else { return }
        try? fm.createDirectory(at: 目标.deletingLastPathComponent(), withIntermediateDirectories: true)

        // 首选：clonefile 写时复制（块共享，近乎零额外占用）
        if 项目容器.写时复制(源, 到: 目标) { return }

        // 兜底：普通整份复制。走到这里说明当前卷不支持 clone 或跨卷，
        // 磁盘占用会回到「一份一份真占」，但内容一定完整。
        if (try? fm.copyItem(at: 源, to: 目标)) == nil {
            // 复制失败就不铺底，后续保存退化成全量文件（至少内容是这次的真实内容）
            NSLog("[自动保护] 基底复制失败（clone 与 copy 均不可用）：%s → %s",
                  源.path, 目标.path)
        }
    }

    // MARK: - 目录 / 轮转

    private func 下一个保护文件URL() -> URL {
        let 格式 = DateFormatter()
        格式.locale = Locale(identifier: "en_US_POSIX")
        格式.dateFormat = "yyyyMMdd-HHmmss"
        let 名 = "自动保护-\(格式.string(from: Date())).\(项目容器.扩展名)"
        return LocalStore.自动保存目录.appendingPathComponent(名)
    }

    /// 新旧排序（新 → 旧）的保护文件列表。
    private func 保护文件列表() -> [URL] {
        let 目录 = LocalStore.自动保存目录
        guard let 列表 = try? FileManager.default.contentsOfDirectory(
            at: 目录,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return 列表
            .filter { $0.pathExtension.lowercased() == 项目容器.扩展名 }
            .compactMap { url -> (URL, Date)? in
                let 时间 = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return (url, 时间)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    /// 只保留最新的 N 份（含刚写好的那份）。
    private func 清理旧保护文件(保留 最新: URL) {
        let 列表 = 保护文件列表()
        guard 列表.count > Self.保留份数 else { return }
        for url in 列表.dropFirst(Self.保留份数) where url.standardizedFileURL != 最新.standardizedFileURL {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
