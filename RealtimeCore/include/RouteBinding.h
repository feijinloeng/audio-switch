#pragma once

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ypq_route_binding ypq_route_binding;

/// Allocates a binding-owned stereo SPSC buffer and lifecycle guards.
ypq_route_binding *ypq_route_binding_create(uint32_t capacity_frames);
void ypq_route_binding_destroy(ypq_route_binding *binding);

/// Capture and output callback operations. They only use preallocated storage
/// and callback gates, so they never allocate, lock, log, or block.
uint32_t ypq_route_binding_write(
    ypq_route_binding *binding,
    const float *interleaved_stereo_frames,
    uint32_t frame_count
);
uint32_t ypq_route_binding_read(
    ypq_route_binding *binding,
    float *interleaved_stereo_frames,
    uint32_t frame_count
);
/// Reads available producer frames without treating unused scratch capacity as
/// a playback underrun. ASRC owns the conversion to output-frame accounting
/// and calls `ypq_route_binding_record_underrun` with the real deficit.
uint32_t ypq_route_binding_read_unmetered(
    ypq_route_binding *binding,
    float *interleaved_stereo_frames,
    uint32_t frame_count
);
void ypq_route_binding_record_underrun(ypq_route_binding *binding, uint32_t frame_count);

/// Monotonic frame counts for bounded SPSC short writes/reads. These are
/// observed off the realtime path; callbacks only perform atomic increments.
uint64_t ypq_route_binding_overrun_frames(const ypq_route_binding *binding);
uint64_t ypq_route_binding_underrun_frames(const ypq_route_binding *binding);

/// Capture-side heartbeat and successful frame totals. They are monotonic
/// atomics intended for control-plane diagnostics and hardware evidence;
/// reading them never changes callback behavior.
uint64_t ypq_route_binding_producer_callback_count(const ypq_route_binding *binding);
uint64_t ypq_route_binding_produced_frames(const ypq_route_binding *binding);

/// The capture IOProc records its most recent AudioTimeStamp with two atomic
/// stores. It performs no allocation, locking, formatting, or Swift work.
void ypq_route_binding_record_producer_timestamp(
    ypq_route_binding *binding,
    double sample_time,
    uint64_t host_time
);
double ypq_route_binding_last_producer_sample_time(const ypq_route_binding *binding);
uint64_t ypq_route_binding_last_producer_host_time(const ypq_route_binding *binding);

/// Number of capture-domain frames currently queued for the output clock
/// bridge. This is sampled by the output callback before it updates its
/// adaptive ratio; it does not mutate the SPSC buffer.
uint32_t ypq_route_binding_available_frames(const ypq_route_binding *binding);

/// Publishes the per-app controls consumed by the output callback. The
/// control plane may call this at any time; publication is lock-free and
/// allocation-free.
void ypq_route_binding_publish_controls(
    ypq_route_binding *binding,
    float gain,
    bool muted
);
float ypq_route_binding_published_gain(const ypq_route_binding *binding);
bool ypq_route_binding_published_muted(const ypq_route_binding *binding);

/// Stops new producer callbacks. Existing output callbacks may continue to
/// drain the sealed tail until the output snapshot has removed this binding.
bool ypq_route_binding_begin_retirement(ypq_route_binding *binding);
void ypq_route_binding_mark_producer_detached(ypq_route_binding *binding);
void ypq_route_binding_acknowledge_snapshot_removal(
    ypq_route_binding *binding,
    uint64_t snapshot_generation
);

/// Drops a sealed tail only after both callback gates are quiescent. This is
/// a bounded control-plane fallback when an output session is stopped before
/// the producer tail can naturally drain; it is never a realtime operation.
bool ypq_route_binding_discard_sealed_tail(ypq_route_binding *binding);

/// True only after producer detach, sealed-tail drain, snapshot removal and
/// both callback gates becoming quiescent.
bool ypq_route_binding_ready_to_reclaim(
    const ypq_route_binding *binding,
    uint64_t required_snapshot_generation
);
bool ypq_route_binding_finish_retirement(ypq_route_binding *binding);

#ifdef __cplusplus
}
#endif
