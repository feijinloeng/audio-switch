import Foundation

/// Input accepted by the managed-backend transaction boundary. It deliberately
/// contains only stable desired state and a request token; Core Audio object
/// identifiers stay inside the backend's short-lived prepared resources.
struct ManagedRouteRequest: Sendable {
    let identity: AppIdentity
    let requestID: UUID
    let desired: DesiredRoute
}

/// Opaque, backend-owned prepared state. The control plane can use it only to
/// commit or roll back the same request.
struct PreparedManagedRoute: Sendable {
    let requestID: UUID
    let opaqueID: UUID
}

enum RouteTransactionBackendError: Error, Sendable {
    case prepareFailed
    case commitFailed
}

protocol RouteTransitionBackend: Sendable {
    func prepare(_ request: ManagedRouteRequest) async throws -> PreparedManagedRoute
    func commit(_ prepared: PreparedManagedRoute) async throws
    func rollback(_ prepared: PreparedManagedRoute) async
}

enum RouteTransactionOutcome: Equatable, Sendable {
    case committed
    case cancelled
    case failed(RouteFailure)
}

/// Serializes the control-plane ownership of request IDs while deliberately
/// allowing backend preparation to suspend. A later request invalidates an
/// earlier one, and every prepared-but-uncommitted route is rolled back.
actor RouteTransactionExecutor {
    private let backend: any RouteTransitionBackend
    private var latestRequestIDByIdentity: [AppIdentity: UUID] = [:]

    init(backend: any RouteTransitionBackend) {
        self.backend = backend
    }

    func execute(
        identity: AppIdentity,
        requestID: UUID,
        desired: DesiredRoute
    ) async -> RouteTransactionOutcome {
        latestRequestIDByIdentity[identity] = requestID
        let request = ManagedRouteRequest(identity: identity, requestID: requestID, desired: desired)

        let prepared: PreparedManagedRoute
        do {
            prepared = try await backend.prepare(request)
        } catch {
            return isLatest(requestID, for: identity) ? .failed(.routePreparationFailed) : .cancelled
        }

        guard isLatest(requestID, for: identity) else {
            await backend.rollback(prepared)
            return .cancelled
        }

        do {
            try await backend.commit(prepared)
        } catch {
            await backend.rollback(prepared)
            return isLatest(requestID, for: identity) ? .failed(.routePreparationFailed) : .cancelled
        }

        guard isLatest(requestID, for: identity) else {
            await backend.rollback(prepared)
            return .cancelled
        }
        return .committed
    }

    private func isLatest(_ requestID: UUID, for identity: AppIdentity) -> Bool {
        latestRequestIDByIdentity[identity] == requestID
    }
}
