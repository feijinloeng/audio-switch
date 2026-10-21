# 更新日志

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [Unreleased]

## [1.3.1] - 2026-10-21

### 变更

- 安装包通过 Apple 公证并装订票据，双击即可打开。
- App 版本号改为跟随 Xcode 构建配置，不再写死在 Info.plist。

## 1.3.0 - 2026-09-06（已删除的未公证版本）

### 新增

- 按 App 路由：为不同音乐 App 选择不同输出设备，独立调节音量和静音。
- 全景播放：最多 3 台蓝牙音箱 + Mac 自带扬声器 + 1 路 iPhone 桥接，共 5 个输出点。
- iPhone 伴侣 App，通过 Mac App 内的二维码安装。
- 每个输出设备独立的时钟校正和自适应重采样。
- 播放中热插拔设备。
- 淡入淡出、增益斜坡和总线限幅，减少切换爆音。

### 修复

- 全景模式的音频安全处理和配置保存问题。

### 已知限制

- 只提供 Apple 芯片（arm64）安装包。
- 安装包未公证。
- Mac 直连蓝牙音箱超过 3 台会断连，第 4 台需要 iPhone 桥接。

[Unreleased]: https://github.com/feijinloeng/audio-switch/compare/v1.3.1...HEAD
[1.3.1]: https://github.com/feijinloeng/audio-switch/releases/tag/v1.3.1
