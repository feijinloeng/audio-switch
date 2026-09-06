import SwiftUI

/// The compact panorama configuration surface shown directly below an app's
/// output picker. It keeps the playback action and the controls that affect it
/// in one visible, short-lived menu-bar context.
struct PanoramaInlineControlsView: View {
    let audioEngine: AudioEngineFacade
    let app: AudioApp
    let onPlaybackChanged: () -> Void

    @State private var configuration: PanoramaGroupConfiguration
    @State private var endpointVolumes: [PanoramaEndpointID: Double] = [:]
    @State private var endpointMutes: [PanoramaEndpointID: Bool] = [:]
    @State private var isStartingPlayback = false
    @State private var playbackMessage: String?
    @State private var selectionMessage: String?
    @State private var showsStopConfirmation = false

    init(
        audioEngine: AudioEngineFacade,
        app: AudioApp,
        onPlaybackChanged: @escaping () -> Void = {}
    ) {
        self.audioEngine = audioEngine
        self.app = app
        self.onPlaybackChanged = onPlaybackChanged
        _configuration = State(initialValue: audioEngine.panoramaGroupConfiguration)
    }

    private var selectedIDs: Set<PanoramaEndpointID> {
        Set(configuration.members.map(\.endpointID))
    }

    private var selectedCandidates: [PanoramaEndpointCandidate] {
        audioEngine.panoramaEndpointCandidates.filter { selectedIDs.contains($0.id) }
    }

    /// The menu panel owns the user's live selection while it is open. Candidate
    /// discovery is refreshed again by the engine when playback starts, so a
    /// stale observation snapshot must not leave this button disabled after the
    /// user has already selected a valid number of members.
    private var canStartPanoramaPlayback: Bool {
        !isStartingPlayback
            && (2 ... PanoramaTopologyLimits.maximumMemberCount)
                .contains(configuration.members.count)
    }

    private var isPlaybackActive: Bool {
        audioEngine.isPanoramaGroupActive(for: app)
    }

    var body: some View {
        let outputStateRevision = audioEngine.outputStateRevision
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            endpointPicker

            if let selectionMessage {
                Text(selectionMessage)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.orange)
            }

            if configuration.members.count < 2 {
                Text("至少选择两个设备后即可开始。")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
            }

            if !selectedCandidates.isEmpty {
                Divider()
                VStack(spacing: 0) {
                    ForEach(Array(selectedCandidates.enumerated()), id: \.element.id) { index, candidate in
                        memberControls(for: candidate)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        if index < selectedCandidates.count - 1 {
                            Divider()
                                .padding(.vertical, DesignTokens.Spacing.sm)
                        }
                    }
                }
            }

            if let playbackMessage {
                Text(playbackMessage)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()
            companionDiscoveryRow
        }
        .padding(.top, DesignTokens.Spacing.sm)
        .onAppear { refreshEndpointVolumes() }
        .onChange(of: selectedIDs) { _, _ in refreshEndpointVolumes() }
        .onChange(of: outputStateRevision) { _, _ in refreshEndpointVolumes() }
        .onChange(of: audioEngine.isPanoramaGroupActive(for: app)) { _, _ in
            refreshEndpointVolumes()
        }
        .onChange(of: audioEngine.panoramaCompanionEndpointStatus) { _, _ in
            refreshEndpointVolumes()
        }
        .onChange(of: audioEngine.panoramaGroupConfiguration) { _, updatedConfiguration in
            guard updatedConfiguration != configuration else { return }
            configuration = updatedConfiguration
        }
        // 选中变化、开始/关闭按钮切换时，让详情行与按钮平滑过渡
        .animation(DesignTokens.Animation.state.animation, value: configuration)
        .animation(DesignTokens.Animation.state.animation, value: isPlaybackActive)
        .alert("关闭全景播放？", isPresented: $showsStopConfirmation) {
            Button("取消", role: .cancel) {}
            Button("关闭", role: .destructive) {
                stopPanoramaPlayback()
            }
        } message: {
            Text("关闭后将停止全景播放，并恢复到之前的输出设备。")
        }
    }

    @ViewBuilder
    private var startButton: some View {
        if isPlaybackActive {
            Button("关闭") {
                showsStopConfirmation = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(.red)
            .transition(.scale.combined(with: .opacity))
            .help("停止全景播放")
        } else {
            Button(isStartingPlayback ? "正在启动…" : "开始") {
                Task { await startPanoramaPlayback() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!canStartPanoramaPlayback)
            .transition(.scale.combined(with: .opacity))
        }
    }

    private var endpointPicker: some View {
        Group {
            if audioEngine.panoramaEndpointCandidates.isEmpty {
                Text("未发现可用的输出设备")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
            } else {
                endpointPickerContent
            }
        }
    }

    /// 复用一级菜单同一套组件：ScrollView + device 图标，与 DevicePickerBar 顶部那排完全同款，只是在全景里再显示一次。
    private var endpointPickerContent: some View {
        HStack(alignment: .center, spacing: DesignTokens.Spacing.sm) {
            // 与一级菜单共用同一视觉：横向滚动、可放多个设备，自适应宽度，8pt 起
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    ForEach(audioEngine.panoramaEndpointCandidates) { candidate in
                        endpointButton(candidate)
                    }
                }
                .padding(.horizontal, 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            startButton
        }
    }

    private func endpointButton(_ candidate: PanoramaEndpointCandidate) -> some View {
        let isSelected = selectedIDs.contains(candidate.id)
        return Button {
            if let reason = selectionDisabledReason(for: candidate) {
                selectionMessage = selectionMessageText(for: reason)
                return
            }
            toggleSelection(candidate)
            selectionMessage = nil
        } label: {
            SharedDeviceChip(
                symbolName: DevicePickerPresentation.iconName(for: candidate),
                label: displayLabel(for: candidate),
                isSelected: isSelected
            )
        }
        .buttonStyle(.pressable)
        .disabled(isSelectionDisabled(candidate))
        .animation(DevicePickerMotionPolicy.selection.animation, value: isSelected)
        .help(unavailableReason(for: candidate) ?? candidate.name)
        .accessibilityLabel(candidate.name)
        .accessibilityValue(isSelected ? "已选中" : "未选中")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func memberControls(
        for candidate: PanoramaEndpointCandidate
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            // 详情标题也复用同一套小方块，保证三兄弟与设备列表同一视觉
            HStack {
                SharedDeviceChip(
                    symbolName: DevicePickerPresentation.iconName(for: candidate),
                    label: displayLabel(for: candidate),
                    isSelected: false
                )
                Spacer()
            }
            .help(candidate.name)

            endpointVolumeControl(for: candidate)
            panoramaSlider(
                title: "延迟",
                value: manualDelayBinding(for: candidate),
                valueText: "\(configuration.member(for: candidate.id)?.manualDelayMilliseconds ?? 0) ms",
                onEditingChanged: { editing in
                    if !editing { persistManualDelay() }
                }
            )
        }
    }

    private func panoramaSlider(
        title: String,
        value: Binding<Double>,
        valueText: String,
        onEditingChanged: @escaping (Bool) -> Void = { _ in }
    ) -> some View {
        HStack(alignment: .center, spacing: DesignTokens.Spacing.xs) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .leading)
            VolumeSlider(
                value: value,
                isMuted: false,
                accessibilityLabel: title,
                accessibilityValue: { _ in valueText },
                onEditingChanged: onEditingChanged
            )
            .frame(width: DesignTokens.Dimensions.panoramaDetailSliderWidth)
            Text(valueText)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                // 右边缘与音量行的静音喇叭图标对齐（实测再回缩 6pt、右移 1pt）
                .frame(width: 49 + DesignTokens.Spacing.xs + DesignTokens.Dimensions.muteButtonWidth, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func endpointVolumeControl(
        for candidate: PanoramaEndpointCandidate
    ) -> some View {
        let isMuted = endpointMuted(for: candidate)
        let isIPhone = candidate.host != .thisMac
        let valueText = isMuted ? "--" : "\(Int(endpointVolume(for: candidate) * 100))%"

        return HStack(alignment: .center, spacing: DesignTokens.Spacing.xs) {
            Text("音量")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .leading)
            VolumeSlider(
                value: endpointVolumeBinding(for: candidate),
                isMuted: isMuted,
                accessibilityLabel: "\(candidate.name) 音量",
                accessibilityValue: { _ in valueText }
            )
            .frame(width: DesignTokens.Dimensions.panoramaDetailSliderWidth)
            .disabled(isIPhone)
            .help(endpointVolumeHelp(for: candidate))
            Text(valueText)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .frame(width: 54, alignment: .trailing)
            MuteButton(isMuted: isMuted) {
                guard !isIPhone else { return }
                _ = audioEngine.setPanoramaEndpointMute(candidate.id, to: !isMuted)
                refreshEndpointVolumes()
            }
            .frame(width: DesignTokens.Dimensions.muteButtonWidth)
            .disabled(isIPhone)
            .help(endpointMuteHelp(for: candidate))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var companionDiscoveryRow: some View {
        HStack(alignment: .bottom, spacing: DesignTokens.Spacing.xs) {
            Image(systemName: "iphone.radiowaves.left.and.right")
                .frame(width: 14)
            Text(
                audioEngine.isPanoramaCompanionAdvertising
                    ? "配对校验码：\(audioEngine.panoramaPairingFingerprint)"
                    : "iPhone 伴侣将在音频切换启动后自动发现"
            )
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: DesignTokens.Spacing.sm)
            CompanionDownloadButton(title: "下载伴侣")
        }
    }

    private func toggleSelection(_ candidate: PanoramaEndpointCandidate) {
        var members = configuration.members
        if selectedIDs.contains(candidate.id) {
            members.removeAll { $0.endpointID == candidate.id }
        } else {
            members.append(PanoramaGroupMember(endpointID: candidate.id))
        }
        save(members)
    }

    private func endpointVolume(for candidate: PanoramaEndpointCandidate) -> Double {
        endpointVolumes[candidate.id]
            ?? Double(audioEngine.getPanoramaEndpointVolume(candidate.id))
    }

    private func endpointMuted(for candidate: PanoramaEndpointCandidate) -> Bool {
        endpointMutes[candidate.id]
            ?? audioEngine.getPanoramaEndpointMute(candidate.id)
    }

    private func endpointVolumeBinding(for candidate: PanoramaEndpointCandidate) -> Binding<Double> {
        Binding(
            get: { endpointVolume(for: candidate) },
            set: { volume in
                let clampedVolume = min(max(volume, 0), 1)
                if audioEngine.setPanoramaEndpointVolume(candidate.id, to: Float(clampedVolume)) {
                    endpointVolumes[candidate.id] = Double(
                        audioEngine.getPanoramaEndpointVolume(candidate.id)
                    )
                } else {
                    endpointVolumes[candidate.id] = Double(
                        audioEngine.getPanoramaEndpointVolume(candidate.id)
                    )
                }
            }
        )
    }

    private func refreshEndpointVolumes() {
        for candidate in selectedCandidates {
            endpointVolumes[candidate.id] = Double(
                audioEngine.getPanoramaEndpointVolume(candidate.id)
            )
            endpointMutes[candidate.id] = audioEngine.getPanoramaEndpointMute(candidate.id)
        }
    }

    private func endpointVolumeHelp(for candidate: PanoramaEndpointCandidate) -> String {
        if case .iPhone = candidate.id {
            return "iPhone 当前系统音量的镜像；请直接在 iPhone 上调节。"
        }
        return "调整此设备的系统输出音量"
    }

    private func endpointMuteHelp(for candidate: PanoramaEndpointCandidate) -> String {
        if case .iPhone = candidate.id {
            return "iPhone 当前系统静音状态的镜像；请直接在 iPhone 上调节。"
        }
        return "切换此设备的系统静音"
    }

    private func manualDelayBinding(for candidate: PanoramaEndpointCandidate) -> Binding<Double> {
        Binding(
            get: {
                Double(configuration.member(for: candidate.id)?.manualDelayMilliseconds ?? 0)
                    / Double(PanoramaGroupMember.maximumManualDelayMilliseconds)
            },
            set: { normalizedDelay in
                guard configuration.member(for: candidate.id) != nil else { return }
                let maximumDelay = Double(PanoramaGroupMember.maximumManualDelayMilliseconds)
                let milliseconds = Int((normalizedDelay * maximumDelay / 10).rounded()) * 10
                updateMember(
                    candidate,
                    manualDelayMilliseconds: milliseconds,
                    saveImmediately: false
                )
                audioEngine.previewPanoramaDelay(
                    endpointID: candidate.id,
                    milliseconds: milliseconds
                )
            }
        )
    }

    private func updateMember(
        _ candidate: PanoramaEndpointCandidate,
        manualDelayMilliseconds: Int,
        saveImmediately: Bool
    ) {
        var members = configuration.members
        guard let index = members.firstIndex(where: { $0.endpointID == candidate.id }) else { return }
        members[index] = PanoramaGroupMember(
            endpointID: candidate.id,
            manualDelayMilliseconds: manualDelayMilliseconds
        )
        configuration = PanoramaGroupConfiguration(members: members)
        if saveImmediately {
            audioEngine.savePanoramaGroupConfiguration(configuration)
        }
    }

    private func persistManualDelay() {
        audioEngine.savePanoramaGroupConfiguration(configuration)
        playbackMessage = "延迟已保存。"
    }

    private func save(_ members: [PanoramaGroupMember]) {
        configuration = PanoramaGroupConfiguration(members: members)
        audioEngine.savePanoramaGroupConfiguration(configuration)
        playbackMessage = nil
    }

    private func startPanoramaPlayback() async {
        guard !isStartingPlayback else { return }
        playbackMessage = nil
        audioEngine.savePanoramaGroupConfiguration(configuration)
        isStartingPlayback = true
        let didStart = await startPanoramaRouteWithRetry()
        isStartingPlayback = false
        if didStart {
            refreshEndpointVolumes()
            onPlaybackChanged()
        }
        playbackMessage = didStart
            ? "已为“\(app.name)”启动全景播放。"
            : "无法启动全景播放。请确认“\(app.name)”仍在播放，且所有已选设备保持连接。"
    }

    private func stopPanoramaPlayback() {
        isStartingPlayback = false
        playbackMessage = "正在停止全景播放…"
        Task { @MainActor in
            let stopped = await audioEngine.stopPanoramaGroup(for: app)
            playbackMessage = stopped
                ? "已停止全景播放。"
                : "全景播放已关闭，但恢复原输出失败"
            refreshEndpointVolumes()
            onPlaybackChanged()
        }
    }

    private func startPanoramaRouteWithRetry() async -> Bool {
        for delay in [Duration.zero, .milliseconds(300), .milliseconds(700)] {
            if delay != .zero { try? await Task.sleep(for: delay) }
            if await audioEngine.routeAppToPanoramaGroup(app) { return true }
        }
        return false
    }

    private func isSelectionDisabled(_ candidate: PanoramaEndpointCandidate) -> Bool {
        if selectedIDs.contains(candidate.id) { return false }
        if case .unavailable = candidate.availability { return true }
        return false
    }

    private func unavailableReason(for candidate: PanoramaEndpointCandidate) -> String? {
        if case let .unavailable(reason) = candidate.availability { return reason }
        return selectionDisabledReason(for: candidate)
    }

    private func selectionDisabledReason(for candidate: PanoramaEndpointCandidate) -> String? {
        let selected = audioEngine.panoramaEndpointCandidates.filter { selectedIDs.contains($0.id) }
        return PanoramaSelectionConstraint.disabledReason(for: candidate, selected: selected)
    }

    private func selectionMessageText(for reason: String) -> String {
        if reason == "已达到四路上限" {
            return "最多选择四路，请先取消一个已选设备后再选择此设备。"
        }
        return reason
    }

    // 与一级完全同一套：直接复用一级的别名 + 命名逻辑（同一设备在两处显示必须一字不差）
    private func displayLabel(for candidate: PanoramaEndpointCandidate) -> String {
        if case let .macDevice(uid) = candidate.id {
            // 先找一级那台真实 AudioDevice，复用它的别名与品牌映射
            if let device = audioEngine.outputDevices.first(where: { $0.uid == uid }) {
                if let alias = audioEngine.settingsManager.deviceAlias(for: uid),
                   !alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return alias
                }
                return DeviceDisplayName.label(for: device.name, transport: device.transport)
            }
            // 兜底：设备表里暂时找不到时，仍走一级同款的 Candidate 映射（别名优先）
            if let alias = audioEngine.settingsManager.deviceAlias(for: uid),
               !alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return alias
            }
        }
        return DeviceDisplayName.label(for: candidate)
    }
}
