import AudioToolbox

/// Prepares the Tap ASBD boundary before any capture callback is registered.
/// The direct branch is zero-copy; every other supported PCM shape is marked
/// for a pre-created `AudioConverterRef` boundary rather than being guessed
/// from buffer byte counts in the callback.
enum CaptureFormatAdapter {
    enum Failure: Error, Equatable {
        case invalidSampleRate(Double)
        case unsupportedEncoding
        case unsupportedChannelCount(UInt32)
        case invalidFrameLayout
    }

    enum Path: Equatable {
        case directCanonical
        case audioConverter(ChannelMapper.StereoMap)
    }

    static let canonicalFormat = AudioStreamBasicDescription(
        mSampleRate: 48_000,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagsNativeFloatPacked,
        mBytesPerPacket: UInt32(MemoryLayout<Float>.size * 2),
        mFramesPerPacket: 1,
        mBytesPerFrame: UInt32(MemoryLayout<Float>.size * 2),
        mChannelsPerFrame: 2,
        mBitsPerChannel: 32,
        mReserved: 0
    )

    static func prepare(source: AudioStreamBasicDescription) throws -> Path {
        guard source.mSampleRate.isFinite, (8_000...384_000).contains(source.mSampleRate) else {
            throw Failure.invalidSampleRate(source.mSampleRate)
        }
        guard source.mFormatID == kAudioFormatLinearPCM else {
            throw Failure.unsupportedEncoding
        }
        guard (1...8).contains(source.mChannelsPerFrame) else {
            throw Failure.unsupportedChannelCount(source.mChannelsPerFrame)
        }
        guard source.mFramesPerPacket == 1,
              source.mBytesPerFrame > 0,
              source.mBytesPerPacket >= source.mBytesPerFrame,
              source.mBitsPerChannel > 0 else {
            throw Failure.invalidFrameLayout
        }
        if isCanonicalDirectFormat(source) {
            return .directCanonical
        }
        return .audioConverter(
            try ChannelMapper.preferredStereoMap(inputChannels: Int(source.mChannelsPerFrame))
        )
    }

    private static func isCanonicalDirectFormat(_ source: AudioStreamBasicDescription) -> Bool {
        source.mSampleRate == canonicalFormat.mSampleRate
            && source.mFormatID == canonicalFormat.mFormatID
            && source.mFormatFlags == canonicalFormat.mFormatFlags
            && source.mBytesPerPacket == canonicalFormat.mBytesPerPacket
            && source.mFramesPerPacket == canonicalFormat.mFramesPerPacket
            && source.mBytesPerFrame == canonicalFormat.mBytesPerFrame
            && source.mChannelsPerFrame == canonicalFormat.mChannelsPerFrame
            && source.mBitsPerChannel == canonicalFormat.mBitsPerChannel
    }
}
