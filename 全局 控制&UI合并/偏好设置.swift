import AppKit
import SwiftUI

// MARK: - 外观模式

/// 界面外观：决定整套配色令牌走深色还是浅色
enum 界面外观: String, CaseIterable, Identifiable {
    case 深色 = "深色"
    case 浅色 = "浅色"
    case 跟随系统 = "跟随系统"

    var id: String { rawValue }
    var title: String { rawValue }

    /// 传给 preferredColorScheme；跟随系统时返回 nil
    var 强制配色: ColorScheme? {
        switch self {
        case .深色: .dark
        case .浅色: .light
        case .跟随系统: nil
        }
    }

    var symbol: String {
        switch self {
        case .深色: "moon.fill"
        case .浅色: "sun.max.fill"
        case .跟随系统: "circle.lefthalf.filled"
        }
    }
}

// MARK: - 主色

/// 主题主色：选中态、强调描边、开关、滑杆高亮都跟它走
enum 界面主色: String, CaseIterable, Identifiable {
    case 蓝 = "蓝"
    case 青 = "青"
    case 绿 = "绿"
    case 橙 = "橙"
    case 粉 = "粉"
    case 紫 = "紫"
    case 金 = "金"

    var id: String { rawValue }
    var title: String { rawValue }

    /// 深色模式下的主色（饱和度略高，暗背景下更亮）
    var 深色值: Color {
        switch self {
        case .蓝: Color(red: 0.32, green: 0.58, blue: 1.00)
        case .青: Color(red: 0.20, green: 0.78, blue: 0.86)
        case .绿: Color(red: 0.28, green: 0.80, blue: 0.52)
        case .橙: Color(red: 1.00, green: 0.58, blue: 0.26)
        case .粉: Color(red: 1.00, green: 0.46, blue: 0.66)
        case .紫: Color(red: 0.68, green: 0.48, blue: 1.00)
        case .金: Color(red: 0.98, green: 0.74, blue: 0.26)
        }
    }

    /// 浅色模式下的主色（压暗一档，白底上不刺眼）
    var 浅色值: Color {
        switch self {
        case .蓝: Color(red: 0.10, green: 0.42, blue: 0.92)
        case .青: Color(red: 0.04, green: 0.55, blue: 0.64)
        case .绿: Color(red: 0.10, green: 0.58, blue: 0.32)
        case .橙: Color(red: 0.90, green: 0.42, blue: 0.08)
        case .粉: Color(red: 0.86, green: 0.24, blue: 0.48)
        case .紫: Color(red: 0.48, green: 0.28, blue: 0.88)
        case .金: Color(red: 0.80, green: 0.56, blue: 0.06)
        }
    }
}

// MARK: - 配色令牌

/// 一整套配色令牌：所有界面的颜色都必须从这里取，禁止在 View 里写死
struct 界面配色 {
    var 深色: Bool
    /// 画布 / 面板 / 检查器 / 视口 四级背景
    var 画布: Color
    var 网格: Color
    var 面板: Color
    var 检查器: Color
    var 视口: Color
    /// 节点卡片
    var 节点底: Color
    var 节点头: Color
    var 控件底: Color
    /// 描边与分隔
    var 描边: Color
    var 分隔: Color
    /// 文字三级
    var 文字主: Color
    var 文字次: Color
    var 文字弱: Color
    /// 主色
    var 主色: Color

    static func 深色(_ accent: Color) -> 界面配色 {
        界面配色(
            深色: true,
            画布: Color(red: 0.086, green: 0.090, blue: 0.100),
            网格: Color.white.opacity(0.075),
            面板: Color(red: 0.125, green: 0.132, blue: 0.146),
            检查器: Color(red: 0.108, green: 0.114, blue: 0.126),
            视口: Color(red: 0.070, green: 0.074, blue: 0.082),
            节点底: Color(red: 0.176, green: 0.184, blue: 0.201),
            节点头: Color.white.opacity(0.055),
            控件底: Color.white.opacity(0.10),
            描边: Color.white.opacity(0.13),
            分隔: Color.white.opacity(0.075),
            文字主: Color.white.opacity(0.96),
            文字次: Color.white.opacity(0.70),
            文字弱: Color.white.opacity(0.46),
            主色: accent
        )
    }

    static func 浅色(_ accent: Color) -> 界面配色 {
        界面配色(
            深色: false,
            画布: Color(red: 0.949, green: 0.953, blue: 0.961),
            网格: Color.black.opacity(0.085),
            面板: Color(red: 0.984, green: 0.986, blue: 0.992),
            检查器: Color.white,
            视口: Color(red: 0.898, green: 0.906, blue: 0.918),
            节点底: Color.white,
            节点头: Color.black.opacity(0.045),
            控件底: Color.black.opacity(0.06),
            描边: Color.black.opacity(0.14),
            分隔: Color.black.opacity(0.08),
            文字主: Color(red: 0.086, green: 0.094, blue: 0.106),
            文字次: Color(red: 0.29, green: 0.31, blue: 0.34),
            文字弱: Color(red: 0.48, green: 0.51, blue: 0.55),
            主色: accent
        )
    }
}

// MARK: - 偏好设置存储

/// 全局偏好：UserDefaults 持久化，Theme 每次取值都问它要令牌。
/// 改配色类设置时 `变更版本` 自增，根视图用它重建整棵树（令牌是静态读取，不重建不会刷新）。
@Observable
final class 偏好设置Store {

    static let shared = 偏好设置Store()

    private let defaults = UserDefaults.standard

    // MARK: 设置项

    var 外观: 界面外观 {
        didSet { defaults.set(外观.rawValue, forKey: Keys.外观); 标记重建() }
    }

    var 主色: 界面主色 {
        didSet { defaults.set(主色.rawValue, forKey: Keys.主色); 标记重建() }
    }

    /// 节点画布是否画点阵网格
    var 显示画布网格: Bool {
        didSet { defaults.set(显示画布网格, forKey: Keys.显示画布网格); 标记重建() }
    }

    /// 节点数值展示的小数位（2…4）
    var 数值小数位: Int {
        didSet {
            let clamped = min(4, max(0, 数值小数位))
            if clamped != 数值小数位 { 数值小数位 = clamped; return }
            defaults.set(clamped, forKey: Keys.数值小数位)
            标记重建()
        }
    }

    /// 选中节点时是否描亮外框
    var 强调选中节点: Bool {
        didSet { defaults.set(强调选中节点, forKey: Keys.强调选中节点); 标记重建() }
    }

    /// 视口是否显示选中物体的高亮描边
    var 视口选中高亮: Bool {
        didSet { defaults.set(视口选中高亮, forKey: Keys.视口选中高亮); 标记重建() }
    }

    /// 自动保护间隔（分钟）：1…60 表示开启，0 表示关闭（只靠 ⌘S 手动保存）。
    ///
    /// 自动保存只写 App 支持目录下的 autosave/ 独立文件，不碰主工程文件。
    var 自动保存间隔分钟: Int {
        didSet {
            let clamped = min(60, max(0, 自动保存间隔分钟))
            if clamped != 自动保存间隔分钟 { 自动保存间隔分钟 = clamped; return }
            if clamped > 0 { 上次自动保存间隔分钟 = clamped }
            defaults.set(clamped, forKey: Keys.自动保存间隔)
            标记重建()
        }
    }

    /// 自动保存是否开启。
    var 自动保存开启: Bool { 自动保存间隔分钟 > 0 }

    /// 关掉自动保存后仍记住用户原先的分钟数，重新打开时回填。
    private(set) var 上次自动保存间隔分钟: Int = 5

    // MARK: 系统外观跟随

    private(set) var 系统深色: Bool = true

    /// 整树重建计数
    private(set) var 变更版本: Int = 1

    // MARK: 初始化

    private init() {
        let 外观值 = defaults.string(forKey: Keys.外观) ?? 界面外观.深色.rawValue
        外观 = 界面外观(rawValue: 外观值) ?? .深色

        let 主色值 = defaults.string(forKey: Keys.主色) ?? 界面主色.蓝.rawValue
        主色 = 界面主色(rawValue: 主色值) ?? .蓝

        显示画布网格 = defaults.object(forKey: Keys.显示画布网格) as? Bool ?? true
        数值小数位 = defaults.object(forKey: Keys.数值小数位) as? Int ?? 3
        强调选中节点 = defaults.object(forKey: Keys.强调选中节点) as? Bool ?? true
        视口选中高亮 = defaults.object(forKey: Keys.视口选中高亮) as? Bool ?? true
        let 间隔值 = defaults.object(forKey: Keys.自动保存间隔) as? Int ?? 5
        自动保存间隔分钟 = min(60, max(0, 间隔值))

        // 没存过就以系统当前外观为初值
        if 外观 == .跟随系统 {
            系统深色 = NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        }
    }

    // MARK: 派生

    var 当前是否深色: Bool {
        switch 外观 {
        case .深色: true
        case .浅色: false
        case .跟随系统: 系统深色
        }
    }

    var 当前配色: 界面配色 {
        当前是否深色
            ? .深色(主色.深色值)
            : .浅色(主色.浅色值)
    }

    var 当前主色: Color { 当前是否深色 ? 主色.深色值 : 主色.浅色值 }

    func 记录系统外观(_ isDark: Bool) {
        guard 系统深色 != isDark else { return }
        系统深色 = isDark
        if 外观 == .跟随系统 { 标记重建() }
    }

    /// 设置改了需要重绘的地方 → 版本自增（视图根节点用 .id 监听）
    private func 标记重建() {
        变更版本 &+= 1
    }

    // MARK: 恢复默认

    func 恢复默认() {
        外观 = .深色
        主色 = .蓝
        显示画布网格 = true
        数值小数位 = 3
        强调选中节点 = true
        视口选中高亮 = true
        自动保存间隔分钟 = 5
        标记重建()
    }

    private enum Keys {
        static let 外观 = "3d渲染.外观"
        static let 主色 = "3d渲染.主色"
        static let 显示画布网格 = "3d渲染.显示画布网格"
        static let 数值小数位 = "3d渲染.数值小数位"
        static let 强调选中节点 = "3d渲染.强调选中节点"
        static let 视口选中高亮 = "3d渲染.视口选中高亮"
        static let 自动保存间隔 = "3d渲染.自动保存间隔分钟"
    }
}

// MARK: - 偏好设置面板

/// 走 Settings 场景（⌘,），面板跟随当前主题配色，改一项立刻全局生效
struct 偏好设置面板: View {
    @State private var 偏好 = 偏好设置Store.shared
    /// 当前页签：常规 / 快捷键
    @State private var 当前页: 设置页 = .常规

    var body: some View {
        @Bindable var 偏好 = 偏好

        VStack(alignment: .leading, spacing: 0) {
            // 顶部分页：常规 = 原来的全部设置项，快捷键 = 只读键位表
            Picker("", selection: $当前页) {
                ForEach(设置页.allCases) { 页 in
                    Label(页.title, systemImage: 页.symbol).tag(页)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 12)

            Divider()

            switch 当前页 {
            case .常规:
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        外观区
                        主色区
                        画布区
                        渲染区
                        选中区
                        保存区
                        用户目录区
                        预览区
                    }
                    .padding(18)
                }
            case .快捷键:
                快捷键页
            }

            Divider()

            HStack(spacing: 10) {
                Text(当前页 == .常规 ? "设置即时生效，随窗口一起持久化" : "快捷键只读展示，暂不支持自定义改键")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if 当前页 == .常规 {
                    Button("恢复默认") { 偏好.恢复默认() }
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .frame(width: 480, height: 560)
        .background(Theme.panelBackground)
    }

    // MARK: 外观

    private var 外观区: some View {
        @Bindable var 偏好 = 偏好
        return 设置分组(title: "外观", note: "决定整套界面走深色还是浅色") {
            Picker("", selection: $偏好.外观) {
                ForEach(界面外观.allCases) { item in
                    Label(item.title, systemImage: item.symbol).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    // MARK: 主色

    private var 主色区: some View {
        @Bindable var 偏好 = 偏好
        return 设置分组(title: "主体颜色", note: "选中态、高亮描边、滑杆与开关的主色") {
            HStack(spacing: 8) {
                ForEach(界面主色.allCases) { item in
                    let isOn = 偏好.主色 == item
                    Button {
                        偏好.主色 = item
                    } label: {
                        VStack(spacing: 5) {
                            Circle()
                                .fill(偏好.当前是否深色 ? item.深色值 : item.浅色值)
                                .frame(width: 24, height: 24)
                                .overlay(
                                    Circle().stroke(
                                        isOn ? Theme.文字主.opacity(0.9) : Color.clear,
                                        lineWidth: 2
                                    )
                                )
                            Text(item.title)
                                .font(.system(size: 9.5))
                                .foregroundStyle(isOn ? Theme.文字主 : Theme.文字弱)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(item.title)
                }
            }
        }
    }

    // MARK: 画布

    private var 画布区: some View {
        @Bindable var 偏好 = 偏好
        return 设置分组(title: "节点画布", note: "影响材质节点编辑器的显示细节") {
            VStack(spacing: 10) {
                Toggle(isOn: $偏好.显示画布网格) {
                    HStack(spacing: 6) {
                        Text("显示点阵网格").font(.system(size: 11.5))
                        Spacer(minLength: 4)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                HStack(spacing: 8) {
                    Text("节点数值小数位").font(.system(size: 11.5))
                    Spacer(minLength: 4)
                    Picker("", selection: $偏好.数值小数位) {
                        Text("2 位").tag(2)
                        Text("3 位").tag(3)
                        Text("4 位").tag(4)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 176)
                }
            }
        }
    }

    // MARK: 视口后端

    private var 渲染区: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "arkit")
                    .font(.system(size: 11))
                Text("RealityKit")
                    .font(.system(size: 11.5, weight: .semibold))
                Spacer(minLength: 0)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 10))
            }
            Text("视口统一走 RealityKit PhysicallyBasedMaterial，阴影用贴地接触阴影补齐。")
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            ForEach(ViewportScene.后端限制, id: \.self) { item in
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 9.5))
                    Text(item + " 暂不支持")
                        .font(.system(size: 9.5))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.orange.opacity(0.9))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Theme.面板, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8).stroke(Theme.描边, lineWidth: 1)
        )
    }

    // MARK: 选中

    private var 选中区: some View {
        @Bindable var 偏好 = 偏好
        return 设置分组(title: "选中反馈", note: "一眼看出在改哪个节点、哪个物体") {
            VStack(spacing: 10) {
                Toggle(isOn: $偏好.强调选中节点) {
                    HStack(spacing: 6) {
                        Text("节点选中外框加粗").font(.system(size: 11.5))
                        Spacer(minLength: 4)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                Toggle(isOn: $偏好.视口选中高亮) {
                    HStack(spacing: 6) {
                        Text("视口选中物体描边").font(.system(size: 11.5))
                        Spacer(minLength: 4)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)
            }
        }
    }

    // MARK: 自动保存

    private var 保存区: some View {
        @Bindable var 偏好 = 偏好
        let 开关 = Binding<Bool>(
            get: { 偏好.自动保存开启 },
            set: { 偏好.自动保存间隔分钟 = $0 ? 偏好.上次自动保存间隔分钟 : 0 }
        )
        let 分钟 = Binding<Int>(
            get: { 偏好.自动保存间隔分钟 },
            set: { 偏好.自动保存间隔分钟 = $0 }
        )
        return 设置分组(
            title: "自动保存",
            note: "只写独立的保护文件，主工程文件仍由 ⌘S 保存"
        ) {
            VStack(spacing: 10) {
                Toggle(isOn: 开关) {
                    HStack(spacing: 6) {
                        Text("启用自动保存").font(.system(size: 11.5))
                        Spacer(minLength: 4)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                HStack(spacing: 8) {
                    Text("保存间隔").font(.system(size: 11.5))
                    Spacer(minLength: 4)
                    Stepper(value: 分钟, in: 1...60, step: 1) {
                        Text(偏好.自动保存开启 ? "\(偏好.自动保存间隔分钟) 分钟" : "已关闭")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(偏好.自动保存开启 ? Theme.文字主 : Theme.文字弱)
                            .frame(minWidth: 46, alignment: .trailing)
                    }
                    .controlSize(.small)
                    .disabled(!偏好.自动保存开启)
                }

                HStack(spacing: 6) {
                    Image(systemName: "internaldrive")
                        .font(.system(size: 9.5))
                    Text(
                        偏好.自动保存开启
                            ? "每 \(偏好.自动保存间隔分钟) 分钟在 App 支持目录的 autosave/ 里写一份保护文件，只保留最近 3 份"
                            : "已关闭：只有 ⌘S / 另存为会写主工程文件，退出时若有未保存改动会先提示"
                    )
                    .font(.system(size: 9.5))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: 用户目录

    /// 只读展示：路径固定为 ~/Documents/cg app，`~` 在运行时按当前用户展开
    private var 用户目录区: some View {
        设置分组(title: "用户目录", note: "项目的用户文档根，位置固定") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Image(systemName: "folder")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.文字次)
                    Text(用户目录.显示路径)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.文字主)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.控件底, in: RoundedRectangle(cornerRadius: 7))
                .overlay(
                    RoundedRectangle(cornerRadius: 7).stroke(Theme.描边, lineWidth: 0.8)
                )

                Text("~ 按当前 macOS 用户展开，不同用户各一份；首次启动自动创建，不可修改")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)

                HStack(spacing: 5) {
                    ForEach(用户目录.子目录名, id: \.self) { 名 in
                        Text(名)
                            .font(.system(size: 9.5))
                            .foregroundStyle(Theme.文字次)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Theme.节点底, in: Capsule())
                            .overlay(Capsule().stroke(Theme.描边, lineWidth: 0.8))
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    // MARK: 预览

    private var 预览区: some View {
        let 配色 = Theme.配色
        return 设置分组(title: "预览", note: "当前配色令牌的实际观感") {
            HStack(spacing: 6) {
                色块("画布", 配色.画布)
                色块("面板", 配色.面板)
                色块("节点", 配色.节点底)
                色块("视口", 配色.视口)
                色块("描边", 配色.描边)
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Text("文字主")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.文字主)
                Text("文字次")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.文字次)
                Text("文字弱")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.文字弱)
                Spacer(minLength: 0)
                Text(配色.深色 ? "深色" : "浅色")
                    .font(.system(size: 9.5, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.主色.opacity(0.18), in: Capsule())
                    .foregroundStyle(Theme.主色)
            }
            .padding(10)
            .background(Theme.节点底, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8).stroke(Theme.描边, lineWidth: 1)
            )
        }
    }

    private func 色块(_ title: String, _ color: Color) -> some View {
        VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 5)
                .fill(color)
                .frame(width: 52, height: 26)
                .overlay(
                    RoundedRectangle(cornerRadius: 5).stroke(Theme.描边, lineWidth: 1)
                )
            Text(title)
                .font(.system(size: 9))
                .foregroundStyle(Theme.文字弱)
        }
    }

    // MARK: 快捷键页

    /// 只读键位表：数据全部来自代码里真实注册的处理，这里只做展示
    private var 快捷键页: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(键位分组表) { 组 in
                    设置分组(title: 组.标题, note: 组.说明) {
                        VStack(spacing: 0) {
                            ForEach(Array(组.条目.enumerated()), id: \.element.id) { index, 项 in
                                if index > 0 {
                                    Rectangle()
                                        .fill(Theme.分隔)
                                        .frame(height: 1)
                                        .padding(.vertical, 5)
                                }
                                键位行(条目: 项)
                            }
                        }
                    }
                }
            }
            .padding(18)
        }
    }

    private func 键位行(条目: 快捷键条目) -> some View {
        HStack(spacing: 8) {
            Text(条目.功能)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.文字主)
            if let 范围 = 条目.范围 {
                Text(范围)
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.主色)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Theme.主色.opacity(0.14), in: Capsule())
            }
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                ForEach(条目.按键, id: \.self) { 键 in
                    按键胶囊(键: 键)
                }
            }
        }
        .padding(.vertical, 1)
    }

    // MARK: 分组容器

    private func 设置分组<Content: View>(
        title: String,
        note: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.文字主)
                Text(note)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.文字弱)
            }
            content()
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.检查器, in: RoundedRectangle(cornerRadius: 9))
                .overlay(
                    RoundedRectangle(cornerRadius: 9).stroke(Theme.描边, lineWidth: 1)
                )
        }
    }
}

// MARK: - 设置面板分页与快捷键数据

/// 设置面板的两页：常规保留原来的全部设置项，快捷键是只读键位表
private enum 设置页: String, CaseIterable, Identifiable {
    case 常规
    case 快捷键

    var id: String { rawValue }
    var title: String { rawValue }

    var symbol: String {
        switch self {
        case .常规: "slider.horizontal.3"
        case .快捷键: "keyboard"
        }
    }
}

/// 一条键位：功能名 + 按键（拆成单个符号，方便逐颗画胶囊）+ 生效范围（可空）
private struct 快捷键条目: Identifiable {
    let id = UUID()
    let 功能: String
    let 按键: [String]
    var 范围: String? = nil
}

private struct 键位组: Identifiable {
    let id = UUID()
    let 标题: String
    let 说明: String
    let 条目: [快捷键条目]
}

/// 键位胶囊：等宽字体 + 细描边，右对齐后便于竖着扫读
private struct 按键胶囊: View {
    let 键: String

    var body: some View {
        Text(键)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(Theme.文字次)
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(Theme.控件底, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(Theme.描边, lineWidth: 0.8)
            )
    }
}

/// 全部键位都对着代码核过（出处见各分组说明），新增键位时请同步这里。
/// 这张表只做展示，不参与任何按键分发。
private let 键位分组表: [键位组] = [
    键位组(
        标题: "全局搜索",
        说明: "窗口内任何位置都能唤起，搜材质库条目与场景物体名",
        条目: [
            // 面板内的 ↑↓ / ⏎ / esc 已经直接标在搜索栏上，这里不再重复
            快捷键条目(功能: "唤起全局搜索 / 再按收起", 按键: ["⌘", "F"], 范围: "全局")
        ]
    ),
    键位组(
        标题: "变换工具",
        说明: "焦点在视口时切换坐标轴手柄模式",
        条目: [
            快捷键条目(功能: "移动模式", 按键: ["W"], 范围: "视口"),
            快捷键条目(功能: "旋转模式", 按键: ["E"], 范围: "视口"),
            快捷键条目(功能: "缩放模式", 按键: ["R"], 范围: "视口"),
            快捷键条目(功能: "全局 / 局部坐标切换", 按键: ["G"], 范围: "视口")
        ]
    ),
    键位组(
        标题: "视口导航与显示",
        说明: "焦点在视口时生效；正在文本框里打字时让给原生输入",
        条目: [
            快捷键条目(功能: "聚焦选中", 按键: ["F"], 范围: "轻按"),
            快捷键条目(功能: "独立显示选中", 按键: ["F"], 范围: "按住"),
            快捷键条目(功能: "取消独立显示", 按键: ["⌥", "F"]),
            快捷键条目(功能: "隐藏选中", 按键: ["H"]),
            快捷键条目(功能: "显示全部（取消隐藏）", 按键: ["⌥", "H"]),
            快捷键条目(功能: "全选", 按键: ["A"]),
            快捷键条目(功能: "取消选择", 按键: ["⌥", "A"]),
            快捷键条目(功能: "添加物体面板（鼠标处弹出）", 按键: ["⇧", "A"]),
            快捷键条目(功能: "循环着色模式", 按键: ["Z"]),
            快捷键条目(功能: "加选", 按键: ["⇧", "点击"], 范围: "视口")
        ]
    ),
    键位组(
        标题: "鼠标侧键",
        说明: "带侧键的鼠标：鼠标在视口里按一下就行，不用配键盘",
        条目: [
            快捷键条目(功能: "聚焦选中", 按键: ["前侧键"], 范围: "等同 F"),
            快捷键条目(功能: "显示并聚焦全部", 按键: ["后侧键"])
        ]
    ),
    键位组(
        标题: "视图对齐（小键盘方位）",
        说明: "数字键照小键盘摆位：2 底、4 左、6 右、8 顶",
        条目: [
            快捷键条目(功能: "前视", 按键: ["1"]),
            快捷键条目(功能: "底视", 按键: ["2"]),
            快捷键条目(功能: "右视", 按键: ["3", "6"]),
            快捷键条目(功能: "左视", 按键: ["4"]),
            快捷键条目(功能: "顶视", 按键: ["7", "8"]),
            快捷键条目(功能: "后视", 按键: ["9"])
        ]
    ),
    键位组(
        标题: "选择与编辑",
        说明: "删除优先清节点编辑器里的选中，没有再删视口物体",
        条目: [
            快捷键条目(功能: "删除选中（节点 / 物体）", 按键: ["⌫"], 范围: "全局"),
            快捷键条目(功能: "删除选中物体", 按键: ["X"], 范围: "视口"),
            快捷键条目(功能: "复制选中物体", 按键: ["⌘", "D"], 范围: "全局"),
            快捷键条目(功能: "绘画开关", 按键: ["B"], 范围: "视口"),
            快捷键条目(功能: "撤销上一笔（绘画）", 按键: ["⌘", "Z"])
        ]
    ),
    键位组(
        标题: "文件与工程",
        说明: "菜单命令，窗口里任何位置都能用",
        条目: [
            快捷键条目(功能: "保存", 按键: ["⌘", "S"]),
            快捷键条目(功能: "另存为", 按键: ["⇧", "⌘", "S"]),
            快捷键条目(功能: "新建项目", 按键: ["⌘", "N"]),
            快捷键条目(功能: "打开工程", 按键: ["⌘", "O"]),
            快捷键条目(功能: "新建材质", 按键: ["⌥", "⌘", "N"]),
            快捷键条目(功能: "添加节点：RGB", 按键: ["⌘", "1"]),
            快捷键条目(功能: "打开设置面板", 按键: ["⌘", ","])
        ]
    ),
    键位组(
        标题: "对话框",
        说明: "弹窗右下角的主操作按钮",
        条目: [
            快捷键条目(功能: "确认 / 完成（节点参数、出图、导入）", 按键: ["⏎"], 范围: "对话框")
        ]
    )
]
