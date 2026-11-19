#include <metal_stdlib>
using namespace metal;

// ============================================================================
// 体积 模拟（GPU 欧拉网格）
// ----------------------------------------------------------------------------
// 口径：效果 / 速度 / 碰撞 三者都要的最优解 = 业界实时体积的唯一主流路线
//   （UE5 Niagara Fluids 3D Gas、NVIDIA Warp Vortex、EmberGen 同一套）：
//
//   1) 速度场自平流（半拉格朗日 + RK2 反推）
//   2) 涡量约束（vorticity confinement）—— 补回数值耗散吃掉的小尺度翻滚，
//      这是"火焰像火而不是像棉花糖"的关键，没有它网格法永远是一坨糊
//   3) 浮力（温度驱动）+ 外力（重力 / 风）+ 喷嘴射流 + 湍流扰动
//   4) 燃烧：温度场生烟密度，温度自身衰减
//   5) 压力投影（Jacobi 泊松解）让速度场无散度 —— 这一步决定烟会"腾起来"而不是"炸开"
//   6) SDF 碰撞：球体集合 + 地面平面，法向速度清零（切向保留 = 滑移边界）
//
// 网格：立方 N³（默认 64），只覆盖这个发射器的羽流包围盒，不浪费体素。
// 纹理：state = (速度xyz, 温度)，density = 烟密度，pressure / divergence 派生。
// 全部 read_write 就地算，只有平流需要 ping-pong（跨体素读取）。
// ============================================================================

// 与 Swift 侧 体积模拟参数 逐字节一致（208 字节）
struct VolSimParams {
    float4x4 world;      // 发射器世界矩阵
    float4 域;           // x=半宽(米)  y=高(米)  z=网格边长  w=体素边长(米)
    float4 时间;         // x=时间(秒)  y=dt(秒)  z=涡量强度  w=浮力
    float4 动力;         // x=速度耗散  y=密度耗散  z=重力强度  w=湍流幅度
    float4 燃烧;         // x=燃烧强度(0=纯烟)  y=温度衰减  z=烟生成率  w=喷口射流速度
    float4 源;           // x=喷口半径  y=喷口厚度  z=是否发射(0/1)  w=初始温度
    float4 外力;         // xyz=风(世界)  w=预热时间
    float4 碰撞;         // x=球数  y=地面高度(局部)  z=地面开关  w=保留
    float4 配色;         // x=密度→消光系数  y=温度→发光强度  z=烟自阴影  w=密度死区
    float4 调参;         // x=每帧子步数  y=压力迭代次数  z=浮力倍率  w=源温倍率
};

struct VolCollider {
    float4 球心半径;     // xyz=球心(世界)  w=半径
};

// ---------------------------------------------------------------- 采样工具
constexpr sampler volSampler(mag_filter::linear, min_filter::linear, address::clamp_to_edge);

static inline float3 volWorldToLocal(constant VolSimParams &p, float3 世界点) {
    float4 l = p.world * float4(世界点, 1.0f);
    // world = 平移 * 旋转 * 缩放，逆变换按列取（正交假设，工程里的物体变换均为刚体+均匀缩放）
    float3 t = p.world.columns[3].xyz;
    float3 d = 世界点 - t;
    float3 局部;
    局部.x = dot(d, p.world.columns[0].xyz) / max(dot(p.world.columns[0].xyz, p.world.columns[0].xyz), 1e-9f);
    局部.y = dot(d, p.world.columns[1].xyz) / max(dot(p.world.columns[1].xyz, p.world.columns[1].xyz), 1e-9f);
    局部.z = dot(d, p.world.columns[2].xyz) / max(dot(p.world.columns[2].xyz, p.world.columns[2].xyz), 1e-9f);
    return 局部;
}

static inline float3 volLocalToWorld(constant VolSimParams &p, float3 局部点) {
    return (p.world * float4(局部点, 1.0f)).xyz;
}

/// 局部坐标 → 纹理坐标（0…1）
static inline float3 volLocalToUV(constant VolSimParams &p, float3 局部点) {
    float 半宽 = max(p.域.x, 1e-4f);
    float 高 = max(p.域.y, 1e-4f);
    return float3((局部点.x + 半宽) / (2.0f * 半宽),
                  局部点.y / 高,
                  (局部点.z + 半宽) / (2.0f * 半宽));
}

/// 网格索引 → 局部坐标（体素中心）
static inline float3 volVoxelToLocal(constant VolSimParams &p, uint3 g) {
    float 边长 = max(p.域.z, 1.0f);
    float 半宽 = p.域.x;
    float 高 = p.域.y;
    float3 归一 = (float3(g) + 0.5f) / 边长;
    return float3((归一.x - 0.5f) * 2.0f * 半宽,
                  归一.y * 高,
                  (归一.z - 0.5f) * 2.0f * 半宽);
}

// ---------------------------------------------------------------- 宿主几何表面场
// volClamp3 的定义在下面（碰撞/边界工具区），这里先声明，免得梯度函数用到时还没见过它
static inline uint3 volClamp3(int3 g, uint 边长);

/// 表面距离（米）：0 = 正好贴在几何表面上，越大离得越远（1e3 = 域里没有几何）。
/// 纹理与模拟网格逐体素对齐，所以直接按 gid 读，不做采样。
static inline float volSurfaceDistance(texture3d<float, access::read> 表面, uint3 gid) {
    return 表面.read(gid).x;
}

/// 表面场梯度 = 指向"远离几何"的方向。
/// 无符号距离在薄壳内是 V 形，梯度在壳外侧指外、壳里侧指内，
/// 拿来当"从表面往外的喷射方向"已经够用：火根部本来就该往外劈开，
/// 往几何内部那一半会被后面的速度耗散和固体遮罩吃掉。
static inline float3 volSurfaceNormal(texture3d<float, access::read> 表面, uint3 gid,
                                      uint 边长, float 半宽, float 高) {
    int3 g = int3(gid);
    float 体素x = 2.0f * 半宽 / max(float(边长), 1.0f);
    float 体素y = 高 / max(float(边长), 1.0f);
    float gx = volSurfaceDistance(表面, volClamp3(int3(g.x + 1, g.y, g.z), 边长))
             - volSurfaceDistance(表面, volClamp3(int3(g.x - 1, g.y, g.z), 边长));
    float gy = volSurfaceDistance(表面, volClamp3(int3(g.x, g.y + 1, g.z), 边长))
             - volSurfaceDistance(表面, volClamp3(int3(g.x, g.y - 1, g.z), 边长));
    float gz = volSurfaceDistance(表面, volClamp3(int3(g.x, g.y, g.z + 1), 边长))
             - volSurfaceDistance(表面, volClamp3(int3(g.x, g.y, g.z - 1), 边长));
    float3 法向 = float3(gx / max(体素x, 1e-5f), gy / max(体素y, 1e-5f), gz / max(体素x, 1e-5f));
    float 长 = length(法向);
    if (长 < 1e-5f) return float3(0.0f, 1.0f, 0.0f);   // 平坦处（薄壳中心）退化成向上
    return 法向 / 长;
}

// ---------------------------------------------------------------- 噪声
static inline float volHash(uint x) {
    x ^= x >> 16; x *= 0x7feb352du;
    x ^= x >> 15; x *= 0x846ca68bu;
    x ^= x >> 16;
    return float(x & 0x00FFFFFFu) / 16777215.0f;
}

static inline float volValueNoise(float3 p) {
    float3 i = floor(p);
    float3 f = fract(p);
    f = f * f * (3.0f - 2.0f * f);
    uint3 基 = uint3(int3(i) & 1023);
    float 结果 = 0.0f;
    for (int z = 0; z < 2; ++z) {
        for (int y = 0; y < 2; ++y) {
            for (int x = 0; x < 2; ++x) {
                uint 键 = (基.x + uint(x)) * 1973u + (基.y + uint(y)) * 9277u + (基.z + uint(z)) * 26699u;
                float 权 = (x ? f.x : 1.0f - f.x) * (y ? f.y : 1.0f - f.y) * (z ? f.z : 1.0f - f.z);
                结果 += volHash(键) * 权;
            }
        }
    }
    return 结果;
}

/// 三倍频噪声速度（发散已被噪声的散度污染，但压力投影会收拾掉，这正是我们要的翻滚）
static inline float3 volCurlNoise(float3 p) {
    const float e = 0.35f;
    float3 噪;
    噪.x = volValueNoise(p + float3(0.0f, 0.0f, e)) - volValueNoise(p - float3(0.0f, 0.0f, e));
    噪.y = volValueNoise(p + float3(e, 0.0f, 0.0f)) - volValueNoise(p - float3(e, 0.0f, 0.0f));
    噪.z = volValueNoise(p + float3(0.0f, e, 0.0f)) - volValueNoise(p - float3(0.0f, e, 0.0f));
    return 噪;
}

// ---------------------------------------------------------------- 边界处理
static inline bool volOutOfRange(uint3 g, uint 边长) {
    return g.x >= 边长 || g.y >= 边长 || g.z >= 边长;
}

static inline uint3 volClamp3(int3 g, uint 边长) {
    int3 hi = int3(int(边长) - 1);
    return uint3(clamp(g, int3(0), hi));
}

/// 取速度并算旋度模长（用于涡量约束的梯度，越界夹边）
static inline float volCurlMag(texture3d<float, access::read> tex, int3 g, uint 边长) {
    int3 p1 = int3(g.x + 1, g.y, g.z), n1 = int3(g.x - 1, g.y, g.z);
    int3 p2 = int3(g.x, g.y + 1, g.z), n2 = int3(g.x, g.y - 1, g.z);
    int3 p3 = int3(g.x, g.y, g.z + 1), n3 = int3(g.x, g.y, g.z - 1);
    float3 vp1 = tex.read(volClamp3(p1, 边长)).xyz, vn1 = tex.read(volClamp3(n1, 边长)).xyz;
    float3 vp2 = tex.read(volClamp3(p2, 边长)).xyz, vn2 = tex.read(volClamp3(n2, 边长)).xyz;
    float3 vp3 = tex.read(volClamp3(p3, 边长)).xyz, vn3 = tex.read(volClamp3(n3, 边长)).xyz;
    float3 curl;
    curl.x = ((vp2.z - vn2.z) - (vp3.y - vn3.y)) * 0.5f;
    curl.y = ((vp3.x - vn3.x) - (vp1.z - vn1.z)) * 0.5f;
    curl.z = ((vp1.y - vn1.y) - (vp2.x - vn2.x)) * 0.5f;
    return length(curl);
}

// ============================================================================
// 1) 涡量与外力
//    一次搞定：涡量约束 + 浮力 + 重力 + 风 + 湍流 + 喷口射流
// ============================================================================
kernel void volSimForce(texture3d<float, access::read> 源速 [[texture(0)]],
                        texture3d<float, access::write> 目标速 [[texture(1)]],
                        texture3d<float, access::read> 密度表 [[texture(2)]],
                        texture3d<float, access::read> 表面表 [[texture(3)]],
                        constant VolSimParams &p [[buffer(0)]],
                        uint3 gid [[thread_position_in_grid]]) {
    uint 边长 = uint(max(p.域.z, 1.0f));
    if (volOutOfRange(gid, 边长)) return;

    int3 g = int3(gid);
    float4 中心 = 源速.read(gid);
    float3 v = 中心.xyz;
    float 温 = 中心.w;
    float 密 = 密度表.read(gid).x;

    // ---- 旋度（立方体差分的标准式）----
    float3 vp1 = 源速.read(volClamp3(int3(g.x + 1, g.y, g.z), 边长)).xyz;
    float3 vn1 = 源速.read(volClamp3(int3(g.x - 1, g.y, g.z), 边长)).xyz;
    float3 vp2 = 源速.read(volClamp3(int3(g.x, g.y + 1, g.z), 边长)).xyz;
    float3 vn2 = 源速.read(volClamp3(int3(g.x, g.y - 1, g.z), 边长)).xyz;
    float3 vp3 = 源速.read(volClamp3(int3(g.x, g.y, g.z + 1), 边长)).xyz;
    float3 vn3 = 源速.read(volClamp3(int3(g.x, g.y, g.z - 1), 边长)).xyz;

    float3 curl;
    curl.x = ((vp2.z - vn2.z) - (vp3.y - vn3.y)) * 0.5f;
    curl.y = ((vp3.x - vn3.x) - (vp1.z - vn1.z)) * 0.5f;
    curl.z = ((vp1.y - vn1.y) - (vp2.x - vn2.x)) * 0.5f;

    // ---- 涡量约束：|curl| 的梯度方向 × curl，把被数值耗散磨平的涡补回来 ----
    float gxp = volCurlMag(源速, int3(g.x + 1, g.y, g.z), 边长);
    float gxn = volCurlMag(源速, int3(g.x - 1, g.y, g.z), 边长);
    float gyp = volCurlMag(源速, int3(g.x, g.y + 1, g.z), 边长);
    float gyn = volCurlMag(源速, int3(g.x, g.y - 1, g.z), 边长);
    float gzp = volCurlMag(源速, int3(g.x, g.y, g.z + 1), 边长);
    float gzn = volCurlMag(源速, int3(g.x, g.y, g.z - 1), 边长);
    float3 梯度 = float3(gxp - gxn, gyp - gyn, gzp - gzn) * 0.5f;
    float 梯度长 = length(梯度);
    if (梯度长 > 1e-6f) {
        v += p.时间.z * p.域.w * cross(梯度 / 梯度长, curl);
    }

    // ---- 浮力：温度驱动的上升（火/热烟的核心动力）----
    // 【为什么扣 0.02】环境温度不是 0，冷区也带一点残温；不扣的话整场都在被微弱上抬，
    // 羽流根部会浮起来离开喷口，看着像"火飘在空中"。
    v.y += p.时间.w * max(温 - 0.02f, 0.0f) * p.时间.y;

    // ---- 重力 + 风（世界方向 → 局部方向）----
    // 【为什么乘烟权】真实火舌的上升加速度是 g·ΔT/T 量级（十几到几十 m/s²），
    // 远大于 g 本身；早期版本把 9.8 的重力无差别压在整场上，浮力只剩 1.5，
    // 结果火一丝都升不起来 —— 全部堆在喷口像一坨饼，这正是"火是个球"的根因。
    // 现在重力只压冷却下来的烟（越热越不受重力），热气才腾空、烟才下沉。
    float 烟权 = saturate(密 * 2.0f) * saturate(1.0f - 温);
    float3 重力世界 = float3(0.0f, -1.0f, 0.0f) * p.动力.z * 烟权;
    float3 外力世界 = p.外力.xyz + 重力世界;
    float3 外力局部 = float3(dot(外力世界, normalize(p.world.columns[0].xyz)),
                              dot(外力世界, normalize(p.world.columns[1].xyz)),
                              dot(外力世界, normalize(p.world.columns[2].xyz)));
    v += 外力局部 * p.时间.y;

    // ---- 湍流扰动：随时间漂移的噪声，火的翻卷与烟丝的撕扯都来自这里 ----
    float3 lp = volVoxelToLocal(p, gid);
    float3 噪声坐标 = lp * (2.6f / max(p.域.x, 0.05f)) + float3(0.0f, -p.时间.x * 0.9f, 0.0f);
    float3 扰 = volCurlNoise(噪声坐标) + volCurlNoise(噪声坐标 * 2.7f + float3(11.3f, 5.1f, 7.7f)) * 0.45f;
    float 湍流权 = p.动力.w * (0.25f + 0.75f * saturate(温 * 0.5f + 密));
    v += 扰 * 湍流权 * p.时间.y;

    // ---- 射流：源.z == 2 是"几何表面发射"，源.z == 1 是老的圆盘喷口 ----
    if (p.源.z > 1.5f) {
        // 【几何表面发射】发射体就是用户选中的那个对象：贴着它表面的薄壳
        // 沿法向朝外推。圈上冒火、球壳冒烟、平面冒雾，都是这一支。
        float d = volSurfaceDistance(表面表, gid);
        float 厚 = max(p.源.y, 1e-4f);
        if (d < 厚 * 2.0f) {
            float 口 = 1.0f - smoothstep(0.0f, 厚 * 2.0f, d);
            float3 法向 = volSurfaceNormal(表面表, gid, 边长, p.域.x, p.域.y);
            // 抖一点，不然整圈表面同一时刻同一个方向推，像气泵不像火
            float3 抖 = volCurlNoise(lp * 5.0f + float3(0.0f, -p.时间.x * 1.7f, 0.0f)) - 0.5f;
            v += (法向 + 抖 * 0.45f) * (口 * p.燃烧.w * p.时间.y);
        }
    } else if (p.源.z > 0.5f) {
        float 距轴 = length(lp.xz);
        // 【为什么不用反向 smoothstep】smoothstep(edge0 > edge1) 在 Metal 里是未定义行为，
        // Apple GPU 上直接返回 0 —— 曾导致喷口射流恒为 0、整团火一丝密度都吐不出来。
        // 这里统一写成 1 - smoothstep(小, 大, x)：内圈为 1、外圈平滑降到 0。
        float 盘 = 1.0f - smoothstep(p.源.x * 0.25f, p.源.x, 距轴);
        float 层 = 1.0f - smoothstep(0.0f, p.源.y * 3.0f, lp.y);
        float 口 = 盘 * 层;
        v.y += 口 * p.燃烧.w * p.时间.y;
        float 抖 = volValueNoise(float3(lp.xz * 6.0f, p.时间.x * 2.2f)) - 0.5f;
        v.x += 口 * 抖 * p.燃烧.w * 0.35f * p.时间.y;
        v.z += 口 * 抖 * p.燃烧.w * 0.35f * p.时间.y;
    }

    // ---- 速度耗散 ----
    v *= clamp(1.0f - p.动力.x * p.时间.y, 0.0f, 1.0f);

    目标速.write(float4(v, 温), gid);
}

// ============================================================================
// 2) 平流（半拉格朗日 + RK2）—— 唯一需要 ping-pong 的一步
// ============================================================================
kernel void volSimAdvect(texture3d<float, access::sample> 源速 [[texture(0)]],
                         texture3d<float, access::sample> 源密 [[texture(1)]],
                         texture3d<float, access::write> 目标速 [[texture(2)]],
                         texture3d<float, access::write> 目标密 [[texture(3)]],
                         constant VolSimParams &p [[buffer(0)]],
                         uint3 gid [[thread_position_in_grid]]) {
    uint 边长 = uint(max(p.域.z, 1.0f));
    if (volOutOfRange(gid, 边长)) return;

    float3 lp = volVoxelToLocal(p, gid);
    // 采样型纹理不能 read(gid)，中心速度按体素中心的 UV 采一次即可
    float3 中心UV = volLocalToUV(p, lp);
    float4 中心 = 源速.sample(volSampler, 中心UV);
    float3 v0 = 中心.xyz;

    // RK2 反推：先走半步找到中点速度，再从中点回退整步
    // 【CFL 限速】半拉格朗日回溯的位移一旦超过 1.5 个体素，采样点会直接飞出域
    // 被 clamp_to_edge 夹到盒壁上，而盒壁密度恒为 0 —— 结果就是密度每帧被
    // "洗"成 0，无论注多少都长不起来（离线实测总密 240 帧恒为 0.000）。
    // 这不是参数问题，是稳定性条件，必须钳制。
    float 位移上限 = 1.5f * max(p.域.w, 1e-5f);
    float 半 = p.时间.y * 0.5f;
    float3 位移0 = v0 * 半;
    float 长0 = length(位移0);
    if (长0 > 位移上限) 位移0 *= 位移上限 / 长0;
    float3 中点局部 = lp - 位移0;
    float3 中点UV = volLocalToUV(p, 中点局部);
    float3 v1 = 源速.sample(volSampler, 中点UV).xyz;
    float3 位移1 = v1 * p.时间.y;
    float 长1 = length(位移1);
    if (长1 > 位移上限) 位移1 *= 位移上限 / 长1;
    float3 起点局部 = lp - 位移1;

    float3 uv = volLocalToUV(p, 起点局部);
    float3 uv夹 = clamp(uv, 0.0f, 1.0f);

    float4 采样速 = 源速.sample(volSampler, uv夹);
    float2 采样密 = 源密.sample(volSampler, uv夹).xy;

    // 越界处理：速度不外推（避免从域外吸进虚假气流），密度按"出域多远"指数衰减。
    // 旧版是乘 0.55 硬稀释 —— 结果密度出不去、在侧壁上刷成一片亮的糊墙，
    // 视口里那层贴着盒子的方块就是它。
    if (any(uv != uv夹)) {
        采样速.xyz = mix(采样速.xyz, float3(0.0f), 0.85f);
        float 越界 = length(uv - uv夹);
        采样密 *= exp(-越界 * 14.0f);
    }

    目标速.write(float4(采样速.xyz, 采样速.w), gid);
    // y 通道是燃料，必须跟着一起平流，否则燃料留在原地、火舌永远长不高
    目标密.write(float4(采样密, 0.0f, 0.0f), gid);
}

// ============================================================================
// 3) 燃烧 + 源注入（温度 → 烟，喷口吐出温度与密度）
// ============================================================================
kernel void volSimBurn(texture3d<float, access::read_write> state [[texture(0)]],
                       texture3d<float, access::read_write> density [[texture(1)]],
                       texture3d<float, access::read> 表面表 [[texture(2)]],
                       constant VolSimParams &p [[buffer(0)]],
                       uint3 gid [[thread_position_in_grid]]) {
    uint 边长 = uint(max(p.域.z, 1.0f));
    if (volOutOfRange(gid, 边长)) return;

    float4 中心 = state.read(gid);
    float 温 = 中心.w;
    float4 密包 = density.read(gid);
    float 密 = 密包.x;
    // 【燃料场】密度纹理 y 通道存燃料，x 通道存烟（燃烧产物）。
    // 为什么必须多一个场：只靠"温度超阈值才产烟"的写法，在强对流+多子步下
    // 密度还没攒起来就被平流稀释掉了（离线实测 240 帧总密恒等于 0.000，
    // 也就是整支火在模拟里根本不存在）。真实燃烧是"有燃料才烧"，
    // 燃料由喷口持续供给、被对流带走、边烧边产烟 —— 这才是火焰形状的来源。
    float 燃料 = 密包.y;

    float 燃烧率 = clamp(p.燃烧.x, 0.0f, 2.0f);
    float dt = p.时间.y;

    // ---- 1) 供料（狄利克雷：钉住，不是累加）----
    // 累加式注入在子步+强对流下永远攒不起来（历史实测火头温度只有 0.1/3.2）。
    if (p.源.z > 1.5f) {
        // 【几何表面供料】供料区 = 贴着宿主几何表面的薄壳，厚 p.源.y。
        // 圈上冒火=沿着环管的曲面烧；球壳冒烟=沿球面烧；平面冒雾=沿板面烧。
        float d = volSurfaceDistance(表面表, gid);
        float 厚 = max(p.源.y, 1e-4f);
        float 口 = 1.0f - smoothstep(0.0f, 厚, d);
        if (口 > 0.001f) {
            燃料 = max(燃料, 口);
            温 = max(温, 口 * p.源.w);
            密 = max(密, 口 * 0.06f);
        }
    } else if (p.源.z > 0.5f) {
        float3 lp = volVoxelToLocal(p, gid);
        float 距轴 = length(lp.xz);
        float 盘 = 1.0f - smoothstep(p.源.x * 0.25f, p.源.x, 距轴);
        // 供料区只占底部极薄一层：火焰的立体感来自上方自由湍流，
        // 供料区一旦做厚，下部就是一根等宽实心柱 —— 观感仍像一个桶。
        float 层 = 1.0f - smoothstep(0.0f, p.源.y * 2.5f, lp.y);
        float 口 = 盘 * 层;
        if (口 > 0.001f) {
            燃料 = max(燃料, 口);
            温 = max(温, 口 * p.源.w);
            // 火根保底密度：不留这项，密度会被对流一路稀释到 1e-4 以下，
            // 渲染端整支火直接消失（离线实测总密=0 的死因之一）。
            密 = max(密, 口 * 0.06f);
        }
    }

    // ---- 2) 燃烧：燃料 → 放热 + 发光气体（密度）----
    // 【为什么是 max 而不是 +=】写成累加时，稳态密度 = 生成率/衰减率，
    // 实测直接冲到 15.3、非零体素 3900/4096（整盒 95% 灌满）——
    // 渲染出来必然是一个发光的实心方团，这正是"火是个球"的数值来源。
    // 火焰的密度应该由"此刻烧得多旺"决定，而不是历史积分，所以取包络最大。
    if (燃料 > 1e-5f && 燃烧率 > 1e-4f) {
        float 烧掉 = min(燃料, 燃料 * 燃烧率 * 7.0f * dt + 1e-5f);
        燃料 -= 烧掉;
        温 = 温 + 烧掉 * 6.0f * clamp(p.燃烧.z, 0.0f, 4.0f);
        密 = max(密, min(1.6f, 烧掉 * 14.0f * clamp(p.燃烧.z, 0.0f, 4.0f)));
    } else {
        // 纯烟（燃烧率=0）：燃料直接当烟用，不做放热
        密 = max(密, 燃料 * 0.5f);
    }

    // ---- 3) 燃料自衰减：离开供料区就烧完/散掉 ----
    // 少了这一项，燃料被湍流搅满整个包围盒，每个体素都在烧 → 满盒发光的球。
    燃料 *= clamp(1.0f - 5.0f * dt, 0.0f, 1.0f);

    // ---- 4) 耗散：温度冷却 + 发光气体寿命 ----
    // 真实火焰只有几百毫秒的发光期：寿命太长就会把整盒染成均匀亮团。
    温 *= clamp(1.0f - p.燃烧.y * dt, 0.0f, 1.0f);
    密 *= clamp(1.0f - p.动力.y * dt, 0.0f, 1.0f);
    密 *= clamp(1.0f - 2.6f * dt, 0.0f, 1.0f);

    // 注意：密度死区 / 幂次压缩**绝不在这里做**。
    // 本内核每帧跑多个子步，每步原始密度只涨一点点；若在这做硬死区，密度会被
    // "涨一点→被清零"反覆抹掉，永远长不到阈值。死区与幂次属于外观映射，
    // 只在渲染端对采样值做一次（见 volDensityLook）。

    state.write(float4(中心.xyz, 温), gid);
    density.write(float4(密, 燃料, 0.0f, 0.0f), gid);
}

// ============================================================================
// 4) 散度 → 5) Jacobi 解压力 → 6) 减梯度
// ============================================================================
kernel void volSimDivergence(texture3d<float, access::read> 速 [[texture(0)]],
                             texture3d<float, access::write> 散度 [[texture(1)]],
                             texture3d<float, access::read> 固体 [[texture(2)]],
                             constant VolSimParams &p [[buffer(0)]],
                             uint3 gid [[thread_position_in_grid]]) {
    uint 边长 = uint(max(p.域.z, 1.0f));
    if (volOutOfRange(gid, 边长)) return;
    // 固体内部不参与不可压缩约束（否则压力会在墙里堆出假源汇）
    if (p.碰撞.x > 0.5f || p.碰撞.z > 0.5f) {
        if (固体.read(gid).x > 0.5f) {
            散度.write(float4(0.0f, 0.0f, 0.0f, 0.0f), gid);
            return;
        }
    }
    int3 g = int3(gid);
    int3 hi = int3(int(边长) - 1);
    float3 vp_x = 速.read(uint3(clamp(g + int3(1, 0, 0), int3(0), hi))).xyz;
    float3 vn_x = 速.read(uint3(clamp(g - int3(1, 0, 0), int3(0), hi))).xyz;
    float3 vp_y = 速.read(uint3(clamp(g + int3(0, 1, 0), int3(0), hi))).xyz;
    float3 vn_y = 速.read(uint3(clamp(g - int3(0, 1, 0), int3(0), hi))).xyz;
    float3 vp_z = 速.read(uint3(clamp(g + int3(0, 0, 1), int3(0), hi))).xyz;
    float3 vn_z = 速.read(uint3(clamp(g - int3(0, 0, 1), int3(0), hi))).xyz;
    float div = 0.5f * ((vp_x.x - vn_x.x) + (vp_y.y - vn_y.y) + (vp_z.z - vn_z.z));

    // 【为什么要把燃烧区的散度清零】火焰是"往外产气"的，那里本来就不守恒。
    // 若照严格不可压缩去求解，压力会立刻把喷口喷出的这股气量平掉 —— 实测表现就是
    // 浮力/射流全被抵消、火瘫在喷口。工业解法的处理是：源区不参与不可压缩约束，
    // 只让"被带起来的烟柱"保持无散，这样既有持续的出口动量，又不会全场炸开。
    float 温 = 速.read(gid).w;
    if (温 > 0.25f) div = 0.0f;
    散度.write(float4(div, 0.0f, 0.0f, 0.0f), gid);
}

kernel void volSimJacobi(texture3d<float, access::read> 散度 [[texture(0)]],
                         texture3d<float, access::read> 压力源 [[texture(1)]],
                         texture3d<float, access::write> 压力目标 [[texture(2)]],
                         texture3d<float, access::read> 固体 [[texture(3)]],
                         constant VolSimParams &p [[buffer(0)]],
                         uint3 gid [[thread_position_in_grid]]) {
    uint 边长 = uint(max(p.域.z, 1.0f));
    if (volOutOfRange(gid, 边长)) return;
    int3 g = int3(gid);
    int3 hi = int3(int(边长) - 1);
    float 自压 = 压力源.read(gid).x;
    bool 有碰撞 = (p.碰撞.x > 0.5f || p.碰撞.z > 0.5f);

    // 【固体边界】固体体素内部不求解压力（DirectForces 式屏蔽），压力保持原值；
    // 相邻的流体体素在取邻居时，如果邻居是固体，就用自身压力代替它
    // —— 这就是离散化的 ∂p/∂n = 0（Neumann），压力不会从墙里"漏"出来。
    if (有碰撞 && 固体.read(gid).x > 0.5f) {
        压力目标.write(float4(自压, 0.0f, 0.0f, 0.0f), gid);
        return;
    }

    // 取邻居压力：固体邻居 → 用自身压力顶替（零法向梯度）
    auto 采样 = [&](int3 q) -> float {
        int3 c = clamp(q, int3(0), hi);
        if (有碰撞 && 固体.read(uint3(c)).x > 0.5f) return 自压;
        return 压力源.read(uint3(c)).x;
    };

    // 【顶部必须开放】封闭盒里质量守恒不允许"只升不降"，压力投影会把浮力上升气流整条抹掉，
    // 火就永远压在喷口堆成一坨。所以域顶取 Dirichlet 边界 p = 0（自由出流），其余五面仍是
    // Neumann（法向梯度 0），火舌才能真的腾空、烟才能从顶上流走。
    float 上 = (g.y + 1 > hi.y) ? 0.0f : 采样(g + int3(0, 1, 0));
    float 下 = (g.y - 1 < 0) ? 0.0f : 采样(g - int3(0, 1, 0));
    float 邻 = 采样(g + int3(1, 0, 0))
             + 采样(g - int3(1, 0, 0))
             + 上
             + 下
             + 采样(g + int3(0, 0, 1))
             + 采样(g - int3(0, 0, 1));
    float d = 散度.read(gid).x;
    压力目标.write(float4((邻 - d) / 6.0f, 0.0f, 0.0f, 0.0f), gid);
}

kernel void volSimProject(texture3d<float, access::read_write> 速 [[texture(0)]],
                          texture3d<float, access::read> 压力 [[texture(1)]],
                          texture3d<float, access::read> 固体 [[texture(2)]],
                          constant VolSimParams &p [[buffer(0)]],
                          uint3 gid [[thread_position_in_grid]]) {
    uint 边长 = uint(max(p.域.z, 1.0f));
    if (volOutOfRange(gid, 边长)) return;
    int3 g = int3(gid);
    int3 hi = int3(int(边长) - 1);
    float4 中心 = 速.read(gid);
    bool 有碰撞 = (p.碰撞.x > 0.5f || p.碰撞.z > 0.5f);

    // 固体体素：速度直接归零（比"投影到切平面"更硬，投影后被墙推出来的速度不许残留）
    if (有碰撞 && 固体.read(gid).x > 0.5f) {
        速.write(float4(0.0f, 0.0f, 0.0f, 中心.w), gid);
        return;
    }

    // 梯度取样同样走 Neumann：固体邻居用自己的压力顶替，否则墙边会出现虚假吸力/推力
    float 自压 = 压力.read(gid).x;
    auto 采样 = [&](int3 q) -> float {
        int3 c = clamp(q, int3(0), hi);
        if (有碰撞 && 固体.read(uint3(c)).x > 0.5f) return 自压;
        return 压力.read(uint3(c)).x;
    };

    float px = 采样(g + int3(1, 0, 0));
    float nx = 采样(g - int3(1, 0, 0));
    float py = 采样(g + int3(0, 1, 0));
    float ny = 采样(g - int3(0, 1, 0));
    float pz = 采样(g + int3(0, 0, 1));
    float nz = 采样(g - int3(0, 0, 1));
    float3 梯度 = float3(px - nx, py - ny, pz - nz) * 0.5f;
    速.write(float4(中心.xyz - 梯度, 中心.w), gid);
}

// ============================================================================
// 6.5) 固体遮罩：把"哪些体素被 SDF 占住了"烘成一张图给压力求解用
//      【为什么必须在投影之前有这一步】碰撞在投影之后清零法向速度，
//      下一帧压力求解并不知道那里有墙，会把它当流体继续吸/推，
//      表现就是火贴到物体上被"抽"进表面、或者紧贴表面狂抖。
//      工业解法 = 压力求解把固体当 Neumann 边界（∂p/∂n = 0），
//      而要知道边界在哪，就得先有一张 solid mask。
// ============================================================================
static inline bool volSolidAt(constant VolSimParams &p, float3 lp, device const VolCollider *球们) {
    if (p.碰撞.z > 0.5f && lp.y < p.碰撞.y) return true;
    uint 球数 = uint(max(p.碰撞.x, 0.0f));
    if (球数 == 0u) return false;
    float3 世界点 = volLocalToWorld(p, lp);
    for (uint i = 0u; i < 球数; ++i) {
        float3 球心 = 球们[i].球心半径.xyz;
        float 半径 = 球们[i].球心半径.w;
        if (半径 <= 1e-4f) continue;
        if (length(世界点 - 球心) < 半径) return true;
    }
    return false;
}

kernel void volSimSolid(texture3d<float, access::write> 固体 [[texture(0)]],
                        device const VolCollider *球们 [[buffer(0)]],
                        constant VolSimParams &p [[buffer(1)]],
                        uint3 gid [[thread_position_in_grid]]) {
    uint 边长 = uint(max(p.域.z, 1.0f));
    if (volOutOfRange(gid, 边长)) return;
    bool 实 = volSolidAt(p, volVoxelToLocal(p, gid), 球们);
    固体.write(float4(实 ? 1.0f : 0.0f, 0.0f, 0.0f, 0.0f), gid);
}

// ============================================================================
// 7) SDF 碰撞：球体集合 + 地面平面
//    做法 = 工业标准的速度场边界条件（法向清零，切向滑移），不是粒子弹开
// ============================================================================
kernel void volSimCollide(texture3d<float, access::read_write> state [[texture(0)]],
                          texture3d<float, access::read_write> density [[texture(1)]],
                          device const VolCollider *球们 [[buffer(0)]],
                          constant VolSimParams &p [[buffer(1)]],
                          uint3 gid [[thread_position_in_grid]]) {
    uint 边长 = uint(max(p.域.z, 1.0f));
    if (volOutOfRange(gid, 边长)) return;

    float3 lp = volVoxelToLocal(p, gid);
    float4 中心 = state.read(gid);
    float3 v = 中心.xyz;
    float 温 = 中心.w;
    float 密 = density.read(gid).x;
    bool 被挡 = false;

    // 地面：局部的喷口底盘平面，法向 = 局部 Y
    if (p.碰撞.z > 0.5f) {
        float 地面 = p.碰撞.y;
        if (lp.y < 地面) {
            v.y = max(v.y, 0.0f);
            被挡 = true;
        }
    }

    // 球体：在球内则把速度投影到球面切平面，密度擦掉（火不该在实心物体内部）
    uint 球数 = uint(max(p.碰撞.x, 0.0f));
    if (球数 > 0u) {
        float3 世界点 = volLocalToWorld(p, lp);
        for (uint i = 0u; i < 球数; ++i) {
            float3 球心 = 球们[i].球心半径.xyz;
            float 半径 = 球们[i].球心半径.w;
            if (半径 <= 1e-4f) continue;
            float3 差 = 世界点 - 球心;
            float 距 = length(差);
            if (距 < 半径) {
                float3 法向世界 = 差 / max(距, 1e-5f);
                float3 法向局部;
                法向局部.x = dot(法向世界, normalize(p.world.columns[0].xyz));
                法向局部.y = dot(法向世界, normalize(p.world.columns[1].xyz));
                法向局部.z = dot(法向世界, normalize(p.world.columns[2].xyz));
                float 法向分量 = dot(v, 法向局部);
                if (法向分量 < 0.0f) v -= 法向局部 * 法向分量;
                密 = 0.0f;
                被挡 = true;
            }
        }
    }

    // 顶部自由出流：向上的气流带着密度离开域，不在顶盖糊成一片
    float 高 = p.域.y;
    if (lp.y > 高 - p.域.w * 3.0f && v.y > 0.0f) {
        密 *= 0.42f;
        温 = 0.0f;
    }

    // 盒边界：法向速度置零，防止"贴墙抽风"
    float 半宽 = p.域.x;
    if (lp.y < 0.0f) { v.y = max(v.y, 0.0f); }
    if (lp.x < -半宽 || lp.x > 半宽) { v.x = 0.0f; 密 = 0.0f; }
    if (lp.z < -半宽 || lp.z > 半宽) { v.z = 0.0f; 密 = 0.0f; }

    温 = 被挡 ? 温 * 0.92f : 温;
    state.write(float4(v, 温), gid);
    density.write(float4(密, 0.0f, 0.0f, 0.0f), gid);
}

// ============================================================================
// 0) 首帧清空（private 纹理不保证为零）
// ============================================================================
kernel void volSimClear(texture3d<float, access::write> 速A [[texture(0)]],
                        texture3d<float, access::write> 速B [[texture(1)]],
                        texture3d<float, access::write> 密A [[texture(2)]],
                        texture3d<float, access::write> 密B [[texture(3)]],
                        texture3d<float, access::write> 压A [[texture(4)]],
                        texture3d<float, access::write> 压B [[texture(5)]],
                        uint3 gid [[thread_position_in_grid]]) {
    速A.write(float4(0.0f), gid);
    速B.write(float4(0.0f), gid);
    密A.write(float4(0.0f), gid);
    密B.write(float4(0.0f), gid);
    压A.write(float4(0.0f), gid);
    压B.write(float4(0.0f), gid);
}
