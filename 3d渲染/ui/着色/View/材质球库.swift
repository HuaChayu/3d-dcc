import AppKit
import Metal
import SceneKit
import SwiftUI

// MARK: - 底栏分页

/// 材质底栏的三页：材质球库（出厂预设/库条目） → 本项目（本工程全部材质） → 材质节点（当前材质的节点图）。
enum 材质底栏页: String, CaseIterable, Identifiable, Sendable {
    case 库
    case 本项目
    case 节点

    var id: String { rawValue }

    var title: String {
        switch self {
        case .库: "材质球库"
        case .本项目: "本项目"
        case .节点: "材质节点"
        }
    }

    var symbol: String {
        switch self {
        case .库: "circle.grid.2x2"
        case .本项目: "shippingbox"
        case .节点: "point.3.connected.trianglepath.dotted"
        }
    }
}

/// 材质球库这一页要列哪一份清单：库条目 / 本项目全部材质。
enum 材质清单范围 {
    case 库
    case 本项目
}

/// 两页共用的切换控件。
/// 节点页把它放在节点工具栏最前面，库页把它放在库工具栏最前面 —— 位置一致，
/// 切页时控件不会跟着跳，眼睛不用重新找。
struct 材质底栏切换控件: View {
    @Binding var 页: 材质底栏页

    var body: some View {
        Picker("", selection: $页) {
            ForEach(材质底栏页.allCases) { 项 in
                Text(项.title).tag(项)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 248)
        .help("切换底部面板：材质球库 / 本项目 / 当前材质节点")
    }
}

// MARK: - 材质球库

/// 材质球库：每个材质一颗球，拖到视口里就给那个物体上这个材质。
/// 只读 store，不改材质图 —— 节点页那套语义完全不受影响。
struct MaterialLibraryView: View {
    @Environment(着色Store.self) private var store
    @Environment(布局Store.self) private var scene

    @Binding var 页: 材质底栏页

    /// 这一页列哪份清单：材质球库列库条目，本项目列材质域全部材质
    var 范围: 材质清单范围 = .库

    private let 网格 = [GridItem(.adaptive(minimum: 104, maximum: 148), spacing: 10)]

    /// 清单来源：两页共用同一套网格 / 卡片 / 拖拽
    private var 列表: [MaterialAsset] { 范围 == .库 ? store.库材质列表 : store.本项目材质列表 }

    var body: some View {
        ScrollViewReader { 滚动 in
            ScrollView {
                LazyVGrid(columns: 网格, spacing: 10) {
                    ForEach(列表) { material in
                        材质球单元(
                            material: material,
                            使用数: store.库使用数(for: material.id),
                            选中: store.selectedMaterialID == material.id,
                            可另存: 范围 == .本项目,
                            // 库页拖出去派生成实例（库条目是模板）；本项目页拖出去就用它本身
                            派生: 范围 == .库,
                        )
                        .id(material.id)
                    }
                }
                .padding(.horizontal, 10)
                // 顶部留出浮层的高度，第一行卡片不被工具栏压住
                .padding(.top, 54)
                .padding(.bottom, 10)
            }
            // 全局搜索点中某个材质跳过来：把那张卡片滚进视野居中的位置。
            // 高亮本身不在这里管 —— 选中态 set 的那一刻卡片就已经是选中样式了。
            .onChange(of: store.库聚焦目标) { _, 目标 in
                滚动到目标(目标, 滚动: 滚动)
            }
            .onAppear {
                滚动到目标(store.库聚焦目标, 滚动: 滚动)
            }
        }
        // 背景与节点页完全同一套：同一底色 + 同一张点阵，
        // 切页时底部面板不会突然换一块底，视觉上不跳。
        .background {
            ZStack(alignment: .topLeading) {
                Theme.canvasBackground
                底栏点阵(scale: store.canvasScale, offset: store.canvasOffset)
            }
        }
        // 工具栏做成和节点页一样的浮动 HUD，而不是贴一条通栏
        .overlay(alignment: .topLeading) { 顶部条 }
    }

    /// 把目标材质卡片滚进视野，然后立刻消费掉这次请求（否则每次切回库页都会自己滚一次）
    private func 滚动到目标(_ 目标: UUID?, 滚动: ScrollViewProxy) {
        guard let 目标 else { return }
        Task { @MainActor in
            withAnimation(.easeOut(duration: 0.22)) {
                滚动.scrollTo(目标, anchor: .center)
            }
            if store.库聚焦目标 == 目标 { store.库聚焦目标 = nil }
        }
    }

    private var 顶部条: some View {
        HStack(spacing: 8) {
            材质底栏切换控件(页: $页)

            Divider().frame(height: 14)

            Button {
                store.addMaterial()
            } label: {
                Label("新建材质", systemImage: "plus.circle")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help("新建一个空材质")

            Spacer(minLength: 0)

            Text("拖到视口＝给物体上材质")
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9).stroke(Theme.divider, lineWidth: 1)
        )
        .padding(10)
    }
}

/// 与节点画布同款点阵：切页时底的纹理跟着画布状态走，不会一页有一页没有。
private struct 底栏点阵: View {
    let scale: CGFloat
    let offset: CGSize

    var body: some View {
        Canvas { context, size in
            let step: CGFloat = 24 * scale
            guard step > 6 else { return }
            let offsetX = offset.width.truncatingRemainder(dividingBy: step)
            let offsetY = offset.height.truncatingRemainder(dividingBy: step)
            var y = offsetY - step
            while y < size.height + step {
                var x = offsetX - step
                while x < size.width + step {
                    context.fill(
                        Path(ellipseIn: CGRect(x: x, y: y, width: 1.4, height: 1.4)),
                        with: .color(Theme.canvasGrid)
                    )
                    x += step
                }
                y += step
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - 单个材质球

private struct 材质球单元: View {
    @Environment(着色Store.self) private var store
    @Environment(布局Store.self) private var scene

    let material: MaterialAsset
    let 使用数: Int
    let 选中: Bool
    /// 只有「本项目」页给另存入口：库里那一条本身就是模板，不需要再存一份
    var 可另存: Bool = false
    /// true = 这格来自材质球库页：拖出去要派生成新实例（库条目是模板，原始样式不能被改脏）
    /// false = 这格来自「本项目」页：拖出去就直接用这条材质本身，不派生、不复制
    var 派生: Bool = true

    @State private var 图像: NSImage?
    @State private var 拖拽中 = false

    private let 球尺寸: CGFloat = 96

    /// 出图用的那份材质。
    /// 库页（派生）用出厂快照：库里那格是模板，调参不该改它的脸；
    /// 本项目页用当前值：这条材质就是工程数据，检查器改了什么，球就得跟着变。
    private var 源素材: MaterialAsset {
        派生 ? material.原始样式 : material
    }

    /// 材质外观签名：跟着 `源素材` 走，解析结果变了签名就变，`.task(id:)` 才会重取图
    private var 签名: String {
        材质缩略图键.key(MaterialCompiler.resolve(源素材))
    }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                // 出图带透明背景，球直接坐在卡片底色上，不再叠一层方格底
                if let 图像 {
                    Image(nsImage: 图像)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(1, contentMode: .fit)
                } else {
                    Circle()
                        .fill(Theme.color(from: 源素材.previewColor))
                        .frame(width: 56, height: 56)
                        .blur(radius: 0.4)
                }
            }
            .frame(height: 球尺寸)
            .overlay(alignment: .topTrailing) {
                if 使用数 > 0 {
                    Text("\(使用数)")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Theme.主色.opacity(0.85), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(5)
                        .help("\(使用数) 个物体在用这个材质")
                }
            }
            .overlay(alignment: .bottomLeading) {
                // 内置预设标一下：它们删不掉、也没有「恢复原始样式」这回事，要改就复制
                if material.是内置预设 {
                    Text("内置")
                        .font(.system(size: 8.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(5)
                        .help("出厂预设：不能删，也不用恢复原始样式；要改造就右键复制一份")
                }
            }

            Text(material.name)
                .font(.system(size: 10.5, weight: 选中 ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(选中 ? Theme.主色 : Color.primary)
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 11)
                .fill(选中 ? Theme.主色.opacity(0.10) : Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11)
                .stroke(选中 ? Theme.主色.opacity(0.55) : Theme.divider, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 11))
        .opacity(拖拽中 ? 0.55 : 1)
        .onTapGesture {
            store.selectedMaterialID = material.id
            store.selectedNodeID = nil
            store.note("选中材质 \(material.name)")
        }
        .contextMenu {
            Button("给选中物体上这个材质") {
                guard let 目标 = scene.selectedObjectID else {
                    store.note("先选一个物体，再上材质")
                    return
                }
                // 库页：从库里拿是拿原始样式，给物体挂一份新实例，之后调参动不到库
                // 本项目页：这条材质本身就是工程数据，直接挂它，不派生副本
                let 上手 = 派生 ? store.实例ID(for: material.id) : material.id
                scene.assign(上手, to: 目标)
                store.selectedMaterialID = 上手
            }
            Divider()
            // 库里的条目永远是原始样式，没有「改坏了要恢复」这回事，所以不给恢复入口
            Button("复制材质") { store.duplicateMaterial(material.id) }
            if 可另存 {
                Button("另存为新材质") { store.另存为新材质(material.id) }
            }
            // 两个删除不是一回事：库页删的是本地 .cgmat，本项目页只把它从工程里摘掉
            if 派生 {
                // 自定义材质 = 库页里非内置的那批，磁盘上有对应的 .cgmat，能直接在访达里定位
                if !material.是内置预设, let 文件 = 材质库文件.定位(id: material.id) {
                    Button("在访达中查看") {
                        NSWorkspace.shared.activateFileViewerSelecting([文件])
                    }
                }
                // 内置预设没有本地文件，是出厂数据，不给删
                if !material.是内置预设 {
                    Button("从材质库删除（连同本地文件）", role: .destructive) {
                        store.删除库材质(material.id)
                    }
                }
            } else {
                Button("从本项目删除", role: .destructive) {
                    store.deleteMaterial(material.id)
                }
            }
        }
        .onDrag {
            拖拽中 = true
            // 拖拽会话结束没有回调，本地态靠"下一次鼠标抬起"复位：给个延时兜底
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { 拖拽中 = false }
            return NSItemProvider(object: material.id.uuidString as NSString)
        } preview: {
            // 拖拽预览是个跟着鼠标跑的浮动快照。背景别用 ultraThinMaterial：
            // 那层是实时模糊，每一帧都要重新采样背后的窗口内容，鼠标一动就得重算一遍，
            // 跟不上时就表现为「方框停在半路，鼠标已经到对象上了」。
            // 半透明纯色一样能把内容托住，代价基本为零。
            HStack(spacing: 6) {
                if let 图像 {
                    Image(nsImage: 图像).resizable().frame(width: 34, height: 34)
                }
                Text(material.name).font(.system(size: 11))
            }
            .padding(6)
            .background(
                SwiftUI.Color(nsColor: .controlBackgroundColor).opacity(0.94),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Theme.stroke.opacity(0.55), lineWidth: 1)
            )
        }
        .task(id: 签名) {
            let resolved = MaterialCompiler.resolve(源素材)
            图像 = 材质球预览器.shared.图像(resolved, 签名: 签名, 尺寸: 球尺寸)
        }
    }
}

// MARK: - 材质球离屏渲染

/// 一颗球、一套三点光、一张假环境图，把 OpenPBR 参数渲成小图给库里看。
/// 走 SCNRenderer 离屏快照（和工程里的容器缩略图同一套做法），不额外占一路 RealityKit 管线，
/// 所以开着路径追踪视口也不会互相抢设备。
@MainActor
final class 材质球预览器 {
    static let shared = 材质球预览器()

    private let 场景 = SCNScene()
    private let 球节点 = SCNNode()
    private let 相机节点 = SCNNode()
    private var 渲染器: SCNRenderer?
    private var 渲染器不可用 = false
    private let 缓存 = NSCache<NSString, NSImage>()

    private init() {
        // 拖滑杆时签名一跳一张图，给缓存封个顶，别让历史图堆着占内存
        缓存.countLimit = 96
        搭建()
    }

    /// 尺寸按 point 传，实际按 >=3 倍出像素。
    /// 缩略图只有 26pt，2x 出图时球直径不到 45px，边缘全靠这几个像素去抗锯齿，
    /// 怎么调都是一个毛圈；多花点采样像素（一次性，且进缓存）比事后模糊干净得多。
    func 图像(_ resolved: ResolvedMaterial, 签名: String, 尺寸: CGFloat, 缩放: CGFloat = 0) -> NSImage? {
        let 倍率 = 缩放 > 0 ? 缩放 : max(3, NSScreen.main?.backingScaleFactor ?? 2)
        let 像素 = max(96, (尺寸 * 倍率).rounded())
        let 键 = "\(签名)|\(Int(像素))" as NSString
        if let 命中 = 缓存.object(forKey: 键) { return 命中 }
        guard !渲染器不可用, let 渲染器 = 渲染器 ?? 建渲染器() else { return nil }

        球节点.geometry?.firstMaterial = 映射材质(resolved.params)
        let 图 = 渲染器.snapshot(
            atTime: 0,
            with: CGSize(width: 像素, height: 像素),
            antialiasingMode: .multisampling8X
        )

        缓存.setObject(图, forKey: 键)
        return 图
    }

    // MARK: 场景

    private func 搭建() {
        // 不画底：出图带 alpha，球直接浮在面板自己的底色上。
        // 之前铺了一块 0.11 的灰，卡片底色和它差一点，边缘就显出一道方框。
        场景.background.contents = nil
        场景.lightingEnvironment.contents = 环境图()
        // 环境图顶部就是 0.95 白，强度再大 PBR 漫反射直接顶到 1.0 变白瓷球，
        // 陶土/橡胶这类本色全靠「灯 + 环境」总照度压在 1 附近才看得出来
        场景.lightingEnvironment.intensity = 0.55

        let 球 = SCNSphere(radius: 1)
        球.segmentCount = 96
        球.isGeodesic = false
        球节点.geometry = 球
        场景.rootNode.addChildNode(球节点)

        let 相机 = SCNCamera()
        相机.fieldOfView = 34
        相机.zNear = 0.1
        相机.zFar = 100
        相机.wantsHDR = true
        // 底色是透明的，bloom 只会在 alpha=0 的像素上算完丢掉（量过，球外一个亮点都不留），
        // 开着纯粹白烧 GPU，这里保持 0；发光观感改由映射里把发射色拉满来做
        相机.bloomIntensity = 0
        相机节点.camera = 相机
        // 相机拉远到球只占画面约 8 成：边缘留一圈余量，
        // 抗锯齿的半透明像素才不会被画面边界截断（之前贴边，剪影那一圈就是毛刺）
        相机节点.position = SCNVector3(0, 0, 4.15)
        场景.rootNode.addChildNode(相机节点)

        // 强度按「球面接收照度 ≈ 1」标定。原来是 900/380/220/110，等于把 albedo 0.6 的陶土
        // 也顶到 (1.0,1.0,1.0)，整库球长得一样，本色等于被照没了
        加灯(类型: .omni, 位置: SCNVector3(2.4, 2.8, 3.0), 强度: 40)
        加灯(类型: .omni, 位置: SCNVector3(-2.8, 0.6, 2.2), 强度: 18)
        加灯(类型: .omni, 位置: SCNVector3(0.4, -2.2, 1.6), 强度: 10)
        加灯(类型: .ambient, 位置: SCNVector3(0, 0, 0), 强度: 8)
    }

    private func 加灯(类型: SCNLight.LightType, 位置: SCNVector3, 强度: CGFloat) {
        let 灯 = SCNLight()
        灯.type = 类型
        灯.intensity = 强度
        灯.castsShadow = false
        let 节点 = SCNNode()
        节点.light = 灯
        节点.position = 位置
        场景.rootNode.addChildNode(节点)
    }

    private func 建渲染器() -> SCNRenderer? {
        guard let 设备 = MTLCreateSystemDefaultDevice() else {
            渲染器不可用 = true
            return nil
        }
        let 新 = SCNRenderer(device: 设备, options: nil)
        新.scene = 场景
        新.pointOfView = 相机节点
        渲染器 = 新
        return 新
    }

    /// 伪环境：上亮下暗的竖向渐变 + 一块柔和高光，金属和清漆才有东西可反
    private func 环境图() -> CGImage? {
        let 宽 = 512, 高 = 256
        guard let 空间 = CGColorSpace(name: CGColorSpace.sRGB),
              let 上下文 = CGContext(
                data: nil, width: 宽, height: 高,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: 空间, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }

        let 颜色们 = [
            NSColor(calibratedWhite: 0.95, alpha: 1).cgColor,
            NSColor(calibratedWhite: 0.42, alpha: 1).cgColor,
            NSColor(calibratedWhite: 0.08, alpha: 1).cgColor,
        ] as CFArray
        if let 渐变 = CGGradient(colorsSpace: 空间, colors: 颜色们, locations: [0, 0.55, 1]) {
            上下文.drawLinearGradient(
                渐变,
                start: CGPoint(x: 0, y: 高),
                end: CGPoint(x: 0, y: 0),
                options: []
            )
        }
        // 一块柔光：球顶部的高光来自这里
        上下文.setFillColor(NSColor(calibratedWhite: 1.0, alpha: 0.85).cgColor)
        // 宽高是 Int（要给 CGContext），这里换算成 CGFloat 再做比例，别让编译器猜
        let 宽f = CGFloat(宽)
        let 高f = CGFloat(高)
        let 柔光区 = CGRect(
            x: 宽f * 0.30,
            y: 高f * 0.58,
            width: 宽f * 0.30,
            height: 高f * 0.34
        )
        上下文.fillEllipse(in: 柔光区)
        return 上下文.makeImage()
    }

    // MARK: 映射

    /// OpenPBR → SceneKit 的 physicallyBased。只求"看得出是什么材质"，
    /// 不追求和 RealityKit 视口逐像素一致（薄膜、透射这类只能近似）。
    private func 映射材质(_ p: OpenPBRParams) -> SCNMaterial {
        let 材质 = SCNMaterial()
        材质.lightingModel = .physicallyBased
        材质.isDoubleSided = true

        var 基色 = p.color(.baseColor).clamped
        let 基重 = min(max(p.double(.baseWeight), 0), 1)
        if 基重 < 0.999 { 基色 = 基色.scaled(基重) }
        材质.diffuse.contents = 基色.nsColor

        let 粗糙 = min(max(p.double(.baseRoughness), 0.03), 1)
        材质.roughness.contents = NSNumber(value: 粗糙)
        材质.metalness.contents = NSNumber(value: min(max(p.double(.baseMetallic), 0), 1))

        // 发光：emission_luminance 0…8 → 0…1 的发光权重。
        // 旧写法是「发射色 × 权重」直接塞 emission，权重最大才 1.0，而灯又开着 900，
        // 结果灯把球打成白球、emission 只贡献一丝颜色，霓虹看着像白瓷。现在反过来：
        // 发光权重高就把漫反射压暗（自发光体本来不靠环境照亮，留着基色只会被灯打白），
        // 发射色直接按本色给到满，球面于是就是那颗饱和的发光色。
        let 发光色 = p.color(.emissionColor).clamped
        let 发光量 = min(max(p.double(.emissionLuminance), 0), 8) / 8
        if 发光量 > 0.02 {
            let 漫反射 = 1 - min(发光量 * 1.8, 1)
            if 漫反射 < 0.999 {
                基色 = 基色.scaled(漫反射)
                材质.diffuse.contents = 基色.nsColor
            }
            // 增益按「亮度 4（预设霓虹）= 发射色原样打满」标定，色相不会随亮度跑偏
            let 增益 = min(0.4 + 1.2 * 发光量, 1)
            材质.emission.contents = NSColor(
                srgbRed: CGFloat(发光色.r * 增益),
                green: CGFloat(发光色.g * 增益),
                blue: CGFloat(发光色.b * 增益),
                alpha: 1
            )
        }

        // 清漆：有就加一层，粗糙度跟着
        let 清漆 = min(max(p.double(.coatWeight), 0), 1)
        if 清漆 > 0.01 {
            材质.clearCoat.contents = NSNumber(value: 清漆)
            材质.clearCoatRoughness.contents = NSNumber(value: min(max(p.double(.coatRoughness), 0.02), 1))
        }

        // 透射 / 不透明度：SceneKit 没有 transmission，只能拿透明度近似
        let 透射 = min(max(p.double(.transmissionWeight), 0), 1)
        let 不透明 = min(max(p.double(.geometryOpacity), 0), 1)
        let 透明 = 不透明 * (1 - 透射 * 0.72)
        if 透明 < 0.999 {
            材质.transparency = 透明
            材质.blendMode = .alpha
        }

        return 材质
    }
}
