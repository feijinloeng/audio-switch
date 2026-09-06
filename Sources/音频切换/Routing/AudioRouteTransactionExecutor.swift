import Foundation
import OSLog

enum AudioRouteTransactionOutcome: Equatable, Sendable {
    case committed(deviceUID: String)
    case cancelled
    case failed(RouteFailure)
}

struct RouteTransactionTiming: Equatable, Sendable {
    let deviceUID: String
    let prepareDuration: Duration
    let commitDuration: Duration
    let priorTeardownDuration: Duration
}

/// Owns the handoff boundary between two active routes. Crucially, the prior
/// route remains registry-owned while the candidate is only prepared; it is
/// released after the new route has atomically committed, never before.
actor AudioRouteTransactionExecutor {
#if DEBUG
    private static let routeTimingLogger = Logger(
        subsystem: "com.mankeipun.yinpinqiehuan",
        category: "route-diagnostics"
    )
#endif
    private struct PendingTransaction {
        let requestID: UUID
        let fingerprint: BackendRouteFingerprint
        var waiters: [CheckedContinuation<AudioRouteTransactionOutcome, Never>] = []
    }

    private let backend: any AudioRoutingBackend
    private var activeByIdentity: [AppIdentity: ActiveRouteResources] = [:]
    private var activeFingerprintsByIdentity: [AppIdentity: BackendRouteFingerprint] = [:]
    private var latestRequestIDByIdentity: [AppIdentity: UUID] = [:]
    private var pendingByIdentity: [AppIdentity: PendingTransaction] = [:]
    private var timingByIdentity: [AppIdentity: RouteTransactionTiming] = [:]
    private var identitiesBeingTornDown: Set<AppIdentity> = []
    private var isInvalidatingAllRoutes = false
    private var identityTeardownWaitersByIdentity:
        [AppIdentity: [CheckedContinuation<Void, Never>]] = [:]
    private var allIdentityTeardownsWaiters: [CheckedContinuation<Void, Never>] = []
    private var invalidationWaiters: [CheckedContinuation<Void, Never>] = []

    init(backend: any AudioRoutingBackend) {
        self.backend = backend
    }

    func execute(_ request: BackendRouteRequest) async -> AudioRouteTransactionOutcome {
        guard !isInvalidatingAllRoutes,
              !identitiesBeingTornDown.contains(request.identity) else {
            return .cancelled
        }
        let fingerprint = request.fingerprint
        if let pending = pendingByIdentity[request.identity] {
            if pending.fingerprint == fingerprint {
                // A repeated click on the in-flight target is the newest user
                // intent even if a different request is already queued.
                latestRequestIDByIdentity[request.identity] = pending.requestID
                return await waitForPendingTransaction(identity: request.identity, requestID: pending.requestID)
            }

            // Publishing newer intent cancels the current transaction at its
            // next safe boundary, but the new transaction must not borrow the
            // same active route until the prior lifecycle has fully exited.
            latestRequestIDByIdentity[request.identity] = request.requestID
            _ = await waitForPendingTransaction(
                identity: request.identity,
                requestID: pending.requestID
            )
            guard isLatest(request) else { return .cancelled }
        } else {
            latestRequestIDByIdentity[request.identity] = request.requestID
        }

        if activeFingerprintsByIdentity[request.identity] == fingerprint,
           let active = activeByIdentity[request.identity] {
            // A same-route request is still the latest user intent, so it must
            // supersede a concurrently preparing different target. Returning
            // here avoids every real-time lifecycle operation.
            return .committed(deviceUID: active.output.deviceUID)
        }

        pendingByIdentity[request.identity] = PendingTransaction(
            requestID: request.requestID,
            fingerprint: fingerprint
        )
        let outcome = await executeNewTransaction(request, fingerprint: fingerprint)
        resolvePendingTransaction(identity: request.identity, requestID: request.requestID, outcome: outcome)
        return outcome
    }

    private func executeNewTransaction(
        _ request: BackendRouteRequest,
        fingerprint: BackendRouteFingerprint
    ) async -> AudioRouteTransactionOutcome {
        let clock = ContinuousClock()
        let handoffSource = activeHandoffSource(
            for: request,
            candidateFingerprint: fingerprint
        )
        let prepared: PreparedRouteResources
        let prepareStartedAt = clock.now
        do {
            if let handoffSource {
                prepared = try await backend.prepareHandoff(
                    from: handoffSource,
                    request: request
                )
            } else {
                prepared = try await backend.prepare(request)
            }
        } catch {
            return isLatest(request) ? .failed(.routePreparationFailed) : .cancelled
        }
        let prepareDuration = prepareStartedAt.duration(to: clock.now)

        guard isLatest(request) else {
            await backend.rollback(prepared)
            return .cancelled
        }

        let active: ActiveRouteResources
        let commitStartedAt = clock.now
        do {
            active = try await backend.commit(prepared, requestID: request.requestID)
        } catch {
            await backend.rollback(prepared)
            return isLatest(request) ? .failed(.routePreparationFailed) : .cancelled
        }
        let commitDuration = commitStartedAt.duration(to: clock.now)

        guard isLatest(request) else {
            if handoffSource != nil {
                await backend.rollback(prepared)
            } else {
                await backend.teardown(active)
            }
            return .cancelled
        }

        var priorTeardownDuration = Duration.zero
        if let handoffSource {
            let priorTeardownStartedAt = clock.now
            do {
                try await backend.finalizeHandoff(old: handoffSource, new: active)
            } catch {
                return isLatest(request) ? .failed(.routePreparationFailed) : .cancelled
            }
            priorTeardownDuration = priorTeardownStartedAt.duration(to: clock.now)
            activeByIdentity[request.identity] = active
            activeFingerprintsByIdentity[request.identity] = fingerprint
        } else {
            let prior = activeByIdentity.updateValue(active, forKey: request.identity)
            activeFingerprintsByIdentity[request.identity] = fingerprint
            if let prior {
                let priorTeardownStartedAt = clock.now
                await backend.teardown(prior)
                priorTeardownDuration = priorTeardownStartedAt.duration(to: clock.now)
            }
        }
        // A newer commit may have completed while an older route was being
        // retired. Do not let the older transaction overwrite its timing.
        guard activeByIdentity[request.identity]?.output.token == active.output.token else {
            return .committed(deviceUID: active.output.deviceUID)
        }
        timingByIdentity[request.identity] = RouteTransactionTiming(
            deviceUID: active.output.deviceUID,
            prepareDuration: prepareDuration,
            commitDuration: commitDuration,
            priorTeardownDuration: priorTeardownDuration
        )
#if DEBUG
        Log.info(
            Self.routeTimingLogger,
            "routeTiming device=\(active.output.deviceUID) prepare=\(prepareDuration.formatted()) commit=\(commitDuration.formatted()) priorTeardown=\(priorTeardownDuration.formatted())"
        )
#endif
        return isLatest(request)
            ? .committed(deviceUID: active.output.deviceUID)
            : .cancelled
    }

    private func activeHandoffSource(
        for request: BackendRouteRequest,
        candidateFingerprint: BackendRouteFingerprint
    ) -> ActiveRouteResources? {
        guard let current = activeByIdentity[request.identity],
              let currentFingerprint = activeFingerprintsByIdentity[request.identity],
              currentFingerprint.targetDeviceUID != candidateFingerprint.targetDeviceUID,
              currentFingerprint.identity == candidateFingerprint.identity,
              currentFingerprint.groups == candidateFingerprint.groups,
              currentFingerprint.halEpoch == candidateFingerprint.halEpoch,
              Set(current.captures.map(\.instanceID))
                == Set(request.groups.map(\.instanceID)) else {
            return nil
        }
        return current
    }

    func activeRoute(for identity: AppIdentity) -> ActiveRouteResources? {
        activeByIdentity[identity]
    }

    func latestTiming(for identity: AppIdentity) -> RouteTransactionTiming? {
        timingByIdentity[identity]
    }

    /// Control-plane diagnostic used to prove that a request has entered the
    /// actor before a deliberately paused backend lifecycle operation resumes.
    func latestRequestID(for identity: AppIdentity) -> UUID? {
        latestRequestIDByIdentity[identity]
    }

    func teardown(identity: AppIdentity) async {
        if identitiesBeingTornDown.contains(identity) {
            await waitForIdentityTeardown(identity)
            return
        }
        if isInvalidatingAllRoutes {
            await waitForGlobalInvalidation()
            return
        }
        identitiesBeingTornDown.insert(identity)
        defer { finishIdentityTeardown(identity) }
        latestRequestIDByIdentity.removeValue(forKey: identity)
        if let pending = pendingByIdentity[identity] {
            _ = await waitForPendingTransaction(
                identity: identity,
                requestID: pending.requestID
            )
        }
        timingByIdentity.removeValue(forKey: identity)
        guard let active = activeByIdentity.removeValue(forKey: identity) else { return }
        activeFingerprintsByIdentity.removeValue(forKey: identity)
        await backend.teardown(active)
    }

    /// Service restart or capture-control loss invalidates every HAL handle at
    /// once. Clearing ownership before awaiting teardown prevents a later
    /// route request from treating a stale muted Tap as still active.
    func invalidateAllForCoreAudioServiceRestart() async {
        if isInvalidatingAllRoutes {
            await waitForGlobalInvalidation()
            return
        }
        isInvalidatingAllRoutes = true
        defer { finishGlobalInvalidation() }

        // A per-identity teardown removes its route from the registry before
        // awaiting backend cleanup. Keep global admission closed until those
        // already-owned lifecycle operations have actually returned.
        await waitForAllIdentityTeardowns()

        let identities = Set(activeByIdentity.keys).union(pendingByIdentity.keys)
        for identity in identities {
            latestRequestIDByIdentity.removeValue(forKey: identity)
        }
        for identity in identities {
            if let pending = pendingByIdentity[identity] {
                _ = await waitForPendingTransaction(
                    identity: identity,
                    requestID: pending.requestID
                )
            }
        }
        let activeRoutes = activeByIdentity
        activeByIdentity.removeAll()
        activeFingerprintsByIdentity.removeAll()
        latestRequestIDByIdentity.removeAll()
        timingByIdentity.removeAll()
        for route in activeRoutes.values {
            await backend.teardown(route)
        }
    }

    private func waitForIdentityTeardown(_ identity: AppIdentity) async {
        await withCheckedContinuation { continuation in
            guard identitiesBeingTornDown.contains(identity) else {
                continuation.resume()
                return
            }
            identityTeardownWaitersByIdentity[identity, default: []].append(continuation)
        }
    }

    private func waitForAllIdentityTeardowns() async {
        await withCheckedContinuation { continuation in
            guard !identitiesBeingTornDown.isEmpty else {
                continuation.resume()
                return
            }
            allIdentityTeardownsWaiters.append(continuation)
        }
    }

    private func finishIdentityTeardown(_ identity: AppIdentity) {
        identitiesBeingTornDown.remove(identity)
        let identityWaiters = identityTeardownWaitersByIdentity.removeValue(
            forKey: identity
        ) ?? []
        for waiter in identityWaiters {
            waiter.resume()
        }
        guard identitiesBeingTornDown.isEmpty else { return }
        let allWaiters = allIdentityTeardownsWaiters
        allIdentityTeardownsWaiters.removeAll()
        for waiter in allWaiters {
            waiter.resume()
        }
    }

    private func waitForGlobalInvalidation() async {
        await withCheckedContinuation { continuation in
            guard isInvalidatingAllRoutes else {
                continuation.resume()
                return
            }
            invalidationWaiters.append(continuation)
        }
    }

    private func finishGlobalInvalidation() {
        isInvalidatingAllRoutes = false
        let waiters = invalidationWaiters
        invalidationWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func isLatest(_ request: BackendRouteRequest) -> Bool {
        latestRequestIDByIdentity[request.identity] == request.requestID
    }

    private func waitForPendingTransaction(
        identity: AppIdentity,
        requestID: UUID
    ) async -> AudioRouteTransactionOutcome {
        await withCheckedContinuation { continuation in
            guard var pending = pendingByIdentity[identity], pending.requestID == requestID else {
                continuation.resume(returning: .cancelled)
                return
            }
            pending.waiters.append(continuation)
            pendingByIdentity[identity] = pending
        }
    }

    private func resolvePendingTransaction(
        identity: AppIdentity,
        requestID: UUID,
        outcome: AudioRouteTransactionOutcome
    ) {
        guard let pending = pendingByIdentity[identity], pending.requestID == requestID else { return }
        pendingByIdentity.removeValue(forKey: identity)
        for waiter in pending.waiters {
            waiter.resume(returning: outcome)
        }
    }
}
