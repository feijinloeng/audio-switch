#include "ClockDomainBridge.h"

#include <algorithm>
#include <cmath>

namespace {

constexpr double kInternalSampleRate = 48'000.0;
constexpr double kSteadyLimit = 0.001;
constexpr double kRecoveryLimit = 0.005;
constexpr double kIntegralLimit = 1.0;
constexpr uint32_t kLegacyUpdateFrames = 480;
constexpr double kRatioSlewPPMPerSecond = 5'000.0;

} // namespace

struct ypq_clock_bridge {
    ypq_clock_bridge(
        double target_rate,
        uint32_t target_fill,
        double proportional,
        double integral
    )
        : nominal_ratio(target_rate / kInternalSampleRate),
          target_fill_frames(target_fill),
          target_nominal_rate(target_rate),
          proportional_gain(proportional),
          integral_gain(integral) {}

    const double nominal_ratio;
    const uint32_t target_fill_frames;
    const double target_nominal_rate;
    const double proportional_gain;
    const double integral_gain;
    double integral_error {0.0};
    double last_correction {0.0};
};

ypq_clock_bridge *ypq_clock_bridge_create(
    double target_nominal_rate,
    uint32_t target_fill_frames,
    double proportional_gain,
    double integral_gain
) {
    if (!std::isfinite(target_nominal_rate) || target_nominal_rate <= 0.0
        || target_fill_frames == 0
        || !std::isfinite(proportional_gain)
        || !std::isfinite(integral_gain)) {
        return nullptr;
    }
    return new ypq_clock_bridge(
        target_nominal_rate,
        target_fill_frames,
        proportional_gain,
        integral_gain
    );
}

void ypq_clock_bridge_destroy(ypq_clock_bridge *bridge) {
    delete bridge;
}

void ypq_clock_bridge_reset(ypq_clock_bridge *bridge) {
    if (bridge != nullptr) {
        bridge->integral_error = 0.0;
        bridge->last_correction = 0.0;
    }
}

double ypq_clock_bridge_update(
    ypq_clock_bridge *bridge,
    uint32_t current_fill_frames,
    bool recovering
) {
    return ypq_clock_bridge_update_for_frames(
        bridge, current_fill_frames, recovering, kLegacyUpdateFrames
    );
}

double ypq_clock_bridge_update_for_frames(
    ypq_clock_bridge *bridge,
    uint32_t current_fill_frames,
    bool recovering,
    uint32_t output_frames
) {
    if (bridge == nullptr) {
        return 0.0;
    }
    if (output_frames == 0) {
        return bridge->nominal_ratio * (1.0 + bridge->last_correction);
    }
    const double normalized_error = (
        static_cast<double>(current_fill_frames) - bridge->target_fill_frames
    ) / bridge->target_fill_frames;
    const double update_scale = static_cast<double>(output_frames) / kLegacyUpdateFrames;
    const double candidate_integral = std::clamp(
        bridge->integral_error + normalized_error * update_scale,
        -kIntegralLimit,
        kIntegralLimit
    );
    const double limit = recovering ? kRecoveryLimit : kSteadyLimit;
    const double candidate_correction = -(
        bridge->proportional_gain * normalized_error
        + bridge->integral_gain * candidate_integral
    );
    const bool drives_further_into_saturation =
        (candidate_correction < -limit && normalized_error > 0.0)
        || (candidate_correction > limit && normalized_error < 0.0);
    // Anti-windup: when the requested correction is already clamped and the
    // current fill error would push it farther outward, retain the previous
    // integral state. This lets the bridge promptly recenter after recovery.
    if (!drives_further_into_saturation) {
        bridge->integral_error = candidate_integral;
    }
    const double requested_correction = -(
        bridge->proportional_gain * normalized_error
        + bridge->integral_gain * bridge->integral_error
    );
    const double correction = std::clamp(requested_correction, -limit, limit);
    const double maximum_delta = (kRatioSlewPPMPerSecond / 1'000'000.0)
        * (static_cast<double>(output_frames) / bridge->target_nominal_rate);
    bridge->last_correction = std::clamp(
        correction,
        bridge->last_correction - maximum_delta,
        bridge->last_correction + maximum_delta
    );
    return bridge->nominal_ratio * (1.0 + bridge->last_correction);
}
