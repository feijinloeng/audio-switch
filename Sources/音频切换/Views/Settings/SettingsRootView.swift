import AppKit
import SwiftUI
import UserNotifications

enum SettingsWindowSizePolicy {
    static func contentSize(for measuredSize: CGSize, maximumSize: CGSize) -> CGSize {
        CGSize(
            width: min(ceil(measuredSize.width), maximumSize.width),
            height: min(ceil(measuredSize.height), maximumSize.height)
        )
    }
}

struct AdaptiveSettingsLayout: Layout {
    let maximumSize: CGSize

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard let content = subviews.first else { return .zero }
        return SettingsWindowSizePolicy.contentSize(
            for: content.sizeThatFits(.unspecified),
            maximumSize: maximumSize
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard let content = subviews.first else { return }
        content.place(
            at: bounds.origin,
            anchor: .topLeading,
            proposal: ProposedViewSize(bounds.size)
        )
    }
}

struct SettingsRootView: View {
    let audioEngine: AudioEngineFacade
    @State private var startupLaunchError: String?
    @State private var isRevertingStartupLaunch = false
    @State private var maximumContentSize = CGSize(width: 520, height: 520)
    @State private var showsPrivacyPolicy = false

    var body: some View {
        @Bindable var settings = audioEngine.settingsManager

        AdaptiveSettingsLayout(maximumSize: maximumContentSize) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                    SettingsControlRow("开机自启动") {
                        Toggle("开机自启动", isOn: $settings.appSettings.launchOnStartup)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .onChange(of: settings.appSettings.launchOnStartup) { _, enabled in
                                updateStartupLaunch(enabled)
                            }
                    }

                    SettingsControlRow("设备断开通知") {
                        Toggle("设备断开通知", isOn: $settings.appSettings.showDeviceDisconnectAlerts)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .onChange(of: settings.appSettings.showDeviceDisconnectAlerts) { _, enabled in
                                guard enabled else { return }
                                requestDeviceDisconnectNotificationPermissionIfNeeded()
                            }
                    }

                    SettingsControlRow("隐私政策") {
                        Button("查看") {
                            showsPrivacyPolicy = true
                        }
                    }

                    SettingsControlRow("iPhone 伴侣") {
                        CompanionDownloadButton(title: "下载")
                    }

                    if let startupLaunchError {
                        GridRow {
                        Label(startupLaunchError, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                                .gridCellColumns(2)
                        }
                    }

                    if let persistenceError = settings.perAppPersistenceError {
                        GridRow {
                            VStack(alignment: .leading, spacing: 5) {
                                Label("设置未保存", systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                Text("请检查磁盘空间或文件权限后重试。\(persistenceError)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Button("重试保存") {
                                    settings.flush()
                                }
                                .controlSize(.small)
                            }
                            .gridCellColumns(2)
                        }
                    }
            }
            .scenePadding()
            .fixedSize(horizontal: true, vertical: true)
            .onAppear {
                let actual = StartupLaunchManager.isEnabled
                guard settings.appSettings.launchOnStartup != actual else { return }
                isRevertingStartupLaunch = true
                settings.appSettings.launchOnStartup = actual
                DispatchQueue.main.async { isRevertingStartupLaunch = false }
            }
        }
        .background {
            SettingsWindowMetricsReader { size in
                guard size != maximumContentSize else { return }
                maximumContentSize = size
            }
        }
        .background(SettingsWindowTitle("设置"))
        .sheet(isPresented: $showsPrivacyPolicy) {
            MacPrivacyPolicyView()
        }
    }

    private func updateStartupLaunch(_ enabled: Bool) {
        guard !isRevertingStartupLaunch else { return }
        do {
            try StartupLaunchManager.apply(enabled)
            startupLaunchError = nil
        } catch {
            isRevertingStartupLaunch = true
            audioEngine.settingsManager.appSettings.launchOnStartup.toggle()
            DispatchQueue.main.async { isRevertingStartupLaunch = false }
            startupLaunchError = "无法更新开机自启动设置：\(error.localizedDescription)"
        }
    }

    private func requestDeviceDisconnectNotificationPermissionIfNeeded() {
        Task {
            let center = UNUserNotificationCenter.current()
            let notificationSettings = await center.notificationSettings()
            guard notificationSettings.authorizationStatus == .notDetermined else { return }
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
    }
}

private struct SettingsControlRow<Control: View>: View {
    let title: String
    let control: Control

    init(_ title: String, @ViewBuilder control: () -> Control) {
        self.title = title
        self.control = control()
    }

    var body: some View {
        GridRow {
            Text(title)
                .lineLimit(1)
            control
                .gridColumnAlignment(.leading)
        }
    }
}

struct SettingsWindowTitle: NSViewRepresentable {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    func makeNSView(context: Context) -> NSView {
        TitleView(title: title)
    }

    func updateNSView(_ view: NSView, context: Context) {
        view.window?.title = title
    }

    private final class TitleView: NSView {
        let title: String

        init(title: String) {
            self.title = title
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.title = title
        }
    }
}
