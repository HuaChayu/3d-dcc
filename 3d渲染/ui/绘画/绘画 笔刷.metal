#include <metal_stdlib>
using namespace metal;

// MARK: - 笔刷投影
//
// 笔迹不是「在 UV 空间里画圆」，而是先在物体表面上撒点、再把每个点投影到 UV 上。
// 这里只负责最后一步：每个 splat 一个屏幕对齐 quad，落在 UV 图集的对应位置。
// 一次 drawCall 画完几万个点（instance），所以拖一条长笔画也不会掉帧。

struct PaintSplat {
    float2 center;   ///< uv 中心
    float2 radius;   ///< uv 半径（各向异性，用于补偿两极挤压）
    float4 color;    ///< rgb = 颜色，a = 强度
    float4 params;   ///< x = 硬度
    float4 bounds;   ///< 本格矩形 (minX, minY, maxX, maxY)，片元按它裁掉出格像素
    float4 brushRef; ///< xy = 这个 splat 圆心在「整支笔刷圆盘」里的坐标（±1 = 笔刷边缘），z = 笔刷自身在 uv 空间的半径（0 = 未知）
    float4 brushJac; ///< 切平面→uv 雅可比（1/笔刷半径）：xy = uv.x 走一格，zw = uv.y 走一格（只做兜底）
    // 精确路径：三角形的 uv 顶点 + 世界顶点 + 整支笔刷的贴表面基 + 落笔点。
    // 片元由像素 uv 反解重心坐标插出世界位置，再用统一基算圆盘坐标 ——
    // 世界位置在接缝两侧本来就连续，所以图案不会出现「折弯 + 间隔变疏」的断层。
    float4 triUV0;   ///< xy = t0, zw = t1（解缠后）
    float4 triUV1;   ///< xy = t2
    float4 world0;   ///< xyz = 世界顶点 A，w = 1 表示几何可信
    float4 world1;
    float4 world2;
    float4 basis0;   ///< 世界空间，已除笔刷半径
    float4 basis1;
    float4 originW;  ///< 落笔点世界坐标，w = 1 表示可信
};

struct PaintLayerGPU {
    float opacity;
    int blend;       ///< 0 正常 / 1 正片叠底 / 2 叠加
    int visible;
    int reserved;
};

struct PaintSplatInOut {
    float4 position [[position]];
    float2 corner;
    float4 color;
    float4 params;
    float2 seed;    ///< 保留（旧版遮罩抖动用，现已按整支笔刷统一采样）
    float2 brush;   ///< 这个顶点在「整支笔刷圆盘」里的位置，±1 = 笔刷边缘
    float2 uv;      ///< 这个顶点在图集里的真实 uv（不夹格边），片元靠它裁掉出格的部分
    float4 bounds;  ///< 本格的有效范围 (lo.x, lo.y, hi.x, hi.y)
    // 精确映射用的三角形数据：每个顶点都填同一份，插值后仍是常量
    float4 triUV0;
    float4 triUV1;
    float4 world0;
    float4 world1;
    float4 world2;
    float4 basis0;
    float4 basis1;
    float4 originW;
};

/// 这个像素在「整支笔刷圆盘」里的坐标（±1 = 笔刷边缘）。
///
/// 主路径：像素 uv → 本片三角形重心坐标 → 插出世界位置 → 用整支笔刷统一的贴表面基算。
/// 世界位置在 UV 接缝两侧本来就是连续的，所以这里算出来的图案也连续 ——
/// 以前拿「本片三角形的 j」把 uv 偏移线性换成圆盘坐标，隔壁三角形的 uv 密度一变，
/// 图案尺度就跟着跳：条纹在接缝处折弯、间隔忽然变疏，正是这么来的。
///
/// 兜底：几何不可信（退化三角形）时才用顶点插值出来的 brush。
inline float2 paintBrushPoint(PaintSplatInOut in, thread bool &ok) {
    ok = true;
    if (in.world0.w > 0.5 && in.originW.w > 0.5) {
        float2 t0 = in.triUV0.xy;
        float2 t1 = in.triUV0.zw;
        float2 t2 = in.triUV1.xy;
        float2 e1 = t1 - t0;
        float2 e2 = t2 - t0;
        float det = e1.x * e2.y - e1.y * e2.x;
        if (abs(det) > 1e-18) {
            // 像素 uv 和这个三角形的 uv 顶点之间差着整数个格宽（接缝解缠 + 环回的结果）
            float2 span = in.bounds.zw - in.bounds.xy;
            float2 r = in.uv - t0;
            if (span.x > 1e-4 && span.y > 1e-4) {
                r -= round(r / span) * span;
            } else {
                r -= round(r);
            }
            float bu = (r.x * e2.y - r.y * e2.x) / det;
            float bv = (e1.x * r.y - e1.y * r.x) / det;
            // 只认真正落在这片三角形里的像素。
            // 一个 splat 的 quad 会比它那片三角形大，越到隔壁三角形时，
            // 反解出来的世界位置是「这片三角形所在平面的延伸」，跟隔壁真实表面差得远；
            // 隔壁自己也有 splat，两边算出的世界位置不一致，图案相位就各错一遍，
            // 叠在一起正是「局部糊成一团」。隔壁交给隔壁自己的 splat 画，这里只画自己那份。
            // 留 5% 容差，避免边上的像素两边都嫌自己不属于它而漏掉。
            const float 越界容差 = 0.05;
            if (bu < -越界容差 || bv < -越界容差 || bu + bv > 1.0 + 越界容差) {
                ok = false;
                return float2(0.0);
            }
            float3 P = in.world0.xyz
                     + bu * (in.world1.xyz - in.world0.xyz)
                     + bv * (in.world2.xyz - in.world0.xyz);
            float3 Q = P - in.originW.xyz;
            return float2(dot(Q, in.basis0.xyz), dot(Q, in.basis1.xyz));
        }
    }
    return in.brush;
}

/// 这个片元是不是已经跑出自己那一格了。
///
/// 顶点侧不再把 quad 夹进格内 —— 夹位置却不夹 corner / brush，等于把一个跨缝 splat
/// 的图案硬压进一条窄带里：缝边上斜纹被挤扁、被切断，正是这么来的。
/// 现在 quad 该多大就多大，越出本格的部分在这里丢掉，既不污染邻格、图案又不失真。
inline bool paintOutOfCell(PaintSplatInOut in) {
    float2 lo = in.bounds.xy;
    float2 hi = in.bounds.zw;
    if (hi.x - lo.x <= 1e-5 || hi.y - lo.y <= 1e-5) return false;
    // 半像素容差：缝上正好压边的像素不要因为浮点抖动整颗丢掉
    const float eps = 0.0006;
    return in.uv.x < lo.x - eps || in.uv.x > hi.x + eps ||
           in.uv.y < lo.y - eps || in.uv.y > hi.y + eps;
}

struct PaintUniforms {
    int mode;         ///< 0 绘画 / 1 擦除 / 2 镂空（与 Swift 侧 PaintMode.rawValue 对齐）
    int useMask;      ///< 0 = 没用遮罩（绑的是 1×1 白图），1 = 用遮罩
    int maskInvert;   ///< 1 = 反转：遮罩数据照旧传，只在采样后把 1 和 0 对调
    float maskScale;  ///< 遮罩缩放：1 = 原大小，>1 图案变大
    float maskRot;    ///< 遮罩旋转，弧度
    float2 maskOffset;///< 遮罩平移，单位是「笔刷边长」的比例（1 = 挪一整个笔刷）
};

/// 遮罩采样的唯一入口。
///
/// 反转不是另一条管线、也不是第二张纹理 —— 它只是「同一个采样结果取反」，
/// 所以放在这一处，两条片元（上色/擦除、镂空）都调它，谁也不会漏掉开关。
inline float sampleMask(texture2d<float> tex, sampler s, float2 uv, constant PaintUniforms &u) {
    // 没选遮罩 = 整笔实心。此处必须提前返回 1，不能让反转把那张 1×1 白图翻成 0，
    // 否则用户开着反转但没选图案时，一笔都画不出来
    if (u.useMask == 0) return 1.0;

    // 缩放/旋转/平移只改「从哪儿取」：把采样坐标做一次逆变换。
    // 图案本身、纹理、管线都不动 —— 和反转一样，是传输层的参数，不是新图案。
    // 正向是「先缩放、再旋转、再平移」；采样取逆：p' = (1/scale) · R(-θ) · (p - offset)
    if (u.maskScale != 1.0 || u.maskRot != 0.0 ||
        u.maskOffset.x != 0.0 || u.maskOffset.y != 0.0) {
        float2 p = uv - 0.5 - u.maskOffset;
        float th = -u.maskRot;
        float c = cos(th), sn = sin(th);
        float2 q = float2(p.x * c - p.y * sn, p.x * sn + p.y * c) / max(u.maskScale, 0.01);
        uv = q + 0.5;
    }

    float m = tex.sample(s, uv).r;
    if (u.maskInvert != 0) m = 1.0 - m;

    // 遮罩图之外一律没有东西 —— 反转也一样。
    // 这里有个只在缩小图案时才露头的坑：maskScale < 1（图案变小）时，
    // 上面的逆变换要把坐标放大 1/scale 倍，[0,1] 的画布被反推到 [0,1] 之外好几倍；
    // 采样器是 clamp_to_edge，出界处会一直取最边上那一列/一行像素拉长，
    // 于是在笔刷圆里看到图案外沿长出一圈放射状条纹，一路溢出到遮罩图外面。
    // 放大（maskScale > 1）时坐标只会往中间收、根本不出界，所以那时看着一切正常。
    // 因子放在取反之后：图外是「没有遮罩图的地方」，无论反转与否都空着。
    float2 到边 = min(uv, 1.0 - uv);
    m *= smoothstep(0.0, 0.004, min(到边.x, 到边.y));

    return m;
}

vertex PaintSplatInOut paintSplatVertex(uint vid [[vertex_id]],
                                        uint iid [[instance_id]],
                                        constant PaintSplat *splats [[buffer(0)]])
{
    // triangleStrip 的四个角，按 (-1,-1)(1,-1)(-1,1)(1,1) 排
    const float2 corners[4] = {
        float2(-1.0, -1.0), float2(1.0, -1.0),
        float2(-1.0,  1.0), float2(1.0,  1.0)
    };
    float2 c = corners[vid];
    PaintSplat s = splats[iid];
    // 先把这个 splat 压回它所属的那一格，再铺 quad：
    // 笔刷打到模型边缘（球的极点扇、圆柱盖外圈、接缝）时，三角形的 UV 面积被压扁，
    // 补偿出来的半径能远大于一格，不夹就会一次糊满整张图集 —— 表现为"整个模型被染色"。
    // 圆心压在格内（CPU 侧已经按格宽取模环回过），但 quad **不夹**到格边。
    // 以前这里把四个角夹进 [lo, hi]，位置被压扁了，corner 和 brush 却还是原样，
    // 结果是一个跨缝 splat 的图案被硬塞进缝边那条窄带 —— 缝上斜纹被切断、被挤歪，
    // 正是「接缝一条直缝、两侧图案对不上」的来源。
    // 现在几何该多大就多大，越出本格的部分由片元 paintOutOfCell 丢掉：
    // 既不污染邻格，图案尺度也完全不走形；对面那半边由 CPU 补写的副本负责。
    float2 uv = s.center + c * s.radius;

    // 遮罩要贴在「整支笔刷」上，不是贴在「每个 splat」上。
    // 一个笔刷圆盘里有几十上百个 splat，若每个都拿自己的 quad 角坐标去采遮罩，
    // 等于同一张图案被盖了几十遍又互相错开 —— 叠加完就是一团灰，还比笔刷大一圈。
    //
    // 换算是「uv 偏移 → 笔刷圆盘坐标」，用的是 splat 自带的雅可比：
    //   brush = j1 · Δu + j2 · Δv
    // j 来自这一小片表面（切平面基 × uv 雅可比），所以图案是**贴在表面上**的：
    // 面转过去，图案跟着转；斜面被压扁，图案跟着压扁。
    // 旧做法是 Δuv / 笔刷uv半径，等于把图案摆在 uv 轴上，跟表面朝向无关 ——
    // 那才叫「永远贴视口/贴 UV」。
    //
    // 基准点改成「这个 splat 自己的圆心」：brushRef.xy 是 CPU 侧按世界位移投到贴表面
    // 基上算出来的精确圆盘坐标。以前这里是 uv - 命中点uv，再乘这个三角形的局部 j ——
    // j 只在命中点附近的一小片里成立，离开几格 uv（球的拉长端、极点、被拉伸缩放过的
    // 模型尤其明显）线性外推就越偏越远，同一笔里几十个 splat 各算各的，叠完图案错位、
    // 糊成一团，而且越远离落笔点越糊、边界越来越不清。现在只剩 splat 内部那一小步
    // 线性换算，误差不再累积，图案一律是笔刷圆盘里那一个，跟表面怎么拉伸无关。
    float2 brush = s.brushRef.xy;
    float2 dd = uv - s.center;
    // uv 在接缝处会折回，差的是「整整一格」而不是 1：按格的宽高就近对齐，
    // 否则缝两侧的 splat 会被甩到图集另一头，图案在缝上直接断成两截。
    // 原来写死 round(dd)（周期 = 1）只是因为单格图集里一格恰好≈整图，多格图集会整体错位。
    float2 span = s.bounds.zw - s.bounds.xy;
    if (span.x > 1e-4 && span.y > 1e-4) {
        dd -= round(dd / span) * span;
    } else {
        dd -= round(dd);
    }
    float jacLen = abs(s.brushJac.x) + abs(s.brushJac.y) + abs(s.brushJac.z) + abs(s.brushJac.w);
    if (jacLen > 1e-12) {
        brush += float2(dd.x * s.brushJac.x + dd.y * s.brushJac.z,
                        dd.x * s.brushJac.y + dd.y * s.brushJac.w);
    } else if (s.brushRef.z > 1e-9) {
        // 没有雅可比（老数据/退化三角形）才退回各向同性
        brush += dd / s.brushRef.z;
    }

    PaintSplatInOut out;
    // uv → NDC：v 向上翻，让 uv.y = 0 落在纹理第一行，与 PT 里 sample 的约定一致
    out.position = float4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, 0.0, 1.0);
    out.corner = c;
    out.color = s.color;
    out.params = s.params;
    out.seed = s.center;
    out.brush = brush;
    out.uv = uv;
    out.bounds = s.bounds;
    out.triUV0 = s.triUV0;
    out.triUV1 = s.triUV1;
    out.world0 = s.world0;
    out.world1 = s.world1;
    out.world2 = s.world2;
    out.basis0 = s.basis0;
    out.basis1 = s.basis1;
    out.originW = s.originW;
    return out;
}

fragment float4 paintSplatFragment(PaintSplatInOut in [[stage_in]],
                                   constant PaintUniforms &u [[buffer(0)]],
                                   texture2d<float> maskTex [[texture(0)]])
{
    // 越出自己那一格的像素不落笔（quad 不再夹格，改由这里裁）
    if (paintOutOfCell(in)) {
        discard_fragment();
        return float4(0.0);
    }
    float d = length(in.corner);
    if (d > 1.0) {
        discard_fragment();
        return float4(0.0);
    }
    // 硬度决定边缘过渡宽度：0.55 表示从 55% 半径处开始软化到边缘
    float hardness = clamp(in.params.x, 0.0, 0.995);
    float weight = 1.0 - smoothstep(hardness, 1.0, d);

    // 笔刷圆盘坐标（按世界位置在片元里精确解，接缝两侧连续）：|圆盘| <= 1 才是笔刷范围
    bool 属于本片 = true;
    float2 圆盘 = paintBrushPoint(in, 属于本片);
    if (!属于本片) {
        discard_fragment();
        return float4(0.0);
    }
    float 笔刷距 = length(圆盘);

    float m = 1.0;
    if (u.useMask != 0) {
        // 图案按「整支笔刷」采样一次，跟面板画板里看到的一模一样；
        // 不再逐 splat 抖开 —— 抖动会让重叠的 splat 采到图案的不同部位，叠完就糊成一团
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        m = sampleMask(maskTex, s, 圆盘 * 0.5 + 0.5, u);
        // 笔刷圆外不要有笔迹：图案满幅铺在 uv 上，不裁的话每个 splat 都会在圈外再画一圈
        weight *= 1.0 - smoothstep(0.97, 1.0, 笔刷距);
        if (u.mode == 2) {
            // 镂空要「有就是有」：把图案硬切成 0/1，才有破布、磨损那种碎裂轮廓；
            // 用软 alpha 过渡只会挖出一片半透明麻点
            m = smoothstep(0.35, 0.62, m);
        }
    } else if (u.mode == 2) {
        // 没选遮罩的镂空 = 硬边圆孔，同样不要中间那圈软过渡
        weight = 1.0;
    }

    float a = weight * m * in.color.a;
    if (a <= 0.0005) {
        discard_fragment();
    }
    return float4(in.color.rgb, a);
}

// MARK: - 覆盖度场（一笔一次）
//
// 为什么需要这一步：笔刷在表面上撒的是几千个彼此重叠的 splat，每个 splat 的 alpha
// 都带 falloff 和图案。若直接把每个 splat over 叠加到图层上，同一个像素会被几十个
// splat 反复覆盖，alpha 很快累积到 1 —— 图案的明暗差别被抹平，笔迹就成了一团
// 比笔刷还大的纯色（斜纹、噪点、破布纹理全都消失）。实测间距 0.3R、半径 R 时
// 重叠约 44 次，0.5 的 alpha 叠 44 次后是 0.9999。
//
// 正确做法：先把「这一笔的覆盖度」用 max 累积成一张场（重叠多少次都只取最大值），
// 再一次性 over 合进图层。图案得以保留、边缘仍然柔和，范围也不会外扩。

/// 单个 splat 的覆盖度。与 paintSplatFragment 的 alpha 计算保持一致，
/// 抽出来给三条片元（上色 / 镂空 / 覆盖场）共用，避免两处逻辑慢慢跑偏。
inline float paintCoverage(PaintSplatInOut in,
                           constant PaintUniforms &u,
                           texture2d<float> maskTex,
                           bool 图案硬切)
{
    // 越出本格的像素不计入覆盖度：quad 现在不夹格，出格的部分必须在这里拦掉
    if (paintOutOfCell(in)) return 0.0;
    float d = length(in.corner);
    if (d > 1.0) return 0.0;
    float hardness = clamp(in.params.x, 0.0, 0.995);
    float weight = 1.0 - smoothstep(hardness, 1.0, d);
    bool 属于本片 = true;
    float2 圆盘 = paintBrushPoint(in, 属于本片);
    if (!属于本片) return 0.0;
    float 笔刷距 = length(圆盘);

    float m = 1.0;
    if (u.useMask != 0) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        m = sampleMask(maskTex, s, 圆盘 * 0.5 + 0.5, u);
        weight *= 1.0 - smoothstep(0.97, 1.0, 笔刷距);
        if (图案硬切) {
            m = smoothstep(0.35, 0.62, m);
        }
    } else if (图案硬切) {
        weight = 1.0;
    }
    return weight * m * in.color.a;
}

/// 写覆盖度场（r8，max 混合）
/// 法线通道：把一个 splat 的圆盘当成一顶球冠，当场算出世界空间法线写进图集。
///
/// 为什么不用「先存高度、采样时求导」：
///   1. OpenPBR 没有 height / displacement 参数，图集里存的必须是合法的
///      geometry_normal，高度只能作为内部中间量，不能落盘成通道；
///   2. 图集是 UV 空间的，不同物体 UV 密度差了十几倍，在 UV 上求导得到的坡度
///      会被 UV 拉伸带偏（同一个笔刷在稠密 UV 上变成缓坡），
///      而按「笔刷圆盘 → 世界切平面」算出来的坡度天然跟 UV 密度无关。
///
/// 高度剖面取 h(r) = (1 - r²)²，斜率 dh/dr = -4r(1 - r²)：中心平、边缘悄悄收，
/// 不会在 r→1 处出现无穷大斜率的硬折边。
fragment float4 paintNormalStampFragment(PaintSplatInOut in [[stage_in]],
                                        constant PaintUniforms &u [[buffer(0)]],
                                        texture2d<float> maskTex [[texture(0)]],
                                        constant float &strength [[buffer(1)]])
{
    if (paintOutOfCell(in)) { discard_fragment(); return float4(0.0); }
    float d = length(in.corner);
    if (d > 1.0) { discard_fragment(); return float4(0.0); }
    bool 属于本片 = true;
    paintBrushPoint(in, 属于本片);
    if (!属于本片) { discard_fragment(); return float4(0.0); }

    constexpr sampler 线性夹取(coord::normalized, address::clamp_to_edge, filter::linear);
    float m = sampleMask(maskTex, 线性夹取, in.uv, u);
    float hardness = clamp(in.params.x, 0.0, 0.995);
    float weight = 1.0 - smoothstep(hardness, 1.0, d);
    // 边缘的覆盖度低一点：法线笔迹与底材过渡才不会出一圈硬边
    float alpha = weight * m;
    if (alpha <= 0.002) { discard_fragment(); return float4(0.0); }

    // 本片三角形的世界法线；退化三角形退到笔刷基的叉积
    float3 Ng = cross(in.world1.xyz - in.world0.xyz, in.world2.xyz - in.world0.xyz);
    float3 b0 = in.basis0.xyz;
    float3 b1 = in.basis1.xyz;
    if (dot(Ng, Ng) < 1e-16) { Ng = cross(b0, b1); }
    if (dot(Ng, Ng) < 1e-16) { Ng = float3(0.0, 0.0, 1.0); }
    Ng = normalize(Ng);

    float lb0 = length(b0);
    float lb1 = length(b1);
    if (lb0 < 1e-9 || lb1 < 1e-9) {
        // 基退化：随便造一组与 Ng 垂直的轴，至少法线方向仍近似正确
        float3 up = (abs(Ng.y) < 0.9) ? float3(0.0, 1.0, 0.0) : float3(1.0, 0.0, 0.0);
        b0 = normalize(cross(up, Ng));
        b1 = cross(Ng, b0);
    } else {
        b0 /= lb0;
        b1 /= lb1;
    }

    float r = min(d, 1.0);
    float 斜率 = -strength * 4.0 * r * (1.0 - r * r);
    float2 方向 = (d > 1e-6) ? (in.corner / d) : float2(0.0);
    float3 n = 斜率 * (b0 * 方向.x + b1 * 方向.y) + Ng;
    if (dot(n, n) < 1e-12) { n = Ng; }
    n = normalize(n);
    return float4(n * 0.5 + 0.5, alpha);
}

fragment float4 paintCoverageFragment(PaintSplatInOut in [[stage_in]],
                                      constant PaintUniforms &u [[buffer(0)]],
                                      texture2d<float> maskTex [[texture(0)]])
{
    float a = paintCoverage(in, u, maskTex, u.mode == 2);
    if (a <= 0.0005) {
        discard_fragment();
        return float4(0.0);
    }
    return float4(a, a, a, a);
}

/// 覆盖场合进图层时用的颜色（一次落笔只有一个颜色，所以走 uniform 而不是逐 splat 带）
struct PaintApply {
    float4 color;   ///< rgb = 笔刷颜色；覆盖度里已经乘过强度和透明度，这里不再乘 alpha
};

vertex float4 paintFullscreenVertex(uint vid [[vertex_id]]) {
    const float2 c[4] = {
        float2(-1.0, -1.0), float2(1.0, -1.0),
        float2(-1.0,  1.0), float2(1.0,  1.0)
    };
    return float4(c[vid], 0.0, 1.0);
}

/// 覆盖场 → 图层（正常上色）
fragment float4 paintCoverageApplyFragment(float4 pos [[position]],
                                           constant PaintApply &p [[buffer(0)]],
                                           texture2d<float, access::read> cover [[texture(0)]])
{
    // 强度不在这里乘：通道强度在合成阶段折进该通道的不透明度，
    // 这样拖滑杆能连已有笔迹一起调，也不会「笔上乘一次、合成再乘一次」地二次衰减
    float a = cover.read(uint2(pos.xy)).r;
    if (a <= 0.0005) {
        discard_fragment();
        return float4(0.0);
    }
    return float4(p.color.rgb, a);
}

/// 覆盖场 → 洞图（镂空）。洞图是 r8，只吃覆盖度本身
fragment float4 paintCoverageApplyHoleFragment(float4 pos [[position]],
                                               constant PaintApply &p [[buffer(0)]],
                                               texture2d<float, access::read> cover [[texture(0)]])
{
    float a = cover.read(uint2(pos.xy)).r;
    if (a <= 0.0005) {
        discard_fragment();
        return float4(0.0);
    }
    return float4(a, a, a, a);
}

// MARK: - 镂空（真打洞）
//
// 镂空不是"把颜色擦回底色"，是让这部分表面根本不存在：
// 命中点在这里就当作没命中，射线继续往后找下一个交点 —— 破掉的披风能直接透出后面的场景。
// 洞不写进图层像素（图层存的是颜色，写 alpha 只会得到一片半透明脏色），
// 单独写一张「洞图」（r8，一物体一格）；但归属照样记在笔画上：
// 镂空笔落在哪一层就属于哪一层，删层/清层/撤销都按剩下的镂空笔重建洞图，
// 擦除笔另走一条 dst×(1-a) 的管线把洞填回去。
fragment float4 paintHoleFragment(PaintSplatInOut in [[stage_in]],
                                  constant PaintUniforms &u [[buffer(0)]],
                                  texture2d<float> maskTex [[texture(0)]])
{
    // 镂空写的是图层纹理（全图集），出格像素不拦就会在邻格里打出洞
    if (paintOutOfCell(in)) {
        discard_fragment();
        return float4(0.0);
    }
    float d = length(in.corner);
    if (d > 1.0) {
        discard_fragment();
        return float4(0.0);
    }
    float hardness = clamp(in.params.x, 0.0, 0.995);
    float weight = 1.0 - smoothstep(hardness, 1.0, d);

    bool 属于本片 = true;
    float2 圆盘 = paintBrushPoint(in, 属于本片);
    if (!属于本片) {
        discard_fragment();
        return float4(0.0);
    }
    float 笔刷距 = length(圆盘);

    float m = 1.0;
    if (u.useMask != 0) {
        // clamp 而不是 repeat：缩放/旋转后 uv 会出界，repeat 会把图案在笔刷里平铺成重复的小块，
        // 看起来像没放大；clamp 让出界部分取边缘值，图案才是真的被放大/转过
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        // 同样按整支笔刷采样（不逐 splat 抖开），圈里形状 = 面板里形状
        m = smoothstep(0.38, 0.60, sampleMask(maskTex, s, 圆盘 * 0.5 + 0.5, u));
        weight *= 1.0 - smoothstep(0.97, 1.0, 笔刷距);
    } else {
        // 没选遮罩 = 硬边圆孔，不留软过渡
        weight = 1.0;
    }

    float a = weight * m * in.color.a;
    if (a <= 0.0005) {
        discard_fragment();
    }
    // r8 目标只吃 r 通道：混合用 sourceAlpha 覆盖式，反复涂会渐近饱和到 1，
    // 单笔边缘又保留渐变，洞不会一上去就硬成锯齿。
    return float4(1.0, 1.0, 1.0, a);
}

// MARK: - 图层合成
//
// 每个物体一套图层，合成成一张图，写进图集的指定 slice。
// 只有图层脏了才重跑，画一笔的代价是「一次 splat draw + 一次全屏合成」，与几何规模无关。

kernel void paintComposite(texture2d_array<float, access::read> layers [[texture(0)]],
                           texture2d_array<float, access::write> outAtlas [[texture(1)]],
                           constant PaintLayerGPU *params [[buffer(0)]],
                           constant uint &count [[buffer(1)]],
                           constant uint &slice [[buffer(2)]],
                           uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= outAtlas.get_width() || gid.y >= outAtlas.get_height()) {
        return;
    }

    float3 rgb = float3(0.0);
    float a = 0.0;
    for (uint i = 0; i < count; ++i) {
        PaintLayerGPU p = params[i];
        if (p.visible == 0 || p.opacity <= 0.0) {
            continue;
        }
        float4 s = layers.read(gid, i);
        if (s.a <= 0.0005) {
            continue;
        }
        float sa = s.a * p.opacity;
        if (p.blend == 2) {
            // 叠加：不参与 alpha 遮盖，只把亮度往上加。
            // 一样按「非预乘」约定归一，否则重叠处会越叠越黑
            float w = saturate(a + sa);
            rgb = (rgb * a + s.rgb * sa) / max(w, 1e-5);
            a = w;
            continue;
        }
        // 图集里存的就是落笔那一刻的值（常量通道存标量、自发光存「色×亮度」），
        // 合成只管照读。CPU 不再注入当前滑杆值，否则一拖滑杆历史笔迹会被整片重算。
        float3 sc = s.rgb;
        if (p.blend == 1) {
            // 正片叠底：与已合成结果相乘。
            // 最底下一层下面是空的（累积器还是 0），乘出来必然全黑 ——
            // 这一轮没有下层可乘时退化成普通覆盖，不然最底层一选正片叠底整片变黑。
            sc = (a > 0.0005 ? rgb : float3(1.0)) * sc;
        }
        // 【必须是非预乘色】PT 侧是 paintTint = mix(baseColor, rgb, a)，
        // 它把 rgb 当「已经是不透明颜色」用。以前这里写的是 mix(rgb, sc, sa)，
        // 首层等于 rgb = sc * sa —— 半透明笔迹的颜色又被乘了一遍覆盖度，
        // 表现就是「画上去比笔刷色暗一大截、叠在红模型上发褐」。
        // 正确 over：按 alpha 加权平均，最后存的是不透明色，透明度单独存在 a 里。
        float w = sa + a * (1.0 - sa);
        rgb = (sc * sa + rgb * a * (1.0 - sa)) / max(w, 1e-5);
        a = w;
    }
    outAtlas.write(float4(rgb, a), gid, slice);
}

// MARK: - 面板里的通道预览（那颗球）

/// 图层面板顶部那颗球的参数。强度语义与通道一致：0 = 这个特性完全不出现。
/// 字段顺序必须与 Swift 侧 通道预览Uniforms 完全一致（16 + 24 + 8 = 48 字节）。
struct PaintPreviewParams {
    float4 color;          ///< rgb = 笔刷色；a = 颜色通道强度（表面覆盖度）
    float roughness;
    float metalness;
    float normalStrength;
    float coat;
    float coatRoughness;
    float emission;
    float2 size;           ///< drawable 像素尺寸：摆正球、算棋盘格都靠它
};

/// 预览用的假环境：上亮下暗的天光 + 一块柔光箱。
/// 金属球能反射出「上面亮、下面暗、还有一块亮斑」，一眼就分得出金属和非金属。
static float3 paintPreviewEnv(float3 d) {
    float up = saturate(d.y * 0.5 + 0.5);
    // 环境亮度按「普通室内/棚拍」的量级给，别给成户外大晴天：
    // 预览环境比真实场景亮多少，金属笔迹在球上就比模型上亮多少，看着就像两套东西。
    float3 sky = mix(float3(0.09, 0.10, 0.12), float3(0.52, 0.56, 0.64), up);
    float3 lampDir = normalize(float3(-0.45, 0.72, 0.55));
    float spot = pow(saturate(dot(d, lampDir)), 26.0);
    return sky + float3(1.0, 0.97, 0.92) * spot * 0.55;
}

vertex float4 paintPreviewVertex(uint vid [[vertex_id]]) {
    const float2 c[4] = {
        float2(-1.0, -1.0), float2(1.0, -1.0),
        float2(-1.0,  1.0), float2(1.0,  1.0)
    };
    return float4(c[vid], 0.0, 1.0);
}

fragment float4 paintPreviewFragment(float4 pos [[position]],
                                     constant PaintPreviewParams &p [[buffer(0)]])
{
    float2 res = max(p.size, float2(1.0, 1.0));
    // 像素坐标 → 以短边归一化的居中坐标（y 翻成向上）
    float2 q = (pos.xy - res * 0.5) * 2.0 / min(res.x, res.y);
    q.y = -q.y;

    // 底纹棋盘格 = 「这一层没盖到的地方」：颜色强度拉低时能看见底下的东西透上来
    float2 cell = floor(q * 9.0);
    // 【必须取绝对值】q 以画面中心为原点，左半边 cell.x+cell.y 是负数，
    // 而 Metal 的 fmod 对负数返回负数（-1 / -0），直接喂给 mix 会让左半边
    // 恒落在最暗那一档、根本不交替 —— 表现就是「预览背景一半黑、一半正常」。
    // abs 只改符号不改奇偶，棋盘相位仍然连续。
    float checker = fmod(abs(cell.x + cell.y), 2.0);
    // 底色 = 常规「看 alpha 图」的那套透明棋盘：白 ✕ 浅灰两档。
    // 预览本身想表达的也是「这一层盖了多少」，白底比深灰底更接近看图工具里的观感
    float3 back = mix(float3(1.0, 1.0, 1.0), float3(0.80, 0.80, 0.80), checker);

    const float R = 0.82;
    float r2 = dot(q, q);
    if (r2 > R * R) {
        return float4(back, 1.0);
    }

    float nz = sqrt(saturate(1.0 - r2 / (R * R)));
    float3 N = normalize(float3(q / R, nz));

    // 法线通道：球面撒一层凸点阵，按强度扰法线。0 = 光溜溜，1 = 明显一鼓一鼓
    float u = atan2(N.z, N.x);
    float v = asin(clamp(N.y, -1.0, 1.0));
    float k = 13.0;
    float dhu = -k * sin(u * k) * cos(v * k);
    float dhv = -k * cos(u * k) * sin(v * k);
    float3 T = normalize(cross(float3(0.0, 1.0, 0.0), N) + float3(1e-4, 0.0, 0.0));
    float3 B = cross(N, T);
    N = normalize(N - (dhu * T + dhv * B) * 0.010 * p.normalStrength);

    float3 V = float3(0.0, 0.0, 1.0);
    float3 albedo = p.color.rgb;
    float rough = clamp(p.roughness, 0.045, 1.0);
    float metal = saturate(p.metalness);
    float3 F0 = mix(float3(0.04), albedo, metal);

    float NdotV = saturate(dot(N, V));
    float3 L = normalize(float3(-0.45, 0.72, 0.55));
    float NdotL = saturate(dot(N, L));
    float3 envSharp = paintPreviewEnv(normalize(reflect(-V, N)));
    // 【别在这里给金属「补亮」】金属没有漫反射，画面里剩多少全靠环境反射。
    // 以前这里乘了 (1 + 0.85 * metal) 再加一点假灰光，球的金属区被强行提亮，
    // 于是「预览一团亮绿、模型一片暗褐」—— 预览必须和 PT 一样老实，亮不起来就是亮不起来。
    float3 specEnv = mix(envSharp, float3(0.42, 0.45, 0.50), rough * rough) * F0;

    float3 H = normalize(L + V);
    float NdotH = saturate(dot(N, H));
    // 简化的高光：粗糙度越高，高光越宽越矮
    float specPower = exp2(1.0 + 11.0 * (1.0 - rough));
    float specDirect = pow(NdotH, specPower) * (specPower + 8.0) * 0.04;
    float fresnel = 0.04 + 0.96 * pow(1.0 - NdotV, 5.0);

    float3 shade = albedo * (1.0 - metal) * NdotL * 0.95
                 + specEnv
                 + specDirect * fresnel * float3(1.0, 0.98, 0.94);

    // 清漆层：一层光滑薄膜，压暗底材、自己再出一块硬高光（不跟法线的凹凸走）
    if (p.coat > 0.001) {
        float3 Nc = normalize(float3(q / R, nz));
        float cr = clamp(p.coatRoughness, 0.02, 1.0);
        float specPowerC = exp2(1.0 + 11.0 * (1.0 - cr));
        float specC = pow(saturate(dot(Nc, normalize(L + V))), specPowerC) * (specPowerC + 8.0) * 0.04;
        float fresnelC = 0.04 + 0.96 * pow(1.0 - saturate(dot(Nc, V)), 5.0);
        float3 envC = paintPreviewEnv(normalize(reflect(-V, Nc)));
        shade = shade * (1.0 - 0.35 * p.coat);
        shade += (specC * 1.8 + envC * 0.35 * (1.0 - cr)) * fresnelC * p.coat;
    }

    // 自发光：直接叠在材质上，暗部也看得见。
    // 倍率必须跟 PT 一致（PT 是 radiance += emissive.rgb * emissive.a，没有额外倍数），
    // 以前这里 ×1.6 会把球刷成一片荧光绿，模型上却没这回事。
    shade += albedo * p.emission;

    float cover = saturate(p.color.a);
    float3 outColor = mix(back, shade, cover);

    // 一道细轮廓：颜色强度拉到 0 时也能看出「球还在，只是这层不进画面」
    float edge = smoothstep(0.985, 1.0, r2 / (R * R));
    outColor = mix(outColor, float3(0.55, 0.57, 0.62), edge * 0.5);

    return float4(saturate(outColor), 1.0);
}
