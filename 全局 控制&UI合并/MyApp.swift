import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct MyApp: App {
    // 双击 .cg / 拖到 Dock 图标上的 open 事件在这里接
    @NSApplicationDelegateAdaptor(应用委托.self) private var 委托

    @State private var app = AppStore()
    @State private var 打开 = 打开请求.共享
    @State private var 拖入中 = false

    init() {
        // 首次启动就把用户目录（~/Documents/cg app）和四个子文件夹补齐
        用户目录.准备()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(app)
                .environment(app.shading)
                .environment(app.layout)
                .environment(app.render)
                .frame(minWidth: 1180, minHeight: 760)
                // 双击打开：delegate 只登记 URL，视图起来后才真正切项目
                .onAppear { 处理待打开(打开.待打开) }
                .onChange(of: 打开.待打开) { _, 新值 in 处理待打开(新值) }
                // 拖放：整个窗口范围接 .cg，其他类型直接不接管
                .onDrop(of: [.fileURL], isTargeted: $拖入中) { providers in
                    项目拖放.接收(providers) { url in
                        _ = app.打开项目(url)
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .defaultSize(width: 1480, height: 940)
        .commands {
            CommandGroup(replacing: .saveItem) {
                Button("保存") { 项目文件面板.保存(app) }
                    .keyboardShortcut("s", modifiers: [.command])
                Button("另存为…") { 项目文件面板.另存为(app) }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
            }
            // 文件 > 新建项目：⌘N，DCC 传统语义 —— 得到一份全新的基础文档
            // （基础场景 + 默认材质/相机/编辑器设置，不继承任何历史素材）。
            // 用 replacing 顶掉系统自带的「新建窗口」，避免两个 ⌘N 打架。
            CommandGroup(replacing: .newItem) {
                Button("新建项目") { 项目文件面板.新建项目(app) }
                    .keyboardShortcut("n", modifiers: [.command])
                Button("打开…") { 项目文件面板.打开(app) }
                    .keyboardShortcut("o", modifiers: [.command])
                Divider()
                Button("新建材质") { app.shading.addMaterial() }
                    // ⌘N 让给「新建项目」，材质退到 ⌥⌘N
                    .keyboardShortcut("n", modifiers: [.command, .option])
                Button("添加节点：RGB") {
                    app.shading.addNode(kind: .rgbConstant, at: CGPoint(x: 120, y: 320))
                }
                .keyboardShortcut("1", modifiers: [.command])
            }
            CommandGroup(after: .toolbar) {
                // 全局搜索：⌘F（系统 Spotlight 的 ⌘Space 抢不过来，⌘F 在本工程没被占用）
                Button("全局搜索…") { app.全局搜索打开 = true }
                    .keyboardShortcut("f", modifiers: [.command])
                Divider()
                Button("删除选中") { 删除选中() }
                    .keyboardShortcut(.delete, modifiers: [])
                Button("复制选中") { 复制选中() }
                    .keyboardShortcut("d", modifiers: [.command])
            }
        }

        // ⌘, 偏好设置：外观 / 主体颜色 / 画布细节
        Settings {
            偏好设置面板()
                .environment(app)
                .environment(app.shading)
                .environment(app.layout)
                .environment(app.render)
        }
    }

    /// ⌫ 只删"当前所在区"里的东西：
    /// 在材质面板就只删节点/连线，在视口才删物体。
    /// 不能靠"有没有选中节点"来猜 —— 节点没点中时会误落到删物体上。
    /// 正在文本框里打字则让给原生退格，别一边改名一边把模型删了
    private func 删除选中() {
        guard !正在输入文字() else { return }
        switch app.layout.焦点 {
        case .节点编辑器:
            if app.shading.selectedNodeID != nil || app.shading.selectedLinkID != nil {
                app.shading.deleteSelection()
            } else {
                app.shading.note("节点编辑器里没有选中节点或连线")
            }
        case .视口:
            if app.layout.删除选中物体() == 0 {
                app.shading.note("没有选中的物体")
            }
        }
    }

    /// ⌘D：复制视口里选中的物体（节点编辑器没有复制语义，这里就不抢它的键）
    private func 复制选中() {
        guard !正在输入文字() else { return }
        let 数量 = app.layout.复制选中()
        app.shading.note(数量 > 0 ? "已复制 \(数量) 个物体，可直接拖走" : "没有选中物体")
    }

    /// 焦点在 NSText / NSTextView（重命名框、数值输入框）时，快捷键一律让路
    private func 正在输入文字() -> Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        return responder is NSText || responder is NSTextView
    }

    /// 双击 .cg / 拖到 Dock 图标：拿到 URL 后切项目，处理完清空请求免重复触发
    private func 处理待打开(_ url: URL?) {
        guard let url else { return }
        if app.打开项目(url) {
            打开.待打开 = nil
        }
    }
}
