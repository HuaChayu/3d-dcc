import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 出图窗口控制器

/// 传统 DCC 那种「Render Window」：点顶栏相机按钮弹出一个独立窗口，出图过程直接在窗口里
/// 渐进显示（越渲越干净），视口只当预览用。
///
/// 为什么用 AppKit 承载：SwiftUI 的 Window scene 要改 MyApp 的 scene 声明，容易牵动全局
/// 窗口/菜单行为；这里 NSWindow + NSHostingView 自管一个窗口，开关都不影响主界面。
@MainActor
final class 出图窗口控制器: NSObject, NSWindowDelegate {
    static let shared = 出图窗口控制器()

    private var 窗口: NSWindow?
    /// 窗口内容的数据来源：每次开窗把视口最新状态灌进来
    private let 来源 = 出图窗口来源()

    private override init() {
        super.init()
    }

    /// 顶栏相机按钮调用：灌入当前场景/相机 → 建或复用窗口 → 前置。
    func 显示(
        objects: [SceneObject],
        materials: [UUID: MaterialAsset],
        视口: ViewportSettings,
        相机: @escaping () -> PTCamera?
    ) {
        来源.objects = objects
        // 不冻结材质副本：只记下用到哪些材质 id，真值永远向材质域现取
        来源.材质IDs = materials.keys.sorted { $0.uuidString < $1.uuidString }
        来源.视口 = 视口
        来源.相机 = 相机

        if 窗口 == nil { 建窗口() }
        guard let 窗口 else { return }
        if 窗口.isMiniaturized { 窗口.deminiaturize(nil) }
        窗口.makeKeyAndOrderFront(nil)
    }

    private func 建窗口() {
        let 承载 = NSHostingView(rootView: 出图窗口视图(来源: 来源))
        let 新窗口 = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        新窗口.title = "渲染出图"
        新窗口.minSize = NSSize(width: 1000, height: 480)   // 两行参数条的固定宽度合计约 860，低于 1000 状态文字就没地方放了
        新窗口.contentView = 承载
        新窗口.isReleasedWhenClosed = false   // 关掉只是隐藏，下次开窗保留上次参数与画面
        新窗口.tabbingMode = .disallowed
        新窗口.delegate = self
        if let 屏幕 = NSScreen.main {
            let 可见 = 屏幕.visibleFrame
            let 尺寸 = 新窗口.frame.size
            新窗口.setFrameOrigin(NSPoint(
                x: 可见.midX - 尺寸.width / 2,
                y: 可见.midY - 尺寸.height / 2 + 40
            ))
        }
        窗口 = 新窗口
    }

    /// 关窗即停：正在渲染就取消（会话的 取消() 会退出离屏模式并恢复视口刷新）
    func windowWillClose(_ notification: Notification) {
        let 会话 = PT出图会话.shared
        if 会话.进行中 { 会话.取消() }
    }

    /// 供窗口内「关闭」等场合使用
    func 关闭() {
        窗口?.close()
    }
}

/// 窗口内容的数据来源（@Observable：重新开窗灌新场景后窗口视图自动刷新）
@Observable
@MainActor
final class 出图窗口来源 {
    var objects: [SceneObject] = []
    /// 出图要用的材质 id 集合（打开窗口那一刻的场景用到的那些）。
    /// 材质内容不在这里存副本 —— 每次向数据层材质域取，改材质后出图跟着变，不会各存一份。
    var 材质IDs: [UUID] = []
    var materials: [UUID: MaterialAsset] {
        var 表: [UUID: MaterialAsset] = [:]
        for id in 材质IDs { if let 资产 = 材质接线.共享.取(资产: id) { 表[id] = 资产 } }
        return 表
    }
    var 视口 = ViewportSettings()
    var 相机: () -> PTCamera? = { nil }
}

// MARK: - 窗口内容

/// 上：参数条（分辨率/采样/弹射/输出）+ 状态与按钮；下：图像区铺满剩余空间。
/// 降噪与曝光刻意不在窗口暴露：一律跟随视口设置，避免同一参数两处操作。
struct 出图窗口视图: View {
    let 来源: 出图窗口来源

    @State private var 会话 = PT出图会话.shared

    // 参数
    @State private var 预设: 出图分辨率预设 = .全高清
    @State private var 自定义宽 = 2560
    @State private var 自定义高 = 1440
    @State private var 采样 = 100
    @State private var 弹射 = 8
    // 降噪与曝光不在窗口里暴露：一律跟随视口（降噪常开 = 与视口同一条 OIDN 链路）

    // 输出
    @State private var 目录URL = 出图窗口视图.默认目录
    @State private var 文件名 = ""
    @State private var 副本提示 = ""

    var body: some View {
        VStack(spacing: 0) {
            参数条
            Divider()
            图像区
        }
        .frame(minWidth: 1000, minHeight: 480)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            if 文件名.isEmpty { 文件名 = 出图窗口视图.默认文件名() }
        }
    }

    // MARK: 参数条

    private var 参数条: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 第一行：分辨率 +（自定义时）尺寸 + 采样 + 弹射
            HStack(spacing: 12) {
                分组("分辨率") {
                    Picker("", selection: $预设) {
                        ForEach(出图分辨率预设.allCases) { 项 in
                            Text(项.标题).tag(项)
                        }
                    }
                    .pickerStyle(.menu)          // 下拉省宽：四段 segmented 会把这一行撑爆
                    .labelsHidden()
                    .font(.system(size: 11))
                    .frame(width: 120)
                }
                .fixedSize()

                if 预设 == .自定义 {
                    分组("尺寸") {
                        HStack(spacing: 4) {
                            TextField("宽", value: $自定义宽, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 54)
                            Text("×").foregroundStyle(.secondary)
                            TextField("高", value: $自定义高, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 54)
                        }
                        .fixedSize()
                    }
                    .fixedSize()
                }

                分组("采样") {
                    HStack(spacing: 4) {
                        TextField("", value: $采样, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 56)
                        Stepper("", value: $采样, in: 1...16384, step: 64)
                            .labelsHidden()
                        Text("spp").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    .fixedSize()
                }
                .fixedSize()

                分组("弹射") {
                    HStack(spacing: 4) {
                        TextField("", value: $弹射, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 44)
                        Stepper("", value: $弹射, in: 1...32)
                            .labelsHidden()
                        Text("次").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    .fixedSize()
                }
                .fixedSize()

                Spacer(minLength: 0)
            }

            // 第二行：输出（左）+ 状态与按钮（右）
            HStack(spacing: 12) {
                分组("输出") {
                    HStack(spacing: 8) {
                        Text(目录URL.path)
                            .font(.system(size: 10, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                            .frame(width: 130, alignment: .leading)
                            .help(目录URL.path)
                        Button {
                            选目录()
                        } label: {
                            Label("选择文件夹", systemImage: "folder")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("换个输出目录")
                        TextField("", text: $文件名)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                        Text(".png").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    .fixedSize()
                }
                .fixedSize()

                Spacer(minLength: 0)

                状态行
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    /// 状态与操作按钮：并到参数条第二行右侧；文字可省略中间，控件一律不压缩
    private var 状态行: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(状态色)
                .frame(width: 6, height: 6)
                .fixedSize()
            Text(状态文字)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(minWidth: 0, maxWidth: 360, alignment: .leading)
                .layoutPriority(1)
                .help(状态文字)
            ProgressView(value: 会话.进度)
                .progressViewStyle(.linear)
                .frame(width: 120)
                .fixedSize()
            Text("\(会话.已采样)/\(max(会话.目标采样, 1)) spp")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .fixedSize()

            HStack(spacing: 8) {
                if 会话.阶段 == .已完成, !会话.输出路径.isEmpty {
                    Button {
                        显示文件()
                    } label: {
                        Image(systemName: "folder")
                    }
                    .help("在 Finder 中显示")
                }
                Button("保存副本…") { 保存副本() }
                    .disabled(会话.预览图 == nil)
                if 会话.进行中 {
                    Button("取消") { 会话.取消() }
                }
                Button("渲染") { 开始() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(会话.进行中)
            }
            .font(.system(size: 11))
            .fixedSize()
        }
    }

    // MARK: 图像区

    private var 图像区: some View {
        ZStack {
            Color(white: 0.11)
            if let 图 = 会话.预览图 {
                Image(nsImage: NSImage(cgImage: 图, size: NSSize(width: 图.width, height: 图.height)))
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)   // 等比适应，窗口改动实时跟随
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "camera.aperture")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text(会话.进行中 ? "等待第一帧…" : "点「渲染」开始出图")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text(分辨率说明)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private var 分辨率说明: String {
        let (宽, 高) = 实际尺寸()
        return "\(宽) × \(高) · \(采样) spp"
    }

    // MARK: 小工具

    private func 分组<内容: View>(_ 标题: String, @ViewBuilder 内容: () -> 内容) -> some View {
        HStack(spacing: 6) {
            Text(标题)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            内容()
        }
    }

    private var 状态文字: String {
        // 阶段说明优先；已完成时把副本提示顶到前面（用户刚点了保存副本，要知道存哪儿了）
        if 会话.阶段 == .已完成, !副本提示.isEmpty { return 副本提示 }
        if 会话.说明.isEmpty {
            switch 会话.阶段 {
            case .空闲: return 副本提示.isEmpty ? "待出图：设好参数点「渲染」" : 副本提示
            case .渲染中: return "渲染中"
            case .已完成: return "已完成"
            case .已取消: return "已取消"
            case .失败: return "失败"
            }
        }
        return 会话.说明
    }

    private var 状态色: Color {
        switch 会话.阶段 {
        case .空闲: .secondary
        case .渲染中: .orange
        case .已完成: .green
        case .已取消: .secondary
        case .失败: .red
        }
    }

    // MARK: 行为

    private func 实际尺寸() -> (Int, Int) {
        if 预设 == .自定义 {
            return (max(自定义宽, 16), max(自定义高, 16))
        }
        return (预设.宽, 预设.高)
    }

    private func 开始() {
        let (宽, 高) = 实际尺寸()
        // 场景在这一刻编译成 PTScene 快照：出图过程与视口的后续操作完全解耦
        let 场景 = PTTranslator.build(
            objects: 来源.objects,
            materials: 来源.materials,
            settings: 来源.视口
        )
        副本提示 = ""
        会话.开始(
            宽: 宽,
            高: 高,
            目标采样数: 采样,
            最大弹射: 弹射,
            降噪: true,                       // 一律与视口同链路：常开
            曝光: 来源.视口.exposure,          // 一律跟随视口曝光（窗口内不再单独调）
            视口设置: 来源.视口,
            场景: 场景,
            相机: 来源.相机(),
            输出: 最终URL
        )
    }

    private func 选目录() {
        let 面板 = NSOpenPanel()
        面板.canChooseFiles = false
        面板.canChooseDirectories = true
        面板.canCreateDirectories = true
        面板.allowsMultipleSelection = false
        面板.directoryURL = 目录URL
        面板.prompt = "选这个目录"
        if 面板.runModal() == .OK, let 选中 = 面板.url {
            目录URL = 选中
        }
    }

    private func 保存副本() {
        let 面板 = NSSavePanel()
        面板.canCreateDirectories = true
        面板.allowedContentTypes = [.png]
        面板.directoryURL = 目录URL
        let 名 = URL(fileURLWithPath: 会话.输出路径).deletingPathExtension().lastPathComponent
        面板.nameFieldStringValue = (名.isEmpty ? 出图窗口视图.默认文件名() : 名) + ".png"
        guard 面板.runModal() == .OK, let url = 面板.url else { return }
        do {
            try 会话.保存副本(到: url)
            副本提示 = "已保存副本：\(url.path)"
        } catch {
            副本提示 = "保存副本失败：\(error.localizedDescription)"
        }
    }

    private func 显示文件() {
        let url = URL(fileURLWithPath: 会话.输出路径)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// 文件名去掉用户可能手输的 .png / 路径分隔符，最终 URL 统一补 .png
    /// 用户输入 → 规范化基名（去掉可能手输的 .png / 路径分隔符），再查重成磁盘上确实不存在的路径
    private var 最终URL: URL {
        let 基名 = 出图窗口视图.规范化基名(文件名)
        return 出图窗口视图.唯一路径(目录: 目录URL, 基名: 基名)
    }

    /// "渲染_x.png" / "渲染_x" / "渲染_x.PNG" 都归一到 "渲染_x"，避免出现 "x.png (1).png"
    static func 规范化基名(_ 原始: String) -> String {
        var 名 = 原始.trimmingCharacters(in: .whitespacesAndNewlines)
        if 名.lowercased().hasSuffix(".png") { 名 = String(名.dropLast(4)) }
        名 = 名.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        名 = 名.trimmingCharacters(in: .whitespacesAndNewlines)
        if 名.isEmpty { 名 = 默认文件名() }
        return 名
    }

    /// 重名保护：占用则依次试 "基名 (1).png"、"基名 (2).png"…（序号在扩展名前，一个空格）
    static func 唯一路径(目录: URL, 基名: String) -> URL {
        let 文件管理 = FileManager.default
        let 首选 = 目录.appendingPathComponent(基名 + ".png")
        if !文件管理.fileExists(atPath: 首选.path) { return 首选 }
        var 序号 = 1
        while true {
            let 候选 = 目录.appendingPathComponent("\(基名) (\(序号)).png")
            if !文件管理.fileExists(atPath: 候选.path) { return 候选 }
            序号 += 1
            if 序号 > 9999 { return 候选 }   // 兜底，正常走不到
        }
    }

    // MARK: 默认值（与旧面板一致，避免两套 UI 并存）

    static var 默认目录: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop")
            .appendingPathComponent("3d渲染输出")
    }

    static func 默认文件名() -> String {
        let 格式 = DateFormatter()
        格式.dateFormat = "yyyyMMdd_HHmmss"
        return "渲染_" + 格式.string(from: .now)
    }
}

// MARK: - 分辨率预设

enum 出图分辨率预设: String, CaseIterable, Identifiable {
    case 全高清
    case 二K
    case 四K
    case 自定义

    var id: String { rawValue }

    var 标题: String {
        switch self {
        case .全高清: "1920×1080"
        case .二K: "2560×1440"
        case .四K: "3840×2160"
        case .自定义: "自定义"
        }
    }

    var 宽: Int {
        switch self {
        case .全高清: 1920
        case .二K: 2560
        case .四K: 3840
        case .自定义: 2560
        }
    }

    var 高: Int {
        switch self {
        case .全高清: 1080
        case .二K: 1440
        case .四K: 2160
        case .自定义: 1440
        }
    }
}
