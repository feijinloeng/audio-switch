import AVFoundation
import MediaPlayer
import SwiftUI

struct CompanionRootView: View {
    let session: CompanionAudioSession
    let client: CompanionSessionClient
    @Environment(\.scenePhase) private var scenePhase
    @State private var pendingHost: DiscoveredCompanionHost?
    @State private var dismissedHostIDs: Set<String> = []

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                pairingCard
                systemVolumeCard
                aboutCard
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("音频切换伴侣")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                activateAudioOutput()
                client.startDiscovery()
                offerFirstDiscoveredHost(from: client.hosts)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    activateAudioOutput()
                }
            }
            .onChange(of: client.hosts) { _, hosts in
                offerFirstDiscoveredHost(from: hosts)
            }
            .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { _ in
                activateAudioOutput()
            }
            .onChange(of: session.currentOutputVolume) { _, _ in
                client.updateCurrentOutput(
                    name: session.currentOutputName,
                    volume: session.currentOutputVolume
                )
            }
            .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { notification in
                resumeAfterInterruptionIfNeeded(notification)
            }
            .onReceive(NotificationCenter.default.publisher(for: .AVAudioEngineConfigurationChange)) { _ in
                client.reactivateAudioRenderer()
            }
            .alert(item: $pendingHost) { host in
                Alert(
                    title: Text("连接到这台 Mac？"),
                    message: Text("请确认 Mac 上显示相同校验码：\n\(host.fingerprint)"),
                    primaryButton: .default(Text("连接")) {
                        connect(to: host)
                    },
                    secondaryButton: .cancel(Text("暂不")) {
                        dismissedHostIDs.insert(host.id)
                    }
                )
            }
        }
    }

    private var pairingCard: some View {
        CompanionCard {
            pairingStatusTitle
                .font(.title3.weight(.semibold))

            if let macName = client.pairedMacName {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(macName)
                        Text("当前输出：\(session.currentOutputName)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    // 与未连接时的「连接」同一位置：连上后原地变红色「断开」
                    Button("断开") {
                        client.forgetPairedMac()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(.red)
                    .accessibilityLabel("断开与 \(macName) 的连接")
                }
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                .background(.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else if client.hosts.isEmpty {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在自动寻找装有音频切换的 Mac…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(minHeight: 42)
            } else {
                ForEach(client.hosts) { host in
                    HStack {
                        Label(host.name, systemImage: "desktopcomputer")
                        Spacer()
                        Button("连接") {
                            connect(to: host)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .accessibilityLabel("连接到 \(host.name)")
                    }
                    .padding(.horizontal, 12)
                    .frame(minHeight: 42)
                    .background(.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }
        // 连接/断开、发现主机时平滑过渡
        .animation(.easeOut(duration: 0.16), value: client.state)
        .animation(.easeOut(duration: 0.16), value: client.pairedMacName)
    }

    private var aboutCard: some View {
        CompanionCard(title: "关于伴侣", icon: "info.circle") {
            Text("iPhone 只提供一个当前输出端点，本机扬声器与蓝牙音箱需要二选一。若要把两者作为独立声道，请将蓝牙音箱直接连接到 Mac。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            NavigationLink {
                CompanionPrivacyPolicyView()
            } label: {
                Label("隐私政策", systemImage: "hand.raised")
                    .font(.footnote.weight(.medium))
            }
        }
    }

    private var systemVolumeCard: some View {
        CompanionCard(title: "iPhone 系统音量", icon: "speaker.wave.2") {
            HStack {
                Text("当前输出：\(session.currentOutputName)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(session.currentOutputVolume * 100))%")
                    .font(.footnote.monospacedDigit())
            }
            SystemVolumeView()
                .frame(height: 30)
            Text("这里与 iPhone 的系统音量键和控制中心使用同一系统音量。Mac 仅显示此状态，不会远程修改它。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var pairingStatusTitle: some View {
        if case let .unavailable(message) = session.state {
            Label(message, systemImage: "speaker.slash.fill")
                .foregroundStyle(.red)
        } else {
            connectionStatusTitle
        }
    }

    @ViewBuilder
    private var connectionStatusTitle: some View {
        switch client.state {
        case .discovering, .notPaired:
            Label("正在寻找 Mac", systemImage: "magnifyingglass")
                .foregroundStyle(.primary)
        case .connecting:
            Label("正在连接", systemImage: "link")
                .foregroundStyle(.blue)
        case .ready:
            Label("已连接，等待音频", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .receiving:
            Label("正在接收音频", systemImage: "waveform")
                .foregroundStyle(.green)
        case let .unavailable(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }

    private func activateAudioOutput() {
        guard session.configurePlayback() else { return }
        client.updateCurrentOutput(
            name: session.currentOutputName,
            volume: session.currentOutputVolume
        )
        client.reactivateAudioRenderer()
    }

    private func connect(to host: DiscoveredCompanionHost) {
        guard session.configurePlayback() else { return }
        client.updateCurrentOutput(
            name: session.currentOutputName,
            volume: session.currentOutputVolume
        )
        client.connect(to: host)
    }

    private func resumeAfterInterruptionIfNeeded(_ notification: Notification) {
        guard CompanionAudioRecoveryPolicy.shouldResume(after: notification) else { return }
        activateAudioOutput()
    }

    private func offerFirstDiscoveredHost(from hosts: [DiscoveredCompanionHost]) {
        guard client.pairedMacName == nil,
              client.state != .connecting,
              pendingHost == nil,
              let host = hosts.first(where: { !dismissedHostIDs.contains($0.id) }) else { return }
        pendingHost = host
    }
}

private struct SystemVolumeView: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let volumeView = MPVolumeView(frame: .zero)
        volumeView.showsVolumeSlider = true
        volumeView.accessibilityLabel = "iPhone 系统音量"
        return volumeView
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}

private struct CompanionCard<Content: View>: View {
    let title: String?
    let icon: String?
    let content: Content

    init(
        title: String? = nil,
        icon: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title, let icon {
                Label(title, systemImage: icon)
                    .font(.headline)
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
    }
}

#Preview("未配对") {
    CompanionRootView(session: CompanionAudioSession(), client: CompanionSessionClient())
}

#Preview("已连接") {
    let session = CompanionAudioSession()
    session.pairForPreview(macName: "Mankeipun 的 Mac")
    return CompanionRootView(session: session, client: CompanionSessionClient())
}
