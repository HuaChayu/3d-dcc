import SwiftUI
import AppKit

// MARK: - 布局常量（端口坐标与绘制共用，避免两处各算一遍）

/// 画布命名坐标空间：端口拖动的手势坐标统一换算到这里，再转画布坐标
enum CanvasSpace {
    static let name = "materialNodeCanvas"
}

private enum NodeLayout {
    static let header: CGFloat = 30
    static let pad: CGFloat = 10
    static let row: CGFloat = 22
    static let portInset: CGFloat = 9
    static let canvas = CGSize(width: 6000, height: 4000)
    /// 图像贴图节点在头部与端口之间多出来的那一块：
    /// 预览 62 + 间距 5 + 动效下拉 22 + 间距 5 + 换贴图按钮 21 + 底距 6
    static let imagePanel: CGFloat = 62 + 5 + 22 + 5 + 21 + 6

    /// 头部以下的起始高度：图像贴图节点要先让开贴图预览区，端口才跟卡片上画的对得上。
    static func topInset(_ node: ShaderNode) -> CGFloat {
        header + (node.kind == .imageTexture ? imagePanel : 0)
    }

    static func height(_ node: ShaderNode) -> CGFloat {
        let rows = node.kind.outputs.count + node.kind.inputs.count
        return topInset(node) + pad * 2 + CGFloat(rows) * row
    }

    static func outputPoint(_ node: ShaderNode, index: Int) -> CGPoint {
        CGPoint(
            x: node.position.x + node.kind.width,
            y: node.position.y + topInset(node) + pad + row * CGFloat(index) + row / 2
        )
    }

    static func inputPoint(_ node: ShaderNode, index: Int) -> CGPoint {
        CGPoint(
            x: node.position.x,
            y: node.position.y + topInset(node) + pad + row * CGFloat(node.kind.outputs.count + index) + row / 2
        )
    }
}

private struct PortRef: Equatable {
    var nodeID: UUID
    var socket: String
    var kind: SocketKind
    var isOutput: Bool
}

private struct PendingLink {
    var from: PortRef
    var cursor: CGPoint // 画布坐标
}

/// 拖动中的节点：只改这里的本地位移做渲染偏移，松手才写一次库。
/// 以前每帧 store.moveNode → 推进材质版本 → @Observable 通知 → 画布 / 检查器 / 视口全量重算，
/// 主线程每帧排满，手势被拖断，连线也因为图反复重建而看着断。
private struct NodeDragState {
    var nodeID: UUID
    var start: CGPoint
    var 位移: CGSize = .zero
}

/// sheet(item:) 需要 Identifiable
private struct 参数节点包装: Identifiable {
    var id: UUID
}

// MARK: - 节点编辑器

struct MaterialNodeEditor: View {
    @Environment(着色Store.self) private var store

    /// 底栏分页：由工作区传进来，工具栏最前面放切换控件。
    /// 传 nil 时退化成原来的样子（标题图标），别的地方单独复用不会突然多出一个切换器。
    var 页: Binding<材质底栏页>? = nil

    @State private var pending: PendingLink?
    @State private var dragging: NodeDragState?
    @State private var panStart: CGSize?
    @State private var hoverPort: PortRef?
    @State private var 参数节点: UUID?

    private var graph: NodeGraph { store.activeMaterial?.graph ?? .empty }

    /// 已经接到 Output 上的节点集合（用于卡片"未接入"提示）
    private var drivenNodeIDs: Set<UUID> {
        guard let output = graph.outputNode else { return [] }
        return Set(graph.links.filter { $0.toNode == output.id }.map(\.fromNode))
    }

    var body: some View {
        @Bindable var store = store

        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Theme.canvasBackground
                dotGrid

                // 平移/空白点击层必须垫在节点下面，否则它会盖住整块画布，
                // 节点卡片上的点击、数值拖拽、取色器全被它吞掉（之前"节点点不动"就是这个原因）
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(panGesture)
                    .onTapGesture {
                        store.scene?.焦点 = .节点编辑器
                        store.selectedLinkID = nil
                        store.selectedNodeID = nil
                    }

                // 缩放层：节点与连线都在画布坐标系里，靠外层统一缩放/平移。
                // canvasScale / canvasOffset 只在 画布变换层 内部读：编辑器 body 一旦读它们，
                // 每拖一帧整块 body 都会重算，6000×4000 画布里所有节点卡片的布局、
                // 阴影、文字排版全部重跑一遍 —— 这就是缩小画面后拖动特别卡的主因
                画布变换层(store: store) {
                    ZStack(alignment: .topLeading) {
                        linkLayer
                        nodeLayer
                        pendingLinkLayer
                    }
                }
            }
            .coordinateSpace(.named(CanvasSpace.name))
            .clipped()
            // 滚轮缩放 / 中键平移：裸滚轮和中键 SwiftUI 手势接不到，只能走 AppKit 本地事件监视器。
            // 必须 overlay + 显式撑满 —— 纯事件旁路视图放进 background 会被压成零尺寸，
            // bounds 判断当场失效，滚轮全被当"不在画布上"放行（上一版没反应就是这个原因）
            .overlay {
                画布事件捕获(
                    区域尺寸: proxy.size,
                    算在画布上: { store.scene?.焦点 == .节点编辑器 },
                    缩放: { factor, 锚点 in
                        应用缩放(factor, 锚点: 锚点)
                    },
                    取当前偏移: { store.canvasOffset },
                    平移到: { store.canvasOffset = $0 }
                )
                .frame(width: proxy.size.width, height: proxy.size.height)
                .allowsHitTesting(false)
            }
            .overlay(alignment: .topLeading) { toolbar(size: proxy.size) }
            .sheet(item: Binding(
                get: { 参数节点.map(参数节点包装.init) },
                set: { 参数节点 = $0?.id }
            )) { item in
                NodeInspectorSheet(nodeID: item.id)
                    .environment(store)
            }
            .overlay(alignment: .bottomLeading) { hintBar }

        }
    }

    // MARK: 背景点阵

    @ViewBuilder
    private var dotGrid: some View {
        if 偏好设置Store.shared.显示画布网格 { 画布网格层(store: store) }
    }

    // MARK: 连线

    private var linkLayer: some View {
        // 视觉线合成到一张 Canvas 里画：原来每条线要两个 6000×4000 的 Shape（描边 + 命中带），
        // 拖节点时每帧都要把这些视图全部重建一遍，是拖动掉帧的主要来源之一。
        // Canvas 闭包不外读 store，数据在 body 求值期算好再进去。
        let 线: [连线绘制项] = graph.links.compactMap { link in
            guard let start = outputPoint(for: link), let end = inputPoint(for: link) else { return nil }
            let selected = store.selectedLinkID == link.id
            return 连线绘制项(
                start: start,
                end: end,
                color: Theme.layerTint(PBRParamKey(rawValue: link.toSocket)?.layer ?? .base)
                    .opacity(selected ? 1 : 0.75),
                width: selected ? 2.6 : 1.8
            )
        }
        return ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                for item in 线 {
                    var path = Path()
                    path.move(to: item.start)
                    let dx = max(36, abs(item.end.x - item.start.x) * 0.5)
                    path.addCurve(
                        to: item.end,
                        control1: CGPoint(x: item.start.x + dx, y: item.start.y),
                        control2: CGPoint(x: item.end.x - dx, y: item.end.y)
                    )
                    context.stroke(
                        path,
                        with: .color(item.color),
                        style: StrokeStyle(lineWidth: item.width, lineCap: .round)
                    )
                }
            }
            .frame(width: NodeLayout.canvas.width, height: NodeLayout.canvas.height)
            .allowsHitTesting(false)

            // 命中层只能逐条挂手势：点哪条线要能选中哪条。
            // 每条的 frame 只取这条线自己的包围盒（坐标平移到以包围盒左上为原点）：
            // 原来每条都撑满 6000×4000，只要 body 重算一次（比如按下卡片写选中），
            // 这几张巨型视图连同命中测试就得全量重建 —— 拖动起步那一下卡顿就是它。
            ForEach(graph.links) { link in
                if let start = outputPoint(for: link), let end = inputPoint(for: link) {
                    let 框 = 连线框(start, end)
                    LinkShape(
                        start: CGPoint(x: start.x - 框.minX, y: start.y - 框.minY),
                        end: CGPoint(x: end.x - 框.minX, y: end.y - 框.minY)
                    )
                        .stroke(Theme.divider, style: StrokeStyle(lineWidth: 14))
                        .frame(width: 框.width, height: 框.height)
                        .contentShape(Rectangle())
                        .position(x: 框.midX, y: 框.midY)
                        .onTapGesture {
                            store.scene?.焦点 = .节点编辑器
                            store.selectedLinkID = link.id
                            store.selectedNodeID = nil
                            store.note("已选中连线 \(link.fromSocket) → \(link.toSocket)")
                        }
                }
            }
        }
    }

    private var pendingLinkLayer: some View {
        ZStack(alignment: .topLeading) {
            if let pending {
                let start = pending.from.isOutput
                    ? outputPoint(nodeID: pending.from.nodeID, socket: pending.from.socket)
                    : inputPoint(nodeID: pending.from.nodeID, socket: pending.from.socket)
                if let start {
                    // 同样只撑这条线的包围盒：拉线时每帧都在重算这一层
                    let 框 = 连线框(start, pending.cursor)
                    PendingLinkShape(
                        start: CGPoint(x: start.x - 框.minX, y: start.y - 框.minY),
                        end: CGPoint(x: pending.cursor.x - 框.minX, y: pending.cursor.y - 框.minY),
                        reversed: !pending.from.isOutput
                    )
                    .stroke(
                        Theme.layerTint(pending.from.kind == .color ? .specular : .geometry),
                        style: StrokeStyle(lineWidth: 2, dash: [5, 4])
                    )
                    .frame(width: 框.width, height: 框.height)
                    .position(x: 框.midX, y: 框.midY)
                    .allowsHitTesting(false)
                }
            }
        }
    }

    // MARK: 节点

    private var nodeLayer: some View {
        // 图指纹算一次，所有卡片共用：预览签名拿它当缓存键，省掉每帧每节点重编一遍上游子图
        let 指纹 = MaterialCompiler.图指纹(graph)
        return ZStack(alignment: .topLeading) {
            ForEach(graph.nodes) { node in
                nodeCard(node, 指纹: 指纹)
                    .frame(width: node.kind.width, height: NodeLayout.height(node))
                    .position(
                        x: node.position.x + node.kind.width / 2,
                        y: node.position.y + NodeLayout.height(node) / 2
                    )
                    .offset(
                        x: 拖动位移(node.id).width / store.canvasScale,
                        y: 拖动位移(node.id).height / store.canvasScale
                    )
            }
        }
    }

    /// 单独拆出来，避免 NodeCard 十几个闭包把类型推断拖爆
    private func nodeCard(_ node: ShaderNode, 指纹: String) -> some View {
        // Output 口的值真源 = 材质基线（与检查器同一份），其他节点仍读自身 params
        let portValueSource: ((String) -> PBRValue)? = node.kind == .output
            ? { socket in
                guard let key = PBRParamKey(rawValue: socket) else { return PBRValue.scalar(0) }
                return store.activeMaterial?.baseline[key] ?? key.defaultValue
            }
            : nil
        // Equatable 短路用：连线增删要刷新端口行，但闭包没法比较，这里折成字符串签名
        var 入线签名 = ""
        for link in graph.links where link.toNode == node.id {
            入线签名 += "\(link.toSocket)>\(link.fromNode.uuidString)/\(link.fromSocket);"
        }
        return NodeCard(
            node: node,
            isSelected: store.selectedNodeID == node.id,
            isGraphDriven: drivenNodeIDs.contains(node.id),
            resolveIncoming: { socket in
                graph.link(into: node.id, socket: socket)
            },
            onSelect: {
                select(node)
            },
            onOpenInspector: {
                select(node)
                参数节点 = node.id
            },
            onDragHeader: { translation in drag(node, by: translation) },
            onDragEnd: { translation in endDrag(translation: translation) },
            onValueChange: { socket, value in
                // Output 口 = 材质基线的读写口，与检查器同一份数据（不再写节点自身 params）
                if node.kind == .output, let key = PBRParamKey(rawValue: socket) {
                    // 拖动是连续的，静默写基线（检查器那边才需要状态栏回显）
                    store.updateActiveMaterial { $0.baseline[key] = value }
                } else {
                    store.setNodeParam(node.id, key: socket, value: value)
                }
            },
            onToggleMute: { store.toggleMute(node.id) },
            onDelete: { store.deleteNode(node.id) },
            onStartLink: { socket, kind, isOutput, point in
                beginLink(node: node, socket: socket, kind: kind, isOutput: isOutput, at: point)
            },
            onDragLink: { point in
                pending?.cursor = toCanvas(point)
            },
            onEndLink: { point in
                finishLink(at: point)
            },
            portValue: portValueSource,
            textureIDs: node.kind == .imageTexture ? 视口纹理库.全部编号 : [],
            imageLoader: { 视口纹理库.缩略图($0) },
            预览图: {
                guard let image = node.image else { return nil }
                // 走和视口同一条编译通路：卡片显示的就是这个节点被采样时的那张图
                return 视口纹理库.缩略图(MaterialCompiler.预览编号(graph, 节点: node.id) ?? image)
            },
            调制签名: MaterialCompiler.预览签名(graph, 指纹: 指纹, 节点: node.id),
            onPickImage: { image in
                store.setNodeImage(node.id, image: image)
                store.persist()
            },
            入线签名: 入线签名,
            强调选中: 偏好设置Store.shared.强调选中节点
        )
        .equatable()
    }

    private func select(_ node: ShaderNode) {
        // 在节点上动手 → 之后的 ⌫ 归节点编辑器，不再去删视口物体。
        // 每项都先比对再写：@Observable 写入即通知（同一份值也会），
        // 无谓重写会连带把 3D 视口和整块画布再算一遍，点一下卡一下就是这么来的
        if store.scene?.焦点 != .节点编辑器 { store.scene?.焦点 = .节点编辑器 }
        if store.selectedLinkID != nil { store.selectedLinkID = nil }
        if store.selectedNodeID != node.id { store.selectedNodeID = node.id }
    }

    /// 拖动过程中只更新本地渲染偏移：不写材质、不推进版本、不触发重算，手势才跟手。
    private func drag(_ node: ShaderNode, by translation: CGSize) {
        if dragging?.nodeID != node.id {
            dragging = NodeDragState(nodeID: node.id, start: node.position)
        }
        dragging?.位移 = translation
    }

    private func endDrag(translation: CGSize) {
        defer { dragging = nil }
        guard let d = dragging else { return }
        store.moveNode(
            d.nodeID,
            to: CGPoint(
                x: d.start.x + translation.width / store.canvasScale,
                y: d.start.y + translation.height / store.canvasScale
            )
        )
        store.persist()
    }

    private func 拖动位移(_ id: UUID) -> CGSize {
        dragging?.nodeID == id ? (dragging?.位移 ?? .zero) : .zero
    }

    /// 拖动位移换算到画布坐标：连线端点要跟着节点一起走，拖的时候才不会看着断
    private func 拖动偏移(_ id: UUID) -> CGPoint {
        let s = 拖动位移(id)
        return CGPoint(x: s.width / store.canvasScale, y: s.height / store.canvasScale)
    }

    /// 给画布坐标点加上某节点的拖动位移（CGPoint 没有内置 +，显式加一次）
    private func 偏移后(_ 点: CGPoint, _ id: UUID) -> CGPoint {
        let 偏 = 拖动偏移(id)
        return CGPoint(x: 点.x + 偏.x, y: 点.y + 偏.y)
    }

    private func beginLink(node: ShaderNode, socket: String, kind: SocketKind, isOutput: Bool, at point: CGPoint) {
        pending = PendingLink(
            from: PortRef(nodeID: node.id, socket: socket, kind: kind, isOutput: isOutput),
            cursor: toCanvas(point)
        )
    }

    private func finishLink(at point: CGPoint) {
        defer {
            pending = nil
            hoverPort = nil
        }
        guard let pending else { return }
        guard let target = hitPort(at: toCanvas(point)) else { return }
        guard target.isOutput != pending.from.isOutput, target.nodeID != pending.from.nodeID else { return }

        if pending.from.isOutput {
            store.connect(
                fromNode: pending.from.nodeID,
                fromSocket: pending.from.socket,
                toNode: target.nodeID,
                toSocket: target.socket
            )
        } else {
            store.connect(
                fromNode: target.nodeID,
                fromSocket: target.socket,
                toNode: pending.from.nodeID,
                toSocket: pending.from.socket
            )
        }
    }

    // MARK: 手势

    /// 以指针为锚点缩放：先把指针位置换算成画布坐标，缩完再把同一个画布点拉回指针底下，
    /// 这样滚轮缩放时手边那个节点不会跑走（视口那边是相机距离缩放，画布这边只能改 offset 来兑）
    private func 应用缩放(_ factor: CGFloat, 锚点: CGPoint) {
        let 旧 = store.canvasScale
        let 新 = min(max(旧 * Double(factor), 0.25), 3)
        guard abs(新 - 旧) > 0.0005 else { return }
        let 画布点 = CGPoint(
            x: (锚点.x - store.canvasOffset.width) / 旧,
            y: (锚点.y - store.canvasOffset.height) / 旧
        )
        store.canvasScale = 新
        store.canvasOffset = CGSize(
            width: 锚点.x - 画布点.x * 新,
            height: 锚点.y - 画布点.y * 新
        )
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if panStart == nil { panStart = store.canvasOffset }
                guard let start = panStart else { return }
                // 空白处平移；按住 ⌥ 或中键时也是平移，这里统一处理
                store.canvasOffset = CGSize(
                    width: start.width + value.translation.width,
                    height: start.height + value.translation.height
                )
            }
            .onEnded { _ in
                panStart = nil
                store.persist()
            }
    }

    // MARK: 材质槽

    /// 槽条只认选中物体自己的材质槽：物体身上有几个槽就排几格。
    /// 每格那颗粒子球去引用材质库里已有的同一份材质（连缩略图都用库里那张缓存图），
    /// 不为槽复制材质，也不为槽单独再渲一遍。
    private var 材质槽条: some View {
        let 对象 = store.scene?.selectedObject
        let 槽们 = 对象.map { 对象统计.材质槽列表($0) } ?? []

        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 3) {
                if let 对象 {
                    ForEach(槽们) { 槽 in
                        let 材质 = 槽材质(槽, 对象: 对象)
                        Button {
                            激活(槽, 对象: 对象)
                        } label: {
                            材质槽单元(
                                槽: 槽,
                                材质: 材质,
                                选中: 材质 != nil && 材质?.id == 对象.materialID
                            )
                        }
                        .buttonStyle(.plain)
                        // 副槽写入路径已封：只有 0 号槽可点，其余置灰只读（渲染端还没接入副槽）
                        .disabled(槽.序 != 0)
                        .help(槽.序 == 0
                              ? "主材质槽：\(材质?.name ?? "还没引用材质")"
                              : "第 \(槽.序 + 1) 格是副槽：渲染端尚未接入，本轮只读")
                        .contextMenu {
                            // 槽上右键只有一件事：把这一格现在调好的样子，另存成材质库里的一条新材质。
                            // 不覆盖出处、不回头改库里的东西 —— 存下来就是一条独立的新模板。
                            Button("另存为新材质") {
                                guard let 材质 else { return }
                                store.另存为新材质(材质.id)
                            }
                            .disabled(材质 == nil)
                            Divider()
                            // 移出槽：这一格不再用这份材质，后面的槽依次前移补位。
                            // 槽数由网格子集决定、不可变，所以不删槽，只把引用表左移一格。
                            Button("移出槽") {
                                移出槽(槽, 对象: 对象)
                            }
                            .disabled(材质 == nil)
                        }
                    }
                } else {
                    Text("未选中物体")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6)
                }
            }
            .padding(.horizontal, 3)
            .padding(.vertical, 2)
        }
        .frame(width: 230, height: 38)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Theme.divider, lineWidth: 1)
        )
        .help("材质槽：选中物体有几个槽就显示几格，点哪格节点图就切到那格引用的材质")
    }

    /// 槽要显示的材质：先看这个槽自己引用的是谁，再看导入子集写的材质名去库里找同名材质，
    /// 最后回落到物体当前生效的材质。全程只拿引用，不复制、不新建。
    private func 槽材质(_ 槽: 对象统计.材质槽, 对象: SceneObject) -> MaterialAsset? {
        // 物体此刻真正在用的那份（可能已经从库条目分离成了实例）
        let 当前 = store.material(对象.materialID)
        if let 引用 = 对象.材质槽引用, 槽.序 < 引用.count, let 命中 = store.material(引用[槽.序]) {
            return 命中
        }
        if let 名 = 槽.材质名 {
            let 同名 = store.materials.filter { $0.name == 名 }
            // 一旦动过节点，库条目会被「分离」成同名实例，物体改指实例，而库条目仍留在库里。
            // 这时槽必须认「当前生效的那一份」，否则 id 对不上会误判成未选中，
            // 再点一下槽又把物体指回库条目，节点布局就整体跳回导入时的原始排布。
            if let 当前, 同名.contains(where: { $0.id == 当前.id }) { return 当前 }
            if let 命中 = 同名.first(where: { $0.是否库条目 }) ?? 同名.first { return 命中 }
        }
        return 当前
    }

    /// 点槽：把物体切到该槽**自己引用的**那份材质上（引用同一份，不复制材质本体）。
    /// 【空槽不写回】空格子被点只弹提示，不拿 `activeMaterial` / 库首条去填，
    /// 也不拿「当前材质」当这一格的材质 —— 那等于把刚「移出槽」移走的材质又恢复回来。
    ///
    /// 【副槽写入路径已封】视口（`场景 构建.swift:449-457`）与 PT（`PT 场景 转译.swift:152`）
    /// 当前都只读 `materialID`（0 号槽）。副槽写进去没有任何消费者，只会造出
    /// "能写进去但没人认"的第二套真值源，所以这里只受理 0 号槽、并把 `材质槽引用` 清空。
    /// 槽条上非 0 号槽已置灰，这条 guard 是双保险（防止将来从别处调进来）。
    /// 导通副槽（视口与 PT 都按槽位表取材质）是独立的一轮工作，不在材质域接入这一轮里做半成品。
    private func 激活(_ 槽: 对象统计.材质槽, 对象: SceneObject) {
        guard let scene = store.scene else { return }
        guard 槽.序 == 0 else {
            store.note("第 \(槽.序 + 1) 格是副槽，渲染端还没接入，本轮只受理主材质槽")
            return
        }
        // 空槽判定以槽位表（真值）为准：这一格没引用就是没引用，
        // 不回落 activeMaterial、不回落库首条、也不把「当前材质」借给它 —— 否则点一下就把移出的材质恢复了。
        let 表 = 对象.材质槽位表
        guard 槽.序 < 表.count, let 引用ID = 表[槽.序], let 目标 = store.material(引用ID) else {
            store.note("第 \(槽.序 + 1) 格是空槽，没有引用材质，点它不会写回任何材质")
            return
        }
        // 主槽真值只有 materialID 一份；清掉 材质槽引用 表示"没有副槽引用"，不留半截数据
        scene.updateObject(对象.id) { 物体 in
            物体.materialID = 目标.id
            物体.材质槽引用 = nil
        }
        // 材质槽归属改了也要过材质接线：引用计数与引用者是 M:N 的真值，绕过它就等于自维护
        switch 材质接线.共享.绑定(对象: 对象.id, 槽位表: [目标.id]) {
        case .变更, .无需变更: break
        case .未知材质(let id): store.note("材质 \(id) 不在材质域里，引用计数未登记")
        case .引用计数错乱(let 原因): store.note("材质引用计数错乱：\(原因)")
        }
        store.selectedMaterialID = 目标.id
        store.selectedNodeID = nil
        store.note("主材质槽 → \(目标.name)")
    }

    /// 移出槽：这一格不再使用它现在引用的材质，后面的槽依次前移补上这个位置。
    ///
    /// 槽数由导入网格的子集（`对象统计.材质槽列表`）决定，**不可变**，所以这里不删槽位，
    /// 只把槽位表左移一格：被移出的那格由后面一格顶上，末尾多出来的那格回到"未引用"。
    /// 槽位表左移后按"从 0 号槽起的连续引用"回填（`材质槽引用` 表达不了中段空槽），
    /// 主槽真值仍是 `materialID` 一份；引用计数与引用者交给材质接线重算，不在这里自己记账。
    /// 只有一个槽时左移结果为空表 = 该槽清空回默认，槽位本身还在，不会造出非法槽数。
    private func 移出槽(_ 槽: 对象统计.材质槽, 对象: SceneObject) {
        guard let scene = store.scene else { return }
        var 表 = 对象.材质槽位表
        guard 槽.序 < 表.count else {
            store.note("第 \(槽.序 + 1) 格还没有引用材质，没有可移出的内容")
            return
        }
        let 被移出 = 表[槽.序]
        表.remove(at: 槽.序)
        // 尾部空槽不构成引用（与 `材质槽位表` 同一口径），裁掉才是"后面补上来"的结果
        while let 尾 = 表.last, 尾 == nil { 表.removeLast() }
        let 新主槽 = 表.first ?? nil
        let 新副槽 = Array(表.dropFirst()).compactMap { $0 }

        scene.updateObject(对象.id) { 物体 in
            物体.materialID = 新主槽
            物体.材质槽引用 = 新副槽.isEmpty ? nil : 新副槽
        }
        switch 材质接线.共享.绑定(对象: 对象.id, 槽位表: 表) {
        case .变更, .无需变更: break
        case .未知材质(let id): store.note("材质 \(id) 不在材质域里，引用计数未登记")
        case .引用计数错乱(let 原因): store.note("材质引用计数错乱：\(原因)")
        }
        // 选中态跟着主槽走：前移上来的材质立刻接管节点图；
        // 若槽已清空，就把节点图那一格放开，不留在刚被移出的那份材质上。
        if let 主 = 新主槽 {
            store.selectedMaterialID = 主
            store.selectedNodeID = nil
        } else if let 被移出, store.selectedMaterialID == 被移出 {
            store.selectedNodeID = nil
        }
        if let 名 = 被移出.flatMap({ store.material($0)?.name }) {
            store.note("已移出第 \(槽.序 + 1) 格的「\(名)」，后面的槽已前移补位")
        } else {
            store.note("第 \(槽.序 + 1) 格已清空，后面的槽已前移补位")
        }
    }

    // MARK: 工具栏

    private func toolbar(size: CGSize) -> some View {
        @Bindable var store = store
        return HStack(spacing: 8) {
            if let 分页 = 页 {
                材质底栏切换控件(页: 分页)
                Divider().frame(height: 14)
            } else {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            // 材质槽：原来这里是「材质名」下拉，一个模型带多个材质时得点开菜单找。
            // 现在把材质球平铺成一条槽位，点哪个槽节点图就切到哪个材质。
            材质槽条

            Divider().frame(height: 14)

            Menu {
                ForEach(NodeCategory.allCases) { category in
                    Section(category.title) {
                        ForEach(ShaderNodeKind.allCases.filter { $0.category == category && $0 != .output }) { kind in
                            Button {
                                let center = CGPoint(
                                    x: (size.width / 2 - store.canvasOffset.width) / store.canvasScale - 90,
                                    y: (size.height / 2 - store.canvasOffset.height) / store.canvasScale - 60
                                )
                                store.addNode(kind: kind, at: center)
                            } label: {
                                Label(kind.title, systemImage: kind.symbol)
                            }
                        }
                    }
                }
            } label: {
                Label("添加节点", systemImage: "plus.circle")
                    .font(.system(size: 11))
            }
            .menuStyle(.borderlessButton)
            .frame(width: 104)

            Button {
                store.deleteSelection()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(store.selectedNodeID == nil && store.selectedLinkID == nil)
            .help("删除选中节点 / 连线")

            Spacer(minLength: 0)

            Text(String(format: "%.0f%%", store.canvasScale * 100))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)

            Button {
                store.canvasScale = 1
                store.canvasOffset = CGSize(width: 30, height: 20)
            } label: {
                Image(systemName: "1.magnifyingglass")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("重置视图")

            Button {
                store.inspectorVisible.toggle()
            } label: {
                Image(systemName: store.inspectorVisible ? "sidebar.right" : "sidebar.right")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("OpenPBR 检查器")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9).stroke(Theme.divider, lineWidth: 1)
        )
        .padding(10)
    }

    private var hintBar: some View {
        Text("拖动端口连线 · 滚轮缩放 · 中键或拖空白平移 · Delete 删除")
            .font(.system(size: 9.5, design: .monospaced))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(10)
    }

    // MARK: 坐标与命中

    private func toCanvas(_ globalPoint: CGPoint, proxy: GeometryProxy? = nil) -> CGPoint {
        CGPoint(
            x: (globalPoint.x - store.canvasOffset.width) / store.canvasScale,
            y: (globalPoint.y - store.canvasOffset.height) / store.canvasScale
        )
    }

    /// 一条线的包围盒（外扩一点留给 14pt 的命中带）。曲线的控制点永远落在两端 x 之间、
    /// 两端 y 之间，所以两端点围出来的框就够，不用另外采样。
    private func 连线框(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        let pad: CGFloat = 12
        let minX = min(a.x, b.x) - pad
        let minY = min(a.y, b.y) - pad
        return CGRect(
            x: minX,
            y: minY,
            width: max(max(a.x, b.x) + pad - minX, 1),
            height: max(max(a.y, b.y) + pad - minY, 1)
        )
    }

    private func outputPoint(for link: NodeLink) -> CGPoint? {
        guard let node = graph.node(link.fromNode),
              let index = node.kind.outputs.firstIndex(where: { $0.id == link.fromSocket })
        else { return nil }
        return 偏移后(NodeLayout.outputPoint(node, index: index), node.id)
    }

    private func inputPoint(for link: NodeLink) -> CGPoint? {
        guard let node = graph.node(link.toNode),
              let index = node.kind.inputs.firstIndex(where: { $0.id == link.toSocket })
        else { return nil }
        return 偏移后(NodeLayout.inputPoint(node, index: index), node.id)
    }

    private func outputPoint(nodeID: UUID, socket: String) -> CGPoint? {
        guard let node = graph.node(nodeID),
              let index = node.kind.outputs.firstIndex(where: { $0.id == socket })
        else { return nil }
        return 偏移后(NodeLayout.outputPoint(node, index: index), node.id)
    }

    private func inputPoint(nodeID: UUID, socket: String) -> CGPoint? {
        guard let node = graph.node(nodeID),
              let index = node.kind.inputs.firstIndex(where: { $0.id == socket })
        else { return nil }
        return 偏移后(NodeLayout.inputPoint(node, index: index), node.id)
    }

    /// 端口命中：就近取 26pt 内最近的端口（画布坐标）
    private func hitPort(at point: CGPoint) -> PortRef? {
        var best: (PortRef, CGFloat)?
        for node in graph.nodes {
            for (index, socket) in node.kind.outputs.enumerated() {
                let p = 偏移后(NodeLayout.outputPoint(node, index: index), node.id)
                let d = hypot(p.x - point.x, p.y - point.y)
                if d < 26, best == nil || d < best!.1 {
                    best = (PortRef(nodeID: node.id, socket: socket.id, kind: socket.kind, isOutput: true), d)
                }
            }
            for (index, socket) in node.kind.inputs.enumerated() {
                let p = 偏移后(NodeLayout.inputPoint(node, index: index), node.id)
                let d = hypot(p.x - point.x, p.y - point.y)
                if d < 26, best == nil || d < best!.1 {
                    best = (PortRef(nodeID: node.id, socket: socket.id, kind: socket.kind, isOutput: false), d)
                }
            }
        }
        return best?.0
    }
}

// MARK: - 画布图层

/// 只在这里读 canvasScale / canvasOffset。
///
/// 平移是逐帧更新：编辑器 body 直接读这两个值的话，每一帧都会让整块 body 失效重算，
/// 6000×4000 画布里的所有节点卡片跟着重新布局、重新排文字、重新光栅化阴影；
/// 缩小画面后卡片全部落进可视区，这笔开销就变成肉眼可见的掉帧。
/// 把读取关进这个小组件后，拖动时只有它自己的 body 重算，画布子树保持原样。
private struct 画布变换层<Inner: View>: View {
    let store: 着色Store
    private let 内容: Inner

    init(store: 着色Store, @ViewBuilder 内容: () -> Inner) {
        self.store = store
        self.内容 = 内容()
    }

    var body: some View {
        内容
            .frame(width: NodeLayout.canvas.width, height: NodeLayout.canvas.height, alignment: .topLeading)
            .scaleEffect(store.canvasScale, anchor: .topLeading)
            .offset(x: store.canvasOffset.width, y: store.canvasOffset.height)
    }
}

/// 背景点阵：屏幕点距 = 24×scale，点数按 1/scale² 平方膨胀 ——
/// 0.3 倍时一屏要三万多颗点，原来逐点 context.fill 每帧重新光栅化一遍，直接拖死主线程。
/// 这里把所有点合成一条 Path 一次填充，并把屏幕点距钳到 14pt 以上，把点数压到几千的量级。
private struct 画布网格层: View {
    let store: 着色Store

    var body: some View {
        // 在 body 求值期显式取值，Canvas 闭包里再读它就不会丢依赖
        let scale = store.canvasScale
        let offset = store.canvasOffset

        Canvas { context, size in
            var step = CGFloat(24 * scale)
            while step < 14 { step *= 2 }

            let offsetX = offset.width.truncatingRemainder(dividingBy: step)
            let offsetY = offset.height.truncatingRemainder(dividingBy: step)

            var path = Path()
            var y = offsetY - step
            while y < size.height + step {
                var x = offsetX - step
                while x < size.width + step {
                    path.addEllipse(in: CGRect(x: x, y: y, width: 1.4, height: 1.4))
                    x += step
                }
                y += step
            }
            context.fill(path, with: .color(Theme.canvasGrid))
        }
        .allowsHitTesting(false)
    }
}

// MARK: - 连线形状

/// linkLayer 的 Canvas 绘制数据。在 body 求值期算好再进 Canvas 闭包，
/// 闭包里不读 store，免得依赖追踪丢失导致连线不跟着动。
private struct 连线绘制项 {
    var start: CGPoint
    var end: CGPoint
    var color: Color
    var width: CGFloat
}


private struct LinkShape: Shape {
    var start: CGPoint
    var end: CGPoint

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: start)
        let dx = max(36, abs(end.x - start.x) * 0.5)
        path.addCurve(
            to: end,
            control1: CGPoint(x: start.x + dx, y: start.y),
            control2: CGPoint(x: end.x - dx, y: end.y)
        )
        return path
    }
}

private struct PendingLinkShape: Shape {
    var start: CGPoint
    var end: CGPoint
    var reversed: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: start)
        let dx = max(36, abs(end.x - start.x) * 0.5)
        if reversed {
            path.addCurve(
                to: end,
                control1: CGPoint(x: start.x - dx, y: start.y),
                control2: CGPoint(x: end.x + dx, y: end.y)
            )
        } else {
            path.addCurve(
                to: end,
                control1: CGPoint(x: start.x + dx, y: start.y),
                control2: CGPoint(x: end.x - dx, y: end.y)
            )
        }
        return path
    }
}

// MARK: - 材质槽单元

/// 槽条里的一格：材质球 + 名字，对应物体身上一个真实的材质槽（不是材质库的平铺）。
/// 球走 材质球缩略图，渲染尺寸给材质库那档 96，直接命中库里已渲好的缓存图，不再多渲一遍；
/// 槽还没引用材质时画一颗粒子虚线占位，点了会把当前材质引用进来。
private struct 材质槽单元: View {
    let 槽: 对象统计.材质槽
    let 材质: MaterialAsset?
    let 选中: Bool

    var body: some View {
        VStack(spacing: 0) {
            if let 材质 {
                let resolved = MaterialCompiler.resolve(材质)
                材质球缩略图(
                    resolved: resolved,
                    签名: 材质缩略图键.key(resolved),
                    尺寸: 22,
                    渲染尺寸: 96
                )
            } else {
                Circle()
                    .strokeBorder(Theme.divider, style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    .frame(width: 20, height: 20)
                    .frame(height: 22)
            }
            Text(材质?.name ?? 槽.显示名)
                .font(.system(size: 7.5))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 46)
                .foregroundStyle(选中 ? Theme.主色 : Color.secondary)
        }
        .frame(width: 50, height: 34)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(选中 ? Theme.主色.opacity(0.16) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(选中 ? Theme.主色.opacity(0.55) : Color.clear, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 7))
    }
}

// MARK: - 画布滚轮缩放 / 中键平移
/// 裸滚轮和中键 SwiftUI 手势都接不到，只能挂一条 AppKit 本地事件监视器。
/// 性能：只监听滚轮与中键共 4 种事件，事件来了才跑；没有定时器、没有每帧逻辑。
private struct 画布事件捕获: NSViewRepresentable {
    /// 画布区尺寸：视图量不出尺寸时用它兜底算锚点
    var 区域尺寸: CGSize
    /// 指针是否算在画布上：几何测不出来时退回这个判断
    var 算在画布上: () -> Bool
    var 缩放: (CGFloat, CGPoint) -> Void
    /// 取当前画布偏移：中键按下时记下来，拖动时按"起点 + 位移"算绝对位置
    var 取当前偏移: () -> CGSize
    /// 直接把画布偏移设成这个值（和左键拖空白同一套算法）
    var 平移到: (CGSize) -> Void

    func makeNSView(context: Context) -> 画布捕获视图 {
        let view = 画布捕获视图()
        view.装回调(区域尺寸: 区域尺寸, 算在画布上: 算在画布上, 缩放: 缩放,
                   取当前偏移: 取当前偏移, 平移到: 平移到)
        view.装监视器()
        return view
    }

    func updateNSView(_ nsView: 画布捕获视图, context: Context) {
        nsView.装回调(区域尺寸: 区域尺寸, 算在画布上: 算在画布上, 缩放: 缩放,
                     取当前偏移: 取当前偏移, 平移到: 平移到)
        nsView.装监视器()
    }

    static func dismantleNSView(_ nsView: 画布捕获视图, coordinator: ()) {
        nsView.停()
    }
}

private final class 画布捕获视图: NSView {
    /// 同一时刻只允许一个视图持有监视器，避免 SwiftUI 重建时新旧两条监视器同时累加事件（那会把平移量翻倍放大）
    private static weak var 活跃: 画布捕获视图?

    private var 区域尺寸: CGSize = .zero
    private var 算在画布上闭包: () -> Bool = { false }
    private var 缩放回调: ((CGFloat, CGPoint) -> Void)?
    private var 取当前偏移: () -> CGSize = { .zero }
    private var 平移到回调: ((CGSize) -> Void)?
    private var monitor: Any?
    private var 平移中 = false
    private var 首帧 = true
    private var 起点: CGPoint?
    private var 起始偏移: CGSize = .zero

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func 装回调(区域尺寸: CGSize,
                算在画布上: @escaping () -> Bool,
                缩放: @escaping (CGFloat, CGPoint) -> Void,
                取当前偏移: @escaping () -> CGSize,
                平移到: @escaping (CGSize) -> Void) {
        self.区域尺寸 = 区域尺寸
        算在画布上闭包 = 算在画布上
        缩放回调 = 缩放
        self.取当前偏移 = 取当前偏移
        平移到回调 = 平移到
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { 停() } else { 装监视器() }
    }

    func 停() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        平移中 = false
        起点 = nil
        if Self.活跃 === self { Self.活跃 = nil }
    }

    /// 一条监视器管 4 种事件；没有滚轮/中键时这里完全不执行
    func 装监视器() {
        if let 旧 = Self.活跃, 旧 !== self { 旧.停() }
        Self.活跃 = self
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.scrollWheel, .otherMouseDown, .otherMouseDragged, .otherMouseUp]
        ) { [weak self] event in
            guard let self else { return event }
            // 只按"事件属于哪个窗口"过滤；self.window 拿不到时不拦（视图刚重建的那一瞬会是 nil）
            if let 目标 = self.window, let 来窗 = event.window, 来窗 !== 目标 { return event }
            switch event.type {
            case .scrollWheel:
                guard self.在画布上(event) else { return event }
                let 点 = self.锚点(event)
                // 触控板按像素增量给一个很细的系数，鼠标滚轮按格给大一点的；
                // 系数与 3D 视口同一套（触控板约 0.005/px、滚轮约 0.09/格），两处手感连贯
                let 原始 = event.hasPreciseScrollingDeltas
                    ? event.scrollingDeltaY * 0.005
                    : event.scrollingDeltaY * 0.09
                guard 原始 != 0 else { return nil }
                // 再对单次事件封顶 ±20%，免得惯性事件一冲到底直接顶到 0.25 / 3 的极限
                let 滚动量 = max(min(原始, 0.2), -0.2)
                // 方向对齐视口：往上滚（scrollingDeltaY 为正）= 推近 = 放大，往下滚 = 拉远 = 缩小
                self.缩放回调?(exp(CGFloat(滚动量)), 点)
                return nil
            case .otherMouseDown:
                guard event.buttonNumber == 2, self.在画布上(event) else { return event }
                self.平移中 = true
                self.首帧 = true
                self.起点 = self.指针(event)
                self.起始偏移 = self.取当前偏移()
                return nil
            case .otherMouseDragged:
                guard self.平移中, let 起点 = self.起点 else { return event }
                // 和左键拖空白完全同一套：偏移 = 按下时的偏移 + 指针位移（绝对量，不是逐帧累加，绝不会滚雪球）
                let 现在 = self.指针(event)
                let 位移 = CGSize(width: 现在.x - 起点.x, height: 现在.y - 起点.y)
                if self.首帧 {
                    self.首帧 = false
                    // 首帧位移离谱说明按下那一刻拿到的坐标不可信（视图刚重建 / 坐标系还没稳），
                    // 就地把它当成新基准，绝不让画面"轻轻一动瞬移出去"
                    if abs(位移.width) > 300 || abs(位移.height) > 300 {
                        self.起点 = 现在
                        self.起始偏移 = self.取当前偏移()
                        return nil
                    }
                }
                self.平移到回调?(CGSize(
                    width: self.起始偏移.width + 位移.width,
                    height: self.起始偏移.height + 位移.height
                ))
                return nil
            case .otherMouseUp:
                let 接管过 = self.平移中
                self.平移中 = false
                self.首帧 = true
                self.起点 = nil
                return 接管过 ? nil : event
            default:
                return event
            }
        }
    }

    /// 事件指针在本视图坐标里的位置（和拖动、缩放锚点统一坐标系）
    private func 指针(_ event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    /// 指针是否落在这块画布上：几何优先，测不出来退回交互区域判断
    private func 在画布上(_ event: NSEvent) -> Bool {
        if bounds.width > 1, bounds.height > 1 {
            if bounds.contains(指针(event)) { return true }
        }
        return 算在画布上闭包()
    }

    private func 锚点(_ event: NSEvent) -> CGPoint {
        if bounds.width > 1, bounds.height > 1 {
            let 点 = 指针(event)
            if bounds.contains(点) { return 点 }
        }
        let 尺寸 = 区域尺寸.width > 1 ? 区域尺寸 : bounds.size
        return CGPoint(x: 尺寸.width / 2, y: 尺寸.height / 2)
    }
}
