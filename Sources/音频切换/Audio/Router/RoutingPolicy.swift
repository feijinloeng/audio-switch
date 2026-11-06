import AudioToolbox
import Foundation

enum RoutingPolicy {
    static let maximumRouteAttempts = 3

    static func shouldCommitRoute(tapSwitchResult: Bool?) -> Bool {
        tapSwitchResult == true
    }

    static func shouldActivateTap(hasExplicitRoute: Bool, hasExistingTap: Bool) -> Bool {
        hasExplicitRoute || hasExistingTap
    }

    static func needsTapRebuild(
        captured: [AudioObjectID],
        incoming: [AudioObjectID]
    ) -> Bool {
        Set(captured) != Set(incoming)
    }

    static func fallbackDeviceUID(
        disconnectedUID: String,
        systemDefaultUID: String,
        availableUIDs: Set<String>
    ) -> String? {
        guard systemDefaultUID != disconnectedUID,
              availableUIDs.contains(systemDefaultUID) else { return nil }
        return systemDefaultUID
    }

    static func effectiveDeviceUID(configuredUID: String?, systemDefaultUID: String) -> String {
        configuredUID ?? systemDefaultUID
    }

    static func shouldRetryRoute(
        completedAttempts: Int,
        permissionAuthorized: Bool,
        appIsActive: Bool,
        deviceIsAvailable: Bool
    ) -> Bool {
        completedAttempts < maximumRouteAttempts
            && permissionAuthorized
            && appIsActive
            && deviceIsAvailable
    }

}
