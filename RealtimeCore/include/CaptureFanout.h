#pragma once

#include <stdbool.h>
#include <stdint.h>

#include <CoreAudio/CoreAudioTypes.h>

#include "RouteBinding.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ypq_capture_fanout ypq_capture_fanout;
typedef struct ypq_capture_input_queue ypq_capture_input_queue;
typedef void (*ypq_capture_fanout_snapshot_visitor)(
    void *context,
    ypq_route_binding *const *bindings,
    uint32_t binding_count,
    uint64_t generation
);

/// Owns immutable binding snapshots for one stable Process Tap callback.
/// Bindings are borrowed, not retained. Every binding must outlive safe
/// acknowledgement of every snapshot that contains it, or fan-out destruction
/// when such a snapshot has not been acknowledged.
ypq_capture_fanout *ypq_capture_fanout_create(void);
void ypq_capture_fanout_destroy(ypq_capture_fanout *fanout);

/// Control-plane-only publication. The caller serializes publish and
/// acknowledge operations. A rejected snapshot leaves the current target
/// unchanged. Published bindings remain borrowed under the lifetime rule above.
bool ypq_capture_fanout_publish(
    ypq_capture_fanout *fanout,
    ypq_route_binding *const *bindings,
    uint32_t binding_count,
    uint64_t generation
);

/// Process Tap callback operation. It performs no allocation, locking,
/// logging, blocking, discovery, or format conversion.
uint32_t ypq_capture_fanout_write(
    ypq_capture_fanout *fanout,
    const float *interleaved_stereo_frames,
    uint32_t frame_count
);

/// Publishes the Process Tap timestamp to every binding in the same immutable
/// target domain without retaining a Swift-side binding pointer.
void ypq_capture_fanout_record_producer_timestamp(
    ypq_capture_fanout *fanout,
    double sample_time,
    uint64_t host_time
);

/// Reclaims snapshots older than `generation` only after a completed callback
/// has observed that generation. Returns false while that proof is absent.
bool ypq_capture_fanout_acknowledge(
    ypq_capture_fanout *fanout,
    uint64_t generation
);

/// Control-plane shutdown used before unregistering the Process Tap IOProc.
/// It rejects new callbacks, waits for the admitted callback to finish, and
/// begins retirement for every binding still borrowed by a live snapshot.
bool ypq_capture_fanout_begin_shutdown(ypq_capture_fanout *fanout);

/// Called after the IOProc is unregistered. It marks every binding still
/// borrowed by the closed fan-out as producer-detached.
void ypq_capture_fanout_mark_producer_detached(ypq_capture_fanout *fanout);

/// Deterministic lifetime-test seam. It holds the same callback admission and
/// immutable snapshot lease as `write` while `visitor` runs.
bool ypq_capture_fanout_visit_current_snapshot_for_testing(
    ypq_capture_fanout *fanout,
    ypq_capture_fanout_snapshot_visitor visitor,
    void *context
);

/// A fixed-capacity single-producer/single-consumer queue for Process Tap
/// input blocks. Create and destroy it on the control plane only. The producer
/// copies an AudioBufferList into preallocated storage and never allocates,
/// locks, blocks, or invokes an audio converter.
ypq_capture_input_queue *ypq_capture_input_queue_create(
    uint32_t maximum_frames_per_block,
    uint32_t bytes_per_frame,
    uint32_t maximum_buffer_count,
    uint32_t capacity_blocks
);
void ypq_capture_input_queue_destroy(ypq_capture_input_queue *queue);

/// Single-producer callback operation. The input is copied before this
/// function returns, so its memory may be immediately reused by Core Audio.
/// A full or malformed queue input is dropped and returns false.
bool ypq_capture_input_queue_enqueue(
    ypq_capture_input_queue *queue,
    const AudioBufferList *input
);

/// Single-consumer worker operation. The returned pointer remains valid until
/// `end_read` and must not be retained. Returns null when the queue is empty.
const AudioBufferList *ypq_capture_input_queue_begin_read(
    ypq_capture_input_queue *queue,
    uint32_t *frame_count
);
void ypq_capture_input_queue_end_read(ypq_capture_input_queue *queue);
uint64_t ypq_capture_input_queue_dropped_blocks(
    const ypq_capture_input_queue *queue
);

#ifdef __cplusplus
}
#endif
