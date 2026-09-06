#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Adds prepared stereo binding buffers into caller-owned output memory.
/// `sources` and `gains` must remain valid for the whole callback. The mixer
/// neither allocates nor locks; source_count == 0 explicitly writes silence.
void ypq_realtime_mixer_mix(
    const float *const *sources,
    const float *gains,
    uint32_t source_count,
    float *output_interleaved_stereo,
    uint32_t frame_count
);

#ifdef __cplusplus
}
#endif
