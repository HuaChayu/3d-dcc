#include <metal_stdlib>
#include <RealityKit/RealityKit.h>

using namespace metal;

/// 视口「法线」调试着色：把视空间法线映射到 RGB。
/// RealityKit 的 ModelDebugOptionsComponent 在 macOS 上不参与 RealityView 渲染，
/// 这条着色器补上 SceneKit 曾经白送的法线可视化。
[[visible]]
void rkNormalSurface(realitykit::surface_parameters params)
{
    float3 n = normalize(params.geometry().normal());
    half3 c = half3(n * 0.5 + 0.5);

    params.surface().set_base_color(c);
    params.surface().set_emissive_color(c);
    params.surface().set_roughness(1.0h);
    params.surface().set_metallic(0.0h);
}

/// 视口「玻璃 / 薄膜」着色（B 路线第一刀）：
/// RealityKit 的 PhysicallyBasedMaterial 没有 transmission、没有 IOR、没有 iridescence，
/// 只能把薄膜干涉色一次性烘进 baseColor。这里在片元级按视线角度算干涉项，
/// 掠射角变色、反射增亮都能动起来。
/// custom_parameter: x = 薄膜厚度(nm)  y = 薄膜 IOR  z = 薄膜权重  w = 透射权重
/// 基底色由 CustomMaterial.baseColor 走 material_constants().base_color_tint() 传进来。
[[visible]]
void rkGlassSurface(realitykit::surface_parameters params)
{
    float4 c = params.uniforms().custom_parameter();
    float3 base = params.material_constants().base_color_tint();

    float3 n = normalize(params.geometry().normal());
    float3 v = normalize(params.geometry().view_direction());
    float cosI = saturate(abs(dot(n, v)));

    float n2 = max(c.y, 1.0001);
    float sinT2 = (1.0 - cosI * cosI) / (n2 * n2);
    float cosT = sqrt(max(1.0 - sinT2, 0.0));

    // 两束反射光的光程差 δ = 4π·n·d·cosθt / λ
    float3 lambda = float3(650.0, 550.0, 450.0);
    float3 delta = 4.0 * M_PI_F * n2 * max(c.x, 0.0) * cosT / lambda;
    float R = pow((n2 - 1.0) / (n2 + 1.0), 2.0);
    float3 film = 4.0 * R * pow(sin(delta * 0.5), 2.0) * 6.0;
    film = clamp(film, 0.0, 1.5);

    float w = saturate(c.z);
    float transmission = saturate(c.w);

    // 少一点薄膜就用底色，多一点就让干涉色主导
    float3 tint = mix(base, base * 0.25 + film, w);

    // Schlick 近似：掠射角反射变强，玻璃边缘才有"亮边"
    float f0 = pow((n2 - 1.0) / (n2 + 1.0), 2.0);
    float fresnel = f0 + (1.0 - f0) * pow(1.0 - cosI, 5.0);

    params.surface().set_base_color(half3(tint));
    params.surface().set_metallic(0.0h);
    params.surface().set_roughness(half(clamp(0.05 + 0.25 * fresnel, 0.0, 1.0)));
    // 透射靠 alpha 假装：正对更透，掠射更实
    params.surface().set_opacity(half(clamp(mix(1.0, 0.32 + 0.5 * fresnel, transmission), 0.02, 1.0)));
    params.surface().set_emissive_color(half3(film * fresnel * transmission * 0.6));
}

// MARK: - 程序化无限网格

/// 网格是尺子：格线间距在世界空间恒定（1 / 10 / 100 三档刻度），直接由片元世界坐标算，
/// 与相机距离、模型大小、承载平面缩放完全无关 —— 所以既不需要重建 mesh、也不需要跳档，
/// 一个大平面（4 顶点）单次 draw call 就能铺满整个视锥。
///
/// 抗锯齿与远景处理全部在屏幕空间完成：
/// - 线宽以「屏幕像素」为单位，用 fwidth 把世界距离折算成像素距离，线条恒约 1px，不闪烁；
/// - 某一档刻度的间距在屏幕上不足约 1.5px 时按并集淡出，只剩更粗的刻度级（消除摩尔纹），
///   这是为了消除采样冲突，绝不是把格子放大。
/// custom_parameter: x = 主题（0 浅色 / 1 深色）  y = 整体不透明度（≤0 视为 1）  z、w 预留
namespace rkGridLevel
{
    /// 该档刻度在本片元的覆盖率（0…1）：线宽按屏幕像素给，边缘自带半像素抗锯齿。
    inline float coverage(float2 p, float spacing, float widthPx)
    {
        float2 coord = p / spacing;
        float2 deriv = max(fwidth(coord), float2(1e-8));        // 每像素跨过多少「格」
        float2 dist = abs(fract(coord - 0.5) - 0.5) / deriv;    // 到最近格线的像素距离
        float d = min(dist.x, dist.y);
        return saturate(widthPx * 0.5 - d + 0.5);
    }

    /// 该档一格在屏幕上小于 6px 时逐渐淡出，1.5px 以下完全消失（防摩尔纹）。
    inline float fade(float2 p, float spacing)
    {
        float2 coord = p / spacing;
        float pxPerCell = 1.0 / max(max(fwidth(coord.x), fwidth(coord.y)), 1e-8);
        return saturate((pxPerCell - 1.5) / 4.5);
    }
}

[[visible]]
void rkGridSurface(realitykit::surface_parameters params)
{
    float4 u = params.uniforms().custom_parameter();
    float dark = saturate(u.x);
    float strength = u.y > 0.0 ? saturate(u.y) : 1.0;

    // 世界空间水平坐标 = 尺子读数基准：平移相机线不动，缩放相机格子尺寸不变。
    float2 p = params.geometry().world_position().xz;

    // 三档刻度同属一把尺子：1 单位细线、10 单位主格线、100 单位读数线
    // 细线在浅色/深色底都要一眼可辨：浅色底需要更深更实（0.92 alpha、1.55px）
    float thinWide = mix(1.55, 1.20, dark);
    float thinAlpha = mix(0.92, 0.72, dark);
    float a1 = rkGridLevel::coverage(p, 1.0, thinWide) * rkGridLevel::fade(p, 1.0) * thinAlpha;
    float a10 = rkGridLevel::coverage(p, 10.0, 1.8) * rkGridLevel::fade(p, 10.0) * mix(0.95, 0.88, dark);
    float a100 = rkGridLevel::coverage(p, 100.0, 2.6) * rkGridLevel::fade(p, 100.0);

    // 深浅主题两套色板：级别越高越醒目（深色更亮 / 浅色更深），作为读数层级
    // 浅色细线压到 (0.16,0.19,0.24) 深灰，与主格线 (0.14,0.17,0.22)、读数线 (0.05,0.07,0.11) 保持递进
    float3 c1 = mix(float3(0.16, 0.19, 0.24), float3(0.60, 0.64, 0.70), dark);
    float3 c10 = mix(float3(0.14, 0.17, 0.22), float3(0.86, 0.89, 0.94), dark);
    float3 c100 = mix(float3(0.05, 0.07, 0.11), float3(0.98, 0.99, 1.00), dark);

    float3 color = c1;
    color = mix(color, c10, saturate(a10 * 1.6));
    color = mix(color, c100, saturate(a100 * 1.6));

    float alpha = 1.0 - (1.0 - a1) * (1.0 - a10) * (1.0 - a100);
    alpha = saturate(alpha * strength);

    params.surface().set_base_color(half3(color));
    params.surface().set_emissive_color(half3(color * 0.45));
    params.surface().set_roughness(1.0h);
    params.surface().set_metallic(0.0h);
    params.surface().set_opacity(half(alpha));
}
