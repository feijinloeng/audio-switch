#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ypq_bus_limiter ypq_bus_limiter;

/// Creates a device-bus limiter. Configuration happens off the realtime path.
ypq_bus_limiter *ypq_bus_limiter_create(
    float sample_rate,
    float threshold,
    float max_reduction_db
);
void ypq_bus_limiter_destroy(ypq_bus_limiter *limiter);

/// Limits an interleaved stereo output bus in place without allocating or locking.
/// The limiter adds a fixed one-millisecond look-ahead latency so gain can
/// ramp smoothly before a detected transient reaches the output.
void ypq_bus_limiter_process(
    ypq_bus_limiter *limiter,
    float *interleaved_stereo,
    uint32_t frame_count
);

#ifdef __cplusplus
}
#endif
