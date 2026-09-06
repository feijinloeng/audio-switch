import Darwin
import Foundation

/// Public workspace facts supplied by the AppKit adapter. This deliberately
/// contains no icon, display name, or mutable Core Audio handle.
struct DisplayableApplicationFact: Equatable, Sendable {
    let pid: pid_t
    let bundleID: String?
    let isDisplayableGUI: Bool
    /// An auxiliary process that AppKit can name and icon, but which is not a
    /// normal `.app` and therefore cannot be reached through a parent PID.
    let isDirectAudioOwner: Bool

    init(
        pid: pid_t,
        bundleID: String?,
        isDisplayableGUI: Bool,
        isDirectAudioOwner: Bool = false
    ) {
        self.pid = pid
        self.bundleID = bundleID
        self.isDisplayableGUI = isDisplayableGUI
        self.isDirectAudioOwner = isDirectAudioOwner
    }
}

struct ResolvedProcessOwner: Equatable, Sendable {
    let processPID: pid_t
    let instanceID: AppInstanceID
}

/// A Core Audio output process is not necessarily user media. Developer tools
/// can briefly own an output stream for previews, alerts, or a debug target;
/// routing such a process through a muted Process Tap can disrupt the actual
/// player. Keep those tools out of the controllable-media inventory.
enum AudioAppEligibility {
    private static let excludedBundleIDs: Set<String> = [
        "com.apple.dt.Xcode",
        "com.mankeipun.yinpinqiehuan"
    ]

    static func isRoutable(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return !excludedBundleIDs.contains(bundleID)
    }
}

/// Resolves helper processes through a bounded, public parent-PID chain.
/// Processes without a verifiable displayable application remain unresolved so
/// they cannot be accidentally merged or persisted under another app.
final class ProcessOwnerResolver {
    private struct InstanceRecord {
        let identity: AppIdentity
        let launchGeneration: UInt64
    }

    private var instancesByOwnerPID: [pid_t: InstanceRecord] = [:]
    private var nextLaunchGeneration: UInt64 = 0

    func resolve(
        _ process: HALAudioProcessDescriptor,
        applicationsByPID: [pid_t: DisplayableApplicationFact],
        parentPID: (pid_t) -> pid_t?
    ) -> ResolvedProcessOwner? {
        var currentPID = process.pid
        var visited = Set<pid_t>()
        var directAudioOwner: DisplayableApplicationFact?

        for _ in 0..<10 {
            guard visited.insert(currentPID).inserted else { return nil }
            if let application = applicationsByPID[currentPID] {
                if application.isDisplayableGUI,
                   let identity = AppIdentity(bundleID: application.bundleID) {
                    return ResolvedProcessOwner(
                        processPID: process.pid,
                        instanceID: instance(for: application.pid, identity: identity)
                    )
                }
                if currentPID == process.pid, application.isDirectAudioOwner {
                    directAudioOwner = application
                }
            }
            guard let nextPID = parentPID(currentPID), nextPID > 1, nextPID != currentPID else {
                break
            }
            currentPID = nextPID
        }
        guard let directAudioOwner,
              let identity = AppIdentity(bundleID: directAudioOwner.bundleID) else { return nil }
        return ResolvedProcessOwner(
            processPID: process.pid,
            instanceID: instance(for: directAudioOwner.pid, identity: identity)
        )
    }

    func retainOnlyOwners(_ activeOwnerPIDs: Set<pid_t>) {
        instancesByOwnerPID = instancesByOwnerPID.filter { activeOwnerPIDs.contains($0.key) }
    }

    private func instance(for ownerPID: pid_t, identity: AppIdentity) -> AppInstanceID {
        if let existing = instancesByOwnerPID[ownerPID], existing.identity == identity {
            return AppInstanceID(
                app: identity,
                ownerPID: ownerPID,
                launchGeneration: existing.launchGeneration
            )
        }
        nextLaunchGeneration &+= 1
        let record = InstanceRecord(identity: identity, launchGeneration: nextLaunchGeneration)
        instancesByOwnerPID[ownerPID] = record
        return AppInstanceID(
            app: identity,
            ownerPID: ownerPID,
            launchGeneration: record.launchGeneration
        )
    }
}
