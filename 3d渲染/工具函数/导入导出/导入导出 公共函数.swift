//
//  导入导出 公共函数.swift
//  3d渲染
//
//  导入 / 导出链路共用的底层原语：小端字节读写、包围盒累加、文件名清理、目录名单、三角法线。
//  这些原先是 网格池文件 / 导出 各格式 / Blender烘焙 / 导入接入 里各写一份的，
//  合并到一处，实现逐字照搬，只做搬家不改写行为。
//

import Foundation
import simd

// MARK: - 小端字节读写（网格池文件 / STL / PLY / GLB 共用）
//
// 写：往 Data 尾部追加小端整数 / 浮点 / UUID / 矩阵 / 字符串，或整块裸数组。
// 读：从 UnsafeRawBufferPointer 按游标顺序取，游标越界返回 nil。
enum 字节 {

    // MARK: 编码细节（小端，直接 memcpy）

    static func 写(_ handle: FileHandle, _ data: Data) -> Bool {
        guard !data.isEmpty else { return true }
        do {
            try handle.write(contentsOf: data)
            return true
        } catch {
            return false
        }
    }

    static func 追加(_ into: inout Data, _ value: UInt32) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { into.append(contentsOf: $0) }
    }

    static func 追加(_ into: inout Data, _ value: Int32) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { into.append(contentsOf: $0) }
    }

    /// 按 IEEE754 位模式写，STL 的 float 三角、PLY 的 property float 都用它
    static func 追加(_ into: inout Data, _ value: Float) {
        var v = value.bitPattern.littleEndian
        withUnsafeBytes(of: &v) { into.append(contentsOf: $0) }
    }

    static func 追加(_ into: inout Data, _ id: UUID) {
        var u = id.uuid
        withUnsafeBytes(of: &u) { into.append(contentsOf: $0) }
    }

    static func 追加(_ into: inout Data, _ m: simd_float4x4) {
        var v = m
        withUnsafeBytes(of: &v) { into.append(contentsOf: $0) }
    }

    static func 追加字符串(_ into: inout Data, _ s: String) {
        let utf8 = Data(s.utf8)
        追加(&into, UInt32(utf8.count))
        into.append(utf8)
    }

    static func 裸数据(_ a: [SIMD3<Float>]) -> Data {
        guard !a.isEmpty else { return Data() }
        return a.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func 裸数据(_ a: [SIMD2<Float>]) -> Data {
        guard !a.isEmpty else { return Data() }
        return a.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func 裸数据(_ a: [UInt32]) -> Data {
        guard !a.isEmpty else { return Data() }
        return a.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    // MARK: 解码游标

    static func 读UInt32(_ raw: UnsafeRawBufferPointer, _ 游标: inout Int) -> UInt32? {
        guard 游标 + 4 <= raw.count else { return nil }
        let v = raw.loadUnaligned(fromByteOffset: 游标, as: UInt32.self)
        游标 += 4
        return UInt32(littleEndian: v)
    }

    static func 读Int32(_ raw: UnsafeRawBufferPointer, _ 游标: inout Int) -> Int32? {
        guard let u = 读UInt32(raw, &游标) else { return nil }
        return Int32(bitPattern: u)
    }

    static func 读UUID(_ raw: UnsafeRawBufferPointer, _ 游标: inout Int) -> UUID? {
        guard 游标 + 16 <= raw.count else { return nil }
        var u = uuid_t(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        withUnsafeMutableBytes(of: &u) { dst in
            dst.copyBytes(from: UnsafeRawBufferPointer(rebasing: raw[游标..<(游标 + 16)]))
        }
        游标 += 16
        return UUID(uuid: u)
    }

    static func 读矩阵(_ raw: UnsafeRawBufferPointer, _ 游标: inout Int) -> simd_float4x4? {
        guard 游标 + 64 <= raw.count else { return nil }
        var m = matrix_identity_float4x4
        withUnsafeMutableBytes(of: &m) { dst in
            dst.copyBytes(from: UnsafeRawBufferPointer(rebasing: raw[游标..<(游标 + 64)]))
        }
        游标 += 64
        return m
    }

    static func 读字符串(_ raw: UnsafeRawBufferPointer, _ 游标: inout Int) -> String? {
        guard let 长度 = 读UInt32(raw, &游标) else { return nil }
        let n = Int(长度)
        guard 游标 + n <= raw.count else { return nil }
        let bytes = UnsafeRawBufferPointer(rebasing: raw[游标..<(游标 + n)])
        let data = Data(bytes: bytes.baseAddress!, count: n)
        游标 += n
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func 读SIMD3(_ raw: UnsafeRawBufferPointer, _ 游标: inout Int, _ n: Int) -> [SIMD3<Float>]? {
        let stride = MemoryLayout<SIMD3<Float>>.stride
        guard 游标 + n * stride <= raw.count else { return nil }
        if n == 0 { return [] }
        var out = [SIMD3<Float>](repeating: .zero, count: n)
        out.withUnsafeMutableBytes { dst in
            dst.copyBytes(from: UnsafeRawBufferPointer(rebasing: raw[游标..<(游标 + n * stride)]))
        }
        游标 += n * stride
        return out
    }

    static func 读SIMD2(_ raw: UnsafeRawBufferPointer, _ 游标: inout Int, _ n: Int) -> [SIMD2<Float>]? {
        let stride = MemoryLayout<SIMD2<Float>>.stride
        guard 游标 + n * stride <= raw.count else { return nil }
        if n == 0 { return [] }
        var out = [SIMD2<Float>](repeating: .zero, count: n)
        out.withUnsafeMutableBytes { dst in
            dst.copyBytes(from: UnsafeRawBufferPointer(rebasing: raw[游标..<(游标 + n * stride)]))
        }
        游标 += n * stride
        return out
    }

    static func 读UInt32Array(_ raw: UnsafeRawBufferPointer, _ 游标: inout Int, _ n: Int) -> [UInt32]? {
        guard 游标 + n * 4 <= raw.count else { return nil }
        if n == 0 { return [] }
        var out = [UInt32](repeating: 0, count: n)
        out.withUnsafeMutableBytes { dst in
            dst.copyBytes(from: UnsafeRawBufferPointer(rebasing: raw[游标..<(游标 + n * 4)]))
        }
        游标 += n * 4
        return out
    }
}

// MARK: - 包围盒累加
//
// 导入接入的整包摆放、导入导出调度里的归一化尺寸、GLB 访问器的 min/max、
// 网格库的局部包围球，原先各自手写「最小初始化为 greatestFiniteMagnitude」，
// 空集时会把结果算成无限大再靠 guard 兜回来。这里统一一份。
struct 包围盒累加 {

    private(set) var 最小 = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
    private(set) var 最大 = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)

    /// 一个点都没加过时，最小仍大于最大
    var 空: Bool { 最小.x > 最大.x }

    mutating func 加(_ 点: SIMD3<Float>) {
        最小 = simd_min(最小, 点)
        最大 = simd_max(最大, 点)
    }

    mutating func 加(_ 盒: (最小: SIMD3<Float>, 最大: SIMD3<Float>)) {
        self.最小 = simd_min(self.最小, 盒.最小)
        self.最大 = simd_max(self.最大, 盒.最大)
    }

    mutating func 加点们(_ 点们: [SIMD3<Float>]) {
        for 点 in 点们 { 加(点) }
    }

    /// 空集返回 nil，调用方照原来的 guard 写法跳过即可
    var 盒: (最小: SIMD3<Float>, 最大: SIMD3<Float>)? {
        空 ? nil : (最小, 最大)
    }

    var 尺寸: SIMD3<Float>? { 盒.map { $0.最大 - $0.最小 } }

    var 中心: SIMD3<Float>? { 盒.map { ($0.最小 + $0.最大) * 0.5 } }
}

// MARK: - 文件名 / 材质名清理
//
// 导出的 OBJ / usda 名字，和 Blender 烘焙的材质图名，禁字符集合不同、
// 空段处理也不同，所以拼串逻辑共用，禁集与兜底名由调用方给。
enum 文件名清理 {

    /// 把禁字符换成下划线。去空段 = true 时连续禁字符会压成一个下划线。
    /// 结果为空时用兜底名，保证文件名不会变成空串。
    static func 替换非法字符(_ 原: String,
                              禁: CharacterSet,
                              去空段: Bool = true,
                              兜底: String) -> String {
        var 段 = 原.components(separatedBy: 禁)
        if 去空段 {
            段 = 段.filter { !$0.isEmpty }
        }
        let 结果 = 段.joined(separator: "_")
        return 结果.isEmpty ? 兜底 : 结果
    }
}

// MARK: - 目录名单

enum 目录名单 {

    /// 列目录里的条目名，列不动就当空目录（调用方全部按「没有就用空数组」处理）
    static func 读(_ 目录: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: 目录.path)) ?? []
    }
}

// MARK: - 三角几何

enum 三角几何 {

    /// 三点叉积归一后的面法线；退化三角返回零向量（STL 二进制里三个分量要照写）
    static func 法线(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>,
                    退化: SIMD3<Float> = SIMD3(0, 1, 0),
                    阈值: Float = 1e-20) -> SIMD3<Float> {
        let n = simd_cross(b - a, c - a)
        let 长 = simd_length(n)
        return 长 > 阈值 ? n / 长 : 退化
    }
}
