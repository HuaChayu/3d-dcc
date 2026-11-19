import AppKit
import Foundation
import Metal
import SceneKit

// MARK: - QuickLook 缩略图

/// 生成容器内的 `thumbnail.png`。
///
/// Finder 的 QuickLook 对 bundle 目录不会自己去渲染，它只认包里这张图。
/// 所以这里用一次极轻的 CPU 光栅化画出「场景俯视分布」：已知物体的位置与包围盒
/// 都在快照里，画成色块 + 底部工程名，足够在 Finder 里一眼认出是哪个项目，
/// 又不用启动 Metal、不用等路径追踪出图。
enum 容器缩略图 {

    static let 边长 = 512

    static func 生成(快照: ProjectSnapshot) -> Data? {
        let size = CGFloat(边长)
        guard let ctx = CGContext(
            data: nil,
            width: 边长,
            height: 边长,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // 背景：深灰渐变，和 App 视口同色调
        let colors = [
            CGColor(red: 0.10, green: 0.11, blue: 0.13, alpha: 1),
            CGColor(red: 0.04, green: 0.04, blue: 0.05, alpha: 1),
        ] as CFArray
        if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: colors,
                                 locations: [0, 1]) {
            ctx.drawLinearGradient(grad,
                                   start: CGPoint(x: 0, y: size),
                                   end: CGPoint(x: 0, y: 0),
                                   options: [])
        }

        // 地网格：给一点空间感
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.06))
        ctx.setLineWidth(1)
        for i in stride(from: 0, through: Int(size), by: 32) {
            ctx.move(to: CGPoint(x: CGFloat(i), y: 0))
            ctx.addLine(to: CGPoint(x: CGFloat(i), y: size))
            ctx.move(to: CGPoint(x: 0, y: CGFloat(i)))
            ctx.addLine(to: CGPoint(x: size, y: CGFloat(i)))
        }
        ctx.strokePath()

        // 物体：按 XZ 投影散点，颜色取材质名哈希，尺寸取缩放
        let objects = 快照.objects
        if !objects.isEmpty {
            let xs = objects.map { $0.position.x }
            let zs = objects.map { $0.position.z }
            let minX = xs.min() ?? -1, maxX = xs.max() ?? 1
            let minZ = zs.min() ?? -1, maxZ = zs.max() ?? 1
            let spanX = max(maxX - minX, 0.001)
            let spanZ = max(maxZ - minZ, 0.001)

            for o in objects {
                let nx = CGFloat((o.position.x - minX) / spanX)
                let nz = CGFloat((o.position.z - minZ) / spanZ)
                let cx = 60 + nx * (size - 120)
                let cy = 90 + nz * (size - 200)
                let r = CGFloat(max(6, min(28, o.scale.x * 12)))
                let hue = CGFloat(abs(o.name.hashValue % 360)) / 360
                let color = NSColor(hue: hue, saturation: 0.55, brightness: 0.9, alpha: 0.85)
                ctx.setFillColor(color.cgColor ?? CGColor(gray: 1, alpha: 1))
                ctx.fillEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
            }
        }

        // 底部：工程摘要
        let 标题 = "\(objects.count) 物体 · \(快照.materials.count) 材质"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 20, weight: .medium),
            .foregroundColor: NSColor(white: 1, alpha: 0.72),
        ]
        let text = NSAttributedString(string: 标题, attributes: attrs)
        let line = CTLineCreateWithAttributedString(text)
        ctx.textPosition = CGPoint(x: 40, y: 28)
        CTLineDraw(line, ctx)

        guard let image = ctx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: 聚焦取景（和空格预览同一套技术）

    /// 用**和空格预览完全相同的代码路径**出图：
    /// `CGSceneLoader.构建` 读容器 → 同一个包围球聚焦机位（FOV 40、略俯视、不自转）
    /// → `SCNRenderer` 离屏渲一张方图。
    ///
    /// 所以 Finder 图标 / 缩略图 / 空格预览首帧看到的是同一个画面，不存在两套取景。
    /// 只在这里渲染，扩展那边依旧只读位图（缩略图扩展跑在受 SIP 保护的进程里，不能碰 GPU）。
    ///
    /// - Parameters:
    ///   - 容器: 已经落盘完整的 .cg 单文件
    ///   - 像素: 输出边长，默认 512（Finder 图标上限就是这个尺寸，再大只是白占体积、拖慢保存）
    static func 渲染聚焦(容器: URL, 像素: Int = 512) -> Data? {
        guard let 场景 = CGSceneLoader.构建(根: 容器) else { return nil }
        guard let 设备 = MTLCreateSystemDefaultDevice() else { return nil }

        let 渲染器 = SCNRenderer(device: 设备, options: nil)
        渲染器.scene = 场景
        var 相机: SCNNode?
        场景.rootNode.enumerateChildNodes { n, _ in
            if n.camera != nil, 相机 == nil { 相机 = n }
        }
        渲染器.pointOfView = 相机
        渲染器.autoenablesDefaultLighting = false

        // 方图：包围球半径已经保证任意方向都装得下，不会横向裁切
        let 图 = 渲染器.snapshot(atTime: 0,
                             with: CGSize(width: 像素, height: 像素),
                             antialiasingMode: .multisampling4X)
        guard let tiff = 图.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
