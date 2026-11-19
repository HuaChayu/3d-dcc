#include <metal_stdlib>
#include <metal_raytracing>
using namespace metal;
using namespace metal::raytracing;

// ============================================================
// 路径追踪内核（M0 骨架 / M1 直接光 + NEE 已通）
// 思路对照 Cycles：同样走"入射光采样 + BSDF 采样"两条腿，
// 但第一步只做单方向路径 + 太阳 NEE，不做 MIS 权重表。
// ============================================================

struct PTCameraGPU {
    float4x4 cameraToWorld;
    float4 params;   // x=tanHalfFov, y=aspect, z=near, w=far
    // x = 介质时间（秒，驱动体积湍流相位）, y = 湍流强度倍率（0 = 关）, z/w 预留。
    // 【为什么挂在相机上】Metal buffer 索引 0…30 已经排满，而这两个量本身就是
    // "这一趟追踪的进场参数"，跟 tanHalfFov 同级，没有更合适的槽位可挂。
    float4 volume;
};

struct PTEnvironmentGPU {
    float4 skyTop;      // xyz 天顶色, w 环境强度
    float4 skyBottom;   // xyz 地平色
    float4 sun;         // xyz 指向太阳, w 辐照强度
};

struct PTMaterialGPU {
    float4 baseColor;   // xyz 基底色, w 基底权重
    float4 emissive;    // xyz 自发光色, w 强度
    float4 p0;          // roughness, metallic, ior, transmission
    float4 p1;          // thinFilmWeight, thinFilmThickness, thinFilmIOR, coatWeight
    float4 p2;          // coatRoughness, coatDarkening, specularWeight, opacity
    // x = 材质贴图（导入的基础色图）在材质图集里的层号，< 0 表示没有贴图（走 baseColor 常量）
    // y = 1 表示这张图按 sRGB 解码（颜色类贴图），0 表示已是线性
    float4 p3;
};

// 显式灯光：不是几何，只参与直接光采样，所以画面里不会出现"发光的网格"
struct PTLightGPU {
    float4 positionRadius;   // xyz 位置, w 发光半径
    float4 axisCosCone;      // xyz 朝向, w 聚光锥半角余弦
    float4 colorIntensity;   // xyz 颜色(含色温), w 强度
    float4 shape;            // x 宽, y 高, z 种类, w 柔和度
};

#define PT_LIGHT_AREA   0u
#define PT_LIGHT_POINT  1u
#define PT_LIGHT_SPOT   2u
#define PT_LIGHT_SUN    3u

// 【开关】显式灯按亮度 CDF 重要性采样。1 = 开启（默认）；0 = 完全退回 1/lightsCount 均匀抽样。
// 回滚方式：把下面这个 1 改成 0，其余代码一行都不用动。
#define PT_EXPLICIT_LIGHT_CDF_ENABLED 1

// 【开关】首跳（bounce==0）也做 NEE（太阳 / 面光 / 显式灯）。
// 1 = 开启（默认）：相机直接看到的那一层表面也开始算直接光，首跳噪声明显下降；
// 0 = 完全退回旧行为：首跳只取"看到的辐射"，直接光从 bounce>=1 才开始算。
// 回滚方式：把下面这个 1 改成 0，其余代码一行都不用动。
// 判定口径：只有"该表面不是 delta 材质"才做首跳 NEE；镜面/玻璃照旧跳过，
// 否则会和 BSDF 采样命中发光面的累加重复计同一份能量。
#define PT_FIRSTBOUNCE_NEE_ENABLED 1

// ------------------------------------------------------------
// 随机数：PCG 变体，够快也够均匀
// ------------------------------------------------------------
struct RNG {
    uint state;

    uint next() {
        state = state * 747796405u + 2891336453u;
        uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
        return (word >> 22u) ^ word;
    }

    float uniform() {
        return float(next() & 0x00FFFFFFu) / 16777216.0f;
    }

    float2 uniform2() {
        return float2(uniform(), uniform());
    }

    float3 cosineHemisphere(float3 normal) {
        float2 u = uniform2();
        float r = sqrt(u.x);
        float phi = 2.0f * M_PI_F * u.y;
        float3 local = float3(r * cos(phi), r * sin(phi), sqrt(max(0.0f, 1.0f - u.x)));
        return localToWorld(local, normal);
    }

    static float3 localToWorld(float3 local, float3 n) {
        float3 up = fabs(n.y) < 0.999f ? float3(0.0f, 1.0f, 0.0f) : float3(1.0f, 0.0f, 0.0f);
        float3 tangent = normalize(cross(up, n));
        float3 bitangent = cross(n, tangent);
        return tangent * local.x + bitangent * local.y + n * local.z;
    }
};

// ------------------------------------------------------------
// 小工具
// ------------------------------------------------------------
static inline float luminanceOf(float3 c) {
    return dot(c, float3(0.2126f, 0.7152f, 0.0722f));
}

static inline float3 skyRadiance(constant PTEnvironmentGPU &env, float3 dir) {
    float t = saturate(dir.y * 0.5f + 0.5f);
    float3 gradient = mix(env.skyBottom.rgb, env.skyTop.rgb, t);
    float3 result = gradient * env.skyTop.a;

    // 太阳圆盘：只为了让镜面反射里能看到光源本身（直接光由 NEE 负责，不会重复计）
    float3 sunDir = normalize(env.sun.xyz);
    float cosAngle = dot(dir, sunDir);
    if (cosAngle > 0.9995f) {
        result += env.sun.w * float3(1.0f, 0.96f, 0.9f) * 40.0f;
    }
    return result;
}

static inline float fresnelSchlick(float cosTheta, float3 f0) {
    float m = pow(saturate(1.0f - cosTheta), 5.0f);
    return m;
}

/// 薄膜干涉的廉价近似：两束光干涉，按 R/G/B 三个波长各算一次余弦。
/// 不是完整 Airy 求和，但色散走向和真实皂膜一致。
static inline float3 thinFilmTint(float thickness, float filmIOR, float cosTheta) {
    float d = max(thickness, 1.0f) * 1e-3f;   // nm → µm
    float opticalPath = 2.0f * filmIOR * d * max(cosTheta, 0.05f);
    const float3 lambda = float3(0.68f, 0.55f, 0.45f);
    float3 phase = 2.0f * M_PI_F * opticalPath / lambda;
    return 0.5f + 0.5f * cos(phase);
}

static inline float3 ggxSample(float3 normal, float roughness, thread RNG &rng) {
    float a = max(roughness * roughness, 0.0015f);
    float2 u = rng.uniform2();
    float phi = 2.0f * M_PI_F * u.x;
    float cosTheta = sqrt((1.0f - u.y) / (1.0f + (a * a - 1.0f) * u.y));
    float sinTheta = sqrt(max(0.0f, 1.0f - cosTheta * cosTheta));
    float3 local = float3(sinTheta * cos(phi), sinTheta * sin(phi), cosTheta);
    return normalize(RNG::localToWorld(local, normal));
}

static inline float ggxD(float nDotH, float roughness) {
    float a = max(roughness * roughness, 0.0015f);
    float a2 = a * a;
    float d = nDotH * nDotH * (a2 - 1.0f) + 1.0f;
    return a2 / max(M_PI_F * d * d, 1e-6f);
}

static inline float smithG1(float nDotV, float roughness) {
    float a = max(roughness * roughness, 0.0015f);
    float k = a * 0.5f;
    return nDotV / max(nDotV * (1.0f - k) + k, 1e-5f);
}

/// 镜面项的完整 BRDF（含 GGX 微表面 + 菲涅尔）
static inline float3 evalSpecular(PTMaterialGPU m, float3 n, float3 v, float3 l, float3 specF0) {
    float3 h = normalize(v + l);
    float nDotL = saturate(dot(n, l));
    float nDotV = saturate(dot(n, v)) + 1e-4f;
    float nDotH = saturate(dot(n, h));
    float vDotH = saturate(dot(v, h));

    float roughness = max(m.p0.x, 0.02f);
    float D = ggxD(nDotH, roughness);
    float G = smithG1(nDotV, roughness) * smithG1(nDotL, roughness);
    float3 F = specF0 + (float3(1.0f) - specF0) * fresnelSchlick(vDotH, specF0);

    float3 tint = float3(1.0f);
    if (m.p1.x > 0.001f) {
        tint = mix(float3(1.0f), thinFilmTint(m.p1.y, m.p1.z, vDotH), m.p1.x);
    }

    return tint * F * (D * G / (4.0f * nDotV * nDotL + 1e-4f)) * nDotL;
}

/// 清漆层：一层薄薄的、更光滑的 GGX 叠在最外层（等效 Coat）
static inline float3 evalCoat(PTMaterialGPU m, float3 n, float3 v, float3 l) {
    if (m.p1.w < 0.001f) return float3(0.0f);
    float3 c = evalSpecular(m, n, v, l, float3(0.04f));
    float rough = max(m.p2.x, 0.02f);
    // 用清漆自身粗糙度再压一次
    float3 h = normalize(v + l);
    float nDotL = saturate(dot(n, l));
    float nDotV = saturate(dot(n, v)) + 1e-4f;
    float D = ggxD(saturate(dot(n, h)), rough);
    float G = smithG1(nDotV, rough) * smithG1(nDotL, rough);
    float F = 0.04f + 0.96f * fresnelSchlick(saturate(dot(v, h)), float3(0.04f));
    return m.p1.w * F * (D * G / (4.0f * nDotV * nDotL + 1e-4f)) * nDotL
        + c * 0.0f;
}

// ------------------------------------------------------------
// 求交结果
// ------------------------------------------------------------
struct Hit {
    bool valid;
    float distance;
    float3 position;
    float3 normal;
    uint materialIndex;
    // 绘画用：命中点的图集 UV + 该物体在图集里的 slice（0xFFFFFFFF = 没有笔迹）
    float2 uv;
    uint slice;
};

// 笔迹只改反照率：图集里 rgb 是颜色、a 是覆盖度。
// 没有笔迹的物体（slice == 0xFFFFFFFF）直接原样返回，一次采样都不做。
static inline float3 paintTint(texture2d_array<float> atlas,
                               sampler s,
                               float2 uv,
                               uint slice,
                               float3 baseColor)
{
    if (slice == 0xFFFFFFFFu) return baseColor;
    // slice 越界时 sample 的结果是未定义的：驱动通常 clamp 到边缘片，
    // 于是整个物体都被糊成那一片的颜色 —— 就是「鼠标划过偶尔把整个模型染成笔刷色」。
    // 片数直接问纹理要，不用 CPU 再传一个参数。
    if (slice >= atlas.get_array_size()) return baseColor;
    float4 tex = atlas.sample(s, uv, slice);
    return mix(baseColor, tex.rgb, tex.a);
}

// HSL 单通道还原（与 Swift 侧 HSL.toColor 同一套公式，差一点视口和出图就会两种颜色）
static inline float ptHSLChannel(float p, float q, float t)
{
    if (t < 0.0f) t += 1.0f;
    if (t > 1.0f) t -= 1.0f;
    if (t < 1.0f / 6.0f) return p + (q - p) * 6.0f * t;
    if (t < 0.5f) return q;
    if (t < 2.0f / 3.0f) return p + (q - p) * (2.0f / 3.0f - t) * 6.0f;
    return p;
}

// 材质自己的基础色：有导入贴图就在贴图上取，没有就返回常量。
// 这一步必须排在 paintTint 之前——「材质在下、绘画在上」的层序就靠这个顺序：
// 贴图只决定"底"，笔迹再按覆盖度盖上去，绘画永远不会被贴图盖掉。
static inline float3 materialBaseColor(texture2d_array<float> matAtlas,
                                       sampler s,
                                       float2 uv,
                                       float4 slot,
                                       float3 常量色)
{
    if (slot.x < 0.0f) return 常量色;
    uint layer = uint(slot.x + 0.5f);
    if (layer >= matAtlas.get_array_size()) return 常量色;
    float3 c = matAtlas.sample(s, uv, layer).rgb;
    // 颜色类贴图按 sRGB 存，线性工作空间里要还原
    if (slot.y > 0.5f) c = pow(max(c, float3(0.0f)), 2.2f);
    return c;
}

static inline Hit traceRay(ray r,
                           instance_acceleration_structure accel,
                           device const float4 *positions,
                           device const float4 *normals,
                           device const uint *indices,
                           device const uint *triangleMaterials,
                           device const float2 *uvs,
                           device const uint *sliceOfVertex,
                           device const uint *holeSlotOfVertex,
                           texture2d_array<float> holeAtlas,
                           float maxDistance)
{
    Hit hit;
    hit.valid = false;
    hit.distance = maxDistance;
    hit.uv = float2(0.0f);
    hit.slice = 0xFFFFFFFFu;

    // 必须带 instancing 标签：只有实例加速结构版的 intersector 才接受 instance_acceleration_structure
    intersector<triangle_data, instancing> isect;
    isect.assume_geometry_type(geometry_type::triangle);
    isect.force_opacity(forced_opacity::opaque);

    // 【镂空 = 真打洞】被用户挖掉的表面在求交阶段就当它不存在：
    // 命中点采样洞图判定是洞，就把射线起点推到命中点之后重新求交（最多连续穿透 8 层）。
    // 不做这一步的话，破掉的披风只能"染回底色"，看着像脏了一块而不是破了个洞。
    constexpr sampler holeSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    for (uint 穿透 = 0u; 穿透 < 8u; ++穿透) {
    auto result = isect.intersect(r, accel);
    if (result.type == intersection_type::none) {
        return hit;
    }

    uint primitive = result.primitive_id;
    uint i0 = indices[primitive * 3 + 0];
    uint i1 = indices[primitive * 3 + 1];
    uint i2 = indices[primitive * 3 + 2];
    float2 bary = result.triangle_barycentric_coord;
    float w0 = 1.0f - bary.x - bary.y;
    float w1 = bary.x;
    float w2 = bary.y;

    float3 n = w0 * normals[i0].xyz + w1 * normals[i1].xyz + w2 * normals[i2].xyz;
    if (length_squared(n) < 1e-8f) {
        n = cross(positions[i1].xyz - positions[i0].xyz, positions[i2].xyz - positions[i0].xyz);
    }
    n = normalize(n);

    hit.valid = true;
    hit.distance = result.distance;
    hit.position = r.origin + r.direction * result.distance;
    // 双面材质：法线朝向射线来向
    hit.normal = dot(n, r.direction) > 0.0f ? -n : n;
    hit.materialIndex = triangleMaterials[primitive];

    if (uvs != nullptr && sliceOfVertex != nullptr) {
        // 接缝三角形（球/环面 u 从 0.99 跳到 0.01）插值后会跑出 0...1，
        // clamp 一下，至少不会采到图集外面那一圈边缘像素
        hit.uv = clamp(w0 * uvs[i0] + w1 * uvs[i1] + w2 * uvs[i2], 0.0f, 1.0f);
        // slice 是逐顶点的常量，取 i0 就够（同一次 append 的整段顶点共用一个值）
        hit.slice = sliceOfVertex[i0];

        // 洞判定：洞图和颜色图集共用同一套 UV 与格位约定，所以直接复用刚插值出来的 uv。
        // 0xFFFFFFFF = 这个物体一格洞都没有，一次采样都不做（绝大多数物体走这条）。
        if (holeSlotOfVertex != nullptr && holeSlotOfVertex[i0] != 0xFFFFFFFFu) {
            uint slot = holeSlotOfVertex[i0];
            if (slot < holeAtlas.get_array_size()
                && holeAtlas.sample(holeSampler, hit.uv, slot).r > 0.5f) {
                // 这里是被挖空的表面：撤销这次命中，把射线起点挪到命中点之后继续找。
                // 推的距离跟距离成比例，避免远距离上被浮点精度卡住反复命中同一个三角形。
                float 推进 = max(result.distance * 0.001f, 0.0005f);
                r.min_distance = result.distance + 推进;
                hit.valid = false;
                continue;
            }
        }
    }
    return hit;
    }
    return hit;
}

// ------------------------------------------------------------
// 灯面求交：让光源本身在相机 / 镜面反射里真的能看见
// ------------------------------------------------------------
// 灯只是 NEE 的采样代理，从来没进过加速结构 —— 相机永远打不到它，
// 于是画面里只有"凭空被照亮的模型"，看不见灯，也就没有光从灯走到模型的过程感。
// 这里给每盏灯补一个可见发光体：面光 = 朝 axis 方向的矩形薄片（尺寸与 NEE 采样同一套基向量），
// 点光/聚光 = 半径 positionRadius.w 的发光球。命中后返回它自身的辐亮度，
// 与 NEE 里的 Le 是同一份物理量，所以"看见的灯"和"照出的光"永远一致。
struct LightHit {
    bool valid;
    float distance;
    float3 normal;
    float3 emissive;
};

// ------------------------------------------------------------
// 灯 AABB 树：把「每像素每弹射线性扫全部灯」换成保守剔除的整枝跳过
// ------------------------------------------------------------
// 【开关】PT_LIGHT_BVH_ENABLED：1 = 开（默认），0 = 完全退回逐盏线性扫描。
// 剔除判据只有一条：「这一整枝的入射距离已经不可能给出更优命中」。
// 全程不引入任何近似、抖动或概率化，所以开关两版的输出必须逐位相同。
// 回滚方式：把下面的 1 改成 0，其余代码一行都不用动。
#ifndef PT_LIGHT_BVH_ENABLED
#define PT_LIGHT_BVH_ENABLED 1
#endif

// 灯数不超过这个值直接线性扫：几十盏灯时建树+遍历的开销还不如顺序扫一遍
#define PT_LIGHT_BVH_MIN_COUNT 64u
// 遍历栈深：叶容量 4 的平衡树，10000 盏也只有 ~13 层，64 足够；
// 万一真的溢出（不该发生）就整体退回线性扫描，绝不丢枝
#define PT_LIGHT_BVH_STACK 64u

// ------------------------------------------------------------
// 面光两级 CDF：排序分块，块级占比 × 块内条件概率
// ------------------------------------------------------------
// 【开关】PT_AREA_LIGHT_BLOCK_CDF_ENABLED：1 = 两级（默认），0 = 完全退回按三角形的单级全局 CDF。
// CPU 侧（PT 场景 转译.swift 构建面光两级CDF）永远把两套数据都建好、打包进同一个 buffer(11)：
//   [0, n)        旧单级全局 CDF（1e-6 相对下限版）
//   [n, n+B)      块级 CDF
//   [n+B, n+B+n)  块内局部 CDF
// 所以回滚只需要把下面的 1 改成 0，Swift 侧一行都不用动。
// 【注意】置 0 是「逐位回滚」到旧的单级按三角形 CDF：随机流、抽中的三角形都与改造前一致，不是近似等价。
// 旧路径里的 max(cdfHigh - cdfLow, 1e-9f)（见下面 #else 分支）只为回滚保险而保留 ——
// 它会把 1e-14 量级的真实格宽抬到 1e-9，两级路径绝不经过这段代码，新路径的除零保护是 PT_AREA_LIGHT_PDF_EPS。
#ifndef PT_AREA_LIGHT_BLOCK_CDF_ENABLED
#define PT_AREA_LIGHT_BLOCK_CDF_ENABLED 1
#endif

// 每块项数，必须与 Swift 侧 PT场景转译.面光每块项数(64) 一致
#define PT_AREA_LIGHT_BLOCK_SIZE 64u
// 格宽兜底：CPU 已经把两级格宽都保证到 ≥ 4 个 ulp（1.19e-7），
// 相乘后最小也有 ~1.4e-14，所以这里取 1e-18 —— 比任何"真实可达"的格宽都小好几个数量级，
// 永远不参与放缩，只用于拦住数据损坏时的除零。原来那个 1e-9 会盖住 1e-14 量级的真实格宽，
// 把暗面的 pdf 抬高上万倍 → 样本被系统性压暗，正是要消掉的失真，因此一并下调。
#define PT_AREA_LIGHT_PDF_EPS 1e-18f

// 灯 AABB 树节点，与 Swift 侧 PTLightNodeGPU 逐字节对齐（48 字节）
struct PTLightNode {
    float4 最小;    // xyz = AABB 最小角
    float4 最大;    // xyz = AABB 最大角
    uint  首项;     // 叶 = lightOrder 里的起始下标；内部节点 = 左子下标（右子 = 首项 + 1）
    uint  数量;     // 0 = 内部节点；> 0 = 叶节点里的灯数
    uint  预留0;
    uint  预留1;
};

// ---- 特效发射器（体积介质源）----
// 与 Swift 侧 PTVolumeEmitterGPU 逐字节一致（144 字节）：改字段两边一起改。
// 口径：这是"介质源头的稳态描述"，不是粒子模拟状态；粒子位置/体素 brick 归渲染器私有，
// 不进这里。介质积分（ratio tracking）接上后，密度/温度/albedo 都由这几个字段在场里现算。
struct PTVolumeEmitter {
    float4x4 world;      // 世界矩阵（局部 +Y = 喷射轴）
    float4   posSize;    // xyz = 世界位置, w = 出生尺寸(米)
    float4   axisCone;   // xyz = 喷射轴(单位向量), w = 扩散锥半角余弦
    float4   emit;       // x = 每秒发射数, y = 寿命(秒), z = 初速(米/秒), w = 种类码(0/1/2/3)
    float4   birth;      // xyz = 出生颜色(线性), w = 不透明度
    float4   death;      // xyz = 死亡颜色(线性), w = 受全局重力比例
    float4   sim;        // x = 域盒半宽(米), y = 域盒高(米), z = 纹理槽+1（0 = 无模拟）, w 保留
    float4   simTint;    // x = 消光系数, y = 发光强度（与视口 配色 同源）
    float4   fire;       // x 芯色温K, y 尾色温K, z 内部结构 0…1, w 亮度倍率（与视口 bounds 同源）
};

/// 单场景发射器上限：必须与 Swift 侧 PTVolumeEmitterGPU.上限 同值（缓冲按它分配）
constant uint PT_VOLUME_EMITTER_LIMIT = 64;

/// 模拟纹理槽数：必须与视口 `VOL_MERGE_MAX` 同值（两边共用同一批 3D 纹理）
#define PT_SIM_SLOTS 8

// ------------------------------------------------------------
// 模拟场直采：视口跑的是 GPU 欧拉网格，出图吃的是同一批体素
// ------------------------------------------------------------
// 【为什么不再用解析场】解析羽流是"从点喷出的锥"，物理上做不出涡、卷、撕裂，
// 再怎么调参都只能得到一团光滑的球/锥。视口已经换成 64³ 欧拉网格 + 浮力涡量，
// 出图若继续走解析场，就会出现"视口里是火、渲染出来是灯泡"的两套东西。
//
// 【做法】视口每帧把本帧在跑的场登记到 `体积场登记`，转译时连纹理一起带进 PTScene，
// 这里按发射器顺序取槽位直接三线性采样密度/温度。坐标变换、色阶换算与视口
// `volumeFXMergedFragment` 逐项同式 —— 两边不是"像"，是同一份数据同一套公式。
//
// 【为什么是固定步长】体素本身已经是离散的（64³，体素 ≈ 2cm），再上 delta tracking
// 只是给三线性插值加一层自适应噪声。按域盒区间等距 march + 每步按 σ 累积，
// 与视口积分器口径一致，收敛干净、无层状条带（视口那套抖动这里照搬）。
#define PT_SIM_STEPS 80

constexpr sampler ptSimSampler(mag_filter::linear, min_filter::linear, address::clamp_to_edge);

/// 世界点 → 模拟场归一化 UV；点不在域盒内返回 false（域盒 = 局部 [-半宽,半宽]×[0,高]×[-半宽,半宽]）
static inline bool ptSimUV(device const PTVolumeEmitter &em, float3 p, thread float3 &uv)
{
    float3 d = p - em.world.columns[3].xyz;
    float3 c0 = em.world.columns[0].xyz;
    float3 c1 = em.world.columns[1].xyz;
    float3 c2 = em.world.columns[2].xyz;
    float3 lp = float3(dot(d, c0) / max(dot(c0, c0), 1e-9f),
                       dot(d, c1) / max(dot(c1, c1), 1e-9f),
                       dot(d, c2) / max(dot(c2, c2), 1e-9f));
    float 半宽 = max(em.sim.x, 1e-4f);
    float 高 = max(em.sim.y, 1e-4f);
    if (lp.y < 0.0f || lp.y > 高) return false;
    if (abs(lp.x) > 半宽 || abs(lp.z) > 半宽) return false;
    uv = float3((lp.x + 半宽) / (2.0f * 半宽), lp.y / 高, (lp.z + 半宽) / (2.0f * 半宽));
    return true;
}

/// 射线 × 域盒（世界空间 slab，与视口 volRayBox 同一判别）
static inline bool ptSimRayBox(device const PTVolumeEmitter &em, float3 ro, float3 rd,
                               thread float &t0, thread float &t1)
{
    float3 c0 = em.world.columns[0].xyz;
    float3 c1 = em.world.columns[1].xyz;
    float3 c2 = em.world.columns[2].xyz;
    float3 o = ro - em.world.columns[3].xyz;
    float3 lo = float3(dot(o, c0) / max(dot(c0, c0), 1e-9f),
                       dot(o, c1) / max(dot(c1, c1), 1e-9f),
                       dot(o, c2) / max(dot(c2, c2), 1e-9f));
    float3 d = float3(dot(rd, c0) / max(dot(c0, c0), 1e-9f),
                      dot(rd, c1) / max(dot(c1, c1), 1e-9f),
                      dot(rd, c2) / max(dot(c2, c2), 1e-9f));
    float 半宽 = max(em.sim.x, 0.02f);
    float 高 = max(em.sim.y, 0.02f);
    float3 下界 = float3(-半宽, 0.0f, -半宽);
    float3 上界 = float3(半宽, 高, 半宽);
    float 进入 = -1e30f;
    float 离开 = 1e30f;
    for (int i = 0; i < 3; ++i) {
        if (abs(d[i]) < 1e-8f) {
            if (lo[i] < 下界[i] || lo[i] > 上界[i]) return false;
            continue;
        }
        float ta = (下界[i] - lo[i]) / d[i];
        float tb = (上界[i] - lo[i]) / d[i];
        if (ta > tb) { float 换 = ta; ta = tb; tb = 换; }
        进入 = max(进入, ta);
        离开 = min(离开, tb);
    }
    if (离开 <= max(进入, 0.0f)) return false;
    t0 = max(进入, 0.0f);
    t1 = 离开;
    return true;
}



// ------------------------------------------------------------
// 体积介质：解析羽流场 + delta tracking（比例追踪）
// ------------------------------------------------------------
// 【为什么不用体素 brick】发射器本来就是一个"从点往轴上喷、沿轴衰减"的解析体，
// 把它离散成 VDB 再采样，等于先花显存把解析函数抄一遍、再引入三线性插值误差。
// 这里直接在场里求：密度 / 颜色 / 温度都是 (发射器参数, 世界点) 的闭式函数，
// 内存开销恒为 0，分辨率上限只由积分步长决定，且**改了参数立刻生效**、不用重建 brick。
//
// 【为什么是 delta tracking 而不是固定步长 ray marching】
// ray marching 的步长一旦固定，就会出现「火边缘一刀切」的层状条带，且要打补丁做抖动；
// delta tracking 按 σt 自适应跳步：空处大步走、密处小步走，天然对稀疏羽流友好，
// 且透射率是**无偏**（不是步长近似），累积几百 spp 就能收敛到干净结果。
//
// 【开关】PT_VOLUME_ENABLED：1 = 开，0 = 逐位回到接入前（画面与没有介质时逐像素相同）。
// 无发射器时本段不消耗任何随机数、不改任何寄存器，所以「场景里没加特效」的画面
// 与接入前逐像素一致 —— 这是本次接线的硬验收口径。
#ifndef PT_VOLUME_ENABLED
#define PT_VOLUME_ENABLED 1
#endif

// 光学厚度标尺：不透明度 1.0、轴心、源头处的消光系数 = 这个值（单位 1/米）。
// 它只决定"烟有多浓"的绝对尺度，不参与任何分布的归一化。
#define PT_VOLUME_DENSITY 1.35f
// 火焰自发辐射强度（线性 HDR，与灯的辐射同一量纲）
#define PT_VOLUME_FIRE_EMISSION 7.0f
// 湍流扩张：羽流半径随轴向距离额外张开，让烟柱越往上越蓬松（0 = 纯锥形）
#define PT_VOLUME_TURBULENCE 0.32f
// 单段介质最多追踪步数：delta tracking 的名义步数由 σ 决定，这个上限只拦数据损坏
#define PT_VOLUME_MAX_STEPS 96u
// 单条路径最多能在介质里散射几次。
// 【为什么和 maxBounces 分开】浓烟里一次散射接着一次散射，如果介质事件也计入几何弹射额度，
// 填 8 的用户会在烟里走两步就"没弹射了"，烟看着发黑 —— 而这不是物理，是预算被抢了。
// 所以介质事件单独记账、并把几何额度抵消掉，上限放在这里。
#define PT_VOLUME_MAX_SCATTER 48u
// 介质处的直接光采样（点光 / 聚光 / 区域光 / 平行光 / 自发光三角面）总开关。
// 关掉就只剩「环境太阳 + 自发辐射 + 遮挡」这条老路 —— 面光/点光下烟会是一团不受光的灰。
#define PT_VOLUME_NEE_LIGHTS_ENABLED 1
// ---- 湍流与时间演化 ----
// 噪声空间尺度：每多少米一格（越小越碎）。1.6 = 0.6m 一格，
// 刚好比一般羽流直径小一档，能看出"翻卷"而不是像撒了沙子。
#define PT_VOLUME_TURBULENCE_SCALE 1.6f
// 流动速度（米/秒）：噪声沿轴向以这个速度往上滑，时间来自 camera.volume.x。
// 只在「时间固定」的语境（烘焙/出图/调好的视口）里有意义 —— PT 是累积渲染器，
// 墙钟驱动的湍流会让每一帧都变成新画面，永远收敛不了。
#define PT_VOLUME_TURBULENCE_FLOW 0.9f

/// 廉价 3D 值噪声：哈希 + 三线性插值，不查表。
/// 【为什么不用纹理】介质场是在 delta tracking 的每一步里求值的，一条浓烟路径能问到几十次，
/// 而 3D 纹理采样的代价在这个位置是纯亏 —— 哈希法只吃 ALU，实测更便宜。
static inline float ptHash13(float3 p)
{
    p = fract(p * 0.1031f);
    p += dot(p, p.yzx + 33.33f);
    return fract((p.x + p.y) * p.z);
}

static inline float ptValueNoise(float3 p)
{
    float3 i = floor(p);
    float3 f = fract(p);
    f = f * f * (3.0f - 2.0f * f);   // smoothstep 插值，避免格子边界出现方向性棱线
    float n000 = ptHash13(i + float3(0.0f, 0.0f, 0.0f));
    float n100 = ptHash13(i + float3(1.0f, 0.0f, 0.0f));
    float n010 = ptHash13(i + float3(0.0f, 1.0f, 0.0f));
    float n110 = ptHash13(i + float3(1.0f, 1.0f, 0.0f));
    float n001 = ptHash13(i + float3(0.0f, 0.0f, 1.0f));
    float n101 = ptHash13(i + float3(1.0f, 0.0f, 1.0f));
    float n011 = ptHash13(i + float3(0.0f, 1.0f, 1.0f));
    float n111 = ptHash13(i + float3(1.0f, 1.0f, 1.0f));
    float nxy0 = mix(mix(n000, n100, f.x), mix(n010, n110, f.x), f.y);
    float nxy1 = mix(mix(n001, n101, f.x), mix(n011, n111, f.x), f.y);
    return mix(nxy0, nxy1, f.z);
}

/// 两层：一层大尺度翻滚（决定烟柱怎么翻），一层细碎毛边（压掉"塑料感"的平滑高斯）
static inline float ptFbm2(float3 p)
{
    return ptValueNoise(p) * 0.65f
         + ptValueNoise(p * 2.7f + float3(11.3f, 5.1f, 7.7f)) * 0.35f;
}

/// 世界点处的介质场（多个发射器已经求和/加权平均完毕）
struct PTVolumeField {
    float  sigmaT;    // 消光系数（1/米），= 0 表示这里没有介质
    float3 emissive;  // 单位长度的自发辐射（已按密度加权平均）
    float3 albedo;    // 单次散射反照率（按密度加权平均）
    float  各向异性;  // HG 相函数的 g（按密度加权平均）
};

/// 正交基：给相函数采样用
static inline void hgBasis(float3 n, thread float3 &t, thread float3 &b)
{
    float3 辅助 = fabs(n.y) < 0.999f ? float3(0.0f, 1.0f, 0.0f) : float3(1.0f, 0.0f, 0.0f);
    t = normalize(cross(辅助, n));
    b = cross(n, t);
}

/// Henyey-Greenstein 相函数采样：g>0 前向散射（烟、雾），g=0 各向同性。
/// 只做方向采样、不需要 pdf —— 介质事件之后走的是"散射继续"，pdf 已在方向采样里抵掉。
static inline float3 hgSample(float3 d, float g, thread RNG &rng)
{
    float u1 = rng.uniform();
    float u2 = rng.uniform();
    float gg = clamp(g, -0.95f, 0.95f);
    float cosTheta;
    if (fabs(gg) < 1e-3f) {
        cosTheta = 1.0f - 2.0f * u1;
    } else {
        float s = (1.0f - gg * gg) / (1.0f - gg + 2.0f * gg * u1);
        cosTheta = clamp((1.0f + gg * gg - s * s) / (2.0f * gg), -1.0f, 1.0f);
    }
    float sinTheta = sqrt(max(0.0f, 1.0f - cosTheta * cosTheta));
    float phi = 2.0f * M_PI_F * u2;
    float3 t, b;
    hgBasis(d, t, b);
    return normalize(t * (sinTheta * cos(phi)) + b * (sinTheta * sin(phi)) + d * cosTheta);
}

/// 求某个世界点的介质场。
/// 【口径】发射器描述的是"稳态羽流"：局部 +Y 是喷射轴，密度沿轴指数衰减、
/// 垂直轴按高斯剖面，中心线受重力下垂（death.w = 受全局重力比例）。
/// 采样量：σt 直接按密度求和；发光/反照率/各向异性按密度加权 —— 密度接近 0 的
/// 发射器不许把平均值往自己那边拉（否则远处的火会把近处烟的散射反照率带偏）。
/// 黑体色温 → 线性 RGB（Kelvin/100 经验曲线）。
/// 【必须和视口 vfx /粒子 着色器.metal 的 volBlackbody 逐项同式】
/// 两条管线同源，否则同一团火在视口和出图里会是两个颜色。
static inline float3 ptBlackbody(float 开尔文)
{
    float t = clamp(开尔文, 500.0f, 12000.0f) / 100.0f;
    float 红, 绿, 蓝;
    if (t <= 66.0f) 红 = 1.0f;
    else            红 = saturate(1.2929362f * pow(max(t - 60.0f, 1e-3f), -0.1332048f));
    if (t <= 66.0f) 绿 = saturate(0.39008157f * log(t) - 0.63184144f);
    else            绿 = saturate(1.1298909f * pow(max(t - 60.0f, 1e-3f), -0.0755148f));
    if (t >= 66.0f)      蓝 = 1.0f;
    else if (t <= 19.0f) 蓝 = 0.0f;
    else                 蓝 = saturate(0.5432068f * log(max(t - 10.0f, 1e-3f)) - 1.1962541f);
    return float3(红, 绿, 蓝);
}

/// 密度外观映射：与视口 volDensityLook **逐项同式**（幂次 1.35 + 增益 2.2）。
/// 视口与出图要对得上，这条映射就必须只有一种写法；任何一侧单独调参都会立刻分家。
static inline float ptSimDensityLook(float 原始, float 死区) {
    float 存活 = saturate((max(原始, 0.0f) - 死区) / max(1.0f - 死区, 1e-3f));
    return pow(存活, 1.35f) * 2.2f;
}

/// 模拟介质积分：一次固定步长 march 覆盖所有**模拟类**发射器（域盒并集），
/// 逐点按视口同一套色阶累加辐射/透射。返回 float4(辐射 rgb, 透射)。
/// 没有模拟类发射器时立刻返回 (0,0,0,1) —— 一个纹理都不采，逐像素与接入前一致。
static inline float4 ptSimIntegrate(device const PTVolumeEmitter *emitters,
                                    uint count,
                                    array<texture3d<float, access::sample>, PT_SIM_SLOTS> &密表,
                                    array<texture3d<float, access::sample>, PT_SIM_SLOTS> &温表,
                                    float3 ro, float3 rd, float tLimit, float 抖动)
{
    float t入 = 1e30f;
    float t出 = -1e30f;
    for (uint i = 0u; i < count; ++i) {
        device const PTVolumeEmitter &em = emitters[i];
        if (em.sim.z <= 0.0f) continue;
        float a = 0.0f;
        float b = 0.0f;
        if (!ptSimRayBox(em, ro, rd, a, b)) continue;
        a = max(a, 0.0f);
        b = min(b, tLimit);
        if (b <= a) continue;
        t入 = min(t入, a);
        t出 = max(t出, b);
    }
    if (t出 <= t入) return float4(0.0f, 0.0f, 0.0f, 1.0f);

    float dt = (t出 - t入) / float(PT_SIM_STEPS);
    float t = t入 + dt * 抖动;
    float3 辐射 = float3(0.0f);
    float 透射 = 1.0f;

    for (uint s = 0u; s < PT_SIM_STEPS && t < t出; ++s, t += dt) {
        if (透射 < 0.004f) break;
        float3 p = ro + rd * t;
        float σ = 0.0f;
        float3 自发光 = float3(0.0f);
        float3 反照 = float3(0.0f);
        for (uint i = 0u; i < count; ++i) {
            device const PTVolumeEmitter &em = emitters[i];
            if (em.sim.z <= 0.0f) continue;
            uint 槽 = uint(max(em.sim.z - 1.0f, 0.0f));
            if (槽 >= PT_SIM_SLOTS) continue;
            float3 uv;
            if (!ptSimUV(em, p, uv)) continue;
            float 原始密 = 密表[槽].sample(ptSimSampler, uv).x;
            float 密度 = ptSimDensityLook(原始密, em.simTint.z);
            if (密度 <= 1e-5f) continue;
            float 温度 = 温表[槽].sample(ptSimSampler, uv).w;

            float 消光 = max(em.simTint.x, 0.0f);
            float 发光强度 = max(em.simTint.y, 0.05f);
            float 热 = saturate(温度 / 2.0f);
            float3 发光;
            float3 反;
            // 内部结构：与视口 volFireStructure 同式（出图没有时间轴，取静态分布即可，
            // 静帧的薄厚位置和视口同一帧的噪声场同一套参数，不会出现"渲染出来是一整块"）
            float 结构倍率 = 1.0f;
            if (em.emit.w < 1.5f) {
                float 结构 = saturate(em.fire.z);
                if (结构 > 0.001f) {
                    float3 q = p * 7.0f;
                    float a = ptValueNoise(q);
                    float b = ptValueNoise(q * 2.3f + float3(11.0f, 3.0f, 7.0f));
                    float n = saturate(a * 0.65f + b * 0.35f);
                    结构倍率 = mix(1.0f, 0.35f + 1.3f * n, 结构);
                }
            }
            if (em.emit.w < 1.5f) {
                // 火：黑体色阶（与视口 volBlackbody 同式）+ 用户配色，色温与亮度走发射器参数
                float3 黑体 = ptBlackbody(mix(max(em.fire.y, 400.0f), max(em.fire.x, 600.0f), 热 * 热));
                float3 用户色 = mix(em.death.xyz, em.birth.xyz, 热);
                发光 = mix(黑体, 黑体 * 用户色 * 1.9f, 0.35f)
                     * (发光强度 * max(em.fire.w, 0.02f) * 结构倍率 * (0.12f + 1.35f * 热 * 热));
                反 = float3(0.55f, 0.16f, 0.05f);
            } else {
                // 烟：极弱自发光 + 天光近似反照（视口同一口径）
                float 环境 = 0.22f + 0.78f * saturate(rd.y * 0.5f + 0.5f);
                发光 = em.death.xyz * (0.04f * 温度);
                反 = mix(em.birth.xyz, em.death.xyz, 0.5f) * 0.75f * 环境;
            }
            float sg = 密度 * 消光 * 结构倍率;
            σ += sg;
            自发光 += 发光 * sg;
            反照 += 反 * sg;
        }
        if (σ > 1e-5f) {
            辐射 += 透射 * (自发光 + 反照 * 0.55f) * dt;
            透射 *= exp(-σ * dt);
        }
    }
    return float4(辐射, 透射);
}


static inline PTVolumeField ptVolumeFieldAt(device const PTVolumeEmitter *emitters,
                                            uint count,
                                            float3 p,
                                            float 时间,
                                            float 湍流倍率)
{
    PTVolumeField f;
    f.sigmaT = 0.0f;
    f.emissive = float3(0.0f);
    f.albedo = float3(0.0f);
    f.各向异性 = 0.0f;
    float 权重和 = 0.0f;

    for (uint i = 0; i < count; ++i) {
        device const PTVolumeEmitter &em = emitters[i];
        // [解析球已停用] 这一支就是旧版假效果：轴向衰减 x 径向高斯，跟方向无关，侧看永远是球。
        // 现在体积火/烟只认模拟纹理：没接到模拟场的发射器宁可不画，也不退回解析球，
        // 否则「没接上」会被一个球伪装成「接上了」。
        continue;

        float 寿命 = max(em.emit.y, 0.02f);
        float 初速 = max(em.emit.z, 0.02f);
        float 羽流长 = max(初速 * 寿命, 0.02f);
        float 不透明度 = clamp(em.birth.w, 0.0f, 1.0f);
        if (不透明度 <= 1e-5f) continue;

        // ---- 世界 → 发射器局部空间 ----
        float3 d = p - em.world.columns[3].xyz;
        float3 lp = float3(dot(em.world.columns[0].xyz, d),
                           dot(em.world.columns[1].xyz, d),
                           dot(em.world.columns[2].xyz, d));

        float s = lp.y;                                  // 沿轴距离（局部 +Y = 喷射轴）
        float 起始半径 = max(em.posSize.w, 0.0005f);
        // 羽流末端之外密度必为 0（半径随 u 收尖），早退省掉绝大多数空采样
        if (s > 羽流长 * 1.30f || s < -起始半径 * 4.0f) continue;
        float 轴向 = max(s, 0.0f);

        // ---- 中心线下垂：世界重力 (0,-1,0) 投到局部系，按 death.w 缩放 ----
        float 重力倍率 = clamp(em.death.w, 0.0f, 4.0f);
        float3 世界重力局部 = -float3(em.world.columns[0].y, em.world.columns[1].y, em.world.columns[2].y);
        float 时间因子 = 轴向 / max(初速, 1e-3f);
        float3 下垂 = 世界重力局部 * (0.5f * 重力倍率 * 时间因子 * 时间因子);
        float2 横向 = lp.xz - 下垂.xz;

        float cosCone = clamp(em.axisCone.w, 0.0f, 1.0f);
        float tanCone = sqrt(max(1.0f - cosCone * cosCone, 0.0f)) / max(cosCone, 0.05f);

        int 种类 = int(em.emit.w + 0.5f);
        float u = saturate(轴向 / 羽流长);           // 0 = 喷口，1 = 羽流末端

        // ---- 火舌轮廓：根部细、中段鼓、顶端收尖（与视口 vfx 同一份式子）----
        // 注意：湍流是「扰动」，不参与半径膨胀 —— 早期版本把 PT_VOLUME_TURBULENCE 直接
        // 加进半径，等于让羽流中段半径 ≈ 0.32×羽流长，整团就成了球。这里只用锥角定半径。
        float 轮廓 = saturate(pow(max(u, 1e-4f), 0.52f) * (1.0f - pow(u, 2.0f)));
        float 瘦身 = 1.0f;
        if (种类 == 1) {
            轮廓 = max(轮廓, 0.16f);
            瘦身 = 0.85f;                       // 火：再收一点，保证是火舌不是橄榄
        } else {
            轮廓 = mix(1.0f, 轮廓, 0.35f);
        }
        float 半径 = max(起始半径 + 羽流长 * tanCone * 轮廓 * 瘦身, 起始半径 * 0.30f);
        float 安全半径 = max(半径, 1e-5f);

        // ---- 湍流：域扭曲 + 根部稳定 / 上部撕碎 ----
        float2 摆动 = float2(0.0f);
        float 湍流系数 = 1.0f;
        if (湍流倍率 > 1e-4f) {
            float 拉伸 = max(羽流长, 0.05f);
            float3 噪声坐标 = float3(lp.x, 轴向, lp.z) * (PT_VOLUME_TURBULENCE_SCALE / 拉伸)
                            - float3(0.0f, 时间 * PT_VOLUME_TURBULENCE_FLOW, 0.0f);
            float 低频 = ptValueNoise(噪声坐标);
            float 高频 = ptValueNoise(噪声坐标 * 2.35f + float3(13.1f, 7.7f, 3.3f));
            float n = 低频 * 0.66f + 高频 * 0.34f;

            // 域扭曲：把噪声采样位置整体推歪，得到翻卷的舌状结构
            float2 摆幅 = float2(ptValueNoise(噪声坐标 * 1.7f + float3(3.7f, 0.0f, 8.1f)),
                                 ptValueNoise(噪声坐标 * 1.7f + float3(9.3f, 5.5f, 1.2f))) - 0.5f;
            摆动 = 摆幅 * (羽流长 * 0.24f * 湍流倍率) * (0.25f + 1.75f * u);

            float 剥离 = smoothstep(0.0f, 起始半径 * 3.0f + 0.03f, 轴向);
            float 幅度 = clamp(0.9f * 湍流倍率, 0.0f, 1.0f);
            湍流系数 = mix(1.0f, saturate(0.28f + 1.15f * n), 幅度 * 剥离);
        }

        float 径向距离 = length(横向 + 摆动);
        float 径向项 = exp(-2.4f * (径向距离 * 径向距离) / (安全半径 * 安全半径));
        float 轴向项 = exp(-轴向 / 羽流长);
        if (s < 0.0f) 轴向项 *= exp(s / max(起始半径 * 1.5f, 1e-3f));

        float 密度 = PT_VOLUME_DENSITY * 不透明度 * 轴向项 * 径向项 * 湍流系数;

        // 火：上方再沿角向咬一轮齿，破掉"光滑回转体"的塑料感
        if (种类 == 1 && 轴向 > 起始半径 * 0.5f) {
            float 角 = atan2(横向.y, 横向.x);
            float 齿 = ptValueNoise(float3(角 * 1.7f, u * 4.5f - 时间 * 1.6f, 0.5f));
            float 权重 = saturate((u - 0.18f) * 1.8f);
            密度 *= mix(1.0f, 0.10f + 1.55f * 齿 * 齿, 权重);
        }
        if (!(密度 > 1e-5f)) continue;

        float 峰值 = PT_VOLUME_DENSITY * 不透明度;
        float 相对密度 = saturate(密度 / max(峰值, 1e-6f));
        float3 用户色 = mix(em.birth.rgb, em.death.rgb, smoothstep(0.0f, 1.0f, u));

        // ---- 按种类码分派材质（0 粒子 / 1 火 / 2 烟 / 3 水）----
        float3 发光 = float3(0.0f);
        float3 反照率 = float3(0.9f);
        float g = 0.25f;
        if (种类 == 1) {
            // 火：黑体色阶 + 内芯更热（取代两色线性插值，避免整团糊成死黄）
            float 轴向热 = pow(1.0f - u, 0.9f);
            float 热 = saturate(0.60f * 轴向热 + 0.62f * 相对密度 * 相对密度);
            热 = pow(热, 1.45f);
            float3 黑体 = ptBlackbody(mix(900.0f, 3200.0f, 热));
            黑体 = mix(黑体, float3(1.0f), saturate((热 - 0.72f) * 2.6f) * 0.45f);
            float3 色 = mix(黑体, 黑体 * 用户色 * 2.2f, 0.30f);
            float 内芯 = exp(-1.6f * (径向距离 * 径向距离) / (安全半径 * 安全半径));
            float 亮度 = PT_VOLUME_FIRE_EMISSION * (0.03f + 1.05f * 热 * 热) * (0.35f + 0.65f * 内芯);
            发光 = 色 * (亮度 * 相对密度);
            反照率 = float3(0.70f, 0.30f, 0.09f);
            g = 0.35f;
        } else if (种类 == 2) {
            // 烟：几乎不发光，灰体散射，强前向
            发光 = 用户色 * (0.06f * 相对密度);
            反照率 = float3(0.86f);
            g = 0.42f;
        } else if (种类 == 3) {
            // 水雾：几乎全散射，无自发光
            发光 = float3(0.0f);
            反照率 = float3(0.98f);
            g = 0.6f;
        } else {
            // 粒子：轻微自发光、中性灰
            发光 = 用户色 * (0.08f * 相对密度);
            反照率 = float3(0.88f);
            g = 0.3f;
        }

        f.sigmaT += 密度;
        f.emissive += 发光 * 密度;
        f.albedo += 反照率 * 密度;
        f.各向异性 += g * 密度;
        权重和 += 密度;
    }

    if (权重和 > 1e-9f) {
        float 倒数 = 1.0f / 权重和;
        f.emissive *= 倒数;
        f.albedo *= 倒数;
        f.各向异性 *= 倒数;
    }
    return f;
}

/// 全局 majorant（消光系数上界）：每发射器的密度峰值都出现在「轴心 + 喷口」，值为
/// PT_VOLUME_DENSITY × 不透明度。求和即为整场的保守上界（剖面函数恒 ≤ 1）。
/// 乘 1.02 只是吃掉浮点误差，不做任何拟合。
static inline float ptVolumeMajorant(device const PTVolumeEmitter *emitters, uint count)
{
    float 和 = 0.0f;
    for (uint i = 0; i < count; ++i) {
        和 += PT_VOLUME_DENSITY * clamp(emitters[i].birth.w, 0.0f, 1.0f);
    }
    return 和 * 1.02f;
}

/// 有效发射器数量：缓冲里有效项连续排在前面、其余全零（CPU 每帧 memset 清尾巴）。
/// 判据用「寿命 > 0」：转译侧保证有效项寿命 ≥ 0.02 秒，全零槽是 0。
/// 不用世界矩阵的 m33 判定 —— 变换域若给出带缩放的矩阵，w 分量未必是 1，
/// 那种情况下 m33 判据会让介质整体静默消失，属于最难查的一类失效。
static inline uint ptVolumeEmitterCount(device const PTVolumeEmitter *emitters)
{
    uint n = 0u;
    for (uint i = 0; i < PT_VOLUME_EMITTER_LIMIT; ++i) {
        if (emitters[i].emit.y <= 0.001f) break;
        n += 1u;
    }
    return n;
}

/// 单个发射器的等效包围球（中心 + 半径）。
/// 【必须和 ptVolumeFieldAt 的几何逐项同式】这个球有双重身份：
/// ① ptVolumeSegmentHitAny 的剔除判据 ② 分段 majorant 的区间切分依据。
/// 只要它比真实羽流"只大不小"，两处都只会偏保守（多算/多查），绝不会漏算介质。
static inline void ptVolumeEmitterBounds(device const PTVolumeEmitter &em,
                                         thread float3 &中心,
                                         thread float &半径)
{
    float 寿命 = max(em.emit.y, 0.02f);
    float 初速 = max(em.emit.z, 0.02f);
    float 羽流长 = max(初速 * 寿命, 0.02f);
    float 起始半径 = max(em.posSize.w, 0.0005f);
    float cosCone = clamp(em.axisCone.w, 0.0f, 1.0f);
    float tanCone = sqrt(max(1.0f - cosCone * cosCone, 0.0f)) / max(cosCone, 0.05f);
    // 与 ptVolumeFieldAt 同式：半径最大处 = 锥角张开量 × 轮廓峰值(≈0.5) × 瘦身，
    // 再补 0.12×羽流长 吃掉域扭曲摆幅，保证包围球只大不小。
    float 末端半径 = 起始半径 + 羽流长 * (tanCone * 0.55f + 0.12f);
    // 下垂量与场求值里同式：0.5·g·倍率·(s/v0)²，在 s = 羽流长 处最大
    float 倍率 = clamp(em.death.w, 0.0f, 4.0f);
    float 下垂 = 0.5f * 倍率 * 羽流长 * 羽流长 / max(初速 * 初速, 1e-6f);
    float3 轴 = normalize(em.world.columns[1].xyz);
    中心 = em.world.columns[3].xyz + 轴 * (羽流长 * 0.5f)
         - float3(0.0f, 1.0f, 0.0f) * (下垂 * 0.5f);
    半径 = max(羽流长 * 0.5f, 末端半径) + 下垂;
}

/// 点所在的局部 majorant：只有"包围球盖住这个点"的发射器才算进来。
/// 这是分段 majorant 的地基 —— 全局上界把整场所有羽流的峰值加在一起，
/// 一条从地面射向太阳的阴影射线在完全无烟的高空也按浓烟的 σ̄ 抽步长，
/// 白跑几百个空步；按点取上界后，空区直接是 0，一步都不用抽。
static inline float ptVolumeMajorantAt(device const PTVolumeEmitter *emitters,
                                       uint count,
                                       float3 p)
{
    float 和 = 0.0f;
    for (uint i = 0; i < count; ++i) {
        device const PTVolumeEmitter &em = emitters[i];
        // [解析球已停用] 这一支就是旧版假效果：轴向衰减 x 径向高斯，跟方向无关，侧看永远是球。
        // 现在体积火/烟只认模拟纹理：没接到模拟场的发射器宁可不画，也不退回解析球，
        // 否则「没接上」会被一个球伪装成「接上了」。
        continue;
        float 不透明度 = clamp(em.birth.w, 0.0f, 1.0f);
        if (不透明度 <= 1e-5f) continue;
        float3 中心;
        float 半径;
        ptVolumeEmitterBounds(em, 中心, 半径);
        // 【为什么把球放大 1.6 倍再判】场函数是解析高斯，没有硬边界 —— 包围球外那一圈
        // 还有尾巴上的非零密度。上界必须"只大不小"：漏算一片尾巴，ratio tracking 里就会
        // 出现 σt > σ̄，T 被 clamp 到 0，整束烟提前变黑。放大球只让上界多算一点
        //（= 多走几个空步），但绝不会漏；画质与无偏性都不受影响。
        float 判定半径 = 半径 * 1.6f;
        if (distance_squared(p, 中心) <= 判定半径 * 判定半径) {
            和 += PT_VOLUME_DENSITY * 不透明度;
        }
    }
    return 和 * 1.02f;
}

/// 从参数 t 往后，"局部上界保持不变"的区段末端距离。
/// 上界只在射线跨过某个包围球球面时才会变，所以取所有球面交点中「大于 t 的最近一个」。
/// 返回值 == tMax 表示后面再没有球面，上界一直到射线尽头都不变。
/// 【为什么必须切段】指数分布抽出的步长只对"当前 σ̄ 覆盖的那一段"成立；
/// 直接跨过球面就会用 A 团烟的上界去采样 B 团烟所在的空区，保守性就破了（会漏算吸收）。
static inline float ptVolumeIntervalEnd(device const PTVolumeEmitter *emitters,
                                        uint count,
                                        float3 起点,
                                        float3 方向,
                                        float t,
                                        float tMax)
{
    float 末 = tMax;
    for (uint i = 0; i < count; ++i) {
        device const PTVolumeEmitter &em = emitters[i];
        // [解析球已停用] 这一支就是旧版假效果：轴向衰减 x 径向高斯，跟方向无关，侧看永远是球。
        // 现在体积火/烟只认模拟纹理：没接到模拟场的发射器宁可不画，也不退回解析球，
        // 否则「没接上」会被一个球伪装成「接上了」。
        continue;
        if (clamp(em.birth.w, 0.0f, 1.0f) <= 1e-5f) continue;
        float3 中心;
        float 半径;
        ptVolumeEmitterBounds(em, 中心, 半径);
        // 与 ptVolumeMajorantAt 用同一个放大半径：切分点必须正好落在
        // "上界发生变化"的那些球面上，否则一个区间内上界会偷偷变值，保守性就破了。
        半径 *= 1.6f;

        float3 oc = 起点 - 中心;
        float b = dot(oc, 方向);              // 方向已归一化，二次项系数为 1
        float c = dot(oc, oc) - 半径 * 半径;
        float disc = b * b - c;
        if (disc <= 0.0f) continue;
        float sq = sqrt(disc);
        float t0 = -b - sq;
        float t1 = -b + sq;
        if (t1 <= t) continue;                // 整个球都在身后
        if (t0 > t + 1e-5f) {
            末 = min(末, t0);                 // 在球外：等到达入射点才换上界
        } else {
            末 = min(末, t1);                 // 在球内：到达出射点才换上界
        }
    }
    return 末;
}

/// 射线段是否可能穿过任何一团介质（包围球粗判，不抽随机数）。
/// 【为什么需要】加了体积阴影之后，每条阴影射线都要跑一遍 ratio tracking，
/// 而每步 ratio tracking 又要遍历所有发射器求场 —— 场景里没烟的地方（99% 的像素、
/// 99% 的阴影射线）会被白白收一笔"存在体积"的税。这里先用宽包围球把绝大多数射线
/// 挡回去：判错方向只会多算，绝不会漏算介质，所以包围球取得比真实羽流明显宽松。
static inline bool ptVolumeSegmentHitAny(device const PTVolumeEmitter *emitters,
                                         uint count,
                                         float3 起点,
                                         float3 方向,
                                         float tMax)
{
    if (count == 0u || tMax <= 0.0f) return false;

    for (uint i = 0; i < count; ++i) {
        device const PTVolumeEmitter &em = emitters[i];
        // [解析球已停用] 这一支就是旧版假效果：轴向衰减 x 径向高斯，跟方向无关，侧看永远是球。
        // 现在体积火/烟只认模拟纹理：没接到模拟场的发射器宁可不画，也不退回解析球，
        // 否则「没接上」会被一个球伪装成「接上了」。
        continue;
        if (clamp(em.birth.w, 0.0f, 1.0f) <= 1e-5f) continue;

        float3 中心;
        float 半径;
        ptVolumeEmitterBounds(em, 中心, 半径);

        // 线段到球心的最近距离 ≤ 半径 就算命中（只求一次投影，不做二次方程）
        float 投影 = dot(中心 - 起点, 方向);
        float3 最近 = 起点 + 方向 * clamp(投影, 0.0f, tMax);
        if (distance_squared(最近, 中心) <= 半径 * 半径) return true;
    }
    return false;
}

/// Henyey-Greenstein 相函数求值（NEE 用；采样侧用上面的 hgSample，两者必须同 g、同约定）
/// 约定：cosTheta = dot(入射前进方向, 出射方向)，前向散射（θ=0）最大。
static inline float hgPhase(float cosTheta, float g)
{
    float gg = clamp(g, -0.95f, 0.95f);
    float 分母 = max(1.0f + gg * gg - 2.0f * gg * cosTheta, 1e-4f);
    return (1.0f - gg * gg) / (4.0f * M_PI_F * 分母 * sqrt(分母));
}

/// 沿射线的体积透射率（阴影射线专用）。
/// 【为什么主路径不需要它】主路径用 delta tracking 前进，"一直没撞上"这个结果本身
/// 就是透射率的无偏实现（概率意义上等价于乘了 exp(-τ)）—— 再乘一次就是重复计权、画面偏黑。
/// 【为什么阴影射线必须显式算】阴影射线只做一次"有没有被几何挡住"的布尔查询，
/// 不带任何概率性衰减，所以介质吸收必须在这里用独立的 ratio tracking 补上：
/// 每次 null 碰撞把 T 乘上 (1 - σt/σ̄)，累乘期望正是 exp(-∫σt)。
static inline float ptVolumeTransmittance(device const PTVolumeEmitter *emitters,
                                          uint count,
                                          float 上界,
                                          float3 起点,
                                          float3 方向,
                                          float tMax,
                                          thread RNG &rng, float 时间, float 湍流倍率)
{
    if (count == 0u || 上界 <= 1e-5f || tMax <= 0.0f) return 1.0f;
    // 这条射线压根不经过任何一团介质：连一次随机数都不用抽
    if (!ptVolumeSegmentHitAny(emitters, count, 起点, 方向, tMax)) return 1.0f;

    float T = 1.0f;
    float t = 0.0f;
    for (uint step = 0u; step < PT_VOLUME_MAX_STEPS; ++step) {
        if (t >= tMax) break;

        // 当前区段：这段距离内"点的局部上界"不会变，可以用同一个 σ̄ 抽样
        float 区间末 = ptVolumeIntervalEnd(emitters, count, 起点, 方向, t, tMax);
        float 局部上界 = ptVolumeMajorantAt(emitters, count, 起点 + 方向 * t);

        // 空区（不在任何羽流的包围球里）：整段跳过，连一个随机数都不抽
        if (局部上界 <= 1e-6f) {
            if (区间末 >= tMax) break;
            t = 区间末 + 1e-4f;
            continue;
        }

        float u = max(1.0f - rng.uniform(), 1e-7f);
        float 步长 = -log(u) / 局部上界;
        // 抽出的步长越过了区段边界 → 这段里没有碰撞（概率意义上等价），
        // 换到下一个区段、用新的上界重新抽。注意这不消耗一次碰撞判定，无偏。
        if (t + 步长 >= 区间末) {
            t = 区间末 + 1e-4f;
            continue;
        }
        t += 步长;

        PTVolumeField f = ptVolumeFieldAt(emitters, count, 起点 + 方向 * t, 时间, 湍流倍率);
        // 上界取的是"球覆盖点"的峰值和，理论上恒 ≥ 该点 σt；
        // clamp 只为吃掉浮点误差，防止 (1 - σt/σ̄) 掉成负数把 T 变成负的。
        T *= clamp(1.0f - f.sigmaT / 局部上界, 0.0f, 1.0f);
        // 已经黑到看不出差别就收工：剩下的期望贡献 < 0.5%，但能省掉成百步场求值
        if (T < 5e-3f) return 0.0f;
    }
    return T;
}

/// delta tracking：从 当前位置 沿 当前方向 追到 tLimit，返回是否在几何之前撞上介质。
/// 命中时输出介质事件点、该点的自发辐射、反照率、相函数 g 与距离。
static inline bool ptTraceVolume(device const PTVolumeEmitter *emitters,
                                 uint count,
                                 float 上界,
                                 ray 当前,
                                 float tLimit,
                                 thread RNG &rng,
                                 thread float3 &事件点,
                                 thread float3 &自发辐射,
                                 thread float3 &反照率,
                                 thread float &各向异性,
                                 thread float &事件距离, float 时间, float 湍流倍率)
{
    if (count == 0u || 上界 <= 1e-5f) return false;
    // 包围球先挡一道：不穿介质的射线一次场求值都不做
    if (!ptVolumeSegmentHitAny(emitters, count, 当前.origin, 当前.direction, tLimit)) return false;

    float t = 0.0f;
    for (uint step = 0u; step < PT_VOLUME_MAX_STEPS; ++step) {
        // 指数分布跳步：Δ = -ln(1-ξ)/σ̄。空处一步就能跨过整段，稠密处自然变小。
        float u = max(1.0f - rng.uniform(), 1e-7f);
        t += -log(u) / 上界;
        if (t >= tLimit) return false;

        float3 p = 当前.origin + 当前.direction * t;
        PTVolumeField f = ptVolumeFieldAt(emitters, count, p, 时间, 湍流倍率);
        if (f.sigmaT <= 1e-6f) continue;

        // 真实碰撞概率 = σt(x) / σ̄ —— 这里就是「比例追踪」的判据
        if (rng.uniform() < f.sigmaT / 上界) {
            事件点 = p;
            自发辐射 = f.emissive;
            反照率 = f.albedo;
            各向异性 = f.各向异性;
            事件距离 = t;
            return true;
        }
        // 否则是 null 碰撞：什么都不发生，继续往深处走（等价于乘了一次透射率）
    }
    return false;
}

// 树头：节点数 + 建树时的灯总数。
// 灯总数与当前 lightsCount 不一致就说明树过期，必须整体退回线性扫描 ——
// 否则树里的下标会指到灯数组之外（这是唯一会读越界的地方，所以必须显式挡住）。
struct PTLightTreeHeader {
    uint 节点数;
    uint 灯数;
    uint 预留0;
    uint 预留1;
};

// 是否采纳 index 这盏灯给出的候选距离 t。
// 【逐位等价的关键】线性扫描里 `t >= best.distance` 一律跳过，也就是"并列距离时下标更小的那盏赢"。
// 这里改成对 (t, 下标) 做字典序比较：树的遍历顺序再怎么变，
// 最终选中的仍然是线性扫描会选中的同一盏灯，结果逐位一致。
static inline bool lightCandidateWins(uint index, float t, LightHit best, uint bestIndex)
{
    if (t <= 0.001f) return false;
    if (bestIndex == 0xFFFFFFFFu) return t < best.distance;
    if (t < best.distance) return true;
    return t == best.distance && index < bestIndex;
}

// 单轴 slab：把 方向≈0 的退化情形单独处理，避免 0 * inf 出 NaN。
// NaN 参与比较会让"能不能剪"悄悄翻转 —— 那是保守剔除最危险的坑。
static inline float2 lightSlabAxis(float 原点, float 方向, float 板近, float 板远)
{
    if (fabs(方向) < 1e-30f) {
        // 射线退化成一条直线：原点不在板内就永远打不到；在板内则这条轴不设限
        if (原点 < 板近 || 原点 > 板远) return float2(1.0f, -1.0f);   // 近 > 远 = 必不相交
        return float2(-3.0e38f, 3.0e38f);
    }
    float t0 = (板近 - 原点) / 方向;
    float t1 = (板远 - 原点) / 方向;
    return float2(min(t0, t1), max(t0, t1));
}

// 保守剔除：返回 true = 这一整枝都不可能出现比当前最优更好的命中，可以整枝跳过。
// 判据：盒子与射线不相交 / 整枝都在射线背后 / 入射距离已经超过当前最优距离（best 在遍历中动态收缩）。
// 余量：盒子求交在 float 下有舍入，tNear 可能比真实入射距离略大，
// 所以留 1e-5 的相对余量 —— 宁可少剪，绝不误剪（误剪会直接破坏逐位等价）。
static inline bool lightNodeCanSkip(PTLightNode node, ray r, float 最优距离)
{
    float2 x = lightSlabAxis(r.origin.x, r.direction.x, node.最小.x, node.最大.x);
    float2 y = lightSlabAxis(r.origin.y, r.direction.y, node.最小.y, node.最大.y);
    float2 z = lightSlabAxis(r.origin.z, r.direction.z, node.最小.z, node.最大.z);
    float tNear = max(x.x, max(y.x, z.x));
    float tFar = min(x.y, min(y.y, z.y));
    if (!(tNear <= tFar)) return true;          // 盒子与射线不相交
    if (tFar <= 0.001f) return true;            // 整枝都在射线背后（灯面命中要求 t > 0.001）
    float 余量 = fmax(1.0f, fabs(最优距离)) * 1e-5f;
    return tNear > 最优距离 + 余量;
}

static inline LightHit traceLightSurface(ray r,
                                         device const PTLightGPU *lights,
                                         uint count,
                                         float maxT,
                                         device const PTLightNode *nodes,
                                         device const uint *order,
                                         PTLightTreeHeader header)
{
    LightHit best;
    best.valid = false;
    best.distance = maxT;
    best.normal = float3(0.0f, 1.0f, 0.0f);
    best.emissive = float3(0.0f);
    // 当前最优那盏灯的下标：只用来做并列距离的判定，不参与任何着色计算
    uint bestIndex = 0xFFFFFFFFu;

    // 候选灯来源：灯数 > 64 且树可用就按树遍历，否则线性扫。
    // 三条树可用条件缺一不可：灯数够多、树非空、树的灯总数与当前灯总数一致（否则下标会越界）。
    bool 用树 = false;
#if PT_LIGHT_BVH_ENABLED
    用树 = (count > PT_LIGHT_BVH_MIN_COUNT) && (header.节点数 > 0u) && (header.灯数 == count);
#endif
    uint 栈[PT_LIGHT_BVH_STACK];
    uint 栈顶 = 0u;
    uint 叶起 = 0u;
    uint 叶止 = 0u;
    uint 线性游标 = 0u;
    if (用树) { 栈[栈顶++] = 0u; }

    while (true) {
        uint 灯号 = 0xFFFFFFFFu;
        while (用树) {
            if (叶起 < 叶止) { 灯号 = order[叶起]; 叶起 += 1u; break; }
            if (栈顶 == 0u) break;                       // 树走完
            uint n = 栈[--栈顶];
            PTLightNode node = nodes[n];
            if (lightNodeCanSkip(node, r, best.distance)) continue;   // 整枝跳过（保守）
            if (node.数量 == 0u) {
                // 内部节点：右子 = 左子 + 1。先压右再压左 → 左子树先访问（剪枝收敛更快；顺序不影响结果）
                if (栈顶 + 1u >= PT_LIGHT_BVH_STACK) {
                    // 栈溢出（平衡树 + 64 深，理论上不会发生）：整体退回线性扫描，绝不丢枝
                    用树 = false;
                    线性游标 = 0u;
                    best.valid = false;
                    best.distance = maxT;
                    best.normal = float3(0.0f, 1.0f, 0.0f);
                    best.emissive = float3(0.0f);
                    bestIndex = 0xFFFFFFFFu;
                    break;
                }
                栈[栈顶++] = node.首项 + 1u;
                栈[栈顶++] = node.首项;
                continue;
            }
            叶起 = node.首项;
            叶止 = node.首项 + node.数量;
        }
        if (!用树 && 灯号 == 0xFFFFFFFFu) {
            灯号 = 线性游标 < count ? 线性游标 : 0xFFFFFFFFu;
            if (灯号 != 0xFFFFFFFFu) { 线性游标 += 1u; }
        }
        if (灯号 == 0xFFFFFFFFu) break;

        uint i = 灯号;
        PTLightGPU L = lights[i];
        uint kind = uint(L.shape.z + 0.5f);
        if (kind == PT_LIGHT_SUN) continue;   // 平行光没有实体，只参与 NEE
        float3 Le = L.colorIntensity.xyz * L.colorIntensity.w;
        if (max(Le.x, max(Le.y, Le.z)) <= 0.0f) continue;
        float3 center = L.positionRadius.xyz;

        if (kind == PT_LIGHT_AREA) {
            float3 axis = normalize(L.axisCosCone.xyz);
            float denom = dot(axis, r.direction);
            if (fabs(denom) < 1e-5f) continue;
            float t = dot(center - r.origin, axis) / denom;
            if (!lightCandidateWins(i, t, best, bestIndex)) continue;
            float3 p = r.origin + r.direction * t;
            float w = max(L.shape.x, 0.01f);
            float h = max(L.shape.y, 0.01f);
            float3 upHint = fabs(axis.y) > 0.99f ? float3(1.0f, 0.0f, 0.0f) : float3(0.0f, 1.0f, 0.0f);
            float3 tx = normalize(cross(upHint, axis));
            float3 ty = cross(axis, tx);
            float3 d = p - center;
            if (fabs(dot(d, tx)) > w * 0.5f || fabs(dot(d, ty)) > h * 0.5f) continue;
            best.valid = true;
            best.distance = t;
            best.normal = denom > 0.0f ? axis : -axis;   // 两面都看得见，法线朝向观察侧
            best.emissive = Le;
            bestIndex = i;
        } else if (kind == PT_LIGHT_POINT || kind == PT_LIGHT_SPOT) {
            float radius = max(L.positionRadius.w, 0.0f);
            if (radius < 1e-3f) continue;                // 无体积的理想点光，没有可见面
            float3 oc = r.origin - center;
            float b = dot(oc, r.direction);
            float c = dot(oc, oc) - radius * radius;
            float disc = b * b - c;
            if (disc < 0.0f) continue;
            float t = -b - sqrt(disc);
            if (!lightCandidateWins(i, t, best, bestIndex)) continue;
            best.valid = true;
            best.distance = t;
            best.normal = normalize(r.origin + r.direction * t - center);
            // 球灯表面辐亮度 = 强度 / (π r²)，与 NEE 的球面采样口径一致
            best.emissive = Le / (M_PI_F * max(radius * radius, 1e-6f));
            bestIndex = i;
        }
    }
    return best;
}

// ------------------------------------------------------------
// 主追踪内核
// ------------------------------------------------------------
kernel void ptTrace(uint2 gid [[thread_position_in_grid]],
                    constant PTCameraGPU &camera [[buffer(0)]],
                    constant PTEnvironmentGPU &environment [[buffer(1)]],
                    device const float4 *positions [[buffer(2)]],
                    device const float4 *normals [[buffer(3)]],
                    device const uint *indices [[buffer(4)]],
                    device const uint *triangleMaterials [[buffer(5)]],
                    device const PTMaterialGPU *materials [[buffer(6)]],
                    instance_acceleration_structure accel [[buffer(7)]],
                    texture2d<float, access::read_write> accum [[texture(0)]],
                    texture2d<float, access::write> gNormalDepth [[texture(1)]],
                    texture2d<float, access::write> gAlbedo [[texture(2)]],
                    constant uint &sampleIndex [[buffer(8)]],
                    constant uint &maxBounces [[buffer(9)]],
                    device const uint *lightTriangles [[buffer(10)]],
                    device const float *lightCDF [[buffer(11)]],
                    constant uint &lightCount [[buffer(12)]],
                    device const float2 *uvs [[buffer(13)]],
                    device const uint *sliceOfVertex [[buffer(14)]],
                    constant uint &hasPaint [[buffer(15)]],
                    texture2d_array<float> paintAtlas [[texture(3)]],
                    device atomic_uint *hitCounter [[buffer(16)]],
                    device const uint *holeSlotOfVertex [[buffer(17)]],
                    texture2d_array<float> holeAtlas [[texture(4)]],
                    // ---- 通道图集：一张通道一张，a 存覆盖度、rgb 存通道值 ----
                    // 没落过笔的通道 CPU 会绑同一张 1x1 占位并把掩码位置 0，
                    // 这里就一次采样都不发起（采样未绑定/空纹理是未定义行为）。
                    texture2d_array<float> roughAtlas [[texture(5)]],
                    texture2d_array<float> metalAtlas [[texture(6)]],
                    texture2d_array<float> coatWeightAtlas [[texture(7)]],
                    texture2d_array<float> coatRoughAtlas [[texture(8)]],
                    texture2d_array<float> emissionAtlas [[texture(9)]],
                    texture2d_array<float> normalAtlas [[texture(10)]],
                    // 材质贴图图集：导入的基础色图，每材质一片（p3.x 指片）。
                    // 没贴图的场景绑 1x1 占位，p3.x < 0 时一次采样都不发起。
                    texture2d_array<float> matAtlas [[texture(11)]],
                    constant uint &channelMask [[buffer(18)]],
                    device const PTLightGPU *lights [[buffer(19)]],
                    constant uint &lightsCount [[buffer(20)]],
                    // ---- 自适应采样（只改调度密度，不改任何像素的期望）----
                    // queueCount > 0 时：gid.x 是队列下标，真实像素坐标从队列里取，
                    // 也就是这一趟只追"还需要的像素"，全屏网格留给正常帧。
                    device const uint2 *pixelQueue [[buffer(21)]],
                    // 队列有效长度：0 = 全网格模式（正常帧）；>0 = 队列模式
                    device const uint *queueLimit [[buffer(22)]],
                    // 1 = 这一趟是新一轮累积的首帧，必须丢掉旧的累加和
                    // （原来靠 sampleIndex == 0 判定，现在分母是逐像素计数的，不能再看全局序号）
                    constant uint &resetAccum [[buffer(23)]],
                    // ---- 补偿求和（Neumaier）：rgb 存每一步被舍掉的低位 ----
                    // 最终值 = accum.rgb + accumComp.rgb。spp 上千时这条把 float32
                    // "大和吃小样本"的误差压掉一个量级，属于同一个积分的更精确求和，不换算法。
                    texture2d<float, access::read_write> accumComp [[texture(12)]],
                    // ---- 模拟场体素（与视口同一批 3D 纹理）----
                    // 13…20 = 密度（r16Float 的 .x），21…28 = 速度场（rgba16Float 的 .w 存温度）。
                    // 槽位 = 发射器.sim.z - 1；没被占用的槽由 CPU 绑一张 1×1×1 常量纹理占位，
                    // 所有槽都必须在，否则 Metal 会因参数缺失直接拒绝绑定。
                    array<texture3d<float, access::sample>, PT_SIM_SLOTS> simDensity [[texture(13)]],
                    array<texture3d<float, access::sample>, PT_SIM_SLOTS> simTemperature [[texture(21)]],
                    // ---- 出图分块：本块左上角在整张图里的坐标 ----
                    // 视口与全图渲染时恒为 (0,0)，行为与以前一模一样；
                    // 出图分块时 dispatch 只覆盖块内像素，坐标再靠这个偏移挪回整图。
                    constant uint2 &tileOrigin [[buffer(24)]],
                    // 帧内 spp 循环：一次 dispatch 内对本像素连采 sppCount 次，辐射在寄存器里
                    // 累加，循环结束只写回一次 accum/accumComp，省掉每样本一轮的整图往返带宽。
                    constant uint &sppCount [[buffer(25)]],
                    // ---- 显式灯亮度权重 CDF（重要性采样）----
                    // 与 lights 等长的归一化前缀和（末位 = 1）。仅用于"抽哪盏灯"，
                    // 不参与任何亮度计算；index 26 是当前唯一空位（0-14、21-25 已被占用）。
                    device const float *lightsCDF [[buffer(26)]],
                    // ---- 灯 AABB 树（仅仅给 traceLightSurface 做保守剔除，不参与 NEE 抽样）----
                    // 27 = 节点数组，28 = 叶内灯下标顺序，29 = 树头（节点数 + 建树时灯数）
                    device const PTLightNode *lightNodes [[buffer(27)]],
                    device const uint *lightOrder [[buffer(28)]],
                    constant PTLightTreeHeader &lightTreeHeader [[buffer(29)]],
                    // ---- 特效发射器（体积介质源）----
                    // 数组固定 PT_VOLUME_EMITTER_LIMIT 项，**有效项连续排在前面，其余全零**。
                    // 数量不单独占槽位：Metal 的 buffer 索引上限就是 0…30，0…29 已经用满，
                    // 30 是最后一个空位，所以用「全零 = 空槽」当终止哨兵（CPU 每帧清零尾巴）。
                    // 这一代**只把桥接通**：CPU 每帧照实写进来，着色器先收下不用，
                    // 画面逐像素与接入前完全一致。介质积分接上时，改的只是下面引用它的那几行。
                    device const PTVolumeEmitter *volumeEmitters [[buffer(30)]])
{
    // 有效发射器数：逐像素算一次（最多 64 次比较），弹射循环里直接复用。
    // 0 表示场景里没有任何特效 → 介质段整体不进入，画面与接入前逐像素一致。
    const uint volumeEmitterCount = PT_VOLUME_ENABLED ? ptVolumeEmitterCount(volumeEmitters) : 0u;
    uint width = accum.get_width();
    uint height = accum.get_height();
    if (gid.y == 0u || queueLimit[0] > 0u) {
        // 队列模式：间接派发会多派到整组边界，越界的线程在这里剔掉
        uint 队列长度 = queueLimit[0];
        if (队列长度 > 0u) {
            if (gid.x >= 队列长度) return;
            gid = pixelQueue[gid.x];
        }
    }
    // 分块：dispatch 出来的是块内局部坐标，先挪回整图坐标，后面的 NDC / RNG / 图集采样全部沿用
    gid += tileOrigin;
    if (gid.x >= width || gid.y >= height) return;

    // 图集是普通 2D 像素图：UV 已归一化，线性 + clamp（格子间留了内缩缝，不会串色）
    constexpr sampler paintSampler(coord::normalized, address::clamp_to_edge, filter::linear);

    float tanHalf = camera.params.x;
    float aspect = camera.params.y;
    float3 origin = camera.cameraToWorld.columns[3].xyz;

    // ---- 帧内 spp 循环 ----
    // 【为什么】以前一帧里的 N 个样本是 N 次 dispatch，每次都要 accum.read + accumComp.read
    // 再 write 回去；4K 下这两张纹理各 132MB，一个样本就是 264MB 纯搬运。改成同一个像素
    // 在寄存器里连采 N 次、只写回一次，像素值不变，累积缓冲的读写次数从 N 次降到 1 次。
    // 【随机序列必须推进】第 s 次的种子用 (sampleIndex + s)，等价于改动前每次 dispatch
    // 各传一个递增的 sampleIndex；若整个循环共用一个种子，就成了同一根光线采 N 遍（等效 spp=1）。
    const uint 样本数 = max(sppCount, 1u);
    float3 radiance = float3(0.0f);
    // G-buffer 寄存器累加（循环结束写一次）：让 albedo/normal 与 beauty 一样是 N 样本平均，
    // 否则 aux 是单点抖动采样、beauty 是平均，两者不是同一个像素重建滤波。
    float3 gAlbedoSum = float3(0.0f);
    float3 gNormalSum = float3(0.0f);
    float gCamDist = 0.0f;
    for (uint s = 0u; s < 样本数; ++s) {
        // ---- 相机射线 ----
        RNG rng;
        rng.state = (gid.x * 1973u + gid.y * 9277u) ^ ((sampleIndex + s) * 26699u) ^ 0x9E3779B9u;

        float2 jitter = rng.uniform2();
        float2 ndc = (float2(gid) + jitter) / float2(width, height) * 2.0f - 1.0f;
        float3 dirCamera = normalize(float3(ndc.x * tanHalf * aspect, -ndc.y * tanHalf, -1.0f));
        float3 direction = normalize((camera.cameraToWorld * float4(dirCamera, 0.0f)).xyz);

        ray current(origin, direction, camera.params.z, camera.params.w);

        float3 样本辐射 = float3(0.0f);
        float3 throughput = float3(1.0f);
        bool lastWasSpecular = true;

        // 【改动·2026-11-09】弹射次数严格等于 UI「光线弹射」的数值：填 4 就跑 4 次。
        // 原貌（2026-11-09 之前）：for (uint bounce = 0u; bounce <= maxBounces; ++bounce) —— 填 4 实跑 5 次。
        // 若 UI 层传下 0（正常不会，PT 类型定义.swift 已 max(...,1) 兜底），0 次循环会全黑，故此处再保底 1 次。
        const uint 弹射次数 = max(maxBounces, 1u);
        uint 介质弹射 = 0u;   // 介质内的散射次数，与几何弹射分开记账（见 PT_VOLUME_MAX_SCATTER）
        for (uint bounce = 0u; bounce < 弹射次数; ++bounce) {
        Hit hit = traceRay(current, accel, positions, normals, indices, triangleMaterials, uvs, sliceOfVertex,
                           holeSlotOfVertex, holeAtlas, camera.params.w);

        // 灯面也参与求交：谁的命中更近，谁就挡在前面。
        // 灯不再只是"NEE 里的一个采样点"，它在画面里是一个真实存在的发光体。
        LightHit lamp = traceLightSurface(current, lights, lightsCount,
                                          hit.valid ? hit.distance : camera.params.w,
                                          lightNodes, lightOrder, lightTreeHeader);

#if PT_VOLUME_ENABLED
        // ---- 模拟场（视口 GPU 欧拉网格）直采：主射线穿一次 ----
        // 【为什么放在几何结算之前】介质是"沿视线累积"的，必须先拿到整条视线上
        // 一直到最近遮挡物的全部体素；先算几何再回头补介质，等于把遮挡关系算错。
        // 【为什么只做首跳】火在画面里的作用是"自己发光 + 挡后面"，二次弹射里
        // 那点散射光对最终图几乎不可见，但每条反射线都再 march 80 步的价格很痛。
        // 首跳拿满，反弹按解析场兜底（有模拟场的发射器在解析场里被跳过，不会翻倍）。
        if (volumeEmitterCount > 0u && bounce == 0u) {
            float 模拟远处 = camera.params.w;
            if (hit.valid) 模拟远处 = min(模拟远处, hit.distance);
            const float4 模拟 = ptSimIntegrate(volumeEmitters, volumeEmitterCount,
                                               simDensity, simTemperature,
                                               current.origin, current.direction, 模拟远处,
                                               rng.uniform());
            样本辐射 += throughput * 模拟.rgb;
            throughput *= 模拟.w;
            if (luminanceOf(throughput) < 1e-4f) break;
        }

        // ---- 体积介质：先穿过介质，再结算这一跳的几何 ----
        // 【为什么插在这里】此刻「几何命中距离」和「灯面命中距离」都已经知道了，
        // 介质只需要追到两者中更近的那个为止 —— 再深的事件会被不透明表面挡住，看不见，白算。
        // 【为什么是 continue 而不是 return】介质事件是路径上的一个真实散射点：
        // 累加它的自发辐射 → throughput 乘单次散射反照率 → 按相函数抽新方向继续追。
        // 它消耗掉一次弹射，与"撞到表面"在路径记账上是同一件事，所以无偏性不变。
        //
        // 【接入前口径的保证】没有发射器时 count == 0，下面一次随机数都不抽、
        // 一个寄存器都不写，画面与接入前逐像素一致。
        // 介质消光上界：本跳主路径与后面所有阴影射线共用同一个数（各处各算一遍纯属浪费）
        const float 介质上界 = (volumeEmitterCount > 0u)
            ? ptVolumeMajorant(volumeEmitters, volumeEmitterCount) : 0.0f;

        if (volumeEmitterCount > 0u) {
            float 远处 = camera.params.w;
            if (hit.valid) 远处 = min(远处, hit.distance);
            if (lamp.valid) 远处 = min(远处, lamp.distance);

            float3 事件点 = float3(0.0f);
            float3 事件发光 = float3(0.0f);
            float3 事件反照率 = float3(1.0f);
            float 事件g = 0.0f;
            float 事件距离 = 0.0f;
            if (ptTraceVolume(volumeEmitters, volumeEmitterCount, 介质上界, current, 远处, rng,
                              事件点, 事件发光, 事件反照率, 事件g, 事件距离, camera.volume.x, camera.volume.y)) {
                // 首跳被介质挡住：G-buffer 要交"介质表面"的引导信息，
                // 而不是背后那个其实没被看见的物体（降噪器拿错引导会在烟边出鬼影）。
                if (bounce == 0u) {
                    gNormalSum += -current.direction;
                    gAlbedoSum += clamp(事件反照率, float3(0.0f), float3(1.0f));
                    gCamDist = 事件距离;
                }
                // 自发光与吸收的耦合：碰撞是按 σt 采样的，只有其中 σa/σt = 1-反照率 的份额
                // 真正被吸收并放出 Le，剩下 σs/σt 的份额散射后继续（throughput 乘反照率）。
                // 两项加起来恰好是 σa·Le + σs·∫p·L，不多不少 —— 所以乘 (1-albedo) 是必须的，
                // 不是随手压暗；这里按通道算而不是取亮度，彩色介质（蓝火/黄烟）才不会串色。
                const float3 反照率夹 = clamp(事件反照率, float3(0.0f), float3(1.0f));
                样本辐射 += throughput * 事件发光 * (float3(1.0f) - 反照率夹);
                throughput *= 反照率夹;
                if (luminanceOf(throughput) < 1e-4f) break;

                // ---- 介质处的直接光（NEE）：相位函数代替 BSDF ----
                // 【为什么必须有】少了这一项，烟只能靠「自发辐射」和「遮住别人」存在：
                // 太阳从侧面照过来时整片烟是死的灰雾，逆光时也不会发亮 —— 而后者恰恰是
                // 真实烟最重要的视觉特征（前向散射把背后光源的光甩向相机）。
                // 相位函数在这里直接替代 BSDF·cos 的乘子；pdf 由方向采样侧承担，
                // 因为介质事件之后我们按 hgSample 抽方向、估计量与 pdf 正好相消。
                if (environment.sun.w > 0.0f) {
                    float3 sunDir = normalize(environment.sun.xyz);
                    float 相位 = hgPhase(dot(current.direction, sunDir), 事件g);
                    if (相位 > 1e-6f) {
                        ray 介质阴影(事件点 + sunDir * 0.002f, sunDir, 0.002f, 1000.0f);
                        Hit 介质遮挡 = traceRay(介质阴影, accel, positions, normals, indices, triangleMaterials, uvs, sliceOfVertex,
                                               holeSlotOfVertex, holeAtlas, 1000.0f);
                        if (!介质遮挡.valid) {
                            // 到太阳这一段还要穿过的烟（自身不会遮住自己，用同一套 ratio tracking）
                            float 穿透 = ptVolumeTransmittance(volumeEmitters, volumeEmitterCount, 介质上界,
                                                               介质阴影.origin, 介质阴影.direction, 1000.0f, rng, camera.volume.x, camera.volume.y);
                            样本辐射 += throughput * 相位 * environment.sun.w * 穿透;
                        }
                    }
                }

#if PT_VOLUME_NEE_LIGHTS_ENABLED
                // ---- 介质处的灯光直接光（NEE）：与表面 NEE 完全对称，只换掉 BSDF ----
                // 【口径】介质事件是体积里的散射点，没有表面法线、也就没有 nDotL 这一项；
                // BSDF·cos 的位置上放相函数。于是世界里的辐照度项只有「光源立体角投影 / 距离²」。
                // 而 pdf 本来就是按这个几何项定的，两者在估计量里恰好相消，于是：
                //   · 面积光 / 球光样本  →  Le · 相位 / pickProb
                //   · 理想点光            →  Le · 相位 / (dist² · pickProb)
                // 这不是化简偷懒，是重要性采样的结果；写成通用式反而会引入两份浮点误差。
                if (lightCount > 0u) {
                    // 自发光三角面（贴了 emissive 材质的网格）：与表面 NEE 用同一张 CDF
                    uint 命中槽 = 0u;
                    float selectProb = 0.0f;
#if PT_AREA_LIGHT_BLOCK_CDF_ENABLED
                    uint 块数 = (lightCount + PT_AREA_LIGHT_BLOCK_SIZE - 1u) / PT_AREA_LIGHT_BLOCK_SIZE;
                    device const float *块CDF = lightCDF + lightCount;
                    device const float *块宽表 = 块CDF + 块数;
                    device const float *内CDF = 块宽表 + 块数;
                    device const float *内宽表 = 内CDF + lightCount;
                    float u1 = rng.uniform();
                    float u2 = rng.uniform();
                    uint lo = 0u;
                    uint hi = 块数 - 1u;
                    while (lo < hi) {
                        uint mid = (lo + hi) >> 1u;
                        if (块CDF[mid] < u1) { lo = mid + 1u; } else { hi = mid; }
                    }
                    float 块宽 = max(块宽表[lo], PT_AREA_LIGHT_PDF_EPS);
                    uint 起 = lo * PT_AREA_LIGHT_BLOCK_SIZE;
                    uint 项数 = min(PT_AREA_LIGHT_BLOCK_SIZE, lightCount - 起);
                    uint a = 0u;
                    uint b = 项数 - 1u;
                    while (a < b) {
                        uint mid = (a + b) >> 1u;
                        if (内CDF[起 + mid] < u2) { a = mid + 1u; } else { b = mid; }
                    }
                    float 内宽 = max(内宽表[起 + a], PT_AREA_LIGHT_PDF_EPS);
                    selectProb = 块宽 * 内宽;
                    命中槽 = 起 + a;
#else
                    float u1 = rng.uniform();
                    uint lo = 0u;
                    uint hi = lightCount - 1u;
                    while (lo < hi) {
                        uint mid = (lo + hi) >> 1u;
                        if (lightCDF[mid] < u1) { lo = mid + 1u; } else { hi = mid; }
                    }
                    float cdfHigh = lightCDF[lo];
                    float cdfLow = lo == 0u ? 0.0f : lightCDF[lo - 1u];
                    selectProb = max(cdfHigh - cdfLow, 1e-9f);
                    命中槽 = lo;
#endif
                    uint tri = lightTriangles[命中槽];
                    float3 q0 = positions[indices[tri * 3u + 0u]].xyz;
                    float3 q1 = positions[indices[tri * 3u + 1u]].xyz;
                    float3 q2 = positions[indices[tri * 3u + 2u]].xyz;
                    float3 crossE = cross(q1 - q0, q2 - q0);
                    if (0.5f * length(crossE) > 1e-8f) {
                        float2 uv = rng.uniform2();
                        float su = sqrt(uv.x);
                        float3 lightPoint = q0 * (1.0f - su) + q1 * (su * (1.0f - uv.y)) + q2 * (su * uv.y);
                        float3 lightNormal = normalize(crossE);
                        float3 toLight = lightPoint - 事件点;
                        float dist2 = length_squared(toLight);
                        float dist = sqrt(dist2);
                        if (dist > 1e-4f) {
                            float3 l = toLight / dist;
                            float cosLight = dot(lightNormal, -l);
                            float 相位 = hgPhase(dot(current.direction, l), 事件g);
                            if (cosLight > 1e-4f && 相位 > 1e-6f) {
                                ray 介质灯影(事件点 + l * 0.002f, l, 0.002f, dist - 0.002f);
                                Hit 挡 = traceRay(介质灯影, accel, positions, normals, indices, triangleMaterials, uvs, sliceOfVertex,
                                                 holeSlotOfVertex, holeAtlas, dist - 0.002f);
                                if (!挡.valid) {
                                    PTMaterialGPU 灯材质 = materials[triangleMaterials[tri]];
                                    float3 Le = 灯材质.emissive.rgb * 灯材质.emissive.a;
                                    float 穿透 = ptVolumeTransmittance(volumeEmitters, volumeEmitterCount, 介质上界,
                                                                       介质灯影.origin, 介质灯影.direction, dist, rng, camera.volume.x, camera.volume.y);
                                    样本辐射 += throughput * 相位 * Le / max(selectProb, 1e-20f) * 穿透;
                                }
                            }
                        }
                    }
                }

                if (lightsCount > 0u) {
                    // 灯对象：平行光 / 区域光 / 点光 / 聚光
                    float u = rng.uniform();
                    uint pick;
                    float pickProb;
#if PT_EXPLICIT_LIGHT_CDF_ENABLED
                    if (lightsCDF[lightsCount - 1u] > 0.0f) {
                        uint lo = 0u;
                        uint hi = lightsCount - 1u;
                        while (lo < hi) {
                            uint mid = (lo + hi) >> 1u;
                            if (lightsCDF[mid] < u) { lo = mid + 1u; } else { hi = mid; }
                        }
                        float cdfHi = lightsCDF[lo];
                        float cdfLo = (lo == 0u) ? 0.0f : lightsCDF[lo - 1u];
                        pick = lo;
                        pickProb = max(cdfHi - cdfLo, 1e-9f);
                    } else
#endif
                    {
                        pick = min(uint(u * float(lightsCount)), lightsCount - 1u);
                        pickProb = 1.0f / float(lightsCount);
                    }

                    PTLightGPU L = lights[pick];
                    uint kind = uint(L.shape.z + 0.5f);
                    float3 Le = L.colorIntensity.xyz * L.colorIntensity.w;
                    float3 center = L.positionRadius.xyz;
                    float radius = max(L.positionRadius.w, 0.0f);
                    float3 axis = normalize(L.axisCosCone.xyz);

                    if (kind == PT_LIGHT_SUN) {
                        float3 l = -axis;
                        float 相位 = hgPhase(dot(current.direction, l), 事件g);
                        if (相位 > 1e-6f) {
                            ray 介质灯影(事件点 + l * 0.002f, l, 0.002f, 1000.0f);
                            Hit 挡 = traceRay(介质灯影, accel, positions, normals, indices, triangleMaterials, uvs, sliceOfVertex,
                                             holeSlotOfVertex, holeAtlas, 1000.0f);
                            if (!挡.valid) {
                                float 穿透 = ptVolumeTransmittance(volumeEmitters, volumeEmitterCount, 介质上界,
                                                                   介质灯影.origin, 介质灯影.direction, 1000.0f, rng, camera.volume.x, camera.volume.y);
                                样本辐射 += throughput * 相位 * Le / pickProb * 穿透;
                            }
                        }
                    } else if (kind == PT_LIGHT_AREA) {
                        float w = max(L.shape.x, 0.01f);
                        float h = max(L.shape.y, 0.01f);
                        float3 upHint = fabs(axis.y) > 0.99f ? float3(1.0f, 0.0f, 0.0f) : float3(0.0f, 1.0f, 0.0f);
                        float3 tx = normalize(cross(upHint, axis));
                        float3 ty = cross(axis, tx);
                        float2 uv = rng.uniform2();
                        float3 lightPoint = center + tx * ((uv.x - 0.5f) * w) + ty * ((uv.y - 0.5f) * h);
                        float3 toLight = lightPoint - 事件点;
                        float dist2 = length_squared(toLight);
                        float dist = sqrt(dist2);
                        if (dist > 1e-4f) {
                            float3 l = toLight / dist;
                            float cosLight = dot(axis, -l);
                            float 相位 = hgPhase(dot(current.direction, l), 事件g);
                            if (cosLight > 1e-4f && 相位 > 1e-6f) {
                                ray 介质灯影(事件点 + l * 0.002f, l, 0.002f, dist - 0.002f);
                                Hit 挡 = traceRay(介质灯影, accel, positions, normals, indices, triangleMaterials, uvs, sliceOfVertex,
                                                 holeSlotOfVertex, holeAtlas, dist - 0.002f);
                                if (!挡.valid) {
                                    float 穿透 = ptVolumeTransmittance(volumeEmitters, volumeEmitterCount, 介质上界,
                                                                       介质灯影.origin, 介质灯影.direction, dist, rng, camera.volume.x, camera.volume.y);
                                    样本辐射 += throughput * 相位 * Le / max(pickProb, 1e-9f) * 穿透;
                                }
                            }
                        }
                    } else {
                        // 点光 / 聚光（半径 > 0 时按小球面采样，柔化阴影，口径同表面 NEE）
                        float3 lightPoint = center;
                        bool 有球面 = false;
                        if (radius > 1e-3f) {
                            float z = 1.0f - 2.0f * rng.uniform();
                            float r = sqrt(max(1.0f - z * z, 0.0f));
                            float phi = 2.0f * M_PI_F * rng.uniform();
                            lightPoint = center + float3(r * cos(phi), r * sin(phi), z) * radius;
                            有球面 = true;
                        }
                        float3 toLight = lightPoint - 事件点;
                        float dist2 = length_squared(toLight);
                        float dist = sqrt(dist2);
                        if (dist > 1e-4f) {
                            float3 l = toLight / dist;
                            float falloff = 1.0f;
                            if (kind == PT_LIGHT_SPOT) {
                                float cosDir = dot(axis, -l);
                                float cosCone = clamp(L.axisCosCone.w, -1.0f, 0.9999f);
                                float softness = clamp(L.shape.w, 0.0f, 1.0f);
                                float cosOuter = cosCone - softness * (1.0f - cosCone);
                                falloff = smoothstep(cosOuter, cosCone, cosDir);
                            }
                            float 相位 = hgPhase(dot(current.direction, l), 事件g);
                            if (falloff > 1e-4f && 相位 > 1e-6f) {
                                ray 介质灯影(事件点 + l * 0.002f, l, 0.002f, dist - 0.002f);
                                Hit 挡 = traceRay(介质灯影, accel, positions, normals, indices, triangleMaterials, uvs, sliceOfVertex,
                                                 holeSlotOfVertex, holeAtlas, dist - 0.002f);
                                if (!挡.valid) {
                                    float 穿透 = ptVolumeTransmittance(volumeEmitters, volumeEmitterCount, 介质上界,
                                                                       介质灯影.origin, 介质灯影.direction, dist, rng, camera.volume.x, camera.volume.y);
                                    if (有球面) {
                                        // 采样了小球面上的一点 → 几何项与 pdf 相消
                                        样本辐射 += throughput * 相位 * Le * falloff / max(pickProb, 1e-9f) * 穿透;
                                    } else {
                                        // 理想点光：强度按平方反比衰减
                                        样本辐射 += throughput * 相位 * Le * falloff / (dist2 * max(pickProb, 1e-9f)) * 穿透;
                                    }
                                }
                            }
                        }
                    }
                }
#endif

                float3 散射方向 = hgSample(current.direction, 事件g, rng);
                // 起点推进一个极小量，避免浮点原地重撞同一个介质事件
                current = ray(事件点 + 散射方向 * 1e-4f, 散射方向, 0.0f, camera.params.w);
                lastWasSpecular = false;
                // 介质散射不占用几何弹射额度，否则浓烟会把预算吃光、烟看着发黑（这属于预算问题不是物理）。
                // bounce == 0（相机第一跳直接进烟）时没有额度可还，就让它正常扣一次。
                if (bounce > 0u) --bounce;
                if (++介质弹射 >= PT_VOLUME_MAX_SCATTER) break;
                continue;
            }
        }
#endif

        // 第一跳的几何信息：逐样本累加到寄存器，循环结束写一次 G-buffer。
        // 【为什么改】OIDN README 要求 aux 与 beauty 用同一像素重建滤波：
        // 原来只在 s==0 写一次，用的是单个抖动采样位置，而 beauty 是 N 个样本平均 → 边缘出 artifact。
        if (bounce == 0u) {
            if (lamp.valid) {
                // 看到的是灯本身：法线给灯面几何；albedo 给 1 而不是发光色——
                // albedo 必须与光照无关，塞 emissive 等于把发光亮度当反照率（且会被截断）。
                gNormalSum += lamp.normal;
                gAlbedoSum += float3(1.0f);
                // 注意：这里不写 hitCounter —— 那是"几何求交健康度"探针，
                // 拿灯面去凑数会让加速结构真的退化时蒙混过关，自动重建就不会触发了。
            } else if (!hit.valid) {
                // 天空：法线给"朝向相机"的方向，而不是 (0,0,0) 的占位值，
                // 跨天地边界时降噪器才不会把天空和物体当成同一张表面；
                // albedo 给 1 而不是纯黑——color 里天空是有亮度的，albedo 给 0 与它自相矛盾。
                gNormalSum += -current.direction;
                gAlbedoSum += float3(1.0f);
            } else {
                gCamDist = length(hit.position - camera.cameraToWorld.columns[3].xyz);
                // 法线累加挪到材质与笔迹处理之后，用"实际着色法线"（含笔迹法线通道扰动）。
                // 求交健康度探针：统计"首发命中"的像素数。
                // 整屏 0 命中而场景非空 = 加速结构求交已退化（全屏只剩环境色的那个 bug），
                // CPU 侧据此自动换代重建，不再需要用户去动一下视口来"踢"它。
                // 口径不变：仍只在第一个样本计一次，避免同一像素被重复计数。
                if (s == 0u) {
                    atomic_fetch_add_explicit(hitCounter, 1u, memory_order_relaxed);
                }
            }
        }

        // 光线先撞上灯：把看到的发光面亮度直接交出去，路径到此收尾。
        // 这就是灯到模型之间可视的那一段：相机看到的是灯真实的辐亮度，
        // 反射/折射路径看到的是经过 BSDF 衰减的样子，跟现实里拍一张带灯具的照片同理。
        if (lamp.valid) {
            样本辐射 += throughput * lamp.emissive;
            break;
        }

        if (!hit.valid) {
            样本辐射 += throughput * skyRadiance(environment, current.direction);
            break;
        }

        PTMaterialGPU m = materials[hit.materialIndex];
        float3 n = hit.normal;
        float3 v = -current.direction;

        // ---- 笔迹通道：颜色以外的 OpenPBR 参数在这里覆盖材质 ----
        // 位序与 CPU 侧 位表 一一对应：1 粗糙度 / 2 金属度 / 4 清漆权重 /
        // 8 清漆粗糙度 / 16 自发光 / 32 法线。图集里 a = 覆盖度，用它 mix，
        // 所以没画到的像素完全等于原材质，不会出现"整块物体变金属"。
        if (hasPaint != 0u && channelMask != 0u && hit.slice != 0xFFFFFFFFu) {
            if ((channelMask & 1u) != 0u) {
                float4 s = roughAtlas.sample(paintSampler, hit.uv, hit.slice);
                m.p0.x = mix(m.p0.x, clamp(s.r, 0.0f, 1.0f), s.a);
            }
            if ((channelMask & 2u) != 0u) {
                float4 s = metalAtlas.sample(paintSampler, hit.uv, hit.slice);
                m.p0.y = mix(m.p0.y, clamp(s.r, 0.0f, 1.0f), s.a);
            }
            if ((channelMask & 4u) != 0u) {
                float4 s = coatWeightAtlas.sample(paintSampler, hit.uv, hit.slice);
                m.p1.w = mix(m.p1.w, clamp(s.r, 0.0f, 1.0f), s.a);
            }
            if ((channelMask & 8u) != 0u) {
                float4 s = coatRoughAtlas.sample(paintSampler, hit.uv, hit.slice);
                m.p2.x = mix(m.p2.x, clamp(s.r, 0.01f, 1.0f), s.a);
            }
            if ((channelMask & 16u) != 0u) {
                float4 s = emissionAtlas.sample(paintSampler, hit.uv, hit.slice);
                m.emissive = float4(mix(m.emissive.rgb, s.rgb, s.a), mix(m.emissive.a, 1.0f, s.a));
            }
            if ((channelMask & 32u) != 0u) {
                float4 s = normalAtlas.sample(paintSampler, hit.uv, hit.slice);
                // 法线通道存的是 n * 0.5 + 0.5（rgba8 存不了负值），这里反解回来。
                // 量化后的法线可能退化成长度接近 0 的向量，那种情况直接不扰动。
                float3 笔刷法线 = s.rgb * 2.0f - 1.0f;
                if (dot(笔刷法线, 笔刷法线) > 0.01f) {
                    n = normalize(mix(n, normalize(笔刷法线), s.a));
                }
            }
        }

        // G-buffer 法线：用这一跳"实际参与着色"的 n（已含笔迹法线通道扰动），
        // 而不是几何法线 hit.normal —— 否则画过法线笔迹的表面 albedo 有笔迹、normal 没有，
        // 降噪器拿到的引导和真实着色不一致。首跳每个样本恰好累加一次。
        if (bounce == 0u) {
            gNormalSum += n;
        }

        // 自发光：只有相机直接看到、或上一跳是镜面时才累加；
        // 漫反射跳自发光交给下面的面光源采样，否则同一份能量会被记两次
        if (bounce == 0u || lastWasSpecular) {
            样本辐射 += throughput * m.emissive.rgb * m.emissive.a;
        }

        // 基底色：先取材质贴图（导入图 / 常量），再让笔迹按覆盖度盖上去。
        // 顺序不能反，否则导入贴图会把画上去的笔迹整片盖掉。
        float3 材质基色 = materialBaseColor(matAtlas, paintSampler, hit.uv, m.p3, m.baseColor.rgb);
        float3 baseAlbedo = paintTint(paintAtlas, paintSampler, hit.uv, hit.slice, 材质基色);
        float metallic = saturate(m.p0.y);
        float roughness = max(m.p0.x, 0.02f);
        float transmission = saturate(m.p0.w);
        float ior = max(m.p0.z, 1.01f);

        float3 diffuseAlbedo = baseAlbedo * (1.0f - metallic) * (1.0f - transmission);
        float3 specF0 = mix(float3(0.04f) * m.p2.z, baseAlbedo, metallic);

        // G-buffer albedo：给"与光照无关"的反射率（OIDN README 的口径）——
        // 金属给 normal-incidence 反射率 specF0，玻璃(delta BSDF)给 1，中间按 metallic/transmission 混合。
        // 原来统一送 baseColor×paintTint，金属和玻璃都会引导错。
        if (bounce == 0u) {
            float3 引导反照率 = mix(diffuseAlbedo, specF0, metallic);
            if (transmission > 0.001f) 引导反照率 = mix(引导反照率, float3(1.0f), transmission);
            gAlbedoSum += 引导反照率;
        }

        // ---- 这一跳能不能做 NEE（直接光采样）----
        // 旧口径只有一条：lastWasSpecular —— 它记录的是"上一跳 BSDF 抽到了 delta lobe"，
        // 所以 bounce==0 时它是初值 true，太阳/面光/显式灯三条 NEE 全被跳过，
        // 相机直接看到的那层表面只能靠 BSDF 瞎撞光源 → 首跳噪声最大。
        // 新口径：
        //   · bounce > 0：保持原样（非 delta 跳才 NEE）；
        //   · bounce == 0：看"首个命中表面的材质是不是 delta"——不是 delta 就做 NEE。
        // 为什么不 delta 就可以做：NEE 算的是"该点的入射辐照 → BSDF → 相机"，
        // 与"相机直接看到发光面本身"是两项不同的积分；而命中发光面的累加只在
        // bounce==0 或 lastWasSpecular 时进行（见上面的自发光累加），
        // 所以首跳做 NEE 之后，后续非 delta 跳的命中发光仍不累加 —— 互斥规则不变，无偏性不破。
        // 而 delta 材质（玻璃 / 纯镜面）必须继续跳过：它的 BSDF 是狄拉克分布，
        // 对 NEE 采到的方向求值恒为 0（只会白打一条阴影射线），
        // 且它的能量本来就由"BSDF 采样命中的发光面"那条路收账，放开就是重复计数。
        // delta 判定与下面 BSDF 采样挑 lobe 的口径对齐：
        //   ① 有透射（玻璃）→ 会走透射 lobe（lastWasSpecular = true）；
        //   ② 漫反射成分为 0 且粗糙度低于镜面阈值 → 会走 ideal 镜面 lobe（lastWasSpecular = true）。
        // 粗糙金属（漫反射为 0 但 roughness >= 0.06）不算 delta：它走 GGX lobe，
        // evalSpecular 在其上是有限值，做 NEE 是有意义的。
        bool 首跳表面是delta = (transmission > 0.001f)
            || (roughness < 0.06f && dot(diffuseAlbedo, float3(1.0f, 1.0f, 1.0f)) < 0.001f);
        bool 可做NEE = !lastWasSpecular;
#if PT_FIRSTBOUNCE_NEE_ENABLED
        if (bounce == 0u && !首跳表面是delta) {
            可做NEE = true;
        }
#endif

        // ---- 太阳直接光（NEE）：上一跳是镜面时跳过，避免高强度点被重复放大 ----
        if (可做NEE) {
            float3 sunDir = normalize(environment.sun.xyz);
            float nDotL = dot(n, sunDir);
            if (nDotL > 0.0f && environment.sun.w > 0.0f) {
                ray shadowRay(hit.position + n * 0.0015f, sunDir, 0.002f, 1000.0f);
                Hit shadowHit = traceRay(shadowRay, accel, positions, normals, indices, triangleMaterials, uvs, sliceOfVertex,
                                         holeSlotOfVertex, holeAtlas, 1000.0f);
                if (!shadowHit.valid) {
                    // 烟/火挡住太阳：阴影射线只回答了「几何可不可见」，介质的吸收要在这里补，
                    // 否则烟永远是半透明的装饰品、不会在地面投出影子。
                    const float 透射 = ptVolumeTransmittance(volumeEmitters, volumeEmitterCount, 介质上界,
                                                             shadowRay.origin, shadowRay.direction, 1000.0f, rng, camera.volume.x, camera.volume.y);
                    float3 f = diffuseAlbedo / M_PI_F
                        + evalSpecular(m, n, v, sunDir, specF0)
                        + evalCoat(m, n, v, sunDir);
                    样本辐射 += throughput * f * nDotL * environment.sun.w * 透射;
                }
            }
        }

        // ---- 面光源直接光（光源列表 CDF 采样 + 阴影射线）----
        // 只抽一支代表光源：纸面上是「均匀抽三角形」，实际效果等于按发光功率做重要性采样，
        // 大面积柔光、发光球这类区域不再依赖 BSDF 瞎撞。
        if (可做NEE && lightCount > 0u) {
            uint 命中槽 = 0u;
            float selectProb = 0.0f;
#if PT_AREA_LIGHT_BLOCK_CDF_ENABLED
            // ---- 两级采样：先抽块（全局占比），再抽块内项（块内条件概率）----
            // 为什么能救回"大而暗的面"：块是按权重降序切出来的，尾部块的总和极小，
            // 块内 CDF 又按「块内总量」重新归一 —— 块内的分辨力参考的是块内总量而不是全局总量，
            // 于是真实占比 1e-9 的面在它所属的小块里占比可能是 1e-2，float32 轻松分辨。
            uint 块数 = (lightCount + PT_AREA_LIGHT_BLOCK_SIZE - 1u) / PT_AREA_LIGHT_BLOCK_SIZE;
            device const float *块CDF = lightCDF + lightCount;          // [n, n+B)      块前缀
            device const float *块宽表 = 块CDF + 块数;                   // [n+B, n+2B)   块格宽（Double 算好再转 float32）
            device const float *内CDF = 块宽表 + 块数;                   // [n+2B, 2n+2B) 块内前缀
            device const float *内宽表 = 内CDF + lightCount;             // [2n+2B, 3n+2B)块内格宽
            float u1 = rng.uniform();   // 选块
            float u2 = rng.uniform();   // 选块内项
            uint lo = 0u;
            uint hi = 块数 - 1u;
            while (lo < hi) {
                uint mid = (lo + hi) >> 1u;
                if (块CDF[mid] < u1) { lo = mid + 1u; } else { hi = mid; }
            }
            // 格宽读表而不是相邻前缀相减：两边都挤在 1.0 附近时 float32 减法的
            // 绝对误差就是 ulp(1.0)=1.19e-7，尾部 6e-7 宽的块会偏 10%，pdf 也跟着偏。
            float 块宽 = max(块宽表[lo], PT_AREA_LIGHT_PDF_EPS);       // = 全局占比
            uint 起 = lo * PT_AREA_LIGHT_BLOCK_SIZE;
            uint 项数 = min(PT_AREA_LIGHT_BLOCK_SIZE, lightCount - 起);
            uint a = 0u;
            uint b = 项数 - 1u;
            while (a < b) {
                uint mid = (a + b) >> 1u;
                if (内CDF[起 + mid] < u2) { a = mid + 1u; } else { b = mid; }
            }
            float 内宽 = max(内宽表[起 + a], PT_AREA_LIGHT_PDF_EPS);    // = 块内条件概率
            // 【pdf 必须是"块格宽 × 块内格宽"】漏乘块格宽 = 每块权重按 1 算，暗块被放大几千倍；
            // 漏乘内格宽 = 块内按均匀算。两者都无偏但方差爆掉，且与 CPU 分布对不上。
            selectProb = 块宽 * 内宽;
            命中槽 = 起 + a;
#else
            // ---- 回滚路径：按三角形的单级全局 CDF（与改动前一致）----
            float u1 = rng.uniform();
            uint lo = 0u;
            uint hi = lightCount - 1u;
            while (lo < hi) {
                uint mid = (lo + hi) >> 1u;
                if (lightCDF[mid] < u1) { lo = mid + 1u; } else { hi = mid; }
            }
            float cdfHigh = lightCDF[lo];
            float cdfLow = lo == 0u ? 0.0f : lightCDF[lo - 1u];
            // CPU 侧这一版仍是「相对全局 1e-6 下限 + 严格单调」，格宽 ≥ ~0.9e-6，
            // 所以 1e-9 只是除法保险，不参与放缩。
            selectProb = max(cdfHigh - cdfLow, 1e-9f);
            命中槽 = lo;
#endif

            // 【permutation 映射】二分命中的是"降序排序后的位置"，必须经 lightTriangles 映射回
            // 真实三角形下标，再拿它取顶点、法线、材质 —— 直接拿位置当下标会错位到别的三角形上。
            uint tri = lightTriangles[命中槽];
            float3 q0 = positions[indices[tri * 3u + 0u]].xyz;
            float3 q1 = positions[indices[tri * 3u + 1u]].xyz;
            float3 q2 = positions[indices[tri * 3u + 2u]].xyz;
            float3 edge1 = q1 - q0;
            float3 edge2 = q2 - q0;
            float3 crossE = cross(edge1, edge2);
            float area = 0.5f * length(crossE);

            if (area > 1e-8f) {
                float2 uv = rng.uniform2();
                float su = sqrt(uv.x);
                float3 lightPoint = q0 * (1.0f - su) + q1 * (su * (1.0f - uv.y)) + q2 * (su * uv.y);
                float3 lightNormal = normalize(crossE);
                float3 toLight = lightPoint - hit.position;
                float dist2 = length_squared(toLight);
                float dist = sqrt(dist2);
                if (dist > 1e-4f) {
                    float3 l = toLight / dist;
                    float cosLight = dot(lightNormal, -l);
                    float nDotL = dot(n, l);
                    if (cosLight > 1e-4f && nDotL > 0.0f) {
                        ray shadowRay(hit.position + n * 0.0015f, l, 0.002f, dist - 0.002f);
                        Hit shadowHit = traceRay(shadowRay, accel, positions, normals, indices, triangleMaterials, uvs, sliceOfVertex,
                                         holeSlotOfVertex, holeAtlas, dist - 0.002f);
                        if (!shadowHit.valid) {
                            const float 透射 = ptVolumeTransmittance(volumeEmitters, volumeEmitterCount, 介质上界,
                                                                     shadowRay.origin, shadowRay.direction, dist, rng, camera.volume.x, camera.volume.y);
                            PTMaterialGPU lightMaterial = materials[triangleMaterials[tri]];
                            float3 Le = lightMaterial.emissive.rgb * lightMaterial.emissive.a;
                            float3 f = diffuseAlbedo / M_PI_F
                                + evalSpecular(m, n, v, l, specF0)
                                + evalCoat(m, n, v, l);
                            // 立体角 pdf = 选中概率 × 距离² / (cosLight × 面积)
                            // 【两级 CDF 后重新核定的下限】原来两处都是 1e-6：
                            //   · max(cosLight*area, 1e-6)：面积 <1e-6 的小三角形会把分母抬上去 → pdf 偏大 → 偏暗；
                            //   · max(pdf, 1e-6)：两级方案里合法的 pdf 可以低到 ~1e-14 量级，
                            //     1e-6 会把它抬高 8 个数量级 → 暗面贡献被压成 0，等于白改。
                            // 现在 cosLight>1e-4 且 area>1e-8 已保证分母 >1e-12，所以 1e-12 只是形状保险；
                            // pdf 侧压到 1e-20（实测合法最小值约 1e-14 × 距离²/(cos·area)），
                            // 既不参与放缩，又拦住 0 * inf 产生 NaN。
                            float pdf = selectProb * dist2 / max(cosLight * area, 1e-12f);
                            样本辐射 += throughput * f * Le * nDotL / max(pdf, 1e-20f) * 透射;
                        }
                    }
                }
            }
        }

        // ---- 显式灯光直接光（灯对象：区域光 / 点光 / 聚光 / 平行光）----
        // 灯不是三角形，只在这里被抽到：每次随机抽一盏，pdf 按选中概率补偿。
        // 抽样分布 = 每盏灯亮度权重的归一化 CDF（PT_EXPLICIT_LIGHT_CDF_ENABLED=1 时）；
        // 只有"抽哪盏灯"的概率变了，每盏灯的贡献表达式原样不动 → 期望不变（无偏），仅方差下降。
        // 相机射线永远不会命中灯 —— 这就是它跟"贴了自发光材质的网格"的本质区别。
        if (可做NEE && lightsCount > 0u) {
            // 【随机数消耗恒定】无论走 CDF 还是退化成均匀，这里都只抽一次 uniform，
            // 因此 lightsCount == 1 时 pick = 0、pickProb = cdf[0] - 0 = 1.0f，
            // 与旧的 min(uint(u*1),0) / 1.0f 逐位相同，随机流一致 → 画面逐位一致。
            float u = rng.uniform();
            uint pick;
            float pickProb;
#if PT_EXPLICIT_LIGHT_CDF_ENABLED
            if (lightsCDF[lightsCount - 1u] > 0.0f) {
                // 二分：找第一个满足 cdf[i] >= u 的 i（CDF 升序，末位 = 1）
                uint lo = 0u;
                uint hi = lightsCount - 1u;
                while (lo < hi) {
                    uint mid = (lo + hi) >> 1u;
                    if (lightsCDF[mid] < u) { lo = mid + 1u; } else { hi = mid; }
                }
                float cdfHi = lightsCDF[lo];
                float cdfLo = (lo == 0u) ? 0.0f : lightsCDF[lo - 1u];
                pick = lo;
                // pdf 必须与选灯分布严格一一对应：就是该灯在 CDF 上的那一格宽度。
                // 下限仅防除零（CPU 侧已把每盏灯权重抬到最亮灯的 1/1000 以上，正常场景不触发），
                // 不改变任何一盏灯被抽中的分布，也不因遮挡情况做任何重归一化。
                pickProb = max(cdfHi - cdfLo, 1e-9f);
            } else
#endif
            {
                // 退回原来的均匀抽样（1/lightsCount），一行开关即可回到旧行为
                pick = min(uint(u * float(lightsCount)), lightsCount - 1u);
                pickProb = 1.0f / float(lightsCount);
            }
            PTLightGPU L = lights[pick];
            uint kind = uint(L.shape.z + 0.5f);
            float3 Le = L.colorIntensity.xyz * L.colorIntensity.w;
            float3 center = L.positionRadius.xyz;
            float radius = max(L.positionRadius.w, 0.0f);
            float3 axis = normalize(L.axisCosCone.xyz);

            if (kind == PT_LIGHT_SUN) {
                // 平行光：朝向即光线传播方向，指向光源的方向取反
                float3 l = -axis;
                float nDotL = dot(n, l);
                if (nDotL > 0.0f) {
                    ray shadowRay(hit.position + n * 0.0015f, l, 0.002f, 1000.0f);
                    Hit shadowHit = traceRay(shadowRay, accel, positions, normals, indices, triangleMaterials, uvs, sliceOfVertex,
                                             holeSlotOfVertex, holeAtlas, 1000.0f);
                    if (!shadowHit.valid) {
                        float3 f = diffuseAlbedo / M_PI_F
                            + evalSpecular(m, n, v, l, specF0)
                            + evalCoat(m, n, v, l);
                        样本辐射 += throughput * f * Le * nDotL / pickProb
                            * ptVolumeTransmittance(volumeEmitters, volumeEmitterCount, 介质上界,
                                                    shadowRay.origin, shadowRay.direction, 1000.0f, rng, camera.volume.x, camera.volume.y);
                    }
                }
            } else if (kind == PT_LIGHT_AREA) {
                // 区域光：矩形面片，单面朝 axis 发光（柔光箱语义）
                float w = max(L.shape.x, 0.01f);
                float h = max(L.shape.y, 0.01f);
                float3 upHint = fabs(axis.y) > 0.99f ? float3(1.0f, 0.0f, 0.0f) : float3(0.0f, 1.0f, 0.0f);
                float3 tx = normalize(cross(upHint, axis));
                float3 ty = cross(axis, tx);
                float2 uv = rng.uniform2();
                float3 lightPoint = center + tx * ((uv.x - 0.5f) * w) + ty * ((uv.y - 0.5f) * h);
                float3 toLight = lightPoint - hit.position;
                float dist2 = length_squared(toLight);
                float dist = sqrt(dist2);
                if (dist > 1e-4f) {
                    float3 l = toLight / dist;
                    float cosLight = dot(axis, -l);
                    float nDotL = dot(n, l);
                    if (cosLight > 1e-4f && nDotL > 0.0f) {
                        ray shadowRay(hit.position + n * 0.0015f, l, 0.002f, dist - 0.002f);
                        Hit shadowHit = traceRay(shadowRay, accel, positions, normals, indices, triangleMaterials, uvs, sliceOfVertex,
                                                 holeSlotOfVertex, holeAtlas, dist - 0.002f);
                        if (!shadowHit.valid) {
                            float3 f = diffuseAlbedo / M_PI_F
                                + evalSpecular(m, n, v, l, specF0)
                                + evalCoat(m, n, v, l);
                            float pdf = pickProb * dist2 / max(cosLight * w * h, 1e-6f);
                            样本辐射 += throughput * f * Le * nDotL / max(pdf, 1e-6f)
                            * ptVolumeTransmittance(volumeEmitters, volumeEmitterCount, 介质上界,
                                                    shadowRay.origin, shadowRay.direction, dist, rng, camera.volume.x, camera.volume.y);
                        }
                    }
                }
            } else {
                // 点光 / 聚光：半径为 0 是理想点，否则按小球面均匀采样（柔化阴影）
                float3 lightPoint = center;
                float sphereSolidAngle = 0.0f;
                if (radius > 1e-3f) {
                    float z = 1.0f - 2.0f * rng.uniform();
                    float r = sqrt(max(1.0f - z * z, 0.0f));
                    float phi = 2.0f * M_PI_F * rng.uniform();
                    float3 dirSphere = float3(r * cos(phi), r * sin(phi), z);
                    lightPoint = center + dirSphere * radius;
                    sphereSolidAngle = M_PI_F * radius * radius;
                }
                float3 toLight = lightPoint - hit.position;
                float dist2 = length_squared(toLight);
                float dist = sqrt(dist2);
                if (dist > 1e-4f) {
                    float3 l = toLight / dist;
                    float nDotL = dot(n, l);
                    float falloff = 1.0f;
                    if (kind == PT_LIGHT_SPOT) {
                        // 锥内才发光，边缘按柔和度平滑收
                        float cosDir = dot(axis, -l);
                        float cosCone = clamp(L.axisCosCone.w, -1.0f, 0.9999f);
                        float softness = clamp(L.shape.w, 0.0f, 1.0f);
                        float cosOuter = cosCone - softness * (1.0f - cosCone);
                        falloff = smoothstep(cosOuter, cosCone, cosDir);
                    }
                    if (nDotL > 0.0f && falloff > 1e-4f) {
                        ray shadowRay(hit.position + n * 0.0015f, l, 0.002f, dist - 0.002f);
                        Hit shadowHit = traceRay(shadowRay, accel, positions, normals, indices, triangleMaterials, uvs, sliceOfVertex,
                                                 holeSlotOfVertex, holeAtlas, dist - 0.002f);
                        if (!shadowHit.valid) {
                            float3 f = diffuseAlbedo / M_PI_F
                                + evalSpecular(m, n, v, l, specF0)
                                + evalCoat(m, n, v, l);
                            if (sphereSolidAngle > 0.0f) {
                                // 球光源：立体角 pdf = 选中概率 × dist² / (球面投影立体角)
                                float cosLight = max(dot(normalize(lightPoint - center), -l), 0.05f);
                                float pdf = pickProb * dist2 / max(sphereSolidAngle * cosLight, 1e-6f);
                                样本辐射 += throughput * f * Le * falloff * nDotL / max(pdf, 1e-6f)
                                * ptVolumeTransmittance(volumeEmitters, volumeEmitterCount, 介质上界,
                                                        shadowRay.origin, shadowRay.direction, dist, rng, camera.volume.x, camera.volume.y);
                            } else {
                                // 理想点：辐射强度 I 已含在 Le 里，按平方反比衰减
                                样本辐射 += throughput * f * Le * falloff * nDotL / (dist2 * pickProb)
                                    * ptVolumeTransmittance(volumeEmitters, volumeEmitterCount, 介质上界,
                                                            shadowRay.origin, shadowRay.direction, dist, rng, camera.volume.x, camera.volume.y);
                            }
                        }
                    }
                }
            }
        }

        // ---- 采样下一跳方向 ----
        float diffuseWeight = luminanceOf(diffuseAlbedo);
        float specWeight = luminanceOf(specF0) * m.p2.z + 0.02f;
        float transWeight = transmission * 1.2f;
        float total = diffuseWeight + specWeight + transWeight;
        if (total < 1e-5f) break;

        float pick = rng.uniform() * total;

        if (pick < transWeight) {
            // 透射（玻璃）：按菲涅尔决定折射 / 反射
            float3 refracted;
            float eta = 1.0f / ior;
            bool tir = false;
            float cosI = saturate(dot(n, v));
            float k = 1.0f - eta * eta * (1.0f - cosI * cosI);
            if (k < 0.0f) {
                tir = true;
                refracted = reflect(-v, n);
            } else {
                refracted = normalize(eta * -v + (eta * cosI - sqrt(k)) * n);
            }
            float F = tir ? 1.0f : (0.04f + 0.96f * pow(1.0f - cosI, 5.0f));
            float3 tint = mix(float3(1.0f), baseAlbedo, 0.6f);
            if (rng.uniform() < F) {
                current = ray(hit.position + n * 0.0015f, reflect(-v, n), 0.002f, camera.params.w);
                throughput *= tint;
            } else {
                current = ray(hit.position - n * 0.0015f, refracted, 0.002f, camera.params.w);
                throughput *= tint / max(eta * eta, 0.1f);
            }
            throughput *= total / transWeight;
            lastWasSpecular = true;
            continue;
        }

        if (pick < transWeight + specWeight) {
            // 镜面 lobe
            if (roughness < 0.06f) {
                float3 reflected = reflect(-v, n);
                current = ray(hit.position + n * 0.0015f, reflected, 0.002f, camera.params.w);
            } else {
                float3 sampled = ggxSample(n, roughness, rng);
                if (dot(sampled, v) < 0.0f) sampled = reflect(sampled, n);
                current = ray(hit.position + n * 0.0015f, sampled, 0.002f, camera.params.w);
            }
            float3 tint = float3(1.0f);
            if (m.p1.x > 0.001f) {
                tint = mix(float3(1.0f), thinFilmTint(m.p1.y, m.p1.z, saturate(dot(n, v))), m.p1.x);
            }
            throughput *= mix(float3(1.0f), specF0, 0.85f) * tint * (total / specWeight);
            lastWasSpecular = true;
            continue;
        }

        // 漫反射 lobe：余弦半球采样，cos 项被 pdf 抵掉
        float3 newDir = rng.cosineHemisphere(n);
        throughput *= diffuseAlbedo * (total / diffuseWeight);
        current = ray(hit.position + n * 0.0015f, newDir, 0.002f, camera.params.w);
        lastWasSpecular = false;

        // 俄罗斯轮盘赌：三跳以后按亮度提前收，省算力不掉画质
        if (bounce >= 2u) {
            float q = saturate(luminanceOf(throughput));
            if (rng.uniform() > q) break;
            throughput /= max(q, 0.05f);
        }
    }

        // NaN / Inf 防护：个别采样爆掉不该污染整张累积
        if (any(isnan(样本辐射)) || any(isinf(样本辐射))) {
            样本辐射 = float3(0.0f);
        }
        样本辐射 = clamp(样本辐射, float3(0.0f), float3(60000.0f));
        radiance += 样本辐射;
    }

    // 整帧寄存器和的兜底防护（单样本已各自 clamp 过）
    if (any(isnan(radiance)) || any(isinf(radiance))) {
        radiance = float3(0.0f);
    }

    // ---- G-buffer 一次性写回（逐样本平均，与 beauty 同滤波）----
    // 每个样本在 bounce==0 时都恰好累加一次 albedo 与 normal，所以除以样本数即为抗锯齿后的 aux。
    // albedo 必须落在 [0,1]：基底色经贴图/笔迹后可能 >1，越界会让降噪器把高光当过曝光反照率。
    float 引导样本数 = float(样本数);
    gAlbedo.write(float4(clamp(gAlbedoSum / 引导样本数, float3(0.0f), float3(1.0f)), 1.0f), gid);
    // normal 保持累加和（不在这里归一化）：pack 阶段会 normalize，方向与抗锯齿结果一致，
    // 天空像素写的是"朝向相机"的方向，不会退化成长度 0。
    gNormalDepth.write(float4(gNormalSum, gCamDist), gid);

    // resetAccum 表示新一轮累积：必须把旧的累加和丢掉，
    // 否则重建纹理/重启后分母从 1 重新数、分子却还是几百个样本的和 → 一上来爆白再慢慢变暗。
    // 【为什么不再看 sampleIndex == 0】：自适应采样下同一帧里各像素的样本数并不相等，
    // 分母必须逐像素自增，谁被调度到了谁才 +1；全局序号只用来做 RNG 种子与收敛上限。
    float4 previous = resetAccum != 0u ? float4(0.0f) : accum.read(gid);
    // Neumaier 补偿求和：t = s + x 之后把 (s - t) + x 这一步被舍掉的低位存进 comp，
    // 累加值始终是 sum + comp。x 远小于 s（spp 上千时是常态）也不丢样本。
    float4 comp = resetAccum != 0u ? float4(0.0f) : accumComp.read(gid);
    float3 旧和 = previous.rgb;
    float3 新和 = 旧和 + radiance;
    // |旧和| >= |x| 时误差是 (旧和 - 新和) + x，否则 (x - 新和) + 旧和；select(a,b,c) = c ? b : a
    float3 误差 = select(
        (radiance - 新和) + 旧和,
        (旧和 - 新和) + radiance,
        abs(旧和) >= abs(radiance)
    );
    comp.rgb += 误差;
    previous.rgb = 新和;
    // 分母一次加满：这 N 个样本是一起写回来的，a 必须一次 +N，否则均值会被放大 N 倍
    previous.a += float(样本数);
    accum.write(clamp(previous, float4(0.0f), float4(60000.0f)), gid);
    // 补偿项本身很小，但也要防 NaN；不进主和，所以不做 60000 上限
    if (any(isnan(comp)) || any(isinf(comp))) comp = float4(0.0f);
    accumComp.write(comp, gid);
}

// ------------------------------------------------------------
// 自适应采样：方差/边缘引导的像素压缩队列
// ------------------------------------------------------------
// 目的只有一个：把算力从"已经收敛的平滑区"挪到"还在抖的边缘与高光区"，
// 让静止后画面变干净更快，而完全不改变任何一个像素的期望值 ——
//   · 每个像素是否被调度，只看它【已累积的历史均值】与四邻的差，与这一趟要采的新样本无关；
//     第 k 个样本 X_k 与"是否采它"的决策 D_k 独立 ⇒ E[X_k | D_k = 1] = E[X_k]，样本均值仍无偏；
//   · 累积分母是该像素自己的样本数，被跳过的像素少算，不会把别人拖白白；
//   · 收敛末段（由 Swift 侧控制）退回全网格，把落后的像素补齐到同一目标 spp。
// 也就是说：它只是"什么时候采"，不是"采什么"，也不做任何跨像素的样本复用（那才有偏）。
kernel void ptAdaptiveQueue(texture2d<float, access::read> accum [[texture(0)]],
                            device uint2 *queue [[buffer(0)]],
                            device atomic_uint *counter [[buffer(1)]],
                            constant uint &targetSpp [[buffer(2)]],
                            constant float &edgeThreshold [[buffer(3)]],
                            constant float &floorProbability [[buffer(4)]],
                            constant uint &frameSeed [[buffer(5)]],
                            uint2 gid [[thread_position_in_grid]])
{
    uint width = accum.get_width();
    uint height = accum.get_height();
    if (gid.x >= width || gid.y >= height) return;

    float4 本像素 = accum.read(gid);
    float 样本数 = 本像素.a;
    if (样本数 >= float(targetSpp)) return;   // 已达本轮目标：这个像素一次都不再采

    float3 均值 = 样本数 > 0.0f ? 本像素.rgb / 样本数 : float3(0.0f);
    float 亮度 = luminanceOf(均值);

    // 四邻均值：只读十字邻域，够判断"这里是不是细节/边缘"，比二阶矩便宜得多
    float3 邻和 = float3(0.0f);
    uint 邻数 = 0u;
    for (uint i = 0u; i < 4u; ++i) {
        int2 偏移 = int2(i == 0u ? -1 : (i == 1u ? 1 : 0), i == 2u ? -1 : (i == 3u ? 1 : 0));
        int2 坐标 = clamp(int2(gid) + 偏移, int2(0), int2(int(width) - 1, int(height) - 1));
        float4 邻像素 = accum.read(uint2(坐标));
        if (邻像素.a > 0.0f) {
            邻和 += 邻像素.rgb / 邻像素.a;
            邻数 += 1u;
        }
    }
    float 邻亮度 = 邻数 > 0u ? luminanceOf(邻和 / float(邻数)) : 亮度;

    // 相对亮度差：平滑区趋近 0，边缘/高光跳变处趋近 1
    float 尺度 = max(max(亮度, 邻亮度), 1e-3f);
    float 差异 = fabs(亮度 - 邻亮度) / 尺度;

    // 差异越大越必采；保底概率保证平滑区也会被慢慢推进，不会永远停在低样本数
    float 概率 = clamp(差异 / max(edgeThreshold, 1e-4f), floorProbability, 1.0f);

    // 逐像素抖动：同一像素在不同帧拿到不同随机数，避免"要么一直采要么一直不采"的锁死
    uint h = (gid.x * 1973u + gid.y * 9277u) ^ (frameSeed * 26699u) ^ 0x9E3779B9u;
    h ^= h >> 16; h *= 0x7feb352du; h ^= h >> 15; h *= 0x846ca68bu; h ^= h >> 16;
    float 掷骰 = float(h & 0xFFFFFFu) / float(0x1000000u);
    if (掷骰 >= 概率) return;

    uint 槽 = atomic_fetch_add_explicit(counter, 1u, memory_order_relaxed);
    queue[槽] = gid;
}

// 把原子计数换算成间接派发参数：组数 = ceil(数量 / 每线程组线程数)。
// 单独一趟 1 线程的内核，是因为组数必须由 GPU 侧算出来 —— CPU 这一帧拿不到计数。
kernel void ptAdaptiveArgs(device const uint *counter [[buffer(0)]],
                           device uint *dispatchArgs [[buffer(1)]],
                           device uint *limit [[buffer(2)]],
                           constant uint &threadsPerGroup [[buffer(3)]])
{
    uint 数量 = counter[0];
    limit[0] = 数量;
    uint 组数 = (数量 + threadsPerGroup - 1u) / max(threadsPerGroup, 1u);
    dispatchArgs[0] = 组数;
    dispatchArgs[1] = 1u;
    dispatchArgs[2] = 1u;
    dispatchArgs[3] = 1u;
}

// ------------------------------------------------------------
// 色调映射
// ------------------------------------------------------------
static inline float3 acesFilm(float3 x) {
    const float a = 2.51f;
    const float b = 0.03f;
    const float c = 2.43f;
    const float d = 0.59f;
    const float e = 0.14f;
    return saturate((x * (a * x + b)) / (x * (c * x + d) + e));
}

// ============================================================
// 眩光辉光（Glare / Bloom）—— 屏幕空间后处理
//
// 对照 Blender 合成器 Glare 节点的 Bloom 模式（本地源码
// source/blender/compositor/shaders/compositor_glare_{highlights,bloom_downsample,bloom_upsample,mix}.glsl）：
//   ① highlights：按亮度把超过阈值的部分提出来（阈值附近 smoothstep 淡入，超亮做上限压制）
//   ② bloom_downsample：逐级 13-tap 下采样（Call of Duty: AW 的 twin filter，权重含 Karis 抗萤火虫）
//   ③ bloom_upsample：逐级 3x3 tent 上采样并累加回上一级，多级叠加 ≈ 大半径高斯
//   ④ mix：原图 + 眩光 × 强度
//
// 为什么做成屏幕空间后处理、而不是在光照里给自发光画光圈：
//   · 节点自发光与绘画自发光最终都只是 HDR 里的高亮像素，这里统一按"亮度超阈值就发光"，
//     两条来源自动都有，调用方只需要递一张 HDR 图，不必区分来源；
//   · 只有屏幕空间后处理才能让光溢到物体轮廓**外面**——表面在模型上发光，光晕在模型外。
// ============================================================

struct PTGlowParams {
    float threshold;      // 起辉亮度（1.0 ≈ 白点；按曝光后的线性 HDR 算）
    float smoothness;     // 阈值平滑宽度，避免相机一动高光边缘就跳闪
    float maxBrightness;  // 单像素亮度上限，压制萤火虫把整屏烧白
    float strength;       // 眩光叠加强度（仅 CPU 侧读取，GPU 侧保留只为对齐布局）
};

constexpr sampler ptGlowSampler(coord::normalized, filter::linear, address::clamp_to_edge);

/// Blender highlights 的阈值提取（在亮度上做，等价于从 HSV 的 V 提取）
static inline float3 ptExtractHighlights(float3 hdr, constant PTGlowParams &p) {
    float lum = luminanceOf(hdr);
    if (!(lum > 1e-5f)) return float3(0.0f);
    float 上限 = max(p.maxBrightness, p.threshold + 1e-3f);
    float 压后 = min(lum, 上限);
    float excess = 压后 - p.threshold;
    if (excess <= 0.0f) return float3(0.0f);
    // 阈值附近淡入：刚过阈值的像素从 0 平滑长起来，避免噪点在阈值上下闪烁
    excess *= smoothstep(0.0f, max(p.smoothness, 1e-4f), excess);
    return hdr * (excess / max(lum, 1e-5f));
}

/// 色调映射前把眩光叠回去（辉光图是内部渲染分辨率，用归一化 uv 双线性放大）
///
/// selfMask = 屏蔽自身（0…1）：
///   0 = 直接整体叠加 —— 模型表面自己也会被辉光提亮，看起来像「整块糊了一层光」；
///   1 = 先从光晕里减掉这个像素本来就有的亮度再取正 —— 表面自发光的地方 hdr 本来就亮，
///       模糊摊薄后的光晕比它还暗，减完是 0，表面保持原来的自发光效果不被洗亮；
///       轮廓外的背景 hdr 接近 0，光晕全留下，于是只有模型外面发光。
/// 这里的 hdr 和光晕图都已经是「曝光后的线性 HDR」，同尺度相减才有物理意义。
static inline float3 ptApplyGlow(float3 hdr, texture2d<float> glowTex,
                                 float strength, float selfMask, float2 uv) {
    if (!(strength > 0.0f)) return hdr;
    float3 g = glowTex.sample(ptGlowSampler, uv).rgb * strength;
    if (any(isnan(g)) || any(isinf(g))) return hdr;
    if (selfMask > 0.0f) {
        g = max(g - hdr * selfMask, float3(0.0f));
    }
    return hdr + g;
}

/// 源 = 累积缓冲：rgb 是样本和，a 是样本数
kernel void ptGlowFromAccum(texture2d<float, access::read> accum [[texture(0)]],
                            texture2d<float, access::write> outTex [[texture(1)]],
                            constant PTGlowParams &p [[buffer(0)]],
                            constant float &exposure [[buffer(1)]],
                            uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) return;
    float4 packed = accum.read(gid);
    float3 hdr = packed.rgb / max(packed.a, 1.0f) * exposure;
    if (any(isnan(hdr)) || any(isinf(hdr))) hdr = float3(0.0f);
    outTex.write(float4(ptExtractHighlights(hdr, p), 1.0f), gid);
}

/// 源 = OIDN 输出的紧密 float3（线性 HDR，未乘曝光）
kernel void ptGlowFromBuffer(device const float *hdrIn [[buffer(0)]],
                             texture2d<float, access::write> outTex [[texture(1)]],
                             constant PTGlowParams &p [[buffer(2)]],
                             constant float &exposure [[buffer(3)]],
                             constant uint2 &srcSize [[buffer(4)]],
                             uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) return;
    uint2 s = min(gid, max(srcSize, uint2(1u)) - 1u);
    uint idx = (s.y * srcSize.x + s.x) * 3u;
    float3 hdr = float3(hdrIn[idx + 0u], hdrIn[idx + 1u], hdrIn[idx + 2u]) * exposure;
    if (any(isnan(hdr)) || any(isinf(hdr))) hdr = float3(0.0f);
    outTex.write(float4(ptExtractHighlights(hdr, p), 1.0f), gid);
}

/// 13-tap 下采样（输出尺寸是输入的一半）。权重照抄 Blender 的 SIMPLE_AVERAGE：
/// 中心与四个近角各 4/32、上下左右远处各 2/32、四角远处各 1/32，和恰好为 1。
kernel void ptGlowDown(texture2d<float> src [[texture(0)]],
                       texture2d<float, access::write> dst [[texture(1)]],
                       uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float2 outSize = float2(dst.get_width(), dst.get_height());
    float2 uv = (float2(gid) + 0.5f) / outSize;
    float2 px = 1.0f / float2(src.get_width(), src.get_height());

    float4 c   = src.sample(ptGlowSampler, uv);
    float4 uln = src.sample(ptGlowSampler, uv + px * float2(-1.0f,  1.0f));
    float4 urn = src.sample(ptGlowSampler, uv + px * float2( 1.0f,  1.0f));
    float4 lln = src.sample(ptGlowSampler, uv + px * float2(-1.0f, -1.0f));
    float4 lrn = src.sample(ptGlowSampler, uv + px * float2( 1.0f, -1.0f));
    float4 lf  = src.sample(ptGlowSampler, uv + px * float2(-2.0f,  0.0f));
    float4 rf  = src.sample(ptGlowSampler, uv + px * float2( 2.0f,  0.0f));
    float4 uf  = src.sample(ptGlowSampler, uv + px * float2( 0.0f,  2.0f));
    float4 df  = src.sample(ptGlowSampler, uv + px * float2( 0.0f, -2.0f));
    float4 ulf = src.sample(ptGlowSampler, uv + px * float2(-2.0f,  2.0f));
    float4 urf = src.sample(ptGlowSampler, uv + px * float2( 2.0f,  2.0f));
    float4 llf = src.sample(ptGlowSampler, uv + px * float2(-2.0f, -2.0f));
    float4 lrf = src.sample(ptGlowSampler, uv + px * float2( 2.0f, -2.0f));

    float4 r = (4.0f / 32.0f) * c
             + (4.0f / 32.0f) * (uln + urn + lln + lrn)
             + (2.0f / 32.0f) * (lf + rf + uf + df)
             + (1.0f / 32.0f) * (ulf + urf + llf + lrf);
    dst.write(r, gid);
}

/// 3x3 tent 上采样，并累加进目标级（目标尺寸是源的两倍）。
/// 反复上采样累加是辉光能铺到模型轮廓外面一圈的关键。
kernel void ptGlowUp(texture2d<float> src [[texture(0)]],
                     texture2d<float, access::read_write> dst [[texture(1)]],
                     uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float2 outSize = float2(dst.get_width(), dst.get_height());
    float2 uv = (float2(gid) + 0.5f) / outSize;
    float2 px = 1.0f / outSize;

    float4 u = (4.0f / 16.0f) * src.sample(ptGlowSampler, uv)
             + (2.0f / 16.0f) * (src.sample(ptGlowSampler, uv + px * float2(-1.0f,  0.0f))
                               + src.sample(ptGlowSampler, uv + px * float2( 1.0f,  0.0f))
                               + src.sample(ptGlowSampler, uv + px * float2( 0.0f,  1.0f))
                               + src.sample(ptGlowSampler, uv + px * float2( 0.0f, -1.0f)))
             + (1.0f / 16.0f) * (src.sample(ptGlowSampler, uv + px * float2(-1.0f,  1.0f))
                               + src.sample(ptGlowSampler, uv + px * float2( 1.0f,  1.0f))
                               + src.sample(ptGlowSampler, uv + px * float2(-1.0f, -1.0f))
                               + src.sample(ptGlowSampler, uv + px * float2( 1.0f, -1.0f)));

    dst.write(dst.read(gid) + u, gid);
}

kernel void ptResolve(texture2d<float, access::read> accum [[texture(0)]],
                      texture2d<float, access::write> output [[texture(1)]],
                      texture2d<float> glowTex [[texture(2)]],
                      texture2d<float, access::read> accumComp [[texture(3)]],
                      constant float &invSampleCount [[buffer(0)]],
                      constant float &exposure [[buffer(1)]],
                      constant float &glowStrength [[buffer(2)]],
                      constant float &glowSelfMask [[buffer(3)]],
                      uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;

    // 累积缓冲可能是低分辨率（省算力），这里做一次最近邻放大
    float2 uv = (float2(gid) + 0.5f) / float2(output.get_width(), output.get_height());
    uint2 src = uint2(uv * float2(accum.get_width(), accum.get_height()));
    src = min(src, uint2(accum.get_width() - 1, accum.get_height() - 1));

    float4 packed = accum.read(src);
    float samples = max(packed.a, 1.0f);
    // 主和 + 补偿项才是真实积分值（Neumaier 的终值口径）
    float3 精确和 = max(packed.rgb + accumComp.read(src).rgb, float3(0.0f));
    float3 hdr = 精确和 / samples * exposure;

    // 眩光：屏幕空间叠回（节点自发光 / 绘画自发光都在这张辉光图里，无需区分来源）
    hdr = ptApplyGlow(hdr, glowTex, glowStrength, glowSelfMask, uv);

    float3 mapped = acesFilm(hdr);
    // 【别再 pow(1/2.2)】Narkowicz 这条 ACES 拟合曲线输出的就是"显示参考"值
    // （已经把线性 HDR 压到 0~1 并带上了 sRGB 编码的非线性），
    // 再套一次 pow(1/2.2) 等于二次 gamma：0.1 的线性亮度会从 32/255 被抬到 99/255，
    // 暗部整片提亮 → 画面永远蒙着一层淡淡的灰。这就是"淡灰"的根因，直接写出去即可。
    output.write(float4(mapped, 1.0f), gid);
}

// ============================================================
// OpenImageDenoise (OIDN) 通路
// OIDN 只吃"线性 HDR 彩色 + albedo + normal"三张紧密 float3 图，
// 所以这里把累积缓冲解包成线性缓冲（顺便做萤火虫压制），
// 降噪完再由 ptResolveOIDN 做 ACES 色调映射。
// OIDN 是训练过的神经网络降噪器，
// 2~4 spp 的输入就能出干净的最终画面，不需要靠几百帧慢慢收敛。
// ============================================================

/// 累积缓冲（rgb = 样本和, a = 样本数）→ OIDN 需要的三张线性图（紧密 float3）
kernel void ptPackOIDN(texture2d<float, access::read> accum [[texture(0)]],
                       texture2d<float, access::read> gNormalDepth [[texture(1)]],
                       texture2d<float, access::read> gAlbedo [[texture(2)]],
                       texture2d<float, access::read> accumComp [[texture(3)]],
                       device float *colorOut [[buffer(0)]],
                       device float *albedoOut [[buffer(1)]],
                       device float *normalOut [[buffer(2)]],
                       constant float &luminosityCeiling [[buffer(3)]],
                       uint2 gid [[thread_position_in_grid]])
{
    uint width = accum.get_width();
    uint height = accum.get_height();
    if (gid.x >= width || gid.y >= height) return;

    float4 packed = accum.read(gid);
    float samples = max(packed.a, 1.0f);
    float3 hdr = max(packed.rgb + accumComp.read(gid).rgb, float3(0.0f)) / samples;
    if (any(isnan(hdr)) || any(isinf(hdr))) hdr = float3(0.0f);

    // 萤火虫压制：OIDN 同样会把孤立超亮点当成真实细节保留下来，
    // 所以入口这一道 clamp 不能省。
    if (luminosityCeiling > 0.0f) {
        int maxX = int(width) - 1;
        int maxY = int(height) - 1;
        float refSum = 0.0f;
        int refCount = 0;
        for (int dy = -1; dy <= 1; ++dy) {
            for (int dx = -1; dx <= 1; ++dx) {
                int px = clamp(int(gid.x) + dx, 0, maxX);
                int py = clamp(int(gid.y) + dy, 0, maxY);
                float4 p = accum.read(uint2(px, py));
                float3 v = max(p.rgb + accumComp.read(uint2(px, py)).rgb, float3(0.0f)) / max(p.a, 1.0f);
                if (any(isnan(v)) || any(isinf(v))) continue;
                refSum += luminanceOf(v);
                refCount += 1;
            }
        }
        float refLuma = refCount > 0 ? refSum / float(refCount) : 0.0f;
        if (refLuma > 1e-4f) hdr = min(hdr, float3(refLuma * luminosityCeiling));
    }
    hdr = clamp(hdr, float3(0.0f), float3(60000.0f));

    // 法线：追踪内核已按样本平均，天空像素给的是"朝向相机"的方向；
    // 这里只剩零长度兜底（极端的退化情况），不再负责给天空编法线。
    float4 nrm = gNormalDepth.read(gid);
    float3 n = nrm.rgb;
    n = (dot(n, n) < 1e-6f) ? float3(0.0f, 0.0f, 1.0f) : normalize(n);

    float3 alb = gAlbedo.read(gid).rgb;
    if (any(isnan(alb)) || any(isinf(alb))) alb = float3(0.0f);
    // albedo 必须在 [0,1]：内核已 clamp，这里再兜一层，防止任何路径漏网把反照率抬高。
    alb = clamp(alb, float3(0.0f), float3(1.0f));

    uint idx = (gid.y * width + gid.x) * 3u;
    colorOut[idx + 0u] = hdr.x;
    colorOut[idx + 1u] = hdr.y;
    colorOut[idx + 2u] = hdr.z;
    albedoOut[idx + 0u] = alb.x;
    albedoOut[idx + 1u] = alb.y;
    albedoOut[idx + 2u] = alb.z;
    normalOut[idx + 0u] = n.x;
    normalOut[idx + 1u] = n.y;
    normalOut[idx + 2u] = n.z;
}

/// OIDN 输出（线性 HDR）→ ACES 色调映射 → drawable
kernel void ptResolveOIDN(device const float *hdrIn [[buffer(0)]],
                          texture2d<float, access::write> output [[texture(1)]],
                          texture2d<float> glowTex [[texture(3)]],
                          constant float &exposure [[buffer(1)]],
                          constant uint2 &srcSize [[buffer(2)]],
                          constant float &glowStrength [[buffer(3)]],
                          constant float &glowSelfMask [[buffer(4)]],
                          uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;

    // 降噪缓冲是内部渲染分辨率，可能是低分辨率，这里做最近邻放大
    float2 uv = (float2(gid) + 0.5f) / float2(output.get_width(), output.get_height());
    uint2 src = uint2(uv * float2(srcSize));
    src = min(src, srcSize - 1u);

    uint idx = (src.y * srcSize.x + src.x) * 3u;
    float3 hdr = float3(hdrIn[idx + 0u], hdrIn[idx + 1u], hdrIn[idx + 2u]) * exposure;
    if (any(isnan(hdr)) || any(isinf(hdr))) hdr = float3(0.0f);

    // 眩光（与未降噪通路同一套，降低"开不开降噪辉光表现不一致"的割裂感）
    hdr = ptApplyGlow(hdr, glowTex, glowStrength, glowSelfMask, uv);

    float3 mapped = acesFilm(hdr);
    // 同上：ACES 拟合已是显示参考值，直接写出，不要再做二次 gamma
    output.write(float4(mapped, 1.0f), gid);
}
