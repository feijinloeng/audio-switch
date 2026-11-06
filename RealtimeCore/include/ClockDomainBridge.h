#pragma once

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ypq_clock_bridge ypq_clock_bridge;

/// The controller assumes 48 kHz stereo frames at its input. It only computes
/// an adaptive output/input ratio; a later libsamplerate adapter owns actual
/// sample conversion.
ypq_clock_bridge *ypq_clock_bridge_create(
    double target_nominal_rate,
    uint32_t target_fill_frames,
    double proportional_gain,
    double integral_gain
);
void ypq_clock_bridge_destroy(ypq_clock_bridge *bridge);
void ypq_clock_bridge_reset(ypq_clock_bridge *bridge);

/// Callback-safe PI update using the legacy 480-frame update interval. New
/// output callbacks should use `ypq_clock_bridge_update_for_frames` so the
/// integrator and ratio slew stay stable across device buffer sizes.
double ypq_clock_bridge_update(
    ypq_clock_bridge *bridge,
    uint32_t current_fill_frames,
    bool recovering
);

/// Callback-safe, frame-aware PI update. Steady state is bounded to ±1,000
/// ppm, recovery is bounded to ±5,000 ppm, and the requested correction is
/// slewed at the development profile's 5,000 ppm per second. The control
/// plane chooses `recovering`; the callback only consumes that immutable flag.
double ypq_clock_bridge_update_for_frames(
    ypq_clock_bridge *bridge,
    uint32_t current_fill_frames,
    bool recovering,
    uint32_t output_frames
);

#ifdef __cplusplus
}
#endif
