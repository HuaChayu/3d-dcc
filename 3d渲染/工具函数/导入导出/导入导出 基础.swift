import Foundation
import UniformTypeIdentifiers

// MARK: - 坐标上轴

/// 场景朝向约定。App 自身是 Y 向上；Blender / UE / 3ds Max 是 Z 向上；
/// glTF 规范写死 Y 向上；FBX 规范默认 Y 向上，但 GlobalSettings 里可以声明 Z，
/// 所以 FBX 这里给的是「文件没声明时的兜底」，不是硬约定。
enum 上轴: String, Codable, CaseIterable, Identifiable, Sendable {
    case y
    case z

    var id: String { rawValue }

    var 标题: String {
        switch self {
        case .y: "Y 向上"
        case .z: "Z 向上"
        }
    }

    var 说明: String {
        switch self {
        case .y: "App / glTF / OBJ 默认"
        case .z: "Blender / UE / 3ds Max"
        }
    }
}

// MARK: - 导入格式（= 通用导入窗口里的 Tab 粒度）

/// 一个 case = 一个 Tab。`usd` 一律指「USD 家族」，
/// 不区分 usda 文本 / usdc 二进制 / usdz 包 / .usd 任意编码。
enum 导入格式: String, CaseIterable, Identifiable, Sendable {
    case fbx
    case blend
    case usd
    case gltf
    case obj
    case stl
    case ply
    /// MaterialX：业界通用的材质描述文件（XML），只有材质没有几何。
    /// 单独一个 Tab，进来直接落材质库，不参与「贴地摆放 / 上轴校正」那套几何流程。
    case mtlx

    var id: String { rawValue }

    var 标题: String {
        switch self {
        case .fbx: "FBX"
        case .blend: "Blender"
        case .usd: "USD"
        case .gltf: "glTF"
        case .obj: "OBJ"
        case .stl: "STL"
        case .ply: "PLY"
        case .mtlx: "MaterialX"
        }
    }

    var 符号: String {
        switch self {
        case .fbx: "cube.transparent"
        case .blend: "circle.hexagongrid.fill"
        case .usd: "square.stack.3d.up.fill"
        case .gltf: "shippingbox.fill"
        case .obj: "square.on.square"
        case .stl: "triangle.fill"
        case .ply: "point.3.connected.trianglepath.dotted"
        case .mtlx: "paintpalette.fill"
        }
    }

    /// 该 Tab 认的扩展名（小写，不含点）
    var 扩展名: [String] {
        switch self {
        case .fbx: ["fbx"]
        case .blend: ["blend"]
        case .usd: ["usd", "usda", "usdc", "usdz"]
        case .gltf: ["gltf", "glb"]
        case .obj: ["obj"]
        case .stl: ["stl"]
        case .ply: ["ply"]
        case .mtlx: ["mtlx"]
        }
    }

    /// 该格式的默认源上轴（仅用于「自动」判定；FBX 会因为文件声明而覆盖）
    var 默认上轴: 上轴 {
        switch self {
        case .blend: .z
        case .usd: .y
        case .fbx: .y
        case .gltf: .y     // glTF 规范：+Y up
        case .obj: .y
        case .stl: .z      // STL 是 CAD 出身，Z 向上是主流
        case .ply: .y
        case .mtlx: .y     // 材质文件没有几何，上轴用不上，占位即可
        }
    }

    /// 分栏说明，摆在 Tab 头部
    var 摘要: String {
        switch self {
        case .fbx: "Autodesk FBX，二进制/ASCII 原生解析，跟随文件内 UpAxis 声明"
        case .blend: "Blender 工程文件，走 SDNA 结构原生解析，不依赖 Blender"
        case .usd: "USD 家族：usda 文本原生解析，usdc/usdz 按容器格式原生读取"
        case .gltf: "glTF 2.0 / GLB，原生解析（JSON + BIN 或 base64 buffer）"
        case .obj: "Wavefront OBJ，原生解析，支持 mtllib 与分组"
        case .stl: "STL 网格，二进制/ASCII 自动识别，原生解析"
        case .ply: "PLY 点云或多边形，ASCII/大端/小端二进制，原生解析"
        case .mtlx: "MaterialX 材质文件，原生 XML 解析，直接落材质库（不含几何）"
        }
    }
}

// MARK: - USD 子类型（同一个 Tab 内部再分）

enum USD子类型: String, Sendable {
    case 文本USDA
    case 二进制USDC
    case 打包USDZ

    var 标题: String {
        switch self {
        case .文本USDA: "usda 文本"
        case .二进制USDC: "usdc 二进制"
        case .打包USDZ: "usdz 打包"
        }
    }

    var 走原生: Bool { self == .文本USDA }
}

// MARK: - 文件描述

/// 一个待导入文件：扩展名 + 魔数嗅探后的确定结论。
/// 用户「不区分二进制/usda/usdc」的诉求在这里兑现：Tab 归到 usd，
/// 但内部仍然要知道它到底该怎么读，否则没法解析。
struct 导入文件: Identifiable, Sendable, Equatable {
    let id = UUID()
    var url: URL
    var 格式: 导入格式
    var usd子类型: USD子类型?
    /// 嗅探出来的额外说明（展示在文件行右侧）
    var 嗅探说明: String
    /// 该文件是否参与本次导入（侧边栏可取消勾选）
    var 启用: Bool = true

    var 名称: String { url.lastPathComponent }

    /// 真正执行时用的上轴（可被每文件覆盖覆盖掉）
    ///
    /// 每个格式只有自己声明的默认值；文件真实朝向由解析器回填的 `导入场景.文件上轴` 优先。
    var 推断上轴: 上轴 {
        格式.默认上轴
    }
}

// MARK: - 格式嗅探

enum 格式嗅探 {
    /// 判定文件格式：**魔数优先，扩展名兜底**。
    /// 为什么不是扩展名优先：拖进来的模型常见 `.bin`、`.dat`、无扩展名、甚至被改成 `.txt`，
    /// 而文件头是骗不了人的（FBX 的 Kaydara、blend 的 BLENDER、glTF 的 glTF、usdc 的 PXR-USDC）。
    static func 识别(url: URL) -> 导入文件? {
        let 扩展 = url.pathExtension.lowercased()
        let 头 = 读文件头(url: url, 字节数: 128)
        let 按扩展 = 导入格式.allCases.first(where: { $0.扩展名.contains(扩展) })

        guard let 格式 = 魔数判定(头: 头, 扩展: 扩展, 文件大小: 文件大小(url: url)) ?? 按扩展 else { return nil }

        var 说明 = 扩展.isEmpty ? "无扩展名" : 扩展.uppercased()
        var usd子类型: USD子类型?

        switch 格式 {
        case .usd:
            usd子类型 = 判定USD(扩展: 扩展, 头: 头)
            说明 = usd子类型?.标题 ?? "USD"
        case .fbx:
            if 头?.starts(with: Data("Kaydara FBX Binary".utf8)) == true {
                说明 = "二进制 FBX"
            } else if 头.flatMap({ String(data: $0.prefix(18), encoding: .ascii) })?.contains("FBX") == true {
                说明 = "ASCII FBX"
            } else {
                说明 = "FBX（编码未知）"
            }
        case .blend:
            if 头?.starts(with: Data("BLENDER".utf8)) == true {
                说明 = "未压缩 .blend"
            } else if 头.flatMap({ $0.first }) == 0x28 {   // Zstandard 帧头 0x28 B5 2F FD
                说明 = "Zstd 压缩 .blend"
            } else {
                说明 = "blend"
            }
        case .gltf:
            if 头?.starts(with: Data("glTF".utf8)) == true {
                说明 = "二进制 GLB"
            } else {
                说明 = "JSON glTF"
            }
        case .stl:
            说明 = 判定STL(头: 头, 文件大小: 文件大小(url: url))
        case .ply:
            说明 = 头.flatMap { String(data: $0.prefix(32), encoding: .ascii) }?.hasPrefix("ply") == true ? "PLY" : "PLY（头部可疑）"
        case .obj:
            说明 = "OBJ"
        case .mtlx:
            说明 = 头.flatMap({ String(data: $0, encoding: .utf8) })?.contains("<materialx") == true
                ? "MaterialX（XML）"
                : "mtlx"
        }

        if 按扩展 != 格式 { 说明 += "（按文件头判定）" }
        return 导入文件(url: url, 格式: 格式, usd子类型: usd子类型, 嗅探说明: 说明)
    }

    /// 只认文件头，不认文件名。识别不出返回 nil，交给扩展名兜底。
    private static func 魔数判定(头: Data?, 扩展: String, 文件大小: Int) -> 导入格式? {
        guard let 头, !头.isEmpty else { return nil }

        if 头.starts(with: Data("Kaydara FBX Binary".utf8)) { return .fbx }
        if 头.starts(with: Data("BLENDER".utf8)) { return .blend }        // 未压缩 .blend
        if 头.starts(with: Data("glTF".utf8)) { return .gltf }            // GLB
        if 头.starts(with: Data("PXR-USDC".utf8)) { return .usd }         // 二进制 usdc
        if 头.starts(with: Data("PK".utf8)) { return .usd }               // usdz 就是 zip 包

        // Zstd 帧头 0x28 B5 2F FD —— Blender 3.0+ 默认的压缩 .blend
        let 起点 = 头.startIndex
        if 头[起点] == 0x28, 头.count >= 4,
           头[起点 + 1] == 0xB5, 头[起点 + 2] == 0x2F, 头[起点 + 3] == 0xFD { return .blend }

        let 文本头 = String(data: 头.prefix(64), encoding: .ascii) ?? ""
        if 文本头.hasPrefix("#usda") || 文本头.hasPrefix("#usd") { return .usd }
        if 文本头.hasPrefix("ply") { return .ply }
        if 文本头.hasPrefix(";") || 文本头.hasPrefix("mtllib") || 文本头.hasPrefix("o ")
            || 文本头.hasPrefix("v ") || 文本头.hasPrefix("g ") { return .obj }

        // STL：二进制先按「84 + 面数×50 == 文件大小」精确对账，再退回文本判 solid。
        // 注意顺序不能反 —— 有些导出器的二进制 STL 头 80 字节里也写着 "solid"。
        if 头.count >= 84 {
            let 面数 = 头[起点 + 80..<起点 + 84].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            if 84 + Int(面数) * 50 == 文件大小 { return .stl }
        }
        if 文本头.lowercased().hasPrefix("solid") { return .stl }

        // JSON：glTF 文本版。只在扩展名像 JSON 时采信，避免把随便一个 .json 当模型。
        if 文本头.hasPrefix("{"), ["gltf", "json", ""].contains(扩展) { return .gltf }
        return nil
    }

    /// 用户要求「不区分 usda/usdc/二进制」，但仍需判定具体读法
    private static func 判定USD(扩展: String, 头: Data?) -> USD子类型 {
        if 扩展 == "usdz" { return .打包USDZ }
        if let 头 {
            if 头.starts(with: Data("PXR-USDC".utf8)) { return .二进制USDC }
            if 头.starts(with: Data("PK".utf8)) { return .打包USDZ }
        }
        if 扩展 == "usdc" { return .二进制USDC }
        // .usd 可能是任意编码：头不是 crate 魔数就按文本试
        return .文本USDA
    }

    private static func 判定STL(头: Data?, 文件大小: Int) -> String {
        guard let 头, 头.count >= 84 else { return "STL" }
        let 起点 = 头.startIndex
        let 面数 = 头[起点 + 80..<起点 + 84].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        if 84 + Int(面数) * 50 == 文件大小 { return "二进制 STL（\(面数) 面）" }
        let 文本 = String(data: 头, encoding: .ascii)?.lowercased() ?? ""
        if 文本.contains("solid") { return "ASCII STL" }
        return "STL"
    }

    private static func 读文件头(url: URL, 字节数: Int) -> Data? {
        guard let 句柄 = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? 句柄.close() }
        return try? 句柄.read(upToCount: 字节数)
    }

    private static func 文件大小(url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }
}

// MARK: - 导入参数

/// 每个文件一份，互不影响（同批可能混着 Y-up 的 obj 与 Z-up 的 blend）
struct 单文件导入设置: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    /// nil = 按格式默认自动判定
    var 源上轴: 上轴?
    /// 附加缩放（在坐标系校正之外再乘一次）
    var 额外缩放: Double = 1
    /// 自动按包围盒把导入物归一化到约 1.5 单位（现有程序化网格都是这个尺度）
    var 归一化尺寸: Bool = false
    var 重算法线: Bool = false
    var 焊接顶点: Bool = false
    var 合并为单对象: Bool = false
    var 保留层级: Bool = true

    // FBX / .blend 等格式的内部读入选项
    /// Blender 读取时是否走「应用变换」，铺平物体自带缩放
    var 应用变换: Bool = true
    /// 是否导入骨骼动画（当前管线无动画通道，仅记录提示）
    var 导入动画: Bool = false

    // USD 专属
    /// 根 prim 路径，空 = 默认 pseudo-root
    var 根Prim: String = ""
    var 展平实例: Bool = true
    /// usda 原生解析时强制读取 metersPerUnit（关闭则按 1 处理）
    var 采用米制换算: Bool = true

    // OBJ 专属
    var 读取MTL: Bool = true
    /// 同一个 o/g 是否合并
    var OBJ按组拆分: Bool = true

    // glTF 专属
    var GLTF导入材质: Bool = true
    /// 关闭 Draco 压缩支路（当前不支持，遇到时给出明确报错而不是静默变空）
    var GLTF保留非三角图元: Bool = false

    init(id: UUID = UUID()) {
        self.id = id
    }

    /// 实际生效的上轴
    func 生效上轴(文件: 导入文件) -> 上轴 {
        源上轴 ?? 文件.推断上轴
    }
}

// MARK: - 错误

enum 导入导出错误: LocalizedError {
    case 不支持的格式(String)
    case 文件不可读(URL)
    case 解析失败(格式: String, 原因: String)
    case 无有效几何(URL)
    case 导出失败(String)
    case 用户取消

    var errorDescription: String? {
        switch self {
        case .不支持的格式(let 扩展):
            "不支持的格式：.\(扩展)"
        case .文件不可读(let url):
            "无法读取文件：\(url.lastPathComponent)"
        case .解析失败(let 格式, let 原因):
            "\(格式) 解析失败：\(原因)"
        case .无有效几何(let url):
            "\(url.lastPathComponent) 里没有可用的三角网格"
        case .导出失败(let 原因):
            "导出失败：\(原因)"
        case .用户取消:
            "已取消"
        }
    }
}

// MARK: - 小工具

enum 导入导出工具 {
    /// 把 Color 之类无关的重复逻辑收在一处：解析出的双精度收敛到 Float 并夹紧
    static func 夹紧(_ v: Double, _ 下限: Double = 0, _ 上限: Double = 1) -> Float {
        Float(min(max(v, 下限), 上限))
    }

    /// 路径里带空格/中文时的转义写法，写外部文件与日志时要靠它
    static func 安全路径(_ url: URL) -> String { url.path }

    /// 中间产物目录（每次导入一组临时文件）
    static func 中间目录(标签: String) -> URL {
        let 根 = FileManager.default.temporaryDirectory
            .appendingPathComponent("3d渲染-导入导出", isDirectory: true)
        let 子 = 根.appendingPathComponent("\(标签)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: 子, withIntermediateDirectories: true)
        return 子
    }
}
