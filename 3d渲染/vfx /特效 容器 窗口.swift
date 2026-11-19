import AppKit
import SwiftUI
import simd

// MARK: - 特效容器窗口
//
// 口径：特效在大纲里也是**一行容器**，双击开这个面板。
//   左边：容器里的发射源列表（程序网格 / 导入网格，可塞材质）
//   右边：选中源自己的参数（形状、材质、TRS）
//
// 这些源**只是发射体**：不进场景、不进大纲、视口不画、出图也看不见。
// 所以"想让圈圈上冒火"不必在场景里摆一个看得见的圈，往容器里塞一个环面就行。
// 容器也不是范围锁，仅作选择与组织的节点（跟 UE 那个容器一个意思），
// 火/烟/粒子/水还是挂在容器对象自己身上、参数照旧去 N 面板调。

@MainActor
final class 特效窗口控制器: NSObject, NSWindowDelegate {
    static let shared = 特效窗口控制器()

    private var 窗口们: [UUID: NSWindow] = [:]
    private override init() { super.init() }

    /// 双击大纲里的特效容器行调用。同一个容器只开一个窗口，重复双击就前置。
    func 打开(特效ID: UUID, store: 布局Store, shading: 着色Store) {
        let 视图 = 特效容器视图(store: store, shading: shading, 特效ID: 特效ID)

        if let 现有 = 窗口们[特效ID] {
            (现有.contentView as? NSHostingView<特效容器视图>)?.rootView = 视图
            if 现有.isMiniaturized { 现有.deminiaturize(nil) }
            现有.makeKeyAndOrderFront(nil)
            return
        }

        let 承载 = NSHostingView(rootView: 视图)
        // 独立窗口不在 ContentView 的视图树里，拿不到那边的 preferredColorScheme，
        // 系统是浅色时会黑字压黑底 → 跟主界面用同一套外观。
        if let 外观 = 偏好设置Store.shared.外观.强制配色 {
            let 名义: NSAppearance.Name = 外观 == .dark ? .darkAqua : .aqua
            承载.appearance = NSAppearance(named: 名义)
        }
        let 窗口 = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        let 名 = store.objects.first { $0.id == 特效ID }?.name ?? "特效"
        窗口.title = "特效容器 · \(名)"
        窗口.minSize = NSSize(width: 700, height: 460)
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
        窗口们[特效ID] = 窗口
        窗口.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ 通: Notification) {
        guard let 窗 = 通.object as? NSWindow else { return }
        窗口们 = 窗口们.filter { $0.value !== 窗 }
    }
}

// MARK: - 面板内容

struct 特效容器视图: View {
    var store: 布局Store
    var shading: 着色Store
    let 特效ID: UUID

    @State private var 选中ID: UUID?
    /// 名称框的草稿：容器数据在 store 里，输入过程不能每敲一个字就写一次存档
    @State private var 名称草稿: String = ""
    @State private var 草稿源: UUID?

    // MARK: 取数

    private var 物体: SceneObject? { store.objects.first { $0.id == 特效ID } }
    private var 设置: 特效设置? { 物体?.特效 }
    private var 源们: [特效发射源] { 设置?.发射源们 ?? [] }

    private var 选中源: 特效发射源? {
        if let 选中ID, let 命中 = 源们.first(where: { $0.id == 选中ID }) { return 命中 }
        return 源们.first
    }

    /// 场景里出现过的导入网格（按名字去重）——"塞预设模型"就从这儿挑
    private var 场景模型: [(网格ID: UUID, 名称: String)] {
        var 见过: [UUID: String] = [:]
        var 顺序: [UUID] = []
        for 物 in store.objects {
            guard let 网格 = 物.导入网格ID, 见过[网格] == nil else { continue }
            见过[网格] = 物.name
            顺序.append(网格)
        }
        return 顺序.map { (网格ID: $0, 名称: 见过[$0] ?? "导入网格") }
    }

    // MARK: 改数

    private func 改容器(_ 变: (inout 特效设置) -> Void) {
        store.updateObject(特效ID) { 物 in
            guard var 设置 = 物.特效 else { return }
            变(&设置)
            物.特效 = 设置
        }
    }

    private func 改源(_ id: UUID, _ 变: (inout 特效发射源) -> Void) {
        改容器 { 设置 in
            var 表 = 设置.发射源们 ?? []
            guard let i = 表.firstIndex(where: { $0.id == id }) else { return }
            变(&表[i])
            设置.发射源们 = 表
        }
    }

    private func 加源(_ 新: 特效发射源) {
        改容器 { 设置 in
            var 表 = 设置.发射源们 ?? []
            表.append(新)
            设置.发射源们 = 表
        }
        选中ID = 新.id
        名称草稿 = 新.名称
        草稿源 = 新.id
    }

    private func 删源(_ id: UUID) {
        let 下一个 = 源们.first(where: { $0.id != id })?.id
        改容器 { 设置 in
            设置.发射源们 = (设置.发射源们 ?? []).filter { $0.id != id }
        }
        if 选中ID == id { 选中ID = 下一个 }
        名称草稿 = 源们.first(where: { $0.id == 下一个 })?.名称 ?? ""
        草稿源 = 下一个
    }

    private func 复制源(_ 源: 特效发射源) {
        var 新 = 源
        新.id = UUID()
        新.名称 = 源.名称 + " 副本"
        新.位置 = Vec3(源.位置.x + 0.2, 源.位置.y, 源.位置.z)
        加源(新)
    }

    /// 把草稿同步成"当前选中源的名字"（切源 / 首次打开时调）
    private func 同步草稿() {
        guard let 源 = 选中源 else {
            名称草稿 = ""
            草稿源 = nil
            return
        }
        if 草稿源 != 源.id || 名称草稿.isEmpty {
            名称草稿 = 源.名称
            草稿源 = 源.id
        }
    }

    // MARK: 视图

    var body: some View {
        VStack(spacing: 0) {
            顶栏
            Rectangle().fill(Theme.divider).frame(height: 1)
            HStack(spacing: 0) {
                左栏
                Rectangle().fill(Theme.divider).frame(width: 1)
                右栏
            }
        }
        .background(Theme.panelBackground)
        .onAppear { 同步草稿() }
        .onChange(of: 选中源?.id) { _, _ in 同步草稿() }
    }

    private var 顶栏: some View {
        HStack(spacing: 10) {
            Image(systemName: 设置?.种类.符号 ?? "flame.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text(物体?.name ?? "特效")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            if let 设置 {
                Text(设置.种类.名称)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Theme.fieldBackground))
            }
            Spacer(minLength: 8)
            Text("源 \(源们.count) 个 · 启用 \(源们.filter { $0.启用 }.count) 个")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // ---- 左：源列表 ----

    private var 左栏: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("发射源")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                添加菜单
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if 源们.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "square.stack.3d.up.slash")
                        .font(.system(size: 26))
                        .foregroundStyle(Theme.textTertiary)
                    Text("容器还是空的")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                    Text("塞个环面进去，火就从环上冒")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(源们) { 源 in
                            源行(源)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
            }

            Rectangle().fill(Theme.divider).frame(height: 1)
            Text("视口里看不到这些发射体，它们只负责出火/出水")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .frame(width: 246)
    }

    private var 添加菜单: some View {
        Menu {
            Section("程序网格") {
                ForEach(MeshKind.可当发射体, id: \.self) { 形状 in
                    Button(形状.title) {
                        加源(特效发射源(名称: 形状.title, 形状: 形状))
                    }
                }
            }
            if !场景模型.isEmpty {
                Section("场景里的模型") {
                    ForEach(场景模型, id: \.网格ID) { 模型 in
                        Button(模型.名称) {
                            加源(特效发射源(名称: 模型.名称, 形状: .torus,
                                            导入网格ID: 模型.网格ID))
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 20)
        .help("往容器里塞一个发射源")
    }

    private func 源行(_ 源: 特效发射源) -> some View {
        let 选中 = (选中源?.id == 源.id)
        return HStack(spacing: 6) {
            Button {
                改源(源.id) { $0.启用.toggle() }
            } label: {
                Image(systemName: 源.启用 ? "eye" : "eye.slash")
                    .font(.system(size: 10))
                    .foregroundStyle(源.启用 ? Theme.textSecondary : Theme.textTertiary)
            }
            .buttonStyle(.plain)
            .help(源.启用 ? "暂时不发射" : "恢复发射")

            Image(systemName: 源.图标)
                .font(.system(size: 10))
                .foregroundStyle(源.启用 ? Theme.accent : Theme.textTertiary)
                .frame(width: 14)

            Text(源.名称)
                .font(.system(size: 11))
                .foregroundStyle(源.启用 ? Theme.textPrimary : Theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 4)

            if let 材质ID = 源.材质ID, let 材质 = shading.material(材质ID) {
                Circle()
                    .fill(Theme.color(from: 材质.previewColor))
                    .frame(width: 9, height: 9)
                    .overlay(Circle().stroke(Theme.stroke, lineWidth: 0.5))
                    .help("材质：\(材质.name)")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(选中 ? Theme.accent.opacity(0.16) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { 选中ID = 源.id }
        .contextMenu {
            Button("复制一份") { 复制源(源) }
            Button(源.启用 ? "暂时不发射" : "恢复发射") { 改源(源.id) { $0.启用.toggle() } }
            Divider()
            Button("删除", role: .destructive) { 删源(源.id) }
        }
    }

    // ---- 右：选中源参数 ----

    private var 右栏: some View {
        VStack(spacing: 0) {
            // 上：预览窗口（跟角色窗口一个思路 —— 先看见成品，再动参数）
            特效预览区(设置: 设置, 源: 选中源, 材质: 选中源材质)
                .frame(height: 214)
            Rectangle().fill(Theme.divider).frame(height: 1)

            // 下：源参数 + 模块栈（UE 新版 Niagara 那种分堆）
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if 选中源 == nil, let 发射体ID = 设置?.发射体对象ID,
                       let 宿主 = store.objects.first(where: { $0.id == 发射体ID }) {
                        收纳提示(宿主)
                    }
                    if let 源 = 选中源 {
                        基础组(源)
                        材质槽组(源)
                        变换组(源)
                    }
                    if let 设置 {
                        组标题("模块")
                        特效模块栈(设置: 设置, 提交: { 新 in 改容器 { $0 = 新 } })
                    }
                    if 选中源 != nil {
                        提示组
                    }
                }
                .padding(16)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// 选中源的材质（预览区和槽都用它，保证"槽里显示的 = 预览里发光的那张球"）
    private var 选中源材质: MaterialAsset? {
        guard let 源 = 选中源 else { return nil }
        return shading.material(源.材质ID)
    }

    /// 老容器（还挂着「发射体对象」的）一键修：把宿主形状收成源、清掉发射体引用，
    /// 火就回到容器所在处，而不是长在别的对象身上。
    private func 收纳提示(_ 宿主: SceneObject) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("这个容器还在借「\(宿主.name)」当发射体")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textPrimary)
            Text("借别人的话火会冒在别人身上。收进容器后，发射位置就跟着容器走。")
                .font(.system(size: 9.5))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                收纳发射体(宿主)
            } label: {
                Text("把形状收进容器")
                    .font(.system(size: 10.5))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.divider.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func 收纳发射体(_ 宿主: SceneObject) {
        改容器 { 设置 in
            var 表 = 设置.发射源们 ?? []
            if !表.contains(where: { $0.名称 == 宿主.name }) {
                表.append(特效发射源(名称: 宿主.name, 形状: 宿主.mesh))
            }
            设置.发射源们 = 表
            设置.发射体对象ID = nil
        }
    }

    private func 材质槽组(_ 源: 特效发射源) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            组标题("材质")
            HStack(spacing: 10) {
                特效材质槽(材质: 选中源材质,
                          材质们: shading.本项目材质列表,
                          尺寸: 56,
                          选: { id in
                    改源(源.id) { $0.材质ID = id }
                })
                VStack(alignment: .leading, spacing: 3) {
                    Text(选中源材质?.name ?? "未指定材质")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text("点槽挑一个（内容 = 材质库「本项目」tab）。这里只定「认哪一个材质」，发出来什么样子由下面的模块决定。")
                        .font(.system(size: 9.5))
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if 源.材质ID != nil {
                    Button {
                        改源(源.id) { $0.材质ID = nil }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .help("清掉材质")
                }
            }
        }
    }

    private func 基础组(_ 源: 特效发射源) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            组标题("这个源是什么")
            HStack(spacing: 8) {
                Text("名称")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 60, alignment: .leading)
                TextField("", text: $名称草稿)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Theme.fieldBackground))
                    .onSubmit {
                        let 新 = 名称草稿.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !新.isEmpty else { 名称草稿 = 源.名称; return }
                        改源(源.id) { $0.名称 = 新 }
                    }
            }
            HStack(spacing: 8) {
                Text("启用")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 60, alignment: .leading)
                Toggle("参与发射", isOn: Binding(
                    get: { 源.启用 },
                    set: { 新 in 改源(源.id) { $0.启用 = 新 } }
                ))
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
                Spacer()
            }
            HStack(spacing: 8) {
                Text("几何")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 60, alignment: .leading)
                Menu {
                    ForEach(MeshKind.可当发射体, id: \.self) { 形状 in
                        Button(形状.title) {
                            改源(源.id) { $0.形状 = 形状; $0.导入网格ID = nil }
                        }
                    }
                    if !场景模型.isEmpty {
                        Divider()
                        ForEach(场景模型, id: \.网格ID) { 模型 in
                            Button(模型.名称) {
                                改源(源.id) { $0.形状 = .torus; $0.导入网格ID = 模型.网格ID }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: 源.图标).font(.system(size: 10))
                        Text(源.形状名).font(.system(size: 11))
                        Image(systemName: "chevron.down").font(.system(size: 8))
                    }
                    .foregroundStyle(Theme.textPrimary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Spacer()
            }
        }
    }

    private func 材质组(_ 源: 特效发射源) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            组标题("材质（只影响身份识别，外观由火的参数决定）")
            HStack(spacing: 8) {
                if let 材质ID = 源.材质ID, let 材质 = shading.material(材质ID) {
                    Circle()
                        .fill(Theme.color(from: 材质.previewColor))
                        .frame(width: 12, height: 12)
                        .overlay(Circle().stroke(Theme.stroke, lineWidth: 0.5))
                    Text(材质.name)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                } else {
                    Text("未指定")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                Menu {
                    Button("不指定") { 改源(源.id) { $0.材质ID = nil } }
                    Divider()
                    ForEach(shading.库材质列表) { 素材 in
                        Button(素材.name) { 改源(源.id) { $0.材质ID = 素材.id } }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("选择材质").font(.system(size: 11))
                        Image(systemName: "chevron.down").font(.system(size: 8))
                    }
                    .foregroundStyle(Theme.textSecondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }

    private func 变换组(_ 源: 特效发射源) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            组标题("在容器里的位置（容器一动，源跟着动）")
            轴行("位置", 值: 源.位置) { 新 in 改源(源.id) { $0.位置 = 新 } }
            轴行("旋转", 值: 源.旋转) { 新 in 改源(源.id) { $0.旋转 = 新 } }
            轴行("缩放", 值: 源.缩放) { 新 in 改源(源.id) { $0.缩放 = 新 } }
            HStack(spacing: 8) {
                Button("缩放归 1") { 改源(源.id) { $0.缩放 = .one } }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textSecondary)
                Button("旋转归零") { 改源(源.id) { $0.旋转 = .zero } }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textSecondary)
                Button("位置归零") { 改源(源.id) { $0.位置 = .zero } }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
            }
        }
    }

    private var 提示组: some View {
        VStack(alignment: .leading, spacing: 4) {
            Rectangle().fill(Theme.divider).frame(height: 1)
            Text("火/烟/粒子/水的发射率、寿命、颜色这些，仍然在 N 面板的特效页里调。")
            Text("容器只是把这些发射体收进一个节点里，方便选择和整体搬动。")
        }
        .font(.system(size: 10))
        .foregroundStyle(Theme.textTertiary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 2)
    }

    private func 组标题(_ 文: String) -> some View {
        Text(文)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Theme.textTertiary)
    }

    /// 一行三格数值（X/Y/Z），复用变换那套输入框：回车提交、失焦也提交
    private func 轴行(_ 标题: String, 值: Vec3, 提交: @escaping (Vec3) -> Void) -> some View {
        HStack(spacing: 8) {
            Text(标题)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 60, alignment: .leading)
            变换数值输入(值: 值.x) { 新 in 提交(Vec3(新, 值.y, 值.z)) }
            变换数值输入(值: 值.y) { 新 in 提交(Vec3(值.x, 新, 值.z)) }
            变换数值输入(值: 值.z) { 新 in 提交(Vec3(值.x, 值.y, 新)) }
        }
    }
}

// MARK: - 小工具

extension MeshKind {
    /// 能当发射体用的程序网格（平面太薄，做发射体没意义，排除掉）
    static var 可当发射体: [MeshKind] {
        [.torus, .sphere, .cube, .cylinder, .shaderBall]
    }
}
