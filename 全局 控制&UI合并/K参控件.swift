import SwiftUI

// MARK: - 悬停通道

/// 鼠标此刻停在哪条通道的输入框上。
///
/// 存在的理由只有一个：`i` 打帧要"打你正看着的那条"，而不是打一堆你不知道的。
/// 它不属于任何域，也不是场景状态 —— 纯交互态，所以放全局、不落盘。
@MainActor
@Observable
final class 动画悬停 {
    static let 共享 = 动画悬停()
    private init() {}

    var 键: String?
}

// MARK: - K 参控件

/// 带关键帧点的数值输入：左边一菱形，右边跟原来一模一样的数值框。
///
/// 所有"能被动画"的参数都换成这个控件，控件自己在注册表里按 `键` 找通道 ——
/// 打帧、显示关键帧状态、自动 K 帧录制全在这里收口，不再每处手写一遍。
/// 键对应的通道没登记过（物体不在场景里）时，菱形不响应，输入框退化成普通数值框。
struct K参控件: View {

    /// 通道键，如 `obj/<uuid>/transform/pos.x`
    var 键: String
    var 值: Double
    /// 轴标签（X / Y / Z）。nil = 不显示标签（单值参数用）
    var 轴名: String? = nil
    /// 提交数值：调用方负责写模型
    var 提交: (Double) -> Void

    private var 域: 时间轴域 { .共享 }
    private var 悬停: 动画悬停 { .共享 }

    /// 通道存在才显示"能打帧"的实心/空心菱形；不存在就是一条淡灰装饰
    private var 有通道: Bool { 动画通道注册表.共享.通道(键) != nil }

    private var 当前帧有帧: Bool { 有通道 && 域.当前帧有关键帧(键) }
    private var 有轨道: Bool { 有通道 && 域.有关键帧(键) }
    private var 偏离: Bool { 有通道 && 域.偏离关键帧(键) }

    var body: some View {
        HStack(spacing: 3) {
            K点

            if let 轴名 {
                Text(轴名)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            变换数值输入(值: 值) { 新 in
                提交(新)
                // 自动 K 帧开着才录制；关着就只改模型，轨道一动不动（默认关）
                域.值被改(键: 键, 新值: 新)
            }
            .frame(maxWidth: .infinity)
        }
        .onHover { 进入 in
            if 进入 {
                悬停.键 = 键
            } else if 悬停.键 == 键 {
                悬停.键 = nil
            }
        }
    }

    // MARK: 菱形

    private var 符号: String {
        当前帧有帧 ? "diamond.fill" : "diamond"
    }

    private var 颜色: Color {
        if 当前帧有帧 { return Theme.主色 }
        if 有轨道 { return Theme.主色.opacity(0.45) }
        return Color.secondary.opacity(0.3)
    }

    private var 提示: String {
        guard 有通道 else { return "这条通道没有登记，不能打关键帧" }
        if 当前帧有帧 { return "第 \(域.当前帧) 帧有关键帧，点一下删除" }
        if 偏离 { return "当前值偏离关键帧：点一下按现值重打第 \(域.当前帧) 帧" }
        if 有轨道 { return "第 \(域.当前帧) 帧没有关键帧，点一下打帧" }
        return "点一下在当前帧打关键帧（i）"
    }

    private var K点: some View {
        Button {
            点一下()
        } label: {
            Image(systemName: 符号)
                .font(.system(size: 8, weight: 当前帧有帧 ? .bold : .regular))
                .foregroundStyle(颜色)
                .frame(width: 11, height: 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!有通道)
        .help(提示)
        .contextMenu { 菜单 }
    }

    private func 点一下() {
        guard 有通道 else { return }
        if 当前帧有帧 {
            域.删当前帧(键: 键)
        } else {
            域.打帧(键: 键)   // 值不传 = 读模型现值，正好把"偏离"这一刻记下来
        }
    }

    // MARK: 右键

    @ViewBuilder
    private var 菜单: some View {
        Button(当前帧有帧 ? "删除第 \(域.当前帧) 帧的关键帧" : "在第 \(域.当前帧) 帧打关键帧") {
            点一下()
        }
        Button("重打为当前值") {
            域.打帧(键: 键, 值: 值)
        }
        .disabled(!有通道)
        Divider()
        Button("删除这条通道的所有关键帧", role: .destructive) {
            域.删除轨道(键: 键)
        }
        .disabled(!有轨道)
        Divider()
        Toggle("自动 K 帧", isOn: Binding(
            get: { 域.自动K帧 },
            set: { 域.自动K帧 = $0 }
        ))
    }
}
