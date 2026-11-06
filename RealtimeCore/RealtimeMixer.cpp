#include "RealtimeMixer.h"

#include <algorithm>
#include <cstddef>

namespace {

constexpr size_t kChannels = 2;

} // namespace

void ypq_realtime_mixer_mix(
    const float *const *sources,
    const float *gains,
    uint32_t source_count,
    float *output_interleaved_stereo,
    uint32_t frame_count
) {
    if (output_interleaved_stereo == nullptr || frame_count == 0) {
        return;
    }
    const size_t sample_count = static_cast<size_t>(frame_count) * kChannels;
    std::fill_n(output_interleaved_stereo, sample_count, 0.0f);
    if (sources == nullptr || gains == nullptr) {
        return;
    }
    for (uint32_t source_index = 0; source_index < source_count; ++source_index) {
        const float *source = sources[source_index];
        if (source == nullptr) {
            continue;
        }
        const float gain = gains[source_index];
        for (size_t sample_index = 0; sample_index < sample_count; ++sample_index) {
            output_interleaved_stereo[sample_index] += source[sample_index] * gain;
        }
    }
}
