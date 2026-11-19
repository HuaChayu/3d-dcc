import Foundation
import Metal
import simd
import Observation

// MARK: - 特效烘焙域
//
// 全局唯一。这里**不存参数真值**（真值永远只有 SceneObject.特效 一份），也不碰工程脏标记：
// 烘焙缓存是可再生的中间产物，删了重烘就行，不该跟着 .cg 工程一起搬、更不该把工程标脏。
//
// 分工：
// - 数据层 `烘焙 数据.swift`：一帧一个文件的容器 + 目录管理 + 指纹。
// - GPU 层 `烘焙 器.swift`：用视口同一套 compute 管线，固定步长 1/帧率 离线推进。
// - 本域：编排（跳帧 → 收集世界矩阵 → 步进 → 落盘）、进度、以及回放时按帧取缓存。

struct 烘焙统计: Equatable {
    var 发射器数: Int = 0
    var 已烘焙帧数: Int = 0
    var 粒子总数量: Int = 0
    var 用时秒: Double = 0
    var 占用兆字节: Double = 0
}

@MainActor @Observable
final class 特效烘焙域 {

    static let 共享 = 特效烘焙域()

    // MARK: 帧范围（界面那两个输入框绑的就是这两个）

    var 起始帧: Int = 0
    var 结束帧: Int = 119

    // MARK: 运行态

    private(set) var 烘焙中 = false
    var 进度: Double = 0
    var 状态文字: String = "未烘焙"
    var 统计 = 烘焙统计()

    /// 已经烘过、且能读到完整缓存的帧（多发射器时取交集）。
    /// 时间线顶部那条细带读的就是它。
    private(set) var 已烘焙帧: Set<Int> = []

    /// 这批缓存是按哪一套参数烘的
    private(set) var 指纹: 烘焙指纹?

    /// 有没有特效可烘（按钮置灰用）
    var 可以烘焙: Bool { !烘焙中 && !在场发射器().isEmpty }

    /// 缓存还对得上当前参数吗（参数一改就假，界面上该提示重烘）
    var 缓存有效: Bool {
        guard let 指纹, !已烘焙帧.isEmpty else { return false }
        return 指纹 == 当前指纹()
    }

    weak var layout: 布局Store?
    weak var shading: 着色Store?

    private var 任务: Task<Void, Never>?

    /// 回放用的内存帧缓存（LRU）。播放时相邻帧会被反复取，
    /// 播放头来回拖也得快，不然每帧读盘会出现卡顿。
    private var 内存帧缓存: [Int: [UUID: 烘焙发射器帧]] = [:]
    private var 内存帧顺序: [Int] = []
    private static let 内存帧上限 = 24

    // MARK: - 接线

    func 绑定(layout: 布局Store, shading: 着色Store) {
        self.layout = layout
        self.shading = shading
        同步帧范围()
        刷新已烘焙帧()
    }

    /// 输入框初值跟时间轴对齐（用户没改过就该是整段）
    func 同步帧范围() {
        let 时间轴 = 时间轴域.共享
        起始帧 = 时间轴.起始帧
        结束帧 = 时间轴.结束帧
    }

    // MARK: - 场景查询

    /// 可以参与烘焙的发射器：可见 + 挂了特效 + 启用。
    /// 关掉的发射器不烘 —— 视口里它也不出粒子，烘了纯浪费空间。
    private func 在场发射器() -> [(id: UUID, 设置: 特效设置)] {
        guard let layout else { return [] }
        return layout.objects.compactMap { 物 in
            guard 物.isVisible, let 设置 = 物.特效, 设置.启用 else { return nil }
            return (物.id, 设置)
        }
    }

    private func 当前指纹() -> 烘焙指纹 {
        烘焙指纹.生成(在场发射器(), 帧率: 时间轴域.共享.帧率)
    }

    // MARK: - 缓存管理

    /// 扫磁盘重建「哪些帧有缓存」。切工程 / 加删发射器 / 改参数后都该调一次。
    func 刷新已烘焙帧() {
        let ids = 在场发射器().map(\.id)
        guard !ids.isEmpty else {
            已烘焙帧 = []
            指纹 = nil
            统计 = 烘焙统计()
            状态文字 = "场景里没有启用的特效"
            return
        }

        // 多个发射器取交集：只有每一个都烘过的帧，播放时才能全都读到缓存
        var 交集: Set<Int>? = nil
        for id in ids {
            let 有 = 烘焙缓存目录.已有帧(id)
            if let 上次 = 交集 {
                交集 = 上次.intersection(有)
            } else {
                交集 = 有
            }
        }

        已烘焙帧 = 交集 ?? []
        指纹 = 当前指纹()
        统计.发射器数 = ids.count
        统计.已烘焙帧数 = 已烘焙帧.count
        统计.占用兆字节 = 烘焙缓存目录.占用兆字节()
        状态文字 = 已烘焙帧.isEmpty ? "未烘焙" : "读到 \(已烘焙帧.count) 帧缓存"
    }

    func 清空缓存() {
        guard !烘焙中 else { return }
        let ids = Set((指纹?.表.keys.map { $0 } ?? []) + 在场发射器().map(\.id))
        for id in ids { 烘焙缓存目录.清空发射器(id) }
        已烘焙帧 = []
        指纹 = nil
        内存帧缓存.removeAll()
        内存帧顺序.removeAll()
        统计 = 烘焙统计()
        状态文字 = "缓存已清空"
    }

    // MARK: - 烘焙

    func 烘焙全部() {
        guard !烘焙中 else { return }
        guard let layout, let shading else { return }

        let 发射器们 = 在场发射器()
        guard !发射器们.isEmpty else {
            状态文字 = "场景里没有启用的特效，先加一个发射器"
            return
        }

        let 时间轴 = 时间轴域.共享
        let 帧率 = 时间轴.帧率

        // 用户填的范围可能超出时间轴，也可能两个框填反了，这里一律夹正
        let 起 = max(min(起始帧, 结束帧), 时间轴.起始帧)
        let 束 = min(max(起始帧, 结束帧), 时间轴.结束帧)
        guard 束 >= 起 else {
            状态文字 = "帧范围不合法（时间轴是 \(时间轴.起始帧)–\(时间轴.结束帧)）"
            return
        }
        起始帧 = 起
        结束帧 = 束

        // 预热必须从时间轴起点跑起：粒子是有状态的，从半路起跑会缺掉前面已经飘出去的烟。
        // 预热段只推进不落盘，所以只是慢一些，不占缓存。
        let 预热起 = 时间轴.起始帧
        let 计划 = 烘焙指纹.生成(发射器们, 帧率: 帧率)

        烘焙中 = true
        进度 = 0
        状态文字 = "准备烘焙（\(起)–\(束)）"
        let 开始时刻 = Date()

        任务 = Task { [weak self] in
            await self?.跑(起: 起, 束: 束, 预热起: 预热起, 帧率: 帧率, 计划: 计划, 开始: 开始时刻)
        }
    }

    /// 停止烘焙：已写进磁盘的帧保留，下次可以接着烘（缓存按帧存，天然可续）。
    func 停止() {
        任务?.cancel()
    }

    private func 跑(起: Int, 束: Int, 预热起: Int, 帧率: Double, 计划: 烘焙指纹, 开始: Date) async {
        defer {
            烘焙中 = false
            任务 = nil
        }

        guard let layout, let shading else { return }
        guard let device = MTLCreateSystemDefaultDevice(),
              let 烘焙器 = 粒子烘焙器(device: device) else {
            状态文字 = "烘焙失败：拿不到 Metal 设备"
            return
        }

        let 时间轴 = 时间轴域.共享
        let 原帧 = 时间轴.当前帧
        时间轴.暂停()

        var 池们: [UUID: 烘焙池会话] = [:]
        var 粒子总数 = 0
        let 待写帧数 = 束 - 起 + 1
        var 已写 = 0

        // 只有存在动画轨道时，世界矩阵才会逐帧变；没有轨道的工程，
        // 预热段（可能几百帧）就没必要每帧跳一遍播放头重算一遍场景 —— 那是纯浪费。
        let 逐帧采样 = !时间轴.轨道表.isEmpty
        var 复用收集: (发射器: [粒子发射器快照], 球: [SIMD4<Float>])?
        var 已到帧 = Int.min

        for 帧 in 预热起...束 {
            if Task.isCancelled { break }

            let 收集: (发射器: [粒子发射器快照], 球: [SIMD4<Float>])
            if 逐帧采样 || 复用收集 == nil {
                // 播放头到位：发射器的世界矩阵可能由动画驱动，必须先求值再收集，
                // 否则烘出来的是一堆静止在初始变换上的粒子
                if 已到帧 != 帧 {
                    时间轴.跳(帧)
                    已到帧 = 帧
                }
                // 主线程算好世界矩阵：渲染线程与后台都不许碰数据层
                收集 = 粒子视口层.收集快照(layout.objects)
                复用收集 = 收集
            } else {
                收集 = 复用收集!
            }
            guard !收集.发射器.isEmpty else { break }

            for 快照 in 收集.发射器 {
                let 会话: 烘焙池会话
                if let 旧 = 池们[快照.id] {
                    会话 = 旧
                } else if let 新 = 烘焙器.建池(id: 快照.id, 设置: 快照.设置) {
                    池们[快照.id] = 新
                    会话 = 新
                } else {
                    continue
                }

                await 烘焙器.步进一帧(池: 会话,
                                      快照: 快照,
                                      域: shading.物理域,
                                      球: 收集.球,
                                      帧率: 帧率)

                // 预热段只推进状态，不落盘
                if 帧 >= 起 {
                    let 帧数据 = 会话.导出()
                    粒子总数 += 帧数据.粒子.count
                    let 路径 = 烘焙缓存目录.帧文件(快照.id, 帧: 帧)
                    try? 烘焙帧文件.写(帧数据, 帧号: 帧, 帧率: 帧率, 到: 路径)
                }
            }

            if 帧 >= 起 {
                已写 += 1
                进度 = Double(已写) / Double(待写帧数)
                状态文字 = "正在烘焙：第 \(帧) 帧（\(已写)/\(待写帧数)）"
            }

            // 每帧让出一次主线程：进度条能动、停止按钮点得着
            await Task.yield()
        }

        let 被取消 = Task.isCancelled

        // 播放头还原成用户原来的位置
        时间轴.跳(原帧)
        内存帧缓存.removeAll()
        内存帧顺序.removeAll()

        if 被取消 {
            // 已经写下去的帧要认账，扫盘重建
            刷新已烘焙帧()
            状态文字 = "烘焙已停止（已写入的帧保留）"
            return
        }

        已烘焙帧 = Set(起...束)
        指纹 = 计划
        统计 = 烘焙统计(发射器数: 池们.count,
                     已烘焙帧数: 已烘焙帧.count,
                     粒子总数量: 粒子总数,
                     用时秒: Date().timeIntervalSince(开始),
                     占用兆字节: 烘焙缓存目录.占用兆字节())
        状态文字 = String(format: "烘焙完成：%d 帧 / %d 个发射器，用时 %.1fs",
                      已烘焙帧.count, 池们.count, 统计.用时秒)
    }

    // MARK: - 回放

    func 有缓存(_ 帧: Int) -> Bool {
        已烘焙帧.contains(帧)
    }

    /// 取这一帧的现成结果。返回 nil = 没烘过 / 缓存对不上，视口会回落到实时模拟。
    func 回放取帧(_ 帧: Int) -> [UUID: 烘焙发射器帧]? {
        guard 已烘焙帧.contains(帧) else { return nil }
        if let 命中 = 内存帧缓存[帧] { return 命中 }

        // 参数改过就别拿旧缓存糊弄：宁可退回实时模拟，也不要放一段对不上的动画
        if let 指纹, 指纹 != 当前指纹() { return nil }

        let ids = 指纹.map { Array($0.表.keys) } ?? 在场发射器().map(\.id)
        guard !ids.isEmpty else { return nil }

        var 结果: [UUID: 烘焙发射器帧] = [:]
        for id in ids {
            let 路径 = 烘焙缓存目录.帧文件(id, 帧: 帧)
            if let 帧数据 = 烘焙帧文件.读(from: 路径, 期望帧号: 帧) {
                结果[id] = 帧数据
            }
        }
        guard !结果.isEmpty else { return nil }

        内存帧缓存[帧] = 结果
        内存帧顺序.append(帧)
        while 内存帧顺序.count > Self.内存帧上限 {
            let 老 = 内存帧顺序.removeFirst()
            内存帧缓存.removeValue(forKey: 老)
        }
        return 结果
    }
}
