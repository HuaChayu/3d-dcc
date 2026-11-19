import Foundation

// MARK: - 诊断

struct GraphDiagnostic: Identifiable {
    enum Level: String {
        case info
        case warning
        case error

        var symbol: String {
            switch self {
            case .info: "info.circle"
            case .warning: "exclamationmark.triangle"
            case .error: "xmark.octagon"
            }
        }
    }

    let id = UUID()
    var level: Level
    var message: String
}

// MARK: - 求值结果

struct GraphEvaluation {
    var overrides: [PBRParamKey: PBRValue]
    var diagnostics: [GraphDiagnostic]
    var cycleDetected: Bool = false

    var drivenCount: Int { overrides.count }
}

// MARK: - 求值器

/// OpenPBR Output 的输入端口是节点图的唯一汇点：
/// 求值 = 从 Output 的每个输入口向上游递归拉取，得到该参数的最终值。
/// 没连线的口不产生 override，材质就用基线值——与 OpenPBR "未连接使用默认值"的语义一致。
enum NodeGraphEvaluator {

    /// 首版近似：视口不做逐像素图求值。纹理节点在固定 UV 上采样一次，
    /// 等价于把整张图烘焙成 1×1 贴图。真正的逐像素烘焙在 Roadmap 里。
    static let sampleU = 0.37
    static let sampleV = 0.61

    static func evaluate(_ graph: NodeGraph) -> GraphEvaluation {
        var diagnostics: [GraphDiagnostic] = []
        guard let output = graph.outputNode else {
            return GraphEvaluation(
                overrides: [:],
                diagnostics: [GraphDiagnostic(level: .error, message: "图里没有「OpenPBR 输出」节点，材质只能使用基线参数")]
            )
        }

        var cache: [UUID: [String: PBRValue]] = [:]
        var visiting: Set<UUID> = []
        var cycle = false
        var textureNodes: Set<UUID> = []

        func fallback(_ kind: SocketKind) -> PBRValue {
            kind == .color ? .color(.black) : .scalar(0)
        }

        func coerce(_ value: PBRValue, to kind: SocketKind) -> PBRValue {
            if kind == .color, case .scalar(let v) = value {
                return .color(PBRColor(gray: v))
            }
            return value
        }

        func outputs(of nodeID: UUID) -> [String: PBRValue] {
            if let cached = cache[nodeID] { return cached }
            guard let node = graph.node(nodeID) else { return [:] }

            if visiting.contains(nodeID) {
                cycle = true
                var safe: [String: PBRValue] = [:]
                for socket in node.kind.outputs { safe[socket.id] = fallback(socket.kind) }
                return safe
            }
            visiting.insert(nodeID)
            defer { visiting.remove(nodeID) }

            if node.kind.category == .texture { textureNodes.insert(nodeID) }

            var inputs: [String: PBRValue] = [:]
            for socket in node.kind.inputs {
                if let link = graph.link(into: nodeID, socket: socket.id) {
                    let upstream = outputs(of: link.fromNode)
                    let upstreamKind = graph.node(link.fromNode)?.kind.outputs.first { $0.id == link.fromSocket }?.kind ?? socket.kind
                    if let value = upstream[link.fromSocket] {
                        if !socket.kind.accepts(upstreamKind) {
                            diagnostics.append(GraphDiagnostic(
                                level: .warning,
                                message: "\(node.displayTitle) · \(socket.title) 收到不兼容类型（\(upstreamKind.title) → \(socket.kind.title)）"
                            ))
                        }
                        inputs[socket.id] = coerce(value, to: socket.kind)
                        continue
                    }
                }
                inputs[socket.id] = coerce(node.value(for: socket.id), to: socket.kind)
            }

            let result = compute(node: node, inputs: inputs, muted: node.isMuted)
            cache[nodeID] = result
            return result
        }

        var overrides: [PBRParamKey: PBRValue] = [:]
        for link in graph.links where link.toNode == output.id {
            guard let key = PBRParamKey(rawValue: link.toSocket) else { continue }
            let upstream = outputs(of: link.fromNode)
            guard let raw = upstream[link.fromSocket] else { continue }
            overrides[key] = key.isColor ? .color(raw.colorValue) : .scalar(raw.scalarValue)
        }

        if overrides.isEmpty {
            diagnostics.append(GraphDiagnostic(
                level: .info,
                message: "输出节点上没有连线，全部参数走基线值"
            ))
        }
        if !textureNodes.isEmpty {
            diagnostics.append(GraphDiagnostic(
                level: .info,
                message: "\(textureNodes.count) 个程序纹理节点按固定 UV（\(String(format: "%.2f", sampleU)), \(String(format: "%.2f", sampleV))）采样单值，视口不做逐像素烘焙"
            ))
        }
        if cycle {
            diagnostics.append(GraphDiagnostic(level: .error, message: "检测到环状连接，已用 0 值截断"))
        }

        return GraphEvaluation(overrides: overrides, diagnostics: diagnostics, cycleDetected: cycle)
    }

    // MARK: 单节点计算

    private static func compute(
        node: ShaderNode,
        inputs: [String: PBRValue],
        muted: Bool
    ) -> [String: PBRValue] {
        if muted {
            // Mute 的节点等价于直通：颜色口传灰、标量口传 0
            var passthrough: [String: PBRValue] = [:]
            for socket in node.kind.outputs {
                passthrough[socket.id] = socket.kind == .color ? .color(PBRColor(gray: 0.5)) : .scalar(0)
            }
            return passthrough
        }

        func scalar(_ key: String) -> Double {
            inputs[key]?.scalarValue ?? node.value(for: key).scalarValue
        }

        func color(_ key: String) -> PBRColor {
            inputs[key]?.colorValue ?? node.value(for: key).colorValue
        }

        switch node.kind {
        case .output:
            return inputs

        case .rgbConstant:
            return ["out": .color(node.value(for: "color").colorValue)]

        case .valueConstant:
            return ["out": .scalar(node.value(for: "value").scalarValue)]

        case .imageTexture:
            // 图真值由视口/离线渲染器采样，这里只给"整图平均色"兜底，
            // 保证没有采样通路的地方（如节点预览、签名降级）也是这张图的颜色而不是灰
            return ["out": .color(color("tint"))]

        case .checkerTexture:
            let scale = max(scalar("scale"), 1)
            let cell = Int(floor(sampleU * scale)) + Int(floor(sampleV * scale))
            let picked = cell % 2 == 0 ? color("colorA") : color("colorB")
            return ["out": .color(picked)]

        case .noiseTexture:
            let scale = max(scalar("scale"), 0.001)
            let n = valueNoise(x: sampleU * scale, y: sampleV * scale, detail: scalar("detail"))
            let a = color("colorA")
            let b = color("colorB")
            return [
                "out": .scalar(n),
                "outColor": .color(a.mixed(b, n))
            ]

        case .gradientMap:
            let fac = min(max(scalar("fac"), 0), 1)
            return ["out": .color(color("colorA").mixed(color("colorB"), fac))]

        case .mix:
            let fac = min(max(scalar("fac"), 0), 1)
            return [
                "out": .color(color("a").mixed(color("b"), fac)),
                "outFac": .scalar(fac)
            ]

        case .hueSaturation:
            let source = color("color")
            let shifted = source.hueRotated(scalar("hue"))
                .saturated(max(scalar("sat"), 0))
                .lightened(scalar("light"))
            return ["out": .color(shifted.clamped)]

        case .remap:
            let value = scalar("value")
            let fromMin = scalar("fromMin")
            let fromMax = scalar("fromMax")
            let toMin = scalar("toMin")
            let toMax = scalar("toMax")
            let span = fromMax - fromMin
            let t = span == 0 ? 0 : (value - fromMin) / span
            return ["out": .scalar(toMin + (toMax - toMin) * t)]

        case .fresnel:
            // F0 = ((n-1)/(n+1))^2，正对视角的反射率。真正的角度项需要逐像素法线。
            let ior = max(scalar("ior"), 1.0)
            let f0 = pow((ior - 1) / (ior + 1), 2)
            let bias = scalar("bias")
            let value = min(max(f0 + bias, 0), 1)
            return [
                "out": .scalar(value),
                "outColor": .color(PBRColor(gray: value))
            ]

        case .bump:
            let height = min(max(scalar("height"), 0), 1)
            let strength = min(max(scalar("strength"), 0), 1)
            let fac = height * strength
            return [
                "out": .scalar(fac),
                "outColor": .color(PBRColor(gray: fac))
            ]
        }
    }

    // MARK: 值噪声

    private static func hash(_ x: Double, _ y: Double) -> Double {
        let s = sin(x * 127.1 + y * 311.7) * 43758.5453
        return s - floor(s)
    }

    private static func valueNoise(x: Double, y: Double, detail: Double) -> Double {
        let octaves = max(Int(detail.rounded()), 1)
        var total = 0.0
        var amplitude = 1.0
        var frequency = 1.0
        var norm = 0.0
        for _ in 0..<octaves {
            let px = x * frequency
            let py = y * frequency
            let x0 = floor(px)
            let y0 = floor(py)
            let fx = px - x0
            let fy = py - y0
            let ux = fx * fx * (3 - 2 * fx)
            let uy = fy * fy * (3 - 2 * fy)
            let a = hash(x0, y0)
            let b = hash(x0 + 1, y0)
            let c = hash(x0, y0 + 1)
            let d = hash(x0 + 1, y0 + 1)
            let top = a + (b - a) * ux
            let bottom = c + (d - c) * ux
            total += (top + (bottom - top) * uy) * amplitude
            norm += amplitude
            amplitude *= 0.5
            frequency *= 2
        }
        return norm == 0 ? 0 : total / norm
    }
}
