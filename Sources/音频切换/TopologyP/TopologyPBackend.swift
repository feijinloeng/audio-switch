import AudioToolbox
import Foundation
import RealtimeCore

enum PreRollWaitPolicy {
    /// Panorama buffers are expressed on the shared 48 kHz program timeline.
    /// Waiting a fixed 250 ms can never fill its one-second pre-roll, so derive
    /// the deadline from the requested frame count and retain a scheduling
    /// margin for Core Audio callback startup.
    static func timeoutMilliseconds(minimumFrames: UInt32) -> Int64 {
        let timelineFramesPerSecond: UInt64 = 48_000
        let frameMilliseconds = (
            UInt64(minimumFrames) * 1_000 + timelineFramesPerSecond - 1
        ) / timelineFramesPerSecond
        return Int64(max(250, frameMilliseconds + 250))
    }
}

enum PreRollAlignmentPolicy {
    static func discardFrames(queuedFrames: UInt32, desiredFrames: UInt32) -> UInt32 {
        queuedFrames > desiredFrames ? queuedFrames - desiredFrames : 0
    }
}

struct OutputClaimBindingState: Equatable, Sendable {
    let bindingToken: UUID
    let outputClaimToken: UUID
    let isActive: Bool
}

enum OutputClaimRenderEligibility {
    static func eligibleBindingTokens(
        _ bindings: [OutputClaimBindingState],
        activeOutputClaims: Set<UUID>
    ) -> Set<UUID> {
        Set(bindings.compactMap { binding in
            binding.isActive && activeOutputClaims.contains(binding.outputClaimToken)
                ? binding.bindingToken
                : nil
        })
    }
}

/// Control-plane proof of the binding tokens currently borrowed by the
/// immutable AUHAL render snapshot. Claim removal records the replacement
/// before binding retirement runs, so retirement cannot rebuild the same
/// physical-device snapshot a second time and reset unaffected ASRC state.
struct OutputRenderSnapshotState: Equatable, Sendable {
    private(set) var renderedBindingTokens: Set<UUID>

    init(renderedBindingTokens: Set<UUID> = []) {
        self.renderedBindingTokens = renderedBindingTokens
    }

    func requiresReplacement(removing bindingTokens: Set<UUID>) -> Bool {
        !renderedBindingTokens.isDisjoint(with: bindingTokens)
    }

    func requiresReplacement(publishing bindingTokens: Set<UUID>) -> Bool {
        renderedBindingTokens != bindingTokens
    }

    mutating func recordPublished(_ bindingTokens: Set<UUID>) {
        renderedBindingTokens = bindingTokens
    }

    /// Executes one physical snapshot replacement only when at least one of
    /// the removed bindings is still borrowed by the published snapshot.
    /// Recording happens after the replacement succeeds, so a failed
    /// replacement never creates a false reclamation proof.
    @discardableResult
    mutating func replaceIfNeeded(
        removing bindingTokens: Set<UUID>,
        publishing replacementTokens: Set<UUID>,
        perform: () throws -> Void
    ) rethrows -> Bool {
        guard requiresReplacement(removing: bindingTokens) else {
            return false
        }
        try perform()
        recordPublished(replacementTokens)
        return true
    }
}

/// Concrete topology-P resource owner. Its actor isolation serializes Core
/// Audio lifecycle work; render and capture callbacks touch only C++ binding
/// state. The app composition root constructs this as its single backend.
actor TopologyPBackend: CaptureSessionBackend, OutputSessionBackend, RouteBindingBackend {
    private var panoramaMixedScratch = [Float](
        repeating: 0,
        count: PanoramaAudioPacket.framesPerPacket * PanoramaAudioPacket.channels
    )
    private var panoramaBindingScratch = [Float](
        repeating: 0,
        count: PanoramaAudioPacket.framesPerPacket * PanoramaAudioPacket.channels
    )
    struct CaptureMetrics: Equatable, Sendable {
        let isRunning: Bool
        let sampleRate: Double
        let formatID: UInt32
        let formatFlags: UInt32
        let channels: UInt32
        let bytesPerFrame: UInt32
    }

    struct OutputMetrics: Equatable, Sendable {
        let sampleRate: Double
        let formatID: UInt32
        let formatFlags: UInt32
        let channels: UInt32
        let bytesPerFrame: UInt32
    }

    struct BindingMetrics: Equatable, Sendable {
        let producerCallbackCount: UInt64
        let producedFrames: UInt64
        let queuedFrames: UInt32
        let overrunFrames: UInt64
        let underrunFrames: UInt64
        let lastProducerSampleTime: Double
        let lastProducerHostTime: UInt64
    }

    private final class CaptureResource {
        let instanceID: AppInstanceID
        let processObjectIDs: [AudioObjectID]
        let label: String
        var session: TapOnlyCaptureSession?
        var lastDiagnostics: TapOnlyCaptureSession.Diagnostics?
        var bindingSnapshotGeneration: UInt64 = 1
        var localBindingTargets: [RouteBindingTarget] = []

        init(instanceID: AppInstanceID, processObjectIDs: [AudioObjectID], label: String) {
            self.instanceID = instanceID
            self.processObjectIDs = processObjectIDs
            self.label = label
        }
    }

    private final class OutputResource {
        let deviceUID: String
        let deviceID: AudioDeviceID
        let clientFormat: AudioStreamBasicDescription
        var session: AUHALOutputSession?
        var snapshotGeneration: UInt64 = 0
        var activeOutputClaims: Set<UUID> = []
        var profile: BufferProfile?
        var manualDelayMilliseconds = 0
        var renderSnapshot = OutputRenderSnapshotState()

        init(deviceUID: String, deviceID: AudioDeviceID, clientFormat: AudioStreamBasicDescription) {
            self.deviceUID = deviceUID
            self.deviceID = deviceID
            self.clientFormat = clientFormat
        }
    }

    private final class BindingResource {
        let token: UUID
        let pointer: OpaquePointer
        let captureToken: UUID
        let output: OutputResource
        let outputClaimToken: UUID
        let profile: BufferProfile
        var isActive = false

        init(
            token: UUID,
            pointer: OpaquePointer,
            captureToken: UUID,
            output: OutputResource,
            outputClaimToken: UUID,
            profile: BufferProfile
        ) {
            self.token = token
            self.pointer = pointer
            self.captureToken = captureToken
            self.output = output
            self.outputClaimToken = outputClaimToken
            self.profile = profile
        }
    }

    /// A capture-owned ring for the non-realtime iPhone mix publisher. Unlike
    /// `BindingResource`, it has no physical output claim or AUHAL session.
    private final class NetworkBindingResource {
        let token: UUID
        let pointer: OpaquePointer
        let captureToken: UUID
        let instanceID: AppInstanceID

        init(token: UUID, pointer: OpaquePointer, captureToken: UUID, instanceID: AppInstanceID) {
            self.token = token
            self.pointer = pointer
            self.captureToken = captureToken
            self.instanceID = instanceID
        }
    }

    private let hal: SystemCoreAudioHAL
    private let maxCallbackFrames: UInt32
    private let captureProgress = CaptureProgressNotifier()
    private var captures: [UUID: CaptureResource] = [:]
    /// Each transaction owns a distinct output claim token. Claims that name
    /// the same stable UID deliberately share exactly one physical resource.
    private var outputs: [UUID: OutputResource] = [:]
    private var outputResourcesByUID: [String: OutputResource] = [:]
    private var bindings: [UUID: BindingResource] = [:]
    private var networkBindings: [UUID: NetworkBindingResource] = [:]

    init(hal: SystemCoreAudioHAL, maxCallbackFrames: UInt32 = 4_096) {
        self.hal = hal
        self.maxCallbackFrames = max(1, maxCallbackFrames)
    }

    func prepare(
        app: AppIdentity,
        instance: AppInstanceID,
        group: AudioProcessGroup
    ) throws -> PreparedCapture {
        guard group.instanceID == instance,
              let objectIDs = hal.resolveProcessObjectIDs(for: Array(group.processObjects)),
              !objectIDs.isEmpty else {
            throw RouteTransactionBackendError.prepareFailed
        }
        let capture = PreparedCapture(instanceID: instance, token: UUID())
        captures[capture.token] = CaptureResource(
            instanceID: instance,
            processObjectIDs: objectIDs,
            label: app.persistenceKey
        )
        return capture
    }

    func discard(_ capture: PreparedCapture) {
        guard let resource = captures[capture.token], resource.session == nil else { return }
        captures.removeValue(forKey: capture.token)
    }

    func start(_ capture: PreparedCapture) throws -> ActiveCapture {
        guard let captureResource = captures[capture.token],
              captureResource.session == nil,
              let bindingResource = bindings.values.first(where: { $0.captureToken == capture.token }) else {
            throw RouteTransactionBackendError.prepareFailed
        }
        let session = TapOnlyCaptureSession(
            binding: bindingResource.pointer,
            progressNotifier: captureProgress
        )
        do {
            try session.start(
                processObjectIDs: captureResource.processObjectIDs,
                label: captureResource.label
            )
        } catch {
            // `stop` seals the producer gate even if startup failed after an
            // IOProc was registered, leaving binding reclamation to teardown.
            session.stop()
            throw error
        }
        captureResource.session = session
        return ActiveCapture(instanceID: capture.instanceID, token: capture.token)
    }

    func stop(_ capture: ActiveCapture) {
        guard let resource = captures[capture.token] else { return }
        if let session = resource.session {
            session.stop()
            resource.lastDiagnostics = session.diagnostics
        }
        resource.session = nil
    }

    func publishBindings(
        _ bindingTargets: [RouteBindingTarget],
        for capture: ActiveCapture
    ) throws -> CaptureBindingPublication {
        guard !bindingTargets.isEmpty,
              Set(bindingTargets.map(\.token)).count == bindingTargets.count,
              let captureResource = captures[capture.token],
              let session = captureResource.session,
              bindingTargets.allSatisfy({ target in
                  target.instanceID == capture.instanceID
                      && captureToken(for: target.token) == capture.token
              }) else {
            throw RouteTransactionBackendError.commitFailed
        }
        let pointers = bindingTargets.compactMap { bindingPointer(for: $0.token) }
        guard pointers.count == bindingTargets.count else {
            throw RouteTransactionBackendError.commitFailed
        }
        // Keep local targets separately because attach/detach of the network
        // fan-out must retain the physical-output snapshot. The publication
        // itself may explicitly include authenticated network targets during
        // local-endpoint isolation.
        captureResource.localBindingTargets = bindingTargets.filter { bindings[$0.token] != nil }
        let allPointers = pointers
        let generation = captureResource.bindingSnapshotGeneration &+ 1
        guard generation != 0,
              session.publishCaptureBindings(allPointers, generation: generation) else {
            throw RouteTransactionBackendError.commitFailed
        }
        captureResource.bindingSnapshotGeneration = generation
        return CaptureBindingPublication(
            instanceID: capture.instanceID,
            captureToken: capture.token,
            generation: generation
        )
    }

    private func captureToken(for bindingToken: UUID) -> UUID? {
        bindings[bindingToken]?.captureToken ?? networkBindings[bindingToken]?.captureToken
    }

    private func bindingPointer(for bindingToken: UUID) -> OpaquePointer? {
        bindings[bindingToken]?.pointer ?? networkBindings[bindingToken]?.pointer
    }

    /// Adds one control-plane-only PCM branch per active capture. These rings
    /// are mixed and drained outside Core Audio callbacks for the iPhone UDP
    /// endpoint, while physical bindings remain unchanged.
    func attachPanoramaNetworkBindings(for captures: [ActiveCapture]) throws -> [ActiveBinding] {
        var attached: [ActiveBinding] = []
        for capture in captures {
            guard let captureResource = self.captures[capture.token],
                  let session = captureResource.session,
                  !captureResource.localBindingTargets.isEmpty else {
                throw RouteTransactionBackendError.commitFailed
            }
            if let existing = networkBindings.values.first(where: { $0.captureToken == capture.token }) {
                attached.append(ActiveBinding(instanceID: existing.instanceID, token: existing.token))
                continue
            }
            guard let pointer = ypq_route_binding_create(BufferProfile.panorama.capacityFrames) else {
                throw RouteTransactionBackendError.prepareFailed
            }
            let resource = NetworkBindingResource(
                token: UUID(),
                pointer: pointer,
                captureToken: capture.token,
                instanceID: capture.instanceID
            )
            networkBindings[resource.token] = resource
            let localPointers = captureResource.localBindingTargets.compactMap { bindings[$0.token]?.pointer }
            let allPointers = localPointers + [pointer]
            let generation = captureResource.bindingSnapshotGeneration &+ 1
            guard generation != 0,
                  session.publishCaptureBindings(allPointers, generation: generation) else {
                networkBindings.removeValue(forKey: resource.token)
                ypq_route_binding_destroy(pointer)
                throw RouteTransactionBackendError.commitFailed
            }
            captureResource.bindingSnapshotGeneration = generation
            attached.append(ActiveBinding(instanceID: capture.instanceID, token: resource.token))
        }
        return attached
    }

    func detachPanoramaNetworkBindings(_ activeBindings: [ActiveBinding]) async {
        let resources = activeBindings.compactMap { networkBindings[$0.token] }
        let capturesToRepublish = Set(resources.map(\.captureToken))
        var publications: [CaptureBindingPublication] = []
        var removalGenerations: [UUID: UInt64] = [:]
        for captureToken in capturesToRepublish {
            guard let capture = captures[captureToken], let session = capture.session else { continue }
            let localPointers = capture.localBindingTargets.compactMap { bindings[$0.token]?.pointer }
            let tokensToRemove = Set(activeBindings.map(\.token))
            let retainedNetworkPointers = networkBindings.values
                .filter { $0.captureToken == captureToken && !tokensToRemove.contains($0.token) }
                .map(\.pointer)
            let generation = capture.bindingSnapshotGeneration &+ 1
            if generation != 0, session.publishCaptureBindings(localPointers + retainedNetworkPointers, generation: generation) {
                capture.bindingSnapshotGeneration = generation
                publications.append(CaptureBindingPublication(
                    instanceID: capture.instanceID,
                    captureToken: captureToken,
                    generation: generation
                ))
                removalGenerations[captureToken] = generation
            }
        }
        var acknowledgedCaptureTokens: Set<UUID> = []
        for publication in publications {
            if (try? await acknowledge(publication)) != nil {
                acknowledgedCaptureTokens.insert(publication.captureToken)
            }
        }
        for resource in resources {
            // A running Process Tap may still have a callback holding the
            // previous fan-out snapshot. Its network ring must remain alive
            // unless that callback observed the removal generation. Keeping a
            // detached ring in the backend is preferable to a use-after-free;
            // a future route attachment will retain and republish it.
            let captureStillRunning = captures[resource.captureToken]?.session != nil
            guard !captureStillRunning || acknowledgedCaptureTokens.contains(resource.captureToken) else {
                continue
            }
            networkBindings.removeValue(forKey: resource.token)
            ypq_route_binding_begin_retirement(resource.pointer)
            ypq_route_binding_mark_producer_detached(resource.pointer)
            ypq_route_binding_acknowledge_snapshot_removal(
                resource.pointer,
                removalGenerations[resource.captureToken] ?? 0
            )
            _ = ypq_route_binding_discard_sealed_tail(resource.pointer)
            _ = ypq_route_binding_finish_retirement(resource.pointer)
            ypq_route_binding_destroy(resource.pointer)
        }
    }

    /// Mixes fixed 5 ms blocks with the same atomic per-app gain/mute controls
    /// used by local bindings. Reads the live binding table so attaching or
    /// detaching a companion never requires restarting the pump; two pump
    /// generations draining the same rings is what made companion streams
    /// glitch. Actor-isolated control-plane work, never an audio render callback.
    func mixAllPanoramaNetworkPCM() -> Data? {
        guard !networkBindings.isEmpty else { return nil }
        let frameCount = PanoramaAudioPacket.framesPerPacket
        for index in panoramaMixedScratch.indices {
            panoramaMixedScratch[index] = 0
        }
        for resource in networkBindings.values {
            panoramaBindingScratch.withUnsafeMutableBufferPointer { buffer in
                let read = ypq_route_binding_read_unmetered(resource.pointer, buffer.baseAddress, UInt32(frameCount))
                let readFrames = Int(read)
                if readFrames < frameCount {
                    for index in (readFrames * 2)..<(frameCount * 2) {
                        buffer[index] = 0
                    }
                }
            }
            let gain = ypq_route_binding_published_muted(resource.pointer)
                ? 0
                : ypq_route_binding_published_gain(resource.pointer)
            for index in panoramaMixedScratch.indices {
                panoramaMixedScratch[index] += panoramaBindingScratch[index] * gain
            }
        }
        // The network endpoint owns a continuous 48 kHz playout clock. A
        // temporarily empty capture ring must produce a silent frame rather
        // than a missing UDP packet, otherwise the iPhone repeatedly
        // underruns and re-buffers between audible fragments.
        var pcm = Data(count: PanoramaAudioPacket.pcmByteCount)
        pcm.withUnsafeMutableBytes { destination in
            guard let samples = destination.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
            for index in panoramaMixedScratch.indices {
                let clamped = min(max(panoramaMixedScratch[index], -1), 1)
                samples[index] = Int16((clamped * Float(Int16.max)).rounded())
            }
        }
        return pcm
    }

    func acknowledge(_ publication: CaptureBindingPublication) async throws {
        guard let captureResource = captures[publication.captureToken],
              captureResource.bindingSnapshotGeneration >= publication.generation,
              let session = captureResource.session else {
            throw RouteTransactionBackendError.commitFailed
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(250))
        var observedProgress = await captureProgress.currentGeneration()
        while true {
            guard let currentResource = captures[publication.captureToken],
                  currentResource === captureResource,
                  currentResource.bindingSnapshotGeneration >= publication.generation,
                  currentResource.session === session else {
                throw RouteTransactionBackendError.commitFailed
            }
            if session.acknowledgeCaptureBindings(generation: publication.generation) {
                return
            }
            observedProgress = try await waitForCaptureProgress(
                after: observedProgress,
                until: deadline
            )
        }
    }

    func prepare(device: OutputDeviceDescriptor) throws -> PreparedOutput {
        guard let deviceID = hal.resolveOutputDeviceID(uid: device.uid) else {
            throw RouteTransactionBackendError.prepareFailed
        }
        let clientFormat: AudioStreamBasicDescription
        do {
            clientFormat = try DeviceFormatNegotiator.clientFormat(for: device)
        } catch {
            throw RouteTransactionBackendError.prepareFailed
        }
        let output = PreparedOutput(deviceUID: device.uid, token: UUID())
        let resource: OutputResource
        if let existing = outputResourcesByUID[device.uid] {
            guard existing.deviceID == deviceID,
                  existing.clientFormat.mSampleRate == clientFormat.mSampleRate,
                  existing.clientFormat.mFormatID == clientFormat.mFormatID,
                  existing.clientFormat.mFormatFlags == clientFormat.mFormatFlags else {
                // A stable UID may acquire a new ephemeral device object or
                // profile after reconnect/sleep. Reusing an old AUHAL is not
                // safe; the recovery state machine must tear it down first.
                throw RouteTransactionBackendError.prepareFailed
            }
            resource = existing
        } else {
            resource = OutputResource(
                deviceUID: device.uid,
                deviceID: deviceID,
                clientFormat: clientFormat
            )
        }
        outputResourcesByUID[device.uid] = resource
        outputs[output.token] = resource
        return output
    }

    func discard(_ output: PreparedOutput) {
        guard let resource = outputs[output.token],
              !resource.activeOutputClaims.contains(output.token) else { return }
        outputs.removeValue(forKey: output.token)
        releaseOutputResourceIfUnused(resource)
    }

    /// This is a logical ownership transition. AUHAL starts only in
    /// `activate`, after all bindings are known, so a physical device receives
    /// precisely one device-wide render session rather than one per app.
    func start(_ output: PreparedOutput) throws -> ActiveOutput {
        guard let resource = outputs[output.token] else { throw RouteTransactionBackendError.prepareFailed }
        resource.activeOutputClaims.insert(output.token)
        return ActiveOutput(deviceUID: output.deviceUID, token: output.token)
    }

    func activate(
        _ output: ActiveOutput,
        bindings activeBindings: [ActiveBinding],
        initialGain: Float = 1
    ) throws {
        guard let outputResource = outputs[output.token],
              outputResource.activeOutputClaims.contains(output.token) else {
            throw RouteTransactionBackendError.commitFailed
        }
        let selected = renderEligibleBindings(for: outputResource)
        guard activeBindings.allSatisfy({ active in
            guard let resource = bindings[active.token] else { return false }
            return resource.output === outputResource
                && resource.outputClaimToken == output.token
                && selected.contains { $0 === resource }
        }),
              let bindingProfile = selected.first?.profile,
              selected.allSatisfy({ $0.profile == bindingProfile }) else {
            throw RouteTransactionBackendError.commitFailed
        }
        let encodedPanoramaDelay = bindingProfile.panoramaManualDelayMilliseconds
        let manualDelayMilliseconds = encodedPanoramaDelay
            ?? outputResource.manualDelayMilliseconds
        let renderProfile = encodedPanoramaDelay == nil
            ? bindingProfile
            : .panorama

        let selectedTokens = Set(selected.map(\.token))
        if let existingSession = outputResource.session {
            if outputResource.profile != renderProfile
                || outputResource.renderSnapshot.requiresReplacement(publishing: selectedTokens) {
                try existingSession.replaceBindings(selected.map(\.pointer), profile: renderProfile)
            }
            existingSession.setManualDelay(milliseconds: manualDelayMilliseconds)
        } else {
            let session = try AUHALOutputSession(
                deviceID: outputResource.deviceID,
                clientSampleRate: outputResource.clientFormat.mSampleRate,
                bindings: selected.map(\.pointer),
                profile: renderProfile,
                maxCallbackFrames: maxCallbackFrames,
                manualDelayMilliseconds: encodedPanoramaDelay.map { _ in
                    manualDelayMilliseconds
                },
                initialGain: initialGain
            )
            do {
                try session.start()
            } catch {
                session.stop()
                throw error
            }
            outputResource.session = session
        }
        outputResource.profile = renderProfile
        outputResource.manualDelayMilliseconds = manualDelayMilliseconds
        outputResource.renderSnapshot.recordPublished(selectedTokens)
        selected.forEach { $0.isActive = true }
    }

    func setManualDelay(milliseconds: Int, for output: ActiveOutput) throws {
        guard let resource = outputs[output.token],
              resource.activeOutputClaims.contains(output.token) else {
            throw RouteTransactionBackendError.commitFailed
        }
        let clamped = min(
            max(milliseconds, 0),
            PanoramaGroupMember.maximumManualDelayMilliseconds
        )
        resource.manualDelayMilliseconds = clamped
        resource.session?.setManualDelay(milliseconds: clamped)
    }

    func stop(_ output: ActiveOutput) {
        guard let outputResource = outputs[output.token] else { return }
        outputResource.activeOutputClaims.remove(output.token)
        outputs.removeValue(forKey: output.token)
        guard outputResource.activeOutputClaims.isEmpty else {
            removeStoppedClaimFromRenderSnapshot(
                output.token,
                outputResource: outputResource
            )
            releaseOutputResourceIfUnused(outputResource)
            return
        }

        outputResource.session?.stop()
        outputResource.snapshotGeneration &+= 1
        outputResource.session?.acknowledgeSnapshotRemoval(generation: outputResource.snapshotGeneration)
        outputResource.session = nil
        outputResource.profile = nil
        outputResource.renderSnapshot.recordPublished([])
        for resource in bindings.values where resource.output === outputResource {
            ypq_route_binding_acknowledge_snapshot_removal(resource.pointer, outputResource.snapshotGeneration)
        }
        releaseOutputResourceIfUnused(outputResource)
    }

    func renderMetrics(deviceUID: String) -> AUHALOutputSession.RenderMetrics? {
        outputResourcesByUID[deviceUID]?.session?.renderMetrics()
    }

    func outputMetrics(deviceUID: String) -> OutputMetrics? {
        guard let format = outputResourcesByUID[deviceUID]?.clientFormat else { return nil }
        return OutputMetrics(
            sampleRate: format.mSampleRate,
            formatID: format.mFormatID,
            formatFlags: format.mFormatFlags,
            channels: format.mChannelsPerFrame,
            bytesPerFrame: format.mBytesPerFrame
        )
    }

    /// Development-harness invariant: one non-nil AUHAL session per stable
    /// output UID, regardless of how many active route claims share it.
    func physicalOutputSessionCount() -> Int {
        outputResourcesByUID.values.reduce(into: 0) { count, resource in
            if resource.session != nil { count += 1 }
        }
    }

    func captureMetrics(_ capture: ActiveCapture) -> CaptureMetrics? {
        guard let session = captures[capture.token]?.session,
              let format = session.tapFormat else {
            return nil
        }
        return CaptureMetrics(
            isRunning: session.isRunning,
            sampleRate: format.mSampleRate,
            formatID: format.mFormatID,
            formatFlags: format.mFormatFlags,
            channels: format.mChannelsPerFrame,
            bytesPerFrame: format.mBytesPerFrame
        )
    }

    func captureDiagnostics(_ capture: ActiveCapture) -> TapOnlyCaptureSession.Diagnostics? {
        guard let resource = captures[capture.token] else { return nil }
        return resource.session?.diagnostics ?? resource.lastDiagnostics
    }

    func bindingMetrics(_ binding: ActiveBinding) -> BindingMetrics? {
        guard let resource = bindings[binding.token] else { return nil }
        return BindingMetrics(
            producerCallbackCount: ypq_route_binding_producer_callback_count(resource.pointer),
            producedFrames: ypq_route_binding_produced_frames(resource.pointer),
            queuedFrames: ypq_route_binding_available_frames(resource.pointer),
            overrunFrames: ypq_route_binding_overrun_frames(resource.pointer),
            underrunFrames: ypq_route_binding_underrun_frames(resource.pointer),
            lastProducerSampleTime: ypq_route_binding_last_producer_sample_time(resource.pointer),
            lastProducerHostTime: ypq_route_binding_last_producer_host_time(resource.pointer)
        )
    }

    /// Updates a committed binding in place. The C API publishes bounded
    /// controls atomically, so this actor method never recreates a Tap,
    /// aggregate device, AUHAL unit, or render snapshot for slider changes.
    func publish(settings: PerAppDSPSettings, to binding: ActiveBinding) {
        if let resource = bindings[binding.token], resource.isActive {
            ypq_route_binding_publish_controls(
                resource.pointer,
                settings.volume,
                settings.muted
            )
            return
        }
        guard let resource = networkBindings[binding.token] else { return }
        ypq_route_binding_publish_controls(
            resource.pointer,
            settings.volume,
            settings.muted
        )
    }

    func prepare(
        capture: PreparedCapture,
        output: ActiveOutput,
        profile: BufferProfile
    ) throws -> PreparedBinding {
        guard profile.isValid,
              captures[capture.token] != nil,
              let outputResource = outputs[output.token],
              let pointer = ypq_route_binding_create(profile.capacityFrames) else {
            throw RouteTransactionBackendError.prepareFailed
        }
        let binding = PreparedBinding(instanceID: capture.instanceID, token: UUID())
        bindings[binding.token] = BindingResource(
            token: binding.token,
            pointer: pointer,
            captureToken: capture.token,
            output: outputResource,
            outputClaimToken: output.token,
            profile: profile
        )
        return binding
    }

    func discard(_ binding: PreparedBinding) {
        finalizeBinding(token: binding.token)
    }

    func commit(_ prepared: [PreparedBinding], requestID: UUID) throws -> [ActiveBinding] {
        guard !prepared.isEmpty,
              prepared.allSatisfy({ bindings[$0.token] != nil }) else {
            throw RouteTransactionBackendError.commitFailed
        }
        return prepared.map { binding in
            bindings[binding.token]?.isActive = true
            return ActiveBinding(instanceID: binding.instanceID, token: binding.token)
        }
    }

    func waitForPreRoll(
        _ activeBindings: [ActiveBinding],
        minimumFrames: UInt32
    ) async throws {
        guard !activeBindings.isEmpty,
              activeBindings.allSatisfy({ bindings[$0.token]?.isActive == true }) else {
            throw RouteTransactionBackendError.commitFailed
        }
        guard minimumFrames > 0 else { return }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(
            by: .milliseconds(
                PreRollWaitPolicy.timeoutMilliseconds(minimumFrames: minimumFrames)
            )
        )
        var observedProgress = await captureProgress.currentGeneration()
        while true {
            guard activeBindings.allSatisfy({ activeBinding in
                guard let resource = bindings[activeBinding.token],
                      resource.isActive,
                      captures[resource.captureToken]?.session != nil else {
                    return false
                }
                return true
            }) else {
                throw RouteTransactionBackendError.commitFailed
            }
            let ready = activeBindings.allSatisfy { activeBinding in
                guard let resource = bindings[activeBinding.token] else {
                    return false
                }
                // A fresh candidate cannot be consumed before its device
                // render state reaches pre-roll. The cumulative count remains
                // a proof after the callback begins consuming, avoiding a
                // control-plane poll that can miss the brief queue watermark.
                return ypq_route_binding_available_frames(resource.pointer) >= minimumFrames
                    || ypq_route_binding_produced_frames(resource.pointer) >= minimumFrames
            }
            if ready { return }
            observedProgress = try await waitForCaptureProgress(
                after: observedProgress,
                until: deadline
            )
        }
    }

    /// All panorama branches are filled until the most-delayed endpoint is
    /// ready. Without this trim every branch starts with the same queue depth,
    /// and the clock bridge would need minutes to drift toward a large manual
    /// offset. Drop only the older surplus frames from the less-delayed
    /// branches so every output starts at its own requested timeline offset.
    func alignPreRoll(_ activeBindings: [ActiveBinding]) throws {
        guard !activeBindings.isEmpty,
              activeBindings.allSatisfy({ bindings[$0.token]?.isActive == true }) else {
            throw RouteTransactionBackendError.commitFailed
        }
        var scratch = [Float](repeating: 0, count: Int(maxCallbackFrames) * 2)
        for activeBinding in activeBindings {
            guard let resource = bindings[activeBinding.token] else {
                throw RouteTransactionBackendError.commitFailed
            }
            var remaining = PreRollAlignmentPolicy.discardFrames(
                queuedFrames: ypq_route_binding_available_frames(resource.pointer),
                desiredFrames: resource.profile.preRollFrames
            )
            while remaining > 0 {
                let chunk = min(remaining, maxCallbackFrames)
                let discarded = scratch.withUnsafeMutableBufferPointer {
                    ypq_route_binding_read_unmetered(resource.pointer, $0.baseAddress, chunk)
                }
                guard discarded > 0 else { break }
                remaining -= discarded
            }
        }
    }

    /// Races a real capture callback against the transaction deadline. This
    /// does not poll the C++ atomics: each wake-up is caused by a callback
    /// completion, and the caller validates resource ownership again before
    /// committing the next lifecycle step.
    private func waitForCaptureProgress(
        after observedProgress: UInt64,
        until deadline: ContinuousClock.Instant
    ) async throws -> UInt64 {
        let notifier = captureProgress
        return try await withThrowingTaskGroup(of: UInt64.self) { group in
            group.addTask {
                guard let progressed = await notifier.waitForProgress(after: observedProgress) else {
                    throw CancellationError()
                }
                return progressed
            }
            group.addTask {
                try await ContinuousClock().sleep(until: deadline)
                throw RouteTransactionBackendError.commitFailed
            }
            defer { group.cancelAll() }
            guard let progressed = try await group.next() else {
                throw RouteTransactionBackendError.commitFailed
            }
            return progressed
        }
    }

    func teardown(_ binding: ActiveBinding) {
        finalizeBinding(token: binding.token)
    }

    /// The caller has already stopped the output (consumer) and capture
    /// (producer). If a platform callback has not yet quiesced, retaining the
    /// allocation is intentionally safer than freeing it; a later lifecycle
    /// retry can call this method again.
    private func finalizeBinding(token: UUID) {
        guard let resource = bindings[token] else { return }
        _ = ypq_route_binding_begin_retirement(resource.pointer)
        ypq_route_binding_mark_producer_detached(resource.pointer)

        let output = resource.output
        if output.session != nil,
           !output.activeOutputClaims.isEmpty,
           output.renderSnapshot.requiresReplacement(removing: [token]) {
            let remaining = renderEligibleBindings(
                for: output,
                excludingBindingToken: token
            )
            if remaining.isEmpty {
                output.session?.stop()
                output.session = nil
                output.profile = nil
                output.renderSnapshot.recordPublished([])
            } else {
                do {
                    try output.renderSnapshot.replaceIfNeeded(
                        removing: [token],
                        publishing: Set(remaining.map(\.token))
                    ) {
                        try output.session?.replaceBindings(
                            remaining.map(\.pointer),
                            profile: resource.profile
                        )
                    }
                } catch {
                    // Keep the old immutable snapshot and retain this binding;
                    // freeing it after an unsuccessful replacement would risk a
                    // callback dereferencing released realtime state.
                    return
                }
            }
        }
        output.snapshotGeneration &+= 1
        ypq_route_binding_acknowledge_snapshot_removal(resource.pointer, output.snapshotGeneration)
        if ypq_route_binding_discard_sealed_tail(resource.pointer),
           ypq_route_binding_ready_to_reclaim(resource.pointer, output.snapshotGeneration),
           ypq_route_binding_finish_retirement(resource.pointer) {
            ypq_route_binding_destroy(resource.pointer)
            bindings.removeValue(forKey: token)
            releaseOutputResourceIfUnused(output)
        }
    }

    private func renderEligibleBindings(
        for output: OutputResource,
        excludingBindingToken: UUID? = nil
    ) -> [BindingResource] {
        let candidates = bindings.compactMap { token, resource -> OutputClaimBindingState? in
            guard resource.output === output, token != excludingBindingToken else {
                return nil
            }
            return OutputClaimBindingState(
                bindingToken: token,
                outputClaimToken: resource.outputClaimToken,
                isActive: resource.isActive
            )
        }
        let eligibleTokens = OutputClaimRenderEligibility.eligibleBindingTokens(
            candidates,
            activeOutputClaims: output.activeOutputClaims
        )
        return bindings.compactMap { token, resource in
            eligibleTokens.contains(token) ? resource : nil
        }
    }

    /// Removing one logical route claim must synchronously remove its bindings
    /// from the shared physical AUHAL snapshot. A failed capture restoration
    /// may retain those allocations, but it never retains render eligibility.
    private func removeStoppedClaimFromRenderSnapshot(
        _ stoppedClaimToken: UUID,
        outputResource: OutputResource
    ) {
        let removed = bindings.values.filter {
            $0.output === outputResource
                && $0.outputClaimToken == stoppedClaimToken
                && $0.isActive
        }
        let remaining = renderEligibleBindings(for: outputResource)
        let removedTokens = Set(removed.map(\.token))

        if let session = outputResource.session {
            if !outputResource.renderSnapshot.requiresReplacement(
                removing: removedTokens
            ) {
                // A prior coalesced claim removal already published the exact
                // remaining snapshot. Binding retirement must not replace it
                // again and reset unaffected bindings' ASRC/pre-roll state.
            } else if let profile = remaining.first?.profile,
                      remaining.allSatisfy({ $0.profile == profile }) {
                do {
                    let replaced = try outputResource.renderSnapshot.replaceIfNeeded(
                        removing: removedTokens,
                        publishing: Set(remaining.map(\.token))
                    ) {
                        try session.replaceBindings(
                            remaining.map(\.pointer),
                            profile: profile
                        )
                    }
                    if replaced {
                        outputResource.profile = profile
                    }
                } catch {
                    // Keeping the prior snapshot would let a failed route keep
                    // rendering. Stop it, then rebuild only from live claims.
                    session.stop()
                    outputResource.session = nil
                    outputResource.profile = nil
                    do {
                        let replacement = try AUHALOutputSession(
                            deviceID: outputResource.deviceID,
                            clientSampleRate: outputResource.clientFormat.mSampleRate,
                            bindings: remaining.map(\.pointer),
                            profile: profile,
                            maxCallbackFrames: maxCallbackFrames
                        )
                        try replacement.start()
                        outputResource.session = replacement
                        outputResource.profile = profile
                        outputResource.renderSnapshot.recordPublished(
                            Set(remaining.map(\.token))
                        )
                    } catch {
                        outputResource.session?.stop()
                        outputResource.session = nil
                        outputResource.profile = nil
                        outputResource.renderSnapshot.recordPublished([])
                    }
                }
            } else {
                session.stop()
                outputResource.session = nil
                outputResource.profile = nil
                outputResource.renderSnapshot.recordPublished([])
            }
        } else {
            outputResource.renderSnapshot.recordPublished([])
        }

        outputResource.snapshotGeneration &+= 1
        for resource in removed {
            ypq_route_binding_acknowledge_snapshot_removal(
                resource.pointer,
                outputResource.snapshotGeneration
            )
        }
    }

    private func releaseOutputResourceIfUnused(_ resource: OutputResource) {
        guard resource.session == nil,
              resource.activeOutputClaims.isEmpty,
              !outputs.values.contains(where: { $0 === resource }),
              !bindings.values.contains(where: { $0.output === resource }) else {
            return
        }
        outputResourcesByUID.removeValue(forKey: resource.deviceUID)
    }

}
