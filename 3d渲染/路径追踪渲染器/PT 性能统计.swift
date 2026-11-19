import Foundation
import Observation

// MARK: - 视口性能面板

/// 视口左上角性能面板的数据源：路径追踪渲染器写入，SwiftUI 直接读。
///
/// 只放"用户需要知道"的指标，内部诊断打点（转译/加速结构/最慢帧）不往这儿塞。
/// 刷新节奏跟随渲染器：每帧记录、自适应节流推送瞬时值（30Hz~10Hz，随帧耗时收紧），
/// 拖动时数值和画面同步跳。不做 60Hz 全速写 —— 那会让 SwiftUI 每帧重排一次字。
@Observable
final class PT性能统计 {
    static let shared = PT性能统计()

    /// 画面刷新率：按统计窗口的真实耗时算（不是 MTKView 的标称帧率）
    var 帧率: Double = 0
    /// 主线程一帧 draw 的 CPU 用时
    var CPU毫秒: Double = 0
    /// 一帧内所有命令缓冲在 GPU 上的执行跨度（追踪 + 降噪 + 呈现）
    var GPU毫秒: Double = 0
    /// OIDN 降噪这一段
    var 降噪毫秒: Double = 0
    /// 内部渲染分辨率（交互期会低于窗口分辨率）
    var 宽度: Int = 0
    var 高度: Int = 0
    /// 累积样本 / 目标样本
    var 样本: Int = 0
    var 样本上限: Int = 0
    /// 是否处于交互窗口（拖动中）
    var 交互中 = false
    /// 拿到过真实数据之前不显示面板，免得一进来全是 0
    var 有效 = false

    private init() {}

    func 提交(帧率: Double,
             CPU毫秒: Double,
             GPU毫秒: Double,
            降噪毫秒: Double,
             宽度: Int,
             高度: Int,
             样本: Int,
             样本上限: Int,
             交互中: Bool) {
        self.帧率 = 帧率
        self.CPU毫秒 = CPU毫秒
        self.GPU毫秒 = GPU毫秒
        self.降噪毫秒 = 降噪毫秒
        self.宽度 = 宽度
        self.高度 = 高度
        self.样本 = 样本
        self.样本上限 = 样本上限
        self.交互中 = 交互中
        self.有效 = true
    }

    /// 退出路径追踪时清掉，避免下次进来先闪一眼上次的旧数字
    func 清空() {
        guard 有效 else { return }
        有效 = false
        帧率 = 0
        CPU毫秒 = 0
        GPU毫秒 = 0
        降噪毫秒 = 0
        宽度 = 0
        高度 = 0
        样本 = 0
        样本上限 = 0
        交互中 = false
    }
}
