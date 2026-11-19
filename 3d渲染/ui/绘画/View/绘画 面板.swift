import SwiftUI
import MetalKit

/// 左下角绘画面板：对象 → 图层 → 笔刷。
/// 只在绘画开关打开时出现；关掉就彻底消失，不占视口也不吃事件。
///
/// 它读的是 PaintEngine 里那套「对象 → 图层栈 → 图层」模型，
/// 面板只负责改元数据（显隐 / 不透明度 / 混合）和切当前图层，
/// 像素本身永远在 PaintEngine 的 layerArray 里，两边不重复存。
@MainActor
struct PaintPanelView: View {
    /// 会进 PT 的可见对象（图集 slice 也按这个顺序排）
    var objects: [SceneObject]
    /// 面板可用空间（视口尺寸减去底栏和留白）。传 .zero 就是「不限」，用默认尺寸。
    var 可用: CGSize = .zero

    /// 左右栏之间的间距（HStack spacing）与 Divider 占位，算右栏可用宽时要扣掉
    private let 分栏间距: CGFloat = 8
    private let 分隔宽: CGFloat = 1
    /// 内容左右 padding 各 10
    private let 内容边距: CGFloat = 10

    /// 整块宽度：跟着视口收，但要保证两栏都装得下自己的最小内容。
    ///
    /// 之前按视口 28% 夹在 190..250，窗口一窄就只剩一百六七的内容宽，
    /// 左栏的三个按钮行、右栏的三段分段控件都超出去了 —— 溢出的部分会跑出
    /// 半透明背景之外，看着像"改坏了"。所以下限必须按内容算，不能按比例算。
    private var 面板宽: CGFloat {
        guard 可用.width > 0 else { return 340 }
        return min(400, max(340, 可用.width * 0.34))
    }

    /// 扣掉 padding 后真正能放进内容的宽度
    private var 内容宽: CGFloat { 面板宽 - 内容边距 * 2 }

    /// 左列（对象 + 图层）；右侧留给笔刷参数。
    /// 图层行里要塞 眼睛 + 名字 + 百分比 + 混合模式，左列太窄名字会被压成方块。
    private var 左列宽: CGFloat {
        min(172, max(148, 内容宽 * 0.46))
    }

    /// 图层列表最多占这么高，再长的部分自己滚动，不让面板往上长到顶栏
    private var 图层区最大高: CGFloat {
        guard 可用.height > 0 else { return 120 }
        return max(76, min(180, 可用.height * 0.34))
    }

    @State private var 会话 = PaintSession.shared
    @State private var 引擎 = PaintEngine.shared
    @State private var 折叠 = false
    /// 正在改名的那一层（双击图层名进入编辑）
    @State private var 改名中: UUID?
    @State private var 改名字: String = ""
    /// 遮罩图案菜单（点画板弹出来换图案）
    @State private var 图案菜单开 = false
    /// 通道面板开不开。通道是全局的（挂在笔刷上），面板不跟任何图层/对象绑定，
    /// 所以这里只是一个开关。常驻面板：里面怎么点都不收，只有点面板外面才关。
    @State private var 通道面板开 = false
    /// 鼠标压在外圈旋转带上：环亮起来，告诉用户「这儿能转」
    @State private var 悬停环带 = false
    @FocusState private var 名字焦点: UUID?

    private var 当前对象: SceneObject? {
        if let id = 会话.当前对象ID,
           let object = objects.first(where: { $0.id == id }) {
            return object
        }
        return objects.first { $0.isVisible }
    }

    private var 当前栈: PaintStack? {
        当前对象.map { 引擎.stack(for: $0.id) }
    }

    /// 当前选中的那层。右栏的通道入口只有一个，它针对的就是这一层
    private var 活动层: (栈: PaintStack, layer: PaintLayer)? {
        guard let 栈 = 当前栈,
              栈.activeIndex >= 0,
              栈.activeIndex < 栈.layers.count else { return nil }
        return (栈, 栈.layers[栈.activeIndex])
    }

    var body: some View {
        // 读一眼 revision：落笔、新建图层、改不透明度都会 +1，面板跟着重算
        let _ = 引擎.revision
        VStack(alignment: .leading, spacing: 8) {
            标题行
            if !折叠 {
                // 左图层 / 右参数：图层列表天生是纵向长的，参数是成组的一小撮。
                // 左右分栏后图层能多露几行，参数也不用跟图层抢纵向空间。
                // 尺寸按「小窗口也要放得下」定：整块宽度跟视口按比例收，左列 44%，右列吃掉剩下的。
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 6) {
                        对象行
                        图层区
                    }
                    .frame(width: 左列宽, alignment: .leading)

                    Divider().opacity(0.3)

                    笔刷区
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(10)
        // 高度只按内容长，绝不被父级 HStack/VStack 拉伸（此前被拉到 453 高就是这个原因）
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 面板宽)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(Theme.stroke, lineWidth: 1)
        )
    }

    // MARK: 标题

    private var 标题行: some View {
        HStack(spacing: 5) {
            Image(systemName: "paintbrush.pointed.fill")
                .font(.system(size: 11))
                .foregroundStyle(Color.accentColor)
            Text("绘画")
                .font(.system(size: 11, weight: .semibold))
            Spacer(minLength: 0)
            if !折叠, 会话.brush.mode != .绘画 {
                HStack(spacing: 3) {
                    Image(systemName: 会话.brush.mode.图标)
                        .font(.system(size: 8, weight: .semibold))
                    Text(会话.brush.mode.名称)
                        .font(.system(size: 9, weight: .semibold))
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.orange.opacity(0.25)))
                .foregroundStyle(.orange)
            }
            Button {
                折叠.toggle()
            } label: {
                Image(systemName: 折叠 ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
        }
    }

    // MARK: 对象

    private var 对象行: some View {
        HStack(spacing: 5) {
            Text("对象")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Menu {
                ForEach(objects) { object in
                    Button {
                        会话.选中对象(object.id)
                    } label: {
                        Label(
                            object.name,
                            systemImage: object.id == 当前对象?.id ? "checkmark" : object.symbol
                        )
                    }
                }
                if objects.isEmpty {
                    Text("场景里还没有物体").disabled(true)
                }
            } label: {
                Text(当前对象?.name ?? "—")
                    .font(.system(size: 11))
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: 图层

    private var 图层区: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Text("图层")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button {
                    guard let id = 当前对象?.id else { return }
                    引擎.新建图层(objectID: id)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 16, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("新建图层")
                Button {
                    guard let id = 当前对象?.id, let 栈 = 当前栈 else { return }
                    引擎.删除图层(objectID: id, index: 栈.activeIndex)
                    // 被删的层可能正在改名，收掉编辑态
                    改名中 = nil
                    名字焦点 = nil
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 16, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("删除当前图层（删掉最后一层会自动补一个新图层）")
                Button {
                    会话.撤销()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 16, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("撤销上一笔（⌘Z）")
            }

            if let 栈 = 当前栈 {
                // 倒序显示：习惯上图层叠在下面的画在最下面
                // 用 id 作 ForEach 标识（不是下标）：删层后旧行视图不会错配到别人身上
                if 栈.layers.count <= 3 {
                    VStack(spacing: 3) {
                        ForEach(Array(栈.layers.reversed()), id: \.id) { layer in
                            图层行(栈: 栈, layer: layer)
                        }
                    }
                } else {
                    // 层多了就自己滚：面板高度到此为止，不再往上顶到顶栏去
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 3) {
                            ForEach(Array(栈.layers.reversed()), id: \.id) { layer in
                                图层行(栈: 栈, layer: layer)
                            }
                        }
                    }
                    .frame(height: 图层区最大高)
                }
            } else {
                Text("先在视口里画一笔，或选个对象")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func 图层行(栈: PaintStack, layer: PaintLayer) -> some View {
        let 选中 = 栈.activeIndex < 栈.layers.count && 栈.layers[栈.activeIndex].id == layer.id
        return VStack(spacing: 2) {
            HStack(spacing: 4) {
                Button {
                    guard let i = 当前下标(of: layer, in: 栈) else { return }
                    栈.layers[i].isVisible.toggle()
                    引擎.图层已变更(objectID: 栈.objectID)
                } label: {
                    Image(systemName: layer.isVisible ? "eye" : "eye.slash")
                        .font(.system(size: 10))
                        .foregroundStyle(layer.isVisible ? Color.secondary : Color.secondary.opacity(0.45))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help(layer.isVisible ? "隐藏图层" : "显示图层")

                if 改名中 == layer.id {
                    TextField("图层名", text: $改名字)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, weight: 选中 ? .semibold : .regular))
                        .focused($名字焦点, equals: layer.id)
                        .onSubmit { 提交改名(栈: 栈, layer: layer) }
                        .onExitCommand {
                            改名中 = nil
                            名字焦点 = nil
                        }
                        .onChange(of: 名字焦点) { _, 新 in
                            // 点到别处也算确认，别让用户输完名字却因为没按回车而丢掉
                            if 新 != layer.id, 改名中 == layer.id {
                                提交改名(栈: 栈, layer: layer)
                            }
                        }
                } else {
                    Text(layer.name)
                        .font(.system(size: 11, weight: 选中 ? .semibold : .regular))
                        .lineLimit(1)
                        .onTapGesture(count: 2) {
                            改名字 = layer.name
                            改名中 = layer.id
                            名字焦点 = layer.id
                        }
                        .help("双击可改名")
                }
                Spacer(minLength: 0)
                Text("\(Int((layer.opacity * 100).rounded()))%")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                混合模式菜单(栈: 栈, layer: layer)
            }
            Slider(
                value: Binding(
                    // 取值也走 id 反查：这一帧万一这层已经被删了，退回 layer 自带的旧值，
                    // 不能再去碰数组下标（那是崩溃点）
                    get: { Double(栈.layers.first { $0.id == layer.id }?.opacity ?? layer.opacity) },
                    set: { 新 in
                        guard let i = 当前下标(of: layer, in: 栈) else { return }
                        栈.layers[i].opacity = Float(新)
                        // 拖滑块时每帧重合成：1024² 图集几个 slice，代价一两毫秒，换来实时反馈
                        引擎.图层已变更(objectID: 栈.objectID)
                    }
                ),
                in: 0...1
            )
            .controlSize(.mini)
            .tint(Color.accentColor)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(选中 ? Color.accentColor.opacity(0.14) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            guard let i = 当前下标(of: layer, in: 栈) else { return }
            引擎.切到图层(objectID: 栈.objectID, index: i)
        }
    }

    /// 图层行右端的混合模式下拉（从通道浮层里拆出来的，占的就是原来通道图标那个位置）。
    /// 用 Menu 自己拼标签：系统 Picker 会按最长选项撑宽（"正片叠底"四个字直接把窄图层行挤爆），
    /// 这里只显示当前模式的短名 + 小箭头，宽度跟着内容走。
    /// 只影响合成，不碰像素。
    private func 混合模式菜单(栈: PaintStack, layer: PaintLayer) -> some View {
        let 当前 = 栈.layers.first { $0.id == layer.id }?.blend ?? layer.blend
        let 唯一层 = 栈.layers.count <= 1
        return Menu {
            ForEach(PaintBlend.allCases, id: \.self) { b in
                Button {
                    guard let i = 当前下标(of: layer, in: 栈) else { return }
                    栈.layers[i].blend = b
                    // 混合模式只影响合成，不碰像素
                    引擎.图层已变更(objectID: 栈.objectID)
                } label: {
                    if b == 当前 {
                        Label(b.title, systemImage: "checkmark")
                    } else {
                        Text(b.title)
                    }
                }
            }
        } label: {
            HStack(spacing: 1) {
                Text(自定短名(当前))
                    .font(.system(size: 9))
                Image(systemName: "chevron.down")
                    .font(.system(size: 6, weight: .bold))
            }
            .foregroundStyle(唯一层 ? Color.secondary.opacity(0.45) : Color.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        // 只有一层时没有下层可混：三种模式在这个栈里都等价于「覆盖」，
        // 置灰免得以为选了没反应
        .disabled(唯一层)
        .help(唯一层
              ? "只有一层：没有下层可混，就是直接盖在模型表面上（等价覆盖）"
              : "这一层跟下面图层怎么叠")
    }

    /// 图层行里只放得下两个字的模式名
    private func 自定短名(_ b: PaintBlend) -> String {
        switch b {
        case .normal: return "正常"
        case .multiply: return "叠底"
        case .add: return "叠加"
        }
    }

    /// 右栏（笔刷参数区）行尾的通道入口。点一下弹出常驻面板，再点一下收起；
    /// 面板里怎么点滑杆都不会收，只有点面板外面才关 —— 这正好是 popover 的原生行为。
    ///
    /// 通道本身是全局的（挂在笔刷上）：不看当前是哪层、哪个对象，
    /// 开了就所有层所有对象都按这套落笔，所以这个入口也不需要图层参数。
    private func 通道入口() -> some View {
        Button {
            通道面板开.toggle()
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(通道面板开 ? Color.accentColor : Color.secondary)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help("通道开关 / 值（全局，与图层无关）")
        .popover(isPresented: $通道面板开, arrowEdge: .top) {
            通道面板()
        }
    }

    /// 常驻的通道面板：每个通道一行「开关 + 值」。
    /// 键名严格对应 OpenPBR 参数：P0（颜色/粗糙度/金属度/法线）在上，P1 在下。
    private func 通道面板() -> some View {
        VStack(alignment: .leading, spacing: 7) {
            // 预览球 = 「按现在这套开关和值落一笔，表面会长成什么样」。
            // 只看开关和值，不看「落没落过这个通道的笔」：
            // 那个过滤会让没画过的通道拖滑杆纹丝不动，看着更像坏了。
            通道预览图(参数: 通道预览Uniforms(笔刷: 会话.brush))
                .frame(height: 104)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
                )
            Divider()
            ForEach(PaintChannel.allCases.filter(\.是基础), id: \.self) { ch in
                通道强度行(ch: ch)
            }
            Divider()
            ForEach(PaintChannel.allCases.filter { !$0.是基础 }, id: \.self) { ch in
                通道强度行(ch: ch)
            }
        }
        .padding(10)
        .frame(width: 236)
    }

    /// 单个通道一行：左边开关管「参不参与」，右边滑杆管「值」。
    ///
    /// 这两件事以前混在一根滑杆里（滑杆其实是覆盖率，值写死成默认值），
    /// 于是面板上那个「0.25」既不像开关也不像参数，谁看谁懵。
    /// 现在开关和值都存在笔刷上，改一次全局生效。
    private func 通道强度行(ch: PaintChannel) -> some View {
        let 开 = 会话.brush.开着(ch)
        // 清漆粗糙度和清漆共用「清漆」那一个开关：这里不再给第二个勾，
        // 只留滑杆（留个等宽空位，两行文字才对得上）
        let 自己带开关 = (ch.开关通道 == ch)
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                if 自己带开关 {
                    Toggle("", isOn: Binding(
                        get: { 会话.brush.开着(ch) },
                        set: { 新 in
                            会话.brush.设置开关(ch, 开: 新)
                            // 开关只管「接下来的笔写不写这个通道」，
                            // 已画上去的内容一点不动，所以不需要重合成。
                        }
                    ))
                    .toggleStyle(.checkbox)
                    .controlSize(.mini)
                    .labelsHidden()
                } else {
                    Color.clear.frame(width: 14, height: 14)
                }
                Text(ch.名称)
                    .font(.system(size: 10))
                    .foregroundStyle(开 ? Color.primary : Color.secondary)
                Spacer(minLength: 0)
                Text(值文本(ch: ch))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(开 ? Color.secondary : Color.secondary.opacity(0.45))
            }
            .help(自己带开关
                  ? (开 ? "落笔会写这个通道" : "落笔不写这个通道；已经画上去的不受影响")
                  : "跟「清漆」共用开关，这里只调值")
            // 颜色吃笔刷色、法线是逐像素算出来的凹凸，没单值可调；其余都能拖
            if ch.有值滑杆 {
                Slider(value: Binding(
                    get: { Double(会话.brush.值(ch)) },
                    set: { 新 in
                        会话.brush.通道值[ch] = Float(新)
                        // 值只改元数据，合成时整块通道按新值重算，已画过的地方一起变
                        引擎.通道已变更()
                    }
                ), in: 0...(ch == .emission ? 4 : 1))
                .controlSize(.mini)
                .tint(开 ? Color.accentColor : Color.secondary)
                .disabled(!开)
                .help(ch == .emission
                      ? "自发光亮度：图集里存的是笔刷色，这里乘上强度，已画过的地方一起变"
                      : "落笔写进这个通道的值（就是 OpenPBR 参数本身），拖它，已画过的地方一起改")
            }
        }
    }

    /// 通道右侧那个数字：常量通道给参数值本身（粗糙度就显示 0.25），
    /// 自发光给的就是强度倍数，颜色吃笔刷色，法线是逐像素算出来的凹凸。
    private func 值文本(ch: PaintChannel) -> String {
        switch ch {
        case .baseColor: return "笔刷色"
        case .emission:  return String(format: "×%.2f", 会话.brush.值(ch))
        case .normal:    return "凹凸"
        default:         return String(format: "%.2f", 会话.brush.值(ch))
        }
    }

    /// 按图层 id 反查当前下标。
    ///
    /// 这是安全底线：ForEach 生成的旧行视图会带着上一帧的下标继续活着，
    /// 删层后数组变短，旧下标再去访问 `栈.layers[index]` 就是
    /// "Fatal error: Index out of range"。全部按 id 现查，删光了也只是返回 nil。
    private func 当前下标(of layer: PaintLayer, in 栈: PaintStack) -> Int? {
        栈.layers.firstIndex { $0.id == layer.id }
    }

    /// 提交改名：只写元数据，不动像素（名字不参与合成，不需要重合成）
    private func 提交改名(栈: PaintStack, layer: PaintLayer) {
        if let i = 当前下标(of: layer, in: 栈) {
            引擎.重命名图层(objectID: 栈.objectID, index: i, 名字: 改名字)
        }
        改名中 = nil
        名字焦点 = nil
    }

    // MARK: 笔刷

    private var 笔刷区: some View {
        VStack(alignment: .leading, spacing: 7) {
            // 三段式：绘画 / 擦除 / 镂空。
            // 擦除只削当前层 alpha（图层还在）；镂空是把这块表面真的挖掉 ——
            // 光线直接穿过去，用来做战损披风、破布、残缺这类"少了块肉"的地方。
            模式选择

            HStack(spacing: 5) {
                ColorPicker("", selection: Binding(
                    get: {
                        Color(
                            red: Double(会话.brush.color.x),
                            green: Double(会话.brush.color.y),
                            blue: Double(会话.brush.color.z)
                        )
                    },
                    set: { 新 in
                        let 组件 = NSColor(新).usingColorSpace(.sRGB) ?? .red
                        会话.brush.color = [
                            Float(组件.redComponent),
                            Float(组件.greenComponent),
                            Float(组件.blueComponent)
                        ]
                    }
                ))
                .labelsHidden()
                .frame(width: 34)
                .help("笔刷颜色（擦除、镂空不用）")

                Spacer(minLength: 0)

                // 通道开关 / 值的入口放在行尾（原来是那个 "r 0.12" 半径文字，
                // 数值对落笔没参考价值，删掉；大小看下面的滑杆就够）。
                // 它调的是「落笔落进哪些通道」—— 全局设置，没选中层/对象时也能改
                通道入口()
            }

            参数行("大小", value: Binding(
                get: { Double(会话.brush.radius) },
                set: { 会话.brush.radius = Float($0) }
            ), range: 0.02...0.6)

            参数行("硬度", value: Binding(
                get: { Double(会话.brush.hardness) },
                set: { 会话.brush.hardness = Float($0) }
            ), range: 0...1)

            参数行("不透明", value: Binding(
                get: { Double(会话.brush.opacity) },
                set: { 会话.brush.opacity = Float($0) }
            ), range: 0.05...1)

            Divider().opacity(0.25)

            遮罩区
        }
    }

    /// 模式切换。segmented 三段一屏看全，比下拉菜单少一次点击
    private var 模式选择: some View {
        Picker("", selection: Binding(
            get: { 会话.brush.mode },
            set: { 会话.brush.mode = $0 }
        )) {
            ForEach(PaintMode.allCases) { m in
                Text(m.名称).tag(m)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.mini)
        .font(.system(size: 10))
        .help(会话.brush.mode.说明)
    }

    /// 遮罩区：标题行里塞「遮罩 + 反转 + 图案名」，下面是一块能直接上手的画板。
    /// 画板画的就是笔刷圆圈本身 —— 拖图=移动、滚轮=缩放、右上角旋钮=旋转、单击=换图案。
    /// 面板里摆成什么样，视口圆圈里就是什么样：两边共用同一组 scale/rot/offset，
    /// 它们都只改「从遮罩图的哪儿采样」，图案和管线一个都不动。
    private var 遮罩区: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Text("遮罩")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                反转开关
                Spacer(minLength: 0)
                Text(会话.brush.mask.rawValue)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            遮罩画板
        }
    }

    /// 画板的边长。96 是「右栏在 288 面板宽下也装得下」和「拖起来够大」之间的折中
    private var 画板边长: CGFloat { 96 }

    private var 遮罩画板: some View {
        let 边长 = 画板边长
        let 无 = 会话.brush.mask == .无
        return ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.black.opacity(0.30))
            if let 图 = 会话.brush.mask.缩略图(256) {
                // 变换顺序必须和 shader 里那条采样公式是同一个：先缩放、再旋转、再平移。
                // 顺序一错，面板里摆正了，笔刷圈里却是歪的
                ZStack {
                    Image(nsImage: 图)
                        .resizable()
                        .interpolation(.none)
                        .frame(width: 边长, height: 边长)
                        .scaleEffect(CGFloat(max(会话.brush.maskScale, 0.05)))
                        .rotationEffect(.degrees(Double(会话.brush.maskRot)))
                        .offset(x: CGFloat(会话.brush.maskOffset.x) * 边长,
                                y: CGFloat(会话.brush.maskOffset.y) * 边长)
                        .遮罩反转(会话.brush.maskInvert)
                }
                .frame(width: 边长, height: 边长)
                .clipShape(Circle())
            } else {
                Text("无遮罩")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            // 外圈那道环：既是笔刷圆的边界（圈外不落笔），也是旋转的抓取带。
            // 鼠标压上去它自己会亮 —— 不用再教用户「先点图标再拖」，直接上手转
            Circle()
                .strokeBorder(悬停环带 && !无 ? Color.accentColor : Theme.stroke,
                              lineWidth: 悬停环带 && !无 ? 2 : 1)
                .frame(width: 边长 - 2, height: 边长 - 2)
                .opacity(无 ? 0.35 : 0.9)
                .allowsHitTesting(false)

            // 环上的小手柄：位置就是当前旋转角，转的时候它跟着走，一眼看出转了多少
            if !无 {
                ZStack {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 7, height: 7)
                        .offset(y: -(边长 / 2 - 1))
                }
                .frame(width: 边长, height: 边长)
                .rotationEffect(.degrees(Double(会话.brush.maskRot)))
                .allowsHitTesting(false)
            }

            遮罩交互层(
                边长: 边长,
                onTap: { 图案菜单开 = true },
                onDoubleTap: { 复位遮罩变换() },
                onReset: { 复位遮罩变换() },
                onHoverRing: { 悬停环带 = $0 },
                onDrag: { d in
                    guard 会话.brush.mask != .无 else { return }
                    var o = 会话.brush.maskOffset
                    // 单位是「一个笔刷边长」：拖到哪图案就到哪，1:1 跟手。
                    // 夹在 ±1 之内，免得图被拖到圈外再也抓不回来
                    o.x = min(max(o.x + Float(d.width / 边长), -1), 1)
                    o.y = min(max(o.y + Float(d.height / 边长), -1), 1)
                    会话.brush.maskOffset = o
                },
                onRotate: { 度 in
                    guard 会话.brush.mask != .无 else { return }
                    // 传进来的是「鼠标绕中心扫过的角度增量」，直接加 ——
                    // 所以手怎么转、图就怎么转，跟直觉对得上
                    var r = 会话.brush.maskRot + Float(度)
                    r = r.truncatingRemainder(dividingBy: 360)
                    if r < 0 { r += 360 }
                    会话.brush.maskRot = r
                },
                onScroll: { dy, 精确 in
                    guard 会话.brush.mask != .无 else { return }
                    // 触控板给的是像素级小量、鼠标滚轮是行级大量（一格才 1~3），
                    // 同一套系数下鼠标滚轮几乎没反应，所以两路分开算
                    let 灵敏度: CGFloat = 精确 ? 0.006 : 0.06
                    let 系数 = Float(exp(dy * 灵敏度))
                    会话.brush.maskScale = min(max(会话.brush.maskScale * 系数, 0.2), 4)
                }
            )
        }
        .frame(width: 边长, height: 边长)
        .overlay(alignment: .topTrailing) { 复位图标 }
        .contentShape(Rectangle())
        .popover(isPresented: $图案菜单开, arrowEdge: .bottom) { 图案菜单 }
        .help("单击换图案 · 中间拖动移动 · 滚轮缩放 · 拖外圈旋转 · 双击或点 ↺ 复位")
    }

    /// 右上角复位：图案滚飞了、转歪了、拖出圈了，一下全回到原大、不转、居中。
    /// 只是个图标，点击由下面的 AppKit 层接（那块区域在它上面，自己画自己接最可靠）
    private var 复位图标: some View {
        Image(systemName: "arrow.counterclockwise")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(会话.brush.mask == .无 ? Color.secondary : Color.accentColor)
            .frame(width: 17, height: 17)
            .background(Circle().fill(Color.black.opacity(0.42)))
            .padding(4)
            .allowsHitTesting(false)
            .help("复位：遮罩回到原大、不旋转、居中")
    }

    private var 图案菜单: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("遮罩图案")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .padding(.bottom, 3)
            ForEach(PaintMaskKind.allCases) { kind in
                Button {
                    会话.brush.mask = kind
                    图案菜单开 = false
                } label: {
                    HStack(spacing: 8) {
                        if let 图 = kind.缩略图(48) {
                            Image(nsImage: 图)
                                .resizable()
                                .interpolation(.none)
                                .frame(width: 20, height: 20)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        } else {
                            Color.clear.frame(width: 20, height: 20)
                        }
                        Text(kind.rawValue)
                            .font(.system(size: 11))
                        Spacer(minLength: 10)
                        if 会话.brush.mask == kind {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
            }
        }
        .padding(.vertical, 8)
        .frame(width: 148)
    }

    /// 双击画板复位：拖歪了、滚飞了，双击一步回到「原大、不转、居中」
    private func 复位遮罩变换() {
        会话.brush.maskScale = 1
        会话.brush.maskRot = 0
        会话.brush.maskOffset = .zero
    }

    /// 反转开关：现在贴在「遮罩」标题后面，和图案名一左一右，不再单独占一列
    private var 反转开关: some View {
        // 不加 fixedSize：这个开关在窄栏里必须能被压缩，硬撑宽会把整行顶出背景
        HStack(spacing: 4) {
            Toggle("", isOn: Binding(
                get: { 会话.brush.maskInvert },
                set: { 会话.brush.maskInvert = $0 }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .layoutPriority(1)
            Text("反转")
                .font(.system(size: 10))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .foregroundStyle(会话.brush.mask == .无 ? .tertiary : .secondary)
        }
        .disabled(会话.brush.mask == .无)
        .help("把图案的黑白对调（1↔0）：实心变留白、留白变实心。只改采样结果，不换图案；绘画和镂空共用，擦除不吃遮罩")
    }

    private func 参数行(_ 名称: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack(spacing: 5) {
            Text(名称)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .leading)
            Slider(value: value, in: range)
                .controlSize(.mini)
        }
    }
}


// MARK: - 遮罩画板的事件层

/// 面板里那块遮罩方图的所有操作都从这里进。
/// 之所以落到 AppKit：SwiftUI 没有滚轮事件，而「滚轮缩放 + 拖动平移 + 角上拖动旋转」
/// 必须共用同一个命中区域，拆成几个手势会互相抢事件（Menu 也会把拖拽吃掉，
/// 所以换图案也改成了单击弹 popover）。
/// 这一层只当事件通道，不画任何东西，视觉仍然全在 SwiftUI 那边。
private struct 遮罩交互层: NSViewRepresentable {
    var 边长: CGFloat
    var onTap: () -> Void
    var onDoubleTap: () -> Void
    /// 点了右上角的 ↺
    var onReset: () -> Void
    /// 鼠标压到外圈旋转带上 / 离开
    var onHoverRing: (Bool) -> Void
    /// 增量位移（pt），不是累计值：调用方按 /边长 换成归一化平移
    var onDrag: (CGSize) -> Void
    /// 绕中心扫过的角度增量（度），正 = 顺时针
    var onRotate: (CGFloat) -> Void
    /// scrollingDeltaY，正数 = 往上滚 = 放大；第二个参数 = 是否触控板/高精度设备
    var onScroll: (CGFloat, Bool) -> Void

    func makeNSView(context: Context) -> 遮罩事件视图 {
        let v = 遮罩事件视图()
        v.边长 = 边长
        return v
    }

    func updateNSView(_ v: 遮罩事件视图, context: Context) {
        v.边长 = 边长
        v.onTap = onTap
        v.onDoubleTap = onDoubleTap
        v.onReset = onReset
        v.onHoverRing = onHoverRing
        v.onDrag = onDrag
        v.onRotate = onRotate
        v.onScroll = onScroll
    }
}

/// 遮罩画板的事件层：中间拖 = 平移，外圈环带拖 = 旋转，滚轮 = 缩放，单击 = 换图案。
/// 旋转不用「图标 + 左右拖」那种做法了 —— 那和脑子里的「转」不是一回事；
/// 改成直接拖外圈：鼠标绕中心怎么扫，图就怎么转。
final class 遮罩事件视图: NSView {
    var 边长: CGFloat = 96
    var onTap: () -> Void = {}
    var onDoubleTap: () -> Void = {}
    var onReset: () -> Void = {}
    var onHoverRing: (Bool) -> Void = { _ in }
    var onDrag: (CGSize) -> Void = { _ in }
    var onRotate: (CGFloat) -> Void = { _ in }
    var onScroll: (CGFloat, Bool) -> Void = { _, _ in }

    /// 跟 SwiftUI 同一套坐标：原点左上、y 向下。不翻过来的话拖动方向会上下颠倒
    override var isFlipped: Bool { true }

    /// 窗口没焦点时第一下也要生效（面板经常和一个没聚焦的视口并排）
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// 外圈这么宽的一条算「旋转带」
    private let 旋转带宽: CGFloat = 18
    /// 滚轮还能吃到的额外边距：贴着画板边缘滚，也还算在调这块图
    private let 滚轮边距: CGFloat = 16

    private var 起点: CGPoint?
    private var 上次角: CGFloat = 0
    private var 累计: CGFloat = 0
    private var 旋转中 = false
    private var 滚轮监视: Any?
    private var 跟踪区: NSTrackingArea?

    private var 中心: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }

    /// 落在环带里 = 这次拖动是旋转。半径判据，和视觉上那圈描边对得上
    private func 在旋转带(_ p: CGPoint) -> Bool {
        let r = min(bounds.width, bounds.height) / 2
        let d = hypot(p.x - 中心.x, p.y - 中心.y)
        return d > r - 旋转带宽 && d <= r + 8
    }

    /// 右上角复位图标的位置（图标 17 + 边距 4，取 26 见方留点余量）
    private var 复位区: CGRect {
        CGRect(x: bounds.width - 26, y: 0, width: 26, height: 26)
    }

    /// flipped 坐标里 y 向下，atan2 的正方向正好是顺时针 —— 和 rotationEffect 一致
    private func 角度(_ p: CGPoint) -> CGFloat {
        atan2(p.y - 中心.y, p.x - 中心.x) * 180 / .pi
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let 旧 = 跟踪区 { removeTrackingArea(旧) }
        let 区 = NSTrackingArea(rect: bounds,
                              options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                              owner: self)
        addTrackingArea(区)
        跟踪区 = 区
    }

    override func mouseMoved(with 事件: NSEvent) {
        onHoverRing(在旋转带(convert(事件.locationInWindow, from: nil)))
    }

    override func mouseExited(with 事件: NSEvent) {
        onHoverRing(false)
    }

    override func mouseDown(with 事件: NSEvent) {
        let p = convert(事件.locationInWindow, from: nil)
        if 复位区.contains(p) {
            起点 = nil
            旋转中 = false
            onReset()
            return
        }
        if 事件.clickCount >= 2 {
            起点 = nil
            onDoubleTap()
            return
        }
        旋转中 = 在旋转带(p)
        起点 = p
        上次角 = 角度(p)
        累计 = 0
    }

    override func mouseDragged(with 事件: NSEvent) {
        guard let 起 = 起点 else { return }
        let p = convert(事件.locationInWindow, from: nil)
        累计 += abs(p.x - 起.x) + abs(p.y - 起.y)
        起点 = p
        if 旋转中 {
            let 角 = 角度(p)
            var d = 角 - 上次角
            // 跨过 ±180 那条缝要补一圈，否则会突然倒转一大截
            if d > 180 { d -= 360 } else if d < -180 { d += 360 }
            上次角 = 角
            onRotate(d)
        } else {
            onDrag(CGSize(width: p.x - 起.x, height: p.y - 起.y))
        }
    }

    override func mouseUp(with 事件: NSEvent) {
        let 有点 = 起点 != nil
        起点 = nil
        旋转中 = false
        // 几乎没挪动 = 单击（也避开了 Menu 那种「按下就弹、于是拖不动」的老问题）
        guard 有点, 累计 < 2 else { return }
        onTap()
    }

    // MARK: 滚轮

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        卸滚轮监视()
        guard window != nil else { return }
        // 滚轮不只看画板本体，还多看一圈边距：手贴边滚也是很自然的事。
        // 命中就吃掉，别让它漏到视口去改笔刷大小 —— 那是另一回事，很容易误操作
        滚轮监视 = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] 事件 in
            guard let self, let window = self.window, 事件.window === window else { return 事件 }
            let p = self.convert(事件.locationInWindow, from: nil)
            guard self.bounds.insetBy(dx: -self.滚轮边距, dy: -self.滚轮边距).contains(p) else { return 事件 }
            self.onScroll(事件.scrollingDeltaY, 事件.hasPreciseScrollingDeltas)
            return nil
        } as Any
    }

    deinit {
        if let 监视 = 滚轮监视 { NSEvent.removeMonitor(监视) }
    }

    private func 卸滚轮监视() {
        if let 监视 = 滚轮监视 { NSEvent.removeMonitor(监视); 滚轮监视 = nil }
    }

    override func scrollWheel(with 事件: NSEvent) {
        onScroll(事件.scrollingDeltaY, 事件.hasPreciseScrollingDeltas)
    }

    /// 这一层必须自己吃事件：否则外层 SwiftUI 手势会把拖动抢走，
    /// 拖到面板外时还会断
    override func hitTest(_ 点: NSPoint) -> NSView? {
        bounds.contains(convert(点, from: superview)) ? self : nil
    }
}

// MARK: - 面板里的通道预览

/// 预览用 uniform。字段顺序与字节排布必须和 绘画 笔刷.metal 里的
/// PaintPreviewParams 严格一致（float4 + 6 × float + float2 = 48 字节）。
private struct 通道预览Uniforms: Equatable {
    var color: SIMD4<Float> = SIMD4<Float>(0.92, 0.24, 0.18, 1)
    var roughness: Float = 0.45
    var metalness: Float = 0
    var normalStrength: Float = 0
    var coat: Float = 0
    var coatRoughness: Float = 0.3
    var emission: Float = 0
    var size: SIMD2<Float> = SIMD2<Float>(216, 104)

    init() {}

    /// 把全局通道开关和值翻译成一颗球的材质 —— 就是「按现在这套设置落一笔，
    /// 表面会长成什么样」。不分层：通道是全局的，预览看到的就是真正的落笔结果。
    init(笔刷: PaintBrush) {
        // 颜色通道关着就透出底盘（alpha 0），开着就是笔刷色本身
        color = SIMD4<Float>(笔刷.color.x, 笔刷.color.y, 笔刷.color.z, 笔刷.开着(.baseColor) ? 1 : 0)
        /// 开关关 = 这个特性完全不出现；开着就直接用这个通道的值
        func 生效(_ ch: PaintChannel) -> Float {
            笔刷.开着(ch) ? 笔刷.值(ch) : 0
        }
        // 关着时留一个中性哑光底材，开着才往这个通道该有的值靠
        roughness = 笔刷.开着(.roughness) ? 笔刷.值(.roughness) : 0.45
        metalness = 生效(.metalness)
        normalStrength = 笔刷.开着(.normal) ? 1 : 0
        coat = 生效(.coatWeight)
        coatRoughness = 笔刷.开着(.coatRoughness) ? 笔刷.值(.coatRoughness) : 0.3
        // 自发光：开着就按强度倍数亮，强度拖到 0 等于不发光
        emission = 生效(.emission)
    }
}

/// 预览球的绘制。用 MTKView 而不是现成的 3D 管线，
/// 是因为这里只需要「一颗球的材质」——不掺场景光照、不掺 PT 的合成，
/// 参数怎么调，球就怎么变，跟滑杆一一对得上。
@MainActor
private final class 通道预览MTKView: MTKView, MTKViewDelegate {
    var 参数 = 通道预览Uniforms()
    private let 队列: MTLCommandQueue?
    private var 管线: MTLRenderPipelineState?

    init() {
        let 设备 = MTLCreateSystemDefaultDevice()
        队列 = 设备?.makeCommandQueue()
        super.init(frame: CGRect(x: 0, y: 0, width: 216, height: 104), device: 设备)
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = true
        // 只在参数变了的时候重画一次，常驻面板不白烧 GPU
        isPaused = true
        enableSetNeedsDisplay = true
        autoResizeDrawable = true
        // 底色和片元里的 alpha 棋盘同色（白），首帧/边缘都不会闪出一条深灰边
        clearColor = MTLClearColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1)
        layer?.cornerRadius = 5
        layer?.masksToBounds = true
        delegate = self
    }

    required init(coder: NSCoder) { fatalError("不支持从 nib 加载预览") }

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    nonisolated func draw(in view: MTKView) {
        // MTKView 的回调本来就落在主线程，直接借用主线程上下文
        MainActor.assumeIsolated { 绘制() }
    }

    private func 绘制() {
        guard let 队列,
              let 管线 = 取管线(),
              let pass = currentRenderPassDescriptor,
              let drawable = currentDrawable,
              let 命令 = 队列.makeCommandBuffer() else { return }

        var u = 参数
        // 尺寸必须给 drawable 的真实像素数，否则球会被拉成椭圆
        u.size = SIMD2<Float>(Float(drawableSize.width), Float(drawableSize.height))

        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = clearColor
        guard let 编码 = 命令.makeRenderCommandEncoder(descriptor: pass) else { return }
        编码.setRenderPipelineState(管线)
        编码.setFragmentBytes(&u, length: MemoryLayout<通道预览Uniforms>.stride, index: 0)
        编码.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        编码.endEncoding()
        命令.present(drawable)
        命令.commit()
    }

    /// 管线只在第一帧建一次，后面复用
    private func 取管线() -> MTLRenderPipelineState? {
        if let 管线 { return 管线 }
        guard let device,
              let 库 = device.makeDefaultLibrary(),
              let 顶点函数 = 库.makeFunction(name: "paintPreviewVertex"),
              let 片元函数 = 库.makeFunction(name: "paintPreviewFragment") else { return nil }
        let 描述 = MTLRenderPipelineDescriptor()
        描述.vertexFunction = 顶点函数
        描述.fragmentFunction = 片元函数
        描述.colorAttachments[0].pixelFormat = colorPixelFormat
        let 新 = try? device.makeRenderPipelineState(descriptor: 描述)
        管线 = 新
        return 新
    }
}

private struct 通道预览图: NSViewRepresentable {
    var 参数: 通道预览Uniforms

    func makeNSView(context: Context) -> 通道预览MTKView {
        let 视图 = 通道预览MTKView()
        视图.参数 = 参数
        return 视图
    }

    func updateNSView(_ 视图: 通道预览MTKView, context: Context) {
        guard 视图.参数 != 参数 else { return }
        视图.参数 = 参数
        // 参数变了才重画：滑杆一路拖就一路跟着变
        视图.setNeedsDisplay(视图.bounds)
    }
}
