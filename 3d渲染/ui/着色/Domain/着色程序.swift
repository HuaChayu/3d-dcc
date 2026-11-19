import Foundation

// MARK: - 指令

/// 逐像素求值指令。
///
/// 口径是栈机：编译时按「操作数逆序」压栈，执行时按正序弹出，
/// 于是源码里写的 a、b、fac 就是执行器里读出来的顺序，两边不用各自记反序规则。
enum 着色指令: Equatable, Hashable {
    case 推色(Int)          // 颜色常量池下标
    case 推数(Int)          // 标量常量池下标
    case 采样(Int)          // 贴图槽下标
    case 混合               // a b fac
    case 相乘               // a b
    case 色相饱和度         // color hue sat light
    case 重映射             // value fromMin fromMax toMin toMax
    case 棋盘格             // scale a b
    case 噪波(取颜色: Bool) // scale detail a b
    case 菲涅尔             // ior bias
    case 亮度               // color -> 数值
}

// MARK: - 程序

/// 节点图在某个颜色参数上的完整求值。
///
/// 所有节点都编译进这一份程序：图像采样、棋盘格、噪波、渐变、混合、色相饱和度、重映射、
/// 菲涅尔、凹凸都是指令 + 常量 + 贴图槽，谁夹在谁中间、连了几层都不影响执行。
/// 视口烘焙、路径追踪、节点卡片预览都只认这一份东西。
struct 着色程序: Equatable {
    var 指令: [着色指令] = []
    var 颜色: [PBRColor] = []
    var 标量: [Double] = []
    var 贴图: [UUID] = []
    /// 编译时经过的节点。卡片预览靠它判断「这张图最终喂给了哪个输出参数」
    var 路径: Set<UUID> = []

    var 依赖贴图: Bool { !贴图.isEmpty }

    /// 是否必须逐像素生成（结果随 uv 变）。不依赖 uv 的程序可以折成常量，省一次烘焙。
    var 逐像素: Bool {
        指令.contains {
            switch $0 {
            case .采样, .棋盘格, .噪波: true
            default: false
            }
        }
    }

    /// 派生图缓存键：指令序列 + 常量 + 贴图槽一起决定结果，全部写进键里才不会串图。
    var 键: String {
        var s = 指令.map { String(describing: $0) }.joined(separator: ";")
        s += "|" + 颜色.map { String(format: "%.6f,%.6f,%.6f", $0.r, $0.g, $0.b) }.joined(separator: ";")
        s += "|" + 标量.map { String(format: "%.6f", $0) }.joined(separator: ";")
        s += "|" + 贴图.map(\.uuidString).joined(separator: ";")
        return s
    }

    /// 沿一条 uv 求值。采样回调按贴图槽给颜色，烘焙器负责把槽换成真实像素。
    func 求值(u: Double, v: Double, 采样: (Int) -> PBRColor) -> PBRColor {
        var 栈: [PBRColor] = []
        栈.reserveCapacity(指令.count + 8)
        func 弹() -> PBRColor { 栈.popLast() ?? PBRColor(gray: 0) }

        for 条 in 指令 {
            switch 条 {
            case .推色(let k):
                栈.append(k < 颜色.count ? 颜色[k] : PBRColor(gray: 0))

            case .推数(let k):
                栈.append(PBRColor(gray: k < 标量.count ? 标量[k] : 0))

            case .采样(let s):
                栈.append(采样(s))

            case .混合:
                let a = 弹()
                let b = 弹()
                let fac = 弹()
                栈.append(a.mixed(b, min(max(fac.r, 0), 1)))

            case .相乘:
                let a = 弹()
                let b = 弹()
                栈.append(PBRColor(a.r * b.r, a.g * b.g, a.b * b.b))

            case .色相饱和度:
                let base = 弹()
                let hue = 弹()
                let sat = 弹()
                let light = 弹()
                栈.append(
                    base.hueRotated(hue.r)
                        .saturated(max(sat.r, 0))
                        .lightened(light.r)
                        .clamped
                )

            case .重映射:
                let value = 弹()
                let fromMin = 弹()
                let fromMax = 弹()
                let toMin = 弹()
                let toMax = 弹()
                let span = fromMax.r - fromMin.r
                let t = span == 0 ? 0 : (value.r - fromMin.r) / span
                栈.append(PBRColor(gray: toMin.r + (toMax.r - toMin.r) * t))

            case .棋盘格:
                let scale = 弹()
                let a = 弹()
                let b = 弹()
                let sc = max(scale.r, 1)
                let cell = Int(floor(u * sc)) + Int(floor(v * sc))
                栈.append(cell % 2 == 0 ? a : b)

            case .噪波(let 取颜色):
                let scale = 弹()
                let detail = 弹()
                let a = 弹()
                let b = 弹()
                let sc = max(scale.r, 0.001)
                let n = 噪波.值(x: u * sc, y: v * sc, detail: detail.r)
                栈.append(取颜色 ? a.mixed(b, n) : PBRColor(gray: n))

            case .菲涅尔:
                let ior = 弹()
                let bias = 弹()
                // F0 = ((n-1)/(n+1))²，正对视角的反射率；逐像素的角度项要法线，颜色通路里没有
                let n = max(ior.r, 1)
                let f0 = pow((n - 1) / (n + 1), 2)
                栈.append(PBRColor(gray: min(max(f0 + bias.r, 0), 1)))

            case .亮度:
                let c = 弹()
                栈.append(PBRColor(gray: c.luminance))
            }
        }
        return 栈.last ?? PBRColor(gray: 0)
    }
}

// MARK: - 噪波（与节点求值同源，任何一侧改了另一侧必须一起改）

enum 噪波 {
    static func 哈希(_ x: Double, _ y: Double) -> Double {
        let s = sin(x * 127.1 + y * 311.7) * 43758.5453
        return s - floor(s)
    }

    static func 值(x: Double, y: Double, detail: Double) -> Double {
        let 层数 = max(Int(detail.rounded()), 1)
        var 总 = 0.0
        var 幅 = 1.0
        var 频 = 1.0
        var 归一 = 0.0
        for _ in 0..<层数 {
            let px = x * 频
            let py = y * 频
            let x0 = floor(px)
            let y0 = floor(py)
            let fx = px - x0
            let fy = py - y0
            let ux = fx * fx * (3 - 2 * fx)
            let uy = fy * fy * (3 - 2 * fy)
            let a = 哈希(x0, y0)
            let b = 哈希(x0 + 1, y0)
            let c = 哈希(x0, y0 + 1)
            let d = 哈希(x0 + 1, y0 + 1)
            let top = a + (b - a) * ux
            let bottom = c + (d - c) * ux
            总 += (top + (bottom - top) * uy) * 幅
            归一 += 幅
            幅 *= 0.5
            频 *= 2
        }
        return 归一 == 0 ? 0 : 总 / 归一
    }
}

// MARK: - 编译器

/// 节点图 -> 着色程序。
///
/// 这里只做一件事：把「某个节点的某个输出口」按后序展开成指令。
/// 每个节点类型在这张表里出现且只出现一次，给出它用哪条算子、参数谁先谁后；
/// 不存在「这个节点能不能进贴图通路」的判断，连成什么样就编成什么样。
enum 节点图编译器 {

    /// 编译输出节点某个颜色参数上的完整求值。返回 nil = 这个口上没有连线，走基线参数。
    static func 编译(_ graph: NodeGraph, 参数: PBRParamKey) -> 着色程序? {
        guard let output = graph.outputNode,
              let link = graph.link(into: output.id, socket: 参数.rawValue)
        else { return nil }
        var 构建 = 构建器()
        guard 构建.编译口(graph, 节点: link.fromNode, 口: link.fromSocket, 期望: 参数.isColor ? .color : .scalar)
        else { return nil }
        guard !构建.程序.指令.isEmpty else { return nil }
        return 构建.程序
    }

    /// 单个节点自己的输出口（卡片预览用）。只编译这一棵子树。
    static func 编译节点(_ graph: NodeGraph, 节点 id: UUID, 口 socket: String) -> 着色程序? {
        var 构建 = 构建器()
        guard 构建.编译口(graph, 节点: id, 口: socket, 期望: .color) else { return nil }
        guard !构建.程序.指令.isEmpty else { return nil }
        return 构建.程序
    }

    // MARK: 构建器

    private struct 构建器 {
        var 程序 = 着色程序()
        var 正在: Set<UUID> = []
        var 深度 = 0

        mutating func 推色(_ c: PBRColor) {
            if let i = 程序.颜色.firstIndex(of: c) {
                程序.指令.append(.推色(i))
                return
            }
            程序.颜色.append(c)
            程序.指令.append(.推色(程序.颜色.count - 1))
        }

        mutating func 推数(_ v: Double) {
            if let i = 程序.标量.firstIndex(of: v) {
                程序.指令.append(.推数(i))
                return
            }
            程序.标量.append(v)
            程序.指令.append(.推数(程序.标量.count - 1))
        }

        mutating func 压默认(_ kind: SocketKind) {
            switch kind {
            case .color: 推色(PBRColor(gray: 0.5))
            case .scalar: 推数(0)
            }
        }

        /// 压一个输入口：连了线就编上游，没连线就压节点自己的值。
        mutating func 输入(_ graph: NodeGraph, _ node: ShaderNode, _ socketID: String) -> Bool {
            let 口 = node.kind.inputs.first { $0.id == socketID }
            let kind = 口?.kind ?? .scalar
            if let link = graph.link(into: node.id, socket: socketID) {
                return 编译口(graph, 节点: link.fromNode, 口: link.fromSocket, 期望: kind)
            }
            switch kind {
            case .color: 推色(node.value(for: socketID).colorValue)
            case .scalar: 推数(node.value(for: socketID).scalarValue)
            }
            return true
        }

        /// 按「执行器读取顺序」压一组输入口：列表第一个是执行器第一个弹出的（栈顶）。
        /// 读顺序必须和上方 求值 里的 弹() 顺序逐字对齐，否则参数会错位。
        mutating func 输入逆序(_ graph: NodeGraph, _ node: ShaderNode, _ socketIDs: [String]) -> Bool {
            for id in socketIDs.reversed() {
                if !输入(graph, node, id) { return false }
            }
            return true
        }

        mutating func 编译口(_ graph: NodeGraph, 节点 id: UUID, 口 socket: String, 期望: SocketKind) -> Bool {
            guard 深度 < 64 else { return false }
            guard let node = graph.node(id) else { return false }

            let 本口 = node.kind.outputs.first { $0.id == socket }
            let 目标 = 本口?.kind ?? 期望

            if 正在.contains(id) {
                // 环：断在这里给个中性值，图本身由 UI 拦，编译不能跟着死
                压默认(目标)
                return true
            }
            if node.isMuted {
                // 静音等价于直通：颜色给中性灰、数值给 0
                压默认(目标)
                return true
            }

            正在.insert(id)
            深度 += 1
            defer {
                正在.remove(id)
                深度 -= 1
            }
            程序.路径.insert(id)

            switch node.kind {
            case .output:
                压默认(目标)

            case .rgbConstant:
                推色(node.value(for: "color").colorValue)

            case .valueConstant:
                推数(node.value(for: "value").scalarValue)

            case .imageTexture:
                // 真图逐像素采样；没有图就退成节点里存的中性色
                guard let image = node.image else {
                    压默认(目标)
                    return true
                }
                if let i = 程序.贴图.firstIndex(of: image) {
                    程序.指令.append(.采样(i))
                } else {
                    程序.贴图.append(image)
                    程序.指令.append(.采样(程序.贴图.count - 1))
                }

            case .checkerTexture:
                guard 输入逆序(graph, node, ["scale", "colorA", "colorB"]) else { return false }
                程序.指令.append(.棋盘格)

            case .noiseTexture:
                guard 输入逆序(graph, node, ["scale", "detail", "colorA", "colorB"]) else { return false }
                程序.指令.append(.噪波(取颜色: 目标 == .color))

            case .gradientMap:
                guard 输入逆序(graph, node, ["colorA", "colorB", "fac"]) else { return false }
                程序.指令.append(.混合)

            case .mix:
                if socket == "outFac" {
                    guard 输入(graph, node, "fac") else { return false }
                } else {
                    guard 输入逆序(graph, node, ["a", "b", "fac"]) else { return false }
                    程序.指令.append(.混合)
                }

            case .hueSaturation:
                guard 输入逆序(graph, node, ["color", "hue", "sat", "light"]) else { return false }
                程序.指令.append(.色相饱和度)

            case .remap:
                guard 输入逆序(graph, node, ["value", "fromMin", "fromMax", "toMin", "toMax"]) else { return false }
                程序.指令.append(.重映射)

            case .fresnel:
                guard 输入逆序(graph, node, ["ior", "bias"]) else { return false }
                程序.指令.append(.菲涅尔)

            case .bump:
                guard 输入逆序(graph, node, ["height", "strength"]) else { return false }
                程序.指令.append(.相乘)
            }

            // 往数值口里塞颜色时按亮度取，跟 PBRValue.scalarValue 同口径
            if 期望 == .scalar, 目标 == .color {
                程序.指令.append(.亮度)
            }
            return true
        }
    }
}
