import AppKit
import Foundation
import SceneKit
import simd

// MARK: - 把 .cg 工程容器还原成一个可直接拖拽旋转的 SceneKit 场景

enum CGSceneLoader {

    struct 物体描述 {
        var name: String = ""
        var mesh: String = "sphere"
        var 网格ID: UUID?
        var 材质ID: UUID?
        var position = SIMD3<Float>(0, 0, 0)
        /// 欧拉角，单位「度」（和 App 里 SceneObject.rotation 同单位）
        var rotation = SIMD3<Float>(0, 0, 0)
        var scale = SIMD3<Float>(1, 1, 1)
        var visible = true
    }

    // MARK: 入口

    /// 读清单 → 读场景参数 → 读几何块 → 组装场景。
    /// 新版 .cg 是单文件，老工程还是目录包，两种都吃。
    static func 构建(根: URL) -> SCNScene? {
        if let 容 = CGContainer(路径: 根) {
            return 构建(取: { 容.读($0) })
        }
        // 老目录形态：按相对路径逐个读文件
        return 构建(取: { 相对 in
            try? Data(contentsOf: 根.appendingPathComponent(相对), options: [.mappedIfSafe])
        })
    }

    private static func 构建(取 读: (String) -> Data?) -> SCNScene? {
        guard let 清单 = 读JSON(读("manifest.json")) as? [String: Any] else {
            return nil
        }

        // 1) 几何池：清单里登记过的 .cgm 才读，孤儿文件不碰
        var 池: [UUID: [CGMesh]] = [:]
        for 条目 in (清单["几何"] as? [[String: Any]]) ?? [] {
            guard let id字 = 条目["网格ID"] as? String,
                  let id = UUID(uuidString: id字),
                  let 文件 = 条目["文件"] as? String,
                  let 数据 = 读("geometry/" + 文件) else { continue }
            let 网格 = CGMeshReader.读(数据)
            if !网格.isEmpty { 池[id] = 网格 }
        }

        // 2) 场景参数：zlib 压过的 JSON
        guard let 场景JSON = 读JSON(读("scene/project.json")) as? [String: Any] else {
            return nil
        }
        let 物体们 = (场景JSON["objects"] as? [[String: Any]])
            ?? (场景JSON["物体"] as? [[String: Any]])
            ?? []

        // 3) 材质表：和 App 用的是同一份数据（OpenPBR 基线 + 节点图），预览端只做近似求解
        var 材质表: [UUID: 材质描述] = [:]
        for 原材质 in (场景JSON["materials"] as? [[String: Any]]) ?? [] {
            guard let id字 = 原材质["id"] as? String, let id = UUID(uuidString: id字) else { continue }
            材质表[id] = 解材质(原材质)
        }

        let 场景 = SCNScene()
        let 背景 = 背景图()
        场景.background.contents = 背景
        // 金属/玻璃要靠环境反射才看得出材质，只给方向光会一片死灰
        场景.lightingEnvironment.contents = 背景
        场景.lightingEnvironment.intensity = 1.6

        let 转台 = SCNNode()
        转台.name = "转台"
        场景.rootNode.addChildNode(转台)

        for 原 in 物体们 {
            let 描述 = 解析(原)
            guard 描述.visible else { continue }
            let 节点 = 造节点(描述, 池: 池, 材质表: 材质表)
            guard let 节点 else { continue }
            转台.addChildNode(节点)
        }

        // 空场景只摆相机：绝不自己造地面/占位体，画面里出现的每个东西都必须来自存档
        let (中心, 半径) = 包围球(转台)
        加灯光(场景: 场景, 半径: 半径)
        加相机(场景: 场景, 中心: 中心, 半径: 半径)

        // 不做任何自转：缩略图与空格预览打开就是这个静止的全景取景，画面完全一致
        return 场景
    }

    // MARK: JSON

    /// 场景存档不是裸 JSON：魔数 "3DPJ"(4B) + 压缩标志(1B) + 负载。
    /// manifest.json 则是明文 JSON，两种都吃。
    /// 容器里的 JSON 有三种落盘形态，按顺序嗅探，别只看老格式：
    ///   1. 明文 JSON（manifest.json 现在就是明文，首字节 `{` / `[`）
    ///   2. "3DPJ" + 标志字节 + 负载（老格式，标志 1 = zlib）
    ///   3. 裸 deflate（新格式：project.json 直接 (NSData).compressed(using:.zlib)，无头无标志）
    private static func 读JSON(_ 数据: Data?) -> Any? {
        guard var data = 数据, !data.isEmpty else { return nil }

        if let 首 = data.first, 首 == 0x7B || 首 == 0x5B {   // '{' / '['
            return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        }

        let 魔数 = Data("3DPJ".utf8)
        if data.count > 5, data.prefix(4) == 魔数 {
            let 标志 = data[data.startIndex + 4]
            var 负载 = data.subdata(in: (data.startIndex + 5)..<data.endIndex)
            if 标志 == 1, let 解 = try? (负载 as NSData).decompressed(using: .zlib) as Data {
                负载 = 解
            }
            data = 负载
        } else if let 解 = try? (data as NSData).decompressed(using: .zlib) as Data {
            data = 解
        }

        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    private static func 解析(_ 原: [String: Any]) -> 物体描述 {
        var d = 物体描述()
        d.name = (原["name"] as? String) ?? "物体"
        d.mesh = (原["mesh"] as? String) ?? "sphere"
        if let id字 = 原["导入网格ID"] as? String { d.网格ID = UUID(uuidString: id字) }
        if let 材质字 = 原["materialID"] as? String { d.材质ID = UUID(uuidString: 材质字) }
        d.position = 向量(原["position"])
        d.rotation = 向量(原["rotation"])
        let s = 向量(原["scale"])
        d.scale = (s.x == 0 && s.y == 0 && s.z == 0) ? SIMD3<Float>(1, 1, 1) : s
        d.visible = (原["isVisible"] as? Bool) ?? true
        return d
    }

    private static func 向量(_ any: Any?) -> SIMD3<Float> {
        guard let d = any as? [String: Any] else { return SIMD3<Float>(0, 0, 0) }
        func 取(_ k: String, _ 缺省: Float) -> Float {
            if let v = d[k] as? Double { return Float(v) }
            if let v = d[k] as? Int { return Float(v) }
            if let v = d[k] as? NSNumber { return v.floatValue }
            return 缺省
        }
        return SIMD3<Float>(取("x", 0), 取("y", 0), 取("z", 0))
    }

    // MARK: 节点

    private static func 造节点(_ d: 物体描述, 池: [UUID: [CGMesh]], 材质表: [UUID: 材质描述]) -> SCNNode? {
        // 几何只有一个来源：存档里的几何池。
        // 池里没有就什么都不画 —— 绝不按 mesh 名字再造一个替代形状，
        // 否则空格预览里的模型就不是 App 里的那个模型了。
        guard let id = d.网格ID, let 网格们 = 池[id], !网格们.isEmpty else { return nil }

        let 根 = SCNNode()
        根.name = d.name
        根.simdPosition = d.position
        根.simdEulerAngles = d.rotation * (.pi / 180)
        根.simdScale = d.scale

        // 材质按物体走：同一个物体拆成几段网格，用的都是它自己的那份材质
        let 面材质 = 造型(d.材质ID.flatMap { 材质表[$0] })
        var 放了 = false
        for m in 网格们 {
            guard let g = 几何(m, 材质: 面材质) else { continue }
            let n = SCNNode(geometry: g)
            n.name = m.名称
            n.simdTransform = m.变换
            根.addChildNode(n)
            放了 = true
        }
        return 放了 ? 根 : nil
    }

    private static func 几何(_ m: CGMesh, 材质 面材质: SCNMaterial) -> SCNGeometry? {
        guard !m.顶点.isEmpty else { return nil }
        let 顶点源 = SCNGeometrySource(vertices: m.顶点.map { SCNVector3($0.x, $0.y, $0.z) })

        var 源: [SCNGeometrySource] = [顶点源]
        if m.法线.count == m.顶点.count {
            源.append(SCNGeometrySource(normals: m.法线.map { SCNVector3($0.x, $0.y, $0.z) }))
        }
        if m.UV.count == m.顶点.count {
            源.append(SCNGeometrySource(textureCoordinates: m.UV.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) }))
        }

        var 索引 = m.索引
        if 索引.isEmpty {
            索引 = (0..<UInt32(m.顶点.count)).map { $0 }
        }
        guard 索引.count >= 3 else { return nil }
        let 元素 = SCNGeometryElement(indices: 索引, primitiveType: .triangles)

        let g = SCNGeometry(sources: 源, elements: [元素])
        g.materials = [面材质]
        return g
    }

    // MARK: 材质

    /// 预览用的材质快照：数值全部来自存档里的 material（OpenPBR 基线 + 节点图），预览端不另立真值
    struct 材质描述 {
        var 基础色 = NSColor(calibratedWhite: 0.8, alpha: 1)
        var 基础色权重: CGFloat = 1
        var 金属度: CGFloat = 0
        var 粗糙度: CGFloat = 0.3
        var 透射: CGFloat = 0
        var 透射色 = NSColor(calibratedWhite: 1, alpha: 1)
        var 自发光色 = NSColor(calibratedWhite: 1, alpha: 1)
        var 自发光亮度: CGFloat = 0
        var 不透明度: CGFloat = 1
    }

    private static func 解材质(_ 原: [String: Any]) -> 材质描述 {
        var d = 材质描述()
        let 基线 = 基线表(原["baseline"])

        d.基础色 = 图解算器.色(基线["base_color"]) ?? d.基础色
        if let v = 图解算器.标量(基线["base_weight"]) { d.基础色权重 = CGFloat(v) }
        if let v = 图解算器.标量(基线["base_metallic"]) { d.金属度 = CGFloat(v) }
        if let v = 图解算器.标量(基线["base_roughness"]) { d.粗糙度 = CGFloat(v) }
        if let v = 图解算器.标量(基线["transmission_weight"]) { d.透射 = CGFloat(v) }
        d.透射色 = 图解算器.色(基线["transmission_color"]) ?? d.透射色
        d.自发光色 = 图解算器.色(基线["emission_color"]) ?? d.自发光色
        if let v = 图解算器.标量(基线["emission_luminance"]) { d.自发光亮度 = CGFloat(v) }
        if let v = 图解算器.标量(基线["base_alpha"]) { d.不透明度 = CGFloat(v) }

        // 节点图是最终真值：被连线驱动的接口用上游节点的代表值盖掉 baseline
        if let 图 = 原["graph"] as? [String: Any] {
            let 求 = 图解算器(图)
            if let c = 求.色(toSocket: "base_color") { d.基础色 = c }
            if let c = 求.色(toSocket: "emission_color") { d.自发光色 = c }
            if let c = 求.色(toSocket: "transmission_color") { d.透射色 = c }
            if let v = 求.标量(toSocket: "base_roughness") { d.粗糙度 = CGFloat(v) }
            if let v = 求.标量(toSocket: "base_metallic") { d.金属度 = CGFloat(v) }
            if let v = 求.标量(toSocket: "transmission_weight") { d.透射 = CGFloat(v) }
            if let v = 求.标量(toSocket: "base_weight") { d.基础色权重 = CGFloat(v) }
            if let v = 求.标量(toSocket: "emission_luminance") { d.自发光亮度 = CGFloat(v) }
            if let v = 求.标量(toSocket: "base_alpha") { d.不透明度 = CGFloat(v) }
        }

        d.金属度 = min(max(d.金属度, 0), 1)
        d.粗糙度 = min(max(d.粗糙度, 0.01), 1)
        d.透射 = min(max(d.透射, 0), 1)
        d.不透明度 = min(max(d.不透明度, 0), 1)
        return d
    }

    private static func 基线表(_ any: Any?) -> [String: Any] {
        guard let d = any as? [String: Any], let 值 = d["values"] as? [Any] else { return [:] }
        var 表: [String: Any] = [:]
        var i = 0
        while i + 1 < 值.count {
            if let k = 值[i] as? String { 表[k] = 值[i + 1] }
            i += 2
        }
        return 表
    }

    /// 节点图近似求解：只沿 output 的实际连线回溯，认得出来的节点用它的参数算代表值，
    /// 认不出来的一律不猜（保持 baseline 原值），避免在预览端造出第二份材质真值
    private struct 图解算器 {
        private let 节点: [String: [String: Any]]
        private let 上游: [String: String]      // "节点ID/接口" → 上游节点ID
        private let 出口: String?

        init(_ 图: [String: Any]) {
            var 节点表: [String: [String: Any]] = [:]
            for n in (图["nodes"] as? [[String: Any]]) ?? [] {
                if let id = n["id"] as? String { 节点表[id] = n }
            }
            var 连线: [String: String] = [:]
            for l in (图["links"] as? [[String: Any]]) ?? [] {
                guard let 到 = l["toNode"] as? String,
                      let 到口 = l["toSocket"] as? String,
                      let 从 = l["fromNode"] as? String else { continue }
                连线["\(到)/\(到口)"] = 从
            }
            节点 = 节点表
            上游 = 连线
            出口 = 节点表.first { ($0.value["kind"] as? String) == "output" }?.key
        }

        func 色(toSocket 口: String) -> NSColor? {
            guard let 出口, let 源 = 上游["\(出口)/\(口)"] else { return nil }
            return 求色(源, 深: 0)
        }

        func 标量(toSocket 口: String) -> Double? {
            guard let 出口, let 源 = 上游["\(出口)/\(口)"] else { return nil }
            return 求标量(源, 深: 0)
        }

        private func 求色(_ id: String, 深: Int) -> NSColor? {
            guard 深 < 6, let n = 节点[id], let kind = n["kind"] as? String else { return nil }
            let p = (n["params"] as? [String: Any]) ?? [:]
            switch kind {
            case "rgbConstant":
                return Self.色(p["color"])
            case "gradientMap", "mix":
                guard let a = Self.色(p["colorA"]), let b = Self.色(p["colorB"]) else { return nil }
                let f = 上游["\(id)/fac"].flatMap { 求标量($0, 深: 深 + 1) } ?? Self.标量(p["fac"]) ?? 0.5
                return Self.混(a, b, CGFloat(f))
            case "noiseTexture", "checkerTexture":
                guard let a = Self.色(p["colorA"]), let b = Self.色(p["colorB"]) else { return nil }
                // 程序化图案在静态预览里取两色中值，只是代表色，不代表逐像素纹理
                return Self.混(a, b, 0.5)
            case "hueSaturation":
                guard let 入 = 上游["\(id)/color"], let base = 求色(入, 深: 深 + 1) else { return nil }
                return Self.调色(base,
                                色相: Self.标量(p["hue"]) ?? 0,
                                饱和: Self.标量(p["sat"]) ?? 1)
            case "remap":
                guard let 入 = 上游["\(id)/value"], let base = 求色(入, 深: 深 + 1) else { return nil }
                return base
            default:
                return nil
            }
        }

        private func 求标量(_ id: String, 深: Int) -> Double? {
            guard 深 < 6, let n = 节点[id], let kind = n["kind"] as? String else { return nil }
            let p = (n["params"] as? [String: Any]) ?? [:]
            switch kind {
            case "remap":
                let 下 = Self.标量(p["toMin"]) ?? 0
                let 上 = Self.标量(p["toMax"]) ?? 1
                return (下 + 上) / 2      // 输入是图案/方向相关的量，静态预览取区间中值
            case "rgbConstant":
                return nil
            default:
                return Self.标量(p["value"])
            }
        }

        static func 色(_ any: Any?) -> NSColor? {
            guard let d = any as? [String: Any] else { return nil }
            let 内 = ((d["color"] as? [String: Any])?["_0"] as? [String: Any])
                ?? (d["_0"] as? [String: Any])
            guard let 内 else { return nil }
            func 取(_ k: String) -> CGFloat {
                (内[k] as? NSNumber).map { CGFloat(truncating: $0) } ?? 0
            }
            return NSColor(calibratedRed: 取("r"), green: 取("g"), blue: 取("b"), alpha: 1)
        }

        static func 标量(_ any: Any?) -> Double? {
            if let v = any as? NSNumber { return v.doubleValue }
            guard let d = any as? [String: Any] else { return nil }
            if let v = (d["scalar"] as? [String: Any])?["_0"] as? NSNumber { return v.doubleValue }
            if let v = d["_0"] as? NSNumber { return v.doubleValue }
            return nil
        }

        static func 混(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> NSColor {
            guard let x = a.usingColorSpace(.sRGB), let y = b.usingColorSpace(.sRGB) else { return a }
            let k = min(max(t, 0), 1)
            return NSColor(calibratedRed: x.redComponent + (y.redComponent - x.redComponent) * k,
                           green: x.greenComponent + (y.greenComponent - x.greenComponent) * k,
                           blue: x.blueComponent + (y.blueComponent - x.blueComponent) * k,
                           alpha: 1)
        }

        static func 调色(_ c: NSColor, 色相: Double, 饱和: Double) -> NSColor {
            guard let x = c.usingColorSpace(.sRGB) else { return c }
            var h: CGFloat = 0, s: CGFloat = 0, br: CGFloat = 0, al: CGFloat = 0
            x.getHue(&h, saturation: &s, brightness: &br, alpha: &al)
            var 新相 = (h + CGFloat(色相) / 360).truncatingRemainder(dividingBy: 1)
            if 新相 < 0 { 新相 += 1 }
            return NSColor(hue: 新相,
                           saturation: min(max(s * CGFloat(饱和), 0), 1),
                           brightness: br, alpha: al)
        }
    }

    /// 把材质快照落到 SceneKit 的 PBR 材质上。
    /// 没有材质数据就用 SceneKit 的默认表面 —— 预览端不按物体名字编颜色。
    private static func 造型(_ d: 材质描述?) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.isDoubleSided = true

        guard let d else { return m }

        m.metalness.contents = d.金属度
        m.roughness.contents = d.粗糙度

        if d.自发光亮度 > 0 {
            m.emission.contents = 自发光(d.自发光色, 亮度: d.自发光亮度)
        }

        if d.透射 > 0.02 {
            // SceneKit 没有 OpenPBR 的透射，用「基础色→透射色」混合 + 透明度近似，
            // 折射观感靠 lightingEnvironment 的环境反射撑住
            m.diffuse.contents = 图解算器.混(d.基础色, d.透射色, d.透射)
            m.transparency = max(0.08, d.不透明度 - d.透射 * 0.78)
            m.blendMode = .alpha
            m.fresnelExponent = 1.6
        } else {
            // 权重是「基础色覆盖率」，没覆盖到的部分按 OpenPBR 默认白
            m.diffuse.contents = 图解算器.混(NSColor(calibratedWhite: 1, alpha: 1),
                                          d.基础色, min(max(d.基础色权重, 0), 1))
            if d.不透明度 < 0.999 {
                m.transparency = d.不透明度
                m.blendMode = .alpha
            }
        }
        return m
    }

    private static func 自发光(_ 色: NSColor, 亮度: CGFloat) -> NSColor {
        guard let x = 色.usingColorSpace(.sRGB) else { return 色 }
        let k = min(max(亮度, 0), 1)
        return NSColor(calibratedRed: x.redComponent * k,
                       green: x.greenComponent * k,
                       blue: x.blueComponent * k,
                       alpha: 1)
    }

    // MARK: 包围球 / 相机 / 灯光

    private static func 包围球(_ 根: SCNNode) -> (SIMD3<Float>, Float) {
        var 最小 = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var 最大 = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var 命中 = false

        根.enumerateHierarchy { node, _ in
            guard let g = node.geometry else { return }
            let (lo, hi) = g.boundingBox
            func 点(_ x: CGFloat, _ y: CGFloat, _ z: CGFloat) -> SIMD3<Float> {
                SIMD3<Float>(Float(x), Float(y), Float(z))
            }
            let 角: [SIMD3<Float>] = [
                点(lo.x, lo.y, lo.z), 点(hi.x, lo.y, lo.z),
                点(lo.x, hi.y, lo.z), 点(hi.x, hi.y, lo.z),
                点(lo.x, lo.y, hi.z), 点(hi.x, lo.y, hi.z),
                点(lo.x, hi.y, hi.z), 点(hi.x, hi.y, hi.z),
            ]
            let 变换 = node.simdWorldTransform
            for c in 角 {
                let p = 变换 * SIMD4<Float>(c, 1)
                let w = SIMD3<Float>(p.x, p.y, p.z)
                最小 = simd_min(最小, w)
                最大 = simd_max(最大, w)
                命中 = true
            }
        }

        guard 命中 else { return (SIMD3<Float>(0, 0, 0), 1) }
        let 中心 = (最小 + 最大) / 2
        let 半径 = max(simd_length(最大 - 最小) / 2, 0.15)
        return (中心, 半径)
    }

    private static func 加相机(场景: SCNScene, 中心: SIMD3<Float>, 半径: Float) {
        let 相机 = SCNCamera()
        相机.fieldOfView = 40
        相机.zNear = Double(max(半径 * 0.001, 0.001))
        相机.zFar = Double(半径 * 200)
        相机.wantsHDR = true
        相机.bloomIntensity = 0.15

        let 节点 = SCNNode()
        节点.camera = 相机
        // 该文件所有对象聚焦：按包围球与垂直 FOV 反解距离，保证整个模型的每个对象都在画面内
        let 半角 = Float(相机.fieldOfView) * .pi / 180 / 2
        let 距离 = 半径 / sinf(半角) * 1.08
        // 略微俯视，和缩略图共用同一个机位，打开即是这个视角，不再转动
        let 方向 = simd_normalize(SIMD3<Float>(0, 0.22, 1))
        节点.simdPosition = 中心 + 方向 * 距离
        节点.look(at: SCNVector3(CGFloat(中心.x), CGFloat(中心.y), CGFloat(中心.z)),
                  up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 0, -1))
        场景.rootNode.addChildNode(节点)
    }

    private static func 加灯光(场景: SCNScene, 半径: Float) {
        let 环境 = SCNNode()
        let 环境光 = SCNLight()
        环境光.type = .ambient
        环境光.intensity = 320
        环境光.color = NSColor(calibratedWhite: 1, alpha: 1)
        环境.light = 环境光
        场景.rootNode.addChildNode(环境)

        func 方向光(_ 位置: SIMD3<Float>, _ 强度: CGFloat, _ 色: NSColor) {
            let n = SCNNode()
            let l = SCNLight()
            l.type = .directional
            l.intensity = 强度
            l.color = 色
            l.castsShadow = false
            n.light = l
            n.simdPosition = 位置 * 半径
            n.look(at: SCNVector3(0, 0, 0), up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 0, -1))
            场景.rootNode.addChildNode(n)
        }

        方向光(SIMD3<Float>(2.2, 3.0, 2.6), 900, NSColor(calibratedRed: 1.0, green: 0.97, blue: 0.92, alpha: 1))
        方向光(SIMD3<Float>(-2.4, 1.2, -1.6), 380, NSColor(calibratedRed: 0.72, green: 0.82, blue: 1.0, alpha: 1))
        方向光(SIMD3<Float>(0.4, -2.6, 1.2), 160, NSColor(calibratedRed: 0.9, green: 0.9, blue: 0.92, alpha: 1))
    }

    // MARK: 背景

    private static func 背景图() -> NSImage {
        let 尺寸 = NSSize(width: 512, height: 512)
        let 图 = NSImage(size: 尺寸)
        图.lockFocus()
        let 渐变 = NSGradient(colors: [
            NSColor(calibratedRed: 0.16, green: 0.17, blue: 0.20, alpha: 1),
            NSColor(calibratedRed: 0.05, green: 0.05, blue: 0.06, alpha: 1),
        ])
        渐变?.draw(in: NSRect(origin: .zero, size: 尺寸), angle: -90)
        图.unlockFocus()
        return 图
    }
}
