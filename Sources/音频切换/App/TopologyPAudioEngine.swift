import AppKit
import AudioToolbox
import Darwin
import Foundation
import Observation
import OSLog

private actor TopologyPHALSnapshotReader {
    private let hal: SystemCoreAudioHAL

    init(hal: SystemCoreAudioHAL) {
        self.hal = hal
    }

    func read() -> (HALOutputSnapshot, HALProcessSnapshot) {
        (hal.outputSnapshot(), hal.processSnapshot())
    }
}

enum PanoramaPacketSchedule {
    static let interval: Duration = .milliseconds(5)

    static func nextDeadline(
        after previous: ContinuousClock.Instant,
        now: ContinuousClock.Instant
    ) -> ContinuousClock.Instant {
        let scheduled = previous.advanced(by: interval)
        return scheduled < now ? now.advanced(by: interval) : scheduled
    }
}

enum AudioAppPresentationHost {
    private static let webKitAuxiliaryBundleIDs: Set<String> = [
        "com.apple.WebKit.GPU",
        "com.apple.WebKit.Networking",
        "com.apple.WebKit.WebContent"
    ]

    static func isWebKitAuxiliary(bundleID: String?) -> Bool {
        bundleID.map(webKitAuxiliaryBundleIDs.contains) == true
    }

    static func matchingHostName(
        for auxiliaryName: String?,
        candidateNames: [String]
    ) -> String? {
        guard let auxiliaryName, !auxiliaryName.isEmpty else { return nil }
        return candidateNames
            .filter { !$0.isEmpty && auxiliaryName.hasPrefix($0) }
            .max(by: { $0.count < $1.count })
    }

    static func bundleID(forAudioOwnerBundleID bundleID: String?) -> String? {
        guard let bundleID else { return nil }
        if bundleID.hasPrefix("org.mozilla.firefoxdeveloperedition.") {
            return "org.mozilla.firefoxdeveloperedition"
        }
        if bundleID.hasPrefix("org.mozilla.firefox.") {
            return "org.mozilla.firefox"
        }
        if let helperRange = bundleID.range(
            of: ".helper",
            options: [.caseInsensitive, .backwards]
        ) {
            return String(bundleID[..<helperRange.lowerBound])
        }
        return nil
    }
}

/// The sole UI-facing audio controller. It translates public AppKit and HAL
/// facts into stable route identities, while all Process Tap/AUHAL lifecycle
/// work stays in the topology-P backend actor.
@Observable
@MainActor
final class TopologyPAudioEngine {
    private static let panoramaLogger = Logger(
        subsystem: "com.mankeipun.yinpinqiehuan",
        category: "panorama"
    )

    let permission: AudioPermissionManager
    let settingsManager: SettingsManager
    private let panoramaGroupStore: PanoramaGroupConfigurationStore

    private let hal: SystemCoreAudioHAL
    private let halSnapshotReader: TopologyPHALSnapshotReader
    private let processCatalog = CoreAudioProcessCatalog()
    private let ownerResolver = ProcessOwnerResolver()
    private let backend: TopologyPBackend
    private let routeBackend: DecoupledClockBridgedBackend
    private let panoramaComposer: PanoramaMacTopologyComposer
    private let companionHost: PanoramaCompanionHost
    private let transactions: AudioRouteTransactionExecutor
    private let coordinator: RouteCoordinator

    private var groupsByIdentity: [AppIdentity: [AudioProcessGroup]] = [:]
    private var appsByPID: [pid_t: AudioApp] = [:]
    private var descriptorsByUID: [String: OutputDeviceDescriptor] = [:]
    private var outputDeviceConnectionOrder = OutputDeviceConnectionOrder()
    private var routeRequestTokens: [AppIdentity: UUID] = [:]
    /// The last process-object generation committed to every managed route.
    /// A process list change can replace one app's opaque Core Audio handle
    /// without affecting another app, so reconciliation stays per identity.
    private var managedGroupsByIdentity: [AppIdentity: [AudioProcessGroup]] = [:]
    private var panoramaRoutesByIdentity: [AppIdentity: PanoramaMacRouteResources] = [:]
    private var panoramaNetworkBindingsByIdentity: [AppIdentity: [ActiveBinding]] = [:]
    private var panoramaNetworkPump: Task<Void, Never>?
    private var panoramaDelayPreviewTasks: [PanoramaEndpointID: Task<Void, Never>] = [:]
    private var recoveringPanoramaIdentities = Set<AppIdentity>()
    /// A transient Core Audio or companion disconnect must never overwrite the
    /// user's panorama choice. While a safe local fallback is active, retain
    /// that choice and resume panorama as soon as the selected topology returns.
    private var panoramaFallbackIdentities = Set<AppIdentity>()
    private var panoramaFailureDeadlines: [AppIdentity: ContinuousClock.Instant] = [:]
    private let panoramaFailureGracePeriod: Duration = .seconds(5)
    private var isolatingPanoramaEndpoints = Set<String>()
    private var reconcilingManagedIdentities = Set<AppIdentity>()
    private var presentationByPID: [pid_t: AppPresentation] = [:]
#if DEBUG
    private static let routeDiagnosticsLogger = Logger(
        subsystem: "com.mankeipun.yinpinqiehuan",
        category: "route-diagnostics"
    )
    private var routeDiagnosticsTasks: [AppIdentity: Task<Void, Never>] = [:]
#endif
    private var refreshTask: Task<Void, Never>?
    private var processPollingTask: Task<Void, Never>?
    private var isStarted = false
    private var halRefreshGeneration: UInt64 = 0

    private struct AppPresentation {
        let bundleID: String?
        let name: String
        let icon: NSImage
    }

    var displayableApps: [DisplayableApp] = []
    var outputDevices: [AudioDevice] = []
    /// Changes whenever Core Audio reports that an output device's volume or
    /// mute state may have changed. Rows use this to re-read the physical
    /// device state rather than maintaining an application-local copy.
    private(set) var outputStateRevision: UInt64 = 0
    private(set) var defaultOutputDeviceUID: String = ""
    private(set) var panoramaGroupConfiguration: PanoramaGroupConfiguration
    private(set) var isPanoramaCompanionAdvertising = false
    var panoramaPairingFingerprint: String { companionHost.pairingFingerprint }
    private(set) var panoramaCompanionEndpointStatus: PanoramaCompanionEndpointStatus?
    /// The facade owns the menu-bar observation boundary. Notify it explicitly
    /// whenever the authenticated companion publishes a new endpoint status so
    /// an already-open popup redraws its endpoint picker immediately.
    var onPanoramaCompanionEndpointStatusChanged: ((PanoramaCompanionEndpointStatus) -> Void)?

    init(
        permission: AudioPermissionManager,
        settingsManager: SettingsManager,
        hal: SystemCoreAudioHAL = SystemCoreAudioHAL()
    ) {
        self.permission = permission
        self.settingsManager = settingsManager
        self.hal = hal
        halSnapshotReader = TopologyPHALSnapshotReader(hal: hal)
        let panoramaGroupStore = PanoramaGroupConfigurationStore(
            storageURL: PanoramaGroupConfigurationStore.defaultStorageURL
        )
        self.panoramaGroupStore = panoramaGroupStore
        let sanitizedPanoramaConfiguration = Self.sanitizedPanoramaConfiguration(
            panoramaGroupStore.configuration
        )
        if sanitizedPanoramaConfiguration != panoramaGroupStore.configuration,
           !panoramaGroupStore.isReadOnly {
            panoramaGroupStore.save(sanitizedPanoramaConfiguration)
        }
        panoramaGroupConfiguration = panoramaGroupStore.configuration
        let backend = TopologyPBackend(hal: hal)
        self.backend = backend
        let routeBackend = DecoupledClockBridgedBackend(
            capture: backend,
            output: backend,
            binding: backend
        )
        self.routeBackend = routeBackend
        panoramaComposer = PanoramaMacTopologyComposer(
            capture: backend,
            output: backend,
            binding: backend
        )
        companionHost = PanoramaCompanionHost()
        transactions = AudioRouteTransactionExecutor(backend: routeBackend)
        coordinator = RouteCoordinator(initialHALEpoch: hal.serviceEpoch)
        companionHost.onEndpointStatusChanged = { [weak self] status in
            self?.handlePanoramaCompanionEndpointStatus(status)
        }
        settingsManager.onPerAppStoreLoaded = { [weak self] in
            self?.refresh()
        }
        panoramaGroupStore.onLoaded = { [weak self, panoramaGroupStore] in
            guard let self else { return }
            let sanitized = Self.sanitizedPanoramaConfiguration(
                panoramaGroupStore.configuration
            )
            if sanitized != panoramaGroupStore.configuration,
               !panoramaGroupStore.isReadOnly {
                panoramaGroupStore.save(sanitized)
            }
            self.panoramaGroupConfiguration = sanitized
            self.refresh()
        }
        refresh()
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        permission.checkPermission()
        hal.setEventHandler { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handle(event)
            }
        }
        companionHost.startAdvertising()
        isPanoramaCompanionAdvertising = true
        refresh()
        startProcessPolling()
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        refreshTask?.cancel()
        refreshTask = nil
        processPollingTask?.cancel()
        processPollingTask = nil
#if DEBUG
        cancelAllRouteDiagnostics()
#endif
        hal.stopObserving()
        companionHost.stop()
        isPanoramaCompanionAdvertising = false
        routeRequestTokens.removeAll()
        managedGroupsByIdentity.removeAll()
        panoramaFallbackIdentities.removeAll()
        panoramaFailureDeadlines.removeAll()
        let panoramaRoutes = panoramaRoutesByIdentity
        panoramaRoutesByIdentity.removeAll()
        let panoramaNetworkBindings = panoramaNetworkBindingsByIdentity.values.flatMap { $0 }
        panoramaNetworkBindingsByIdentity.removeAll()
        panoramaNetworkPump?.cancel()
        panoramaNetworkPump = nil
        reconcilingManagedIdentities.removeAll()
        Task { [transactions, panoramaComposer, backend] in
            await transactions.invalidateAllForCoreAudioServiceRestart()
            await backend.detachPanoramaNetworkBindings(panoramaNetworkBindings)
            for route in panoramaRoutes.values {
                await panoramaComposer.teardown(route)
            }
        }
    }

    func refresh() {
        halRefreshGeneration &+= 1
        let generation = halRefreshGeneration
        Task { [weak self, halSnapshotReader] in
            let (outputSnapshot, processSnapshot) = await halSnapshotReader.read()
            guard let self, self.halRefreshGeneration == generation else { return }
            self.refreshOutputs(snapshot: outputSnapshot)
            self.refreshProcesses(snapshot: processSnapshot)
            self.reconcilePanoramaEndpointIsolation()
            self.reconcilePanoramaFailureRecovery()
        }
    }

    func setVolume(for app: AudioApp, to volume: Float) {
        settingsManager.setVolume(for: app.persistenceIdentifier, to: volume)
        publishOrActivateDSP(for: app)
    }

    func getVolume(for app: AudioApp) -> Float {
        settingsManager.getVolume(for: app.persistenceIdentifier) ?? 1
    }

    func setOutputVolume(for app: AudioApp, to volume: Float) -> Bool {
        guard !isPanoramaGroupActive(for: app) else { return false }
        guard let device = outputVolumeDevice(for: app) else { return false }
        return device.id.setOutputVolumeScalar(volume)
    }

    func getOutputVolume(for app: AudioApp) -> Float {
        guard !isPanoramaGroupActive(for: app) else { return 1 }
        guard let device = outputVolumeDevice(for: app) else { return 1 }
        return device.id.readOutputVolumeScalar()
    }

    /// The mute switch belonging to the selected physical output device.
    /// This is deliberately separate from the per-app DSP mute that panorama
    /// playback uses: normal device playback mirrors macOS exactly.
    func getOutputMute(for app: AudioApp) -> Bool {
        guard !isPanoramaGroupActive(for: app),
              let device = outputVolumeDevice(for: app) else { return false }
        return device.id.readMuteState()
    }

    @discardableResult
    func setOutputMute(for app: AudioApp, to muted: Bool) -> Bool {
        guard !isPanoramaGroupActive(for: app),
              let device = outputVolumeDevice(for: app) else { return false }
        return device.id.setMuteState(muted)
    }

    func getPanoramaEndpointVolume(_ endpointID: PanoramaEndpointID) -> Float {
        switch endpointID {
        case let .macDevice(uid):
            return outputDevices.first(where: { $0.uid == uid })?.id.readOutputVolumeScalar() ?? 1
        case let .iPhone(peerID):
            return panoramaCompanionEndpointStatus?.peerID == peerID
                ? panoramaCompanionEndpointStatus?.outputVolume ?? 1
                : 1
        }
    }

    @discardableResult
    func setPanoramaEndpointVolume(_ endpointID: PanoramaEndpointID, to volume: Float) -> Bool {
        let clampedVolume = min(max(volume, 0), 1)
        switch endpointID {
        case let .macDevice(uid):
            guard let device = outputDevices.first(where: { $0.uid == uid }) else { return false }
            return device.id.setOutputVolumeScalar(clampedVolume)
        case .iPhone:
            // AVAudioSession.outputVolume is user-controlled on iOS. Never
            // replace it with a hidden stream gain or a non-public setter.
            return false
        }
    }

    func getPanoramaEndpointMute(_ endpointID: PanoramaEndpointID) -> Bool {
        switch endpointID {
        case let .macDevice(uid):
            return outputDevices.first(where: { $0.uid == uid })?.id.readMuteState() ?? false
        case let .iPhone(peerID):
            let volume = panoramaCompanionEndpointStatus?.peerID == peerID
                ? panoramaCompanionEndpointStatus?.outputVolume ?? 1
                : 1
            return volume <= 0
        }
    }

    @discardableResult
    func setPanoramaEndpointMute(_ endpointID: PanoramaEndpointID, to muted: Bool) -> Bool {
        guard case let .macDevice(uid) = endpointID,
              let device = outputDevices.first(where: { $0.uid == uid }) else { return false }
        return device.id.setMuteState(muted)
    }

    func setMute(for app: AudioApp, to muted: Bool) {
        settingsManager.setMute(for: app.persistenceIdentifier, to: muted)
        publishOrActivateDSP(for: app)
    }

    func getMute(for app: AudioApp) -> Bool {
        settingsManager.getMute(for: app.persistenceIdentifier) ?? false
    }

    func getDeviceForApp(_ pid: pid_t) -> String? {
        guard let app = appsByPID[pid], let identity = AppIdentity(bundleID: app.bundleID) else { return nil }
        guard case let .device(uid) = settingsManager.desiredRoute(for: identity) else { return nil }
        return uid
    }

    func isFollowingDefault(_ pid: pid_t) -> Bool {
        getDeviceForApp(pid) == nil
    }

    var panoramaEndpointCandidates: [PanoramaEndpointCandidate] {
        var candidates = outputDevices.map { device in
            PanoramaEndpointCandidate(
                id: .macDevice(uid: device.uid),
                name: device.name,
                host: .thisMac,
                transport: Self.panoramaTransport(for: device),
                availability: .available
            )
        }
        if let companion = panoramaCompanionEndpointStatus {
            candidates.append(
                PanoramaEndpointCandidate(
                    id: .iPhone(peerID: companion.peerID),
                    name: "\(companion.deviceName) · \(companion.outputName)",
                    host: .iPhone(peerID: companion.peerID),
                    transport: .network,
                    availability: companion.availability
                )
            )
        }
        return candidates
    }

    var canActivatePanoramaGroup: Bool {
        panoramaTopology() != nil
    }

    func isPanoramaGroupActive(for app: AudioApp) -> Bool {
        guard let identity = AppIdentity(bundleID: app.bundleID) else { return false }
        return panoramaRoutesByIdentity[identity] != nil
    }

    func routeAppToPanoramaGroup(_ app: AudioApp) async -> Bool {
        guard let identity = AppIdentity(bundleID: app.bundleID) else { return false }
        panoramaFallbackIdentities.remove(identity)
        panoramaFailureDeadlines.removeValue(forKey: identity)
        refresh()
        guard let currentApp = appsByPID[app.id] else { return false }
        return await apply(desired: .panoramaGroup, for: currentApp, identity: identity)
    }

    func stopPanoramaGroup(for app: AudioApp) async -> Bool {
        guard let identity = AppIdentity(bundleID: app.bundleID) else { return false }
        panoramaFallbackIdentities.remove(identity)
        panoramaFailureDeadlines.removeValue(forKey: identity)
        refresh()
        guard let currentApp = appsByPID[app.id] else { return false }
        let fallbackRoute: DesiredRoute
        if let lastUID = settingsManager.lastSuccessfulSingleDeviceRoute(for: identity),
           descriptorsByUID[lastUID]?.readiness.isPreflightReady == true {
            fallbackRoute = .device(uid: lastUID)
        } else {
            fallbackRoute = .followSystemDefault
        }
        return await apply(desired: fallbackRoute, for: currentApp, identity: identity)
    }

    func savePanoramaGroupConfiguration(_ configuration: PanoramaGroupConfiguration) {
        let sanitizedConfiguration = Self.sanitizedPanoramaConfiguration(configuration)
        let changedMembership = panoramaGroupConfiguration.members.map(\.endpointID)
            != sanitizedConfiguration.members.map(\.endpointID)
        let changedTiming = hasChangedTiming(
            from: panoramaGroupConfiguration,
            to: sanitizedConfiguration
        )
        let previousConfiguration = panoramaGroupConfiguration
        panoramaGroupStore.save(sanitizedConfiguration)
        guard !panoramaGroupStore.isReadOnly else { return }
        panoramaGroupConfiguration = sanitizedConfiguration
        reconcilePanoramaFailureRecovery()
        publishPanoramaMemberControls()
        if let remoteDelayMilliseconds = panoramaTopology()?.remoteDelayMilliseconds {
            companionHost.configureRemoteDelay(milliseconds: remoteDelayMilliseconds)
        }
        guard changedMembership || changedTiming else { return }
        if changedTiming, !changedMembership {
            publishActivePanoramaDelays(from: sanitizedConfiguration)
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.applyPanoramaMembershipChanges(
                from: previousConfiguration,
                to: sanitizedConfiguration
            )
        }
    }

    /// Applies an endpoint add/remove to active panorama routes without tearing
    /// down the whole route. A pure single local macDevice add or remove is
    /// hot-swapped with a fade (join starts silent then ramps in; remove fades
    /// out then isolates). Any other change falls back to a full rebuild.
    private func applyPanoramaMembershipChanges(
        from oldConfiguration: PanoramaGroupConfiguration,
        to newConfiguration: PanoramaGroupConfiguration
    ) async {
        let oldIDs = Set(oldConfiguration.members.map(\.endpointID))
        let newIDs = Set(newConfiguration.members.map(\.endpointID))
        let added = newIDs.subtracting(oldIDs)
        let removed = oldIDs.subtracting(newIDs)
        let identities = Array(panoramaRoutesByIdentity.keys)

        for identity in identities {
            guard appsByPID.values.contains(where: {
                AppIdentity(bundleID: $0.bundleID) == identity
            }) else { continue }

            if added.count == 1, removed.isEmpty,
               let addedID = added.first,
               case let .macDevice(uid) = addedID,
               let descriptor = descriptorsByUID[uid] {
                await applyPanoramaEndpointAdd(
                    uid: uid,
                    descriptor: descriptor,
                    delayMilliseconds: newConfiguration.member(for: addedID)?.manualDelayMilliseconds ?? 0,
                    identity: identity
                )
                continue
            }
            if removed.count == 1, added.isEmpty,
               let removedID = removed.first,
               case let .macDevice(uid) = removedID,
               newConfiguration.members.count >= 2,
               panoramaRoutesByIdentity[identity] != nil {
                await applyPanoramaEndpointRemove(uid: uid, identity: identity)
                continue
            }
            // The iPhone never owns Core Audio resources: joining or leaving is
            // a pure network-branch change, so the running route (and every
            // local speaker on it) keeps playing untouched.
            if added.count == 1, removed.isEmpty,
               let addedID = added.first,
               case .iPhone = addedID {
                await attachPanoramaIPhoneBranch(identity: identity)
                continue
            }
            if removed.count == 1, added.isEmpty,
               let removedID = removed.first,
               case .iPhone = removedID {
                await detachPanoramaIPhoneBranch(identity: identity)
                continue
            }
            // A reconnect mints a fresh peerID, so the saved member swaps
            // old→new. Re-attach is idempotent: existing rings are reused and
            // only the delay control is refreshed.
            if added.count == 1, removed.count == 1,
               let addedID = added.first, let removedID = removed.first,
               case .iPhone = addedID,
               case .iPhone = removedID {
                await attachPanoramaIPhoneBranch(identity: identity)
                continue
            }

            guard let app = appsByPID.values.first(where: {
                AppIdentity(bundleID: $0.bundleID) == identity
            }) else { continue }
            _ = await applyPanoramaGroup(
                for: app,
                identity: identity,
                minimumExecutableEndpointCount: 1
            )
        }
    }

    /// Hot-swaps one local output into a running panorama route and fades it in.
    private func applyPanoramaEndpointAdd(
        uid: String,
        descriptor: OutputDeviceDescriptor,
        delayMilliseconds: Int,
        identity: AppIdentity
    ) async {
        guard let current = panoramaRoutesByIdentity[identity] else { return }
        do {
            let updated = try await panoramaComposer.addEndpoint(
                device: descriptor,
                delayMilliseconds: delayMilliseconds,
                to: current,
                retainingAdditionalTargetsByCapture: panoramaNetworkTargets(
                    identity: identity,
                    route: current
                )
            )
            // The joining render session starts at gain 0. Publishing full gain
            // ramps it in over the render core's ~140ms fade.
            let newBindings = updated.bindings
                .filter { updatedAssignment in
                    !current.bindings.contains(where: {
                        $0.binding.token == updatedAssignment.binding.token
                    })
                }
                .map(\.binding)
            for binding in newBindings {
                await backend.publish(settings: panoramaSettings(), to: binding)
            }
            panoramaRoutesByIdentity[identity] = updated
            refreshPanoramaRouteDiagnostics(identity: identity)
            Self.panoramaLogger.notice(
                "panoramaTrace hot-swap added device=\(uid, privacy: .public) identity=\(identity.persistenceKey, privacy: .public)"
            )
        } catch {
            // Fail-safe: the old route is retained untouched.
            Self.panoramaLogger.error(
                "panoramaTrace hot-swap add failed device=\(uid, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
        }
    }

    /// Fades one local output out, then isolates it from the running route.
    private func applyPanoramaEndpointRemove(
        uid: String,
        identity: AppIdentity
    ) async {
        guard let current = panoramaRoutesByIdentity[identity] else { return }
        let removedBindings = current.bindings
            .filter { $0.output.deviceUID == uid }
            .map(\.binding)
        guard !removedBindings.isEmpty else { return }
        // Fade out first: publish muted so the render ramps gain to zero.
        for binding in removedBindings {
            await backend.publish(
                settings: PerAppDSPSettings(volume: 1, muted: true),
                to: binding
            )
        }
        try? await Task.sleep(for: .milliseconds(300))
        do {
            let updated = try await panoramaComposer.isolate(
                endpointUID: uid,
                from: current,
                retainingAdditionalTargetsByCapture: panoramaNetworkTargets(
                    identity: identity,
                    route: current
                )
            )
            panoramaRoutesByIdentity[identity] = updated
            refreshPanoramaRouteDiagnostics(identity: identity)
            Self.panoramaLogger.notice(
                "panoramaTrace hot-swap removed device=\(uid, privacy: .public) identity=\(identity.persistenceKey, privacy: .public)"
            )
        } catch {
            // Restore gain if isolate failed so the speaker stays audible.
            for binding in removedBindings {
                await backend.publish(settings: panoramaSettings(), to: binding)
            }
            Self.panoramaLogger.error(
                "panoramaTrace hot-swap remove failed device=\(uid, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
        }
    }

    /// Hot-attaches the authenticated iPhone as a pure network branch of an
    /// already-running panorama route. Local outputs, captures, and bindings
    /// are untouched; the capture fan-out gains one ring through the same
    /// generation-safe snapshot publication used by local endpoint hot-swap.
    private func attachPanoramaIPhoneBranch(identity: AppIdentity) async {
        guard let current = panoramaRoutesByIdentity[identity] else { return }
        do {
            let bindings = try await backend.attachPanoramaNetworkBindings(for: current.captures)
            for binding in bindings {
                await backend.publish(settings: panoramaSettings(), to: binding)
            }
            panoramaNetworkBindingsByIdentity[identity] = bindings
            let delayMilliseconds = panoramaTopology()?.remoteDelayMilliseconds ?? 0
            companionHost.configureRemoteDelay(milliseconds: delayMilliseconds)
            ensurePanoramaNetworkPump()
            Self.panoramaLogger.notice(
                "panoramaTrace hot-swap attached iPhone branch identity=\(identity.persistenceKey, privacy: .public)"
            )
        } catch {
            Self.panoramaLogger.error(
                "panoramaTrace hot-swap iPhone attach failed error=\(String(describing: error), privacy: .public)"
            )
        }
    }

    /// Hot-detaches the iPhone network branch. Remaining local endpoints keep
    /// playing; only the capture fan-out snapshot drops the network rings.
    private func detachPanoramaIPhoneBranch(identity: AppIdentity) async {
        let bindings = panoramaNetworkBindingsByIdentity.removeValue(forKey: identity) ?? []
        stopPanoramaNetworkPumpIfUnused()
        guard !bindings.isEmpty else { return }
        await backend.detachPanoramaNetworkBindings(bindings)
        Self.panoramaLogger.notice(
            "panoramaTrace hot-swap detached iPhone branch identity=\(identity.persistenceKey, privacy: .public)"
        )
    }

    /// Network bindings that must survive a capture fan-out republication.
    /// Without them, rewriting the fan-out for a local hot-swap would drop the
    /// authenticated iPhone rings and mute the companion mid-playback.
    private func panoramaNetworkTargets(
        identity: AppIdentity,
        route: PanoramaMacRouteResources
    ) -> [UUID: [RouteBindingTarget]] {
        let networkBindings = panoramaNetworkBindingsByIdentity[identity] ?? []
        return Dictionary(uniqueKeysWithValues: route.captures.map { capture in
            (
                capture.token,
                networkBindings
                    .filter { $0.instanceID == capture.instanceID }
                    .map(RouteBindingTarget.init)
            )
        })
    }

    /// Restarts per-device route diagnostics so a hot-swapped endpoint is
    /// monitored. No-op in release builds.
    private func refreshPanoramaRouteDiagnostics(identity: AppIdentity) {
#if DEBUG
        guard let route = panoramaRoutesByIdentity[identity] else {
            cancelRouteDiagnostics(for: identity)
            return
        }
        let byOutput = Dictionary(
            grouping: route.bindings,
            by: { $0.output.deviceUID }
        )
        startRouteDiagnostics(
            for: identity,
            devices: byOutput.map { deviceUID, assignments in
                (deviceUID: deviceUID, bindings: assignments.map(\.binding))
            }
        )
#endif
    }

    /// Debounced drag-preview path. It deliberately bypasses persistence and
    /// publishes only to an already-running endpoint delay line.
    func previewPanoramaDelay(endpointID: PanoramaEndpointID, milliseconds: Int) {
        let clamped = min(
            max(milliseconds, 0),
            PanoramaGroupMember.maximumManualDelayMilliseconds
        )
        panoramaDelayPreviewTasks[endpointID]?.cancel()
        panoramaDelayPreviewTasks[endpointID] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(16))
            guard let self, !Task.isCancelled else { return }
            await self.publishActivePanoramaDelay(
                endpointID: endpointID,
                milliseconds: clamped
            )
            self.panoramaDelayPreviewTasks[endpointID] = nil
        }
    }

    private func publishActivePanoramaDelays(
        from configuration: PanoramaGroupConfiguration
    ) {
        for member in configuration.members {
            Task { @MainActor [weak self] in
                await self?.publishActivePanoramaDelay(
                    endpointID: member.endpointID,
                    milliseconds: member.manualDelayMilliseconds
                )
            }
        }
    }

    private func publishActivePanoramaDelay(
        endpointID: PanoramaEndpointID,
        milliseconds: Int
    ) async {
        switch endpointID {
        case let .macDevice(uid):
            for resources in panoramaRoutesByIdentity.values {
                try? await panoramaComposer.updateManualDelay(
                    endpointUID: uid,
                    milliseconds: milliseconds,
                    in: resources
                )
            }
        case .iPhone:
            // The companion keeps its jitter buffer intact and adjusts the
            // running AVAudioEngine delay node.
            companionHost.configureRemoteDelay(milliseconds: milliseconds)
        }
    }

    /// Schedules a user route request for callers that need the historical
    /// synchronous façade. The picker uses `routeAppWithRetry` and receives
    /// the real committed result before it clears its progress message.
    @discardableResult
    func routeApp(_ app: AudioApp, to deviceUID: String?) -> Bool {
        Task { @MainActor [weak self] in
            _ = await self?.routeAppWithRetry(app, to: deviceUID)
        }
        return true
    }

    func routeAppWithRetry(_ app: AudioApp, to deviceUID: String?) async -> Bool {
        guard let identity = AppIdentity(bundleID: app.bundleID) else { return false }
        let requestToken = UUID()
        routeRequestTokens[identity] = requestToken
        defer {
            if routeRequestTokens[identity] == requestToken {
                routeRequestTokens.removeValue(forKey: identity)
            }
        }

        let desired = deviceUID.map { DesiredRoute.device(uid: $0) } ?? .followSystemDefault
        for delay in [Duration.zero, .milliseconds(500), .seconds(1)] {
            if delay != .zero { try? await Task.sleep(for: delay) }
            guard routeRequestTokens[identity] == requestToken else { return false }
            refresh()
            guard let currentApp = appsByPID[app.id] else { return false }
            if await apply(desired: desired, for: currentApp, identity: identity) {
                return true
            }
        }
        return false
    }

    func pinApp(_ app: AudioApp) {
        settingsManager.pinApp(
            app.persistenceIdentifier,
            info: PinnedAppInfo(
                persistenceIdentifier: app.persistenceIdentifier,
                displayName: app.name,
                bundleID: app.bundleID
            )
        )
        rebuildDisplayableApps()
    }

    func unpinApp(_ identifier: String) {
        settingsManager.unpinApp(identifier)
        rebuildDisplayableApps()
    }

    func isPinned(_ app: AudioApp) -> Bool {
        settingsManager.isPinned(app.persistenceIdentifier)
    }

    func ignoreApp(_ app: AudioApp) {
        settingsManager.ignoreApp(
            app.persistenceIdentifier,
            info: IgnoredAppInfo(
                persistenceIdentifier: app.persistenceIdentifier,
                displayName: app.name,
                bundleID: app.bundleID
            )
        )
        if let identity = AppIdentity(bundleID: app.bundleID) {
#if DEBUG
            cancelRouteDiagnostics(for: identity)
#endif
            managedGroupsByIdentity.removeValue(forKey: identity)
            reconcilingManagedIdentities.remove(identity)
            let panoramaRoute = panoramaRoutesByIdentity.removeValue(forKey: identity)
            let panoramaNetworkBindings = panoramaNetworkBindingsByIdentity.removeValue(forKey: identity) ?? []
            stopPanoramaNetworkPumpIfUnused()
            Task { [transactions, panoramaComposer, backend] in
                await transactions.teardown(identity: identity)
                await backend.detachPanoramaNetworkBindings(panoramaNetworkBindings)
                if let panoramaRoute {
                    await panoramaComposer.teardown(panoramaRoute)
                }
            }
        }
        refresh()
    }

    func unignoreApp(_ identifier: String) {
        settingsManager.unignoreApp(identifier)
        refresh()
    }

    private func refreshOutputs(snapshot: HALOutputSnapshot) {
        // 系统 HAL 快照的设备 UID 理论上唯一，但防御重复 UID 以免整 App 崩溃
        // （与 refreshProcesses 的重复 PID 崩溃同类）。
        descriptorsByUID = Dictionary(
            snapshot.devices.map { ($0.uid, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        defaultOutputDeviceUID = snapshot.defaultDeviceUID ?? ""
        let discoveredDevices: [AudioDevice] = snapshot.devices.compactMap { descriptor in
            guard let deviceID = hal.resolveOutputDeviceID(uid: descriptor.uid) else { return nil }
            return AudioDevice(
                id: deviceID,
                uid: descriptor.uid,
                name: descriptor.name,
                transport: deviceID.readTransportType(),
                icon: nil
            )
        }
        outputDevices = outputDeviceConnectionOrder.ordered(discoveredDevices)
    }

    private static func sanitizedPanoramaConfiguration(
        _ configuration: PanoramaGroupConfiguration
    ) -> PanoramaGroupConfiguration {
        PanoramaGroupConfiguration(members: configuration.members.filter { member in
            guard case let .macDevice(uid) = member.endpointID else { return true }
            return InternalCoreAudioDevicePolicy.isSelectableOutput(uid: uid)
        })
    }

    private func handlePanoramaCompanionEndpointStatus(
        _ status: PanoramaCompanionEndpointStatus
    ) {
        panoramaCompanionEndpointStatus = status
        onPanoramaCompanionEndpointStatusChanged?(status)
        let endpointID = PanoramaEndpointID.iPhone(peerID: status.peerID)
        guard !panoramaGroupConfiguration.members.contains(where: {
            $0.endpointID == endpointID
        }), let oldIndex = panoramaGroupConfiguration.members.firstIndex(where: {
            if case .iPhone = $0.endpointID { return true }
            return false
        }) else {
            reconcilePanoramaFailureRecovery()
            return
        }

        var members = panoramaGroupConfiguration.members
        let oldMember = members[oldIndex]
        members[oldIndex] = PanoramaGroupMember(
            endpointID: endpointID,
            manualDelayMilliseconds: oldMember.manualDelayMilliseconds
        )
        savePanoramaGroupConfiguration(PanoramaGroupConfiguration(members: members))
    }

    private func reconcilePanoramaFailureRecovery() {
        let identities = Set(panoramaRoutesByIdentity.keys).union(panoramaFallbackIdentities)
        let clock = ContinuousClock()
        let now = clock.now
        for identity in identities {
            let action = PanoramaFaultRecoveryPlanner.action(
                configuration: panoramaGroupConfiguration,
                candidates: panoramaEndpointCandidates,
                lastSuccessfulSingleDeviceUID: settingsManager.lastSuccessfulSingleDeviceRoute(for: identity)
            )
            switch action {
            case .remainActive:
                panoramaFailureDeadlines.removeValue(forKey: identity)
                guard panoramaFallbackIdentities.contains(identity),
                      reconcilingManagedIdentities.insert(identity).inserted,
                      let app = appsByPID.values.first(where: {
                          AppIdentity(bundleID: $0.bundleID) == identity
                      }) else { continue }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    defer { self.reconcilingManagedIdentities.remove(identity) }
                    _ = await self.applyPanoramaGroup(for: app, identity: identity)
                }
                continue
            case let .fallBackToSingleDevice(uid):
                guard panoramaRoutesByIdentity[identity] != nil else { continue }
                let desired = DesiredRoute.device(uid: uid)
                guard let deadline = panoramaFailureDeadlines[identity] else {
                    panoramaFailureDeadlines[identity] = now.advanced(by: panoramaFailureGracePeriod)
                    Self.panoramaLogger.notice(
                        "Panorama endpoint snapshot is temporarily unavailable; retaining the route during the recovery grace period"
                    )
                    continue
                }
                guard now >= deadline else { continue }
                beginPanoramaFallback(for: identity, app: app(for: identity), desired: desired)
            case .fallBackToSystemDefault:
                guard panoramaRoutesByIdentity[identity] != nil else { continue }
                guard let deadline = panoramaFailureDeadlines[identity] else {
                    panoramaFailureDeadlines[identity] = now.advanced(by: panoramaFailureGracePeriod)
                    Self.panoramaLogger.notice(
                        "Panorama endpoint snapshot is temporarily unavailable; retaining the route during the recovery grace period"
                    )
                    continue
                }
                guard now >= deadline else { continue }
                beginPanoramaFallback(for: identity, app: app(for: identity), desired: .followSystemDefault)
            }
        }
    }

    private func beginPanoramaFallback(
        for identity: AppIdentity,
        app: AudioApp?,
        desired: DesiredRoute
    ) {
        guard recoveringPanoramaIdentities.insert(identity).inserted,
              let app else { return }
        panoramaFallbackIdentities.insert(identity)
        panoramaFailureDeadlines.removeValue(forKey: identity)
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.recoveringPanoramaIdentities.remove(identity) }
            // Keep the persisted route as `.panoramaGroup`: this is a live
            // safety fallback, not an instruction from the user to abandon it.
            if !(await self.apply(
                desired: desired,
                for: app,
                identity: identity,
                persistDesiredRoute: false
            )), desired != .followSystemDefault {
                _ = await self.apply(
                    desired: .followSystemDefault,
                    for: app,
                    identity: identity,
                    persistDesiredRoute: false
                )
            }
        }
    }

    private func app(for identity: AppIdentity) -> AudioApp? {
        appsByPID.values.first { AppIdentity(bundleID: $0.bundleID) == identity }
    }

    /// A physical local endpoint can disappear while one or more remaining
    /// local/remote branches are still healthy. Remove only that AUHAL branch
    /// and keep the Process Tap plus the authenticated iPhone fan-out alive.
    /// If it was the last local branch, isolation is still valid when a remote
    /// iPhone target remains; otherwise the existing all-endpoint recovery
    /// falls back to the remembered single-device route.
    private func reconcilePanoramaEndpointIsolation() {
        for (identity, route) in panoramaRoutesByIdentity {
            guard let missingOutput = route.outputs.first(where: {
                // Production HAL snapshots describe connected, usable outputs
                // as `formatReady`. The AUHAL session owns the real IO probe;
                // treating the snapshot as if it must already be `ioReady`
                // would immediately isolate every successfully started route.
                descriptorsByUID[$0.deviceUID]?.readiness.isPreflightReady != true
            }) else { continue }
            let key = "\(identity.persistenceKey):\(missingOutput.deviceUID)"
            guard isolatingPanoramaEndpoints.insert(key).inserted else { continue }
            let retainedTargets = panoramaNetworkTargets(identity: identity, route: route)
            Task { @MainActor [weak self, panoramaComposer] in
                guard let self else { return }
                defer { self.isolatingPanoramaEndpoints.remove(key) }
                guard let current = self.panoramaRoutesByIdentity[identity] else { return }
                do {
                    let isolated = try await panoramaComposer.isolate(
                        endpointUID: missingOutput.deviceUID,
                        from: current,
                        retainingAdditionalTargetsByCapture: retainedTargets
                    )
                    self.panoramaRoutesByIdentity[identity] = isolated
                } catch {
                    // A sole local endpoint without a remaining remote branch
                    // is handled by the all-failed recovery path below.
                    self.reconcilePanoramaFailureRecovery()
                }
            }
        }
    }

    private func refreshProcesses(snapshot processSnapshot: HALProcessSnapshot) {
        // NSWorkspace can transiently report an invalid PID (for example -1
        // while an application is launching or terminating) and can list the
        // same PID twice. Building dictionaries from that raw list with
        // `uniqueKeysWithValues` would crash the whole app, so keep only valid
        // PIDs and let a duplicate collapse to a single entry.
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.processIdentifier > 0 }
        let audioProcessPIDs = Set(processSnapshot.processes.map(\.pid))
        let applicationFacts = Dictionary(
            running.map {
                ($0.processIdentifier, DisplayableApplicationFact(
                    pid: $0.processIdentifier,
                    bundleID: $0.bundleIdentifier,
                    isDisplayableGUI: $0.activationPolicy == .regular && $0.bundleURL?.pathExtension == "app",
                    isDirectAudioOwner: audioProcessPIDs.contains($0.processIdentifier)
                        && Self.isDirectAudioOwner($0)
                ))
            },
            uniquingKeysWith: { first, _ in first }
        )
        let allGroups = processCatalog.replace(
            snapshot: processSnapshot,
            resolver: ownerResolver,
            applicationsByPID: applicationFacts,
            parentPID: Self.parentPID
        )
        let groups = allGroups.filter {
            AudioAppEligibility.isRoutable(bundleID: $0.key.app.bundleID)
        }
        groupsByIdentity = Dictionary(grouping: groups.values, by: { $0.instanceID.app })

        let runningByPID = Dictionary(
            running.map { ($0.processIdentifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let runningPIDs = Set(runningByPID.keys)
        presentationByPID = presentationByPID.filter { runningPIDs.contains($0.key) }
        var refreshed: [pid_t: AudioApp] = [:]
        for group in groups.values {
            let instance = group.instanceID
            guard let runningApp = runningByPID[instance.ownerPID],
                  !settingsManager.isIgnored(instance.app.persistenceKey) else { continue }
            let presentation: AppPresentation
            if let cached = presentationByPID[instance.ownerPID],
               cached.bundleID == instance.app.bundleID {
                presentation = cached
            } else {
                let hostPresentation = Self.presentationHost(
                    for: instance.app.bundleID,
                    runningApplication: runningApp,
                    runningApplications: running,
                    workspace: .shared
                )
                let refreshedPresentation = AppPresentation(
                    bundleID: instance.app.bundleID,
                    name: hostPresentation?.name
                        ?? runningApp.localizedName
                        ?? instance.app.persistenceKey,
                    icon: hostPresentation?.icon
                        ?? runningApp.icon
                        ?? NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil)
                        ?? NSImage()
                )
                presentationByPID[instance.ownerPID] = refreshedPresentation
                presentation = refreshedPresentation
            }
            refreshed[instance.ownerPID] = AudioApp(
                id: instance.ownerPID,
                name: presentation.name,
                icon: presentation.icon,
                bundleID: instance.app.bundleID,
                isHelperBacked: group.processObjects.count > 1
            )
        }
        appsByPID = refreshed
        rebuildDisplayableApps()
        reconcileManagedRoutes()
    }

    private func rebuildDisplayableApps() {
        let active = appsByPID.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let activeIdentifiers = Set(active.map(\.persistenceIdentifier))
        let pinnedActive = active.filter { settingsManager.isPinned($0.persistenceIdentifier) }.map(DisplayableApp.active)
        let pinnedInactive = settingsManager.getPinnedAppInfo()
            .filter { !activeIdentifiers.contains($0.persistenceIdentifier) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            .map(DisplayableApp.pinnedInactive)
        let unpinned = active.filter { !settingsManager.isPinned($0.persistenceIdentifier) }.map(DisplayableApp.active)
        displayableApps = pinnedActive + pinnedInactive + unpinned
    }

    private func publishOrActivateDSP(for app: AudioApp) {
        guard let identity = AppIdentity(bundleID: app.bundleID) else { return }
        let settings = settings(for: app)
        let panoramaRoute = panoramaRoutesByIdentity[identity]
        let panoramaNetworkBindings = panoramaNetworkBindingsByIdentity[identity] ?? []
        Task { [backend, transactions] in
            if let panoramaRoute {
                for assignment in panoramaRoute.bindings {
                    await backend.publish(
                        settings: panoramaSettings(),
                        to: assignment.binding
                    )
                }
                for binding in panoramaNetworkBindings {
                    await backend.publish(
                        settings: panoramaSettings(),
                        to: binding
                    )
                }
                return
            }
            if let active = await transactions.activeRoute(for: identity) {
                for binding in active.bindings {
                    await backend.publish(settings: settings, to: binding)
                }
            }
        }
    }

    private func apply(
        desired: DesiredRoute,
        for app: AudioApp,
        identity: AppIdentity,
        persistDesiredRoute: Bool = true
    ) async -> Bool {
        if persistDesiredRoute, desired != .panoramaGroup {
            panoramaFallbackIdentities.remove(identity)
            panoramaFailureDeadlines.removeValue(forKey: identity)
        }
        if desired == .panoramaGroup {
            return await applyPanoramaGroup(for: app, identity: identity)
        }
        await teardownPanoramaRoute(for: identity)
        let settings = settings(for: app)
        let defaultSelection = DefaultOutputSelection(
            deviceUID: defaultOutputDeviceUID.isEmpty ? nil : defaultOutputDeviceUID,
            generation: hal.serviceEpoch
        )
        let state = await coordinator.request(
            identity: identity,
            desired: desired,
            settings: settings,
            defaultSelection: defaultSelection
        )

        switch operation(desired: desired, settings: settings, defaultSelection: defaultSelection) {
        case .nativePassThrough:
#if DEBUG
            cancelRouteDiagnostics(for: identity)
#endif
            await transactions.teardown(identity: identity)
            managedGroupsByIdentity.removeValue(forKey: identity)
            reconcilingManagedIdentities.remove(identity)
            guard let requestID = state.requestID,
                  await coordinator.commit(
                    identity: identity,
                    requestID: requestID,
                    halEpoch: hal.serviceEpoch,
                    defaultSelection: defaultSelection,
                    effectiveByInstance: [:]
                  ) else { return false }
            if persistDesiredRoute {
                settingsManager.setDesiredRoute(desired, for: identity)
            }
            return true
        case .managed:
            guard let requestID = state.requestID,
                  let device = targetDevice(for: desired) else { return false }
            guard await permission.requestPermissionIfNeeded() else {
                _ = await coordinator.resolveAuthorization(
                    identity: identity,
                    requestID: requestID,
                    allowed: false
                )
                return false
            }
            _ = await coordinator.resolveAuthorization(identity: identity, requestID: requestID, allowed: true)
            let groups = groupsByIdentity[identity] ?? []
            guard !groups.isEmpty else { return false }
            let outcome = await transactions.execute(BackendRouteRequest(
                identity: identity,
                requestID: requestID,
                targetDevice: device,
                groups: groups,
                bufferProfile: .profile(for: device),
                halEpoch: hal.serviceEpoch
            ))
            guard case let .committed(deviceUID) = outcome else {
                permission.recordCaptureFailure()
                return false
            }
            guard let active = await transactions.activeRoute(for: identity) else { return false }
            permission.markAuthorized()
#if DEBUG
            if let timing = await transactions.latestTiming(for: identity) {
                Self.routeDiagnosticsLogger.debug(
                    "routeTiming device=\(timing.deviceUID, privacy: .public) prepare=\(timing.prepareDuration.formatted(), privacy: .public) commit=\(timing.commitDuration.formatted(), privacy: .public) priorTeardown=\(timing.priorTeardownDuration.formatted(), privacy: .public)"
                )
            }
            startRouteDiagnostics(
                for: identity,
                devices: [(deviceUID: deviceUID, bindings: active.bindings)]
            )
#endif
            for binding in active.bindings {
                await backend.publish(settings: settings, to: binding)
            }
            let effective = Dictionary(uniqueKeysWithValues: groups.map {
                ($0.instanceID, EffectiveRoute(binding: .managed(deviceUID: deviceUID), health: .active))
            })
            guard await coordinator.commit(
                identity: identity,
                requestID: requestID,
                halEpoch: hal.serviceEpoch,
                defaultSelection: defaultSelection,
                effectiveByInstance: effective
                  ) else { return false }
            if persistDesiredRoute {
                settingsManager.setDesiredRoute(desired, for: identity)
            }
            if case let .device(uid) = desired {
                settingsManager.setLastSuccessfulSingleDeviceRoute(uid: uid, for: identity)
            }
            managedGroupsByIdentity[identity] = groups
            return true
        }
    }

    private func applyPanoramaGroup(
        for app: AudioApp,
        identity: AppIdentity,
        minimumExecutableEndpointCount: Int = 2
    ) async -> Bool {
        guard let topology = panoramaTopology(
            minimumExecutableEndpointCount: minimumExecutableEndpointCount
        ) else {
            Self.panoramaLogger.error("Panorama start rejected: selected endpoint topology is not executable")
            return false
        }
        guard !topology.localOutputs.isEmpty else {
            Self.panoramaLogger.error("Panorama start rejected: no local output is available")
            return false
        }
        guard let groups = groupsByIdentity[identity], !groups.isEmpty else {
            Self.panoramaLogger.error("Panorama start rejected: the selected app has no active audio process group")
            return false
        }

        let priorDesired = settingsManager.desiredRoute(for: identity)
        let hadSingleDeviceRoute = await transactions.activeRoute(for: identity) != nil
        let previousPanoramaRoute = panoramaRoutesByIdentity[identity]
        let previousNetworkBindingCount = panoramaNetworkBindingsByIdentity[identity]?.count ?? 0
        Self.panoramaLogger.notice(
            "panoramaTrace activation requested identity=\(identity.persistenceKey, privacy: .public) groups=\(groups.count, privacy: .public) replacingRoute=\(previousPanoramaRoute != nil, privacy: .public) previousNetworkBindings=\(previousNetworkBindingCount, privacy: .public)"
        )
        if hadSingleDeviceRoute {
            // Process Tap ownership cannot be shared with the legacy
            // single-output transaction. This is an explicit user route
            // change, so release that route before building the panorama.
            await transactions.teardown(identity: identity)
        }

        if let previousNetworkBindings = panoramaNetworkBindingsByIdentity.removeValue(forKey: identity) {
            Self.panoramaLogger.notice(
                "panoramaTrace removing old network bindings before route activation identity=\(identity.persistenceKey, privacy: .public) count=\(previousNetworkBindings.count, privacy: .public)"
            )
            stopPanoramaNetworkPumpIfUnused()
            await backend.detachPanoramaNetworkBindings(previousNetworkBindings)
        }
        if let previous = panoramaRoutesByIdentity.removeValue(forKey: identity) {
            await panoramaComposer.teardown(previous)
        }

        var activatedRoute: PanoramaMacRouteResources?
        var activatedNetworkBindings: [ActiveBinding] = []
        do {
            let route = try await panoramaComposer.activate(
                PanoramaMacRouteRequest(
                    identity: identity,
                    groups: groups,
                    outputs: topology.localOutputs,
                    profilesByOutputUID: topology.localProfilesByUID,
                    delayMillisecondsByOutputUID: topology.localDelayMillisecondsByUID,
                    allowsSingleLocalOutput: topology.localOutputs.count == 1
                )
            )
            activatedRoute = route
            for assignment in route.bindings {
                await backend.publish(
                    settings: panoramaSettings(),
                    to: assignment.binding
                )
            }
            if !topology.plan.remoteEndpoints.isEmpty {
                activatedNetworkBindings = try await backend.attachPanoramaNetworkBindings(for: route.captures)
                for binding in activatedNetworkBindings {
                    await backend.publish(
                        settings: panoramaSettings(),
                        to: binding
                    )
                }
                companionHost.configureRemoteDelay(milliseconds: topology.remoteDelayMilliseconds ?? 0)
                panoramaNetworkBindingsByIdentity[identity] = activatedNetworkBindings
                ensurePanoramaNetworkPump()
            }
            panoramaRoutesByIdentity[identity] = route
            managedGroupsByIdentity[identity] = groups
            permission.markAuthorized()
            panoramaFallbackIdentities.remove(identity)
            panoramaFailureDeadlines.removeValue(forKey: identity)
            settingsManager.setDesiredRoute(.panoramaGroup, for: identity)
            Self.panoramaLogger.notice(
                "panoramaTrace activation committed identity=\(identity.persistenceKey, privacy: .public) networkBindings=\(activatedNetworkBindings.count, privacy: .public)"
            )
            // 每台输出设备的配置延迟参考（用于极限测试的延迟评估）。
            // 全景基准 pre-roll 固定为 1000ms（48000 帧），手动延迟在其上叠加。
            for (uid, delayMilliseconds) in topology.localDelayMillisecondsByUID {
                Self.panoramaLogger.notice(
                    "panoramaTrace output profile device=\(uid, privacy: .public) delayMilliseconds=\(delayMilliseconds, privacy: .public) basePreRollMilliseconds=1000"
                )
            }
#if DEBUG
            let panoramaBindingsByOutputUID = Dictionary(
                grouping: route.bindings,
                by: { $0.output.deviceUID }
            )
            startRouteDiagnostics(
                for: identity,
                devices: panoramaBindingsByOutputUID.map { deviceUID, assignments in
                    (deviceUID: deviceUID, bindings: assignments.map(\.binding))
                }
            )
#endif
            return true
        } catch {
            Self.panoramaLogger.error(
                "Panorama activation failed: \(String(describing: error), privacy: .public)"
            )
            panoramaNetworkBindingsByIdentity.removeValue(forKey: identity)
            stopPanoramaNetworkPumpIfUnused()
            if !activatedNetworkBindings.isEmpty {
                await backend.detachPanoramaNetworkBindings(activatedNetworkBindings)
            }
            if let activatedRoute {
                await panoramaComposer.teardown(activatedRoute)
            }
            if hadSingleDeviceRoute, priorDesired != .panoramaGroup {
                _ = await apply(desired: priorDesired, for: app, identity: identity)
            }
            return false
        }
    }

    private func teardownPanoramaRoute(for identity: AppIdentity) async {
#if DEBUG
        cancelRouteDiagnostics(for: identity)
#endif
        let networkBindings = panoramaNetworkBindingsByIdentity.removeValue(forKey: identity) ?? []
        Self.panoramaLogger.notice(
            "panoramaTrace tearing down panorama route identity=\(identity.persistenceKey, privacy: .public) networkBindings=\(networkBindings.count, privacy: .public)"
        )
        stopPanoramaNetworkPumpIfUnused()
        if !networkBindings.isEmpty {
            await backend.detachPanoramaNetworkBindings(networkBindings)
        }
        if let route = panoramaRoutesByIdentity.removeValue(forKey: identity) {
            await panoramaComposer.teardown(route)
        }
    }

    /// Core Audio can recreate an app's process object when another player
    /// pauses, resumes, or changes helpers. A muted Tap bound to the old object
    /// then owns silence, so replace only that app's route through the existing
    /// transaction handoff. No action here touches a different app identity.
    private func reconcileManagedRoutes() {
        let actions = ManagedRouteReconciliation.actions(
            previous: managedGroupsByIdentity,
            current: groupsByIdentity
        )
        for action in actions {
            switch action {
            case let .teardown(identity):
#if DEBUG
                cancelRouteDiagnostics(for: identity)
#endif
                managedGroupsByIdentity[identity] = []
                reconcilingManagedIdentities.remove(identity)
                // A paused app has no process object to rebuild from. Keep an
                // active panorama fan-out alive (it sends silence) until the
                // process returns, instead of tearing down the user's route.
                guard panoramaRoutesByIdentity[identity] == nil,
                      !panoramaFallbackIdentities.contains(identity) else { continue }
                Task { [transactions] in
                    await transactions.teardown(identity: identity)
                }

            case let .rebuild(identity):
                // A temporary fallback retains the user's panorama intent.
                // Recovery is driven by `reconcilePanoramaFailureRecovery` so
                // process polling cannot race it with a stale desired route.
                guard !panoramaFallbackIdentities.contains(identity) else { continue }
                if panoramaRoutesByIdentity[identity] != nil {
                    Self.panoramaLogger.notice(
                        "panoramaTrace process-group generation changed; rebuilding active panorama route identity=\(identity.persistenceKey, privacy: .public)"
                    )
                }
                guard reconcilingManagedIdentities.insert(identity).inserted,
                      let app = appsByPID.values.first(where: {
                          AppIdentity(bundleID: $0.bundleID) == identity
                      }) else { continue }
                let desired = settingsManager.desiredRoute(for: identity)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    defer { self.reconcilingManagedIdentities.remove(identity) }
                    _ = await self.apply(desired: desired, for: app, identity: identity)
                }
            }
        }
    }

    private func settings(for app: AudioApp) -> PerAppDSPSettings {
        PerAppDSPSettings(
            volume: 1,
            muted: false
        )
    }

    private func panoramaSettings() -> PerAppDSPSettings {
        PerAppDSPSettings(
            // Panorama only fans audio out. Loudness and mute state belong to
            // each endpoint's own operating-system audio controls.
            volume: 1,
            muted: false
        )
    }

    private func hasChangedTiming(
        from previous: PanoramaGroupConfiguration,
        to current: PanoramaGroupConfiguration
    ) -> Bool {
        // 配置来自磁盘文件，可能被旧版本或外部写坏而出现重复 endpointID，
        // 防御式构建避免字典断言崩溃。
        let previousTiming = Dictionary(
            previous.members.map {
                ($0.endpointID, TimingInput(
                    manualDelayMilliseconds: $0.manualDelayMilliseconds
                ))
            },
            uniquingKeysWith: { first, _ in first }
        )
        let currentTiming = Dictionary(
            current.members.map {
                ($0.endpointID, TimingInput(
                    manualDelayMilliseconds: $0.manualDelayMilliseconds
                ))
            },
            uniquingKeysWith: { first, _ in first }
        )
        return previousTiming != currentTiming
    }

    private struct TimingInput: Equatable {
        let manualDelayMilliseconds: Int
    }

    private func publishPanoramaMemberControls() {
        for (identity, route) in panoramaRoutesByIdentity {
            guard appsByPID.values.contains(where: {
                AppIdentity(bundleID: $0.bundleID) == identity
            }) else { continue }
            let networkBindings = panoramaNetworkBindingsByIdentity[identity] ?? []
            Task { [backend] in
                for assignment in route.bindings {
                    await backend.publish(
                        settings: panoramaSettings(),
                        to: assignment.binding
                    )
                }
                for binding in networkBindings {
                    await backend.publish(
                        settings: panoramaSettings(),
                        to: binding
                    )
                }
            }
        }
    }

    private func outputVolumeDevice(for app: AudioApp) -> AudioDevice? {
        OutputVolumeDeviceResolver.device(
            configuredDeviceUID: getDeviceForApp(app.id),
            systemDefaultUID: defaultOutputDeviceUID,
            devices: outputDevices
        )
    }

    private func targetDevice(for desired: DesiredRoute) -> OutputDeviceDescriptor? {
        switch desired {
        case let .device(uid):
            return descriptorsByUID[uid]?.readiness.isPreflightReady == true ? descriptorsByUID[uid] : nil
        case .followSystemDefault:
            guard !defaultOutputDeviceUID.isEmpty else { return nil }
            return descriptorsByUID[defaultOutputDeviceUID]?.readiness.isPreflightReady == true
                ? descriptorsByUID[defaultOutputDeviceUID]
                : nil
        case .panoramaGroup:
            return nil
        }
    }

    private struct PanoramaResolvedTopology {
        let plan: PanoramaTopologyPlan
        let localOutputs: [OutputDeviceDescriptor]
        let localProfilesByUID: [String: BufferProfile]
        let localDelayMillisecondsByUID: [String: Int]
        let remoteDelayMilliseconds: Int?
    }

    private func panoramaTopology(
        minimumExecutableEndpointCount: Int = 2
    ) -> PanoramaResolvedTopology? {
        let candidates = panoramaEndpointCandidates
        // A remembered endpoint can disappear between sessions (for example,
        // an iPhone companion that is currently offline). Keep that choice in
        // the saved configuration so it can return automatically, but do not
        // let an invisible, unavailable endpoint prevent the connected
        // speakers from starting a panorama route.
        let executableConfiguration = Self.executablePanoramaConfiguration(
            panoramaGroupConfiguration,
            candidates: candidates
        )
        guard case let .success(plan) = PanoramaTopologyPlanner.makePlan(
            configuration: executableConfiguration,
            candidates: candidates,
            minimumExecutableEndpointCount: minimumExecutableEndpointCount
        ) else {
            return nil
        }
        let descriptors = plan.localEndpoints.compactMap { candidate -> OutputDeviceDescriptor? in
            guard case let .macDevice(uid) = candidate.id else { return nil }
            return descriptorsByUID[uid]
        }
        guard descriptors.count == plan.localEndpoints.count,
              // `SystemCoreAudioHAL.outputSnapshot()` reports every live
              // physical output as `formatReady`. Actual IO readiness is
              // established below by output.prepare/start, which already
              // propagates the precise Core Audio failure.
              descriptors.allSatisfy({ $0.readiness.isPreflightReady }) else {
            return nil
        }
        guard !descriptors.isEmpty else { return nil }
        // Manual delay is intentionally direct: the user listens to the two
        // outputs and delays the earlier one. No microphone measurement or
        // inferred latency can block panorama playback.
        let localProfilesByUID = Dictionary(uniqueKeysWithValues: plan.localEndpoints.compactMap { endpoint -> (String, BufferProfile)? in
            guard case let .macDevice(uid) = endpoint.id else { return nil }
            let delay = executableConfiguration.member(for: endpoint.id)?.manualDelayMilliseconds ?? 0
            return (uid, .panorama(delaying: delay))
        })
        let localDelayMillisecondsByUID = Dictionary(uniqueKeysWithValues: plan.localEndpoints.compactMap {
            endpoint -> (String, Int)? in
            guard case let .macDevice(uid) = endpoint.id else { return nil }
            return (
                uid,
                executableConfiguration.member(for: endpoint.id)?.manualDelayMilliseconds ?? 0
            )
        })
        let remoteDelayMilliseconds = plan.remoteEndpoints.first.flatMap {
            executableConfiguration.member(for: $0.id)?.manualDelayMilliseconds
        }
        return PanoramaResolvedTopology(
            plan: plan,
            localOutputs: descriptors,
            localProfilesByUID: localProfilesByUID,
            localDelayMillisecondsByUID: localDelayMillisecondsByUID,
            remoteDelayMilliseconds: remoteDelayMilliseconds
        )
    }

    static func executablePanoramaConfiguration(
        _ configuration: PanoramaGroupConfiguration,
        candidates: [PanoramaEndpointCandidate]
    ) -> PanoramaGroupConfiguration {
        let availableIDs = Set(candidates.compactMap { candidate -> PanoramaEndpointID? in
            guard case .available = candidate.availability else { return nil }
            return candidate.id
        })
        return PanoramaGroupConfiguration(
            members: configuration.members.filter { availableIDs.contains($0.endpointID) }
        )
    }

    private func ensurePanoramaNetworkPump() {
        guard panoramaNetworkPump == nil else { return }
        Self.panoramaLogger.notice("panoramaTrace network pump started")
        let backend = backend
        let transport = companionHost.networkTransport
        let logger = Self.panoramaLogger
        panoramaNetworkPump = Task.detached(priority: .userInitiated) { [backend, transport, logger] in
            let clock = ContinuousClock()
            var nextPacketDeadline = clock.now
            var sentPacketCount = 0
            var consecutiveMissingPCMCount = 0
            while !Task.isCancelled {
                nextPacketDeadline = PanoramaPacketSchedule.nextDeadline(
                    after: nextPacketDeadline,
                    now: clock.now
                )
                try? await clock.sleep(until: nextPacketDeadline)
                // Reads the backend's live binding table each tick, so joining
                // or leaving never requires restarting this pump.
                guard let pcm = await backend.mixAllPanoramaNetworkPCM() else {
                    consecutiveMissingPCMCount += 1
                    if consecutiveMissingPCMCount == 200 {
                        logger.error(
                            "iPhone stream has no PCM available for one second while network bindings remain active"
                        )
                    }
                    continue
                }
                consecutiveMissingPCMCount = 0
                if await transport.send(pcm: pcm) {
                    sentPacketCount += 1
                    if sentPacketCount.isMultiple(of: 1_000) {
                        logger.debug(
                            "iPhone stream sent packets=\(sentPacketCount, privacy: .public)"
                        )
                    }
                }
            }
        }
    }

    private func stopPanoramaNetworkPumpIfUnused() {
        guard panoramaNetworkBindingsByIdentity.isEmpty else { return }
        if panoramaNetworkPump != nil {
            Self.panoramaLogger.notice("panoramaTrace network pump stopped because no remote bindings remain")
        }
        panoramaNetworkPump?.cancel()
        panoramaNetworkPump = nil
    }

    /// Uses the same built-in-device classification as the application output
    /// picker, including its UID/name fallback for HAL snapshots whose
    /// transport is reported as unknown.
    static func panoramaTransport(for device: AudioDevice) -> PanoramaEndpointTransport {
        if device.isBuiltInOutput { return .builtIn }
        switch device.transport {
        case .builtIn:
            return .builtIn
        case .bluetooth, .bluetoothLE:
            return .bluetooth
        default:
            return .wired
        }
    }

    private func handle(_ event: CoreAudioHALEvent) {
        switch event {
        case .serviceRestarted:
            outputStateRevision &+= 1
            refreshTask?.cancel()
            refreshTask = nil
#if DEBUG
            cancelAllRouteDiagnostics()
#endif
            Task { [transactions, coordinator, hal] in
                await transactions.invalidateAllForCoreAudioServiceRestart()
                await coordinator.handleServiceRestart(newHALEpoch: hal.serviceEpoch)
            }
        case .deviceListChanged, .defaultOutputChanged, .deviceConfigurationChanged:
            outputStateRevision &+= 1
            scheduleRefresh()
        case .processListChanged:
            scheduleRefresh()
        }
    }

    /// Core Audio can deliver continuous device and process notifications while
    /// a stream is active. Refreshing every event monopolizes the main actor
    /// and prevents a user-initiated route transaction from running.
    private func scheduleRefresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.refresh()
            self.refreshTask = nil
        }
    }

    /// Playing state is polled off the audio callback path. Core Audio can
    /// report frequent per-process changes while frames are being rendered.
    private func startProcessPolling() {
        processPollingTask?.cancel()
        processPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }

                guard let self, !Task.isCancelled else { return }
                self.refresh()
            }
        }
    }

#if DEBUG
    /// Debug-only, control-plane sampling. It reads monotonic atomics every
    /// three seconds and never runs in a Core Audio capture/render callback.
    private func startRouteDiagnostics(
        for identity: AppIdentity,
        devices: [(deviceUID: String, bindings: [ActiveBinding])]
    ) {
        cancelRouteDiagnostics(for: identity)
        let routeBackend = backend
        routeDiagnosticsTasks[identity] = Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(3))
                } catch {
                    return
                }
                for (deviceUID, bindings) in devices {
                    guard !Task.isCancelled,
                          let output = await routeBackend.outputMetrics(deviceUID: deviceUID),
                          let render = await routeBackend.renderMetrics(deviceUID: deviceUID) else {
                        continue
                    }
                    for binding in bindings {
                        guard let metrics = await routeBackend.bindingMetrics(binding) else { continue }
                        Self.routeDiagnosticsLogger.info(
                            "routeHeartbeat device=\(deviceUID, privacy: .public) rate=\(output.sampleRate, privacy: .public) queued=\(metrics.queuedFrames, privacy: .public) underrun=\(metrics.underrunFrames, privacy: .public) overrun=\(metrics.overrunFrames, privacy: .public) lowWatermark=\(render.lowWatermarkEventCount, privacy: .public) recovery=\(render.recoveryEventCount, privacy: .public) partialUnderrun=\(render.partialUnderrunFrames, privacy: .public) minFill=\(render.minimumEffectiveFillFrames, privacy: .public) maxFill=\(render.maximumEffectiveFillFrames, privacy: .public) producerSample=\(metrics.lastProducerSampleTime, privacy: .public) renderSample=\(render.lastCallbackSampleTime, privacy: .public) captureCallbacks=\(metrics.producerCallbackCount, privacy: .public) renderCallbacks=\(render.callbackCount, privacy: .public) renderMaxTicks=\(render.maximumRenderTicks, privacy: .public) callbackMaxFrames=\(render.maximumCallbackFrames, privacy: .public)"
                        )
                    }
                }
            }
        }
    }

    private func cancelRouteDiagnostics(for identity: AppIdentity) {
        routeDiagnosticsTasks.removeValue(forKey: identity)?.cancel()
    }

    private func cancelAllRouteDiagnostics() {
        routeDiagnosticsTasks.values.forEach { $0.cancel() }
        routeDiagnosticsTasks.removeAll()
    }
#endif

    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let parent = info.kp_eproc.e_ppid
        return parent > 0 ? parent : nil
    }

    private static func presentationHost(
        for audioOwnerBundleID: String?,
        runningApplication: NSRunningApplication,
        runningApplications: [NSRunningApplication],
        workspace: NSWorkspace
    ) -> (name: String?, icon: NSImage)? {
        let regularApplications = runningApplications.filter {
            $0.activationPolicy == .regular
        }
        if AudioAppPresentationHost.isWebKitAuxiliary(bundleID: audioOwnerBundleID) {
            if let hostName = AudioAppPresentationHost.matchingHostName(
                for: runningApplication.localizedName,
                candidateNames: regularApplications.compactMap(\.localizedName)
            ), let host = regularApplications.first(where: {
                $0.localizedName == hostName
            }), let icon = host.icon {
                return (host.localizedName, icon)
            }
        }

        guard let hostBundleID = AudioAppPresentationHost.bundleID(
            forAudioOwnerBundleID: audioOwnerBundleID
        ) else { return nil }

        if let runningHost = regularApplications.first(where: {
            $0.bundleIdentifier == hostBundleID
        }), let icon = runningHost.icon {
            return (runningHost.localizedName, icon)
        }

        guard let applicationURL = workspace.urlForApplication(
            withBundleIdentifier: hostBundleID
        ) else { return nil }
        let bundle = Bundle(url: applicationURL)
        let name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
        return (name, workspace.icon(forFile: applicationURL.path))
    }

    /// WebKit WebContent and similar XPC audio producers are registered in
    /// AppKit as accessory applications. They may be launched by `launchd`,
    /// so their parent chain never reaches the browser or host app. Limit the
    /// fallback to actual XPC-style auxiliary processes to avoid surfacing
    /// ordinary background services as routable apps.
    private static func isDirectAudioOwner(_ application: NSRunningApplication) -> Bool {
        guard application.activationPolicy == .accessory else { return false }
        guard let bundleURL = application.bundleURL else { return true }
        return bundleURL.pathExtension.caseInsensitiveCompare("xpc") == .orderedSame
    }
}
