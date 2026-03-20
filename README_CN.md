# 🦐 VisionClaw — Apple Vision Pro 上的 AI 伙伴

[English](README.md) | **中文**

**VisionClaw** 将一个有生命感的 3D AI 角色带入你的 Apple Vision Pro。一只活泼的虾虾角色站在你的桌面上，听你说话、和你对话、连接 Mac 上的 AI 大脑——一切都在混合现实中发生。

> *"就像桌上住着一个有个性的 AI 小助手。"*

### 🎥 演示视频

[![演示视频](demo_preview.gif)](https://github.com/lhfer/visionclaw/releases/download/v0.1.0/demo.mp4)

*点击预览图观看完整演示视频*

---

## ✨ 核心功能

### 🎭 有生命感的 3D 角色
- **15+ 精心制作的动画** — 闲逛、倾听、思考、工作、庆祝、入睡等
- **智能状态机** — 角色对每个交互阶段做出视觉反应
- **手势操控** — 拖拽移动、捏合缩放、双手旋转
- **永远鲜活** — 随机待机动画、彩蛋舞蹈、打哈欠、入睡周期

### 🎤 语音交互
- **点击说话** — 点击角色开始录音，再点发送
- **实时转写** — 说话时在气泡中看到实时文字
- **中文语音识别** — 基于 Apple 设备端 `SFSpeechRecognizer`
- **语音回复** — 角色用自然中文语音回应你

### 💬 AI 驱动对话
- **OpenClaw 集成** — 通过 WebSocket 连接到 Mac Mini 上的 OpenClaw AI 代理
- **自动发现** — 通过 Bonjour 协议自动发现局域网中的 Mac
- **实时状态反馈** — 看到思考中、工作中、处理中等状态
- **渐进式超时提示** — 10 秒、30 秒、60 秒分阶段反馈

### 🫧 智能气泡
- **打字机效果** — 回复逐字显示，中文/英文/标点自适应速度
- **状态图标** — 🎤 听写中、✨ 发送中、💭 思考中、⚙️ 工作中、✓ 成功、⚠️ 出错
- **自动消失** — 按中文阅读速度（~3字/秒）计算充足的阅读时间

### 🏠 空间感知
- **混合现实** — 角色存在于你的真实环境中，带有阴影
- **自由定位** — 三轴自由拖拽角色到任意位置
- **捏合缩放** — 从 1cm 迷你到 60cm 大号
- **气泡跟随** — 气泡始终面向你，自动定位在头顶

---

## 🚀 快速开始

### 环境要求

- **Apple Vision Pro**（或 visionOS 模拟器）
- **Xcode 26+**，visionOS 26 SDK
- **Mac Mini**（或任何 Mac）运行 OpenClaw 桥接服务（用于 AI 功能）

### 1. 克隆项目

```bash
git clone https://github.com/lhfer/visionclaw.git
cd visionclaw
open ShrimpXR.xcodeproj
```

### 2. 编译运行

1. 选择 `Apple Vision Pro` 目标设备
2. 编译运行（⌘R）
3. 控制面板窗口出现

### 3. 连接 AI

1. 在 Mac 上启动 OpenClaw 桥接：
   ```bash
   cd OpenClawBridge
   pip install -r requirements.txt
   python bridge.py
   ```
2. 在 VisionClaw 中点击 **"搜索 Mac Mini"** 自动发现
3. 状态变绿即已连接

### 4. 和虾虾互动

1. 点击 **"放出虾虾"** 生成角色
2. 角色出现在你面前，播放打招呼动画
3. **点击角色** 开始语音输入
4. **说中文** — 在气泡中看到实时转写
5. **再次点击** 发送消息给 AI
6. 看角色反应 — 施法 → 思考 → 庆祝！

### 5. 手势操控

| 手势 | 动作 |
|------|------|
| **点击** | 开始/结束录音 |
| **长按** | 强制角色站直 |
| **拖拽** | 三轴自由移动角色 |
| **捏合** | 缩放角色大小 |
| **双手旋转** | 旋转角色朝向 |

---

## 🎬 动画状态

| 状态 | 动画 | 触发条件 |
|------|------|----------|
| `idle` | 呼吸、踱步、随机动作 | 默认状态 |
| `listening` | 专注倾听 | 用户点击说话 |
| `sendingCommand` | 施法发送 ✨ | 语音输入完成 |
| `thinking` | 踱步思考 | AI 处理中 |
| `working` | 忙碌动作 | AI 执行中 |
| `success` | 胜利舞蹈 🎉 | 收到 AI 回复 |
| `error` | 失败姿态 | 出错了 |
| `sleeping` | 打盹 💤 | 2 分钟不操作 |

---

## 🏗 技术架构

```
Apple Vision Pro                          Mac Mini
┌─────────────────────┐                  ┌──────────────────┐
│  VisionClaw App     │  ◄──WebSocket──► │  OpenClaw Bridge │
│                     │                  │  (Python)        │
│  ┌───────────────┐  │   Bonjour        │  ┌────────────┐  │
│  │ ShrimpEntity  │  │   自动发现        │  │  OpenClaw   │  │
│  │ (3D 角色)     │  │                  │  │  AI Agent   │  │
│  ├───────────────┤  │                  │  └────────────┘  │
│  │ AnimController│  │                  └──────────────────┘
│  │ (15+ 动画)    │  │
│  ├───────────────┤  │
│  │ SpeechManager │  │
│  │ (语音识别+合成)│  │
│  ├───────────────┤  │
│  │ Bubble3D      │  │
│  │ (3D SwiftUI)  │  │
│  └───────────────┘  │
└─────────────────────┘
```

### 技术亮点

- **双层实体架构**：Wrapper 实体（手势/旋转）→ Model 实体（动画），防止动画根运动和用户手势冲突
- **异步音频初始化**：`AVAudioEngine` 在后台线程初始化，避免 Vision Pro 上 UI 冻结
- **ViewAttachmentComponent**：visionOS 26 原生 API，将 SwiftUI 直接渲染在 3D 空间
- **自适应气泡定位**：自定义 ECS 组件追踪角色头部，自动反向缩放保持文字可读
- **Swift 6 严格并发**：完全兼容 Swift 最新并发模型

---

## 📄 许可证

MIT License — 详见 [LICENSE](LICENSE)

---

<p align="center">
  用 ❤️ 为 Apple Vision Pro 打造<br>
  <strong>VisionClaw</strong> — 当 AI 遇见空间计算
</p>
