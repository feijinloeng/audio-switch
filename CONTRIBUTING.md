# 参与贡献

感谢愿意帮忙。这个项目主要在 macOS 上做实时音频路由，改动前请先看完这篇。

## 先提 Issue

以下改动请先开 Issue 说明动机，避免白做：

1. 新增依赖或第三方库。
2. 改动音频管线、时钟校正或缓冲策略。
3. 改动 Xcode 工程结构、Bundle ID 或权限配置。
4. 大范围重命名或重构。

修错别字、改文档、补测试可以直接提 PR。

## 环境

- macOS 14.2 或更高版本
- Xcode（含 iOS 模拟器）
- Swift 5.9 或更高版本

## 提交前必须跑

```bash
swift test -Xswiftc -strict-concurrency=complete
Scripts/build_and_run.sh
```

改动了 Xcode 工程或 App 配置时，还要确认两个 App 都能无签名构建：

```bash
xcodebuild -project 音频切换.xcodeproj -scheme 音频切换 \
  -configuration Debug CODE_SIGNING_ALLOWED=NO build

xcodebuild -project 音频切换.xcodeproj -scheme 音频切换伴侣 \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

CI 也会跑同样的检查，PR 必须全绿才能合并。

## 代码约定

1. 实时音频回调里不要分配内存、加锁、打日志或调用 Objective-C。
2. 新增的共享状态要考虑并发安全，工程开启了 complete concurrency checking。
3. 修 Bug 时优先改根因，不要在调用处叠加临时判断。
4. 行为变化请补一条对应的测试。

## 提交信息

用一句话说清改了什么，例如：

```text
修复全景模式下移除设备时的爆音
```

## 提 PR

1. 从 `main` 切分支。
2. 在 PR 描述里写清现象、原因和验证方式。
3. 涉及界面改动时附上截图或录屏。
4. 关联相关 Issue。

## 报告 Bug

用仓库里的 Issue 模板，尽量附上：

1. macOS 版本和 Mac 芯片型号。
2. App 版本。
3. 蓝牙音箱型号和数量。
4. 复现步骤。
5. `Scripts/build_and_run.sh --logs` 的相关日志。

设备兼容性问题很有价值，但请注意：Mac 蓝牙能同时带几台音箱取决于硬件，见 README 的「已知边界」。

## 维护者发版

1. 在 [appleid.apple.com](https://appleid.apple.com) 生成一个 App 专用密码。
2. 存一次公证凭证（只需一次，会提示粘贴密码）：

```bash
xcrun notarytool store-credentials audio-switch \
  --apple-id 你的AppleID邮箱 --team-id J394BNW2WG
```

3. 发版：

```bash
Scripts/release.sh 1.4.0
```

4. 用脚本输出的 `gh release create` 命令发布。

脚本会依次完成：构建 → Developer ID 签名 → 公证 → 装订票据 → 打包 dmg/zip → 生成 SHA256SUMS。证书需要在本机 Keychain 里（Xcode → Settings → Accounts → Manage Certificates → Developer ID Application）。
