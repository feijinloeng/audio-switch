import Foundation

/// A hardware-independent buffer configuration selected before realtime work.
/// The production profile is locked by phase-0 evidence; it is never adjusted
/// from a callback.
struct BufferProfile: Equatable, Sendable {
    let capacityFrames: UInt32
    let preRollFrames: UInt32
    let targetFrames: UInt32
    let lowFrames: UInt32
    let highFrames: UInt32

    /// All buffer arithmetic in the realtime core assumes a power-of-two
    /// capacity. Bounds are selected once during prepare and never adjusted
    /// from a callback.
    var isValid: Bool {
        capacityFrames != 0
            && capacityFrames.nonzeroBitCount == 1
            && preRollFrames <= capacityFrames
            && lowFrames <= targetFrames
            && targetFrames <= highFrames
            && highFrames <= capacityFrames
    }

    static let wiredDefault = BufferProfile(
        capacityFrames: 16_384,
        preRollFrames: 1_920,
        targetFrames: 1_920,
        lowFrames: 720,
        highFrames: 4_800
    )

    static let bluetooth = BufferProfile(
        // Bluetooth output can pause its render callback while the hardware
        // transport settles after a route change. Keep the normal pre-roll
        // short, but reserve enough headroom for that one-time burst so the
        // Process Tap never has to drop program frames (heard as distortion).
        capacityFrames: 131_072,
        preRollFrames: 8_192,
        targetFrames: 8_192,
        lowFrames: 3_840,
        highFrames: 32_768
    )

    /// Panorama playback trades approximately one second of end-to-end
    /// latency for a shared 48 kHz program timeline. The backing ring leaves
    /// room for the one-second user correction plus acoustic alignment.
    static let panorama = BufferProfile(
        capacityFrames: 262_144,
        preRollFrames: 48_000,
        targetFrames: 48_000,
        lowFrames: 24_000,
        highFrames: 96_000
    )

    /// A per-endpoint, control-plane delay for manual panorama alignment. The
    /// offset is represented by a higher steady-state target fill (not a
    /// one-time start pause), so the ASRC controller preserves it after the
    /// initial pre-roll.
    static func panorama(delaying milliseconds: Int) -> BufferProfile {
        let delayFrames = UInt32(
            min(
                max(milliseconds, 0),
                PanoramaGroupMember.maximumManualDelayMilliseconds
            ) * 48
        )
        return BufferProfile(
            capacityFrames: panorama.capacityFrames,
            preRollFrames: panorama.preRollFrames + delayFrames,
            targetFrames: panorama.targetFrames + delayFrames,
            lowFrames: panorama.lowFrames + delayFrames,
            highFrames: panorama.highFrames + delayFrames
        )
    }

    /// Returns the manual panorama offset encoded in a binding's pre-roll
    /// profile. The AUHAL render session itself uses the stable base profile;
    /// the offset is owned by its independently adjustable device-bus delay.
    var panoramaManualDelayMilliseconds: Int? {
        let base = Self.panorama
        guard capacityFrames == base.capacityFrames,
              preRollFrames >= base.preRollFrames,
              targetFrames >= base.targetFrames,
              lowFrames >= base.lowFrames,
              highFrames >= base.highFrames else {
            return nil
        }
        let offset = preRollFrames - base.preRollFrames
        guard targetFrames - base.targetFrames == offset,
              lowFrames - base.lowFrames == offset,
              highFrames - base.highFrames == offset,
              offset % 48 == 0 else {
            return nil
        }
        return Int(offset / 48)
    }

    static func profile(for device: OutputDeviceDescriptor) -> BufferProfile {
        device.transport == .bluetooth ? .bluetooth : .wiredDefault
    }
}

/// Opaque lifecycle values. They intentionally contain no `AudioObjectID`,
/// `AudioUnit`, pointer, or other HAL resource that could escape into domain
/// state or persistence.
struct PreparedCapture: Sendable { let instanceID: AppInstanceID; let token: UUID }
struct ActiveCapture: Sendable { let instanceID: AppInstanceID; let token: UUID }
struct PreparedOutput: Sendable { let deviceUID: String; let token: UUID }
struct ActiveOutput: Sendable { let deviceUID: String; let token: UUID }
struct PreparedBinding: Sendable { let instanceID: AppInstanceID; let token: UUID }
struct ActiveBinding: Sendable { let instanceID: AppInstanceID; let token: UUID }

/// Uniform control-plane reference used to publish prepared or active
/// bindings into a capture-owned immutable fan-out snapshot.
struct RouteBindingTarget: Sendable {
    let instanceID: AppInstanceID
    let token: UUID

    init(_ binding: PreparedBinding) {
        instanceID = binding.instanceID
        token = binding.token
    }

    init(_ binding: ActiveBinding) {
        instanceID = binding.instanceID
        token = binding.token
    }
}

/// Proof handle for one capture snapshot publication. Concrete backends own
/// its generation and acknowledge it only after the callback has observed the
/// replacement.
struct CaptureBindingPublication: Sendable {
    let instanceID: AppInstanceID
    let captureToken: UUID
    let generation: UInt64
}

struct BackendRouteRequest: Sendable {
    let identity: AppIdentity
    let requestID: UUID
    let targetDevice: OutputDeviceDescriptor
    let groups: [AudioProcessGroup]
    let bufferProfile: BufferProfile
    /// A Core Audio service restart invalidates every opaque process/device
    /// handle even when their public UID happens to be unchanged.
    let halEpoch: UInt64

    init(
        identity: AppIdentity,
        requestID: UUID,
        targetDevice: OutputDeviceDescriptor,
        groups: [AudioProcessGroup],
        bufferProfile: BufferProfile,
        halEpoch: UInt64 = 0
    ) {
        self.identity = identity
        self.requestID = requestID
        self.targetDevice = targetDevice
        self.groups = groups
        self.bufferProfile = bufferProfile
        self.halEpoch = halEpoch
    }

    var fingerprint: BackendRouteFingerprint {
        BackendRouteFingerprint(
            identity: identity,
            targetDeviceUID: targetDevice.uid,
            targetDeviceReadiness: targetDevice.readiness,
            targetSampleRate: targetDevice.nominalSampleRate,
            targetChannelCount: targetDevice.channelCount,
            groups: groups.sorted {
                if $0.instanceID.ownerPID != $1.instanceID.ownerPID {
                    return $0.instanceID.ownerPID < $1.instanceID.ownerPID
                }
                return $0.instanceID.launchGeneration < $1.instanceID.launchGeneration
            },
            bufferProfile: bufferProfile,
            halEpoch: halEpoch
        )
    }
}

/// Control-plane identity of a committed topology. It intentionally excludes
/// per-app DSP controls because volume and mute are published to an
/// existing binding and must never cause Process Tap/AUHAL reconstruction.
struct BackendRouteFingerprint: Equatable, Sendable {
    let identity: AppIdentity
    let targetDeviceUID: String
    let targetDeviceReadiness: OutputDeviceReadiness
    let targetSampleRate: Double
    let targetChannelCount: Int
    let groups: [AudioProcessGroup]
    let bufferProfile: BufferProfile
    let halEpoch: UInt64
}

struct ActiveRouteResources: Sendable {
    let output: ActiveOutput
    let captures: [ActiveCapture]
    let bindings: [ActiveBinding]
}

struct PreparedRouteResources: Sendable {
    let output: ActiveOutput
    let captures: [ActiveCapture]
    let bindings: [PreparedBinding]
    let handoffFrom: ActiveRouteResources?
    let handoffPreRollFrames: UInt32?

    init(
        output: ActiveOutput,
        captures: [ActiveCapture],
        bindings: [PreparedBinding],
        handoffFrom: ActiveRouteResources? = nil,
        handoffPreRollFrames: UInt32? = nil
    ) {
        self.output = output
        self.captures = captures
        self.bindings = bindings
        self.handoffFrom = handoffFrom
        self.handoffPreRollFrames = handoffPreRollFrames
    }
}

protocol CaptureSessionBackend: Sendable {
    func prepare(
        app: AppIdentity,
        instance: AppInstanceID,
        group: AudioProcessGroup
    ) async throws -> PreparedCapture
    func discard(_ capture: PreparedCapture) async
    func start(_ capture: PreparedCapture) async throws -> ActiveCapture
    func stop(_ capture: ActiveCapture) async
    /// Control-plane-only immutable fan-out replacement. Binding targets are
    /// borrowed until `acknowledge` proves the callback left older snapshots.
    func publishBindings(
        _ bindings: [RouteBindingTarget],
        for capture: ActiveCapture
    ) async throws -> CaptureBindingPublication
    func acknowledge(_ publication: CaptureBindingPublication) async throws
}

protocol OutputSessionBackend: Sendable {
    func prepare(device: OutputDeviceDescriptor) async throws -> PreparedOutput
    func discard(_ output: PreparedOutput) async
    func start(_ output: PreparedOutput) async throws -> ActiveOutput
    /// Publishes the complete immutable binding snapshot to this single
    /// physical-device session. It runs only after every capture/binding is
    /// prepared and therefore must not create one AUHAL per binding.
    /// `initialGain` lets a hot-swapped joining endpoint start silent and fade in.
    func activate(
        _ output: ActiveOutput,
        bindings: [ActiveBinding],
        initialGain: Float
    ) async throws
    /// Changes only the physical output's device-bus delay. Implementations
    /// must not stop or replace the active output session.
    func setManualDelay(milliseconds: Int, for output: ActiveOutput) async throws
    func stop(_ output: ActiveOutput) async
}

extension OutputSessionBackend {
    /// Two-argument convenience that activates at full gain.
    func activate(_ output: ActiveOutput, bindings: [ActiveBinding]) async throws {
        try await activate(output, bindings: bindings, initialGain: 1)
    }

    func setManualDelay(milliseconds: Int, for output: ActiveOutput) async throws {}
}

protocol RouteBindingBackend: Sendable {
    func prepare(
        capture: PreparedCapture,
        output: ActiveOutput,
        profile: BufferProfile
    ) async throws -> PreparedBinding
    func discard(_ binding: PreparedBinding) async
    func commit(_ bindings: [PreparedBinding], requestID: UUID) async throws -> [ActiveBinding]
    /// Waits on the control plane while the candidate receives enough capture
    /// frames for its render session to leave pre-roll.
    func waitForPreRoll(_ bindings: [ActiveBinding], minimumFrames: UInt32) async throws
    /// Trims each binding to its own configured pre-roll after the slowest
    /// panorama endpoint is ready. This establishes the requested relative
    /// delay before any output callback starts consuming frames.
    func alignPreRoll(_ bindings: [ActiveBinding]) async throws
    /// Implements the complete producer-detach, tail-drain, snapshot-removal
    /// proof before freeing realtime memory.
    func teardown(_ binding: ActiveBinding) async
}

extension RouteBindingBackend {
    func alignPreRoll(_ bindings: [ActiveBinding]) async throws {}
}

protocol AudioRoutingBackend: Sendable {
    func prepare(_ request: BackendRouteRequest) async throws -> PreparedRouteResources
    func prepareHandoff(
        from current: ActiveRouteResources,
        request: BackendRouteRequest
    ) async throws -> PreparedRouteResources
    func commit(_ prepared: PreparedRouteResources, requestID: UUID) async throws -> ActiveRouteResources
    func rollback(_ prepared: PreparedRouteResources) async
    func finalizeHandoff(
        old: ActiveRouteResources,
        new: ActiveRouteResources
    ) async throws
    func teardown(_ active: ActiveRouteResources) async
}

extension AudioRoutingBackend {
    func prepareHandoff(
        from current: ActiveRouteResources,
        request: BackendRouteRequest
    ) async throws -> PreparedRouteResources {
        throw RouteTransactionBackendError.prepareFailed
    }

    func finalizeHandoff(
        old: ActiveRouteResources,
        new: ActiveRouteResources
    ) async throws {
        throw RouteTransactionBackendError.commitFailed
    }
}

private enum DeferredBindingRetirement: Sendable {
    case prepared(PreparedBinding)
    case active(ActiveBinding)

    var token: UUID {
        switch self {
        case .prepared(let binding):
            binding.token
        case .active(let binding):
            binding.token
        }
    }
}

private actor DeferredBindingRetirementStore {
    private struct Entry: Sendable {
        let captureToken: UUID
        let minimumGeneration: UInt64?
        let retirement: DeferredBindingRetirement
    }

    private var entriesByBindingToken: [UUID: Entry] = [:]

    func retain(
        _ retirement: DeferredBindingRetirement,
        captureToken: UUID,
        minimumGeneration: UInt64?
    ) {
        entriesByBindingToken[retirement.token] = Entry(
            captureToken: captureToken,
            minimumGeneration: minimumGeneration,
            retirement: retirement
        )
    }

    func takeAcknowledged(
        captureToken: UUID,
        generation: UInt64
    ) -> [DeferredBindingRetirement] {
        take { entry in
            guard entry.captureToken == captureToken else { return false }
            guard let minimumGeneration = entry.minimumGeneration else {
                return true
            }
            return generation >= minimumGeneration
        }
    }

    func takeAll(
        captureTokens: Set<UUID>
    ) -> [DeferredBindingRetirement] {
        take { captureTokens.contains($0.captureToken) }
    }

    private func take(
        where predicate: (Entry) -> Bool
    ) -> [DeferredBindingRetirement] {
        let selected = entriesByBindingToken.filter { predicate($0.value) }
        for token in selected.keys {
            entriesByBindingToken.removeValue(forKey: token)
        }
        return selected.values.map(\.retirement)
    }
}

private struct CaptureBindingRestoration: Sendable {
    let publication: CaptureBindingPublication?
    let acknowledged: Bool
}

/// The only intended production topology composer. It owns no HAL object
/// itself; the supplied concrete session backends run their lifecycle actions
/// on `CoreAudioHALExecutor`. Its ordering makes the physical output ready,
/// wires each binding before its capture callback can run, and reverses every
/// transaction-owned resource on a pre-commit failure.
struct DecoupledClockBridgedBackend: AudioRoutingBackend {
    private let capture: any CaptureSessionBackend
    private let output: any OutputSessionBackend
    private let binding: any RouteBindingBackend
    private let deferredRetirements: DeferredBindingRetirementStore

    init(
        capture: any CaptureSessionBackend,
        output: any OutputSessionBackend,
        binding: any RouteBindingBackend
    ) {
        self.capture = capture
        self.output = output
        self.binding = binding
        deferredRetirements = DeferredBindingRetirementStore()
    }

    func prepare(_ request: BackendRouteRequest) async throws -> PreparedRouteResources {
        guard request.bufferProfile.isValid else {
            throw RouteTransactionBackendError.prepareFailed
        }
        let preparedOutput = try await output.prepare(device: request.targetDevice)
        let activeOutput: ActiveOutput
        do {
            activeOutput = try await output.start(preparedOutput)
        } catch {
            await output.discard(preparedOutput)
            throw error
        }
        var activeCaptures: [ActiveCapture] = []
        var preparedCaptures: [PreparedCapture] = []
        var preparedBindings: [PreparedBinding] = []

        do {
            for group in request.groups.sorted(by: { $0.instanceID.ownerPID < $1.instanceID.ownerPID }) {
                let preparedCapture = try await capture.prepare(
                    app: request.identity,
                    instance: group.instanceID,
                    group: group
                )
                preparedCaptures.append(preparedCapture)
                let preparedBinding = try await binding.prepare(
                    capture: preparedCapture,
                    output: activeOutput,
                    profile: request.bufferProfile
                )
                preparedBindings.append(preparedBinding)
            }
            for preparedCapture in preparedCaptures {
                let activeCapture = try await capture.start(preparedCapture)
                activeCaptures.append(activeCapture)
            }
            return PreparedRouteResources(
                output: activeOutput,
                captures: activeCaptures,
                bindings: preparedBindings
            )
        } catch {
            for activeCapture in activeCaptures.reversed() {
                await capture.stop(activeCapture)
            }
            let activeTokens = Set(activeCaptures.map(\.token))
            for preparedCapture in preparedCaptures.reversed()
                where !activeTokens.contains(preparedCapture.token) {
                await capture.discard(preparedCapture)
            }
            for preparedBinding in preparedBindings.reversed() {
                await binding.discard(preparedBinding)
            }
            await output.stop(activeOutput)
            throw error
        }
    }

    func prepareHandoff(
        from current: ActiveRouteResources,
        request: BackendRouteRequest
    ) async throws -> PreparedRouteResources {
        guard request.bufferProfile.isValid,
              matchingCaptureAndBindingPairs(in: current) != nil,
              Set(current.captures.map(\.instanceID))
                == Set(request.groups.map(\.instanceID)) else {
            throw RouteTransactionBackendError.prepareFailed
        }

        let preparedOutput = try await output.prepare(device: request.targetDevice)
        let activeOutput: ActiveOutput
        do {
            activeOutput = try await output.start(preparedOutput)
        } catch {
            await output.discard(preparedOutput)
            throw error
        }

        var preparedBindings: [PreparedBinding] = []
        do {
            for activeCapture in current.captures.sorted(by: {
                $0.instanceID.ownerPID < $1.instanceID.ownerPID
            }) {
                let preparedCapture = PreparedCapture(
                    instanceID: activeCapture.instanceID,
                    token: activeCapture.token
                )
                preparedBindings.append(
                    try await binding.prepare(
                        capture: preparedCapture,
                        output: activeOutput,
                        profile: request.bufferProfile
                    )
                )
            }

            guard let oldPairs = matchingCaptureAndBindingPairs(in: current),
                  let candidateByInstance = uniquePreparedBindings(preparedBindings) else {
                throw RouteTransactionBackendError.prepareFailed
            }
            for (activeCapture, oldBinding) in oldPairs {
                guard let candidate = candidateByInstance[activeCapture.instanceID] else {
                    throw RouteTransactionBackendError.prepareFailed
                }
                _ = try await capture.publishBindings(
                    [RouteBindingTarget(oldBinding), RouteBindingTarget(candidate)],
                    for: activeCapture
                )
            }

            return PreparedRouteResources(
                output: activeOutput,
                captures: current.captures,
                bindings: preparedBindings,
                handoffFrom: current,
                handoffPreRollFrames: request.bufferProfile.preRollFrames
            )
        } catch {
            let restoration = await restoreCaptureBindings(for: current)
            await output.stop(activeOutput)
            await retireOrDefer(
                preparedBindings.map(DeferredBindingRetirement.prepared),
                captures: current.captures,
                restoration: restoration
            )
            throw error
        }
    }

    func commit(
        _ prepared: PreparedRouteResources,
        requestID: UUID
    ) async throws -> ActiveRouteResources {
        let activeBindings = try await binding.commit(prepared.bindings, requestID: requestID)
        guard activeBindings.count == prepared.bindings.count else {
            throw RouteTransactionBackendError.commitFailed
        }
        try await output.activate(prepared.output, bindings: activeBindings)
        if let preRollFrames = prepared.handoffPreRollFrames {
            try await binding.waitForPreRoll(
                activeBindings,
                minimumFrames: preRollFrames
            )
        }
        return ActiveRouteResources(
            output: prepared.output,
            captures: prepared.captures,
            bindings: activeBindings
        )
    }

    func rollback(_ prepared: PreparedRouteResources) async {
        if let previous = prepared.handoffFrom {
            let restoration = await restoreCaptureBindings(for: previous)
            await output.stop(prepared.output)
            await retireOrDefer(
                prepared.bindings.reversed().map(DeferredBindingRetirement.prepared),
                captures: previous.captures,
                restoration: restoration
            )
            return
        }
        // An output callback is the binding consumer. Remove that snapshot
        // first, then detach producers, and only then free prepared binding
        // state. A concrete backend must make `discard` wait for its C++
        // producer/tail/gate proof before actually destroying memory.
        await output.stop(prepared.output)
        for activeCapture in prepared.captures.reversed() {
            await capture.stop(activeCapture)
        }
        for preparedBinding in prepared.bindings.reversed() {
            await binding.discard(preparedBinding)
        }
        await retireDeferredBindings(
            forStoppedCaptures: prepared.captures
        )
    }

    func finalizeHandoff(
        old: ActiveRouteResources,
        new: ActiveRouteResources
    ) async throws {
        guard Set(old.captures.map(\.token)) == Set(new.captures.map(\.token)),
              let oldPairs = matchingCaptureAndBindingPairs(in: old),
              let newBindingByInstance = uniqueActiveBindings(new.bindings) else {
            throw RouteTransactionBackendError.commitFailed
        }

        var candidatePublications:
            [AppInstanceID: CaptureBindingPublication] = [:]
        do {
            for (activeCapture, _) in oldPairs {
                guard let candidate = newBindingByInstance[activeCapture.instanceID] else {
                    throw RouteTransactionBackendError.commitFailed
                }
                let publication = try await capture.publishBindings(
                    [RouteBindingTarget(candidate)],
                    for: activeCapture
                )
                candidatePublications[activeCapture.instanceID] = publication
            }
        } catch {
            let restoration = await restoreCaptureBindings(for: old)
            await output.stop(new.output)
            await retireOrDefer(
                new.bindings.reversed().map(DeferredBindingRetirement.active),
                captures: old.captures,
                restoration: restoration
            )
            throw error
        }

        // Once every capture has published candidate-only, the candidate is
        // the only route guaranteed to be receiving every source. Callback
        // acknowledgement is a memory-retirement proof, not a reason to undo
        // an already-audible cutover. Treating its timeout as rollback could
        // stop the candidate after a fallible old-only restoration and leave
        // the capture targeting no running output.
        var candidateProofs:
            [AppInstanceID: CaptureBindingRestoration] = [:]
        for (activeCapture, _) in oldPairs {
            guard let publication = candidatePublications[activeCapture.instanceID] else {
                throw RouteTransactionBackendError.commitFailed
            }
            var acknowledged = false
            do {
                try await acknowledgeAndRetireDeferred(publication)
                acknowledged = true
            } catch {
                // The old binding remains allocated until a later capture
                // generation is acknowledged or the capture is stopped.
            }
            candidateProofs[activeCapture.instanceID] = CaptureBindingRestoration(
                publication: publication,
                acknowledged: acknowledged
            )
        }

        await output.stop(old.output)
        await retireOrDefer(
            old.bindings.reversed().map(DeferredBindingRetirement.active),
            captures: old.captures,
            restoration: candidateProofs
        )
    }

    func teardown(_ active: ActiveRouteResources) async {
        await output.stop(active.output)
        for activeCapture in active.captures.reversed() {
            await capture.stop(activeCapture)
        }
        for activeBinding in active.bindings.reversed() {
            await binding.teardown(activeBinding)
        }
        await retireDeferredBindings(
            forStoppedCaptures: active.captures
        )
    }

    private func restoreCaptureBindings(
        for route: ActiveRouteResources
    ) async -> [AppInstanceID: CaptureBindingRestoration] {
        guard let pairs = matchingCaptureAndBindingPairs(in: route) else {
            return [:]
        }
        var result: [AppInstanceID: CaptureBindingRestoration] = [:]
        for (activeCapture, activeBinding) in pairs {
            var publication: CaptureBindingPublication?
            var acknowledged = false
            do {
                let published = try await capture.publishBindings(
                    [RouteBindingTarget(activeBinding)],
                    for: activeCapture
                )
                publication = published
                do {
                    try await acknowledgeAndRetireDeferred(published)
                    acknowledged = true
                } catch {
                    acknowledged = false
                }
            } catch {
                publication = nil
            }
            result[activeCapture.instanceID] = CaptureBindingRestoration(
                publication: publication,
                acknowledged: acknowledged
            )
        }
        return result
    }

    private func acknowledgeAndRetireDeferred(
        _ publication: CaptureBindingPublication
    ) async throws {
        try await capture.acknowledge(publication)
        let ready = await deferredRetirements.takeAcknowledged(
            captureToken: publication.captureToken,
            generation: publication.generation
        )
        await retire(ready)
    }

    private func retireOrDefer(
        _ retirements: [DeferredBindingRetirement],
        captures: [ActiveCapture],
        restoration: [AppInstanceID: CaptureBindingRestoration]
    ) async {
        let capturesByInstance = Dictionary(
            uniqueKeysWithValues: captures.map { ($0.instanceID, $0) }
        )
        for retirement in retirements {
            let instanceID: AppInstanceID
            switch retirement {
            case .prepared(let binding):
                instanceID = binding.instanceID
            case .active(let binding):
                instanceID = binding.instanceID
            }
            guard let activeCapture = capturesByInstance[instanceID] else {
                continue
            }
            let proof = restoration[instanceID]
            if proof?.acknowledged == true {
                await retire([retirement])
            } else {
                await deferredRetirements.retain(
                    retirement,
                    captureToken: activeCapture.token,
                    minimumGeneration: proof?.publication?.generation
                )
            }
        }
    }

    private func retireDeferredBindings(
        forStoppedCaptures captures: [ActiveCapture]
    ) async {
        let retirements = await deferredRetirements.takeAll(
            captureTokens: Set(captures.map(\.token))
        )
        await retire(retirements)
    }

    private func retire(
        _ retirements: [DeferredBindingRetirement]
    ) async {
        for retirement in retirements {
            switch retirement {
            case .prepared(let prepared):
                await binding.discard(prepared)
            case .active(let active):
                await binding.teardown(active)
            }
        }
    }

    private func matchingCaptureAndBindingPairs(
        in route: ActiveRouteResources
    ) -> [(ActiveCapture, ActiveBinding)]? {
        guard let bindingsByInstance = uniqueActiveBindings(route.bindings),
              bindingsByInstance.count == route.captures.count,
              Set(route.captures.map(\.instanceID)).count == route.captures.count else {
            return nil
        }
        var result: [(ActiveCapture, ActiveBinding)] = []
        for activeCapture in route.captures.sorted(by: {
            $0.instanceID.ownerPID < $1.instanceID.ownerPID
        }) {
            guard let activeBinding = bindingsByInstance[activeCapture.instanceID] else {
                return nil
            }
            result.append((activeCapture, activeBinding))
        }
        return result
    }

    private func uniquePreparedBindings(
        _ bindings: [PreparedBinding]
    ) -> [AppInstanceID: PreparedBinding]? {
        guard Set(bindings.map(\.instanceID)).count == bindings.count else {
            return nil
        }
        return Dictionary(uniqueKeysWithValues: bindings.map { ($0.instanceID, $0) })
    }

    private func uniqueActiveBindings(
        _ bindings: [ActiveBinding]
    ) -> [AppInstanceID: ActiveBinding]? {
        guard Set(bindings.map(\.instanceID)).count == bindings.count else {
            return nil
        }
        return Dictionary(uniqueKeysWithValues: bindings.map { ($0.instanceID, $0) })
    }

}
