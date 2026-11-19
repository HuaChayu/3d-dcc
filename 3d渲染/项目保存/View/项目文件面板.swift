import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 待打开请求
//
// Finder 双击 .cg、或把 .cg 拖到 Dock 图标上时，系统在 App 可能还没建好窗口的
// 时刻就回调 delegate。这里只把 URL 存起来，等 SwiftUI 视图起来再取走处理，
// 免得在 Store 还没初始化完的时候就去改状态。

@Observable
final class 打开请求 {
    static let 共享 = 打开请求()
    var 待打开: URL?
}

// MARK: - 应用委托

final class 应用委托: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        // 一次可能来多个文件，只认第一个 .cg；其他类型静默忽略
        guard let 目标 = urls.first(where: { 项目容器.是容器($0) }) else { return }
        打开请求.共享.待打开 = 目标
    }

    /// 退出前防丢：主文件只在用户确认时才写，绝不静默覆盖，也绝不静默丢数据。
    ///
    /// 判据与流程：
    /// 1. 没有未保存改动 → 直接退出。
    /// 2. 有改动 → 先同步写一份 autosave 保护文件（不管用户后面选什么，内容都留住了）。
    /// 3. 弹框让用户选：保存并退出 / 保留自动保护后退出 / 取消。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated { 退出确认() }
    }

    private func 退出确认() -> NSApplication.TerminateReply {
        // 有在途保存就先等它落完：不然「正在保存」会被错当成「已保存」直接退出
        LocalStore.等待写队列空闲()
        guard let app = LocalStore.主App, app.有未保存改动 else { return .terminateNow }

        // 兜底：先落一份独立保护文件，之后无论选哪条都不会丢内容
        let 保护成功 = 自动保存协调器.共享.退出前兜底写保护()

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "「\(app.项目名)」有未保存的改动"
        alert.informativeText = 保护成功
            ? "主工程文件还没写入。已先把当前内容存成一份自动保护文件，你也可以直接保存到主工程文件。"
            : "主工程文件还没写入，自动保护文件也没能生成。建议先保存。"
        alert.addButton(withTitle: "保存并退出")
        alert.addButton(withTitle: "保留自动保护后退出")
        alert.addButton(withTitle: "取消")
        if let 第三个 = alert.buttons.last {
            第三个.keyEquivalent = "\u{1b}"
        }

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            _ = app.保存()
            // ⌘S 已改成异步：进程退出前必须等写队列真的写完，否则一退就丢数据。
            // 这里允许阻塞 —— 退出路径宁可慢一点，不能丢内容。
            LocalStore.等待写队列空闲()
            return .terminateNow
        case .alertSecondButtonReturn:
            return .terminateNow
        default:
            return .terminateCancel
        }
    }
}

// MARK: - 打开 / 另存为面板

enum 项目文件面板 {
    // MARK: - 新建项目

    /// 文件 > 新建项目（⌘N）：DCC 传统语义 —— 给你一份全新的基础文档。
    ///
    /// 这里只负责「未保存改动」的确认；真正的从零构造在工作区状态.新建项目()，
    /// 它直接走与冷启动共用的构造路径，不是「复用当前文档再清空」。
    @MainActor
    static func 新建项目(_ app: AppStore) {
        if app.有未保存改动 {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "「\(app.项目名)」有未保存的改动"
            alert.informativeText = app.项目位置 == nil
                ? "这份文档还没存过盘。选「保存并新建」会先让你挑个位置存下来。"
                : "新建会把这份文档关掉。选「保存并新建」会先写进主工程文件。"
            alert.addButton(withTitle: "保存并新建")
            alert.addButton(withTitle: "不保存")
            alert.addButton(withTitle: "取消")
            if let 取消 = alert.buttons.last {
                取消.keyEquivalent = "\u{1b}"
            }
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                if app.项目位置 == nil {
                    // 未命名文档没有落点：先另存为，存成功了才有资格继续新建
                    另存为(app)
                    guard app.项目位置 != nil else { return }
                } else if !app.保存() {
                    return
                }
                // ⌘S 是异步写：必须等它真的落完再切文档，否则在途那笔会写脏新文档
                LocalStore.等待写队列空闲()
            case .alertSecondButtonReturn:
                break
            default:
                return
            }
        }
        // 新建项目内部自带：丢弃延后任务 + 等写队列空闲 + 递增保存代次
        app.新建项目()
    }

    /// ⌘S 的菜单入口：未命名文档还没有落点，按 DCC 习惯先走「另存为」，
    /// 存成功后这份文档就有了名字，之后再按 ⌘S 就是常规保存。
    @MainActor
    static func 保存(_ app: AppStore) {
        guard app.项目位置 != nil else {
            另存为(app)
            return
        }
        app.保存()
    }

    /// 打开：选一个 .cg 直接切换当前项目
    @MainActor
    static func 打开(_ app: AppStore) {
        let panel = NSOpenPanel()
        panel.title = "打开项目"
        panel.message = "选择一个 .cg 项目包"
        panel.prompt = "打开"
        panel.allowedContentTypes = [项目容器.文件类型]
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        // .cg 是 package：不这样设，面板会钻进去让人一层层选子目录
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = 项目容器.当前项目.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        app.打开项目(url)
    }

    /// 另存为：整个容器目录复制到新位置，之后所有写盘都落到新路径
    @MainActor
    static func 另存为(_ app: AppStore) {
        let panel = NSSavePanel()
        panel.title = "项目另存为"
        panel.message = "把当前项目整体复制成一个新的 .cg"
        panel.prompt = "存储"
        panel.allowedContentTypes = [项目容器.文件类型]
        panel.nameFieldStringValue = app.项目名
        panel.isExtensionHidden = false
        panel.canCreateDirectories = true
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = 项目容器.当前项目.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        app.另存为(url)
    }
}

// MARK: - 拖放

enum 项目拖放 {
    /// 返回 true 表示接管了这次拖放（有文件 URL 类型），避免系统再弹拒绝光标的抖动
    @discardableResult
    static func 接收(_ providers: [NSItemProvider],
                     完成: @escaping @MainActor (URL) -> Void) -> Bool {
        var 命中 = false
        for provider in providers
        where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            命中 = true
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                var url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let 值 = item as? URL {
                    url = 值
                } else if let 文本 = item as? String {
                    url = URL(fileURLWithPath: 文本)
                }
                guard let url, 项目容器.是容器(url) else { return }
                Task { @MainActor in
                    完成(url)
                }
            }
        }
        return 命中
    }
}
