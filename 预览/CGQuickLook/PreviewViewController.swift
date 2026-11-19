import Cocoa
import Quartz
import SceneKit

// MARK: - Quick Look 预览扩展入口
//
// 这个类跑在独立的预览进程里，完全不依赖主 App 启动：
// 用户选中 .cg 工程按空格，系统直接把包丢给这里，读完 manifest + 场景参数 + 几何块，
// 现场组装成一个可拖拽旋转、滚轮缩放的 SceneKit 场景。

@objc(PreviewViewController)
final class PreviewViewController: NSViewController, QLPreviewingController {

    /// 预览底色：取自 CGSceneLoader 原有深灰渐变背景（0.16/0.17/0.20 → 0.05/0.05/0.06）的中位色。
    /// 视图底色、layer 底色、scene.background 三处全都用这一个值，
    /// 首帧出现前后画面完全同色，不会出现「底色变一下」的跳变。
    private static let 预览背景色 = NSColor(calibratedRed: 0.11, green: 0.115, blue: 0.135, alpha: 1)

    private let 三维视图 = SCNView(frame: NSRect(x: 0, y: 0, width: 900, height: 620))
    /// 系统偶尔会对同一个文件连发两次预览请求，别把整场建两遍
    private var 已处理 = false

    override func loadView() {
        // 直接把 SCNView 当根视图：从加入层级的第一刻起就铺满整块预览区、不透明、alpha = 1，
        // 没有位图垫底层、没有透明态、全程不换层，
        // 因此任何时刻都不存在「一层已消失、另一层还没画出来」的空白态。
        let 视图 = 三维视图
        视图.allowsCameraControl = true
        视图.autoenablesDefaultLighting = false
        视图.antialiasingMode = .multisampling4X
        视图.rendersContinuously = false   // 静止展示：打开就是这个聚焦画面，不自转
        视图.preferredFramesPerSecond = 30
        视图.defaultCameraController.interactionMode = .orbitTurntable
        视图.defaultCameraController.inertiaEnabled = true
        视图.defaultCameraController.automaticTarget = true

        // 不透明底色：view 背景 + layer 都设成同一个实色，且 layer 标记不透明，
        // 这样首帧还在 GPU 里跑的时候，用户看到的就是这层实色，而不是窗口底色或白闪。
        视图.backgroundColor = Self.预览背景色
        视图.wantsLayer = true
        视图.layer?.isOpaque = true
        视图.layer?.backgroundColor = Self.预览背景色.cgColor
        视图.alphaValue = 1
        视图.isHidden = false
        视图.autoresizingMask = [.width, .height]

        view = 视图
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        guard !已处理 else { handler(nil); return }
        已处理 = true

        // 一、最轻的可读性判断（解析容器索引，不建场）：读不到才报错，避免建场白跑
        let 容 = CGContainer(路径: url)
        guard 容 != nil || 有清单(url) else {
            handler(CGPreviewError.无法读取)
            return
        }

        // 二、后台建场，建完直接换成模型画面：没有位图兜底，所以可以等整场建好再回调。
        //     失败路径必须回调错误，不能永远不回调（否则空格会一直转菊花）。
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let 场景 = CGSceneLoader.构建(根: url)
            DispatchQueue.main.async {
                guard let self, let 场景 else {
                    handler(CGPreviewError.无法读取)
                    return
                }
                // CGSceneLoader 原本给场景铺的是深灰渐变，这里覆盖成与视图底色完全相同的纯色，
                // 否则首帧渲染出来的一刻底色会「纯色 → 渐变」变一下，那就是一次跳变。
                场景.background.contents = Self.预览背景色
                self.三维视图.scene = 场景
                handler(nil)
            }
        }
    }

    private func 有清单(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent("manifest.json").path)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(三维视图)
    }
}

enum CGPreviewError: LocalizedError {
    case 无法读取

    var errorDescription: String? {
        "这个 .cg 工程里没有可预览的场景数据"
    }
}
