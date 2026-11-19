import simd

/// # 角色木偶：拓扑驱动的静力学摆姿
///
/// 拖任意一颗关节球，其余关节自动落到「最像人」的位置。
/// 和 `角色约束求解` 的根本区别：那边要指定「目标骨 + 链长」，这边**一个骨名都不读**，
/// 刚度、限位、弯曲朝向全部由拓扑和静止几何算出来，任意来源、任意命名的骨架都能直接玩。
///
/// 四步，按优先级：
/// 1. **骨长** —— 硬，位置投影。抓着踝，膝只能弯，这就是隐式 IK
/// 2. **关节限位** —— 硬，矢状面内按屈曲范围、平面外按侧摆范围。
///    屈曲**带正负**：膝盖只能朝一个方向折，反折会被直接压回 0，所以不会变橡皮筋
/// 3. **重力** —— 半硬，放松方向朝世界下方偏一点，自由的手脚自然会垂下来
/// 4. **静止姿态先验** —— 软，「肌肉」，按拓扑刚度往回拉
///
/// 用**静力学**而不是动力学：没有速度项、没有上一帧、没有时间步，
/// 迭代到平衡就是终点，所以不会像弹簧那样来回晃。
///
/// 全流程只在两处用到「配置」，都不是骨名：
/// - `拓扑.前向`：角色正面朝哪（默认 +Z），用来定矢状面
/// - `拓扑.弯曲符号`：偏离 +1 / -1。翻一下就是膝往另一边折，用来适配不同导入朝向
enum 角色木偶 {

    static let 单位 = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)

    // MARK: - 拓扑表

    /// 一次性分析出来的拓扑。同一份骨架反复拖动时复用，不重建。
    struct 拓扑 {
        /// 合并后的关节（静止时头位置重合的骨共用一个关节）
        var 节点: [SIMD3<Float>] = []
        var 头节点: [Int] = []
        var 尾节点: [Int] = []
        /// 每个节点作为「尾」挂上的那根骨，没有则 -1
        var 入边: [Int] = []
        /// 按层升序的骨下标，父永远排在子前面
        var 层序: [Int] = []
        var 父: [Int] = []
        var 可用: [Bool] = []
        var 骨长: [Float] = []
        /// 0 = 完全松（末梢），1 = 完全硬（承重主干）
        var 刚度: [Float] = []
        /// 铰链关节：和父骨几乎共线，只能绕一根横轴折（膝、肘、手指）
        var 铰链: [Bool] = []
        /// 矢状面内允许的屈曲范围（弧度）。正 = 朝 `弯曲向` 折，负 = 反折
        var 屈曲下限: [Float] = []
        var 屈曲上限: [Float] = []
        /// 平面外允许的侧摆（弧度），铰链几乎不许侧摆
        var 侧摆上限: [Float] = []
        var 静止方向: [SIMD3<Float>] = []
        var 局部静止方向: [SIMD3<Float>] = []
        var 静止世界旋转: [simd_quatf] = []
        /// 钉住不动的关节（所有无父骨的头）
        var 根节点: [Int] = []
        /// 角色正面朝向，定义矢状面
        var 前向: SIMD3<Float> = SIMD3<Float>(0, 0, 1)
        /// 屈曲正方向 = 前向 × 这个符号。人体的膝和肘都往身体背面折，所以默认 -1
        var 弯曲符号: Float = -1
        /// 重力强度：放松方向朝世界下方偏多少
        var 重力: Float = 0.3
    }

    // MARK: - 构建

    /// 分析骨架：合并关节、算拓扑量、推刚度与限位。全流程不读 `名称`。
    static func 构建(骨: [角色骨骼]) -> 拓扑 {
        var 出 = 拓扑()
        let n = 骨.count
        guard n > 0 else { return 出 }

        let 静 = 角色姿态.解算(骨: 骨, 姿态: [:])
        出.静止世界旋转 = 静.世界旋转.count == n ? 静.世界旋转 : [simd_quatf](repeating: 单位, count: n)

        出.骨长 = 骨.map { simd_length($0.尾 - $0.头) }
        出.可用 = (0..<n).map { 骨[$0].有效 && 出.骨长[$0] > 1e-5 }
        出.静止方向 = (0..<n).map { i in
            let d = 骨[i].尾 - 骨[i].头
            let l = simd_length(d)
            return l > 1e-6 ? d / l : SIMD3<Float>(0, 1, 0)
        }

        // 父下标：越界 / 自指一律当根
        出.父 = (0..<n).map { i in
            guard let p = 骨[i].父, p >= 0, p < n, p != i else { return -1 }
            return p
        }

        // 合并关节：静止时头位置重合的骨共用同一个关节
        var 节点: [SIMD3<Float>] = []
        func 取节点(_ p: SIMD3<Float>) -> Int {
            for (k, q) in 节点.enumerated() where simd_distance(q, p) < 1e-3 { return k }
            节点.append(p)
            return 节点.count - 1
        }
        var 头节点 = [Int](repeating: 0, count: n)
        var 尾节点 = [Int](repeating: 0, count: n)
        for i in 0..<n where 出.可用[i] {
            头节点[i] = 取节点(骨[i].头)
            尾节点[i] = 取节点(骨[i].尾)
        }
        出.节点 = 节点
        出.头节点 = 头节点
        出.尾节点 = 尾节点

        var 入边 = [Int](repeating: -1, count: 节点.count)
        for i in 0..<n where 出.可用[i] {
            if 入边[尾节点[i]] < 0 { 入边[尾节点[i]] = i }
        }
        出.入边 = 入边

        // 层序：父先于子。沿父指针爬出来的深度，坏数据（环）也爬得出来
        let 层号 = (0..<n).map { i -> Int in
            var d = 0
            var k = i
            var 防环 = 0
            while 出.父[k] >= 0, 防环 < n {
                k = 出.父[k]
                d += 1
                防环 += 1
            }
            return d
        }
        出.层序 = (0..<n).sorted { 层号[$0] < 层号[$1] }

        // 子树规模：本骨下游（含自己）有几根骨
        var 子树 = [Int](repeating: 1, count: n)
        for i in 出.层序.reversed() where 出.父[i] >= 0 {
            子树[出.父[i]] += 子树[i]
        }
        // 测地距离（到根的累计骨长）：完全不依赖朝向，角色躺着也一样
        var 累计 = 出.骨长
        for i in 出.层序 where 出.父[i] >= 0 {
            累计[i] += 累计[出.父[i]]
        }
        let 最大累计 = max(累计.max() ?? 1, 1e-5)

        // 刚度：离根越远越松、子树越大越硬。代入人体正好是 脊柱/髋最硬 → 膝中 → 踝松 → 指最松
        出.刚度 = (0..<n).map { i in
            let t = min(max(累计[i] / 最大累计, 0), 1)
            let 份额 = Float(子树[i]) / Float(n)
            let raw = 0.65 * (1 - t) + 0.35 * 份额
            return min(max(raw, 0.03), 0.9)
        }

        // 铰链 / 球窝：和父骨越共线越像铰链（膝、肘、手指），越垂直越像球窝（髋、肩）
        出.铰链 = (0..<n).map { i -> Bool in
            let p = 出.父[i]
            guard p >= 0, 出.可用[p] else { return false }
            let c = simd_dot(出.静止方向[i], 出.静止方向[p])
            return acos(min(max(c, -1), 1)) < 0.52   // 30°
        }
        let 全向: Float = 85 * .pi / 180
        let 铰曲上限: Float = 150 * .pi / 180
        let 铰曲下限: Float = -2 * .pi / 180
        let 铰侧: Float = 6 * .pi / 180
        出.屈曲上限 = (0..<n).map { 出.铰链[$0] ? 铰曲上限 : 全向 }
        出.屈曲下限 = (0..<n).map { 出.铰链[$0] ? 铰曲下限 : -全向 }
        出.侧摆上限 = (0..<n).map { 出.铰链[$0] ? 铰侧 : 全向 }

        // 局部静止方向：父骨空间里的这一节朝哪儿。父骨一转，期望方向跟着转
        出.局部静止方向 = (0..<n).map { i -> SIMD3<Float> in
            let p = 出.父[i]
            guard p >= 0, 出.可用[p] else { return 出.静止方向[i] }
            return 出.静止世界旋转[p].inverse.act(出.静止方向[i])
        }

        var 根: [Int] = []
        for i in 0..<n where 出.可用[i] && 出.父[i] < 0 {
            if !根.contains(头节点[i]) { 根.append(头节点[i]) }
        }
        出.根节点 = 根
        return 出
    }

    // MARK: - 求解

    /// 抓一个关节，把整身落到最自然的平衡位。
    /// - Parameters:
    ///   - 抓取节点: 被抓住的关节下标（`拓扑` 里的节点号）
    ///   - 抓取目标: 想把它拖到哪儿（角色局部空间）
    static func 求解(骨: [角色骨骼],
                     拓扑: 拓扑,
                     姿态: [String: SIMD4<Float>],
                     抓取节点: Int?,
                     抓取目标: SIMD3<Float>,
                     外轮: Int = 26) -> [String: SIMD4<Float>] {
        let n = 骨.count
        guard n > 0, 拓扑.节点.count > 0,
              拓扑.可用.count == n, 拓扑.头节点.count == n else { return 姿态 }

        // 1. 热启动：点集从当前姿态接过来，拖起来才不会跳
        let 解 = 角色姿态.解算(骨: 骨, 姿态: 姿态)
        var 点 = 拓扑.节点
        var 已填 = [Bool](repeating: false, count: 点.count)
        for i in 0..<n where 拓扑.可用[i] {
            let a = 拓扑.头节点[i], b = 拓扑.尾节点[i]
            if !已填[a], i < 解.骨头.count { 点[a] = 解.骨头[i]; 已填[a] = true }
            if !已填[b], i < 解.骨尾.count { 点[b] = 解.骨尾[i]; 已填[b] = true }
        }

        // 1.5 范围：被抓关节沿父骨往上爬到根，到根之后还要再上一层。
        //     同一个关节上可能挂着好几根父骨（`入边` 只记第一根，其余会被漏掉），
        //     所以这里枚举全部父骨逐层上溯：只走父方向，不碰子链、也不碰同层兄弟。
        var 可写 = [Bool](repeating: false, count: n)
        if let g = 抓取节点, g >= 0, g < 点.count {
            // 主链：单父那条直系
            var 节点 = g
            var 步 = 0
            while 步 < 128 {
                let e = 拓扑.入边[节点]
                guard e >= 0, e < n, 拓扑.可用[e], !可写[e] else { break }
                可写[e] = true
                节点 = 拓扑.头节点[e]
                步 += 1
            }
            // 上一层：根节点上还挂着的父骨全收进来，这一层可能不止一根
            var 本层 = [节点]
            var 层步 = 0
            while 层步 < 8, !本层.isEmpty {
                var 下层: [Int] = []
                for 节 in 本层 {
                    for i in 0..<n where 拓扑.可用[i] && 拓扑.尾节点[i] == 节 && !可写[i] {
                        可写[i] = true
                        下层.append(拓扑.头节点[i])
                    }
                }
                本层 = 下层
                层步 += 1
            }
        }
        if !可写.contains(true) { for i in 0..<n { 可写[i] = true } }

        // 2. 钉住：所有根（髋/肩那层）原地不动，被抓的关节钉到目标
        var 钉: [Int: SIMD3<Float>] = [:]
        // 正常骨架根很少；要是父子关系大面积缺失（每根骨都成了根），全钉等于拖不动，
        // 这时只钉被抓的那条链的根，其余交给骨长和重力去平衡
        if 拓扑.根节点.count <= max(2, n / 10) {
            for r in 拓扑.根节点 where r >= 0 && r < 点.count {
                钉[r] = 点[r]
            }
        } else if let g = 抓取节点, g >= 0, g < 点.count {
            let (链根, _) = 链根与长度(到: g, 拓扑: 拓扑)
            if 链根 >= 0, 链根 < 点.count { 钉[链根] = 点[链根] }
        }
        var 抓 = -1
        var 目标 = 抓取目标
        if let g = 抓取节点, g >= 0, g < 点.count {
            // 抓太远就沿链表方向伸直，别让骨长被硬拽断
            let (链根, 臂展) = 链根与长度(到: g, 拓扑: 拓扑)
            if 臂展 > 1e-5, 链根 >= 0, 链根 < 点.count {
                let d = 目标 - 点[链根]
                let dl = simd_length(d)
                if dl > 臂展 { 目标 = 点[链根] + d * (臂展 / dl) }
            }
            钉[g] = 目标
            点[g] = 目标
            抓 = g
        }

        // 3. 破共线退化：腿伸直时膝往哪弯其实有两个解，先朝「目标那一侧」推一把，
        //    迭代才会收敛到人该有的那一边（否则会绕去反关节）
        if 抓 >= 0 {
            let (链根, _) = 链根与长度(到: 抓, 拓扑: 拓扑)
            var 向 = 拓扑.前向
            if 链根 >= 0, 链根 < 点.count {
                let d = 抓取目标 - 点[链根]
                let dl = simd_length(d)
                if dl > 1e-5 {
                    let 单位向 = d / dl
                    let 分量 = 拓扑.前向 - 单位向 * simd_dot(单位向, 拓扑.前向)
                    if simd_length(分量) > 1e-4 { 向 = simd_normalize(分量) }
                }
            }
            var 当前 = 抓
            var 步 = 0
            while 步 < 16 {
                let e = 拓扑.入边[当前]
                guard e >= 0, 拓扑.可用[e] else { break }
                点[当前] += 向 * (拓扑.骨长[e] * 0.35)
                当前 = 拓扑.头节点[e]
                步 += 1
            }
        }

        var 世界 = 拓扑.静止世界旋转
        let 层序 = 拓扑.层序
        let 下 = SIMD3<Float>(0, -1, 0)

        var 上一轮 = 点
        for _ in 0..<max(外轮, 4) {
            // a. 刷新每根骨的世界旋转（roll 永远钉在静止姿态上，所以不会乱翻）
            for i in 层序 where 拓扑.可用[i] {
                let d = 点[拓扑.尾节点[i]] - 点[拓扑.头节点[i]]
                let l = simd_length(d)
                guard l > 1e-6 else { continue }
                世界[i] = simd_quatf(from: 拓扑.静止方向[i], to: d / l) * 拓扑.静止世界旋转[i]
            }

            // b. 骨长：正反各扫一遍，从根往末、从末往根都要传得到
            for 向 in 0..<2 {
                let 序 = 向 == 0 ? 层序 : 层序.reversed()
                for i in 序 where 拓扑.可用[i] {
                    let a = 拓扑.头节点[i], b = 拓扑.尾节点[i]
                    guard a != b else { continue }
                    var d = 点[b] - 点[a]
                    let l = simd_length(d)
                    guard l > 1e-6 else { continue }
                    let 差 = (l - 拓扑.骨长[i]) / l
                    let 钉a = 钉[a] != nil, 钉b = 钉[b] != nil
                    if 钉a && 钉b { continue }
                    d *= 差
                    if 钉a {
                        点[b] -= d
                    } else if 钉b {
                        点[a] += d
                    } else {
                        点[a] += d * 0.5
                        点[b] -= d * 0.5
                    }
                }
            }

            // c. 限位 + 重力 + 肌肉。三个一起做完，一步一个方向
            for i in 层序 where 拓扑.可用[i] {
                let a = 拓扑.头节点[i], b = 拓扑.尾节点[i]
                guard a != b else { continue }
                let 钉a = 钉[a] != nil, 钉b = 钉[b] != nil
                if 钉a && 钉b { continue }

                let p = 拓扑.父[i]
                let 父旋 = p >= 0 ? 世界[p] : 单位
                let 原期望 = 父旋.act(拓扑.局部静止方向[i])
                let 原长 = simd_length(原期望)
                guard 原长 > 1e-6 else { continue }
                let 期望 = 原期望 / 原长

                var 当前 = 点[b] - 点[a]
                let l = simd_length(当前)
                guard l > 1e-6 else { continue }
                当前 /= l

                // 限位贴着锥边走：反折会被压回 0，膝就不会折成橡皮泥
                let 限 = 钳制(当前, 期望: 期望, 拓扑: 拓扑, 骨: i)

                // 重力：放松方向朝下偏一点，自由的手脚自然下垂
                var 松 = 期望 + 下 * 拓扑.重力
                let 松长 = simd_length(松)
                松 = 松长 > 1e-6 ? 松 / 松长 : 期望

                // 肌肉：按拓扑刚度往回拉。刚度高的关节就是「有肌肉撑着」
                let w = 拓扑.刚度[i] * 0.18
                var 新 = 限 + (松 - 限) * w
                let 新长 = simd_length(新)
                guard 新长 > 1e-6 else { continue }
                新 /= 新长

                // 被抓的点不能动，那就反过来把父端挪开：这一节的角度照样生效
                if 钉b {
                    点[a] = 点[b] - 新 * 拓扑.骨长[i]
                } else {
                    点[b] = 点[a] + 新 * 拓扑.骨长[i]
                }
            }

            // d. 钉住最后兜底，保证被抓的点精确落在鼠标上
            for (k, v) in 钉 { 点[k] = v }

            // e. 已经不动了就早点收工，别把帧预算耗在无意义的迭代上
            var 位移: Float = 0
            for k in 点.indices { 位移 = max(位移, simd_distance(点[k], 上一轮[k])) }
            if 位移 < 2e-4 { break }
            上一轮 = 点
        }

        // 4. 导出：只写回本次操作该动的那一段——被抓关节沿父链上溯到根，再带上根的那一层。
        //    链远端（手指、另一条腿、摆好姿势的脚）不写回局部旋转，
        //    它们刚性跟着父骨走，不会再被重力或静止先验重新拉回原样。
        var 世界2 = 世界
        for i in 层序 where 拓扑.可用[i] && 可写[i] {
            let d = 点[拓扑.尾节点[i]] - 点[拓扑.头节点[i]]
            let l = simd_length(d)
            guard l > 1e-6 else { continue }
            世界2[i] = simd_quatf(from: 拓扑.静止方向[i], to: d / l) * 拓扑.静止世界旋转[i]
        }

        var 出 = 姿态
        for i in 0..<n where 拓扑.可用[i] && 可写[i] && !骨[i].路径.isEmpty {
            let p = 拓扑.父[i]
            let 父旋 = p >= 0 ? 世界2[p] : 单位
            出[骨[i].路径] = 角色姿态.值(父旋.inverse * 世界2[i])
        }
        return 出
    }

    // MARK: - 限位

    /// 把方向钳进允许范围：矢状面内的屈曲有个带正负的区间，平面外的侧摆有个小锥。
    /// 膝之所以不会反折，全靠这里 `屈曲下限 ≈ 0`。
    private static func 钳制(_ 方向: SIMD3<Float>,
                            期望: SIMD3<Float>,
                            拓扑: 拓扑,
                            骨 i: Int) -> SIMD3<Float> {
        let 弯曲向 = 拓扑.前向 * 拓扑.弯曲符号
        var f = 弯曲向 - 期望 * simd_dot(期望, 弯曲向)
        let fl = simd_length(f)
        guard fl > 1e-5 else { return 方向 }
        f /= fl
        let s = simd_normalize(simd_cross(期望, f))

        let θ = atan2(simd_dot(方向, f), simd_dot(方向, 期望))
        let φ = asin(min(max(simd_dot(方向, s), -1), 1))
        let 侧 = 拓扑.侧摆上限[i]
        let θ2 = min(max(θ, 拓扑.屈曲下限[i]), 拓扑.屈曲上限[i])
        let φ2 = min(max(φ, -侧), 侧)
        guard abs(θ2 - θ) > 1e-5 || abs(φ2 - φ) > 1e-5 else { return 方向 }

        let 新 = 期望 * (cos(θ2) * cos(φ2)) + f * (sin(θ2) * cos(φ2)) + s * sin(φ2)
        let l = simd_length(新)
        return l > 1e-6 ? 新 / l : 方向
    }

    // MARK: - 查询

    /// 骨尾（关节球所在处）→ 节点号。视口按下时用它把「球」对上「关节」。
    static func 节点(of 骨下标: Int, 拓扑: 拓扑) -> Int? {
        guard 骨下标 >= 0, 骨下标 < 拓扑.尾节点.count, 骨下标 < 拓扑.可用.count,
              拓扑.可用[骨下标] else { return nil }
        return 拓扑.尾节点[骨下标]
    }

    /// 沿父链往上爬到链根，顺便累加骨长：抓取目标超出这个长度就只能伸直
    private static func 链根与长度(到 节点: Int, 拓扑: 拓扑) -> (Int, Float) {
        var 当前 = 节点
        var 总: Float = 0
        var 步 = 0
        while 步 < 64, 当前 >= 0, 当前 < 拓扑.入边.count {
            let e = 拓扑.入边[当前]
            guard e >= 0, 拓扑.可用[e] else { break }
            总 += 拓扑.骨长[e]
            当前 = 拓扑.头节点[e]
            步 += 1
        }
        return (当前, 总)
    }
}
