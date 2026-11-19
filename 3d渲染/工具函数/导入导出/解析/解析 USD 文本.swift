import Foundation
import simd

/// .usda 文本格式原生解析。
/// 只做「几何 + 层级变换 + 顶轴/米制」这三件 DCC 导入真正要的事；
/// 组合（references / subLayers / variants / instancing）只做识别与报告，不做展开 ——
/// 展开需要 USD 运行时（usdcat），那属于 Blender / usdview 的活，纯 Swift 里假装支持只会静默丢东西。
enum USD文本解析: 网格格式解析器 {

    static func 解析(url: URL, 设置: 单文件导入设置) throws -> 导入场景 {
        guard let 文本 = try? String(contentsOf: url, encoding: .utf8) else {
            throw 导入导出错误.文件不可读(url)
        }
        var 场景 = 导入场景(源文件: url)

        var 词法 = 词法器(文本: 文本)
        let 标记 = 词法.运行()
        var 解析 = 解析器(标记: 标记)
        let 根 = 解析.运行()

        // 顶层元数据
        var 文件上轴: 上轴 = .y
        if let s = 根.元数据["upAxis"], case .串(let v) = s {
            文件上轴 = v.uppercased() == "Z" ? .z : .y
        }
        var 米制 = 1.0
        if let m = 根.元数据["metersPerUnit"], case .数(let v) = m, v > 0 {
            米制 = 设置.采用米制换算 ? v : 1
        }
        let 生效上轴 = 设置.源上轴 ?? 文件上轴
        场景.文件上轴 = 文件上轴
        if 生效上轴 != 文件上轴 {
            场景.报告.append("顶轴按用户覆盖：文件声明 \(文件上轴.标题)，按 \(生效上轴.标题) 处理")
        }

        var 网格计数 = 0
        var 已报告组合: Set<String> = []

        func 遍历(_ 节点: 节点, 父变换: simd_double4x4, 父路径: String) {
            let 路径 = 父路径 + "/" + 节点.名
            var 变换 = 父变换 * 节点.变换矩阵()

            if let 说明 = 节点.组合说明(), !已报告组合.contains(说明) {
                已报告组合.insert(说明)
                场景.报告.append(说明)
            }

            if let 网格 = 节点.生成网格(路径: 路径) {
                var 输出 = 网格
                输出.变换 = simd_float4x4(变换)   // double → float 见文件末尾扩展
                场景.网格.append(输出)
                网格计数 += 1
            }

            for 子 in 节点.子 { 遍历(子, 父变换: 变换, 父路径: 路径) }
            _ = 变换
        }

        let 根变换 = simd_double4x4(1)
        for 顶层 in 根.顶层 {
            遍历(顶层, 父变换: 根变换, 父路径: "")
        }

        guard !场景.网格.isEmpty else {
            throw 导入导出错误.无有效几何(url)
        }
        场景.报告.insert("usda：\(网格计数) 个 Mesh prim，metersPerUnit=\(米制)", at: 0)
        return 场景
    }
}

// MARK: - 值

private enum USD值 {
    case 数(Double)
    case 元组([Double])
    case 数组([USD值])
    case 串(String)
    case 标识(String)

    /// 拍平成 double 序列 + 每项分量数
    func 数值() -> (平铺: [Double], 分量: Int) {
        switch self {
        case .数(let v): return ([v], 1)
        case .元组(let v): return (v, max(v.count, 1))
        case .数组(let 项):
            var 平铺: [Double] = []
            var 分量 = 1
            for t in 项 {
                let (v, c) = t.数值()
                分量 = max(分量, c)
                平铺.append(contentsOf: v)
            }
            return (平铺, 分量)
        case .串, .标识:
            return ([], 1)
        }
    }

    func 三元组列表() -> [SIMD3<Double>] {
        let (平, 分量) = 数值()
        guard 分量 >= 3, 平.count >= 3 else { return [] }
        var 输出: [SIMD3<Double>] = []
        输出.reserveCapacity(平.count / 分量)
        var i = 0
        while i + 分量 - 1 < 平.count {
            输出.append(SIMD3(平[i], 平[i + 1], 平[i + 2]))
            i += 分量
        }
        return 输出
    }

    func 二元组列表() -> [SIMD2<Double>] {
        let (平, 分量) = 数值()
        guard 分量 >= 2, 平.count >= 2 else { return [] }
        var 输出: [SIMD2<Double>] = []
        var i = 0
        while i + 分量 - 1 < 平.count {
            输出.append(SIMD2(平[i], 平[i + 1]))
            i += 分量
        }
        return 输出
    }

    func 整数列表() -> [Int] {
        let (平, _) = 数值()
        return 平.map { Int($0.rounded()) }
    }

    func 双精度() -> Double? {
        switch self {
        case .数(let v): return v
        case .元组(let v): return v.first
        default: return nil
        }
    }
}

// MARK: - 词法

private enum 标记: Equatable {
    case 名(String)
    case 数(Double)
    case 串(String)
    case 路径(String)
    case 符号(Character)
}

private struct 词法器 {
    let 字符: [Character]
    var 位 = 0

    init(文本: String) {
        // 去掉 `#usda 1.0` 与注释行：两者都以 # 开头，注释到行尾，头只有一行且解析阶段用不到
        var 结果: [Character] = []
        var 跳过 = false
        for c in 文本 {
            if c == "\n" { 跳过 = false; 结果.append(c); continue }
            if c == "#" { 跳过 = true; continue }
            if !跳过 { 结果.append(c) }
        }
        字符 = 结果
    }

    mutating func 运行() -> [标记] {
        var 输出: [标记] = []
        while 位 < 字符.count {
            let c = 字符[位]
            if c.isWhitespace { 位 += 1; continue }
            if c == "\"" { 输出.append(.串(读串())); continue }
            if c == "@" { 输出.append(.路径(读资产())); continue }
            if c == "<" {
                // 关系路径 </Root/Mesh>
                var s = ""
                位 += 1
                while 位 < 字符.count, 字符[位] != ">" { s.append(字符[位]); 位 += 1 }
                位 += 1
                输出.append(.路径(s))
                continue
            }
            if c == "[" || c == "]" || c == "{" || c == "}" || c == "(" || c == ")"
                || c == "=" || c == "," || c == ";" || c == "." && !(位 + 1 < 字符.count && 字符[位 + 1].isNumber) {
                输出.append(.符号(c)); 位 += 1; continue
            }
            if c.isNumber || c == "-" || c == "+" || (c == "." && 位 + 1 < 字符.count && 字符[位 + 1].isNumber) {
                if let v = 读数() { 输出.append(.数(v)); continue }
            }
            if c.isLetter || c == "_" {
                输出.append(.名(读名())); continue
            }
            if c == ":" {
                // 独立的冒号极少见，当符号吞掉
                位 += 1; continue
            }
            位 += 1
        }
        return 输出
    }

    private mutating func 读串() -> String {
        位 += 1
        var s = ""
        while 位 < 字符.count {
            let c = 字符[位]
            if c == "\\", 位 + 1 < 字符.count {
                let n = 字符[位 + 1]
                s.append(n == "n" ? "\n" : n)
                位 += 2
                continue
            }
            if c == "\"" { 位 += 1; break }
            s.append(c)
            位 += 1
        }
        return s
    }

    private mutating func 读资产() -> String {
        位 += 1
        var s = ""
        while 位 < 字符.count, 字符[位] != "@" { s.append(字符[位]); 位 += 1 }
        位 += 1
        return s
    }

    private mutating func 读名() -> String {
        var s = ""
        while 位 < 字符.count {
            let c = 字符[位]
            if c.isLetter || c.isNumber || c == "_" || c == ":" {
                s.append(c); 位 += 1
            } else {
                break
            }
        }
        return s
    }

    private mutating func 读数() -> Double? {
        var s = ""
        while 位 < 字符.count {
            let c = 字符[位]
            if c.isNumber || c == "." || c == "-" || c == "+" || c == "e" || c == "E" {
                // 指数符号要跟着数字，避免把 1e 后面的标识吃掉
                s.append(c); 位 += 1
            } else {
                break
            }
        }
        return Double(s)
    }
}

// MARK: - 节点

private final class 节点 {
    var 名: String = ""
    var 类型: String = ""
    var 属性: [String: USD值] = [:]
    /// 属性是否为数组（有些 op 需要区分）
    var 数组属性: Set<String> = []
    var 子: [节点] = []
    var 组合标记: [String] = []

    /// xformOpOrder + 各 op 合成。USD 语义：M = op1 · op2 · …（列表首项最外层）
    func 变换矩阵() -> simd_double4x4 {
        var 结果 = simd_double4x4(1)
        var 顺序: [String] = []
        if case .数组(let 项)? = 属性["xformOpOrder"] {
            顺序 = 项.compactMap { v -> String? in
                if case .串(let s) = v { return s }
                return nil
            }
        }
        if 顺序.isEmpty {
            顺序 = 属性.keys.filter { $0.hasPrefix("xformOp:") }.sorted()
        }
        for 名 in 顺序 {
            guard let 值 = 属性[名] else { continue }
            let 短名 = 名.replacingOccurrences(of: "xformOp:", with: "")
            if let m = 单项变换(短名: 短名, 值: 值) {
                结果 = 结果 * m
            }
        }
        return 结果
    }

    private func 单项变换(短名: String, 值: USD值) -> simd_double4x4? {
        switch 短名 {
        case "translate":
            guard let t = 值.三维() else { return nil }
            var m = simd_double4x4(1)
            m.columns.3 = SIMD4(t, 1)
            return m
        case "scale":
            guard let s = 值.三维() else { return nil }
            var m = simd_double4x4(1)
            m.columns.0.x = s.x
            m.columns.1.y = s.y
            m.columns.2.z = s.z
            return m
        case "transform":
            guard case .数组(let 项) = 值 else { return nil }
            let 平 = 项.flatMap { $0.数值().平铺 }
            guard 平.count >= 16 else { return nil }
            // USD 的 matrix4d 是行主序
            return simd_double4x4(rows: [
                SIMD4(平[0], 平[1], 平[2], 平[3]),
                SIMD4(平[4], 平[5], 平[6], 平[7]),
                SIMD4(平[8], 平[9], 平[10], 平[11]),
                SIMD4(平[12], 平[13], 平[14], 平[15])
            ])
        case "orient":
            guard let q = 值.四元() else { return nil }
            return simd_double4x4(simd_quatd(ix: q.x, iy: q.y, iz: q.z, r: q.w))
        case "rotateX", "rotateY", "rotateZ":
            guard let 度 = 值.双精度() else { return nil }
            let 弧 = 度 * .pi / 180
            let c = cos(弧), s = sin(弧)
            var m = simd_double4x4(1)
            switch 短名 {
            case "rotateX":
                m.columns.1.y = c; m.columns.1.z = s
                m.columns.2.y = -s; m.columns.2.z = c
            case "rotateY":
                m.columns.0.x = c; m.columns.0.z = -s
                m.columns.2.x = s; m.columns.2.z = c
            default:
                m.columns.0.x = c; m.columns.0.y = s
                m.columns.1.x = -s; m.columns.1.y = c
            }
            return m
        case "rotateXYZ", "rotateZYX":
            guard case .元组(let 三项) = 值, 三项.count >= 3 else { return nil }
            let (rx, ry, rz) = (三项[0] * .pi / 180, 三项[1] * .pi / 180, 三项[2] * .pi / 180)
            func R(_ 轴: Int, _ a: Double) -> simd_double4x4 {
                var m = simd_double4x4(1)
                let c = cos(a), s = sin(a)
                switch 轴 {
                case 0:
                    m.columns.1.y = c; m.columns.1.z = s; m.columns.2.y = -s; m.columns.2.z = c
                case 1:
                    m.columns.0.x = c; m.columns.0.z = -s; m.columns.2.x = s; m.columns.2.z = c
                default:
                    m.columns.0.x = c; m.columns.0.y = s; m.columns.1.x = -s; m.columns.1.y = c
                }
                return m
            }
            return 短名 == "rotateXYZ" ? R(0, rx) * R(1, ry) * R(2, rz) : R(2, rz) * R(1, ry) * R(0, rx)
        default:
            return nil
        }
    }

    /// references / subLayers / instanceable 这类没展开就一定会丢内容的东西，明说
    func 组合说明() -> String? {
        guard !组合标记.isEmpty else { return nil }
        return "「\(名)」含 \(组合标记.joined(separator: " / "))，未做展开（纯 Swift 不解析 usdc 引用），只导入其直接几何"
    }

    func 生成网格(路径: String) -> 导入网格? {
        guard let 点属性 = 属性["points"] else { return nil }
        let 点 = 点属性.三元组列表()
        guard !点.isEmpty else { return nil }

        var 网格 = 导入网格(名称: 名.isEmpty ? "Mesh" : 名)
        网格.顶点 = 点.map { SIMD3<Float>($0) }

        let 面数 = 属性["faceVertexCounts"]?.整数列表() ?? []
        let 面索引 = 属性["faceVertexIndices"]?.整数列表() ?? []

        // 法线 / UV 的插值域
        let 法线 = 属性["normals"]?.三元组列表() ?? []
        let st = 属性["primvars:st"]?.二元组列表() ?? []

        let 角点数 = 面索引.count
        let 法线按角 = 法线.count == 角点数 && 角点数 > 0 && 法线.count != 点.count
        let st按角 = st.count == 角点数 && 角点数 > 0 && st.count != 点.count

        var 索引: [UInt32] = []
        var 输出点 = 网格.顶点
        var 输出法线: [SIMD3<Float>] = []
        var 输出UV: [SIMD2<Float>] = []
        if 法线.count == 点.count { 输出法线 = 法线.map { SIMD3<Float>($0) } }
        if st.count == 点.count { 输出UV = st.map { SIMD2<Float>($0) } }
        if 法线按角 { 输出法线 = [] }
        if st按角 { 输出UV = [] }

        // 面 → 角列表
        var 角偏移 = 0
        var 面列表: [(起: Int, 数: Int)] = []
        if !面数.isEmpty {
            for n in 面数 {
                let 数 = max(n, 0)
                if 角偏移 + 数 <= 面索引.count {
                    面列表.append((角偏移, 数))
                }
                角偏移 += 数
            }
        }

        // faceVarying 属性需要拆点：一个角一个顶点
        let 需拆点 = 法线按角 || st按角
        if 需拆点 {
            输出点 = []
            if 法线按角 { 输出法线 = [] }
            if st按角 { 输出UV = [] }
            var 角顶点映射: [Int: UInt32] = [:]

            func 角顶点(_ 角: Int) -> UInt32 {
                if let 命中 = 角顶点映射[角] { return 命中 }
                let 原点 = 面索引[角]
                let p = (原点 >= 0 && 原点 < 点.count) ? 点[原点] : .zero
                let 新 = UInt32(输出点.count)
                输出点.append(SIMD3<Float>(p))
                if 法线按角 { 输出法线.append(SIMD3<Float>(法线[角])) }
                if st按角 { 输出UV.append(SIMD2<Float>(st[角])) }
                角顶点映射[角] = 新
                return 新
            }

            for 面 in 面列表 {
                guard 面.数 >= 3 else { continue }
                let 首 = 角顶点(面.起)
                for i in 1..<(面.数 - 1) {
                    索引.append(首)
                    索引.append(角顶点(面.起 + i))
                    索引.append(角顶点(面.起 + i + 1))
                }
            }
        } else {
            var 缓冲: [UInt32] = []
            for 面 in 面列表 {
                guard 面.数 >= 3 else { continue }
                let 首 = UInt32(max(面索引[面.起], 0))
                for i in 1..<(面.数 - 1) {
                    缓冲.append(首)
                    缓冲.append(UInt32(max(面索引[面.起 + i], 0)))
                    缓冲.append(UInt32(max(面索引[面.起 + i + 1], 0)))
                }
            }
            索引 = 缓冲
            // 越界清理
            let 上界 = UInt32(输出点.count)
            索引 = 索引.map { min($0, 上界 &- 1) }
        }

        guard !索引.isEmpty else { return nil }
        网格.顶点 = 输出点
        网格.法线 = 输出法线
        网格.UV = 输出UV
        网格.索引 = 索引
        网格.子集 = [导入子集(材质: nil, 起始: 0, 数量: 索引.count)]

        // 材质绑定：只记名字，App 侧材质库按名字匹配
        // material:binding 的值在词法阶段被当作路径 @...@ 或字符串，
        // 两者都归到 USD值.串，这里统一按"末段名字"取材质名。
        if let 绑定 = 属性["material:binding"] {
            switch 绑定 {
            case .串(let 材质路径), .标识(let 材质路径):
                网格.子集[0].材质名 = (材质路径 as NSString).lastPathComponent
            default:
                break
            }
        }
        return 网格
    }
}

private extension USD值 {
    func 三维() -> SIMD3<Double>? {
        if case .元组(let v) = self, v.count >= 3 { return SIMD3(v[0], v[1], v[2]) }
        if case .数组(let 项) = self {
            let 平 = 项.flatMap { $0.数值().平铺 }
            if 平.count >= 3 { return SIMD3(平[0], 平[1], 平[2]) }
        }
        if case .数(let v) = self { return SIMD3(v, v, v) }
        return nil
    }

    func 四元() -> SIMD4<Double>? {
        if case .元组(let v) = self, v.count >= 4 { return SIMD4(v[0], v[1], v[2], v[3]) }
        if case .数组(let 项) = self {
            let 平 = 项.flatMap { $0.数值().平铺 }
            if 平.count >= 4 { return SIMD4(平[0], 平[1], 平[2], 平[3]) }
        }
        return nil
    }
}

// MARK: - 解析器

private struct 解析器 {
    let 标记: [标记]
    var 位 = 0

    var 元数据: [String: USD值] = [:]
    var 顶层: [节点] = []

    init(标记: [标记]) {
        self.标记 = 标记
    }

    mutating func 运行() -> (元数据: [String: USD值], 顶层: [节点]) {
        跳过文件头元数据()
        var 收集: [节点] = []
        解析作用域(容器: &收集, 前缀: "")
        return (元数据, 收集)
    }

    private mutating func 跳过文件头元数据() {
        // 形式： ( defaultPrim = "X" metersPerUnit = 1 upAxis = "Z" )
        guard 位 < 标记.count, 标记[位] == .符号("(") else { return }
        var 深度 = 0
        var 待定名: String?
        while 位 < 标记.count {
            let t = 标记[位]
            if t == .符号("(") { 深度 += 1; 位 += 1; continue }
            if t == .符号(")") {
                深度 -= 1; 位 += 1
                if 深度 == 0 { break }
                continue
            }
            if case .名(let k) = t {
                if 下一标记是等号() {
                    待定名 = k
                    位 += 2   // 名 + '='
                    let v = 读值()
                    if let n = 待定名 { 元数据[n] = v }
                    待定名 = nil
                    continue
                }
            }
            位 += 1
        }
    }

    private func 下一标记是等号() -> Bool {
        位 + 1 < 标记.count && 标记[位 + 1] == .符号("=")
    }

    // 解析一个 {} 作用域内的内容
    private mutating func 解析作用域(容器: inout [节点], 前缀: String) {
        while 位 < 标记.count {
            let t = 标记[位]
            if t == .符号("}") { 位 += 1; return }
            if case .名(let 关键字) = t {
                switch 关键字 {
                case "def", "over", "class", "custom":
                    解析Prim(容器: &容器, 前缀: 前缀)
                    continue
                case "variantSet", "variants", "reorder", "inherits", "specializes",
                     "references", "payload", "subLayers", "subLayerss", "apiSchemas":
                    // 整体跳过赋值部分
                    跳过赋值()
                    continue
                default:
                    // 属性：类型 名 = 值  或  名 = 值
                    跳过赋值()
                    continue
                }
            }
            位 += 1
        }
    }

    private mutating func 跳过赋值() {
        var 深度 = 0
        while 位 < 标记.count {
            let t = 标记[位]
            if t == .符号("{") || t == .符号("[") || t == .符号("(") { 深度 += 1; 位 += 1; continue }
            if t == .符号("}") || t == .符号("]") || t == .符号(")") {
                if 深度 == 0 { return }
                深度 -= 1; 位 += 1; continue
            }
            if t == .符号(";") || t == .符号(",") { 位 += 1; if 深度 == 0 { return }; continue }
            if case .名(let k) = t, 深度 == 0, ["def", "over", "class"].contains(k) { return }
            位 += 1
            if 深度 == 0, 位 < 标记.count, case .名 = 标记[位], case .名 = t {
                // 两个连续标识符 = 下一个属性开始了
                return
            }
        }
    }

    private mutating func 解析Prim(容器: inout [节点], 前缀: String) {
        // 关键字
        位 += 1
        var 类型 = "Xform"
        var 名 = ""
        var 修饰: [String] = []

        // 类型名（可能被 custom / reorder 等前置修饰过，已在上面吃掉 custom）
        if 位 < 标记.count, case .名(let t) = 标记[位] {
            类型 = t
            位 += 1
        }
        if 位 < 标记.count, case .串(let s) = 标记[位] {
            名 = s
            位 += 1
        }
        // 元数据块
        if 位 < 标记.count, 标记[位] == .符号("(") {
            let 内 = 读括号内容()
            修饰 = 内
        }
        guard 位 < 标记.count, 标记[位] == .符号("{") else { return }
        位 += 1

        let 节点值 = 节点()
        节点值.类型 = 类型
        节点值.名 = 名
        if 修饰.contains("references") { 节点值.组合标记.append("references") }
        if 修饰.contains("payload") { 节点值.组合标记.append("payload") }
        if 修饰.contains("instanceable") { 节点值.组合标记.append("instanceable") }

        // 读体：属性 + 子 prim
        while 位 < 标记.count {
            let t = 标记[位]
            if t == .符号("}") { 位 += 1; break }
            if case .名(let 关键字) = t {
                if ["def", "over", "class"].contains(关键字) {
                    var 子容器: [节点] = []
                    解析Prim(容器: &子容器, 前缀: 前缀 + "/" + 名)
                    节点值.子.append(contentsOf: 子容器)
                    continue
                }
                if ["variantSet", "variants", "reorder", "inherits", "specializes"].contains(关键字) {
                    跳过赋值()
                    continue
                }
                // 属性：可能带 uniform / varying / custom 修饰
                var 游标 = 位
                var 修饰词: [String] = []
                while 游标 < 标记.count, case .名(let m) = 标记[游标],
                      ["uniform", "varying", "custom", "config"].contains(m) {
                    修饰词.append(m)
                    游标 += 1
                }
                // 类型名
                var 类型名 = ""
                if 游标 < 标记.count, case .名(let t2) = 标记[游标] {
                    类型名 = t2
                    游标 += 1
                }
                // 数组标记
                if 游标 < 标记.count, 标记[游标] == .符号("[") {
                    游标 += 1
                    if 游标 < 标记.count, 标记[游标] == .符号("]") { 游标 += 1 }
                }
                // 属性名
                guard 游标 < 标记.count, case .名(let 属性名) = 标记[游标] else {
                    位 = max(位 + 1, 游标)
                    continue
                }
                游标 += 1
                guard 游标 < 标记.count, 标记[游标] == .符号("=") else {
                    位 = max(位 + 1, 游标)
                    continue
                }
                // 消费到值
                位 = 游标 + 1
                let 值 = 读值()
                节点值.属性[属性名] = 值
                // 属性元数据块
                if 位 < 标记.count, 标记[位] == .符号("(") { _ = 读括号内容() }
                _ = 类型名
                continue
            }
            if t == .符号("}") { 位 += 1; break }
            位 += 1
        }

        容器.append(节点值)
    }

    /// 读 (...) 里的标识符序列（用于组合元数据识别）
    private mutating func 读括号内容() -> [String] {
        var 深度 = 0
        var 输出: [String] = []
        while 位 < 标记.count {
            let t = 标记[位]
            if t == .符号("(") { 深度 += 1; 位 += 1; continue }
            if t == .符号(")") {
                深度 -= 1; 位 += 1
                if 深度 == 0 { break }
                continue
            }
            if case .名(let k) = t { 输出.append(k) }
            位 += 1
        }
        return 输出
    }

    private mutating func 读值() -> USD值 {
        guard 位 < 标记.count else { return .数(0) }
        let t = 标记[位]
        switch t {
        case .符号("["):
            位 += 1
            var 项: [USD值] = []
            while 位 < 标记.count, 标记[位] != .符号("]") {
                if 标记[位] == .符号(",") { 位 += 1; continue }
                let v = 读值()
                项.append(v)
            }
            if 位 < 标记.count { 位 += 1 }
            return .数组(项)
        case .符号("("):
            位 += 1
            var 数: [Double] = []
            while 位 < 标记.count, 标记[位] != .符号(")") {
                if case .数(let v) = 标记[位] { 数.append(v) }
                位 += 1
            }
            if 位 < 标记.count { 位 += 1 }
            return .元组(数)
        case .数(let v):
            位 += 1
            return .数(v)
        case .串(let s):
            位 += 1
            return .串(s)
        case .路径(let s):
            位 += 1
            return .串(s)
        case .名(let s):
            位 += 1
            return .标识(s)
        default:
            位 += 1
            return .数(0)
        }
    }
}

// MARK: - double → float 矩阵换算

/// USD 的 xform 链路全程用 double 算（避免长层级累积误差），
/// 落到 App 的网格上才转 float。手写逐列转换，别指望 SIMD 有隐式精度降级。
private extension simd_float4x4 {
    init(_ d: simd_double4x4) {
        self.init(columns: (
            SIMD4<Float>(Float(d.columns.0.x), Float(d.columns.0.y), Float(d.columns.0.z), Float(d.columns.0.w)),
            SIMD4<Float>(Float(d.columns.1.x), Float(d.columns.1.y), Float(d.columns.1.z), Float(d.columns.1.w)),
            SIMD4<Float>(Float(d.columns.2.x), Float(d.columns.2.y), Float(d.columns.2.z), Float(d.columns.2.w)),
            SIMD4<Float>(Float(d.columns.3.x), Float(d.columns.3.y), Float(d.columns.3.z), Float(d.columns.3.w))
        ))
    }
}
