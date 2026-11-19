import Foundation
import simd

// MARK: - 通用网格中间表示

/// 导入侧统一落在这一层，和具体格式解耦。
/// 之所以不直接产出 PTGeometry.Piece：Piece 没有子网格/材质信息，
/// 而一个外部模型往往是「一个物体 + 多材质」，必须先留子集信息再决定怎么拆。
struct 导入材质: Sendable, Equatable {
    var 名称: String = "默认材质"
    /// 线性基础色（和各格式的 sRGB 输入不同，构造时已经转成线性）
    var 基础色: SIMD3<Float> = SIMD3(0.72, 0.72, 0.72)
    var 金属度: Float = 0
    var 粗糙度: Float = 0.5
    var 不透明度: Float = 1
    var 自发光: SIMD3<Float> = .zero
    var IOR: Float = 1.5
    var 双面: Bool = true
    /// 基础色贴图原始字节（glTF 的 baseColorTexture / OBJ 的 map_Kd）。
    /// 后台解析期只搬字节不解码，回主线程再交给贴图库。
    var 基础色贴图: Data? = nil
    /// 贴图原始文件名或内嵌标记，只用于备注与诊断
    var 基础色贴图名: String? = nil
    /// 基础色之外的通道图（粗糙度/金属度/自发光/AO 等）。
    /// 不做节点树复刻，一张图就是一个图像贴图节点，直接接到 OpenPBR 对应输入口。
    var 通道图: [导入通道图] = []
    /// 没落到任何 OpenPBR 口上的图像节点：只建图像贴图节点、不连线，摆在那里给用户自己接。
    var 游离图: [导入通道图] = []
}

/// 一张通道贴图：用途由图像名推断，上层按用途找 OpenPBR 的输入口
struct 导入通道图: Sendable, Equatable {
    /// roughness / metallic / emission / alpha / specular
    var 用途: String
    var 名: String
    var 字节: Data
}

/// 索引区间 → 材质下标
struct 导入子集: Sendable, Equatable {
    var 材质: Int?
    var 起始: Int
    var 数量: Int
    /// 文件里写的材质名（USD 的 material:binding、FBX 的材质槽名）。
    /// App 侧材质库按名字匹配，匹配不到再退回 材质 下标里的近似值。
    var 材质名: String? = nil
}

/// 单个顶点上的一个骨骼权重
struct 导入骨权重: Sendable, Equatable {
    /// 顶点组下标（blend 的顶点组下标，和骨架骨骼按名字对）
    var 组: Int
    /// 组名 = 骨骼名；读网格阶段还不知道，等组装时拿 Object.defbase 填
    var 骨名: String = ""
    var 重量: Float
}

struct 导入网格: Sendable {
    var 名称: String
    var 顶点: [SIMD3<Float>] = []
    var 法线: [SIMD3<Float>] = []
    var UV: [SIMD2<Float>] = []
    var 索引: [UInt32] = []
    var 子集: [导入子集] = []
    /// 每个顶点的蒙皮权重（最多留 4 个，按重量降序）。没有顶点组的网格留空。
    var 权重: [[导入骨权重]] = []
    /// 保留节点自带的局部变换；展平层级时为 identity
    var 变换: simd_float4x4 = matrix_identity_float4x4

    var 三角形数: Int { 索引.count / 3 }
    var 顶点数: Int { 顶点.count }

    init(名称: String) {
        self.名称 = 名称
    }

    /// 属性长度对齐：缺法线/UV 时补齐，多出来的截掉。
    /// 各格式解析器都只需要往数组里塞，不必各自保证对齐。
    mutating func 对齐属性(缺省法线: SIMD3<Float> = SIMD3(0, 1, 0)) {
        if 法线.count != 顶点.count {
            // 缺法线时必须按拓扑算出真实法线，绝不能一律填 缺省法线。
            // 曾经这里无条件填常量：不带 vn 的 OBJ/PLY 整段法线全同，
            // 再过上轴校正 (0,1,0)→(0,0,-1)，落盘时被「全同」压成常量段，
            // 打开与 QuickLook 预览都只剩一片没有明暗的死色，看着就像模型碎了。
            if 法线.isEmpty, let 算出 = 计算顶点法线() {
                法线 = 算出
            } else {
                法线 = Array(repeating: 缺省法线, count: 顶点.count)
            }
        }
        if UV.count != 顶点.count {
            UV = Array(repeating: .zero, count: 顶点.count)
        }
    }

    /// 按面法线、以面积加权累加的平滑顶点法线。
    /// 缺顶点或索引时返回 nil，由调用方退回缺省常量。
    func 计算顶点法线() -> [SIMD3<Float>]? {
        guard !顶点.isEmpty, 索引.count >= 3 else { return nil }
        var 累计 = [SIMD3<Float>](repeating: .zero, count: 顶点.count)
        var i = 0
        while i + 2 < 索引.count {
            let a = Int(索引[i]), b = Int(索引[i + 1]), c = Int(索引[i + 2])
            i += 3
            guard a < 顶点.count, b < 顶点.count, c < 顶点.count else { continue }
            // 叉积模长即两倍三角形面积，直接累加天然带面积加权
            let 面 = simd_cross(顶点[b] - 顶点[a], 顶点[c] - 顶点[a])
            累计[a] += 面
            累计[b] += 面
            累计[c] += 面
        }
        var 有结果 = false
        for k in 累计.indices where simd_length_squared(累计[k]) > 1e-12 {
            累计[k] = simd_normalize(累计[k])
            有结果 = true
        }
        return 有结果 ? 累计 : nil
    }

    mutating func 重建默认子集() {
        guard 子集.isEmpty, !索引.isEmpty else { return }
        子集 = [导入子集(材质: nil, 起始: 0, 数量: 索引.count)]
    }
}

/// 文件里的一个对象（节点）。
///
/// 之前接入层固定「一个文件 = 一个 SceneObject」，把整包网格塞进同一个网格库条目，
/// 于是 Blender 里几十个带父子关系的对象导进来只剩一个物体，名字、位置、层级全没了。
/// 现在解析器把对象树填出来，接入层按节点拆成多个 SceneObject。
struct 导入节点: Sendable {
    var 名称: String
    /// 父节点在 导入场景.节点 里的下标；nil = 顶层
    var 父: Int? = nil
    /// 指向 导入场景.网格 的下标；空 = 该节点没有几何（空物体 / 相机 / 灯光 / 骨架）
    var 网格: [Int] = []
    /// 节点类型，写报告用（"网格" / "空物体" / "相机" / "灯光" / "骨架" …）
    var 类型: String = "网格"
    /// 骨架节点专用：骨骼层级路径（"手.L/小指.01.L"），父在前、用 / 分层
    var 骨骼: [String] = []
    /// 骨架节点专用：骨骼几何（rest 姿态头尾点，已换算到场景空间）
    var 骨骼数据: [导入骨骼] = []
    /// 骨架节点专用：当前姿态下每根骨的局部矩阵（bPoseChannel.pose_mat），键 = 骨名
    var 姿态: [String: simd_float4x4] = [:]
}

/// 解析出来的单根骨骼。头尾点是 rest pose 的世界坐标，
/// 接入层把它换算成 角色骨骼 存进角色资产，预览就能直接画骨架。
struct 导入骨骼: Sendable {
    var 名称: String
    /// 层级路径（"躯干/胸/手.L"）
    var 路径: String
    /// 父骨在数组里的下标；根骨 nil
    var 父: Int? = nil
    var 头: SIMD3<Float> = .zero
    var 尾: SIMD3<Float> = .zero
    /// rest 局部矩阵（armature 空间）。蒙皮变形 = pose_mat · rest矩阵⁻¹
    var rest矩阵: simd_float4x4 = matrix_identity_float4x4
}

struct 导入场景: Sendable {
    var 源文件: URL
    var 网格: [导入网格] = []
    var 材质: [导入材质] = []
    /// 非网格来源的材质（MaterialX `.mtlx`）：文件里没有几何，解析产物直接挂这里，
    /// 由接入层落进着色域材质库。其它格式恒为空，不参与网格/子集逻辑。
    var mtlx材质: [MTLX材质] = []
    /// 文件自带的对象节点树。空 = 该格式没提供节点信息，接入层按旧行为整包一个物体。
    var 节点: [导入节点] = []
    /// 是否按 节点 拆成多个 SceneObject（由「保留层级」开关决定，调度层回填）
    var 按节点拆分: Bool = false
    /// 文件自己声明的上轴（USD 的 upAxis、FBX 的 UpAxis）。解析器读到就填，
    /// 调度侧优先采信它，其次才用格式默认值 —— 否则 Blender 存出来的 Z-up usda 会躺倒。
    var 文件上轴: 上轴? = nil
    /// 解析器想告诉用户的事（材质丢失、图元跳过、单位推断等）
    var 报告: [String] = []

    var 总三角形: Int { 网格.reduce(0) { $0 + $1.三角形数 } }
    var 总顶点: Int { 网格.reduce(0) { $0 + $1.顶点数 } }
}

// MARK: - 坐标与变换

enum 网格变换 {
    /// Z 向上 → App 的 Y 向上：绕 X 轴 -90°。
    /// e_y → -z，e_z → +y，Det = +1（不含镜像，法线不会反）。
    static let z转y: simd_float4x4 = simd_float4x4(columns: (
        SIMD4<Float>(1, 0, 0, 0),
        SIMD4<Float>(0, 0, -1, 0),
        SIMD4<Float>(0, 1, 0, 0),
        SIMD4<Float>(0, 0, 0, 1)
    ))

    /// Y 向上 → Z 向上（导出给 Blender / UE 时用），是 z转y 的转置（正交逆）
    static let y转z: simd_float4x4 = z转y.transpose

    static func 上轴校正(from 源: 上轴, 到 目标: 上轴 = .y) -> simd_float4x4 {
        switch (源, 目标) {
        case (.y, .y), (.z, .z): return matrix_identity_float4x4
        case (.z, .y): return z转y
        case (.y, .z): return y转z
        }
    }

    static func 缩放(_ s: Float) -> simd_float4x4 {
        simd_float4x4(diagonal: SIMD4<Float>(s, s, s, 1))
    }

    /// 法线用逆转置，否则非均匀缩放下法线会歪
    static func 法线矩阵(_ m: simd_float4x4) -> simd_float3x3 {
        let 上 = simd_float3x3(
            SIMD3<Float>(m.columns.0.x, m.columns.0.y, m.columns.0.z),
            SIMD3<Float>(m.columns.1.x, m.columns.1.y, m.columns.1.z),
            SIMD3<Float>(m.columns.2.x, m.columns.2.y, m.columns.2.z)
        )
        return 上.inverse.transpose
    }
}

extension 导入网格 {
    mutating func 施加变换(_ m: simd_float4x4) {
        guard m != matrix_identity_float4x4 else { return }
        变换 = m * 变换
    }

    /// 把 变换 烘焙进顶点，随后变换归位（导出/接入场景前必须调一次）
    mutating func 烘焙变换() {
        guard 变换 != matrix_identity_float4x4 else { return }
        let 法 = 网格变换.法线矩阵(变换)
        for i in 顶点.indices {
            let p = 变换 * SIMD4<Float>(顶点[i], 1)
            顶点[i] = SIMD3<Float>(p.x, p.y, p.z)
        }
        for i in 法线.indices {
            let n = 法 * 法线[i]
            let 长 = simd_length(n)
            法线[i] = 长 > 1e-20 ? n / 长 : SIMD3(0, 1, 0)
        }
        变换 = matrix_identity_float4x4
    }

    var 包围盒: (最小: SIMD3<Float>, 最大: SIMD3<Float>)? {
        guard let 首 = 顶点.first else { return nil }
        var 最小 = 首, 最大 = 首
        for v in 顶点 {
            最小 = simd_min(最小, v)
            最大 = simd_max(最大, v)
        }
        return (最小, 最大)
    }

    var 最大边长: Float {
        guard let 盒 = 包围盒 else { return 0 }
        let 尺寸 = 盒.最大 - 盒.最小
        return max(尺寸.x, max(尺寸.y, 尺寸.z))
    }

    /// 面法线加权重算（面积权重：叉积长度天然带面积，不必再除）
    mutating func 重算法线() {
        guard !索引.isEmpty else { return }
        var 累加 = Array(repeating: SIMD3<Float>.zero, count: 顶点.count)
        var i = 0
        while i + 2 < 索引.count {
            let a = Int(索引[i]), b = Int(索引[i + 1]), c = Int(索引[i + 2])
            i += 3
            guard a < 顶点.count, b < 顶点.count, c < 顶点.count else { continue }
            let n = simd_cross(顶点[b] - 顶点[a], 顶点[c] - 顶点[a])
            if simd_length_squared(n) < 1e-24 { continue }
            累加[a] += n
            累加[b] += n
            累加[c] += n
        }
        法线 = 累加.map { n in
            let 长 = simd_length(n)
            return 长 > 1e-20 ? n / 长 : SIMD3(0, 1, 0)
        }
    }

    /// 焊接重复顶点。按「位置 + 法线 + UV」三件套判等，
    /// 只按位置焊会把硬边/UV 缝一起焊掉，是导入时最常见的翻车点。
    mutating func 焊接顶点(精度: Float = 1e-5) {
        guard !顶点.isEmpty else { return }
        对齐属性()
        var 映射 = [UInt64: UInt32]()
        var 新顶点: [SIMD3<Float>] = []
        var 新法线: [SIMD3<Float>] = []
        var 新UV: [SIMD2<Float>] = []
        var 重映射 = Array(repeating: UInt32(0), count: 顶点.count)
        let 倒数 = 1 / max(精度, 1e-9)

        func 量化(_ v: Float) -> UInt64 { UInt64(bitPattern: Int64((v * 倒数).rounded())) }

        for i in 顶点.indices {
            let p = 顶点[i]
            let n = 法线[i]
            let t = UV[i]
            var 哈希 = 量化(p.x) &* 73856093
            哈希 ^= 量化(p.y) &* 19349663
            哈希 ^= 量化(p.z) &* 83492791
            哈希 ^= 量化(n.x) &* 2654435761
            哈希 ^= 量化(n.y) &* 40503
            哈希 ^= 量化(n.z) &* 97
            哈希 ^= 量化(t.x) &* 6364136223
            哈希 ^= 量化(t.y) &* 1442695040

            if let 命中 = 映射[哈希] {
                重映射[i] = 命中
            } else {
                let 新下标 = UInt32(新顶点.count)
                映射[哈希] = 新下标
                新顶点.append(p)
                新法线.append(n)
                新UV.append(t)
                重映射[i] = 新下标
            }
        }

        顶点 = 新顶点
        法线 = 新法线
        UV = 新UV
        索引 = 索引.map { 重映射[Int($0)] }
        // 子集区间在焊接后仍然按索引顺序成立，数量不变
    }

    /// 多边形 fan 三角化：吃 n 边形（n>=3）的顶点环，吐出三角形索引
    static func 扇形三角化(_ 环: [UInt32], 写入 到: inout [UInt32]) {
        guard 环.count >= 3 else { return }
        for i in 1..<(环.count - 1) {
            到.append(环[0])
            到.append(环[i])
            到.append(环[i + 1])
        }
    }

    // MARK: - 任意多边形三角化（耳切）

    /// 三角化结果
    struct 三角化结果: Sendable {
        /// 三角形列表：每 3 个一组，值是「环内局部下标」（不是顶点池下标）
        var 索引: [Int] = []
        /// 是否非凸，走了耳切而不是简单扇形
        var 凹: Bool = false
        /// 是否被判成退化面（点数不足 / 共线 / 面积≈0），调用方应整面跳过
        var 退化: Bool = false
    }

    // 【注意】三角化会把「面边界」丢掉：这里只吐三角形索引，没有「这个三角形属于哪个原始面」的映射，
    // 全链路（导入网格 → 网格库 → 存档 → PTScene）都是三角粒度，存档里也没有面数据。
    // 以后若要做面级语义（light tree 按面聚合、面级 portal、面级 CDF），必须从导入层开始补一份
    // 「每个面产出的三角形数」（前缀式的面 → 三角映射），并一路贯穿上面四层，约 10 个文件，
    // 且要处理旧存档兼容（缺这条时退回三角粒度，不能直接崩）。
    // 【注意】禁止用共面 / 共边聚合去事后猜面：同平面相邻的两个独立面会被错合，猜出来的面既不可逆也不稳定，
    // 一旦被 light tree 或面级 CDF 拿去当重要性采样单位，误差会直接进画面。
    /// 任意简单多边形三角化。凸多边形扇形出一遍，凹多边形走耳切（Ear Clipping），
    /// 保证不吐出「落在多边形外面」的三角形 —— 这是扇形硬切凹面的典型翻车。
    ///
    /// - 输入：环上各角坐标，绕序顺/逆都行（内部统一成逆时针后再按原始绕序还原每片三角形朝向）
    /// - 输出：`环内局部下标`三元组，调用方自己映射成顶点池下标
    /// - 退化输入（点数 < 3、全部共线、面积≈0）返回 `退化 = true` + 空索引，由调用方跳过该面
    static func 三角化多边形(_ 环点: [SIMD3<Float>]) -> 三角化结果 {
        var 结果 = 三角化结果()
        guard 环点.count >= 3 else {
            结果.退化 = true
            return 结果
        }

        // 用面自身包围盒尺度做容差基准：绝对坐标大但面很小的模型不会被误判成退化
        var 最小 = 环点[0], 最大 = 环点[0]
        for p in 环点 {
            最小 = simd_min(最小, p)
            最大 = simd_max(最大, p)
        }
        let 尺度 = max(simd_length(最大 - 最小), 1e-9)
        let 点容差 = 尺度 * 1e-6
        let 面积容差 = 尺度 * 尺度 * 1e-9

        // 1. 去掉相邻重复角（含首尾闭合），保留原始下标
        var 序: [Int] = []
        序.reserveCapacity(环点.count)
        for i in 环点.indices {
            if let 末 = 序.last, simd_length(环点[i] - 环点[末]) <= 点容差 { continue }
            序.append(i)
        }
        while 序.count >= 2, simd_length(环点[序[0]] - 环点[序[序.count - 1]]) <= 点容差 {
            序.removeLast()
        }
        guard 序.count >= 3 else {
            结果.退化 = true
            return 结果
        }

        // 2. Newell 法向：非平面多边形也能给出稳定的面积加权法向
        var 新尔 = SIMD3<Float>.zero
        for k in 序.indices {
            let a = 环点[序[k]]
            let b = 环点[序[(k + 1) % 序.count]]
            新尔.x += (a.y - b.y) * (a.z + b.z)
            新尔.y += (a.z - b.z) * (a.x + b.x)
            新尔.z += (a.x - b.x) * (a.y + b.y)
        }
        guard simd_length(新尔) > 面积容差 else {
            结果.退化 = true
            return 结果
        }

        // 3. 投影到法向主轴平面（右手三元组，保证 2D 叉积与 3D 绕向同构）
        let ax = abs(新尔.x), ay = abs(新尔.y), az = abs(新尔.z)
        var 平面: [(Float, Float)] = []
        平面.reserveCapacity(序.count)
        for i in 序 {
            let p = 环点[i]
            if az >= ax, az >= ay {
                平面.append((p.x, p.y))
            } else if ax >= ay {
                平面.append((p.y, p.z))
            } else {
                平面.append((p.z, p.x))
            }
        }

        // 4. 统一成逆时针
        let 面积 = 有向面积(平面)
        guard abs(面积) > 面积容差 else {
            结果.退化 = true
            return 结果
        }
        if 面积 < 0 {
            平面.reverse()
            序.reverse()
        }

        // 5. 凸性判定（顺手记账，报告里区分「扇形」和「耳切」）
        if !是凸(平面) { 结果.凹 = true }

        // 6. 耳切主循环
        var 剩余 = Array(平面.indices)
        var 出: [Int] = []
        出.reserveCapacity((平面.count - 2) * 3)
        while 剩余.count > 3 {
            var 切了 = false
            for k in 剩余.indices {
                let n = 剩余.count
                let i0 = 剩余[(k + n - 1) % n]
                let i1 = 剩余[k]
                let i2 = 剩余[(k + 1) % n]
                // 凹角不可能是耳
                guard 叉积(平面[i0], 平面[i1], 平面[i2]) > 面积容差 else { continue }
                // 耳三角内不能圈住其它顶点（贴在同一点上的重复点不算）
                var 干净 = true
                for j in 剩余 where j != i0 && j != i1 && j != i2 {
                    let q = 平面[j]
                    if 同点(q, 平面[i0], 点容差) || 同点(q, 平面[i1], 点容差) || 同点(q, 平面[i2], 点容差) { continue }
                    if 在三角形内(q, 平面[i0], 平面[i1], 平面[i2], 面积容差) {
                        干净 = false
                        break
                    }
                }
                guard 干净 else { continue }
                出.append(序[i0])
                出.append(序[i1])
                出.append(序[i2])
                剩余.remove(at: k)
                切了 = true
                break
            }
            if 切了 { continue }

            // 没找到耳：多半是多余的共线点挡着，拆掉它（不改变形状）
            if let 共线 = 剩余.firstIndex(where: { k in
                let n = 剩余.count
                return abs(叉积(平面[剩余[(k + n - 1) % n]], 平面[剩余[k]], 平面[剩余[(k + 1) % n]])) <= 面积容差
            }) {
                剩余.remove(at: 共线)
                continue
            }

            // 自交 / 病态面：扇形收尾，保证既不死循环也不整面丢掉
            if 剩余.count >= 3 {
                for k in 1..<(剩余.count - 1) {
                    出.append(序[剩余[0]])
                    出.append(序[剩余[k]])
                    出.append(序[剩余[k + 1]])
                }
            }
            剩余.removeAll()
            break
        }
        if 剩余.count == 3 {
            出.append(序[剩余[0]])
            出.append(序[剩余[1]])
            出.append(序[剩余[2]])
        }

        // 7. 朝向还原：内部统一成了逆时针，原本顺时针的环会被翻转，这里按 Newell 法向纠回来
        for t in stride(from: 0, to: 出.count - 2, by: 3) {
            let a = 环点[出[t]], b = 环点[出[t + 1]], c = 环点[出[t + 2]]
            if simd_dot(simd_cross(b - a, c - a), 新尔) < 0 {
                出.swapAt(t + 1, t + 2)
            }
        }

        结果.索引 = 出
        return 结果
    }

    private static func 有向面积(_ 点: [(Float, Float)]) -> Float {
        guard 点.count >= 3 else { return 0 }
        var s: Float = 0
        for i in 点.indices {
            let a = 点[i]
            let b = 点[(i + 1) % 点.count]
            s += a.0 * b.1 - b.0 * a.1
        }
        return s * 0.5
    }

    private static func 叉积(_ a: (Float, Float), _ b: (Float, Float), _ c: (Float, Float)) -> Float {
        (b.0 - a.0) * (c.1 - a.1) - (b.1 - a.1) * (c.0 - a.0)
    }

    private static func 是凸(_ 点: [(Float, Float)]) -> Bool {
        guard 点.count >= 3 else { return true }
        for i in 点.indices {
            let a = 点[(i + 点.count - 1) % 点.count]
            let b = 点[i]
            let c = 点[(i + 1) % 点.count]
            if 叉积(a, b, c) < 0 { return false }
        }
        return true
    }

    private static func 同点(_ a: (Float, Float), _ b: (Float, Float), _ 容差: Float) -> Bool {
        abs(a.0 - b.0) <= 容差 && abs(a.1 - b.1) <= 容差
    }

    private static func 在三角形内(
        _ p: (Float, Float),
        _ a: (Float, Float),
        _ b: (Float, Float),
        _ c: (Float, Float),
        _ 容差: Float
    ) -> Bool {
        let d1 = 叉积(a, b, p)
        let d2 = 叉积(b, c, p)
        let d3 = 叉积(c, a, p)
        return d1 >= -容差 && d2 >= -容差 && d3 >= -容差
    }
}

// MARK: - 合并 / 拆分

enum 网格组装 {
    /// 按子集拆成多个网格（每个子集一份），用于「一物体多材质」
    static func 按子集拆(_ 网格: 导入网格) -> [导入网格] {
        guard 网格.子集.count > 1 else { return [网格] }
        // 子集共享同一份顶点池，拆出来只需复制顶点 + 各自索引区间
        return 网格.子集.compactMap { 子集 in
            guard 子集.数量 > 0, 子集.起始 + 子集.数量 <= 网格.索引.count else { return nil }
            var 片 = 导入网格(名称: 网格.名称)
            片.顶点 = 网格.顶点
            片.法线 = 网格.法线
            片.UV = 网格.UV
            片.索引 = Array(网格.索引[子集.起始..<(子集.起始 + 子集.数量)])
            片.子集 = [导入子集(材质: 子集.材质, 起始: 0, 数量: 子集.数量)]
            片.变换 = 网格.变换
            // 顶点池是全量的，索引不变依然有效；顺手剔除孤立点省的进 GPU
            return 片
        }
    }

    /// 多个网格硬合并成一个（顶点池拼接 + 索引偏移）
    static func 合并(_ 网格集: [导入网格], 名称: String) -> 导入网格? {
        guard !网格集.isEmpty else { return nil }
        var 结果 = 导入网格(名称: 名称)
        var 偏移: UInt32 = 0
        for 片 in 网格集 {
            结果.顶点.append(contentsOf: 片.顶点)
            结果.法线.append(contentsOf: 片.法线)
            结果.UV.append(contentsOf: 片.UV)
            结果.索引.append(contentsOf: 片.索引.map { $0 + 偏移 })
            偏移 += UInt32(片.顶点.count)
        }
        结果.对齐属性()
        结果.重建默认子集()
        return 结果
    }

    /// 把最长边压到 目标尺寸（现有程序化网格大致 1~2 单位）
    static func 归一化(_ 网格: inout 导入网格, 目标尺寸: Float = 1.5) {
        let 最长 = 网格.最大边长
        guard 最长 > 1e-6, 目标尺寸 > 0 else { return }
        网格.施加变换(网格变换.缩放(目标尺寸 / 最长))
    }
}

// MARK: - 存档编解码

/// SIMD3/2 与 simd_float4x4 都不是 Codable，统一拍平成一维 [Float] 存进项目存档。
/// 顶点占体积最大，但这里是本地 JSON 存档，不做量化——精度损失在视口里会表现成
/// 「模型表面轻微抖动」，省那点字节不值得。
extension 导入子集: Codable {}

extension 导入网格: Codable {
    private enum 键: String, CodingKey {
        case 名称, 顶点, 法线, uv = "UV", 索引, 子集, 变换
    }

    init(from 解码器: Decoder) throws {
        let c = try 解码器.container(keyedBy: 键.self)
        self.init(名称: try c.decode(String.self, forKey: .名称))

        let 平顶点 = try c.decodeIfPresent([Float].self, forKey: .顶点) ?? []
        let 平法线 = try c.decodeIfPresent([Float].self, forKey: .法线) ?? []
        let 平UV = try c.decodeIfPresent([Float].self, forKey: .uv) ?? []

        顶点 = stride(from: 0, to: 平顶点.count - 平顶点.count % 3, by: 3)
            .map { SIMD3<Float>(平顶点[$0], 平顶点[$0 + 1], 平顶点[$0 + 2]) }
        法线 = stride(from: 0, to: 平法线.count - 平法线.count % 3, by: 3)
            .map { SIMD3<Float>(平法线[$0], 平法线[$0 + 1], 平法线[$0 + 2]) }
        UV = stride(from: 0, to: 平UV.count - 平UV.count % 2, by: 2)
            .map { SIMD2<Float>(平UV[$0], 平UV[$0 + 1]) }

        索引 = try c.decodeIfPresent([UInt32].self, forKey: .索引) ?? []
        子集 = try c.decodeIfPresent([导入子集].self, forKey: .子集) ?? []

        let 平矩阵 = try c.decodeIfPresent([Float].self, forKey: .变换) ?? []
        if 平矩阵.count == 16 {
            变换 = simd_float4x4(columns: (
                SIMD4(平矩阵[0], 平矩阵[1], 平矩阵[2], 平矩阵[3]),
                SIMD4(平矩阵[4], 平矩阵[5], 平矩阵[6], 平矩阵[7]),
                SIMD4(平矩阵[8], 平矩阵[9], 平矩阵[10], 平矩阵[11]),
                SIMD4(平矩阵[12], 平矩阵[13], 平矩阵[14], 平矩阵[15])
            ))
        }

        对齐属性()
        if 子集.isEmpty { 重建默认子集() }
    }

    func encode(to 编码器: Encoder) throws {
        var c = 编码器.container(keyedBy: 键.self)
        try c.encode(名称, forKey: .名称)
        try c.encode(顶点.flatMap { [$0.x, $0.y, $0.z] }, forKey: .顶点)
        try c.encode(法线.flatMap { [$0.x, $0.y, $0.z] }, forKey: .法线)
        try c.encode(UV.flatMap { [$0.x, $0.y] }, forKey: .uv)
        try c.encode(索引, forKey: .索引)
        try c.encode(子集, forKey: .子集)
        let 列 = 变换.columns
        try c.encode([
            列.0.x, 列.0.y, 列.0.z, 列.0.w,
            列.1.x, 列.1.y, 列.1.z, 列.1.w,
            列.2.x, 列.2.y, 列.2.z, 列.2.w,
            列.3.x, 列.3.y, 列.3.z, 列.3.w,
        ], forKey: .变换)
    }
}
