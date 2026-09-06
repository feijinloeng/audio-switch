import Foundation
import Darwin

struct HALOutputSnapshot: Equatable, Sendable {
    let devices: [OutputDeviceDescriptor]
    let defaultDeviceUID: String?
    let serviceEpoch: UInt64
}

enum CoreAudioHALEvent: Equatable, Sendable {
    case deviceListChanged
    case defaultOutputChanged
    case deviceConfigurationChanged
    case processListChanged
    case serviceRestarted
}

/// Opaque, epoch-scoped reference to a Core Audio process object. It never
/// exposes an `AudioObjectID` to preference, UI, or route-domain code.
struct ProcessObjectHandle: Hashable, Sendable {
    fileprivate let token: UInt64
    let halEpoch: UInt64

    init(token: UInt64 = UInt64.random(in: .min ... .max), halEpoch: UInt64 = 0) {
        self.token = token
        self.halEpoch = halEpoch
    }
}

struct HALAudioProcessDescriptor: Equatable, Sendable {
    let handle: ProcessObjectHandle
    let pid: pid_t
    let bundleID: String?
    let isRunningOutput: Bool?
    let isRunning: Bool?

    init(
        handle: ProcessObjectHandle = ProcessObjectHandle(),
        pid: pid_t,
        bundleID: String?,
        isRunningOutput: Bool?,
        isRunning: Bool?
    ) {
        self.handle = handle
        self.pid = pid
        self.bundleID = bundleID
        self.isRunningOutput = isRunningOutput
        self.isRunning = isRunning
    }
}

struct HALProcessSnapshot: Equatable, Sendable {
    let processes: [HALAudioProcessDescriptor]
    let serviceEpoch: UInt64
}

/// Boundary for the control-plane facts needed by routing. The production
/// implementation is introduced beside the legacy monitors; tests use the
/// fake and therefore require no Core Audio hardware.
protocol CoreAudioHAL: AnyObject, Sendable {
    var serviceEpoch: UInt64 { get }
    func outputSnapshot() -> HALOutputSnapshot
    func processSnapshot() -> HALProcessSnapshot
    func setEventHandler(_ handler: @escaping (CoreAudioHALEvent) -> Void)
    func stopObserving()
}

final class FakeCoreAudioHAL: CoreAudioHAL, @unchecked Sendable {
    private var devices: [OutputDeviceDescriptor]
    private var defaultDeviceUID: String?
    private var processes: [HALAudioProcessDescriptor]
    private var eventHandler: ((CoreAudioHALEvent) -> Void)?
    private(set) var serviceEpoch: UInt64 = 0

    init(
        devices: [OutputDeviceDescriptor] = [],
        defaultDeviceUID: String? = nil,
        processes: [HALAudioProcessDescriptor] = []
    ) {
        self.devices = devices
        self.defaultDeviceUID = defaultDeviceUID
        self.processes = processes
    }

    func outputSnapshot() -> HALOutputSnapshot {
        HALOutputSnapshot(
            devices: devices,
            defaultDeviceUID: defaultDeviceUID,
            serviceEpoch: serviceEpoch
        )
    }

    func processSnapshot() -> HALProcessSnapshot {
        HALProcessSnapshot(processes: processes, serviceEpoch: serviceEpoch)
    }

    func replace(devices: [OutputDeviceDescriptor], defaultDeviceUID: String?) {
        self.devices = devices
        self.defaultDeviceUID = defaultDeviceUID
    }

    func replace(processes: [HALAudioProcessDescriptor]) {
        self.processes = processes
    }

    func simulateServiceRestart() {
        serviceEpoch &+= 1
        emit(.serviceRestarted)
    }

    func setEventHandler(_ handler: @escaping (CoreAudioHALEvent) -> Void) {
        eventHandler = handler
    }

    func stopObserving() {
        eventHandler = nil
    }

    func emit(_ event: CoreAudioHALEvent) {
        eventHandler?(event)
    }
}
