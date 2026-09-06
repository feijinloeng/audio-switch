enum DisplayableApp: Identifiable {
    case active(AudioApp)
    case pinnedInactive(PinnedAppInfo)

    var id: String {
        switch self {
        case .active(let app): app.persistenceIdentifier
        case .pinnedInactive(let info): info.persistenceIdentifier
        }
    }

    var displayName: String {
        switch self {
        case .active(let app): app.name
        case .pinnedInactive(let info): info.displayName
        }
    }
}

struct PinnedAppInfo: Codable, Equatable, Sendable {
    let persistenceIdentifier: String
    let displayName: String
    let bundleID: String?
}
