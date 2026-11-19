import Foundation
import Observation
import CoreGraphics

/// 着色工作区状态：材质库、材质节点图、OpenPBR 参数、3D 视口设置、节点编辑器视图变换。
///
/// 职责边界：
/// - 本 Store 只管"着色域"的真值与选中态；
/// - 场景物体（布局域）通过 `scene` 弱引用只读访问，不反向持有；
/// - 落盘与状态栏文案通过 `onChange` / `onNote` 回调交给根 `AppStore`，避免跨层强耦合。
@Observable
final class 着色Store {

    // MARK: 材质真值

    /// 材质真值已搬到数据层材质域（唯一所有者）。此处是**只读投影**：每次取都按域内顺序现算，
    /// 不另存任何数组 —— 所以不存在第二份材质。写入一律走本文件的写入方法 → 材质接线（令牌 .材质）。
    var materials: [MaterialAsset] {
        _ = 材质代
        // 用在册()而不是全部()：删除是延迟回收的，域里那条记录还在，
        // 但界面必须当它已经没了 —— 否则删完材质球还留在页面上，切个 tab 才消失。
        return 材质接线.共享.在册().map(\.记录.资产)
    }

    /// 投影失效信号：材质域写过一次就 bump 一次，@Observable 靠它让界面重新取投影。
    private(set) var 材质代: UInt64 = 0
    private func 材质已变() { 材质代 &+= 1 }
    var selectedMaterialID: UUID?
    var selectedNodeID: UUID?
    var selectedLinkID: UUID?

    // MARK: 视口设置

    var viewport: ViewportSettings = .default

    /// 全局物理（重力 / 风 / 流 / 湍流 / 阻力）：跟摄像机同口径的全局单体，
    /// 不是场景对象、不上大纲；所有特效发射器共用这一套力，各自按倍率决定吃多少。
    /// 随工程存盘（见 ProjectSnapshot.物理域）。
    var 物理域: 物理域 = .标准

    /// 轨道相机机位：保存时写进快照，打开工程后由视口面板取用还原。
    /// 视口里每次转/缩/平移都会刷新它（不额外写盘），随下一次 persist 落盘。
    var 视口相机存档: 视口相机存档?

    /// 机位还原信号：每次载入工程 +1，视口面板据此把存档套到相机上。
    /// 用计数器而不是直接观察存档本身，避免用户拖动时来回套用。
    var 相机还原信号: Int = 0

    // MARK: 节点编辑器视图状态

    var canvasScale: Double = 1
    var canvasOffset: CGSize = .zero

    // MARK: 工作区 UI 状态

    /// 节点区域高度占比（视口 / 节点 竖向分栏）
    var nodeAreaRatio: Double = 0.42
    var inspectorVisible: Bool = true
    var diagnosticsVisible: Bool = true

    /// N 面板（视口右侧抽屉）的可见性与当前页。
    /// 放在 store 里而不是工作区本地 @State：布局 / 着色两个工作区共用同一个视口，
    /// 按 N 的语义是「这个视口的抽屉开没开」，切 Tab 不该把它重置。
    var n面板可见: Bool = true
    var n面板页: N面板页 = .变换

    /// 底部面板当前页（材质球库 / 材质节点）。
    /// 放在 store 里而不是工作区本地 @State：全局搜索点击材质时要能把面板切到材质库。
    var 底栏页: 材质底栏页 = .节点

    /// 材质库请求滚动并聚焦到某个材质（全局搜索跳转用）；库里 scrollTo 后立刻清空
    var 库聚焦目标: UUID?

    /// 视口请求「把镜头对准某个物体」（全局搜索跳转用）。
    /// 用请求 + 序号而不是裸 UUID：同一个物体被反复搜到时也要能再次对焦。
    var 视口聚焦请求: 视口对焦请求?

    private var 视口聚焦计数 = 0
    private var 已消费视口聚焦序号 = 0

    /// 请求视口对焦某个物体（跨域：搜索面板 → 视口面板）
    func 请求视口聚焦(_ 物体: UUID) {
        视口聚焦计数 += 1
        视口聚焦请求 = 视口对焦请求(物体: 物体, 序号: 视口聚焦计数)
    }

    /// 视口取走一条尚未消费的对焦请求；同一条请求只会被返回一次，
    /// 序号记在 store 上而不是视图本地，避免切 tab 重建视口时重复对焦。
    func 取视口聚焦物体() -> UUID? {
        guard let 请求 = 视口聚焦请求, 请求.序号 > 已消费视口聚焦序号 else { return nil }
        已消费视口聚焦序号 = 请求.序号
        return 请求.物体
    }

    // MARK: 跨域协作

    /// 场景（布局域）只读引用，用于判断材质被哪些物体使用、当前选中物体绑定哪个材质
    weak var scene: 布局Store?

    /// 数据变更 → 根 Store 节流落盘
    var onChange: (() -> Void)?
    /// 状态栏文案 → 根 Store
    var onNote: ((String) -> Void)?
    /// 库材质只读提示的节流时间戳（拖动类操作每帧都会撞上来）
    @ObservationIgnored private var 上次库只读提示: Date = .distantPast

    // MARK: 派生

    var selectedMaterial: MaterialAsset? {
        guard let selectedMaterialID else { return nil }
        return materials.first { $0.id == selectedMaterialID }
    }

    var materialsByID: [UUID: MaterialAsset] {
        Dictionary(uniqueKeysWithValues: materials.map { ($0.id, $0) })
    }

    var resolvedSelected: ResolvedMaterial? {
        selectedMaterial.map { MaterialCompiler.resolve($0) }
    }

    /// 当前材质（检查器、节点编辑器实际在看/在改哪一份）。
    ///
    /// 口径：**显式点选优先**。在本项目页 / 材质库页 / 节点编辑器里点了哪条材质，
    /// 它就成为当前材质；没有任何点选时才回落到选中物体绑定的材质。
    /// 以前是「物体材质优先」，只要视口里选着物体，检查器就被钉在那颗材质上 ——
    /// 去库页点别的材质，检查器纹丝不动，像是没响应点击。
    var activeMaterial: MaterialAsset? {
        // 显式读一次投影信号：材质真值在数据层，@Observable 看不见域内写入。
        // 少了这一句，节点编辑器拿到的是「第一次求值时的旧材质」——拖节点里的数值滑块时
        // 材质真的变了、渲染也真的变了，但面板不重算，滑动条上的数字就永远停在原地。
        _ = 材质代
        // 只向材质域要材质：不再扫本地投影数组，也不持有副本
        if let id = selectedMaterialID, let asset = 材质接线.共享.取(资产: id) {
            return asset
        }
        if let id = scene?.selectedObject?.materialID,
           let asset = 材质接线.共享.取(资产: id) {
            return asset
        }
        return selectedMaterial
    }

    var activeMaterialID: UUID? { activeMaterial?.id }

    func material(_ id: UUID?) -> MaterialAsset? {
        guard let id else { return nil }
        // 和 activeMaterial 同一个道理：真值在数据层，@Observable 看不见域内写入，
        // 这里不显式读一次 材质代，读它的视图（材质槽条、槽单元、检查器绑定行…）就停在旧材质上 ——
        // 改个颜色节点编辑器和检查器都跟着变，底下槽里那颗球却一直是改之前的样子。
        _ = 材质代
        return 材质接线.共享.取(资产: id)
    }

    /// 用到这个材质的物体数：直接读材质接线的反向索引引用计数（M:N 的真值），
    /// 不再每帧扫一遍 objects 自己数。
    func objectCount(for materialID: UUID) -> Int {
        材质接线.共享.引用计数(资产: materialID)
    }

    // MARK: 材质库条目 / 场景实例

    /// 把用户材质库目录（`~/Documents/cg app/自定义材质库`）里的 `.cgmat` 并进材质域，
    /// 冷启动与打开工程时各扫一次，界面「材质库」页才看得到自定义材质。
    ///
    /// 去重口径按**资产 id**：工程里已有同一 id 的条目就跳过（工程状态优先，不吃磁盘旧快照）；
    /// id 不同但同名的照收 —— 那是用户真的存过两份同名材质，不该被悄悄吞掉。
    /// 返回实际新收下的条数。
    @discardableResult
    func 并入用户材质库() -> Int {
        let 已有 = Set(materials.map(\.id))
        var 收下 = 0
        for 条目 in 材质库文件.全部() where !已有.contains(条目.id) {
            if 材质接线.共享.登记(条目) { 收下 += 1 }
        }
        if 收下 > 0 { 材质已变() }
        return 收下
    }

    /// 材质库只列库里的条目本身。某个条目被用到场景后会派生出一份「实例」，
    /// 实例不进库 —— 库里那一条永远是原始样式，改参数只改实例。
    ///
    /// 展示顺序：
    /// 1. 内置预设永远排在最前面，按出厂顺序，位置不随增删改漂移；
    /// 2. 从某条内置复制出来的副本跟着它那一组走，排在原件右边（这就是「复制肥皂、肥皂副本在它右边」）；
    /// 3. 其余自定义材质按名字排在最后，复制出来的自定义副本也按名字归位。
    var 库材质列表: [MaterialAsset] {
        let 库 = materials.filter(\.是否库条目)
        guard !库.isEmpty else { return [] }
        var 按ID: [UUID: MaterialAsset] = [:]
        for 项 in 库 where 按ID[项.id] == nil { 按ID[项.id] = 项 }

        // 沿「复制自」一路往上找源头；遇到断链（原件被删了）就停手，把它当独立条目
        func 源头(_ 项: MaterialAsset) -> MaterialAsset {
            var 当前 = 项
            var 步数 = 0
            while let 上 = 当前.副本于, let 父 = 按ID[上], 步数 < 32 {
                当前 = 父
                步数 += 1
            }
            return 当前
        }

        var 组: [UUID: [MaterialAsset]] = [:]
        var 散装: [MaterialAsset] = []
        for 项 in 库 {
            let 头 = 源头(项)
            if 头.是内置预设 {
                组[头.id, default: []].append(项)
            } else {
                散装.append(项)
            }
        }

        var 结果: [MaterialAsset] = []
        for 内置项 in 库 where 内置项.是内置预设 {
            guard let 成员 = 组[内置项.id], !成员.isEmpty else { continue }
            let 组内 = 成员.sorted { a, b in
                if a.id == 内置项.id { return true }
                if b.id == 内置项.id { return false }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            结果.append(contentsOf: 组内)
        }
        结果.append(contentsOf: 散装.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        })
        return 结果
    }

    /// 「本项目」页：只列工程自有材质（自建条目 + 由库派生的实例），
    /// 出厂内置预设**一律不列**：它们只是模板，被改时会自动派生成实例承载改动，永远不算工程数据。
    var 本项目材质列表: [MaterialAsset] {
        // 只列工程自有材质：自建条目（仅工程）+ 由库派生的实例。
        // 库条目（内置预设、用户自攒的模板）一律不进这一页 —— 它们在库页。
        // 混进来的后果很具体：从这页拖给物体会被当成模板去派生成实例，本项目里凭空多出一条材质。
        materials.filter { !$0.是否库条目 }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// 这条库材质一共被几个物体用着：它自己 + 由它派生出来的实例，都算在它名下。
    /// 内置预设例外：它只是模板，派生出来的实例是独立材质、在「本项目」页自己算账，
    /// 所以模板角标只统计**直接指着它**的物体 —— 一被改就派生成实例，角标自然回到 0。
    func 库使用数(for 库ID: UUID) -> Int {
        let 相关: Set<UUID> = material(库ID)?.是内置预设 == true
            ? [库ID]
            : Set(materials.filter { $0.id == 库ID || $0.出处 == 库ID }.map(\.id))
        guard !相关.isEmpty, let 物体们 = scene?.objects else { return 0 }
        return 物体们.filter { 物体 in
            物体.materialID.map { 相关.contains($0) } == true
                || (物体.材质槽引用?.contains { 相关.contains($0) } ?? false)
        }.count
    }

    /// 把库材质拿来用：每次都给一份全新实例，样式取自库里的出厂快照。
    /// 所以库里拖多少次、拖到哪个物体上，上手的永远是原始样式，跟别人改过的参数无关。
    @discardableResult
    func 实例ID(for 库ID: UUID) -> UUID {
        guard let 源 = material(库ID) else { return 库ID }
        // 只有库条目（含内置）才是模板、才需要派生；工程自有材质直接给本身，
        // 所以「本项目页拖出去不派生」这条语义由这里兜住，调用方不必再区分来源。
        guard 源.是否库条目 else { return 库ID }
        let 出厂 = 源.原始样式
        let 实例 = MaterialAsset(
            name: 出厂.name,
            baseline: 出厂.baseline,
            graph: 出厂.graph,
            note: 出厂.note,
            出处: 源.id
        )
        材质接线.共享.登记(实例)
        材质已变()
        return 实例.id
    }


    // MARK: 状态回传

    func note(_ message: String) { onNote?(message) }

    /// 立即落盘（由根 Store 组装快照）
    func persist() { onChange?() }

    /// 高频编辑（拖节点、拖数值）走节流落盘，避免每帧写 UserDefaults
    private var persistTask: Task<Void, Never>?

    func schedulePersist() {
        persistTask?.cancel()
        persistTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            self?.onChange?()
        }
    }

    // MARK: 材质编辑

    func updateActiveMaterial(_ mutate: (inout MaterialAsset) -> Void) {
        guard let 当前 = activeMaterialID, let 原 = material(当前) else { return }
        // 只读的判定只认「当前是不是在材质球库那一页」：那一页是陈列，只给看。
        // 本项目页、材质节点页一律正常可编辑（同一个材质在别的页不该被连坐）。
        // 以前这里对库条目做写时分离：一点滑条就派生实例、把选中从库条目挪到实例上，
        // 检查器看着就像「材质忽然变成了另一个」。要改：拖给物体拿实例，或右键「复制材质」。
        //
        // 库页内的拦截口径只认「成像外观」：节点的 position、标题这类编辑期信息照常写进去，
        // 否则在库页看节点图一拖就弹回原位（材质接线内部按 外观相同 判版本，
        // 挪位置不会推进参数版本，也不会触发路径追踪重译）。
        if 底栏页 == .库 {
            var 试 = 原
            mutate(&试)
            guard 原.外观相同(试) else {
                提示库材质只读()
                return
            }
            guard 材质接线.共享.改(资产: 当前, { $0 = 试 }) else { return }
            材质已变()
            return
        }
        guard 材质接线.共享.改(资产: 当前, mutate) else { return }
        材质已变()
        schedulePersist()
    }

    /// 库材质只读时的统一提示：拖滑条 / 拖节点会每帧打进来，节流一下别刷屏。
    private func 提示库材质只读() {
        let 现在 = Date()
        guard 现在.timeIntervalSince(上次库只读提示) > 1.5 else { return }
        上次库只读提示 = 现在
        note("材质库里的材质只预览：拖给物体或右键「复制材质」之后再调")
    }

    /// 外部来源（MTLX / USD / OBJ 导入）新增材质：唯一入口，登记进域 + 通知界面。
    /// 禁止任何地方再写 `store.materials.append` —— 那是第二份存储。
    func 导入材质(_ 资产: MaterialAsset) {
        // 导入来的材质只属于这个工程：不打库条目标记，材质库页看不到它 ——
        // 库是用户自己攒的模板，不该被随手导入的模型污染；想留模板就「另存为新材质」。
        var 条目 = 资产
        条目.仅工程 = true
        材质接线.共享.登记(条目)
        材质已变()
        schedulePersist()
    }

    /// 材质节点页槽位右键「另存为新材质」：不管出处，一律在库里存成一条新材质 ——
    /// 存进来这一刻的样子就是它的原始样式，之后就是个独立模板（不算内置，随便改随便删）。
    func 另存为新材质(_ id: UUID) {
        guard let 源 = material(id) else { return }
        let 名 = 未占用材质名(基于: 源.name)
        let 新条目 = MaterialAsset(
            name: 名,
            baseline: 源.baseline,
            graph: 源.graph,
            note: 源.note,
            内置: false
        )
        材质接线.共享.登记(新条目)
        材质已变()
        selectedMaterialID = 新条目.id
        persist()

        // 同时落到用户材质库（~/Documents/cg app/自定义材质库/<名>.cgmat）：
        // 工程里这条是能编辑的实例，库里的 .cgmat 是跨工程的模板。
        if let 文件 = 材质库文件.保存(新条目) {
            note("已另存为新材质 · \(名) → \(材质库文件.显示路径(文件))")
        } else {
            note("已另存为新材质 · \(名)（写入自定义材质库失败）")
        }
    }

    /// 库里有重名就往后排「2」「3」…… 免得库里出现两条同名材质分不清
    private func 未占用材质名(基于 基名: String) -> String {
        let 已有 = Set(库材质列表.map(\.name))
        guard 已有.contains(基名) else { return 基名 }
        var 序 = 2
        while 已有.contains("\(基名) \(序)") { 序 += 1 }
        return "\(基名) \(序)"
    }

    func setParam(_ key: PBRParamKey, value: PBRValue) {
        // 手调优先，判据只看"这条参数此刻有没有驱动边"：
        // 有边就必须摘掉（图覆盖基线，不摘刚写的值会被盖回，滑条就成了拉不动）；
        // 没边就只写基线，别去动图 —— 库条目和实例都可能有驱动边，跟是不是模板无关。
        updateActiveMaterial { 资产 in
            资产.baseline[key] = value
            if 资产.graph.isDriven(key) { 资产.graph.disconnect(to: key) }
        }
        // 不写状态栏：滑条拖动是逐帧调用，每帧改一次全局文案会把整块界面连带重排
    }

    func resetParam(_ key: PBRParamKey) {
        // 与手调一致：重置也要摘掉这条参数的驱动边，否则重置看不到效果
        updateActiveMaterial { 资产 in
            资产.baseline[key] = key.defaultValue
            if 资产.graph.isDriven(key) { 资产.graph.disconnect(to: key) }
        }
    }

    func renameMaterial(_ id: UUID, to name: String) {
        // 名字也是材质本体的一部分：在材质球库那一页只陈列，不给就地改名。
        let 新名 = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !新名.isEmpty, let 原 = material(id), 原.name != 新名 else { return }
        if 底栏页 == .库 {
            提示库材质只读()
            return
        }
        let 目标 = id
        guard 材质接线.共享.改(资产: 目标, { $0.name = 新名 }) else { return }
        // 名字是「同一个材质」的身份，不是外观参数：检查器里改的往往是库派生出来的实例，
        // 只改实例的话材质球库里那条仍是旧名字，看起来就是改名没生效。
        // 所以实例改名时把它的库条目一起改，库页与本项目页永远同名。
        if let 出处 = material(目标)?.出处,
           let 库条目 = material(出处),
           库条目.name != 新名 {
            _ = 材质接线.共享.改(资产: 出处, { $0.name = 新名 })
        }
        材质已变()
        persist()
    }

    /// 老存档里的材质没有出厂快照：能按名字对回预置材质的就用预置参数（被改过的预置材质也能回到原样），
    /// 对不上的（新建 / 导入的材质）冻结当前值 —— 之后库里展示就不再跟着参数变了。
    private func 补齐出厂快照() {
        guard materials.contains(where: { $0.出厂基线 == nil || $0.出厂图 == nil }) else { return }
        let 预置 = 初始项目.预置快照表()
        for 资产 in materials where 资产.出厂基线 == nil || 资产.出厂图 == nil {
            if let 项 = 预置[资产.name] {
                _ = 材质接线.共享.改(资产: 资产.id) { $0.冻结出厂样式(baseline: 项.baseline, graph: 项.graph) }
            } else {
                _ = 材质接线.共享.改(资产: 资产.id) { $0.冻结出厂样式() }
            }
        }
        材质已变()
    }

    /// 老存档没有「内置」字段：名字能对回预置材质的认作内置预设，其余都算自定义。
    private func 补齐内置标记() {
        guard materials.contains(where: { $0.内置 == nil }) else { return }
        let 预置名 = Set(初始项目.预置快照表().keys)
        for 资产 in materials where 资产.内置 == nil {
            let 认作内置 = 资产.是否库条目 && 预置名.contains(资产.name)
            _ = 材质接线.共享.改(资产: 资产.id) { $0.内置 = 认作内置 }
        }
        // 内置是出厂原件，不该挂在谁名下（老数据若误带副本来源就清掉，免得排序把它拉出内置组）
        for 资产 in materials where 资产.是内置预设 {
            _ = 材质接线.共享.改(资产: 资产.id) { $0.副本于 = nil }
        }
        材质已变()
    }

    /// 新建一条空白自定义材质（不算内置）
    /// 落在「本项目」页：新建是为了马上给物体用，属于工程数据，不进库 —— 想留模板走「另存为新材质」
    func addMaterial() {
        var baseline = OpenPBRParams()
        baseline[.baseColor] = .color(PBRColor(0.72, 0.74, 0.78))
        var asset = MaterialAsset(name: "材质 \(materials.count + 1)", baseline: baseline)
        asset.仅工程 = true
        材质接线.共享.登记(asset)
        材质已变()
        selectedMaterialID = asset.id
        persist()
        note("已新建材质 \(asset.name)")
    }

    /// 复制材质：复制出来的是一份**新的源模板**，不算内置（内置永远只有出厂那几条），
    /// 名字排「复制」类后缀，并记下它是从哪条复制的 —— 库里显示时它就贴在原件右边，
    /// 而不是被甩到列表末尾。
    func duplicateMaterial(_ id: UUID) {
        guard let source = materials.first(where: { $0.id == id }) else { return }
        // 源可能是库条目，也可能是物体身上的实例：副本一律挂到它所属的那条库材质名下
        let 归属 = source.出处 ?? source.id
        var asset = MaterialAsset(
            name: 未占用材质名(基于: source.name + " 副本"),
            baseline: source.baseline,
            graph: remapGraph(source.graph),
            note: source.note,
            内置: false,
            副本于: 归属
        )
        // 归属跟着源走：源是工程材质（自建/实例），副本也留在「本项目」页；
        // 源是库条目，副本才进库当模板。否则在工程里复制一条会凭空跑进库页。
        if !source.是否库条目 { asset.仅工程 = true }
        // 不再靠数组插入定位：库列表的「副本贴在原件右边」由 副本于 关系 + 名字排序决定，
        // 域里只按登记顺序存放材质本体，登记即完成。
        材质接线.共享.登记(asset)
        材质已变()
        selectedMaterialID = asset.id
        persist()
        note("已复制材质 · \(asset.name)")
    }

    /// 复制时把图内节点 ID 重映射，避免两份材质共享 ID 导致连线错乱
    private func remapGraph(_ graph: NodeGraph) -> NodeGraph {
        var map: [UUID: UUID] = [:]
        var newGraph = NodeGraph(nodes: [], links: [])
        for node in graph.nodes {
            let newID = UUID()
            map[node.id] = newID
            let copy = ShaderNode(
                id: newID, kind: node.kind, title: node.title,
                position: node.position, params: node.params, isMuted: node.isMuted
            )
            newGraph.nodes.append(copy)
        }
        for link in graph.links {
            guard let from = map[link.fromNode], let to = map[link.toNode] else { continue }
            newGraph.links.append(
                NodeLink(fromNode: from, fromSocket: link.fromSocket, toNode: to, toSocket: link.toSocket)
            )
        }
        return newGraph
    }

    /// 本项目页的删除：只把这条材质从工程里摘掉，**不动**磁盘上的 .cgmat。
    /// 库里的那份原文件归库页的删除管 —— 两个删除按钮不是一件事。
    func deleteMaterial(_ id: UUID) {
        // 库条目是库的东西，在本项目页本来也不列，误调就明说去哪删
        if material(id)?.是否库条目 == true {
            note("这是材质库里的材质，请到「材质球库」页删，那里才动本地文件")
            return
        }
        guard materials.count > 1 else { return }
        guard 移除材质(id) else { return }
        persist()
    }

    /// 材质库页的删除：删掉 `~/Documents/cg app/自定义材质库` 里那份 `.cgmat`，再从材质域摘掉。
    /// 内置预设不在本地存储里（出厂数据，重建工程还会回来），不给删。
    func 删除库材质(_ id: UUID) {
        guard let 资产 = material(id), 资产.是否库条目 else { return }
        if 资产.是内置预设 {
            note("内置预设是出厂材质，没有本地文件，不能删")
            return
        }
        // 顺序：先摘材质域，成功之后再删磁盘文件。
        // 反过来做过：删除被拒（只剩一条材质 / 仍有引用）时文件已经删掉，库里却还挂着一条没有文件的条目。
        guard 移除材质(id) else { return }
        let 删了文件 = 材质库文件.删除(id: id)
        note(删了文件 ? "已删除材质库文件 · \(资产.name)" : "材质库文件没找到，只从库里移除 · \(资产.name)")
        persist()
    }

    /// 两条删除共用的后半段：解绑引用者 → 交材质接线删除 → 选中顺延。
    /// 引用计数不为 0 就拒绝删除（绝不悄悄重建），返回是否真的删掉了。
    @discardableResult
    private func 移除材质(_ id: UUID) -> Bool {
        // 材质域至少留一条：检查器和节点编辑器都靠 active 材质，删空就没人可显示
        guard materials.count > 1 else {
            note("至少留一条材质")
            return false
        }
        // 【顺序有意义】先让场景侧断引用，再清数据层槽位表。
        // 反过来做过：先逐条把槽位置空，反向索引随即变成空集，接着 `unbindMaterial` 按引用者扫
        // 就一个对象都扫不到，objects 里的 materialID 留在原地指向一条已经不在材质域里的材质 ——
        // 视口不重套、PT 转译查不到材质，表现就是"删完画面纹丝不动，切一次模式才看到材质没了"。
        scene?.unbindMaterial(id)
        // 场景侧收尾之后，还残留在槽位表里的引用（不认识的对象 / 副槽）在这里置空
        for 对象 in 材质接线.共享.引用者(资产: id) {
            // 只把指向这条材质的槽置空：整表清空会把对象上别的材质一并卸掉
            var 表 = 材质接线.共享.槽位表(对象: 对象)
            for i in 表.indices where 表[i] == id { 表[i] = nil }
            _ = 材质接线.共享.绑定(对象: 对象, 槽位表: 表)
        }
        switch 材质接线.共享.删除(资产: id) {
        case .已受理:
            材质已变()
        case .拒绝仍有引用(let 引用者):
            note("该材质仍被 \(引用者.count) 个物体引用，已拒绝删除")
            return false
        case .未知材质:
            return false
        }
        if selectedMaterialID == id { selectedMaterialID = materials.first?.id }
        return true
    }

    // MARK: 节点图编辑

    func addNode(kind: ShaderNodeKind, at point: CGPoint) {
        updateActiveMaterial { asset in
            let position = asset.graph.freePosition(near: point)
            let node = ShaderNode(kind: kind, position: position)
            asset.graph.nodes.append(node)
            selectedNodeID = node.id
        }
        note("添加节点：\(kind.title)")
    }

    func moveNode(_ id: UUID, to point: CGPoint, persistNow: Bool = false) {
        // 网格吸附：8pt，避免节点落在半像素上导致连线抖动
        let 目标 = CGPoint(x: point.x.rounded(), y: point.y.rounded())
        updateActiveMaterial { asset in
            guard let index = asset.graph.nodes.firstIndex(where: { $0.id == id }) else { return }
            // 慢速拖动时同一位置会连续来几十帧。@Observable 写入即通知（值没变也通知），
            // 白写一次就把整块画布再算一遍，拖动会一顿一顿的，所以先比再写。
            if asset.graph.nodes[index].position == 目标 { return }
            asset.graph.nodes[index].position = 目标
        }
        if persistNow { persist() }
    }

    func setNodeParam(_ nodeID: UUID, key: String, value: PBRValue) {
        updateActiveMaterial { asset in
            guard let index = asset.graph.nodes.firstIndex(where: { $0.id == nodeID }) else { return }
            asset.graph.nodes[index].params[key] = value
        }
    }

    /// 换掉节点引用的贴图（nil = 清空）。贴图本体仍在视口纹理库里，只改节点指向，
    /// 所以同一张图被多个节点共用时互不影响。
    func setNodeImage(_ nodeID: UUID, image: UUID?) {
        updateActiveMaterial { asset in
            guard let index = asset.graph.nodes.firstIndex(where: { $0.id == nodeID }) else { return }
            guard asset.graph.nodes[index].kind == .imageTexture else { return }
            asset.graph.nodes[index].image = image
        }
        note(image == nil ? "已清空节点贴图" : "已更换节点贴图")
    }

    func toggleMute(_ nodeID: UUID) {
        updateActiveMaterial { asset in
            guard let index = asset.graph.nodes.firstIndex(where: { $0.id == nodeID }) else { return }
            asset.graph.nodes[index].isMuted.toggle()
        }
    }

    func renameNode(_ nodeID: UUID, to title: String) {
        updateActiveMaterial { asset in
            guard let index = asset.graph.nodes.firstIndex(where: { $0.id == nodeID }) else { return }
            asset.graph.nodes[index].title = title
        }
    }

    func deleteNode(_ nodeID: UUID) {
        updateActiveMaterial { asset in
            guard let node = asset.graph.node(nodeID), node.kind != .output else { return }
            asset.graph.removeNode(nodeID)
            if selectedNodeID == nodeID { selectedNodeID = nil }
        }
        note("已删除节点")
    }

    func connect(fromNode: UUID, fromSocket: String, toNode: UUID, toSocket: String) {
        updateActiveMaterial { asset in
            asset.graph.connect(fromNode: fromNode, fromSocket: fromSocket, toNode: toNode, toSocket: toSocket)
        }
        note("已连接 \(fromSocket) → \(toSocket)")
    }

    /// 把节点输出接到 OpenPBR Output 的某个参数口（同端口的旧连线按替换语义顶掉）。
    /// 只有接进 Output 的参数才会进 MaterialCompiler.resolve 的 overrides，才会真的改模型外观。
    func connectToOutput(_ nodeID: UUID, key: PBRParamKey) {
        updateActiveMaterial { asset in
            guard let output = asset.graph.outputNode,
                  let node = asset.graph.node(nodeID) else { return }
            let wanted: SocketKind = key.isColor ? .color : .scalar
            guard let socket = node.kind.outputs.first(where: { $0.kind == wanted })
                    ?? node.kind.outputs.first else { return }
            asset.graph.connect(
                fromNode: nodeID,
                fromSocket: socket.id,
                toNode: output.id,
                toSocket: key.rawValue
            )
        }
        note("已接入输出 · \(key.title)（改动会作用到模型）")
    }

    /// 该节点当前驱动的 Output 参数（没接线则为空）
    func drivenKeys(of nodeID: UUID) -> [PBRParamKey] {
        guard let asset = activeMaterial, let output = asset.graph.outputNode else { return [] }
        return asset.graph.links
            .filter { $0.fromNode == nodeID && $0.toNode == output.id }
            .compactMap { PBRParamKey(rawValue: $0.toSocket) }
    }

    func disconnect(_ linkID: UUID) {
        updateActiveMaterial { $0.graph.disconnect(linkID) }
    }

    func deleteSelection() {
        if let selectedLinkID {
            disconnect(selectedLinkID)
            self.selectedLinkID = nil
            return
        }
        if let selectedNodeID {
            deleteNode(selectedNodeID)
        }
    }

    // MARK: 载入 / 重置

    /// 把视口设置里的缓存策略落到全局贴图库上。
    /// 派生图字节上限是「设置项」而不是常量：上限只在调用时读一次，
    /// 所以载入设置、改设置都要走这里，否则界面改了数字、回收那边还在用旧值。
    func 应用缓存策略() {
        // 下限 64MB：再小的话一张 4K 烘焙图集就能把缓存顶爆，变成每帧重烘
        视口纹理库.设派生字节上限(max(64, viewport.ptDerivedCacheMB) * 1024 * 1024)
    }

    func load(from snapshot: ProjectSnapshot) {
        材质接线.共享.换库(snapshot.materials)
        材质已变()
        补齐出厂快照()
        补齐内置标记()
        selectedMaterialID = snapshot.selectedMaterialID ?? snapshot.materials.first?.id
        viewport = snapshot.viewport
        应用缓存策略()
        // 全局物理跟着工程走：老工程没有这一项就是标准地球重力
        物理域 = snapshot.物理域 ?? .标准
        // 机位跟着工程走：读出来交给视口面板还原，老工程没有就是 nil（保持默认机位）
        视口相机存档 = snapshot.视口相机
        相机还原信号 += 1
    }

    /// 构造「出厂基础场景」的着色域：内建材质 + 默认视口设置。
    ///
    /// 这是新建项目 / 冷启动的唯一入口。它不读也不继承任何历史状态：
    /// 材质、选中项、节点/连线选中、视口设置、相机存档全部整体赋值，
    /// 上一个文档里的一切（导入素材驱动出来的材质、上次机位）不进入本次构造。
    func 载入基础场景() {
        材质接线.共享.换库(初始项目.materials())
        材质已变()
        selectedMaterialID = materials.first?.id
        selectedNodeID = nil
        selectedLinkID = nil
        viewport = .default
        应用缓存策略()
        物理域 = .标准
        视口相机存档 = nil
        // 编辑器自身的面板/画布视图状态也回出厂：新建的文档不该继承上一个文档的手感
        canvasScale = 1
        canvasOffset = .zero
        nodeAreaRatio = 0.42
        inspectorVisible = true
        diagnosticsVisible = true
        // 通知视口把机位退回默认：只置 nil 不会让已经建好的视口重新取景
        相机还原信号 += 1
    }
}

// MARK: - 跨域对焦请求

/// 一次「请视口把镜头对准这个物体」的请求。序号自增，同一物体重复请求也能触发。
struct 视口对焦请求: Equatable, Sendable {
    let 物体: UUID
    let 序号: Int
}

// MARK: - 小工具

extension PBRValue {
    var summary: String {
        switch self {
        case .scalar(let v): String(format: "%.3f", v)
        case .color(let c): String(format: "%.2f, %.2f, %.2f", c.r, c.g, c.b)
        }
    }
}
