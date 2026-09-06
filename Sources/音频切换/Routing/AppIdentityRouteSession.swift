import AudioToolbox
import Foundation

/// A process-local identity. Its PID and generation never enter persistence.
struct AppInstanceID: Hashable, Sendable {
    let app: AppIdentity
    let ownerPID: pid_t
    let launchGeneration: UInt64
}

struct RequestContext: Equatable, Sendable {
    let requestID: UUID
    let appIdentity: AppIdentity
    let requestedRoute: DesiredRoute
    let requestedSettingsRevision: UInt64
}

struct AuthorizationContext: Equatable, Sendable {
    let request: RequestContext
    let priorCommitted: CommittedRouteSnapshot?
}

struct NativeRequestContext: Equatable, Sendable {
    let request: RequestContext
    let defaultSelection: DefaultOutputSelection
    let priorCommitted: CommittedRouteSnapshot?
}

/// Desired state is shared by an app identity; effective routes remain per
/// instance and therefore cannot accidentally be persisted as a single UID.
struct CommittedRouteSnapshot: Equatable, Sendable {
    let desired: DesiredRoute
    let settingsRevision: UInt64
    let effectiveByInstance: [AppInstanceID: EffectiveRoute]
    let defaultSelection: DefaultOutputSelection?
}

enum RouteSessionState: Equatable, Sendable {
    case idle(committed: CommittedRouteSnapshot?)
    case authorizing(AuthorizationContext)
    case preflighting(AuthorizationContext)
    case preparingNative(NativeRequestContext)
    case active(CommittedRouteSnapshot)
    case failed(RouteFailure)
}

enum RouteSessionPhase: Equatable, Sendable {
    case idle
    case authorizing
    case preflighting
    case preparingNative
    case active
    case failed
}

extension RouteSessionState {
    var requestID: UUID? {
        switch self {
        case let .authorizing(context), let .preflighting(context): return context.request.requestID
        case let .preparingNative(context): return context.request.requestID
        case .idle, .active, .failed: return nil
        }
    }

    var phase: RouteSessionPhase {
        switch self {
        case .idle: return .idle
        case .authorizing: return .authorizing
        case .preflighting: return .preflighting
        case .preparingNative: return .preparingNative
        case .active: return .active
        case .failed: return .failed
        }
    }

    var committedSnapshot: CommittedRouteSnapshot? {
        switch self {
        case let .idle(committed): return committed
        case let .active(committed): return committed
        case .authorizing, .preflighting, .preparingNative, .failed: return nil
        }
    }

    var failure: RouteFailure? {
        guard case let .failed(failure) = self else { return nil }
        return failure
    }
}

/// Pure state holder used by the future coordinator. It does not touch Core
/// Audio: deciding native vs managed happens before any permission request.
final class AppIdentityRouteSession {
    let identity: AppIdentity
    private(set) var state: RouteSessionState
    private var settingsRevision: UInt64

    init(identity: AppIdentity, committed: CommittedRouteSnapshot? = nil) {
        self.identity = identity
        state = .idle(committed: committed)
        settingsRevision = committed?.settingsRevision ?? 0
    }

    @discardableResult
    func begin(
        desired: DesiredRoute,
        settings: PerAppDSPSettings,
        defaultSelection: DefaultOutputSelection
    ) -> RouteSessionState {
        settingsRevision &+= 1
        let prior = committedSnapshot
        let request = RequestContext(
            requestID: UUID(),
            appIdentity: identity,
            requestedRoute: desired,
            requestedSettingsRevision: settingsRevision
        )

        switch operation(desired: desired, settings: settings, defaultSelection: defaultSelection) {
        case .nativePassThrough(let selection):
            state = .preparingNative(
                NativeRequestContext(request: request, defaultSelection: selection, priorCommitted: prior)
            )
        case .managed:
            state = .authorizing(AuthorizationContext(request: request, priorCommitted: prior))
        }
        return state
    }

    /// A rejected managed request restores the precise committed snapshot rather
    /// than drawing the newly requested device as if it were active.
    @discardableResult
    func authorizationDenied() -> RouteSessionState {
        guard case let .authorizing(context) = state else { return state }
        if let prior = context.priorCommitted {
            state = .active(prior)
        } else {
            state = .failed(.capturePermissionDenied)
        }
        return state
    }

    @discardableResult
    func authorizationGranted() -> RouteSessionState {
        guard case let .authorizing(context) = state else { return state }
        state = .preflighting(context)
        return state
    }

    @discardableResult
    func commit(
        effectiveByInstance: [AppInstanceID: EffectiveRoute],
        defaultSelection: DefaultOutputSelection?
    ) -> RouteSessionState {
        let request: RequestContext
        switch state {
        case let .preflighting(context): request = context.request
        case let .preparingNative(context): request = context.request
        case .idle, .authorizing, .active, .failed: return state
        }
        let committed = CommittedRouteSnapshot(
            desired: request.requestedRoute,
            settingsRevision: request.requestedSettingsRevision,
            effectiveByInstance: effectiveByInstance,
            defaultSelection: defaultSelection
        )
        state = .active(committed)
        return state
    }

    @discardableResult
    func fail(_ failure: RouteFailure) -> RouteSessionState {
        state = .failed(failure)
        return state
    }

    /// Recovery changes only the actual binding. The desired route and its
    /// persisted identity remain intact so a later reconnect can retry it.
    @discardableResult
    func recover(
        desired: DesiredRoute,
        effectiveByInstance: [AppInstanceID: EffectiveRoute],
        defaultSelection: DefaultOutputSelection?
    ) -> RouteSessionState {
        state = .active(
            CommittedRouteSnapshot(
                desired: desired,
                settingsRevision: settingsRevision,
                effectiveByInstance: effectiveByInstance,
                defaultSelection: defaultSelection
            )
        )
        return state
    }

    var committedSnapshot: CommittedRouteSnapshot? {
        switch state {
        case let .idle(committed): return committed
        case let .active(committed): return committed
        case .authorizing, .preflighting, .preparingNative, .failed: return nil
        }
    }
}
