import AudioToolbox
import Foundation
import RealtimeCore

/// Development-spike ownership for one physical output device. The render
/// callback supports either a silent lifecycle spike or one prepared binding
/// through the development ASRC bridge. Device-wide binding snapshots and
/// mixing are deliberately not wired into the release target yet.
final class AUHALOutputSession {
    struct RenderMetrics: Equatable, Sendable {
        let callbackCount: UInt64
        let maximumRenderTicks: UInt64
        let lastRenderHostTicks: UInt64
        let maximumCallbackFrames: UInt32
        let lowWatermarkEventCount: UInt64
        let recoveryEventCount: UInt64
        let partialUnderrunFrames: UInt64
        let minimumEffectiveFillFrames: UInt32
        let maximumEffectiveFillFrames: UInt32
        let lastCallbackSampleTime: Double
        let lastCallbackHostTime: UInt64
    }
    enum Failure: Error {
        case unavailableComponent
        case osStatus(OSStatus)
        case realtimePreparationFailed
        case realtimeSnapshotReplacementTimedOut
    }

    private var unit: AudioUnit?
    private(set) var isRunning = false
    private let deviceID: AudioDeviceID
    private let clientSampleRate: Double
    private let binding: OpaquePointer?
    private let asrc: OpaquePointer?
    private let clockBridge: OpaquePointer?
    private let deviceRenderHost: OpaquePointer?
    private let maxCallbackFrames: UInt32
    private let delayEnabled: Bool
    private var manualDelayMilliseconds: Int

    init(deviceID: AudioDeviceID, clientSampleRate: Double) {
        self.deviceID = deviceID
        self.clientSampleRate = max(1, clientSampleRate)
        binding = nil
        asrc = nil
        clockBridge = nil
        deviceRenderHost = nil
        maxCallbackFrames = 0
        delayEnabled = false
        manualDelayMilliseconds = 0
    }

    /// Development-harness route only. The caller owns `binding` and must not
    /// reclaim it until output snapshot removal and callback quiescence have
    /// both been acknowledged.
    init(
        deviceID: AudioDeviceID,
        clientSampleRate: Double,
        binding: OpaquePointer,
        profile: BufferProfile
    ) throws {
        guard profile.isValid,
              let createdASRC = ypq_adaptive_asrc_create(profile.capacityFrames),
              let createdClockBridge = ypq_clock_bridge_create(
                clientSampleRate,
                profile.targetFrames,
                0.05,
                0.001
              ) else {
            throw Failure.realtimePreparationFailed
        }
        self.deviceID = deviceID
        self.clientSampleRate = max(1, clientSampleRate)
        self.binding = binding
        asrc = createdASRC
        clockBridge = createdClockBridge
        deviceRenderHost = nil
        maxCallbackFrames = 0
        delayEnabled = false
        manualDelayMilliseconds = 0
    }

    /// One physical device owns this one AUHAL session even when several app
    /// bindings target it. Each binding receives its own ASRC/clock state in
    /// the prepared device render snapshot.
    init(
        deviceID: AudioDeviceID,
        clientSampleRate: Double,
        bindings: [OpaquePointer],
        profile: BufferProfile,
        maxCallbackFrames: UInt32,
        manualDelayMilliseconds: Int? = nil,
        initialGain: Float = 1
    ) throws {
        guard profile.isValid, !bindings.isEmpty else {
            throw Failure.realtimePreparationFailed
        }
        let nullableBindings = bindings.map(Optional.some)
        let createdSession = nullableBindings.withUnsafeBufferPointer { buffer in
            ypq_device_render_session_create_with_watermarks(
                buffer.baseAddress,
                UInt32(bindings.count),
                profile.capacityFrames,
                maxCallbackFrames,
                clientSampleRate,
                profile.targetFrames,
                profile.preRollFrames,
                profile.lowFrames,
                profile.highFrames
            )
        }
        let normalizedRate = max(1, clientSampleRate)
        let clampedDelay = min(
            max(manualDelayMilliseconds ?? 0, 0),
            PanoramaGroupMember.maximumManualDelayMilliseconds
        )
        let maximumDelayFrames = UInt32(
            normalizedRate * Double(PanoramaGroupMember.maximumManualDelayMilliseconds) / 1_000
        )
        let initialDelayFrames = UInt32(normalizedRate * Double(clampedDelay) / 1_000)
        let transitionFrames = UInt32(normalizedRate * 0.03)
        guard let createdSession else {
            throw Failure.realtimePreparationFailed
        }
        if manualDelayMilliseconds != nil,
           (!ypq_device_render_session_configure_delay(
               createdSession,
               maximumDelayFrames,
               initialDelayFrames,
               transitionFrames
           ) || !ypq_device_render_session_prime_delay(createdSession, initialDelayFrames)) {
            ypq_device_render_session_destroy(createdSession)
            throw Failure.realtimePreparationFailed
        }
        guard let createdHost = ypq_device_render_host_create(createdSession) else {
            ypq_device_render_session_destroy(createdSession)
            throw Failure.realtimePreparationFailed
        }
        // Endpoint hot-swap starts a joining speaker at gain 0 so it fades in.
        // This runs before the AUHAL output starts, so no callback has rendered.
        ypq_device_render_host_set_initial_gain(createdHost, initialGain)
        self.deviceID = deviceID
        self.clientSampleRate = max(1, clientSampleRate)
        self.binding = nil
        self.asrc = nil
        self.clockBridge = nil
        self.deviceRenderHost = createdHost
        self.maxCallbackFrames = maxCallbackFrames
        self.delayEnabled = manualDelayMilliseconds != nil
        self.manualDelayMilliseconds = clampedDelay
    }

    func start() throws {
        guard !isRunning else { return }
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw Failure.unavailableComponent
        }
        var createdUnit: AudioUnit?
        var status = AudioComponentInstanceNew(component, &createdUnit)
        guard status == noErr, let createdUnit else { throw Failure.osStatus(status) }
        unit = createdUnit

        do {
            var outputEnabled: UInt32 = 1
            status = AudioUnitSetProperty(
                createdUnit,
                kAudioOutputUnitProperty_EnableIO,
                kAudioUnitScope_Output,
                0,
                &outputEnabled,
                UInt32(MemoryLayout<UInt32>.size)
            )
            guard status == noErr else { throw Failure.osStatus(status) }

            var selectedDevice = deviceID
            status = AudioUnitSetProperty(
                createdUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &selectedDevice,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            guard status == noErr else { throw Failure.osStatus(status) }

            var format = AudioStreamBasicDescription(
                mSampleRate: clientSampleRate,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagsNativeFloatPacked,
                mBytesPerPacket: UInt32(MemoryLayout<Float>.size * 2),
                mFramesPerPacket: 1,
                mBytesPerFrame: UInt32(MemoryLayout<Float>.size * 2),
                mChannelsPerFrame: 2,
                mBitsPerChannel: 32,
                mReserved: 0
            )
            status = AudioUnitSetProperty(
                createdUnit,
                kAudioUnitProperty_StreamFormat,
                kAudioUnitScope_Input,
                0,
                &format,
                UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            )
            guard status == noErr else { throw Failure.osStatus(status) }

            var callback = AURenderCallbackStruct(
                inputProc: Self.render,
                inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
            )
            status = AudioUnitSetProperty(
                createdUnit,
                kAudioUnitProperty_SetRenderCallback,
                kAudioUnitScope_Input,
                0,
                &callback,
                UInt32(MemoryLayout<AURenderCallbackStruct>.size)
            )
            guard status == noErr else { throw Failure.osStatus(status) }

            status = AudioUnitInitialize(createdUnit)
            guard status == noErr else { throw Failure.osStatus(status) }
            status = AudioOutputUnitStart(createdUnit)
            guard status == noErr else { throw Failure.osStatus(status) }
            isRunning = true
        } catch {
            stop()
            throw error
        }
    }

    /// Fixed inverse order: stop AUHAL → unregister render callback →
    /// uninitialize → dispose → release prepared realtime state.
    func stop() {
        guard let unit else { return }
        if isRunning { AudioOutputUnitStop(unit) }
        var emptyCallback = AURenderCallbackStruct(inputProc: nil, inputProcRefCon: nil)
        AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_SetRenderCallback,
            kAudioUnitScope_Input,
            0,
            &emptyCallback,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        self.unit = nil
        isRunning = false
    }

    /// Control-plane snapshot only; the callback updates these C++ atomics.
    func renderMetrics() -> RenderMetrics? {
        guard let deviceRenderHost else { return nil }
        return RenderMetrics(
            callbackCount: ypq_device_render_host_render_callback_count(deviceRenderHost),
            maximumRenderTicks: ypq_device_render_host_maximum_render_ticks(deviceRenderHost),
            lastRenderHostTicks: ypq_device_render_host_last_render_host_ticks(deviceRenderHost),
            maximumCallbackFrames: ypq_device_render_host_maximum_callback_frames(deviceRenderHost),
            lowWatermarkEventCount: ypq_device_render_host_low_watermark_event_count(deviceRenderHost),
            recoveryEventCount: ypq_device_render_host_recovery_event_count(deviceRenderHost),
            partialUnderrunFrames: ypq_device_render_host_partial_underrun_frames(deviceRenderHost),
            minimumEffectiveFillFrames: ypq_device_render_host_minimum_effective_fill_frames(deviceRenderHost),
            maximumEffectiveFillFrames: ypq_device_render_host_maximum_effective_fill_frames(deviceRenderHost),
            lastCallbackSampleTime: ypq_device_render_host_last_callback_sample_time(deviceRenderHost),
            lastCallbackHostTime: ypq_device_render_host_last_callback_host_time(deviceRenderHost)
        )
    }

    /// Control-plane-only immutable snapshot replacement. The C++ host keeps
    /// the old session alive until all admitted callbacks have left it, so an
    /// output callback never observes freed ASRC or scratch state.
    func replaceBindings(_ bindings: [OpaquePointer], profile: BufferProfile) throws {
        guard let deviceRenderHost,
              profile.isValid,
              !bindings.isEmpty,
              maxCallbackFrames > 0 else {
            throw Failure.realtimePreparationFailed
        }
        let nullableBindings = bindings.map(Optional.some)
        let replacement = nullableBindings.withUnsafeBufferPointer { buffer in
            ypq_device_render_session_create_with_watermarks(
                buffer.baseAddress,
                UInt32(bindings.count),
                profile.capacityFrames,
                maxCallbackFrames,
                clientSampleRate,
                profile.targetFrames,
                profile.preRollFrames,
                profile.lowFrames,
                profile.highFrames
            )
        }
        let maximumDelayFrames = UInt32(
            clientSampleRate * Double(PanoramaGroupMember.maximumManualDelayMilliseconds) / 1_000
        )
        let initialDelayFrames = UInt32(
            clientSampleRate * Double(manualDelayMilliseconds) / 1_000
        )
        guard let replacement else {
            throw Failure.realtimePreparationFailed
        }
        if delayEnabled,
           (!ypq_device_render_session_configure_delay(
               replacement,
               maximumDelayFrames,
               initialDelayFrames,
               UInt32(clientSampleRate * 0.03)
           ) || !ypq_device_render_session_prime_delay(replacement, initialDelayFrames)) {
            ypq_device_render_session_destroy(replacement)
            throw Failure.realtimePreparationFailed
        }
        guard ypq_device_render_host_replace(deviceRenderHost, replacement, 1_000_000) else {
            ypq_device_render_session_destroy(replacement)
            throw Failure.realtimeSnapshotReplacementTimedOut
        }
    }

    /// One atomic target publication; AUHAL remains started and the callback
    /// crossfades between delay read heads over 30 ms.
    func setManualDelay(milliseconds: Int) {
        guard delayEnabled, let deviceRenderHost else { return }
        let clamped = min(
            max(milliseconds, 0),
            PanoramaGroupMember.maximumManualDelayMilliseconds
        )
        manualDelayMilliseconds = clamped
        let frames = UInt32(clientSampleRate * Double(clamped) / 1_000)
        ypq_device_render_host_set_delay_frames(deviceRenderHost, frames)
    }

    func acknowledgeSnapshotRemoval(generation: UInt64) {
        guard let deviceRenderHost else { return }
        ypq_device_render_host_acknowledge_snapshot_removal(deviceRenderHost, generation)
    }

    deinit {
        stop()
        ypq_adaptive_asrc_destroy(asrc)
        ypq_clock_bridge_destroy(clockBridge)
        ypq_device_render_host_destroy(deviceRenderHost)
    }

    private static let render: AURenderCallback = {
        refCon, _, timestamp, _, frameCount, ioData in
        guard let ioData else { return noErr }
        let bufferList = ioData.pointee
        guard bufferList.mNumberBuffers == 1,
              let data = bufferList.mBuffers.mData else { return noErr }
        let bytes = Int(bufferList.mBuffers.mDataByteSize)
        let session = Unmanaged<AUHALOutputSession>.fromOpaque(refCon).takeUnretainedValue()
        if let deviceRenderHost = session.deviceRenderHost {
            ypq_device_render_host_record_callback_timestamp(
                deviceRenderHost,
                timestamp.pointee.mSampleTime,
                timestamp.pointee.mHostTime
            )
            ypq_device_render_host_render(
                deviceRenderHost,
                data.assumingMemoryBound(to: Float.self),
                frameCount
            )
            return noErr
        }
        guard let binding = session.binding,
              let asrc = session.asrc,
              let clockBridge = session.clockBridge else {
            memset(data, 0, bytes)
            return noErr
        }
        let ratio = ypq_clock_bridge_update_for_frames(
            clockBridge,
            ypq_route_binding_available_frames(binding),
            false,
            frameCount
        )
        _ = ypq_adaptive_asrc_process(
            asrc,
            binding,
            data.assumingMemoryBound(to: Float.self),
            frameCount,
            ratio
        )
        return noErr
    }
}
