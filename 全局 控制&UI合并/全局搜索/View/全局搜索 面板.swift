import AppKit
import SwiftUI

/// 全局搜索面板（⌘F）。
///
/// 交互按系统 Spotlight 的手感来：居中浮层、上方输入、下方结果按类型分组、
/// 键盘 ↑↓ 选、↩ 跳转、esc 收起。但它搜的是本工程的实体，点下去会跳到对应区间并聚焦。
///
/// 这一层只做"找 + 搬光标"，选中/聚焦全都复用各区间现成的手动点击逻辑。
struct 全局搜索面板: View {
    @Environment(AppStore.self) private var app

    @State private var 词 = ""
    @State private var 高亮 = 0
    @State private var 键盘监视: Any?
    @FocusState private var 输入聚焦: Bool

    private let 面板宽: CGFloat = 580

    var body: some View {
        ZStack(alignment: .top) {
            遮罩
            面板
                .padding(.top, 110)
        }
        .onAppear {
            Task { @MainActor in 输入聚焦 = true }
            安装键盘()
        }
        .onDisappear { 卸载键盘() }
        .onChange(of: 词) { _, _ in 高亮 = 0 }
    }

    // MARK: 命中

    private var 分组: [命中分组] {
        let 全部 = app.搜索结果(for: 词)
        guard !全部.isEmpty else { return [] }
        return 搜索命中.类别.allCases.compactMap { 类别 in
            let 项 = 全部.filter { $0.类别 == 类别 }
            return 项.isEmpty ? nil : 命中分组(类别: 类别, 项: 项)
        }
    }

    /// 键盘上下走的顺序 = 面板上从上往下的顺序
    private var 平铺: [搜索命中] { 分组.flatMap(\.项) }

    private var 当前命中: 搜索命中? {
        guard !平铺.isEmpty else { return nil }
        return 平铺.indices.contains(高亮) ? 平铺[高亮] : 平铺.first
    }

    // MARK: 骨架

    private var 遮罩: some View {
        Color.black.opacity(0.22)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture { 关闭() }
    }

    private var 面板: some View {
        VStack(spacing: 0) {
            搜索框
            Divider().overlay(Theme.divider)
            结果区
            Divider().overlay(Theme.divider)
            提示条
        }
        .frame(width: 面板宽)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Theme.divider, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.3), radius: 28, y: 14)
    }

    private var 搜索框: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("搜索材质、物体…", text: $词)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($输入聚焦)
                .onSubmit { 执行当前() }

            if !词.isEmpty {
                Button {
                    词 = ""
                    输入聚焦 = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
            }

            Text("⌘F")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 5).fill(Theme.canvasBackground.opacity(0.75))
                )
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
    }

    // MARK: 结果

    @ViewBuilder
    private var 结果区: some View {
        ScrollViewReader { 滚动 in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if 词.trimmingCharacters(in: .whitespaces).isEmpty {
                        空提示("输入名字：材质库里的材质、场景里的物体都能搜")
                    } else if 平铺.isEmpty {
                        空提示("没有匹配「\(词)」的材质或物体")
                    } else {
                        ForEach(分组) { 组 in
                            组标题(组.类别, 数量: 组.项.count)
                            ForEach(组.项) { 项 in
                                行(项).id(项.id)
                            }
                        }
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 6)
            }
            .frame(maxHeight: 340)
            .onChange(of: 高亮) { _, 新值 in
                guard 平铺.indices.contains(新值) else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    滚动.scrollTo(平铺[新值].id, anchor: .center)
                }
            }
        }
    }

    private func 组标题(_ 类别: 搜索命中.类别, 数量: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: 类别.图标)
                .font(.system(size: 9))
            Text(类别.标题)
                .font(.system(size: 10, weight: .semibold))
            Text("\(数量)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 3)
    }

    private func 行(_ 项: 搜索命中) -> some View {
        let 选中 = 当前命中?.id == 项.id
        return HStack(spacing: 10) {
            类型图标(项)

            VStack(alignment: .leading, spacing: 1) {
                Text(项.名称)
                    .font(.system(size: 12))
                    .lineLimit(1)
                Text(项.副标题)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            Text(项.类别.标题)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill(Theme.canvasBackground.opacity(0.75))
                )
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(选中 ? Color.accentColor.opacity(0.2) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { 执行(项) }
        .onHover { 进入 in
            guard 进入, let 序 = 平铺.firstIndex(where: { $0.id == 项.id }) else { return }
            高亮 = 序
        }
        .help(跳转说明(项))
    }

    private func 类型图标(_ 项: 搜索命中) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Theme.canvasBackground.opacity(0.85))
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(Theme.stroke, lineWidth: 0.5)
                )
            if let 色 = 项.色 {
                Circle()
                    .fill(Theme.color(from: 色))
                    .frame(width: 13, height: 13)
                    .overlay(Circle().stroke(Theme.stroke, lineWidth: 0.5))
            } else {
                Image(systemName: 项.类别.图标)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 22, height: 22)
    }

    private func 空提示(_ 文本: String) -> some View {
        Text(文本)
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 26)
    }

    private var 提示条: some View {
        HStack(spacing: 12) {
            键位提示("↑↓", "选择")
            键位提示("↩", "跳转")
            键位提示("esc", "关闭")
            Spacer()
            Text("物体→大纲聚焦 · 材质→材质库聚焦")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Theme.canvasBackground.opacity(0.45))
    }

    private func 键位提示(_ 键: String, _ 说明: String) -> some View {
        HStack(spacing: 4) {
            Text(键)
                .font(.system(size: 9, design: .monospaced))
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(
                    RoundedRectangle(cornerRadius: 4).fill(Theme.canvasBackground.opacity(0.8))
                )
            Text(说明)
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: 执行

    private func 执行当前() {
        guard let 目标 = 当前命中 else { return }
        执行(目标)
    }

    private func 执行(_ 项: 搜索命中) {
        卸载键盘()
        app.跳转到(项)
    }

    private func 跳转说明(_ 项: 搜索命中) -> String {
        switch 项.类别 {
        case .对象: "在布局大纲里聚焦这个物体（不切走当前 Tab）"
        case .材质: "切到着色工作区的材质库页并选中它"
        }
    }

    private func 关闭() {
        卸载键盘()
        app.全局搜索打开 = false
    }

    // MARK: 键盘

    /// 用本地事件监听而不是 SwiftUI 的 onKeyPress：
    /// 输入框拿到焦点后会先把 ↑↓ 当光标移动吃掉，onKeyPress 收不到。
    private func 安装键盘() {
        guard 键盘监视 == nil else { return }
        键盘监视 = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { 事件 in
            // ⌘F 再按一次 = 收起，和打开同一个键（Spotlight 手感）
            if 事件.modifierFlags.contains(.command),
               事件.charactersIgnoringModifiers?.lowercased() == "f" {
                关闭()
                return nil
            }
            // 带修饰键的组合还给系统（⌘S 之类照常可用）
            guard 事件.modifierFlags.intersection([.command, .option, .control]).isEmpty else {
                return 事件
            }
            switch 事件.keyCode {
            case 125: 移动高亮(1); return nil        // ↓
            case 126: 移动高亮(-1); return nil       // ↑
            case 53: 关闭(); return nil             // esc
            case 36, 76: 执行当前(); return nil      // return / enter
            default: return 事件
            }
        }
    }

    private func 卸载键盘() {
        if let 监视 = 键盘监视 {
            NSEvent.removeMonitor(监视)
            键盘监视 = nil
        }
    }

    private func 移动高亮(_ 步: Int) {
        let 总数 = 平铺.count
        guard 总数 > 0 else { return }
        高亮 = min(max(高亮 + 步, 0), 总数 - 1)
    }
}

/// 结果分组（面板内部用）
private struct 命中分组: Identifiable {
    let 类别: 搜索命中.类别
    let 项: [搜索命中]

    var id: String { 类别.rawValue }
}
