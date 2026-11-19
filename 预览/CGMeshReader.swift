import Compression
import Foundation
import simd

// MARK: - 几何块读取（与主 App 的 容器几何 二进制格式一一对应）

/// `.cgm` 单网格块。
///
/// 扩展是独立进程，链接不到主 App 的源码（也不需要），所以这里按同一份二进制
/// 规格独立实现一份只读解析：头 16B + 段表 n×16B + 16B 对齐的数据区；
/// 数据区可能整段被 LZFSE 压过（版本字最高位为标志），压过的块前面 8 字节存原长。
///
/// **段表类型字布局（必须和 容器几何 打包() 逐字对齐）**：
///   bit 16..31 = 子网格序号，bit 8..15 = 元素编码，bit 0..7 = 段类型。
/// 曾经这里按「类型 = 类型字 & 0xFFFF」读，写端一加编码字节就对不上号：
/// 法线常量段（0x0204）被当成未知类型跳过、半宽索引段（0x0306）也被跳过，
/// 结果法线全零、索引为空 → 预览变形、导入物回落 cube。改动此文件前先读上面这行注释。
struct CGMesh {
    var 名称: String = ""
    var 顶点: [SIMD3<Float>] = []
    var 法线: [SIMD3<Float>] = []
    var UV: [SIMD2<Float>] = []
    var 索引: [UInt32] = []
    var 变换: simd_float4x4 = matrix_identity_float4x4
}

enum CGMeshReader {

    private static let 头长 = 16
    private static let 段长 = 16
    private static let 压缩标志: UInt32 = 0x8000_0000
    /// 常量 / 紧凑 / 半宽 / 顺序编码一旦出现就会在版本字打这个标志，老读端据此判不兼容。
    private static let 紧凑标志: UInt32 = 0x4000_0000
    /// 本读端能认的格式版本（版本字要先把两个标志位 mask 掉再比）。
    private static let 版本: UInt32 = 1

    private enum 段类型: UInt32 {
        case 名称 = 1
        case 变换 = 2
        case 顶点 = 3
        case 法线 = 4
        case UV = 5
        case 索引 = 6
        case 子集 = 7
    }

    /// 段内元素编码，取值与 容器几何.编码 一致。
    private enum 编码: UInt32 {
        case 原始 = 0
        case 紧凑 = 1
        case 常量 = 2
        case 半宽 = 3
        case 顺序 = 4
    }

    static func 读(_ url: URL) -> [CGMesh] {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return [] }
        return 读(data)
    }

    /// 单文件容器里拿到的是整包 mmap 的切片，直接喂进来即可，不用再落一次盘
    static func 读(_ data: Data) -> [CGMesh] {
        guard data.count > 头长 else { return [] }
        // 魔数校验：不是几何块就老实返回空，绝不让扩展进程崩掉
        let 首 = data.startIndex
        guard data[首] == 0x43, data[首 + 1] == 0x47, data[首 + 2] == 0x47, data[首 + 3] == 0x45 else { return [] }
        return data.withUnsafeBytes { raw -> [CGMesh] in
            let 版本字 = raw.loadUnaligned(fromByteOffset: 8, as: UInt32.self)
            let 段数 = Int(raw.loadUnaligned(fromByteOffset: 12, as: UInt32.self))
            let 数据区 = 头长 + 段数 * 段长
            guard 段数 > 0, 数据区 <= raw.count else { return [] }
            // 版本兼容只看去掉标志位之后的值，否则新编码块会被当成「未来格式」丢掉
            guard 版本字 & ~(压缩标志 | 紧凑标志) <= 版本 else { return [] }

            // 没压：直接解析文件内存
            if 版本字 & 压缩标志 == 0 {
                return 解析体(raw)
            }

            // 压过：把「头 + 段表」原样搬到新缓冲，再把数据区解到它后面，
            // 段表里的偏移是文件绝对偏移，解析逻辑一行不用改。
            guard let 首址 = raw.baseAddress, raw.count > 数据区 + 8 else { return [] }
            let 原长 = Int(raw.loadUnaligned(fromByteOffset: 数据区, as: UInt64.self))
            guard 原长 > 0, 原长 < 1 << 31 else { return [] }
            let 总量 = 数据区 + 原长
            let 缓冲 = UnsafeMutableRawPointer.allocate(byteCount: 总量, alignment: 16)
            defer { 缓冲.deallocate() }
            缓冲.copyMemory(from: 首址, byteCount: 数据区)
            let 压流 = 首址.advanced(by: 数据区 + 8)
            let 解出 = compression_decode_buffer(
                缓冲.advanced(by: 数据区).assumingMemoryBound(to: UInt8.self), 原长,
                压流.assumingMemoryBound(to: UInt8.self), raw.count - 数据区 - 8,
                nil, COMPRESSION_LZFSE
            )
            guard 解出 == 原长 else { return [] }
            return 解析体(UnsafeRawBufferPointer(start: 缓冲, count: 总量))
        }
    }

    private static func 解析体(_ raw: UnsafeRawBufferPointer) -> [CGMesh] {
        let 段数 = Int(raw.loadUnaligned(fromByteOffset: 12, as: UInt32.self))
        guard 段数 > 0, 头长 + 段数 * 段长 <= raw.count else { return [] }

        var 名称: [Int: String] = [:]
        var 变换: [Int: simd_float4x4] = [:]
        var 顶点: [Int: [SIMD3<Float>]] = [:]
        var 法线: [Int: [SIMD3<Float>]] = [:]
        var UV: [Int: [SIMD2<Float>]] = [:]
        var 索引: [Int: [UInt32]] = [:]
        var 最大子 = 0

        for i in 0..<段数 {
            let off = 头长 + i * 段长
            let 类型字 = raw.loadUnaligned(fromByteOffset: off, as: UInt32.self)
            let 数量 = Int(raw.loadUnaligned(fromByteOffset: off + 4, as: UInt32.self))
            let 偏移64 = raw.loadUnaligned(fromByteOffset: off + 8, as: UInt64.self)
            guard 偏移64 <= UInt64(Int.max) else { continue }
            let 偏移 = Int(偏移64)
            let 子 = Int(类型字 >> 16)
            let 编码值 = (类型字 >> 8) & 0xFF
            let 类型 = 类型字 & 0xFF
            最大子 = max(最大子, 子)
            guard 偏移 >= 0, 偏移 <= raw.count else { continue }

            switch 类型 {
            case 段类型.名称.rawValue:
                let 长度 = min(数量, raw.count - 偏移)
                名称[子] = String(decoding: UnsafeRawBufferPointer(rebasing: raw[偏移..<(偏移 + 长度)]), as: UTF8.self)

            case 段类型.变换.rawValue:
                guard 偏移 + 64 <= raw.count else { continue }
                var m = matrix_identity_float4x4
                withUnsafeMutableBytes(of: &m) { dst in
                    dst.copyMemory(from: UnsafeRawBufferPointer(rebasing: raw[偏移..<(偏移 + 64)]))
                }
                变换[子] = m

            case 段类型.顶点.rawValue, 段类型.法线.rawValue:
                guard 数量 > 0, let 表 = 解三维(raw, 偏移, 数量, 编码值) else { continue }
                if 类型 == 段类型.顶点.rawValue { 顶点[子] = 表 } else { 法线[子] = 表 }

            case 段类型.UV.rawValue:
                guard 数量 > 0, let 表 = 解UV(raw, 偏移, 数量, 编码值) else { continue }
                UV[子] = 表

            case 段类型.索引.rawValue:
                guard 数量 > 0, let 表 = 解索引(raw, 偏移, 数量, 编码值) else { continue }
                索引[子] = 表

            default:
                // 子集段只服务主程序的绘制范围/材质，预览不消费，直接跳过
                continue
            }
        }

        var 结果: [CGMesh] = []
        for i in 0...max(0, 最大子) {
            guard let v = 顶点[i], !v.isEmpty else { continue }
            var m = CGMesh()
            m.名称 = 名称[i] ?? "网格 \(i + 1)"
            m.顶点 = v
            m.法线 = 修补法线(法线[i] ?? [], 顶点: v, 索引: 索引[i] ?? [])
            m.UV = UV[i] ?? []
            m.索引 = 索引[i] ?? []
            m.变换 = 变换[i] ?? matrix_identity_float4x4
            结果.append(m)
        }
        return 结果
    }

    // MARK: - 按编码解包（与 容器几何 解三维/解UV/解索引 同一套语义）

    /// 法线兜底：老文件把「不带 vn 的模型」整段写成常量法线，读回来全是同一个方向，
    /// 预览就成了一片没有明暗的死色，看着像模型碎了。数量和顶点不符或整段全同就按拓扑重算。
    private static func 修补法线(_ 法线: [SIMD3<Float>], 顶点: [SIMD3<Float>],
                            索引: [UInt32]) -> [SIMD3<Float>] {
        guard 顶点.count > 1 else { return 法线 }
        if 法线.count == 顶点.count, !全同(法线) { return 法线 }
        guard 索引.count >= 3 else { return 法线 }
        var 累计 = [SIMD3<Float>](repeating: .zero, count: 顶点.count)
        var i = 0
        while i + 2 < 索引.count {
            let a = Int(索引[i]), b = Int(索引[i + 1]), c = Int(索引[i + 2])
            i += 3
            guard a < 顶点.count, b < 顶点.count, c < 顶点.count else { continue }
            // 叉积模长即两倍面积，累加天然带面积加权
            let 面 = simd_cross(顶点[b] - 顶点[a], 顶点[c] - 顶点[a])
            累计[a] += 面
            累计[b] += 面
            累计[c] += 面
        }
        var 有结果 = false
        for k in 累计.indices where simd_length_squared(累计[k]) > 1e-12 {
            累计[k] = simd_normalize(累计[k])
            有结果 = true
        }
        return 有结果 ? 累计 : 法线
    }

    private static func 全同<T: Equatable>(_ a: [T]) -> Bool {
        guard let 首 = a.first else { return false }
        for v in a.dropFirst() where v != 首 { return false }
        return true
    }

    /// 容器切片不保证对齐，全程走 loadUnaligned；边界不够就返回 nil（该段跳过）。
    private static func 解三维(_ raw: UnsafeRawBufferPointer, _ 偏移: Int, _ 数量: Int,
                             _ 编码值: UInt32) -> [SIMD3<Float>]? {
        switch 编码值 {
        case 编码.原始.rawValue:
            guard 偏移 + 数量 * 16 <= raw.count else { return nil }
            var 表 = [SIMD3<Float>]()
            表.reserveCapacity(数量)
            for k in 0..<数量 { 表.append(raw.loadUnaligned(fromByteOffset: 偏移 + k * 16, as: SIMD3<Float>.self)) }
            return 表
        case 编码.紧凑.rawValue:
            guard 偏移 + 数量 * 12 <= raw.count else { return nil }
            var 表 = [SIMD3<Float>](repeating: .zero, count: 数量)
            for k in 0..<数量 {
                let o = 偏移 + k * 12
                表[k] = SIMD3<Float>(raw.loadUnaligned(fromByteOffset: o, as: Float.self),
                                     raw.loadUnaligned(fromByteOffset: o + 4, as: Float.self),
                                     raw.loadUnaligned(fromByteOffset: o + 8, as: Float.self))
            }
            return 表
        case 编码.常量.rawValue:
            guard 偏移 + 12 <= raw.count else { return nil }
            let v = SIMD3<Float>(raw.loadUnaligned(fromByteOffset: 偏移, as: Float.self),
                                 raw.loadUnaligned(fromByteOffset: 偏移 + 4, as: Float.self),
                                 raw.loadUnaligned(fromByteOffset: 偏移 + 8, as: Float.self))
            return [SIMD3<Float>](repeating: v, count: 数量)
        default:
            return nil
        }
    }

    private static func 解UV(_ raw: UnsafeRawBufferPointer, _ 偏移: Int, _ 数量: Int,
                            _ 编码值: UInt32) -> [SIMD2<Float>]? {
        switch 编码值 {
        case 编码.原始.rawValue:
            guard 偏移 + 数量 * 8 <= raw.count else { return nil }
            var 表 = [SIMD2<Float>]()
            表.reserveCapacity(数量)
            for k in 0..<数量 { 表.append(raw.loadUnaligned(fromByteOffset: 偏移 + k * 8, as: SIMD2<Float>.self)) }
            return 表
        case 编码.紧凑.rawValue:
            // UV 没有紧凑编码，但写端以后要加就在这里补，别让旧读端静默丢 UV
            guard 偏移 + 数量 * 8 <= raw.count else { return nil }
            var 表 = [SIMD2<Float>]()
            表.reserveCapacity(数量)
            for k in 0..<数量 { 表.append(raw.loadUnaligned(fromByteOffset: 偏移 + k * 8, as: SIMD2<Float>.self)) }
            return 表
        case 编码.常量.rawValue:
            guard 偏移 + 8 <= raw.count else { return nil }
            let v = SIMD2<Float>(raw.loadUnaligned(fromByteOffset: 偏移, as: Float.self),
                                 raw.loadUnaligned(fromByteOffset: 偏移 + 4, as: Float.self))
            return [SIMD2<Float>](repeating: v, count: 数量)
        default:
            return nil
        }
    }

    private static func 解索引(_ raw: UnsafeRawBufferPointer, _ 偏移: Int, _ 数量: Int,
                             _ 编码值: UInt32) -> [UInt32]? {
        switch 编码值 {
        case 编码.原始.rawValue:
            guard 偏移 + 数量 * 4 <= raw.count else { return nil }
            var 表 = [UInt32]()
            表.reserveCapacity(数量)
            for k in 0..<数量 { 表.append(raw.loadUnaligned(fromByteOffset: 偏移 + k * 4, as: UInt32.self)) }
            return 表
        case 编码.半宽.rawValue:
            guard 偏移 + 数量 * 2 <= raw.count else { return nil }
            var 表 = [UInt32](repeating: 0, count: 数量)
            for k in 0..<数量 { 表[k] = UInt32(raw.loadUnaligned(fromByteOffset: 偏移 + k * 2, as: UInt16.self)) }
            return 表
        case 编码.顺序.rawValue:
            // 一个字节都不在盘上：数量就是长度。防一手畸形数量把内存打爆。
            guard 数量 <= 1 << 27 else { return nil }
            return (0..<数量).map { UInt32($0) }
        default:
            return nil
        }
    }
}
