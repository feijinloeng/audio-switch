#include "RealtimeBusLimiter.h"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <new>

namespace {

constexpr size_t kChannels = 2;
constexpr float kLookAheadMilliseconds = 1.0F;

float coefficient(float milliseconds, float sample_rate) {
    return std::exp(-1.0F / (sample_rate * milliseconds / 1000.0F));
}

} // namespace

struct ypq_bus_limiter {
    float threshold;
    float minimum_gain;
    float release_coefficient;
    float current_gain;
    float attack_target_gain;
    float attack_step;
    uint32_t attack_frames_remaining;
    uint32_t lookahead_frames;
    uint32_t buffered_frames;
    uint32_t write_frame;
    float *delay_line;
};

ypq_bus_limiter *ypq_bus_limiter_create(float sample_rate, float threshold, float max_reduction_db) {
    const float rate = std::max(1.0F, sample_rate);
    const float safe_threshold = std::clamp(threshold, 0.0001F, 1.0F);
    const float safe_reduction = std::max(0.0F, max_reduction_db);
    const auto lookahead_frames = std::max(
        1U,
        static_cast<uint32_t>(std::lround(rate * kLookAheadMilliseconds / 1000.0F))
    );
    auto *delay_line = new (std::nothrow) float[static_cast<size_t>(lookahead_frames) * kChannels]();
    if (delay_line == nullptr) return nullptr;
    auto *limiter = new (std::nothrow) ypq_bus_limiter{
        safe_threshold,
        std::pow(10.0F, -safe_reduction / 20.0F),
        coefficient(50.0F, rate),
        1.0F,
        1.0F,
        0.0F,
        0,
        lookahead_frames,
        0,
        0,
        delay_line,
    };
    if (limiter == nullptr) delete[] delay_line;
    return limiter;
}

void ypq_bus_limiter_destroy(ypq_bus_limiter *limiter) {
    if (limiter != nullptr) delete[] limiter->delay_line;
    delete limiter;
}

void ypq_bus_limiter_process(ypq_bus_limiter *limiter, float *interleaved_stereo, uint32_t frame_count) {
    if (limiter == nullptr || interleaved_stereo == nullptr || frame_count == 0) {
        return;
    }
    for (uint32_t frame = 0; frame < frame_count; ++frame) {
        const size_t sample_index = static_cast<size_t>(frame) * kChannels;
        const float left = interleaved_stereo[sample_index];
        const float right = interleaved_stereo[sample_index + 1];
        const float peak = std::max(std::abs(left), std::abs(right));
        const float target_gain = peak > limiter->threshold
            ? std::max(limiter->minimum_gain, limiter->threshold / peak)
            : 1.0F;

        // The delayed frame is emitted one millisecond later. Start a linear
        // attack now so the gain reaches this peak's target before that frame
        // leaves the delay line, avoiding a callback-boundary gain step.
        if (target_gain < limiter->current_gain
            && (limiter->attack_frames_remaining == 0
                || target_gain < limiter->attack_target_gain)) {
            limiter->attack_target_gain = target_gain;
            limiter->attack_frames_remaining = limiter->lookahead_frames;
            limiter->attack_step = (target_gain - limiter->current_gain)
                / static_cast<float>(limiter->attack_frames_remaining);
        }
        if (limiter->attack_frames_remaining > 0) {
            limiter->current_gain += limiter->attack_step;
            --limiter->attack_frames_remaining;
            if (limiter->attack_frames_remaining == 0) {
                limiter->current_gain = limiter->attack_target_gain;
            }
        } else {
            limiter->current_gain += (1.0F - limiter->current_gain)
                * (1.0F - limiter->release_coefficient);
        }

        const size_t delayed_index = static_cast<size_t>(limiter->write_frame) * kChannels;
        const float delayed_left = limiter->delay_line[delayed_index];
        const float delayed_right = limiter->delay_line[delayed_index + 1];
        limiter->delay_line[delayed_index] = left;
        limiter->delay_line[delayed_index + 1] = right;
        limiter->write_frame = (limiter->write_frame + 1) % limiter->lookahead_frames;

        if (limiter->buffered_frames < limiter->lookahead_frames) {
            ++limiter->buffered_frames;
            interleaved_stereo[sample_index] = 0.0F;
            interleaved_stereo[sample_index + 1] = 0.0F;
        } else {
            interleaved_stereo[sample_index] = delayed_left * limiter->current_gain;
            interleaved_stereo[sample_index + 1] = delayed_right * limiter->current_gain;
        }
    }
}
