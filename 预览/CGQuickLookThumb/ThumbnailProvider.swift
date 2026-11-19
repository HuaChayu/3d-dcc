import AppKit
import Foundation
import QuickLookThumbnailing

// MARK: - Finder 缩略图（Blender 式：只读取，不渲染）
//
// 缩略图是主 App 保存工程时画好、一起写进 .cg 容器的位图块（thumbnail.png，
// 老档兼容 QuickLook/Thumbnail.png）。本扩展只做三件事：
//   打开容器 → 取那块 PNG → 原样交给系统缩放显示。
//
// 因此这里不链接 Metal / SceneKit / ModelIO，不建场景、不截图、不开渲染线程，
// 响应是毫秒级；系统调度缩略图时也不会因为建 GPU 上下文而超时。
// 空格预览（可旋转的 3D 场景）仍由 CGQuickLook 扩展负责，两者互不影响。
@objc(ThumbnailProvider)
final class ThumbnailProvider: QLThumbnailProvider {

    override func provideThumbnail(for request: QLFileThumbnailRequest,
                                   _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        guard let png = 取内嵌缩略图(项目: request.fileURL),
              let 落点 = 写出(png) else {
            handler(nil, nil)   // 老工程没存缩略图 → 交回系统默认图标，不硬造
            return
        }
        handler(QLThumbnailReply(imageFileURL: 落点), nil)
    }

    // MARK: - 从容器里取 PNG

    private func 取内嵌缩略图(项目: URL) -> Data? {
        guard let 容 = CGContainer(路径: 项目) else { return nil }
        let 签名: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        for 键 in ["thumbnail.png", "QuickLook/Thumbnail.png"] {
            guard let 切片 = 容.读(键), 切片.count > 8 else { continue }
            // 容.读 返回的是 mmap 切片，必须拷出来再交出去（容器一释放映射就没了）
            let 数据 = Data(切片)
            guard Array(数据.prefix(8)) == 签名 else { continue }
            return 数据
        }
        return nil
    }

    private func 写出(_ 数据: Data) -> URL? {
        let 落点 = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cgthumb-\(UUID().uuidString).png")
        do {
            try 数据.write(to: 落点)
            return 落点
        } catch {
            return nil
        }
    }
}
