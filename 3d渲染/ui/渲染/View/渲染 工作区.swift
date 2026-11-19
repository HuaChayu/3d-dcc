import SwiftUI

/// 模式三：渲染。左边输出设置，中间预览，右边队列。
struct RenderWorkspace: View {
    @Environment(渲染Store.self) private var store
    @Environment(着色Store.self) private var shading

    private let presets: [(String, Int, Int)] = [
        ("HD 1920×1080", 1920, 1080),
        ("方形 1080×1080", 1080, 1080),
        ("竖版 1080×1350", 1080, 1350),
        ("4K 3840×2160", 3840, 2160)
    ]

    var body: some View {
        HStack(spacing: 0) {
            settingsColumn
                .frame(width: 320)

            Rectangle().fill(Theme.divider).frame(width: 1)

            previewColumn

            Rectangle().fill(Theme.divider).frame(width: 1)

            queueColumn
                .frame(width: 320)
        }
        .background(Theme.canvasBackground)
    }

    // MARK: 输出设置

    private var settingsColumn: some View {
        @Bindable var store = store
        return VStack(spacing: 0) {
            PanelHeader(title: "输出设置", symbol: "camera.aperture")

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SectionTitle(text: "分辨率", trailing: store.render.aspectTitle)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 6)], alignment: .leading, spacing: 6) {
                        ForEach(presets, id: \.0) { preset in
                            Button {
                                store.render.applyAspect(preset.1, preset.2)
                                store.note("输出改为 \(preset.1) × \(preset.2)")
                            } label: {
                                Text(preset.0)
                                    .font(.system(size: 10.5))
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .tint(store.render.width == preset.1 && store.render.height == preset.2 ? .accentColor : .gray)
                        }
                    }

                    SectionTitle(text: "采样", trailing: "\(store.render.samples) spp")
                    Slider(
                        value: Binding(
                            get: { Double(store.render.samples) },
                            set: { store.render.samples = max(16, Int($0)) }
                        ),
                        in: 16...1024, step: 16
                    )
                    .controlSize(.small)

                    SectionTitle(text: "最大反弹", trailing: "\(store.render.maxBounces)")
                    Slider(
                        value: Binding(
                            get: { Double(store.render.maxBounces) },
                            set: { store.render.maxBounces = max(1, Int($0)) }
                        ),
                        in: 1...32, step: 1
                    )
                    .controlSize(.small)

                    SectionTitle(text: "色调映射")
                    Picker("", selection: $store.render.toneMapping) {
                        ForEach(ToneMapping.allCases) { mapping in
                            Text(mapping.title).tag(mapping)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    SectionTitle(text: "曝光", trailing: String(format: "%+.2f EV", store.render.exposure))
                    Slider(value: $store.render.exposure, in: -4...4)
                        .controlSize(.small)

                    Toggle("降噪", isOn: $store.render.denoise)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    Toggle("透明背景", isOn: $store.render.transparentBackground)
                        .toggleStyle(.switch)
                        .controlSize(.small)

                    Divider()

                    HStack {
                        Text("预估")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(store.render.estimatedSeconds) s")
                            .font(.system(size: 11, design: .monospaced))
                    }

                    Button {
                        store.enqueueRender()
                    } label: {
                        Label("加入渲染队列", systemImage: "square.stack.3d.down.right")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)

                    Text("演示说明：本工程未接真实光线追踪内核，队列进度为模拟过程；参数与 OpenPBR 求值链路是真实的。")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
            }
        }
        .background(Theme.panelBackground)
    }

    // MARK: 预览

    private var previewColumn: some View {
        VStack(spacing: 0) {
            ZStack {
                Theme.canvasBackground
                VStack(spacing: 8) {
                    ViewportPanel()
                        .aspectRatio(Double(store.render.width) / Double(store.render.height), contentMode: .fit)
                        .padding(24)
                }
            }

            HStack(spacing: 10) {
                Text(store.render.aspectTitle)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text("·")
                    .foregroundStyle(.quaternary)
                Text("\(store.render.samples) spp / \(store.render.maxBounces) bounces")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text("·")
                    .foregroundStyle(.quaternary)
                Text(store.render.toneMapping.title)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Theme.panelBackground)
            .overlay(alignment: .top) {
                Rectangle().fill(Theme.divider).frame(height: 1)
            }
        }
    }

    // MARK: 队列

    private var queueColumn: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "渲染队列", symbol: "list.number") {
                Button {
                    store.clearRenderHistory()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .help("清空已完成")
            }

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(store.renderJobs) { job in
                        jobRow(job)
                    }
                    if store.renderJobs.isEmpty {
                        Text("队列为空")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 14)
                    }

                    if let material = shading.activeMaterial {
                        let resolved = MaterialCompiler.resolve(material)
                        if !resolved.viewportGaps.isEmpty {
                            VStack(alignment: .leading, spacing: 5) {
                                SectionTitle(text: "视口缺口（需正式渲染器）")
                                FlowText(items: resolved.viewportGaps.map(\.title), tint: .orange)
                            }
                            .padding(9)
                            .background(Color.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
                .padding(10)
            }
        }
        .background(Theme.inspectorBackground)
    }

    private func jobRow(_ job: RenderJob) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(stateColor(job.state))
                    .frame(width: 6, height: 6)
                Text(job.label)
                    .font(.system(size: 10.5, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 2)
                Text(job.state.title)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }

            Text("\(job.width) × \(job.height) · \(job.createdAt.formatted(date: .omitted, time: .shortened))")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)

            if job.state == .running {
                ProgressView(value: job.progress)
                    .progressViewStyle(.linear)
                    .controlSize(.small)
            } else if job.state == .done {
                Text(String(format: "完成 · %.1f s", job.seconds))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.green.opacity(0.85))
            }

            HStack(spacing: 6) {
                Button(job.state == .done ? "重新渲染（演示）" : "开始渲染") {
                    store.startRender(job.id)
                }
                .controlSize(.mini)
                .disabled(job.state == .running)

                Spacer()
            }
        }
        .padding(9)
        .background(Theme.divider, in: RoundedRectangle(cornerRadius: 8))
    }

    private func stateColor(_ state: RenderJobState) -> Color {
        switch state {
        case .idle: .gray
        case .running: .orange
        case .done: .green
        case .failed: .red
        }
    }
}
