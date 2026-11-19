import Foundation

/// 项目的「用户目录」：所有用户侧文档（缓存、自定义材质 / 角色 / 动作库）的根。
///
/// 路径固定为 `~/Documents/cg app`，`~` 在运行时展开成当前登录用户的个人目录，
/// 所以同一台机器上的不同 macOS 用户各用各的一份，互不干扰。
/// 首次启动（或用户手动删掉后再次启动）由 `准备()` 补齐缺失的根目录与子文件夹。
enum 用户目录 {

    /// 界面上展示的写法：保留 `~`，不暴露具体用户名。
    static let 显示路径 = "~/Documents/cg app"

    /// 需要存在的子文件夹（顺序即界面展示顺序）。
    static let 子目录名 = ["cache", "自定义材质库", "自定义角色库", "自定义动作库"]

    /// 展开 `~` 后的真实根路径。
    static var 根: URL {
        URL(
            fileURLWithPath: (显示路径 as NSString).expandingTildeInPath,
            isDirectory: true
        )
    }

    static var 缓存: URL { 根.appendingPathComponent("cache", isDirectory: true) }
    static var 材质库: URL { 根.appendingPathComponent("自定义材质库", isDirectory: true) }
    static var 角色库: URL { 根.appendingPathComponent("自定义角色库", isDirectory: true) }
    static var 动作库: URL { 根.appendingPathComponent("自定义动作库", isDirectory: true) }

    /// 幂等：目录已存在就什么都不做，缺哪个补哪个。
    static func 准备() {
        let fm = FileManager.default
        try? fm.createDirectory(at: 根, withIntermediateDirectories: true)
        for 名 in 子目录名 {
            try? fm.createDirectory(
                at: 根.appendingPathComponent(名, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
    }
}
