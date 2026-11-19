import Foundation

// MARK: - 域模版（外部键 → 域记录 的通用机件）

/// 域模版：一个域对「外部键（`SceneObject.id.uuidString` / 灯键）→ 域记录」这层映射的通用机件。
///
/// 为什么要有它：几何 / 灯光 / 变换三个接线原先各写一遍同样的四张表 ——
/// 「键→域标识」「键→上次写进域的值」「键→逐键版本」「本轮键序 + 键集」，各配一把锁，
/// 各写一份 `段版本(键们:)` 求和。三份代码逐行同构，改一处得改三处。
/// 现在统一到这里，接线只剩「什么时候该写域」这一件事。
///
/// 职责边界（钉死，防止它长成第二个域）：
/// - 它**不持有**记录内容，只是键到标识的映射 + “上次写了什么”的备忘，不是第二份真相；
/// - 它**不碰**记录域的写入口，写入令牌校验仍然在域那一侧；
/// - 它不判断“值变没变”，只接受调用方给的结论（`版本该推进`）。
///
/// 并发：锁由调用方注入。几何用 `NSLock`、变换用 `NSRecursiveLock`（它的写入路径会重入），
/// 灯光单线程写入但同样持有锁实例 —— 锁的对象语义一律不变，只是从“各写一份”改成“各持一份”。
final class 域模版<域, 值> {

    let 锁: NSLocking

    private var 标识表: [String: 稳定标识<域>] = [:]
    private var 值表: [String: 值] = [:]
    private var 版本表: [String: UInt64] = [:]

    /// 整段内容版本：任何一份记录的值真变了、或记录消失，都 +1。
    /// 只回答“这段几何/这批灯有没有被动过”，回答不了“动的是谁”（那是逐键版本的活）。
    private(set) var 内容版本: UInt64 = 0
    /// 本轮同步进来的键序：决定消费端装配顺序，必须与模型顺序一致。
    private(set) var 键序: [String] = []
    private(set) var 键集: Set<String> = []
    /// 诊断计数（不参与任何判定）
    private(set) var 同步次数: UInt64 = 0
    private(set) var 实际写入次数: UInt64 = 0

    init(锁: NSLocking = NSLock()) {
        self.锁 = 锁
    }

    // MARK: 读

    func 标识(键: String) -> 稳定标识<域>? {
        锁.lock()
        defer { 锁.unlock() }
        return 标识表[键]
    }

    func 值(键: String) -> 值? {
        锁.lock()
        defer { 锁.unlock() }
        return 值表[键]
    }

    /// 逐键版本号：段缓存 / 加速结构判“这一份动没动”用它。
    func 记录版本(键: String) -> UInt64 {
        锁.lock()
        defer { 锁.unlock() }
        return 版本表[键] ?? 0
    }

    /// 段版本：这批键对应记录的逐键版本之和。
    /// 单调不减 —— 任何一份真变了，和必变；全都没变，和不变。
    /// （记录消失时和会变小，所以调用方只能拿它判“变没变”，不能当计数器用。）
    func 段版本(键们: [String]) -> UInt64 {
        锁.lock()
        defer { 锁.unlock() }
        var 和: UInt64 = 0
        for 键 in 键们 {
            和 &+= 版本表[键] ?? 0
        }
        return 和
    }

    /// 当前全部缓存值（回收轮询要遍历“这批键都指向哪些网格”）。
    func 全部值() -> [String: 值] {
        锁.lock()
        defer { 锁.unlock() }
        return 值表
    }

    func 键序快照() -> [String] {
        锁.lock()
        defer { 锁.unlock() }
        return 键序
    }

    func 键集快照() -> Set<String> {
        锁.lock()
        defer { 锁.unlock() }
        return 键集
    }

    // MARK: 写（各接线在锁外决定“该不该写域”，这里只记账）

    /// 记入一条：标识 + 上次值 + 是否推进逐键版本。
    /// - Parameter 版本该推进: 由调用方按“真正影响成像的字段变没变”判定，
    ///   名字这类不参与渲染的字段不该推进版本（推进了等于让消费端白清一次缓存）。
    /// - Returns: 该键当前的逐键版本
    @discardableResult
    func 记入(键: String, 标识: 稳定标识<域>?, 值: 值, 版本该推进: Bool) -> UInt64 {
        锁.lock()
        defer { 锁.unlock() }
        if let 标识 { 标识表[键] = 标识 }
        值表[键] = 值
        var 版本 = 版本表[键] ?? 0
        if 版本该推进 {
            版本 &+= 1
            版本表[键] = 版本
            内容版本 &+= 1
        }
        return 版本
    }

    /// 移除一条（记录已从域消失）。返回它的标识，由调用方交给域做请求删除。
    func 移除(键: String) -> 稳定标识<域>? {
        锁.lock()
        defer { 锁.unlock() }
        let 标识 = 标识表.removeValue(forKey: 键)
        值表[键] = nil
        版本表[键] = nil
        return 标识
    }

    /// 收尾：替换本轮键序 / 键集，同步次数 +1。
    /// - Returns: 上一轮有、这一轮没有的键（= 消失的键，调用方逐个 `移除`）
    @discardableResult
    func 收尾(键序 新键序: [String]) -> [String] {
        锁.lock()
        defer { 锁.unlock() }
        同步次数 &+= 1
        let 新集 = Set(新键序)
        let 消失 = 标识表.keys.filter { !新集.contains($0) }
        键序 = 新键序
        键集 = 新集
        return 消失
    }

    /// 内容版本 +1（记录消失、或外部池被动过时用）。
    func 推进内容版本() {
        锁.lock()
        内容版本 &+= 1
        锁.unlock()
    }

    /// 记一次“真的写了域”（诊断口径，不影响任何判定）。
    func 计一次写入() {
        锁.lock()
        实际写入次数 &+= 1
        锁.unlock()
    }
}
