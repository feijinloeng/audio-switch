import Foundation

enum DesiredRoute: Equatable, Sendable {
    case followSystemDefault
    case device(uid: String)
    /// A virtual output backed by the separately versioned panorama group.
    /// It is persisted before the multi-endpoint backend is asked to activate it.
    case panoramaGroup
}

/// The sole JSON wire format for a desired route. `DesiredRoute` intentionally
/// does not conform to Codable, so its associated value representation cannot
/// become an accidental on-disk contract.
struct RoutePreferenceRecord: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case followSystemDefault
        case device
        case panoramaGroup
    }

    let kind: Kind
    let deviceUID: String?

    init(desiredRoute: DesiredRoute) {
        switch desiredRoute {
        case .followSystemDefault:
            kind = .followSystemDefault
            deviceUID = nil
        case let .device(uid):
            kind = .device
            deviceUID = uid.trimmingCharacters(in: .whitespacesAndNewlines)
        case .panoramaGroup:
            kind = .panoramaGroup
            deviceUID = nil
        }
    }

    func validatedDesiredRoute() -> DesiredRoute? {
        switch kind {
        case .followSystemDefault:
            return deviceUID == nil ? .followSystemDefault : nil
        case .device:
            guard let uid = deviceUID?.trimmingCharacters(in: .whitespacesAndNewlines), !uid.isEmpty else {
                return nil
            }
            return .device(uid: uid)
        case .panoramaGroup:
            return deviceUID == nil ? .panoramaGroup : nil
        }
    }
}
