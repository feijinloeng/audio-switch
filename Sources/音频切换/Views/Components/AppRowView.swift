import SwiftUI
import AudioToolbox

enum DevicePickerExpansionPolicy {
    static let motion = DesignTokens.Animation.content
    static var animation: SwiftUI.Animation { motion.animation }
}

/// A row displaying a single audio app with volume control, mute, and routing.
struct AppRowView: View {
    let app: AudioApp
    let audioEngine: AudioEngineFacade

    @State private var deviceVolume: Double = 1
    @State private var showDevicePicker = false

    var body: some View {
        let isPanoramaActive = audioEngine.isPanoramaGroupActive(for: app)
        let systemMuted = audioEngine.getOutputMute(for: app)
        let outputStateRevision = audioEngine.outputStateRevision

        VStack(spacing: 0) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Button {
                    withAnimation(DevicePickerExpansionPolicy.animation) {
                        showDevicePicker.toggle()
                    }
                } label: {
                    HStack(spacing: DesignTokens.Spacing.xs) {
                        Image(nsImage: app.icon)
                            .resizable()
                            .frame(width: DesignTokens.Dimensions.iconSize,
                                   height: DesignTokens.Dimensions.iconSize)
                            .clipShape(RoundedRectangle(cornerRadius: 4))

                        Text(app.name)
                            .font(DesignTokens.Typography.rowName)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Image(systemName: showDevicePicker ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)

                    }
                    .frame(width: DesignTokens.Dimensions.appNameControlWidth, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(showDevicePicker ? "收起输出设备" : "选择输出设备")
                .accessibilityLabel("\(app.name) 输出设备")
                .accessibilityValue(showDevicePicker ? "已展开" : "已收起")

                // Panorama volume is controlled per endpoint in the expanded
                // device list. The application slider must not add a second
                // software ceiling on top of those physical device volumes.
                VolumeSlider(
                    value: VolumeSlider.clampedBinding(
                        get: { deviceVolume },
                        set: { setDeviceVolume($0) }
                    ),
                    isMuted: systemMuted || isPanoramaActive
                )
                    .frame(width: DesignTokens.Dimensions.sliderWidth)
                    .disabled(isPanoramaActive)
                    .help(isPanoramaActive ? "请在全景设备列表中分别调节音量" : "调整当前输出设备的系统音量")

                // Percentage
                Text(systemMuted || isPanoramaActive ? "--" : "\(Int(deviceVolume * 100))%")
                    .font(DesignTokens.Typography.percentage)
                    .foregroundColor(DesignTokens.Colors.textSecondary)
                    .frame(width: DesignTokens.Dimensions.percentageWidth, alignment: .trailing)

                // 静音按钮
                MuteButton(isMuted: systemMuted) {
                    guard !isPanoramaActive else { return }
                    _ = audioEngine.setOutputMute(for: app, to: !systemMuted)
                    refreshDeviceVolume()
                }
                .disabled(isPanoramaActive)
                .help(isPanoramaActive ? "请在全景设备列表中分别静音" : "切换当前输出设备的系统静音")
            }
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .padding(.vertical, DesignTokens.Spacing.xs)
            .frame(height: DesignTokens.Dimensions.rowContentHeight + DesignTokens.Spacing.sm)
            .contextMenu {
                if audioEngine.isPinned(app) {
                    Button("取消置顶") { audioEngine.unpinApp(app.persistenceIdentifier) }
                } else {
                    Button("置顶应用") { audioEngine.pinApp(app) }
                }
                Divider()
                Button("忽略此应用", role: .destructive) { audioEngine.ignoreApp(app) }
            }

            // Device picker bar (expandable)
            if showDevicePicker {
                DevicePickerBar(
                    devices: audioEngine.outputDevices,
                    currentDeviceUID: audioEngine.getDeviceForApp(app.id),
                    audioEngine: audioEngine,
                    app: app,
                    onRouteChanged: refreshDeviceVolume
                )
                .transition(.opacity)
            }

        }
        .onChange(of: isPanoramaActive) { _, _ in refreshDeviceVolume() }
        .onChange(of: outputStateRevision) { _, _ in refreshDeviceVolume() }
        // 首次出现时读取当前物理输出设备的系统音量。
        .onAppear { refreshDeviceVolume() }
    }

    private func refreshDeviceVolume() {
        deviceVolume = Double(audioEngine.getOutputVolume(for: app))
    }

    private func setDeviceVolume(_ volume: Double) {
        let clampedVolume = Float(min(max(volume, 0), 1))
        guard !audioEngine.isPanoramaGroupActive(for: app) else { return }
        if audioEngine.setOutputVolume(for: app, to: clampedVolume) {
            deviceVolume = Double(clampedVolume)
        } else {
            refreshDeviceVolume()
        }
    }

}

// MARK: - Inactive App Row

struct InactiveAppRowView: View {
    let info: PinnedAppInfo
    let audioEngine: AudioEngineFacade
    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "app.square")
                .font(.system(size: 16))
                .frame(width: DesignTokens.Dimensions.iconSize)
                .foregroundColor(DesignTokens.Colors.textTertiary)

            Text(info.displayName)
                .font(DesignTokens.Typography.rowName)
                .foregroundColor(DesignTokens.Colors.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: DesignTokens.Dimensions.appNameControlWidth, alignment: .leading)

            Spacer()

            Text("未播放")
                .font(DesignTokens.Typography.caption)
                .foregroundColor(DesignTokens.Colors.textTertiary)
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.vertical, DesignTokens.Spacing.xs)
        .frame(height: DesignTokens.Dimensions.rowContentHeight + DesignTokens.Spacing.sm)
        .contextMenu {
            Button("取消置顶") { audioEngine.unpinApp(info.persistenceIdentifier) }
        }
    }
}
