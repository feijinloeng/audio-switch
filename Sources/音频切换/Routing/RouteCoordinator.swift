import Foundation

/// The sole control-plane state machine for route requests. It deliberately
/// has no Core Audio resource ownership: production prepare/commit work will
/// arrive through the approved topology-P backend in a later phase.
actor RouteCoordinator {
    private struct RequestInput: Sendable {
        let desired: DesiredRoute
        let settings: PerAppDSPSettings
        let defaultSelection: DefaultOutputSelection
    }

    private var sessions: [AppIdentity: AppIdentityRouteSession] = [:]
    private var latestInputs: [AppIdentity: RequestInput] = [:]
    private var halEpoch: UInt64

    init(initialHALEpoch: UInt64 = 0) {
        halEpoch = initialHALEpoch
    }

    func request(
        identity: AppIdentity,
        desired: DesiredRoute,
        settings: PerAppDSPSettings,
        defaultSelection: DefaultOutputSelection
    ) -> RouteSessionState {
        let session = session(for: identity)
        latestInputs[identity] = RequestInput(
            desired: desired,
            settings: settings,
            defaultSelection: defaultSelection
        )
        return session.begin(
            desired: desired,
            settings: settings,
            defaultSelection: defaultSelection
        )
    }

    func resolveAuthorization(
        identity: AppIdentity,
        requestID: UUID,
        allowed: Bool
    ) -> RouteSessionState {
        let session = session(for: identity)
        guard session.state.requestID == requestID else { return session.state }
        return allowed ? session.authorizationGranted() : session.authorizationDenied()
    }

    /// Returns false for stale async completions or for a completion that has
    /// not reached the expected control-plane phase.
    func commit(
        identity: AppIdentity,
        requestID: UUID,
        halEpoch: UInt64,
        defaultSelection: DefaultOutputSelection?,
        effectiveByInstance: [AppInstanceID: EffectiveRoute]
    ) -> Bool {
        let session = session(for: identity)
        guard halEpoch == self.halEpoch,
              session.state.requestID == requestID,
              session.state.phase == .preflighting || session.state.phase == .preparingNative else {
            return false
        }
        _ = session.commit(
            effectiveByInstance: effectiveByInstance,
            defaultSelection: defaultSelection
        )
        return true
    }

    func state(for identity: AppIdentity) -> RouteSessionState {
        session(for: identity).state
    }

    func handleServiceRestart(newHALEpoch: UInt64) {
        guard newHALEpoch > halEpoch else { return }
        halEpoch = newHALEpoch
        for (identity, session) in sessions {
            guard let input = latestInputs[identity] else {
                _ = session.fail(.audioServiceRestarted)
                continue
            }
            switch operation(
                desired: input.desired,
                settings: input.settings,
                defaultSelection: input.defaultSelection
            ) {
            case .nativePassThrough:
                _ = session.begin(
                    desired: input.desired,
                    settings: input.settings,
                    defaultSelection: input.defaultSelection
                )
            case .managed:
                _ = session.fail(.captureControlLost)
            }
        }
    }

    /// A disconnected explicit device never erases the user's desired UID.
    /// Existing managed bindings may move to a known default only when there
    /// is an already-committed route to preserve; otherwise the session stays
    /// failed rather than claiming unmanaged playback is equivalent.
    func handleDeviceDisconnected(uid: String, fallback: DefaultOutputSelection) {
        for (identity, input) in latestInputs {
            guard case let .device(desiredUID) = input.desired, desiredUID == uid else { continue }
            let session = session(for: identity)
            guard let fallbackUID = fallback.deviceUID,
                  let committed = session.committedSnapshot,
                  !committed.effectiveByInstance.isEmpty else {
                _ = session.fail(.deviceUnavailable(uid: uid))
                continue
            }
            let recovered: [AppInstanceID: EffectiveRoute] = Dictionary(
                uniqueKeysWithValues: committed.effectiveByInstance.keys.map { instance in
                    (
                        instance,
                        EffectiveRoute(
                            binding: .managed(deviceUID: fallbackUID),
                            health: .degraded(reason: .deviceUnavailable(uid: uid))
                        )
                    )
                }
            )
            _ = session.recover(
                desired: input.desired,
                effectiveByInstance: recovered,
                defaultSelection: fallback
            )
        }
    }

    private func session(for identity: AppIdentity) -> AppIdentityRouteSession {
        if let existing = sessions[identity] { return existing }
        let created = AppIdentityRouteSession(identity: identity)
        sessions[identity] = created
        return created
    }
}
