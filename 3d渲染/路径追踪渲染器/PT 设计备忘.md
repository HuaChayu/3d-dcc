---
AIGC:
    Label: "1"
    ContentProducer: 001191440300708461136T1XGW3
    ProduceID: 2a3ad4afc341e3a7b9ee947e156d9b72_79a6a0ecd75211f1a286525400638852
    ReservedCode1: EJ6i3DIs58ajlX9R85CD+aGbja66j8GCopN99Qese66aVRR5WeTOaU7VmP9sUbHUbJWctNRH5MK6Coyo7TnEsebR1ZATYc86yS6c9Reriookomvr45Ndv0RpUxPwDMPoE3K1Q+Sh+TYwYmd6+gFMwVI13VCZvOXlYSRTixSezLE6zenRchL1Jm2fIjo=
    ContentPropagator: 001191440300708461136T1XGW3
    PropagateID: 2a3ad4afc341e3a7b9ee947e156d9b72_79a6a0ecd75211f1a286525400638852
    ReservedCode2: EJ6i3DIs58ajlX9R85CD+aGbja66j8GCopN99Qese66aVRR5WeTOaU7VmP9sUbHUbJWctNRH5MK6Coyo7TnEsebR1ZATYc86yS6c9Reriookomvr45Ndv0RpUxPwDMPoE3K1Q+Sh+TYwYmd6+gFMwVI13VCZvOXlYSRTixSezLE6zenRchL1Jm2fIjo=
---

# 路径追踪渲染器 · 设计备忘

自研 Metal 硬件光追路径追踪器，不嵌 Cycles。目前完成 **M0（加速结构）+ M1（直接光）+ M2 骨架（间接光/BSDF 混合）**，可出图、可累积收敛。

## 文件分工

| 文件 | 职责 |
| --- | --- |
| `PT 类型定义.swift` | CPU 侧数据结构：`PTCamera` / `PTScene` / `PTMaterialGPU` / `PTEnvironmentGPU` / `PathTraceSettings`，字段与 Metal struct 逐字段对齐 |
| `PT 几何 生成.swift` | 程序化几何（球/盒/柱/环/平面/shaderBall）→ 世界空间三角形汤；`SceneObject.pathTraceMatrix` 做 位置·欧拉角·缩放 合成 |
| `PT 场景 转译.swift` | RealityKit 场景 → PT 场景；OpenPBR 参数直译成 PT 材质（不折色）；构建**自发光三角形光源列表 + 面积加权的前缀和 CDF** |
| `PT 加速结构 构建.swift` | BLAS（三角形几何）+ 单实例 IAS（单位矩阵，几何已烘焙到世界空间）；按场景签名缓存 |
| `PT 着色器.metal` | `ptTrace` 主内核：相机射线、太阳 NEE、面光源 NEE、GGX 高光、薄膜干涉、透射菲涅尔、清漆、俄式轮盘；`ptResolve` 做 ACES + sRGB + 低分辨率放大 |
| `PT 渲染器.swift` | `MTKViewDelegate`：渐进累积、相机/场景签名变更自动重启、分辨率缩放、样本数回调 |
| `PT 视口.swift` | SwiftUI 外壳（`NSViewRepresentable`）+ 左下角 spp 角标；**不参与命中测试**，鼠标事件继续落到下面的 RealityView |

## 数据流

```
SceneObject[] + MaterialAsset[] + ViewportSettings
        │  PTTranslator.build（每帧比对签名，变了才重建）
        ▼
     PTScene（世界空间三角形 + 逐三角形材质下标 + 光源 CDF）
        │  PTAcceleration.payload（签名不变直接复用 BLAS/IAS）
        ▼
   MTLBuffer × 6 + IAS ──► ptTrace 每帧 1 spp 累加进 accumTexture
                                   │
                                   ▼
                          ptResolve → MTKView drawable
```

## 与 Cycles 最新 beta 的对照

借鉴的点：

1. **光源列表 + 面积加权 CDF**（`buildLightList`）：自发光三角形按 `面积 × 发光亮度` 建前缀和，着色器二分抽一支做 NEE。Cycles 的 light distribution 同源思路，只是它更进一层做了 light tree。
2. **直接光 / BSDF 采样不双计**：自发光只在「相机直击」或「上一跳为镜面」时累加，漫反射跳交给 NEE，和 Cycles 的 MIS 处理同构（这里省掉了 BSDF pdf 的权重项，先求稳）。
3. **渐进累积 + 变动重启**：相机或场景签名一变就清零重来，对应 Cycles 的 progressive refine。
4. **俄式轮盘**终止长路径。

暂未做的（后续里程碑）：

- M3：完整 OpenPBR BSDF（各向异性、次表面、薄膜多层精确解）+ 光谱/PBR 白炉测试
- M4：降噪。Cycles 走 OIDN（机器学习降噪），本地可先上 **À-Trous 小波 + 法线/深度引导**，后续再考虑 ML 降噪
- light tree / 多光源重要性采样、自适应采样（方差图）
- 纹理/UV、法线贴图、体积散射

## 已知限制

- 只跑硬件光追（M3+ 机型），无软件回退
- 材质目前逐三角形常量，没有 UV 与贴图采样
- 环境是双色天空 + 单太阳，没有 HDRI
- `maxSamples` 默认 512，到顶暂停省电；挪相机或改场景自动续算
*（内容由AI生成，仅供参考）*
