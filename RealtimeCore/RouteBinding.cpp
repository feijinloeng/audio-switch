#include "RouteBinding.h"

#include "RealtimeCallbackGate.h"
#include "RealtimeRingBuffer.h"

#include <atomic>
#include <algorithm>
#include <cmath>
#include <cstring>
#include <new>

namespace {

void publish_max(std::atomic<uint64_t> &value, uint64_t candidate) {
    uint64_t observed = value.load(std::memory_order_relaxed);
    while (observed < candidate
           && !value.compare_exchange_weak(
               observed,
               candidate,
               std::memory_order_release,
               std::memory_order_relaxed
           )) {
    }
}

uint64_t double_bits(double value) {
    uint64_t bits = 0;
    static_assert(sizeof(bits) == sizeof(value));
    std::memcpy(&bits, &value, sizeof(bits));
    return bits;
}

double bits_double(uint64_t bits) {
    double value = 0;
    static_assert(sizeof(bits) == sizeof(value));
    std::memcpy(&value, &bits, sizeof(value));
    return value;
}

} // namespace

struct ypq_route_binding {
    ypq_ring_buffer *ring_buffer;
    ypq_callback_gate *producer_gate;
    ypq_callback_gate *output_gate;
    std::atomic<bool> producer_detached {false};
    std::atomic<uint64_t> removed_snapshot_generation {0};
    std::atomic<uint64_t> overrun_frames {0};
    std::atomic<uint64_t> underrun_frames {0};
    std::atomic<uint64_t> producer_callback_count {0};
    std::atomic<uint64_t> produced_frames {0};
    std::atomic<uint64_t> last_producer_sample_time_bits {0};
    std::atomic<uint64_t> last_producer_host_time {0};
    std::atomic<uint64_t> control_gain_bits {0};
    std::atomic<bool> control_muted {false};
};

ypq_route_binding *ypq_route_binding_create(uint32_t capacity_frames) {
    auto *binding = new (std::nothrow) ypq_route_binding{
        ypq_ring_buffer_create(capacity_frames),
        ypq_callback_gate_create(),
        ypq_callback_gate_create(),
    };
    if (binding == nullptr
        || binding->ring_buffer == nullptr
        || binding->producer_gate == nullptr
        || binding->output_gate == nullptr) {
        if (binding != nullptr) {
            ypq_ring_buffer_destroy(binding->ring_buffer);
            ypq_callback_gate_destroy(binding->producer_gate);
            ypq_callback_gate_destroy(binding->output_gate);
        }
        delete binding;
        return nullptr;
    }
    binding->control_gain_bits.store(double_bits(1.0), std::memory_order_relaxed);
    return binding;
}

void ypq_route_binding_destroy(ypq_route_binding *binding) {
    if (binding == nullptr) {
        return;
    }
    ypq_ring_buffer_destroy(binding->ring_buffer);
    ypq_callback_gate_destroy(binding->producer_gate);
    ypq_callback_gate_destroy(binding->output_gate);
    delete binding;
}

uint32_t ypq_route_binding_write(
    ypq_route_binding *binding,
    const float *interleaved_stereo_frames,
    uint32_t frame_count
) {
    if (binding == nullptr || !ypq_callback_gate_try_enter(binding->producer_gate)) {
        return 0;
    }
    const uint32_t written = ypq_ring_buffer_write(
        binding->ring_buffer,
        interleaved_stereo_frames,
        frame_count
    );
    binding->producer_callback_count.fetch_add(1, std::memory_order_relaxed);
    binding->produced_frames.fetch_add(written, std::memory_order_relaxed);
    if (written < frame_count) {
        binding->overrun_frames.fetch_add(frame_count - written, std::memory_order_relaxed);
    }
    ypq_callback_gate_leave(binding->producer_gate, 0);
    return written;
}

uint32_t ypq_route_binding_read(
    ypq_route_binding *binding,
    float *interleaved_stereo_frames,
    uint32_t frame_count
) {
    if (binding == nullptr || !ypq_callback_gate_try_enter(binding->output_gate)) {
        return 0;
    }
    const uint32_t read = ypq_ring_buffer_read(
        binding->ring_buffer,
        interleaved_stereo_frames,
        frame_count
    );
    if (read < frame_count) {
        binding->underrun_frames.fetch_add(frame_count - read, std::memory_order_relaxed);
    }
    ypq_callback_gate_leave(binding->output_gate, 0);
    return read;
}

uint32_t ypq_route_binding_read_unmetered(
    ypq_route_binding *binding,
    float *interleaved_stereo_frames,
    uint32_t frame_count
) {
    if (binding == nullptr || !ypq_callback_gate_try_enter(binding->output_gate)) {
        return 0;
    }
    const uint32_t read = ypq_ring_buffer_read(
        binding->ring_buffer,
        interleaved_stereo_frames,
        frame_count
    );
    ypq_callback_gate_leave(binding->output_gate, 0);
    return read;
}

void ypq_route_binding_record_underrun(ypq_route_binding *binding, uint32_t frame_count) {
    if (binding != nullptr && frame_count > 0) {
        binding->underrun_frames.fetch_add(frame_count, std::memory_order_relaxed);
    }
}

uint64_t ypq_route_binding_overrun_frames(const ypq_route_binding *binding) {
    return binding == nullptr ? 0 : binding->overrun_frames.load(std::memory_order_acquire);
}

uint64_t ypq_route_binding_underrun_frames(const ypq_route_binding *binding) {
    return binding == nullptr ? 0 : binding->underrun_frames.load(std::memory_order_acquire);
}

uint64_t ypq_route_binding_producer_callback_count(const ypq_route_binding *binding) {
    return binding == nullptr
        ? 0
        : binding->producer_callback_count.load(std::memory_order_acquire);
}

uint64_t ypq_route_binding_produced_frames(const ypq_route_binding *binding) {
    return binding == nullptr ? 0 : binding->produced_frames.load(std::memory_order_acquire);
}

void ypq_route_binding_record_producer_timestamp(
    ypq_route_binding *binding,
    double sample_time,
    uint64_t host_time
) {
    if (binding == nullptr) return;
    binding->last_producer_sample_time_bits.store(double_bits(sample_time), std::memory_order_relaxed);
    binding->last_producer_host_time.store(host_time, std::memory_order_relaxed);
}

double ypq_route_binding_last_producer_sample_time(const ypq_route_binding *binding) {
    return binding == nullptr
        ? 0
        : bits_double(binding->last_producer_sample_time_bits.load(std::memory_order_acquire));
}

uint64_t ypq_route_binding_last_producer_host_time(const ypq_route_binding *binding) {
    return binding == nullptr
        ? 0
        : binding->last_producer_host_time.load(std::memory_order_acquire);
}

uint32_t ypq_route_binding_available_frames(const ypq_route_binding *binding) {
    return binding == nullptr
        ? 0
        : ypq_ring_buffer_available_to_read(binding->ring_buffer);
}

void ypq_route_binding_publish_controls(
    ypq_route_binding *binding,
    float gain,
    bool muted
) {
    if (binding == nullptr) return;
    const float normalized = std::isfinite(gain) ? std::max(0.0F, std::min(gain, 1.0F)) : 1.0F;
    binding->control_gain_bits.store(
        double_bits(static_cast<double>(normalized)), std::memory_order_release
    );
    binding->control_muted.store(muted, std::memory_order_release);
}

float ypq_route_binding_published_gain(const ypq_route_binding *binding) {
    return binding == nullptr ? 1.0F : static_cast<float>(bits_double(
        binding->control_gain_bits.load(std::memory_order_acquire)
    ));
}

bool ypq_route_binding_published_muted(const ypq_route_binding *binding) {
    return binding != nullptr && binding->control_muted.load(std::memory_order_acquire);
}

bool ypq_route_binding_begin_retirement(ypq_route_binding *binding) {
    return binding != nullptr && ypq_callback_gate_begin_closing(binding->producer_gate);
}

void ypq_route_binding_mark_producer_detached(ypq_route_binding *binding) {
    if (binding != nullptr) {
        binding->producer_detached.store(true, std::memory_order_release);
    }
}

void ypq_route_binding_acknowledge_snapshot_removal(
    ypq_route_binding *binding,
    uint64_t snapshot_generation
) {
    if (binding == nullptr) {
        return;
    }
    publish_max(binding->removed_snapshot_generation, snapshot_generation);
    ypq_callback_gate_begin_closing(binding->output_gate);
}

bool ypq_route_binding_discard_sealed_tail(ypq_route_binding *binding) {
    if (binding == nullptr
        || !binding->producer_detached.load(std::memory_order_acquire)
        || !ypq_callback_gate_is_quiescent(binding->producer_gate)
        || !ypq_callback_gate_is_quiescent(binding->output_gate)) {
        return false;
    }
    ypq_ring_buffer_discard_all(binding->ring_buffer);
    return true;
}

bool ypq_route_binding_ready_to_reclaim(
    const ypq_route_binding *binding,
    uint64_t required_snapshot_generation
) {
    return binding != nullptr
        && binding->producer_detached.load(std::memory_order_acquire)
        && ypq_ring_buffer_available_to_read(binding->ring_buffer) == 0
        && binding->removed_snapshot_generation.load(std::memory_order_acquire)
            >= required_snapshot_generation
        && ypq_callback_gate_is_quiescent(binding->producer_gate)
        && ypq_callback_gate_is_quiescent(binding->output_gate);
}

bool ypq_route_binding_finish_retirement(ypq_route_binding *binding) {
    return binding != nullptr
        && ypq_callback_gate_finish_closing(binding->producer_gate)
        && ypq_callback_gate_finish_closing(binding->output_gate);
}
