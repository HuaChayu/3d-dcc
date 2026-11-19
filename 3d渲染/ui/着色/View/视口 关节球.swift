import SwiftUI
import simd

// MARK: - 视口关节球（摆姿势的把手）
//
// 大纲里的「角色」选中后，视口在这一身骨骼的每个终点（膝盖、脚踝、指尖…）画一颗实心球。
// 拖动球 = 绕该骨的头点旋动这一节，子骨跟着一起走 —— 这就是调动作的最小交互。
//
// 画在 Canvas 里、命中交给 AppKit 事件监视器（和对象坐标轴同一套路数）：
// RealityKit 的实体拾取要和模型几何抢命中，且球是"屏幕恒定大小"的控件，不适合做实体。

/// 一颗关节球：世界坐标就是这一节骨的世界坐标（骨点 × 角色物体），屏幕只是投影
struct 关节球项: Identifiable {
    var 角色ID: UUID
    var 骨下标: Int
    var 骨名: String
    var 世界: SIMD3<Float>
    var 屏幕: CGPoint

    var id: String { "\(角色ID.uuidString)#\(骨下标)" }
}

/// 点中哪颗球就选中哪一节骨。这里只记「选的是谁」——转多少度、绕哪根轴、
/// 键盘敲多少，全部交给全局三轴手柄那一套，关节本身不另写拖动。
struct 关节选中项: Equatable {
    var 角色ID: UUID
    var 骨下标: Int
    var 骨路径: String
    var 骨名: String
    var 键: String { "\(角色ID.uuidString)#\(骨下标)" }
}

/// 一次关节拖动：按下瞬间的骨世界旋转 + 父骨世界旋转。
/// 角度增量全部基于按下瞬间的基准累计，最后只写成「这一节骨在父骨空间的局部旋转」，
/// 骨点世界坐标仍旧由 角色姿态.解算 统一复合 —— 这里不存任何位置。
struct 关节拖动 {
    var 角色ID: UUID
    var 骨下标: Int
    var 骨路径: String
    /// 枢轴：这颗骨的世界坐标（骨尾点）
    var 枢轴: SIMD3<Float>
    var 起点: CGPoint
    /// 拖三轴时才有：绕哪根轴转
    var 几何: 手柄轴几何?
    /// 拖关节球时才有：把这节骨的上游段对准鼠标
    var 对齐: 关节对齐?
    /// 按下瞬间该骨的世界旋转
    var 骨世界旋转: simd_quatf
    /// 按下瞬间父骨的世界旋转（根骨为单位）
    var 父世界旋转: simd_quatf
    /// 当前累计角度（度），只用来判有没有新进展
    var 角度: Double = 0
}

/// 拖关节球的基准：把鼠标点投到「过骨尾、正对相机」的平面上，
/// 再让这节骨的头→尾方向指向它。骨长不变，所以关节只会落在以父关节为心的球面上拖动。
struct 关节对齐 {
    /// 平面过这一点（按下瞬间的骨尾世界坐标）
    var 平面点: SIMD3<Float>
    /// 平面法线（相机视线，正对屏幕）
    var 平面法线: SIMD3<Float>
    /// 这节骨的头，角色局部坐标
    var 头: SIMD3<Float>
    /// 静止姿态下 头→尾 的方向（角色局部，已归一化）
    var 静止方向: SIMD3<Float>
}

/// 木偶抓取会话：按下关节球时建一次。
/// 拓扑表建起来偏贵（要合并关节），但同一身骨架可以一直复用，松手也不清。
struct 木偶抓取会话 {
    var 角色ID: UUID
    var 骨下标: Int
    /// 被抓的那个关节（拓扑里的节点号）
    var 节点: Int
    var 拓扑: 角色木偶.拓扑
    /// 建这张表时这一身有几根骨：骨数据被重导过就作废重建
    var 骨数: Int
}

/// 关节球绘制层：只画不接收事件，命中由事件监视器统一处理。
struct 关节球层: View {
    var 球们: [关节球项]
    var 激活: String?

    var body: some View {
        Canvas { ctx, _ in
            for 球 in 球们 {
                let 亮 = 激活 == 球.id
                let r: CGFloat = 亮 ? 7 : 5
                let 框 = CGRect(x: 球.屏幕.x - r, y: 球.屏幕.y - r, width: r * 2, height: r * 2)
                let 圆 = Path(ellipseIn: 框)
                // 实心球 + 一圈主色描边：压在皮肤上也看得清，但不至于糊住模型
                ctx.fill(圆, with: .color(.white.opacity(亮 ? 1 : 0.88)))
                ctx.stroke(
                    圆,
                    with: .color(Theme.accent.opacity(亮 ? 1 : 0.7)),
                    style: StrokeStyle(lineWidth: 亮 ? 2.4 : 1.4, lineCap: .round)
                )
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - 视口容器圆盘（角色容器的落脚点）

/// 选中角色时脚下那只圆盘。位置跟着「拓扑根骨」走，摆姿势、做动画、
/// 角色自己跑出去，圆盘都自然跟上 —— 它挂在同一棵骨树上，靠层级同步，不靠采样。
/// 它只是「容器在哪」的显示代理 + 「拖整身」的点击区：只读，不存数据、不写数据。
struct 角色圆盘柄 {
    var 角色ID: UUID?
    /// 圆心的屏幕位置
    var 屏幕: CGPoint
    /// 水平面采样一圈投影后的屏幕点（俯视近正圆，侧视压成椭圆）
    var 圈: [CGPoint]
    /// 屏幕上的最大半径，判命中用
    var 半径: CGFloat
}

struct 角色圆盘层: View {
    var 盘: 角色圆盘柄
    var 高亮: Bool = false

    var body: some View {
        Canvas { ctx, _ in
            guard 盘.圈.count > 2 else { return }
            var 路径 = Path()
            路径.move(to: 盘.圈[0])
            for 点 in 盘.圈.dropFirst() { 路径.addLine(to: 点) }
            路径.closeSubpath()

            // 半透明底：看得出整身归这个圈管，又不至于糊住脚下的模型
            ctx.fill(路径, with: .color(Theme.accent.opacity(高亮 ? 0.16 : 0.09)))
            ctx.stroke(
                路径,
                with: .color(Theme.accent.opacity(高亮 ? 0.95 : 0.6)),
                style: StrokeStyle(lineWidth: 高亮 ? 1.8 : 1.2, dash: [5, 4])
            )

            // 盘心十字：俯视时圆心压在脚上也能一眼找到
            var 十字 = Path()
            let r: CGFloat = 7
            十字.move(to: CGPoint(x: 盘.屏幕.x - r, y: 盘.屏幕.y))
            十字.addLine(to: CGPoint(x: 盘.屏幕.x + r, y: 盘.屏幕.y))
            十字.move(to: CGPoint(x: 盘.屏幕.x, y: 盘.屏幕.y - r))
            十字.addLine(to: CGPoint(x: 盘.屏幕.x, y: 盘.屏幕.y + r))
            ctx.stroke(十字, with: .color(Theme.accent.opacity(0.9)),
                       style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
        }
        .allowsHitTesting(false)
    }
}
