import Foundation
import simd

// MARK: - 键盘数值变换

/// 键盘处理结果：告诉上层这个键算不算被吃掉
enum 数值键结果 {
    /// 状态变了，刷新一次预览
    case 继续
    /// ⏎ / 空格：结算最后一段并结束
    case 确认
    /// esc：整段回滚，回到长按那一刻
    case 取消
    /// 不认识的键，交还给上层的快捷键逻辑
    case 忽略
}

/// 长按 W / E / R 之后进入的「键盘数值变换」会话：不拖手柄，直接敲数值给变换量。
///
/// 输入是流式的：遇到新的轴字母先把上一段结算掉再开新的一段，
/// 所以 `x-0.01x4` 读作「X 轴 -0.01，再来一次 X 轴 4」，两次累加后 X 轴总共 +3.99。
/// 会话本身只记「每个轴要变多少」，真正写进场景的是面板那边，这样 esc 能整段回滚。
struct 数值变换会话 {
    /// 这次会话在干什么：移动 / 旋转 / 缩放，决定数值的单位与作用对象
    let 模式: 变换模式
    /// 多选时的枢轴（单选就是物体自己的中心），缩放与旋转要绕它推开
    let 枢轴: SIMD3<Double>

    /// 当前锁定的轴：还没敲 x / y / z 就是 nil，此时输数字也不生效
    private(set) var 轴: 手柄轴?
    /// 正在敲的这一段数字，允许中途状态（"-"、"-0."）
    private(set) var 文本: String = ""
    /// 乘号后面的倍数：`0.1x4` 里那个 4。数字后面紧跟的 x 是乘号，不算切轴
    private(set) var 乘数文本: String = ""
    /// 已经结算掉的段，按轴累加（同一个轴可以来好几段）
    private(set) var 累计: [手柄轴: Double] = [:]
    /// 结算过多少段，纯粹给提示条用
    private(set) var 已结算段数 = 0

    init(模式: 变换模式, 枢轴: SIMD3<Double>) {
        self.模式 = 模式
        self.枢轴 = 枢轴
    }

    /// 数值单位：只影响提示条文案，不参与计算
    var 单位: String {
        switch 模式 {
        case .移动: return "位移"
        case .旋转: return "角度°"
        case .缩放: return "倍率"
        }
    }

    /// 乘号已经按下（倍数可能还没敲）
    private(set) var 乘号中 = false

    /// 单个数字串能不能读成值（中途态 "-"、"-0." 读不出来）
    private static func 读数(_ 串: String) -> Double? {
        guard !串.isEmpty, 串 != "-", 串 != ".", 串 != "-." else { return nil }
        return Double(串)
    }

    /// 正在敲的这一段：主数 × 倍数。倍数没敲完就当没乘（`0.1x` 还是 0.1）
    var 当前值: Double? {
        guard let 主 = Self.读数(文本) else { return nil }
        guard let 倍 = Self.读数(乘数文本) else { return 主 }
        return 主 * 倍
    }

    /// 正在敲的那段原文，给状态栏显示用（`-0.01×4`）
    var 输入片段: String {
        乘号中 ? 文本 + "×" + 乘数文本 : 文本
    }

    /// 没敲轴字母就直接输数字时的兜底轴：移动 / 旋转按 X，缩放不给轴（等比）
    private var 默认轴: 手柄轴? { 模式 == .缩放 ? nil : .x }

    /// 数字类输入进来先把轴定好，否则敲了数字也没人接
    private mutating func 确保轴() {
        if 轴 == nil, let 默认轴 { 轴 = 默认轴 }
    }

    /// 每个轴的合计（已结算 + 正在敲的那段）
    var 各轴合计: [手柄轴: Double] {
        var 结果 = 累计
        if let 轴, let 当前值 {
            结果[轴, default: 0] += 当前值
        } else if 轴 == nil, 模式 == .缩放, let 当前值 {
            // 缩放不锁轴 = 等比，三个轴吃同一个量
            for 轴 in 手柄轴.allCases { 结果[轴, default: 0] += 当前值 }
        }
        return 结果
    }

    /// 会话里有没有实打实的数值：没有就不必惊动场景
    var 有数值: Bool { !各轴合计.isEmpty }

    /// 键盘输入。x / y / z 选轴，数字与句号拼数值，⌫ 退格，⏎ 确认，esc 取消。
    /// 紧跟在数字后面的 x（或 * / ×）是乘号：`0.1x4` 读作 0.1×4，而不是切到 X 轴
    mutating func 按键(_ 键: String) -> 数值键结果 {
        switch 键 {
        case "x":
            guard !文本.isEmpty else { return 切轴("x") }
            // 已经在乘号里又按了一次：当成取消乘号
            if 乘号中 {
                乘号中 = false
                乘数文本 = ""
            } else {
                乘号中 = true
                乘数文本 = ""
            }
            return .继续

        case "y", "z":
            return 切轴(键)

        case "*", "×":
            guard !文本.isEmpty else { return .忽略 }
            乘号中 = true
            乘数文本 = ""
            return .继续

        case "backspace":
            // 退格逐层退：倍数 → 乘号 → 主数 → 轴
            if !乘数文本.isEmpty {
                乘数文本.removeLast()
            } else if 乘号中 {
                乘号中 = false
            } else if !文本.isEmpty {
                文本.removeLast()
            } else {
                轴 = nil
            }
            return .继续

        case "return", "enter", "space":
            结算当前段()
            return .确认

        case "esc":
            return .取消

        case ".", "。", "．":
            // 一段里只认一个小数点；空段开头补 0，直接敲 "-." 也能继续
            if 乘号中 {
                guard !乘数文本.contains(".") else { return .忽略 }
                乘数文本 = (乘数文本.isEmpty || 乘数文本 == "-") ? 乘数文本 + "0." : 乘数文本 + "."
                return .继续
            }
            确保轴()
            guard !文本.contains(".") else { return .忽略 }
            文本 = (文本.isEmpty || 文本 == "-") ? 文本 + "0." : 文本 + "."
            return .继续

        case "-", "−":
            // 负号只作用于整段，再按一次取反
            确保轴()
            if 乘号中 {
                乘数文本 = 乘数文本.hasPrefix("-")
                    ? String(乘数文本.dropFirst())
                    : "-" + 乘数文本
            } else {
                文本 = 文本.hasPrefix("-")
                    ? String(文本.dropFirst())
                    : "-" + 文本
            }
            return .继续

        default:
             guard 键.count == 1, let 字符 = 键.first, 字符.isNumber else { return .忽略 }
             确保轴()
             if 乘号中 { 乘数文本.append(字符) } else { 文本.append(字符) }
             return .继续
        }
    }

    /// 切轴：先把上一段结算掉（连写的 `x0.1y0.2` 靠这一步分开）
    private mutating func 切轴(_ 键: String) -> 数值键结果 {
        guard let 新轴 = 手柄轴(rawValue: 键) else { return .忽略 }
        结算当前段()
        轴 = 新轴
        return .继续
    }

    /// 把正在敲的这一段并进累计，然后把文本腾空给下一段
    mutating func 结算当前段() {
        if let 值 = 当前值, 值 != 0 {
            if let 轴 {
                累计[轴, default: 0] += 值
                已结算段数 += 1
            } else if 模式 == .缩放 {
                // 等比缩放没有具体轴，落到三个轴上，预览那边当倍率用
                for 轴 in 手柄轴.allCases { 累计[轴, default: 0] += 值 }
                已结算段数 += 1
            }
        }
        文本 = ""
        乘数文本 = ""
        乘号中 = false
    }
}
