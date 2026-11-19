//
//  导入导出 流程.swift
//  3d渲染
//
//  导入 / 导出的编排层：URL 进来 → 选解析器 → 变换与摆放 → 落进场景；
//  导出方向是场景 → 片段 → 各格式写盘。
//  合并自「导入导出 调度 / 导入接入 / 导出接入」三个文件，只做搬家，
//  类型名、函数名、签名一律未改。
//

import AppKit
import Foundation
import simd
import UniformTypeIdentifiers

// MARK: - 调度：批量导入与导出分发（原 导入导出 调度.swift）

// MARK: - 批量导入结果

struct 导入结果项: Sendable {
    var 文件: 导入文件
    var 场景: 导入场景
    var 摘要: String {
        // 纯材质文件（.mtlx）没有网格，摘要如实说「几个材质」，别显示成 0 网格
        if 场景.网格.isEmpty, !场景.mtlx材质.isEmpty { return "\(场景.mtlx材质.count) 个材质" }
        let 网格摘要 = "\(场景.网格.count) 个网格 / \(场景.总三角形) 三角面"
        return 场景.mtlx材质.isEmpty ? 网格摘要 : 网格摘要 + " + \(场景.mtlx材质.count) 个材质"
    }
}

struct 批量导入结果: Sendable {
    var 成功: [导入结果项] = []
    var 失败: [(文件: 导入文件, 原因: String)] = []
    var 已取消 = false

    var 总网格: Int { 成功.reduce(0) { $0 + $1.场景.网格.count } }
    var 总三角形: Int { 成功.reduce(0) { $0 + $1.场景.总三角形 } }
    /// 纯材质文件（.mtlx）没有网格，结果区得能单独报材质数
    var 总材质: Int { 成功.reduce(0) { $0 + $1.场景.mtlx材质.count } }

    /// 结果区那一行字：几何 / 材质 / 两者混合三种情况分开写，别把纯材质导入显示成「0 网格」
    var 摘要行: String {
        if 总网格 == 0, 总材质 > 0 { return "\(总材质) 个材质" }
        let 几何 = "\(总网格) 网格 / \(总三角形) 三角面"
        return 总材质 > 0 ? 几何 + " + \(总材质) 个材质" : 几何
    }
}

// MARK: - 导入调度

/// 「选了一堆文件」之后真正干活的入口。
/// 顺序固定为：解析 → 上轴校正 → 缩放/归一化 → 烘焙 → 重算法线 → 焊接 → 合并。
/// 每步只施加一次，避免「缩放被应用两遍」这类典型导入事故。
enum 导入调度 {

    static func 单个文件(_ 文件: 导入文件, 设置: 单文件导入设置) throws -> 导入场景 {
        guard 文件.启用 else { throw 导入导出错误.用户取消 }
        var 是目录: ObjCBool = false
        guard FileManager.default.fileExists(atPath: 文件.url.path, isDirectory: &是目录), !是目录.boolValue else {
            throw 导入导出错误.文件不可读(文件.url)
        }

        // 1. 解析：全部原生实现，不借道任何外部 DCC
        var 场景: 导入场景
        switch 文件.格式 {
        case .obj: 场景 = try OBJ解析.解析(url: 文件.url, 设置: 设置)
        case .stl: 场景 = try STL解析.解析(url: 文件.url, 设置: 设置)
        case .ply: 场景 = try PLY解析.解析(url: 文件.url, 设置: 设置)
        case .gltf: 场景 = try GLTF解析.解析(url: 文件.url, 设置: 设置)
        case .usd: 场景 = try USD文本解析.解析(url: 文件.url, 设置: 设置)
        case .fbx: 场景 = try FBX解析.导入(url: 文件.url, 设置: 设置)
        case .blend: 场景 = try Blend解析.导入(url: 文件.url, 设置: 设置)
        case .mtlx: 场景 = try MTLX接入.解析为场景(url: 文件.url)
        }

        场景.网格 = 场景.网格.filter { !$0.顶点.isEmpty && !$0.索引.isEmpty }
        // .mtlx 是纯材质文件：没有几何是正常的，不套网格校验，也不做上轴/缩放/合并，
        // 原样交给接入层落进着色域材质库。
        if 场景.网格.isEmpty, !场景.mtlx材质.isEmpty { return 场景 }
        guard !场景.网格.isEmpty else { throw 导入导出错误.无有效几何(文件.url) }

        // 2. 上轴校正：源轴与 App 的 Y 轴不同才动
        // 优先级：用户手动指定 > 文件自己声明（USD upAxis / FBX UpAxis）> 格式默认
        let 源轴 = 设置.源上轴 ?? 场景.文件上轴 ?? 文件.推断上轴
        let 上轴矩阵 = 网格变换.上轴校正(from: 源轴, 到: .y)
        if 上轴矩阵 != matrix_identity_float4x4 {
            施加几何变换(上轴矩阵, 到: &场景)
            场景.报告.append("已做 \(源轴.标题) → Y 向上 校正")
        }

        // 3. 缩放 / 归一化
        if abs(设置.额外缩放 - 1) > 1e-9, 设置.额外缩放 > 0 {
            施加几何变换(网格变换.缩放(Float(设置.额外缩放)), 到: &场景)
        }
        if 设置.归一化尺寸 {
            if 场景.网格.count > 1 {
                // 多对象必须按整包包围盒算一个统一比例：逐对象各缩到 1.5 会把
                // 一根头发丝和一个躯干缩成一样大，对象间相对大小和相对位置全毁
                var 累加 = 包围盒累加()
                for 片 in 场景.网格 {
                    guard let 盒 = 片.包围盒 else { continue }
                    累加.加(盒)
                }
                let 尺寸 = 累加.尺寸 ?? .zero
                let 最长 = max(尺寸.x, max(尺寸.y, 尺寸.z))
                if 最长 > 1e-6, 最长.isFinite {
                    施加几何变换(网格变换.缩放(1.5 / 最长), 到: &场景)
                }
            } else if let 唯一 = 场景.网格.first {
                // 单个网格也要按同一个比例同时缩骨架，否则皮缩到 1.5、骨还是原始尺寸
                let 最长 = 唯一.最大边长
                if 最长 > 1e-6, 最长.isFinite {
                    施加几何变换(网格变换.缩放(1.5 / 最长), 到: &场景)
                }
            }
        }

        // 4. 烘焙（SceneObject 自带 TRS，网格必须是物体局部的最终形状）
        for i in 场景.网格.indices { 场景.网格[i].烘焙变换() }

        // 5. 法线 / 焊接
        for i in 场景.网格.indices {
            if 设置.重算法线 { 场景.网格[i].重算法线() }
            if 设置.焊接顶点 { 场景.网格[i].焊接顶点() }
        }

        // 6. 合并
        if 设置.合并为单对象, 场景.网格.count > 1,
           let 合 = 网格组装.合并(场景.网格, 名称: 文件.url.deletingPathExtension().lastPathComponent) {
            var 材质名表: [String] = []
            for 片 in 场景.网格 {
                if let 名 = 片.子集.first?.材质名, !材质名表.contains(名) { 材质名表.append(名) }
            }
            场景.网格 = [合]
            if !材质名表.isEmpty {
                场景.报告.append("已合并为单对象（原 \(材质名表.count) 个材质区间合成同一网格）")
            } else {
                场景.报告.append("已合并为单对象")
            }
        }

        if 设置.采用米制换算 == false {
            场景.报告.append("已跳过米制换算，按文件原始单位导入")
        }

        // 7. 节点树：只有「保留层级」且没被合并成单对象时，才让接入层按对象拆开
        let 可拆节点 = 场景.节点.filter { !$0.网格.isEmpty }.count
        if 设置.合并为单对象 || !设置.保留层级 || 可拆节点 == 0 {
            场景.节点.removeAll()
            场景.按节点拆分 = false
        } else {
            场景.按节点拆分 = true
        }
        return 场景
    }

    /// 上轴校正 / 缩放这类「整包几何变换」必须同时压到网格和骨架身上。
    /// 只转网格不转骨架 → 角色窗口里皮竖着、骨架躺着（或反过来），
    /// 而且两套坐标混在一个包围盒里取景，皮会被挤到画面外，看着就像「只剩骨骼」。
    /// 这里一处统一施加，绝不各转一次。
    private static func 施加几何变换(_ m: simd_float4x4, 到 场景: inout 导入场景) {
        guard m != matrix_identity_float4x4 else { return }
        for i in 场景.网格.indices { 场景.网格[i].施加变换(m) }
        for i in 场景.节点.indices {
            for j in 场景.节点[i].骨骼数据.indices {
                var 骨 = 场景.节点[i].骨骼数据[j]
                骨.头 = 变换点(m, 骨.头)
                骨.尾 = 变换点(m, 骨.尾)
                骨.rest矩阵 = m * 骨.rest矩阵
                场景.节点[i].骨骼数据[j] = 骨
            }
            for (名, 姿) in 场景.节点[i].姿态 {
                场景.节点[i].姿态[名] = m * 姿
            }
        }
    }

    private static func 变换点(_ m: simd_float4x4, _ p: SIMD3<Float>) -> SIMD3<Float> {
        let q = m * SIMD4<Float>(p, 1)
        guard abs(q.w) > 1e-9, q.w != 1 else { return SIMD3<Float>(q.x, q.y, q.z) }
        return SIMD3<Float>(q.x / q.w, q.y / q.w, q.z / q.w)
    }

    /// 串行执行：解析本身就会吃满多核，并发只会互抢 CPU，总时间反而更长。
    static func 批量(
        _ 文件列表: [导入文件],
        设置表: [UUID: 单文件导入设置],
        进度: ((Int, Int, String) -> Void)? = nil,
        已取消: (() -> Bool)? = nil
    ) -> 批量导入结果 {
        var 结果 = 批量导入结果()
        let 启用 = 文件列表.filter { $0.启用 }
        for (序, 文件) in 启用.enumerated() {
            if 已取消?() == true {
                结果.已取消 = true
                break
            }
            进度?(序, 启用.count, 文件.名称)
            let 设置 = 设置表[文件.id] ?? 单文件导入设置()
            do {
                结果.成功.append(导入结果项(文件: 文件, 场景: try 单个文件(文件, 设置: 设置)))
            } catch {
                结果.失败.append((文件, (error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
            }
        }
        进度?(启用.count, 启用.count, "")
        return 结果
    }
}

// MARK: - 导出调度

struct 导出请求: Sendable {
    var 片段: [导入网格]
    var 材质: [导入材质] = []
    var 目标: URL
    /// 目标朝向。导出给 Blender / UE 选 .z，给自己留档选 .y
    var 目标上轴: 上轴 = .y
}

enum 导出调度 {

    static func 导出(_ 请求: 导出请求) throws {
        guard !请求.片段.isEmpty else { throw 导入导出错误.导出失败("场景里没有可导出的网格") }
        let 扩展 = 请求.目标.pathExtension.lowercased()
        let 图 = try 选定格式(扩展)
        var 片段 = 请求.片段

        // glTF 规范写死 Y-up；usda 由写出函数自己转轴（避免翻两次）
        if 请求.目标上轴 == .z, 图 != .gltf, 图 != .usd {
            let 矩阵 = 网格变换.y转z
            for i in 片段.indices {
                片段[i].施加变换(矩阵)
                片段[i].烘焙变换()
            }
        }

        switch 图 {
        case .gltf:
            if 扩展 == "glb" {
                try GLTF导出.写出GLB(片段: 片段, 材质: 请求.材质, 到: 请求.目标)
            } else {
                try GLTF导出.写出GLTF(片段: 片段, 材质: 请求.材质, 到: 请求.目标)
            }
        case .obj:
            try 纯文本导出.写出OBJ(片段: 片段, 材质: 请求.材质, 到: 请求.目标)
        case .stl:
            try 纯文本导出.写出STL(片段: 片段, 到: 请求.目标, 二进制: true)
        case .ply:
            try 纯文本导出.写出PLY(片段: 片段, 到: 请求.目标)
        case .usd:
            try 纯文本导出.写出USDA(片段: 片段, 材质: 请求.材质, 到: 请求.目标, 上轴: 请求.目标上轴)
        default:
            throw 导入导出错误.导出失败("暂不支持导出 .\(扩展)")
        }
    }

    private static func 选定格式(_ 扩展: String) throws -> 导入格式 {
        guard let 格式 = 导入格式.allCases.first(where: { $0.扩展名.contains(扩展) }) else {
            throw 导入导出错误.不支持的格式(扩展)
        }
        return 格式
    }
}

// MARK: - 导入接入：导入结果 → 场景（原 导入接入.swift）

// MARK: - 导入结果 → 场景

/// 把「通用导入」跑出来的 `导入场景` 落进场景里。
///
/// 职责边界很窄：
/// 1. 网格（已烘焙成局部形状、已校正到 Y 上轴）存进 `导入网格库`；
/// 2. 场景里只留一个 `SceneObject`，用 `导入网格ID` 指回网格库；
/// 3. 摆放：模型底部贴地面，多个文件沿 X 依次排开，不互相穿模。
///
/// 视口实体 / 路径追踪 / 拾取三处都已经按 `导入网格ID` 分支（见 场景 构建、PT 场景 转译、拾取 几何），
/// 所以这里不要碰 MeshKind 之外的任何渲染逻辑。
@MainActor
enum 导入接入 {

    @discardableResult
    /// 按子集材质把一份网格拆开。
    /// 本 App 的材质挂在物体级（SceneObject.materialID），一个网格只能吃一个材质；
    /// 多材质模型（.blend 里一个对象多个材质槽）必须拆成多个物体，否则只剩首个材质、其余回落陶土。
    static func 按材质拆分(_ 网格: 导入网格) -> [(网格: 导入网格, 材质: Int?, 材质名: String?)] {
        let 单份 = [(网格: 网格, 材质: 网格.子集.first?.材质, 材质名: 网格.子集.first?.材质名)]
        let 不同 = Set(网格.子集.compactMap(\.材质))
        guard 不同.count > 1, !网格.索引.isEmpty else { return 单份 }
        var 结果: [(网格: 导入网格, 材质: Int?, 材质名: String?)] = []
        for 材 in 不同.sorted() {
            let 段 = 网格.子集.filter { $0.材质 == 材 }
            var 新索引: [UInt32] = []
            新索引.reserveCapacity(段.reduce(0) { $0 + $1.数量 })
            for s in 段 {
                let 起 = max(0, min(s.起始, 网格.索引.count))
                let 止 = max(起, min(s.起始 + s.数量, 网格.索引.count))
                guard 起 < 止 else { continue }
                新索引.append(contentsOf: 网格.索引[起..<止])
            }
            guard !新索引.isEmpty else { continue }
            var 份 = 网格
            份.索引 = 新索引
            份.子集 = [导入子集(材质: 材, 起始: 0, 数量: 新索引.count, 材质名: 段.first?.材质名)]
            份.名称 = 网格.名称 + "_" + (段.first?.材质名 ?? "\(材)")
            结果.append((份, 材, 段.first?.材质名))
        }
        return 结果.isEmpty ? 单份 : 结果
    }

    static func 放入(
        _ 场景集: [导入场景],
        场景 scene: 布局Store,
        设材质: Bool = true
    ) -> [SceneObject] {
        guard !场景集.isEmpty else { return [] }

        // MaterialX 材质文件先落材质库（着色域），再走几何；
        // 纯材质文件没有网格，下面按网格过滤时会被跳过，不会在场景里留空物体。
        // 这里只往库尾追加新材质，不改任何既有材质与物体绑定 —— 材质层与绘画层各管各的。
        let 新材质 = MTLX接入.入库(场景集, 着色: scene.shading)
        if !新材质.isEmpty, 设材质, let 首 = 新材质.first, scene.shading?.selectedMaterialID == nil {
            scene.shading?.selectedMaterialID = 首
        }

        // 模型自带材质（含基础色贴图）已经落进材质库，这里按子集材质把物体绑过去
        let 网格材质表 = 设材质 ? MTLX接入.网格材质入库(场景集, 着色: scene.shading) : [:]
        let 缺省材质 = 设材质 ? scene.shading?.materials.first?.id : nil
        func 材质ID(_ 场景下标: Int, _ 子集材质: Int?) -> UUID? {
            if let 子集材质, let id = 网格材质表[场景下标]?[子集材质] { return id }
            return 缺省材质
        }
        var 新物体: [SceneObject] = []
        var 已有名字 = Set(scene.objects.map(\.name))
        // 已经摆到哪个 X 了：按每个模型的包围半径累加，大模型占得宽
        var 光标: Float = 0

        for (场景下标, 场景数据) in 场景集.enumerated() {
            // 过滤空网格时记下「原下标 → 新下标」：节点里的网格下标是原始下标
            var 旧到新: [Int: Int] = [:]
            var 有效: [导入网格] = []
            for (i, 片) in 场景数据.网格.enumerated() where !片.顶点.isEmpty && !片.索引.isEmpty {
                旧到新[i] = 有效.count
                有效.append(片)
            }
            guard !有效.isEmpty else { continue }

            // 整包包围盒：同一个文件的所有对象共享同一次摆放偏移，
            // 否则每个对象各自贴地/各自居中，对象之间的相对位置就全散了
            var 累加 = 包围盒累加()
            for 片 in 有效 {
                guard let 盒 = 片.包围盒 else { continue }
                累加.加(盒)
            }
            let 盒尺寸 = 累加.尺寸 ?? .zero
            let 中心Y = 累加.中心?.y ?? 0
            let 半径 = max(max(盒尺寸.x, 盒尺寸.z) * 0.5, 0.001)

            let x = 光标 + 半径
            光标 = x + 半径 + max(半径 * 0.5, 0.08)
            let 放置 = Vec3(Double(x), Double(-中心Y), 0)

            // 按节点拆分：文件里有几个对象就建几个 SceneObject，
            // 并把 Blender 的层级一起搬进场景：
            // - 骨架（Armature）→ **角色**物体：不是文件夹，双击打开独立窗口，
            //   里面的身体/衣服/道具都挂它身上
            // - 有几何的节点 → 物体（父可能是物体，形成父子变换；也可能是容器）
            // - 没几何但被别的节点当父的空物体 → 场景集合（文件夹）
            if 场景数据.按节点拆分, !场景数据.节点.isEmpty {
                let 节点们 = 场景数据.节点
                var 下标到物体: [Int: UUID] = [:]
                var 下标到集合: [Int: UUID] = [:]
                var 角色部件: [Int: [UUID]] = [:]

                // 往上找最近的骨架节点：找到就说明这个物体是"某个角色身上的部件"
                func 骨架祖先(_ i: Int) -> Int? {
                    var 深 = 0
                    var 当前 = 节点们[i].父
                    while let 父 = 当前, 深 < 64, 父 >= 0, 父 < 节点们.count {
                        if 节点们[父].类型 == "骨架" { return 父 }
                        当前 = 节点们[父].父
                        深 += 1
                    }
                    return nil
                }

                // 第零遍：骨架落实成角色物体（骨架自己通常不带几何）
                for (下标, 节) in 节点们.enumerated() where 节.类型 == "骨架" {
                    let 基 = 节.名称.isEmpty ? 基础名(场景数据.源文件) : 节.名称
                    let 名 = 唯一名(基, 已有: 已有名字)
                    已有名字.insert(名)
                    let 物体 = SceneObject(
                        name: 名,
                        mesh: .cube,
                        position: 放置,
                        materialID: 缺省材质,
                        角色: 角色资产(骨架名: 名,
                                    骨骼: 节.骨骼,
                                    骨数据: 节.骨骼数据.map {
                                        角色骨骼(名称: $0.名称,
                                               路径: $0.路径,
                                               父: $0.父,
                                               层: $0.路径.reduce(0) { $1 == "/" ? $0 + 1 : $0 },
                                               头: $0.头,
                                               尾: $0.尾)
                                    },
                                    部件: [])
                    )
                    下标到物体[下标] = 物体.id
                    新物体.append(物体)
                }

                // 第一遍：有几何的节点落实成物体（挂在骨架下的是角色部件）
                for (下标, 节) in 节点们.enumerated() where !节.网格.isEmpty {
                    let 片 = 节.网格.compactMap { 旧到新[$0] }.map { 有效[$0] }
                    guard !片.isEmpty else { continue }
                    let 基名 = 节.名称.isEmpty ? 基础名(场景数据.源文件) : 节.名称
                    // 一个物体只吃一个材质（SceneObject.materialID），多材质网格按材质拆成几个物体，
                    // 否则只取首个子集的材质，其余部分全退回缺省陶土球。
                    var 份们: [(网格: 导入网格, 材质: Int?, 材质名: String?)] = []
                    for g in 片 { 份们.append(contentsOf: 按材质拆分(g)) }
                    // 材质种类多于一种就拆：一个物体只吃一个材质，不拆就只剩首个材质的颜色。
                    // （早先只拆「单网格多材质」的情况，多片网格整体成一个物体时材质照样丢。）
                    let 材质种类 = Set(份们.compactMap(\.材质))
                    let 需拆 = 份们.count > 1 && (片.count == 1 || 材质种类.count > 1)
                    let 成组 = !需拆
                    let 份组: [[导入网格]] = 成组 ? [片] : 份们.map { [$0.网格] }
                    for (k, 组份) in 份组.enumerated() {
                        let 份 = k < 份们.count ? 份们[k] : (网格: 片[0], 材质: nil, 材质名: nil)
                        let 网格ID = 几何接线.共享.存入(组份)
                        let 名基 = (成组 || 份.材质名 == nil) ? 基名 : "\(基名)·\(份.材质名!)"
                        let 名字 = 唯一名(名基, 已有: 已有名字)
                        已有名字.insert(名字)
                        var 物体 = SceneObject(
                            name: 名字,
                            mesh: .cube,
                            导入网格ID: 网格ID,
                            导入符号: 符号(场景数据.源文件),
                            position: 放置,
                            materialID: 材质ID(场景下标, 份.材质)
                        )
                        if 物体.materialID == nil { 物体.materialID = 缺省材质 }
                        下标到物体[下标] = 物体.id
                        新物体.append(物体)
                        // 挂在骨架下 → 记成这个角色的部件（大纲里不再单列，收进角色窗口）
                        if let 骨架 = 骨架祖先(下标) {
                            角色部件[骨架, default: []].append(物体.id)
                        }
                    }
                }

                // 第二遍：只有"被当成父"的纯容器节点才建集合，否则会凭空多出一堆空文件夹
                var 容器下标 = Set<Int>()
                for 节 in 节点们 {
                    guard let 父 = 节.父, 父 >= 0, 父 < 节点们.count else { continue }
                    if 下标到物体[父] == nil { 容器下标.insert(父) }
                }

                // 集合要按"父先建、子后建"的顺序，用递归把整条链补齐
                func 集合ID(下标 i: Int, 层: Int = 0) -> UUID? {
                    guard 层 < 64, i >= 0, i < 节点们.count else { return nil }
                    if let 现成 = 下标到集合[i] { return 现成 }
                    guard 下标到物体[i] == nil, 容器下标.contains(i) else { return nil }
                    var 上级: UUID? = nil
                    if let 父 = 节点们[i].父, 父 >= 0, 父 < 节点们.count {
                        上级 = 集合ID(下标: 父, 层: 层 + 1)
                    }
                    // 集合名也参与去重：同一批/多次导入里容器常重名（都叫 Armature / Empty）
                    let 基 = 节点们[i].名称.isEmpty ? "集合" : 节点们[i].名称
                    let 名 = 唯一名(基, 已有: 已有名字)
                    已有名字.insert(名)
                    let 集合 = scene.新建集合(名: 名, 父: 上级)
                    下标到集合[i] = 集合.id
                    return 集合.id
                }
                for i in 容器下标.sorted() { _ = 集合ID(下标: i) }

                // 第三遍：把每个物体的父挂上去。父是物体 → 真父子（父动子跟随）；
                // 父是容器 → 落到集合里；都没有 → 留在场景根级。
                // 角色部件直接挂到角色物体上（角色一动，整身穿挂跟着走），
                // 并且把部件 id 记进 角色资产，独立窗口按这个列表树。
                var 父子数 = 0
                var 角色数 = 0
                for (下标, 物体ID) in 下标到物体 {
                    guard let i = 新物体.firstIndex(where: { $0.id == 物体ID }) else { continue }
                    if let 骨架 = 骨架祖先(下标), let 角色ID = 下标到物体[骨架] {
                        新物体[i].父 = .对象(角色ID)
                        父子数 += 1
                        continue
                    }
                    guard let 父 = 节点们[下标].父, 父 >= 0, 父 < 节点们.count else { continue }
                    if let 父物体 = 下标到物体[父] {
                        新物体[i].父 = .对象(父物体)
                        父子数 += 1
                    } else if let 父集合 = 下标到集合[父] {
                        新物体[i].父 = .集合(父集合)
                    }
                }
                for (骨架, 部件) in 角色部件 {
                    guard let 角色ID = 下标到物体[骨架],
                          let i = 新物体.firstIndex(where: { $0.id == 角色ID }) else { continue }
                    新物体[i].角色?.部件 = 部件
                    角色数 += 1
                }
                if !下标到集合.isEmpty || 父子数 > 0 {
                    scene.note("层级：\(父子数) 组父子 · \(下标到集合.count) 个集合")
                }
                if 角色数 > 0 {
                    scene.note("角色：\(角色数) 个（双击大纲里的角色，打开穿挂窗口）")
                }
                continue
            }

            let 网格ID = 几何接线.共享.存入(有效)
            let 名字 = 唯一名(场景数据.源文件, 已有: 已有名字)
            已有名字.insert(名字)

            新物体.append(SceneObject(
                name: 名字,
                // 占位：真实几何在网格库里，MeshKind 只保证旧的序列化/图标逻辑不炸
                mesh: .cube,
                导入网格ID: 网格ID,
                导入符号: 符号(场景数据.源文件),
                position: 放置,
                materialID: 材质ID(场景下标, 场景数据.网格.first?.子集.first?.材质)
            ))
        }

        guard !新物体.isEmpty else { return [] }

        scene.updateObjects { $0.append(contentsOf: 新物体) }
        scene.selectedObjectID = 新物体.first?.id
        // 导入物体自带材质归属，直接改 model 会绕开引用计数：
        // 这里把 (对象 → 全部材质槽位) 补登记进材质接线，否则删材质会被误判"没人用"。
        // 传整张槽位表（0 号槽 + 副槽），与运行时口径一致，不留"导入时只算主槽"的第二条路径。
        for 物 in 新物体 {
            let 槽位 = 物.材质槽位表
            guard 槽位.contains(where: { $0 != nil }) else { continue }
            switch 材质接线.共享.绑定(对象: 物.id, 槽位表: 槽位) {
            case .变更, .无需变更: break
            case .未知材质(let id): scene.note("导入材质 \(id) 未登记到材质域，引用计数缺这一条")
            case .引用计数错乱(let 原因): scene.note("导入材质引用计数错乱：\(原因)")
            }
        }

        // 导入诊断：落到固定文件，排查「导入后视口空白」时直接读这里
        var 诊断 = "=== 导入诊断 \(Date()) 文件数 \(场景集.count) ===\n"
        诊断 += "文件：" + 场景集.map { "\($0.源文件) 拆节点=\($0.按节点拆分) 网格\($0.网格.count)" }.joined(separator: " ; ") + "\n"
        for 物 in 新物体 {
            let 网格集 = 物.导入网格ID.flatMap { 几何接线.共享.取($0) } ?? []
            let 顶点数 = 网格集.reduce(0) { $0 + $1.顶点.count }
            let 三角数 = 网格集.reduce(0) { $0 + $1.三角形数 }
            var 盒 = "-"
            if let 球 = 物.导入网格ID.flatMap({ 几何接线.共享.局部包围球($0) }) {
                盒 = "中心(\(String(format: "%.2f", 球.中心.x)),\(String(format: "%.2f", 球.中心.y)),\(String(format: "%.2f", 球.中心.z))) 半径\(String(format: "%.2f", 球.半径))"
            }
            诊断 += "\(物.name) | 子网格\(网格集.count) | v\(顶点数) tri\(三角数) | \(盒) | pos(\(String(format: "%.2f", 物.position.x)),\(String(format: "%.2f", 物.position.y)),\(String(format: "%.2f", 物.position.z))) | 可见\(物.isVisible) | 角色\(物.是角色) | 有ID\(物.导入网格ID != nil)\n"
        }
        try? 诊断.write(toFile: "/tmp/3d渲染_导入诊断.log", atomically: true, encoding: .utf8)
        print(诊断)
        scene.note("导入 \(新物体.count) 个物体 · \(三角形数(新物体)) 个三角形")
        return 新物体
    }

    /// 这些物体所用的网格总三角形数（给状态栏 / 报告用）
    static func 三角形数(_ objects: [SceneObject]) -> Int {
        objects.reduce(0) { 和, 物体 in
            guard let id = 物体.导入网格ID,
                  let 网格集 = 几何接线.共享.取(id) else { return 和 }
            return 和 + 网格集.reduce(0) { $0 + $1.三角形数 }
        }
    }

    // MARK: 命名与图标

    private static func 基础名(_ url: URL) -> String {
        let 名 = url.deletingPathExtension().lastPathComponent
        return 名.isEmpty ? "导入" : 名
    }

    private static func 唯一名(_ url: URL, 已有: Set<String>) -> String {
        唯一名(基础名(url), 已有: 已有)
    }

    /// 同一批导入里对象重名就加序号（.blend 允许不同集合里有同名对象）
    private static func 唯一名(_ 基: String, 已有: Set<String>) -> String {
        let 底 = 基.isEmpty ? "导入" : 基
        guard 已有.contains(底) else { return 底 }
        var 序号 = 2
        while 已有.contains("\(底) \(序号)") { 序号 += 1 }
        return "\(底) \(序号)"
    }

    /// 图层 / 大纲里的格式图标
    static func 符号(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "blend": return "circle.hexagongrid"
        case "usd", "usda", "usdc", "usdz": return "square.stack.3d.up"
        case "fbx": return "cube.transparent"
        case "gltf", "glb": return "shippingbox"
        case "obj": return "cube"
        case "stl": return "triangle"
        case "ply": return "point.3.connected.trianglepath.dotted"
        default: return "cube"
        }
    }
}

// MARK: - 导出接入：场景 → 导出文件（原 导出接入.swift）

// MARK: - 场景 → 导出文件

/// 场景里的物体（内置程序化形体 + 导入网格）统一变成 `导入网格` 片段，交给 `导出调度` 写盘。
///
/// 两条硬规矩：
/// 1. 顶点一律烘焙到世界空间再导出 —— 交换格式里的节点变换各家解释不一（FBX 的
///    PreRotation / USD 的 xformOpOrder / glTF 的列主序混轴），烘焙掉最省事；
/// 2. 一个物体 = 一份单子集网格，材质下标指向统一的材质表，
///    免得导入时那套「多子集多材质」在导出侧对不上号。
@MainActor
enum 导出接入 {

    struct 格式项: Identifiable {
        let id: String          // 扩展名
        let 标题: String
        let 说明: String
        /// glTF 规范写死 Y-up，不给用户选轴
        let 固定Y上轴: Bool
    }

    static let 格式表: [格式项] = [
        格式项(id: "glb", 标题: "glTF 二进制 (.glb)", 说明: "交换首选，几何 + 材质一次打包", 固定Y上轴: true),
        格式项(id: "gltf", 标题: "glTF 文本 (.gltf)", 说明: "JSON 头，方便手查", 固定Y上轴: true),
        格式项(id: "obj", 标题: "Wavefront OBJ (.obj)", 说明: "最通用，配 .mtl 一起给", 固定Y上轴: false),
        格式项(id: "usda", 标题: "USD 文本 (.usda)", 说明: "原生写出，无 Blender 依赖", 固定Y上轴: false),
        格式项(id: "stl", 标题: "STL 二进制 (.stl)", 说明: "只有几何，3D 打印常用", 固定Y上轴: false),
        格式项(id: "ply", 标题: "PLY (.ply)", 说明: "顶点 + 面，可带颜色", 固定Y上轴: false),
        格式项(id: "fbx", 标题: "FBX (.fbx)", 说明: "原生写出（待接入）", 固定Y上轴: false),
        格式项(id: "blend", 标题: "Blender (.blend)", 说明: "原生写出（待接入）", 固定Y上轴: false)
    ]

    // MARK: 入口

    static func 运行(
        _ 项: 格式项,
        objects: [SceneObject],
        materials: [UUID: MaterialAsset],
        场景 scene: 布局Store
    ) {
        let 可见 = objects.filter { $0.isVisible }
        guard !可见.isEmpty else {
            scene.note("场景里没有可导出的物体")
            return
        }

        // 目标上轴：glTF 不给选，其余先问一句（导出给别家 DCC 最常见的坑就是轴）
        var 目标上轴: 上轴 = .y
        if !项.固定Y上轴 {
            let 弹出 = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 210, height: 25), pullsDown: false)
            弹出.addItems(withTitles: ["Y 向上（本 App / Three.js 系）", "Z 向上（Blender / UE）"])
            弹出.selectItem(at: 0)
            let 提醒 = NSAlert()
            提醒.messageText = "导出 \(项.标题)"
            提醒.informativeText = 项.说明
            提醒.accessoryView = 弹出
            提醒.addButton(withTitle: "继续")
            提醒.addButton(withTitle: "取消")
            guard 提醒.runModal() == .alertFirstButtonReturn else { return }
            目标上轴 = 弹出.indexOfSelectedItem == 1 ? .z : .y
        }

        let 面板 = NSSavePanel()
        面板.title = "导出"
        面板.message = "场景内 \(可见.count) 个可见物体"
        面板.nameFieldStringValue = "场景.\(项.id)"
        面板.canCreateDirectories = true
        面板.isExtensionHidden = false
        if let 类型 = UTType(filenameExtension: 项.id) {
            面板.allowedContentTypes = [类型]
        }
        guard 面板.runModal() == .OK, let 目标 = 面板.url else { return }

        scene.note("正在导出 \(目标.lastPathComponent)…")
        let (片段, 材质) = 打包(objects: 可见, materials: materials)

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let 请求 = 导出请求(片段: 片段, 材质: 材质, 目标: 目标, 目标上轴: 目标上轴)
                try 导出调度.导出(请求)
                DispatchQueue.main.async {
                    scene.note("已导出 \(目标.lastPathComponent) · \(片段.count) 个网格")
                }
            } catch {
                DispatchQueue.main.async {
                    scene.note("导出失败：\(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: 打包

    static func 打包(
        objects: [SceneObject],
        materials: [UUID: MaterialAsset]
    ) -> (片段: [导入网格], 材质: [导入材质]) {
        var 片段表: [导入网格] = []
        var 材质表: [导入材质] = []
        var 材质槽: [UUID: Int] = [:]

        for 物体 in objects {
            let 世界 = 拾取几何.世界矩阵(物体)

            // 材质：同一个材质只进表一次
            var 槽位: Int?
            if let 材质ID = 物体.materialID, let 资产 = materials[材质ID] {
                if let 已有 = 材质槽[材质ID] {
                    槽位 = 已有
                } else {
                    let 转换 = 转换材质(资产)
                    材质槽[材质ID] = 材质表.count
                    槽位 = 材质表.count
                    材质表.append(转换)
                }
            }

            let 源网格: [导入网格]
            if let 网格ID = 几何接线.共享.取值(键: 物体.id.uuidString)?.导入网格标识, let 已有 = 几何接线.共享.取(网格ID) {
                源网格 = 已有
            } else {
                源网格 = [内置网格(几何接线.共享.程序形状(键: 物体.id.uuidString, 兜底: 物体.mesh))]
            }

            for (序, 原始) in 源网格.enumerated() {
                var 网格 = 原始
                // 名字：单网格就用物体名，多子网格加后缀
                网格.名称 = 源网格.count > 1 ? "\(物体.name)_\(序 + 1)" : 物体.name
                网格.施加变换(世界)
                网格.烘焙变换()
                // 子集统一成一份，材质指向上面那张表
                let 材质名 = 槽位.map { 材质表[$0].名称 }
                网格.子集 = [导入子集(材质: 槽位, 起始: 0, 数量: 网格.索引.count, 材质名: 材质名)]
                片段表.append(网格)
            }
        }
        return (片段表, 材质表)
    }

    /// 内置程序化形体 → 通用网格（顶点按 piece 直接摊平，重复顶点不影响交换格式）
    static func 内置网格(_ mesh: MeshKind) -> 导入网格 {
        var 结果 = 导入网格(名称: mesh.title)
        for 片 in PTGeometry.piece(for: mesh) {
            let 基 = UInt32(结果.顶点.count)
            结果.顶点.append(contentsOf: 片.positions)
            结果.法线.append(contentsOf: 片.normals.count == 片.positions.count
                ? 片.normals
                : Array(repeating: SIMD3<Float>(0, 1, 0), count: 片.positions.count))
            结果.UV.append(contentsOf: 片.uvs.count == 片.positions.count
                ? 片.uvs
                : Array(repeating: SIMD2<Float>(0, 0), count: 片.positions.count))
            结果.索引.append(contentsOf: 片.indices.map { $0 + 基 })
        }
        结果.重建默认子集()
        return 结果
    }

    private static func 转换材质(_ 资产: MaterialAsset) -> 导入材质 {
        let 基色 = 资产.baseline.color(.baseColor)
        let 自发光色 = 资产.baseline.color(.emissionColor)
        let 亮度 = Float(资产.baseline.double(.emissionLuminance))
        var 结果 = 导入材质(名称: 资产.name)
        结果.基础色 = SIMD3<Float>(Float(基色.r), Float(基色.g), Float(基色.b))
        结果.金属度 = Float(资产.baseline.double(.baseMetallic))
        结果.粗糙度 = Float(资产.baseline.double(.baseRoughness))
        结果.不透明度 = Float(资产.baseline.double(.baseAlpha))
        结果.IOR = Float(资产.baseline.double(.baseIOR))
        结果.自发光 = SIMD3<Float>(
            Float(自发光色.r) * 亮度,
            Float(自发光色.g) * 亮度,
            Float(自发光色.b) * 亮度
        )
        return 结果
    }
}
