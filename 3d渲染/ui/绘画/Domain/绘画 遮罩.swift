import AppKit
import Foundation
import Metal
import SwiftUI

/// 笔刷形状遮罩。
///
/// 一张灰度图，1 = 笔刷在这一像素上生效：
/// - 绘画模式：图里的白色才上色 → 笔迹自带纹理（破布的经纬、裂纹、噪点）
/// - 镂空模式：图里的白色被挖掉 → 在表面上"抠"出破洞、磨损缺口
///
/// 图案全部在 CPU 端程序生成（固定种子，可复现），同一份灰度数据同时喂给
/// GPU 纹理和面板缩略图，两边永远一致，不依赖任何外部图片资源。
enum PaintMaskKind: String, CaseIterable, Identifiable, Sendable {
    case 无 = "无"
    case 圆斑 = "圆斑"
    case 破布 = "破布"
    case 裂纹 = "裂纹"
    case 噪点 = "噪点"
    case 斜纹 = "斜纹"

    var id: String { rawValue }

    /// 遮罩分辨率。256 够细（破洞边缘不会糊成马赛克），生成一次也就几十毫秒
    static let 边长 = 256

    // MARK: 像素生成

    /// 0...255 灰度，行优先（y * 边长 + x）
    func 生成像素() -> [UInt8] {
        let n = Self.边长
        var out = [UInt8](repeating: 255, count: n * n)

        switch self {
        case .无:
            return out

        case .圆斑:
            for y in 0..<n {
                for x in 0..<n {
                    let u = (Float(x) + 0.5) / Float(n) * 2 - 1
                    let v = (Float(y) + 0.5) / Float(n) * 2 - 1
                    let r = (u * u + v * v).squareRoot()
                    // 边缘留一圈软过渡，笔刷在斜面上不至于出现硬台阶
                    let a = 1 - 平滑(0.55, 1.0, r)
                    out[y * n + x] = 灰度(a)
                }
            }

        case .破布:
            // 大块不规则破洞 + 高频纤维毛边：低频决定洞的形状，高频把边缘啃碎
            let seed: UInt32 = 0x1F35_A7C1
            for y in 0..<n {
                for x in 0..<n {
                    let fx = Float(x) / Float(n)
                    let fy = Float(y) / Float(n)
                    let 大 = fbm(fx, fy, 频率: 4, 层数: 3, seed: seed)
                    let 细 = fbm(fx, fy, 频率: 32, 层数: 2, seed: seed &+ 77)
                    // 大块噪声过阈值成为洞，细噪声在边界把值推来推去 → 参差边缘
                    let t = 大 + (细 - 0.5) * 0.22
                    let a = 平滑(0.46, 0.58, t)
                    out[y * n + x] = 灰度(a)
                }
            }

        case .裂纹:
            // 若干条随机折线当裂纹骨架，取到折线的最短距离做笔迹宽度
            var rng = 小随机(种子: 0xC0FF_EE11)
            var 段: [(SIMD2<Float>, SIMD2<Float>)] = []
            let 条数 = 9
            for _ in 0..<条数 {
                var p = SIMD2<Float>(rng.下一个(), rng.下一个())
                let 折数 = 3 + Int(rng.下一个() * 3)
                for _ in 0..<折数 {
                    let 角 = rng.下一个() * 6.2832
                    let 长 = 0.12 + rng.下一个() * 0.28
                    let q = p + SIMD2<Float>(cos(角), sin(角)) * 长
                    段.append((p, q))
                    p = q
                }
            }
            for y in 0..<n {
                for x in 0..<n {
                    let pt = SIMD2<Float>((Float(x) + 0.5) / Float(n), (Float(y) + 0.5) / Float(n))
                    var 最近: Float = 9
                    for (a, b) in 段 {
                        let ab = b - a
                        let 长2 = max(ab.x * ab.x + ab.y * ab.y, 1e-6)
                        let t = max(0, min(1, ((pt.x - a.x) * ab.x + (pt.y - a.y) * ab.y) / 长2))
                        let dx = pt.x - (a.x + ab.x * t)
                        let dy = pt.y - (a.y + ab.y * t)
                        最近 = min(最近, (dx * dx + dy * dy).squareRoot())
                    }
                    // 0.006 ≈ 1.5px 线宽，外圈 0.02 做晕边
                    let a = 1 - 平滑(0.006, 0.022, 最近)
                    out[y * n + x] = 灰度(a)
                }
            }

        case .噪点:
            var rng = 小随机(种子: 0x51ED_2701)
            for i in 0..<(n * n) {
                out[i] = rng.下一个() > 0.52 ? 255 : 0
            }

        case .斜纹:
            for y in 0..<n {
                for x in 0..<n {
                    // 周期数按「一个笔刷直径内约 10 条」定：太密的话笔刷在屏幕上只有几十像素，
                    // 条纹全被采样糊成一个平均色，看起来就像没有图案
                    let s = (Float(x) * 0.72 + Float(y) * 0.72) * 0.17
                    let v = sin(s) * 0.5 + 0.5
                    // 阈值化，留给绘画/镂空两侧一点过渡
                    out[y * n + x] = 灰度(平滑(0.38, 0.52, v))
                }
            }
        }
        return out
    }

    // MARK: 面板缩略图

    /// 缓存键带上尺寸：面板要 128（缩放 3 倍也不糊），视口光标要 256，
    /// 同一张图案只按尺寸各生成一次
    @MainActor private static var 缩略缓存: [String: NSImage] = [:]

    private var 缓存键前缀: String { rawValue }

    /// 面板上的方形缩略图。带缓存 —— 面板每帧重算 body，不能每次都跑一遍噪声
    @MainActor
    func 缩略图(_ 尺寸: Int = 64) -> NSImage? {
        let 键 = "\(缓存键前缀)_\(尺寸)"
        if let 有 = Self.缩略缓存[键] { return 有 }
        let n = Self.边长
        let 像素 = 生成像素()
        var rgba = [UInt8](repeating: 0, count: n * n * 4)
        for i in 0..<(n * n) {
            let v = 像素[i]
            rgba[i * 4 + 0] = v
            rgba[i * 4 + 1] = v
            rgba[i * 4 + 2] = v
            rgba[i * 4 + 3] = 255
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let cg = CGImage(
                width: n, height: n,
                bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: n * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider, decode: nil,
                shouldInterpolate: 尺寸 < n,
                intent: .defaultIntent
              ) else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: 尺寸, height: 尺寸))
        Self.缩略缓存[键] = img
        return img
    }

    // MARK: 小工具

    private func 灰度(_ a: Float) -> UInt8 {
        UInt8(max(0, min(1, a)) * 255)
    }

    private func 平滑(_ 起: Float, _ 止: Float, _ x: Float) -> Float {
        let t = max(0, min(1, (x - 起) / max(止 - 起, 1e-6)))
        return t * t * (3 - 2 * t)
    }

    /// 确定性伪随机，保证每次生成的图案完全一样（撤销回放才复用得上）
    private struct 小随机 {
        var 状态: UInt64
        init(种子: UInt64) { 状态 = 种子 &* 2862933555777941757 &+ 3037000493 }
        mutating func 下一个() -> Float {
            状态 = 状态 &* 6364136223846793005 &+ 1442695040888963407
            let x = (状态 >> 40) & 0xFFFFFF
            return Float(x) / Float(0xFFFFFF)
        }
    }

    @inline(__always)
    private func 哈希(_ i: Int, _ j: Int, _ seed: UInt32) -> Float {
        var h = UInt32(truncatingIfNeeded: i &* 374_761_393 &+ j &* 668_265_263) &+ seed
        h = (h ^ (h >> 13)) &* 1_274_126_177
        h = h ^ (h >> 16)
        return Float(h & 0xFFFFFF) / Float(0xFFFFFF)
    }

    /// 值噪声：双线性 + smoothstep 插值，够糊也够快
    private func 噪声(_ x: Float, _ y: Float, _ seed: UInt32) -> Float {
        let xi = Int(floor(x)), yi = Int(floor(y))
        let fx = x - Float(xi), fy = y - Float(yi)
        let sx = fx * fx * (3 - 2 * fx)
        let sy = fy * fy * (3 - 2 * fy)
        let a = 哈希(xi, yi, seed)
        let b = 哈希(xi + 1, yi, seed)
        let c = 哈希(xi, yi + 1, seed)
        let d = 哈希(xi + 1, yi + 1, seed)
        return (a + (b - a) * sx) + ((c + (d - c) * sx) - (a + (b - a) * sx)) * sy
    }

    private func fbm(_ x: Float, _ y: Float, 频率: Float, 层数: Int, seed: UInt32) -> Float {
        var 和: Float = 0, 幅: Float = 0.5, 总: Float = 0
        var f = 频率
        for i in 0..<层数 {
            let p = SIMD2<Float>(x * f, y * f)
            // 每层平移一下，避免各层格点对齐出现规则网格
            和 += 噪声(p.x + Float(i) * 17.3, p.y + Float(i) * 9.7, seed &+ UInt32(i) &* 101) * 幅
            总 += 幅
            幅 *= 0.5
            f *= 2
        }
        return 总 > 0 ? 和 / 总 : 0
    }
}

/// 遮罩预览的反转：SwiftUI 的 colorInvert() 不带参数，只能按条件包一层
/// （面板缩略图和视口光标里的预览共用，别各写一份）
struct 遮罩反转修饰: ViewModifier {
    let 开: Bool

    func body(content: Content) -> some View {
        if 开 {
            content.colorInvert()
        } else {
            content
        }
    }
}

extension View {
    func 遮罩反转(_ 开: Bool) -> some View { modifier(遮罩反转修饰(开: 开)) }
}
