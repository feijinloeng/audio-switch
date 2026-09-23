import Foundation
import Observation

/// UI-facing control surface for topology-P routing. Views retain this small
/// synchronous API while the controller owns asynchronous Core Audio
/// transactions and all realtime resources.
@Observable
@MainActor
final class AudioEngineFacade {
    private let backend: TopologyPAudioEngine

    let permission: AudioPermissionManager
    let settingsManager: SettingsManager
    /// Keep companion state at the same observation boundary as the menu-bar
    /// SwiftUI views. Reaching through two observable objects can otherwise
    /// miss an invalidation while a status-item popup is already open.
    private(set) var panoramaCompanionEndpointStatus: PanoramaCompanionEndpointStatus?
    private(set) var isPanoramaGroupConfigurationReadOnly: Bool

    init(backend: TopologyPAudioEngine) {
        self.backend = backend
        permission = backend.permission
        settingsManager = backend.settingsManager
        panoramaCompanionEndpointStatus = backend.panoramaCompanionEndpointStatus
        isPanoramaGroupConfigurationReadOnly = backend.isPanoramaGroupConfigurationReadOnly
        backend.onPanoramaCompanionEndpointStatusChanged = { [weak self] status in
            self?.panoramaCompanionEndpointStatus = status
        }
        backend.onPanoramaGroupReadOnlyChanged = { [weak self] isReadOnly in
            self?.isPanoramaGroupConfigurationReadOnly = isReadOnly
        }
    }

    var displayableApps: [DisplayableApp] { backend.displayableApps }
    var outputDevices: [AudioDevice] { backend.outputDevices }
    var outputStateRevision: UInt64 { backend.outputStateRevision }
    var defaultOutputDeviceUID: String { backend.defaultOutputDeviceUID }
    var panoramaEndpointCandidates: [PanoramaEndpointCandidate] {
        // Make the facade-owned state an explicit dependency of the picker.
        // The engine still provides the local devices and builds the list.
        _ = panoramaCompanionEndpointStatus
        return backend.panoramaEndpointCandidates
    }
    var panoramaGroupConfiguration: PanoramaGroupConfiguration { backend.panoramaGroupConfiguration }
    var canActivatePanoramaGroup: Bool { backend.canActivatePanoramaGroup }
    var isPanoramaCompanionAdvertising: Bool { backend.isPanoramaCompanionAdvertising }
    var panoramaPairingFingerprint: String { backend.panoramaPairingFingerprint }

    func start() { backend.start() }
    func stop() { backend.stop() }

    func setOutputDeviceDisconnectHandler(_ handler: ((String) -> Void)?) {
        backend.onOutputDeviceDisconnected = handler
    }

    func setVolume(for app: AudioApp, to volume: Float) {
        backend.setVolume(for: app, to: volume)
    }

    func getVolume(for app: AudioApp) -> Float {
        backend.getVolume(for: app)
    }

    @discardableResult
    func setOutputVolume(for app: AudioApp, to volume: Float) -> Bool {
        backend.setOutputVolume(for: app, to: volume)
    }

    func getOutputVolume(for app: AudioApp) -> Float {
        backend.getOutputVolume(for: app)
    }

    @discardableResult
    func setOutputMute(for app: AudioApp, to muted: Bool) -> Bool {
        backend.setOutputMute(for: app, to: muted)
    }

    func getOutputMute(for app: AudioApp) -> Bool {
        backend.getOutputMute(for: app)
    }

    func getPanoramaEndpointVolume(_ endpointID: PanoramaEndpointID) -> Float {
        backend.getPanoramaEndpointVolume(endpointID)
    }

    @discardableResult
    func setPanoramaEndpointVolume(_ endpointID: PanoramaEndpointID, to volume: Float) -> Bool {
        backend.setPanoramaEndpointVolume(endpointID, to: volume)
    }

    func getPanoramaEndpointMute(_ endpointID: PanoramaEndpointID) -> Bool {
        backend.getPanoramaEndpointMute(endpointID)
    }

    @discardableResult
    func setPanoramaEndpointMute(_ endpointID: PanoramaEndpointID, to muted: Bool) -> Bool {
        backend.setPanoramaEndpointMute(endpointID, to: muted)
    }

    func setMute(for app: AudioApp, to muted: Bool) {
        backend.setMute(for: app, to: muted)
    }

    func getMute(for app: AudioApp) -> Bool {
        backend.getMute(for: app)
    }

    func getDeviceForApp(_ pid: pid_t) -> String? {
        backend.getDeviceForApp(pid)
    }

    func isFollowingDefault(_ pid: pid_t) -> Bool {
        backend.isFollowingDefault(pid)
    }

    @discardableResult
    func routeApp(_ app: AudioApp, to deviceUID: String?) -> Bool {
        backend.routeApp(app, to: deviceUID)
    }

    func routeAppWithRetry(_ app: AudioApp, to deviceUID: String?) async -> Bool {
        await backend.routeAppWithRetry(app, to: deviceUID)
    }

    func savePanoramaGroupConfiguration(_ configuration: PanoramaGroupConfiguration) {
        backend.savePanoramaGroupConfiguration(configuration)
    }

    func previewPanoramaDelay(endpointID: PanoramaEndpointID, milliseconds: Int) {
        backend.previewPanoramaDelay(endpointID: endpointID, milliseconds: milliseconds)
    }

    func isPanoramaGroupActive(for app: AudioApp) -> Bool {
        backend.isPanoramaGroupActive(for: app)
    }

    func routeAppToPanoramaGroup(_ app: AudioApp) async -> Bool {
        await backend.routeAppToPanoramaGroup(app)
    }

    func stopPanoramaGroup(for app: AudioApp) async -> Bool {
        await backend.stopPanoramaGroup(for: app)
    }

    func pinApp(_ app: AudioApp) { backend.pinApp(app) }
    func unpinApp(_ identifier: String) { backend.unpinApp(identifier) }
    func isPinned(_ app: AudioApp) -> Bool { backend.isPinned(app) }
    func ignoreApp(_ app: AudioApp) { backend.ignoreApp(app) }
    func unignoreApp(_ identifier: String) { backend.unignoreApp(identifier) }
}
