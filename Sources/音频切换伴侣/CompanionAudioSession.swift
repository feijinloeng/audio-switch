import AVFAudio
import Observation

enum CompanionAudioRecoveryPolicy {
    static func shouldResume(after notification: Notification) -> Bool {
        guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              AVAudioSession.InterruptionType(rawValue: rawType) == .ended else { return false }
        guard let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt else {
            return CompanionRecoveryPolicy.action(
                for: .interruptionEnded(shouldResume: true)
            ) == .reactivateAudio
        }
        let shouldResume = AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume)
        return CompanionRecoveryPolicy.action(
            for: .interruptionEnded(shouldResume: shouldResume)
        ) == .reactivateAudio
    }
}

@MainActor
@Observable
final class CompanionAudioSession {
    enum State: Equatable {
        case notPaired
        case ready
        case receiving
        case unavailable(message: String)
    }

    private let audioSession: AVAudioSession
    var state: State = .notPaired
    var pairedMacName: String?
    var currentOutputName = "未激活"
    var currentOutputVolume: Float = 1
    private var outputVolumeObservation: NSKeyValueObservation?

    init(audioSession: AVAudioSession = .sharedInstance()) {
        self.audioSession = audioSession
        currentOutputVolume = Self.clamped(audioSession.outputVolume)
        outputVolumeObservation = audioSession.observe(
            \.outputVolume,
            options: [.initial, .new]
        ) { [weak self] session, _ in
            let volume = Self.clamped(session.outputVolume)
            Task { @MainActor [weak self] in
                self?.currentOutputVolume = volume
            }
        }
    }

    @discardableResult
    func configurePlayback() -> Bool {
        do {
            // The playback category routes to A2DP automatically. Passing
            // allowBluetoothA2DP here is invalid because that option is only
            // for categories that also support audio input.
            try audioSession.setCategory(.playback, mode: .default)
            try audioSession.setActive(true)
            refreshRoute()
            guard !audioSession.currentRoute.outputs.isEmpty else {
                state = .unavailable(message: CompanionLocalizedMessage.text("companion.error.noOutput"))
                return false
            }
            state = .ready
            return true
        } catch {
            currentOutputName = "激活失败"
            state = .unavailable(message: CompanionLocalizedMessage.text("companion.error.audioOutput", error.localizedDescription))
            return false
        }
    }

    func refreshRoute() {
        currentOutputName = audioSession.currentRoute.outputs.first?.portName ?? "未发现输出"
        currentOutputVolume = Self.clamped(audioSession.outputVolume)
    }

    func pairForPreview(macName: String) {
        pairedMacName = macName
        state = .ready
    }

    private nonisolated static func clamped(_ volume: Float) -> Float {
        volume.isFinite ? min(max(volume, 0), 1) : 1
    }
}
