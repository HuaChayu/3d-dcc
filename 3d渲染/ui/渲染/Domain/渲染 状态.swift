import Foundation
import Observation

/// 渲染工作区状态：输出设置与渲染队列。
/// 队列进度为演示流程（Task 推进），未接真实光线追踪渲染器。
@Observable
final class 渲染Store {

    var render: RenderSettings = .default
    var renderJobs: [RenderJob] = []

    /// 材质名来源（着色域）弱引用，仅读取
    weak var shading: 着色Store?

    /// 数据变更 → 根 Store 落盘
    var onChange: (() -> Void)?
    var onNote: ((String) -> Void)?

    var isRendering: Bool { renderJobs.contains { $0.state == .running } }

    func note(_ message: String) { onNote?(message) }

    // MARK: 队列

    func enqueueRender() {
        guard let material = shading?.activeMaterial else { return }
        let job = RenderJob(
            label: "\(material.name) · \(render.aspectTitle)",
            state: .idle,
            width: render.width,
            height: render.height
        )
        renderJobs.insert(job, at: 0)
        onChange?()
    }

    func startRender(_ jobID: UUID) {
        guard let index = renderJobs.firstIndex(where: { $0.id == jobID }) else { return }
        guard renderJobs[index].state != .running else { return }
        renderJobs[index].state = .running
        renderJobs[index].progress = 0
        note("渲染中（演示流程）")

        let total = max(0.8, Double(render.jobsEstimate))
        Task { @MainActor [weak self] in
            let steps = 40
            for step in 1...steps {
                try? await Task.sleep(for: .milliseconds(Int(total / Double(steps) * 1000)))
                guard let self, let idx = self.renderJobs.firstIndex(where: { $0.id == jobID }) else { return }
                self.renderJobs[idx].progress = Double(step) / Double(steps)
            }
            guard let self, let idx = self.renderJobs.firstIndex(where: { $0.id == jobID }) else { return }
            self.renderJobs[idx].state = .done
            self.renderJobs[idx].seconds = total
            self.note("渲染完成（演示，不含真实光线追踪）")
            self.onChange?()
        }
    }

    func clearRenderHistory() {
        renderJobs.removeAll { $0.state == .done }
        onChange?()
    }

    // MARK: 载入 / 重置

    func load(from snapshot: ProjectSnapshot) {
        render = snapshot.render
        renderJobs = snapshot.renderJobs
    }

    /// 构造「出厂基础场景」的渲染域：默认输出设置 + 默认队列，不带上次的渲染历史。
    func 载入基础场景() {
        render = .default
        renderJobs = 初始项目.renderJobs()
    }
}

extension RenderSettings {
    /// 演示用的进度时长（秒）
    var jobsEstimate: Int { max(1, estimatedSeconds / 12) }
}
