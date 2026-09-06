import AudioToolbox
import Dispatch
import RealtimeCore

/// Owns an optional fixed-format `AudioConverterRef` and all scratch storage
/// before the Tap IOProc starts. It is deliberately confined to the
/// topology-P runtime: no converter is created, destroyed, or reconfigured
/// from a callback.
final class PreparedCaptureAdapter {
    enum Failure: Error {
        case format(CaptureFormatAdapter.Failure)
        case converter(OSStatus)
        case inputQueue
        case unsupportedDirectBuffer
    }

    private let sourceFormat: AudioStreamBasicDescription
    private let path: CaptureFormatAdapter.Path
    private let maximumOutputFrames: UInt32
    private let scratch: UnsafeMutablePointer<Float>
    private var converter: AudioConverterRef?
    private let inputQueue: OpaquePointer?
    private let conversionQueue: DispatchQueue?
    private let conversionWakeSource: DispatchSourceUserDataAdd?
    private var converterFanout: OpaquePointer?
    private var currentInput: UnsafePointer<AudioBufferList>?
    private var currentInputFrames: UInt32 = 0
    private var didSupplyInput = false

    private static let conversionWorkerKey = DispatchSpecificKey<UInt8>()

    private enum WriteTarget {
        case binding(OpaquePointer)
        case fanout(OpaquePointer)
    }

    init(sourceFormat: AudioStreamBasicDescription, maximumOutputFrames: UInt32) throws {
        guard maximumOutputFrames > 0 else { throw Failure.unsupportedDirectBuffer }
        self.sourceFormat = sourceFormat
        do {
            path = try CaptureFormatAdapter.prepare(source: sourceFormat)
        } catch let failure as CaptureFormatAdapter.Failure {
            throw Failure.format(failure)
        }
        self.maximumOutputFrames = maximumOutputFrames
        scratch = .allocate(capacity: Int(maximumOutputFrames) * 2)
        scratch.initialize(repeating: 0, count: Int(maximumOutputFrames) * 2)

        guard case let .audioConverter(map) = path else {
            inputQueue = nil
            conversionQueue = nil
            conversionWakeSource = nil
            return
        }

        var mutableSource = sourceFormat
        var destination = CaptureFormatAdapter.canonicalFormat
        var created: AudioConverterRef?
        let status = AudioConverterNew(&mutableSource, &destination, &created)
        guard status == noErr, let created else {
            scratch.deinitialize(count: Int(maximumOutputFrames) * 2)
            scratch.deallocate()
            throw Failure.converter(status)
        }
        var channelMap = [Int32(map.leftSourceChannel), Int32(map.rightSourceChannel)]
        let mapStatus = AudioConverterSetProperty(
            created,
            kAudioConverterChannelMap,
            UInt32(channelMap.count * MemoryLayout<Int32>.size),
            &channelMap
        )
        guard mapStatus == noErr else {
            AudioConverterDispose(created)
            scratch.deinitialize(count: Int(maximumOutputFrames) * 2)
            scratch.deallocate()
            throw Failure.converter(mapStatus)
        }

        guard let queue = Self.makeInputQueue(
            sourceFormat: sourceFormat,
            maximumOutputFrames: maximumOutputFrames
        ) else {
            AudioConverterDispose(created)
            scratch.deinitialize(count: Int(maximumOutputFrames) * 2)
            scratch.deallocate()
            throw Failure.inputQueue
        }

        converter = created
        inputQueue = queue
        let workerQueue = DispatchQueue(
            label: "com.mankeipun.yinpinqiehuan.capture-conversion",
            qos: .userInitiated
        )
        workerQueue.setSpecific(key: Self.conversionWorkerKey, value: 1)
        conversionQueue = workerQueue
        let source = DispatchSource.makeUserDataAddSource(queue: workerQueue)
        conversionWakeSource = source
        source.setEventHandler { [weak self] in
            self?.drainQueuedConversion()
        }
        source.resume()
    }

    deinit {
        stopRealtimeDelivery()
        if let inputQueue {
            ypq_capture_input_queue_destroy(inputQueue)
        }
        if let converter { AudioConverterDispose(converter) }
        releaseScratch()
    }

    /// Test/control-plane seam. Conversion here is synchronous and must not
    /// be called from a Process Tap callback.
    func write(
        input: UnsafePointer<AudioBufferList>,
        to binding: OpaquePointer
    ) -> UInt32 {
        write(input: input, target: .binding(binding))
    }

    /// The stable Process Tap path emits its already-adapted canonical frames
    /// through the capture-owned immutable snapshot. Non-canonical input is
    /// copied to a fixed SPSC queue; conversion runs on its worker instead of
    /// the Core Audio realtime callback.
    func write(
        input: UnsafePointer<AudioBufferList>,
        toFanout fanout: OpaquePointer
    ) -> UInt32 {
        switch path {
        case .directCanonical:
            return writeDirectCanonical(input: input, target: .fanout(fanout))
        case .audioConverter:
            return enqueueForConversion(input: input)
        }
    }

    /// Must be called before the Tap IOProc starts. It gives the conversion
    /// worker its stable capture-owned output target.
    func prepareRealtimeDelivery(toFanout fanout: OpaquePointer) -> Bool {
        guard case .audioConverter = path else { return true }
        guard inputQueue != nil,
              conversionWakeSource != nil,
              converterFanout == nil else { return false }
        converterFanout = fanout
        return true
    }

    /// Control-plane stop. It prevents the conversion worker from retaining a
    /// fan-out write while the capture session begins its teardown.
    func stopRealtimeDelivery() {
        conversionWakeSource?.cancel()
        if DispatchQueue.getSpecific(key: Self.conversionWorkerKey) == nil {
            conversionQueue?.sync {}
        }
    }

    private func write(
        input: UnsafePointer<AudioBufferList>,
        target: WriteTarget
    ) -> UInt32 {
        switch path {
        case .directCanonical:
            return writeDirectCanonical(input: input, target: target)
        case .audioConverter:
            return convertAndWrite(input: input, target: target)
        }
    }

    private func enqueueForConversion(
        input: UnsafePointer<AudioBufferList>
    ) -> UInt32 {
        guard let queue = inputQueue,
              let inputFrames = frameCount(in: input),
              ypq_capture_input_queue_enqueue(queue, input) else { return 0 }
        conversionWakeSource?.add(data: 1)
        return inputFrames
    }

    private func drainQueuedConversion() {
        guard let queue = inputQueue, let fanout = converterFanout else { return }
        while let input = ypq_capture_input_queue_begin_read(queue, nil) {
            _ = convertAndWrite(input: input, target: .fanout(fanout))
            ypq_capture_input_queue_end_read(queue)
        }
    }

    private func writeDirectCanonical(
        input: UnsafePointer<AudioBufferList>,
        target: WriteTarget
    ) -> UInt32 {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard buffers.count == 1,
              let data = buffers[0].mData,
              buffers[0].mNumberChannels == 2,
              buffers[0].mDataByteSize % 8 == 0 else { return 0 }
        let frames = min(buffers[0].mDataByteSize / 8, maximumOutputFrames)
        return write(
            data.assumingMemoryBound(to: Float.self),
            frameCount: frames,
            target: target
        )
    }

    private func convertAndWrite(
        input: UnsafePointer<AudioBufferList>,
        target: WriteTarget
    ) -> UInt32 {
        guard let converter,
              let inputFrames = frameCount(in: input), inputFrames > 0 else { return 0 }
        currentInput = input
        currentInputFrames = inputFrames
        didSupplyInput = false
        var outputFrames = maximumOutputFrames
        var output = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: 2,
                mDataByteSize: maximumOutputFrames * 8,
                mData: scratch
            )
        )
        let status = AudioConverterFillComplexBuffer(
            converter,
            Self.supplyInput,
            Unmanaged.passUnretained(self).toOpaque(),
            &outputFrames,
            &output,
            nil
        )
        currentInput = nil
        currentInputFrames = 0
        guard status == noErr, outputFrames > 0 else { return 0 }
        return write(scratch, frameCount: outputFrames, target: target)
    }

    private func write(
        _ frames: UnsafePointer<Float>,
        frameCount: UInt32,
        target: WriteTarget
    ) -> UInt32 {
        switch target {
        case let .binding(binding):
            return ypq_route_binding_write(binding, frames, frameCount)
        case let .fanout(fanout):
            return ypq_capture_fanout_write(fanout, frames, frameCount)
        }
    }

    private func frameCount(in input: UnsafePointer<AudioBufferList>) -> UInt32? {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard !buffers.isEmpty, sourceFormat.mBytesPerFrame > 0 else { return nil }
        let frameCount = buffers[0].mDataByteSize / sourceFormat.mBytesPerFrame
        guard frameCount > 0 else { return nil }
        guard buffers.allSatisfy({
            $0.mData != nil && $0.mDataByteSize / sourceFormat.mBytesPerFrame == frameCount
        }) else { return nil }
        return frameCount
    }

    private static func makeInputQueue(
        sourceFormat: AudioStreamBasicDescription,
        maximumOutputFrames: UInt32
    ) -> OpaquePointer? {
        guard sourceFormat.mBytesPerFrame > 0,
              sourceFormat.mSampleRate > 0 else { return nil }
        let maximumInputFrames = Double(maximumOutputFrames)
            * sourceFormat.mSampleRate / CaptureFormatAdapter.canonicalFormat.mSampleRate
        guard maximumInputFrames <= Double(UInt32.max - 2) else { return nil }
        let bufferCount: UInt32 = sourceFormat.mFormatFlags
            & kAudioFormatFlagIsNonInterleaved != 0
            ? sourceFormat.mChannelsPerFrame
            : 1
        return ypq_capture_input_queue_create(
            UInt32(maximumInputFrames.rounded(.up)) + 2,
            sourceFormat.mBytesPerFrame,
            bufferCount,
            8
        )
    }

    private func releaseScratch() {
        scratch.deinitialize(count: Int(maximumOutputFrames) * 2)
        scratch.deallocate()
    }

    private static let supplyInput: AudioConverterComplexInputDataProc = {
        _, ioNumberDataPackets, ioData, _, userData in
        guard let userData else { return kAudio_ParamError }
        let adapter = Unmanaged<PreparedCaptureAdapter>.fromOpaque(userData).takeUnretainedValue()
        guard !adapter.didSupplyInput, let source = adapter.currentInput else {
            ioNumberDataPackets.pointee = 0
            return noErr
        }
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: source))
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(ioData)
        guard destinationBuffers.count >= sourceBuffers.count else { return kAudio_ParamError }
        ioData.pointee.mNumberBuffers = UInt32(sourceBuffers.count)
        for index in 0..<sourceBuffers.count {
            destinationBuffers[index] = sourceBuffers[index]
        }
        ioNumberDataPackets.pointee = adapter.currentInputFrames
        adapter.didSupplyInput = true
        return noErr
    }
}
