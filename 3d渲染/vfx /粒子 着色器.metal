#include <metal_stdlib>
using namespace metal;

// MARK: - 粒子（spark / 浮尘 / 溅沫）
//
// 【分工】这个文件里其实住着两套东西：
//   1) 粒子管线：真正的"一颗颗"，走球 impostor + compute 发射/步进 —— 火花、浮尘、水花溅沫用它；
//   2) 体积管线：火和烟的密度场 raymarch（见文件末尾）—— 连续介质，不该由球来假装。
// 火/烟在 Swift 侧（特效设置.走体积）就已经分流掉，压根不会进粒子池，
// 所以这里的 种类 只剩 0（粒子）与 3（水溅沫）会真正跑到。

// MARK: GPU 结构（与 粒子 GPU 类型.swift 逐字节一致）

/// 48 字节
struct 粒子GPU {
    float4 位置_已活;   // xyz 世界位置, w 已活秒数
    float4 速度_总活;   // xyz 速度, w 总寿命（0 = 空闲槽）
    float4 随机;        // x 相位, y 尺寸抖动, z 湍流种子, w 保留
};

/// 224 字节
struct 发射参数 {
    float4x4 世界;
    float 初速;
    float 速度随机;
    float 扩散余弦;
    float 寿命;
    float 寿命随机;
    float 起始尺寸;
    float 终止尺寸;
    float 不透明度;
    float4 起始颜色;
    float4 终止颜色;
    float 重力倍率;
    float 风力倍率;
    float 湍流;
    float 种类;
    float4 重力;        // xyz 加速度, w 空气阻力
    float4 风;          // xyz 恒定风, w 全局湍流
    float4 流;          // xyz 流场, w 时间（秒）
    float 碰撞开关;
    float 粒子半径;
    uint 球数;
    uint 池容量;
    uint 发射数;
    uint 帧序号;
    float dt;
    float 保留;
};

// MARK: 随机与噪声

static inline uint pHash(uint x) {
    x ^= x >> 16; x *= 0x7FEB352Du;
    x ^= x >> 15; x *= 0x846CA68Bu;
    x ^= x >> 16;
    return x;
}

/// 0…1 均匀
static inline float pRand(uint s) {
    return float(pHash(s) & 0x00FFFFFFu) / 16777215.0f;
}

static inline float pHash13(float3 p) {
    p = fract(p * 0.1031f);
    p += dot(p, p.yzx + 33.33f);
    return fract((p.x + p.y) * p.z);
}

/// 三线性 value noise，湍流扰动用
static inline float pNoise3(float3 p) {
    float3 i = floor(p);
    float3 f = fract(p);
    f = f * f * (3.0f - 2.0f * f);
    float n000 = pHash13(i + float3(0.0f, 0.0f, 0.0f));
    float n100 = pHash13(i + float3(1.0f, 0.0f, 0.0f));
    float n010 = pHash13(i + float3(0.0f, 1.0f, 0.0f));
    float n110 = pHash13(i + float3(1.0f, 1.0f, 0.0f));
    float n001 = pHash13(i + float3(0.0f, 0.0f, 1.0f));
    float n101 = pHash13(i + float3(1.0f, 0.0f, 1.0f));
    float n011 = pHash13(i + float3(0.0f, 1.0f, 1.0f));
    float n111 = pHash13(i + float3(1.0f, 1.0f, 1.0f));
    float x00 = mix(n000, n100, f.x);
    float x10 = mix(n010, n110, f.x);
    float x01 = mix(n001, n101, f.x);
    float x11 = mix(n011, n111, f.x);
    return mix(mix(x00, x10, f.y), mix(x01, x11, f.y), f.z);
}

// MARK: 发射（compute）

/// 一次派发 = 本帧要喷的 发射数 个线程，每个线程抢一个池槽位（写指针原子递增）。
kernel void particleEmit(device 粒子GPU *粒子 [[buffer(0)]],
                         constant 发射参数 &参数 [[buffer(1)]],
                         device atomic_uint *写指针 [[buffer(2)]],
                         uint tid [[thread_position_in_grid]]) {
    uint 槽 = atomic_fetch_add_explicit(写指针, 1u, memory_order_relaxed);
    if (槽 >= 参数.池容量) { return; }   // 抢过头的直接丢弃

    uint 种子 = pHash(参数.帧序号 * 0x9E3779B9u ^ (tid + 1u) * 0x85EBCA6Bu);
    float r0 = pRand(种子);
    float r1 = pRand(种子 ^ 0x68E31DA4u);
    float r2 = pRand(种子 ^ 0x1B56C4E9u);
    float r3 = pRand(种子 ^ 0x0F423F2Bu);
    float r4 = pRand(种子 ^ 0x3C6EF372u);

    // 发射口固定在发射器局部原点；沿局部 +Y 的锥内随机方向
    float3 原点 = (参数.世界 * float4(0.0f, 0.0f, 0.0f, 1.0f)).xyz;
    float 余弦 = mix(clamp(参数.扩散余弦, -1.0f, 1.0f), 1.0f, r1);
    float 正弦 = sqrt(max(0.0f, 1.0f - 余弦 * 余弦));
    float 角 = r2 * 6.2831853f;
    float3 局部方向 = float3(cos(角) * 正弦, 余弦, sin(角) * 正弦);
    float3 方向 = normalize((参数.世界 * float4(局部方向, 0.0f)).xyz);

    float 速率 = 参数.初速 + 参数.速度随机 * (r3 * 2.0f - 1.0f);
    float 总活 = max(0.02f, 参数.寿命 * (1.0f + 参数.寿命随机 * (r4 * 2.0f - 1.0f)));
    // 出生点带一点半径抖动，避免所有粒子从同一个点冒出
    float3 出生点 = 原点 + 方向 * (参数.起始尺寸 * 0.5f * r0);

    粒子[槽].位置_已活 = float4(出生点, 0.0f);
    粒子[槽].速度_总活 = float4(方向 * 速率, 总活);
    粒子[槽].随机 = float4(r0, r1 * 2.0f - 1.0f, r2, 0.0f);
}

// MARK: 步进（compute）

kernel void particleStep(device 粒子GPU *粒子 [[buffer(0)]],
                         constant 发射参数 &参数 [[buffer(1)]],
                         constant float4 *碰撞球 [[buffer(2)]],
                         uint gid [[thread_position_in_grid]]) {
    if (gid >= 参数.池容量) { return; }

    粒子GPU p = 粒子[gid];
    float 总活 = p.速度_总活.w;
    if (总活 <= 0.0f) { return; }        // 空闲槽：什么都不做，别覆盖别人的数据

    float 已活 = p.位置_已活.w + 参数.dt;
    if (已活 >= 总活) {
        // 到期回收：w 置 0 即空闲，池内不做压缩搬移（槽位复用在发射阶段原子抢）
        粒子[gid].速度_总活.w = 0.0f;
        粒子[gid].位置_已活.w = 0.0f;
        return;
    }

    float3 加速度 = (参数.重力 * 参数.重力倍率 + 参数.风 * 参数.风力倍率).xyz;

    if (参数.湍流 > 0.0f) {
        // 湍流是"打碎"，不是整体推力：用位置 + 相位做的噪声场，产生分叉与抖动
        float3 采样点 = p.位置_已活.xyz * 0.85f
                      + float3(p.随机.x, p.随机.z, p.随机.y) * 6.0f
                      + 参数.流.xyz * 参数.流.w;
        float3 扰动 = float3(pNoise3(采样点),
                             pNoise3(采样点 + float3(31.4f, 17.7f, 5.3f)),
                             pNoise3(采样点 + float3(-11.9f, 43.1f, 27.5f))) - 0.5f;
        加速度 += 扰动 * (2.0f * 参数.湍流 * 6.0f);
    }

    float3 速度 = p.速度_总活.xyz + 加速度 * 参数.dt;

    // 空气阻力：每秒衰减 阻力 比例，按 dt 取幂才不随帧率漂移
    float 阻力 = clamp(参数.重力.w, 0.0f, 0.999f);
    if (阻力 > 0.0f) { 速度 *= pow(max(0.0f, 1.0f - 阻力), 参数.dt); }

    float3 位置 = p.位置_已活.xyz + 速度 * 参数.dt;

    // 场景碰撞球：推出表面 + 法向反弹（带一点能量损失）
    if (参数.碰撞开关 > 0.5f) {
        for (uint i = 0u; i < 参数.球数; ++i) {
            float4 球 = 碰撞球[i];
            float3 差 = 位置 - 球.xyz;
            float 距离 = length(差);
            float 最小 = 球.w + 参数.粒子半径;
            if (距离 < 最小 && 距离 > 1e-5f) {
                float3 法线 = 差 / 距离;
                位置 = 球.xyz + 法线 * 最小;
                float 法向 = dot(速度, 法线);
                if (法向 < 0.0f) { 速度 -= 法线 * 法向 * 1.4f; }
            }
        }
    }

    粒子[gid].位置_已活 = float4(位置, 已活);
    粒子[gid].速度_总活 = float4(速度, 总活);
}

// MARK: 颜色 / 观察（渲染）

struct 粒子顶点输出 {
    float4 位置 [[position]];
    float2 uv;
    float4 颜色;
    float 高光 [[flat]];
};

// 视口只有一盏虚拟主光：粒子层拿不到 PT 的灯光，明暗只为让球有体积感
static inline float3 主光方向() { return normalize(float3(-0.35f, 0.85f, 0.55f)); }

vertex 粒子顶点输出 particleVertex(uint vid [[vertex_id]],
                                   uint iid [[instance_id]],
                                   device const 粒子GPU *粒子 [[buffer(0)]],
                                   constant 发射参数 &参数 [[buffer(1)]],
                                   constant float4x4 &视图投影 [[buffer(2)]],
                                   constant float4 *相机基 [[buffer(3)]]) {
    粒子顶点输出 出;
    float2 角点 = float2((vid & 1u) ? 1.0f : -1.0f, (vid & 2u) ? 1.0f : -1.0f);
    出.uv = 角点;
    出.颜色 = float4(0.0f);
    出.高光 = 0.0f;

    粒子GPU p = 粒子[iid];
    float 总活 = p.速度_总活.w;
    if (总活 <= 0.0f) {
        出.位置 = float4(0.0f, 0.0f, 0.0f, 0.0f);   // w=0：整片退化到无穷远，不产生片元
        return 出;
    }

    float t = saturate(p.位置_已活.w / max(总活, 1e-4f));
    float 尺寸 = mix(参数.起始尺寸, 参数.终止尺寸, t) * (1.0f + 0.25f * p.随机.y);
    if (尺寸 <= 1e-5f) { 出.位置 = float4(0.0f, 0.0f, 0.0f, 0.0f); return 出; }

    float4 色 = mix(参数.起始颜色, 参数.终止颜色, t);
    float 淡出 = 1.0f - t;
    出.颜色 = float4(色.rgb, 色.a * 参数.不透明度 * 淡出 * 淡出);
    出.高光 = (参数.种类 >= 2.5f) ? 1.0f : 0.0f;   // 3 = 水，给湿高光

    float3 右向 = 相机基[0].xyz;
    float3 上向 = 相机基[1].xyz;
    float3 世界位置 = p.位置_已活.xyz + (右向 * 角点.x + 上向 * 角点.y) * (尺寸 * 0.5f);
    出.位置 = 视图投影 * float4(世界位置, 1.0f);
    return 出;
}

fragment float4 particleFragment(粒子顶点输出 in [[stage_in]]) {
    float r2 = dot(in.uv, in.uv);
    if (r2 > 1.0f) { discard_fragment(); }

    float r = sqrt(r2);
    float3 法线 = normalize(float3(in.uv, sqrt(max(1.0f - r2, 1e-4f))));
    float 软化 = 1.0f - smoothstep(0.35f, 1.0f, r);
    float 明暗 = 0.45f + 0.55f * saturate(dot(法线, 主光方向()));

    float a = in.颜色.a * 软化 * 明暗;
    float3 rgb = in.颜色.rgb * a;   // 预乘 alpha：混合式是 one / oneMinusSourceAlpha

    if (in.高光 > 0.5f) {
        float3 半角 = normalize(主光方向() + float3(0.0f, 0.0f, 1.0f));
        float s = pow(saturate(dot(法线, 半角)), 42.0f);
        rgb += float3(s * 0.85f);
        a = saturate(a + s * 0.55f);
    }

    if (a <= 0.002f) { discard_fragment(); }
    return float4(rgb, a);
}




// MARK: - 体积特效（火 / 烟）
//
// 【口径】火和烟是连续介质，密度场必须由速度场输运出来。这里的密度不是解析出来的，
// 而是 体积 模拟.metal 在 GPU 上跑欧拉网格（自平流 + 涡量约束 + 燃烧 + 压力投影 + SDF 碰撞）
// 得到的 3D 纹理。视口只做一件事：沿视线在纹理里积分发光与吸收。
//
// 这样做的三个直接后果：
//   1) 形态由物理决定 —— 火舌、翻卷、被风压弯、撞到物体散开，都不是手写公式能摆出来的；
//   2) 成本与"火的个数"线性但每火只覆盖自己的包围盒，不像旧的全屏 raymarch 那样一多就崩；
//   3) 视口与 PT 读的是同一张纹理 —— 视口看到什么，出图就是什么，不可能再分叉。
#define VOL_STEP_MAX      96u
#define VOL_EXPOSURE      1.0f

// 与 Swift 侧 体积发射参数 逐字节一致（192 字节）
struct VolumeFXParams {
    float4x4 world;
    float4 birth;    // rgb 出生色, w 不透明度
    float4 death;    // rgb 终止色, w 重力倍率
    float4 axisCone; // x 初速, y 寿命, z 起始半径, w cosCone（仅保留给旧逻辑，形态已不依赖）
    float4 emit;     // x 种类(1火/2烟), y 湍流倍率, z 时间(秒), w 保留
    float4 bounds;   // 保留
    float4 域盒;      // x 半宽, y 高, z 网格边长, w 体素边长
    float4 配色;      // x 消光, y 发光强度, z 自阴影, w 保留
};

// 与 Swift 侧 体积相机参数 逐字节一致
struct VolumeFXCam {
    float4 eye;
    float4 rightV;
    float4 upV;
    float4 fwd;
    float4 plane;   // x tanHalfFov, y aspect, z 步数, w 保留
    float4x4 viewProj;
};

struct VolumeFXOut {
    float4 position [[position]];
    float2 uv;
};

constexpr sampler volTexSampler(mag_filter::linear, min_filter::linear, address::clamp_to_edge);

/// 密度外观映射：幂次压缩 + 增益。模拟端已把低于死区的尾雾硬置 0，
/// 这里再把残存的中低密度往下压一档，只留真正密的火芯与烟柱 ——
/// 外轮廓因此由"密度分布"决定，而不是由包围盒决定（旧版那团圆球就是这么来的）。
/// 【必须与 PT 着色器 ptSimDensityLook 逐项同式】，否则视口与出图两副样子。
static inline float volDensityLook(float 原始, float 死区) {
    float 存活 = saturate((max(原始, 0.0f) - 死区) / max(1.0f - 死区, 1e-3f));
    return pow(存活, 1.35f) * 2.2f;
}

// MARK: 几何

/// 纹理密度上界：主光方向的 majorant，固定值换掉逐点求上界的大量采样
#define VOL_MAJORANT 3.2f

static inline float3 volLocalToWorld(constant VolumeFXParams &v, float3 lp) {
    return (v.world * float4(lp, 1.0f)).xyz;
}

static inline float3 volWorldToLocal(constant VolumeFXParams &v, float3 wp) {
    float3 d = wp - v.world.columns[3].xyz;
    float3 c0 = v.world.columns[0].xyz;
    float3 c1 = v.world.columns[1].xyz;
    float3 c2 = v.world.columns[2].xyz;
    return float3(dot(d, c0) / max(dot(c0, c0), 1e-9f),
                  dot(d, c1) / max(dot(c1, c1), 1e-9f),
                  dot(d, c2) / max(dot(c2, c2), 1e-9f));
}

static inline float3 volLocalToUV(constant VolumeFXParams &v, float3 lp) {
    float 半宽 = max(v.域盒.x, 1e-4f);
    float 高 = max(v.域盒.y, 1e-4f);
    return float3((lp.x + 半宽) / (2.0f * 半宽), lp.y / 高, (lp.z + 半宽) / (2.0f * 半宽));
}

/// 包围球：局部盒 8 个角的世界外接球
static inline void volFieldBounds(constant VolumeFXParams &v, thread float3 &中心, thread float &半径) {
    float 半宽 = max(v.域盒.x, 0.02f);
    float 高 = max(v.域盒.y, 0.02f);
    float3 局部中心 = float3(0.0f, 高 * 0.5f, 0.0f);
    中心 = volLocalToWorld(v, 局部中心);
    float 半对角 = 0.5f * length(float3(半宽 * 2.0f, 高, 半宽 * 2.0f));
    半径 = 半对角 * 1.02f;
}

static inline bool volRayBox(float3 ro, float3 rd, constant VolumeFXParams &v,
                             thread float &t0, thread float &t1) {
    // 用局部空间做 slab 测试：射线搬到局部空间，盒固定为 [-半宽,半宽]×[0,高]×[-半宽,半宽]
    float3 o = volWorldToLocal(v, ro);
    float3 c0 = v.world.columns[0].xyz;
    float3 c1 = v.world.columns[1].xyz;
    float3 c2 = v.world.columns[2].xyz;
    float3 d = float3(dot(rd, c0) / max(dot(c0, c0), 1e-9f),
                      dot(rd, c1) / max(dot(c1, c1), 1e-9f),
                      dot(rd, c2) / max(dot(c2, c2), 1e-9f));
    float 半宽 = max(v.域盒.x, 0.02f);
    float 高 = max(v.域盒.y, 0.02f);
    float3 下界 = float3(-半宽, 0.0f, -半宽);
    float3 上界 = float3(半宽, 高, 半宽);
    float 进入 = -1e30f;
    float 离开 = 1e30f;
    for (int i = 0; i < 3; ++i) {
        float oi = o[i];
        float di = d[i];
        float lo = 下界[i];
        float hi = 上界[i];
        if (abs(di) < 1e-8f) {
            if (oi < lo || oi > hi) return false;
            continue;
        }
        float ta = (lo - oi) / di;
        float tb = (hi - oi) / di;
        if (ta > tb) { float tmp = ta; ta = tb; tb = tmp; }
        进入 = max(进入, ta);
        离开 = min(离开, tb);
    }
    if (离开 <= max(进入, 0.0f)) return false;
    t0 = max(进入, 0.0f);
    t1 = 离开;
    return true;
}

// MARK: 黑体色温

/// 色温 → 线性 RGB（Tanner Helland 近似）：900K 暗红、1800K 橙、3000K 亮黄白
static inline float3 volBlackbody(float 开尔文) {
    float t = clamp(开尔文, 500.0f, 12000.0f) / 100.0f;
    float 红, 绿, 蓝;
    if (t <= 66.0f) {
        红 = 1.0f;
    } else {
        红 = saturate(1.2929362f * pow(max(t - 60.0f, 1e-3f), -0.1332048f));
    }
    if (t <= 66.0f) {
        绿 = saturate(0.39008157f * log(t) - 0.63184144f);
    } else {
        绿 = saturate(1.1298909f * pow(max(t - 60.0f, 1e-3f), -0.0755148f));
    }
    if (t >= 66.0f) {
        蓝 = 1.0f;
    } else if (t <= 19.0f) {
        蓝 = 0.0f;
    } else {
        蓝 = saturate(0.5432068f * log(max(t - 10.0f, 1e-3f)) - 1.1962541f);
    }
    return float3(红, 绿, 蓝);
}

// MARK: 火焰外观参数

// 【为什么复用 bounds 而不是给结构扩容】VolumeFXParams 与 Swift 侧 体积发射参数 是
// 逐字节对齐的（192 字节），中间插一个 float4 就等于把后面所有字段的偏移全部挪位，
// 一旦两边有一处漏改，表现是"颜色/位置莫名错乱"而不是报错。bounds 一直是保留字段，
// 这里把它征用成火焰外观，零布局风险。
// x 芯色温(K)  y 尾色温(K)  z 内部结构强度(0=均匀一块, 0.5~0.9 自然)  w 亮度倍率

/// 芯色温：火根白热的那个温度。默认 3400K（亮黄白）。
static inline float volFireCoreK(constant VolumeFXParams &v) {
    return v.bounds.x > 1.0f ? v.bounds.x : 3400.0f;
}

/// 尾色温：外焰/火舌顶端。默认 760K（暗红），压太低会整体发红发脏。
static inline float volFireTailK(constant VolumeFXParams &v) {
    return v.bounds.y > 1.0f ? v.bounds.y : 760.0f;
}

/// 亮度倍率（HDR 发光强度之上的总增益）。
static inline float volFireGain(constant VolumeFXParams &v) {
    return v.bounds.w > 0.001f ? v.bounds.w : 1.0f;
}

/// 火的内部结构：用世界空间的固定噪声给密度场分出薄厚。
///
/// 【为什么不用材质 α 做"半透"】火是自发光介质，观感上的"局部透局部不"来自
/// **同一条视线穿过好几层密度不同的火舌**：薄处消光小、光穿过去，后面的亮芯透出来；
/// 厚处自己挡自己，叠成暗红。所以这里调的是消光与发光，光路照旧走体积积分。
/// 噪声沿 -Y 缓慢上飘（乘时间），否则火会像一块静止的噪点贴图"钉"在原地。
/// 返回 0.35~1.65 的倍率：小于 1 = 变薄变透，大于 1 = 变厚更挡光。
static inline float volFireStructure(float3 p, float 时间, float 强度) {
    float k = saturate(强度);
    if (k <= 0.001f) return 1.0f;
    float3 q = p * 7.0f + float3(0.0f, -时间 * 1.6f, 0.0f);
    float a = pNoise3(q);
    float b = pNoise3(q * 2.3f + float3(11.0f, 3.0f, 7.0f));
    float n = saturate(a * 0.65f + b * 0.35f);
    return mix(1.0f, 0.35f + 1.3f * n, k);
}

// MARK: 场采样

/// 从模拟纹理读 (密度, 温度)。越界即空，不做边缘外推 —— 外推会让火焰贴着盒壁"糊一片"。
static inline void volSample(texture3d<float> 速, texture3d<float> 密,
                             constant VolumeFXParams &v, float3 p,
                             thread float &密度, thread float &温度) {
    密度 = 0.0f;
    温度 = 0.0f;
    if (v.birth.w <= 1e-5f) return;

    float3 lp = volWorldToLocal(v, p);
    float 半宽 = v.域盒.x;
    float 高 = v.域盒.y;
    if (lp.y < 0.0f || lp.y > 高) return;
    if (abs(lp.x) > 半宽 || abs(lp.z) > 半宽) return;

    float3 uv = volLocalToUV(v, lp);
    密度 = volDensityLook(密.sample(volTexSampler, uv).x, v.配色.w);
    温度 = 速.sample(volTexSampler, uv).w;
}

/// 朝光源方向的密度遮蔽（体积自阴影）：烟才有厚度感，火因为自发光主要靠这个压暗外缘
static inline float volShadow(texture3d<float> 密, constant VolumeFXParams &v, float3 p, float3 光向) {
    float 步 = max(v.域盒.w * 2.2f, 0.01f);
    float 累积 = 0.0f;
    for (int i = 1; i <= 5; ++i) {
        float3 采样点 = p + 光向 * (步 * float(i));
        float3 lp = volWorldToLocal(v, 采样点);
        if (lp.y < 0.0f || lp.y > v.域盒.y) break;
        if (abs(lp.x) > v.域盒.x || abs(lp.z) > v.域盒.x) break;
        float3 uv = volLocalToUV(v, lp);
        累积 += volDensityLook(密.sample(volTexSampler, uv).x, v.配色.w);
    }
    return exp(-累积 * 1.15f);
}

// MARK: 顶点 / 片元

vertex VolumeFXOut volumeFXVertex(uint vid [[vertex_id]],
                                  constant VolumeFXParams &v [[buffer(0)]],
                                  constant VolumeFXCam &cam [[buffer(1)]]) {
    float2 corner = float2((vid & 1u) == 0u ? -1.0 : 1.0, (vid & 2u) == 0u ? -1.0 : 1.0);

    float3 中心;
    float 半径;
    volFieldBounds(v, 中心, 半径);

    float3 wp = 中心 + (cam.rightV.xyz * corner.x + cam.upV.xyz * corner.y) * (半径 * 1.02f);

    VolumeFXOut o;
    o.position = cam.viewProj * float4(wp, 1.0f);
    o.uv = corner;
    return o;
}

fragment float4 volumeFXFragment(VolumeFXOut in [[stage_in]],
                                 constant VolumeFXParams &v [[buffer(0)]],
                                 constant VolumeFXCam &cam [[buffer(1)]],
                                 texture3d<float> 速 [[texture(0)]],
                                 texture3d<float> 密 [[texture(1)]]) {
    float3 ro = cam.eye.xyz;
    float3 rd = normalize(cam.fwd.xyz
                          + cam.rightV.xyz * (in.uv.x * cam.plane.x * cam.plane.y)
                          + cam.upV.xyz * (in.uv.y * cam.plane.x));

    float t0, t1;
    if (!volRayBox(ro, rd, v, t0, t1)) {
        discard_fragment();
        return float4(0.0f);
    }
    if (t1 <= t0 + 1e-5f) {
        discard_fragment();
        return float4(0.0f);
    }

    uint 步数 = uint(clamp(cam.plane.z, 16.0f, float(VOL_STEP_MAX)));
    float 基准步长 = (t1 - t0) / float(步数);

    // 蓝噪声感抖动：每像素错开起点，配合自适应步长消掉层带
    float 抖动 = fract(sin(dot(in.position.xy, float2(12.9898f, 78.233f))) * 43758.5453f);
    float dt = 基准步长;
    float t = t0 + dt * 抖动;

    bool 是火 = v.emit.x < 1.5f;
    float 消光 = max(v.配色.x, 0.0f);
    float 发光强度 = max(v.配色.y, 0.05f);
    float3 冷端色 = v.death.rgb;
    float3 热端色 = v.birth.rgb;
    float3 光向 = normalize(float3(0.35f, 0.9f, 0.25f));

    float3 辐射 = float3(0.0f);
    float 透射 = 1.0f;

    uint 步数上限 = 步数 * 2u;
    for (uint i = 0u; i < 步数上限 && t < t1; ++i) {
        float3 p = ro + rd * t;
        float 密度, 温度;
        volSample(速, 密, v, p, 密度, 温度);

        float sigma = 密度 * 消光;
        // 内部结构必须在判空之前作用到 sigma 上：薄的地方先变薄，光才穿得过去，
        // 后面的火芯才能透出来 —— 这是"局部透局部不"的唯一来路。
        float 结构倍率 = 是火 ? volFireStructure(p, v.emit.z, v.bounds.z) : 1.0f;
        sigma *= 结构倍率;
        if (sigma > 1e-4f) {
            float3 发光 = float3(0.0f);
            float3 反照率 = float3(0.0f);
            if (是火) {
                // 温度 → 色温：根部白热、外缘暗红，这是火的真实色阶来源
                float 热 = saturate(温度 / 2.0f);
                float3 黑体 = volBlackbody(mix(volFireTailK(v), volFireCoreK(v), 热 * 热));
                // 保留一点用户调色：出生色作热端、终止色作冷端
                float3 用户 = mix(冷端色, 热端色, 热);
                发光 = mix(黑体, 黑体 * 用户 * 1.9f, 0.35f)
                     * (发光强度 * volFireGain(v) * 结构倍率 * (0.12f + 1.35f * 热 * 热));
                反照率 = float3(0.55f, 0.16f, 0.05f);
            } else {
                // 烟不是纯黑：靠环境光与自阴影给出体积感
                float 遮蔽 = v.配色.z > 0.5f ? volShadow(密, v, p, 光向) : 1.0f;
                float 环境 = 0.22f + 0.78f * saturate(rd.y * 0.5f + 0.5f);
                发光 = 冷端色 * (0.04f * 温度);
                反照率 = mix(热端色, 冷端色, 0.5f) * (0.35f + 0.9f * 遮蔽) * 环境;
            }
            辐射 += 透射 * (发光 + 反照率 * 0.55f) * sigma * dt;
            透射 *= exp(-sigma * dt);
            if (透射 < 0.004f) break;
        }
        t += dt;
    }

    float 覆盖率 = saturate(1.0f - 透射);
    if (覆盖率 <= 1e-3f) {
        discard_fragment();
        return float4(0.0f);
    }

    // 预乘 alpha：先还原平均色再 HDR 压缩，避免 8bit 目标被削顶成一片死黄
    float3 平均色 = 辐射 / max(覆盖率, 1e-3f);
    float3 x = 平均色 * VOL_EXPOSURE;
    float3 映射 = saturate((x * (2.51f * x + 0.03f)) / (x * (2.43f * x + 0.59f) + 0.14f));
    return float4(映射 * 覆盖率, 覆盖率);
}


// ============================================================================
// 单次全屏合并体积渲染（多实例）
//    为什么要有这一版：旧路径是"每个火一个全屏 quad 各跑一遍 raymarch"，
//    10 个火 = 10 次全屏 raymarch，而且互相之间不共享透射率，重叠处颜色直接叠爆。
//    这里改成：整屏只画一次，fragment 内把所有实例的包围盒区间按 t0 排序后
//    统一累积辐射与透射 —— 重叠处的吸收/遮挡是对的，实例数增长只增加少量采样。
// ============================================================================

#define VOL_MERGE_MAX 8

struct VolumeFXMergeHeader {
    int 数量;
    int 填充0;
    int 填充1;
    int 填充2;
};

/// 合并版采样：纹理由调用方按实例下标传入，内部只做局部盒裁剪 + 三线性采样
static inline void volSampleOf(texture3d<float> 速, texture3d<float> 密,
                               constant VolumeFXParams &v, float3 p,
                               thread float &密度, thread float &温度) {
    密度 = 0.0f;
    温度 = 0.0f;
    float3 lp = volWorldToLocal(v, p);
    float 半宽 = v.域盒.x;
    float 高 = v.域盒.y;
    if (lp.y < 0.0f || lp.y > 高) return;
    if (abs(lp.x) > 半宽 || abs(lp.z) > 半宽) return;
    float3 uv = volLocalToUV(v, lp);
    密度 = volDensityLook(密.sample(volTexSampler, uv).x, v.配色.w);
    温度 = 速.sample(volTexSampler, uv).w;
}

vertex VolumeFXOut volumeFXFullscreenVertex(uint vid [[vertex_id]]) {
    float2 corner = float2((vid & 1u) == 0u ? -1.0 : 1.0, (vid & 2u) == 0u ? -1.0 : 1.0);
    VolumeFXOut o;
    o.position = float4(corner, 0.0f, 1.0f);
    o.uv = corner;
    return o;
}

fragment float4 volumeFXMergedFragment(VolumeFXOut in [[stage_in]],
                                       constant VolumeFXMergeHeader &h [[buffer(0)]],
                                       constant VolumeFXCam &cam [[buffer(1)]],
                                       constant VolumeFXParams *实例 [[buffer(2)]],
                                       array<texture3d<float>, VOL_MERGE_MAX> 速表 [[texture(0)]],
                                       array<texture3d<float>, VOL_MERGE_MAX> 密表 [[texture(VOL_MERGE_MAX)]]) {
    float3 ro = cam.eye.xyz;
    float3 rd = normalize(cam.fwd.xyz
                          + cam.rightV.xyz * (in.uv.x * cam.plane.x * cam.plane.y)
                          + cam.upV.xyz * (in.uv.y * cam.plane.x));

    int 数 = clamp(h.数量, 0, VOL_MERGE_MAX);
    float 区入[VOL_MERGE_MAX];
    float 区出[VOL_MERGE_MAX];
    int 序[VOL_MERGE_MAX];
    int 有效 = 0;
    for (int i = 0; i < 数; ++i) {
        float a = 0.0f, b = 0.0f;
        if (volRayBox(ro, rd, 实例[i], a, b)) {
            序[有效] = i;
            区入[有效] = a;
            区出[有效] = b;
            有效 += 1;
        }
    }
    if (有效 == 0) {
        discard_fragment();
        return float4(0.0f);
    }
    // 按进入距离排序：体积累积必须从近到远，否则重叠处透射率用错、颜色叠爆
    for (int i = 1; i < 有效; ++i) {
        float k入 = 区入[i];
        float k出 = 区出[i];
        int k序 = 序[i];
        int j = i - 1;
        while (j >= 0 && 区入[j] > k入) {
            区入[j + 1] = 区入[j];
            区出[j + 1] = 区出[j];
            序[j + 1] = 序[j];
            j -= 1;
        }
        区入[j + 1] = k入;
        区出[j + 1] = k出;
        序[j + 1] = k序;
    }

    float3 光向 = normalize(float3(0.35f, 0.9f, 0.25f));
    uint 步数 = uint(clamp(cam.plane.z, 12.0f, 96.0f));
    float 抖动 = fract(sin(dot(in.position.xy, float2(12.9898f, 78.233f))) * 43758.5453f);

    float3 辐射 = float3(0.0f);
    float 透射 = 1.0f;

    for (int k = 0; k < 有效; ++k) {
        if (透射 < 0.004f) break;
        int i = 序[k];
        constant VolumeFXParams &v = 实例[i];
        float a = 区入[k];
        float b = 区出[k];
        if (b <= a) continue;

        bool 是火 = v.emit.x < 1.5f;
        float 消光 = max(v.配色.x, 0.0f);
        float 发光强度 = max(v.配色.y, 0.05f);
        float3 冷端色 = v.death.rgb;
        float3 热端色 = v.birth.rgb;

        float dt = (b - a) / float(步数);
        float t = a + dt * 抖动;
        for (uint s = 0u; s < 步数 && t < b; ++s) {
            float3 p = ro + rd * t;
            float 密度, 温度;
            volSampleOf(速表[i], 密表[i], v, p, 密度, 温度);
            float sigma = 密度 * 消光;
            // 与单发版同一套结构调制（两边必须一致，否则"一个火"和"多个火"长得不一样）
            float 结构倍率 = 是火 ? volFireStructure(p, v.emit.z, v.bounds.z) : 1.0f;
            sigma *= 结构倍率;
            if (sigma > 1e-4f) {
                float3 发光 = float3(0.0f);
                float3 反照率 = float3(0.0f);
                if (是火) {
                    float 热 = saturate(温度 / 2.0f);
                    float3 黑体 = volBlackbody(mix(volFireTailK(v), volFireCoreK(v), 热 * 热));
                    float3 用户 = mix(冷端色, 热端色, 热);
                    发光 = mix(黑体, 黑体 * 用户 * 1.9f, 0.35f)
                         * (发光强度 * volFireGain(v) * 结构倍率 * (0.12f + 1.35f * 热 * 热));
                    反照率 = float3(0.55f, 0.16f, 0.05f);
                } else {
                    float 环境 = 0.22f + 0.78f * saturate(rd.y * 0.5f + 0.5f);
                    发光 = 冷端色 * (0.04f * 温度);
                    反照率 = mix(热端色, 冷端色, 0.5f) * 0.75f * 环境;
                }
                辐射 += 透射 * (发光 + 反照率 * 0.55f) * sigma * dt;
                透射 *= exp(-sigma * dt);
                if (透射 < 0.004f) break;
            }
            t += dt;
        }
    }

    float 覆盖率 = saturate(1.0f - 透射);
    if (覆盖率 <= 1e-3f) {
        discard_fragment();
        return float4(0.0f);
    }
    float3 平均色 = 辐射 / max(覆盖率, 1e-3f);
    float3 x = 平均色 * VOL_EXPOSURE;
    float3 映射 = saturate((x * (2.51f * x + 0.03f)) / (x * (2.43f * x + 0.59f) + 0.14f));
    return float4(映射 * 覆盖率, 覆盖率);
}
