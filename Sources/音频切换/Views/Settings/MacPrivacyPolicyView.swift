import SwiftUI

/// The in-app copy matches the privacy statements that must also be published
/// at the App Store privacy-policy URL before release.
struct MacPrivacyPolicyView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("隐私政策")
                .font(.title2.bold())

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    PrivacyPolicySection(
                        title: "数据处理",
                        text: "音频切换在本机实时处理系统音频，用于识别正在播放声音的应用并按你的选择路由输出。我们不会录制、保存或上传屏幕内容或正在播放的音频。"
                    )
                    PrivacyPolicySection(
                        title: "本地设置与凭据",
                        text: "音量、静音、设备偏好和路由设置仅保存在这台 Mac。Mac 的长期配对签名身份保存在系统 Keychain；每次 iPhone 连接的临时会话密钥不会落盘。"
                    )
                    PrivacyPolicySection(
                        title: "局域网连接",
                        text: "只有在你选择使用 iPhone 伴侣时，应用才会在同一局域网内发现并连接你的设备，以发送实时音频；音频不会经过我们的服务器。"
                    )
                    PrivacyPolicySection(
                        title: "第三方与联系",
                        text: "当前版本不接入广告、统计或第三方崩溃分析 SDK。如隐私处理方式发生变化，我们会在更新应用和 App Store 隐私信息前说明。"
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520, height: 440)
    }
}

private struct PrivacyPolicySection: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.headline)
            Text(text).font(.body).foregroundStyle(.secondary)
        }
    }
}
