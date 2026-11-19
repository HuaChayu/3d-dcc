import AppKit
import SwiftUI

/// App 根视图：把「偏好设置」里的外观/主色落到整棵视图树上。
/// 配色令牌是静态读取的，改了必须换 `.id` 重建一次才会重新取值。
struct ContentView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppStore.self) private var app
    private var 偏好: 偏好设置Store { .shared }

    var body: some View {
        RootTabs()
            .tint(Theme.accent)
            .background(Theme.canvasBackground)
            .preferredColorScheme(偏好.外观.强制配色)
            .id(偏好.变更版本)
            // 全局搜索浮层：盖在整棵工作区之上，⌘F 唤起（不用 ⌘Space，那是系统 Spotlight 的）
            .overlay(alignment: .top) {
                if app.全局搜索打开 {
                    全局搜索面板()
                }
            }
            .animation(.easeOut(duration: 0.14), value: app.全局搜索打开)
            .onAppear {
                偏好.记录系统外观(colorScheme == .dark)
                关闭多余色彩面板()
            }
            .onChange(of: colorScheme) { _, newValue in
                偏好.记录系统外观(newValue == .dark)
            }
    }

    /// SwiftUI 的 ColorPicker 会在启动时顺手弹一个空的「Colors」面板，直接收掉
    private func 关闭多余色彩面板() {
        for delay in [0.4, 1.2] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                for window in NSApp.windows where window.title == "Colors" {
                    window.orderOut(nil)
                }
            }
        }
    }
}

#Preview {
    ContentView()
        .environment(AppStore())
        .frame(width: 1480, height: 940)
}
