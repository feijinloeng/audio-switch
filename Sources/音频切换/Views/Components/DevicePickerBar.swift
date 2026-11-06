import SwiftUI
import AudioToolbox

enum DeviceDisplayName {
    static func label(for name: String, transport: TransportType) -> String {
        label(for: name, isBuiltInOutput: transport == .builtIn)
    }

    static func label(for candidate: PanoramaEndpointCandidate) -> String {
        label(for: candidate.name, isBuiltInOutput: candidate.transport == .builtIn)
    }

    private static func label(for name: String, isBuiltInOutput: Bool) -> String {
        if isBuiltInOutput { return "本机" }

        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()

        if lowercased.contains("airpods") {
            if lowercased.contains("airpods pro") { return "AirPods Pro" }
            if lowercased.contains("airpods max") { return "AirPods Max" }
            return "AirPods"
        }

        let knownBrands: [(needle: String, label: String)] = [
            ("jbl", "JBL"),
            ("sony", "Sony"),
            ("bose", "Bose"),
            ("beats", "Beats"),
            ("marshall", "Marshall"),
            ("sennheiser", "Sennheiser")
        ]
        if let brand = knownBrands.first(where: { lowercased.contains($0.needle) }) {
            return brand.label
        }

        let uppercased = trimmed.uppercased()
        if ["WH-", "WF-", "SRS-"].contains(where: { uppercased.hasPrefix($0) }) {
            return "Sony"
        }

        return trimmed.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? name
    }
}

enum DevicePickerLayout {
    static let outerLeadingInset = DesignTokens.Spacing.sm
    static let outerTrailingInset = DesignTokens.Spacing.sm
    static let innerLeadingInset: CGFloat = 0
    static let firstDeviceLeadingEdge = outerLeadingInset + innerLeadingInset
}

enum DevicePickerMotionPolicy {
    static let selection = DesignTokens.Animation.state
}

/// 一级与二级共用的设备小方块（图标在上、文字在下，居中），保证两处边距完全一致
struct SharedDeviceChip: View {
    let symbolName: String
    let label: String
    let isSelected: Bool
    var body: some View {
        VStack(spacing: DesignTokens.Spacing.xxs) {
            Image(systemName: symbolName)
                .font(.system(size: 14))
            Text(label)
                .font(DesignTokens.Typography.caption)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(minWidth: 44, maxWidth: 82, minHeight: 40)
        .padding(.horizontal, DesignTokens.Spacing.xs)
        .fixedSize(horizontal: true, vertical: false)
        .contentShape(Rectangle())
        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
    }
}

enum DevicePickerPresentation {
    /// Core Audio reports external devices in their discovery order. Keep that
    /// order, but pin the built-in output at the leading edge of the picker.
    static func ordered(_ devices: [AudioDevice]) -> [AudioDevice] {
        devices.filter(\.isBuiltInOutput)
            + devices.filter { !$0.isBuiltInOutput }
    }

    static func iconName(for device: AudioDevice) -> String {
        iconName(for: device.name, isBuiltInOutput: device.isBuiltInOutput)
    }

    static func iconName(for candidate: PanoramaEndpointCandidate) -> String {
        if case .iPhone = candidate.host { return "iphone" }
        return iconName(for: candidate.name, isBuiltInOutput: candidate.transport == .builtIn)
    }

    private static func iconName(for name: String, isBuiltInOutput: Bool) -> String {
        if isBuiltInOutput {
            return "laptopcomputer"
        }
        return isHeadphones(name) ? "headphones" : "hifispeaker.fill"
    }

    private static func isHeadphones(_ name: String) -> Bool {
        let normalized = name.lowercased()
        let headphoneMarkers = [
            "airpods", "headphone", "headset", "earbud", "耳机",
            "wh-", "wf-", "quietcomfort", "beats"
        ]
        return headphoneMarkers.contains { normalized.contains($0) }
    }

}

/// 横向显示所有输出设备，支持单击切换。
struct DevicePickerBar: View {
    let devices: [AudioDevice]
    let currentDeviceUID: String?
    let audioEngine: AudioEngineFacade
    let app: AudioApp
    let onRouteChanged: () -> Void

    @State private var isRequestingPermission = false
    @State private var routingMessage: String?
    @State private var latestRouteRequestID: UUID?
    @State private var isPanoramaExpanded = false
    @State private var deviceBeingRenamed: AudioDevice?
    @State private var deviceAliasDraft = ""
    @State private var showsDeviceAliasEditor = false

    private var systemDefaultUID: String {
        audioEngine.defaultOutputDeviceUID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                if devices.isEmpty {
                    Text("无可用输出设备")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    HStack(spacing: DesignTokens.Spacing.sm) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: DesignTokens.Spacing.xs) {
                                ForEach(DevicePickerPresentation.ordered(devices)) { device in
                                    deviceItemButton(
                                        symbolName: DevicePickerPresentation.iconName(
                                            for: device
                                        ),
                                        displayLabel: displayName(for: device),
                                        fullLabel: audioEngine.settingsManager.deviceAlias(for: device.uid)
                                            ?? device.name,
                                        isSelected: !isPanoramaActive
                                            && RoutingPolicy.effectiveDeviceUID(
                                                configuredUID: currentDeviceUID,
                                                systemDefaultUID: systemDefaultUID
                                            ) == device.uid,
                                        isEnabled: !isPanoramaActive
                                    ) { select(device) }
                                    .contextMenu {
                                        Button("自定义名称…") {
                                            beginRenaming(device)
                                        }
                                        if audioEngine.settingsManager.deviceAlias(for: device.uid) != nil {
                                            Button("恢复默认名称") {
                                                audioEngine.settingsManager.setDeviceAlias("", for: device.uid)
                                            }
                                        }
                                    }
                                }
                            }
                            .padding(.leading, DevicePickerLayout.innerLeadingInset)
                            .padding(.trailing, DesignTokens.Spacing.xxs)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        panoramaGroupButton
                    }
                }
            }

            if let routingMessage {
                Text(routingMessage)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
            }

            if isPanoramaExpanded {
                Divider()
                PanoramaInlineControlsView(
                    audioEngine: audioEngine,
                    app: app,
                    onPlaybackChanged: onRouteChanged
                )
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity)
        .onChange(of: isPanoramaActive) { _, isActive in
            // 关闭全景播放后自动收起全景列表
            guard !isActive else { return }
            withAnimation(DevicePickerExpansionPolicy.animation) {
                isPanoramaExpanded = false
            }
        }
        .padding(.leading, DevicePickerLayout.outerLeadingInset)
        .padding(.trailing, DevicePickerLayout.outerTrailingInset)
        .padding(.vertical, DesignTokens.Spacing.xs)
        .background(Color.primary.opacity(0.03))
        .alert("自定义设备名称", isPresented: $showsDeviceAliasEditor) {
            TextField("例如：客厅音箱", text: $deviceAliasDraft)
            Button("取消", role: .cancel) {
                deviceBeingRenamed = nil
            }
            Button("保存") {
                saveDeviceAlias()
            }
        } message: {
            Text("留空即可恢复“\(deviceBeingRenamed?.name ?? "设备")”的默认名称。")
        }
    }

    private func select(_ device: AudioDevice) {
        requestRoute(to: device.uid)
    }

    private var isPanoramaActive: Bool {
        audioEngine.isPanoramaGroupActive(for: app)
    }

    private func displayName(for device: AudioDevice) -> String {
        audioEngine.settingsManager.deviceAlias(for: device.uid)
            ?? DeviceDisplayName.label(for: device.name, transport: device.transport)
    }

    private func beginRenaming(_ device: AudioDevice) {
        deviceBeingRenamed = device
        deviceAliasDraft = audioEngine.settingsManager.deviceAlias(for: device.uid) ?? ""
        showsDeviceAliasEditor = true
    }

    private func saveDeviceAlias() {
        guard let deviceBeingRenamed else { return }
        audioEngine.settingsManager.setDeviceAlias(deviceAliasDraft, for: deviceBeingRenamed.uid)
        self.deviceBeingRenamed = nil
    }

    private var panoramaGroupButton: some View {
        Button {
            togglePanoramaExpansion()
        } label: {
            VStack(spacing: DesignTokens.Spacing.xxs) {
                Image(systemName: "hifispeaker.2.fill")
                    .font(.system(size: 14))
                Text("全景")
                    .font(DesignTokens.Typography.caption)
                    .lineLimit(1)
            }
            .frame(minWidth: 44, minHeight: 40)
            .contentShape(Rectangle())
            .foregroundStyle(isPanoramaActive ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.pressable)
        .help(isPanoramaExpanded ? "收起全景播放" : "展开全景播放")
        .accessibilityLabel("全景播放组")
        .accessibilityValue(isPanoramaExpanded ? "已展开" : (isPanoramaActive ? "已启用" : "未启用"))
        .accessibilityHint("在下方展开全景播放设置")
    }

    private func togglePanoramaExpansion() {
        withAnimation(DevicePickerExpansionPolicy.animation) {
            isPanoramaExpanded.toggle()
        }
    }

    private func requestRoute(to deviceUID: String) {
        performRoute(to: deviceUID)
    }

    private func performRoute(to deviceUID: String) {
        let requestID = UUID()
        latestRouteRequestID = requestID
        routingMessage = "正在切换输出设备…"
        Task { @MainActor in
            let succeeded = await audioEngine.routeAppWithRetry(app, to: deviceUID)
            guard latestRouteRequestID == requestID else { return }
            routingMessage = succeeded
                ? nil
                : "切换失败，原输出保持不变；请检查设备连接或重新授权"
            if succeeded { onRouteChanged() }
        }
    }

    @ViewBuilder
    private func deviceItemButton(
        symbolName: String,
        displayLabel: String,
        fullLabel: String,
        isSelected: Bool,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            SharedDeviceChip(symbolName: symbolName, label: displayLabel, isSelected: isSelected)
        }
        .buttonStyle(.pressable)
        .disabled(!isEnabled)
        .animation(DevicePickerMotionPolicy.selection.animation, value: isSelected)
        .help(isEnabled ? fullLabel : "全景播放期间不能切换单独输出")
        .accessibilityLabel(fullLabel)
        .accessibilityValue(
            isEnabled
                ? (isSelected ? "已选中" : "未选中")
                : "全景播放中，单独输出不可用"
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

}
