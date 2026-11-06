import Foundation

/// A stable identity for preferences shared by every running instance of an app.
///
/// Only bundle identifiers are stable enough to become persistence keys. Display
/// names and PIDs remain runtime or presentation data and are deliberately
/// excluded from this value.
struct AppIdentity: Hashable, Codable, Sendable {
    let persistenceKey: String
    let bundleID: String?

    init?(bundleID: String?) {
        guard let bundleID = bundleID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !bundleID.isEmpty else {
            return nil
        }
        self.persistenceKey = bundleID
        self.bundleID = bundleID
    }
}
