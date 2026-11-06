#include "CaptureFanout.h"

#include "RealtimeCallbackGate.h"

#include <atomic>
#include <cstddef>
#include <cstring>
#include <limits>
#include <new>
#include <vector>

struct capture_fanout_snapshot {
    uint64_t generation {0};
    std::vector<ypq_route_binding *> bindings;
    capture_fanout_snapshot *retired_next {nullptr};
};

struct ypq_capture_fanout {
    ypq_capture_fanout(
        capture_fanout_snapshot *initial,
        ypq_callback_gate *gate
    ) : current(initial), callback_gate(gate) {}

    std::atomic<capture_fanout_snapshot *> current;
    ypq_callback_gate *callback_gate;
    capture_fanout_snapshot *retired_head {nullptr};
    bool is_shutdown {false};
};

struct capture_input_slot {
    AudioBufferList *list {nullptr};
    uint8_t *samples {nullptr};
};

struct ypq_capture_input_queue {
    uint32_t maximum_frames_per_block {0};
    uint32_t bytes_per_frame {0};
    uint32_t maximum_buffer_count {0};
    uint32_t slot_count {0};
    uint32_t bytes_per_buffer {0};
    std::vector<capture_input_slot> slots;
    std::atomic<uint32_t> write_index {0};
    std::atomic<uint32_t> read_index {0};
    std::atomic<uint64_t> dropped_blocks {0};
};

namespace {

void destroy_snapshot_list(capture_fanout_snapshot *snapshot) {
    while (snapshot != nullptr) {
        auto *next = snapshot->retired_next;
        delete snapshot;
        snapshot = next;
    }
}

bool bindings_are_valid(
    ypq_route_binding *const *bindings,
    uint32_t binding_count
) {
    if (binding_count != 0 && bindings == nullptr) return false;
    for (uint32_t index = 0; index < binding_count; ++index) {
        if (bindings[index] == nullptr) return false;
        for (uint32_t prior = 0; prior < index; ++prior) {
            if (bindings[prior] == bindings[index]) return false;
        }
    }
    return true;
}

bool queue_limits_are_valid(
    uint32_t maximum_frames_per_block,
    uint32_t bytes_per_frame,
    uint32_t maximum_buffer_count,
    uint32_t capacity_blocks
) {
    if (maximum_frames_per_block == 0
        || bytes_per_frame == 0
        || maximum_buffer_count == 0
        || capacity_blocks == 0
        || capacity_blocks == std::numeric_limits<uint32_t>::max()) {
        return false;
    }
    return maximum_frames_per_block
        <= std::numeric_limits<uint32_t>::max() / bytes_per_frame;
}

void destroy_input_queue_slots(ypq_capture_input_queue *queue) {
    for (auto &slot : queue->slots) {
        delete[] reinterpret_cast<uint8_t *>(slot.list);
        delete[] slot.samples;
    }
}

template <typename Operation>
void for_each_borrowed_binding(
    ypq_capture_fanout *fanout,
    Operation operation
) {
    if (auto *snapshot = fanout->current.load(std::memory_order_acquire)) {
        for (auto *binding : snapshot->bindings) {
            operation(binding);
        }
    }
    for (auto *snapshot = fanout->retired_head;
         snapshot != nullptr;
         snapshot = snapshot->retired_next) {
        for (auto *binding : snapshot->bindings) {
            operation(binding);
        }
    }
}

} // namespace

ypq_capture_fanout *ypq_capture_fanout_create(void) {
    auto *initial = new (std::nothrow) capture_fanout_snapshot;
    if (initial == nullptr) return nullptr;

    ypq_callback_gate *gate = nullptr;
    try {
        gate = ypq_callback_gate_create();
    } catch (...) {
        delete initial;
        return nullptr;
    }
    if (gate == nullptr) {
        delete initial;
        return nullptr;
    }

    auto *fanout = new (std::nothrow) ypq_capture_fanout(initial, gate);
    if (fanout == nullptr) {
        ypq_callback_gate_destroy(gate);
        delete initial;
    }
    return fanout;
}

void ypq_capture_fanout_destroy(ypq_capture_fanout *fanout) {
    if (fanout == nullptr) return;

    (void)ypq_callback_gate_close_and_wait(fanout->callback_gate);

    delete fanout->current.exchange(nullptr, std::memory_order_acq_rel);
    destroy_snapshot_list(fanout->retired_head);
    ypq_callback_gate_destroy(fanout->callback_gate);
    delete fanout;
}

bool ypq_capture_fanout_publish(
    ypq_capture_fanout *fanout,
    ypq_route_binding *const *bindings,
    uint32_t binding_count,
    uint64_t generation
) {
    if (fanout == nullptr
        || fanout->is_shutdown
        || generation == 0
        || !bindings_are_valid(bindings, binding_count)) {
        return false;
    }

    auto *prior = fanout->current.load(std::memory_order_acquire);
    if (prior == nullptr || generation <= prior->generation) return false;

    auto *replacement = new (std::nothrow) capture_fanout_snapshot;
    if (replacement == nullptr) return false;
    replacement->generation = generation;
    try {
        if (binding_count != 0) {
            replacement->bindings.assign(bindings, bindings + binding_count);
        }
    } catch (...) {
        delete replacement;
        return false;
    }

    prior = fanout->current.exchange(replacement, std::memory_order_acq_rel);
    prior->retired_next = fanout->retired_head;
    fanout->retired_head = prior;
    return true;
}

uint32_t ypq_capture_fanout_write(
    ypq_capture_fanout *fanout,
    const float *interleaved_stereo_frames,
    uint32_t frame_count
) {
    if (fanout == nullptr
        || interleaved_stereo_frames == nullptr
        || frame_count == 0
        || !ypq_callback_gate_try_enter(fanout->callback_gate)) {
        return 0;
    }

    auto *snapshot = fanout->current.load(std::memory_order_acquire);
    if (snapshot != nullptr) {
        for (auto *binding : snapshot->bindings) {
            (void)ypq_route_binding_write(
                binding,
                interleaved_stereo_frames,
                frame_count
            );
        }
    }
    const uint64_t generation = snapshot == nullptr ? 0 : snapshot->generation;
    ypq_callback_gate_leave(fanout->callback_gate, generation);
    return snapshot == nullptr ? 0 : frame_count;
}

void ypq_capture_fanout_record_producer_timestamp(
    ypq_capture_fanout *fanout,
    double sample_time,
    uint64_t host_time
) {
    if (fanout == nullptr || !ypq_callback_gate_try_enter(fanout->callback_gate)) {
        return;
    }

    auto *snapshot = fanout->current.load(std::memory_order_acquire);
    if (snapshot != nullptr) {
        for (auto *binding : snapshot->bindings) {
            ypq_route_binding_record_producer_timestamp(
                binding,
                sample_time,
                host_time
            );
        }
    }
    const uint64_t generation = snapshot == nullptr ? 0 : snapshot->generation;
    ypq_callback_gate_leave(fanout->callback_gate, generation);
}

bool ypq_capture_fanout_acknowledge(
    ypq_capture_fanout *fanout,
    uint64_t generation
) {
    if (fanout == nullptr || generation == 0) return false;
    auto *current = fanout->current.load(std::memory_order_acquire);
    if (current == nullptr || generation > current->generation) return false;
    if (!ypq_callback_gate_has_idle_acknowledgement(
            fanout->callback_gate,
            generation
        )) {
        return false;
    }

    auto **link = &fanout->retired_head;
    while (*link != nullptr) {
        auto *snapshot = *link;
        if (snapshot->generation < generation) {
            *link = snapshot->retired_next;
            delete snapshot;
        } else {
            link = &snapshot->retired_next;
        }
    }
    return true;
}

bool ypq_capture_fanout_begin_shutdown(ypq_capture_fanout *fanout) {
    if (fanout == nullptr) {
        return false;
    }
    if (fanout->is_shutdown) {
        return true;
    }
    if (!ypq_callback_gate_close_and_wait(fanout->callback_gate)) {
        return false;
    }
    fanout->is_shutdown = true;
    for_each_borrowed_binding(fanout, [](ypq_route_binding *binding) {
        (void)ypq_route_binding_begin_retirement(binding);
    });
    return true;
}

void ypq_capture_fanout_mark_producer_detached(ypq_capture_fanout *fanout) {
    if (fanout == nullptr || !fanout->is_shutdown) {
        return;
    }
    for_each_borrowed_binding(fanout, [](ypq_route_binding *binding) {
        ypq_route_binding_mark_producer_detached(binding);
    });
}

bool ypq_capture_fanout_visit_current_snapshot_for_testing(
    ypq_capture_fanout *fanout,
    ypq_capture_fanout_snapshot_visitor visitor,
    void *context
) {
    if (fanout == nullptr
        || visitor == nullptr
        || !ypq_callback_gate_try_enter(fanout->callback_gate)) {
        return false;
    }

    auto *snapshot = fanout->current.load(std::memory_order_acquire);
    if (snapshot != nullptr) {
        visitor(
            context,
            snapshot->bindings.data(),
            static_cast<uint32_t>(snapshot->bindings.size()),
            snapshot->generation
        );
    }
    const uint64_t generation = snapshot == nullptr ? 0 : snapshot->generation;
    ypq_callback_gate_leave(fanout->callback_gate, generation);
    return snapshot != nullptr;
}

ypq_capture_input_queue *ypq_capture_input_queue_create(
    uint32_t maximum_frames_per_block,
    uint32_t bytes_per_frame,
    uint32_t maximum_buffer_count,
    uint32_t capacity_blocks
) {
    if (!queue_limits_are_valid(
            maximum_frames_per_block,
            bytes_per_frame,
            maximum_buffer_count,
            capacity_blocks
        )) {
        return nullptr;
    }

    const uint32_t bytes_per_buffer = maximum_frames_per_block * bytes_per_frame;
    const size_t audio_buffer_list_size = offsetof(AudioBufferList, mBuffers)
        + sizeof(AudioBuffer) * static_cast<size_t>(maximum_buffer_count);
    if (maximum_buffer_count > 0
        && audio_buffer_list_size / sizeof(AudioBuffer)
            < static_cast<size_t>(maximum_buffer_count)) {
        return nullptr;
    }
    const size_t samples_per_slot = static_cast<size_t>(bytes_per_buffer)
        * static_cast<size_t>(maximum_buffer_count);
    if (maximum_buffer_count > 0
        && samples_per_slot / maximum_buffer_count != bytes_per_buffer) {
        return nullptr;
    }

    auto *queue = new (std::nothrow) ypq_capture_input_queue;
    if (queue == nullptr) return nullptr;
    queue->maximum_frames_per_block = maximum_frames_per_block;
    queue->bytes_per_frame = bytes_per_frame;
    queue->maximum_buffer_count = maximum_buffer_count;
    queue->slot_count = capacity_blocks + 1;
    queue->bytes_per_buffer = bytes_per_buffer;
    try {
        queue->slots.resize(queue->slot_count);
        for (auto &slot : queue->slots) {
            slot.list = reinterpret_cast<AudioBufferList *>(
                new uint8_t[audio_buffer_list_size]
            );
            slot.samples = new uint8_t[samples_per_slot];
            slot.list->mNumberBuffers = maximum_buffer_count;
            for (uint32_t index = 0; index < maximum_buffer_count; ++index) {
                auto &buffer = slot.list->mBuffers[index];
                buffer.mNumberChannels = 0;
                buffer.mDataByteSize = 0;
                buffer.mData = slot.samples + static_cast<size_t>(index)
                    * bytes_per_buffer;
            }
        }
    } catch (...) {
        destroy_input_queue_slots(queue);
        delete queue;
        return nullptr;
    }
    return queue;
}

void ypq_capture_input_queue_destroy(ypq_capture_input_queue *queue) {
    if (queue == nullptr) return;
    destroy_input_queue_slots(queue);
    delete queue;
}

bool ypq_capture_input_queue_enqueue(
    ypq_capture_input_queue *queue,
    const AudioBufferList *input
) {
    if (queue == nullptr || input == nullptr
        || input->mNumberBuffers == 0
        || input->mNumberBuffers > queue->maximum_buffer_count) {
        if (queue != nullptr) {
            queue->dropped_blocks.fetch_add(1, std::memory_order_relaxed);
        }
        return false;
    }

    const uint32_t producer_index = queue->write_index.load(std::memory_order_relaxed);
    const uint32_t next_index = (producer_index + 1) % queue->slot_count;
    if (next_index == queue->read_index.load(std::memory_order_acquire)) {
        queue->dropped_blocks.fetch_add(1, std::memory_order_relaxed);
        return false;
    }

    uint32_t frame_count = 0;
    for (uint32_t index = 0; index < input->mNumberBuffers; ++index) {
        const auto &source = input->mBuffers[index];
        if (source.mData == nullptr
            || source.mDataByteSize == 0
            || source.mDataByteSize > queue->bytes_per_buffer
            || source.mDataByteSize % queue->bytes_per_frame != 0) {
            queue->dropped_blocks.fetch_add(1, std::memory_order_relaxed);
            return false;
        }
        const uint32_t candidate_frames = source.mDataByteSize / queue->bytes_per_frame;
        if (candidate_frames > queue->maximum_frames_per_block
            || (index != 0 && candidate_frames != frame_count)) {
            queue->dropped_blocks.fetch_add(1, std::memory_order_relaxed);
            return false;
        }
        frame_count = candidate_frames;
    }

    auto &slot = queue->slots[producer_index];
    slot.list->mNumberBuffers = input->mNumberBuffers;
    for (uint32_t index = 0; index < input->mNumberBuffers; ++index) {
        const auto &source = input->mBuffers[index];
        auto &destination = slot.list->mBuffers[index];
        destination.mNumberChannels = source.mNumberChannels;
        destination.mDataByteSize = source.mDataByteSize;
        std::memcpy(destination.mData, source.mData, source.mDataByteSize);
    }
    queue->write_index.store(next_index, std::memory_order_release);
    return true;
}

const AudioBufferList *ypq_capture_input_queue_begin_read(
    ypq_capture_input_queue *queue,
    uint32_t *frame_count
) {
    if (queue == nullptr) return nullptr;
    const uint32_t consumer_index = queue->read_index.load(std::memory_order_relaxed);
    if (consumer_index == queue->write_index.load(std::memory_order_acquire)) {
        return nullptr;
    }
    const auto &slot = queue->slots[consumer_index];
    if (frame_count != nullptr) {
        *frame_count = slot.list->mBuffers[0].mDataByteSize / queue->bytes_per_frame;
    }
    return slot.list;
}

void ypq_capture_input_queue_end_read(ypq_capture_input_queue *queue) {
    if (queue == nullptr) return;
    const uint32_t consumer_index = queue->read_index.load(std::memory_order_relaxed);
    if (consumer_index == queue->write_index.load(std::memory_order_acquire)) return;
    queue->read_index.store(
        (consumer_index + 1) % queue->slot_count,
        std::memory_order_release
    );
}

uint64_t ypq_capture_input_queue_dropped_blocks(
    const ypq_capture_input_queue *queue
) {
    return queue == nullptr
        ? 0
        : queue->dropped_blocks.load(std::memory_order_relaxed);
}
