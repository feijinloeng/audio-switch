import Foundation

/// Decides which existing managed routes need lifecycle work when Core Audio
/// publishes a new process-object snapshot. Each app identity is isolated so a
/// pause or helper change in one player cannot rebuild another player's route.
enum ManagedRouteReconciliation {
    enum Action: Hashable {
        case rebuild(AppIdentity)
        case teardown(AppIdentity)
    }

    static func actions(
        previous: [AppIdentity: [AudioProcessGroup]],
        current: [AppIdentity: [AudioProcessGroup]]
    ) -> Set<Action> {
        Set(previous.compactMap { identity, priorGroups in
            let currentGroups = current[identity] ?? []
            guard priorGroups != currentGroups else { return nil }
            return currentGroups.isEmpty ? .teardown(identity) : .rebuild(identity)
        })
    }
}
