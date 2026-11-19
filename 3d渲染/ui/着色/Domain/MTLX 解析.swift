import CoreGraphics
import ImageIO
import Foundation

// MaterialX（`.mtlx`）子集解析器
//
// 读：open_pbr_surface / standard_surface 及其上游节点图（程序纹理、ramp、range、mix、image、
//     算术节点等），映射到项目自研的那套节点集；不支持的节点跳过并记诊断，
//     不在导入时静默丢图——诊断最后会进材质备注，检查器里能看到。
// 不读：几何、<look>/<collection> 变体、自定义节点的 glsl 源码。
// 贴图：现阶段取整图平均色当常量（视口和路径追踪都还没有 sampler 通路）；
//     以后接真贴图，只要把 `MTLX材质.节点` 上的 图片 字段绑到纹理库，这一层不用动。

// MARK: - 错误

enum MTLX错误: LocalizedError, Sendable {
    case 文件不可读(URL)
    case 格式错误(String)
    case 没有找到材质

    var errorDescription: String? {
        switch self {
        case .文件不可读(let url):
            "读不到 \(url.lastPathComponent)"
        case .格式错误(let 详情):
            "MTLX 格式错误：\(详情)"
        case .没有找到材质:
            "文件里没有 open_pbr_surface 或 material/shaderref 材质"
        }
    }
}

// MARK: - 极简 XML 扫描器
//
// 只服务 .mtlx：元素、属性、自闭合、注释、CDATA、声明、常见实体。
// 不追求通用 XML 规范覆盖（无命名空间、无 DTD 校验），够读材质包即可。
// 手写而非 XMLParser 的原因：这个文件要能在后台线程跑，且不想引入 ObjC 委托。

final class MTLX元素: @unchecked Sendable {
    let 名: String
    let 属性: [String: String]
    var 子: [MTLX元素] = []

    init(名: String, 属性: [String: String]) {
        self.名 = 名
        self.属性 = 属性
    }

    func 取(_ 键: String) -> String? { 属性[键] }

    func 子元素(_ 名: String) -> [MTLX元素] { 子.filter { $0.名 == 名 } }

    func 首个子元素(_ 名: String) -> MTLX元素? { 子.first { $0.名 == 名 } }

    func 所有后代(_ 名: String) -> [MTLX元素] {
        var 结果: [MTLX元素] = []
        for 项 in 子 {
            if 项.名 == 名 { 结果.append(项) }
            结果.append(contentsOf: 项.所有后代(名))
        }
        return 结果
    }
}

enum MTLX扫描 {

    static func 建树(_ 文本: String) throws -> MTLX元素 {
        let 字符 = Array(文本)
        let 总数 = 字符.count
        var 栈: [MTLX元素] = []
        var 根: MTLX元素?
        var i = 0

        while i < 总数 {
            guard 字符[i] == "<" else {
                var j = i
                while j < 总数, 字符[j] != "<" { j += 1 }
                _ = String(字符[i..<j])   // 文本内容本解析器用不到，直接跳过
                i = j
                continue
            }

            // 注释
            if 匹配(字符, i, "<!--") {
                guard let 尾 = 查找(字符, from: i + 4, "-->") else {
                    throw MTLX错误.格式错误("注释没有闭合")
                }
                i = 尾 + 3
                continue
            }

            // CDATA
            if 匹配(字符, i, "<![CDATA[") {
                guard let 尾 = 查找(字符, from: i + 9, "]]>") else {
                    throw MTLX错误.格式错误("CDATA 没有闭合")
                }
                i = 尾 + 3
                continue
            }

            // 声明 / 处理指令 / DOCTYPE
            if 匹配(字符, i, "<?") || 匹配(字符, i, "<!") {
                guard let 尾 = 查找(字符, from: i, ">") else {
                    throw MTLX错误.格式错误("声明没有闭合")
                }
                i = 尾 + 1
                continue
            }

            guard let 尾 = 查找(字符, from: i, ">") else {
                throw MTLX错误.格式错误("标签没有闭合（位置 \(i)）")
            }

            // 结束标签
            if 匹配(字符, i, "</") {
                if !栈.isEmpty { 栈.removeLast() }
                i = 尾 + 1
                continue
            }

            // 开始标签
            let 原文 = String(字符[(i + 1)..<尾])
            let 自闭合 = 原文.hasSuffix("/")
            let 主体 = 自闭合 ? String(原文.dropLast()) : 原文
            let (名, 属性表) = 拆标签(主体)
            let 元素 = MTLX元素(名: 名, 属性: 属性表)

            if let 父 = 栈.last {
                父.子.append(元素)
            } else if 根 == nil {
                根 = 元素
            }
            if !自闭合 { 栈.append(元素) }
            i = 尾 + 1
        }

        guard let 根 else { throw MTLX错误.格式错误("文件里没有元素") }
        return 根
    }

    static func 匹配(_ 字符: [Character], _ 位置: Int, _ 模式: String) -> Bool {
        let 模式字 = Array(模式)
        guard 位置 + 模式字.count <= 字符.count else { return false }
        for (偏移, 字) in 模式字.enumerated() where 字符[位置 + 偏移] != 字 { return false }
        return true
    }

    static func 查找(_ 字符: [Character], from 起点: Int, _ 模式: String) -> Int? {
        let 模式字 = Array(模式)
        guard !模式字.isEmpty, 起点 < 字符.count else { return nil }
        var i = 起点
        while i + 模式字.count <= 字符.count {
            var 命中 = true
            for (偏移, 字) in 模式字.enumerated() where 字符[i + 偏移] != 字 {
                命中 = false
                break
            }
            if 命中 { return i }
            i += 1
        }
        return nil
    }

    /// 把 `noise2d name="a" type="color3"` 拆成元素名 + 属性表
    static func 拆标签(_ 主体: String) -> (String, [String: String]) {
        let 字符 = Array(主体)
        let 总数 = 字符.count
        var i = 0

        func 跳过空白() {
            while i < 总数, 字符[i].isWhitespace { i += 1 }
        }

        跳过空白()
        var 名 = ""
        while i < 总数, !字符[i].isWhitespace, 字符[i] != "/" {
            名.append(字符[i])
            i += 1
        }

        var 属性: [String: String] = [:]
        while i < 总数 {
            跳过空白()
            guard i < 总数 else { break }

            var 键 = ""
            while i < 总数, 字符[i] != "=", !字符[i].isWhitespace {
                键.append(字符[i])
                i += 1
            }
            跳过空白()

            guard !键.isEmpty, i < 总数, 字符[i] == "=" else {
                if !键.isEmpty { 属性[键] = "" }
                while i < 总数, 字符[i] != "=", !字符[i].isWhitespace { i += 1 }
                continue
            }
            i += 1
            跳过空白()
            guard i < 总数 else { break }

            let 引号 = 字符[i]
            if 引号 == "\"" || 引号 == "'" {
                i += 1
                var 值 = ""
                while i < 总数, 字符[i] != 引号 {
                    值.append(字符[i])
                    i += 1
                }
                if i < 总数 { i += 1 }
                属性[键] = 实体解码(值)
            } else {
                var 值 = ""
                while i < 总数, !字符[i].isWhitespace {
                    值.append(字符[i])
                    i += 1
                }
                属性[键] = 实体解码(值)
            }
        }
        return (名, 属性)
    }

    static func 实体解码(_ 文本: String) -> String {
        guard 文本.contains("&") else { return 文本 }
        var 结果 = ""
        var 剩余 = Substring(文本)
        while let 位置 = 剩余.firstIndex(of: "&") {
            结果 += 剩余[剩余.startIndex..<位置]
            let 之后 = 剩余[剩余.index(after: 位置)...]
            guard let 分号 = 之后.firstIndex(of: ";") else {
                结果 += 剩余[位置...]
                return 结果
            }
            let 实体 = String(之后[之后.startIndex..<分号])
            switch 实体 {
            case "amp": 结果 += "&"
            case "lt": 结果 += "<"
            case "gt": 结果 += ">"
            case "quot": 结果 += "\""
            case "apos": 结果 += "'"
            default:
                if 实体.hasPrefix("#x") || 实体.hasPrefix("#X"),
                   let 码 = UInt32(实体.dropFirst(2), radix: 16),
                   let 字 = Unicode.Scalar(码) {
                    结果.append(Character(字))
                } else if 实体.hasPrefix("#"),
                          let 码 = UInt32(实体.dropFirst(), radix: 10),
                          let 字 = Unicode.Scalar(码) {
                    结果.append(Character(字))
                } else {
                    结果 += "&\(实体);"
                }
            }
            剩余 = 之后[之后.index(after: 分号)...]
        }
        结果 += 剩余
        return 结果
    }
}

// MARK: - 中间文档
//
// 只含 Sendable 值：可以在导入解析线程产生，回主线程再构造成 MaterialAsset。
// 对应踩坑记录：解析阶段只搬数据，不碰主线程隔离的资产类型。

struct MTLX文档: Sendable {
    var 材质: [MTLX材质]
}

struct MTLX材质: Sendable {
    var 名称: String
    /// 表面参数里给了字面值的那些，直接进 OpenPBR 基线
    var 参数: [PBRParamKey: PBRValue]
    var 节点: [MTLX节点]
    var 连线: [MTLX连线]
    /// 降级 / 跳过说明，原样展示给用户，不静默吞掉
    var 诊断: [String]
}

struct MTLX节点: Sendable {
    /// .mtlx 里的 name，连线和标题都用它
    var 名字: String
    var kind: ShaderNodeKind
    var 参数: [String: PBRValue]
    /// 到 Output 的最长上游跳数，构造时按它排横向位置
    var 深度: Int
    /// 图像贴图节点（MaterialX 的 `<image>` / `<tiledimage>`）的原始 file 路径。
    /// 项目里没有图像贴图节点，解析期先记路径，近似色留到接入层读图再填进 `参数`——
    /// 解析器是纯函数，不碰磁盘，也不在主线程上读大图。
    var 图片: String? = nil
    /// 这张图是灰度图（roughness / metalness 这类）：近似成常量时要保持三通道相等，
    /// 否则喂到标量口会被按亮度加权，数值整体变暗。
    var 图片是标量: Bool = false
}

struct MTLX连线: Sendable {
    var 从: String
    var 到: String      // 节点 name，或 MTLX连线.输出
    var 到口: String
    /// 目标口要不要颜色值：解析期只记语义，取上游哪个输出口留到构造时决定
    var 要颜色: Bool

    static let 输出 = "__output__"
}

// MARK: - 解析

enum MTLX解析 {

    // MARK: 入口

    /// 后台线程可以调这个：只做磁盘读取和 UTF-8 解码，返回纯 String
    nonisolated static func 读文本(url: URL) throws -> String {
        guard let 数据 = try? Data(contentsOf: url),
              let 文本 = String(data: 数据, encoding: .utf8)
        else { throw MTLX错误.文件不可读(url) }
        return 文本
    }

    /// 主线程入口：解析 + 构造一条链走完
    static func 解析(url: URL) throws -> MTLX文档 {
        try 解析(文本: 读文本(url: url))
    }

    static func 解析(文本: String) throws -> MTLX文档 {
        let 根 = try MTLX扫描.建树(文本)
        guard 根.名 == "materialx" else {
            throw MTLX错误.格式错误("根元素不是 <materialx>，而是 <\(根.名)>")
        }

        var 图表: [String: MTLX元素] = [:]
        for 图 in 根.子元素("nodegraph") {
            if let 名 = 图.取("name") { 图表[名] = 图 }
        }

        var 材质列表: [MTLX材质] = []
        var 已见: Set<String> = []

        // 先记下被 <material><shaderref node="..."> 指向的表面名：这些表面归 ② 那一路出材质，
        // ①/①' 的裸表面循环要跳过，否则同一份表面会在材质库里出两份（"SR_a" 和 "M_concrete · SR_c"）。
        var 被引用: Set<String> = []
        for 材质元素 in 根.子元素("material") {
            for 引用 in 材质元素.子元素("shaderref") {
                if let 节点名 = 引用.取("node") ?? 引用.取("nodeid"), !节点名.isEmpty {
                    被引用.insert(节点名)
                }
            }
        }

        // ① 顶层直接摆着的 open_pbr_surface（最常见）
        for 表面 in 根.子元素("open_pbr_surface") {
            let 名 = 表面.取("name") ?? "OpenPBR Surface"
            guard !已见.contains(名), !被引用.contains(名) else { continue }
            已见.insert(名)
            材质列表.append(建材质(名称: 名, 表面: 表面, 容器: nil, 根: 根, 图表: 图表))
        }

        // ①' 顶层直接摆着的 standard_surface：Autodesk 官方标准库导出常是这种裸写法，
        // 只认 open_pbr_surface 会让整份文件报「没有找到材质」。
        for 表面 in 根.子元素("standard_surface") {
            let 名 = 表面.取("name") ?? "Standard Surface"
            guard !已见.contains(名), !被引用.contains(名) else { continue }
            已见.insert(名)
            材质列表.append(建材质(名称: 名, 表面: 表面, 容器: nil, 根: 根, 图表: 图表, 用标准表面: true))
        }

        // ② material + shaderref（Maya / Houdini 导出常见）
        for 材质元素 in 根.子元素("material") {
            let 材质名 = 材质元素.取("name") ?? "Material"
            for 引用 in 材质元素.子元素("shaderref") {
                let 名 = 引用.取("name").map { "\(材质名) · \($0)" } ?? 材质名
                guard !已见.contains(名) else { continue }
                已见.insert(名)

                if let 图名 = 引用.取("nodegraph"), let 图 = 图表[图名] {
                    if let 图内表面 = 图.所有后代("open_pbr_surface").first {
                        材质列表.append(建材质(名称: 名, 表面: 图内表面, 容器: 图, 根: 根, 图表: 图表))
                    } else {
                        材质列表.append(MTLX材质(
                            名称: 名, 参数: [:], 节点: [], 连线: [],
                            诊断: ["图 \(图名) 里没有 open_pbr_surface，无法确定表面类型"]
                        ))
                    }
                    continue
                }

                let 节点名 = 引用.取("node") ?? 引用.取("nodeid") ?? ""
                // shaderref 本身只是个指针（<shaderref node="SR_std"/>），真实参数在它指向的表面元素上。
                // 拿 shaderref 当表面源会读出 0 个参数，导入后材质全是默认值。
                let 表面源 = 节点名.isEmpty ? nil : 按名找(根, 节点名)
                if 节点名.contains("open_pbr_surface") {
                    材质列表.append(建材质(名称: 名, 表面: 表面源 ?? 引用, 容器: nil, 根: 根, 图表: 图表))
                } else if 节点名.contains("standard_surface") {
                    材质列表.append(建材质(名称: 名, 表面: 表面源 ?? 引用, 容器: nil, 根: 根, 图表: 图表, 用标准表面: true))
                } else if let 表面源, (表面源.取("type") ?? "").contains("surfaceshader") {
                    // node 名不按约定起名时，退回看目标元素自身的 type
                    材质列表.append(建材质(名称: 名, 表面: 表面源, 容器: nil, 根: 根, 图表: 图表,
                                        用标准表面: 表面源.名.contains("standard_surface")))
                } else {
                    材质列表.append(MTLX材质(
                        名称: 名, 参数: [:], 节点: [], 连线: [],
                        诊断: ["不支持的表面着色器「\(节点名)」，只能读 open_pbr_surface 或 standard_surface"]
                    ))
                }
            }
        }

        // ③ 文件里只有 nodegraph：把每个图当一份材质试着读
        if 材质列表.isEmpty {
            for (名, 图) in 图表 {
                if let 图内表面 = 图.所有后代("open_pbr_surface").first {
                    材质列表.append(建材质(名称: 名, 表面: 图内表面, 容器: 图, 根: 根, 图表: 图表))
                } else if let 图内表面 = 图.所有后代("standard_surface").first {
                    材质列表.append(建材质(名称: 名, 表面: 图内表面, 容器: 图, 根: 根, 图表: 图表, 用标准表面: true))
                }
            }
        }

        guard !材质列表.isEmpty else { throw MTLX错误.没有找到材质 }
        return MTLX文档(材质: 材质列表)
    }

    // MARK: 单份材质

    /// 按 name 属性在整棵树里找元素（shaderref 的 node 指向就是靠它落地的）。
    /// 只找第一个命中：MaterialX 里同名元素本就该唯一，重复视为作者错误，不额外报错。
    static func 按名找(_ 根: MTLX元素, _ 名: String) -> MTLX元素? {
        for 子 in 根.子 {
            if 子.取("name") == 名 { return 子 }
            if let 命中 = 按名找(子, 名) { return 命中 }
        }
        return nil
    }

    static func 建材质(
        名称: String,
        表面: MTLX元素?,
        容器: MTLX元素?,
        根: MTLX元素,
        图表: [String: MTLX元素],
        用标准表面: Bool = false
    ) -> MTLX材质 {
        var 诊断: [String] = []
        var 跳过: [String] = []   // 不支持的节点名，最后汇总成一条诊断

        // 候选节点元素：当前容器内的、文件顶层散落的、以及所有子图里的
        // （真实文件普遍把节点塞在 <nodegraph> 里，表面着色器再引用子图）
        var 候选: [MTLX元素] = []
        if let 容器 { 候选 += 容器.子.filter { 是节点元素($0) } }
        候选 += 根.子.filter { 是节点元素($0) }
        for 图 in 根.子元素("nodegraph") {
            候选 += 图.子.filter { 是节点元素($0) }
        }

        var 节点列表: [MTLX节点] = []
        var 名字表: [String: Int] = [:]

        for 元素 in 候选 {
            guard let 元素名 = 元素.取("name") else { continue }
            guard 名字表[元素名] == nil else { continue }   // 同名节点只认第一个
            // <image>/<tiledimage>：项目没有图像贴图节点，先落成占位颜色常量，
            // 近似色留到接入层读图再填（解析器纯函数，不碰磁盘）。
            var 图片: String? = nil
            var 图片是标量 = false
            var 折: (口: String, 值: PBRValue)? = nil
            let kind: ShaderNodeKind
            if 元素.名 == "image" || 元素.名 == "tiledimage" {
                let 路径 = 元素.子元素("input").first { $0.取("name") == "file" }?.取("value") ?? ""
                guard !路径.isEmpty else {
                    诊断.append("图像节点「\(元素名)」没有 file 属性，已跳过")
                    continue
                }
                图片 = 路径
                图片是标量 = !是颜色类型(元素.取("type") ?? "")
                kind = .imageTexture
            } else if let 认出 = 节点种类(元素.名, 类型: 元素.取("type") ?? "") {
                kind = 认出
            } else if let 折叠 = 常量折叠(元素) {
                // 输入全是数字的算术节点：直接算成常量，别让它整条链断掉
                kind = 折叠.kind
                折 = (折叠.口, 折叠.值)
            } else {
                跳过.append("\(元素.名)「\(元素名)」")
                continue
            }

            var 参数: [String: PBRValue] = [:]
            if let 折 { 参数[折.口] = 折.值 }
            for 输入 in 元素.子元素("input") {
                // 折叠出来的常量就是最终值，别再被原始输入覆盖
                if 折 != nil { break }
                guard let 口名 = 输入.取("name") else { continue }
                // 带 nodename / nodegraph 的输入是连线，字面值在这轮不看
                if 输入.取("nodename") != nil || 输入.取("nodegraph") != nil { continue }
                guard let 目标口 = 参数口(kind: kind, 源名: 口名),
                      let 原值 = 输入.取("value"),
                      let 数字 = 解析数字(原值)
                else { continue }
                let 期望: SocketKind = 是颜色类型(输入.取("type") ?? "") ? .color : .scalar
                var 值 = 转值(数字, 期望: 期望)
                if case .color = 期望, (输入.取("colorspace") ?? "").lowercased().contains("srgb") {
                    值 = 颜色转线性(值)
                }
                参数[目标口] = 值
            }

            名字表[元素名] = 节点列表.count
            节点列表.append(MTLX节点(名字: 元素名, kind: kind, 参数: 参数, 深度: 0, 图片: 图片, 图片是标量: 图片是标量))
        }

        // 节点之间连线
        var 连线: [MTLX连线] = []
        var 已扫连线: Set<String> = []
        for 元素 in 候选 {
            guard let 元素名 = 元素.取("name"),
                  let 下标 = 名字表[元素名],
                  已扫连线.insert(元素名).inserted
            else { continue }

            for 输入 in 元素.子元素("input") {
                guard let 口名 = 输入.取("name"),
                      let 目标口 = 参数口(kind: 节点列表[下标].kind, 源名: 口名)
                else { continue }

                if let 上游 = 输入.取("nodename") {
                    guard 名字表[上游] != nil else {
                        诊断.append("「\(元素名) · \(口名)」指向不存在的节点「\(上游)」，已断开")
                        continue
                    }
                    连线.append(MTLX连线(
                        从: 上游,
                        到: 元素名,
                        到口: 目标口,
                        要颜色: 是颜色类型(输入.取("type") ?? "")
                    ))
                } else if let 图名 = 输入.取("nodegraph") {
                    // <input nodegraph="NG_rust" output="out" />：接到子图 output 指向的那个节点上
                    if let 源图 = 图表[图名], let 出口 = 源图.首个子元素("output"),
                       let 出口节点 = 出口.取("nodename"), 名字表[出口节点] != nil {
                        连线.append(MTLX连线(
                            从: 出口节点,
                            到: 元素名,
                            到口: 目标口,
                            要颜色: 是颜色类型(输入.取("type") ?? "")
                        ))
                    } else {
                        诊断.append("「\(元素名) · \(口名)」引用了子图 \(图名)，但图里没找到 output，已断开")
                    }
                }
            }
        }

        // 表面着色器 → Output 插槽 / 基线
        var 参数集: [PBRParamKey: PBRValue] = [:]
        if let 表面 {
            for 输入 in 表面.子元素("input") {
                guard let 输入名 = 输入.取("name") else { continue }
                guard let 键 = 参数键(输入名, 标准表面: 用标准表面) else {
                    诊断.append("跳过无法对应的表面参数「\(输入名)」")
                    continue
                }

                if let 上游 = 输入.取("nodename") {
                    guard 名字表[上游] != nil else {
                        // 有导出器把子图名写在 nodename 上（<input nodename="NG_rust" output="out"/>），
                        // 这里顺手接住：认得出图名就按子图处理，不认得出才报断线。
                        if let 源图 = 图表[上游], let 出口 = 源图.首个子元素("output"),
                           let 出口节点 = 出口.取("nodename"), 名字表[出口节点] != nil {
                            连线.append(MTLX连线(从: 出口节点, 到: MTLX连线.输出, 到口: 键.rawValue,
                                                要颜色: 是颜色参数(键)))
                        } else {
                            诊断.append("表面参数「\(输入名)」指向不存在的节点「\(上游)」，用基线默认值")
                        }
                        continue
                    }
                    连线.append(MTLX连线(从: 上游, 到: MTLX连线.输出, 到口: 键.rawValue, 要颜色: 是颜色参数(键)))
                } else if let 图名 = 输入.取("nodegraph") {
                    if let 源图 = 图表[图名],
                       let 出口 = 源图.首个子元素("output"),
                       let 出口节点 = 出口.取("nodename"),
                       名字表[出口节点] != nil {
                        连线.append(MTLX连线(从: 出口节点, 到: MTLX连线.输出, 到口: 键.rawValue, 要颜色: 是颜色参数(键)))
                    } else {
                        诊断.append("表面参数「\(输入名)」引用图 \(图名)，但接不进本项目的节点集，已断开")
                    }
                } else if let 原值 = 输入.取("value"), let 数字 = 解析数字(原值) {
                    let 期望: SocketKind = 是颜色参数(键) ? .color : .scalar
                var 值 = 转值(数字, 期望: 期望)
                if case .color = 期望, (输入.取("colorspace") ?? "").lowercased().contains("srgb") {
                    值 = 颜色转线性(值)
                }
                参数集[键] = 值
                }
            }
        } else {
            诊断.append("没有表面着色器，只保留节点图")
        }

        // 末尾带类型的 open_pbr_surface 也可能被当成节点写进候选（已排除），这里再兜一次
        节点列表 = 节点列表.map { 项 in
            var 副本 = 项
            副本.深度 = 算深度(项.名字, 上游表: 上游表(连线), 缓存: [:])
            return 副本
        }

        if !跳过.isEmpty {
            let 摘 = 跳过.prefix(5).joined(separator: "、")
            诊断.append("跳过 \(跳过.count) 个不支持的节点：\(摘)\(跳过.count > 5 ? " 等" : "")")
        }
        if 节点列表.isEmpty, 参数集.isEmpty {
            诊断.append("这份材质解析后是空的")
        }

        return MTLX材质(名称: 名称, 参数: 参数集, 节点: 节点列表, 连线: 连线, 诊断: 诊断)
    }

    // MARK: 元素判定

    static func 是节点元素(_ 元素: MTLX元素) -> Bool {
        let 非节点: Set<String> = [
            "input", "output", "parameter", "token", "comment", "nodegraph",
            "material", "shaderref", "open_pbr_surface", "standard_surface",
            "surfacematerial", "look", "collection"
        ]
        return !非节点.contains(元素.名) && 元素.取("name") != nil
    }

    // MARK: 算术节点常量折叠

    /// 能一次算成常量的算术节点。项目还没有通用数学节点，带连线的这类节点只能跳过；
    /// 但「输入全是数字」的那些在真实 .mtlx 里占一大半（倍乘、加偏、钳制、反相），
    /// 折成一个常量节点就等于把它们全接上了，还保住下游连线。
    static let 可折叠: Set<String> = [
        "multiply", "add", "subtract", "divide", "power", "min", "max",
        "abs", "floor", "ceil", "round", "clamp", "saturate", "invert",
        "contrast", "modulo", "mod", "sin", "cos",
    ]

    /// 折叠成功返回该落成的常量节点（种类 + 参数口 + 值）。
    /// 只要有一条输入连着别的节点，就返回 nil——那种情况交给上层跳过并记诊断。
    static func 常量折叠(_ 元素: MTLX元素) -> (kind: ShaderNodeKind, 口: String, 值: PBRValue)? {
        let 键 = 规范名(元素.名)
        guard 可折叠.contains(键) else { return nil }
        let 要颜色 = 是颜色类型(元素.取("type") ?? "")

        var 值们: [[Double]] = []
        for 输入 in 元素.子元素("input") {
            if 输入.取("nodename") != nil || 输入.取("nodegraph") != nil { return nil }
            guard let 原文 = 输入.取("value"), let 数 = 解析数字(原文) else { continue }
            值们.append(数)
        }

        let 通道数 = 要颜色 ? 3 : 1
        var 结果: [Double] = []
        for 通道 in 0..<通道数 {
            let 甲 = 值们.count > 0 ? 通道值(值们[0], 通道) : nil
            let 乙 = 值们.count > 1 ? 通道值(值们[1], 通道) : nil
            let 丙 = 值们.count > 2 ? 通道值(值们[2], 通道) : nil
            let a = 甲 ?? 0
            let b = 乙 ?? 0
            var r: Double
            switch 键 {
            case "multiply": r = (甲 ?? 1) * (乙 ?? 1)
            case "add": r = a + b
            case "subtract": r = a - b
            case "divide":
                let 分母 = 乙 ?? 1
                r = 分母 == 0 ? 0 : a / 分母
            case "power": r = pow(max(甲 ?? 0, 0), 乙 ?? 1)
            case "min": r = Swift.min(甲 ?? 0, 乙 ?? 0)
            case "max": r = Swift.max(甲 ?? 0, 乙 ?? 0)
            case "abs": r = abs(a)
            case "floor": r = a.rounded(.down)
            case "ceil": r = a.rounded(.up)
            case "round": r = a.rounded()
            case "clamp": r = Swift.min(Swift.max(a, 乙 ?? 0), 丙 ?? 1)
            case "saturate": r = Swift.min(Swift.max(a, 0), 1)
            case "invert":
                // MaterialX 的定义：in*(1-amount) + (1-in)*amount，amount=1 时就是 1-in
                let 量 = 乙 ?? 1
                r = a * (1 - 量) + (1 - a) * 量
            case "contrast":
                let 量 = 乙 ?? 1
                let 轴 = 丙 ?? 0.5
                r = (a - 轴) * 量 + 轴
            case "mod", "modulo":
                let 模 = 乙 ?? 1
                r = 模 == 0 ? 0 : fmod(a, 模)
            case "sin": r = sin(a)
            case "cos": r = cos(a)
            default: return nil
            }
            结果.append(r.isFinite ? r : 0)
        }

        if 要颜色 {
            guard 结果.count == 3 else { return nil }
            return (.rgbConstant, "color", .color(PBRColor(结果[0], 结果[1], 结果[2])))
        }
        guard let 单值 = 结果.first else { return nil }
        return (.valueConstant, "value", .scalar(单值))
    }

    /// 单个通道的取值：颜色值可能只写一个数（灰度写法），这时按广播处理
    private static func 通道值(_ 值: [Double], _ 通道: Int) -> Double? {
        if 值.count == 1 { return 值[0] }
        if 通道 < 值.count { return 值[通道] }
        return 值.first
    }

    /// 和 `节点种类` 用同一套名字规范化：去掉 ND_ 前缀和 _color3 / _float 这类类型后缀
    static func 规范名(_ 元素名: String) -> String {
        var 键 = 元素名
        if 键.hasPrefix("ND_") { 键.removeFirst(3) }
        for 尾 in ["_color4", "_color3", "_vector4", "_vector3", "_vector2", "_float", "_integer", "_boolean"]
        where 键.hasSuffix(尾) {
            键.removeLast(尾.count)
            break
        }
        return 键
    }

    // MARK: 节点类型映射

    static func 节点种类(_ 元素名: String, 类型: String) -> ShaderNodeKind? {
        var 键 = 元素名
        if 键.hasPrefix("ND_") { 键.removeFirst(3) }
        for 尾 in ["_color4", "_color3", "_vector4", "_vector3", "_vector2", "_float", "_integer", "_boolean"]
        where 键.hasSuffix(尾) {
            键.removeLast(尾.count)
            break
        }
        let 是颜色 = 类型.contains("color") || 类型.contains("vector")

        switch 键 {
        case "constant", "uniform":
            return 是颜色 ? .rgbConstant : .valueConstant
        case "noise2d", "noise3d", "noise", "vertnoise",
             "cellularnoise2d", "cellularnoise3d", "fractal2d", "fractal3d":
            return .noiseTexture
        case "checkerboard", "checker":
            return .checkerTexture
        case "ramplr", "ramptb":
            return .gradientMap
        case "mix":
            return .mix
        case "hsvadjust", "saturate":
            return .hueSaturation
        case "range", "remap":
            return .remap
        case "fresnel":
            return .fresnel
        case "bump", "bump2d":
            return .bump
        default:
            return nil
        }
    }

    /// MaterialX 的 input 名 → 本项目节点的 socket id
    static func 参数口(kind: ShaderNodeKind, 源名: String) -> String? {
        switch kind {
        case .output:
            return PBRParamKey(rawValue: 源名)?.rawValue
        case .rgbConstant:
            return (源名 == "color" || 源名 == "value" || 源名 == "in") ? "color" : nil
        case .valueConstant:
            return (源名 == "value" || 源名 == "in") ? "value" : nil
        case .checkerTexture:
            switch 源名 {
            case "color1": return "colorA"
            case "color2": return "colorB"
            case "uvtiling", "scale": return "scale"
            default: return nil
            }
        case .noiseTexture:
            switch 源名 {
            case "color1": return "colorA"
            case "color2": return "colorB"
            case "scale", "frequency": return "scale"
            case "octaves", "octaves2", "lacunarity", "detail": return "detail"
            default: return nil
            }
        case .gradientMap:
            switch 源名 {
            case "valuel", "valuet": return "colorA"
            case "valuer", "valueb": return "colorB"
            case "fac", "in": return "fac"
            default: return nil
            }
        case .mix:
            switch 源名 {
            case "mix", "fac": return "fac"
            case "bg", "in1": return "a"
            case "fg", "in2": return "b"
            default: return nil
            }
        case .hueSaturation:
            switch 源名 {
            case "in": return "color"
            case "hue": return "hue"
            case "sat", "saturation", "amount": return "sat"
            default: return nil
            }
        case .remap:
            switch 源名 {
            case "in": return "value"
            case "inlow": return "fromMin"
            case "inhigh": return "fromMax"
            case "outlow": return "toMin"
            case "outhigh": return "toMax"
            default: return nil
            }
        case .fresnel:
            switch 源名 {
            case "ior": return "ior"
            case "bias": return "bias"
            default: return nil
            }
        case .bump:
            switch 源名 {
            case "height", "in": return "height"
            case "scale", "strength": return "strength"
            default: return nil
            }
        case .imageTexture:
            // 图像节点已经没有任何输入端口：图本身就是一组复合颜色，再插颜色口没有意义
            return nil
        }
    }

    /// 构造材质时用：要读 ShaderNodeKind 的插槽表，只能在主线程上算
    static func 选输出口(_ kind: ShaderNodeKind, 期望: SocketKind) -> String? {
        let 口 = kind.outputs
        if let 命中 = 口.first(where: { $0.kind == 期望 }) { return 命中.id }
        return 口.first?.id
    }

    /// 颜色型参数（nonisolated 版本，避免跨隔离引用 PBRParamKey.isColor）
    static func 是颜色参数(_ 键: PBRParamKey) -> Bool {
        switch 键 {
        case .baseColor, .specularColor, .transmissionColor, .transmissionScatter,
             .subsurfaceColor, .fuzzColor, .coatColor, .emissionColor:
            return true
        default:
            return false
        }
    }

    /// 表面 input 名 → 本项目参数键
    static func 参数键(_ 源名: String, 标准表面: Bool) -> PBRParamKey? {
        if !标准表面 {
            if let 直取 = PBRParamKey(rawValue: 源名) { return 直取 }
            // OpenPBR 规范名与本项目键名有两处出入，单独接住
            switch 源名 {
            case "base_metalness": return .baseMetallic
            case "base_diffuse_roughness": return .baseRoughness
            default: return nil
            }
        }
        switch 源名 {
        case "base", "base_color": return .baseColor
        case "metalness": return .baseMetallic
        case "diffuse_roughness", "specular_roughness": return .baseRoughness
        case "specular": return .specularWeight
        case "specular_color": return .specularColor
        case "specular_IOR": return .specularIOR
        case "specular_anisotropy": return .specularAnisotropy
        case "transmission": return .transmissionWeight
        case "transmission_color": return .transmissionColor
        case "subsurface": return .subsurfaceWeight
        case "subsurface_color": return .subsurfaceColor
        case "subsurface_radius": return .subsurfaceRadius
        case "coat": return .coatWeight
        case "coat_color": return .coatColor
        case "coat_roughness": return .coatRoughness
        case "coat_IOR": return .coatIOR
        case "sheen", "fuzz": return .fuzzWeight
        case "sheen_color": return .fuzzColor
        case "sheen_roughness": return .fuzzRoughness
        case "emission": return .emissionLuminance
        case "emission_color": return .emissionColor
        case "opacity": return .geometryOpacity
        default: return nil
        }
    }

    // MARK: 取值

    /// MaterialX 的 input type 属性 → 要不要按颜色处理
    static func 是颜色类型(_ 类型: String) -> Bool {
        类型.contains("color") || 类型.contains("vector")
    }

    static func 解析数字(_ 原文: String) -> [Double]? {
        var 文本 = 原文.trimmingCharacters(in: .whitespacesAndNewlines)
        // 兼容 color3(0.1, 0.2, 0.3) 这种带类型名包裹的写法
        if let 左括号 = 文本.firstIndex(of: "("), 文本.hasSuffix(")") {
            文本 = String(文本[文本.index(after: 左括号)..<文本.index(before: 文本.endIndex)])
        }
        let 数字 = 文本
            .split(whereSeparator: { $0 == "," || $0 == ";" || $0 == " " })
            .compactMap { Double($0) }
        return 数字.isEmpty ? nil : 数字
    }

    // MARK: 贴图

    /// 找贴图文件：`.mtlx` 里的 file 是相对 mtlx 所在目录的路径，不是相对当前工作目录。
    /// 顺手兼容两种情况——Windows 作者写的反斜杠路径、以及包里换了扩展名（写 .png 实存 .jpg），
    /// 这两种在真实材质包里都很常见，直接判「读不到」太浪费。
    static func 定位贴图(_ 原路径: String, 目录: URL) -> URL? {
        let 规范 = 原路径
            .replacingOccurrences(of: "\\", with: "/")
            .removingPercentEncoding ?? 原路径.replacingOccurrences(of: "\\", with: "/")
        let 候选 = 规范.hasPrefix("/")
            ? URL(fileURLWithPath: 规范)
            : 目录.appendingPathComponent(规范)
        let 管理器 = FileManager.default
        if 管理器.fileExists(atPath: 候选.path) { return 候选 }
        for 扩展 in ["png", "jpg", "jpeg", "tif", "tiff", "exr", "hdr", "bmp", "tga", "webp"] {
            let 换 = 候选.deletingPathExtension().appendingPathExtension(扩展)
            if 管理器.fileExists(atPath: 换.path) { return 换 }
        }
        return nil
    }

    /// 解码贴图（sRGB 语义），给视口贴图库用
    static func 读图(_ url: URL) -> CGImage? {
        guard let 源 = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(源, 0, nil)
    }

    /// 缩到 1×1 再读像素：等价于整图平均，比逐像素遍历快几个数量级。
    /// 图是 sRGB 编码的、PBRColor 存线性值，这里顺手转。
    static func 平均色(_ url: URL) -> PBRColor? {
        guard let 图 = 读图(url) else { return nil }
        var 像素: [UInt8] = [0, 0, 0, 0]
        guard let 空间 = CGColorSpace(name: CGColorSpace.sRGB),
              let 上下文 = CGContext(
                data: &像素, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: 空间, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        上下文.interpolationQuality = .medium
        上下文.draw(图, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return PBRColor(sRGB转线性(Double(像素[0]) / 255),
                        sRGB转线性(Double(像素[1]) / 255),
                        sRGB转线性(Double(像素[2]) / 255))
    }

    /// MaterialX 的颜色常量默认按线性（lin_rec709）解释，只有显式写了
    /// `colorspace="srgb"` 的才要转一次；不转的话导入的灰色会比原文件亮一档。
    static func 颜色转线性(_ 值: PBRValue) -> PBRValue {
        guard case .color(let 色) = 值 else { return 值 }
        return .color(PBRColor(sRGB转线性(色.r), sRGB转线性(色.g), sRGB转线性(色.b)))
    }

    static func sRGB转线性(_ 值: Double) -> Double {
        let c = Swift.min(Swift.max(值, 0), 1)
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    static func 转值(_ 数字: [Double], 期望: SocketKind) -> PBRValue {
        if 数字.count >= 3 {
            return .color(PBRColor(数字[0], 数字[1], 数字[2]))
        }
        let 单 = 数字.first ?? 0
        return 期望 == .color ? .color(PBRColor(gray: 单)) : .scalar(单)
    }

    // MARK: 深度（排布用）

    static func 上游表(_ 连线: [MTLX连线]) -> [String: [String]] {
        var 表: [String: [String]] = [:]
        for 线 in 连线 {
            表[线.到, default: []].append(线.从)
        }
        return 表
    }

    static func 算深度(_ 名: String, 上游表: [String: [String]], 缓存: [String: Int]) -> Int {
        var 缓存 = 缓存
        var 访问: Set<String> = []
        return 深度递归(名, 上游表: 上游表, 缓存: &缓存, 访问: &访问)
    }

    private static func 深度递归(
        _ 名: String,
        上游表: [String: [String]],
        缓存: inout [String: Int],
        访问: inout Set<String>
    ) -> Int {
        if let 已知 = 缓存[名] { return 已知 }
        guard !访问.contains(名) else { return 0 }
        访问.insert(名)
        var 最大 = 0
        for 上游 in 上游表[名] ?? [] {
            最大 = max(最大, 深度递归(上游, 上游表: 上游表, 缓存: &缓存, 访问: &访问) + 1)
        }
        访问.remove(名)
        缓存[名] = 最大
        return 最大
    }

    // MARK: 构造材质（主线程：产出 MaterialAsset）

    static func 构造材质(_ 材质: MTLX材质) -> MaterialAsset {
        var id表: [String: UUID] = [:]
        var 节点列表: [ShaderNode] = []

        let 排序后 = 材质.节点.sorted {
            算深度($0.名字, 上游表: 上游表(材质.连线), 缓存: [:]) <
            算深度($1.名字, 上游表: 上游表(材质.连线), 缓存: [:])
        }

        for (序号, 项) in 排序后.enumerated() {
            let id = UUID()
            id表[项.名字] = id
            let 列 = CGFloat(项.深度 + 1)
            let 位置 = CGPoint(x: 760 - 列 * 230, y: 90 + CGFloat(序号) * 150)
            节点列表.append(ShaderNode(
                id: id,
                kind: 项.kind,
                title: 项.名字,
                position: 位置,
                params: 项.参数
            ))
        }

        let 输出ID = UUID()
        节点列表.append(ShaderNode(
            id: 输出ID,
            kind: .output,
            title: "OpenPBR 输出",
            position: CGPoint(x: 760, y: 120)
        ))

        var 种类表: [String: ShaderNodeKind] = [:]
        for 项 in 材质.节点 { 种类表[项.名字] = 项.kind }

        var 连线列表: [NodeLink] = []
        for 线 in 材质.连线 {
            guard let 从 = id表[线.从],
                  let 上游kind = 种类表[线.从],
                  let 从口 = 选输出口(上游kind, 期望: 线.要颜色 ? .color : .scalar)
            else { continue }
            let 到 = (线.到 == MTLX连线.输出) ? 输出ID : id表[线.到]
            guard let 到 else { continue }
            连线列表.append(NodeLink(
                fromNode: 从,
                fromSocket: 从口,
                toNode: 到,
                toSocket: 线.到口
            ))
        }

        var 基线 = OpenPBRParams()
        for (键, 值) in 材质.参数 { 基线[键] = 值 }

        let 备注 = "由 .mtlx 导入：\(节点列表.count - 1) 个节点 / \(连线列表.count) 条连线"
            + (材质.诊断.isEmpty ? "" : "，\(材质.诊断.count) 条降级提示")

        return MaterialAsset(
            name: 材质.名称,
            baseline: 基线,
            graph: NodeGraph(nodes: 节点列表, links: 连线列表),
            note: 备注
        )
    }

    // MARK: 自检

    /// 在控制台跑一遍：不碰界面、不写文件，只验证「解析 → 构造 → 求值」这条链。
    static func 自检() -> String {
        let 示例 = """
        <?xml version="1.0" encoding="UTF-8"?>
        <materialx version="1.39">
          <noise2d name="noise_a" type="color3">
            <input name="scale" type="float" value="4.5" />
            <input name="octaves" type="integer" value="3" />
          </noise2d>
          <ramplr name="ramp_a" type="color3">
            <input name="valuel" type="color3" value="0.10, 0.20, 0.30" />
            <input name="valuer" type="color3" value="0.90, 0.80, 0.70" />
            <input name="fac" type="float" nodename="noise_a" />
          </ramplr>
          <range name="range_a" type="float">
            <input name="in" type="float" value="0.5" />
            <input name="inlow" type="float" value="0" />
            <input name="inhigh" type="float" value="1" />
            <input name="outlow" type="float" value="0.1" />
            <input name="outhigh" type="float" value="0.9" />
          </range>
          <open_pbr_surface name="surface_a" type="surfaceshader">
            <input name="base_color" type="color3" nodename="ramp_a" />
            <input name="base_metalness" type="float" value="0.15" />
            <input name="specular_roughness" type="float" value="0.32" />
            <input name="coat_weight" type="float" nodename="range_a" />
            <input name="image_tex" type="color3" nodename="tex_missing" />
          </open_pbr_surface>
          <surfacematerial name="mat_a" type="material">
            <input name="surfaceshader" type="surfaceshader" nodename="surface_a" />
          </surfacematerial>
        </materialx>
        """

        do {
            let 文档 = try 解析(文本: 示例)
            var 行: [String] = ["== .mtlx 自检 ==", "解析到 \(文档.材质.count) 份材质"]

            for 材质 in 文档.材质 {
                行.append("· \(材质.名称)")
                行.append("  中间文档：\(材质.节点.count) 节点 / \(材质.连线.count) 连线 / 基线 \(材质.参数.count) 项")
                for 诊断 in 材质.诊断 { 行.append("  ⚠︎ \(诊断)") }

                let 资产 = 构造材质(材质)
                行.append("  材质资产：\(资产.graph.nodes.count) 节点 / \(资产.graph.links.count) 连线 / 驱动 \(资产.drivenKeys.count) 个参数")
                行.append("  驱动键：\(资产.drivenKeys.map(\.rawValue).sorted().joined(separator: ", "))")

                let 求值 = NodeGraphEvaluator.evaluate(资产.graph)
                行.append("  求值覆盖：\(求值.overrides.count) 项，环检测：\(求值.cycleDetected ? "有环" : "无环")")
                for 项 in 求值.overrides.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                    行.append("    \(项.key.rawValue) = \(项.value)")
                }
            }
            return 行.joined(separator: "\n")
        } catch {
            return "自检失败：\(error.localizedDescription)"
        }
    }
}
