import AppKit
import SwiftUI

/// 模式二：布局 / 场景装配。大纲 + 视口 + 变换。
struct LayoutWorkspace: View {
    @Environment(布局Store.self) private var store
    @Environment(着色Store.self) private var shading

    /// 集合重命名弹窗（右键"重命名…"用）
    @State private var 重命名目标: UUID?
    @State private var 重命名文本: String = ""
    @State private var 显示重命名 = false

    var body: some View {
        @Bindable var shading = shading

        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                outline
                    .frame(width: 240)

                Rectangle().fill(Theme.divider).frame(width: 1)

                VStack(spacing: 0) {
                    ViewportPanel()
                    transformBar
                }

                if shading.n面板可见 {
                    Rectangle().fill(Theme.divider).frame(width: 1)

                    // 变换面板已经整体搬进 N 面板的「变换」页：
                    // 布局 Tab 里原本常驻的那 300pt 检查器不留副本，避免两处都能改、谁都不权威。
                    N面板(页: $shading.n面板页) { shading.n面板可见 = false }
                }
            }
        }
        .background(Theme.canvasBackground)
    }

    // MARK: 大纲

    private var outline: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "大纲", symbol: "list.bullet.indent") {
                Menu {
                    ForEach(MeshKind.allCases) { mesh in
                        Button {
                            store.addObject(mesh: mesh)
                        } label: {
                            Label(mesh.title, systemImage: mesh.symbol)
                        }
                    }

                    Divider()

                    Button {
                        store.新建集合()
                    } label: {
                        Label("新建集合", systemImage: "folder.badge.plus")
                    }

                    Button {
                        store.打包选中为集合()
                    } label: {
                        Label("把选中打包成集合", systemImage: "folder")
                    }
                    .disabled(store.选中集合.isEmpty)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24)
            }

            ScrollViewReader { 滚动 in
                ScrollView {
                    VStack(spacing: 2) {
                        场景根行
                        容器行(父集合: nil, 层: 0)

                        if store.objects.isEmpty {
                            Text("场景为空，点 + 添加网格")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .padding(.top, 12)
                        }
                    }
                    .padding(.vertical, 4)
                }
                // 全局搜索点中某个物体跳过来：把它滚到视觉中间。
                // 选中高亮走的是选中集合，行本身不用再额外处理。
                .onChange(of: store.大纲聚焦目标) { _, 目标 in
                    滚动到目标(目标, 滚动: 滚动)
                }
                .onAppear {
                    滚动到目标(store.大纲聚焦目标, 滚动: 滚动)
                }
            }
        }
        .background(Theme.panelBackground)
        .alert("重命名集合", isPresented: $显示重命名) {
            TextField("集合名称", text: $重命名文本)
            Button("确定") {
                if let 目标 = 重命名目标 { store.重命名集合(目标, 为: 重命名文本) }
            }
            Button("取消", role: .cancel) {}
        }
    }

    /// 树根：把东西拖到这一行 = 移出集合、回到场景根级
    private var 场景根行: some View {
        HStack(spacing: 6) {
            Image(systemName: "cube.transparent")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text("场景")
                .font(.system(size: 11, weight: .semibold))
            Spacer()
            Text("\(store.objects.count)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { 项目, _ in
            拖放(项目, 到: nil)
        }
        .contextMenu {
            Button("新建集合") { store.新建集合() }
        }
    }

    // MARK: 树

    /// 一个容器下的全部内容：先子集合，再直接子物体（挂集合的 + 挂这个物体当子级的）
    private func 容器行(父集合: UUID?, 层: Int) -> AnyView {
        let 父: 父引用? = 父集合.map { 父引用.集合($0) }
        return AnyView(
            VStack(spacing: 2) {
                ForEach(store.子集合们(父集合)) { c in
                    集合行(c, 层: 层)
                }
                // 角色身上的身体/衣服/道具收在角色窗口里，大纲只留角色那一行
                ForEach(store.子对象们(父).filter { !store.角色部件ID集.contains($0.id) }) { object in
                    物体树(object, 层: 层)
                }
            }
        )
    }

    private func 集合行(_ c: 场景集合, 层: Int) -> AnyView {
        AnyView(
            VStack(spacing: 2) {
                HStack(spacing: 5) {
                    // 方形点击热区：不用精确点到箭头本身，整块 20×20 都能展开/收起
                    Button {
                        store.切换集合展开(c.id)
                    } label: {
                        ZStack {
                            Image(systemName: c.展开 ? "chevron.down" : "chevron.right")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    Image(systemName: c.isVisible ? "folder.fill" : "folder")
                        .font(.system(size: 9.5))
                        .foregroundStyle(c.isVisible ? .secondary : .tertiary)
                    Text(c.name)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    Text("\(store.集合内对象ID(c.id).count)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                .padding(.leading, CGFloat(层) * 11 + 4)
                .padding(.trailing, 10)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
                .onTapGesture { store.切换集合展开(c.id) }
                .draggable("col:\(c.id.uuidString)")
                .dropDestination(for: String.self) { 项目, _ in
                    拖放(项目, 到: .集合(c.id))
                }
                .contextMenu {
                    Button("新建子集合") { store.新建集合(父: c.id) }
                    Button("重命名…") {
                        重命名目标 = c.id
                        重命名文本 = c.name
                        显示重命名 = true
                    }
                    Button(c.isVisible ? "隐藏集合" : "显示集合") {
                        store.设集合可见(c.id, !c.isVisible)
                    }
                    Divider()
                    Button("解散集合（保留物体）", role: .destructive) {
                        store.删除集合(c.id)
                    }
                }

                if c.展开 {
                    容器行(父集合: c.id, 层: 层 + 1)
                }
            }
        )
    }

    /// 一个物体 + 它下面的子物体（父子层级）。
    /// 角色（骨架）是容器型资产：大纲里就是一行，双击打开它的穿挂窗口，
    /// 身上的部件不在大纲里展开。
    private func 物体树(_ object: SceneObject, 层: Int) -> AnyView {
        let 是角色 = object.是角色
        let 有子 = !是角色 && store.有子对象(object.id)
        let 展开 = store.展开对象.contains(object.id)
        return AnyView(
            VStack(spacing: 2) {
                HStack(spacing: 0) {
                    // 方形点击热区：整块 20×20 都能展开/收起，不用精确点到箭头
                    Button {
                        store.切换对象展开(object.id)
                    } label: {
                        ZStack {
                            Image(systemName: 展开 ? "chevron.down" : "chevron.right")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .opacity(有子 ? 1 : 0)
                    .disabled(!有子)

                    objectRow(object)
                }
                .padding(.leading, CGFloat(层) * 11 + 4)
                .draggable("obj:\(object.id.uuidString)")
                .dropDestination(for: String.self) { 项目, _ in
                    // 拖到物体上 = 认它当父级（父动子跟随）
                    拖放(项目, 到: .对象(object.id))
                }
                .id(object.id)

                if 有子, 展开 {
                    ForEach(store.子对象们(.对象(object.id))) { 子 in
                        物体树(子, 层: 层 + 1)
                    }
                }
            }
        )
    }

    /// 把拖拽负载解析成节点引用，然后挂到目标容器下
    private func 拖放(_ 项目: [String], 到 目标: 父引用?) -> Bool {
        let 节点 = 项目.compactMap { 串 -> 父引用? in
            guard 串.count > 4 else { return nil }
            if 串.hasPrefix("obj:"), let id = UUID(uuidString: String(串.dropFirst(4))) {
                return .对象(id)
            }
            if 串.hasPrefix("col:"), let id = UUID(uuidString: String(串.dropFirst(4))) {
                return .集合(id)
            }
            return nil
        }
        guard !节点.isEmpty else { return false }
        return store.移入(节点, 到: 目标)
    }

    /// 把目标物体滚进大纲视野，然后消费掉请求（免得每次切回布局 tab 又自动滚一次）
    private func 滚动到目标(_ 目标: UUID?, 滚动: ScrollViewProxy) {
        guard let 目标 else { return }
        Task { @MainActor in
            withAnimation(.easeOut(duration: 0.22)) {
                滚动.scrollTo(目标, anchor: .center)
            }
            if store.大纲聚焦目标 == 目标 { store.大纲聚焦目标 = nil }
        }
    }

    private func objectRow(_ object: SceneObject) -> some View {
        HStack(spacing: 7) {
            Button {
                store.updateObject(object.id) { $0.isVisible.toggle() }
            } label: {
                Image(systemName: object.isVisible ? "eye" : "eye.slash")
                    .font(.system(size: 9.5))
                    .foregroundStyle(object.isVisible ? .secondary : .tertiary)
            }
            .buttonStyle(.borderless)

            Image(systemName: object.symbol)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(object.name)
                .font(.system(size: 11))
                .lineLimit(1)
            if object.是角色 {
                Text("\(object.角色?.部件.count ?? 0) 件")
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Theme.fieldBackground))
                    .overlay(Capsule().stroke(Theme.stroke, lineWidth: 0.5))
            }
            if let 特效 = object.特效 {
                // 特效容器：跟角色一个待遇，大纲里就是一行，双击进去调里面的发射源
                Text("\(特效.源数) 源")
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Theme.fieldBackground))
                    .overlay(Capsule().stroke(Theme.stroke, lineWidth: 0.5))
            }
            Spacer(minLength: 2)
            if let material = shading.material(object.materialID) {
                Circle()
                    .fill(Theme.color(from: material.previewColor))
                    .frame(width: 8, height: 8)
                    .overlay(Circle().stroke(Theme.stroke, lineWidth: 0.5))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            store.选中集合.contains(object.id)
                ? Color.accentColor.opacity(0.18)
                : Color.clear
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            // 双击容器型资产 = 打开它自己的面板
            if object.是角色 {
                角色窗口控制器.shared.打开(角色ID: object.id, store: store)
                return
            }
            if object.特效 != nil {
                特效窗口控制器.shared.打开(特效ID: object.id, store: store, shading: shading)
            }
        }
        .onTapGesture {
            // 与视口同一套语义：Shift 点击加选 / 减选
            store.选中(object.id, 加选: NSEvent.modifierFlags.contains(.shift))
        }
        .contextMenu {
            if object.是角色 {
                Button("打开角色窗口（穿衣挂道具）") {
                    角色窗口控制器.shared.打开(角色ID: object.id, store: store)
                }
                Divider()
            }
            if object.特效 != nil {
                Button("打开特效容器（调发射源）") {
                    特效窗口控制器.shared.打开(特效ID: object.id, store: store, shading: shading)
                }
                Divider()
            }
            Button("把选中打包成集合") { store.打包选中为集合() }
            if object.父 != nil {
                Button("移出到场景根级") { store.设父(object.id, 到: nil) }
            }
            Divider()
            Button("删除物体", role: .destructive) { store.deleteObject(object.id) }
        }
    }

    // MARK: 视口底部条

    private var transformBar: some View {
        HStack(spacing: 10) {
            Text("场景物体 \(store.objects.count) · 材质 \(shading.库材质列表.count)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
            Text("视口交互与「着色」工作区共用同一 RealityKit 场景")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Theme.panelBackground)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.divider).frame(height: 1)
        }
    }

}

// MARK: - 变换数值输入

/// 变换数值输入：回车提交、**失焦也提交** —— 点面板里另一个输入框、点面板空白、
/// 点外层其他面板、点视口、切窗口，全都算。
///
/// 为什么不用 SwiftUI 的 TextField：
/// 1. `TextField(value:format:)` 在 macOS 上只在回车时把文本写回绑定，失焦直接丢；
/// 2. 换成自管文本 + `@FocusState` 也不稳 —— 点窗口里的纯空白、点某些非文本控件，
///    文本框压根不 resign，焦点一直挂着，提交永远等不到。
/// 这里直接用 AppKit 的 NSTextField：`controlTextDidEndEditing` 是字段编辑器真实 resign 的回调，
/// 覆盖面比 SwiftUI 的焦点状态广；再挂一条本地左键监视器，按下的位置不落在本框里就当场
/// `makeFirstResponder(nil)` 收尾，把「点空白不 resign」这条漏网也堵上。
struct 变换数值输入: NSViewRepresentable {
    var 值: Double
    var 提交: (Double) -> Void

    func makeCoordinator() -> 协调器 { 协调器(当前值: 值, 提交: 提交) }

    func makeNSView(context: Context) -> NSTextField {
        let 框 = NSTextField()
        框.isBezeled = true
        框.bezelStyle = .roundedBezel
        框.controlSize = .small
        框.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        框.usesSingleLineMode = true
        框.lineBreakMode = .byClipping
        框.stringValue = Self.格式化(值)
        框.delegate = context.coordinator
        框.target = context.coordinator
        框.action = #selector(协调器.回车(_:))
        // 宽度交给外面的 HStack 去分，自己不跟内容抢
        框.setContentHuggingPriority(.defaultLow, for: .horizontal)
        框.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        context.coordinator.框 = 框
        context.coordinator.装监视器()
        return 框
    }

    func updateNSView(_ 框: NSTextField, context: Context) {
        context.coordinator.当前值 = 值
        // 正在打字就别覆盖用户输入；外部拖手柄改了值也一样，等他收工再回填
        guard 框.currentEditor() == nil else { return }
        let 文本 = Self.格式化(值)
        if 框.stringValue != 文本 { 框.stringValue = 文本 }
    }

    static func dismantleNSView(_ 框: NSTextField, coordinator: 协调器) {
        coordinator.卸监视器()
    }

    static func 格式化(_ 数: Double) -> String {
        String(format: "%.2f", 数)
    }

    @MainActor
    final class 协调器: NSObject, NSTextFieldDelegate {
        var 当前值: Double
        var 提交: (Double) -> Void
        weak var 框: NSTextField?
        private var 监视器: Any?

        init(当前值: Double, 提交: @escaping (Double) -> Void) {
            self.当前值 = 当前值
            self.提交 = 提交
        }

        /// 回车走文本框的 action
        @objc func 回车(_ 发送者: NSTextField) { 落地(发送者) }

        /// 失焦走这里：点别的输入框 / 别的控件 / 按 Tab / 窗口换焦点，字段编辑器都会 resign
        func controlTextDidEndEditing(_ 通知: Notification) {
            guard let 字段 = 通知.object as? NSTextField else { return }
            落地(字段)
        }

        /// 幂等：值没变就不写场景，重复回调（回车后又失焦）不会提交两遍
        private func 落地(_ 字段: NSTextField) {
            let 干净 = 字段.stringValue
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "，", with: ".")
                .replacingOccurrences(of: ",", with: ".")
            guard let 新 = Double(干净), 新.isFinite else {
                字段.stringValue = 变换数值输入.格式化(当前值)   // 打错了还原显示，不把脏数据送进场景
                return
            }
            if 新 != 当前值 {
                当前值 = 新
                提交(新)
            }
            字段.stringValue = 变换数值输入.格式化(新)
        }

        func 装监视器() {
            guard 监视器 == nil else { return }
            监视器 = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] 事件 in
                guard let self, let 框 = self.框, 框.currentEditor() != nil else { return 事件 }
                guard let 内容 = 事件.window?.contentView else { return 事件 }
                // 用 AppKit 自己的 hitTest 判命中，比换算 SwiftUI 的 global 坐标可靠（不受标题栏偏移影响）
                let 点 = 内容.convert(事件.locationInWindow, from: nil)
                if let 命中 = 内容.hitTest(点), 命中 === 框 || 命中.isDescendant(of: 框) {
                    return 事件
                }
                事件.window?.makeFirstResponder(nil)   // 点别处：先收尾，触发 controlTextDidEndEditing
                return 事件
            }
        }

        func 卸监视器() {
            if let 监视器 { NSEvent.removeMonitor(监视器) }
            监视器 = nil
        }
    }
}
