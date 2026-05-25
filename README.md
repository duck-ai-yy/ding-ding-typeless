<div align="center">

# 叮叮嘴替 (DingDing-Typeless)

**懒得打字？让嘴替来。**

按住 ⌥Space 说中文 → 松开 → 自动转录 + 补标点 → 粘到光标位置。
**完全离线，零网络，零成本。**

[![Platform](https://img.shields.io/badge/platform-macOS_12%2B-blue)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-6.2-orange)](https://swift.org)
[![License](https://img.shields.io/badge/License-Apache_2.0-blue)](LICENSE)

</div>

---

## ✨ 为什么用叮叮嘴替

| | 商业云端方案<br/>(Wispr Flow / SuperWhisper) | 国际开源方案<br/>(TypeWhisper / Whisper.cpp) | **叮叮嘴替** |
|---|:---:|:---:|:---:|
| 完全离线 | ❌ 上传到云 | ✅ | ✅ |
| 中文优先 | 英文为主 | 英文为主 | ✅ 中文专精 |
| 自动补标点 | ✅（云端 LLM） | ❌ 需自己加 | ✅（本地 punct 模型） |
| 隐私 | 文字上传服务器 | 全本地 | **全本地，零网络** |
| 成本 | 订阅 / pay-per-use | 免费 | **免费** |
| 体积 | App ~50MB + 云 | ~50MB | ~167MB（含 ASR + punct 模型） |

**最适合：**
- 中文母语用户 / 中文工作者
- 重视隐私，不想录音 / 转录文字进云端
- 厌烦云端订阅，要一次性安装永久使用

---

## 📸 效果

> v1.0 自用版，demo GIF 待补。

工作流程：

```
按住 ⌥Space          说中文            松开
   ↓                  ↓                ↓
🎙️ menubar mic.fill   持续录音          🎯 自动:
💬 "说吧"气泡                          1. ASR 转录
🔔 "叮"声                              2. 标点恢复
                                       3. 粘贴到光标

                                       💬 "好了"气泡（1s 收）
                                       ✓ menubar 图标
                                       🔔 "嗒"声
```

---

## 🚀 安装

### 推荐：从 Release 下载（待发布）

> v1.0 暂未发布到 GitHub Releases，先走 "从源码构建" 路线。

### 从源码构建（v1.0 当前路径）

**系统要求**：
- macOS 12.0+（已实测 Intel Mac；Apple Silicon 兼容但未优化）
- Xcode Command Line Tools（无需完整 Xcode）
- ~500MB 磁盘空间（含 sherpa-onnx 静态库 + 2 个模型）

**5 步装好**：

```bash
# 1. clone repo
git clone https://github.com/duck-ai-yy/ding-ding-typeless.git
cd ding-ding-typeless

# 2. 装 Swift（如未装）
xcode-select --install

# 3. 下载 sherpa-onnx 库 + ASR + punct 模型（~160MB 一次性，自动 SHA256 校验）
./scripts/fetch-deps.sh

# 4. 编译并组装 .app
swift build -c release
./scripts/build-app.sh

# 5. 安装到 /Applications/
cp -R DingDing.app /Applications/
```

**首次启动**（macOS 安全模型）：

```bash
open /Applications/DingDing.app
```

未签名 .app 首次可能弹"未验证的开发者"——**右键 .app → 打开**，授权一次即可。

随后会依次弹 2 个权限请求：
1. **麦克风权限**：用于录音转文字（音频只在本地处理，不上传）
2. **辅助功能权限**：用于模拟 ⌘V 自动粘贴

两个都允许后即可使用。

---

## ⌨️ 使用方法

### 基本用法

1. 在任意 app 的输入框点一下（光标定位）
2. **按住 ⌥Space**（默认热键）说中文
3. **松开** → 文字自动粘贴到光标位置（带标点）

### 自定义热键

menubar 上点叮叮图标 → **热键: ⌥Space …** → 按下你想要的新组合（支持 ⌃⌥⇧⌘ 任意组合 + 字母 / 数字 / F-keys / Space / Tab）→ 确认。

### menubar 图标状态

| 图标 | 含义 |
|---|---|
| `waveform` | 空闲 |
| `mic.fill` | 录音中 |
| `checkmark.circle` | 完成（1 秒后回 idle） |
| `exclamationmark.triangle` | 异常（停留，需处理） |

### 异常处理

| 气泡文字 | 含义 | 怎么办 |
|---|---|---|
| "太快了" | 录音 < 0.5s | 按久一点 |
| "没听清" | ASR 没听到内容 | 说大声 / 离麦克风近 |
| "超时了" | ASR > 5s 没出结果 | 重试 |
| "原文粘了" | 标点模型挂了 | 文字仍粘出来，只是没标点 |
| "需要麦克风权限" | 权限被拒 | 系统设置 → 隐私 → 麦克风 |
| "需要辅助功能权限" | AX 被拒 | 系统设置 → 隐私 → 辅助功能 |
| "热键被占用" | 默认热键冲突 | 改自定义热键 |

---

## 🛠️ 技术栈

| 层 | 技术 |
|---|---|
| **UI** | AppKit / NSStatusItem / NSPopover |
| **录音** | AVFoundation（AVAudioEngine 16kHz mono PCM） |
| **热键** | Carbon RegisterEventHotKey（支持任意 modifier 组合） |
| **ASR** | sherpa-onnx C API + Zipformer 中文 small int8 (80MB) |
| **标点恢复** | sherpa-onnx + CT-Transformer int8 (72MB) |
| **粘贴** | NSPasteboard + CGEvent.post（带 fence-post 保护） |
| **构建** | Swift 6.2 + SPM（不依赖完整 Xcode） |

**完全本地，无网络调用，无 Python/Node/Electron 运行时。**

---

## 🔒 隐私

- ✅ **音频不离机器**：录音 → ASR 全本地，原始音频 + 转录文字只在内存
- ✅ **零网络调用**：app 启动 / 录音 / 转录 / 粘贴**整条管线无任何 HTTP 请求**
- ✅ **零历史**：进程退出 = 所有用户数据消失。唯一持久化的只有设置（热键 / UserDefaults）
- ✅ **零分析**：不发任何 telemetry，不收集使用统计

唯一一次网络调用是 `scripts/fetch-deps.sh` 首次下载模型（GitHub Releases + Hugging Face）—— **运行时永远离线**。

---

## 🗺️ Roadmap

| 版本 | 状态 | 范围 |
|---|---|---|
| **v1.0** | ✅ 当前 | Mac Intel 起步，中文 ASR + 标点，热键自定义 |
| v1.1 | 计划 | Apple Silicon 优化（Metal/Neural Engine 加速） |
| v1.2 | 计划 | 中英双语模型可选（解决中英混合识别） |
| v2 | 长期 | Windows + Mac 跨平台（Tauri 2 + Rust 核心） |
| v2.1 | 长期 | Linux |

**v1 已知限制**（详见 `docs/spec-v1.md` 末尾 "后续可探索"段）：
- 中英混合识别不可靠（默认纯中文模型）—— 未来 v1.2 加双语模型
- 长录音粘贴可能因 fence-post 时序撞 v1 hack 边界 —— 未来 v1.x 用 NSAccessibility 直接 inject text 根治
- 流式输出（一边说一边显示）—— v1.x / v2 路线候选

---

## 🙏 鸣谢

- **[k2-fsa/sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx)**：完整 ASR + 标点恢复管线的 C API + 模型
- **[csukuangfj](https://huggingface.co/csukuangfj)**：sherpa-onnx 上游中文 ASR 模型维护者
- **[ranger810](https://huggingface.co/ranger810/sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12-int8)**：标点模型 int8 量化镜像（节省 73% 体积）
- 阿里 DAMO 学院 / icefall 上游中文 ASR 训练数据

---

## 🤝 贡献

v1.0 是单人自用版。如果你对中文语音输入有兴趣：

- 报 Bug：开 issue + 附 Console.app 里 DingDing 的 log
- 提想法：欢迎讨论，但 v1.x 优先级以用户实测痛点为准
- PR：请先开 issue 讨论，避免做完发现方向不对

---

## 📄 License

[Apache License 2.0](LICENSE)

Copyright 2026 [duck-ai-yy](https://github.com/duck-ai-yy)

Apache 2.0 同 MIT 一样允许任何人 fork / 商用 / 修改 / 闭源衍生，**额外保护贡献者专利**（贡献者一旦提交代码默认授予项目专利使用许可，防止后续反诉）。详见 [LICENSE](LICENSE) 文件。

---

<div align="center">

**叮叮嘴替** · 让中文语音输入回到"快"的本质

Made with ☕ by [@duck-ai-yy](https://github.com/duck-ai-yy)

</div>
