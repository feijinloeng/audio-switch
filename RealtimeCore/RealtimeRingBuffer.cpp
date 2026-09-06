#include "RealtimeRingBuffer.h"

#include <algorithm>
#include <atomic>
#include <cstdint>
#include <memory>

namespace {

constexpr uint32_t kChannels = 2;

bool is_power_of_two(uint32_t value) {
    return value != 0 && (value & (value - 1)) == 0;
}

uint32_t copy_frames(
    float *destination,
    const float *source,
    uint32_t first_frame,
    uint32_t frame_count,
    uint32_t capacity_frames
) {
    const uint32_t first_segment = std::min(frame_count, capacity_frames - first_frame);
    std::copy_n(
        source,
        static_cast<size_t>(first_segment) * kChannels,
        destination + static_cast<size_t>(first_frame) * kChannels
    );
    const uint32_t second_segment = frame_count - first_segment;
    if (second_segment != 0) {
        std::copy_n(
            source + static_cast<size_t>(first_segment) * kChannels,
            static_cast<size_t>(second_segment) * kChannels,
            destination
        );
    }
    return frame_count;
}

uint32_t copy_frames_out(
    float *destination,
    const float *source,
    uint32_t first_frame,
    uint32_t frame_count,
    uint32_t capacity_frames
) {
    const uint32_t first_segment = std::min(frame_count, capacity_frames - first_frame);
    std::copy_n(
        source + static_cast<size_t>(first_frame) * kChannels,
        static_cast<size_t>(first_segment) * kChannels,
        destination
    );
    const uint32_t second_segment = frame_count - first_segment;
    if (second_segment != 0) {
        std::copy_n(
            source,
            static_cast<size_t>(second_segment) * kChannels,
            destination + static_cast<size_t>(first_segment) * kChannels
        );
    }
    return frame_count;
}

} // namespace

struct ypq_ring_buffer {
    explicit ypq_ring_buffer(uint32_t capacity)
        : capacity_frames(capacity), mask(capacity - 1), samples(new float[static_cast<size_t>(capacity) * kChannels]) {}

    const uint32_t capacity_frames;
    const uint32_t mask;
    std::unique_ptr<float[]> samples;
    alignas(64) std::atomic<uint32_t> write_index {0};
    alignas(64) std::atomic<uint32_t> read_index {0};
};

ypq_ring_buffer *ypq_ring_buffer_create(uint32_t capacity_frames) {
    if (!is_power_of_two(capacity_frames)) {
        return nullptr;
    }
    return new ypq_ring_buffer(capacity_frames);
}

void ypq_ring_buffer_destroy(ypq_ring_buffer *buffer) {
    delete buffer;
}

uint32_t ypq_ring_buffer_write(
    ypq_ring_buffer *buffer,
    const float *interleaved_stereo_frames,
    uint32_t frame_count
) {
    if (buffer == nullptr || interleaved_stereo_frames == nullptr || frame_count == 0) {
        return 0;
    }
    const uint32_t write = buffer->write_index.load(std::memory_order_relaxed);
    const uint32_t read = buffer->read_index.load(std::memory_order_acquire);
    const uint32_t used = write - read;
    const uint32_t accepted = std::min(frame_count, buffer->capacity_frames - used);
    copy_frames(
        buffer->samples.get(),
        interleaved_stereo_frames,
        write & buffer->mask,
        accepted,
        buffer->capacity_frames
    );
    buffer->write_index.store(write + accepted, std::memory_order_release);
    return accepted;
}

uint32_t ypq_ring_buffer_read(
    ypq_ring_buffer *buffer,
    float *interleaved_stereo_frames,
    uint32_t frame_count
) {
    if (buffer == nullptr || interleaved_stereo_frames == nullptr || frame_count == 0) {
        return 0;
    }
    const uint32_t read = buffer->read_index.load(std::memory_order_relaxed);
    const uint32_t write = buffer->write_index.load(std::memory_order_acquire);
    const uint32_t available = write - read;
    const uint32_t provided = std::min(frame_count, available);
    copy_frames_out(
        interleaved_stereo_frames,
        buffer->samples.get(),
        read & buffer->mask,
        provided,
        buffer->capacity_frames
    );
    buffer->read_index.store(read + provided, std::memory_order_release);
    return provided;
}

uint32_t ypq_ring_buffer_available_to_read(const ypq_ring_buffer *buffer) {
    if (buffer == nullptr) {
        return 0;
    }
    const uint32_t write = buffer->write_index.load(std::memory_order_acquire);
    const uint32_t read = buffer->read_index.load(std::memory_order_acquire);
    return write - read;
}

uint32_t ypq_ring_buffer_available_to_write(const ypq_ring_buffer *buffer) {
    if (buffer == nullptr) {
        return 0;
    }
    return buffer->capacity_frames - ypq_ring_buffer_available_to_read(buffer);
}

uint32_t ypq_ring_buffer_discard_all(ypq_ring_buffer *buffer) {
    if (buffer == nullptr) return 0;
    const uint32_t read = buffer->read_index.load(std::memory_order_acquire);
    const uint32_t write = buffer->write_index.load(std::memory_order_acquire);
    buffer->read_index.store(write, std::memory_order_release);
    return write - read;
}
