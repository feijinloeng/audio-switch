import Foundation

/// The local-only topology request. Remote iPhone endpoints are deliberately
/// excluded here: they enter through the companion transport in phase 3 and
/// cannot be mistaken for Core Audio output devices.
struct PanoramaMacRouteRequest: Sendable {
    let identity: AppIdentity
    let groups: [AudioProcessGroup]
    let outputs: [OutputDeviceDescriptor]
    let profile: BufferProfile
    let profilesByOutputUID: [String: BufferProfile]
    let delayMillisecondsByOutputUID: [String: Int]
    /// A remote iPhone peer supplies the second selected endpoint, so one
    /// local AUHAL output is then a valid branch of a 2-endpoint panorama.
    let allowsSingleLocalOutput: Bool

    init(
        identity: AppIdentity,
        groups: [AudioProcessGroup],
        outputs: [OutputDeviceDescriptor],
        profile: BufferProfile = .panorama,
        profilesByOutputUID: [String: BufferProfile] = [:],
        delayMillisecondsByOutputUID: [String: Int] = [:],
        allowsSingleLocalOutput: Bool = false
    ) {
        self.identity = identity
        self.groups = groups
        self.outputs = outputs
        self.profile = profile
        self.profilesByOutputUID = profilesByOutputUID
        self.delayMillisecondsByOutputUID = delayMillisecondsByOutputUID
        self.allowsSingleLocalOutput = allowsSingleLocalOutput
    }

    func profile(for output: OutputDeviceDescriptor) -> BufferProfile {
        profilesByOutputUID[output.uid] ?? profile
    }
}

struct PanoramaMacActiveBinding: Sendable {
    let binding: ActiveBinding
    let capture: ActiveCapture
    let output: ActiveOutput
}

struct PanoramaMacRouteResources: Sendable {
    let outputs: [ActiveOutput]
    let captures: [ActiveCapture]
    let bindings: [PanoramaMacActiveBinding]
}

enum PanoramaMacTopologyError: Error, Equatable, Sendable {
    case outputCountOutOfRange(actual: Int)
    case duplicateOutput(uid: String)
    case outputNotReady(uid: String)
    case noCaptureGroups
    case invalidBufferProfile
    case lifecycleFailed
    case endpointNotActive(uid: String)
    case cannotIsolateLastEndpoint
}

/// Builds the one-capture-to-many-output branch of the panorama topology.
/// Every selected output receives a distinct binding (and hence its own
/// ASRC/clock bridge), while each Process Tap publishes the same source
/// frames to all of those bindings through its immutable fan-out snapshot.
struct PanoramaMacTopologyComposer: Sendable {
    private let capture: any CaptureSessionBackend
    private let output: any OutputSessionBackend
    private let binding: any RouteBindingBackend

    init(
        capture: any CaptureSessionBackend,
        output: any OutputSessionBackend,
        binding: any RouteBindingBackend
    ) {
        self.capture = capture
        self.output = output
        self.binding = binding
    }

    func activate(_ request: PanoramaMacRouteRequest) async throws -> PanoramaMacRouteResources {
        try validate(request)

        var activeOutputs: [ActiveOutput] = []
        var preparedCaptures: [PreparedCapture] = []
        var activeCaptures: [ActiveCapture] = []
        var preparedAssignments: [(capture: PreparedCapture, output: ActiveOutput, binding: PreparedBinding)] = []
        var activeAssignments: [PanoramaMacActiveBinding] = []

        do {
            for device in request.outputs {
                let preparedOutput = try await output.prepare(device: device)
                do {
                    activeOutputs.append(try await output.start(preparedOutput))
                } catch {
                    await output.discard(preparedOutput)
                    throw error
                }
            }

            for group in request.groups.sorted(by: Self.order) {
                preparedCaptures.append(
                    try await capture.prepare(
                        app: request.identity,
                        instance: group.instanceID,
                        group: group
                    )
                )
            }

            for preparedCapture in preparedCaptures {
                for activeOutput in activeOutputs {
                    preparedAssignments.append(
                        (
                                capture: preparedCapture,
                                output: activeOutput,
                                binding: try await binding.prepare(
                                    capture: preparedCapture,
                                    output: activeOutput,
                                    profile: request.profile(for: device(for: activeOutput, in: request.outputs))
                                )
                        )
                    )
                }
            }

            for preparedCapture in preparedCaptures {
                activeCaptures.append(try await capture.start(preparedCapture))
            }

            let committedBindings = try await binding.commit(
                preparedAssignments.map(\.binding),
                requestID: UUID()
            )
            let committedByToken = Dictionary(uniqueKeysWithValues: committedBindings.map { ($0.token, $0) })
            guard committedByToken.count == preparedAssignments.count else {
                throw PanoramaMacTopologyError.lifecycleFailed
            }
            let capturesByToken = Dictionary(uniqueKeysWithValues: activeCaptures.map { ($0.token, $0) })
            activeAssignments = try preparedAssignments.map { assignment in
                guard let activeCapture = capturesByToken[assignment.capture.token],
                      let activeBinding = committedByToken[assignment.binding.token] else {
                    throw PanoramaMacTopologyError.lifecycleFailed
                }
                return PanoramaMacActiveBinding(
                    binding: activeBinding,
                    capture: activeCapture,
                    output: assignment.output
                )
            }

            for activeCapture in activeCaptures {
                let targets = activeAssignments
                    .filter { $0.capture.token == activeCapture.token }
                    .map { RouteBindingTarget($0.binding) }
                guard targets.count == activeOutputs.count else {
                    throw PanoramaMacTopologyError.lifecycleFailed
                }
                _ = try await capture.publishBindings(targets, for: activeCapture)
            }

            try await binding.waitForPreRoll(
                activeAssignments.map(\.binding),
                minimumFrames: request.outputs.map { request.profile(for: $0).preRollFrames }.max() ?? 0
            )
            try await binding.alignPreRoll(activeAssignments.map(\.binding))

            for activeOutput in activeOutputs {
                let outputBindings = activeAssignments
                    .filter { $0.output.token == activeOutput.token }
                    .map(\.binding)
                guard outputBindings.count == activeCaptures.count else {
                    throw PanoramaMacTopologyError.lifecycleFailed
                }
                try await output.setManualDelay(
                    milliseconds: request.delayMillisecondsByOutputUID[activeOutput.deviceUID] ?? 0,
                    for: activeOutput
                )
                try await output.activate(activeOutput, bindings: outputBindings)
            }

            return PanoramaMacRouteResources(
                outputs: activeOutputs,
                captures: activeCaptures,
                bindings: activeAssignments
            )
        } catch {
            for activeOutput in activeOutputs.reversed() {
                await output.stop(activeOutput)
            }
            for activeCapture in activeCaptures.reversed() {
                await capture.stop(activeCapture)
            }
            let activeTokens = Set(activeAssignments.map { $0.binding.token })
            for assignment in preparedAssignments.reversed() {
                if let active = activeAssignments.first(where: { $0.binding.token == assignment.binding.token }) {
                    await binding.teardown(active.binding)
                } else if !activeTokens.contains(assignment.binding.token) {
                    await binding.discard(assignment.binding)
                }
            }
            let activeCaptureTokens = Set(activeCaptures.map(\.token))
            for preparedCapture in preparedCaptures.reversed() where !activeCaptureTokens.contains(preparedCapture.token) {
                await capture.discard(preparedCapture)
            }
            throw error
        }
    }

    /// Publishes runtime delay targets to already-running physical outputs.
    /// No capture, binding, render snapshot, or AUHAL lifecycle is changed.
    func updateManualDelay(
        endpointUID: String,
        milliseconds: Int,
        in resources: PanoramaMacRouteResources
    ) async throws {
        guard let activeOutput = resources.outputs.first(where: {
            $0.deviceUID == endpointUID
        }) else {
            throw PanoramaMacTopologyError.endpointNotActive(uid: endpointUID)
        }
        try await output.setManualDelay(milliseconds: milliseconds, for: activeOutput)
    }

    func teardown(_ resources: PanoramaMacRouteResources) async {
        for activeOutput in resources.outputs.reversed() {
            await output.stop(activeOutput)
        }
        for activeCapture in resources.captures.reversed() {
            await capture.stop(activeCapture)
        }
        for assignment in resources.bindings.reversed() {
            await binding.teardown(assignment.binding)
        }
    }

    /// Hot-swaps one local output into an already-active panorama route. The
    /// existing outputs, captures, and bindings are untouched; the joining
    /// output starts silent (`initialGain: 0`) so the engine can fade it in.
    /// Targets in `retainingAdditionalTargetsByCapture` (the authenticated
    /// iPhone network rings) stay on every republished fan-out so joining a
    /// speaker never cuts the companion's PCM feed.
    /// On failure every newly prepared resource is rolled back and the original
    /// route is returned untouched.
    func addEndpoint(
        device: OutputDeviceDescriptor,
        delayMilliseconds: Int,
        to resources: PanoramaMacRouteResources,
        retainingAdditionalTargetsByCapture: [UUID: [RouteBindingTarget]] = [:]
    ) async throws -> PanoramaMacRouteResources {
        guard device.readiness.isPreflightReady else {
            throw PanoramaMacTopologyError.outputNotReady(uid: device.uid)
        }
        guard !resources.outputs.contains(where: { $0.deviceUID == device.uid }) else {
            throw PanoramaMacTopologyError.duplicateOutput(uid: device.uid)
        }
        let profile = BufferProfile.panorama(delaying: delayMilliseconds)
        guard profile.isValid else {
            throw PanoramaMacTopologyError.invalidBufferProfile
        }
        let orderedCaptures = resources.captures.sorted {
            $0.instanceID.ownerPID < $1.instanceID.ownerPID
        }

        let preparedOutput = try await output.prepare(device: device)
        let activeOutput: ActiveOutput
        do {
            activeOutput = try await output.start(preparedOutput)
        } catch {
            await output.discard(preparedOutput)
            throw error
        }

        var preparedBindings: [PreparedBinding] = []
        var activeBindings: [ActiveBinding] = []
        var assignments: [PanoramaMacActiveBinding] = []
        var rollbackTargetsByCaptureToken: [
            UUID: (capture: ActiveCapture, targets: [RouteBindingTarget])
        ] = [:]
        do {
            for capture in orderedCaptures {
                preparedBindings.append(
                    try await binding.prepare(
                        capture: PreparedCapture(instanceID: capture.instanceID, token: capture.token),
                        output: activeOutput,
                        profile: profile
                    )
                )
            }
            activeBindings = try await binding.commit(preparedBindings, requestID: UUID())
            guard activeBindings.count == preparedBindings.count else {
                throw PanoramaMacTopologyError.lifecycleFailed
            }
            assignments = try zip(orderedCaptures, activeBindings).map { capture, active in
                PanoramaMacActiveBinding(binding: active, capture: capture, output: activeOutput)
            }

            // Re-publish each capture fan-out so it now also feeds the joining
            // binding. Existing bindings keep their queue and ASRC state.
            for activeCapture in resources.captures {
                let existingTargets = resources.bindings
                    .filter { $0.capture.token == activeCapture.token }
                    .map { RouteBindingTarget($0.binding) }
                let originalTargets = existingTargets
                    + (retainingAdditionalTargetsByCapture[activeCapture.token] ?? [])
                guard let newAssignment = assignments.first(where: {
                    $0.capture.token == activeCapture.token
                }) else {
                    throw PanoramaMacTopologyError.lifecycleFailed
                }
                // Save the exact live fan-out before publishing the new target.
                // `publishBindings` only replaces the snapshot; its old raw
                // binding pointers remain borrowed until a later acknowledgement.
                rollbackTargetsByCaptureToken[activeCapture.token] = (
                    capture: activeCapture,
                    targets: originalTargets
                )
                let targets = originalTargets + [RouteBindingTarget(newAssignment.binding)]
                let publication = try await capture.publishBindings(targets, for: activeCapture)
                try await capture.acknowledge(publication)
            }

            try await binding.waitForPreRoll(
                activeBindings,
                minimumFrames: profile.preRollFrames
            )
            try await binding.alignPreRoll(activeBindings)

            // Start silent so the engine can publish gain 1 and fade the new
            // speaker in over the render core's gain ramp.
            try await output.activate(
                activeOutput,
                bindings: activeBindings,
                initialGain: 0
            )
        } catch {
            // Restore every capture snapshot that may have seen a joining
            // binding, then wait until its callback has left the newer snapshot
            // before retiring that binding. If restore/acknowledgement fails,
            // keep that binding allocated: retaining memory on this exceptional
            // path is safer than freeing an address a live callback may use.
            var capturesSafeToRetire: Set<UUID> = []
            for activeCapture in orderedCaptures.reversed() {
                guard let rollback = rollbackTargetsByCaptureToken[activeCapture.token] else {
                    continue
                }
                do {
                    let publication = try await capture.publishBindings(
                        rollback.targets,
                        for: rollback.capture
                    )
                    try await capture.acknowledge(publication)
                    capturesSafeToRetire.insert(activeCapture.token)
                } catch {
                    // Keep all new bindings for this capture in the backend.
                }
            }

            for active in activeBindings.reversed() {
                if let assignment = assignments.first(where: {
                    $0.binding.token == active.token
                }),
                   rollbackTargetsByCaptureToken[assignment.capture.token] != nil,
                   !capturesSafeToRetire.contains(assignment.capture.token) {
                    continue
                }
                await binding.teardown(active)
            }
            await output.stop(activeOutput)
            throw error
        }

        return PanoramaMacRouteResources(
            outputs: resources.outputs + [activeOutput],
            captures: resources.captures,
            bindings: resources.bindings + assignments
        )
    }

    /// Removes one unhealthy local endpoint without touching the remaining
    /// captures or outputs. Publication moves every capture fan-out away from
    /// the endpoint before its AUHAL claim and binding memory are retired.
    /// A caller may therefore keep the last healthy endpoint audible in the
    /// documented degraded state.
    func isolate(
        endpointUID: String,
        from resources: PanoramaMacRouteResources,
        retainingAdditionalTargetsByCapture: [UUID: [RouteBindingTarget]] = [:]
    ) async throws -> PanoramaMacRouteResources {
        let removedOutputs = resources.outputs.filter { $0.deviceUID == endpointUID }
        guard !removedOutputs.isEmpty else {
            throw PanoramaMacTopologyError.endpointNotActive(uid: endpointUID)
        }
        let remainingOutputs = resources.outputs.filter { $0.deviceUID != endpointUID }
        let retainsRemoteBranch = resources.captures.allSatisfy {
            !(retainingAdditionalTargetsByCapture[$0.token] ?? []).isEmpty
        }
        guard !remainingOutputs.isEmpty || retainsRemoteBranch else {
            throw PanoramaMacTopologyError.cannotIsolateLastEndpoint
        }
        let removedTokens = Set(removedOutputs.map(\.token))
        let remainingBindings = resources.bindings.filter {
            !removedTokens.contains($0.output.token)
        }
        let removedBindings = resources.bindings.filter {
            removedTokens.contains($0.output.token)
        }

        for activeCapture in resources.captures {
            let targets = remainingBindings
                .filter { $0.capture.token == activeCapture.token }
                .map { RouteBindingTarget($0.binding) }
                + (retainingAdditionalTargetsByCapture[activeCapture.token] ?? [])
            guard !targets.isEmpty else {
                throw PanoramaMacTopologyError.lifecycleFailed
            }
            let publication = try await capture.publishBindings(targets, for: activeCapture)
            try await capture.acknowledge(publication)
        }

        for outputToStop in removedOutputs.reversed() {
            await output.stop(outputToStop)
        }
        for bindingToRetire in removedBindings.reversed() {
            await binding.teardown(bindingToRetire.binding)
        }
        return PanoramaMacRouteResources(
            outputs: remainingOutputs,
            captures: resources.captures,
            bindings: remainingBindings
        )
    }

    private func validate(_ request: PanoramaMacRouteRequest) throws {
        let minimumOutputs = request.allowsSingleLocalOutput ? 1 : 2
        // 2026-08-14 极限测试验证：本机输出最多 4 路（3 蓝牙 + 本机扬声器）可稳定播放。
        guard (minimumOutputs ... PanoramaTopologyLimits.maximumMacEndpointCount)
            .contains(request.outputs.count) else {
            throw PanoramaMacTopologyError.outputCountOutOfRange(actual: request.outputs.count)
        }
        guard !request.groups.isEmpty else {
            throw PanoramaMacTopologyError.noCaptureGroups
        }
        guard request.profile.isValid,
              request.outputs.allSatisfy({ request.profile(for: $0).isValid }) else {
            throw PanoramaMacTopologyError.invalidBufferProfile
        }
        var seenUIDs = Set<String>()
        for output in request.outputs {
            guard seenUIDs.insert(output.uid).inserted else {
                throw PanoramaMacTopologyError.duplicateOutput(uid: output.uid)
            }
            // Discovery can prove format viability, but only the real output
            // backend can prove that AUHAL IO starts. Accept the production
            // snapshot here and let prepare/start propagate the exact failure.
            guard output.readiness.isPreflightReady else {
                throw PanoramaMacTopologyError.outputNotReady(uid: output.uid)
            }
        }
    }

    private static func order(_ lhs: AudioProcessGroup, _ rhs: AudioProcessGroup) -> Bool {
        if lhs.instanceID.ownerPID != rhs.instanceID.ownerPID {
            return lhs.instanceID.ownerPID < rhs.instanceID.ownerPID
        }
        return lhs.instanceID.launchGeneration < rhs.instanceID.launchGeneration
    }

    private func device(
        for activeOutput: ActiveOutput,
        in outputs: [OutputDeviceDescriptor]
    ) -> OutputDeviceDescriptor {
        // `activate` preserves the prepared device UID, which was validated
        // as unique before any resource allocation.
        outputs.first { $0.uid == activeOutput.deviceUID }!
    }
}
