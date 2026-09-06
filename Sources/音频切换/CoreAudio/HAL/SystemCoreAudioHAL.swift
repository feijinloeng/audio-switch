import AudioToolbox
import Dispatch
import Foundation

enum SystemCoreAudioHALListenerKind {
    case system
    case outputState
}

struct SystemCoreAudioHALListener {
    let objectID: AudioObjectID
    let address: AudioObjectPropertyAddress
    let block: AudioObjectPropertyListenerBlock
    let kind: SystemCoreAudioHALListenerKind
}

/// Core Audio creates this aggregate while it proxies the system default
/// output for a Process Tap. It is an internal capture endpoint, never a
/// physical speaker a user can select.
enum InternalCoreAudioDevicePolicy {
    private static let defaultAggregatePrefix = "CADefaultDeviceAggregate-"

    static func isSelectableOutput(uid: String) -> Bool {
        !uid.hasPrefix(defaultAggregatePrefix)
    }
}

/// Serializes the mutable control-plane state shared by the main actor, the
/// topology backend actor, and Core Audio property-listener callbacks.
final class SystemCoreAudioHALState {
    private let lock = NSLock()
    private var serviceEpoch: UInt64 = 0
    private var eventHandler: ((CoreAudioHALEvent) -> Void)?
    private var listeners: [SystemCoreAudioHALListener] = []
    private var listenerGeneration: UInt64 = 0
    private var nextProcessHandleToken: UInt64 = 0
    private var processHandlesByObjectID: [AudioObjectID: ProcessObjectHandle] = [:]

    func currentServiceEpoch() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return serviceEpoch
    }

    func beginObserving(
        handler: @escaping (CoreAudioHALEvent) -> Void
    ) -> (generation: UInt64, listenersToRemove: [SystemCoreAudioHALListener]) {
        lock.lock()
        defer { lock.unlock() }

        listenerGeneration &+= 1
        eventHandler = handler
        let listenersToRemove = listeners
        listeners.removeAll()
        return (listenerGeneration, listenersToRemove)
    }

    func stopObserving() -> [SystemCoreAudioHALListener] {
        lock.lock()
        defer { lock.unlock() }

        listenerGeneration &+= 1
        eventHandler = nil
        let listenersToRemove = listeners
        listeners.removeAll()
        return listenersToRemove
    }

    func appendListener(
        _ listener: SystemCoreAudioHALListener,
        generation: UInt64
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard listenerGeneration == generation, eventHandler != nil else { return false }
        listeners.append(listener)
        return true
    }

    func replaceOutputStateListeners(
        generation: UInt64
    ) -> [SystemCoreAudioHALListener]? {
        lock.lock()
        defer { lock.unlock() }

        guard listenerGeneration == generation, eventHandler != nil else { return nil }
        let listenersToRemove = listeners.filter { $0.kind == .outputState }
        listeners.removeAll { $0.kind == .outputState }
        return listenersToRemove
    }

    func deliver(
        _ event: CoreAudioHALEvent,
        generation: UInt64
    ) {
        let handler: ((CoreAudioHALEvent) -> Void)?

        lock.lock()
        guard listenerGeneration == generation else {
            lock.unlock()
            return
        }
        if event == .serviceRestarted {
            serviceEpoch &+= 1
            processHandlesByObjectID.removeAll()
        }
        handler = eventHandler
        lock.unlock()

        // Handlers may re-enter the HAL or hop to another executor, so they
        // must never run while the shared state lock is held.
        handler?(event)
    }

    func processHandles(
        for objectIDs: [AudioObjectID]
    ) -> (epoch: UInt64, handlesByObjectID: [AudioObjectID: ProcessObjectHandle]) {
        lock.lock()
        defer { lock.unlock() }

        let epoch = serviceEpoch
        var handlesByObjectID: [AudioObjectID: ProcessObjectHandle] = [:]
        handlesByObjectID.reserveCapacity(objectIDs.count)

        for objectID in objectIDs {
            if let existing = processHandlesByObjectID[objectID], existing.halEpoch == epoch {
                handlesByObjectID[objectID] = existing
                continue
            }

            nextProcessHandleToken &+= 1
            let handle = ProcessObjectHandle(token: nextProcessHandleToken, halEpoch: epoch)
            processHandlesByObjectID[objectID] = handle
            handlesByObjectID[objectID] = handle
        }
        return (epoch, handlesByObjectID)
    }

    func resolveProcessObjectIDs(
        for handles: [ProcessObjectHandle]
    ) -> [AudioObjectID]? {
        lock.lock()
        defer { lock.unlock() }

        guard handles.allSatisfy({ $0.halEpoch == serviceEpoch }) else { return nil }
        let resolved = handles.compactMap { handle in
            processHandlesByObjectID.first(where: { $0.value == handle })?.key
        }
        guard resolved.count == handles.count,
              Set(resolved).count == resolved.count else { return nil }
        return resolved
    }
}

/// Read-only adapter for the public Core Audio Hardware Abstraction Layer.
///
/// It owns only non-realtime Core Audio property listeners. IO objects and
/// audio callbacks remain in the topology backend actor.
final class SystemCoreAudioHAL: CoreAudioHAL, @unchecked Sendable {
    private let state = SystemCoreAudioHALState()
    /// Keep property callbacks away from Core Audio's real-time work.
    private let observationQueue = DispatchQueue(label: "com.mankeipun.yinpinqiehuan.core-audio-observation", qos: .utility)

    var serviceEpoch: UInt64 { state.currentServiceEpoch() }

    func outputSnapshot() -> HALOutputSnapshot {
        var descriptors: [OutputDeviceDescriptor] = []
        var seenUIDs = Set<String>()

        let deviceIDs = AudioObjectID.allAudioDevices()

        for deviceID in deviceIDs {
            let uid = deviceID.readDeviceUID()
            guard !uid.isEmpty,
                  InternalCoreAudioDevicePolicy.isSelectableOutput(uid: uid),
                  seenUIDs.insert(uid).inserted else { continue }
            guard !deviceID.isDeviceHidden(),
                  hasOutputStream(deviceID) else { continue }

            let name = deviceID.readDeviceName()
            guard !name.hasPrefix("音频切换-") else { continue }

            descriptors.append(
                OutputDeviceDescriptor(
                    uid: uid,
                    name: name,
                    readiness: deviceID.isAlive() ? .formatReady : .unavailable,
                    nominalSampleRate: nominalSampleRate(of: deviceID),
                    channelCount: outputChannelCount(of: deviceID),
                    transport: outputDeviceTransport(of: deviceID)
                )
            )
        }

        let descriptorUIDs = Set(descriptors.map(\.uid))
        let defaultUID = AudioObjectID.defaultOutputDevice().readDeviceUID()
        let coherentDefaultUID = descriptorUIDs.contains(defaultUID) ? defaultUID : nil

        return HALOutputSnapshot(
            devices: descriptors,
            defaultDeviceUID: coherentDefaultUID,
            serviceEpoch: serviceEpoch
        )
    }

    func setEventHandler(_ handler: @escaping (CoreAudioHALEvent) -> Void) {
        let observation = state.beginObserving(handler: handler)
        removeListeners(observation.listenersToRemove)
        addSystemListener(
            selector: kAudioHardwarePropertyDevices,
            event: .deviceListChanged,
            generation: observation.generation,
            beforeDelivery: { [weak self] in
                self?.refreshOutputStateListeners(generation: observation.generation)
            }
        )
        addSystemListener(
            selector: kAudioHardwarePropertyDefaultOutputDevice,
            event: .defaultOutputChanged,
            generation: observation.generation
        )
        refreshOutputStateListeners(generation: observation.generation)
        addSystemListener(
            selector: kAudioHardwarePropertyServiceRestarted,
            event: .serviceRestarted,
            generation: observation.generation
        )
        addSystemListener(
            selector: kAudioHardwarePropertyProcessObjectList,
            event: .processListChanged,
            generation: observation.generation
        )
    }

    func processSnapshot() -> HALProcessSnapshot {
        let processFacts = AudioObjectID.readProcessList().compactMap { objectID -> (AudioObjectID, pid_t, String?, Bool, Bool)? in
            guard let pid = objectID.processPID, pid > 0 else { return nil }
            return (
                objectID,
                pid,
                objectID.processBundleID,
                objectID.processIsRunningOutput ?? false,
                objectID.processIsRunning ?? false
            )
        }
        let handleSnapshot = state.processHandles(for: processFacts.map { $0.0 })
        let processes = processFacts.compactMap { objectID, pid, bundleID, isRunningOutput, isRunning -> HALAudioProcessDescriptor? in
            guard let handle = handleSnapshot.handlesByObjectID[objectID] else { return nil }
            return HALAudioProcessDescriptor(
                handle: handle,
                pid: pid,
                bundleID: bundleID,
                isRunningOutput: isRunningOutput,
                isRunning: isRunning
            )
        }
        return HALProcessSnapshot(processes: processes, serviceEpoch: handleSnapshot.epoch)
    }

    /// Development-backend bridge only. Opaque handles are resolved while
    /// they still belong to this HAL epoch; raw object IDs never enter route
    /// domain state, preferences, or UI models.
    func resolveProcessObjectIDs(
        for handles: [ProcessObjectHandle]
    ) -> [AudioObjectID]? {
        state.resolveProcessObjectIDs(for: handles)
    }

    /// Resolves a transient Core Audio device object from a stable UID only at
    /// the HAL boundary. Callers must re-resolve after a service restart.
    func resolveOutputDeviceID(uid: String) -> AudioDeviceID? {
        AudioObjectID.allAudioDevices().first { $0.readDeviceUID() == uid }
    }

    func stopObserving() {
        removeListeners(state.stopObserving())
    }

    private func removeListeners(_ listeners: [SystemCoreAudioHALListener]) {
        for listener in listeners {
            var address = listener.address
            AudioObjectRemovePropertyListenerBlock(
                listener.objectID,
                &address,
                observationQueue,
                listener.block
            )
        }
    }

    private func hasOutputStream(_ deviceID: AudioDeviceID) -> Bool {
        var size: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        return AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr && size > 0
    }

    private func addSystemListener(
        selector: AudioObjectPropertySelector,
        event: CoreAudioHALEvent,
        generation: UInt64,
        beforeDelivery: (() -> Void)? = nil
    ) {
        addListener(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: selector,
            scope: kAudioObjectPropertyScopeGlobal,
            event: event,
            generation: generation,
            kind: .system,
            beforeDelivery: beforeDelivery
        )
    }

    private func refreshOutputStateListeners(generation: UInt64) {
        guard let listenersToRemove = state.replaceOutputStateListeners(generation: generation) else { return }
        removeListeners(listenersToRemove)

        for deviceID in AudioObjectID.allAudioDevices() where isObservableOutput(deviceID) {
            addOutputStateListener(
                deviceID: deviceID,
                selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                generation: generation
            )
            addOutputStateListener(
                deviceID: deviceID,
                selector: kAudioDevicePropertyVolumeScalar,
                generation: generation
            )
            addOutputStateListener(
                deviceID: deviceID,
                selector: kAudioDevicePropertyMute,
                generation: generation
            )
        }
    }

    private func isObservableOutput(_ deviceID: AudioDeviceID) -> Bool {
        let uid = deviceID.readDeviceUID()
        guard !uid.isEmpty,
              InternalCoreAudioDevicePolicy.isSelectableOutput(uid: uid),
              !deviceID.isDeviceHidden(),
              hasOutputStream(deviceID) else { return false }
        return !deviceID.readDeviceName().hasPrefix("音频切换-")
    }

    private func addOutputStateListener(
        deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector,
        generation: UInt64
    ) {
        addListener(
            objectID: deviceID,
            selector: selector,
            scope: kAudioDevicePropertyScopeOutput,
            event: .deviceConfigurationChanged,
            generation: generation,
            kind: .outputState
        )
    }

    private func addListener(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        event: CoreAudioHALEvent,
        generation: UInt64,
        kind: SystemCoreAudioHALListenerKind,
        beforeDelivery: (() -> Void)? = nil
    ) {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            beforeDelivery?()
            self?.state.deliver(event, generation: generation)
        }
        guard AudioObjectAddPropertyListenerBlock(objectID, &address, observationQueue, block) == noErr else { return }
        let listener = SystemCoreAudioHALListener(
            objectID: objectID,
            address: address,
            block: block,
            kind: kind
        )
        guard state.appendListener(listener, generation: generation) else {
            removeListeners([listener])
            return
        }
    }

    private func nominalSampleRate(of deviceID: AudioDeviceID) -> Double {
        var sampleRate = 0.0
        var size = UInt32(MemoryLayout<Double>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &sampleRate)
        return status == noErr ? sampleRate : 0
    }

    private func outputDeviceTransport(of deviceID: AudioDeviceID) -> OutputDeviceTransport {
        var transportType = UInt32(kAudioDeviceTransportTypeUnknown)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            &transportType
        )
        guard status == noErr else { return .other }
        return Self.outputDeviceTransport(coreAudioTransportType: transportType)
    }

    static func outputDeviceTransport(
        coreAudioTransportType: UInt32
    ) -> OutputDeviceTransport {
        switch coreAudioTransportType {
        case kAudioDeviceTransportTypeBuiltIn:
            return .builtIn
        case kAudioDeviceTransportTypeBluetooth,
             kAudioDeviceTransportTypeBluetoothLE:
            return .bluetooth
        default:
            return .other
        }
    }

    private func outputChannelCount(of deviceID: AudioDeviceID) -> Int {
        var size: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr, size > 0 else {
            return 0
        }

        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { storage.deallocate() }

        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, storage)
        guard status == noErr else { return 0 }

        let bufferList = storage.assumingMemoryBound(to: AudioBufferList.self)
        return UnsafeMutableAudioBufferListPointer(bufferList).reduce(0) { count, buffer in
            count + Int(buffer.mNumberChannels)
        }
    }
}
