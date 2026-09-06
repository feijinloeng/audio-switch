import Foundation

enum OutputDeviceReadiness: Int, Equatable, Sendable {
    case discovered
    case present
    case alive
    case outputStreamAvailable
    case formatReady
    case ioReady
    case unavailable

    var isPreflightReady: Bool { self == .formatReady || self == .ioReady }
    var isCommitReady: Bool { self == .ioReady }
}

enum OutputDeviceTransport: Equatable, Sendable {
    case builtIn
    case bluetooth
    case other
}

/// HAL-independent output capability snapshot. Hardware IDs and stream ASBDs
/// are added by the system adapter in stage 2; this type already keeps their
/// lifetime separate from the stable Core Audio UID.
struct OutputDeviceDescriptor: Equatable, Sendable {
    let uid: String
    let name: String
    let readiness: OutputDeviceReadiness
    let nominalSampleRate: Double
    let channelCount: Int
    let transport: OutputDeviceTransport
}

/// Publishes a coherent device/default snapshot. A later `CoreAudioHAL`
/// adapter is the only producer; clients never compose a UID and generations
/// from independent HAL reads.
final class OutputDeviceRegistry {
    private var devicesByUID: [String: OutputDeviceDescriptor] = [:]
    private var generationByUID: [String: UInt64] = [:]
    private var defaultSelection = DefaultOutputSelection(deviceUID: nil, generation: 0)

    func replace(
        devices: [OutputDeviceDescriptor],
        defaultDeviceUID: String?
    ) -> DefaultOutputSelection {
        // 设备 UID 来自系统发现，防御重复 UID 避免字典断言崩溃。
        let incoming = Dictionary(
            devices.map { ($0.uid, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for (uid, descriptor) in incoming where devicesByUID[uid] != descriptor {
            generationByUID[uid] = (generationByUID[uid] ?? 0) &+ 1
        }
        devicesByUID = incoming

        let deviceGeneration = defaultDeviceUID.flatMap { generationByUID[$0] }
        if defaultSelection.deviceUID != defaultDeviceUID
            || defaultSelection.deviceGeneration != deviceGeneration {
            defaultSelection = DefaultOutputSelection(
                deviceUID: defaultDeviceUID,
                generation: defaultSelection.defaultSelectionGeneration &+ 1,
                deviceGeneration: deviceGeneration
            )
        }
        return defaultSelection
    }

    func descriptor(for uid: String) -> OutputDeviceDescriptor? { devicesByUID[uid] }
    func currentDefaultSelection() -> DefaultOutputSelection { defaultSelection }
}
