#if SWIFT_PACKAGE
import RealtimeCore

/// Deterministic development-only clock model. It validates the same
/// frame-aware PI ABI used by the render session, but it is not hardware or
/// callback-deadline evidence and cannot approve topology P.
struct SimulatedClockBridge {
    struct Result: Equatable {
        let minimumFillFrames: Double
        let maximumFillFrames: Double
        let hardRecenters: Int
    }

    static func run(
        driftPPM: Double,
        durationHours: Int = 8,
        capacityFrames: Double = 12_000,
        targetFillFrames: Double = 1_920,
        lowWaterFrames: Double = 720,
        highWaterFrames: Double = 4_800,
        callbackFrames: UInt32 = 480
    ) -> Result? {
        guard durationHours > 0,
              callbackFrames > 0,
              let bridge = ypq_clock_bridge_create(48_000, UInt32(targetFillFrames), 0.05, 0.001) else {
            return nil
        }
        defer { ypq_clock_bridge_destroy(bridge) }

        let callbackCount = durationHours * 60 * 60 * 100
        let producerFrames = Double(callbackFrames) / (1 + driftPPM / 1_000_000)
        var fill = targetFillFrames
        var minimum = fill
        var maximum = fill
        var hardRecenters = 0

        for _ in 0..<callbackCount {
            fill += producerFrames
            let ratio = ypq_clock_bridge_update_for_frames(
                bridge,
                UInt32(max(0, min(fill.rounded(), Double(UInt32.max)))),
                false,
                callbackFrames
            )
            fill -= Double(callbackFrames) / ratio
            minimum = min(minimum, fill)
            maximum = max(maximum, fill)

            if fill < 0 || fill > capacityFrames {
                hardRecenters += 1
                break
            }
        }
        _ = lowWaterFrames
        _ = highWaterFrames
        return Result(
            minimumFillFrames: minimum,
            maximumFillFrames: maximum,
            hardRecenters: hardRecenters
        )
    }
}
#endif
