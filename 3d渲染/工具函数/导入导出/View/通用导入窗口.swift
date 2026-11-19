import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 窗口控制器

/// 「通用导入」只有这一个入口：点一次 → 选一堆文件 → 一个窗口按类型分 Tab。
/// 不再为每种格式单独做按钮，格式差异全部收进 Tab 里的侧边栏参数。
@MainActor
final class 通用导入窗口控制器: NSObject, NSWindowDelegate {
    static let shared = 通用导入窗口控制器()

    private var 窗口: NSWindow?

    private override init() { super.init() }

    /// 顶栏按钮 / 菜单 / 拖拽都走这里。
    /// `完成` 在用户点「放入场景」时回调，参数是全部成功解析出来的场景。
    func 显示(预设文件: [URL] = [], 完成: @escaping ([导入场景]) -> Void) {
        let 待导入: [URL]
        if !预设文件.isEmpty {
            待导入 = 预设文件
        } else {
            guard let 选中的 = 选文件() else { return }
            待导入 = 选中的
        }
        let 模型 = 通用导入模型(完成: 完成)
        模型.加入(待导入)
        guard !模型.文件表.isEmpty else { return }

        if 窗口 == nil { 建窗口(模型: 模型) }
        else if let 视图 = 窗口?.contentView as? NSHostingView<通用导入视图> {
            视图.rootView = 通用导入视图(模型: 模型) { [weak self] 场景集 in
                模型.交付(场景集)
                self?.窗口?.close()
            }
        }
        guard let 窗口 else { return }
        if 窗口.isMiniaturized { 窗口.deminiaturize(nil) }
        窗口.makeKeyAndOrderFront(nil)
    }

    func 选文件() -> [URL]? {
        let 面板 = NSOpenPanel()
        面板.title = "通用导入"
        面板.message = "可以混选：fbx / blend / usd / usda / usdc / usdz / gltf / glb / obj / stl / ply"
        面板.allowsMultipleSelection = true
        面板.canChooseDirectories = false
        面板.canChooseFiles = true
        面板.allowsOtherFileTypes = true
        面板.resolvesAliases = true
        var 类型: [UTType] = []
        for 格式 in 导入格式.allCases {
            for 扩展 in 格式.扩展名 {
                if let t = UTType(filenameExtension: 扩展) { 类型.append(t) }
            }
        }
        面板.allowedContentTypes = 类型.isEmpty ? [.data] : 类型
        return 面板.runModal() == .OK ? 面板.urls : nil
    }

    private func 建窗口(模型: 通用导入模型) {
        let 承载 = NSHostingView(rootView: 通用导入视图(模型: 模型) { [weak self] 场景集 in
            模型.交付(场景集)
            self?.窗口?.close()
        })
        let 新窗口 = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 660),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        新窗口.title = "通用导入"
        新窗口.minSize = NSSize(width: 880, height: 520)
        新窗口.contentView = 承载
        新窗口.isReleasedWhenClosed = false
        新窗口.tabbingMode = .disallowed
        新窗口.delegate = self
        if let 屏幕 = NSScreen.main {
            let 可见 = 屏幕.visibleFrame
            let 尺寸 = 新窗口.frame.size
            新窗口.setFrameOrigin(NSPoint(
                x: 可见.midX - 尺寸.width / 2,
                y: 可见.midY - 尺寸.height / 2
            ))
        }
        窗口 = 新窗口
    }

    func 关闭() { 窗口?.close() }
}

// MARK: - 模型

@MainActor
@Observable
final class 通用导入模型 {

    enum 阶段: Equatable {
        case 配置
        case 执行
        case 完成
    }

    var 文件表: [导入文件] = []
    /// 每个文件一份设置，key 是 导入文件.id
    var 设置表: [UUID: 单文件导入设置] = [:]
    var 选中Tab: 导入格式?
    var 当前阶段: 阶段 = .配置
    var 进度文本 = ""
    var 进度比: Double = 0
    var 结果: 批量导入结果?
    var 错误文本: String?

    private var 已取消 = false
    private let 取消锁 = NSLock()
    private let 完成回调: ([导入场景]) -> Void

    init(完成: @escaping ([导入场景]) -> Void) {
        完成回调 = 完成
    }

    // MARK: 文件

    /// 按扩展名 + 魔数归类。认不出的记进提示，不弹窗打断这一场导入。
    func 加入(_ urls: [URL]) {
        错误文本 = nil
        var 未识别: [String] = []
        for url in urls {
            guard let 文件 = 格式嗅探.识别(url: url) else {
                未识别.append(url.lastPathComponent)
                continue
            }
            guard !文件表.contains(where: { $0.url == url }) else { continue }
            文件表.append(文件)
            设置表[文件.id] = 单文件导入设置(id: 文件.id)
        }
        if !未识别.isEmpty {
            错误文本 = "已跳过无法识别的文件：\(未识别.joined(separator: "、"))"
        }
        if let 选 = 选中Tab, 出现的格式.contains(选) { return }
        选中Tab = 出现的格式.first
    }

    func 移除(_ 文件: 导入文件) {
        文件表.removeAll { $0.id == 文件.id }
        设置表.removeValue(forKey: 文件.id)
        if let 选 = 选中Tab, !出现的格式.contains(选) {
            选中Tab = 出现的格式.first
        }
    }

    /// 只列出真正出现过的格式 —— 这次没选 obj，就不该出现 OBJ 的 Tab
    var 出现的格式: [导入格式] {
        导入格式.allCases.filter { 格式 in 文件表.contains { $0.格式 == 格式 } }
    }

    func 文件集(_ 格式: 导入格式) -> [导入文件] {
        文件表.filter { $0.格式 == 格式 }
    }

    func 计数(_ 格式: 导入格式) -> Int {
        文件表.filter { $0.格式 == 格式 }.count
    }

    var 启用文件: [导入文件] { 文件表.filter { $0.启用 } }

    var 桥接提示: String {
        "全部格式走内置原生解析，不依赖任何外部软件"
    }

    // MARK: 设置绑定

    func 绑定<值>(_ 文件: 导入文件, _ 键: WritableKeyPath<单文件导入设置, 值>) -> Binding<值> {
        Binding(
            get: { [weak self] in
                (self?.设置表[文件.id] ?? 单文件导入设置())[keyPath: 键]
            },
            set: { [weak self] 新 in
                guard let self else { return }
                var 设置 = 设置表[文件.id] ?? 单文件导入设置(id: 文件.id)
                设置[keyPath: 键] = 新
                设置表[文件.id] = 设置
            }
        )
    }

    /// 把某个文件的参数抄给同 Tab 的其它文件 —— 一批 obj 通常参数完全一样
    func 应用到本Tab(_ 文件: 导入文件) {
        guard let 源 = 设置表[文件.id] else { return }
        for 其它 in 文件表 where 其它.格式 == 文件.格式 && 其它.id != 文件.id {
            var 复制 = 源
            复制.id = 其它.id
            设置表[其它.id] = 复制
        }
    }

    // MARK: 执行

    func 开始导入() {
        guard 当前阶段 == .配置 else { return }
        let 文件快照 = 文件表
        let 设置快照 = 设置表
        guard 文件快照.contains(where: { $0.启用 }) else {
            错误文本 = "没有勾选任何文件"
            return
        }
        当前阶段 = .执行
        进度比 = 0
        进度文本 = "准备导入…"
        结果 = nil
        取消锁.lock(); 已取消 = false; 取消锁.unlock()

        DispatchQueue.global(qos: .userInitiated).async {
            let 输出 = 导入调度.批量(
                文件快照,
                设置表: 设置快照,
                进度: { 序, 总, 名 in
                    let 比 = 总 > 0 ? Double(序) / Double(总) : 0
                    DispatchQueue.main.async {
                        self.进度比 = 比
                        self.进度文本 = 名.isEmpty ? "收尾…" : "\(min(序 + 1, 总))/\(总)  \(名)"
                    }
                },
                已取消: {
                    self.取消锁.lock()
                    defer { self.取消锁.unlock() }
                    return self.已取消
                }
            )
            DispatchQueue.main.async {
                self.结果 = 输出
                self.进度比 = 1
                self.当前阶段 = .完成
            }
        }
    }

    func 取消() {
        guard 当前阶段 == .执行 else { return }
        取消锁.lock(); 已取消 = true; 取消锁.unlock()
        进度文本 = "正在取消（当前文件处理完就停）…"
    }

    /// 完成阶段点「放入场景」
    func 确认放入() {
        guard let 结果 else { return }
        完成回调(结果.成功.map(\.场景))
    }

    /// 视图侧已拿到一批成品场景时直接交付（不再走 结果 汇总）
    func 交付(_ 场景集: [导入场景]) {
        guard !场景集.isEmpty else { return }
        完成回调(场景集)
    }
}
