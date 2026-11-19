import SwiftUI

// MARK: - 节点卡片

/// 一张卡片 = 一个 shader 节点。端口位置必须与 NodeLayout 完全一致，否则连线会飘。
struct NodeCard: View {
    var node: ShaderNode
    var isSelected: Bool
    /// 该节点是否真的接进了 Output（没接的话改参数不会影响模型，卡片上直说）
    var isGraphDriven: Bool = true
    var resolveIncoming: (String) -> NodeLink?

    var onSelect: () -> Void
    var onOpenInspector: () -> Void
    var onDragHeader: (CGSize) -> Void
    var onDragEnd: (CGSize) -> Void
    var onValueChange: (String, PBRValue) -> Void
    var onToggleMute: () -> Void
    var onDelete: () -> Void
    var onStartLink: (String, SocketKind, Bool, CGPoint) -> Void
    var onDragLink: (CGPoint) -> Void
    var onEndLink: (CGPoint) -> Void
    /// 单一真源：Output 节点的输入口不存自己的 params，值直接来自材质基线（检查器同一份）。
    /// 传 nil 时回落到节点自身 params，常量类节点行为不变。
    var portValue: ((String) -> PBRValue)? = nil
    /// 当前项目里的全部贴图（按登记顺序）。图像贴图节点上方的「更换贴图」直接吃这份清单。
    var textureIDs: [UUID] = []
    var imageLoader: ((UUID) -> CGImage?)? = nil
    /// 图像节点在链路里的实际样子（调色已经烘进去）。走这条路，预览和视口才是同一张图。
    var 预览图: (() -> CGImage?)? = nil
    /// 链路签名：调色参数一动，卡片就得重画预览
    var 调制签名: String = ""
    var onPickImage: (UUID?) -> Void = { _ in }
    /// 入线签名：只参与 Equatable 短路判断（连线增删要刷新端口行），不参与渲染。
    var 入线签名: String = ""
    /// 描边用不用强调色。这里是外部读好的值而不是在 body 里读偏好 store，
    /// 否则偏好在 body 求值期被追踪，Equatable 短路后切偏好不刷新。
    var 强调选中: Bool = false

    @State private var 换图展开 = false
    /// 预览图缓存盒（引用类型，写在 body 求值期也不触发状态更新）
    @State private var 预览盒 = 预览缓存盒()

    private let headerHeight: CGFloat = 30
    private let rowHeight: CGFloat = 22
    private let pad: CGFloat = 10
    /// 图像贴图节点的预览面板总高（62 预览 + 5 间距 + 22 动效下拉 + 5 间距 + 21 按钮 + 6 底距），与 NodeLayout 的 imagePanel 同名同值
    private let imagePanelHeight: CGFloat = 62 + 5 + 22 + 5 + 21 + 6

    private var tint: Color { Theme.categoryTint(node.kind.category) }

    var body: some View {
        VStack(spacing: 0) {
            header

            if node.kind == .imageTexture { imagePanel }

            VStack(spacing: 0) {
                if node.kind == .rgbConstant { constantColorRow }
                if node.kind == .valueConstant { constantValueRow }

                ForEach(Array(node.kind.outputs.enumerated()), id: \.element.id) { index, socket in
                    outputRow(socket, index: index)
                }
                ForEach(Array(node.kind.inputs.enumerated()), id: \.element.id) { index, socket in
                    inputRow(socket, index: index)
                }
            }
            .padding(.vertical, pad)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            // 整张卡片垫一层透明拖动带（在内容之下、圆角背景之上）：
            // 只有真正吃事件的控件（按钮、数值拖动条、端口圆点）会挡住它，
            // 于是标题、预览图、端口行之间的空隙、底部留白都能按住拖节点。
            Rectangle()
                .fill(Color.white.opacity(0.001))
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 1, coordinateSpace: .named(CanvasSpace.name))
                        .onChanged { value in onDragHeader(value.translation) }
                        .onEnded { value in onDragEnd(value.translation) }
                )
        }
        .background(
            RoundedRectangle(cornerRadius: Theme.nodeRadius)
                .fill(Theme.nodeBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.nodeRadius)
                .stroke(
                    isSelected ? Theme.accent : Theme.stroke,
                    lineWidth: isSelected ? (强调选中 ? 2.0 : 1.4) : 1
                )
        )
        .overlay(alignment: .top) {
            // 顶部色条：一眼分辨节点类别
            UnevenRoundedRectangle(
                topLeadingRadius: Theme.nodeRadius,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: Theme.nodeRadius
            )
            .fill(tint.opacity(node.isMuted ? 0.15 : 0.55))
            .frame(height: 2)
        }
        .opacity(node.isMuted ? 0.55 : 1)
        .shadow(color: .black.opacity(isSelected ? 0.35 : 0.18), radius: isSelected ? 8 : 4, y: 2)
        .onTapGesture(count: 2) { onOpenInspector() }
        // 双击和单击共存时，系统必须等双击判定超时（约 0.3s）才派发单击 ——
        // 这就是"点了半天才出选中框"的直接来源。改成按下（minimumDistance 0 的 onChanged）
        // 立刻选中，跟手；双击照旧打开检查器，两者互不影响。
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in onSelect() }
        )
        .contextMenu {
            Button("编辑参数…") { onOpenInspector() }
            Button(node.isMuted ? "启用节点" : "旁路节点") { onToggleMute() }
            Button("删除节点", role: .destructive) { onDelete() }
                .disabled(node.kind == .output)
        }
    }

    // MARK: 头部

    private var header: some View {
        HStack(spacing: 5) {
            // 只有图标+标题参与拖动，右侧按钮才点得动（否则 DragGesture 会吞掉按钮点击）
            HStack(spacing: 5) {
                Image(systemName: node.kind.symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tint)
                Text(node.displayTitle)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(height: headerHeight, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named(CanvasSpace.name))
                    .onChanged { value in onDragHeader(value.translation) }
                    .onEnded { value in onDragEnd(value.translation) }
            )
            .onTapGesture(count: 2) { onOpenInspector() }
            .onTapGesture { onSelect() }
            if node.kind != .output {
                // 明显的可点入口：双击卡片任意位置也能打开同一面板
                Button(action: onOpenInspector) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("打开节点参数")
            }
            if node.kind != .output && !isGraphDriven {
                Text("未接入")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
                    .help("该节点没有接到「OpenPBR 输出」，改参数不会影响模型")
            }
            if node.kind == .output {
                Text("输出端")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(tint.opacity(0.8))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: headerHeight)
        .background(Theme.nodeHeader)
    }

    // MARK: 图像贴图（预览 + 换图）

    /// 取卡片预览，按「链路签名」缓存。
    ///
    /// 取一次要编译整条上游子图，还可能现场烘焙一张纹理；而卡片只要被选中、描边、鼠标进出，
    /// body 就会重算一遍。以前每次重算都现取，于是「按住节点开始拖」的那一下要顺带把烘焙重做，
    /// 手感就是起步卡一下，拖起来才顺。现在签名没变直接用缓存图。
    /// 只缓存取到图的结果：图还没烘焙好时留空，下一帧继续问，不会把空结果焊死。
    private func 取预览() -> CGImage? {
        let 盒 = 预览盒
        if 盒.签名 == 调制签名, let 图 = 盒.图 { return 图 }
        let 图 = 预览图?() ?? node.image.flatMap { imageLoader?($0) }
        if let 图 {
            盒.签名 = 调制签名
            盒.图 = 图
        }
        return 图
    }

    /// 图像贴图节点：上边一块贴图预览，下边一条「更换贴图」框。
    /// 框里直接列当前项目的全部贴图（张数就印在按钮上），点一张就地换掉，
    /// 不用回参数面板重新选文件。
    private var imagePanel: some View {
        VStack(spacing: 5) {
            // 尺寸由 Rectangle 定死，图片走 overlay —— 图片自己带原图尺寸，
            // 直接摆进 ZStack 会把卡片撑到几万点宽，标题连着手势区一起被挤出可见范围。
            Rectangle()
                .fill(Theme.fieldBackground)
                .frame(height: 62)
                .frame(maxWidth: .infinity)
                .overlay {
                    if let cg = 取预览() {
                        // 静帧 + 时间驱动形变：下拉选了哪一项，预览就按哪一项动
                        图像动效预览(图: cg, 动效: node.图像动效值)
                    } else {
                        VStack(spacing: 3) {
                            Image(systemName: "photo")
                                .font(.system(size: 15, weight: .light))
                            Text("未选贴图")
                                .font(.system(size: 9))
                        }
                        .foregroundStyle(Theme.textSecondary)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(Theme.stroke.opacity(0.8), lineWidth: 0.8)
                )
                // 预览本身不吃鼠标事件，按住预览就能直接拖节点
                .allowsHitTesting(false)

            动效行

            Button {
                换图展开 = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "photo.stack")
                        .font(.system(size: 9, weight: .semibold))
                    Text("更换贴图")
                        .font(.system(size: 9.5, weight: .medium))
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    Text("项目 \(textureIDs.count)")
                        .font(.system(size: 8.5, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(Theme.textSecondary)
                }
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 6)
                .frame(height: 21)
                .frame(maxWidth: .infinity)
                .background(Theme.fieldBackground, in: RoundedRectangle(cornerRadius: 5))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(Theme.stroke.opacity(0.8), lineWidth: 0.8)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("从当前项目的贴图里挑一张换掉这个节点（共 \(textureIDs.count) 张）")
            .popover(isPresented: $换图展开, arrowEdge: .top) { 贴图选择板 }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }

    /// 图像节点唯一的可调项：动效下拉。
    /// 以前这里是「基色」颜色输入口 —— 贴图本身就是复合颜色，再插一个颜色毫无意义，
    /// 换成让这张图动起来的选项，选中即写回 params["anim"]，预览立刻跟着动。
    private var 动效行: some View {
        Menu {
            ForEach(图像动效.allCases) { 效果 in
                Button {
                    onValueChange(图像动效.paramKey, .scalar(Double(效果.rawValue)))
                } label: {
                    Label(效果.title, systemImage: 效果 == node.图像动效值 ? "checkmark" : 效果.symbol)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: node.图像动效值.symbol)
                    .font(.system(size: 9, weight: .semibold))
                Text(node.图像动效值.title)
                    .font(.system(size: 9.5, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 2)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 6)
            .frame(height: 22)
            .frame(maxWidth: .infinity)
            .background(Theme.fieldBackground, in: RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Theme.stroke.opacity(0.8), lineWidth: 0.8)
            )
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("给这张图加动效：火焰扰动 / 水面波动 / 旋转 / 漂移 / 呼吸 / 涟漪，预览实时播放")
    }

    private var 贴图选择板: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Text("当前项目贴图")
                    .font(.system(size: 11, weight: .semibold))
                Spacer(minLength: 0)
                Text("\(textureIDs.count) 张")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            if textureIDs.isEmpty {
                Text("项目里还没有贴图")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.fixed(52), spacing: 6), count: 4),
                        spacing: 6
                    ) {
                        ForEach(textureIDs, id: \.self) { id in
                            贴图格(id)
                        }
                    }
                    .padding(.vertical, 1)
                }
                .frame(width: 232, height: min(CGFloat((textureIDs.count + 3) / 4) * 58, 232))
            }
            if node.image != nil {
                Button("清空这个节点的贴图") {
                    onPickImage(nil)
                    换图展开 = false
                }
                .buttonStyle(.plain)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }
        }
        .padding(10)
    }

    private func 贴图格(_ id: UUID) -> some View {
        Button {
            onPickImage(id)
            换图展开 = false
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Theme.fieldBackground)
                if let cg = imageLoader?(id) {
                    Image(decorative: cg, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                }
            }
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(
                        node.image == id ? Theme.accent : Theme.stroke.opacity(0.8),
                        lineWidth: node.image == id ? 2 : 0.8
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(node.image == id ? "当前使用的贴图" : "换成这张")
    }

    // MARK: 常量节点

    private var constantColorRow: some View {
        HStack {
            Text("颜色")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 2)
            colorWell(for: "color")
        }
        .padding(.horizontal, 10)
        .frame(height: rowHeight)
    }

    private var constantValueRow: some View {
        HStack {
            Text("数值")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 2)
            ScalarScrub(
                value: node.value(for: "value").scalarValue,
                range: 0...1,
                onChange: { onValueChange("value", .scalar($0)) }
            )
        }
        .padding(.horizontal, 10)
        .frame(height: rowHeight)
    }

    // MARK: 端口行

    private func outputRow(_ socket: NodeSocket, index: Int) -> some View {
        HStack(spacing: 4) {
            Spacer(minLength: 0)
            Text(socket.title)
                .font(.system(size: 9.5))
                .foregroundStyle(Theme.textSecondary)
                .allowsHitTesting(false)
            portDot(socket: socket, isOutput: true)
        }
        .padding(.leading, 10)
        .frame(height: rowHeight)
    }

    private func inputRow(_ socket: NodeSocket, index: Int) -> some View {
        HStack(spacing: 4) {
            portDot(socket: socket, isOutput: false)
            Text(socket.title)
                .font(.system(size: 9.5))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .layoutPriority(1)
                .allowsHitTesting(false)
            Spacer(minLength: 2)

            if let link = resolveIncoming(socket.id), let from = sourceLabel(link) {
                Text(from)
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(Theme.categoryTint(.input).opacity(0.85))
                    .lineLimit(1)
                    .allowsHitTesting(false)
            } else if socket.kind == .color {
                colorWell(for: socket.id)
            } else {
                ScalarScrub(
                    value: currentValue(socket.id).scalarValue,
                    range: socketRange(socket),
                    onChange: { onValueChange(socket.id, .scalar($0)) },
                    compact: true
                )
            }
        }
        .padding(.leading, 2)
        .padding(.trailing, 10)
        .frame(height: rowHeight)
    }

    private func portDot(socket: NodeSocket, isOutput: Bool) -> some View {
        Circle()
            .fill(Theme.layerTint(socket.paramKey?.layer ?? .base).opacity(0.9))
            .frame(width: 7, height: 7)
            .overlay(Circle().stroke(Color.black.opacity(0.5), lineWidth: 0.5))
            .frame(width: 15, height: rowHeight)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named(CanvasSpace.name))
                    .onChanged { value in
                        if !isDragging(socket: socket.id, isOutput: isOutput) {
                            beginDrag(socket: socket, isOutput: isOutput, at: value.startLocation)
                        }
                        onDragLink(value.location)
                    }
                    .onEnded { value in
                        onEndLink(value.location)
                        endDrag()
                    }
            )
            .help("\(socket.title) · \(socket.kind.title)")
    }

    // MARK: 拖动状态（避免重复触发 onStartLink）

    @State private var draggingSocket: String?

    private func isDragging(socket: String, isOutput: Bool) -> Bool {
        draggingSocket == "\(isOutput ? "o" : "i"):\(socket)"
    }

    private func beginDrag(socket: NodeSocket, isOutput: Bool, at point: CGPoint) {
        draggingSocket = "\(isOutput ? "o" : "i"):\(socket.id)"
        onStartLink(socket.id, socket.kind, isOutput, point)
    }

    private func endDrag() { draggingSocket = nil }

    // MARK: 控件

    /// 端口当前值：优先外部真源（Output 口 = 材质基线），否则节点自身 params
    private func currentValue(_ socket: String) -> PBRValue {
        portValue?(socket) ?? node.value(for: socket)
    }

    private func colorWell(for socket: String) -> some View {
        let color = currentValue(socket).colorValue
        return ColorPicker(
            "",
            selection: Binding(
                get: { Theme.color(from: color) },
                set: { onValueChange(socket, .color(Theme.pbr(from: $0))) }
            ),
            supportsOpacity: false
        )
        .labelsHidden()
        .controlSize(.mini)
        .frame(width: 30)
    }

    private func socketRange(_ socket: NodeSocket) -> ClosedRange<Double> {
        // 卡片上直接拖的那些数值也一样：色相是度、饱和度是倍率，不能一律 0…1
        if let 范围 = node.kind.参数范围(socket.id) { return 范围 }
        guard let key = socket.paramKey else {
            return 0...1
        }
        return key.range
    }

    private func sourceLabel(_ link: NodeLink) -> String? {
        // 由外部传 graph 才能解析来源名，这里用端口名兜底
        link.fromSocket
    }
}

// MARK: - 数值拖拽（DCC 风格：横向拖动改值，双击可回中）

struct ScalarScrub: View {
    var value: Double
    var range: ClosedRange<Double>
    var onChange: (Double) -> Void
    var compact: Bool = false

    @State private var startValue: Double?
    /// 拖动过程中的本地值：数字先按手走，等上游真值追上来再交还。
    /// 卡片上这个数来自材质图，写完参数要等一次界面刷新才回到这里；盯着外部值显示，
    /// 手感就是「材质变了、数字不动」——和检查器滑条当初那个毛病一模一样。
    @State private var 拖动值: Double?

    private var 显示值: Double { 拖动值 ?? value }

    var body: some View {
        Text(format(显示值))
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundStyle(Theme.textPrimary)
            .lineLimit(1)
            .padding(.horizontal, compact ? 4 : 6)
            .padding(.vertical, 2)
            .frame(minWidth: compact ? 38 : 52, alignment: .trailing)
            .background(Theme.fieldBackground, in: RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4).stroke(Theme.stroke.opacity(0.7), lineWidth: 0.8)
            )
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if startValue == nil { startValue = value }
                        guard let start = startValue else { return }
                        let span = range.upperBound - range.lowerBound
                        let delta = Double(gesture.translation.width) * span / 240.0
                        let next = min(range.upperBound, max(range.lowerBound, start + delta))
                        拖动值 = next
                        onChange(next)
                    }
                    .onEnded { _ in startValue = nil }
            )
            // 不在拖动时以真值说了算：松手后真值追上来、或别处（检查器 / 撤销）改了值，本地值让位
            .onChange(of: value) { _, _ in
                if startValue == nil { 拖动值 = nil }
            }
            .help("横向拖动调整数值")
    }

    private func format(_ v: Double) -> String {
        if range.upperBound > 50 { return String(format: "%.0f", v) }
        return String(format: "%.\(偏好设置Store.shared.数值小数位)f", v)
    }
}

// MARK: - 拖动性能

/// 拖节点时 graph.nodes 每帧都在变，整块画布会重算，ForEach 里的卡片也都会被重新构造。
/// 这里按「影响外观的字段」短路：只有被拖的那张、选中态变化的、连线/贴图清单变化的卡片才真重算 body，
/// 其余卡片留着缓存，拖动才不会一路掉帧。
extension NodeCard: Equatable {
    static func == (a: NodeCard, b: NodeCard) -> Bool {
        // Output 卡片的值来自材质基线（portValue 闭包），node 自身不变也要跟着刷新
        if a.node.kind == .output || b.node.kind == .output { return false }
        return a.node == b.node
            && a.isSelected == b.isSelected
            && a.isGraphDriven == b.isGraphDriven
            && a.入线签名 == b.入线签名
            && a.强调选中 == b.强调选中
            && a.textureIDs.count == b.textureIDs.count
            && (a.imageLoader == nil) == (b.imageLoader == nil)
            && a.调制签名 == b.调制签名
    }
}

// MARK: - 图像动效预览

/// 图像贴图节点的预览：静帧 + 时间驱动形变。
/// 选「不动」时 TimelineView 是 paused 的，定时器根本不跑；
/// 选了效果之后只重绘这一小块画布，父卡片与整块节点画布不参与，拖动画布不会因此掉帧。
struct 图像动效预览: View {
    var 图: CGImage
    var 动效: 图像动效

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !动效.有动画)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                绘制(&ctx, 尺寸: size, 时间: t)
            }
        }
    }

    private func 绘制(_ ctx: inout GraphicsContext, 尺寸 size: CGSize, 时间 t: Double) {
        guard size.width > 1, size.height > 1 else { return }
        let box = CGRect(origin: .zero, size: size)
        let img = Image(decorative: 图, scale: 1)

        if !动效.有动画 {
            ctx.draw(img, in: 填充矩形(in: box, 放大: 1))
            return
        }

        // 先铺底色：旋转 / 外扩类效果转起来时四角露的是这个颜色，不是透明
        ctx.fill(Path(box), with: .color(Theme.fieldBackground))

        switch 动效 {
        case .无:
            ctx.draw(img, in: box)

        case .火焰扰动:
            // 越靠上横摆越大，再叠一层高频细波 —— 像火苗往上蹿
            切片绘制(&ctx, img: img, 底图: 填充矩形(in: box, 放大: 1.16), box: box, 条数: 26) { 离底 in
                let 大波 = sin(离底 * 9.0 - t * 4.6) * 3.4 * 离底
                let 细波 = sin(离底 * 24.0 + t * 7.9) * 1.2 * 离底
                return CGSize(width: 大波 + 细波, height: -离底 * 2.0 * (0.5 + 0.5 * sin(t * 3.1)))
            }
            // 顶部叠一层暖色上浮，火感更足
            ctx.blendMode = .plusLighter
            ctx.fill(Path(box), with: .linearGradient(
                Gradient(colors: [.clear, Color(red: 1.0, green: 0.42, blue: 0.10).opacity(0.20)]),
                startPoint: CGPoint(x: box.midX, y: box.maxY),
                endPoint: CGPoint(x: box.midX, y: box.minY)
            ))
            ctx.blendMode = .normal

        case .水面波动:
            切片绘制(&ctx, img: img, 底图: 填充矩形(in: box, 放大: 1.16), box: box, 条数: 24) { 离底 in
                CGSize(width: sin(离底 * 11.0 + t * 2.4) * 3.2,
                       height: cos(离底 * 7.0 - t * 1.7) * 1.4)
            }

        case .旋转:
            ctx.translateBy(x: box.midX, y: box.midY)
            ctx.rotate(by: .radians(t * 0.55))
            ctx.translateBy(x: -box.midX, y: -box.midY)
            ctx.draw(img, in: 填充矩形(in: box, 放大: 1.5))

        case .漂移:
            ctx.translateBy(x: sin(t * 0.55) * size.width * 0.06,
                            y: cos(t * 0.43) * size.height * 0.05)
            ctx.draw(img, in: 填充矩形(in: box, 放大: 1.16))

        case .呼吸:
            let s = 1.0 + 0.05 * sin(t * 1.8)
            ctx.translateBy(x: box.midX, y: box.midY)
            ctx.scaleBy(x: s, y: s)
            ctx.translateBy(x: -box.midX, y: -box.midY)
            ctx.draw(img, in: 填充矩形(in: box, 放大: 1.06))
            ctx.blendMode = .plusLighter
            ctx.fill(Path(box), with: .color(.white.opacity(0.05 + 0.05 * sin(t * 1.8))))
            ctx.blendMode = .normal

        case .涟漪:
            // 以画面中心为圆心向外的环状波纹
            切片绘制(&ctx, img: img, 底图: 填充矩形(in: box, 放大: 1.16), box: box, 条数: 24) { 离底 in
                let 到中心 = (离底 - 0.5) * 2.0
                let 波 = sin(到中心 * 9.0 - t * 3.2) * 2.8
                return CGSize(width: 波, height: 波 * 0.45)
            }
        }
    }

    /// 逐条横切片绘制：每条按自己的偏移量画一遍整图，再由 clip 裁成一条 —— 便宜的伪扭曲
    private func 切片绘制(
        _ ctx: inout GraphicsContext,
        img: Image,
        底图: CGRect,
        box: CGRect,
        条数: Int,
        _ 偏移: (Double) -> CGSize
    ) {
        let 条高 = box.height / CGFloat(条数)
        for i in 0..<条数 {
            var 条 = ctx
            let y = box.minY + CGFloat(i) * 条高
            条.clip(to: Path(CGRect(x: box.minX, y: y, width: box.width, height: 条高 + 1)))
            // 0 = 底边，1 = 顶边
            let 离底 = 1.0 - (Double(i) + 0.5) / Double(条数)
            let d = 偏移(离底)
            条.translateBy(x: d.width, y: d.height)
            条.draw(img, in: 底图)
        }
    }

    /// aspect-fill 的绘制矩形（按放大系数外扩，给形变留余量）
    private func 填充矩形(in box: CGRect, 放大: CGFloat) -> CGRect {
        let iw = CGFloat(图.width), ih = CGFloat(图.height)
        guard iw > 0, ih > 0 else { return box }
        let s = max(box.width / iw, box.height / ih) * 放大
        let w = iw * s, h = ih * s
        return CGRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h)
    }
}

// MARK: - 卡片预览缓存

/// 卡片预览的缓存槽：签名 + 图。
/// 用引用类型装，是为了能在 body 求值期安全写入（改成 @State 写会触发「状态在更新中被修改」）。
final class 预览缓存盒 {
    var 签名: String?
    var 图: CGImage?
}
