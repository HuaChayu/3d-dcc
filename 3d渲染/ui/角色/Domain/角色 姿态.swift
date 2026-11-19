import Foundation
import simd

// MARK: - 角色姿态（摆姿势）
//
// 角色资产里的「骨数据」只有 rest 头尾点：那是骨架的静止形状，摆不了动作。
// 这里补一层姿态：每根骨存一个「相对父骨空间的局部旋转」，解算时沿父子链复合出
// 世界旋转与骨头/骨尾位置；蒙皮变形用 v' = Σ w · (骨头 + R · (v − rest骨头))。
//
// 为什么不用 rest/pose 矩阵那套：这套数据只要求「骨头 + 世界旋转」，骨长与滚转都不参与，
// 交互上等价于「绕骨头（关节）旋动这一节」，正好对应视口里拖关节球的语义。

/// 一次解算的结果。数组下标与 `角色资产.骨数据` 一一对应。
struct 角色姿态解算 {
    /// 每根骨的世界旋转
    var 世界旋转: [simd_quatf] = []
    /// 每根骨的头点（关节起点）世界位置
    var 骨头: [SIMD3<Float>] = []
    /// 每根骨的尾点（子关节）世界位置
    var 骨尾: [SIMD3<Float>] = []
    /// 全部骨都没有旋转：蒙皮可以整段跳过
    var 是静止: Bool = true
}

enum 角色姿态 {

    static let 单位 = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    static let 单位值 = SIMD4<Float>(0, 0, 0, 1)

    /// 存档里的四元数 → simd_quatf（脏数据先归一，长度太小的当单位）
    static func 四元数(_ 值: SIMD4<Float>?) -> simd_quatf {
        guard let 值 else { return 单位 }
        let 长 = simd_length(值)
        guard 长 > 0.0001, 长.isFinite else { return 单位 }
        let n = 值 / 长
        return simd_quatf(ix: n.x, iy: n.y, iz: n.z, r: n.w)
    }

    static func 值(_ q: simd_quatf) -> SIMD4<Float> {
        SIMD4<Float>(q.imag.x, q.imag.y, q.imag.z, q.real)
    }

    /// 有没有「真的摆过」。全单位四元数就当没摆，蒙皮直接跳过。
    static func 有姿态(_ 姿态: [String: SIMD4<Float>]) -> Bool {
        姿态.contains { 值 in
            abs(值.value.w - 1) > 1e-5
                || abs(值.value.x) > 1e-5
                || abs(值.value.y) > 1e-5
                || abs(值.value.z) > 1e-5
        }
    }

    /// 姿态指纹：进视口实体缓存的签名，姿态一动就换新值，实体随之重建。
    static func 签名(_ 姿态: [String: SIMD4<Float>]) -> String {
        guard !姿态.isEmpty else { return "-" }
        return 姿态
            .sorted { $0.key < $1.key }
            .map { 键, 值 in
                String(format: "%@:%.4f,%.4f,%.4f,%.4f", 键, 值.x, 值.y, 值.z, 值.w)
            }
            .joined(separator: ";")
    }

    /// 沿父子链解算世界旋转与头尾点。
    /// 父下标可能比子大、也可能成环（坏数据），所以按"逐条往根爬 + 记忆化"迭代，不做递归。
    static func 解算(骨: [角色骨骼], 姿态: [String: SIMD4<Float>]) -> 角色姿态解算 {
        let n = 骨.count
        guard n > 0 else { return 角色姿态解算() }

        var 旋 = [simd_quatf](repeating: 单位, count: n)
        var 头 = [SIMD3<Float>](repeating: .zero, count: n)
        var 已算 = [Bool](repeating: false, count: n)

        for 起 in 0..<n {
            guard !已算[起] else { continue }
            // 往上爬，收集「还没算过的祖先链」
            var 链: [Int] = []
            var 当前 = 起
            var 防环 = 0
            while !已算[当前], 防环 < n + 1 {
                链.append(当前)
                防环 += 1
                guard let 父 = 骨[当前].父, 父 >= 0, 父 < n, !链.contains(父) else { break }
                当前 = 父
            }
            // 从最靠根的一端往下算
            for 下标 in 链.reversed() {
                let 局 = 四元数(姿态[骨[下标].路径])
                if let 父 = 骨[下标].父, 父 >= 0, 父 < n, 已算[父] {
                    头[下标] = 头[父] + 旋[父].act(骨[下标].头 - 骨[父].头)
                    旋[下标] = 旋[父] * 局
                } else {
                    // 根骨（或父数据坏掉）：绕自己的头旋转，位置不动
                    头[下标] = 骨[下标].头
                    旋[下标] = 局
                }
                已算[下标] = true
            }
        }

        var 尾 = [SIMD3<Float>](repeating: .zero, count: n)
        for i in 0..<n {
            尾[i] = 头[i] + 旋[i].act(骨[i].尾 - 骨[i].头)
        }
        return 角色姿态解算(世界旋转: 旋, 骨头: 头, 骨尾: 尾, 是静止: !有姿态(姿态))
    }

    /// 蒙皮：把池里的静止几何按姿态摆出来，返回一份新数组（池里的原数据不动，
    /// 所以姿态随时可清空、可反复改，不会把模型越拖越歪）。
    static func 变形(片们: [导入网格], 骨: [角色骨骼], 解: 角色姿态解算) -> [导入网格] {
        guard !解.是静止, !骨.isEmpty, 解.世界旋转.count == 骨.count else { return 片们 }
        let 表 = 骨名表(骨)
        guard !表.isEmpty else { return 片们 }

        var 输出 = 片们
        for g in 输出.indices {
            let 顶点 = 输出[g].顶点
            let 权重 = 输出[g].权重
            guard !顶点.isEmpty, 权重.count == 顶点.count else { continue }
            let 原法线 = 输出[g].法线
            let 有法线 = 原法线.count == 顶点.count

            var 新点 = 顶点
            var 新法 = 原法线
            for vi in 顶点.indices {
                let v = 顶点[vi]
                var 累积 = SIMD3<Float>.zero
                var 法累积 = SIMD3<Float>.zero
                var 总: Float = 0
                for w in 权重[vi] {
                    guard w.重量 > 0, let b = 表[w.骨名] else { continue }
                    let r = 解.世界旋转[b]
                    累积 += (解.骨头[b] + r.act(v - 骨[b].头)) * w.重量
                    if 有法线 { 法累积 += r.act(原法线[vi]) * w.重量 }
                    总 += w.重量
                }
                guard 总 > 1e-5 else { continue }
                新点[vi] = 累积 / 总
                if 有法线 {
                    let n = 法累积 / 总
                    let 长 = simd_length(n)
                    新法[vi] = 长 > 1e-6 ? n / 长 : 原法线[vi]
                }
            }
            输出[g].顶点 = 新点
            if 有法线 { 输出[g].法线 = 新法 }
        }
        return 输出
    }

    /// 骨名 → 下标。权重里存的是 Blender 顶点组名，通常是骨名本身；
    /// 个别文件会带层级前缀，所以再补一层「路径末段」的兜底。
    static func 骨名表(_ 骨: [角色骨骼]) -> [String: Int] {
        var 表: [String: Int] = [:]
        表.reserveCapacity(骨.count * 2)
        for (i, b) in 骨.enumerated() {
            if !b.名称.isEmpty, 表[b.名称] == nil { 表[b.名称] = i }
        }
        for (i, b) in 骨.enumerated() {
            guard !b.路径.isEmpty else { continue }
            let 末 = b.路径.split(separator: "/").last.map(String.init) ?? b.路径
            if !末.isEmpty, 表[末] == nil { 表[末] = i }
            if 表[b.路径] == nil { 表[b.路径] = i }
        }
        return 表
    }

    /// 关节球要落在每根骨的终点（膝盖 / 脚踝 / 指尖都是别人的终点或自己的终点），
    /// 这里直接把解算出的骨尾点当作关节位置。
    static func 关节世界点(_ 解: 角色姿态解算, 骨下标 i: Int) -> SIMD3<Float>? {
        guard i >= 0, i < 解.骨尾.count else { return nil }
        return 解.骨尾[i]
    }
}
