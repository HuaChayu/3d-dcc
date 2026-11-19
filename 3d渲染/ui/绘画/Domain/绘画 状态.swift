import Foundation
import Observation
import simd

/// 绘画会话：把「视口鼠标事件 → 相机射线 → 表面命中 → 3D 撒点 → 投影成 UV splat → 写图层」
/// 这条链子串起来，并持有刷子参数与光标状态。
///
/// 为什么不塞进 ViewportScene：那层只管相机与选中，绘画是另一条完全独立的管线，
/// 而且它唯一的输出是「图层纹理」，跟场景图（RealityKit 那边）没有任何关系。
@MainActor
@Observable
final class PaintSession {

    static let shared = PaintSession()

    // MARK: 状态

    /// 全局绘画开关。关着的时候视口事件照旧全部走选中/轨道，一点额外开销都没有。
    var 启用 = false {
        didSet { if 启用 != oldValue { 光标 = nil; 光标在表面 = false; 正在画 = false } }
    }

    var brush = PaintBrush()

    /// 视口本地坐标（左上原点）的刷子位置，nil = 指针不在视口内
    var 光标: CGPoint?
    /// 指针下此刻是否有可画表面（光标画实线还是虚线）
    var 光标在表面 = false
    /// 光标落在表面的世界位置与法线：画圆环朝向用
    var 光标世界点: SIMD3<Float>?
    /// 光标处表面法线。预览圈要按它把笔刷摊到切平面上——没有它，圈只能画成正对屏幕的圆，
    /// 看着就像「笔刷永远贴视口」。
    var 光标世界法线: SIMD3<Float>?
    /// 正在拖笔
    private(set) var 正在画 = false
    /// 最近落笔的对象，图层面板据此定位
    private(set) var 当前对象ID: UUID?

    // MARK: 内部

    /// 上一次落笔的世界位置：鼠标移动快的时候两个事件之间能隔出好几个笔刷半径，
    /// 中间得补点，否则线条是虚线段的
    private var 上次世界点: SIMD3<Float>?
    /// 已同步给引擎的可见对象顺序，变了才刷新图集映射
    private var 已同步对象: [UUID] = []
    /// 本帧攒下的 splat，一次落笔提交，避免一个事件里反复合成图集
    private var 待提交: [UUID: [PaintSplat]] = [:]

    private init() {}

    /// 新建项目：清掉一切与上一份文档绑定过的会话状态。
    /// 笔刷参数（brush）属于用户偏好，保留；挂在旧物体 ID 上的东西一律丢掉。
    func 重置会话() {
        启用 = false
        当前对象ID = nil
        光标 = nil
        光标在表面 = false
        光标世界点 = nil
        光标世界法线 = nil
        正在画 = false
        上次世界点 = nil
        已同步对象.removeAll()
        待提交.removeAll()
    }

    // MARK: 场景同步

    /// 视口每次同步场景时调一次：把「会进 PT 的可见对象顺序」告诉引擎，
    /// 图集 slice 按这个顺序分配，PT 转译端查的是同一份映射。
    func 同步场景(_ objects: [SceneObject]) {
        let ids = objects.filter { $0.isVisible }.map(\.id)
        guard ids != 已同步对象 else { return }
        已同步对象 = ids
        PaintEngine.shared.场景对象ID = ids
        PaintEngine.shared.刷新图集(objectIDs: ids)
    }

    // MARK: 指针

    /// 指针在视口内移动（没按键）。只更新光标，不落笔。
    func 移动(point: CGPoint, size: CGSize, objects: [SceneObject], 相机: 视口相机) {
        #if DEBUG
        // PAINT_SELFTEST=1 时，第一次鼠标悬停即跑一遍自检（走真实的拾取→采样→落笔→合成）
        if ProcessInfo.processInfo.environment["PAINT_SELFTEST"] == "1", !PaintEngine.自检已跑 {
            PaintEngine.自检已跑 = true
            NSLog("PAINT自检 触发")
            PaintEngine.shared.自检(objects: objects.filter(\.isVisible), 相机: 相机)
            NSLog("PAINT自检 完成")
        }
        #endif
        guard 启用 else { return }
        光标 = point
        // 每帧做一次全三角形遍历，量级是几千个三角形，够快；
        // 真画起来再上 BVH，现在不提前优化
        let hit = 射线命中(point: point, size: size, objects: objects, 相机: 相机)
        光标在表面 = hit != nil
        光标世界点 = hit?.worldPoint
        光标世界法线 = hit?.worldNormal
    }

    /// 滚轮调笔刷半径：向上滚变粗，向下变细，按指数缩放所以粗细两头手感一致
    func 调整笔刷(滚动 delta: CGFloat) {
        let 系数 = Float(exp(Double(delta) * 0.045))
        brush.radius = min(max(brush.radius * 系数, 0.008), 2.0)
    }

    /// 撤销上一笔（Cmd+Z / 面板按钮）。只撤当前对象的最后一笔。
    @discardableResult
    func 撤销() -> Bool {
        guard let id = 当前对象ID else { return false }
        return PaintEngine.shared.撤销(objectID: id)
    }

    /// 面板上点对象：把「当前画的是谁」切过去
    func 选中对象(_ id: UUID?) {
        当前对象ID = id
    }

    func 移出视口() {
        光标 = nil
        光标在表面 = false
        光标世界点 = nil
        光标世界法线 = nil
    }

    /// 左键按下。返回 true 表示这次按下被绘画吃掉了（事件不再往下走，
    /// 否则 RealityView 会同时开始轨道旋转，画面会跑）。
    func 按下(point: CGPoint, size: CGSize, objects: [SceneObject], 相机: 视口相机) -> Bool {
        guard 启用 else { return false }
        guard let hit = 射线命中(point: point, size: size, objects: objects, 相机: 相机) else {
            光标 = point; 光标在表面 = false; 光标世界法线 = nil
            return false
        }
        正在画 = true
        光标 = point
        光标在表面 = true
        光标世界点 = hit.worldPoint
        光标世界法线 = hit.worldNormal
        上次世界点 = hit.worldPoint
        待提交.removeAll()
        涂抹(hit: hit, objects: objects, 相机: 相机)
        提交()
        return true
    }

    /// 左键拖动：沿世界空间补点，保证快速划过也连着。
    func 拖动(point: CGPoint, size: CGSize, objects: [SceneObject], 相机: 视口相机) {
        guard 启用, 正在画 else { return }
        光标 = point
        guard let hit = 射线命中(point: point, size: size, objects: objects, 相机: 相机) else {
            // 划出物体边缘：圆环改虚线，避免让人以为还在往上画
            光标在表面 = false
            光标世界点 = nil
            光标世界法线 = nil
            return
        }
        光标在表面 = true
        光标世界点 = hit.worldPoint
        光标世界法线 = hit.worldNormal

        if let 上次 = 上次世界点 {
            let 距离 = simd_length(hit.worldPoint - 上次)
            // 补点步长取笔刷半径的一半：再密就是浪费，再疏就会露出颗粒
            let 步长 = max(brush.radius * max(brush.spacing, 0.1) * 0.5, 1e-4)
            let 段数 = min(Int(距离 / 步长), 8)
            if 段数 > 1 {
                for i in 1..<段数 {
                    let t = Float(i) / Float(段数)
                    let 中点 = 上次 + (hit.worldPoint - 上次) * t
                    // 中间点沿同一条表面走：重新打射线比插值准（曲面会跑偏）
                    let dir = simd_normalize(中点 - 相机.位置)
                    if let 补 = PaintPicker.拾取(origin: 相机.位置, direction: dir, objects: objects) {
                        涂抹(hit: 补, objects: objects, 相机: 相机)
                    }
                }
            }
        }
        涂抹(hit: hit, objects: objects, 相机: 相机)
        上次世界点 = hit.worldPoint
        提交()
    }

    func 抬起() {
        guard 启用 else { return }
        正在画 = false
        上次世界点 = nil
        待提交.removeAll()
    }

    // MARK: 落笔

    private func 涂抹(hit: PaintHit, objects: [SceneObject], 相机: 视口相机) {
        guard let object = objects.first(where: { $0.id == hit.objectID }) else { return }
        let 基 = 笔刷基(法线: hit.worldNormal, 相机: 相机)
        let splats = PaintPicker.采样(object: object, hit: hit, brush: brush, 基: 基)
        guard !splats.isEmpty else { return }
        待提交[hit.objectID, default: []].append(contentsOf: splats)
        当前对象ID = hit.objectID
    }

    /// 一批 splat 一次提交：图层纹理只写一遍，图集也只合成一遍
    private func 提交() {
        guard !待提交.isEmpty else { return }
        for (objectID, splats) in 待提交 {
            // 擦除只是削 alpha，和形状无关：它既不吃遮罩，也不受反转影响。
            // 绘画和镂空都吃同一套遮罩 + 同一个反转开关（形状决定"哪里有效"）
            let 用遮罩 = brush.mode != .擦除
            PaintEngine.shared.落笔(objectID: objectID, splats: splats, mode: brush.mode,
                                 mask: 用遮罩 ? brush.mask : .无,
                                 反转: 用遮罩 && brush.maskInvert,
                                 缩放: brush.maskScale,
                                 旋转: brush.maskRot,
                                 平移: brush.maskOffset)
        }
        待提交.removeAll()
    }

    private func 射线命中(point: CGPoint,
                         size: CGSize,
                         objects: [SceneObject],
                         相机: 视口相机) -> PaintHit? {
        guard let (origin, direction) = 相机.射线(屏幕点: point, 视图尺寸: size) else { return nil }
        return PaintPicker.拾取(origin: origin, direction: direction, objects: objects)
    }

    // MARK: 笔刷落位

    /// 笔刷在某个命中点的切平面基。预览圈和落笔都走这一个函数 ——
    /// 两边各算一套的话，圈里看到的图案和真正画下去的必然对不上。
    func 笔刷基(法线: SIMD3<Float>, 相机: 视口相机) -> PaintBrushFrame {
        PaintBrushFrame(normal: 法线, 屏幕角: brush.maskRot, 相机: 相机)
    }

    /// 光标处的基；指针不在表面上时为 nil（此时画虚线圆）
    func 光标基(相机: 视口相机) -> PaintBrushFrame? {
        guard let n = 光标世界法线 else { return nil }
        return 笔刷基(法线: n, 相机: 相机)
    }

    /// 切平面上的笔刷圆盘 → 屏幕的仿射矩阵（输入圆盘坐标 -1…1，y 向下）。
    ///
    /// 这是「曲面处的一阶近似」：圆盘上取 X/Y 两个方向各一个半径点投到屏幕，
    /// 得到局部 2×2 映射。笔刷尺寸远小于相机距离时，透视误差小到看不出来；
    /// 换来的是预览能直接用 CGAffineTransform 画，不用手搓投影矩阵。
    func 圆盘到屏幕(size: CGSize, 相机: 视口相机) -> CGAffineTransform? {
        guard let 基 = 光标基(相机: 相机), let 中心 = 光标世界点 else { return nil }
        let r = brush.radius
        guard let p0 = 相机.投影(中心, 视图尺寸: size),
              let px = 相机.投影(中心 + 基.x * r, 视图尺寸: size),
              let py = 相机.投影(中心 + 基.y * r, 视图尺寸: size) else { return nil }
        return CGAffineTransform(
            a: px.x - p0.x, b: px.y - p0.y,
            c: py.x - p0.x, d: py.y - p0.y,
            tx: p0.x, ty: p0.y
        )
    }

    // MARK: 光标尺寸

    /// 刷子圆环的屏幕半径（像素）。按命中点的深度换算，所以远处的圈会小，
    /// 和笔迹在世界里的实际覆盖一致 —— 这是「所见即所得」的关键。
    func 光标像素半径(size: CGSize, 相机: 视口相机) -> CGFloat {
        let 目标 = 光标世界点 ?? 相机.目标点
        let 每像素 = 相机.每像素世界长度(at: 目标, 视图尺寸: size)
        guard 每像素 > 1e-6 else { return 8 }
        return CGFloat(max(brush.radius / 每像素, 2))
    }
}
