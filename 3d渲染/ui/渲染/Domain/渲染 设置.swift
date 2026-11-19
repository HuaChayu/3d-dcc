import Foundation

// MARK: - 渲染设置

enum ToneMapping: String, Codable, CaseIterable, Identifiable, Sendable {
    case agx
    case aces
    case filmic
    case linear

    var id: String { rawValue }

    var title: String {
        switch self {
        case .agx: "AgX"
        case .aces: "ACES"
        case .filmic: "Filmic"
        case .linear: "Linear"
        }
    }
}

struct RenderSettings: Codable, Equatable {
    var width: Int = 1920
    var height: Int = 1080
    var samples: Int = 256
    var maxBounces: Int = 12
    var denoise: Bool = true
    var toneMapping: ToneMapping = .agx
    var exposure: Double = 0
    var transparentBackground: Bool = false

    static var `default`: RenderSettings { RenderSettings() }

    var aspectTitle: String { "\(width) × \(height)" }

    /// 预估耗时（演示用估算，不代表真实渲染器性能）
    var estimatedSeconds: Int {
        let pixels = Double(width * height) / (1920 * 1080)
        return max(1, Int(pixels * Double(samples) / 32.0))
    }

    mutating func applyAspect(_ w: Int, _ h: Int) {
        width = w
        height = h
    }
}

// MARK: - 渲染任务

enum RenderJobState: String, Codable, Sendable {
    case idle
    case running
    case done
    case failed

    var title: String {
        switch self {
        case .idle: "待渲染"
        case .running: "渲染中"
        case .done: "已完成"
        case .failed: "失败"
        }
    }
}

struct RenderJob: Identifiable, Codable, Equatable {
    let id: UUID
    var label: String
    var createdAt: Date
    var state: RenderJobState
    var progress: Double
    var width: Int
    var height: Int
    var seconds: Double

    init(
        id: UUID = UUID(),
        label: String,
        createdAt: Date = .now,
        state: RenderJobState = .idle,
        progress: Double = 0,
        width: Int = 1920,
        height: Int = 1080,
        seconds: Double = 0
    ) {
        self.id = id
        self.label = label
        self.createdAt = createdAt
        self.state = state
        self.progress = progress
        self.width = width
        self.height = height
        self.seconds = seconds
    }
}
