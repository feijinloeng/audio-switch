import Darwin
import Foundation

struct AudioProcessGroup: Equatable, Sendable {
    let instanceID: AppInstanceID
    let processObjects: Set<ProcessObjectHandle>
    let generation: UInt64
}

/// Pure process grouping for the route coordinator. Owner resolution remains
/// outside this type because it depends on public AppKit/workspace facts; the
/// catalog only tracks mutable HAL handles and invalidates them by epoch.
final class CoreAudioProcessCatalog {
    private var groups: [AppInstanceID: AudioProcessGroup] = [:]
    private var lastServiceEpoch: UInt64?

    /// Production-facing refresh path. The resolver is deliberately injected:
    /// Core Audio discovery never reaches into AppKit or guesses helper
    /// ownership from a bundle-name similarity.
    @discardableResult
    func replace(
        snapshot: HALProcessSnapshot,
        resolver: ProcessOwnerResolver,
        applicationsByPID: [pid_t: DisplayableApplicationFact],
        parentPID: (pid_t) -> pid_t?
    ) -> [AppInstanceID: AudioProcessGroup] {
        var ownersByProcessPID: [pid_t: AppInstanceID] = [:]
        var activeOwnerPIDs = Set<pid_t>()
        for process in snapshot.processes {
            guard let resolved = resolver.resolve(
                process,
                applicationsByPID: applicationsByPID,
                parentPID: parentPID
            ) else { continue }
            ownersByProcessPID[resolved.processPID] = resolved.instanceID
            activeOwnerPIDs.insert(resolved.instanceID.ownerPID)
        }
        resolver.retainOnlyOwners(activeOwnerPIDs)
        return replace(
            processes: snapshot.processes,
            serviceEpoch: snapshot.serviceEpoch,
            ownersByProcessPID: ownersByProcessPID
        )
    }

    @discardableResult
    func replace(
        processes: [HALAudioProcessDescriptor],
        serviceEpoch: UInt64,
        ownersByProcessPID: [pid_t: AppInstanceID]
    ) -> [AppInstanceID: AudioProcessGroup] {
        var incoming: [AppInstanceID: Set<ProcessObjectHandle>] = [:]
        for process in processes where Self.isPlaying(process) {
            guard let owner = ownersByProcessPID[process.pid] else { continue }
            incoming[owner, default: []].insert(process.handle)
        }

        let epochChanged = lastServiceEpoch != nil && lastServiceEpoch != serviceEpoch
        var updated: [AppInstanceID: AudioProcessGroup] = [:]
        for (instanceID, handles) in incoming {
            let previous = groups[instanceID]
            let changed = epochChanged || previous?.processObjects != handles
            let generation = changed
                ? (previous?.generation ?? 0) &+ 1
                : (previous?.generation ?? 1)
            updated[instanceID] = AudioProcessGroup(
                instanceID: instanceID,
                processObjects: handles,
                generation: generation
            )
        }
        groups = updated
        lastServiceEpoch = serviceEpoch
        return updated
    }

    private static func isPlaying(_ process: HALAudioProcessDescriptor) -> Bool {
        process.isRunningOutput ?? process.isRunning ?? true
    }
}
