import SwiftUI

// MARK: - 节点参数面板

/// 双击节点卡片 / 点卡片头部滑杆按钮打开。
/// 卡片上的 ScalarScrub 适合快速微调，这个面板给大目标、带刻度，方便精确修改。
struct NodeInspectorSheet: View {
    @Environment(着色Store.self) private var store
    @Environment(\.dismiss) private var dismiss

    var nodeID: UUID

    private var node: ShaderNode? {
        store.activeMaterial?.graph.node(nodeID)
    }

    private var graph: NodeGraph {
        store.activeMaterial?.graph ?? .empty
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.stroke)

            if let node {
                ScrollView {
                    VStack(spacing: 10) {
                        if node.kind != .output {
                            connectSection(node)
                        }

                        ForEach(node.kind.inputs) { socket in
                            row(socket, node: node)
                        }

                        if node.kind == .imageTexture { 动效行(node) }

                        if node.kind == .rgbConstant {
                            colorRow(title: "颜色", socket: "color", node: node)
                        }
                        if node.kind == .valueConstant {
                            sliderRow(title: "数值", socket: "value", range: 0...1, node: node)
                        }
                        if node.kind.inputs.isEmpty && node.kind != .rgbConstant && node.kind != .valueConstant {
                            Text("该节点没有可调参数")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(14)
                }
            } else {
                Text("节点已不存在")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider().overlay(Theme.stroke)
            footer
        }
        .frame(width: 320, height: 420)
        .background(Theme.panelBackground)
    }

    // MARK: 头部

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: node?.kind.symbol ?? "questionmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.categoryTint(node?.kind.category ?? .input))
            Text(node?.displayTitle ?? "节点参数")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let node {
                Toggle("旁路", isOn: Binding(
                    get: { node.isMuted },
                    set: { _ in store.toggleMute(node.id) }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.system(size: 10))
                .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
    }

    // MARK: 接线状态（决定改动到底影不影响模型）

    @ViewBuilder
    private func connectSection(_ node: ShaderNode) -> some View {
        let driven = store.drivenKeys(of: node.id)
        VStack(alignment: .leading, spacing: 6) {
            if driven.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                    Text("未接入「OpenPBR 输出」，这里的改动不会影响模型")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Menu {
                    ForEach(candidateKeys(for: node), id: \.self) { key in
                        Button("\(key.title)　（当前 \(key.defaultValue.summary)）") {
                            store.connectToOutput(node.id, key: key)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "link")
                            .font(.system(size: 9))
                        Text("接入到输出参数…")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Theme.fieldBackground, in: Capsule())
                    .overlay(Capsule().stroke(Theme.stroke, lineWidth: 0.8))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            } else {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.accent)
                    Text("正在驱动：\(driven.map(\.title).joined(separator: "、")))")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Theme.fieldBackground.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
    }

    /// 能接进 Output 的参数：类型必须匹配（颜色↔颜色，数值↔数值）
    private func candidateKeys(for node: ShaderNode) -> [PBRParamKey] {
        let hasColor = node.kind.outputs.contains { $0.kind == .color }
        let hasScalar = node.kind.outputs.contains { $0.kind == .scalar }
        var keys = NodeGraph.outputKeys.filter { key in
            key.isColor ? hasColor : hasScalar
        }
        // 数值常量最常见的用途排前面，减少找项成本
        keys.sort { lhs, rhs in
            let order: [PBRParamKey] = [.baseRoughness, .baseMetallic, .baseColor, .coatWeight, .geometryOpacity]
            let l = order.firstIndex(of: lhs) ?? 99
            let r = order.firstIndex(of: rhs) ?? 99
            return l < r
        }
        return keys
    }

    /// 图像贴图节点：动效下拉（和卡片上那个是同一个参数 params["anim"]）
    @ViewBuilder
    private func 动效行(_ node: ShaderNode) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: node.图像动效值.symbol)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.categoryTint(node.kind.category))
                Text("动效")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 0)
            }
            Picker("", selection: Binding(
                get: { node.图像动效值 },
                set: { 效果 in
                    store.setNodeParam(node.id, key: 图像动效.paramKey, value: .scalar(Double(效果.rawValue)))
                }
            )) {
                ForEach(图像动效.allCases) { 效果 in
                    Label(效果.title, systemImage: 效果.symbol).tag(效果)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 行

    @ViewBuilder
    private func row(_ socket: NodeSocket, node: ShaderNode) -> some View {
        if let link = graph.link(into: node.id, socket: socket.id) {
            HStack {
                label(socket.title)
                Spacer(minLength: 8)
                Text("← \(link.fromSocket)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.categoryTint(.input).opacity(0.9))
            }
            .frame(height: 24)
        } else if socket.kind == .color {
            colorRow(title: socket.title, socket: socket.id, node: node)
        } else {
            sliderRow(
                title: socket.title,
                socket: socket.id,
                // 节点自身参数优先用它的语义范围（色相是度、饱和度是倍率），输出节点才走材质参数的范围
                range: node.kind.参数范围(socket.id) ?? socket.paramKey?.range ?? 0...1,
                node: node
            )
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Theme.textSecondary)
            .lineLimit(1)
            .frame(width: 88, alignment: .leading)
    }

    private func colorRow(title: String, socket: String, node: ShaderNode) -> some View {
        HStack {
            label(title)
            Spacer(minLength: 8)
            ColorPicker(
                "",
                selection: Binding(
                    get: { Theme.color(from: node.value(for: socket).colorValue) },
                    set: { store.setNodeParam(node.id, key: socket, value: .color(Theme.pbr(from: $0))) }
                ),
                supportsOpacity: false
            )
            .labelsHidden()
            .controlSize(.small)
        }
        .frame(height: 26)
    }

    private func sliderRow(title: String, socket: String, range: ClosedRange<Double>, node: ShaderNode) -> some View {
        let current = node.value(for: socket).scalarValue
        return VStack(spacing: 2) {
            HStack {
                label(title)
                Spacer(minLength: 8)
                Text(format(current, range: range))
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Theme.fieldBackground, in: RoundedRectangle(cornerRadius: 4))
            }
            Slider(
                value: Binding(
                    get: { current },
                    set: { store.setNodeParam(node.id, key: socket, value: .scalar($0)) }
                ),
                in: range
            )
            .controlSize(.small)
            .tint(Theme.accent)
        }
        .frame(height: 40)
    }

    private func format(_ v: Double, range: ClosedRange<Double>) -> String {
        if range.upperBound > 50 { return String(format: "%.0f", v) }
        return String(format: "%.\(偏好设置Store.shared.数值小数位)f", v)
    }

    // MARK: 底部

    private var footer: some View {
        HStack(spacing: 8) {
            if let node, node.kind != .output {
                Button(role: .destructive) {
                    store.deleteNode(node.id)
                    dismiss()
                } label: {
                    Label("删除节点", systemImage: "trash")
                        .font(.system(size: 11))
                }
                .controlSize(.small)
            }
            Spacer(minLength: 0)
            Button("完成") { dismiss() }
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
    }
}
