import AppKit
import SwiftUI
import SceneKit
import Combine
import simd

// MARK: - 角色窗口
//
// 口径：骨架不是"文件夹"，而是一个角色。
// 双击大纲里的角色 → 弹这个独立窗口：
//   左边：这个角色自己的小内部树（骨骼 / 身体 / 衣服 / 道具）
//   右边：实时的角色本体（穿好衣服、挂好道具的样子）
// 窗体和 出图窗口 一个套路：NSWindow + NSHostingView 自管，不动主界面 scene 结构。

@MainActor
final class 角色窗口控制器: NSObject, NSWindowDelegate {
    static let shared = 角色窗口控制器()

    private var 窗口们: [UUID: NSWindow] = [:]
    private override init() { super.init() }

    /// 双击角色行调用。同一个角色只开一个窗口，重复双击就前置。
    func 打开(角色ID: UUID, store: 布局Store) {
        let 视图 = 角色窗口视图(store: store, 角色ID: 角色ID)

        if let 现有 = 窗口们[角色ID] {
            (现有.contentView as? NSHostingView<角色窗口视图>)?.rootView = 视图
            if 现有.isMiniaturized { 现有.deminiaturize(nil) }
            现有.makeKeyAndOrderFront(nil)
            return
        }

        let 承载 = NSHostingView(rootView: 视图)
        // 独立窗口不在 ContentView 的视图树里，拿不到那边的 preferredColorScheme，
        // 默认就跟着系统外观走：系统是浅色时 .primary/.secondary 全是黑字，
        // 而 Theme 面板底是深色 → 黑字压黑底看不见。这里跟主界面用同一套外观。
        if let 外观 = 偏好设置Store.shared.外观.强制配色 {
            let 名义: NSAppearance.Name = 外观 == .dark ? .darkAqua : .aqua
            承载.appearance = NSAppearance(named: 名义)
        }
        let 窗口 = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 640),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        let 名 = store.objects.first { $0.id == 角色ID }?.name ?? "角色"
        窗口.title = "角色 · \(名)"
        窗口.minSize = NSSize(width: 720, height: 460)
        窗口.contentView = 承载
        窗口.isReleasedWhenClosed = false
        窗口.tabbingMode = .disallowed
        窗口.delegate = self
        if let 屏幕 = NSScreen.main {
            let 可见 = 屏幕.visibleFrame
            let 尺寸 = 窗口.frame.size
            窗口.setFrameOrigin(NSPoint(
                x: 可见.midX - 尺寸.width / 2,
                y: 可见.midY - 尺寸.height / 2 + 30
            ))
        }
        窗口们[角色ID] = 窗口
        窗口.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let 关掉 = notification.object as? NSWindow else { return }
        窗口们 = 窗口们.filter { $0.value !== 关掉 }
    }
}

// MARK: - 窗口内容

struct 角色窗口视图: View {
    let store: 布局Store
    let 角色ID: UUID

    /// 选中的骨（存路径，全局唯一）。左边树点一行、右边预览点一根骨都能选中，
    /// 选中后预览里这根骨变亮绿、并把受它影响的顶点打出来。
    @State private var 选中骨: String? = nil
    /// 选中骨的受影响顶点数（选中变化时算一次，缓着给左下角那行用）
    @State private var 选中顶点数: Int? = nil
    @State private var 选中数骨: String = ""

    /// 骨骼树里被收起来的骨路径：收起的骨，它的子孙一律不显示。
    /// 默认全展开（跟原来一样），骨多的角色自己收。
    @State private var 收起骨: Set<String> = []
    /// 「+ 把外面大纲里的物体拉进这一身」的弹窗
    /// 材质轮询的滴答：主界面改了材质，这个窗口里的预览要跟着变
    @State private var 材质滴答 = 0

    /// 角色之所以带一份骨架名/骨骼，是为了以后接骨骼层级；
    /// 现在没有骨骼数据就先只画部件分组，不留空壳标题。
    private var 角色: SceneObject? {
        store.objects.first { $0.id == 角色ID && $0.是角色 }
    }

    private var 部件们: [SceneObject] {
        store.角色部件物体(角色ID)
    }

    /// 预览左下角那行状态：几件在身 + 几根骨
    private var 副标题: String {
        let 件 = "\(部件们.filter(\.isVisible).count) 件在身"
        let 骨数 = 角色?.角色?.骨数据.count ?? 0
        let 骨 = 骨数 > 0 ? " · \(骨数) 根骨（rest）" : ""
        return 件 + 骨 + " · 拖拽旋转 / 滚轮缩放"
    }

    /// 选中那根骨的说明：名字 + 被它拽着的顶点数
    private func 选中说明(_ 路径: String) -> String {
        let 名 = 路径.split(separator: "/").last.map(String.init) ?? 路径
        guard 选中数骨 == 路径, let 数 = 选中顶点数 else { return "● \(名)" }
        return 数 > 0 ? "● \(名) · 影响 \(数) 顶点" : "● \(名) · 这身网格里没有它的权重"
    }

    /// 选中骨的权重统计很重（要扫全部部件顶点），只在选中变化时算一次并缓存；
    /// 不能塞进 body，否则界面每刷新一次就重扫一遍。
    private func 计算选中数(_ 路径: String?) {
        guard let 路径 else { 选中顶点数 = nil; 选中数骨 = ""; return }
        let 名 = 路径.split(separator: "/").last.map(String.init) ?? 路径
        选中顶点数 = 骨骼影响.算(骨名: 名, 部件们: 部件们).总数
        选中数骨 = 路径
    }

    private struct 部件组: Identifiable {
        var 分类: 角色部件分类
        var 列表: [SceneObject]
        var id: 角色部件分类 { 分类 }
    }

    /// 按分类分组，空的分类不占行
    private var 分组: [部件组] {
        let 全部 = 部件们
        return 角色部件分类.allCases.compactMap { 类 in
            let 列表 = 全部.filter { store.部件分类(物体ID: $0.id) == 类 }
            return 列表.isEmpty ? nil : 部件组(分类: 类, 列表: 列表)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            内部树
                .frame(width: 268)
            Rectangle().fill(Theme.divider).frame(width: 1)
            预览
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 720, minHeight: 460)
        .background(Theme.panelBackground)
        // 语义文字色（.primary/.secondary）跟着这个走：必须和 Theme 的面板底色同源，
        // 否则深色面板上会渲染出黑字。
        .preferredColorScheme(偏好设置Store.shared.外观.强制配色)
        // 材质是主界面那边改的，这个窗口拿不到通知：
        // 便宜地瞄一眼材质域版本（就是一次字典求和），变了才重建预览，没变什么都不做。
        .onReceive(Timer.publish(every: 1.2, on: .main, in: .common).autoconnect()) { _ in
            材质滴答 &+= 1
        }
    }

    // MARK: 左：内部树

    private var 内部树: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: "figure.arms.open")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(角色?.name ?? "角色")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 2)
                Text("\(部件们.count) 件")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)

            Rectangle().fill(Theme.divider).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if let 骨骼 = 角色?.角色?.骨骼, !骨骼.isEmpty {
                        骨骼段(骨骼)
                    }
                    if 分组.isEmpty {
                        Text("这一身还没有部件。\n把 Blender 里的身体/衣服/道具挂到骨架下重新导入。")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                    } else {
                        ForEach(分组) { 组 in
                            分组标题(组.分类, 数量: 组.列表.count)
                            ForEach(组.列表) { 部件 in
                                部件行(部件, 层: 1)
                            }
                        }
                    }
                }
                .padding(.vertical, 6)
            }
            .scrollIndicators(.automatic)
        }
        .background(Theme.inspectorBackground)
    }

    private func 骨骼段(_ 骨骼: [String]) -> some View {
        // 谁身上有子骨：把每根骨的父路径收集起来（路径形如 "躯干/胸/手.L"）。
        // 收起箭头只给这些骨画，叶子骨留个空位保持行首对齐。
        var 有子: Set<String> = []
        for 路径 in 骨骼 {
            let 段们 = 路径.split(separator: "/")
            guard 段们.count > 1 else { continue }
            有子.insert(段们.dropLast().map(String.init).joined(separator: "/"))
        }
        // 收起的骨，它的子孙一律不画（父收着，孩子自然不露头）
        let 可见骨 = 骨骼.filter { 路径 in
            let 段们 = 路径.split(separator: "/")
            guard 段们.count > 1 else { return true }
            var 前缀: [String] = []
            for 段 in 段们.dropLast() {
                前缀.append(String(段))
                if 收起骨.contains(前缀.joined(separator: "/")) { return false }
            }
            return true
        }
        let 已全收 = !有子.isEmpty && 收起骨.isSuperset(of: 有子)

        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Image(systemName: "figure.stand")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Text("骨骼")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 2)
                Text("\(可见骨.count)/\(骨骼.count)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Button {
                    if 已全收 { 收起骨.removeAll() } else { 收起骨 = 有子 }
                } label: {
                    Text(已全收 ? "全展开" : "全收起")
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help(已全收 ? "展开所有骨骼" : "收起所有骨骼，只留根骨")
            }
            .padding(.leading, 10)
            .padding(.trailing, 10)
            .padding(.top, 7)
            .padding(.bottom, 2)

            ForEach(可见骨, id: \.self) { 路径 in
                // 路径形如 "躯干/胸/手.L"：用 / 的层数决定缩进，末段才是骨名
                let 层 = 路径.reduce(0) { $0 + ($1 == "/" ? 1 : 0) }
                let 被选 = 选中骨 == 路径
                let 子 = 有子.contains(路径)
                let 收 = 收起骨.contains(路径)
                HStack(spacing: 3) {
                    Button {
                        if 收 { 收起骨.remove(路径) } else { 收起骨.insert(路径) }
                    } label: {
                        Image(systemName: 收 ? "chevron.right" : "chevron.down")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(子 ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.clear))
                            .frame(width: 11, height: 15)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .disabled(!子)
                    .help(子 ? (收 ? "展开它下面的骨" : "收起它下面的骨") : "")

                    Image(systemName: 层 == 0 ? "figure.stand" : "circle")
                        .font(.system(size: 层 == 0 ? 10 : 6))
                        .foregroundStyle(被选 ? AnyShapeStyle(Color.green) : (层 == 0 ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary)))
                    Text(路径.split(separator: "/").last.map(String.init) ?? 路径)
                        .font(.system(size: 11, weight: 层 == 0 || 被选 ? .medium : .regular))
                        .foregroundStyle(被选 ? AnyShapeStyle(Color.green) : (层 == 0 ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    // 收着的骨上标一下子骨数，省得忘了里面藏了多少
                    if 收 {
                        Text("\(骨骼.filter { $0.hasPrefix(路径 + "/") }.count)")
                            .font(.system(size: 8.5, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.leading, 10 + CGFloat(层) * 11)
                .padding(.trailing, 10)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
                .onTapGesture { 选中骨 = 被选 ? nil : 路径 }
                .background(Color.green.opacity(被选 ? 0.14 : 0))
                .help(路径)
            }
        }
    }

    private func 分组标题(_ 类: 角色部件分类, 数量: Int, 标题: String? = nil) -> some View {
        HStack(spacing: 5) {
            Image(systemName: 类.符号)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Text(标题 ?? 类.名)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 2)
            Text("\(数量)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.leading, 10)
        .padding(.trailing, 10)
        .padding(.top, 7)
        .padding(.bottom, 2)
    }

    private func 部件行(_ 部件: SceneObject, 层: Int) -> some View {
        HStack(spacing: 5) {
            Button {
                store.设物体可见(部件.id, !部件.isVisible)
            } label: {
                Image(systemName: 部件.isVisible ? "eye" : "eye.slash")
                    .font(.system(size: 9))
                    .foregroundStyle(部件.isVisible ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(部件.isVisible ? "隐藏这件" : "显示这件")

            Image(systemName: 部件.symbol)
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
            Text(部件.name)
                .font(.system(size: 11))
                .lineLimit(1)
                .foregroundStyle(部件.isVisible ? .primary : .tertiary)
            Spacer(minLength: 2)
        }
        .padding(.leading, CGFloat(层) * 11 + 10)
        .padding(.trailing, 10)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture { store.selectedObjectID = 部件.id }
        .background(
            Color.accentColor.opacity(store.selectedObjectID == 部件.id ? 0.16 : 0)
        )
        .contextMenu {
            Button(部件.isVisible ? "隐藏" : "显示") {
                store.设物体可见(部件.id, !部件.isVisible)
            }
            Menu("换个分类") {
                ForEach(角色部件分类.allCases, id: \.self) { 类 in
                    Button(类.名) { store.设部件分类(物体ID: 部件.id, 分类: 类) }
                }
            }
            Divider()
            Button("从角色里移出（还原成普通物体）", role: .destructive) {
                store.移出角色部件(部件.id)
            }
        }
    }

    // MARK: 右：预览

    /// 部件 → 它引用的材质资产 id（没挂材质的就是白模）
    private var 部件材质: [UUID: UUID] {
        var 表: [UUID: UUID] = [:]
        for 部件 in 部件们 {
            if let id = 部件.materialID { 表[部件.id] = id }
        }
        return 表
    }

    /// 材质签名：资产 id + 材质域版本号。版本一变就重建预览，主界面改完材质这里立刻能看到。
    /// 这里只读材质域版本（一次字典求和），不编译节点图 —— 编译放在建场景时按需做并缓存。
    private var 部件材质签名: String {
        let _ = 材质滴答
        return 部件们.map { 部件 in
            guard let id = 部件.materialID else { return "\(部件.id.uuidString)=白模" }
            return "\(部件.id.uuidString)=\(id.uuidString):\(材质接线.共享.版本(资产: id) ?? 0)"
        }.joined(separator: ";")
    }

    private var 预览: some View {
        ZStack(alignment: .topLeading) {
            if 角色 == nil {
                Text("角色已被删除")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // 真的角色本体：眼睛关掉的部件不参加预览，跟视口一致
                角色预览容器(部件们: 部件们,
                        骨骼们: 角色?.角色?.骨数据 ?? [],
                        选中骨: $选中骨,
                        材质: 部件材质,
                        材质签名: 部件材质签名)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(角色?.name ?? "")
                    .font(.system(size: 11, weight: .medium))
                Text(副标题)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                if let 骨 = 选中骨 {
                    Text(选中说明(骨))
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.green)
                }
            }
            .padding(10)
            .allowsHitTesting(false)
        }
        .onChange(of: 选中骨) { 新 in
            计算选中数(新)
        }
    }
}

// MARK: - SceneKit 预览

/// 预览外面套一层壳：只负责「显示骨架」这个开关。
/// SceneKit 那边拿到的东西全是纯数据（部件 + 骨骼 + 要不要画骨架），自己不管状态。
struct 角色预览容器: View {
    let 部件们: [SceneObject]
    let 骨骼们: [角色骨骼]
    @Binding var 选中骨: String?
    /// 部件 → 材质资产 id（没挂材质的走白模）
    let 材质: [UUID: UUID]
    /// 材质签名：变了才重建场景，没变一点事都不做
    let 材质签名: String

    @State private var 显示骨架 = true
    @State private var 标骨名 = false
    /// 预览相机的朝向，SceneKit 那边每帧量出来回写。
    /// 相机本身仍归 SceneKit 的 allowsCameraControl 管，这里只读不写。
    @State private var 轴右向 = SIMD3<Float>(1, 0, 0)
    @State private var 轴上向 = SIMD3<Float>(0, 1, 0)
    @State private var 轴前向 = SIMD3<Float>(0, 0, -1)

    var body: some View {
        ZStack(alignment: .topTrailing) {
            角色预览视图(部件们: 部件们,
                    骨骼们: 骨骼们,
                    显示骨架: 显示骨架,
                    标骨名: 标骨名 && 显示骨架,
                    选中骨: $选中骨,
                    材质: 材质,
                    材质签名: 材质签名,
                    轴右向: $轴右向,
                    轴上向: $轴上向,
                    轴前向: $轴前向)

            // 按钮在左、轴在右，一行摆开：轴别被按钮挤到下面去
            HStack(alignment: .top, spacing: 6) {
                if !骨骼们.isEmpty {
                    HStack(spacing: 6) {
                        Button {
                            标骨名.toggle()
                        } label: {
                            Text(标骨名 ? "骨名开" : "标骨名")
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(标骨名 ? Color.cyan : Color.secondary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(.ultraThinMaterial, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("在每根骨上标出骨名（骨多的时候会有点挤）")

                        Button {
                            显示骨架.toggle()
                            if !显示骨架 { 选中骨 = nil }
                        } label: {
                            Text(显示骨架 ? "隐藏骨架" : "显示骨架（\(骨骼们.count)）")
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(显示骨架 ? Color.orange : Color.secondary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(.ultraThinMaterial, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .help(显示骨架 ? "隐藏骨架，只留角色本体" : "显示骨架")
                    }
                    // 胶囊比小轴矮，给一点上沿让两者视觉齐顶
                    .padding(.top, 2)
                }

                // 跟视口右上角同一只表，只是小一号、点不动：这里只用来认方向
                只读轴向指示(右向: 轴右向, 上向: 轴上向, 前向: 轴前向)
            }
            .padding(8)
        }
    }
}

/// 把角色的部件（都是 导入网格库 里的网格）摆到 SceneKit 里实时显示。
/// 位置直接用网格自带的 变换（解析时写进去的就是文件里的世界矩阵），
/// 所以部件之间的相对关系跟 Blender 里一致；
/// 角色物体本身的 position 只是"整包摆到场景哪"的偏移，预览不需要带上。
/// 骨骼同理：头尾点也是世界坐标，因此骨架能直接跟部件叠在一起看。
struct 角色预览视图: NSViewRepresentable {
    let 部件们: [SceneObject]
    let 骨骼们: [角色骨骼]
    let 显示骨架: Bool
    let 标骨名: Bool
    @Binding var 选中骨: String?
    /// 部件 → 材质资产 id
    let 材质: [UUID: UUID]
    /// 材质签名：参与重建判定，主界面改完材质回来这儿能刷新
    let 材质签名: String
    /// 预览相机朝向回写（给右上角那只小轴向用）
    @Binding var 轴右向: SIMD3<Float>
    @Binding var 轴上向: SIMD3<Float>
    @Binding var 轴前向: SIMD3<Float>

    func makeCoordinator() -> 协调器 { 协调器() }

    func makeNSView(context: Context) -> SCNView {
        let 视图 = SCNView()
        视图.allowsCameraControl = true
        视图.autoenablesDefaultLighting = false
        视图.antialiasingMode = .multisampling4X
        视图.backgroundColor = NSColor(calibratedWhite: 0.11, alpha: 1)
        视图.rendersContinuously = true

        let 协 = context.coordinator
        协.写选中 = { 选中骨 = $0 }
        协.写朝向 = { 右, 上, 前 in
            轴右向 = 右
            轴上向 = 上
            轴前向 = 前
        }
        协.部件们 = 部件们
        视图.scene = 建场景(配到: 协)
        协.基础签名 = 当前签名()
        协.选中 = 显示骨架 ? 选中骨 : nil
        协.应用选中()
        // 相机朝向靠主线程定时器量（10Hz 足够画那只小轴向，没必要每帧吵醒主线程）
        协.挂相机跟随(视图)

        // 点一根骨就选中它（点身体上靠骨的位置也能选中最近那根）
        let 手势 = NSClickGestureRecognizer(target: 协, action: #selector(协调器.点一下(_:)))
        视图.addGestureRecognizer(手势)
        return 视图
    }

    func updateNSView(_ 视图: SCNView, context: Context) {
        let 协 = context.coordinator
        协.写选中 = { 选中骨 = $0 }
        协.部件们 = 部件们

        // 部件可见性 / 骨架开关变化才重建场景；单纯换选中的骨只改材质和点云，
        // 免得每点一次骨就把整个几何重搭一遍（还顺带闪一下）。
        let 新 = 当前签名()
        if 新 != 协.基础签名 {
            协.基础签名 = 新
            let 旧相机 = 视图.pointOfView?.simdWorldPosition
            视图.scene = 建场景(配到: 协)
            // 只是开关某件衣物的可见性时，别把用户已经转好的视角重置了
            if let 旧相机, let 相机节点 = 视图.scene?.rootNode.childNode(withName: "角色相机", recursively: false) {
                相机节点.simdPosition = 旧相机
            }
        }
        协.选中 = 显示骨架 ? 选中骨 : nil
        协.应用选中()
    }

    private func 当前签名() -> String {
        let 部件签 = 部件们
            .map { "\($0.id.uuidString)|\(几何接线.共享.取值(键: $0.id.uuidString)?.导入网格标识 ?? $0.导入网格ID?.uuidString ?? "-")|\($0.isVisible)" }
            .joined(separator: ";")
        // 骨骼是导入时定死的，拿「根数 + 首末路径 + 显示开关」当签名就够，不必逐根比
        let 骨签 = 骨骼们.isEmpty
            ? "无骨"
            : "\(骨骼们.count)|\(骨骼们.first?.路径 ?? "")|\(骨骼们.last?.路径 ?? "")"
        return "\(显示骨架 ? "骨显" : "骨隐")|\(标骨名 ? "标名" : "无名")|\(骨签)|\(部件签)|\(材质签名)"
    }

    private func 建场景(配到 协: 协调器) -> SCNScene {
        // 场景要重搭了，上一轮抓着的节点引用全部作废，先清干净
        协.清空引用()

        let 场景 = SCNScene()
        let 根 = SCNNode()
        场景.rootNode.addChildNode(根)

        let 摆正 = SCNNode()
        根.addChildNode(摆正)
        let 内容 = SCNNode()
        摆正.addChildNode(内容)
        协.内容节点 = 内容

        // 皮和骨各算一份包围盒：取景必须认皮，不能把两套坐标混进同一个盒子
        var 网最小 = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var 网最大 = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var 有网格 = false

        var 诊断 = "=== 角色窗口 \(Date()) 部件\(部件们.count) 骨骼\(骨骼们.count) 显骨\(显示骨架)\n"
        for 物体 in 部件们 {
            诊断 += "· \(物体.name) 可见\(物体.isVisible) 有ID\(几何接线.共享.取值(键: 物体.id.uuidString)?.导入网格标识 ?? 物体.导入网格ID != nil)"
            guard 物体.isVisible else {
                诊断 += " → 跳过(不可见)\n"
                continue
            }
            guard let 网格ID = 几何接线.共享.取值(键: 物体.id.uuidString)?.导入网格标识 ?? 物体.导入网格ID,
                  let 片们 = 几何接线.共享.取(网格ID) else {
                诊断 += " → 跳过(网格池无数据)\n"
                continue
            }
            诊断 += " 片\(片们.count) v\(片们.reduce(0) { $0 + $1.顶点.count }) tri\(片们.reduce(0) { $0 + $1.三角形数 })\n"
            // 有材质就上色，没挂材质留白模。解析与 SCNMaterial 两边都有缓存，
            // 同一材质的十几片摸到的是同一份对象（改一处不会各存一份）
            let 该物体材质 = 预览材质(物体)
            for 片 in 片们 {
                guard let 几何 = 自造几何(片) else {
                    诊断 += "   片「\(片.名称)」造几何失败 v\(片.顶点.count) i\(片.索引.count)\n"
                    continue
                }
                诊断 += "   片「\(片.名称)」几何OK tri\(片.三角形数)\n"
                if let 该物体材质 { 几何.materials = [该物体材质] }
                let 节点 = SCNNode(geometry: 几何)
                节点.simdTransform = 片.变换
                节点.name = 物体.name
                内容.addChildNode(节点)

                for 顶点 in 片.顶点 {
                    let 齐 = 片.变换 * SIMD4<Float>(顶点, 1)
                    guard 齐.w != 0 else { continue }
                    let 世界 = SIMD3<Float>(齐.x, 齐.y, 齐.z) / 齐.w
                    guard 世界.x.isFinite, 世界.y.isFinite, 世界.z.isFinite else { continue }
                    网最小 = simd_min(网最小, 世界)
                    网最大 = simd_max(网最大, 世界)
                    有网格 = true
                }
            }
        }

        诊断 += "内容子节点\(内容.childNodes.count) 有网格\(有网格)\n"
        try? 诊断.write(toFile: "/tmp/3d渲染_角色窗口.log", atomically: true, encoding: .utf8)

        // 骨架也算进包围盒：部件全关了（或这角色压根没部件）时，
        // 光看骨架也能把相机摆到合适的位置
        let 网尺寸 = 有网格 ? 网最大 - 网最小 : .zero

        var 骨最小 = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var 骨最大 = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var 有骨 = false
        for 骨 in 骨骼们 where 骨.有效 {
            骨最小 = simd_min(骨最小, simd_min(骨.头, 骨.尾))
            骨最大 = simd_max(骨最大, simd_max(骨.头, 骨.尾))
            有骨 = true
        }

        // 骨架方向兜底：老项目存档里的骨头尾是上轴校正之前存的（Z 向上），
        // 皮早就是 Y 向上，两套坐标叠在一起就是「一个站着、一个躺着」。
        // 只在「皮明显 Y 向高、骨明显 Z 向高」时把骨架单独转正，正常数据一律不动。
        var 骨局部 = matrix_identity_float4x4
        if 有骨, 有网格, 骨骼们.count > 1 {
            let 骨尺寸 = 骨最大 - 骨最小
            if 网尺寸.y > 网尺寸.z * 1.4, 骨尺寸.z > 骨尺寸.y * 1.4 {
                骨局部 = 网格变换.z转y
            }
            // 老存档的骨连归一化缩放也没吃到，尺寸可能差好几倍，
            // 差得离谱就按包围盒比例把骨架缩回跟皮一个量级，正常数据不会进这个分支
            let 网最长 = max(网尺寸.x, max(网尺寸.y, 网尺寸.z))
            let 骨最长 = max(骨尺寸.x, max(骨尺寸.y, 骨尺寸.z))
            if 网最长 > 1e-6, 骨最长 > 1e-6 {
                let 比 = 网最长 / 骨最长
                if 比 < 0.4 || 比 > 2.5 {
                    骨局部 = 骨局部 * simd_float4x4(diagonal: SIMD4<Float>(比, 比, 比, 1))
                }
            }
        }
        if 有骨, 骨局部 != matrix_identity_float4x4 {
            let 甲 = 变换点(骨局部, 骨最小)
            let 乙 = 变换点(骨局部, 骨最大)
            骨最小 = simd_min(甲, 乙)
            骨最大 = simd_max(甲, 乙)
        }

        // 灯：环境 + 主光 + 轮廓光，白模也能看出体积
        let 环境光 = SCNNode()
        环境光.light = SCNLight()
        环境光.light?.type = .ambient
        环境光.light?.color = NSColor(calibratedWhite: 0.52, alpha: 1)
        根.addChildNode(环境光)

        let 主光 = SCNNode()
        主光.light = SCNLight()
        主光.light?.type = .directional
        主光.light?.color = NSColor(calibratedWhite: 0.95, alpha: 1)
        主光.light?.intensity = 1150
        主光.eulerAngles = SCNVector3(-0.85, 0.55, 0)
        根.addChildNode(主光)

        let 背光 = SCNNode()
        背光.light = SCNLight()
        背光.light?.type = .directional
        背光.light?.color = NSColor(calibratedWhite: 0.5, alpha: 1)
        背光.light?.intensity = 620
        背光.eulerAngles = SCNVector3(-0.35, 3.4, 0)
        根.addChildNode(背光)

        let 相机 = SCNNode()
        相机.name = "角色相机"
        相机.camera = SCNCamera()
        相机.camera?.fieldOfView = 38
        相机.camera?.zNear = 0.01
        相机.camera?.zFar = 200
        根.addChildNode(相机)

        guard 有网格 || 有骨 else {
            相机.simdPosition = SIMD3<Float>(0, 0, 4)
            return 场景
        }

        // 内容居中：取景认皮——有皮就以皮为准，只有骨时才退回骨盒。
        // 两套坐标混着算会把中心拉到中间，皮容易被挤出画面，看着像「皮没了只剩骨」。
        let 取景最小 = 有网格 ? 网最小 : 骨最小
        let 取景最大 = 有网格 ? 网最大 : 骨最大
        let 中心 = (取景最小 + 取景最大) * 0.5
        let 尺寸 = 取景最大 - 取景最小
        内容.simdPosition = -中心

        // 骨架：rest 姿态下 head→tail 一根杆 + 头端一个关节球。
        // 挂在 内容 下面跟着一起居中，粗细按角色体量缩放，小模型不会画出大粗骨头。
        if 显示骨架, !骨骼们.isEmpty {
            let 尺度 = max(max(尺寸.x, max(尺寸.y, 尺寸.z)), 0.001)
            let 杆半径 = CGFloat(尺度 * 0.0035)
            let 球半径 = CGFloat(尺度 * 0.008)
            协.尺度 = 尺度

            let 骨架 = SCNNode()
            骨架.name = "角色骨架"
            骨架.simdTransform = 骨局部
            内容.addChildNode(骨架)

            for 骨 in 骨骼们 {
                guard 骨.有效 else { continue }

                协.骨段[骨.路径] = (变换点(骨局部, 骨.头), 变换点(骨局部, 骨.尾))

                var 杆节点: SCNNode?
                var 球节点: SCNNode?

                let 球 = SCNNode(geometry: SCNSphere(radius: 球半径))
                球.name = "骨节点:" + 骨.路径
                球.simdPosition = 骨.头
                球.geometry?.materials = [协.球材质()]
                骨架.addChildNode(球)
                球节点 = 球

                let 向量 = 骨.尾 - 骨.头
                let 长 = simd_length(向量)
                if 长 > 1e-5 {
                    let 杆 = SCNNode(geometry: SCNCylinder(radius: 杆半径, height: CGFloat(长)))
                    杆.name = "骨杆:" + 骨.路径
                    杆.simdPosition = (骨.头 + 骨.尾) * 0.5
                    // 圆柱默认沿 +Y，转到骨的方向上
                    杆.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: 向量 / 长)
                    杆.geometry?.materials = [协.杆材质()]
                    骨架.addChildNode(杆)
                    杆节点 = 杆
                }

                协.骨节点表[骨.路径] = (杆节点, 球节点)

                if 标骨名, let 文字 = 骨名节点(骨, 尺度: 尺度) {
                    骨架.addChildNode(文字)
                }
            }
        }

        // 只有皮本身是 Z 向上（老格式没声明轴）才整体转正；骨架方向上面已经单独校正过
        if 有网格, 尺寸.z > 尺寸.y * 1.6 {
            摆正.eulerAngles.x = -.pi / 2
        }

        let 半径 = max(simd_length(尺寸) * 0.5, 0.001)
        let 半角 = Float(38.0 * Double.pi / 180 / 2)
        let 距离 = 半径 / tanf(半角) * 1.08
        相机.simdPosition = SIMD3<Float>(0, 0, 距离)
        return 场景
    }

    /// 骨名标注：一个字挂在骨头上，加 billboard 约束永远面向相机。
    /// 骨多时会有点挤，所以做成开关，默认不开。
    private func 骨名节点(_ 骨: 角色骨骼, 尺度: Float) -> SCNNode? {
        let 名 = 骨.名称.isEmpty
            ? (骨.路径.split(separator: "/").last.map(String.init) ?? 骨.路径)
            : 骨.名称
        guard !名.isEmpty else { return nil }

        let 文字 = SCNText(string: 名, extrusionDepth: 0)
        文字.font = NSFont.systemFont(ofSize: 1, weight: .medium)
        文字.flatness = 0.1
        文字.firstMaterial?.diffuse.contents = NSColor(calibratedRed: 0.55, green: 0.95, blue: 1.0, alpha: 1)
        文字.firstMaterial?.lightingModel = .constant
        文字.firstMaterial?.isDoubleSided = true
        // 骨名是给人看的标注，别被身体挡掉
        文字.firstMaterial?.readsFromDepthBuffer = false

        let 节点 = SCNNode(geometry: 文字)
        节点.name = "骨名:" + 骨.路径
        节点.simdPosition = 骨.头 + SIMD3<Float>(0, 尺度 * 0.008, 0)
        let 放大 = 尺度 * 0.02
        节点.scale = SCNVector3(放大, 放大, 放大)
        let 朝向 = SCNBillboardConstraint()
        朝向.freeAxes = .Y
        节点.constraints = [朝向]
        节点.renderingOrder = 30
        return 节点
    }

    /// 部件对应的预览材质；没挂材质返回 nil（由 自造几何 留白模）
    private func 预览材质(_ 物体: SceneObject) -> SCNMaterial? {
        guard let 资产ID = 材质[物体.id],
              let 资产 = 材质接线.共享.取(资产: 资产ID) else { return nil }
        return SCN材质桥.做(MaterialCompiler.resolve(资产), 双面: true)
    }

    /// 导入网格 → SCNGeometry（三角面 + 法线，白模双面）
    private func 自造几何(_ 片: 导入网格) -> SCNGeometry? {
        guard !片.顶点.isEmpty, 片.索引.count >= 3 else { return nil }

        var 源 = [SCNGeometrySource(vertices: 片.顶点.map { SCNVector3(CGFloat($0.x), CGFloat($0.y), CGFloat($0.z)) })]
        if 片.法线.count == 片.顶点.count {
            源.append(SCNGeometrySource(normals: 片.法线.map { SCNVector3(CGFloat($0.x), CGFloat($0.y), CGFloat($0.z)) }))
        }
        // 索引宽度必须被 SceneKit 认：直接喂 [Int]，bytesPerIndex 会变成 8，
        // 而 SceneKit 只支持 1/2/4 字节索引，几何会被静默丢掉——包围盒算得出来、皮却一片不画。
        let 元素: SCNGeometryElement
        if 片.顶点.count <= 0xFFFF {
            元素 = SCNGeometryElement(indices: 片.索引.map { UInt16($0) }, primitiveType: .triangles)
        } else {
            元素 = SCNGeometryElement(indices: 片.索引.map { UInt32($0) }, primitiveType: .triangles)
        }
        let 几何 = SCNGeometry(sources: 源, elements: [元素])

        let 材质 = SCNMaterial()
        let 明度: CGFloat = 0.78
        材质.diffuse.contents = NSColor(calibratedWhite: 明度, alpha: 1)
        材质.metalness.contents = 0.0
        材质.roughness.contents = 0.62
        材质.isDoubleSided = true
        材质.lightingModel = .physicallyBased
        几何.materials = [材质]
        return 几何
    }

    @MainActor
    final class 协调器: NSObject {
        var 基础签名: String = ""
        /// 当前选中的骨路径
        var 选中: String? = nil
        /// 往 SwiftUI 那边回写选中（点预览里的骨时用）
        var 写选中: (String?) -> Void = { _ in }
        /// 往 SwiftUI 那边回写相机朝向（右上角那只小轴向用）
        var 写朝向: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>) -> Void = { _, _, _ in }

        private weak var 监视视图: SCNView?
        private var 朝向定时器: Timer?
        private var 上次朝向: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)?

        /// 挂上相机朝向跟随：主线程 10Hz 量一次，转得明显才回写。
        /// 视图没了（窗口关了）自己会停，不留一个空转的定时器。
        func 挂相机跟随(_ 视图: SCNView) {
            监视视图 = 视图
            朝向定时器?.invalidate()
            let 表 = Timer(timeInterval: 0.1, repeats: true) { [weak self] 计时 in
                MainActor.assumeIsolated {
                    guard let self, self.监视视图 != nil else {
                        计时.invalidate()
                        return
                    }
                    self.量一次朝向()
                }
            }
            表.tolerance = 0.05
            RunLoop.main.add(表, forMode: .common)
            朝向定时器 = 表
        }

        private func 量一次朝向() {
            guard let 相机 = 监视视图?.pointOfView else { return }
            let 转 = 相机.simdWorldTransform
            let 右 = 单位(SIMD3<Float>(转.columns.0.x, 转.columns.0.y, 转.columns.0.z))
            let 上 = 单位(SIMD3<Float>(转.columns.1.x, 转.columns.1.y, 转.columns.1.z))
            let 前 = 单位(-SIMD3<Float>(转.columns.2.x, 转.columns.2.y, 转.columns.2.z))
            guard 右.x.isFinite, 上.y.isFinite, 前.z.isFinite else { return }
            // 转幅小于约 1.5° 就当没动：省得每 0.1 秒都往 SwiftUI 里推一次
            if let 旧 = 上次朝向,
               simd_dot(旧.0, 右) > 0.9997,
               simd_dot(旧.1, 上) > 0.9997,
               simd_dot(旧.2, 前) > 0.9997 {
                return
            }
            上次朝向 = (右, 上, 前)
            写朝向(右, 上, 前)
        }

        private func 单位(_ 值: SIMD3<Float>) -> SIMD3<Float> {
            let 长 = simd_length(值)
            return 长 > 1e-6 ? 值 / 长 : 值
        }
        /// 点云要靠部件的蒙皮权重算，所以得留着部件清单
        var 部件们: [SceneObject] = []

        // 场景重建后回填的引用，选中高亮和点云定位都靠它们
        var 内容节点: SCNNode?
        var 尺度: Float = 1
        /// 路径 → (杆, 关节球)
        var 骨节点表: [String: (杆: SCNNode?, 球: SCNNode?)] = [:]
        /// 路径 → (头, 尾)，点在身体上时用来找最近的骨
        var 骨段: [String: (头: SIMD3<Float>, 尾: SIMD3<Float>)] = [:]

        /// 上一次真正刷过的选中值：SwiftUI 每次 body 更新都会走到 应用选中()，
        /// 而算点云要全扫一遍顶点，没变就别重复扫。
        private var 已应用选中: String? = nil
        private var 已应用有效 = false

        private var 点云: SCNNode?
        private var 杆默认材质: SCNMaterial?
        private var 杆选中材质: SCNMaterial?
        private var 球默认材质: SCNMaterial?
        private var 球选中材质: SCNMaterial?

        func 清空引用() {
            内容节点 = nil
            点云 = nil
            骨节点表 = [:]
            骨段 = [:]
            尺度 = 1
            // 场景重造了，骨节点和材质都是新对象，选中态得重新上色
            已应用有效 = false
        }

        // MARK: 材质

        func 杆材质(选中 选: Bool = false) -> SCNMaterial {
            if 选 {
                if let 杆选中材质 { return 杆选中材质 }
                let 新 = 协调器.造材质(0.30, 1.00, 0.45, 双面: true)
                杆选中材质 = 新
                return 新
            }
            if let 杆默认材质 { return 杆默认材质 }
            let 新 = 协调器.造材质(0.96, 0.60, 0.20, 双面: true)
            杆默认材质 = 新
            return 新
        }

        func 球材质(选中 选: Bool = false) -> SCNMaterial {
            if 选 {
                if let 球选中材质 { return 球选中材质 }
                let 新 = 协调器.造材质(0.55, 1.00, 0.62, 双面: false)
                球选中材质 = 新
                return 新
            }
            if let 球默认材质 { return 球默认材质 }
            let 新 = 协调器.造材质(0.45, 0.90, 0.98, 双面: false)
            球默认材质 = 新
            return 新
        }

        private static func 造材质(_ 红: CGFloat, _ 绿: CGFloat, _ 蓝: CGFloat, 双面: Bool) -> SCNMaterial {
            let 材 = SCNMaterial()
            材.diffuse.contents = NSColor(calibratedRed: 红, green: 绿, blue: 蓝, alpha: 1)
            材.lightingModel = .constant
            材.isDoubleSided = 双面
            return 材
        }

        // MARK: 选中

        /// 只改材质 + 重搭点云，不动其它几何（点一根骨不该把场景整个重来）
        func 应用选中() {
            if 已应用有效, 已应用选中 == 选中 { return }
            已应用选中 = 选中
            已应用有效 = true

            for (路径, 节点们) in 骨节点表 {
                let 被选 = (路径 == 选中)
                if let 杆 = 节点们.杆 { 杆.geometry?.materials = [杆材质(选中: 被选)] }
                if let 球 = 节点们.球 { 球.geometry?.materials = [球材质(选中: 被选)] }
            }

            点云?.removeFromParentNode()
            点云 = nil

            guard let 路径 = 选中, let 内容 = 内容节点 else { return }
            let 骨名 = 路径.split(separator: "/").last.map(String.init) ?? 路径
            let 结果 = 骨骼影响.算(骨名: 骨名, 部件们: 部件们)
            guard !结果.点.isEmpty, let 几何 = 造点云(结果.点) else { return }

            let 节点 = SCNNode(geometry: 几何)
            节点.name = "影响顶点"
            节点.renderingOrder = 20
            内容.addChildNode(节点)
            点云 = 节点
        }

        @objc func 点一下(_ 手势: NSClickGestureRecognizer) {
            guard let 视图 = 手势.view as? SCNView else { return }
            let 位置 = 手势.location(in: 视图)
            let 命中 = 视图.hitTest(位置, options: [
                .searchMode: SCNHitTestSearchMode.all.rawValue,
                .ignoreHiddenNodes: true,
                .backFaceCulling: false
            ])

            // 直接点到骨（杆或关节球）就算选中它
            for 结果 in 命中 {
                guard let 名 = 结果.node.name else { continue }
                if 名.hasPrefix("骨杆:") { 切到(String(名.dropFirst(3))); return }
                if 名.hasPrefix("骨节点:") { 切到(String(名.dropFirst(4))); return }
            }

            // 点在身上：选离落点最近、且够近的那根骨，点手臂就落到手臂骨上
            guard let 原始落点 = 命中.first?.worldCoordinates else { 写选中(nil); return }
            // 骨段存的是「内容」局部坐标，落点也得换算到同一空间，否则永远点不中
            let 局部 = 内容节点?.convertPosition(原始落点, from: nil) ?? 原始落点
            let 落点 = SIMD3<Float>(Float(局部.x), Float(局部.y), Float(局部.z))
            var 最佳: String?
            var 最佳距 = Float.greatestFiniteMagnitude
            for (路径, 段) in 骨段 {
                let 距 = 点到线段(落点, 段.头, 段.尾)
                if 距 < 最佳距 { 最佳距 = 距; 最佳 = 路径 }
            }
            if let 最佳, 最佳距 <= 尺度 * 0.06 { 切到(最佳) } else { 写选中(nil) }
        }

        /// 再点一次同一根骨就取消选中
        private func 切到(_ 路径: String) {
            写选中(路径 == 选中 ? nil : 路径)
        }

        private func 点到线段(_ p: SIMD3<Float>, _ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
            let 方向 = b - a
            let 长2 = simd_length_squared(方向)
            guard 长2 > 1e-12 else { return simd_length(p - a) }
            let t = max(Float(0), min(Float(1), simd_dot(p - a, 方向) / 长2))
            return simd_length(p - (a + 方向 * t))
        }

        /// 受影响顶点画成点云。位置就是网格顶点（已在世界坐标），跟骨架同一个空间。
        private func 造点云(_ 点: [SIMD3<Float>]) -> SCNGeometry? {
            guard !点.isEmpty else { return nil }
            let 源 = SCNGeometrySource(vertices: 点.map { SCNVector3(CGFloat($0.x), CGFloat($0.y), CGFloat($0.z)) })
            let 元素 = SCNGeometryElement(indices: (0..<UInt32(点.count)).map { $0 }, primitiveType: .point)
            元素.pointSize = 5
            元素.minimumPointScreenSpaceRadius = 1.5
            元素.maximumPointScreenSpaceRadius = 9

            let 几何 = SCNGeometry(sources: [源], elements: [元素])
            let 材 = SCNMaterial()
            let 色 = NSColor(calibratedRed: 0.30, green: 1.00, blue: 0.45, alpha: 1)
            材.diffuse.contents = 色
            材.emission.contents = 色
            材.lightingModel = .constant
            // 权重点正好落在皮肤表面上，和面重合容易打架；
            // 让它盖在面上画，隔着衣服也看得见这根骨到底拽着哪片皮。
            材.readsFromDepthBuffer = false
            材.writesToDepthBuffer = false
            几何.materials = [材]
            return 几何
        }
    }
}


// MARK: - 一根骨的影响范围

/// 一根骨到底拽着哪片皮：数据来源是导入网格里的蒙皮权重（顶点组名就是骨名）。
/// 预览里打点、左下角报数量都走这一份算法，免得两处口径对不上。
enum 骨骼影响 {
    /// 权重太小的顶点肉眼看不出位移，标出来反而像整身都在亮
    static let 阈值: Float = 0.2
    /// 点云上限：几万点全打会拖慢 SceneKit，超了按等间隔抽样
    static let 上限 = 24000

    struct 结果 {
        var 点: [SIMD3<Float>] = []
        /// 抽样前的真实顶点数（左下角显示的是这个）
        var 总数: Int = 0
    }

    static func 算(骨名: String, 部件们: [SceneObject]) -> 结果 {
        var 值 = 结果()
        guard !骨名.isEmpty else { return 值 }

        for 物体 in 部件们 where 物体.isVisible {
            guard let 网格ID = 几何接线.共享.取值(键: 物体.id.uuidString)?.导入网格标识 ?? 物体.导入网格ID,
                  let 片们 = 几何接线.共享.取(网格ID) else { continue }
            for 片 in 片们 {
                guard 片.权重.count == 片.顶点.count, !片.权重.isEmpty else { continue }
                for i in 0..<片.顶点.count {
                    guard 片.权重[i].contains(where: { $0.骨名 == 骨名 && $0.重量 >= 阈值 }) else { continue }
                    值.总数 += 1
                    // 顶点要乘部件的变换才是世界坐标（骨架头尾也在这个空间里）
                    let 齐 = 片.变换 * SIMD4<Float>(片.顶点[i], 1)
                    guard 齐.w != 0 else { continue }
                    let 世界 = SIMD3<Float>(齐.x, 齐.y, 齐.z) / 齐.w
                    guard 世界.x.isFinite, 世界.y.isFinite, 世界.z.isFinite else { continue }
                    值.点.append(世界)
                }
            }
        }

        if 值.点.count > 上限 {
            let 步 = Double(值.点.count) / Double(上限)
            var 取: [SIMD3<Float>] = []
            取.reserveCapacity(上限)
            var f = 0.0
            while Int(f) < 值.点.count && 取.count < 上限 {
                取.append(值.点[Int(f)])
                f += 步
            }
            值.点 = 取
        }
        return 值
    }
}


/// 只做点变换（骨骼头尾是没有 w 的世界坐标点），跟 解析 blend 里那份保持同一口径
private func 变换点(_ m: simd_float4x4, _ p: SIMD3<Float>) -> SIMD3<Float> {
    let q = m * SIMD4<Float>(p, 1)
    guard abs(q.w) > 1e-9, q.w != 1 else { return SIMD3<Float>(q.x, q.y, q.z) }
    return SIMD3<Float>(q.x / q.w, q.y / q.w, q.z / q.w)
}
