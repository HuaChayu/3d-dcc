import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 主视图

struct 通用导入视图: View {
    @Bindable var 模型: 通用导入模型
    var 放入场景: ([导入场景]) -> Void

    @State private var 选中文件ID: UUID?
    @State private var 拖入中 = false

    var body: some View {
        VStack(spacing: 0) {
            标题条
            Divider()
            if 模型.出现的格式.isEmpty {
                空态
            } else {
                Tab条
                Divider()
                HStack(spacing: 0) {
                    文件栏
                        .frame(minWidth: 320, idealWidth: 380)
                    Divider()
                    参数栏
                        .frame(minWidth: 320)
                }
            }
            Divider()
            底栏
        }
        .frame(minWidth: 880, minHeight: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay {
            if 拖入中 {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $拖入中) { 提供者们 in
            接收拖拽(提供者们)
        }
        .onAppear { 同步选中() }
        .onChange(of: 模型.选中Tab) { _, _ in 同步选中() }
    }

    private func 同步选中() {
        guard let Tab = 模型.选中Tab else { return }
        let 本组 = 模型.文件集(Tab)
        if let 旧 = 选中文件ID, 本组.contains(where: { $0.id == 旧 }) { return }
        选中文件ID = 本组.first?.id
    }

    private func 接收拖拽(_ 提供者们: [NSItemProvider]) -> Bool {
        for 提供者 in 提供者们 {
            _ = 提供者.loadObject(ofClass: NSURL.self) { 对象, _ in
                guard let nsURL = 对象 as? NSURL else { return }
                let url = nsURL as URL
                DispatchQueue.main.async { 模型.加入([url]) }
            }
        }
        return true
    }

    private var 当前选中: 导入文件? {
        guard let 选中文件ID else { return nil }
        return 模型.文件表.first { $0.id == 选中文件ID }
    }

    // MARK: 标题条

    private var 标题条: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("通用导入")
                    .font(.system(size: 13, weight: .semibold))
                Text("\(模型.文件表.count) 个文件 · \(模型.出现的格式.count) 种类型 · \(模型.桥接提示)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                if let urls = 通用导入窗口控制器.shared.选文件() { 模型.加入(urls) }
            } label: {
                Label("添加文件", systemImage: "plus")
                    .font(.system(size: 11))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(模型.当前阶段 != .配置)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var 空态: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)
            Text("把模型文件拖进来，或点「添加文件」")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text("支持 fbx / blend / usd 全家族 / gltf / glb / obj / stl / ply，二进制与文本不区分")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Tab 条

    private var Tab条: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(模型.出现的格式) { 格式 in
                    let 选中 = 模型.选中Tab == 格式
                    Button {
                        模型.选中Tab = 格式
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: 格式.符号)
                                .font(.system(size: 10))
                            Text(格式.标题)
                                .font(.system(size: 11, weight: 选中 ? .semibold : .regular))
                            Text("\(模型.计数(格式))")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(选中 ? Color.accentColor.opacity(0.16) : Color.clear)
                        }
                        .foregroundStyle(选中 ? Color.accentColor : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
    }

    // MARK: 文件栏

    private var 文件栏: some View {
        VStack(spacing: 0) {
            if let Tab = 模型.选中Tab {
                HStack(spacing: 6) {
                    Text(Tab.摘要)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Divider()
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(模型.文件集(Tab)) { 文件 in
                            文件行(文件)
                            Divider().padding(.leading, 34)
                        }
                    }
                }
            } else {
                Spacer()
            }
        }
    }

    private func 文件行(_ 文件: 导入文件) -> some View {
        let 选中 = 选中文件ID == 文件.id
        return HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { 文件.启用 },
                set: { 新值 in
                    guard let 序 = 模型.文件表.firstIndex(where: { $0.id == 文件.id }) else { return }
                    模型.文件表[序].启用 = 新值
                }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()

            Image(systemName: 文件.格式.符号)
                .font(.system(size: 11))
                .foregroundStyle(选中 ? Color.accentColor : .secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(文件.名称)
                    .font(.system(size: 11, weight: 选中 ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(文件.嗅探说明)
                    Text("·")
                    Text("原生解析")
                    if let 大小 = 文件大小(文件.url) {
                        Text("·")
                        Text(大小)
                    }
                }
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button {
                模型.移除(文件)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .disabled(模型.当前阶段 != .配置)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .background(选中 ? Color.accentColor.opacity(0.10) : Color.clear)
        .opacity(文件.启用 ? 1 : 0.45)
        .onTapGesture { 选中文件ID = 文件.id }
    }

    private func 文件大小(_ url: URL) -> String? {
        guard let 值 = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return nil }
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: Int64(值))
    }
}

// MARK: - 参数栏与底栏

extension 通用导入视图 {

    var 参数栏: some View {
        VStack(spacing: 0) {
            if let 文件 = 当前选中, let Tab = 模型.选中Tab {
                HStack(spacing: 8) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text("\(Tab.标题) 导入参数")
                        .font(.system(size: 11, weight: .semibold))
                    Spacer()
                    if 模型.计数(Tab) > 1 {
                        Button {
                            模型.应用到本Tab(文件)
                        } label: {
                            Text("应用到本 Tab 全部")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.borderless)
                        .disabled(模型.当前阶段 != .配置)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(文件.名称)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        坐标块(文件)
                        Divider()
                        几何块(文件)
                        Divider()
                        专属块(文件)
                    }
                    .padding(12)
                }
                .disabled(模型.当前阶段 != .配置)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "cursorarrow.click")
                        .font(.system(size: 22))
                        .foregroundStyle(.tertiary)
                    Text("在左侧选一个文件来调参数")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if 模型.当前阶段 != .配置 {
                Divider()
                结果区
            }
        }
    }

    // MARK: 参数块

    private func 块<内容: View>(_ 标题: String, @ViewBuilder 内容: () -> 内容) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(标题)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            内容()
        }
    }

    private func 开关(_ 标题: String, 说明: String? = nil, 值: Binding<Bool>) -> some View {
        Toggle(isOn: 值) {
            VStack(alignment: .leading, spacing: 1) {
                Text(标题).font(.system(size: 11))
                if let 说明 {
                    Text(说明).font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
    }

    private func 坐标块(_ 文件: 导入文件) -> some View {
        块("坐标") {
            HStack(spacing: 8) {
                Text("源上轴").font(.system(size: 11)).frame(width: 64, alignment: .leading)
                Picker("", selection: 模型.绑定(文件, \.源上轴)) {
                    Text("自动（\(文件.推断上轴.标题)）").tag(上轴?.none)
                    ForEach(上轴.allCases) { 轴 in
                        Text(轴.标题).tag(上轴?.some(轴))
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 150)
                Spacer()
            }
            if 文件.推断上轴 == .y {
                Text("App 是 Y 向上。这类文件的几何进来时通常已经是 Y 朝向，一般不用动；模型躺下了就手动选 Z 向上翻一次。")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("该格式默认 Z 向上，导入时会绕 X 轴 -90° 转成 Y 向上（不含镜像，法线不反）。")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Text("额外缩放").font(.system(size: 11)).frame(width: 64, alignment: .leading)
                TextField("1.0", value: 模型.绑定(文件, \.额外缩放), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 90)
                Stepper("", value: 模型.绑定(文件, \.额外缩放), in: 0.0001...10000, step: 0.1)
                    .labelsHidden()
                    .controlSize(.mini)
                Spacer()
            }
            开关("归一化尺寸", 说明: "把最长边缩到 1.5，和 App 内置形体一个量级", 值: 模型.绑定(文件, \.归一化尺寸))
            开关("米制换算", 说明: "按文件声明的单位换算到米；关掉则用原始数值", 值: 模型.绑定(文件, \.采用米制换算))
        }
    }

    private func 几何块(_ 文件: 导入文件) -> some View {
        块("几何") {
            开关("重算法线", 说明: "删掉文件自带法线，按面法线重算（导入后出现硬边/暗面时才开）", 值: 模型.绑定(文件, \.重算法线))
            开关("焊接顶点", 说明: "合并重合顶点，能减少路径追踪的重复求交", 值: 模型.绑定(文件, \.焊接顶点))
            开关("合并为单对象", 说明: "把一个文件拆出来的多个网格并成一个，场景树更干净", 值: 模型.绑定(文件, \.合并为单对象))
            开关("保留层级", 说明: "按文件里的节点层级拆成多个对象；关掉则拍平", 值: 模型.绑定(文件, \.保留层级))
        }
    }

    @ViewBuilder
    private func 专属块(_ 文件: 导入文件) -> some View {
        switch 文件.格式 {
        case .fbx, .blend:
            块(文件.格式.标题 + " 专属") {
                开关("应用变换", 说明: "把节点 TRS 烘进顶点；关掉则保留原始变换矩阵", 值: 模型.绑定(文件, \.应用变换))
                开关("导入动画", 说明: "读取动画曲线（当前只记录，视口暂不播放）", 值: 模型.绑定(文件, \.导入动画))
                Text("原生解析，跟随文件内声明的 UpAxis。")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        case .usd:
            块("USD 专属") {
                HStack(spacing: 8) {
                    Text("根 Prim").font(.system(size: 11)).frame(width: 64, alignment: .leading)
                    TextField("留空 = 默认 prim", text: 模型.绑定(文件, \.根Prim))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 170)
                    Spacer()
                }
                开关("展平实例", 说明: "把 instanceable 引用展开成实体网格", 值: 模型.绑定(文件, \.展平实例))
                Text("usda 文本原生解析；usdc/usdz 按容器格式读取，不依赖外部软件。")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        case .obj:
            块("OBJ 专属") {
                开关("读取 MTL", 说明: "顺带读同目录的 .mtl 拿基础色/粗糙度", 值: 模型.绑定(文件, \.读取MTL))
                开关("按组拆分", 说明: "g / o 分组各成一个对象", 值: 模型.绑定(文件, \.OBJ按组拆分))
            }
        case .gltf:
            块("glTF 专属") {
                开关("导入材质", 说明: "读 PBR 基础色/金属度/粗糙度", 值: 模型.绑定(文件, \.GLTF导入材质))
                开关("保留非三角图元", 说明: "线和点也建对象（路径追踪只认三角形）", 值: 模型.绑定(文件, \.GLTF保留非三角图元))
            }
        case .stl, .ply:
            块(文件.格式.标题 + " 说明") {
                Text(文件.格式 == .stl
                     ? "STL 只有三角面，没有材质与层级，导入后按单一对象处理。"
                     : "PLY 可能带顶点色或点云；点云部分不进入渲染。")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .mtlx:
            块("MaterialX 说明") {
                Text("材质文件，不含几何：选中后直接进材质库（节点图 + OpenPBR 基线），不生成物体。")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: 结果区

    @ViewBuilder
    private var 结果区: some View {
        VStack(alignment: .leading, spacing: 6) {
            if 模型.当前阶段 == .执行 {
                ProgressView(value: 模型.进度比)
                    .progressViewStyle(.linear)
                Text(模型.进度文本)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else if let 结果 = 模型.结果 {
                HStack(spacing: 10) {
                    Label("成功 \(结果.成功.count)", systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                    if !结果.失败.isEmpty {
                        Label("失败 \(结果.失败.count)", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    Text(结果.摘要行)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .font(.system(size: 10))

                if 结果.已取消 {
                    Text("已取消，只处理了前面几个文件").font(.system(size: 10)).foregroundStyle(.orange)
                }
                ForEach(Array(结果.失败.enumerated()), id: \.offset) { _, 项 in
                    Text("· \(项.文件.名称)：\(项.原因)")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                let 报告 = 结果.成功.flatMap { 项 in 项.场景.报告.map { "\(项.文件.名称)：\($0)" } }
                if !报告.isEmpty {
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(报告.enumerated()), id: \.offset) { _, 行 in
                                Text("· \(行)").font(.system(size: 9)).foregroundStyle(.secondary)
                            }
                        }
                    } label: {
                        Text("解析说明（\(报告.count)）").font(.system(size: 10))
                    }
                }
            }
        }
        .padding(12)
    }

    // MARK: 底栏

    var 底栏: some View {
        HStack(spacing: 10) {
            if let 错误 = 模型.错误文本 {
                Text(错误)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
            Spacer()
            switch 模型.当前阶段 {
            case .配置:
                Button("取消") { 通用导入窗口控制器.shared.关闭() }
                    .controlSize(.small)
                Button("开始导入") { 模型.开始导入() }
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
                
            case .执行:
                Button("停止") { 模型.取消() }
                    .controlSize(.small)
                
            case .完成:
                Button("关闭") { 通用导入窗口控制器.shared.关闭() }
                    .controlSize(.small)
                Button("放入场景") { 放入场景(模型.结果?.成功.map(\.场景) ?? []) }
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
                    .disabled((模型.结果?.成功.isEmpty ?? true))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
    }
}
