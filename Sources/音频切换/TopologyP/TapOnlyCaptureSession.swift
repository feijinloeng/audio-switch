import AudioToolbox
import CoreAudio
import Dispatch
import Foundation
import RealtimeCore

/// Coalesces capture-callback completions into a control-plane event. The
/// callback itself only merges data into a Dispatch source; waiter bookkeeping
/// stays off the realtime thread.
actor CaptureProgressNotifier {
    private var generation: UInt64 = 0
    private var waiters: [UUID: CheckedContinuation<UInt64?, Never>] = [:]

    func currentGeneration() -> UInt64 {
        generation
    }

    func waitForProgress(after observedGeneration: UInt64) async -> UInt64? {
        guard generation <= observedGeneration else { return generation }
        let waiterID = UUID()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: nil)
                } else if generation > observedGeneration {
                    continuation.resume(returning: generation)
                } else {
                    waiters[waiterID] = continuation
                }
            }
        }, onCancel: {
            Task { await self.cancelWaiter(waiterID) }
        })
    }

    func signal() {
        generation &+= 1
        if generation == 0 { generation = 1 }
        let pendingWaiters = waiters
        waiters.removeAll()
        for continuation in pendingWaiters.values {
            continuation.resume(returning: generation)
        }
    }

    private func cancelWaiter(_ waiterID: UUID) {
        waiters.removeValue(forKey: waiterID)?.resume(returning: nil)
    }
}

/// Development-spike ownership for the fixed capture half of topology P.
/// It intentionally contains no physical output UID or output AudioUnit:
/// capture and playback must remain in separate clock domains.
final class TapOnlyCaptureSession {
    struct Diagnostics: Equatable, Sendable {
        struct Format: Equatable, Sendable {
            let sampleRate: Double
            let formatID: UInt32
            let formatFlags: UInt32
            let channels: UInt32
            let bytesPerFrame: UInt32
        }

        let tapUID: String?
        let aggregateUID: String?
        let aggregateDeviceID: UInt32?
        let processObjectIDs: [UInt32]
        let isPrivate: Bool
        let isTapOnly: Bool
        let format: Format?
        let lifecycleEvents: [String]
    }

    enum Failure: Error {
        case noProcessObjects
        case osStatus(OSStatus)
        case unavailableTapFormat
        case unavailableTapUID
        case unavailableCaptureFanout
        case unsupportedDirectBindingFormat(TapCaptureFormat.Rejection)
    }

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let callbackContext: CaptureCallbackContext?
    private var createdTapUID: String?
    private var createdAggregateUID: String?
    private var createdAggregateDeviceID: UInt32?
    private var processObjectIDs: [UInt32] = []
    private var capturedFormat: Diagnostics.Format?
    private var lifecycleEvents: [String] = []

    private(set) var tapFormat: AudioStreamBasicDescription?
    private(set) var isRunning = false

    init(binding: OpaquePointer, progressNotifier: CaptureProgressNotifier) {
        callbackContext = CaptureCallbackContext(
            binding: binding,
            progressNotifier: progressNotifier
        )
    }

    deinit { stop() }

    /// Control-plane evidence only. The callback never reads or mutates this
    /// snapshot; its timing values live in the C++ binding atomics instead.
    var diagnostics: Diagnostics {
        Diagnostics(
            tapUID: createdTapUID,
            aggregateUID: createdAggregateUID,
            aggregateDeviceID: createdAggregateDeviceID,
            processObjectIDs: processObjectIDs,
            isPrivate: true,
            isTapOnly: true,
            format: capturedFormat,
            lifecycleEvents: lifecycleEvents
        )
    }

    func start(processObjectIDs: [AudioObjectID], label: String) throws {
        guard !isRunning else { return }
        guard !processObjectIDs.isEmpty else { throw Failure.noProcessObjects }
        lifecycleEvents = []
        self.processObjectIDs = processObjectIDs.map { UInt32($0) }
        createdTapUID = nil
        createdAggregateUID = nil
        createdAggregateDeviceID = nil
        capturedFormat = nil

        let description = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped

        var createdTapID = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &createdTapID)
        guard status == noErr, createdTapID != kAudioObjectUnknown else {
            throw Failure.osStatus(status)
        }
        tapID = createdTapID
        lifecycleEvents.append("tapCreated")

        do {
            tapFormat = try readTapFormat(tapID)
            guard let tapFormat else { throw Failure.unavailableTapFormat }
            capturedFormat = Diagnostics.Format(
                sampleRate: tapFormat.mSampleRate,
                formatID: tapFormat.mFormatID,
                formatFlags: tapFormat.mFormatFlags,
                channels: tapFormat.mChannelsPerFrame,
                bytesPerFrame: tapFormat.mBytesPerFrame
            )
            lifecycleEvents.append("tapFormatRead")
            let preparedAdapter = try PreparedCaptureAdapter(
                sourceFormat: tapFormat,
                maximumOutputFrames: 16_384
            )
            guard let preparedContext = callbackContext,
                  preparedContext.prepare(adapter: preparedAdapter) else {
                throw Failure.unavailableCaptureFanout
            }
            let tapUID = try readTapUID(tapID)
            createdTapUID = tapUID
            lifecycleEvents.append("tapUIDRead")
            let aggregateUID = UUID().uuidString
            createdAggregateUID = aggregateUID
            let aggregateDescription: [String: Any] = [
                kAudioAggregateDeviceNameKey as String: "音频切换-TopologyP-Capture-\(label)",
                kAudioAggregateDeviceUIDKey as String: aggregateUID,
                kAudioAggregateDeviceIsPrivateKey as String: true,
                kAudioAggregateDeviceTapAutoStartKey as String: true,
                // This is deliberately a tap-only list. Do not add a target
                // device, default device, master, clock, or sub-device here.
                kAudioAggregateDeviceTapListKey as String: [
                    [
                        kAudioSubTapUIDKey as String: tapUID,
                        kAudioSubTapDriftCompensationKey as String: false,
                    ],
                ],
            ]
            var createdAggregateID = AudioObjectID(kAudioObjectUnknown)
            status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &createdAggregateID)
            guard status == noErr, createdAggregateID != kAudioObjectUnknown else {
                throw Failure.osStatus(status)
            }
            aggregateDeviceID = createdAggregateID
            createdAggregateDeviceID = UInt32(createdAggregateID)
            lifecycleEvents.append("aggregateCreated")

            status = AudioDeviceCreateIOProcID(
                aggregateDeviceID,
                Self.captureIOProc,
                Unmanaged.passUnretained(preparedContext).toOpaque(),
                &ioProcID
            )
            guard status == noErr, let ioProcID else { throw Failure.osStatus(status) }
            lifecycleEvents.append("ioProcCreated")

            status = AudioDeviceStart(aggregateDeviceID, ioProcID)
            guard status == noErr else { throw Failure.osStatus(status) }
            isRunning = true
            lifecycleEvents.append("ioStarted")
        } catch {
            stop()
            throw error
        }
    }

    /// Idempotent fixed inverse order: stop IO → destroy IOProc → destroy
    /// private Aggregate → destroy Tap → release Swift-owned metadata.
    func stop() {
        defer { callbackContext?.signalControlPlaneProgress() }
        // Join any conversion worker before the fan-out it writes into can be
        // closed or destroyed. Calling this more than once is harmless.
        callbackContext?.stopConversionDelivery()
        if let ioProcID, aggregateDeviceID != kAudioObjectUnknown {
            // The fan-out closes first, waits for its admitted callback, and
            // begins retirement only for bindings still borrowed by live
            // snapshots. An acknowledged original binding may already have
            // been reclaimed by a handoff or service-restart teardown.
            _ = callbackContext?.beginShutdown()
            AudioDeviceStop(aggregateDeviceID, ioProcID)
            lifecycleEvents.append("ioStopped")
            AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            lifecycleEvents.append("ioProcDestroyed")
            callbackContext?.markProducerDetached()
            self.ioProcID = nil
        }
        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            lifecycleEvents.append("aggregateDestroyed")
            aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            lifecycleEvents.append("tapDestroyed")
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        tapFormat = nil
        isRunning = false
    }

    /// Backend-actor publication used by output handoff preparation. Failed
    /// validation or allocation leaves the last committed snapshot intact.
    func publishCaptureBindings(
        _ bindings: [OpaquePointer],
        generation: UInt64
    ) -> Bool {
        callbackContext?.publish(bindings: bindings, generation: generation) ?? false
    }

    /// Backend-actor proof that the Process Tap callback has moved to the
    /// requested immutable snapshot generation.
    func acknowledgeCaptureBindings(generation: UInt64) -> Bool {
        callbackContext?.acknowledge(generation: generation) ?? false
    }

    private static let captureIOProc: AudioDeviceIOProc = {
        _, _, inputData, inputTime, _, _, clientData in
        guard let clientData else { return noErr }
        let context = Unmanaged<CaptureCallbackContext>.fromOpaque(clientData).takeUnretainedValue()
        _ = context.write(input: inputData, timestamp: inputTime)
        return noErr
    }

    private func readTapFormat(_ tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format)
        guard status == noErr else { throw Failure.unavailableTapFormat }
        return format
    }

    private func readTapUID(_ tapID: AudioObjectID) throws -> String {
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { throw Failure.unavailableTapUID }
        return value.takeRetainedValue() as String
    }
}

/// The IOProc retains only an unretained pointer to this session-owned arena.
/// `TapOnlyCaptureSession.stop()` unregisters IO before releasing it; binding
/// reclamation additionally waits for the C++ producer gate proof.
final class CaptureCallbackContext {
    private var adapter: PreparedCaptureAdapter?
    private let fanout: OpaquePointer
    private let progressNotifier: CaptureProgressNotifier
    private let progressSource: DispatchSourceUserDataAdd

    init?(
        binding: OpaquePointer,
        progressNotifier: CaptureProgressNotifier = CaptureProgressNotifier()
    ) {
        guard let fanout = ypq_capture_fanout_create() else { return nil }
        let initialBindings: [OpaquePointer?] = [binding]
        let published = initialBindings.withUnsafeBufferPointer {
            ypq_capture_fanout_publish(fanout, $0.baseAddress, 1, 1)
        }
        guard published else {
            ypq_capture_fanout_destroy(fanout)
            return nil
        }
        self.fanout = fanout
        self.progressNotifier = progressNotifier
        let source = DispatchSource.makeUserDataAddSource(
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler { [progressNotifier] in
            Task { await progressNotifier.signal() }
        }
        self.progressSource = source
        source.resume()
    }

    deinit {
        adapter?.stopRealtimeDelivery()
        progressSource.cancel()
        ypq_capture_fanout_destroy(fanout)
    }

    func prepare(adapter: PreparedCaptureAdapter) -> Bool {
        guard self.adapter == nil,
              adapter.prepareRealtimeDelivery(toFanout: fanout) else { return false }
        self.adapter = adapter
        return true
    }

    func publish(bindings: [OpaquePointer], generation: UInt64) -> Bool {
        let nullableBindings = bindings.map(Optional.some)
        return nullableBindings.withUnsafeBufferPointer {
            ypq_capture_fanout_publish(
                fanout,
                $0.baseAddress,
                UInt32($0.count),
                generation
            )
        }
    }

    func acknowledge(generation: UInt64) -> Bool {
        ypq_capture_fanout_acknowledge(fanout, generation)
    }

    func captureProgressGeneration() async -> UInt64 {
        await progressNotifier.currentGeneration()
    }

    func waitForCaptureProgress(after observedGeneration: UInt64) async -> UInt64? {
        await progressNotifier.waitForProgress(after: observedGeneration)
    }

    func signalControlPlaneProgress() {
        progressSource.add(data: 1)
    }

    func beginShutdown() -> Bool {
        ypq_capture_fanout_begin_shutdown(fanout)
    }

    func stopConversionDelivery() {
        adapter?.stopRealtimeDelivery()
    }

    func markProducerDetached() {
        ypq_capture_fanout_mark_producer_detached(fanout)
    }

    func write(
        input: UnsafePointer<AudioBufferList>,
        timestamp: UnsafePointer<AudioTimeStamp>?
    ) -> UInt32 {
        defer { signalControlPlaneProgress() }
        if let timestamp {
            ypq_capture_fanout_record_producer_timestamp(
                fanout,
                timestamp.pointee.mSampleTime,
                timestamp.pointee.mHostTime
            )
        }
        guard let adapter else { return 0 }
        return adapter.write(input: input, toFanout: fanout)
    }
}
