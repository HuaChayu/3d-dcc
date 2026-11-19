import AppKit
import SwiftUI

// MARK: - 改名输入框

/// 材质改名框：回车提交，**点框外任何地方也提交** —— 面板空白、别的控件、视口都算。
///
/// 只靠 `@FocusState` 不够：macOS 上点窗口里的纯空白区域不会让文本框主动 resignFirstResponder，
/// 焦点一直挂着、`onChange(of: 聚焦)` 就不触发，用户点半天也没生效。
/// 所以额外挂一条本地左键监视器：按下位置不在输入框里就当场提交，事件原样放行、不吞点击。
private struct 改名输入框: View {
    @Binding var 文本: String
    var 提交: () -> Void

    @FocusState private var 聚焦: Bool
    @State private var 框: CGRect = .zero
    @State private var 监视器: Any?

    var body: some View {
        TextField("材质名", text: $文本)
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .focused($聚焦)
            .onSubmit { 提交() }
            .onChange(of: 聚焦) { _, 在 in if !在 { 提交() } }
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { 框 = geo.frame(in: .global) }
                        .onChange(of: geo.frame(in: .global)) { _, 新 in 框 = 新 }
                }
            )
            .onAppear {
                聚焦 = true
                装监视器()
            }
            .onDisappear { 卸监视器() }
    }

    private func 装监视器() {
        guard 监视器 == nil else { return }
        监视器 = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { 事件 in
            if !落在框内(事件) { 提交() }
            return 事件
        }
    }

    private func 卸监视器() {
        if let 监视器 { NSEvent.removeMonitor(监视器) }
        监视器 = nil
    }

    /// 把鼠标位置换算到 SwiftUI 的 `.global` 坐标（内容区左上、y 向下）再判命中。
    /// 判定区放宽 2pt，贴着边框点也算在框里。
    private func 落在框内(_ 事件: NSEvent) -> Bool {
        guard let 内容 = 事件.window?.contentView else { return false }
        let 点 = 事件.locationInWindow
        let 换算 = CGPoint(x: 点.x, y: 内容.bounds.height - 点.y)
        return 框.insetBy(dx: -2, dy: -2).contains(换算)
    }
}

// MARK: - OpenPBR 检查器

/// 参数按 OpenPBR Surface 1.0 的层组织，每个键直接对应官方 shader input 名。
struct MaterialInspector: View {
    @Environment(着色Store.self) private var store
    @Environment(布局Store.self) private var scene

    @State private var expanded: Set<PBRParamLayer> = [.base, .specular, .coat, .transmission]
    @State private var renameText: String = ""
    @State private var isRenaming = false

    private var material: MaterialAsset? { store.activeMaterial }
    /// 只有「材质球库」那一页是陈列：只给看，参数区整片禁用。
    /// 本项目页 / 材质节点页照常可编辑，不按材质出身连坐。
    private var 库页只读: Bool { store.底栏页 == .库 }

    private var 只读提示条: some View {
        HStack(spacing: 6) {
            Image(systemName: "eye")
            Text("材质库里的材质只预览 · 拖给物体或右键「复制材质」后再调")
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .padding(8)
        .background(Theme.divider, in: RoundedRectangle(cornerRadius: 8))
    }
    /// 一次 body 只解析一次：以前每行参数各自访问都会重新 resolve（几十行 × 每次深比较 + 图求值），
    /// 拖着滑条每帧要跑几十遍，主线程被占满，Slider 的手势就丢帧、thumb 不跟手。
    private var resolved: ResolvedMaterial { MaterialCompiler.resolve(material) }

    var body: some View {
        if let object = scene.selectedObject, let 灯 = object.灯光 {
            // 选中灯时面板换成灯光参数：灯没有材质可调
            LightInspector(objectID: object.id, 设置: 灯)
        } else {
            materialPanel
        }
    }

    private var materialPanel: some View {
        let 解析 = resolved
        return VStack(spacing: 0) {
            PanelHeader(title: "OpenPBR 检查器", symbol: "slider.horizontal.3") {
                Menu {
                    Button("新建材质") { store.addMaterial() }
                    if let material {
                        Button("复制当前材质") { store.duplicateMaterial(material.id) }
                        if material.是否库条目 {
                            // 库条目删的是本地 .cgmat；内置预设是出厂数据、没有文件，不给删
                            if !material.是内置预设 {
                                Divider()
                                Button("从材质库删除（连同本地文件）", role: .destructive) {
                                    store.删除库材质(material.id)
                                }
                            }
                        } else {
                            Divider()
                            Button("从本项目删除", role: .destructive) {
                                store.deleteMaterial(material.id)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 12))
                }
                .menuStyle(.borderlessButton)
                .frame(width: 26)
            }

            if material != nil {
                materialHeader(解析)
                Divider().opacity(0.4)
                ScrollView {
                    VStack(spacing: 10) {
                        objectBindingRow
                        if 库页只读 { 只读提示条 }
                        Group {
                            ForEach(PBRParamLayer.allCases) { layer in
                                layerSection(layer, 解析)
                            }
                            viewportGapSection(解析)
                        }
                        // 材质库里的材质是模板 / 出厂数据，只预览：参数控件整片禁用，
                        // 不再是「一拖就派生成另一个材质」那种看着像自己跑掉的体验
                        .disabled(库页只读)
                        .opacity(库页只读 ? 0.55 : 1)
                        Spacer(minLength: 20)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
            } else {
                ContentUnavailableView("没有材质", systemImage: "circle.dashed")
            }
        }
        .background(Theme.inspectorBackground)
        // 换了材质就把改名框收起来：留着的话输入框里还是上一颗材质的名字，
        // 一回车就把它写到新材质头上。改名进行中切材质就是要放弃这次改名。
        .onChange(of: material?.id) { _, _ in isRenaming = false }
    }

    // MARK: 材质头

    private func materialHeader(_ resolved: ResolvedMaterial) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                材质球缩略图(resolved: resolved, 签名: 材质缩略图键.key(resolved), 尺寸: 26, 渲染尺寸: 96)
                    .frame(width: 26, height: 26)

                if isRenaming {
                    改名输入框(文本: $renameText, 提交: commitRename)
                } else {
                    Text(material?.name ?? "")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .onTapGesture {
                            // 库条目不许就地改名：名字也是它本体的一部分
                            guard !库页只读 else { return }
                            renameText = material?.name ?? ""
                            isRenaming = true
                        }
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 6) {
                Text("\(resolved.drivenKeys.count) 项图驱动")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text("·")
                    .foregroundStyle(.quaternary)
                Text("节点 \(material?.graph.nodes.count ?? 0) / 连线 \(material?.graph.links.count ?? 0)")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        .padding(.top, 2)
    }

    /// 回车 / 失焦 / 点框外三路都走这里，所以必须幂等：
    /// 第一条先落下 `isRenaming = false` 把输入框收掉，后到的直接返回，不会写两遍。
    private func commitRename() {
        guard isRenaming else { return }
        isRenaming = false
        guard let 当前 = material else { return }
        let 新名 = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !新名.isEmpty, 新名 != 当前.name else { return }
        store.renameMaterial(当前.id, to: 新名)
    }

    // MARK: 物体绑定

    private var objectBindingRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            SectionTitle(text: "当前物体", trailing: scene.selectedObject.map { (几何接线.共享.取值(键: $0.id.uuidString)?.程序网格形状 ?? $0.mesh).title })
            if let object = scene.selectedObject {
                HStack(spacing: 6) {
                    Text(object.name)
                        .font(.system(size: 11))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Menu {
                        ForEach(store.库材质列表) { item in
                            Button(item.name) {
                                // 选库里的材质 = 给物体挂一份原始样式实例
                                scene.assign(store.实例ID(for: item.id), to: object.id)
                            }
                        }
                        Divider()
                        Button("解除绑定") { scene.assign(nil, to: object.id) }
                    } label: {
                        Text(store.material(object.materialID)?.name ?? "未绑定")
                            .font(.system(size: 10.5))
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 120)
                }
            } else {
                Text("在视口中选择物体")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(9)
        .background(Theme.divider, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: 层

    private func layerSection(_ layer: PBRParamLayer, _ resolved: ResolvedMaterial) -> some View {
        let keys = PBRParamKey.allCases.filter { $0.layer == layer }
        let isOpen = expanded.contains(layer)

        return VStack(spacing: 0) {
            Button {
                if isOpen { expanded.remove(layer) } else { expanded.insert(layer) }
            } label: {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Theme.layerTint(layer))
                        .frame(width: 3, height: 11)
                    Text(layer.title)
                        .font(.system(size: 11, weight: .semibold))
                    Spacer(minLength: 4)
                    Text("\(keys.count)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
                .padding(.vertical, 5)
            }
            .buttonStyle(.plain)

            if isOpen {
                VStack(spacing: 9) {
                    ForEach(keys) { key in
                        paramRow(key, resolved)
                    }
                }
                .padding(.bottom, 6)
            }

            Divider().opacity(0.25)
        }
    }

    private func paramRow(_ key: PBRParamKey, _ resolved: ResolvedMaterial) -> some View {
        let driven = resolved.drivenKeys.contains(key)
        let value = resolved.params[key]
        // 手调永远优先：写入时会摘掉这条参数的驱动边，所以滑条一律可拖、不按驱动置灰。
        // （旧版按 driven && !模板 置灰，结果第一次改动把模板变实例后，滑条在拖动途中被 disabled，
        //   SwiftUI 会立刻取消这一次 DragGesture —— 这就是"材质在变但滑条不跟手、拉不动"的真正原因。）

        return VStack(alignment: .leading, spacing: 3) {
            ParamHeader(key: key, driven: driven)

            if key.isColor {
                HStack(spacing: 8) {
                    ColorPicker(
                        "",
                        selection: Binding(
                            get: { Theme.color(from: value.colorValue) },
                            set: { store.setParam(key, value: .color(Theme.pbr(from: $0))) }
                        ),
                        supportsOpacity: false
                    )
                    .labelsHidden()
                    .controlSize(.small)

                    Text(String(format: "%.3f, %.3f, %.3f",
                                value.colorValue.r, value.colorValue.g, value.colorValue.b))
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                }
            } else {
                ParamSlider(
                    label: key.title,
                    value: value.scalarValue,
                    range: key.range,
                    onChange: { store.setParam(key, value: .scalar($0)) }
                )
            }

            if driven, let source = driverLabel(for: key) {
                Text((material?.是否库条目 ?? false) ? "← \(source)（手调会派生成新实例）" : "← \(source)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Theme.layerTint(key.layer).opacity(0.85))
            }
        }
        .help("\(key.opName) · 默认 \(key.defaultValue.summary)")
    }

    /// 找到驱动该参数的来源节点，检查器里直接标出来，省得回节点区找
    private func driverLabel(for key: PBRParamKey) -> String? {
        guard let graph = material?.graph,
              let output = graph.outputNode,
              let link = graph.link(into: output.id, socket: key.rawValue),
              let node = graph.node(link.fromNode) else { return nil }
        return "\(node.displayTitle) › \(link.fromSocket)"
    }

    // MARK: 视口缺口

    private func viewportGapSection(_ resolved: ResolvedMaterial) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(text: "视口未支持", trailing: "\(resolved.viewportGaps.count) 项")
            if resolved.viewportGaps.isEmpty {
                Text("当前参数全部可在视口近似表达")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            } else {
                FlowText(
                    items: resolved.viewportGaps.map(\.title),
                    tint: .orange
                )
                Text("这些参数已参与求值并写入材质，但 RealityKit 视口没有对应通道——切到「渲染」工作区查看差异清单。")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(9)
        .background(Color.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.14), lineWidth: 1)
        )
    }
}

// MARK: - 简易标签流

struct FlowText: View {
    var items: [String]
    var tint: Color

    var body: some View {
        // 参数名短，用 LazyVGrid 自适应即可，不必真做换行测量
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 4)], alignment: .leading, spacing: 4) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.system(size: 9, design: .monospaced))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(tint)
                    .lineLimit(1)
            }
        }
    }
}
