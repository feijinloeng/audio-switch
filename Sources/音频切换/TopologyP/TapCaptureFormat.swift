import AudioToolbox

/// The Phase-3 spike has no `AudioConverterRef` boundary yet. It may publish
/// only an ASBD that is already identical to the fixed processing format;
/// every other format fails before a muted tap is started. Production support
/// for other source rates, layouts and PCM encodings belongs to the converter
/// boundary introduced with the locked ASRC implementation.
enum TapCaptureFormat {
    enum Rejection: Error, Equatable {
        case sampleRate(Double)
        case encoding
        case channelCount(UInt32)
        case nonInterleaved
        case frameLayout
    }

    static let processingSampleRate = 48_000.0
    static let processingChannels: UInt32 = 2
    static let bytesPerFrame: UInt32 = 8

    static func validateDirectBinding(_ format: AudioStreamBasicDescription) throws {
        guard format.mSampleRate == processingSampleRate else {
            throw Rejection.sampleRate(format.mSampleRate)
        }
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mBitsPerChannel == 32,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0 else {
            throw Rejection.encoding
        }
        guard format.mChannelsPerFrame == processingChannels else {
            throw Rejection.channelCount(format.mChannelsPerFrame)
        }
        guard format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0 else {
            throw Rejection.nonInterleaved
        }
        guard format.mFramesPerPacket == 1,
              format.mBytesPerFrame == bytesPerFrame,
              format.mBytesPerPacket == bytesPerFrame else {
            throw Rejection.frameLayout
        }
    }

    /// All supported PCM shapes are classified before the muted Tap starts.
    /// Only the exact canonical shape may use the direct binding; every other
    /// valid PCM shape requires the prepared AudioConverter boundary.
    static func adapterPath(for format: AudioStreamBasicDescription) throws -> CaptureFormatAdapter.Path {
        try CaptureFormatAdapter.prepare(source: format)
    }
}
