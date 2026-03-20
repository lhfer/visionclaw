# 虾模型骨骼规范 (Shrimp Model Bone Spec)

## 导出格式
- **USDZ** (RealityKit 原生格式)
- 从 Blender 导出时使用 Apple 的 USDZ exporter

## 模型尺寸
- 自然尺寸建模即可，代码里会 scale 到 ~10cm

## 骨骼命名 (必须严格匹配)

```
root
├── body            ← 主体躯干 (必须)
│   ├── claw_L      ← 左钳 (必须)
│   ├── claw_R      ← 右钳 (必须)
│   ├── tail        ← 尾巴 (必须)
│   ├── antenna_L   ← 左触须 (必须)
│   ├── antenna_R   ← 右触须 (必须)
│   ├── leg_0       ← 第1对腿 (至少4对)
│   ├── leg_1
│   ├── leg_2
│   ├── leg_3
│   ├── leg_4       ← (可选, 更多腿)
│   ├── leg_5
│   ├── leg_6
│   └── leg_7
```

## 骨骼轴向
- **X轴**: 左右
- **Y轴**: 上下
- **Z轴**: 前后 (虾头朝 -Z)

## 注意事项
1. 每个骨骼需要独立，不能合并 mesh
2. 钳子需要一个开合的旋转轴 (Z轴旋转 = 开合)
3. 触须建议分 2-3 段骨骼做链式效果 (但第一版单段也行)
4. 材质建议用半透明 PBR，透光效果在 Vision Pro 上很美
5. 文件放到 `ShrimpXR/Resources/shrimp.usdz`
