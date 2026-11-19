import SwiftUI
import AppKit

/// App 主壳：顶部工作区 Tab（macOS 原生 TabView 标签栏）+ 底部状态条。
/// 每个 Tab 是一个"工作模式"，不是页面跳转——切 Tab 不销毁场景与材质状态。
struct RootTabs: View {
    @Environment(AppStore.self) private var app

    /// 全局快捷键监视器（空格 / i / j / k）
    @State private var 键监视: Any?

    var body: some View {
        @Bindable var app = app

        TabView(selection: $app.tab) {
            Tab(WorkspaceTab.shading.title, systemImage: WorkspaceTab.shading.symbol, value: WorkspaceTab.shading) {
                ShadingWorkspace()
            }
            Tab(WorkspaceTab.layout.title, systemImage: WorkspaceTab.layout.symbol, value: WorkspaceTab.layout) {
                LayoutWorkspace()
            }
            Tab(WorkspaceTab.render.title, systemImage: WorkspaceTab.render.symbol, value: WorkspaceTab.render) {
                RenderWorkspace()
            }
            Tab(WorkspaceTab.assets.title, systemImage: WorkspaceTab.assets.symbol, value: WorkspaceTab.assets) {
                AssetWorkspace()
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                // 时间轴条是全局的：四个工作区共用同一个播放头，
                // 布局里打的关键帧，切到着色 / 渲染 / 资源照样能看到在动。
                帧播放器条()
                StatusBar()
            }
        }
        // 保存失败必须有可见反馈，绝不静默
        .alert("保存失败", isPresented: Binding(
            get: { app.保存失败信息 != nil },
            set: { if !$0 { app.保存失败信息 = nil } }
        )) {
            Button("重试 ⌘S", role: .cancel) { app.保存失败信息 = nil; _ = app.保存() }
            Button("另存为…") { app.保存失败信息 = nil; 项目文件面板.另存为(app) }
        } message: {
            Text(app.保存失败信息 ?? "")
        }
        .onAppear { 安装键监视() }
        .onDisappear {
            if let 键监视 { NSEvent.removeMonitor(键监视) }
            键监视 = nil
        }
    }

    // MARK: - 全局快捷键

    /// 空格 / i / j / k 是**全局播放快捷键**，跟时间轴条一样不属于任何 Tab。
    ///
    /// 为什么不用 `keyboardShortcut`：那套走菜单 keyEquivalent，会抢在字段编辑器之前
    /// 吃掉按键 —— 用户在数值框里就打不出 i 了。这里用本地事件监视器，第一响应者是
    /// 文本编辑（数值框、搜索框、代码框）时直接放行，其余情况才消费。
    private func 安装键监视() {
        guard 键监视 == nil else { return }
        let app = self.app
        键监视 = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { 事件 in
            MainActor.assumeIsolated { Self.处理(事件, app: app) }
        }
    }

    private static func 处理(_ 事件: NSEvent, app: AppStore) -> NSEvent? {
        // 正在打字：一律放行
        if let 响应者 = NSApp.keyWindow?.firstResponder,
           响应者 is NSTextView || 响应者 is NSTextField {
            return 事件
        }
        // 带修饰键的交给菜单/系统（⌘S ⌘Z 之类）
        let 修饰 = 事件.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .capsLock, .function])
        guard 修饰.isEmpty else { return 事件 }

        let 域 = 时间轴域.共享
        switch 事件.charactersIgnoringModifiers {
        case " ":
            域.切换播放()
            app.statusMessage = 域.播放中 ? "播放中 · 第 \(域.当前帧) 帧" : "已暂停 · 第 \(域.当前帧) 帧"
            return nil
        case "i":
            app.statusMessage = 动画接线.共享.打帧快捷键()
            return nil
        case "j":
            域.步进(-1)
            return nil
        case "k":
            域.步进(1)
            return nil
        default:
            return 事件
        }
    }
}

// MARK: - 状态条

struct StatusBar: View {
    @Environment(AppStore.self) private var app
    @Environment(着色Store.self) private var shading
    @Environment(渲染Store.self) private var render

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(render.isRendering ? Color.orange : Color.green.opacity(0.8))
                .frame(width: 6, height: 6)
            Text(app.statusMessage)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            // 保存态：⌘S 已异步化，这里如实反映「正在保存」→「已保存」/「保存失败」
            switch app.保存状态 {
            case .正在保存:
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.7)
                    .frame(width: 10, height: 10)
                Text("正在保存…")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.accentColor)
            case .失败(let 原因):
                Text("保存失败：\(原因)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.red.opacity(0.95))
                    .help("改动仍在内存中，⌘S 可重试")
            case .空闲:
                EmptyView()
            }

            // 脏状态：主工程文件还没写。自动保护只是多留一份独立文件，不算已保存。
            if app.有未保存改动 {
                Text("未保存")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.orange.opacity(0.95))
                    .help("有改动尚未写入主工程文件，⌘S 保存")
                if let 保护时间 = app.最近自动保护时间 {
                    Text("·")
                        .foregroundStyle(.quaternary)
                    Text("已自动保护 \(保护时间.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .help("保护文件在 App 支持目录的 autosave/ 下，保留最近 3 份")
                }
            }

            Spacer(minLength: 8)

            if let material = shading.activeMaterial {
                let resolved = MaterialCompiler.resolve(material)
                Text("驱动参数 \(resolved.drivenKeys.count)/\(PBRParamKey.allCases.count)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Text("·")
                    .foregroundStyle(.quaternary)
                Text("视口缺口 \(resolved.viewportGaps.count)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(resolved.viewportGaps.isEmpty ? Color.secondary.opacity(0.7) : Color.orange.opacity(0.9))
            }
            Text("·")
                .foregroundStyle(.quaternary)
            Text(shading.viewport.environment.title)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
            Text(shading.viewport.shading.title)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
        }
    }
}

// MARK: - 小工具

struct PanelHeader: View {
    var title: String
    var symbol: String
    var trailing: AnyView?

    init<Content: View>(title: String, symbol: String, @ViewBuilder trailing: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.trailing = AnyView(trailing())
    }

    init(title: String, symbol: String) {
        self.title = title
        self.symbol = symbol
        self.trailing = nil
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            if let trailing { trailing }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Theme.panelBackground.opacity(0.55))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
        }
    }
}
