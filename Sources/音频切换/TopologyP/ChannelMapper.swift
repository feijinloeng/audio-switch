import Foundation

/// Prepared, deterministic PCM channel mapping for the topology-P boundary.
/// The map is selected during route preparation; `mapInterleavedFloat32` does
/// no allocation, locking, logging, or format discovery in a realtime path.
enum ChannelMapper {
    enum Failure: Error, Equatable {
        case unsupportedInputChannels(Int)
        case invalidFrameCount
    }

    struct StereoMap: Equatable, Sendable {
        let leftSourceChannel: Int
        let rightSourceChannel: Int
    }

    /// Core Audio's standard interleaved ordering starts with front-left and
    /// front-right. Mono duplicates its sole channel; surround/LFE channels
    /// are intentionally not mixed into the primary stereo program path.
    static func preferredStereoMap(inputChannels: Int) throws -> StereoMap {
        switch inputChannels {
        case 1:
            return StereoMap(leftSourceChannel: 0, rightSourceChannel: 0)
        case 2...8:
            return StereoMap(leftSourceChannel: 0, rightSourceChannel: 1)
        default:
            throw Failure.unsupportedInputChannels(inputChannels)
        }
    }

    static func mapInterleavedFloat32(
        input: UnsafePointer<Float>?,
        inputChannels: Int,
        output: UnsafeMutablePointer<Float>?,
        frameCount: Int,
        map: StereoMap
    ) throws {
        guard frameCount >= 0 else { throw Failure.invalidFrameCount }
        guard frameCount == 0 || (input != nil && output != nil) else { return }
        guard map.leftSourceChannel >= 0, map.rightSourceChannel >= 0,
              map.leftSourceChannel < inputChannels, map.rightSourceChannel < inputChannels else {
            throw Failure.unsupportedInputChannels(inputChannels)
        }
        guard let input, let output else { return }
        for frame in 0..<frameCount {
            let source = input.advanced(by: frame * inputChannels)
            let destination = output.advanced(by: frame * 2)
            destination[0] = source[map.leftSourceChannel]
            destination[1] = source[map.rightSourceChannel]
        }
    }
}
