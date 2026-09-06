#pragma once

#include <stdint.h>

#include "RouteBinding.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ypq_adaptive_asrc ypq_adaptive_asrc;

/// Creates the fixed stereo libsamplerate processing state and all callback
/// scratch storage. `max_input_frames` is selected during route prepare.
ypq_adaptive_asrc *ypq_adaptive_asrc_create(uint32_t max_input_frames);
void ypq_adaptive_asrc_destroy(ypq_adaptive_asrc *bridge);
void ypq_adaptive_asrc_reset(ypq_adaptive_asrc *bridge);
/// Input-domain frames already removed from the route binding but not yet
/// consumed by libsamplerate. Render watermarks must include these frames.
uint32_t ypq_adaptive_asrc_pending_frames(const ypq_adaptive_asrc *bridge);

/// Produces at most `output_frames` stereo frames into already-owned storage.
/// The remainder is zeroed. `ratio` is the output/input ratio calculated by
/// ClockDomainBridge; no allocation, locking, logging, or blocking occurs.
uint32_t ypq_adaptive_asrc_process(
    ypq_adaptive_asrc *bridge,
    ypq_route_binding *binding,
    float *interleaved_stereo_output,
    uint32_t output_frames,
    double ratio
);

#ifdef __cplusplus
}
#endif
