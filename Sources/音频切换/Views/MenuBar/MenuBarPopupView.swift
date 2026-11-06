import SwiftUI
import AppKit

struct EmptyStatePresentation {
    enum Action: Equatable {
        case openSystemSettings

        var title: String {
            switch self {
            case .openSystemSettings:
                "打开系统设置"
            }
        }
    }

    let symbolName: String
    let title: String
    let message: String
    let action: Action?

    var showsAction: Bool { action != nil }

    init(permissionStatus: AudioPermissionManager.PermissionStatus) {
        if permissionStatus == .denied {
            symbolName = "lock.shield"
            title = "需要系统音频权限"
            message = "请在系统设置中允许“音频切换”访问系统音频，然后重新播放声音。"
            action = .openSystemSettings
        } else {
            symbolName = "music.note"
            title = "等待音频播放"
            message = "播放声音后自动显示应用"
            action = nil
        }
    }
}

/// 可观察的尺寸代理，让 SwiftUI 内容尺寸变化能更新 NSPopover。
struct PopoverSizePolicy {
    func contentSize(for measuredSize: CGSize) -> CGSize {
        CGSize(
            width: ceil(measuredSize.width),
            height: ceil(measuredSize.height)
        )
    }
}

@Observable
final class PopoverSizeProxy {
    private var policy = PopoverSizePolicy()
    private(set) var size: CGSize = .zero {
        didSet { onSizeChanged?(size) }
    }
    var onSizeChanged: ((CGSize) -> Void)?

    func update(measuredSize: CGSize) {
        let newSize = policy.contentSize(for: measuredSize)
        if abs(size.width - newSize.width) > 1 || abs(size.height - newSize.height) > 1 {
            size = newSize
        }
    }
}

/// 主菜单栏弹窗。
struct MenuBarPopupView: View {
    let audioEngine: AudioEngineFacade
    let sizeProxy: PopoverSizeProxy
    @State private var selectedAppIndex: Int?

    var body: some View {
        @Bindable var permission = audioEngine.permission

        VStack(spacing: 0) {
            topBar
            Divider()
            appListSection
        }
        .onPreferenceChange(AppListSizeKey.self) { size in
            sizeProxy.update(measuredSize: size)
        }
        .alert("需要系统音频权限", isPresented: $permission.showsAuthorizationGuidance) {
            Button("打开系统设置") {
                permission.openSystemAudioRecordingSettings()
            }
            Button("稍后", role: .cancel) {}
        } message: {
            Text("要将应用声音发送到其他输出设备，请在 macOS 的“隐私与安全性 > 屏幕与系统音频录制”中允许“音频切换”。")
        }
        .fixedSize(horizontal: true, vertical: true)
    }

    // MARK: - 主页顶栏

    private var topBar: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            quitButton
            Spacer()
            SettingsLink {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .help("打开设置")
            .accessibilityLabel("打开设置")
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .frame(
            width: sizeProxy.size.width > 0 ? sizeProxy.size.width : nil,
            alignment: .leading
        )
    }

    // MARK: - App 列表

    private var appListSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            if audioEngine.displayableApps.isEmpty {
                emptyState
            } else {
                VStack(spacing: 1) {
                    ForEach(Array(audioEngine.displayableApps.enumerated()), id: \.element.id) { index, displayable in
                        Group {
                            switch displayable {
                            case .active(let app):
                                AppRowView(
                                    app: app,
                                    audioEngine: audioEngine
                                )
                            case .pinnedInactive(let info):
                                InactiveAppRowView(info: info, audioEngine: audioEngine)
                            }
                        }
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(selectedAppIndex == index
                                    ? Color.accentColor.opacity(0.12)
                                    : Color.clear)
                        )
                    }
                }
            }
        }
        .padding(.bottom, DesignTokens.Spacing.sm)
        .fixedSize(horizontal: true, vertical: false)
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: AppListSizeKey.self, value: geo.size)
            }
        )
    }

    private var emptyState: some View {
        let presentation = EmptyStatePresentation(permissionStatus: audioEngine.permission.status)

        return VStack(spacing: DesignTokens.Spacing.sm) {
            ZStack {
                Circle()
                    .fill(Color.primary.opacity(0.07))
                    .frame(width: 48, height: 48)
                Image(systemName: presentation.symbolName)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Text(presentation.title)
                .font(.system(size: 14, weight: .semibold))

            Text(presentation.message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if let action = presentation.action {
                Button(action.title) {
                    switch action {
                    case .openSystemSettings:
                        audioEngine.permission.openSystemAudioRecordingSettings()
                    }
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(width: 280)
        .frame(minHeight: 145)
        .padding(.vertical, DesignTokens.Spacing.md)
        .onAppear { audioEngine.permission.checkPermission() }
    }

    private var quitButton: some View {
        Button {
            NSApp.terminate(nil)
        } label: {
            Image(systemName: "power")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("退出音频切换")
        .accessibilityLabel("退出音频切换")
    }
}

// MARK: - Size Preference Key

private struct AppListSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}
