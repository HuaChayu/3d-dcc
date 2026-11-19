//
//  网格池.swift
//  3d渲染
//
//  导入网格的运行时池（UUID → 一组子网格）+ 它的二进制落盘格式。
//  合并自「导入网格库 / 网格池文件」，只做搬家，类型名与函数名未改。
//  小端字节读写原语在「导入导出 公共函数.swift」里，本文件里已改为 字节.xxx 调用。
//

import Foundation
import simd
import RealityKit

// MARK: - 运行时池（原 导入网格库.swift）

// MARK: - 导入网格运行时池

/// `SceneObject.mesh` 只能表达那 6 个程序化形体，外部模型来的几何没地方放。
/// 这里开一个「UUID → 一组子网格」的池子，SceneObject 只记一个 ID，
/// 视口 / 拾取 / 绘画 / 路径追踪四处都从这里取几何。
///
/// 加锁而不是标 @MainActor：路径追踪转译跑在后台队列，用 actor 会把整条转译链
/// 拖成 async，改动面太大；一个 NSLock 足够，取出来的都是值类型快照。
final class 导入网格库: @unchecked Sendable {
    /// 只给几何域用：网格池是几何域的私有存储，外部一律经 几何接线.共享 访问，
    /// 名字故意不叫 shared —— 谁在这里写 .域内部 就是绕过了唯一所有者。
    static let 域内部 = 导入网格库()

    private let 锁 = NSLock()
    private var 池: [UUID: [导入网格]] = [:]

    /// 每块几何的内容版本号。
    ///
    /// 用途只有一个：给「保存时的 SHA256 缓存」当输入判据。凡是改写池里某块内容的
    /// 入口（存入 / 恢复 / 移除后再存）都必须换一个新号，否则缓存会拿着旧哈希当新内容。
    /// 号只增不减、永不复用，宁可多算一次哈希，也不给出一个可误判的相同值。
    private var 版本: [UUID: UInt64] = [:]
    private var 版本序列: UInt64 = 0

    private func 新版本() -> UInt64 {
        版本序列 += 1
        return 版本序列
    }

    private init() {}

    /// 存入一组网格，返回 SceneObject 要记的 ID
    @discardableResult
    func 存入(_ 网格集: [导入网格]) -> UUID {
        let id = UUID()
        锁.lock()
        池[id] = 网格集
        版本[id] = 新版本()
        锁.unlock()
        // 池变了才写二进制，普通参数调整完全不碰这里
        网格池写盘.shared.标脏()
        return id
    }

    func 取(_ id: UUID) -> [导入网格]? {
        锁.lock()
        defer { 锁.unlock() }
        return 池[id]
    }

    func 存在(_ id: UUID) -> Bool {
        锁.lock()
        defer { 锁.unlock() }
        return 池[id] != nil
    }

    /// 某块几何当前的内容版本号（0 表示池里没有这块）。
    ///
    /// 视图层拿它当实体缓存的签名：打开工程时物体列表可能和上一份逐字相同，
    /// 只按「id + mesh + 可见性」判缓存会跳过重建，而几何是随后才恢复进池的 ——
    /// 视口就会一直挂着前面那次生成的 cube 占位实体。版本号在 存入 / 恢复 时递增，
    /// 所以几何一变签名必变，重建一定会发生。
    func 版本号(_ id: UUID) -> UInt64 {
        锁.lock()
        defer { 锁.unlock() }
        return 版本[id] ?? 0
    }

    /// 池里现有全部网格标识（只读，不复制顶点；只给几何域的引用回收轮询用）
    func 全部标识() -> [UUID] {
        锁.lock()
        defer { 锁.unlock() }
        return Array(池.keys)
    }

    func 移除(_ id: UUID) {
        锁.lock()
        池.removeValue(forKey: id)
        版本[id] = nil
        锁.unlock()
        网格池写盘.shared.标脏()
    }

    /// 存档：把整个池拍一份值快照出去（值类型，出去的副本与池解耦）
    func 快照() -> [UUID: [导入网格]] {
        锁.lock()
        defer { 锁.unlock() }
        return 池
    }

    /// 快照 + 每块的内容版本：一次加锁同时拿到，保证两者严格对齐
    /// （分两次取会出现「池已经是新内容、版本还是旧号」的错位）。
    func 快照与版本() -> (池: [UUID: [导入网格]], 版本: [UUID: UInt64]) {
        锁.lock()
        defer { 锁.unlock() }
        return (池, 版本)
    }

    /// 读档：整体覆盖。池是纯运行时结构，不参与增量合并，覆盖最不容易出错。
    /// 覆盖后每块都换新版本号：内容来自磁盘，与内存里缓存过的哈希一律不许复用。
    func 恢复(_ 表: [UUID: [导入网格]]) {
        锁.lock()
        池 = 表
        版本 = 表.keys.reduce(into: [UUID: UInt64]()) { 结果, id in
            结果[id] = 新版本()
        }
        锁.unlock()
    }

    /// 按当前场景里还在用的 ID 清池，避免连开几次大模型把内存吃满
    func 保留(_ ids: Set<UUID>) {
        锁.lock()
        池 = 池.filter { ids.contains($0.key) }
        锁.unlock()
        网格池写盘.shared.标脏()
    }

    var 占用条目数: Int {
        锁.lock()
        defer { 锁.unlock() }
        return 池.count
    }

    var 总三角形数: Int {
        锁.lock()
        defer { 锁.unlock() }
        return 池.values.reduce(0) { $0 + $1.reduce(0) { $0 + $1.三角形数 } }
    }

    /// 世界包围球（网格已烘焙成局部形状，直接按物体 TRS 变换一个中心即可）
    func 局部包围球(_ id: UUID) -> (中心: SIMD3<Float>, 半径: Float)? {
        guard let 网格集 = 取(id), !网格集.isEmpty else { return nil }
        var 累加 = 包围盒累加()
        for 网格 in 网格集 {
            累加.加点们(网格.顶点)
        }
        guard let 盒 = 累加.盒, let 中心 = 累加.中心 else { return nil }
        let 半径 = max(simd_length(盒.最大 - 中心), 0.001)
        return (中心, 半径)
    }
}

// MARK: - 转 RealityKit

extension 导入网格库 {

    /// 视口实体。多个子网格各出一份 MeshDescriptor，RealityKit 会合成一个
    /// 带多 part 的 MeshResource，正好对应模型的多个材质区间。
    /// - Parameter 替身: 摆好姿势的几何。给角色部件用：池里那份额外存的是静止形状，
    ///   变形后每动一下都是一份新顶点，所以由调用方算好传进来，池里的数据始终不动。
    func 生成实体(_ id: UUID, 名称: String, 替身: [导入网格]? = nil) -> Entity? {
        guard let 网格集 = 替身 ?? 取(id), !网格集.isEmpty else {
            print("⚠️ 网格库取不到数据：\(名称)")
            return nil
        }

        var 描述们: [MeshDescriptor] = []
        for 网格 in 网格集 {
            guard !网格.顶点.isEmpty, !网格.索引.isEmpty else { continue }
            var 描述 = MeshDescriptor(name: 网格.名称)
            描述.positions = MeshBuffers.Positions(网格.顶点)

            let 法线 = 网格.法线.count == 网格.顶点.count
                ? 网格.法线
                : Array(repeating: SIMD3<Float>(0, 1, 0), count: 网格.顶点.count)
            描述.normals = MeshBuffers.Normals(法线)

            let UV = 网格.UV.count == 网格.顶点.count
                ? 网格.UV
                : Array(repeating: SIMD2<Float>(0, 0), count: 网格.顶点.count)
            描述.textureCoordinates = MeshBuffers.TextureCoordinates(UV)

            描述.primitives = .triangles(网格.索引)
            描述们.append(描述)
        }
        // 逐子网格单独试生成：一个子集坏掉不连坐整身，失败原因直接打控制台
        var 好的: [MeshDescriptor] = []
        for 描述 in 描述们 {
            do {
                _ = try MeshResource.generate(from: [描述])
                好的.append(描述)
            } catch {
                print("⚠️ 子网格「\(描述.name)」生成失败：\(error)｜顶点 \(描述.positions.count)")
            }
        }
        guard !好的.isEmpty else {
            // 兜底：去掉 UV / 法线，只留位置 + 三角形，先保证能看见人形
            var 裸们: [MeshDescriptor] = []
            for 网格 in 网格集 where !网格.顶点.isEmpty && !网格.索引.isEmpty {
                var 裸 = MeshDescriptor(name: 网格.名称)
                裸.positions = MeshBuffers.Positions(网格.顶点)
                裸.primitives = .triangles(网格.索引)
                裸们.append(裸)
            }
            if !裸们.isEmpty, let 简 = try? MeshResource.generate(from: 裸们) {
                print("⚠️ 全部子网格失败，已退化为纯位置几何：\(名称)（\(裸们.count) 块）")
                let 实体 = ModelEntity(mesh: 简)
                实体.name = 名称
                return 实体
            }
            print("⚠️ 全部子网格都失败，放弃：\(描述们.map(\.name))")
            return nil
        }

        var 资源: MeshResource
        do {
            let 合体 = try MeshResource.generate(from: 好的)
            资源 = 合体
        } catch {
            print("⚠️ 多 part 合成失败（\(好的.count) 个子网格）：\(error)")
            guard let 单体 = 好的.first,
                  let 单资源 = try? MeshResource.generate(from: [单体]) else { return nil }
            资源 = 单资源
        }
        print("✅ 网格「\(名称)」：\(好的.count)/\(描述们.count) 子网格，包围盒 \(资源.bounds)")

        let 实体 = ModelEntity(mesh: 资源)
        实体.name = 名称
        return 实体
    }
}

// MARK: - 转路径追踪

extension 导入网格库 {

    /// PT 用三份平行数组。UV 缺失时补零（PaintUV 会按需重算参数化 UV）。
    func 转PT片段(_ id: UUID) -> [PTGeometry.Piece] {
        guard let 网格集 = 取(id) else { return [] }
        return 网格集.compactMap { 网格 in
            guard !网格.顶点.isEmpty, !网格.索引.isEmpty else { return nil }
            var 片 = PTGeometry.Piece()
            片.positions = 网格.顶点
            片.normals = 网格.法线.count == 网格.顶点.count
                ? 网格.法线
                : Array(repeating: SIMD3<Float>(0, 1, 0), count: 网格.顶点.count)
            片.uvs = 网格.UV.count == 网格.顶点.count
                ? 网格.UV
                : Array(repeating: SIMD2<Float>(0, 0), count: 网格.顶点.count)
            片.indices = 网格.索引
            return 片
        }
    }

    /// 拾取用的扁平三角形列表（每 3 个点一组）
    func 三角点列(_ id: UUID) -> [SIMD3<Float>] {
        guard let 网格集 = 取(id) else { return [] }
        var 输出: [SIMD3<Float>] = []
        输出.reserveCapacity(网格集.reduce(0) { $0 + $1.索引.count })
        for 网格 in 网格集 {
            let n = 网格.索引.count - 网格.索引.count % 3
            var i = 0
            while i < n {
                let a = 网格.索引[i], b = 网格.索引[i + 1], c = 网格.索引[i + 2]
                guard Int(a) < 网格.顶点.count, Int(b) < 网格.顶点.count, Int(c) < 网格.顶点.count else {
                    i += 3
                    continue
                }
                输出.append(网格.顶点[Int(a)])
                输出.append(网格.顶点[Int(b)])
                输出.append(网格.顶点[Int(c)])
                i += 3
            }
        }
        return 输出
    }
}

// MARK: - 二进制落盘（原 网格池文件.swift）

// MARK: - 导入网格池的二进制落盘
//
// 为什么单独存：
// 顶点/法线/UV/索引是纯数字，塞进 project.3dpj 的 JSON 里会被编码成 base64
// 文本，446 MB 的池光编码就要几百毫秒，而且每次改参数都要重编一遍。
// 这里按裸数组写盘（Float32 / UInt32），只在导入、删除模型时才写，
// 普通参数调整只写几十 KB 的 project.3dpj，主线程再也不碰大块数据。
//
// 文件格式（小端）：
//   魔数 "3DMB"(4B) + 版本 UInt32(=1) + 条目数 UInt32
//   条目：UUID(16B) + 子网格数 UInt32
//   子网格：
//     名称长度 UInt32 + UTF8
//     变换 4×SIMD4<Float>(64B)
//     顶点数 / 法线数 / UV 数 / 索引数 / 子集数（各 UInt32）
//     顶点块（SIMD3<Float> 按 stride 16B） / 法线块 / UV 块（stride 8B） / 索引块（UInt32）
//     子集：材质 Int32（-1 = 无）+ 起始 Int32 + 数量 Int32 + 材质名长度 UInt32 + UTF8
enum 网格池文件 {
    static let 魔数 = Data("3DMB".utf8)
    static let 版本: UInt32 = 1

    static var 文件: URL {
        LocalStore.存档目录.appendingPathComponent("meshpool.3dmb")
    }

    static var 存在: Bool {
        FileManager.default.fileExists(atPath: 文件.path)
    }

    // MARK: 写

    @discardableResult
    static func 写出(_ 池: [UUID: [导入网格]]) -> Bool {
        let url = 文件
        let 临时 = url.appendingPathExtension("tmp")
        guard FileManager.default.createFile(atPath: 临时.path, contents: nil) else { return false }
        guard let handle = try? FileHandle(forWritingTo: 临时) else { return false }

        var 头 = 魔数
        字节.追加(&头, 版本)
        字节.追加(&头, UInt32(池.count))
        guard 字节.写(handle, 头) else { try? handle.close(); return false }

        for (id, 网格集) in 池 {
            var 条目头 = Data()
            字节.追加(&条目头, id)
            字节.追加(&条目头, UInt32(网格集.count))
            guard 字节.写(handle, 条目头) else { try? handle.close(); return false }

            for 网格 in 网格集 {
                var 小头 = Data()
                字节.追加字符串(&小头, 网格.名称)
                字节.追加(&小头, 网格.变换)
                字节.追加(&小头, UInt32(网格.顶点.count))
                字节.追加(&小头, UInt32(网格.法线.count))
                字节.追加(&小头, UInt32(网格.UV.count))
                字节.追加(&小头, UInt32(网格.索引.count))
                字节.追加(&小头, UInt32(网格.子集.count))
                guard 字节.写(handle, 小头) else { try? handle.close(); return false }

                guard 字节.写(handle, 字节.裸数据(网格.顶点)),
                      字节.写(handle, 字节.裸数据(网格.法线)),
                      字节.写(handle, 字节.裸数据(网格.UV)),
                      字节.写(handle, 字节.裸数据(网格.索引)) else { try? handle.close(); return false }

                var 子集块 = Data()
                for 子集 in 网格.子集 {
                    字节.追加(&子集块, Int32(子集.材质 ?? -1))
                    字节.追加(&子集块, Int32(clamping: 子集.起始))
                    字节.追加(&子集块, Int32(clamping: 子集.数量))
                    字节.追加字符串(&子集块, 子集.材质名 ?? "")
                }
                if !子集块.isEmpty, !字节.写(handle, 子集块) { try? handle.close(); return false }
            }
        }

        try? handle.close()

        // 原子替换，避免写一半崩溃留下坏文件
        // 首次写盘目标还不存在，replaceItemAt 会失败，要走 move
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: 临时)
            } else {
                try FileManager.default.moveItem(at: 临时, to: url)
            }
            return true
        } catch {
            try? FileManager.default.removeItem(at: 临时)
            return false
        }
    }

    // MARK: 读

    static func 载入() -> [UUID: [导入网格]]? {
        guard let data = try? Data(contentsOf: 文件), data.count > 12 else { return nil }
        return data.withUnsafeBytes { raw -> [UUID: [导入网格]]? in
            guard raw.count > 12, Data(raw.prefix(4)) == 魔数 else { return nil }
            var 游标 = 4
            guard let 版 = 字节.读UInt32(raw, &游标), 版 == 版本 else { return nil }
            guard let 条目数 = 字节.读UInt32(raw, &游标) else { return nil }

            var 池: [UUID: [导入网格]] = [:]
            池.reserveCapacity(Int(条目数))

            for _ in 0..<条目数 {
                guard let id = 字节.读UUID(raw, &游标),
                      let 网格数 = 字节.读UInt32(raw, &游标) else { return nil }
                var 网格集: [导入网格] = []
                网格集.reserveCapacity(Int(网格数))

                for _ in 0..<网格数 {
                    guard let 名称 = 字节.读字符串(raw, &游标),
                          let 变换 = 字节.读矩阵(raw, &游标),
                          let 顶点数 = 字节.读UInt32(raw, &游标),
                          let 法线数 = 字节.读UInt32(raw, &游标),
                          let UV数 = 字节.读UInt32(raw, &游标),
                          let 索引数 = 字节.读UInt32(raw, &游标),
                          let 子集数 = 字节.读UInt32(raw, &游标) else { return nil }

                    guard let 顶点 = 字节.读SIMD3(raw, &游标, Int(顶点数)),
                          let 法线 = 字节.读SIMD3(raw, &游标, Int(法线数)),
                          let UV = 字节.读SIMD2(raw, &游标, Int(UV数)),
                          let 索引 = 字节.读UInt32Array(raw, &游标, Int(索引数)) else { return nil }

                    var 网格 = 导入网格(名称: 名称)
                    网格.顶点 = 顶点
                    网格.法线 = 法线
                    网格.UV = UV
                    网格.索引 = 索引
                    网格.变换 = 变换

                    var 子集们: [导入子集] = []
                    子集们.reserveCapacity(Int(子集数))
                    for _ in 0..<子集数 {
                        guard let 材质 = 字节.读Int32(raw, &游标),
                              let 起始 = 字节.读Int32(raw, &游标),
                              let 数量 = 字节.读Int32(raw, &游标),
                              let 材质名 = 字节.读字符串(raw, &游标) else { return nil }
                        子集们.append(导入子集(
                            材质: 材质 < 0 ? nil : Int(材质),
                            起始: Int(起始),
                            数量: Int(数量),
                            材质名: 材质名.isEmpty ? nil : 材质名
                        ))
                    }
                    网格.子集 = 子集们
                    网格集.append(网格)
                }
                池[id] = 网格集
            }
            return 池
        }
    }

}

// MARK: - 脏标记写盘
//
// 网格池只在「导入模型 / 删除模型」时才变，且变一次可能 400 MB，
// 这里只记「池和磁盘不一致」，真正落盘交给手动保存（⌘S）/ 另存为 / 自动保护文件。
// 导入或删除模型时绝不再自己写主工程文件。
final class 网格池写盘 {
    static let shared = 网格池写盘()

    private init() {}

    /// 只置脏标记：几何池变了不等于可以偷偷写主文件。
    /// 调用点都在主线程的导入/删除路径上，转发到主队列统一走 AppStore 的脏状态。
    func 标脏() {
        DispatchQueue.main.async {
            LocalStore.主App?.标记脏()
        }
    }

    /// 显式落盘：只在手动保存 / 自动保护文件这类明确路径上调用。
    func 立即写盘(到 root: URL) {
        项目容器.只写几何(几何接线.共享.快照(), 到: root)
    }
}
