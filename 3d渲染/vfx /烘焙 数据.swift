import Foundation
import simd

// MARK: - 特效烘焙 缓存（DCC 语义的「点缓存」）
//
// 口径：
// - 烘焙 = 把**有状态的模拟**从"视口实时现算"改成"离线固定步长算一遍、逐帧存起来"。
//   之后拖播放头 / 播放 / 出图全都读缓存，同一帧永远同一结果（现算那条路是靠真实
//   帧时长积分的，掉一帧就变样，不可复现）。
// - 存的是**模拟状态**，不是参数、不是图：粒子池里每颗粒子的位置 / 速度 / 随机量。
//   参数真值仍然只有一份（SceneObject.特效），这里绝不存第二份参数。
// - 一个发射器一个目录，一帧一个文件。跳跃播放要随机访问某一帧，按目录分层最省事；
//   烘焙中途失败也只会缺帧，不会把已烘好的帧弄坏。
// - 文件是给未来的布料 / 刚体等模拟共用的**同一套容器**：载荷与模拟品类无关，
//   品类只决定载荷里那 48 字节怎么解释（见 `粒子GPU`）。

// MARK: - 一帧的载荷

/// 一个发射器在一帧上的完整模拟状态。
///
/// 粒子池是**环形**的（写指针回绕覆盖最老的），所以除了粒子本身，
/// 写指针 / 累计时刻 / 帧序号也必须一起存：不然读回来接着跑会立刻错位。
struct 烘焙发射器帧 {
    /// 环形写指针（下一颗新粒子落在哪个槽）
    var 写指针: UInt32 = 0
    /// 这个池累计模拟了多少秒（喂给湍流噪声当时间轴）
    var 时刻: Float = 0
    /// 池自己数了多少帧（喂给发射随机数）
    var 帧序号: UInt32 = 0
    /// 只存活着的粒子（寿命字段 > 0 的那些），空槽不占空间
    var 粒子: [粒子GPU] = []

    /// 一帧的近似字节数（进度/统计用）
    var 字节数: Int { 烘焙帧文件.头大小 + 粒子.count * MemoryLayout<粒子GPU>.stride }
}

// MARK: - 单帧文件

/// 一帧一个文件。布局固定，头部自带魔数与帧率，防止读到过期/别的帧率的缓存。
///
/// ```
/// 0   magic      [4]  "VFB1"
/// 4   帧率        f64
/// 12  帧号        i32   ← 与文件名双保险，防止人工改名后错位
/// 16  写指针      u32
/// 20  粒子数      u32
/// 24  时刻        f32
/// 28  帧序号      u32
/// 32  粒子数据    粒子数 × 48 字节
/// ```
enum 烘焙帧文件 {

    static let 魔数: [UInt8] = Array("VFB1".utf8)
    static let 头大小 = 32

    static func 写(_ 帧: 烘焙发射器帧, 帧号: Int, 帧率: Double, 到 url: URL) throws {
        var 数据 = Data(capacity: 头大小 + 帧.粒子.count * MemoryLayout<粒子GPU>.stride)
        数据.append(contentsOf: 魔数)

        var 率 = 帧率
        withUnsafeBytes(of: &率) { 数据.append(contentsOf: $0) }

        var 号 = Int32(帧号)
        withUnsafeBytes(of: &号) { 数据.append(contentsOf: $0) }

        var 指针 = 帧.写指针
        withUnsafeBytes(of: &指针) { 数据.append(contentsOf: $0) }

        var 数 = UInt32(帧.粒子.count)
        withUnsafeBytes(of: &数) { 数据.append(contentsOf: $0) }

        var 刻 = 帧.时刻
        withUnsafeBytes(of: &刻) { 数据.append(contentsOf: $0) }

        var 序 = 帧.帧序号
        withUnsafeBytes(of: &序) { 数据.append(contentsOf: $0) }

        // 粒子是 POD，直接按字节摊平（端序与内存布局一致，同机读写，不做跨端兼容）
        帧.粒子.withUnsafeBytes { 原 in
            数据.append(contentsOf: 原)
        }

        try 数据.write(to: url, options: .atomic)
    }

    static func 读(from url: URL, 期望帧号: Int) -> 烘焙发射器帧? {
        guard let 数据 = try? Data(contentsOf: url, options: .alwaysMapped),
              数据.count >= 头大小
        else { return nil }

        guard 数据.prefix(4).elementsEqual(魔数) else { return nil }

        // 第 12 字节的帧号必须对得上：文件被改名 / 缓存目录被别的工程占用时直接当无效
        let 号 = 数据.withUnsafeBytes { $0.load(fromByteOffset: 12, as: Int32.self) }
        guard Int(号) == 期望帧号 else { return nil }

        let 指针 = 数据.withUnsafeBytes { $0.load(fromByteOffset: 16, as: UInt32.self) }
        let 数 = 数据.withUnsafeBytes { $0.load(fromByteOffset: 20, as: UInt32.self) }
        let 刻 = 数据.withUnsafeBytes { $0.load(fromByteOffset: 24, as: Float.self) }
        let 序 = 数据.withUnsafeBytes { $0.load(fromByteOffset: 28, as: UInt32.self) }

        let 字节 = Int(数) * MemoryLayout<粒子GPU>.stride
        guard 数据.count >= 头大小 + 字节 else { return nil }

        var 粒子 = [粒子GPU](repeating: 粒子GPU(), count: Int(数))
        粒子.withUnsafeMutableBytes { 目标 in
            数据.withUnsafeBytes { 源 in
                guard let 起 = 源.baseAddress else { return }
                memcpy(目标.baseAddress!, 起 + 头大小, 字节)
            }
        }

        return 烘焙发射器帧(写指针: 指针, 时刻: 刻, 帧序号: 序, 粒子: 粒子)
    }
}

// MARK: - 缓存目录

/// 烘焙缓存的落盘位置与目录管理。
///
/// 放在用户目录的 `cache` 下（`~/Documents/cg app/cache/特效烘焙`），
/// 跟工程文件本身分开：缓存是可再生的，删了重烘就行，不该跟着 .cg 工程一起搬。
enum 烘焙缓存目录 {

    static var 根: URL {
        let dir = 用户目录.缓存.appendingPathComponent("特效烘焙", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 一个发射器的缓存目录：`.../特效烘焙/<发射器 UUID>/`
    static func 发射器目录(_ id: UUID) -> URL {
        let dir = 根.appendingPathComponent(id.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func 帧文件(_ id: UUID, 帧: Int) -> URL {
        发射器目录(id).appendingPathComponent(String(format: "%06d.vfb", 帧))
    }

    /// 这个发射器已经烘了哪些帧（扫目录，文件名即帧号）
    static func 已有帧(_ id: UUID) -> Set<Int> {
        let dir = 发射器目录(id)
        guard let 文件们 = try? FileManager.default.contentsOfDirectory(at: dir,
                                                                   includingPropertiesForKeys: nil)
        else { return [] }
        var 结果: Set<Int> = []
        for 文件 in 文件们 where 文件.pathExtension == "vfb" {
            if let 帧 = Int(文件.deletingPathExtension().lastPathComponent) {
                结果.insert(帧)
            }
        }
        return 结果
    }

    static func 清空发射器(_ id: UUID) {
        try? FileManager.default.removeItem(at: 发射器目录(id))
    }

    static func 清空全部() {
        try? FileManager.default.removeItem(at: 根)
    }

    /// 缓存占用（MB），给界面显示"烘焙占了多少地方"
    static func 占用兆字节() -> Double {
        let 根目录 = 根
        guard let 枚举器 = FileManager.default.enumerator(at: 根目录,
                                                        includingPropertiesForKeys: [.fileSizeKey])
        else { return 0 }
        var 字节: Int = 0
        for case let 文件 as URL in 枚举器 {
            if let 尺寸 = try? 文件.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                字节 += 尺寸
            }
        }
        return Double(字节) / 1_048_576
    }
}

// MARK: - 缓存有效性

/// 一份烘焙缓存对应的是「这一套发射器参数」。参数一改，缓存立刻失效 ——
/// 跟 PT 那边 `特效版本` 是同一个道理：宁可从零重烘，也不要放一段对不上的假动画。
struct 烘焙指纹: Equatable {
    /// 发射器 id → 设置
    var 表: [UUID: 特效设置] = [:]
    var 帧率: Double = 24

    /// 参与烘焙的全部发射器（按 id 排序，保证同一个场景每次算出来的指纹稳定）
    static func 生成(_ 发射器们: [(id: UUID, 设置: 特效设置)], 帧率: Double) -> 烘焙指纹 {
        var 表: [UUID: 特效设置] = [:]
        for 项 in 发射器们 { 表[项.id] = 项.设置 }
        return 烘焙指纹(表: 表, 帧率: 帧率)
    }
}
