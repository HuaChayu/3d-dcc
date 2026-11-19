import Foundation
import Compression

/// 容器大块数据的压缩通道。
///
/// 用系统自带的 Compression 框架里的 LZFSE：零依赖、解压速度约 zlib 的 2~3 倍，
/// 压缩率还略优。全部走裸指针，不产生中间 Data。
enum 块压缩 {

    /// 版本字最高位当压缩标志，低 31 位仍是版本号 —— 老解析器读到会直接拒绝，不会误读。
    static let 标志: UInt32 = 0x8000_0000

    /// 小于这个尺寸不值得压：帧头开销 + 解压一次 memcpy 比省下的空间贵。
    static let 阈值 = 256 * 1024

    /// 压缩块前面这 8 个字节放原始长度 —— LZFSE 的流式头不带长度，必须自己存。
    static let 头长 = 8

    /// 压缩一段裸内存。返回「8 字节原长 + 压缩流」，调用方负责和原尺寸比较要不要采用。
    static func 压(_ 源: UnsafeRawPointer, 长度: Int) -> Data? {
        guard 长度 > 0 else { return nil }
        let 上限 = 长度 + 长度 / 8 + 4096
        var 输出 = [UInt8](repeating: 0, count: 上限 + 头长)
        var 原长 = UInt64(长度)
        let 结果: Int = 输出.withUnsafeMutableBytes { out -> Int in
            guard let 首址 = out.baseAddress else { return 0 }
            首址.storeBytes(of: 原长, toByteOffset: 0, as: UInt64.self)
            let 目标 = 首址.advanced(by: 头长).assumingMemoryBound(to: UInt8.self)
            return compression_encode_buffer(目标, 上限,
                                            源.assumingMemoryBound(to: UInt8.self), 长度,
                                            nil, COMPRESSION_LZFSE)
        }
        guard 结果 > 0 else { return nil }
        return Data(输出[0..<(结果 + 头长)])
    }

    /// 压缩块里存的原始长度。
    static func 原始长度(_ 压缩块: UnsafeRawPointer) -> Int? {
        let n = 压缩块.load(fromByteOffset: 0, as: UInt64.self)
        guard n > 0, n <= UInt64(Int.max) else { return nil }
        return Int(n)
    }

    /// 直接解到调用方给的目标里，返回实际解压字节数（失败 0）。
    /// 目标用 UnsafeMutableRawPointer.allocate 分配 —— 少一次 250MB 级别的中间拷贝。
    static func 解压到(_ 压缩块: UnsafeRawPointer, _ 长度: Int,
                    目标: UnsafeMutableRawPointer, 容量: Int) -> Int {
        guard 长度 > 头长 else { return 0 }
        let n = compression_decode_buffer(目标.assumingMemoryBound(to: UInt8.self), 容量,
                                         压缩块.advanced(by: 头长).assumingMemoryBound(to: UInt8.self),
                                         长度 - 头长,
                                         nil, COMPRESSION_LZFSE)
        return n
    }
}
