import AudioToolbox

/// Chooses the one AUHAL client format used by a physical output session.
/// Dynamic 48 kHz-to-device-rate conversion remains solely in adaptive ASRC;
/// the HAL may adapt this client format to the device's hardware stream.
enum DeviceFormatNegotiator {
    enum Failure: Error, Equatable {
        case deviceNotReady
        case invalidNominalSampleRate
        case noOutputChannels
    }

    static func clientFormat(for device: OutputDeviceDescriptor) throws -> AudioStreamBasicDescription {
        guard device.readiness.isPreflightReady else { throw Failure.deviceNotReady }
        guard device.nominalSampleRate.isFinite,
              (8_000...384_000).contains(device.nominalSampleRate) else {
            throw Failure.invalidNominalSampleRate
        }
        guard device.channelCount > 0 else { throw Failure.noOutputChannels }
        return AudioStreamBasicDescription(
            mSampleRate: device.nominalSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked,
            mBytesPerPacket: UInt32(MemoryLayout<Float>.size * 2),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float>.size * 2),
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
    }
}
