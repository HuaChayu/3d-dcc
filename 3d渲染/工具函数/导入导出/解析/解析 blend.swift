import Foundation
import simd

/// .blend 纯原生解析。
///
/// 不依赖 Blender 软件，也不调用任何外部进程：直接按 Blender 公开的文件格式
/// （`BLENDER` 文件头 + `BHead` 块链 + `DNA1` 里的 SDNA 结构定义）读取几何。
/// 关键点是 **SDNA 自带每个结构每个字段的顺序与类型**，所以版本差异靠文件自身
/// 描述来适配，不需要把某个版本的 struct 布局硬编码进来。
///
/// 轴向：这里**不做任何转换**。文件里是什么坐标就输出什么坐标（.blend 传统上
/// 是 Z 向上），由上层的「上轴校正」统一转到 App 的 Y 向上 ——
/// 一处转换，绝不两处各翻一次。
enum Blend解析 {

    // MARK: - 常量

    private static let 指针长 = 8
    private static let 块头长 = 32

    // MARK: - 导入入口

    static func 导入(url: URL, 设置: 单文件导入设置) throws -> 导入场景 {
        guard let 数据 = try? Data(contentsOf: url) else {
            throw 导入导出错误.文件不可读(url)
        }
        var 原 = [UInt8](数据)
        // 压缩容器：Blender 可把整个文件包一层 zstd / gzip。
        // zstd 用内嵌的 zstd 源码就地脱壳，脱完就是普通 .blend，后面流程不用区分。
        var 压缩说明: String? = nil
        if Zstd.是压缩数据(原) {
            let 壳长 = 原.count
            原 = try Zstd.解压(原)
            压缩说明 = "Zstd 整包解压：\(壳长) → \(原.count) 字节"
        }
        if 原.count >= 2, 原[0] == 0x1F, 原[1] == 0x8B {
            throw 导入导出错误.解析失败(
                格式: "BLEND",
                原因: "该 .blend 被 gzip 整包压缩。请另存一份不压缩的 .blend 后再导入")
        }

        guard 原.count > 64 else {
            throw 导入导出错误.解析失败(格式: "BLEND", 原因: "文件过小，不是有效的 .blend")
        }

        _ = 设置
        let 头 = 解头(原)
        guard 原.count > 头.长度 + 块头长 else {
            throw 导入导出错误.解析失败(格式: "BLEND", 原因: "文件头之后没有块数据")
        }

        let 文件 = 文件视图(原: 原, 大头: 头.大头)
        let 块表 = try 遍历块(文件: 文件, 起: 头.长度, 块头: 头.块头)

        guard let DNA块 = 块表.first(where: { $0.码 == "DNA1" }) else {
            throw 导入导出错误.解析失败(格式: "BLEND", 原因: "缺少 DNA1 块，无法获知结构布局")
        }
        let 结构表 = try 解析SDNA(文件: 文件, 块: DNA块)

        // old 地址 → 块内容，用于指针解引用
        var 地址表: [UInt64: 块] = [:]
        地址表.reserveCapacity(块表.count)
        for 块 in 块表 where 块.旧地址 != 0 {
            地址表[块.旧地址] = 块
        }

        var 场景 = 导入场景(源文件: url)
        场景.文件上轴 = .z
        if let 压缩说明 { 场景.报告.append(压缩说明) }

        let 顶点来源说明 = ""

        // ---- 1. 所有 ME 块先解成网格，按 Mesh 的 ID 旧地址登记 ----
        // 5.x 里同一 old 地址可能出现多份不同内容的块（内存复用），只认第一份。
        var 网格表: [UInt64: 导入网格] = [:]
        var 网格序 = 0
        for (块序, 块) in 块表.enumerated() where 块.码 == "ME" {
            guard 块.长 >= 64 else { continue }
            // 本网格的数据块区间：紧跟本 ME 之后，到下一个 ME 之前
            var 组止 = 块表.count
            var 探 = 块序 + 1
            while 探 < 块表.count {
                if 块表[探].码 == "ME" { 组止 = 探; break }
                探 += 1
            }
            guard let 网格 = try? 读网格(文件: 文件, 块: 块, 结构: 结构表, 地址: 地址表,
                                       块表: 块表, 区间起: 块序 + 1, 区间止: 组止) else { continue }
            guard !网格.顶点.isEmpty, !网格.索引.isEmpty else { continue }

            网格序 += 1
            var 产 = 网格
            产.名称 = "网格\(网格序)"
            // 一次网格数据可能被多个对象共享（实例复制），先只存一份，对象阶段再各复制
            if 块.旧地址 != 0, 网格表[块.旧地址] == nil { 网格表[块.旧地址] = 产 }
        }

        // ---- 2. 读对象块（OB）：对象名 / 父子层级 / 对象变换 ----
        // 只解 ME 会把「一堆带层级的对象」压成「一堆无名网格」，上层再整包塞进一个
        // SceneObject，就彻底看不出文件原来的结构了。
        let 对象表 = 读对象表(文件: 文件, 块表: 块表, S: 结构表)
        let 组 = 组装(对象表: 对象表, 网格表: 网格表, 文件: 文件, 块表: 块表, S: 结构表, 地址表: 地址表)

        if 组.网格.isEmpty {
            // 兜底：没有可用对象信息（老文件 / 对象块异常）时按网格顺序平铺，至少别丢几何
            var 已用名: Set<String> = []
            for (序, 网格) in 网格表.values.enumerated() {
                var 名 = 网格.名称
                if 已用名.contains(名) { 名 += "_\(序 + 1)" }
                已用名.insert(名)
                var 产物 = 网格
                产物.名称 = 名
                产物.对齐属性()
                产物.重建默认子集()
                场景.网格.append(产物)
            }
        } else {
            场景.网格 = 组.网格
            场景.节点 = 组.节点
            for 说明 in 组.报告 { 场景.报告.append(说明) }
            if let 说明 = 蒙皮摆姿(节点: &场景.节点, 网格: &场景.网格) { 场景.报告.append(说明) }
        }

        guard !场景.网格.isEmpty else {
            throw 导入导出错误.无有效几何(url)
        }

        // ---- 3. 材质：MA 块 → 场景材质；对象的材质槽 → 网格子集材质下标 ----
        // 以前这一步是缺的：面里只有 material_index，没有 MA 块就没有材质名与颜色，
        // 上层判定「单默认材质」直接不入库，于是整个模型都退回那个陶土球。

        let 材质结果 = 读材质表(文件: 文件, 块表: 块表, S: 结构表, 地址: 地址表,
                       基目录: url.deletingLastPathComponent(), 源文件: url)
        if !材质结果.材质.isEmpty {
            场景.材质 = 材质结果.材质
            let 样例 = 材质结果.材质.prefix(5).map(\.名称).joined(separator: "、")
            场景.报告.append("识别到 \(材质结果.材质.count) 个材质：\(样例)\(材质结果.材质.count > 5 ? " 等" : "")")
            if 材质结果.贴图数 - 材质结果.外部图数 > 0 {
                场景.报告.append("带回 \(材质结果.贴图数 - 材质结果.外部图数) 张打包在 .blend 里的贴图")
            }
            if 材质结果.外部图数 > 0 {
                场景.报告.append("从 .blend 外部的图片路径读到 \(材质结果.外部图数) 张贴图")
            }
            if 材质结果.缺图数 > 0 {
                场景.报告.append("\(材质结果.缺图数) 个材质的贴图既没打包、外部路径也读不到，只能落颜色")
            }
        }
        if !材质结果.下标.isEmpty, !组.网格来源.isEmpty {
            var 已绑 = 0
            for (网格序, 对象序) in 组.网格来源.enumerated() where 网格序 < 场景.网格.count {
                let 槽 = 对象表[对象序].材质槽
                guard !槽.isEmpty else { continue }
                var 子集 = 场景.网格[网格序].子集
                for i in 子集.indices {
                    // 面里没有 material_index 属性的网格（单槽对象在 Blender 里很常见）：
                    // 不能因为「没面材质号」就跳过绑定，否则这一片会退回缺省陶土球，
                    // 整角色看着就只剩一个材质。没有号就按第 0 槽。
                    let 号 = 子集[i].材质 ?? 0
                    guard 号 >= 0, 号 < 槽.count,
                          let 全 = 材质结果.下标[槽[号]] else { continue }
                    子集[i].材质 = 全
                    子集[i].材质名 = 场景.材质[全].名称
                    已绑 += 1
                }
                场景.网格[网格序].子集 = 子集
            }
            if 已绑 > 0 { 场景.报告.append("已把 \(已绑) 个网格子集对回 .blend 里的材质槽") }
            // 有槽没面：Blender 里材质槽可以留空/不对应任何面，导进来就是「槽有 N 个、表面只有一个」。
            // 直接写进报告，用户不用猜是不是导入漏了材质。
            var 空槽说明: [String] = []
            for (网格序, 对象序) in 组.网格来源.enumerated() where 网格序 < 场景.网格.count {
                let 槽 = 对象表[对象序].材质槽
                guard 槽.count > 1 else { continue }
                let 用了 = Set(场景.网格[网格序].子集.compactMap { $0.材质 })
                let 未用 = 槽.indices.compactMap { 材质结果.下标[槽[$0]] }.filter { !用了.contains($0) }
                guard !未用.isEmpty else { continue }
                let 名 = 未用.map { 场景.材质[$0].名称 }.joined(separator: "、")
                空槽说明.append("\(对象表[对象序].名) 有 \(槽.count) 个材质槽，其中 \(未用.count) 个没有面在用（\(名)），表面只显示被面引用的那个")
            }
            if !空槽说明.isEmpty { 场景.报告.append(contentsOf: 空槽说明.prefix(4)) }
        }

        if !顶点来源说明.isEmpty { 场景.报告.append(顶点来源说明) }
        场景.报告.append("按 .blend 自带 DNA 结构定义原生解析，未做任何轴向转换。")
        return 场景
    }

    // MARK: - 对象（OB 块）

    private struct 对象记录 {
        var 旧地址: UInt64 = 0
        /// ID 名字去掉 "OB" 前缀后的显示名
        var 名: String = ""
        /// OB_MESH = 1，OB_EMPTY = 0，OB_CAMERA = 11，OB_LIGHT = 10，OB_ARMATURE = 25 …
        var 类型码: UInt16 = 0
        var 父地址: UInt64 = 0
        var 数据地址: UInt64 = 0
        var 局部矩阵: simd_float4x4 = matrix_identity_float4x4
        var 父逆矩阵: simd_float4x4 = matrix_identity_float4x4
        /// 骨骼父级（partype != 0）：骨骼偏移没解析，只能按对象级近似
        var 骨父级 = false
        /// Object.defbase.first：顶点组链表头（bDeformGroup），组名就是骨骼名
        var 组首地址: UInt64 = 0
        /// Object.**mat：材质槽指针数组，槽下标就是网格面里的 material_index
        var 材质槽: [UInt64] = []
    }

    private static func 类型说明(_ 码: UInt16) -> String {
        switch 码 {
        case 0: return "空物体"
        case 1: return "网格"
        case 10: return "灯光"
        case 11: return "相机"
        case 22: return "曲线"
        case 25: return "骨架"
        default: return "对象"
        }
    }

    /// 遍历所有 OB 块，读出名字 / 类型 / 父对象 / Mesh 数据指针 / 局部矩阵。
    /// 字段偏移全部走 SDNA —— 5.0 与 5.1 的 Object 布局就不一样（type 在 432 vs 416），
    /// 硬编码必错。
    private static func 读对象表(文件: 文件视图, 块表: [块], S: SDNA) -> [对象记录] {
        guard let 名路 = 路径偏移("Object", "id.name", S),
              let 型路 = 路径偏移("Object", "type", S),
              let 父路 = 路径偏移("Object", "parent", S),
              let 数路 = 路径偏移("Object", "data", S),
              let 位路 = 路径偏移("Object", "loc", S),
              let 尺路 = 路径偏移("Object", "size", S),
              let 转路 = 路径偏移("Object", "rot", S) else { return [] }

        let 四元路 = 路径偏移("Object", "quat", S)
        let 模路 = 路径偏移("Object", "rotmode", S)
        let 逆父路 = 路径偏移("Object", "parentinv", S)
        let 父类路 = 路径偏移("Object", "partype", S)
        // 5.x 里顶点组链表就是 ListBase defbase（first 指针 + last 指针，各 8 字节）
        let 组路 = 路径偏移("Object", "defbase", S)
        // 材质槽：Object.**mat 指向「Material* 数组」，Object.totcol 是槽数。
        // 面里的 material_index 用的就是槽下标，所以这张槽表必须按对象存下来。
        let 槽路 = 字段偏移("Object", "mat", S)
        let 槽数路 = 字段偏移("Object", "totcol", S)
        var 全地址: [UInt64: 块] = [:]
        for 块 in 块表 where 块.旧地址 != 0 { 全地址[块.旧地址] = 块 }

        var 结果: [对象记录] = []
        for 块 in 块表 where 块.码 == "OB" {
            let 起 = 块.数据起
            let 长 = 块.长
            guard 长 > 名路.偏移, 长 > 型路.偏移 else { continue }

            var 记 = 对象记录()
            记.旧地址 = 块.旧地址
            var 名 = 文件.串(起 + 名路.偏移, 长: 66)
            // .blend 的 ID 名字带 2 字符类型前缀（"OB" / "ME" / "GR"），去掉才是用户看到的名字
            if 名.count > 2, 名.hasPrefix("OB") { 名 = String(名.dropFirst(2)) }
            记.名 = 名
            记.类型码 = 文件.u16(起 + 型路.偏移)
            记.父地址 = 父路.偏移 + 8 <= 长 ? 文件.u64(起 + 父路.偏移) : 0
            记.数据地址 = 数路.偏移 + 8 <= 长 ? 文件.u64(起 + 数路.偏移) : 0
            if let 父类路, 父类路.偏移 + 2 <= 长, 文件.u16(起 + 父类路.偏移) != 0 {
                记.骨父级 = true
            }
            if let 组路, 组路.偏移 + 8 <= 长 {
                记.组首地址 = 文件.u64(起 + 组路.偏移)
            }
            // 材质槽在哪一版上放的位置不一样：
            //   · 4.x 及更早：Object.mat / Object.totcol
            //   · 5.x 起：槽搬到了网格数据上（Mesh.mat / Mesh.totcol），Object.mat 恒为 0。
            // 实测 6号王宁宁 这类 5.x 存出来的文件，Object.mat 读到的是全 0 副本，
            // 只有 Mesh.mat 指向的那个数组里才真的是 MA 指针 —— 取错一份，整个模型就只剩陶土。
            // 两条路都试，并且用「指针能不能命中 MA 块」做校验，避免拿到同地址的空壳副本。
            func 读槽数组(_ 宿主: 块, _ 基准: Int, _ 槽字段: 字段, _ 数段: 字段) -> [UInt64] {
                guard 基准 + 数段.偏移 + 4 <= 宿主.长, 基准 + 槽字段.偏移 + 8 <= 宿主.长 else { return [] }
                // totcol 在 DNA 里是 short（后面紧跟填充），按 32 位读会把相邻字段一起读进来
                let 数 = Int(文件.u32(宿主.数据起 + 基准 + 数段.偏移) & 0xFFFF)
                guard 数 > 0, 数 < 4096 else { return [] }
                let 首址 = 文件.u64(宿主.数据起 + 基准 + 槽字段.偏移)
                guard 首址 != 0 else { return [] }
                // 同一 old 地址可能对应多份块，挑「内容真是材质指针」的那一份
                var 候选块: [块] = []
                for b in 块表 where b.旧地址 == 首址 { 候选块.append(b) }
                for b in 块表 where 首址 > b.旧地址 && 首址 < b.旧地址 &+ UInt64(b.长) { 候选块.append(b) }
                var 最佳: [UInt64] = []
                for b in 候选块 {
                    let 偏 = Int(首址 - b.旧地址)
                    var 组: [UInt64] = []
                    组.reserveCapacity(数)
                    for k in 0..<数 {
                        let q = b.数据起 + 偏 + k * 8
                        guard q + 8 <= b.数据起 + b.长 else { break }
                        组.append(文件.u64(q))
                    }
                    let 命中 = 组.filter { 全地址[$0]?.码 == "MA" }.count
                    if 命中 > 最佳.filter({ 全地址[$0]?.码 == "MA" }).count { 最佳 = 组 }
                }
                return 最佳
            }

            var 候选槽: [[UInt64]] = []
            if 记.数据地址 != 0, let (网格块, 网偏) = 解引用(记.数据地址, 全地址, 块表),
               let 网槽路 = 字段偏移("Mesh", "mat", S),
               let 网槽数路 = 字段偏移("Mesh", "totcol", S) {
                候选槽.append(读槽数组(网格块, 网偏, 网槽路, 网槽数路))
            }
            if let 槽路, let 槽数路 {
                候选槽.append(读槽数组(块, 0, 槽路, 槽数路))
            }
            记.材质槽 = 候选槽.first { 组 in
                !组.isEmpty && 组.contains { 全地址[$0]?.码 == "MA" }
            } ?? []

            // 局部矩阵 = T(loc) · R(rot) · S(size)
            let 位 = SIMD3<Float>(文件.f32(起 + 位路.偏移), 文件.f32(起 + 位路.偏移 + 4),
                              文件.f32(起 + 位路.偏移 + 8))
            let 尺 = SIMD3<Float>(文件.f32(起 + 尺路.偏移), 文件.f32(起 + 尺路.偏移 + 4),
                              文件.f32(起 + 尺路.偏移 + 8))
            var 转: simd_float4x4
            if let 模路, let 四元路, 模路.偏移 + 2 <= 长, 四元路.偏移 + 16 <= 长,
               文件.u16(起 + 模路.偏移) == 1 {
                // rotmode == QUATERNION：quat 存的是 (w, x, y, z)
                let q = simd_quatf(ix: 文件.f32(起 + 四元路.偏移 + 4),
                                   iy: 文件.f32(起 + 四元路.偏移 + 8),
                                   iz: 文件.f32(起 + 四元路.偏移 + 12),
                                   r: 文件.f32(起 + 四元路.偏移))
                转 = simd_float4x4(q)
            } else {
                转 = 欧拉矩阵(SIMD3<Float>(文件.f32(起 + 转路.偏移), 文件.f32(起 + 转路.偏移 + 4),
                                       文件.f32(起 + 转路.偏移 + 8)))
            }
            记.局部矩阵 = 平移矩阵(位) * 转 * 缩放矩阵(尺)

            if let 逆父路, 逆父路.偏移 + 64 <= 长 {
                let o = 起 + 逆父路.偏移
                var 列: [SIMD4<Float>] = []
                for c in 0..<4 {
                    let p = o + c * 16
                    列.append(SIMD4<Float>(文件.f32(p), 文件.f32(p + 4),
                                          文件.f32(p + 8), 文件.f32(p + 12)))
                }
                记.父逆矩阵 = simd_float4x4(columns: (列[0], 列[1], 列[2], 列[3]))
            }

            结果.append(记)
        }
        return 结果
    }

    /// 对象表 + 网格表 → 场景网格（一个网格对象一份，已带世界变换）+ 节点树
    private static func 组装(对象表: [对象记录], 网格表: [UInt64: 导入网格],
                             文件: 文件视图, 块表: [块], S: SDNA, 地址表: [UInt64: 块])
        -> (网格: [导入网格], 节点: [导入节点], 报告: [String], 网格来源: [Int]) {
        guard !对象表.isEmpty else { return ([], [], [], []) }

        var 地址索引: [UInt64: Int] = [:]
        for (i, o) in 对象表.enumerated() where o.旧地址 != 0 && 地址索引[o.旧地址] == nil {
            地址索引[o.旧地址] = i
        }

        // old 地址会被复用（5.x 里大部分结构都写成通用 DATA 块），姿态块要靠候选列表挑
        var 块索引: [UInt64: [块]] = [:]
        for 块 in 块表 where 块.旧地址 != 0 { 块索引[块.旧地址, default: []].append(块) }

        // 世界矩阵 = parent.world · parentinv · local
        var 世界表: [simd_float4x4?] = Array(repeating: nil, count: 对象表.count)
        func 世界(_ i: Int, _ 深: Int) -> simd_float4x4 {
            if let w = 世界表[i] { return w }
            var 结 = 对象表[i].局部矩阵
            if 对象表[i].父地址 != 0, let p = 地址索引[对象表[i].父地址], p != i, 深 < 64 {
                结 = 世界(p, 深 + 1) * 对象表[i].父逆矩阵 * 结
            }
            世界表[i] = 结
            return 结
        }

        var 父表: [Int?] = Array(repeating: nil, count: 对象表.count)
        var 子表: [[Int]] = Array(repeating: [], count: 对象表.count)
        for i in 对象表.indices {
            if 对象表[i].父地址 != 0, let p = 地址索引[对象表[i].父地址], p != i {
                父表[i] = p
                子表[p].append(i)
            }
        }

        // 深度优先排序：父在子前，大纲里看起来才是树的顺序（.blend 里对象按名字字母排序存放）
        var 顺序: [Int] = []
        顺序.reserveCapacity(对象表.count)
        var 已访 = [Bool](repeating: false, count: 对象表.count)
        func 深搜(_ i: Int, _ 深: Int) {
            guard 深 < 128, !已访[i] else { return }
            已访[i] = true
            顺序.append(i)
            for c in 子表[i] { 深搜(c, 深 + 1) }
        }
        for i in 对象表.indices where 父表[i] == nil { 深搜(i, 0) }
        for i in 对象表.indices where !已访[i] { 深搜(i, 0) }

        var 新序号 = [Int](repeating: -1, count: 对象表.count)
        for (新, 旧) in 顺序.enumerated() { 新序号[旧] = 新 }

        var 网格: [导入网格] = []
        var 网格来源: [Int] = []
        var 节点: [导入节点] = []
        var 已用名: Set<String> = []
        var 非几何 = 0
        var 缺数据 = 0
        var 骨父级数 = 0
        var 共享数 = 0
        var 已用网格 = Set<UInt64>()

        for 旧 in 顺序 {
            let o = 对象表[旧]
            var 名 = o.名
            if 名.isEmpty { 名 = "\(类型说明(o.类型码))\(旧 + 1)" }
            if 已用名.contains(名) { 名 += ".\(旧 + 1)" }
            已用名.insert(名)

            var 节 = 导入节点(名称: 名, 类型: 类型说明(o.类型码))
            if let p = 父表[旧] {
                let 新父 = 新序号[p]
                if 新父 >= 0 { 节.父 = 新父 }
            }
            if o.骨父级 { 骨父级数 += 1 }

            // 骨架：顺带把骨骼层级读出来，角色窗口左侧才有骨骼树
            if o.类型码 == 25, o.数据地址 != 0 {
                let 骨架世界 = 世界(旧, 0)
                let 骨架 = 读骨骼(骨架数据地址: o.数据地址, 骨架世界: 骨架世界,
                                文件: 文件, 块表: 块表, S: S)
                节.骨骼 = 骨架.map(\.路径)
                // rest 矩阵一起抬到世界空间：蒙皮统一用 世界pose · 世界rest⁻¹，
                // 后面就不必再套一层骨架物体矩阵
                节.骨骼数据 = 骨架.map { 骨 in
                    var 骨 = 骨
                    骨.rest矩阵 = 骨架世界 * 骨.rest矩阵
                    return 骨
                }
                if let 对象块 = 块索引[o.旧地址]?.first {
                    节.姿态 = 读姿态(对象起: 对象块.数据起, 文件: 文件, S: S, 索引: 块索引)
                        .mapValues { 骨架世界 * $0 }
                }
            }

            if o.类型码 == 1, let 原 = 网格表[o.数据地址] {
                if 已用网格.contains(o.数据地址) { 共享数 += 1 }
                已用网格.insert(o.数据地址)

                var g = 原
                g.名称 = 名
                // 顶点组下标 → 骨骼名。5.x 的组名在网格阶段就补好了；这里只兜老文件，
                // 那些文件的组名还挂在 Object.defbase 上。
                if !g.权重.isEmpty, g.权重.allSatisfy({ $0.allSatisfy { $0.骨名.isEmpty } }) {
                    let 组名们 = 读顶点组名(首地址: o.组首地址, 文件: 文件, 地址: 地址表)
                    if !组名们.isEmpty {
                        for i in g.权重.indices {
                            for j in g.权重[i].indices where g.权重[i][j].组 < 组名们.count {
                                g.权重[i][j].骨名 = 组名们[g.权重[i][j].组]
                            }
                        }
                    }
                }
                // 对象变换左乘在网格自己的变换外层；调度层之后还会再左乘上轴校正 / 缩放，
                // 顺序天然正确，不需要在这里烘焙
                g.施加变换(世界(旧, 0))
                g.对齐属性()
                g.重建默认子集()
                节.网格 = [网格.count]
                网格.append(g)
                网格来源.append(旧)
                节点.append(节)
                continue
            }
            if o.类型码 == 1 { 缺数据 += 1 } else { 非几何 += 1 }
            节点.append(节)
        }

        var 报告: [String] = []
        if 网格.count > 1 {
            报告.append("识别到 \(对象表.count) 个对象，其中 \(网格.count) 个网格对象已按对象拆开")
        } else {
            报告.append("识别到 \(对象表.count) 个对象，其中 \(网格.count) 个网格对象")
        }
        if 非几何 > 0 {
            报告.append("跳过 \(非几何) 个无几何对象（空物体 / 相机 / 灯光 / 骨架等）")
        }
        if 缺数据 > 0 {
            报告.append("有 \(缺数据) 个网格对象找不到 Mesh 数据块，已跳过")
        }
        if 共享数 > 0 {
            报告.append("有 \(共享数) 个对象共享同一份 Mesh 数据（实例复制），已各自复制一份几何")
        }
        if 骨父级数 > 0 {
            报告.append("其中 \(骨父级数) 个对象的父级是骨骼，骨骼级偏移未解析，按对象级变换近似")
        }
        let 骨骼总数 = 节点.reduce(0) { $0 + $1.骨骼.count }
        if 骨骼总数 > 0 {
            let 有几何的骨 = 节点.reduce(0) { $0 + $1.骨骼数据.filter { $0.头 != .zero || $0.尾 != .zero }.count }
            报告.append("骨骼层级已解析：\(骨骼总数) 根骨，其中 \(有几何的骨) 根带 rest 头尾点（导入后双击大纲里的角色可查看骨架）")
        } else if 节点.contains(where: { $0.类型 == "骨架" }) {
            报告.append("骨架已识别，但骨骼块没读到（可能缺姿态/绑定数据），角色窗口先只显示部件分组")
        }

        let 姿态骨数 = 节点.reduce(0) { $0 + $1.姿态.count }
        if 姿态骨数 > 0 {
            报告.append("当前姿态矩阵已解析：\(姿态骨数) 根骨带 pose 矩阵，蒙皮变形按它摆骨")
        }

        // 蒙皮权重：组名已按网格上的 vertex_group_names 还原成骨名，这里只报统计
        let 带权重网格 = 网格.filter { !$0.权重.isEmpty }
        if !带权重网格.isEmpty {
            let 顶点总数 = 带权重网格.reduce(0) { $0 + $1.顶点.count }
            let 有权顶点 = 带权重网格.reduce(0) { $0 + $1.权重.filter { !$0.isEmpty }.count }
            var 骨名集: Set<String> = []
            for 网 in 带权重网格 {
                for 项 in 网.权重 { for w in 项 where !w.骨名.isEmpty { 骨名集.insert(w.骨名) } }
            }
            报告.append("蒙皮权重已解析：\(带权重网格.count) 个网格、\(有权顶点)/\(顶点总数) 顶点带权重，涉及 \(骨名集.count) 根骨")
            if 有权顶点 < 顶点总数 {
                报告.append("有 \(顶点总数 - 有权顶点) 个顶点没有权重，变形时会留在原位")
            }
        }
        return (网格, 节点, 报告, 网格来源)
    }

    // MARK: - 材质（MA 块）

    /// 所有 MA 块 → 导入材质。名字取 ID.name，颜色优先取 Principled BSDF 的 Base Color，
    /// 拿不到才退回 Material.r/g/b（那是视口显示色，常年是一片灰）。
    /// 返回的「下标」是 MA 旧地址 → 场景材质下标，供对象材质槽回指。
    private static func 读材质表(文件: 文件视图, 块表: [块], S: SDNA, 地址: [UInt64: 块],
                          基目录: URL?, 源文件: URL? = nil)
        -> (材质: [导入材质], 下标: [UInt64: Int], 贴图数: Int, 缺图数: Int, 外部图数: Int) {
        guard let 名路 = 路径偏移("Material", "id.name", S) else { return ([], [:], 0, 0, 0) }
        let 红路 = 字段偏移("Material", "r", S)
        let 绿路 = 字段偏移("Material", "g", S)
        let 蓝路 = 字段偏移("Material", "b", S)
        let 粗路 = 字段偏移("Material", "roughness", S)
        let 金路 = 字段偏移("Material", "metallic", S)
        let 树路 = 字段偏移("Material", "nodetree", S)

        var 材质: [导入材质] = []
        var 下标: [UInt64: Int] = [:]
        var 贴图数 = 0
        var 缺图数 = 0
        var 外部图数 = 0
        for 块 in 块表 where 块.码 == "MA" {
            // 5.x 里同一 old 地址可能被复用出多份块，只认第一份
            if 块.旧地址 != 0 {
                if 下标[块.旧地址] != nil { continue }
                下标[块.旧地址] = 材质.count
            }
            let 起 = 块.数据起
            guard 名路.偏移 + 2 <= 块.长 else { continue }

            var 名 = 文件.串(起 + 名路.偏移, 长: 258)
            // 5.x 的 ID.name 带类型前缀，实测有 "MA.Human" 与 "MA体积云" 两种写法
            if 名.hasPrefix("MA") {
                名 = String(名.dropFirst(2))
                if 名.hasPrefix(".") { 名 = String(名.dropFirst()) }
            }
            名 = 去重名后缀(名)

            var 产 = 导入材质()
            产.名称 = 名.isEmpty ? "材质\(材质.count + 1)" : 名
            if let 红路, let 绿路, let 蓝路, 红路.偏移 + 12 <= 块.长 {
                产.基础色 = sRGB转线性(SIMD3(文件.f32(起 + 红路.偏移),
                                             文件.f32(起 + 绿路.偏移),
                                             文件.f32(起 + 蓝路.偏移)))
            }
            if let 粗路, 粗路.偏移 + 4 <= 块.长 {
                产.粗糙度 = min(max(文件.f32(起 + 粗路.偏移), 0), 1)
            }
            if let 金路, 金路.偏移 + 4 <= 块.长 {
                产.金属度 = min(max(文件.f32(起 + 金路.偏移), 0), 1)
            }
            // 真颜色在着色节点树里：Principled 的 Base Color；贴图则看图像节点里打包的字节
            if let 树路, 树路.偏移 + 8 <= 块.长 {
                let 树首 = 文件.u64(起 + 树路.偏移)
                if 树首 != 0, let (树块, 树偏) = 解引用(树首, 地址, 块表) {
                    let 树起 = 树块.数据起 + 树偏
                    if let 基 = 读棱镜(树起: 树起, 文件: 文件, 地址: 地址,
                                      块表: 块表, S: S) {
                        产.基础色 = 基.色
                        if 基.金属度 >= 0 { 产.金属度 = min(max(基.金属度, 0), 1) }
                        if 基.粗糙度 >= 0 { 产.粗糙度 = min(max(基.粗糙度, 0), 1) }
                    }
                    // 导入什么图就是什么：既不烘焙，也不复刻对方的节点树。
                    // 只做一件事——Principled 的哪个输入口上接了图像，就把那张图原样
                    // 接到 OpenPBR 的同义入口；该口没接图就空着（数值走 Principled 的参数）。
                    // 剩下没落到任何口上的图像节点，一律摆进节点图但不连线，由用户自己接。
                    let 全部图 = 收集贴图(树起: 树起, 文件: 文件, 地址: 地址,
                                      块表: 块表, S: S, 基目录: 基目录)
                    if 全部图.isEmpty {
                        缺图数 += 1
                    } else {
                        let 图表 = Dictionary(全部图.map { ($0.名, $0) },
                                            uniquingKeysWith: { 甲, _ in 甲 })
                        var 已用 = Set<String>()
                        for (口名, 图名) in 读口图(树起: 树起, 文件: 文件, 地址: 地址,
                                               块表: 块表, S: S) {
                            guard let 口 = OpenPBR口(blender口: 口名),
                                  let 图 = 图表[图名], !已用.contains(图.名) else { continue }
                            已用.insert(图.名)
                            if 口 == "base_color" {
                                产.基础色贴图 = 图.字节
                                产.基础色贴图名 = 图.名
                            } else {
                                产.通道图.append(导入通道图(用途: 口, 名: 图.名, 字节: 图.字节))
                            }
                        }
                        for 图 in 全部图 where !已用.contains(图.名) {
                            产.游离图.append(导入通道图(用途: "", 名: 图.名, 字节: 图.字节))
                        }
                        // 统计口径：凡是进了节点图的图都算（接了口的 + 游离的）
                        贴图数 += 全部图.count
                        外部图数 += 全部图.filter(\.外部).count
                        let 接了口 = 产.通道图.isEmpty
                            ? "无"
                            : 产.通道图.map(\.用途).joined(separator: "、")
                        print("[blend导入] 材质「\(产.名称)」共 \(全部图.count) 张图，"
                              + "按口直连 \(产.通道图.count + (产.基础色贴图 != nil ? 1 : 0)) 张"
                              + "（\(接了口)\(产.基础色贴图 != nil ? "、base_color" : "")），"
                              + "游离 \(产.游离图.count) 张留给用户自己接")
                    }
                }
            }
            材质.append(产)
        }
        return (材质, 下标, 贴图数, 缺图数, 外部图数)
    }

    /// Material.nodetree → bNodeTree.nodes（链表）→ bNode.idname == "BSDF_PRINCIPLED"
    /// → bNode.inputs（链表）里按口名取 Base Color / Metallic / Roughness 的默认值。
    /// 取不到就返回 nil，由调用方退回视口色。
    private static func 读棱镜(树起: Int, 文件: 文件视图, 地址: [UInt64: 块],
                            块表: [块], S: SDNA, 深度: Int = 4)
        -> (色: SIMD3<Float>, 金属度: Float, 粗糙度: Float)? {
        guard let 首路 = 路径偏移("bNodeTree", "nodes.first", S),
              let 名路 = 字段偏移("bNode", "idname", S),
              let 输入路 = 路径偏移("bNode", "inputs.first", S),
              let 节下路 = 字段偏移("bNode", "next", S),
              let 口下路 = 字段偏移("bNodeSocket", "next", S),
              let 口名路 = 字段偏移("bNodeSocket", "name", S),
              let 值路 = 字段偏移("bNodeSocket", "default_value", S) else { return nil }

        var 节针 = 文件.u64(树起 + 首路.偏移)
        var 遍历数 = 0
        while 节针 != 0, 遍历数 < 4096 {
            遍历数 += 1
            guard let (节块, 节偏) = 解引用(节针, 地址, 块表) else { return nil }
            let 节起 = 节块.数据起 + 节偏
            guard 名路.偏移 + 64 <= 节块.长 - 节偏 else { return nil }
            let 类型 = 文件.串(节起 + 名路.偏移, 长: 64)
            节针 = 文件.u64(节起 + 节下路.偏移)
            // HG_* 这类材质把整条链包在 Group 里，得进组树继续找 Principled
            if 类型 == "ShaderNodeGroup" || 类型 == "GROUP", 深度 > 0,
               let 组路 = 字段偏移("bNode", "id", S) {
                let 组ID = 文件.u64(节起 + 组路.偏移)
                if 组ID != 0, let (组块, 组偏) = 解引用(组ID, 地址, 块表),
                   let 子 = 读棱镜(树起: 组块.数据起 + 组偏, 文件: 文件, 地址: 地址,
                                  块表: 块表, S: S, 深度: 深度 - 1) {
                    return 子
                }
            }
            // 4.x 存 "BSDF_PRINCIPLED"，5.x 存 "ShaderNodeBsdfPrincipled"
            guard 类型 == "BSDF_PRINCIPLED" || 类型 == "ShaderNodeBsdfPrincipled" else { continue }

            var 色 = SIMD3<Float>(-1, -1, -1)
            var 金: Float = -1
            var 粗: Float = -1
            var 口针 = 文件.u64(节起 + 输入路.偏移)
            var 口数 = 0
            while 口针 != 0, 口数 < 512 {
                口数 += 1
                guard let (口块, 口偏) = 解引用(口针, 地址, 块表) else { break }
                let 口起 = 口块.数据起 + 口偏
                guard 口名路.偏移 + 64 <= 口块.长 - 口偏 else { break }
                let 口名 = 文件.串(口起 + 口名路.偏移, 长: 64)
                口针 = 文件.u64(口起 + 口下路.偏移)
                let 值针 = 文件.u64(口起 + 值路.偏移)
                guard 值针 != 0, let (值块, 值偏) = 解引用(值针, 地址, 块表) else { continue }
                let 值起 = 值块.数据起 + 值偏
                guard 值偏 + 16 <= 值块.长 else { continue }
                switch 口名 {
                case "Base Color":
                    色 = SIMD3(文件.f32(值起), 文件.f32(值起 + 4), 文件.f32(值起 + 8))
                case "Metallic":
                    金 = 文件.f32(值起)
                case "Roughness":
                    粗 = 文件.f32(值起)
                default:
                    break
                }
            }
            guard 色.x >= 0 else { return nil }
            return (sRGB转线性(色), 金, 粗)
        }
        return nil
    }

    /// Principled 每个输入口 → 该口链路上最近的图像节点名。
    /// 口上没接图（只有常量）就不出现在结果里，上层据此把该口空着。
    /// 中间隔着混合/映射/节点组也能穿透，取的是链上真正喂进去的那张图。
    private static func 读口图(树起: Int, 文件: 文件视图, 地址: [UInt64: 块],
                            块表: [块], S: SDNA, 深度: Int = 4) -> [(口: String, 图: String)] {
        guard let 首路 = 路径偏移("bNodeTree", "nodes.first", S),
              let 名路 = 字段偏移("bNode", "idname", S),
              let 节下路 = 字段偏移("bNode", "next", S),
              let 输入路 = 字段偏移("bNode", "inputs.first", S),
              let 口下路 = 字段偏移("bNodeSocket", "next", S),
              let 口名路 = 字段偏移("bNodeSocket", "name", S),
              let 链路 = 字段偏移("bNodeSocket", "link", S) else { return [] }

        var 结果: [(口: String, 图: String)] = []
        var 节针 = 文件.u64(树起 + 首路.偏移)
        var 遍历 = 0
        while 节针 != 0, 遍历 < 4096 {
            遍历 += 1
            guard let (节块, 节偏) = 解引用(节针, 地址, 块表) else { break }
            let 节起 = 节块.数据起 + 节偏
            节针 = 文件.u64(节起 + 节下路.偏移)
            guard 名路.偏移 + 64 <= 节块.长 - 节偏 else { break }
            let 类型 = 文件.串(节起 + 名路.偏移, 长: 64)

            // HG_* 这类材质把整条链包在节点组里，得进组树继续找 Principled
            if 类型 == "ShaderNodeGroup" || 类型 == "GROUP", 深度 > 0,
               let 组路 = 字段偏移("bNode", "id", S) {
                let 组ID = 文件.u64(节起 + 组路.偏移)
                if 组ID != 0, let (组块, 组偏) = 解引用(组ID, 地址, 块表) {
                    结果 += 读口图(树起: 组块.数据起 + 组偏, 文件: 文件, 地址: 地址,
                                块表: 块表, S: S, 深度: 深度 - 1)
                }
                continue
            }
            guard 类型 == "BSDF_PRINCIPLED" || 类型 == "ShaderNodeBsdfPrincipled" else { continue }

            var 口针 = 文件.u64(节起 + 输入路.偏移)
            var 口数 = 0
            while 口针 != 0, 口数 < 512 {
                口数 += 1
                guard let (口块, 口偏) = 解引用(口针, 地址, 块表) else { break }
                let 口起 = 口块.数据起 + 口偏
                guard 口下路.偏移 + 8 <= 口块.长 - 口偏,
                      链路.偏移 + 8 <= 口块.长 - 口偏,
                      口名路.偏移 + 64 <= 口块.长 - 口偏 else { break }
                口针 = 文件.u64(口起 + 口下路.偏移)
                let 口名 = 文件.串(口起 + 口名路.偏移, 长: 64)
                guard !口名.isEmpty else { continue }
                // 这个口没接线 → 空着，交给 OpenPBR 那边的默认值
                let 链针 = 文件.u64(口起 + 链路.偏移)
                guard 链针 != 0,
                      let 图名 = 上溯图名(链针: 链针, 文件: 文件, 地址: 地址,
                                      块表: 块表, S: S, 深: 8) else { continue }
                结果.append((口名, 图名))
            }
        }
        return 结果
    }

    /// Blender Principled BSDF 的输入口名 → OpenPBR 参数键（PBRParamKey 的 rawValue）。
    /// 只映射语义对得上的口；法线/切线这类 OpenPBR 没有对应入口的口返回 nil，
    /// 那些图就落到「游离图」里，只建节点不连线，留给用户自己接。
    /// 口名跨版本有差异（4.x 叫 Specular/Clearcoat/Sheen，5.x 改成 Specular IOR Level/Coat Weight…），
    /// 新旧两套名字都认。
    private static func OpenPBR口(blender口 原名: String) -> String? {
        let 名 = 原名.trimmingCharacters(in: .whitespacesAndNewlines)
        let 表: [String: String] = [
            "Base Color": "base_color",
            "Metallic": "base_metallic",
            "Roughness": "base_roughness",
            "IOR": "base_ior",
            "Alpha": "base_alpha",
            "Emission Color": "emission_color",
            "Emission": "emission_color",
            "Emission Strength": "emission_luminance",
            "Specular IOR Level": "specular_ior_level",
            "Specular": "specular_ior_level",
            "Specular Tint": "specular_color",
            "Anisotropic": "specular_anisotropy",
            "Transmission Weight": "transmission_weight",
            "Transmission": "transmission_weight",
            "Subsurface Weight": "subsurface_weight",
            "Subsurface": "subsurface_weight",
            "Sheen Weight": "fuzz_weight",
            "Sheen": "fuzz_weight",
            "Sheen Roughness": "fuzz_roughness",
            "Coat Weight": "coat_weight",
            "Clearcoat": "coat_weight",
            "Coat Roughness": "coat_roughness",
            "Clearcoat Roughness": "coat_roughness",
            "Coat IOR": "coat_ior",
            "Coat Darkening": "coat_darkening",
            "Thin Film Thickness": "thin_film_thickness",
            "Thin Film IOR": "thin_film_ior"
        ]
        return 表[名]
    }


    /// 从一条 bNodeLink 往上游追溯，取最近一张图片节点的图像名（中间隔着混合/映射节点也能穿透）。
    private static func 上溯图名(链针: UInt64, 文件: 文件视图, 地址: [UInt64: 块],
                          块表: [块], S: SDNA, 深: Int) -> String? {
        guard 深 > 0,
              let 源路 = 字段偏移("bNodeLink", "from_node", S),
              let 名路 = 字段偏移("bNode", "idname", S),
              let 图路 = 字段偏移("bNode", "id", S),
              let 像名路 = 字段偏移("Image", "name", S),
              let 输入路 = 字段偏移("bNode", "inputs.first", S),
              let 口下路 = 字段偏移("bNodeSocket", "next", S),
              let 链路 = 字段偏移("bNodeSocket", "link", S) else { return nil }

        guard let (链块, 链偏) = 解引用(链针, 地址, 块表) else { return nil }
        let 链起 = 链块.数据起 + 链偏
        guard 源路.偏移 + 8 <= 链块.长 - 链偏 else { return nil }
        let 节针 = 文件.u64(链起 + 源路.偏移)
        guard 节针 != 0, let (节块, 节偏) = 解引用(节针, 地址, 块表) else { return nil }
        let 节起 = 节块.数据起 + 节偏
        guard 名路.偏移 + 64 <= 节块.长 - 节偏 else { return nil }
        let 类型 = 文件.串(节起 + 名路.偏移, 长: 64)

        if 类型 == "ShaderNodeTexImage", 图路.偏移 + 8 <= 节块.长 - 节偏 {
            let 像 = 文件.u64(节起 + 图路.偏移)
            guard 像 != 0, let (像块, 像偏) = 解引用(像, 地址, 块表),
                  像名路.偏移 + 4 <= 像块.长 - 像偏 else { return nil }
            let 短名 = (文件.串(像块.数据起 + 像偏 + 像名路.偏移, 长: 1024) as NSString).lastPathComponent
            return 短名.isEmpty ? nil : 短名
        }

        // 混合 / 正片叠底 / 映射 / 分离 XYZ 这类中间节点：每个输入口的上游都试一遍
        guard 输入路.偏移 + 8 <= 节块.长 - 节偏,
              口下路.偏移 + 8 <= 节块.长 - 节偏,
              链路.偏移 + 8 <= 节块.长 - 节偏 else { return nil }
        var 口针 = 文件.u64(节起 + 输入路.偏移)
        var 口数 = 0
        while 口针 != 0, 口数 < 256 {
            口数 += 1
            guard let (口块, 口偏) = 解引用(口针, 地址, 块表) else { break }
            let 口起 = 口块.数据起 + 口偏
            guard 口下路.偏移 + 8 <= 口块.长 - 口偏, 链路.偏移 + 8 <= 口块.长 - 口偏 else { break }
            口针 = 文件.u64(口起 + 口下路.偏移)
            let 子链 = 文件.u64(口起 + 链路.偏移)
            if 子链 != 0,
               let 名 = 上溯图名(链针: 子链, 文件: 文件, 地址: 地址, 块表: 块表, S: S, 深: 深 - 1) {
                return 名
            }
        }
        return nil
    }

    private static func 收集贴图(树起: Int, 文件: 文件视图, 地址: [UInt64: 块],
                              块表: [块], S: SDNA, 基目录: URL?, 深度: Int = 4)
        -> [(字节: Data, 名: String, 外部: Bool)] {
        guard let 首路 = 路径偏移("bNodeTree", "nodes.first", S),
              let 名路 = 字段偏移("bNode", "idname", S),
              let 下路 = 字段偏移("bNode", "next", S),
              let 图路 = 字段偏移("bNode", "id", S),
              let 像名路 = 字段偏移("Image", "name", S),
              let 包路 = 字段偏移("Image", "packedfile", S),
              let 长路 = 字段偏移("PackedFile", "size", S),
              let 数路 = 字段偏移("PackedFile", "data", S) else { return [] }

        var 候选: [(字节: Data, 名: String, 外部: Bool)] = []
        var 节针 = 文件.u64(树起 + 首路.偏移)
        var 遍历 = 0
        while 节针 != 0, 遍历 < 4096 {
            遍历 += 1
            guard let (节块, 节偏) = 解引用(节针, 地址, 块表) else { break }
            let 节起 = 节块.数据起 + 节偏
            节针 = 文件.u64(节起 + 下路.偏移)
            let 类型 = 文件.串(节起 + 名路.偏移, 长: 64)
            if 类型 != "ShaderNodeTexImage" {
                // 贴图也会藏在 Group 里，递归进去收
                if (类型 == "ShaderNodeGroup" || 类型 == "GROUP"), 深度 > 0,
                   let 组路 = 字段偏移("bNode", "id", S) {
                    let 组ID = 文件.u64(节起 + 组路.偏移)
                    if 组ID != 0, let (组块, 组偏) = 解引用(组ID, 地址, 块表) {
                        let 子 = 收集贴图(树起: 组块.数据起 + 组偏, 文件: 文件, 地址: 地址,
                                          块表: 块表, S: S, 基目录: 基目录, 深度: 深度 - 1)
                        候选.append(contentsOf: 子)
                    }
                }
                continue
            }

            let 像 = 文件.u64(节起 + 图路.偏移)
            guard 像 != 0, let (像块, 像偏) = 解引用(像, 地址, 块表) else { continue }
            let 像起 = 像块.数据起 + 像偏
            guard 像名路.偏移 + 4 <= 像块.长 - 像偏, 包路.偏移 + 8 <= 像块.长 - 像偏 else { continue }
            // Image 的 name 字段（1024 字节）存的是图像路径，不一定是纯文件名
            let 图路径 = 文件.串(像起 + 像名路.偏移, 长: 1024)
            let 短名 = (图路径 as NSString).lastPathComponent
            var 图字节: Data? = nil
            var 外部 = false

            let 包 = 文件.u64(像起 + 包路.偏移)
            if 包 != 0, let (包块, 包偏) = 解引用(包, 地址, 块表) {
                let 包起 = 包块.数据起 + 包偏
                let 长 = Int(文件.i32(包起 + 长路.偏移))
                let 数 = 文件.u64(包起 + 数路.偏移)
                if 长 > 64, 长 < (64 << 20), 数 != 0,
                   let (数块, 数偏) = 解引用(数, 地址, 块表),
                   数偏 + 长 <= 数块.长 {
                    let 首 = 数块.数据起 + 数偏
                    let 试 = Data(文件.原[首..<(首 + 长)])
                    if 是图片字节(试) { 图字节 = 试 }
                }
            }

            // 没打包就读外部文件：`//` 开头 = 相对 .blend 所在目录，
            // 其余按原样（绝对路径 / 相对当前目录）解读。
            if 图字节 == nil, !图路径.isEmpty {
                var 路 = 图路径
                if 路.hasPrefix("//"), let 基目录 {
                    路 = 基目录.appendingPathComponent(String(路.dropFirst(2)))
                        .standardizedFileURL.path
                } else if !路.hasPrefix("/"), let 基目录 {
                    路 = 基目录.appendingPathComponent(路).standardizedFileURL.path
                }
                if 路.hasPrefix("/"),
                   let 读 = try? Data(contentsOf: URL(fileURLWithPath: 路)),
                   是图片字节(读) {
                    图字节 = 读
                    外部 = true
                }
            }
            guard let 实 = 图字节 else { continue }
            候选.append((实, 短名, 外部))
        }
        var 见过 = Set<String>()
        return 候选.filter { 见过.insert($0.名 + "\($0.字节.count)").inserted }
    }

    private static func 是图片字节(_ d: Data) -> Bool {
        guard d.count > 64 else { return false }
        let 头 = [UInt8](d.prefix(4))
        if 头.count >= 4 {
            if 头[0] == 0x89, 头[1] == 0x50, 头[2] == 0x4E, 头[3] == 0x47 { return true } // PNG
            if 头[0] == 0xFF, 头[1] == 0xD8, 头[2] == 0xFF { return true }               // JPG
            if 头[0] == 0x52, 头[1] == 0x49, 头[2] == 0x46, 头[3] == 0x46 { return true } // RIFF/WEBP
            if 头[0] == 0x42, 头[1] == 0x4D { return true }                              // BMP
        }
        return false
    }

    /// 图像名 → OpenPBR 输入口用途。认不出来（法线/AO/高度这类 OpenPBR 没有通用口的）
    /// 就返回 nil，宁可不建节点，也不往图上塞看不懂的东西。
    private static func 通道用途(_ 名: String) -> String? {
        let n = 名.lowercased()
        if n.contains("normal") || n.contains("bump") || n.contains("height") { return nil }
        if n.contains("ao") || n.contains("occlu") || n.contains("curvature") { return nil }
        if n.contains("rough") { return "roughness" }
        if n.contains("metal") { return "metallic" }
        if n.contains("emis") || n.contains("glow") { return "emission" }
        if n.contains("alpha") || n.contains("opacity") || n.contains("mask") { return "alpha" }
        if n.contains("spec") { return "specular" }
        return nil
    }

    /// Blender 给重名材质自动加 ".001" 后缀，导入侧去掉更干净
    private static func 去重名后缀(_ 名: String) -> String {
        guard let 点 = 名.lastIndex(of: ".") else { return 名 }
        let 尾 = 名[名.index(after: 点)...]
        guard 尾.count == 3, 尾.allSatisfy({ $0.isNumber }) else { return 名 }
        return String(名[..<点])
    }

    /// 按 "id.name" 这样的路径取字段：嵌套结构逐层展开，累加偏移。
    private static func 路径偏移(_ 结构名: String, _ 路径: String, _ S: SDNA) -> 字段? {
        let 段 = 路径.split(separator: ".").map(String.init)
        guard !段.isEmpty else { return nil }
        var 当前 = 结构名
        var 累加 = 0
        for (i, 名) in 段.enumerated() {
            guard let f = 布局(当前, S).first(where: { $0.纯名 == 名 }) else { return nil }
            if i == 段.count - 1 {
                return 字段(纯名: f.纯名, 基类型: f.基类型, 指针层: f.指针层,
                           元素数: f.元素数, 偏移: 累加 + f.偏移, 大小: f.大小)
            }
            // 指针不能继续走字段
            guard f.指针层 == 0 else { return nil }
            累加 += f.偏移
            当前 = f.基类型
        }
        return nil
    }

    // MARK: - 骨骼

    /// 骨架数据（bArmature）→ 骨骼层级 + rest 头尾点。
    /// Blender 把骨架存成内存指针链：bArmature.bonebase(ListBase).first →
    /// Bone（同级靠 Bone.next 串起来），子骨在 Bone.childbase.first 里递归。
    /// 偏移全部按 SDNA 字段名现算，不写死常量，4.x / 5.x 都能吃。
    ///
    /// 头尾取 arm_head / arm_tail（armature 空间的 rest 位置），再左乘骨架物体的
    /// 世界矩阵 —— 网格顶点走的是同一条路，所以骨架和部件天然对齐。
    private static func 读骨骼(骨架数据地址: UInt64, 骨架世界: simd_float4x4, 文件: 文件视图,
                             块表: [块], S: SDNA) -> [导入骨骼] {
        guard 骨架数据地址 != 0,
              let 首路 = 路径偏移("bArmature", "bonebase.first", S),
              let 名路 = 路径偏移("Bone", "name", S),
              let 下路 = 路径偏移("Bone", "next", S),
              let 子路 = 路径偏移("Bone", "childbase.first", S) else { return [] }
        let 头路 = 路径偏移("Bone", "arm_head", S)
        let 尾路 = 路径偏移("Bone", "arm_tail", S)
        // rest 局部矩阵（armature 空间）。蒙皮变形 = pose_mat · rest⁻¹，缺它就只剩骨架线。
        // 5.x 把 Bone.matrix_local 改名成 arm_mat，两个名字都探一下。
        let 阵路 = 路径偏移("Bone", "matrix_local", S) ?? 路径偏移("Bone", "arm_mat", S)

        /// 读 armature 空间的一个点并换算到场景空间
        func 取点(_ 起: Int, _ 路: 字段?, _ 块长: Int) -> SIMD3<Float> {
            guard let 路, 路.偏移 + 12 <= 块长 else { return .zero }
            let 齐 = 骨架世界 * SIMD4<Float>(文件.f32(起 + 路.偏移),
                                         文件.f32(起 + 路.偏移 + 4),
                                         文件.f32(起 + 路.偏移 + 8), 1)
            guard 齐.w != 0 else { return .zero }
            let 点 = SIMD3<Float>(齐.x, 齐.y, 齐.z) / 齐.w
            return SIMD3<Float>(点.x.isFinite ? 点.x : 0,
                                点.y.isFinite ? 点.y : 0,
                                点.z.isFinite ? 点.z : 0)
        }

        // old 地址 → 候选块。同 old 会被内存复用写成多份（骨骼块在 5.x 里是通用
        // "DATA" 块，块码帮不上忙），所以留全部候选，读的时候用「name 处是可打印串」
        // 把真块筛出来。
        var 索引: [UInt64: [块]] = [:]
        for 块 in 块表 where 块.旧地址 != 0 { 索引[块.旧地址, default: []].append(块) }

        func 挑块(_ 地址: UInt64) -> 块? {
            guard let 候选 = 索引[地址] else { return nil }
            if 候选.count == 1 { return 候选[0] }
            for 块 in 候选 where 块.长 > 名路.偏移 + 1 {
                let 首 = 文件.原[块.数据起 + 名路.偏移]
                if 首 > 0x20, 首 < 0x7F { return 块 }
            }
            return 候选.first
        }

        var 结果: [导入骨骼] = []
        var 走过 = Set<UInt64>()

        func 走(_ 首: UInt64, 前: String, 层: Int, 父下标: Int?) {
            guard 层 < 32 else { return }
            var 地址 = 首
            while 地址 != 0, !走过.contains(地址),
                  let 块 = 挑块(地址), 块.长 > 名路.偏移 + 1 {
                走过.insert(地址)
                let 起 = 块.数据起
                let 可用 = 块.长 - 名路.偏移
                var 名 = 文件.串(起 + 名路.偏移, 长: min(64, 可用))
                if 名.isEmpty { 名 = "骨\(结果.count + 1)" }
                let 路径 = 前.isEmpty ? 名 : "\(前)/\(名)"
                let 本下标 = 结果.count
                结果.append(导入骨骼(名称: 名,
                                     路径: 路径,
                                     父: 父下标,
                                     头: 取点(起, 头路, 块.长),
                                     尾: 取点(起, 尾路, 块.长),
                                     rest矩阵: 阵路.flatMap {
                                         $0.偏移 + 64 <= 块.长 ? 四乘四(起 + $0.偏移, 文件) : nil
                                     } ?? matrix_identity_float4x4))
                if 子路.偏移 + 8 <= 块.长 {
                    走(文件.u64(起 + 子路.偏移), 前: 路径, 层: 层 + 1, 父下标: 本下标)
                }
                地址 = 下路.偏移 + 8 <= 块.长 ? 文件.u64(起 + 下路.偏移) : 0
            }
        }

        guard let 骨架块 = 挑块(骨架数据地址), 骨架块.长 > 首路.偏移 + 8 else { return [] }
        走(文件.u64(骨架块.数据起 + 首路.偏移), 前: "", 层: 0, 父下标: nil)
        return 结果
    }

    /// 读骨架对象的当前姿态：bPose.chanbase → bPoseChannel.pose_mat（4x4 骨局部矩阵）。
    /// 静态文件里它和 rest 基本重合，带姿态 / 动画的文件才不同；蒙皮变形要拿它当骨矩阵。
    private static func 读姿态(对象起: Int, 文件: 文件视图, S: SDNA,
                          索引: [UInt64: [块]]) -> [String: simd_float4x4] {
        guard let 姿态路 = 布局("Object", S).first(where: { $0.纯名 == "pose" }),
              姿态路.指针层 == 1 else { return [:] }
        let 姿态地址 = 文件.u64(对象起 + 姿态路.偏移)
        guard 姿态地址 != 0, let 姿态块 = 挑姿态块(姿态地址, 索引) else { return [:] }
        guard let 链路 = 布局("bPose", S).first(where: { $0.纯名 == "chanbase" }),
              链路.偏移 + 8 <= 姿态块.长,
              let 名路 = 布局("bPoseChannel", S).first(where: { $0.纯名 == "name" }),
              let 阵路 = 布局("bPoseChannel", S).first(where: { $0.纯名 == "pose_mat" })
        else { return [:] }

        var 结果: [String: simd_float4x4] = [:]
        var 地址 = 文件.u64(姿态块.数据起 + 链路.偏移)
        var 防环 = 0
        while 地址 != 0, 防环 < 4096, let 块 = 挑姿态块(地址, 索引),
              块.长 >= 阵路.偏移 + 64 {
            防环 += 1
            let 名 = 文件.串(块.数据起 + 名路.偏移, 长: min(64, 块.长 - 名路.偏移))
            if !名.isEmpty { 结果[名] = 四乘四(块.数据起 + 阵路.偏移, 文件) }
            let 下一个 = 文件.u64(块.数据起)
            地址 = (下一个 == 地址) ? 0 : 下一个
        }
        return 结果
    }

    /// 姿态块和骨骼块一样是通用 DATA 块、old 地址会被复用，多候选时挑最长的那份。
    private static func 挑姿态块(_ 地址: UInt64, _ 索引: [UInt64: [块]]) -> 块? {
        guard let 候选 = 索引[地址] else { return nil }
        if 候选.count == 1 { return 候选[0] }
        return 候选.max(by: { $0.长 < $1.长 })
    }

    /// 读列主序的 float[4][4]。
    private static func 四乘四(_ 偏移: Int, _ 文件: 文件视图) -> simd_float4x4 {
        func 列(_ i: Int) -> SIMD4<Float> {
            let 基 = 偏移 + i * 16
            return SIMD4<Float>(文件.f32(基), 文件.f32(基 + 4), 文件.f32(基 + 8), 文件.f32(基 + 12))
        }
        return simd_float4x4(列(0), 列(1), 列(2), 列(3))
    }

    /// 矩阵变换一个点（带齐次除法，透视/非仿射矩阵也安全）
    private static func 变换点(_ m: simd_float4x4, _ p: SIMD3<Float>) -> SIMD3<Float> {
        let q = m * SIMD4<Float>(p, 1)
        if abs(q.w) < 1e-9 || q.w == 1 { return SIMD3<Float>(q.x, q.y, q.z) }
        return SIMD3<Float>(q.x / q.w, q.y / q.w, q.z / q.w)
    }

    /// 按当前姿态把蒙皮网格的顶点摆到位（CPU 一次性烘焙，blend 是静态姿态没有动画播放）。
    /// 公式取自 Blender：v' = Σ w · (pose_mat · rest⁻¹) · v，权重和归一。
    /// 网格节点沿父链找最近的骨架节点，找不到就原样不动。
    private static func 蒙皮摆姿(节点: inout [导入节点], 网格: inout [导入网格]) -> String? {
        var 各骨架: [Int: [String: simd_float4x4]] = [:]
        for (i, 节) in 节点.enumerated() where !节.骨骼数据.isEmpty && !节.姿态.isEmpty {
            var 表: [String: simd_float4x4] = [:]
            for 骨 in 节.骨骼数据 {
                guard let 姿 = 节.姿态[骨.名称], 骨.rest矩阵.determinant != 0 else { continue }
                表[骨.名称] = 姿 * 骨.rest矩阵.inverse
            }
            if !表.isEmpty { 各骨架[i] = 表 }
        }
        guard !各骨架.isEmpty else { return nil }

        // 骨骼线也要跟着姿态走：头 = 变形矩阵 · rest 头；尾优先接子骨头（父子相连才连贯），
        // 没有子骨就用 变形矩阵 · rest 尾。数据一路透传到角色窗口，那边不用改。
        var 摆骨数 = 0
        for (骨节, 表) in 各骨架 {
            var 新头: [String: SIMD3<Float>] = [:]
            for 骨 in 节点[骨节].骨骼数据 {
                guard let m = 表[骨.名称] else { continue }
                新头[骨.名称] = 变换点(m, 骨.头)
            }
            var 子骨头: [Int: SIMD3<Float>] = [:]
            for (j, 骨) in 节点[骨节].骨骼数据.enumerated() {
                guard let 父 = 骨.父, 父 >= 0, 子骨头[父] == nil, let 点 = 新头[骨.名称] else { continue }
                子骨头[父] = 点
            }
            for j in 节点[骨节].骨骼数据.indices {
                let 骨 = 节点[骨节].骨骼数据[j]
                guard let m = 表[骨.名称], let 头 = 新头[骨.名称] else { continue }
                节点[骨节].骨骼数据[j].头 = 头
                节点[骨节].骨骼数据[j].尾 = 子骨头[j] ?? 变换点(m, 骨.尾)
                摆骨数 += 1
            }
        }

        var 已摆 = Set<Int>()
        var 网格数 = 0, 顶点数 = 0
        for (i, 节) in 节点.enumerated() {
            guard !节.网格.isEmpty else { continue }
            var 父 = 节.父 ?? -1
            var 变: [String: simd_float4x4]?
            while 父 >= 0, 父 < 节点.count {
                if let 表 = 各骨架[父] { 变 = 表; break }
                父 = 节点[父].父 ?? -1
            }
            guard let 变形 = 变 else { continue }
            for 下标 in 节.网格 where 下标 >= 0 && 下标 < 网格.count && !已摆.contains(下标) {
                已摆.insert(下标)
                guard 网格[下标].权重.count == 网格[下标].顶点.count, !网格[下标].权重.isEmpty else { continue }
                var 摆过 = false
                for vi in 网格[下标].顶点.indices {
                    var 总: Float = 0
                    var 累 = SIMD3<Float>.zero
                    for w in 网格[下标].权重[vi] {
                        guard let m = 变形[w.骨名] else { continue }
                        let q = m * SIMD4<Float>(网格[下标].顶点[vi], 1)
                        累 += SIMD3<Float>(q.x, q.y, q.z) * w.重量
                        总 += w.重量
                    }
                    if 总 > 1e-6 {
                        网格[下标].顶点[vi] = 累 / 总
                        摆过 = true
                    }
                }
                if 摆过 {
                    网格[下标].重算法线()
                    网格数 += 1
                    顶点数 += 网格[下标].顶点.count
                }
            }
        }
        var 说明: [String] = []
        if 网格数 > 0 { 说明.append("蒙皮已按姿态摆好：\(网格数) 个网格、\(顶点数) 个顶点完成变形。") }
        if 摆骨数 > 0 { 说明.append("骨骼线已按姿态摆位：\(摆骨数) 根。") }
        return 说明.isEmpty ? nil : 说明.joined(separator: " ")
    }

    // MARK: - 矩阵工具

    private static func 平移矩阵(_ v: SIMD3<Float>) -> simd_float4x4 {
        simd_float4x4(columns: (SIMD4<Float>(1, 0, 0, 0),
                                SIMD4<Float>(0, 1, 0, 0),
                                SIMD4<Float>(0, 0, 1, 0),
                                SIMD4<Float>(v.x, v.y, v.z, 1)))
    }

    private static func 缩放矩阵(_ v: SIMD3<Float>) -> simd_float4x4 {
        simd_float4x4(diagonal: SIMD4<Float>(v.x, v.y, v.z, 1))
    }

    /// Blender 的 rot 是 XYZ 欧拉角：R = Rz · Ry · Rx
    private static func 欧拉矩阵(_ r: SIMD3<Float>) -> simd_float4x4 {
        let cx = cos(r.x), sx = sin(r.x)
        let cy = cos(r.y), sy = sin(r.y)
        let cz = cos(r.z), sz = sin(r.z)
        let rx = simd_float4x4(columns: (SIMD4<Float>(1, 0, 0, 0),
                                         SIMD4<Float>(0, cx, sx, 0),
                                         SIMD4<Float>(0, -sx, cx, 0),
                                         SIMD4<Float>(0, 0, 0, 1)))
        let ry = simd_float4x4(columns: (SIMD4<Float>(cy, 0, -sy, 0),
                                         SIMD4<Float>(0, 1, 0, 0),
                                         SIMD4<Float>(sy, 0, cy, 0),
                                         SIMD4<Float>(0, 0, 0, 1)))
        let rz = simd_float4x4(columns: (SIMD4<Float>(cz, sz, 0, 0),
                                         SIMD4<Float>(-sz, cz, 0, 0),
                                         SIMD4<Float>(0, 0, 1, 0),
                                         SIMD4<Float>(0, 0, 0, 1)))
        return rz * ry * rx
    }

    // MARK: - 文件头

    private struct 头信息 {
        var 长度: Int
        var 大头: Bool
        var 版本: String
        /// 块头字节数：4.x 为 24，5.x 为 32
        var 块头: Int = 块头长
    }

    private static func 解头(_ 原: [UInt8]) -> 头信息 {
        let 前11 = String(decoding: 原.prefix(min(11, 原.count)), as: UTF8.self)
        guard 前11.hasPrefix("BLENDER") else {
            return 头信息(长度: 17, 大头: false, 版本: "未知", 块头: 块头长)
        }
        // 旧格式 12 字节：BLENDER + '-' + 字节序 + 3 位版本
        if 原.count > 8, 原[7] == UInt8(ascii: "-") {
            let 大 = 原[8] == UInt8(ascii: "V")
            let 版 = String(decoding: 原[9..<min(12, 原.count)], as: UTF8.self)
            return 头信息(长度: 12, 大头: 大, 版本: 版, 块头: 24)
        }
        // 新格式 17 字节：BLENDER + 10 字节（含指针宽度、字节序、4 位版本）
        var 大 = false
        if 原.count > 12 { 大 = 原[12] == UInt8(ascii: "V") }
        let 版 = 原.count >= 17 ? String(decoding: 原[13..<17], as: UTF8.self) : "未知"
        return 头信息(长度: 17, 大头: 大, 版本: 版, 块头: 块头长)
    }

    // MARK: - 字节视图

    private struct 文件视图 {
        let 原: [UInt8]
        let 大头: Bool

        func u16(_ o: Int) -> UInt16 {
            guard o >= 0, o + 2 <= 原.count else { return 0 }
            let a = UInt16(原[o]), b = UInt16(原[o + 1])
            return 大头 ? (a << 8 | b) : (b << 8 | a)
        }

        func u32(_ o: Int) -> UInt32 {
            guard o >= 0, o + 4 <= 原.count else { return 0 }
            var 值: UInt32 = 0
            if 大头 {
                for i in 0..<4 { 值 = 值 << 8 | UInt32(原[o + i]) }
            } else {
                for i in (0..<4).reversed() { 值 = 值 << 8 | UInt32(原[o + i]) }
            }
            return 值
        }

        func i32(_ o: Int) -> Int32 { Int32(bitPattern: u32(o)) }

        func u64(_ o: Int) -> UInt64 {
            guard o >= 0, o + 8 <= 原.count else { return 0 }
            var 值: UInt64 = 0
            if 大头 {
                for i in 0..<8 { 值 = 值 << 8 | UInt64(原[o + i]) }
            } else {
                for i in (0..<8).reversed() { 值 = 值 << 8 | UInt64(原[o + i]) }
            }
            return 值
        }

        func f32(_ o: Int) -> Float {
            Float(bitPattern: u32(o))
        }

        func 串(_ o: Int, 长: Int) -> String {
            guard 长 > 0, o >= 0, o < 原.count else { return "" }
            let 止 = min(o + 长, 原.count)
            var 端 = o
            while 端 < 止, 原[端] != 0 { 端 += 1 }
            return String(decoding: 原[o..<端], as: UTF8.self)
        }

        /// 从 offset 起找 NUL 结尾的字符串（DNA 里的名字表用）
        func 取串(_ o: inout Int) -> String {
            guard o >= 0, o < 原.count else { return "" }
            var 端 = o
            while 端 < 原.count, 原[端] != 0 { 端 += 1 }
            let 文 = String(decoding: 原[o..<端], as: UTF8.self)
            o = 端 + 1
            return 文
        }
    }

    // MARK: - 块

    private struct 块 {
        var 码: String
        var 结构索引: Int
        var 旧地址: UInt64
        var 长: Int
        var 数据起: Int
    }

    private static func 遍历块(文件: 文件视图, 起: Int, 块头: Int = 块头长) throws -> [块] {
        var 结果: [块] = []
        var 位 = 起
        let 总 = 文件.原.count
        // 4.x（12 字节头）块头 24 字节，长度在 +4；5.x（17 字节头）块头 32 字节，长度在 +16、结构索引在 +24
        let 长偏移 = 块头 == 24 ? 4 : 16
        let 索引偏移 = 块头 == 24 ? 4 : 24

        while 位 + 块头 <= 总 {
            let 码 = 文件.串(位, 长: 4).trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
            if 码 == "ENDB" { break }
            // 4 字节码后半段常补 \0（"ME\0\0" / "WM\0\0"），去零后可能不足 4 字符，不能因此断链
            guard !码.isEmpty else { break }
            // 块码允许字母、数字与空格（如 DNA1、REND、DATA），否则 DNA1 会被误判为非法而中断块链
            let 合法 = 码.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == " ") }
            guard 合法 else { break }

            let 结构索引 = Int(文件.u32(位 + 索引偏移))
            let 旧地址 = 文件.u64(位 + 8)
            let 长 = Int(文件.u32(位 + 长偏移))
            guard 长 >= 0, 位 + 块头 + 长 <= 总 else { break }

            结果.append(块(码: 码, 结构索引: 结构索引, 旧地址: 旧地址,
                          长: 长, 数据起: 位 + 块头))
            位 += 块头 + 长
        }

        guard !结果.isEmpty else {
            throw 导入导出错误.解析失败(格式: "BLEND", 原因: "块链为空")
        }
        return 结果
    }

    // MARK: - SDNA

    private struct 结构定义 {
        var 名: String
        var 字段: [(型: String, 名: String)]
    }

    private struct SDNA {
        var 名表: [String] = []
        var 型表: [String] = []
        var 型长: [Int] = []
        var 结构: [结构定义] = []
        var 名到结构: [String: Int] = [:]
        var 型到索引: [String: Int] = [:]
        /// 该 DNA 的指纹：布局缓存必须按它分组，否则批量导入 5.0 与 5.1 两种
        /// 版本的文件时，后一个文件会用前一个版本的字段偏移，解出来全是错位
        var 指纹: Int = 0

        func 结构大小(_ 名: String) -> Int {
            guard let i = 型到索引[名], i < 型长.count else { return 0 }
            return 型长[i]
        }
    }

    /// 把 DNA1 块里的 `NAME` / `TYPE` / `TLEN` / `STRC` 四段解出来。
    /// 这个布局是 Blender 文件格式里最稳定的一部分，20 年没变过。
    private static func 解析SDNA(文件: 文件视图, 块: 块) throws -> SDNA {
        var S = SDNA()
        var p = 块.数据起
        let 止 = 块.数据起 + 块.长

        // 段标记：Blender 各版本对段间是否做 4 字节对齐并不统一（5.x 实测不对齐），
        // 所以先原位匹配，失败再按 4 字节对齐匹配，两种布局都能吃下。
        func 标量(_ 期待: String) -> Bool {
            // 段标记前可能补 0~3 个 \0，也可能会先 4 字节对齐，逐字节试探最稳
            for 偏移 in 0..<4 {
                let 候选 = p + 偏移
                guard 候选 + 4 <= 止 else { break }
                let 码 = 文件.串(候选, 长: 4).trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
                if 码 == 期待 {
                    p = 候选 + 4
                    return true
                }
            }
            return false
        }

        func 对齐4() { p = (p + 3) & ~3 }

        guard 标量("SDNA"), 标量("NAME") else {
            throw 导入导出错误.解析失败(格式: "BLEND", 原因: "DNA1 缺少 SDNA/NAME 标记")
        }

        let 名数 = 文件.i32(p); p += 4
        guard 名数 > 0, 名数 < 1_000_000 else {
            throw 导入导出错误.解析失败(格式: "BLEND", 原因: "SDNA 名字表异常")
        }
        S.名表.reserveCapacity(Int(名数))
        for _ in 0..<Int(名数) { S.名表.append(文件.取串(&p)) }

        guard 标量("TYPE") else {
            throw 导入导出错误.解析失败(格式: "BLEND", 原因: "DNA1 缺少 TYPE 段")
        }
        let 型数 = 文件.i32(p); p += 4
        guard 型数 > 0, 型数 < 1_000_000 else {
            throw 导入导出错误.解析失败(格式: "BLEND", 原因: "SDNA 类型表异常")
        }
        S.型表.reserveCapacity(Int(型数))
        for _ in 0..<Int(型数) { S.型表.append(文件.取串(&p)) }

        guard 标量("TLEN") else {
            throw 导入导出错误.解析失败(格式: "BLEND", 原因: "DNA1 缺少 TLEN 段")
        }
        S.型长.reserveCapacity(Int(型数))
        for _ in 0..<Int(型数) {
            S.型长.append(Int(文件.u16(p)))
            p += 2
        }

        guard 标量("STRC") else {
            throw 导入导出错误.解析失败(格式: "BLEND", 原因: "DNA1 缺少 STRC 段")
        }
        let 构数 = 文件.i32(p); p += 4
        guard 构数 > 0, 构数 < 200_000 else {
            throw 导入导出错误.解析失败(格式: "BLEND", 原因: "SDNA 结构表异常")
        }

        S.结构.reserveCapacity(Int(构数))
        for _ in 0..<Int(构数) {
            guard p + 4 <= 止 else { break }
            let 型索引 = Int(文件.u16(p))
            let 字段数 = Int(文件.u16(p + 2))
            p += 4
            var 字段: [(型: String, 名: String)] = []
            字段.reserveCapacity(字段数)
            for _ in 0..<字段数 {
                guard p + 4 <= 止 else { break }
                let t = Int(文件.u16(p))
                let n = Int(文件.u16(p + 2))
                p += 4
                let 型名 = t < S.型表.count ? S.型表[t] : ""
                let 字段名 = n < S.名表.count ? S.名表[n] : ""
                字段.append((型名, 字段名))
            }
            let 名 = 型索引 < S.型表.count ? S.型表[型索引] : ""
            S.结构.append(结构定义(名: 名, 字段: 字段))
        }

        for (i, s) in S.结构.enumerated() where S.名到结构[s.名] == nil {
            S.名到结构[s.名] = i
        }
        for (i, t) in S.型表.enumerated() where S.型到索引[t] == nil {
            S.型到索引[t] = i
        }
        S.指纹 = S.型长.hashValue &* 31 &+ S.结构.count
        return S
    }

    // MARK: - 结构布局

    /// 字段描述：解析「类型 + 字段名」。
    /// 注意 Blender 的 SDNA 把指针星号记在**字段名**上（`*next` / `**mat`），
    /// 数组维度也记在字段名上（`co[3]`），类型里反而没有这些记号。
    private struct 字段 {
        var 纯名: String
        var 基类型: String
        var 指针层: Int
        var 元素数: Int
        var 偏移: Int
        var 大小: Int
    }

    private static func 解析字段名(_ 字段名: String) -> (纯名: String, 指针层: Int, 元素数: Int) {
        var 纯 = 字段名
        let 针 = 纯.filter { $0 == "*" }.count
        纯.removeAll { $0 == "*" }

        var 元素 = 1
        while let 左 = 纯.firstIndex(of: "["), let 右 = 纯[左...].firstIndex(of: "]") {
            let 数文 = 纯[纯.index(after: 左)..<右]
            if let 数 = Int(数文), 数 > 0 { 元素 *= 数 }
            // 柔性数组 `data[0]` 不占空间
            纯.removeSubrange(左...右)
        }
        return (纯, 针, 元素)
    }

    private static func 类型对齐(_ 名: String, 指针层: Int, _ S: SDNA) -> Int {
        if 指针层 > 0 { return 指针长 }
        let 大 = S.结构大小(名)
        if 大 <= 0 { return 1 }
        return min(大, 8)
    }

    private nonisolated(unsafe) static var 布局缓存: [String: [字段]] = [:]

    /// 按 C 的自然对齐算出结构里每个字段的偏移。
    /// 结构整体大小直接用 SDNA 的 TLEN，不递归推导 —— 少一层风险。
    private static func 布局(_ 结构名: String, _ S: SDNA) -> [字段] {
        let 键 = "\(S.指纹)|\(结构名)"
        if let 缓 = 布局缓存[键] { return 缓 }
        guard let i = S.名到结构[结构名] else { return [] }

        var 结果: [字段] = []
        var 偏移 = 0
        for (型, 名) in S.结构[i].字段 {
            let (纯名, 针, 元素) = 解析字段名(名)
            let 基 = 型.replacingOccurrences(of: "*", with: "").trimmingCharacters(in: .whitespaces)
            let 对 = 类型对齐(基, 指针层: 针, S)
            let 单 = 针 > 0 ? 指针长 : S.结构大小(基)
            guard 单 > 0 else { continue }
            偏移 = (偏移 + 对 - 1) / 对 * 对
            let 总 = 单 * 元素
            结果.append(字段(纯名: 纯名, 基类型: 基, 指针层: 针, 元素数: 元素, 偏移: 偏移, 大小: 总))
            偏移 += 总
        }
        布局缓存[键] = 结果
        return 结果
    }

    private static func 字段偏移(_ 结构名: String, _ 字段名: String, _ S: SDNA) -> 字段? {
        布局(结构名, S).first { $0.纯名 == 字段名 }
    }

    /// old 内存地址 → (块, 块内偏移)。
    /// Blender 的指针既可能正好等于某个块的 old 地址，也可能指进某个块的内部（大块共享缓冲），
    /// 所以先精确命中，再退化为「落在哪一块的地址区间里」。
    /// 关键：同一个 old 地址在文件里往往被复用多次（内存释放后重新分配，上一阶段是别的数组），
    /// 所以给了「靠近」锚点时必须挑离锚点最近的那一份，否则会读到上一个网格甚至更早的旧副本。
    private static func 解引用(_ 值: UInt64, _ 地址: [UInt64: 块], _ 块表: [块],
                          靠近: Int? = nil) -> (块, Int)? {
        guard 值 != 0 else { return nil }
        if let 靠 = 靠近 {
            var 之后: (Int, 块)? = nil
            var 之前: (Int, 块)? = nil
            for (i, b) in 块表.enumerated() where b.旧地址 == 值 {
                if i >= 靠 {
                    if 之后 == nil || i < 之后!.0 { 之后 = (i, b) }
                } else if 之前 == nil || i > 之前!.0 {
                    之前 = (i, b)
                }
            }
            if let r = 之后 { return (r.1, 0) }
            if let r = 之前 { return (r.1, 0) }
        } else if let b = 地址[值] {
            return (b, 0)
        }
        var 最佳: (块, Int)? = nil
        for b in 块表 where 值 >= b.旧地址 && 值 < b.旧地址 &+ UInt64(b.长) {
            let 内 = Int(值 - b.旧地址)
            if 最佳 == nil || 内 < 最佳!.1 { 最佳 = (b, 内) }
        }
        return 最佳
    }

    /// 读 Mesh 的 AttributeStorage。
    /// 这是 Blender 5.x 几何数据的**正规入口**：position / .corner_vert / material_index 等全部是
    /// Attribute，每个 Attribute 自带 data 指针，指哪读哪。
    /// 返回值多带一个「锚」= 这份属性数组所在块在块表里的下标，供后续所有指针解引用做就近选择。
    private static func 读属性表(文件: 文件视图, 起: Int, S: SDNA,
                          地址: [UInt64: 块], 块表: [块],
                          区间起: Int, 区间止: Int) -> [(名: String, 域: Int, 值: UInt64, 锚: Int)] {
        guard let st = 字段偏移("Mesh", "attribute_storage", S),
              let 首段 = 字段偏移("AttributeStorage", "dna_attributes", S),
              let 数段 = 字段偏移("AttributeStorage", "dna_attributes_num", S),
              let 名段 = 字段偏移("Attribute", "name", S),
              let 域段 = 字段偏移("Attribute", "domain", S),
              let 数据段 = 字段偏移("Attribute", "data", S) else { return [] }

        let 数 = Int(文件.i32(起 + st.偏移 + 数段.偏移))
        let 首 = 文件.u64(起 + st.偏移 + 首段.偏移)
        guard 数 > 0, 数 < 16384, 首 != 0 else { return [] }

        // Attribute 在块内是紧凑排布，步长按最后一个字段的结束位置向上取 8 字节对齐。
        let 尾 = max(名段.偏移 + 指针长, 数据段.偏移 + 指针长)
        let 步 = (尾 + 7) / 8 * 8
        guard 步 > 0 else { return [] }

        func 读名(_ 针: UInt64, _ 锚: Int) -> String? {
            guard let (名块, 名偏) = 解引用(针, 地址, 块表, 靠近: 锚), 名偏 >= 0 else { return nil }
            var 字节: [UInt8] = []
            var q = 名块.数据起 + 名偏
            let 止 = min(名块.数据起 + 名块.长, q + 128)
            while q < 止 {
                let c = UInt8(文件.u32(q) & 0xFF)
                if c == 0 { break }
                if c < 32 || c > 126 { return nil }
                字节.append(c)
                q += 1
            }
            guard !字节.isEmpty else { return nil }
            return String(decoding: 字节, as: UTF8.self)
        }

        func 解析(_ 块: 块, _ 内偏: Int, _ 锚: Int) -> [(名: String, 域: Int, 值: UInt64, 锚: Int)]? {
            var 结果: [(名: String, 域: Int, 值: UInt64, 锚: Int)] = []
            结果.reserveCapacity(数)
            for i in 0..<数 {
                let p = 块.数据起 + 内偏 + i * 步
                guard p + 步 <= 块.数据起 + 块.长 else { return nil }
                let 名针 = 文件.u64(p + 名段.偏移)
                let 域 = Int(Int8(truncatingIfNeeded: UInt8(文件.u32(p + 域段.偏移) & 0xFF)))
                let 数据针 = 文件.u64(p + 数据段.偏移)
                guard let 名 = 读名(名针, 锚) else { return nil }
                结果.append((名, 域, 数据针, 锚))
            }
            return 结果
        }

        // 候选一：按 dna_attributes 指针就近解引用（锚在本网格区间起点之后，可避开更早的旧副本）
        if let (块, 内偏) = 解引用(首, 地址, 块表, 靠近: 区间起) {
            let 锚 = 块表.firstIndex { $0.数据起 == 块.数据起 } ?? 区间起
            if let r = 解析(块, 内偏, 锚) { return r }
        }
        // 候选二：本网格区间内长度正好等于 属性数×步长 的 DATA 块
        let 止 = min(区间止, 块表.count)
        if 区间起 < 止 {
            for i in 区间起..<止 where 块表[i].长 == 数 * 步 {
                if let r = 解析(块表[i], 0, i) { return r }
            }
        }
        return []
    }

    // MARK: - 读网格

    /// Blender 5.x 的几何数据不再挂在 `mvert` / `mpoly` / `mloop` 这些老指针上，
    /// 而是被拆成一个个独立的 DATA 块：顶点坐标 = 顶点数×12、角点索引 = 环数×4、
    /// 面偏移表 = (面数+1)×4、UV = 环数×8、法线 = 环数×12。
    /// 所以这里按「本 Mesh 之后、下一个 Mesh 之前」的块区间，用**字节长度精确匹配**取块，
    /// 不去猜指针、也不做任何轴向转换（轴向由上层「上轴校正」统一处理）。
    private static func 读网格(文件: 文件视图, 块: 块, 结构 S: SDNA,
                           地址: [UInt64: 块], 块表: [块],
                           区间起: Int, 区间止: Int) throws -> 导入网格 {
        let 起 = 块.数据起

        func 整(_ 名: String) -> Int {
            guard let f = 字段偏移("Mesh", 名, S) else { return 0 }
            return Int(文件.i32(起 + f.偏移))
        }

        let 总顶点 = 整("totvert")
        let 总面 = 整("totpoly")
        let 总环 = 整("totloop")
        guard 总顶点 > 0, 总面 > 0 else {
            throw 导入导出错误.无有效几何(URL(fileURLWithPath: "/"))
        }

        // ---- 几何：全部按原始数据读，不做任何三角/形态假设 ----
        let 属性 = 读属性表(文件: 文件, 起: 起, S: S, 地址: 地址, 块表: 块表,
                        区间起: 区间起, 区间止: 区间止)

        func 属性指针(_ 名: String) -> (块, Int)? {
            for a in 属性 where a.名 == 名 {
                if let r = 解引用(a.值, 地址, 块表, 靠近: a.锚) { return r }
            }
            return nil
        }

        func 读点3(_ 位置: (块, Int), _ 个数: Int) -> [SIMD3<Float>] {
            let (b, o) = 位置
            guard o >= 0, b.数据起 + o + 个数 * 12 <= b.数据起 + b.长 else { return [] }
            var r: [SIMD3<Float>] = []
            r.reserveCapacity(个数)
            for i in 0..<个数 {
                let q = b.数据起 + o + i * 12
                r.append(SIMD3<Float>(文件.f32(q), 文件.f32(q + 4), 文件.f32(q + 8)))
            }
            return r
        }

        // 面起始偏移：Mesh.poly_offset_indices 是真正的数组指针，实测必中。
        // 它总是紧贴在 Mesh 块之前落盘，因此可以顺带当锚点，圈定「属于本网格的数据块组」。
        var 偏源: (块, Int)? = nil
        if let f = 字段偏移("Mesh", "poly_offset_indices", S) {
            偏源 = 解引用(文件.u64(起 + f.偏移), 地址, 块表)
        }
        if 偏源 == nil, 总面 > 0,
           let b = 取块(块表, 从: 区间起, 到: 区间止, 长: (总面 + 1) * 4, 靠近: 区间起, 校验: { _ in true }) {
            偏源 = (b, 0)
        }

        var 组止 = min(区间止, 块表.count)
        if let p = 偏源, let k = 块表.firstIndex(where: { $0.旧地址 == p.0.旧地址 }) {
            组止 = k + 1
        }
        let 组起 = max(0, 组止 - 96)

        // 组内按字节长度取块：优先取第一个通过内容校验的，都不通过时退回第一个，绝不丢数据。
        func 组内取块(_ 长: Int, _ 校验: (块) -> Bool) -> 块? {
            guard 组起 < 组止 else { return nil }
            var 头: 块? = nil
            for i in 组起..<组止 {
                let b = 块表[i]
                guard b.长 == 长 else { continue }
                if 校验(b) { return b }
                if 头 == nil { 头 = b }
            }
            return 头
        }

        var 顶点: [SIMD3<Float>] = []
        if let 位 = 属性指针("position"), 位.0.长 >= 总顶点 * 12 {
            顶点 = 读点3(位, 总顶点)
        }
        if 顶点.isEmpty {
            顶点 = 读顶点自MVert(文件: 文件, 起: 起, 总顶点数: 总顶点, S: S, 地址: 地址)
        }
        if 顶点.isEmpty, 总顶点 > 0,
           let b = 组内取块(总顶点 * 12, { 坐标有限(文件: 文件, 块: $0, 个数: 总顶点) }) {
            顶点 = 读浮点3(文件: 文件, 块: b, 个数: 总顶点)
        }
        if 顶点.isEmpty, 总顶点 > 0,
           let b = 组内取块(总顶点 * 6, { 半坐标有限(文件: 文件, 块: $0, 个数: 总顶点) }) {
            顶点 = 读半3(文件: 文件, 块: b, 个数: 总顶点)
        }
        guard !顶点.isEmpty else {
            throw 导入导出错误.无有效几何(URL(fileURLWithPath: "/"))
        }

        // ---- 面：poly_offset_indices（totpoly+1 个 int）+ 角点顶点索引（totloop 个 int）----
        var 面环表: [[UInt32]] = []

        // 角点表：Blender 把 int[totloop] 的数组都写成同样长度的 DATA 块
        // （.corner_vert / .corner_edge / uv 选择层……），单靠长度分不出来。
        // 所以逐个候选做两项内容判据，选出真正的角点表：
        //   ① 每个角点值都落在 [0, totvert) 内；
        //   ② 同一个面环里不会重复出现同一个顶点（这是 Blender 面拓扑的固有性质）。
        // 只用来挑数组，不修改任何几何数据。
        var 角源: (块, Int)? = nil
        if 总环 > 0, 组起 < 组止 {
            var 角 = [Int32](repeating: 0, count: 总环)
            var 小 = [Int32]()
            小.reserveCapacity(64)

            func 是角点表(_ b: 块) -> Bool {
                guard b.长 >= 总环 * 4 else { return false }
                for k in 0..<总环 {
                    let v = 文件.i32(b.数据起 + k * 4)
                    if v < 0 || v >= Int32(总顶点) { return false }
                    角[k] = v
                }
                guard let o = 偏源 else { return true }
                for f in 0..<总面 {
                    let 始 = Int(文件.i32(o.0.数据起 + o.1 + f * 4))
                    let 终 = Int(文件.i32(o.0.数据起 + o.1 + (f + 1) * 4))
                    guard 始 >= 0, 终 >= 始, 终 <= 总环 else { continue }
                    if 终 - 始 < 2 { continue }
                    小.removeAll(keepingCapacity: true)
                    for k in 始..<终 {
                        let v = 角[k]
                        if 小.contains(v) { return false }
                        小.append(v)
                    }
                }
                return true
            }

            for i in 组起..<组止 where 块表[i].长 == 总环 * 4 {
                if 是角点表(块表[i]) { 角源 = (块表[i], 0); break }
            }
        }

        if let o = 偏源, let c = 角源 {
            面环表 = 由指针读面(文件: 文件, 偏移: o, 角: c, 总面: 总面, 总环: 总环)
        }
        if 面环表.isEmpty {
            let 兜底 = 读面环自多边(文件: 文件, 起: 起, 总面: 总面, 总环: 总环,
                              S: S, 地址: 地址, 顶点上限: 顶点.count)
            面环表 = 兜底
        }
        guard !面环表.isEmpty else {
            throw 导入导出错误.无有效几何(URL(fileURLWithPath: "/"))
        }

        // ---- UV / 法线（角点域，按顶点去重铺开）----
        // UV 的正规入口是 attribute_storage 里的 float2 属性（默认名 UVMap，用户可以改名）。
        // 以前只按「块长 = 环数×8」在区间里猜一块，可角点域里同长的 float2 数组不止一个
        // （自定义属性、UV 选择层……），猜错就等于把坐标喂成垃圾，贴图在模型上糊成花斑。
        var UV: [SIMD2<Float>] = []
        var 角UV全: [SIMD2<Float>] = []
        if 总环 > 0 {
            let 候选UV层 = 属性.filter { $0.名.lowercased().contains("uv") }
            for a in 候选UV层 {
                guard let (b, o) = 解引用(a.值, 地址, 块表, 靠近: a.锚), o >= 0,
                     b.数据起 + o + 总环 * 8 <= b.数据起 + b.长 else { continue }
                var 角UV: [SIMD2<Float>] = []
                角UV.reserveCapacity(总环)
                var 有效 = true
                var 有非零 = false
                for i in 0..<总环 {
                    let q = b.数据起 + o + i * 8
                    let u = 文件.f32(q)
                    let v = 文件.f32(q + 4)
                    guard u.isFinite, v.isFinite, abs(u) < 1e6, abs(v) < 1e6 else { 有效 = false; break }
                    if u != 0 || v != 0 { 有非零 = true }
                    角UV.append(SIMD2<Float>(u, v))
                }
                guard 有效, 有非零, 角UV.count == 总环 else { continue }
                角UV全 = 角UV
                break
            }
            if 角UV全.isEmpty,
               let b = 取块(块表, 从: 区间起, 到: 区间止, 长: 总环 * 8, 靠近: 区间起,
                          校验: { 浮点2自洽(文件: 文件, 块: $0, 个数: min(总环, 512)) }) {
                角UV全 = 读浮点2(文件: 文件, 块: b, 个数: 总环)
            }
        }

        var 法线: [SIMD3<Float>] = []
        var 角法线全: [SIMD3<Float>] = []
        if 总环 > 0, 总环 != 总顶点,
           let b = 取块(块表, 从: 区间起, 到: 区间止, 长: 总环 * 12, 靠近: 区间起,
                      校验: { 坐标有限(文件: 文件, 块: $0, 个数: min(总环, 200)) }) {
            // 取块的校验只抽样前 200 条：复杂场景环数上万，尾部完全可能是同长块的别的东西
            //（面索引、锐边标记、自定义属性……）。所以读出来之后必须逐条体检再决定认不认这块，
            // 否则脏法线会一路传到接缝量化，甚至让导入崩在 Float→Int32 的转换上。
            角法线全 = 滤法线(读浮点3(文件: 文件, 块: b, 个数: 总环))
        }

        // ---- 接缝展开 ----
        // Blender 的 UV / 法线是「角点（loop）域」，同一个 3D 顶点在 UV 接缝两侧各有一份 UV，
        // 这正是接缝的意思。App 网格只有 per-vertex 的 UV，以前按顶点去重取第一个角的值，
        // 接缝两边就被迫共用一条 UV 线 —— 贴图在缝上被拉成锯齿黑缝（Blender 里看不到，
        // 因为它采样用的是 loop UV）。所以这里按 (顶点, UV, 法线) 组合重新编号顶点，
        // 接缝处复制顶点、面索引跟着改，权重也按映射复制。
        let 原顶点数 = 顶点.count
        var 展开来源: [UInt32] = []
        if !角UV全.isEmpty || !角法线全.isEmpty {
            let r = 展开接缝(顶点: 顶点, 法线: 法线, 角UV: 角UV全,
                         角法线: 角法线全, 面环: 面环表)
            顶点 = r.顶点
            法线 = r.法线
            UV = r.UV
            面环表 = r.面环
            展开来源 = r.来源
            if r.顶点.count > 原顶点数 {
                print("[blend导入] 接缝展开：顶点 \(原顶点数) → \(r.顶点.count)")
            }
        }

        // ---- 面材质 ----
        // 正规路径：Mesh.attribute_storage 里的 material_index 属性（面域或角点域）。
        // 以前靠「块长恰好 = 总面×4」猜块，而 Blender 5.x 把面材质存成 Attribute，
        // 猜到的往往是别的同长数组（内容全 0），多材质网格于是退化成单材质球。
        var 材质表 = 读面材质属性(文件: 文件, 起: 起, S: S, 地址: 地址, 块表: 块表,
                           总面: 总面, 总环: 总环, 面环: 面环表,
                           区间起: 区间起, 区间止: 区间止)
        if 材质表.isEmpty,
           let b = 取块(块表, 从: 区间起, 到: 区间止, 长: 总面 * 4, 靠近: 区间起,
                      校验: { 块 in
                          // 兜底也不能瞎认：必须整段值域合法且**确实存在不同值**，
                          // 否则会把别的同长数组（常见是全 0）当成面材质，多材质又退化成单材质。
                          let 可 = min(总面, 块.长 / 4)
                          guard 可 > 0 else { return false }
                          var 首值: Int32? = nil
                          for i in 0..<可 {
                              let v = 文件.i32(块.数据起 + i * 4)
                              guard v >= 0, v < 4096 else { return false }
                              if let f = 首值 {
                                  if f != v { return true }
                              } else {
                                  首值 = v
                              }
                          }
                          return false
                      }) {
            材质表 = 读面材质(文件: 文件, 块: b, 总面: 总面)
        }

        // ---- 组装三角化 ----
        var 索引: [UInt32] = []
        索引.reserveCapacity(面环表.count * 3)
        var 子集: [导入子集] = []
        var 当前材质: Int? = nil
        var 子集起 = 0
        let 上界 = 顶点.count

        for (面序, 环) in 面环表.enumerated() {
            let 材质号 = 面序 < 材质表.count ? 材质表[面序] : nil
            if 材质号 != 当前材质 {
                if 索引.count > 子集起 {
                    子集.append(导入子集(材质: 当前材质, 起始: 子集起, 数量: 索引.count - 子集起))
                    子集起 = 索引.count
                }
                当前材质 = 材质号
            }
            // 注意：三角化后只剩三角形，面边界与「面 → 三角」映射在这里丢失（详见 导入网格.三角化多边形 的说明）。
            导入网格.扇形三角化(环, 写入: &索引)
        }
        if 索引.count > 子集起 {
            子集.append(导入子集(材质: 当前材质, 起始: 子集起, 数量: 索引.count - 子集起))
        }

        var 网格 = 导入网格(名称: "")
        网格.顶点 = 顶点
        网格.法线 = 法线
        网格.UV = UV
        网格.索引 = 索引
        网格.子集 = 子集
        网格.权重 = 读顶点权重(文件: 文件, 块表: 块表, 从: 区间起, 到: 区间止,
                           顶点数: 原顶点数, 地址: 地址)
        // 接缝展开复制出来的新顶点，权重按来源顶点照抄，否则骨权重会与顶点数对不上、
        // 整张皮塌到原点（蒙皮那段有 权重.count == 顶点.count 的硬校验）。
        if !展开来源.isEmpty, !网格.权重.isEmpty, 展开来源.count == 顶点.count {
            var 新权重 = [[导入骨权重]](repeating: [], count: 顶点.count)
            for (新号, 原号) in 展开来源.enumerated() where Int(原号) < 网格.权重.count {
                新权重[新号] = 网格.权重[Int(原号)]
            }
            网格.权重 = 新权重
        }
        // 5.x 把顶点组名搬到了 Mesh 上（vertex_group_names），Object.defbase 留着但已空。
        // 权重层里只有组下标，名必须从这里补，否则整张皮都挂不到骨头上。
        if !网格.权重.isEmpty, let 组路 = 字段偏移("Mesh", "vertex_group_names", S),
           块.长 > 组路.偏移 + 8 {
            let 组名们 = 读顶点组名(首地址: 文件.u64(块.数据起 + 组路.偏移), 文件: 文件, 地址: 地址)
            if !组名们.isEmpty {
                for i in 网格.权重.indices {
                    for j in 网格.权重[i].indices where 网格.权重[i][j].组 < 组名们.count {
                        网格.权重[i][j].骨名 = 组名们[网格.权重[i][j].组]
                    }
                }
            }
        }
        return 网格
    }

    // MARK: - 顶点组权重（蒙皮）

    /// MDeformVert：dw(8) + totweight(4) + flag(4) = 16 字节
    private static let 权重项长 = 16
    /// MDeformWeight：def_nr(4) + weight(4) = 8 字节（组下标在前，重量在后）
    private static let 单位权重长 = 8

    private static func 读顶点权重(文件: 文件视图, 块表: [块], 从: Int, 到: Int,
                            顶点数: Int, 地址: [UInt64: 块]) -> [[导入骨权重]] {
        guard 顶点数 > 0 else { return [] }
        guard let b = 取块(块表, 从: 从, 到: 到, 长: 顶点数 * 权重项长, 靠近: 从,
                           校验: { 权重层自洽(文件: 文件, 块: $0, 顶点数: 顶点数, 地址: 地址) })
        else { return [] }

        var 结果: [[导入骨权重]] = []
        结果.reserveCapacity(顶点数)
        for i in 0..<顶点数 {
            let 起 = b.数据起 + i * 权重项长
            let dw = 文件.u64(起)
            let 项数 = Int(文件.i32(起 + 8))
            guard dw != 0, 项数 > 0, 项数 <= 64, let 权块 = 地址[dw],
                  权块.数据起 + 项数 * 单位权重长 <= 权块.数据起 + 权块.长
            else {
                结果.append([])
                continue
            }
            var 一项: [导入骨权重] = []
            一项.reserveCapacity(项数)
            for k in 0..<项数 {
                let p = 权块.数据起 + k * 单位权重长
                // MDeformWeight 是 { int def_nr; float weight; }，组下标在前、重量在后
                let 组 = Int(文件.i32(p))
                let 重 = 文件.f32(p + 4)
                guard 重 > 0, 重.isFinite, 组 >= 0 else { continue }
                一项.append(导入骨权重(组: 组, 重量: 重))
            }
            // 这里不做截断：源文件的顶点组里常混着 mask_ / 固定 这类辅助组，
            // 真正影响骨骼的那几根要等蒙皮阶段按骨架名单筛，先解析就砍会误伤
            结果.append(一项)
        }
        return 结果
    }

    /// 权重层校验：抽样看 totweight 在合理范围，dw 要么空要么指向长度对得上的块。
    private static func 权重层自洽(文件: 文件视图, 块: 块, 顶点数: Int,
                            地址: [UInt64: 块]) -> Bool {
        guard 块.长 >= 顶点数 * 权重项长 else { return false }
        let 步 = max(1, 顶点数 / 200)
        var 非空 = 0
        var i = 0
        while i < 顶点数 {
            let 起 = 块.数据起 + i * 权重项长
            let dw = 文件.u64(起)
            let 项数 = Int(文件.i32(起 + 8))
            if 项数 < 0 || 项数 > 64 { return false }
            if 项数 > 0 && dw != 0 {
                guard let 权块 = 地址[dw], 权块.长 >= 项数 * 单位权重长 else { return false }
                // 权重值该在 (0, 1]；0 权重也允许（Blender 会留残项），但不能是 NaN/离谱值
                let 重 = 文件.f32(权块.数据起 + 4)
                if !重.isFinite || 重 < 0 || 重 > 1.0001 { return false }
                let 组 = Int(文件.i32(权块.数据起))
                if 组 < 0 || 组 > 4096 { return false }
                非空 += 1
            }
            i += 步
        }
        // 整层全是空 dw 的块多半是别的什么 16 字节结构，不放行
        return 非空 > 0
    }

    /// 顶点组名表：Object.defbase 是 bDeformGroup 链表，bDeformGroup：next(8) prev(8) name[64]
    private static func 读顶点组名(首地址: UInt64, 文件: 文件视图,
                           地址: [UInt64: 块]) -> [String] {
        guard 首地址 != 0 else { return [] }
        var 名们: [String] = []
        var 当前 = 首地址
        var 已看: Set<UInt64> = []
        while 当前 != 0, 名们.count < 512, !已看.contains(当前) {
            已看.insert(当前)
            guard let 块 = 地址[当前], 块.长 >= 24 else { break }
            let 名 = 文件.串(块.数据起 + 16, 长: min(64, 块.长 - 16))
            if 名.isEmpty { break }
            名们.append(名)
            当前 = 文件.u64(块.数据起)
        }
        return 名们
    }

    // MARK: - 按字节长度定位数据块

    /// 取数据块：先在本网格的块区间里找，找不到再全文件按「离本网格最近」的顺序找。
    /// 每步都要过内容校验 —— 同一长度的块在一个文件里往往有好几份（不同网格的
    /// 顶点数可能刚好相同），只有内容自洽的那份才是本网格的。
    private static func 取块(_ 块表: [块], 从: Int, 到: Int, 长: Int, 靠近: Int,
                          校验: (块) -> Bool) -> 块? {
        guard 长 > 0 else { return nil }
        let 起 = max(0, 从)
        let 止 = min(块表.count, 到)

        var i = 起
        while i < 止 {
            let b = 块表[i]
            if b.长 == 长, !跳过取块(b.码), 校验(b) { return b }
            i += 1
        }

        var 候选: [(距: Int, 块: 块)] = []
        for (idx, b) in 块表.enumerated() {
            guard b.长 == 长, !跳过取块(b.码) else { continue }
            候选.append((idx >= 靠近 ? idx - 靠近 : 靠近 - idx, b))
        }
        候选.sort { $0.距 < $1.距 }
        for c in 候选 where 校验(c.块) { return c.块 }
        return nil
    }

    private static func 跳过取块(_ 码: String) -> Bool {
        码 == "ME" || 码 == "DNA1" || 码 == "ENDB"
    }

    /// 顶点块校验：抽样坐标必须是有限值、量级正常
    private static func 坐标有限(文件: 文件视图, 块: 块, 个数: Int) -> Bool {
        let 抽 = min(max(个数, 1), 200)
        for i in 0..<抽 {
            let o = 块.数据起 + i * 12
            guard o + 12 <= 块.数据起 + 块.长 else { return false }
            for k in 0..<3 {
                let v = 文件.f32(o + k * 4)
                if !v.isFinite || abs(v) > 1e9 { return false }
            }
        }
        return true
    }

    /// UV 块校验：抽样值有限、量级正常，并且**不是整段全 0**
    /// （全 0 的 float2 数组多半是 UV 选择层或别的自定义属性，拿它当坐标贴图就是一片死色）
    private static func 浮点2自洽(文件: 文件视图, 块: 块, 个数: Int) -> Bool {
        let 抽 = min(max(个数, 1), 512)
        var 有非零 = false
        for i in 0..<抽 {
            let o = 块.数据起 + i * 8
            guard o + 8 <= 块.数据起 + 块.长 else { return false }
            for k in 0..<2 {
                let v = 文件.f32(o + k * 4)
                if !v.isFinite || abs(v) > 1e6 { return false }
                if v != 0 { 有非零 = true }
            }
        }
        return 有非零
    }

    private static func 半坐标有限(文件: 文件视图, 块: 块, 个数: Int) -> Bool {
        let 抽 = min(max(个数, 1), 200)
        for i in 0..<抽 {
            let o = 块.数据起 + i * 6
            guard o + 6 <= 块.数据起 + 块.长 else { return false }
            for k in 0..<3 {
                let v = 半转浮(文件.u16(o + k * 2))
                if !v.isFinite || abs(v) > 1e9 { return false }
            }
        }
        return true
    }

    // MARK: - 基本读取

    private static func 读浮点3(文件: 文件视图, 块: 块, 个数: Int) -> [SIMD3<Float>] {
        let 可读 = min(个数, 块.长 / 12)
        guard 可读 > 0 else { return [] }
        var 结果: [SIMD3<Float>] = []
        结果.reserveCapacity(可读)
        for i in 0..<可读 {
            let o = 块.数据起 + i * 12
            结果.append(SIMD3(文件.f32(o), 文件.f32(o + 4), 文件.f32(o + 8)))
        }
        return 结果
    }

    private static func 读浮点2(文件: 文件视图, 块: 块, 个数: Int) -> [SIMD2<Float>] {
        let 可读 = min(个数, 块.长 / 8)
        guard 可读 > 0 else { return [] }
        var 结果: [SIMD2<Float>] = []
        结果.reserveCapacity(可读)
        for i in 0..<可读 {
            let o = 块.数据起 + i * 8
            结果.append(SIMD2(文件.f32(o), 文件.f32(o + 4)))
        }
        return 结果
    }

    private static func 读半3(文件: 文件视图, 块: 块, 个数: Int) -> [SIMD3<Float>] {
        let 可读 = min(个数, 块.长 / 6)
        guard 可读 > 0 else { return [] }
        var 结果: [SIMD3<Float>] = []
        结果.reserveCapacity(可读)
        for i in 0..<可读 {
            let o = 块.数据起 + i * 6
            结果.append(SIMD3(半转浮(文件.u16(o)), 半转浮(文件.u16(o + 2)), 半转浮(文件.u16(o + 4))))
        }
        return 结果
    }

    private static func 半转浮(_ v: UInt16) -> Float {
        let 符 = UInt32(v >> 15)
        let 阶 = UInt32((v >> 10) & 0x1F)
        let 尾 = UInt32(v & 0x3FF)
        if 阶 == 0 {
            return 符 == 1 ? -Float(尾) * 5.9604645e-8 : Float(尾) * 5.9604645e-8
        }
        if 阶 == 31 {
            return 尾 == 0 ? (符 == 1 ? -Float.infinity : Float.infinity) : Float.nan
        }
        return Float(bitPattern: (符 << 31) | ((阶 + 112) << 23) | (尾 << 13))
    }

    /// poly_offset_indices[n+1] + corner_vert[totloop] → 每面的顶点环。
    /// 面可以是 3 角、4 角，也可以任意多角，这里原样切出：
    /// 不设长度门槛、不丢面、不翻面、不去重、不改索引值。
    private static func 由指针读面(文件: 文件视图, 偏移: (块, Int), 角: (块, Int),
                           总面: Int, 总环: Int) -> [[UInt32]] {
        let (偏块, 偏偏) = 偏移
        let (角块, 角偏) = 角
        var 结果: [[UInt32]] = []
        结果.reserveCapacity(总面)
        for i in 0..<总面 {
            let 始 = Int(文件.i32(偏块.数据起 + 偏偏 + i * 4))
            let 终 = Int(文件.i32(偏块.数据起 + 偏偏 + (i + 1) * 4))
            guard 始 >= 0, 终 >= 始, 终 <= 总环 else { continue }
            var 环: [UInt32] = []
            环.reserveCapacity(终 - 始)
            for k in 始..<终 {
                环.append(文件.u32(角块.数据起 + 角偏 + k * 4))
            }
            结果.append(环)
        }
        return 结果
    }

    /// 面材质的正规读法：走 Mesh.attribute_storage 里的 `material_index`。
    /// 该属性的 `data` 指向 AttributeArray（数组指针 / 共享信息 / 元素数 / 是否单值），
    /// 真正的 int 数组在其数组指针指向的 DATA 块里。域可能按面（FACE=2）也可能按角点
    /// （CORNER=1）存，直接按属性自带的域取数，不靠「元素数猜等于面数」。
    private static func 读面材质属性(文件: 文件视图, 起: Int, S: SDNA,
                             地址: [UInt64: 块], 块表: [块],
                             总面: Int, 总环: Int, 面环: [[UInt32]],
                             区间起: Int, 区间止: Int) -> [Int] {
        let 属性 = 读属性表(文件: 文件, 起: 起, S: S, 地址: 地址, 块表: 块表,
                        区间起: 区间起, 区间止: 区间止)
        guard let 料 = 属性.first(where: { $0.名 == "material_index" }),
              let (块, 偏, 数) = 读属性整数数组(文件: 文件, 值: 料.值, 靠近: 料.锚,
                                       地址: 地址, 块表: 块表)
        else { return [] }

        func 规范(_ v: Int32) -> Int { v >= 0 && v < 4096 ? Int(v) : 0 }
        let 可读 = min(数, (块.长 - 偏) / 4)

        if 料.域 == 1, 总环 > 0, 可读 >= 总环, !面环.isEmpty {
            var 结果: [Int] = []
            结果.reserveCapacity(面环.count)
            var 环序 = 0
            for 环 in 面环 {
                let v = 环序 < 可读 ? 规范(文件.i32(块.数据起 + 偏 + 环序 * 4)) : 0
                结果.append(v)
                环序 += 环.count
            }
            return 结果
        }
        if 总面 > 0, 可读 >= 总面 {
            return (0..<总面).map { 规范(文件.i32(块.数据起 + 偏 + $0 * 4)) }
        }
        if 总环 > 0, 可读 >= 总环, !面环.isEmpty {
            var 结果: [Int] = []
            结果.reserveCapacity(面环.count)
            var 环序 = 0
            for 环 in 面环 {
                let v = 环序 < 可读 ? 规范(文件.i32(块.数据起 + 偏 + 环序 * 4)) : 0
                结果.append(v)
                环序 += 环.count
            }
            return 结果
        }
        return []
    }

    /// Attribute.data → AttributeArray（32 字节：数组指针 / 共享信息 / 元素数 int64 / 是否单值）→ 数组。
    /// 老文件的 data 直接就是数组首址，AttributeArray 解析不成立时按裸数组处理。
    /// `靠近` 是属性数组所在块的块表下标：同一 old 地址在文件里会被复用多次，
    /// 必须挑离它最近的那一份，否则拿到的是上一个网格的同类型旧副本（元素数对不上、内容全 0）。
    private static func 读属性整数数组(文件: 文件视图, 值: UInt64, 靠近: Int,
                              地址: [UInt64: 块], 块表: [块]) -> (块, Int, Int)? {
        guard let (块, 偏) = 解引用(值, 地址, 块表, 靠近: 靠近) else { return nil }
        let 剩 = 块.长 - 偏
        guard 剩 > 0 else { return nil }

        if 剩 >= 24 {
            let 数据针 = 文件.u64(块.数据起 + 偏)
            let 数 = Int(文件.i32(块.数据起 + 偏 + 16))
            if 数据针 != 0, 数 > 0, 数 < (1 << 26),
               let (数块, 数偏) = 解引用(数据针, 地址, 块表, 靠近: 靠近),
               数块.长 - 数偏 >= 数 * 4 {
                return (数块, 数偏, 数)
            }
        }
        let 数 = 剩 / 4
        return 数 > 0 ? (块, 偏, 数) : nil
    }

    private static func 读面材质(文件: 文件视图, 块: 块, 总面: Int) -> [Int] {
        let 可读 = min(总面, 块.长 / 4)
        guard 可读 > 0 else { return [] }
        var 结果: [Int] = []
        结果.reserveCapacity(可读)
        for i in 0..<可读 {
            let v = Int(文件.i32(块.数据起 + i * 4))
            结果.append(v >= 0 && v < 4096 ? v : 0)
        }
        return 结果
    }

    private static func 角转顶点3(_ 角: [SIMD3<Float>], 面环: [[UInt32]], 顶点数: Int) -> [SIMD3<Float>] {
        guard !角.isEmpty, 顶点数 > 0 else { return [] }
        var 结果 = [SIMD3<Float>](repeating: .zero, count: 顶点数)
        var 已填 = [Bool](repeating: false, count: 顶点数)
        var 角序 = 0
        for 环 in 面环 {
            for v in 环 {
                let vi = Int(v)
                if 角序 < 角.count, vi < 顶点数, !已填[vi] {
                    结果[vi] = 角[角序]
                    已填[vi] = true
                }
                角序 += 1
            }
        }
        return 结果
    }

    /// 角点域的唯一键：同一个 3D 顶点，UV 或法线不同就是不同「角」，必须各自成顶点。
    private struct 角接缝键: Hashable {
        var 顶点: UInt32
        var u: Int64
        var v: Int64
        var nx: Int32
        var ny: Int32
        var nz: Int32
    }

    /// 把文件里来的浮点钳进安全区间：非有限值（NaN/±inf）当 0，越界钳到 ±限。
    /// 定点量化前必须过这一道：越界 float 转整数在 Swift 里是运行时 trap，不是回绕。
    private static func 钳进(_ v: Float, _ 限: Float) -> Float {
        v.isFinite ? min(max(v, -限), 限) : 0
    }

    /// 法线数组的全量体检。
    /// 单位法线的分量必然落在 [-1, 1]；长度明显偏离 1（或压根不是有限数）说明这一块不是法线，
    /// 是同长块误命中。零向量是合法的「没法线」，保留。坏值超过 2% 就整块丢弃，
    /// 让网格退回「入库后重算法线」这条路，而不是把垃圾喂给接缝量化。
    private static func 滤法线(_ 原始: [SIMD3<Float>]) -> [SIMD3<Float>] {
        guard !原始.isEmpty else { return [] }
        var 结果 = 原始
        var 坏 = 0
        for i in 原始.indices {
            let n = 原始[i]
            let 平方 = n.x * n.x + n.y * n.y + n.z * n.z
            let 长 = 平方.squareRoot()
            let 异常 = !平方.isFinite || (长 > 1e-4 && (长 < 0.5 || 长 > 1.5))
            if 异常 {
                坏 += 1
                结果[i] = .zero
            }
        }
        return 坏 * 50 > 原始.count ? [] : 结果
    }

    /// 按 (顶点号, UV, 法线) 展开角点域，把 UV 接缝处拆成多个顶点。
    /// 返回的新顶点表里，来源[i] 是第 i 个新顶点来自哪个原始顶点（权重按它复制）。
    private static func 展开接缝(顶点 原点: [SIMD3<Float>], 法线 原法线: [SIMD3<Float>],
                           角UV: [SIMD2<Float>], 角法线: [SIMD3<Float>],
                           面环: [[UInt32]])
        -> (顶点: [SIMD3<Float>], 法线: [SIMD3<Float>],
            UV: [SIMD2<Float>], 面环: [[UInt32]], 来源: [UInt32]) {
        let 有UV = !角UV.isEmpty
        let 有法线 = !角法线.isEmpty || !原法线.isEmpty
        var 新顶点: [SIMD3<Float>] = []
        var 新法线: [SIMD3<Float>] = []
        var 新UV: [SIMD2<Float>] = []
        var 来源: [UInt32] = []
        var 新面环: [[UInt32]] = []
        var 表: [角接缝键: UInt32] = [:]
        let 预计 = 原点.count + 原点.count / 8 + 16
        新顶点.reserveCapacity(预计)
        新法线.reserveCapacity(预计)
        新UV.reserveCapacity(预计)
        来源.reserveCapacity(预计)
        新面环.reserveCapacity(面环.count)

        var 角序 = 0
        for 环 in 面环 {
            var 新环: [UInt32] = []
            新环.reserveCapacity(环.count)
            for 号 in 环 {
                let vi = Int(号)
                let uv: SIMD2<Float> = (有UV && 角序 < 角UV.count) ? 角UV[角序] : .zero
                var 法: SIMD3<Float> = .zero
                if 角序 < 角法线.count { 法 = 角法线[角序] }
                else if vi < 原法线.count { 法 = 原法线[vi] }
                // UV 量子到 1e-6、法线量子到 1/32768：同一条缝两侧的 UV 差远大于量化步长，
                // 而平滑表面相邻角的法线基本一致，不会因浮点噪声把网格炸成碎片。
                // 量化前一律钳制：Float→Int32/Int64 在越界或 NaN 时会直接 trap（本次崩溃就在这里）。
                // 文件里来的法线/UV 不能假设干净，越界值钳到边界、非有限值当 0。
                let 键 = 角接缝键(
                    顶点: 号,
                    u: Int64((钳进(uv.x, 1_000_000) * 1_000_000).rounded()),
                    v: Int64((钳进(uv.y, 1_000_000) * 1_000_000).rounded()),
                    nx: 有法线 ? Int32((钳进(法.x, 1) * 32_768).rounded()) : 0,
                    ny: 有法线 ? Int32((钳进(法.y, 1) * 32_768).rounded()) : 0,
                    nz: 有法线 ? Int32((钳进(法.z, 1) * 32_768).rounded()) : 0)
                if let 已有 = 表[键] {
                    新环.append(已有)
                } else {
                    let 新号 = UInt32(新顶点.count)
                    新顶点.append(vi < 原点.count ? 原点[vi] : .zero)
                    if 有法线 { 新法线.append(法) }
                    if 有UV { 新UV.append(uv) }
                    来源.append(号)
                    表[键] = 新号
                    新环.append(新号)
                }
                角序 += 1
            }
            新面环.append(新环)
        }
        return (新顶点, 新法线, 新UV, 新面环, 来源)
    }

    private static func 角转顶点2(_ 角: [SIMD2<Float>], 面环: [[UInt32]], 顶点数: Int) -> [SIMD2<Float>] {
        guard !角.isEmpty, 顶点数 > 0 else { return [] }
        var 结果 = [SIMD2<Float>](repeating: .zero, count: 顶点数)
        var 已填 = [Bool](repeating: false, count: 顶点数)
        var 角序 = 0
        for 环 in 面环 {
            for v in 环 {
                let vi = Int(v)
                if 角序 < 角.count, vi < 顶点数, !已填[vi] {
                    结果[vi] = 角[角序]
                    已填[vi] = true
                }
                角序 += 1
            }
        }
        return 结果
    }

    // MARK: - 老格式兜底

    private static func 读顶点自MVert(文件: 文件视图, 起: Int, 总顶点数: Int,
                                  S: SDNA, 地址: [UInt64: 块]) -> [SIMD3<Float>] {
        guard let f = 字段偏移("Mesh", "mvert", S) else { return [] }
        let 指针 = 文件.u64(起 + f.偏移)
        guard 指针 != 0, let 块 = 地址[指针] else { return [] }
        let 单项 = max(S.结构大小("MVert"), 12)
        guard 块.长 >= 单项 else { return [] }

        let 可读 = min(总顶点数, 块.长 / 单项)
        var 结果: [SIMD3<Float>] = []
        结果.reserveCapacity(可读)
        for i in 0..<可读 {
            let o = 块.数据起 + i * 单项
            结果.append(SIMD3(文件.f32(o), 文件.f32(o + 4), 文件.f32(o + 8)))
        }
        return 结果
    }

    private static func 读面环自多边(文件: 文件视图, 起: Int, 总面: Int, 总环: Int,
                              S: SDNA, 地址: [UInt64: 块], 顶点上限: Int) -> [[UInt32]] {
        guard let 面f = 字段偏移("Mesh", "mpoly", S),
              let 环f = 字段偏移("Mesh", "mloop", S) else { return [] }

        let 面指针 = 文件.u64(起 + 面f.偏移)
        let 环指针 = 文件.u64(起 + 环f.偏移)
        guard 面指针 != 0, 环指针 != 0,
              let 面块 = 地址[面指针], let 环块 = 地址[环指针] else { return [] }

        let 面项 = S.结构大小("MPoly")
        let 环项 = max(S.结构大小("MLoop"), 8)
        guard 面项 > 0 else { return [] }

        guard let 始f = 字段偏移("MPoly", "loopstart", S),
              let 数f = 字段偏移("MPoly", "totloop", S),
              let vf = 字段偏移("MLoop", "v", S) else { return [] }

        let 可读面 = min(总面, 面块.长 / 面项)
        let 可读环 = min(总环 == 0 ? 环块.长 / 环项 : 总环, 环块.长 / 环项)

        var 结果: [[UInt32]] = []
        结果.reserveCapacity(可读面)
        for i in 0..<可读面 {
            let 面基 = 面块.数据起 + i * 面项
            let 始 = Int(文件.i32(面基 + 始f.偏移))
            let 数 = Int(文件.i32(面基 + 数f.偏移))
            guard 数 >= 3, 始 >= 0, 始 + 数 <= 可读环 else { continue }

            var 环: [UInt32] = []
            环.reserveCapacity(数)
            var 坏 = false
            for k in 0..<数 {
                let o = 环块.数据起 + (始 + k) * 环项
                let v = Int(文件.i32(o + vf.偏移))
                if v < 0 || v >= 顶点上限 { 坏 = true; break }
                环.append(UInt32(v))
            }
            if !坏, 环.count >= 3 { 结果.append(环) }
        }
        return 结果
    }

}
