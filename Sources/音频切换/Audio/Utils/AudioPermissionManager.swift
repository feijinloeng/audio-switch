import AppKit
import Foundation

@Observable
@MainActor
final class AudioPermissionManager {
    enum PermissionStatus: Equatable {
        case unknown
        case authorized
        case denied
        case notDetermined
    }

    private let openSystemSettings: @MainActor () -> Void
    private(set) var status: PermissionStatus
    var showsAuthorizationGuidance = false

    init(
        openSystemSettings: @escaping @MainActor () -> Void = AudioPermissionManager.openSystemAudioRecordingSettings
    ) {
        self.openSystemSettings = openSystemSettings
        status = .notDetermined
    }

    /// Core Audio owns the system-audio TCC prompt when it creates a Process
    /// Tap. macOS has no public preflight API for this audio-only permission;
    /// using the screen-capture APIs would incorrectly request a second,
    /// broader "Screen & System Audio Recording" permission.
    func checkPermission() {
        // The latest confirmed capture result is the only reliable state.
    }

    /// Let the first Process Tap creation trigger macOS's audio-only prompt.
    /// After that attempt was denied, show our own recovery guidance before
    /// retrying so the user can return to System Settings deliberately.
    @discardableResult
    func requestPermissionIfNeeded() async -> Bool {
        guard status != .denied else {
            showsAuthorizationGuidance = true
            return false
        }
        return true
    }

    /// A successfully created Process Tap is direct evidence that the current
    /// process has access. It is not persisted; later checks still reflect a
    /// user revoking access in System Settings.
    func markAuthorized() {
        status = .authorized
    }

    /// The tap creation path reports a failed authorization through a failed
    /// route. Defer recovery guidance until the next user request, rather than
    /// stacking it on top of macOS's own denial dialog.
    func recordCaptureFailure() {
        status = .denied
    }

    func openSystemAudioRecordingSettings() {
        showsAuthorizationGuidance = false
        // A return from System Settings has no public audio-only status API.
        // Permit the next explicit route request to retry Process Tap creation.
        status = .notDetermined
        openSystemSettings()
    }

    private static func openSystemAudioRecordingSettings() {
        guard let settingsURL = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ) else { return }
        NSWorkspace.shared.open(settingsURL)
    }
}
