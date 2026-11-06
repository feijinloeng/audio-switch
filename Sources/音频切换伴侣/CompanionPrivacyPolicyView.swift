import SwiftUI

struct CompanionPrivacyPolicyView: View {
    var body: some View {
        List {
            Section("数据处理") {
                Text("音频切换伴侣仅在本机播放同一局域网内 Mac 发送的实时音频。我们不会录制、保存或上传音频内容。")
            }
            Section("局域网与配对") {
                Text("应用使用本地网络发现你的 Mac。Mac 的长期身份公钥保存在 iPhone 系统 Keychain 中；每次连接的临时会话密钥只保存在内存，断开后立即清除。")
            }
            Section("第三方服务") {
                Text("当前版本不接入广告、统计或第三方崩溃分析 SDK；音频不会经过我们的服务器。")
            }
            Section("更新说明") {
                Text("如隐私处理方式发生变化，我们会在更新应用和 App Store 隐私信息前说明。")
            }
        }
        .navigationTitle("隐私政策")
        .navigationBarTitleDisplayMode(.inline)
    }
}
