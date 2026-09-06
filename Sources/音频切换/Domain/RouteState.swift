import Foundation

struct PerAppDSPSettings: Equatable, Sendable {
    let volume: Float
    let muted: Bool

    init(volume: Float, muted: Bool) {
        self.volume = volume.isFinite ? min(max(volume, 0), 1) : 1
        self.muted = muted
    }
}

func requiresManagedPath(_ settings: PerAppDSPSettings) -> Bool {
    settings.muted
        || abs(settings.volume - 1) > 0.0001
}

struct DefaultOutputSelection: Equatable, Sendable {
    let deviceUID: String?
    let defaultSelectionGeneration: UInt64
    let deviceGeneration: UInt64?

    init(deviceUID: String?, generation: UInt64, deviceGeneration: UInt64? = nil) {
        self.deviceUID = deviceUID
        defaultSelectionGeneration = generation
        self.deviceGeneration = deviceGeneration
    }

    /// Compatibility spelling for existing stage-1 callers; new code must use
    /// `defaultSelectionGeneration` to make the snapshot scope explicit.
    var generation: UInt64 { defaultSelectionGeneration }
}

enum RouteOperation: Equatable, Sendable {
    case nativePassThrough(DefaultOutputSelection)
    case managed(DesiredRoute)
}

func operation(
    desired: DesiredRoute,
    settings: PerAppDSPSettings,
    defaultSelection: DefaultOutputSelection
) -> RouteOperation {
    if desired == .followSystemDefault, !requiresManagedPath(settings) {
        return .nativePassThrough(defaultSelection)
    }
    return .managed(desired)
}

enum RouteFailure: Equatable, Sendable {
    case captureControlLost
    case capturePermissionDenied
    case deviceUnavailable(uid: String)
    case deviceNotReady(uid: String)
    case audioServiceRestarted
    case routePreparationFailed
}

enum OutputBinding: Equatable, Sendable {
    case nativeDefault(deviceUID: String?)
    case managed(deviceUID: String)
    case none
}

enum RouteHealth: Equatable, Sendable {
    case active
    case recovering(reason: RouteFailure)
    case degraded(reason: RouteFailure)
    case failed(reason: RouteFailure)
}

struct EffectiveRoute: Equatable, Sendable {
    let binding: OutputBinding
    let health: RouteHealth
}
