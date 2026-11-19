import Foundation
import Observation

// MARK: - 工作区

enum WorkspaceTab: String, CaseIterable, Identifiable, Hashable {
    case shading
    case layout
    case render
    case assets

    var id: String { rawValue }

    var title: String {
        switch self {
        case .shading: "着色"
        case .layout: "布局"
        case .render: "渲染"
        case .assets: "资源"
        }
    }

    var symbol: String {
        switch self {
        case .shading: "circle.hexagongrid"
        case .layout: "cube.transparent"
        case .render: "camera.aperture"
        case .assets: "square.stack.3d.up"
        }
    }

    var hint: String {
        switch self {
        case .shading: "3D 视口 + OpenPBR 材质节点"
        case .layout: "大纲、变换与相机"
        case .render: "输出设置与渲染队列"
        case .assets: "材质库与网格库"
        }
    }
}

// MARK: - 根 Store（组合根）

/// 应用根状态：只负责「跨工作区」的东西——当前 Tab、状态栏、落盘与重置。
/// 各功能域的真值都在自己的 Store 里：
/// - 着色：`着色Store`（材质 / 节点图 / 视口）
/// - 布局：`布局Store`（场景物体 / 选中物体）
/// - 渲染：`渲染Store`（输出设置 / 渲染队列）
///
/// View 通过 `@Environment` 直接注入自己需要的那一个 Store，不依赖本类。
@Observable
final class AppStore {

    // MARK: 子 Store

    let shading = 着色Store()
    let layout = 布局Store()
    let render = 渲染Store()

    // MARK: 全局 UI 状态

    var tab: WorkspaceTab = .shading
    var statusMessage: String = "就绪"

    /// 全局搜索面板是否打开（⌘F）。放根 Store：它跨所有工作区，不算任何一域的真值。
    var 全局搜索打开 = false

    // MARK: 脏状态（手动保存 / 自动保存共用）

    /// 有未保存到主工程文件的改动。
    ///
    /// 传统 DCC 语义：主工程文件只在 ⌘S / 另存为时写。域状态一变就写主文件的老行为
    /// 已经去掉，这里只记「脏」；真正的落盘由手动保存或自动保护（独立 autosave 文件）负责。
    private(set) var 有未保存改动 = false

    /// 最近一次自动保护落盘的时间。界面用它区分「有改动」和「已自动保护」。
    private(set) var 最近自动保护时间: Date?

    // MARK: 异步保存状态（⌘S 立刻返回，写盘在后台串行队列）

    /// 状态栏据此显示「正在保存…」→「已保存」。
    enum 保存态: Equatable {
        case 空闲
        case 正在保存
        case 失败(String)
    }

    private(set) var 保存状态: 保存态 = .空闲

    /// 保存代次：切换项目 / 另存为 / 重置都会 +1。
    /// 在途那笔异步保存回来时代次已变，说明它写的是「上一个项目」，
    /// 结果只能丢弃，绝不能拿它去清当前项目的脏标记。
    private var 保存代次 = 0

    /// 写盘失败的用户可见反馈（界面绑 alert）。成功后自动清空。
    var 保存失败信息: String?

    /// 同一时刻只允许一笔在途保存；在途期间再按 ⌘S 只记「待再存」，不排队。
    private var 在途保存 = false
    private var 待再存 = false

    /// 改动序号：每次标脏 +1。保存发起时记下序号，写完若序号已变
    /// 说明写盘期间又改过东西，这一版不算「已保存」，必须补写最后一版。
    private var 改动序号: UInt64 = 0

    /// 任何域状态变化都只标脏，绝不在这里写主文件。
    func 标记脏() {
        // 播放/拖播放头时求值会把值写回模型，那是"看"，不是"改"。
        // 不在这里让路，一播就是每秒 24 次脏标志 + 自动保存风暴。
        if 时间轴域.共享.正在回放 { return }
        改动序号 &+= 1
        if !有未保存改动 { 有未保存改动 = true }
        自动保存协调器.共享.脏状态变化()
    }

    /// 自动保护写成功后由协调器回调（主线程）。
    func 记录自动保护(_ 时间: Date) {
        最近自动保护时间 = 时间
    }

    /// 手动保存（⌘S / 另存为）成功后清脏。
    /// 同时把当前版本登记为「已落盘」，免得定时器紧接着又写一份保护文件。
    private func 清脏标记() {
        if 有未保存改动 { 有未保存改动 = false }
        自动保存协调器.共享.手动保存完成()
    }

    // MARK: 初始化

    init() {
        wire()
        // 冷启动 = 基础项目：与「文件 > 新建项目」走同一条构造路径。
        //
        // 这里刻意不调用 `LocalStore.载入容器()`：DCC 的启动语义是「给你一份新文档」，
        // 而不是「恢复上一次工程」。历史容器里的导入几何、绘画、上次机位、
        // 上次面板状态都不参与这次构造（不是构造后再清掉，是压根不读）。
        // 需要旧工程时走「文件 > 打开」。
        构造基础项目()
        LocalStore.主App = self
        自动保存协调器.共享.绑定(self)
        // 用户材质库（~/Documents/cg app/自定义材质库）是磁盘上的东西，不属于「工程」，
        // 所以每个新文档都要重新并进来一次，否则材质库页只剩内置预设。
        // 并完立刻清脏：这是开机装库，不是用户改动。
        if shading.并入用户材质库() > 0 { 清脏标记() }
    }

    /// 只做引用接线：域间只读依赖 + 变更回调
    private func wire() {
        shading.scene = layout
        layout.shading = shading
        render.shading = shading

        // 域状态一变只标脏：主工程文件的写入时机交给 ⌘S / 另存为
        shading.onChange = { [weak self] in self?.标记脏() }
        layout.onChange = { [weak self] in self?.标记脏() }
        render.onChange = { [weak self] in self?.标记脏() }

        shading.onNote = { [weak self] message in self?.statusMessage = message }
        layout.onNote = { [weak self] message in self?.statusMessage = message }
        render.onNote = { [weak self] message in self?.statusMessage = message }

        // 动画域：只有「轨道被编辑」（打帧 / 删帧 / 载入）才算文档改动。
        // 播放与拖播放头不在这里，靠 标记脏() 里对 `正在回放` 让路。
        时间轴域.共享.onChange = { [weak self] in self?.标记脏() }

        // 把场景变换接进动画通道注册表（9 条通道 + 同物体批量写器）。
        // 走布局 Store 的公开写入口，写进模型后上游「变换接线」照旧推进变换域。
        动画接线.共享.接上(self)

        // 特效烘焙域：只读布局（场景 + 世界矩阵）与着色（物理域）。烘焙缓存是中间产物，
        // 不落工程文件、不参与脏标记，所以这里不接 onChange。
        特效烘焙域.共享.绑定(layout: layout, shading: shading)
    }

    // MARK: 持久化

    /// 当前内存状态 → 存档快照（不含几何池，几何走容器里的内容寻址块）。
    /// 存档前把几何来源对齐到域：文件里落的必须是域此刻认定的那块几何，
    /// 而不是模型字段上一次被写时的值。域里查不到的物体原样保留，不凭空改几何。
    private func 按几何域回填(_ objects: [SceneObject]) -> [SceneObject] {
        objects.map { 物体 in
            guard let 源 = 几何接线.共享.取值(键: 物体.id.uuidString) else { return 物体 }
            var 副本 = 物体
            副本.按域回填几何(源)
            return 副本
        }
    }

    func 生成快照() -> ProjectSnapshot {
        ProjectSnapshot(
            materials: shading.materials,
            objects: 按几何域回填(layout.objects),
            selectedMaterialID: shading.selectedMaterialID,
            selectedObjectID: layout.selectedObjectID,
            viewport: shading.viewport,
            render: render.render,
            renderJobs: render.renderJobs,
            // 网格数据不在 JSON 里，走容器里的几何块；这里恒为 nil
            导入网格池: nil,
            savedAt: .now,
            视口相机: shading.视口相机存档,
            集合们: layout.集合们,
            动画: 时间轴域.共享.快照(),
            物理域: shading.物理域
        )
    }

    /// 写指定容器：
    /// - 主工程文件只在手动保存 / 另存为路径调用；
    /// - 自动保护走 autosave 目录下的独立文件，绝不碰主文件。
    func persist(到 root: URL, 刷新聚焦图: Bool) {
        LocalStore.save(生成快照(), 到: root, 刷新聚焦图: 刷新聚焦图)
    }

    // MARK: - 项目文件（打开 / 另存为 / 保存）

    /// 当前文档的容器位置。`nil` = 未命名文档（新建后尚未落盘），首次 ⌘S 走另存为。
    private(set) var 项目位置: URL?

    var 项目名: String {
        guard let 项目位置 else { return "未命名" }
        return 项目位置.deletingPathExtension().lastPathComponent
    }

    /// 打开另一个 .cg：先把手上的改动落盘，再切容器指针，最后重建各域状态。
    @discardableResult
    func 打开项目(_ url: URL) -> Bool {
        guard 项目容器.是容器(url) else {
            statusMessage = "不是有效的 .cg 项目：\(url.lastPathComponent)"
            return false
        }
        if url.standardizedFileURL == 项目位置?.standardizedFileURL {
            statusMessage = "\(项目名) 已经是当前项目"
            return true
        }
        // 切指针前必须落盘，并且要连后台在途那笔一起等完：
        // 只 flush 不够 —— 写队列上排着的 append + 索引提交还在写旧容器，
        // 两路同时写同一个 .cg 会把索引写乱。
        LocalStore.丢弃延后任务()
        LocalStore.等待写队列空闲()
        在途保存 = false
        待再存 = false
        保存代次 &+= 1
        // 未命名文档没有容器可 flush；有容器才把在手上的改动落进去
        if let 当前位置 = 项目位置 { LocalStore.flush(到: 当前位置) }
        // 整池替换 + Store 重新载入的这段窗口里引用关系是对不上的，
        // 先停掉几何域的回收轮询，载入完（含失败提前返回）再放开。
        几何接线.共享.暂停回收(true)
        defer { 几何接线.共享.暂停回收(false) }
        guard let 内容 = 项目容器.载入(url) else {
            statusMessage = "项目载入失败：\(url.lastPathComponent)"
            return false
        }
        项目容器.当前项目 = url
        // 自动保存的基底源跟着走：它只做 clonefile 基底，本身不改项目指针
        自动保存协调器.基底源 = url
        项目位置 = url
        // 顺序跟启动时一致：几何先进池，各 Store 再载入
        几何接线.共享.恢复(内容.几何)
        shading.load(from: 内容.快照)
        // 工程里带着自己那份库，磁盘上新存的 .cgmat 也要补进来（同 id 跳过，工程优先）
        shading.并入用户材质库()
        layout.load(from: 内容.快照)
        render.load(from: 内容.快照)
        // 轨道跟着工程走：老工程没有动画字段 → 载入 nil = 空轨道。
        // 放在 layout.load 之后，载完轨道立刻按当前帧求值一次，模型与时间轴对齐。
        时间轴域.共享.载入(内容.快照.动画)
        if let 画 = 内容.绘画 {
            MainActor.assumeIsolated { PaintEngine.shared.恢复绘画快照(画) }
        }
        // 换项目后把定时器的时间基准重置，避免拿着上一个项目的计时马上触发
        自动保存协调器.共享.手动保存完成()
        statusMessage = "已打开 \(项目名)"
        return true
    }

    /// 另存为：把当前文档落成一个新的 .cg，之后所有写盘都跟着新路径走。
    ///
    /// 两条路径，区别只在「有没有可复制的旧容器」：
    /// - 已有容器（打开了别人的工程）：整目录复制，保留块级去重收益；
    /// - 未命名文档（`项目位置 == nil`，刚新建）：没有可复制的容器，直接由内存状态
    ///   在目标位置建容器 —— 新文件里只会有当前文档真正引用的块。
    /// 目标已存在时只允许覆盖同样是 .cg 的项目包（面板里系统已确认过一次覆盖）。
    @discardableResult
    func 另存为(_ url: URL) -> Bool {
        var 目标 = url.standardizedFileURL
        if 目标.pathExtension.lowercased() != 项目容器.扩展名 {
            目标 = 目标.appendingPathExtension(项目容器.扩展名)
        }
        let 源 = 项目位置
        if 目标 == 源?.standardizedFileURL {
            return 保存()
        }
        // 拷贝前必须等写队列彻底空：在途那笔还在往旧容器追加块 / 提交索引，
        // 这时候 copyItem 会拷出一个「索引指向正在写的块」的半成品。
        LocalStore.丢弃延后任务()
        LocalStore.等待写队列空闲()
        在途保存 = false
        待再存 = false
        保存代次 &+= 1
        // 先把手上的改动写进旧容器，复制过去的才是最新状态（未命名文档没有旧容器）
        if let 源 { LocalStore.flush(到: 源) }
        let fm = FileManager.default
        if fm.fileExists(atPath: 目标.path) {
            guard 项目容器.是容器(目标) else {
                statusMessage = "同名文件不是项目包，换个名字再存"
                return false
            }
            do {
                try fm.removeItem(at: 目标)
            } catch {
                statusMessage = "覆盖失败：\(error.localizedDescription)"
                return false
            }
        }
        do {
            try fm.createDirectory(
                at: 目标.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            // 未命名文档：没有可复制的旧容器，下面的 persist 会在目标位置从零建出容器
            if let 源 { try fm.copyItem(at: 源, to: 目标) }
        } catch {
            statusMessage = "另存为失败：\(error.localizedDescription)"
            return false
        }
        项目容器.当前项目 = 目标
        自动保存协调器.基底源 = 目标
        项目位置 = 目标
        // 以新路径重写一次清单，刷新「应用 / 修改时间」
        persist(到: 目标, 刷新聚焦图: true)
        LocalStore.flush(到: 目标)
        清脏标记()
        statusMessage = "已另存为 \(项目名).\(项目容器.扩展名)"
        return true
    }

    /// ⌘S：主工程文件唯一的手动写入时机，且**不阻塞 UI**。
    ///
    /// 主线程只做三件事 —— 拍快照、导出绘画、登记写盘，然后立刻返回；
    /// 几何块写入、索引提交、fsync、聚焦图、整理全在后台串行写队列。
    ///
    /// 合并：同一时刻只允许一笔在途保存。在途期间再按 ⌘S 只置 `待再存`，
    /// 等那笔写完补写最后一版 —— 连按 ⌘S 不会排队写多遍。
    @discardableResult
    func 保存() -> Bool {
        guard let 目标 = 项目位置 else {
            // 未命名文档没有落点：菜单层会先弹另存为，这里只是兜底
            statusMessage = "未命名文档，请先另存为"
            return false
        }

        // 在途：后到的合并，不排队（写完自然会补最新一版）
        guard !在途保存 else {
            待再存 = true
            return true
        }

        let 本轮序号 = 改动序号
        let 本轮代次 = 保存代次
        let 快照 = 生成快照()
        // 绘画数据在引擎 / 显存里，只有主线程取得到，必须此刻导出
        let 画 = MainActor.assumeIsolated { PaintEngine.shared.导出绘画快照同步() }

        在途保存 = true
        保存状态 = .正在保存
        statusMessage = "正在保存 \(项目名)…"

        LocalStore.异步落盘(快照, 绘画: 画, 到: 目标, 刷新聚焦图: true) { [weak self] 成功 in
            guard let self else { return }
            // 过期回调：写盘期间已经切了项目 / 另存为 / 重置，这一笔的结果不归现在管
            guard self.保存代次 == 本轮代次 else { return }
            self.在途保存 = false

            if 成功 {
                if self.改动序号 != 本轮序号 {
                    // 写盘期间又改过：这一版不算已保存，补写最后一版
                    self.待再存 = true
                    self.保存状态 = .正在保存
                } else {
                    self.保存状态 = .空闲
                    self.保存失败信息 = nil
                    self.statusMessage = "已保存 \(self.项目名)"
                    self.清脏标记()
                }
            } else {
                // 失败绝不静默：状态栏红字 + alert，改动仍在内存里
                self.保存状态 = .失败("写入失败")
                self.statusMessage = "保存失败：\(目标.lastPathComponent)"
                self.保存失败信息 = "「\(self.项目名)」写入磁盘失败。改动仍在内存中，请重试 ⌘S，或另存为到其他位置。"
            }

            if self.待再存 {
                self.待再存 = false
                _ = self.保存()
            }
        }
        return true
    }

    // MARK: - 新建项目

    /// 文件 > 新建项目：DCC 语义的「新文档」。
    ///
    /// 关键是「从零构造」，而不是「复用当前文档再清空某些集合」：
    /// 1. 先跟现有串行化对齐 —— 丢弃延后任务、等写队列彻底空、换一代保存代次。
    ///    少了这一步，队列里在途那笔会继续把上一个文档的块追加进来，
    ///    回调还会因为代次相同而误清新文档的脏标记；
    /// 2. 再把整份文档状态重建为出厂态（见 `构造基础项目()`）；
    /// 3. 项目位置置空 → 变成未命名文档，首次 ⌘S 走另存为。
    ///
    /// 构造函数里没有任何「继承当前文档」的分支：基础场景之外的东西不存在，
    /// 因此不需要（也不允许）靠事后清空各个集合来打补丁。
    func 新建项目() {
        LocalStore.丢弃延后任务()
        LocalStore.等待写队列空闲()
        在途保存 = false
        待再存 = false
        保存代次 &+= 1

        构造基础项目()

        保存状态 = .空闲
        保存失败信息 = nil
        statusMessage = "已新建项目"
    }

    /// 把这份文档重建为「刚出厂」的样子。新建项目与冷启动共用这一个构造入口。
    ///
    /// 除三个域 Store 之外，几何池与绘画引擎是进程级单例（不在 AppStore 里），
    /// 所以也必须在这里回到出厂态 —— 少了这两步，基础场景会跟上一个文档的
    /// 导入素材 / 笔迹 / 图集切片一起落盘，正是新文件体积不下来的根因。
    private func 构造基础项目() {
        几何接线.共享.恢复([:])
        MainActor.assumeIsolated {
            PaintEngine.shared.清空全部()
            PaintSession.shared.重置会话()
        }
        shading.载入基础场景()
        layout.载入基础场景()
        render.载入基础场景()
        // 新文档没有动画：轨道清空、播放头回第 0 帧。
        // 载入 nil 走的就是 清空()，不需要第二套重置逻辑。
        时间轴域.共享.载入(nil)
        // 未命名文档：没有容器路径，也还没有写盘
        项目位置 = nil
        // 面板的默认目录仍指向应用支持目录（下次打开 / 另存为从这儿起步）
        项目容器.当前项目 = 项目容器.默认项目
        // 未命名文档：没有落点，自动保存基底源为空，首次 ⌘S 走另存为
        自动保存协调器.基底源 = nil
        // 新文档视为已落盘：不脏，也不会立刻被自动保存写一份保护文件
        清脏标记()
    }
}
