import Foundation

struct AppAudioState {
    var volume: Float
    var muted: Bool
    var persistenceIdentifier: String
}

@Observable
@MainActor
final class VolumeState {
    var states: [pid_t: AppAudioState] = [:] // SwiftUI observable
    private let settingsManager: SettingsManager?

    init(settingsManager: SettingsManager? = nil) {
        self.settingsManager = settingsManager
    }

    func restoreState(for pid: pid_t, identifier: String) {
        guard states[pid] == nil else { return }
        states[pid] = initialState(for: identifier)
    }

    private func initialState(for identifier: String) -> AppAudioState {
        AppAudioState(
            volume: Self.clampedVolume(settingsManager?.getVolume(for: identifier) ?? 1.0),
            muted: settingsManager?.getMute(for: identifier) ?? false,
            persistenceIdentifier: identifier
        )
    }

    func getVolume(for pid: pid_t) -> Float {
        states[pid]?.volume ?? 1.0
    }

    func setVolume(for pid: pid_t, to volume: Float, identifier: String? = nil) {
        let volume = Self.clampedVolume(volume)
        if var state = states[pid] {
            state.volume = volume
            if let id = identifier { state.persistenceIdentifier = id }
            states[pid] = state
            if let id = identifier { settingsManager?.setVolume(for: id, to: volume) }
        } else if let identifier = identifier {
            var state = initialState(for: identifier)
            state.volume = volume
            states[pid] = state
            settingsManager?.setVolume(for: identifier, to: volume)
        }
    }

    private static func clampedVolume(_ volume: Float) -> Float {
        volume.isFinite ? min(max(volume, 0), 1) : 1
    }

    func getMute(for pid: pid_t) -> Bool {
        states[pid]?.muted ?? false
    }

    func setMute(for pid: pid_t, to muted: Bool, identifier: String? = nil) {
        if var state = states[pid] {
            state.muted = muted
            if let id = identifier { state.persistenceIdentifier = id }
            states[pid] = state
            if let id = identifier { settingsManager?.setMute(for: id, to: muted) }
        } else if let identifier = identifier {
            var state = initialState(for: identifier)
            state.muted = muted
            states[pid] = state
            settingsManager?.setMute(for: identifier, to: muted)
        }
    }

    func cleanup(keeping pids: Set<pid_t>) {
        states = states.filter { pids.contains($0.key) }
    }
}
