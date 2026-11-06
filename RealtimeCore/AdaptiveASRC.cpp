#include "AdaptiveASRC.h"

#include "samplerate.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <new>
#include <vector>

namespace {
constexpr int kStereoChannels = 2;
constexpr int kConverterType = SRC_SINC_FASTEST;
constexpr uint32_t kFilterGuardFrames = 64;
}

struct ypq_adaptive_asrc {
    SRC_STATE *state;
    std::vector<float> input;
    uint32_t pending_offset {0};
    uint32_t pending_frames {0};
};

ypq_adaptive_asrc *ypq_adaptive_asrc_create(uint32_t max_input_frames) {
    if (max_input_frames == 0) return nullptr;
    int error = 0;
    SRC_STATE *state = src_new(kConverterType, kStereoChannels, &error);
    if (state == nullptr || error != 0) return nullptr;
    auto *bridge = new (std::nothrow) ypq_adaptive_asrc {state, std::vector<float>()};
    if (bridge == nullptr) {
        src_delete(state);
        return nullptr;
    }
    try {
        bridge->input.resize(static_cast<size_t>(max_input_frames) * kStereoChannels);
    } catch (...) {
        src_delete(state);
        delete bridge;
        return nullptr;
    }
    return bridge;
}

void ypq_adaptive_asrc_destroy(ypq_adaptive_asrc *bridge) {
    if (bridge == nullptr) return;
    src_delete(bridge->state);
    delete bridge;
}

void ypq_adaptive_asrc_reset(ypq_adaptive_asrc *bridge) {
    if (bridge == nullptr) return;
    src_reset(bridge->state);
    bridge->pending_offset = 0;
    bridge->pending_frames = 0;
}

uint32_t ypq_adaptive_asrc_pending_frames(const ypq_adaptive_asrc *bridge) {
    return bridge == nullptr ? 0 : bridge->pending_frames;
}

uint32_t ypq_adaptive_asrc_process(
    ypq_adaptive_asrc *bridge,
    ypq_route_binding *binding,
    float *output,
    uint32_t output_frames,
    double ratio
) {
    if (output == nullptr || output_frames == 0) return 0;
    std::memset(output, 0, static_cast<size_t>(output_frames) * kStereoChannels * sizeof(float));
    if (bridge == nullptr || binding == nullptr || !std::isfinite(ratio) || ratio <= 0.0) return 0;

    uint32_t generated = 0;
    const uint32_t capacity = static_cast<uint32_t>(bridge->input.size() / kStereoChannels);
    while (generated < output_frames) {
        if (bridge->pending_frames == 0) {
            bridge->pending_offset = 0;
            bridge->pending_frames = ypq_route_binding_read_unmetered(
                binding, bridge->input.data(), capacity
            );
            if (bridge->pending_frames == 0) break;
        }
        SRC_DATA data {};
        data.data_in = bridge->input.data() + static_cast<size_t>(bridge->pending_offset) * kStereoChannels;
        data.data_out = output + static_cast<size_t>(generated) * kStereoChannels;
        data.output_frames = output_frames - generated;
        data.src_ratio = ratio;
        // Feeding libsamplerate the whole ring buffer lets it retain a large
        // opaque tail internally when the output callback is smaller. Keep
        // the unneeded tail in our explicit pending buffer so watermarks and
        // recovery can observe it on the following callback.
        const double requested_input = std::ceil(
            static_cast<double>(data.output_frames) / ratio
        ) + kFilterGuardFrames;
        const uint32_t bounded_input = static_cast<uint32_t>(std::min<double>(
            requested_input,
            static_cast<double>(bridge->pending_frames)
        ));
        data.input_frames = std::max<uint32_t>(1, bounded_input);
        if (src_process(bridge->state, &data) != 0) break;
        bridge->pending_offset += static_cast<uint32_t>(data.input_frames_used);
        bridge->pending_frames -= static_cast<uint32_t>(data.input_frames_used);
        generated += static_cast<uint32_t>(data.output_frames_gen);
        if (data.input_frames_used == 0 && data.output_frames_gen == 0) break;
    }
    ypq_route_binding_record_underrun(binding, output_frames - generated);
    return generated;
}
